import AppKit
import CoreMIDI
import Foundation
import Network
import os

final class MeshEngine {
    struct Snapshot: Equatable {
        var localName: String
        var port: UInt16
        var peers: [PeerSnapshot]
        var ready: Bool
        var error: String?
    }

    var onUpdate: ((Snapshot) -> Void)?

    private let localName: String
    private let localUUID: String
    private var control: UDPSocket?
    private var midiSocket: UDPSocket?
    private var session: MIDISession?
    private var browser: PeerBrowser?
    private var publisher: ServicePublisher?
    private var client = MIDIClientRef()
    private var source = MIDIEndpointRef()
    private var pathMonitor: NWPathMonitor?
    private var networkUp = true
    private let log = Logger(subsystem: "com.mitchellschrock.Mesh", category: "engine")

    init() {
        let savedKey = "mesh.peerID"
        if let saved = UserDefaults.standard.string(forKey: savedKey) {
            localUUID = saved.lowercased()
        } else {
            let created = UUID().uuidString.lowercased()
            UserDefaults.standard.set(created, forKey: savedKey)
            localUUID = created
        }
        localName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    }

    func start() {
        let pair: (UDPSocket, UDPSocket)
        do {
            pair = try UDPSocket.bindPair()
        } catch {
            emit(peers: [], ready: false, error: "Mesh couldn't open a network port.")
            return
        }
        control = pair.0
        midiSocket = pair.1

        let session = MIDISession(
            localName: localName,
            localUUID: localUUID,
            control: pair.0,
            midi: pair.1
        )
        session.onMIDI = { [weak self] data in
            self?.inject(data)
        }
        session.onChange = { [weak self] peers in
            self?.emit(peers: peers, ready: true, error: nil)
        }
        session.start()
        self.session = session

        if !createMIDIPorts(session: session) {
            emit(peers: [], ready: false, error: "Mesh couldn't create its MIDI port.")
            return
        }

        emit(peers: [], ready: true, error: nil)
        print("Mesh ready · \(localName) · port \(pair.0.port)")
        log.info("Mesh ready on port \(pair.0.port, privacy: .public)")

        DispatchQueue.main.async { [weak self] in
            self?.startDiscovery()
            self?.watchSystem()
        }
    }

    func reconnect() {
        session?.reconnect()
        DispatchQueue.main.async { [weak self] in
            self?.browser?.restart()
        }
    }

    private func startDiscovery() {
        guard let control else { return }
        let browser = PeerBrowser(localUUID: localUUID, localPort: control.port)
        browser.onPeers = { [weak self] peers in
            self?.session?.updateDiscovered(peers)
        }
        browser.start()
        self.browser = browser

        let publisher = ServicePublisher(name: localName, port: Int32(control.port), uuid: localUUID)
        publisher.publish()
        self.publisher = publisher
    }

    private func watchSystem() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            self?.session?.suspend()
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self?.browser?.restart()
                self?.session?.resume()
            }
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied
            if satisfied && !self.networkUp {
                self.session?.resume()
            } else if !satisfied && self.networkUp {
                self.session?.suspend()
            }
            self.networkUp = satisfied
        }
        monitor.start(queue: DispatchQueue(label: "mesh.path"))
        pathMonitor = monitor
    }

    private func createMIDIPorts(session: MIDISession) -> Bool {
        var client = MIDIClientRef()
        var status = MIDIClientCreate("Mesh" as CFString, nil, nil, &client)
        guard status == noErr else {
            log.error("MIDIClientCreate failed: \(status)")
            return false
        }
        self.client = client

        var source = MIDIEndpointRef()
        status = MIDISourceCreate(client, "Mesh" as CFString, &source)
        guard status == noErr else {
            log.error("MIDISourceCreate failed: \(status)")
            return false
        }
        self.source = source

        var destination = MIDIEndpointRef()
        status = MIDIDestinationCreateWithBlock(client, "Mesh" as CFString, &destination) { [weak self] packetList, _ in
            guard let self else { return }
            for bytes in MIDIBytes.collect(packetList) {
                self.session?.broadcast(bytes)
            }
        }
        guard status == noErr else {
            log.error("MIDIDestinationCreate failed: \(status)")
            return false
        }
        return true
    }

    private func inject(_ data: Data) {
        guard !data.isEmpty, source != 0 else { return }
        let capacity = data.count + 512
        let raw = UnsafeMutableRawPointer.allocate(byteCount: capacity, alignment: MemoryLayout<UInt64>.alignment)
        defer { raw.deallocate() }
        memset(raw, 0, capacity)
        let list = raw.bindMemory(to: MIDIPacketList.self, capacity: 1)
        let packet = MIDIPacketListInit(list)
        var added = false
        data.withUnsafeBytes { buffer in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = MIDIPacketListAdd(list, capacity, packet, mach_absolute_time(), data.count, base)
            added = true
        }
        if added {
            MIDIReceived(source, list)
        }
    }

    private func emit(peers: [PeerSnapshot], ready: Bool, error: String?) {
        let snapshot = Snapshot(
            localName: localName,
            port: control?.port ?? 0,
            peers: peers,
            ready: ready,
            error: error
        )
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(snapshot)
        }
    }
}

enum MIDIBytes {
    static func collect(_ packetList: UnsafePointer<MIDIPacketList>) -> [Data] {
        let count = Int(packetList.pointee.numPackets)
        guard count > 0 else { return [] }
        let listOffset = MemoryLayout<MIDIPacketList>.offset(of: \.packet) ?? 0
        var pointer = UnsafeMutableRawPointer(mutating: packetList)
            .advanced(by: listOffset)
            .assumingMemoryBound(to: MIDIPacket.self)
        var result: [Data] = []
        result.reserveCapacity(count)
        for _ in 0..<count {
            let length = Int(pointer.pointee.length)
            if length > 0 {
                let dataOffset = MemoryLayout<MIDIPacket>.offset(of: \.data) ?? 0
                let bytes = UnsafeRawPointer(pointer).advanced(by: dataOffset)
                result.append(Data(bytes: bytes, count: length))
            }
            pointer = MIDIPacketNext(pointer)
        }
        return result
    }
}
