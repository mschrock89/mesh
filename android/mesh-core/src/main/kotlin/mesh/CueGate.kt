package mesh

data class CuePolicy(
    val sends: Boolean = true,
    val receives: Boolean = true,
    val blockedSources: Set<String> = emptySet(),
    val blockedDestinations: Set<String> = emptySet()
) {
    fun accepts(uuid: String): Boolean {
        val id = uuid.lowercase()
        return id.isEmpty() || id !in blockedSources
    }

    fun delivers(uuid: String): Boolean {
        val id = uuid.lowercase()
        return id.isEmpty() || id !in blockedDestinations
    }
}

data class CueOrigin(val uuid: String, val sends: Boolean, val receives: Boolean)

/** Notes and ordinary controllers. Clock, active sensing, and channel-mode resets are port chatter. */
object CueBytes {
    fun audible(data: ByteArray): ByteArray {
        val output = ArrayList<Byte>(data.size)
        var index = 0
        var running = 0
        while (index < data.size) {
            val byte = data[index].toInt() and 0xFF
            if (byte >= 0xF8) {
                index += 1
                continue
            }
            if (byte == 0xF0) {
                output.add(byte.toByte())
                index += 1
                while (index < data.size) {
                    val next = data[index].toInt() and 0xFF
                    if (next >= 0xF8) {
                        index += 1
                        continue
                    }
                    output.add(next.toByte())
                    index += 1
                    if (next == 0xF7) break
                }
                running = 0
                continue
            }
            if (byte >= 0xF0) {
                index += systemCommonLength(byte)
                running = 0
                continue
            }

            val status: Int
            val dataStart: Int
            if (byte >= 0x80) {
                status = byte
                running = byte
                dataStart = index + 1
            } else if (running in 0x80..0xEF) {
                status = running
                dataStart = index
            } else {
                index += 1
                continue
            }
            val dataLength = if (status and 0xF0 == 0xC0 || status and 0xF0 == 0xD0) 1 else 2
            if (dataStart + dataLength > data.size) break
            val first = data[dataStart].toInt() and 0xFF
            val channelMode = status and 0xF0 == 0xB0 && first >= 120
            if (!channelMode) {
                output.add(status.toByte())
                for (cursor in dataStart until dataStart + dataLength) output.add(data[cursor])
            }
            index = dataStart + dataLength
        }
        return ByteArray(output.size) { output[it] }
    }

    private fun systemCommonLength(status: Int): Int = when (status) {
        0xF1, 0xF3 -> 2
        0xF2 -> 3
        else -> 1
    }
}
