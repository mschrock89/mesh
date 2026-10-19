package com.mitchellschrock.mesh

import mesh.AnnouncedRoom
import mesh.DiscoveredPeer
import mesh.Ipv4
import mesh.LocalAddresses
import mesh.MeshRoom
import mesh.RoomCatalogTXT
import mesh.UdpAddress
import java.net.Inet4Address
import java.net.InetAddress
import java.net.NetworkInterface
import java.util.concurrent.Executors
import javax.jmdns.JmDNS
import javax.jmdns.ServiceEvent
import javax.jmdns.ServiceInfo
import javax.jmdns.ServiceListener

/**
 * Publishes and browses the same Bonjour service the Apple app uses: `_mesh-midi._udp`.
 */
class MeshDiscovery(
    private val localUUID: String,
    private val localPort: Int,
    private val localName: String,
    private val onPeers: (List<DiscoveredPeer>) -> Unit,
    private val onRooms: (List<AnnouncedRoom>) -> Unit
) {
    private val io = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "mesh-mdns").apply { isDaemon = true }
    }
    private val lock = Any()
    private val browsers = mutableListOf<JmDNS>()
    private val resolved = linkedMapOf<String, ResolvedService>()
    private var roomID = MeshRoom.DEFAULT_ID
    private var selected = MeshRoom.sanctuaries[0]
    private var catalog = MeshRoom.sanctuaries
    private var instanceName = serviceName(localName)

    private val listener = object : ServiceListener {
        override fun serviceAdded(event: ServiceEvent) {
            try {
                event.getDNS().requestServiceInfo(event.type, event.name, true)
            } catch (_: Exception) {
            }
        }

        override fun serviceRemoved(event: ServiceEvent) {
            synchronized(lock) { resolved.remove(event.name) }
            emit()
        }

        override fun serviceResolved(event: ServiceEvent) {
            val info = event.info ?: return
            remember(event.name, info)
        }
    }

    fun start(selected: MeshRoom, catalog: List<MeshRoom>) {
        io.execute {
            this.selected = selected
            this.catalog = catalog
            roomID = selected.id
            reopen()
        }
    }

    fun update(selected: MeshRoom, catalog: List<MeshRoom>) {
        io.execute {
            val same = this.selected == selected && this.catalog == catalog
            this.selected = selected
            this.catalog = catalog
            if (!same) reregister()
        }
    }

    fun setRoom(id: String) {
        io.execute {
            roomID = MeshRoom.cleanedID(id) ?: MeshRoom.DEFAULT_ID
            emit()
        }
    }

    fun restart() {
        io.execute { reopen() }
    }

    fun stop() {
        io.execute { closeAll() }
        io.shutdown()
    }

    private fun reopen() {
        closeAll()
        synchronized(lock) { resolved.clear() }
        emit()
        val addresses = eligible()
        for (address in addresses) {
            try {
                val dns = JmDNS.create(address, hostName(address))
                dns.addServiceListener(TYPE, listener)
                register(dns)
                browsers.add(dns)
            } catch (error: Exception) {
                android.util.Log.e("Mesh", "mDNS failed on ${address.hostAddress}", error)
            }
        }
    }

    private fun reregister() {
        for (dns in browsers) {
            try {
                dns.unregisterAllServices()
                register(dns)
            } catch (error: Exception) {
                android.util.Log.e("Mesh", "Could not update the Mesh service", error)
            }
        }
    }

    private fun register(dns: JmDNS) {
        val props = HashMap<String, String>(RoomCatalogTXT.fields(selected, catalog))
        props["id"] = localUUID
        try {
            dns.registerService(serviceInfo(instanceName, props))
        } catch (_: Exception) {
            instanceName = serviceName("$localName ${localUUID.take(4)}")
            dns.registerService(serviceInfo(instanceName, props))
        }
    }

    private fun serviceInfo(name: String, props: Map<String, String>): ServiceInfo {
        return ServiceInfo.create(TYPE, name, localPort, 0, 0, props)
    }

    private fun closeAll() {
        for (dns in browsers) {
            try {
                dns.unregisterAllServices()
            } catch (_: Exception) {
            }
            try {
                dns.close()
            } catch (_: Exception) {
            }
        }
        browsers.clear()
    }

    private fun remember(name: String, info: ServiceInfo) {
        val fields = txt(info)
        val uuid = fields["id"]?.lowercase().orEmpty()
        if (uuid.isNotEmpty() && uuid == localUUID) return
        val room = MeshRoom.cleanedID(fields["room"] ?: "") ?: ""
        if (room.isEmpty()) {
            synchronized(lock) { resolved.remove(name) }
            emit()
            return
        }
        val addresses = addresses(info)
        if (addresses.isEmpty()) return
        if (addresses.all { it.port == localPort && it.ip in LocalAddresses.ipv4() }) return
        val peer = DiscoveredPeer(uuid, name, addresses.first(), addresses)
        synchronized(lock) {
            resolved[name] = ResolvedService(peer, room, RoomCatalogTXT.announced(fields))
        }
        emit()
    }

    private fun emit() {
        val peers: List<DiscoveredPeer>
        val rooms: List<AnnouncedRoom>
        synchronized(lock) {
            val grouped = linkedMapOf<String, MutableList<ResolvedService>>()
            for (item in resolved.values) {
                if (item.roomID != roomID) continue
                val key = item.peer.uuid.ifEmpty { item.peer.name }
                grouped.getOrPut(key) { mutableListOf() }.add(item)
            }
            peers = grouped.values.map { group ->
                val addresses = group.flatMap { it.peer.addresses }
                    .distinct()
                    .sortedBy { LocalAddresses.rank(it.ip) }
                val sample = group.first().peer
                DiscoveredPeer(sample.uuid, sample.name, addresses.first(), addresses)
            }
            val best = linkedMapOf<String, AnnouncedRoom>()
            for (item in resolved.values) {
                for (announced in item.announced) {
                    if (announced.name.isEmpty()) continue
                    val existing = best[announced.id]
                    if (existing != null && existing.revision >= announced.revision) continue
                    best[announced.id] = announced
                }
            }
            rooms = best.values.toList()
        }
        onPeers(peers)
        onRooms(rooms)
    }

    private fun addresses(info: ServiceInfo): List<UdpAddress> {
        if (info.port <= 0) return emptyList()
        val found = mutableListOf<UdpAddress>()
        val listed = info.inet4Addresses?.toList().orEmpty()
        for (address in listed) {
            val ip = Ipv4.fromNetworkBytes(address.address)
            if (LocalAddresses.rank(ip) >= 100) continue
            val udp = UdpAddress(ip, info.port)
            if (udp !in found) found.add(udp)
        }
        return found.sortedBy { LocalAddresses.rank(it.ip) }
    }

    private fun txt(info: ServiceInfo): Map<String, String> {
        val fields = linkedMapOf<String, String>()
        val names = info.propertyNames ?: return fields
        while (names.hasMoreElements()) {
            val key = names.nextElement()?.toString() ?: continue
            val value = info.getPropertyString(key) ?: continue
            fields[key] = value
        }
        return fields
    }

    private fun eligible(): List<InetAddress> {
        val found = mutableListOf<InetAddress>()
        val interfaces = try {
            NetworkInterface.getNetworkInterfaces()?.toList().orEmpty()
        } catch (_: Exception) {
            emptyList()
        }
        for (nif in interfaces) {
            try {
                if (!nif.isUp || nif.isLoopback) continue
            } catch (_: Exception) {
                continue
            }
            for (address in nif.inetAddresses.asSequence()) {
                if (address !is Inet4Address) continue
                val ip = Ipv4.fromNetworkBytes(address.address)
                if (LocalAddresses.rank(ip) >= 100) continue
                found.add(address)
            }
        }
        return found.sortedBy { LocalAddresses.rank(Ipv4.fromNetworkBytes(it.address)) }
    }

    private fun hostName(address: InetAddress): String {
        val tail = address.hostAddress?.substringAfterLast('.') ?: "0"
        return "mesh-${localUUID.take(8)}-$tail"
    }

    private fun serviceName(raw: String): String {
        val trimmed = raw.trim().ifEmpty { "Mesh" }
        val bytes = trimmed.toByteArray(Charsets.UTF_8)
        if (bytes.size <= 63) return trimmed
        return String(bytes.copyOf(63), Charsets.UTF_8).trim().ifEmpty { "Mesh" }
    }

    private class ResolvedService(
        val peer: DiscoveredPeer,
        val roomID: String,
        val announced: List<AnnouncedRoom>
    )

    companion object {
        const val TYPE = "_mesh-midi._udp.local."
    }
}
