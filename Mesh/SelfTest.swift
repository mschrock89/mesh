import AppKit
import Foundation

enum SelfTest {
    static func run() -> Bool {
        var failures: [String] = []
        failures += codecChecks()
        failures += roomChecks()
        failures += updateChecks()
        failures += panelChecks()
        if let isolated = roomIsolationCheck() {
            failures.append(isolated)
        }
        if let changed = roomChangeCheck() {
            failures.append(changed)
        }
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

    private static func panelChecks() -> [String] {
        var failures: [String] = []
        guard let image = MenuBarIcon.image() else {
            return ["menu bar icon is missing"]
        }
        if image.size.width < 10 || image.size.height < 10 {
            failures.append("menu bar icon has no size")
        }

        let anchor = CGRect(x: 1000, y: 800, width: 22, height: 22)
        let attached = CGRect(x: 820, y: 400, width: 360, height: 390)
        if !PopoverPlacement.isAttached(window: attached, anchor: anchor) {
            failures.append("panel under the status item was treated as detached")
        }
        let shifted = CGRect(x: 700, y: 400, width: 360, height: 390)
        if !PopoverPlacement.isAttached(window: shifted, anchor: anchor) {
            failures.append("panel kept on screen was treated as detached")
        }
        let jumped = CGRect(x: 0, y: 0, width: 360, height: 400)
        if PopoverPlacement.isAttached(window: jumped, anchor: anchor) {
            failures.append("panel at the screen origin was treated as attached")
        }
        let dropped = CGRect(x: 820, y: 200, width: 360, height: 390)
        if PopoverPlacement.isAttached(window: dropped, anchor: anchor) {
            failures.append("panel that fell away from the menu bar was treated as attached")
        }
        if PopoverPlacement.isAttached(window: attached, anchor: .zero) {
            failures.append("a missing status item was treated as attached")
        }
        return failures
    }

    private static func codecChecks() -> [String] {
        var failures: [String] = []
        let invitation = AppleMIDI.Exchange(command: .invitation, token: 42, ssrc: 99, name: "Booth")
        guard case .exchange(let decoded) = AppleMIDI.decode(AppleMIDI.encodeExchange(invitation)) else {
            return ["invitation did not decode"]
        }
        if decoded.token != 42 || decoded.ssrc != 99 || decoded.name != "Booth" || decoded.command != .invitation || decoded.room != "" {
            failures.append("invitation fields changed")
        }
        let placed = AppleMIDI.Exchange(command: .accepted, token: 7, ssrc: 8, name: "Booth", room: "sanctuary-2")
        guard case .exchange(let placedDecoded) = AppleMIDI.decode(AppleMIDI.encodeExchange(placed)) else {
            return ["room invitation did not decode"]
        }
        if placedDecoded.room != "sanctuary-2" || placedDecoded.name != "Booth" || placedDecoded.command != .accepted {
            failures.append("room was dropped from the invitation")
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
        let tagged = "mesh-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        if UpdateCheck.commit(fromTag: tagged) != "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" {
            failures.append("release tag should carry the commit")
        }
        if !UpdateCheck.same(UpdateCheck.commit(fromTag: tagged), "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA") {
            failures.append("tagged release should match its commit")
        }
        if !UpdateCredential.ghCandidates().contains(where: { $0.hasSuffix("/.local/bin/gh") }) {
            failures.append("github login should be found in .local/bin")
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

    private static func roomChecks() -> [String] {
        var failures: [String] = []
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mesh-rooms-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("rooms.json")
        let suite = "mesh.rooms.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: suite)
        }
        let store = RoomStore(defaults: defaults, fileURL: url)
        if store.rooms.map(\.id) != MeshRoom.sanctuaries.map(\.id) || store.selectedID != MeshRoom.defaultID {
            failures.append("a new Mac should start in Sanctuary 1")
        }
        if !store.select("sanctuary-3") || store.selected.name != "Sanctuary 3" {
            failures.append("room selection did not stick")
        }
        if !store.rename("sanctuary-3", to: "  Main   Hall ") || store.selected.name != "Main Hall" {
            failures.append("room rename did not stick")
        }
        guard let added = store.add(named: "Chapel") else {
            failures.append("could not add a room")
            return failures
        }
        if store.delete("sanctuary-1") {
            failures.append("sanctuary rooms should stay in the list")
        }
        if !store.delete(added.id) || store.rooms.contains(where: { $0.id == added.id }) {
            failures.append("custom room was not removed")
        }
        let revived = RoomStore(defaults: defaults, fileURL: url)
        if revived.selectedID != "sanctuary-3" || revived.selected.name != "Main Hall" {
            failures.append("room choice was not stored")
        }
        if revived.rooms.contains(where: { $0.id == added.id }) {
            failures.append("removed room came back")
        }
        let older = AnnouncedRoom(id: "sanctuary-3", name: "Old Name", revision: 1)
        let chapel = AnnouncedRoom(id: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", name: "Chapel", revision: 50)
        if !revived.merge([older, chapel]) || !revived.rooms.contains(where: { $0.name == "Chapel" }) {
            failures.append("a room from another Mac was not added")
        }
        if revived.selected.name != "Main Hall" {
            failures.append("an older name replaced the saved room")
        }
        guard let imported = revived.rooms.first(where: { $0.name == "Chapel" }) else { return failures }
        if !revived.delete(imported.id) {
            failures.append("imported room could not be removed")
        }
        if !revived.merge([chapel]) || !revived.elsewhere.contains(where: { $0.id == chapel.id }) {
            failures.append("a removed room should stay off this Mac until it is added again")
        }
        if !revived.restore(chapel.id) || !revived.rooms.contains(where: { $0.id == chapel.id }) {
            failures.append("a removed room could not be added again")
        }
        if !RoomGate.same("Sanctuary-2", "sanctuary-2") || RoomGate.same("sanctuary-1", "sanctuary-2") || RoomGate.same("", "sanctuary-1") {
            failures.append("room matching is wrong")
        }
        let posted = RoomCatalogTXT.fields(selected: revived.selected, rooms: revived.rooms)
        let heard = RoomCatalogTXT.announced(from: posted)
        if !heard.contains(where: { $0.id == "sanctuary-3" && $0.name == "Main Hall" }) || !heard.contains(where: { $0.name == "Chapel" }) {
            failures.append("room list did not travel with the Mac")
        }
        return failures
    }

    private static func roomIsolationCheck() -> String? {
        guard let leftControl = try? UDPSocket(port: 0),
              let leftMIDI = try? UDPSocket(port: leftControl.port &+ 1),
              let rightControl = try? UDPSocket(port: 0),
              let rightMIDI = try? UDPSocket(port: rightControl.port &+ 1),
              let leftAddress = UDPAddress.ipv4("127.0.0.1", port: leftControl.port),
              let rightAddress = UDPAddress.ipv4("127.0.0.1", port: rightControl.port) else {
            return "could not open room ports"
        }
        let left = MIDISession(localName: "Mac A", localUUID: "00000000-0000-0000-0000-000000000001", control: leftControl, midi: leftMIDI, roomID: "sanctuary-1")
        let right = MIDISession(localName: "Mac B", localUUID: "ffffffff-ffff-ffff-ffff-ffffffffffff", control: rightControl, midi: rightMIDI, roomID: "sanctuary-2")
        let received = Received()
        right.onMIDI = { received.append($0) }
        left.onMIDI = { received.appendReturn($0) }
        left.start()
        right.start()
        left.setRoom("sanctuary-1")
        right.setRoom("sanctuary-2")
        left.updateDiscovered([DiscoveredPeer(uuid: right.localUUID, name: "Mac B", address: rightAddress)])
        right.updateDiscovered([DiscoveredPeer(uuid: left.localUUID, name: "Mac A", address: leftAddress)])
        let connected = waitUntil(2.5) {
            left.snapshots().contains(where: \.isReachable) || right.snapshots().contains(where: \.isReachable)
        }
        let note = Data([0x90, 70, 40])
        left.broadcast(note)
        right.broadcast(note)
        _ = waitUntil(0.4) { false }
        let leaked = received.contains(note) || received.containsReturn(note)
        left.stop()
        right.stop()
        if connected { return "sanctuary rooms connected to each other" }
        if leaked { return "midi crossed between rooms" }
        return nil
    }

    private static func roomChangeCheck() -> String? {
        guard let leftControl = try? UDPSocket(port: 0),
              let leftMIDI = try? UDPSocket(port: leftControl.port &+ 1),
              let rightControl = try? UDPSocket(port: 0),
              let rightMIDI = try? UDPSocket(port: rightControl.port &+ 1),
              let leftAddress = UDPAddress.ipv4("127.0.0.1", port: leftControl.port),
              let rightAddress = UDPAddress.ipv4("127.0.0.1", port: rightControl.port) else {
            return "could not open room-change ports"
        }
        let left = MIDISession(localName: "Mac A", localUUID: "00000000-0000-0000-0000-000000000001", control: leftControl, midi: leftMIDI, roomID: "sanctuary-1")
        let right = MIDISession(localName: "Mac B", localUUID: "ffffffff-ffff-ffff-ffff-ffffffffffff", control: rightControl, midi: rightMIDI, roomID: "sanctuary-1")
        let received = Received()
        right.onMIDI = { received.append($0) }
        left.start()
        right.start()
        left.updateDiscovered([DiscoveredPeer(uuid: right.localUUID, name: "Mac B", address: rightAddress)])
        right.updateDiscovered([DiscoveredPeer(uuid: left.localUUID, name: "Mac A", address: leftAddress)])
        guard waitUntil(4, {
            left.snapshots().contains(where: \.isReachable) && right.snapshots().contains(where: \.isReachable)
        }) else {
            let detail = "left=\(left.debugSummary()) right=\(right.debugSummary())"
            left.stop()
            right.stop()
            return "same room did not connect (\(detail))"
        }
        right.setRoom("sanctuary-2")
        guard waitUntil(2, {
            !left.snapshots().contains(where: \.isReachable) && !right.snapshots().contains(where: \.isReachable)
        }) else {
            left.stop()
            right.stop()
            return "changing rooms left the Macs connected"
        }
        let note = Data([0x90, 71, 40])
        left.broadcast(note)
        _ = waitUntil(0.4) { false }
        let leaked = received.count(of: note) > 0
        left.stop()
        right.stop()
        if leaked { return "midi kept flowing after the room change" }
        return nil
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
