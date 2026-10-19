package mesh

import org.junit.jupiter.api.Assertions.assertArrayEquals
import org.junit.jupiter.api.Assertions.assertEquals
import org.junit.jupiter.api.Assertions.assertFalse
import org.junit.jupiter.api.Assertions.assertNotNull
import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.io.TempDir
import java.io.File
import java.nio.file.Path

class ProtocolTest {
    @Test
    fun `apple packets match the mac encoder byte for byte`() {
        val invitation = AppleMidi.encodeExchange(
            AppleMidi.Exchange(AppleMidi.Command.Invitation, 42u, 99u, "Booth", "sanctuary-2")
        )
        assertEquals(
            "FFFF494E000000020000002A00000063426F6F74680073616E6374756172792D3200",
            invitation.hex()
        )
        val decoded = AppleMidi.decode(invitation) as AppleMidi.Packet.ExchangePacket
        assertEquals(AppleMidi.Command.Invitation, decoded.message.command)
        assertEquals(42u, decoded.message.token)
        assertEquals(99u, decoded.message.ssrc)
        assertEquals("Booth", decoded.message.name)
        assertEquals("sanctuary-2", decoded.message.room)

        val accepted = AppleMidi.encodeExchange(
            AppleMidi.Exchange(AppleMidi.Command.Accepted, 7u, 8u, "Booth", "")
        )
        val acceptedDecoded = AppleMidi.decode(accepted) as AppleMidi.Packet.ExchangePacket
        assertEquals("", acceptedDecoded.message.room)
        assertEquals("Booth", acceptedDecoded.message.name)

        val rejected = AppleMidi.encodeExchange(
            AppleMidi.Exchange(AppleMidi.Command.Rejected, 1u, 2u, "")
        )
        assertEquals("FFFF4E4F000000020000000100000002", rejected.hex())

        val sync = AppleMidi.encodeSync(AppleMidi.Sync(7u, 1, 10, 20, 30))
        assertEquals(
            "FFFF434B0000000701000000000000000000000A0000000000000014000000000000001E",
            sync.hex()
        )
        val decodedSync = (AppleMidi.decode(sync) as AppleMidi.Packet.SyncPacket).message
        assertEquals(7u, decodedSync.ssrc)
        assertEquals(1, decodedSync.count)
        assertEquals(20L, decodedSync.timestamp2)

        val note = byteArrayOf(0x90.toByte(), 60, 100)
        val midi = AppleMidi.encodeMidi(8, 1234u, 5u, note)
        assertEquals("80E10008000004D20000000503903C64", midi.hex())
        val payload = (AppleMidi.decode(midi) as AppleMidi.Packet.Midi).payload
        assertEquals(8, payload.sequence)
        assertEquals(1234u, payload.timestamp)
        assertArrayEquals(note, payload.midi)

        val long = ByteArray(20) { 0x90.toByte() }
        val longPacket = AppleMidi.encodeMidi(1, 2u, 3u, long)
        assertEquals(
            "80E1000100000002000000038014" + "90".repeat(20),
            longPacket.hex()
        )
        assertArrayEquals(long, (AppleMidi.decode(longPacket) as AppleMidi.Packet.Midi).payload.midi)

        // 10.10.13.88 is stored by the Mac as native memory of in_addr, which is these four octets.
        val entry = AppleMidi.DirectoryEntry(Ipv4.parse("10.10.13.88")!!, 5006, "abc", "Booth")
        val directory = AppleMidi.encodeDirectory(4u, listOf(entry))
        assertEquals("FFFF4D44000000040A0A0D58138E61626300426F6F746800", directory.hex())
        val listed = AppleMidi.decode(directory) as AppleMidi.Packet.Directory
        assertEquals(4u, listed.ssrc)
        assertEquals(1, listed.peers.size)
        assertEquals(5006, listed.peers[0].port)
        assertEquals("abc", listed.peers[0].uuid)
        assertEquals("Booth", listed.peers[0].name)
        assertEquals(entry.ip, listed.peers[0].ip)

        val feedback = AppleMidi.decode(hex("FFFF52530000000900110000")) as AppleMidi.Packet.Feedback
        assertEquals(9u, feedback.ssrc)
        assertEquals(17, feedback.sequence)
    }

    @Test
    fun `addresses rank loopback and link local the way the mac does`() {
        assertEquals(100, LocalAddresses.rank(Ipv4.parse("127.0.0.1")!!))
        assertEquals(100, LocalAddresses.rank(Ipv4.parse("224.0.0.1")!!))
        assertEquals(100, LocalAddresses.rank(Ipv4.parse("0.0.0.0")!!))
        assertEquals(40, LocalAddresses.rank(Ipv4.parse("169.254.1.1")!!))
    }

