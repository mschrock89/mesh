import Foundation
import os

struct DiscoveredPeer: Equatable {
    var uuid: String
    var name: String
    var address: UDPAddress
    var addresses: [UDPAddress]

    init(uuid: String, name: String, address: UDPAddress, addresses: [UDPAddress] = []) {
        self.uuid = uuid
        self.name = name
        self.address = address
        self.addresses = addresses.isEmpty ? [address] : addresses
    }
}

struct PeerSnapshot: Identifiable, Equatable {
    var id: String
    var name: String
    var status: Status
    var via: String?

    enum Status: String, Equatable {
        case waiting
        case connecting
        case connected
        case bridged
    }

    var isReachable: Bool { status == .connected || status == .bridged }
}

/// One Apple network MIDI session per remote Mac.
/// The Mac with the lower id sends the invitation first. If that does not
/// connect, the other Mac tries, and an invitation that actually arrives wins
/// over one that never gets an answer. Local MIDI goes to every directly
/// connected Mac and is relayed through those Macs, so a Mac that can see the other two
/// still joins them when their own path does not come up.
final class MIDISession {
    let localName: String
    let localUUID: String
    let ssrc: UInt32
    let control: UDPSocket
    let midi: UDPSocket
    var onMIDI: ((Data) -> Void)?
    var onChange: (([PeerSnapshot]) -> Void)?

    private let queue: DispatchQueue
    private let queueKey: DispatchSpecificKey<UInt8>
    private var links: [String: Link] = [:]
    private var suspended = false
    private var lastSnapshot: [PeerSnapshot] = []
    private var timer: DispatchSourceTimer?
    private var nextEvent: UInt32 = 1
    private var seenEvents: [UInt64] = []
    private var lastDirectory = Date.distantPast
    /// Tests can turn this off to prove MIDI still crosses a missing edge.
    var dialPeersLearnedFromNeighbors = true
    private let log = Logger(subsystem: "com.mitchellschrock.Mesh", category: "session")

    init(localName: String, localUUID: String, control: UDPSocket, midi: UDPSocket) {
        self.localName = localName
        self.localUUID = localUUID.lowercased()
        self.ssrc = UInt32.random(in: 1..<UInt32.max)
        self.control = control
        self.midi = midi
        let key = DispatchSpecificKey<UInt8>()
        let queue = DispatchQueue(label: "mesh.session.\(localUUID)", qos: .userInteractive)
        queue.setSpecific(key: key, value: 1)
        self.queueKey = key
        self.queue = queue
    }

    func start() {
        control.onPacket = { [weak self] data, address in
            self?.onQueue { self?.ingest(data, from: address, midiPort: false) }
        }
        midi.onPacket = { [weak self] data, address in
            self?.onQueue { self?.ingest(data, from: address, midiPort: true) }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.2, repeating: 0.25)
        timer.setEventHandler { [weak self] in
            self?.tick()
        }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        onQueue {
            self.timer?.cancel()
            self.timer = nil
            for key in self.links.keys {
                if self.links[key]?.phase == .connected {
                    self.sendExit(self.links[key]!)
                }
            }
        }
        control.closeSocket()
        midi.closeSocket()
    }

    func updateDiscovered(_ found: [DiscoveredPeer]) {
        onQueue {
            var seen = Set<String>()
            for item in found {
                let uuid = item.uuid.lowercased()
                if !uuid.isEmpty && uuid == self.localUUID { continue }
                let candidates = item.addresses.isEmpty ? [item.address] : item.addresses
                let key = self.links.first(where: { $0.value.uuid == uuid && !uuid.isEmpty })?.key ?? item.address.key
                seen.insert(key)
                if var link = self.links[key] {
                    let learnedIdentity = link.uuid.isEmpty && !uuid.isEmpty
                    if !uuid.isEmpty { link.uuid = uuid }
                    link.name = item.name
                    link.candidates = candidates
                    link.missingSince = nil
                    if link.phase != .connected && !candidates.contains(link.address) {
                        link.address = item.address
                    }
                    if learnedIdentity && link.phase != .connected && !link.controlAccepted && !link.midiAccepted {
                        link.weInitiate = self.initiates(uuid: uuid, name: item.name)
                    }
                    self.store(link, replacing: key)
                    seen.remove(key)
                    seen.insert(link.address.key)
                } else {
                    var link = Link.make(item, uuid: uuid, initiate: self.initiates(uuid: uuid, name: item.name))
                    link.candidates = candidates
                    self.links[link.address.key] = link
                    seen.insert(link.address.key)
                }
            }
            let now = Date()
            for key in self.links.keys where !seen.contains(key) {
                if self.links[key]?.via != nil || self.links[key]?.phase == .connected { continue }
                if self.links[key]?.missingSince == nil {
                    self.links[key]?.missingSince = now
                }
            }
            self.publish()
        }
    }

