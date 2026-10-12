import Foundation
import os

struct DiscoveredPeer: Equatable {
    var uuid: String
    var name: String
    var address: UDPAddress
}

struct PeerSnapshot: Identifiable, Equatable {
    var id: String
    var name: String
    var status: Status

    enum Status: String, Equatable {
        case waiting
        case connecting
        case connected
    }
}

/// One Apple network MIDI session per remote Mac.
/// The Mac with the lower id sends the invitation. The other accepts it.
/// Local MIDI is broadcast to every connected Mac. MIDI that arrives from the
/// network is delivered locally and is not forwarded, so a mesh does not echo.
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
                if uuid == self.localUUID { continue }
                let key = item.address.key
                seen.insert(key)
                if var link = self.links[key] {
                    link.uuid = uuid
                    link.name = item.name
                    link.address = item.address
                    link.missingSince = nil
                    if !link.controlAccepted && !link.midiAccepted && link.phase != .connected {
                        link.weInitiate = self.initiates(uuid: uuid, name: item.name)
                    }
                    self.links[key] = link
                } else {
                    self.links[key] = Link.make(item, uuid: uuid, initiate: self.initiates(uuid: uuid, name: item.name))
                }
            }
            let now = Date()
            for key in self.links.keys where !seen.contains(key) {
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
            let timestamp = UInt32(truncatingIfNeeded: AppleMIDIClock.now())
            for key in self.links.keys {
                guard self.links[key]?.phase == .connected else { continue }
                self.links[key]?.sequence &+= 1
                guard let link = self.links[key] else { continue }
                let packet = AppleMIDI.encodeMIDI(
                    sequence: link.sequence,
                    timestamp: timestamp,
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
            service(&link, now: now)
            links[key] = link
        }
        for key in remove {
            links.removeValue(forKey: key)
        }
        publish()
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

        guard link.weInitiate else {
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
            case .rejected, .synchronization, .feedback:
                break
            }
        case .sync(let sync):
            if midiPort { handleSync(sync, from: address) }
        case .midi(let payload):
            if midiPort { handleMIDI(payload, from: address) }
        case .feedback:
            touch(address, midiPort: midiPort)
        }
    }

    private func handleInvitation(_ message: AppleMIDI.Exchange, from address: UDPAddress, midiPort: Bool) {
        let controlAddress = midiPort ? address.withPort(address.port &- 1) : address
        let key = controlAddress.key
        var link = links[key] ?? Link.incoming(address: controlAddress, name: message.name)
        link.lastHeard = Date()
        link.missingSince = nil
        if !message.name.isEmpty { link.name = message.name }
        if link.weInitiate && !link.uuid.isEmpty && link.phase != .connected {
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
        if !payload.midi.isEmpty {
            onMIDI?(payload.midi)
        }
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
        let name = link.name
        log.info("Connected to \(name, privacy: .public).")
        print("Mesh connected to \(name)")
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
            PeerSnapshot(id: key, name: link.name.isEmpty ? "Mac" : link.name, status: link.status)
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

    enum Phase: String {
        case idle
        case invitingControl
        case invitingMIDI
        case connected
    }

    var status: PeerSnapshot.Status {
        if phase == .connected { return .connected }
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
            missingSince: nil
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
            missingSince: nil
        )
    }
}
