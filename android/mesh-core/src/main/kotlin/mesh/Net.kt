package mesh

import java.net.BindException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.NetworkInterface
import java.net.SocketException
import java.util.concurrent.atomic.AtomicBoolean

/** IPv4 address stored in network byte order. */
@JvmInline
value class Ipv4(val bits: UInt) {
    val octet0: Int get() = ((bits shr 24) and 255u).toInt()
    val octet1: Int get() = ((bits shr 16) and 255u).toInt()

    val text: String
        get() = "$octet0.$octet1.${((bits shr 8) and 255u).toInt()}.${(bits and 255u).toInt()}"

    fun networkBytes(): ByteArray = byteArrayOf(
        octet0.toByte(),
        octet1.toByte(),
        ((bits shr 8) and 255u).toByte(),
        (bits and 255u).toByte()
    )

    companion object {
        fun fromNetworkBytes(raw: ByteArray): Ipv4 {
            require(raw.size == 4)
            val bits = ((raw[0].toUInt() and 255u) shl 24) or
                ((raw[1].toUInt() and 255u) shl 16) or
                ((raw[2].toUInt() and 255u) shl 8) or
                (raw[3].toUInt() and 255u)
            return Ipv4(bits)
        }

        fun parse(text: String): Ipv4? {
            val parts = text.split('.')
            if (parts.size != 4) return null
            var bits = 0u
            for (part in parts) {
                val value = part.toIntOrNull() ?: return null
                if (value !in 0..255) return null
                bits = (bits shl 8) or value.toUInt()
            }
            return Ipv4(bits)
        }
    }
}

data class UdpAddress(val ip: Ipv4, val port: Int) {
    val key: String get() = "${ip.text}:${port and 0xFFFF}"

    fun withPort(port: Int): UdpAddress = UdpAddress(ip, port and 0xFFFF)

    companion object {
        fun ipv4(text: String, port: Int): UdpAddress? {
            val ip = Ipv4.parse(text) ?: return null
            return UdpAddress(ip, port and 0xFFFF)
        }
    }
}

object LocalAddresses {
    fun ipv4(): Set<Ipv4> {
        val found = mutableSetOf<Ipv4>()
        for (nif in interfaces()) {
            for (address in nif.inetAddresses.asSequence()) {
                if (address is Inet4Address) found.add(Ipv4.fromNetworkBytes(address.address))
            }
        }
        return found
    }

    /** Lower is better. Loopback and multicast are unusable for a peer. */
    fun rank(ip: Ipv4): Int {
        val first = ip.octet0
        if (ip.bits == 0u || first == 127 || first >= 224) return 100
        val linkLocal = first == 169 && ip.octet1 == 254
        if (sharesSubnet(ip) && !linkLocal) return 0
        if (linkLocal) return 40
        return 20
    }

    private fun sharesSubnet(ip: Ipv4): Boolean {
        for (nif in interfaces()) {
            for (ia in nif.interfaceAddresses) {
                val address = ia.address
                if (address !is Inet4Address) continue
                val prefix = ia.networkPrefixLength.toInt()
                if (prefix <= 0) continue
                val mask = if (prefix >= 32) 0xFFFFFFFFu else (0xFFFFFFFFu shl (32 - prefix))
                val local = Ipv4.fromNetworkBytes(address.address).bits
                if ((ip.bits and mask) == (local and mask)) return true
            }
        }
        return false
    }

    private fun interfaces(): List<NetworkInterface> = try {
        NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
    } catch (_: Exception) {
        emptyList()
    }
}

class UdpSocket(port: Int) {
    private val socket: DatagramSocket
    val port: Int
    @Volatile var onPacket: ((ByteArray, UdpAddress) -> Unit)? = null

    private val closed = AtomicBoolean(false)

    init {
        val opened = DatagramSocket(null)
        try {
            opened.reuseAddress = false
            opened.bind(InetSocketAddress(InetAddress.getByName("0.0.0.0"), port))
        } catch (error: Exception) {
            opened.close()
            throw error
        }
        socket = opened
        this.port = opened.localPort
        Thread({ drain() }, "mesh-udp-${this.port}").apply {
            isDaemon = true
            start()
        }
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return
        socket.close()
    }

    fun send(data: ByteArray, to: UdpAddress) {
        if (closed.get()) return
        val packet = DatagramPacket(
            data,
            data.size,
            InetAddress.getByAddress(to.ip.networkBytes()),
            to.port and 0xFFFF
        )
        try {
            socket.send(packet)
        } catch (_: Exception) {
        }
    }

    private fun drain() {
        val buffer = ByteArray(4096)
        val packet = DatagramPacket(buffer, buffer.size)
        while (!closed.get()) {
            try {
                packet.length = buffer.size
                socket.receive(packet)
                val address = packet.address
                if (address !is Inet4Address) continue
                val data = packet.data.copyOfRange(packet.offset, packet.offset + packet.length)
                val from = UdpAddress(Ipv4.fromNetworkBytes(address.address), packet.port)
                onPacket?.invoke(data, from)
            } catch (_: SocketException) {
                if (closed.get()) return
            } catch (_: Exception) {
                if (closed.get()) return
            }
        }
    }

    companion object {
        fun bindPair(start: Int = 5004): Pair<UdpSocket, UdpSocket> {
            var port = start
            val limit = start + 400
            while (port < limit) {
                val control = try {
                    UdpSocket(port)
                } catch (_: Exception) {
                    port += 1
                    continue
                }
                try {
                    val midi = UdpSocket((port + 1) and 0xFFFF)
                    return control to midi
                } catch (_: Exception) {
                    control.close()
                }
                port += 1
            }
            throw BindException("Mesh couldn't open a network port.")
        }
    }
}
