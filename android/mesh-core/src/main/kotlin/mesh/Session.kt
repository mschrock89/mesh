package mesh

import java.util.ArrayDeque
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.locks.ReentrantLock
import kotlin.concurrent.withLock
import kotlin.random.Random
import kotlin.random.nextUInt

data class DiscoveredPeer(
    val uuid: String,
    val name: String,
    val address: UdpAddress,
    val addresses: List<UdpAddress> = emptyList()
)

data class PeerSnapshot(
    val id: String,
    val name: String,
    val status: Status,
    val via: String?
) {
    enum class Status {
        Waiting,
        Connecting,
        Connected,
        Bridged
    }

    val isReachable: Boolean get() = status == Status.Connected || status == Status.Bridged
}

/**
 * One Apple network MIDI session per remote device.
 * The device with the lower id sends the invitation first. Local MIDI goes to
 * every directly connected device and is relayed onward, so a device that can
 * see the other two still joins them when their own path does not come up.
 */
class MidiSession(
    val localName: String,
    localUUID: String,
    val control: UdpSocket,
    val midi: UdpSocket,
    roomID: String = MeshRoom.DEFAULT_ID
) {
    val localUUID: String = localUUID.lowercase()
    val ssrc: UInt = randomUInt()
    var onMIDI: ((ByteArray) -> Unit)? = null
    var onChange: ((List<PeerSnapshot>) -> Unit)? = null

    /** Tests can turn this off to prove MIDI still crosses a missing edge. */
    var dialPeersLearnedFromNeighbors: Boolean = true

    private val queue = SerialQueue("mesh.session.$localUUID")
    private val links = LinkedHashMap<String, Link>()
    private var suspended = false
    private var stopped = false
    private var lastSnapshot: List<PeerSnapshot> = emptyList()
    private var nextEvent: UInt = 1u
    private val seenEvents = ArrayDeque<ULong>()
    private var lastMidiAt = 0L
    private var lastDirectory = 0L
    private var roomID: String = MeshRoom.cleanedID(roomID) ?: MeshRoom.DEFAULT_ID
    private val timer = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "mesh.session.timer").apply { isDaemon = true }
    }

    fun start() {
        control.onPacket = { data, address ->
            queue.async { ingest(data, address, midiPort = false) }
        }
        midi.onPacket = { data, address ->
            queue.async { ingest(data, address, midiPort = true) }
        }
        timer.scheduleAtFixedRate({
            try {
                queue.async { tick() }
            } catch (_: RejectedExecutionException) {
            }
        }, 200, 250, TimeUnit.MILLISECONDS)
    }

    fun stop() {
        timer.shutdownNow()
        try {
            queue.sync {
                stopped = true
                for (link in links.values.toList()) {
                    if (link.phase == Phase.Connected) sendExit(link)
                }
            }
        } catch (_: RejectedExecutionException) {
        }
        control.close()
        midi.close()
        queue.shutdown()
    }

    fun updateDiscovered(found: List<DiscoveredPeer>) {
        queue.async {
            val seen = mutableSetOf<String>()
            for (item in found) {
                val uuid = item.uuid.lowercase()
                if (uuid.isNotEmpty() && uuid == localUUID) continue
                val candidates = item.addresses.ifEmpty { listOf(item.address) }
                val key = links.entries.firstOrNull { it.value.uuid == uuid && uuid.isNotEmpty() }?.key
                    ?: item.address.key
                seen.add(key)
                val current = links[key]
                if (current != null) {
                    val learnedIdentity = current.uuid.isEmpty() && uuid.isNotEmpty()
                    if (uuid.isNotEmpty()) current.uuid = uuid
                    current.name = item.name
                    current.candidates = candidates.toMutableList()
                    current.missingSince = null
                    if (current.phase != Phase.Connected && current.address !in candidates) {
                        current.address = item.address
                    }
                    if (learnedIdentity && current.phase != Phase.Connected && !current.controlAccepted && !current.midiAccepted) {
                        current.weInitiate = initiates(uuid, item.name)
                    }
                    store(current, key)
                    seen.remove(key)
                    seen.add(current.address.key)
                } else {
                    val link = Link.make(item, uuid, initiates(uuid, item.name))
                    link.candidates = candidates.toMutableList()
                    links[link.address.key] = link
                    seen.add(link.address.key)
                }
            }
            val now = System.currentTimeMillis()
            for (key in links.keys.toList()) {
                if (key in seen) continue
                val link = links[key] ?: continue
                if (link.via != null || link.phase == Phase.Connected) continue
                if (link.missingSince == null) link.missingSince = now
            }
            publish()
        }
    }

    fun broadcast(midiData: ByteArray) {
        if (midiData.isEmpty()) return
        queue.async {
            val now = System.currentTimeMillis()
            // The first cue after a quiet stretch is the datagram a sleeping
            // radio drops. Send that one again with the same event id so the
            // other side plays it once.
            val opening = now - lastMidiAt >= 1_000L
            lastMidiAt = now
            val event = nextEvent
            nextEvent += 1u
            if (nextEvent == 0u) nextEvent = 1u
            remember(ssrc, event)
            sendMidi(midiData, event)
            if (!opening) return@async
            val copy = midiData.copyOf()
            try {
                timer.schedule({
                    try {
                        queue.async { sendMidi(copy, event) }
                    } catch (_: RejectedExecutionException) {
                    }
                }, 30, TimeUnit.MILLISECONDS)
            } catch (_: RejectedExecutionException) {
            }
        }
    }

    private fun sendMidi(midiData: ByteArray, event: UInt) {
        for (key in links.keys.toList()) {
            val link = links[key] ?: continue
            if (link.phase != Phase.Connected) continue
            link.sequence = (link.sequence + 1) and 0xFFFF
            val packet = AppleMidi.encodeMidi(link.sequence, event, ssrc, midiData)
            midi.send(packet, link.address.withPort((link.address.port + 1) and 0xFFFF))
        }
    }

    fun setRoom(roomID: String) {
        queue.async {
            val cleaned = MeshRoom.cleanedID(roomID) ?: MeshRoom.DEFAULT_ID
            if (this.roomID == cleaned) return@async
            this.roomID = cleaned
            for (link in links.values.toList()) {
                if (link.phase == Phase.Connected) sendExit(link)
            }
            links.clear()
            publish()
        }
    }

    fun reconnect() {
        queue.async {
            suspended = false
            for (link in links.values.toList()) {
                if (link.phase == Phase.Connected) sendExit(link)
                reset(link)
            }
            publish()
        }
    }

    fun suspend() {
        queue.async {
            suspended = true
            for (link in links.values.toList()) {
                if (link.phase == Phase.Connected) sendExit(link)
                reset(link)
            }
            publish()
        }
    }

    fun resume() {
        reconnect()
    }

    fun snapshots(): List<PeerSnapshot> = queue.sync { makeSnapshots() }

    fun debugSummary(): String {
        val body = queue.sync {
            links.values.map { link ->
                "${link.name} ${link.address.key} initiate=${link.weInitiate} phase=${link.phase} attempts=${link.attempts}"
            }.sorted().joinToString(" | ")
        }
        return body.ifEmpty { "no peers" }
    }

    private fun initiates(uuid: String, name: String): Boolean {
        if (uuid.isEmpty()) return false
        if (localUUID != uuid) return localUUID < uuid
        return localName.compareTo(name, ignoreCase = true) < 0
    }

    private fun tick() {
        if (suspended || stopped) return
        val now = System.currentTimeMillis()
        val remove = mutableListOf<String>()
        for (key in links.keys.toList()) {
            val link = links[key] ?: continue
            val missing = link.missingSince
            if (missing != null && now - missing > 10_000) {
                if (link.phase == Phase.Connected) sendExit(link)
                remove.add(key)
                continue
            }
            val viaSeen = link.viaSeen
            if (viaSeen != null && now - viaSeen > 4_000) {
                link.via = null
                link.viaSeen = null
                if (link.phase != Phase.Connected && link.missingSince == null) link.missingSince = now
            }
            val rotated = rotate(link)
            if (rotated != null) {
                links.remove(key)
                if (links[rotated] == null) links[rotated] = link
                continue
            }
            service(link, now)
            links[key] = link
        }
        for (key in remove) links.remove(key)
        sendDirectories(now)
        publish()
    }

    private fun rotate(link: Link): String? {
        if (!(link.weInitiate && (link.phase == Phase.InvitingControl || link.phase == Phase.Idle))) return null
        if (link.attempts < 4 || link.candidates.size <= 1) return null
        val current = link.candidates.indexOf(link.address).let { if (it < 0) 0 else it }
        val next = link.candidates[(current + 1) % link.candidates.size]
        if (next == link.address) return null
        reset(link)
        link.address = next
        return next.key
    }

    private fun service(link: Link, now: Long) {
        if (link.phase == Phase.Connected) {
            if (now - link.lastHeard > 25_000) {
                sendExit(link)
                reset(link)
                return
            }
            if (!link.weInitiate) return
            val interval = if (link.syncsCompleted < 3) 400L else 10_000L
            if (now - link.lastSync >= interval) {
                sendSync(link, 0, AppleMidiClock.now(), 0, 0)
                link.lastSync = now
            }
            return
        }

        val learnedFromNeighbor = link.via != null && !dialPeersLearnedFromNeighbors
        if (!link.weInitiate && !learnedFromNeighbor && !link.controlAccepted && !link.midiAccepted) {
            if (now - link.opened >= 2_500) link.weInitiate = true
        }
        if (!link.weInitiate || learnedFromNeighbor) {
            if ((link.controlAccepted || link.midiAccepted) && now - link.lastHeard > 25_000) reset(link)
            return
        }
        if (link.attempts >= 12) {
            if (now - link.lastInvite >= 3_000) {
                link.attempts = 0
                link.phase = Phase.Idle
                link.token = 0u
            }
            return
        }
        if (link.phase == Phase.InvitingMidi) {
            if (now - link.lastInvite >= 1_000) {
                sendInvitation(link, midiPort = true)
                link.attempts += 1
                link.lastInvite = now
            }
            return
        }
        if (link.phase == Phase.Idle) {
            link.token = randomUInt()
            link.phase = Phase.InvitingControl
        }
        if (link.attempts == 0 || now - link.lastInvite >= 1_000) {
            sendInvitation(link, midiPort = false)
            link.attempts += 1
            link.lastInvite = now
        }
    }

    private fun ingest(data: ByteArray, from: UdpAddress, midiPort: Boolean) {
        if (stopped || isOwn(from)) return
        val packet = AppleMidi.decode(data) ?: return
        when (packet) {
            is AppleMidi.Packet.ExchangePacket -> when (packet.message.command) {
                AppleMidi.Command.Invitation -> handleInvitation(packet.message, from, midiPort)
                AppleMidi.Command.Accepted -> handleAccepted(packet.message, from, midiPort)
                AppleMidi.Command.Exit -> handleExit(from, midiPort)
                else -> {}
            }
            is AppleMidi.Packet.SyncPacket -> if (midiPort) handleSync(packet.message, from)
            is AppleMidi.Packet.Midi -> if (midiPort) handleMIDI(packet.payload, from)
            is AppleMidi.Packet.Feedback -> touch(from, midiPort)
            is AppleMidi.Packet.Directory -> if (!midiPort) handleDirectory(packet.peers, from)
        }
    }

    private fun handleInvitation(message: AppleMidi.Exchange, from: UdpAddress, midiPort: Boolean) {
        if (!RoomGate.same(message.room, roomID)) {
            refuse(message, from, midiPort)
            return
        }
        val controlAddress = if (midiPort) from.withPort((from.port - 1) and 0xFFFF) else from
        val key = controlAddress.key
        val link = links[key] ?: Link.incoming(controlAddress, message.name)
        link.lastHeard = System.currentTimeMillis()
        link.missingSince = null
        if (message.name.isNotEmpty()) link.name = message.name
        val ourInviteIsWinning = link.weInitiate &&
            link.phase == Phase.InvitingControl &&
            link.token != 0u &&
            message.token > link.token &&
            link.attempts < 6
        if (ourInviteIsWinning) {
            links[key] = link
            return
        }
        link.weInitiate = false
        val reply = AppleMidi.encodeExchange(
            AppleMidi.Exchange(AppleMidi.Command.Accepted, message.token, ssrc, localName, roomID)
        )
        if (midiPort) {
            midi.send(reply, from)
            link.midiAccepted = true
        } else {
            control.send(reply, from)
            link.controlAccepted = true
        }
        if (link.controlAccepted && link.midiAccepted) becomeConnected(link)
        links[key] = link
        publish()
    }

    private fun handleAccepted(message: AppleMidi.Exchange, from: UdpAddress, midiPort: Boolean) {
        if (!RoomGate.same(message.room, roomID)) return
        val controlAddress = if (midiPort) from.withPort((from.port - 1) and 0xFFFF) else from
        val link = links[controlAddress.key] ?: return
        if (!link.weInitiate || message.token != link.token) return
        link.lastHeard = System.currentTimeMillis()
        if (!midiPort && link.phase == Phase.InvitingControl) {
            link.phase = Phase.InvitingMidi
            link.attempts = 0
            link.lastInvite = System.currentTimeMillis()
            sendInvitation(link, midiPort = true)
        } else if (midiPort && link.phase == Phase.InvitingMidi) {
            becomeConnected(link)
            sendSync(link, 0, AppleMidiClock.now(), 0, 0)
            link.lastSync = System.currentTimeMillis()
        }
        links[controlAddress.key] = link
        publish()
    }

    private fun handleSync(sync: AppleMidi.Sync, from: UdpAddress) {
        val key = from.withPort((from.port - 1) and 0xFFFF).key
        val link = links[key] ?: return
        link.lastHeard = System.currentTimeMillis()
        val now = AppleMidiClock.now()
        when (sync.count) {
            0 -> sendSync(link, 1, sync.timestamp1, now, 0)
            1 -> {
                sendSync(link, 2, sync.timestamp1, sync.timestamp2, now)
                link.syncsCompleted += 1
            }
            2 -> link.syncsCompleted += 1
        }
        links[key] = link
    }

    private fun handleMIDI(payload: AppleMidi.MidiPayload, from: UdpAddress) {
        val key = from.withPort((from.port - 1) and 0xFFFF).key
        val link = links[key] ?: return
        if (link.phase != Phase.Connected) return
        link.lastHeard = System.currentTimeMillis()
        if (payload.ssrc == ssrc || payload.midi.isEmpty()) return
        if (!remember(payload.ssrc, payload.timestamp)) return
        onMIDI?.invoke(payload.midi)
        for (other in links.keys.toList()) {
            if (other == key) continue
            val hop = links[other] ?: continue
            if (hop.phase != Phase.Connected) continue
            hop.sequence = (hop.sequence + 1) and 0xFFFF
            val packet = AppleMidi.encodeMidi(hop.sequence, payload.timestamp, payload.ssrc, payload.midi)
            midi.send(packet, hop.address.withPort((hop.address.port + 1) and 0xFFFF))
        }
    }

    private fun handleDirectory(entries: List<AppleMidi.DirectoryEntry>, from: UdpAddress) {
        val relay = links[from.key] ?: return
        if (relay.phase != Phase.Connected) return
        val relayName = relay.name.ifEmpty { "another Mac" }
        val now = System.currentTimeMillis()
        for (entry in entries) {
            val uuid = entry.uuid.lowercase()
            if (uuid.isEmpty() || uuid == localUUID) continue
            val peerAddress = UdpAddress(entry.ip, entry.port)
            if (isOwn(peerAddress)) continue
            if (links.values.any { it.uuid == uuid && it.phase == Phase.Connected }) continue
            val existing = links.entries.firstOrNull { it.value.uuid == uuid }
            if (existing != null) {
                existing.value.via = relayName
                existing.value.viaSeen = now
                existing.value.missingSince = null
                if (existing.value.name.isEmpty()) existing.value.name = entry.name
                continue
            }
            val link = links[peerAddress.key] ?: Link.make(
                DiscoveredPeer(uuid, entry.name, peerAddress),
                uuid,
                dialPeersLearnedFromNeighbors && initiates(uuid, entry.name)
            )
            if (link.uuid.isEmpty()) link.uuid = uuid
            if (link.name.isEmpty()) link.name = entry.name
            if (link.phase != Phase.Connected) {
                link.via = relayName
                link.viaSeen = now
                link.missingSince = null
            }
            links[peerAddress.key] = link
        }
        publish()
    }

    private fun handleExit(from: UdpAddress, midiPort: Boolean) {
        val controlAddress = if (midiPort) from.withPort((from.port - 1) and 0xFFFF) else from
        val link = links[controlAddress.key] ?: return
        reset(link)
        links[controlAddress.key] = link
        publish()
    }

    private fun touch(address: UdpAddress, midiPort: Boolean) {
        val controlAddress = if (midiPort) address.withPort((address.port - 1) and 0xFFFF) else address
        links[controlAddress.key]?.lastHeard = System.currentTimeMillis()
    }

    private fun becomeConnected(link: Link) {
        if (link.phase == Phase.Connected) return
        link.phase = Phase.Connected
        link.lastHeard = System.currentTimeMillis()
        link.via = null
        link.viaSeen = null
        if (link.uuid.isEmpty()) {
            val donor = links.values.firstOrNull { it.name == link.name && it.uuid.isNotEmpty() && it.name.isNotEmpty() }
            if (donor != null) link.uuid = donor.uuid
        }
        val key = link.address.key
        if (link.uuid.isNotEmpty()) {
            for (other in links.keys.toList()) {
                if (other != key && links[other]?.uuid == link.uuid) links.remove(other)
            }
        }
        if (link.name.isNotEmpty()) {
            for (other in links.keys.toList()) {
                if (other != key && links[other]?.name == link.name && links[other]?.phase != Phase.Connected) {
                    links.remove(other)
                }
            }
        }
        println("Mesh connected to ${link.name}")
    }

    private fun remember(ssrc: UInt, event: UInt): Boolean {
        val key = (ssrc.toULong() shl 32) or event.toULong()
        if (seenEvents.contains(key)) return false
        seenEvents.addLast(key)
        while (seenEvents.size > 256) seenEvents.removeFirst()
        return true
    }

    private fun sendDirectories(now: Long) {
        if (now - lastDirectory < 500) return
        val connected = links.values.filter { it.phase == Phase.Connected && it.uuid.isNotEmpty() }
        if (connected.isEmpty()) return
        lastDirectory = now
        val entries = connected.map {
            AppleMidi.DirectoryEntry(it.address.ip, it.address.port, it.uuid, it.name)
        }
        val packet = AppleMidi.encodeDirectory(ssrc, entries)
        for (link in connected) control.send(packet, link.address)
    }

    private fun store(link: Link, replacing: String) {
        links.remove(replacing)
        links[link.address.key] = link
    }

    private fun sendInvitation(link: Link, midiPort: Boolean) {
        val packet = AppleMidi.encodeExchange(
            AppleMidi.Exchange(AppleMidi.Command.Invitation, link.token, ssrc, localName, roomID)
        )
        if (midiPort) {
            midi.send(packet, link.address.withPort((link.address.port + 1) and 0xFFFF))
        } else {
            control.send(packet, link.address)
        }
    }

    private fun sendSync(link: Link, count: Int, t1: Long, t2: Long, t3: Long) {
        val packet = AppleMidi.encodeSync(AppleMidi.Sync(ssrc, count, t1, t2, t3))
        midi.send(packet, link.address.withPort((link.address.port + 1) and 0xFFFF))
    }

    private fun refuse(message: AppleMidi.Exchange, from: UdpAddress, midiPort: Boolean) {
        val reply = AppleMidi.encodeExchange(
            AppleMidi.Exchange(AppleMidi.Command.Rejected, message.token, ssrc, "")
        )
        if (midiPort) midi.send(reply, from) else control.send(reply, from)
    }

    private fun sendExit(link: Link) {
        val packet = AppleMidi.encodeExchange(
            AppleMidi.Exchange(AppleMidi.Command.Exit, link.token, ssrc, "")
        )
        control.send(packet, link.address)
        midi.send(packet, link.address.withPort((link.address.port + 1) and 0xFFFF))
    }

    private fun reset(link: Link) {
        link.phase = Phase.Idle
        link.token = 0u
        link.attempts = 0
        link.controlAccepted = false
        link.midiAccepted = false
        link.lastInvite = 0L
        link.lastHeard = System.currentTimeMillis()
        link.syncsCompleted = 0
    }

    private fun isOwn(address: UdpAddress): Boolean {
        val ownPort = address.port == control.port || address.port == midi.port
        return ownPort && address.ip in LocalAddresses.ipv4()
    }

    private fun makeSnapshots(): List<PeerSnapshot> {
        return links.map { (key, link) ->
            PeerSnapshot(
                id = key,
                name = link.name.ifEmpty { "Mac" },
                status = link.status,
                via = if (link.status == PeerSnapshot.Status.Bridged) link.via else null
            )
        }.sortedWith(compareBy(String.CASE_INSENSITIVE_ORDER) { it.name })
    }

    private fun publish() {
        val snapshot = makeSnapshots()
        if (snapshot == lastSnapshot) return
        lastSnapshot = snapshot
        onChange?.invoke(snapshot)
    }
}

