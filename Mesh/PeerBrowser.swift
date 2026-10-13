import Foundation
import os

final class PeerBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onPeers: (([DiscoveredPeer]) -> Void)?
    var onRooms: (([AnnouncedRoom]) -> Void)?
    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]
    private var resolved: [String: ResolvedService] = [:]
    private let localUUID: String
    private let localPort: UInt16
    private let localIPs: Set<UInt32>
    private var roomID: String
    private let log = Logger(subsystem: "com.mitchellschrock.Mesh", category: "bonjour")

    init(localUUID: String, localPort: UInt16, roomID: String) {
        self.localUUID = localUUID.lowercased()
        self.localPort = localPort
        self.localIPs = LocalAddresses.ipv4()
        self.roomID = MeshRoom.cleanedID(roomID) ?? MeshRoom.defaultID
        super.init()
    }

    func setRoom(_ roomID: String) {
        self.roomID = MeshRoom.cleanedID(roomID) ?? MeshRoom.defaultID
        emit()
    }

    func start() {
        browser.delegate = self
        browser.schedule(in: .main, forMode: .common)
        browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
    }

    func restart() {
        browser.stop()
        services.removeAll()
        resolved.removeAll()
        emit()
        browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        services[service.name] = service
        service.resolve(withTimeout: 8)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        services.removeValue(forKey: service.name)
        resolved.removeValue(forKey: service.name)
        emit()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        log.error("Bonjour search failed: \(String(describing: errorDict), privacy: .public)")
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        remember(sender, txt: sender.txtRecordData() ?? Data())
    }

    func netService(_ sender: NetService, didUpdateTXTRecord data: Data) {
        remember(sender, txt: data)
    }

    private func remember(_ sender: NetService, txt: Data) {
        let addresses = ipv4s(from: sender)
        guard let address = addresses.first else { return }
        let record = NetService.dictionary(fromTXTRecord: txt)
        let uuid = record["id"].flatMap { String(data: $0, encoding: .utf8) }?.lowercased() ?? ""
        if !uuid.isEmpty && uuid == localUUID { return }
        if address.port == localPort && localIPs.contains(address.ip) { return }
        let text = record.reduce(into: [String: String]()) { fields, item in
            guard let value = String(data: item.value, encoding: .utf8) else { return }
            fields[item.key] = value
        }
        let room = MeshRoom.cleanedID(text["room"] ?? "") ?? ""
        guard !room.isEmpty else {
            resolved.removeValue(forKey: sender.name)
            emit()
            return
        }
        resolved[sender.name] = ResolvedService(
            peer: DiscoveredPeer(uuid: uuid, name: sender.name, address: address, addresses: addresses),
            roomID: room,
            announced: RoomCatalogTXT.announced(from: text)
        )
        emit()
    }

    private func emit() {
        let peers = resolved.values
            .filter { $0.roomID == roomID }
            .map(\.peer)
        onPeers?(peers)
        var best: [String: AnnouncedRoom] = [:]
        for item in resolved.values {
            for announced in item.announced where !announced.name.isEmpty {
                if let existing = best[announced.id], existing.revision >= announced.revision { continue }
                best[announced.id] = announced
            }
        }
        onRooms?(Array(best.values))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        log.error("Could not resolve \(sender.name, privacy: .public)")
    }

    private func ipv4s(from service: NetService) -> [UDPAddress] {
        guard let addresses = service.addresses else { return [] }
        var found: [UDPAddress] = []
        for data in addresses {
            guard data.count >= MemoryLayout<sockaddr_in>.size else { continue }
            var storage = sockaddr_in()
            let copied = withUnsafeMutableBytes(of: &storage) { destination in
                data.copyBytes(to: destination)
            }
            guard copied >= MemoryLayout<sockaddr_in>.size else { continue }
            guard storage.sin_family == UInt8(AF_INET) else { continue }
            let port = UInt16(bigEndian: storage.sin_port)
            guard port > 0 else { continue }
            let address = UDPAddress(ip: storage.sin_addr.s_addr, port: port)
            guard LocalAddresses.rank(ip: address.ip) < 100 else { continue }
            if !found.contains(address) {
                found.append(address)
            }
        }
        return found.sorted { LocalAddresses.rank(ip: $0.ip) < LocalAddresses.rank(ip: $1.ip) }
    }

    static let serviceType = "_mesh-midi._udp."
}

private struct ResolvedService {
    var peer: DiscoveredPeer
    var roomID: String
    var announced: [AnnouncedRoom]
}

final class ServicePublisher: NSObject, NetServiceDelegate {
    private var service: NetService
    private let port: Int32
    private let uuid: String
    private var catalog: [MeshRoom]
    private var selected: MeshRoom
    private var retried = false
    private let log = Logger(subsystem: "com.mitchellschrock.Mesh", category: "bonjour")

    init(name: String, port: Int32, uuid: String, selected: MeshRoom, catalog: [MeshRoom]) {
        self.port = port
        self.uuid = uuid
        self.selected = selected
        self.catalog = catalog
        service = NetService(domain: "local.", type: PeerBrowser.serviceType, name: name, port: port)
        super.init()
        prepare(service)
    }

    func update(selected: MeshRoom, catalog: [MeshRoom]) {
        self.selected = selected
        self.catalog = catalog
        applyTXT(service)
    }

    func publish() {
        service.schedule(in: .main, forMode: .common)
        service.publish()
    }

    func netServiceDidPublish(_ sender: NetService) {
        log.info("Published \(sender.name, privacy: .public) on port \(sender.port)")
        print("Mesh published \(sender.name) on port \(sender.port)")
    }

    func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict["NSNetServicesErrorCode"]?.intValue ?? 0
        if code == -72001 && !retried {
            retried = true
            let renamed = "\(sender.name) \(uuid.prefix(4))"
            service = NetService(domain: "local.", type: PeerBrowser.serviceType, name: renamed, port: port)
            prepare(service)
            publish()
            return
        }
        log.error("Publish failed: \(String(describing: errorDict), privacy: .public)")
        print("Mesh could not publish on the network: \(errorDict)")
    }

    private func prepare(_ service: NetService) {
        applyTXT(service)
        service.delegate = self
    }

    private func applyTXT(_ service: NetService) {
        var fields = RoomCatalogTXT.fields(selected: selected, rooms: catalog).mapValues { Data($0.utf8) }
        fields["id"] = Data(uuid.utf8)
        service.setTXTRecord(NetService.data(fromTXTRecord: fields))
    }
}
