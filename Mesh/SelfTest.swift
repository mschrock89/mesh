import Foundation

enum SelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        failures += codecChecks()
        failures += updateChecks()
        if let handshake = handshakeCheck() {
            failures.append(handshake)
        }
        if let mesh = threeMacCheck() {
            failures.append(mesh)
        }
        if let relay = relayCheck() {
            failures.append(relay)
        }
        if let recovery = unreachableAddressCheck() {
            failures.append(recovery)
        }
        if failures.isEmpty {
            print("Mesh self-test passed")
            return true
        }
        for failure in failures {
            print("FAIL \(failure)")
        }
        return false
    }

    private static func codecChecks() -> [String] {
        var failures: [String] = []
        let invitation = AppleMIDI.Exchange(command: .invitation, token: 42, ssrc: 99, name: "Booth")
        guard case .exchange(let decoded) = AppleMIDI.decode(AppleMIDI.encodeExchange(invitation)) else {
            return ["invitation did not decode"]
        }
        if decoded.token != 42 || decoded.ssrc != 99 || decoded.name != "Booth" || decoded.command != .invitation {
            failures.append("invitation fields changed")
        }

        let sync = AppleMIDI.Sync(ssrc: 7, count: 1, timestamp1: 10, timestamp2: 20, timestamp3: 30)
        guard case .sync(let decodedSync) = AppleMIDI.decode(AppleMIDI.encodeSync(sync)) else {
            failures.append("sync did not decode")
            return failures
        }
        if decodedSync.ssrc != 7 || decodedSync.count != 1 || decodedSync.timestamp2 != 20 {
            failures.append("sync fields changed")
        }

        let note = Data([0x90, 60, 100])
        guard case .midi(let payload) = AppleMIDI.decode(AppleMIDI.encodeMIDI(sequence: 8, timestamp: 1234, ssrc: 5, midi: note)) else {
            failures.append("midi did not decode")
            return failures
        }
        if payload.sequence != 8 || payload.timestamp != 1234 || payload.midi != note {
            failures.append("midi fields changed")
        }

        let long = Data(repeating: 0x90, count: 20)
        guard case .midi(let longPayload) = AppleMIDI.decode(AppleMIDI.encodeMIDI(sequence: 1, timestamp: 2, ssrc: 3, midi: long)) else {
            failures.append("long midi did not decode")
            return failures
        }
        if longPayload.midi != long {
            failures.append("long midi payload changed")
        }

        let entry = AppleMIDI.DirectoryEntry(ip: 0x580D0A0A, port: 5006, uuid: "abc", name: "Booth")
        guard case .directory(let ssrc, let peers) = AppleMIDI.decode(AppleMIDI.encodeDirectory(ssrc: 4, peers: [entry])) else {
            failures.append("directory did not decode")
            return failures
        }
        if ssrc != 4 || peers.count != 1 || peers[0].port != 5006 || peers[0].uuid != "abc" || peers[0].name != "Booth" || peers[0].ip != entry.ip {
            failures.append("directory fields changed")
        }
        return failures
    }

    private static func threeMacCheck() -> String? {
        guard let macs = MacTrio() else { return "could not open three sessions" }
        macs.a.updateDiscovered([
            DiscoveredPeer(uuid: macs.b.localUUID, name: "Mac B", address: macs.addressB),
            DiscoveredPeer(uuid: macs.c.localUUID, name: "Mac C", address: macs.addressC)
        ])
        macs.b.updateDiscovered([
            DiscoveredPeer(uuid: macs.a.localUUID, name: "Mac A", address: macs.addressA),
            DiscoveredPeer(uuid: macs.c.localUUID, name: "Mac C", address: macs.addressC)
        ])
        macs.c.updateDiscovered([
            DiscoveredPeer(uuid: macs.a.localUUID, name: "Mac A", address: macs.addressA),
            DiscoveredPeer(uuid: macs.b.localUUID, name: "Mac B", address: macs.addressB)
        ])
        guard waitUntil(8, { macs.connectedPairs }) else {
            let detail = "a=\(macs.a.debugSummary()) b=\(macs.b.debugSummary()) c=\(macs.c.debugSummary())"
            macs.stop()
            return "three Macs did not form a full mesh (\(detail))"
        }
        let note = Data([0x90, 64, 100])
        macs.a.broadcast(note)
        guard waitUntil(1.5, { macs.receivedB.count(of: note) >= 1 && macs.receivedC.count(of: note) >= 1 }) else {
            macs.stop()
            return "midi did not reach both other Macs"
        }
        _ = waitUntil(0.6) { false }
        let copies = macs.receivedB.count(of: note) + macs.receivedC.count(of: note)
        macs.stop()
        if copies != 2 {
            return "midi was delivered \(copies) times across two Macs"
        }
        return nil
    }

    private static func relayCheck() -> String? {
        guard let macs = MacTrio() else { return "could not open relay sessions" }
        macs.a.dialPeersLearnedFromNeighbors = false
        macs.b.dialPeersLearnedFromNeighbors = false
        macs.c.dialPeersLearnedFromNeighbors = false
        macs.a.updateDiscovered([DiscoveredPeer(uuid: macs.b.localUUID, name: "Mac B", address: macs.addressB)])
        macs.b.updateDiscovered([
            DiscoveredPeer(uuid: macs.a.localUUID, name: "Mac A", address: macs.addressA),
            DiscoveredPeer(uuid: macs.c.localUUID, name: "Mac C", address: macs.addressC)
        ])
        macs.c.updateDiscovered([DiscoveredPeer(uuid: macs.b.localUUID, name: "Mac B", address: macs.addressB)])
        guard waitUntil(4, {
            macs.a.snapshots().contains { $0.name == "Mac C" && $0.status == .bridged }
                && macs.c.snapshots().contains { $0.name == "Mac A" && $0.status == .bridged }
        }) else {
            let detail = "a=\(macs.a.debugSummary()) c=\(macs.c.debugSummary())"
            macs.stop()
            return "the middle Mac did not introduce the other two (\(detail))"
        }
        let note = Data([0x90, 67, 90])
        macs.a.broadcast(note)
        guard waitUntil(1.5, { macs.receivedC.count(of: note) == 1 && macs.receivedB.count(of: note) == 1 }) else {
            macs.stop()
            return "midi did not cross the missing link"
        }
        let stillBridged = macs.a.snapshots().contains { $0.name == "Mac C" && $0.status == .bridged }
        macs.stop()
        if !stillBridged { return "bridged Mac was marked directly connected" }
        return nil
    }

    private static func unreachableAddressCheck() -> String? {
        guard let leftControl = try? UDPSocket(port: 0),
              let leftMIDI = try? UDPSocket(port: leftControl.port &+ 1),
              let rightControl = try? UDPSocket(port: 0),
              let rightMIDI = try? UDPSocket(port: rightControl.port &+ 1),
              let leftAddress = UDPAddress.ipv4("127.0.0.1", port: leftControl.port),
              let rightAddress = UDPAddress.ipv4("127.0.0.1", port: rightControl.port),
              let blackhole = UDPAddress.ipv4("192.0.2.9", port: rightControl.port) else {
            return "could not open recovery ports"
        }
        let left = MIDISession(localName: "Mac A", localUUID: "00000000-0000-0000-0000-000000000001", control: leftControl, midi: leftMIDI)
        let right = MIDISession(localName: "Mac B", localUUID: "ffffffff-ffff-ffff-ffff-ffffffffffff", control: rightControl, midi: rightMIDI)
        left.start()
        right.start()
        left.updateDiscovered([
            DiscoveredPeer(uuid: right.localUUID, name: "Mac B", address: blackhole, addresses: [blackhole, rightAddress])
        ])
        right.updateDiscovered([DiscoveredPeer(uuid: left.localUUID, name: "Mac A", address: leftAddress)])
        let connected = waitUntil(9) {
            left.snapshots().contains { $0.status == .connected } && right.snapshots().contains { $0.status == .connected }
        }
        let detail = "left=\(left.debugSummary()) right=\(right.debugSummary())"
        left.stop()
        right.stop()
        return connected ? nil : "unreachable first address never recovered (\(detail))"
    }

    private static func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        return condition()
    }

    private static func updateChecks() -> [String] {
        var failures: [String] = []
        if UpdateCheck.relation(localCommit: "abc", remoteTag: "abc", compareStatus: nil) != .upToDate {
            failures.append("same commit should be up to date")
        }
        if UpdateCheck.relation(localCommit: "ABC", remoteTag: "abc", compareStatus: "ahead") != .upToDate {
            failures.append("commit compare should ignore case")
        }
        if UpdateCheck.relation(localCommit: "old", remoteTag: "new", compareStatus: "ahead") != .available {
            failures.append("remote ahead should be installable")
        }
        if UpdateCheck.relation(localCommit: "new", remoteTag: "old", compareStatus: "behind") != .localIsNewer {
            failures.append("remote behind should keep this copy")
        }
        if UpdateCheck.relation(localCommit: "local", remoteTag: "remote", compareStatus: nil) != .notOnGitHub {
            failures.append("missing compare should stay unpublished")
        }
        if UpdateCheck.relation(localCommit: "unknown", remoteTag: "remote", compareStatus: nil) != .different {
            failures.append("unknown build should install the published app")
        }
        if UpdateCheck.relation(localCommit: "a", remoteTag: "b", compareStatus: "diverged") != .different {
            failures.append("diverged history should be replaceable")
        }

        let json = """
        {"tag_name":"abc123","assets":[{"id":5,"name":"notes.txt"},{"id":9,"name":"Mesh.app.zip"}]}
        """.data(using: .utf8)!
        let release = try? JSONDecoder().decode(GitHubRelease.self, from: json)
        if release?.tagName != "abc123" || release?.meshAssetID != 9 {
            failures.append("release json did not decode")
        }
        let empty = try? JSONDecoder().decode(GitHubRelease.self, from: Data("{\"tag_name\":\"abc\",\"assets\":[]}".utf8))
        if empty?.meshAssetID != nil {
            failures.append("missing asset should not install")
        }
        return failures
    }

    private static func handshakeCheck() -> String? {
        guard let leftControl = try? UDPSocket(port: 0),
              let leftMIDI = try? UDPSocket(port: leftControl.port &+ 1),
              let rightControl = try? UDPSocket(port: 0),
              let rightMIDI = try? UDPSocket(port: rightControl.port &+ 1),
              let leftAddress = UDPAddress.ipv4("127.0.0.1", port: leftControl.port),
              let rightAddress = UDPAddress.ipv4("127.0.0.1", port: rightControl.port) else {
            return "could not open loopback ports"
        }

        let left = MIDISession(localName: "Mac A", localUUID: "00000000-0000-0000-0000-000000000001", control: leftControl, midi: leftMIDI)
        let right = MIDISession(localName: "Mac B", localUUID: "ffffffff-ffff-ffff-ffff-ffffffffffff", control: rightControl, midi: rightMIDI)
        let received = Received()
        right.onMIDI = { data in
            received.append(data)
        }
        left.onMIDI = { data in
            received.appendReturn(data)
        }
        left.start()
        right.start()
        left.updateDiscovered([DiscoveredPeer(uuid: right.localUUID, name: "Mac B", address: rightAddress)])
        right.updateDiscovered([DiscoveredPeer(uuid: left.localUUID, name: "Mac A", address: leftAddress)])

        let deadline = Date().addingTimeInterval(4)
        var connected = false
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            let leftReady = left.snapshots().contains { $0.status == .connected }
            let rightReady = right.snapshots().contains { $0.status == .connected }
            if leftReady && rightReady {
                connected = true
                break
            }
        }
        guard connected else {
            let detail = "left=\(left.debugSummary()) right=\(right.debugSummary())"
            left.stop()
            right.stop()
            return "handshake did not connect (\(detail))"
        }

        let note = Data([0x90, 60, 100])
        let reply = Data([0x80, 60, 0])
        left.broadcast(note)
        right.broadcast(reply)

        let midiDeadline = Date().addingTimeInterval(1)
        while Date() < midiDeadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            if received.contains(note) && received.containsReturn(reply) { break }
        }
        left.stop()
        right.stop()
        if !received.contains(note) || !received.containsReturn(reply) {
            return "midi did not cross the session"
        }
        return nil
    }
}

