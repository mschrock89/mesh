package mesh

/**
 * Apple network MIDI, plus the room name Mesh adds to invitations.
 * Clock ticks are 100 microseconds of a monotonic clock. The timestamp inside a
 * MIDI packet is an event id, not one of those ticks: peers use it to drop echoes.
 */
object AppleMidiClock {
    fun now(): Long {
        val nanos = System.nanoTime()
        return if (nanos <= 0L) 0L else nanos / 100_000L
    }
}

object AppleMidi {
    const val SIGNATURE: Int = 0xFFFF
    const val VERSION: Long = 2

    enum class Command(val code: Int) {
        Invitation(0x494E),
        Accepted(0x4F4B),
        Rejected(0x4E4F),
        Exit(0x4259),
        Synchronization(0x434B),
        Feedback(0x5253),
        Directory(0x4D44);

        companion object {
            fun from(code: Int): Command? = entries.firstOrNull { it.code == code }
        }
    }

    data class DirectoryEntry(val ip: Ipv4, val port: Int, val uuid: String, val name: String)

    data class Exchange(
        val command: Command,
        val token: UInt,
        val ssrc: UInt,
        val name: String,
        val room: String = ""
    )

    data class Sync(
        val ssrc: UInt,
        val count: Int,
        val timestamp1: Long,
        val timestamp2: Long,
        val timestamp3: Long
    )

    class MidiPayload(
        val sequence: Int,
        val timestamp: UInt,
        val ssrc: UInt,
        val midi: ByteArray
    )

    sealed class Packet {
        class ExchangePacket(val message: Exchange) : Packet()
        class SyncPacket(val message: Sync) : Packet()
        class Feedback(val ssrc: UInt, val sequence: Int) : Packet()
        class Midi(val payload: MidiPayload) : Packet()
        class Directory(val ssrc: UInt, val peers: List<DirectoryEntry>) : Packet()
    }

    fun encodeDirectory(ssrc: UInt, peers: List<DirectoryEntry>): ByteArray {
        val out = Writer()
        out.u16(SIGNATURE)
        out.u16(Command.Directory.code)
        out.u32(ssrc)
        for (peer in peers.take(8)) {
            out.raw(peer.ip.networkBytes())
            out.u16(peer.port)
            out.cstr(peer.uuid)
            out.cstr(peer.name)
        }
        return out.bytes()
    }

    fun encodeExchange(message: Exchange): ByteArray {
        val out = Writer()
        out.u16(SIGNATURE)
        out.u16(message.command.code)
        out.u32(VERSION.toUInt())
        out.u32(message.token)
        out.u32(message.ssrc)
        if (message.command == Command.Invitation || message.command == Command.Accepted) {
            out.cstr(utf8Prefix(message.name, 63))
            out.cstr(utf8Prefix(message.room, 80))
        }
        return out.bytes()
    }

    fun encodeSync(message: Sync): ByteArray {
        val out = Writer()
        out.u16(SIGNATURE)
        out.u16(Command.Synchronization.code)
        out.u32(message.ssrc)
        out.u8(message.count)
        out.u8(0)
        out.u8(0)
        out.u8(0)
        out.u64(message.timestamp1)
        out.u64(message.timestamp2)
        out.u64(message.timestamp3)
        return out.bytes()
    }

    fun encodeMidi(sequence: Int, timestamp: UInt, ssrc: UInt, midi: ByteArray): ByteArray {
        val out = Writer()
        out.u8(0x80)
        out.u8(0xE1)
        out.u16(sequence)
        out.u32(timestamp)
        out.u32(ssrc)
        val length = minOf(midi.size, 4095)
        if (length < 16) {
            out.u8(length)
        } else {
            out.u8(0x80 or ((length shr 8) and 0x0F))
            out.u8(length and 0xFF)
        }
        out.raw(midi.copyOf(length))
        return out.bytes()
    }

    fun decode(data: ByteArray): Packet? {
        if (data.size < 4 || u16(data, 0) != SIGNATURE) return decodeMidi(data)
        val command = Command.from(u16(data, 2) ?: return null) ?: return null
        return when (command) {
            Command.Synchronization -> decodeSync(data)?.let(Packet::SyncPacket)
            Command.Feedback -> decodeFeedback(data)
            Command.Directory -> decodeDirectory(data)?.let { Packet.Directory(it.first, it.second) }
            else -> decodeExchange(data, command)?.let(Packet::ExchangePacket)
        }
    }

    private fun decodeDirectory(data: ByteArray): Pair<UInt, List<DirectoryEntry>>? {
        val ssrc = u32(data, 4) ?: return null
        var offset = 8
        val peers = mutableListOf<DirectoryEntry>()
        while (offset < data.size) {
            if (offset + 6 > data.size) return null
            val ip = Ipv4.fromNetworkBytes(data.copyOfRange(offset, offset + 4))
            offset += 4
            val port = u16(data, offset) ?: return null
            offset += 2
            val cursor = intArrayOf(offset)
            val uuid = readCString(data, cursor) ?: return null
            val name = readCString(data, cursor) ?: return null
            offset = cursor[0]
            peers.add(DirectoryEntry(ip, port, uuid, name))
        }
        return ssrc to peers
    }