    func broadcast(_ midiData: Data) {
        guard !midiData.isEmpty else { return }
        onQueue {
            let event = self.nextEvent
            self.nextEvent &+= 1
            if self.nextEvent == 0 { self.nextEvent = 1 }
            self.remember(ssrc: self.ssrc, event: event)
            for key in self.links.keys {
                guard self.links[key]?.phase == .connected else { continue }
                self.links[key]?.sequence &+= 1
                guard let link = self.links[key] else { continue }
                let packet = AppleMIDI.encodeMIDI(
                    sequence: link.sequence,
                    timestamp: event,
                    ssrc: self.ssrc,
                    midi: midiData
                )
                self.midi.send(packet, to: link.address.withPort(link.address.port &+ 1))
            }
        }
    }

    func reconnect() {
        onQueue {
            self.suspended = false
            for key in Array(self.links.keys) {
                if self.links[key]?.phase == .connected {
                    self.sendExit(self.links[key]!)
                }
                self.reset(&self.links[key]!)
            }
            self.publish()
        }
    }

    func suspend() {
        onQueue {
            self.suspended = true
            for key in Array(self.links.keys) {
                if self.links[key]?.phase == .connected {
                    self.sendExit(self.links[key]!)
                }
                self.reset(&self.links[key]!)
            }
            self.publish()
        }
    }

    func resume() {
        reconnect()
    }