private enum class Phase {
    Idle,
    InvitingControl,
    InvitingMidi,
    Connected;

    override fun toString(): String = when (this) {
        Idle -> "idle"
        InvitingControl -> "invitingControl"
        InvitingMidi -> "invitingMIDI"
        Connected -> "connected"
    }
}

private class Link(
    var uuid: String,
    var name: String,
    var address: UdpAddress,
    var weInitiate: Boolean,
    var phase: Phase = Phase.Idle,
    var token: UInt = 0u,
    var attempts: Int = 0,
    var lastInvite: Long = 0L,
    var lastHeard: Long = System.currentTimeMillis(),
    var lastSync: Long = 0L,
    var syncsCompleted: Int = 0,
    var sequence: Int = Random.nextInt(0, 65535),
    var controlAccepted: Boolean = false,
    var midiAccepted: Boolean = false,
    var missingSince: Long? = null,
    var candidates: MutableList<UdpAddress> = mutableListOf(),
    var opened: Long = System.currentTimeMillis(),
    var via: String? = null,
    var viaSeen: Long? = null
) {
    val status: PeerSnapshot.Status
        get() = when {
            phase == Phase.Connected -> PeerSnapshot.Status.Connected
            via != null -> PeerSnapshot.Status.Bridged
            weInitiate -> PeerSnapshot.Status.Connecting
            else -> PeerSnapshot.Status.Waiting
        }

    companion object {
        fun make(peer: DiscoveredPeer, uuid: String, initiate: Boolean): Link {
            return Link(
                uuid = uuid,
                name = peer.name,
                address = peer.address,
                weInitiate = initiate,
                candidates = peer.addresses.ifEmpty { listOf(peer.address) }.toMutableList()
            )
        }

        fun incoming(address: UdpAddress, name: String): Link {
            return Link(
                uuid = "",
                name = name,
                address = address,
                weInitiate = false,
                candidates = mutableListOf(address)
            )
        }
    }
}

