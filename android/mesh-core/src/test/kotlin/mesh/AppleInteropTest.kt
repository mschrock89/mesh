package mesh

import org.junit.jupiter.api.Assertions.assertTrue
import org.junit.jupiter.api.Test
import org.junit.jupiter.api.Timeout
import java.io.File
import java.util.concurrent.TimeUnit

class AppleInteropTest {
    @Test
    @Timeout(value = 40, unit = TimeUnit.SECONDS)
    fun `a kotlin session exchanges midi with the apple session`() {
        val root = repoRoot()
        val binary = root.resolve("android/mesh-core/build/mesh-peer")
        binary.parentFile.mkdirs()
        val compile = ProcessBuilder(
            "swiftc",
            "-parse-as-library",
            "-o", binary.absolutePath,
            root.resolve("android/interop/PeerMain.swift").absolutePath,
            root.resolve("Mesh/AppleMIDI.swift").absolutePath,
            root.resolve("Mesh/UDPSocket.swift").absolutePath,
            root.resolve("Mesh/Room.swift").absolutePath,
            root.resolve("Mesh/MIDISession.swift").absolutePath
        ).redirectErrorStream(true).start()
        val compileLog = compile.inputStream.readBytes().toString(Charsets.UTF_8)
        assertTrue(compile.waitFor() == 0, compileLog)

        val (control, midi) = openSessionPair()
        val kotlinUUID = "00000000-0000-0000-0000-00000000000a"
        val appleUUID = "ffffffff-ffff-ffff-ffff-ffffffffffff"
        val session = MidiSession("Tablet", kotlinUUID, control, midi)
        val received = mutableListOf<ByteArray>()
        session.onMIDI = { data -> synchronized(received) { received.add(data) } }
        session.start()

        val process = ProcessBuilder(binary.absolutePath, "Mac", appleUUID, "sanctuary-1")
            .redirectErrorStream(false)
            .start()
        val lines = mutableListOf<String>()
        val stdout = Thread {
            process.inputStream.bufferedReader().forEachLine { synchronized(lines) { lines.add(it) } }
        }.apply { isDaemon = true; start() }
        val stderr = StringBuilder()
        Thread {
            process.errorStream.bufferedReader().forEachLine { synchronized(stderr) { stderr.appendLine(it) } }
        }.apply { isDaemon = true; start() }
        val writer = process.outputStream.bufferedWriter()
        try {
            assertTrue(waitForLine(lines, "READY", 10_000) != null, "apple peer did not start ${dump(lines)} $stderr")
            val ready = synchronized(lines) { lines.first { it.startsWith("READY") } }
            val applePort = ready.removePrefix("READY ").trim().toInt()
            writer.write("PEER\t$kotlinUUID\tTablet\t127.0.0.1\t${control.port}")
            writer.newLine()
            writer.flush()
            session.updateDiscovered(listOf(
                DiscoveredPeer(appleUUID, "Mac", UdpAddress.ipv4("127.0.0.1", applePort)!!)
            ))
            assertTrue(waitUntilReady(8.0) {
                session.snapshots().any { it.status == PeerSnapshot.Status.Connected }
            }, "did not connect to the apple session ${session.debugSummary()} ${dump(lines)} $stderr")

            val note = byteArrayOf(0x90.toByte(), 60, 100)
            session.broadcast(note)
            assertTrue(waitForLine(lines, "MIDI 903C64", 3_000) != null, "apple peer did not hear the note ${dump(lines)}")

            writer.write("SEND\t803C00")
            writer.newLine()
            writer.flush()
            assertTrue(waitUntilReady(3.0) {
                synchronized(received) { received.any { it.contentEquals(byteArrayOf(0x80.toByte(), 60, 0)) } }
            }, "kotlin peer did not hear the apple note")
        } finally {
            try {
                writer.write("QUIT")
                writer.newLine()
                writer.flush()
            } catch (_: Exception) {
            }
            writer.close()
            session.stop()
            process.destroy()
        }
    }
}

private fun repoRoot(): File {
    var dir = File("").absoluteFile
    while (true) {
        if (dir.resolve("Mesh/AppleMIDI.swift").exists() && dir.resolve("android/interop/PeerMain.swift").exists()) {
            return dir
        }
        dir = dir.parentFile ?: error("repo root not found from ${File("").absolutePath}")
    }
}

private fun openSessionPair(): Pair<UdpSocket, UdpSocket> {
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

private fun waitUntilReady(seconds: Double, condition: () -> Boolean): Boolean {
    val deadline = System.nanoTime() + (seconds * 1_000_000_000L).toLong()
    while (System.nanoTime() < deadline) {
        if (condition()) return true
        Thread.sleep(50)
    }
    return condition()
}

private fun waitForLine(lines: MutableList<String>, prefix: String, timeoutMs: Long): String? {
    val deadline = System.currentTimeMillis() + timeoutMs
    while (System.currentTimeMillis() < deadline) {
        val found = synchronized(lines) { lines.firstOrNull { it.startsWith(prefix) } }
        if (found != null) return found
        Thread.sleep(50)
    }
    return synchronized(lines) { lines.firstOrNull { it.startsWith(prefix) } }
}

private fun dump(lines: MutableList<String>): String = synchronized(lines) { lines.joinToString(" | ") }