    @Test
    fun `rooms stay isolated and travel with the device`(@TempDir directory: Path) {
        val file = directory.resolve("rooms.json").toFile()
        val prefs = MemoryBytes()
        val store = RoomStore(prefs, file)
        assertEquals(MeshRoom.sanctuaries.map { it.id }, store.rooms.map { it.id })
        assertEquals(MeshRoom.DEFAULT_ID, store.selectedID)
        assertTrue(store.select("sanctuary-3"))
        assertEquals("Sanctuary 3", store.selected.name)
        assertTrue(store.rename("sanctuary-3", "  Main   Hall "))
        assertEquals("Main Hall", store.selected.name)
        val added = store.add("Chapel")
        assertNotNull(added)
        assertFalse(store.delete("sanctuary-1"))
        assertTrue(store.delete(added!!.id))
        assertFalse(store.rooms.any { it.id == added.id })

        val revived = RoomStore(prefs, file)
        assertEquals("sanctuary-3", revived.selectedID)
        assertEquals("Main Hall", revived.selected.name)
        assertFalse(revived.rooms.any { it.id == added.id })

        val older = AnnouncedRoom("sanctuary-3", "Old Name", 1)
        val chapel = AnnouncedRoom("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", "Chapel", 50)
        assertTrue(revived.merge(listOf(older, chapel)))
        assertTrue(revived.rooms.any { it.name == "Chapel" })
        assertEquals("Main Hall", revived.selected.name)
        val imported = revived.rooms.first { it.name == "Chapel" }
        assertTrue(revived.delete(imported.id))
        assertTrue(revived.merge(listOf(chapel)))
        assertTrue(revived.elsewhere.any { it.id == chapel.id })
        assertTrue(revived.restore(chapel.id))
        assertTrue(revived.rooms.any { it.id == chapel.id })

        assertTrue(RoomGate.same("Sanctuary-2", "sanctuary-2"))
        assertFalse(RoomGate.same("sanctuary-1", "sanctuary-2"))
        assertFalse(RoomGate.same("", "sanctuary-1"))

        val posted = RoomCatalogTXT.fields(revived.selected, revived.rooms)
        val heard = RoomCatalogTXT.announced(posted)
        assertTrue(heard.any { it.id == "sanctuary-3" && it.name == "Main Hall" })
        assertTrue(heard.any { it.name == "Chapel" })
    }

    @Test
    fun `two devices in one room exchange midi`() {
        val (left, right, leftAddress, rightAddress) = openEnds()
        val received = Received()
        left.onMIDI = { received.addReturn(it) }
        right.onMIDI = { received.add(it) }
        left.start()
        right.start()
        try {
            left.updateDiscovered(listOf(DiscoveredPeer(right.localUUID, "Mac B", rightAddress)))
            right.updateDiscovered(listOf(DiscoveredPeer(left.localUUID, "Mac A", leftAddress)))
            assertTrue(waitUntil(6.0) {
                left.snapshots().any { it.status == PeerSnapshot.Status.Connected } &&
                    right.snapshots().any { it.status == PeerSnapshot.Status.Connected }
            }, "handshake did not connect left=${left.debugSummary()} right=${right.debugSummary()}")
            val note = byteArrayOf(0x90.toByte(), 60, 100)
            val reply = byteArrayOf(0x80.toByte(), 60, 0)
            left.broadcast(note)
            right.broadcast(reply)
            assertTrue(waitUntil(2.0) { received.contains(note) && received.containsReturn(reply) })
            Thread.sleep(400)
            assertEquals(1, received.count(note))
        } finally {
            left.stop()
            right.stop()
        }
    }

    @Test
    fun `different rooms never share midi`() {
        val (left, right, leftAddress, rightAddress) = openEnds("sanctuary-1", "sanctuary-2")
        val received = Received()
        left.onMIDI = { received.addReturn(it) }
        right.onMIDI = { received.add(it) }
        left.start()
        right.start()
        try {
            left.setRoom("sanctuary-1")
            right.setRoom("sanctuary-2")
            left.updateDiscovered(listOf(DiscoveredPeer(right.localUUID, "Mac B", rightAddress)))
            right.updateDiscovered(listOf(DiscoveredPeer(left.localUUID, "Mac A", leftAddress)))
            val connected = waitUntil(2.5) {
                left.snapshots().any { it.isReachable } || right.snapshots().any { it.isReachable }
            }
            val note = byteArrayOf(0x90.toByte(), 70, 40)
            left.broadcast(note)
            right.broadcast(note)
            Thread.sleep(400)
            assertFalse(connected)
            assertFalse(received.contains(note) || received.containsReturn(note))
        } finally {
            left.stop()
            right.stop()
        }
    }