    func snapshots() -> [PeerSnapshot] {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return makeSnapshots()
        }
        return queue.sync { makeSnapshots() }
    }

    func debugSummary() -> String {
        let body = queue.sync {
            self.links.values.map { link in
                "\(link.name) \(link.address.key) initiate=\(link.weInitiate) phase=\(link.phase) attempts=\(link.attempts)"
            }.sorted().joined(separator: " | ")
        }
        return body.isEmpty ? "no peers" : body
    }

    private func initiates(uuid: String, name: String) -> Bool {
        guard !uuid.isEmpty else { return false }
        if localUUID != uuid { return localUUID < uuid }
        return localName.localizedCaseInsensitiveCompare(name) == .orderedAscending
    }

    private func onQueue(_ body: @escaping () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            body()
        } else {
            queue.async(execute: body)
        }
    }

    private func tick() {
        guard !suspended else { return }
        let now = Date()
        var remove: [String] = []
        for key in Array(links.keys) {
            guard var link = links[key] else { continue }
            if let missing = link.missingSince, now.timeIntervalSince(missing) > 10 {
                if link.phase == .connected { sendExit(link) }
                remove.append(key)
                continue
            }
            if let viaSeen = link.viaSeen, now.timeIntervalSince(viaSeen) > 4 {
                link.via = nil
                link.viaSeen = nil
                if link.phase != .connected && link.missingSince == nil {
                    link.missingSince = now
                }
            }
            if let rotated = rotate(&link) {
                links.removeValue(forKey: key)
                if links[rotated] == nil {
                    links[rotated] = link
                }
                continue
            }
            service(&link, now: now)
            links[key] = link
        }
        for key in remove {
            links.removeValue(forKey: key)
        }
        sendDirectories(now: now)
        publish()
    }

    private func rotate(_ link: inout Link) -> String? {
        guard link.weInitiate, (link.phase == .invitingControl || link.phase == .idle) else { return nil }
        guard link.attempts >= 4, link.candidates.count > 1 else { return nil }
        let current = link.candidates.firstIndex(of: link.address) ?? 0
        let next = link.candidates[(current + 1) % link.candidates.count]
        guard next != link.address else { return nil }
        reset(&link)
        link.address = next
        return next.key
    }

    private func service(_ link: inout Link, now: Date) {
        if link.phase == .connected {
            if now.timeIntervalSince(link.lastHeard) > 25 {
                let name = link.name
                log.info("Link to \(name, privacy: .public) went quiet. Reconnecting.")
                sendExit(link)
                reset(&link)
                return
            }
            guard link.weInitiate else { return }
            let interval: TimeInterval = link.syncsCompleted < 3 ? 0.4 : 10
            if now.timeIntervalSince(link.lastSync) >= interval {
                sendSync(to: link, count: 0, t1: AppleMIDIClock.now(), t2: 0, t3: 0)
                link.lastSync = now
            }
            return
        }

        let learnedFromNeighbor = link.via != nil && !dialPeersLearnedFromNeighbors
        if !link.weInitiate && !learnedFromNeighbor && link.phase != .connected && !link.controlAccepted && !link.midiAccepted {
            if now.timeIntervalSince(link.opened) >= 2.5 {
                link.weInitiate = true
            }
        }

        guard link.weInitiate, !learnedFromNeighbor else {
            if (link.controlAccepted || link.midiAccepted), now.timeIntervalSince(link.lastHeard) > 25 {
                reset(&link)
            }
            return
        }

        if link.attempts >= 12 {
            if now.timeIntervalSince(link.lastInvite) >= 3 {
                link.attempts = 0
                link.phase = .idle
                link.token = 0
            }
            return
        }

        if link.phase == .invitingMIDI {
            if now.timeIntervalSince(link.lastInvite) >= 1 {
                sendInvitation(to: link, midiPort: true)
                link.attempts += 1
                link.lastInvite = now
            }
            return
        }

        if link.phase == .idle {
            link.token = UInt32.random(in: 1..<UInt32.max)
            link.phase = .invitingControl
        }
        if link.attempts == 0 || now.timeIntervalSince(link.lastInvite) >= 1 {
            sendInvitation(to: link, midiPort: false)
            link.attempts += 1
            link.lastInvite = now
        }
    }

    private func ingest(_ data: Data, from address: UDPAddress, midiPort: Bool) {
        guard !isOwn(address), let packet = AppleMIDI.decode(data) else { return }
        switch packet {
        case .exchange(let message):
            switch message.command {
            case .invitation:
                handleInvitation(message, from: address, midiPort: midiPort)
            case .accepted:
                handleAccepted(message, from: address, midiPort: midiPort)
            case .exit:
                handleExit(from: address, midiPort: midiPort)
            case .rejected, .synchronization, .feedback, .directory:
                break
            }
        case .sync(let sync):
            if midiPort { handleSync(sync, from: address) }
        case .midi(let payload):
            if midiPort { handleMIDI(payload, from: address) }
        case .feedback:
            touch(address, midiPort: midiPort)
        case .directory(_, let peers):
            if !midiPort { handleDirectory(peers, from: address) }
        }
    }

    private func handleInvitation(_ message: AppleMIDI.Exchange, from address: UDPAddress, midiPort: Bool) {
        let controlAddress = midiPort ? address.withPort(address.port &- 1) : address
        let key = controlAddress.key
        var link = links[key] ?? Link.incoming(address: controlAddress, name: message.name)
        link.lastHeard = Date()
        link.missingSince = nil
        if !message.name.isEmpty { link.name = message.name }
        let ourInviteIsWinning = link.weInitiate
            && link.phase == .invitingControl
            && link.token != 0
            && message.token > link.token
            && link.attempts < 6
        if ourInviteIsWinning {
            links[key] = link
            return
        }
        link.weInitiate = false
        let reply = AppleMIDI.encodeExchange(
            .init(command: .accepted, token: message.token, ssrc: ssrc, name: localName)
        )
        if midiPort {
            midi.send(reply, to: address)
            link.midiAccepted = true
        } else {
            control.send(reply, to: address)
            link.controlAccepted = true
        }
        if link.controlAccepted && link.midiAccepted {
            becomeConnected(&link)
        }
        links[key] = link
        publish()
    }

    private func handleAccepted(_ message: AppleMIDI.Exchange, from address: UDPAddress, midiPort: Bool) {
        let controlAddress = midiPort ? address.withPort(address.port &- 1) : address
        guard var link = links[controlAddress.key], link.weInitiate, message.token == link.token else { return }
        link.lastHeard = Date()
        if !midiPort && link.phase == .invitingControl {
            link.phase = .invitingMIDI
            link.attempts = 0
            link.lastInvite = Date()
            sendInvitation(to: link, midiPort: true)
        } else if midiPort && link.phase == .invitingMIDI {
            becomeConnected(&link)
            sendSync(to: link, count: 0, t1: AppleMIDIClock.now(), t2: 0, t3: 0)
            link.lastSync = Date()
        }
        links[controlAddress.key] = link
        publish()
    }

    private func handleSync(_ sync: AppleMIDI.Sync, from address: UDPAddress) {
        let key = address.withPort(address.port &- 1).key
        guard var link = links[key] else { return }
        link.lastHeard = Date()
        let now = AppleMIDIClock.now()
        switch sync.count {
        case 0:
            sendSync(to: link, count: 1, t1: sync.timestamp1, t2: now, t3: 0)
        case 1:
            sendSync(to: link, count: 2, t1: sync.timestamp1, t2: sync.timestamp2, t3: now)
            link.syncsCompleted += 1
        case 2:
            link.syncsCompleted += 1
        default:
            break
        }
        links[key] = link
    }

    private func handleMIDI(_ payload: AppleMIDI.MIDIPayload, from address: UDPAddress) {
        let key = address.withPort(address.port &- 1).key
        guard var link = links[key], link.phase == .connected else { return }
        link.lastHeard = Date()
        links[key] = link
        guard payload.ssrc != ssrc, !payload.midi.isEmpty else { return }
        guard remember(ssrc: payload.ssrc, event: payload.timestamp) else { return }
        onMIDI?(payload.midi)
        for other in links.keys where other != key {
            guard links[other]?.phase == .connected else { continue }
            links[other]?.sequence &+= 1
            guard let hop = links[other] else { continue }
            let packet = AppleMIDI.encodeMIDI(
                sequence: hop.sequence,
                timestamp: payload.timestamp,
                ssrc: payload.ssrc,
                midi: payload.midi
            )
            midi.send(packet, to: hop.address.withPort(hop.address.port &+ 1))
        }
    }

    private func handleDirectory(_ entries: [AppleMIDI.DirectoryEntry], from address: UDPAddress) {
        guard let relay = links[address.key], relay.phase == .connected else { return }
        let relayName = relay.name.isEmpty ? "another Mac" : relay.name
        for entry in entries {
            let uuid = entry.uuid.lowercased()
            if uuid.isEmpty || uuid == localUUID { continue }
            let peerAddress = UDPAddress(ip: entry.ip, port: entry.port)
            if isOwn(peerAddress) { continue }
            if links.values.contains(where: { $0.uuid == uuid && $0.phase == .connected }) { continue }
            if let existing = links.first(where: { $0.value.uuid == uuid }) {
                links[existing.key]?.via = relayName
                links[existing.key]?.viaSeen = Date()
                links[existing.key]?.missingSince = nil
                if links[existing.key]?.name.isEmpty == true {
                    links[existing.key]?.name = entry.name
                }
                continue
            }
            var link = links[peerAddress.key] ?? Link.make(
                DiscoveredPeer(uuid: uuid, name: entry.name, address: peerAddress),
                uuid: uuid,
                initiate: dialPeersLearnedFromNeighbors && initiates(uuid: uuid, name: entry.name)
            )
            if link.uuid.isEmpty { link.uuid = uuid }
            if link.name.isEmpty { link.name = entry.name }
            if link.phase != .connected {
                link.via = relayName
                link.viaSeen = Date()
                link.missingSince = nil
            }
            links[peerAddress.key] = link
        }
        publish()
    }

    private func handleExit(from address: UDPAddress, midiPort: Bool) {
        let controlAddress = midiPort ? address.withPort(address.port &- 1) : address
        guard var link = links[controlAddress.key] else { return }
        let name = link.name
        log.info("\(name, privacy: .public) left the session.")
        reset(&link)
        links[controlAddress.key] = link
        publish()
    }

    private func touch(_ address: UDPAddress, midiPort: Bool) {
        let controlAddress = midiPort ? address.withPort(address.port &- 1) : address
        links[controlAddress.key]?.lastHeard = Date()
    }

    private func becomeConnected(_ link: inout Link) {
        guard link.phase != .connected else { return }
        link.phase = .connected
        link.lastHeard = Date()
        link.via = nil
        link.viaSeen = nil
        if link.uuid.isEmpty, let donor = links.values.first(where: { $0.name == link.name && !$0.uuid.isEmpty && $0.name != "" }) {
            link.uuid = donor.uuid
        }
        let key = link.address.key
        let uuid = link.uuid
        if !uuid.isEmpty {
            for other in links.keys where other != key && links[other]?.uuid == uuid {
                links.removeValue(forKey: other)
            }
        }
        if !link.name.isEmpty {
            for other in links.keys where other != key && links[other]?.name == link.name && links[other]?.phase != .connected {
                links.removeValue(forKey: other)
            }
        }
        let name = link.name
        log.info("Connected to \(name, privacy: .public).")
        print("Mesh connected to \(name)")
    }

    @discardableResult
    private func remember(ssrc: UInt32, event: UInt32) -> Bool {
        let key = (UInt64(ssrc) << 32) | UInt64(event)
        if seenEvents.contains(key) { return false }
        seenEvents.append(key)
        if seenEvents.count > 256 {
            seenEvents.removeFirst(seenEvents.count - 256)
        }
        return true
    }

    private func sendDirectories(now: Date) {
        guard now.timeIntervalSince(lastDirectory) >= 0.5 else { return }
        let connected = links.values.filter { $0.phase == .connected && !$0.uuid.isEmpty }
        guard !connected.isEmpty else { return }
        lastDirectory = now
        let entries = connected.map {
            AppleMIDI.DirectoryEntry(ip: $0.address.ip, port: $0.address.port, uuid: $0.uuid, name: $0.name)
        }
        let packet = AppleMIDI.encodeDirectory(ssrc: ssrc, peers: entries)
        for link in connected {
            control.send(packet, to: link.address)
        }
    }

    private func store(_ link: Link, replacing key: String) {
        links.removeValue(forKey: key)
        links[link.address.key] = link
    }

    private func sendInvitation(to link: Link, midiPort: Bool) {
        let packet = AppleMIDI.encodeExchange(
            .init(command: .invitation, token: link.token, ssrc: ssrc, name: localName)
        )
        if midiPort {
            midi.send(packet, to: link.address.withPort(link.address.port &+ 1))
        } else {
            control.send(packet, to: link.address)
        }
    }

    private func sendSync(to link: Link, count: UInt8, t1: UInt64, t2: UInt64, t3: UInt64) {
        let packet = AppleMIDI.encodeSync(
            .init(ssrc: ssrc, count: count, timestamp1: t1, timestamp2: t2, timestamp3: t3)
        )
        midi.send(packet, to: link.address.withPort(link.address.port &+ 1))
    }

    private func sendExit(_ link: Link) {
        let packet = AppleMIDI.encodeExchange(
            .init(command: .exit, token: link.token, ssrc: ssrc, name: "")
        )
        control.send(packet, to: link.address)
        midi.send(packet, to: link.address.withPort(link.address.port &+ 1))
    }

    private func reset(_ link: inout Link) {
        link.phase = .idle
        link.token = 0
        link.attempts = 0
        link.controlAccepted = false
        link.midiAccepted = false
        link.lastInvite = .distantPast
        link.lastHeard = Date()
        link.syncsCompleted = 0
    }

    private func isOwn(_ address: UDPAddress) -> Bool {
        let local = LocalAddresses.ipv4()
        let ownPort = address.port == control.port || address.port == midi.port
        return ownPort && local.contains(address.ip)
    }

    private func makeSnapshots() -> [PeerSnapshot] {
        links.map { key, link in
            PeerSnapshot(
                id: key,
                name: link.name.isEmpty ? "Mac" : link.name,
                status: link.status,
                via: link.status == .bridged ? link.via : nil
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func publish() {
        let snapshot = makeSnapshots()
        guard snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        onChange?(snapshot)
    }
}

private struct Link {
    var uuid: String
    var name: String
    var address: UDPAddress
    var weInitiate: Bool
    var phase: Phase
    var token: UInt32
    var attempts: Int
    var lastInvite: Date
    var lastHeard: Date
    var lastSync: Date
    var syncsCompleted: Int
    var sequence: UInt16
    var controlAccepted: Bool
    var midiAccepted: Bool
    var missingSince: Date?
    var candidates: [UDPAddress]
    var opened: Date
    var via: String?
    var viaSeen: Date?

    enum Phase: String {
        case idle
        case invitingControl
        case invitingMIDI
        case connected
    }

    var status: PeerSnapshot.Status {
        if phase == .connected { return .connected }
        if via != nil { return .bridged }
        if weInitiate { return .connecting }
        return .waiting
    }

    static func make(_ peer: DiscoveredPeer, uuid: String, initiate: Bool) -> Link {
        Link(
            uuid: uuid,
            name: peer.name,
            address: peer.address,
            weInitiate: initiate,
            phase: .idle,
            token: 0,
            attempts: 0,
            lastInvite: .distantPast,
            lastHeard: Date(),
            lastSync: .distantPast,
            syncsCompleted: 0,
            sequence: UInt16.random(in: 0..<UInt16.max),
            controlAccepted: false,
            midiAccepted: false,
            missingSince: nil,
            candidates: peer.addresses.isEmpty ? [peer.address] : peer.addresses,
            opened: Date(),
            via: nil,
            viaSeen: nil
        )
    }

    static func incoming(address: UDPAddress, name: String) -> Link {
        Link(
            uuid: "",
            name: name,
            address: address,
            weInitiate: false,
            phase: .idle,
            token: 0,
            attempts: 0,
            lastInvite: .distantPast,
            lastHeard: Date(),
            lastSync: .distantPast,
            syncsCompleted: 0,
            sequence: UInt16.random(in: 0..<UInt16.max),
            controlAccepted: false,
            midiAccepted: false,
            missingSince: nil,
            candidates: [address],
            opened: Date(),
            via: nil,
            viaSeen: nil
        )
    }
}