private fun randomUInt(): UInt = Random.nextUInt(1u, UInt.MAX_VALUE)

private class SerialQueue(name: String) {
    private val tasks = ArrayDeque<() -> Unit>()
    private val lock = ReentrantLock()
    private val ready = lock.newCondition()
    @Volatile private var open = true

    private val worker = Thread({
        while (true) {
            val task: (() -> Unit)? = lock.withLock {
                while (tasks.isEmpty() && open) ready.await()
                if (tasks.isEmpty()) null else tasks.removeFirst()
            }
            if (task == null) break
            try {
                task()
            } catch (error: Throwable) {
                System.err.println("mesh session task failed: $error")
                error.printStackTrace()
            }
        }
    }, name).apply {
        isDaemon = true
        start()
    }

    fun async(block: () -> Unit) {
        if (Thread.currentThread() == worker) {
            block()
            return
        }
        lock.withLock {
            if (!open) throw RejectedExecutionException()
            tasks.addLast(block)
            ready.signal()
        }
    }

    fun <T> sync(block: () -> T): T {
        if (Thread.currentThread() == worker) return block()
        val latch = CountDownLatch(1)
        val holder = arrayOfNulls<Any>(1)
        var error: Throwable? = null
        async {
            try {
                holder[0] = block()
            } catch (thrown: Throwable) {
                error = thrown
            } finally {
                latch.countDown()
            }
        }
        latch.await()
        error?.let { throw it }
        @Suppress("UNCHECKED_CAST")
        return holder[0] as T
    }

    fun shutdown() {
        lock.withLock {
            open = false
            ready.signal()
        }
    }
}