    @Test
    fun `changing rooms stops midi`() {
        val (left, right, leftAddress, rightAddress) = openEnds()
        val received = Received()
        right.onMIDI = { received.add(it) }
        left.start()
        right.start()
        try {
            left.updateDiscovered(listOf(DiscoveredPeer(right.localUUID, "Mac B", rightAddress)))
            right.updateDiscovered(listOf(DiscoveredPeer(left.localUUID, "Mac A", leftAddress)))
            assertTrue(waitUntil(6.0) {
                left.snapshots().any { it.isReachable } && right.snapshots().any { it.isReachable }
            }, "same room did not connect left=${left.debugSummary()} right=${right.debugSummary()}")
            right.setRoom("sanctuary-2")
            assertTrue(waitUntil(2.0) {
                left.snapshots().none { it.isReachable } && right.snapshots().none { it.isReachable }
            })
            val note = byteArrayOf(0x90.toByte(), 71, 40)
            left.broadcast(note)
            Thread.sleep(400)
            assertEquals(0, received.count(note))
        } finally {
            left.stop()
            right.stop()
        }
    }

    @Test
    fun `three devices form a mesh and deliver one copy`() {
        val trio = Trio()
        try {
            trio.a.updateDiscovered(listOf(
                DiscoveredPeer(trio.b.localUUID, "Mac B", trio.addressB),
                DiscoveredPeer(trio.c.localUUID, "Mac C", trio.addressC)
            ))
            trio.b.updateDiscovered(listOf(
                DiscoveredPeer(trio.a.localUUID, "Mac A", trio.addressA),
                DiscoveredPeer(trio.c.localUUID, "Mac C", trio.addressC)
            ))
            trio.c.updateDiscovered(listOf(
                DiscoveredPeer(trio.a.localUUID, "Mac A", trio.addressA),
                DiscoveredPeer(trio.b.localUUID, "Mac B", trio.addressB)
            ))
            assertTrue(waitUntil(10.0) { trio.connectedPairs }, trio.summary())
            val note = byteArrayOf(0x90.toByte(), 64, 100)
            trio.a.broadcast(note)
            assertTrue(waitUntil(2.0) { trio.receivedB.count(note) >= 1 && trio.receivedC.count(note) >= 1 })
            Thread.sleep(600)
            assertEquals(2, trio.receivedB.count(note) + trio.receivedC.count(note))
        } finally {
            trio.stop()
        }
    }

    @Test
    fun `a middle device relays midi across a missing link`() {
        val trio = Trio()
        try {
            trio.a.dialPeersLearnedFromNeighbors = false
            trio.b.dialPeersLearnedFromNeighbors = false
            trio.c.dialPeersLearnedFromNeighbors = false
            trio.a.updateDiscovered(listOf(DiscoveredPeer(trio.b.localUUID, "Mac B", trio.addressB)))
            trio.b.updateDiscovered(listOf(
                DiscoveredPeer(trio.a.localUUID, "Mac A", trio.addressA),
                DiscoveredPeer(trio.c.localUUID, "Mac C", trio.addressC)
            ))
            trio.c.updateDiscovered(listOf(DiscoveredPeer(trio.b.localUUID, "Mac B", trio.addressB)))
            assertTrue(waitUntil(6.0) {
                trio.a.snapshots().any { it.name == "Mac C" && it.status == PeerSnapshot.Status.Bridged } &&
                    trio.c.snapshots().any { it.name == "Mac A" && it.status == PeerSnapshot.Status.Bridged }
            }, trio.summary())
            val note = byteArrayOf(0x90.toByte(), 67, 90)
            trio.a.broadcast(note)
            assertTrue(waitUntil(2.0) { trio.receivedC.count(note) == 1 && trio.receivedB.count(note) == 1 })
            assertTrue(trio.a.snapshots().any { it.name == "Mac C" && it.status == PeerSnapshot.Status.Bridged })
        } finally {
            trio.stop()
        }
    }

    @Test
    fun `an unreachable first address recovers`() {
        val (left, right, leftAddress, rightAddress) = openEnds()
        val blackhole = UdpAddress.ipv4("192.0.2.9", rightAddress.port)!!
        left.start()
        right.start()
        try {
            left.updateDiscovered(listOf(
                DiscoveredPeer(right.localUUID, "Mac B", blackhole, listOf(blackhole, rightAddress))
            ))
            right.updateDiscovered(listOf(DiscoveredPeer(left.localUUID, "Mac A", leftAddress)))
            assertTrue(waitUntil(12.0) {
                left.snapshots().any { it.status == PeerSnapshot.Status.Connected } &&
                    right.snapshots().any { it.status == PeerSnapshot.Status.Connected }
            }, "left=${left.debugSummary()} right=${right.debugSummary()}")
        } finally {
            left.stop()
            right.stop()
        }
    }
}