private final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var inbound: [Data] = []
    private var returned: [Data] = []

    func append(_ data: Data) {
        lock.lock()
        inbound.append(data)
        lock.unlock()
    }

    func appendReturn(_ data: Data) {
        lock.lock()
        returned.append(data)
        lock.unlock()
    }

    func contains(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return inbound.contains(data)
    }

    func containsReturn(_ data: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return returned.contains(data)
    }

    func count(of data: Data) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return inbound.filter { $0 == data }.count
    }
}

private final class MacTrio {
    let a: MIDISession
    let b: MIDISession
    let c: MIDISession
    let addressA: UDPAddress
    let addressB: UDPAddress
    let addressC: UDPAddress
    let receivedA = Received()
    let receivedB = Received()
    let receivedC = Received()

    init?() {
        guard let aControl = try? UDPSocket(port: 0),
              let aMIDI = try? UDPSocket(port: aControl.port &+ 1),
              let bControl = try? UDPSocket(port: 0),
              let bMIDI = try? UDPSocket(port: bControl.port &+ 1),
              let cControl = try? UDPSocket(port: 0),
              let cMIDI = try? UDPSocket(port: cControl.port &+ 1),
              let addressA = UDPAddress.ipv4("127.0.0.1", port: aControl.port),
              let addressB = UDPAddress.ipv4("127.0.0.1", port: bControl.port),
              let addressC = UDPAddress.ipv4("127.0.0.1", port: cControl.port) else {
            return nil
        }
        a = MIDISession(localName: "Mac A", localUUID: "00000000-0000-0000-0000-000000000001", control: aControl, midi: aMIDI)
        b = MIDISession(localName: "Mac B", localUUID: "00000000-0000-0000-0000-000000000002", control: bControl, midi: bMIDI)
        c = MIDISession(localName: "Mac C", localUUID: "ffffffff-ffff-ffff-ffff-ffffffffffff", control: cControl, midi: cMIDI)
        self.addressA = addressA
        self.addressB = addressB
        self.addressC = addressC
        a.onMIDI = { [receivedA] data in receivedA.append(data) }
        b.onMIDI = { [receivedB] data in receivedB.append(data) }
        c.onMIDI = { [receivedC] data in receivedC.append(data) }
        a.start()
        b.start()
        c.start()
    }

    var connectedPairs: Bool {
        a.snapshots().filter { $0.status == .connected }.count == 2
            && b.snapshots().filter { $0.status == .connected }.count == 2
            && c.snapshots().filter { $0.status == .connected }.count == 2
    }

    func stop() {
        a.stop()
        b.stop()
        c.stop()
    }
}