    private fun decodeExchange(data: ByteArray, command: Command): Exchange? {
        if (data.size < 16) return null
        val token = u32(data, 8) ?: return null
        val ssrc = u32(data, 12) ?: return null
        val cursor = intArrayOf(16)
        val name: String
        val room: String
        if (cursor[0] < data.size) {
            val decoded = readCString(data, cursor)
            if (decoded != null) {
                name = decoded
                room = if (cursor[0] < data.size) readCString(data, cursor) ?: "" else ""
            } else {
                name = readName(data, 16)
                room = ""
            }
        } else {
            name = readName(data, 16)
            room = ""
        }
        return Exchange(command, token, ssrc, name, room)
    }

    private fun decodeSync(data: ByteArray): Sync? {
        if (data.size < 36) return null
        val ssrc = u32(data, 4) ?: return null
        val timestamp1 = u64(data, 12) ?: return null
        val timestamp2 = u64(data, 20) ?: return null
        val timestamp3 = u64(data, 28) ?: return null
        return Sync(ssrc, data[8].toInt() and 0xFF, timestamp1, timestamp2, timestamp3)
    }

    private fun decodeFeedback(data: ByteArray): Packet? {
        if (data.size < 12) return null
        val ssrc = u32(data, 4) ?: return null
        val sequence = u16(data, 8) ?: return null
        return Packet.Feedback(ssrc, sequence)
    }

    private fun decodeMidi(data: ByteArray): Packet? {
        if (data.size < 13) return null
        val lead = data[0].toInt() and 0xFF
        val marker = data[1].toInt() and 0xFF
        if (lead ushr 6 != 2) return null
        if (marker and 0x7F != 0x61) return null
        val sequence = u16(data, 2) ?: return null
        val timestamp = u32(data, 4) ?: return null
        val ssrc = u32(data, 8) ?: return null
        val header = data[12].toInt() and 0xFF
        val length: Int
        val start: Int
        if (header and 0x80 != 0) {
            if (data.size < 14) return null
            length = ((header and 0x0F) shl 8) or (data[13].toInt() and 0xFF)
            start = 14
        } else {
            length = header and 0x0F
            start = 13
        }
        if (data.size < start + length) return null
        val midi = if (length == 0) ByteArray(0) else data.copyOfRange(start, start + length)
        return Packet.Midi(MidiPayload(sequence, timestamp, ssrc, midi))
    }

    private fun utf8Prefix(value: String, max: Int): String {
        val raw = value.toByteArray(Charsets.UTF_8)
        if (raw.size <= max) return value
        return String(raw.copyOf(max), Charsets.UTF_8)
    }

    private fun readCString(data: ByteArray, offset: IntArray): String? {
        val start = offset[0]
        var cursor = start
        while (cursor < data.size && data[cursor] != 0.toByte()) cursor += 1
        if (cursor >= data.size) return null
        val text = String(data, start, cursor - start, Charsets.UTF_8)
        offset[0] = cursor + 1
        return text
    }

    private fun readName(data: ByteArray, offset: Int): String {
        if (offset >= data.size) return ""
        var end = offset
        while (end < data.size && data[end] != 0.toByte()) end += 1
        return String(data, offset, end - offset, Charsets.UTF_8)
    }

    private fun u16(data: ByteArray, offset: Int): Int? {
        if (offset < 0 || offset + 2 > data.size) return null
        return ((data[offset].toInt() and 0xFF) shl 8) or (data[offset + 1].toInt() and 0xFF)
    }

    private fun u32(data: ByteArray, offset: Int): UInt? {
        val hi = u16(data, offset) ?: return null
        val lo = u16(data, offset + 2) ?: return null
        return (hi.toUInt() shl 16) or lo.toUInt()
    }

    private fun u64(data: ByteArray, offset: Int): Long? {
        val hi = u32(data, offset) ?: return null
        val lo = u32(data, offset + 4) ?: return null
        return (hi.toLong() shl 32) or lo.toLong()
    }

    private class Writer {
        private val out = ArrayList<Byte>(64)
        fun u8(value: Int) { out.add(value.toByte()) }
        fun u16(value: Int) { u8(value ushr 8); u8(value) }
        fun u32(value: UInt) { u16((value shr 16).toInt()); u16(value.toInt()) }
        fun u64(value: Long) { u32((value ushr 32).toUInt()); u32(value.toUInt()) }
        fun raw(bytes: ByteArray) { for (byte in bytes) out.add(byte) }
        fun cstr(value: String) { raw(value.toByteArray(Charsets.UTF_8)); u8(0) }
        fun bytes(): ByteArray = ByteArray(out.size) { out[it] }
    }
}