private class MemoryBytes : BytesStore {
    private val values = mutableMapOf<String, ByteArray>()
    override fun read(key: String): ByteArray? = values[key]
    override fun write(key: String, data: ByteArray) { values[key] = data }
}

private class Received {
    private val inbound = mutableListOf<ByteArray>()
    private val returned = mutableListOf<ByteArray>()
    fun add(data: ByteArray) = synchronized(this) { inbound.add(data) }
    fun addReturn(data: ByteArray) = synchronized(this) { returned.add(data) }
    fun contains(data: ByteArray) = synchronized(this) { inbound.any { it.contentEquals(data) } }
    fun containsReturn(data: ByteArray) = synchronized(this) { returned.any { it.contentEquals(data) } }
    fun count(data: ByteArray) = synchronized(this) { inbound.count { it.contentEquals(data) } }
}

private data class Ends(
    val left: MidiSession,
    val right: MidiSession,
    val leftAddress: UdpAddress,
    val rightAddress: UdpAddress
)

private fun openEnds(leftRoom: String = MeshRoom.DEFAULT_ID, rightRoom: String = MeshRoom.DEFAULT_ID): Ends {
    val (leftControl, leftMidi) = openPair()
    val (rightControl, rightMidi) = openPair()
    val left = MidiSession("Mac A", "00000000-0000-0000-0000-000000000001", leftControl, leftMidi, leftRoom)
    val right = MidiSession("Mac B", "ffffffff-ffff-ffff-ffff-ffffffffffff", rightControl, rightMidi, rightRoom)
    return Ends(
        left,
        right,
        UdpAddress.ipv4("127.0.0.1", leftControl.port)!!,
        UdpAddress.ipv4("127.0.0.1", rightControl.port)!!
    )
}

private class Trio {
    val a: MidiSession
    val b: MidiSession
    val c: MidiSession
    val addressA: UdpAddress
    val addressB: UdpAddress
    val addressC: UdpAddress
    val receivedA = Received()
    val receivedB = Received()
    val receivedC = Received()

    init {
        val (aControl, aMidi) = openPair()
        val (bControl, bMidi) = openPair()
        val (cControl, cMidi) = openPair()
        a = MidiSession("Mac A", "00000000-0000-0000-0000-000000000001", aControl, aMidi)
        b = MidiSession("Mac B", "00000000-0000-0000-0000-000000000002", bControl, bMidi)
        c = MidiSession("Mac C", "ffffffff-ffff-ffff-ffff-ffffffffffff", cControl, cMidi)
        addressA = UdpAddress.ipv4("127.0.0.1", aControl.port)!!
        addressB = UdpAddress.ipv4("127.0.0.1", bControl.port)!!
        addressC = UdpAddress.ipv4("127.0.0.1", cControl.port)!!
        a.onMIDI = { receivedA.add(it) }
        b.onMIDI = { receivedB.add(it) }
        c.onMIDI = { receivedC.add(it) }
        a.start()
        b.start()
        c.start()
    }

    val connectedPairs: Boolean
        get() = a.snapshots().count { it.status == PeerSnapshot.Status.Connected } == 2 &&
            b.snapshots().count { it.status == PeerSnapshot.Status.Connected } == 2 &&
            c.snapshots().count { it.status == PeerSnapshot.Status.Connected } == 2

    fun summary(): String = "a=${a.debugSummary()} b=${b.debugSummary()} c=${c.debugSummary()}"

    fun stop() {
        a.stop()
        b.stop()
        c.stop()
    }
}

private fun openPair(): Pair<UdpSocket, UdpSocket> {
    repeat(30) {
        val control = try {
            UdpSocket(0)
        } catch (_: Exception) {
            return@repeat
        }
        try {
            return control to UdpSocket((control.port + 1) and 0xFFFF)
        } catch (_: Exception) {
            control.close()
        }
    }
    error("could not open ports")
}

private fun waitUntil(seconds: Double, condition: () -> Boolean): Boolean {
    val deadline = System.nanoTime() + (seconds * 1_000_000_000L).toLong()
    while (System.nanoTime() < deadline) {
        if (condition()) return true
        Thread.sleep(50)
    }
    return condition()
}

private fun ByteArray.hex(): String = joinToString("") { "%02X".format(it) }

private fun hex(text: String): ByteArray {
    val out = ByteArray(text.length / 2)
    for (index in out.indices) {
        out[index] = text.substring(index * 2, index * 2 + 2).toInt(16).toByte()
    }
    return out
}
