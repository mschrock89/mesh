import Foundation
import os

final class PeerBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    var onPeers: (([DiscoveredPeer]) -> Void)?
    private let browser = NetServiceBrowser()
    private var services: [String: NetService] = [:]
    private var peers: [String: DiscoveredPeer] = [:]
    private let localUUID: String
    private let localPort: UInt16
    private let localIPs: Set<UInt32>
    private let log = Logger(subsystem: "com.mitchellschrock.Mesh", category: "bonjour")

    init(localUUID: String, localPort: UInt16) {
        self.localUUID = localUUID.lowercased()
        self.localPort = localPort
        self.localIPs = LocalAddresses.ipv4()
        super.init()
    }

    func start() {
        browser.delegate = self
        browser.schedule(in: .main, forMode: .common)
        browser.searchForServices(ofType: Self.serviceType, inDomain: "local.")
    }

    func restart() {
        browser.stop()
        services.removeAll()
        peers.removeAll()
        onPeers?([])
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
        peers.removeValue(forKey: service.name)
        onPeers?(Array(peers.values))
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        log.error("Bonjour search failed: \(String(describing: errorDict), privacy: .public)")
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let address = ipv4(from: sender) else { return }
        let record = NetService.dictionary(fromTXTRecord: sender.txtRecordData() ?? Data())
        let uuid = record["id"].flatMap { String(data: $0, encoding: .utf8) }?.lowercased()
            ?? "name:\(sender.name.lowercased())"
        if uuid == localUUID { return }
        if address.port == localPort && localIPs.contains(address.ip) { return }
        peers[sender.name] = DiscoveredPeer(uuid: uuid, name: sender.name, address: address)
        onPeers?(Array(peers.values))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        log.error("Could not resolve \(sender.name, privacy: .public)")
    }

    private func ipv4(from service: NetService) -> UDPAddress? {
        guard let addresses = service.addresses else { return nil }
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
            return UDPAddress(ip: storage.sin_addr.s_addr, port: port)
        }
        return nil
    }

    static let serviceType = "_mesh-midi._udp."
}

final class ServicePublisher: NSObject, NetServiceDelegate {
    private var service: NetService
    private let port: Int32
    private let uuid: String
    private var retried = false
    private let log = Logger(subsystem: "com.mitchellschrock.Mesh", category: "bonjour")

    init(name: String, port: Int32, uuid: String) {
        self.port = port
        self.uuid = uuid
        service = NetService(domain: "local.", type: PeerBrowser.serviceType, name: name, port: port)
        super.init()
        prepare(service)
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
        let record = NetService.data(fromTXTRecord: ["id": Data(uuid.utf8)])
        service.setTXTRecord(record)
        service.delegate = self
    }
}
