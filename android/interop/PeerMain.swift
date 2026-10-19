import Darwin
import Foundation

@main
struct PeerMain {
    static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let arguments = CommandLine.arguments
        let peerName = arguments.count > 1 ? arguments[1] : "Mac"
        let peerUUID = arguments.count > 2 ? arguments[2] : "ffffffff-ffff-ffff-ffff-ffffffffffff"
        let peerRoom = arguments.count > 3 ? arguments[3] : "sanctuary-1"

        guard let control = try? UDPSocket(port: 0),
              let midi = try? UDPSocket(port: control.port &+ 1) else {
            fputs("FAIL ports\n", stderr)
            exit(1)
        }

        let session = MIDISession(
            localName: peerName,
            localUUID: peerUUID,
            control: control,
            midi: midi,
            roomID: peerRoom
        )
        session.onMIDI = { data in
            print("MIDI \(data.map { String(format: "%02X", $0) }.joined())")
        }
        session.onChange = { peers in
            let connected = peers.filter { $0.status == .connected }.count
            print("UP \(connected)")
        }
        session.start()
        print("READY \(control.port)")

        while let line = readLine(strippingNewline: true) {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let command = parts.first else { continue }
            switch command {
            case "PEER":
                guard parts.count == 5,
                      let port = UInt16(parts[4]),
                      let address = UDPAddress.ipv4(parts[3], port: port) else { continue }
                session.updateDiscovered([
                    DiscoveredPeer(uuid: parts[1], name: parts[2], address: address)
                ])
            case "SEND":
                guard parts.count == 2, let data = hexData(parts[1]) else { continue }
                session.broadcast(data)
            case "SNAP":
                print("SNAP \(session.debugSummary())")
            case "QUIT":
                session.stop()
                exit(0)
            default:
                break
            }
        }
        session.stop()
    }
}

private func hexData(_ hex: String) -> Data? {
    guard hex.count % 2 == 0 else { return nil }
    var data = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
        data.append(byte)
        index = next
    }
    return data
}
