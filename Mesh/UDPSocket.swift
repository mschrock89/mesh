import Darwin
import Foundation

struct UDPAddress: Hashable {
    var ip: UInt32
    var port: UInt16

    var key: String { "\(presentation):\(port)" }

    var presentation: String {
        var addr = in_addr(s_addr: ip)
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &addr, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }

    func withPort(_ port: UInt16) -> UDPAddress {
        UDPAddress(ip: ip, port: port)
    }

    static func ipv4(_ string: String, port: UInt16) -> UDPAddress? {
        var addr = in_addr()
        guard inet_pton(AF_INET, string, &addr) == 1 else { return nil }
        return UDPAddress(ip: addr.s_addr, port: port)
    }
}

enum LocalAddresses {
    static func ipv4() -> Set<UInt32> {
        var found = Set<UInt32>()
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return found }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            if let sa = current.pointee.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) {
                let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                found.insert(sin.sin_addr.s_addr)
            }
            cursor = current.pointee.ifa_next
        }
        return found
    }

    /// Lower is better. Loopback and multicast are unusable for a peer.
    static func rank(ip: UInt32) -> Int {
        let firstOctet = ip & 0xFF
        if ip == 0 || firstOctet == 127 || firstOctet >= 224 { return 100 }
        let linkLocal = (ip & 0xFFFF) == 0xFEA9
        if sharesSubnet(ip) && !linkLocal { return 0 }
        if linkLocal { return 40 }
        return 20
    }

    private static func sharesSubnet(_ ip: UInt32) -> Bool {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return false }
        defer { freeifaddrs(first) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            if let sa = current.pointee.ifa_addr,
               sa.pointee.sa_family == UInt8(AF_INET),
               let maskPointer = current.pointee.ifa_netmask {
                let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let mask = maskPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                let bits = mask.sin_addr.s_addr
                if bits != 0 && (ip & bits) == (sin.sin_addr.s_addr & bits) {
                    return true
                }
            }
            cursor = current.pointee.ifa_next
        }
        return false
    }
}

enum UDPError: Error {
    case socket
    case bind
}

final class UDPSocket {
    let fd: Int32
    let port: UInt16
    var onPacket: ((Data, UDPAddress) -> Void)?
    private let source: DispatchSourceRead
    private var didClose = false

    init(port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw UDPError.socket }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = in_addr_t(0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                bind(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw UDPError.bind
        }
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                getsockname(fd, sa, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw UDPError.bind
        }
        self.fd = fd
        self.port = UInt16(bigEndian: actual.sin_port)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue.global(qos: .userInteractive))
        self.source = source
        source.setEventHandler { [weak self] in
            self?.drain()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
    }

    deinit {
        closeSocket()
    }

    func closeSocket() {
        guard !didClose else { return }
        didClose = true
        source.cancel()
    }

    func send(_ data: Data, to address: UDPAddress) {
        guard !didClose else { return }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = address.port.bigEndian
        addr.sin_addr.s_addr = address.ip
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    _ = sendto(fd, base, buffer.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    static func bindPair(startingAt start: UInt16 = 5004) throws -> (UDPSocket, UDPSocket) {
        var port = start
        let limit = start &+ 400
        while port < limit {
            if let control = try? UDPSocket(port: port) {
                if let midi = try? UDPSocket(port: port &+ 1) {
                    return (control, midi)
                }
                control.closeSocket()
            }
            port &+= 1
        }
        throw UDPError.bind
    }

    private func drain() {
        while true {
            var buffer = [UInt8](repeating: 0, count: 4096)
            var addr = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                withUnsafeMutablePointer(to: &addr) { addrPointer in
                    addrPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                        recvfrom(fd, raw.baseAddress, raw.count, 0, sa, &length)
                    }
                }
            }
            if count <= 0 { return }
            let data = Data(buffer.prefix(count))
            let from = UDPAddress(ip: addr.sin_addr.s_addr, port: UInt16(bigEndian: addr.sin_port))
            onPacket?(data, from)
        }
    }
}
