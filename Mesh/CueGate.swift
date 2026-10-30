import Foundation

struct CuePolicy: Equatable {
    var sends = true
    var receives = true
    var blockedSources: Set<String> = []
    var blockedDestinations: Set<String> = []

    func accepts(_ uuid: String) -> Bool {
        let id = uuid.lowercased()
        return id.isEmpty || !blockedSources.contains(id)
    }

    func delivers(to uuid: String) -> Bool {
        let id = uuid.lowercased()
        return id.isEmpty || !blockedDestinations.contains(id)
    }
}

struct CueOrigin: Equatable {
    var uuid: String
    var sends: Bool
    var receives: Bool
}

/// Notes and ordinary controllers. Clock, active sensing, and channel-mode
/// resets are what a port sends when something merely opens it.
enum CueBytes {
    static func audible(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var output = Data()
        var index = 0
        var running: UInt8 = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte >= 0xF8 {
                index += 1
                continue
            }
            if byte == 0xF0 {
                output.append(byte)
                index += 1
                while index < bytes.count {
                    let next = bytes[index]
                    if next >= 0xF8 {
                        index += 1
                        continue
                    }
                    output.append(next)
                    index += 1
                    if next == 0xF7 { break }
                }
                running = 0
                continue
            }
            if byte >= 0xF0 {
                index += systemCommonLength(byte)
                running = 0
                continue
            }

            let status: UInt8
            let dataStart: Int
            if byte >= 0x80 {
                status = byte
                running = byte
                dataStart = index + 1
            } else if running >= 0x80 && running < 0xF0 {
                status = running
                dataStart = index
            } else {
                index += 1
                continue
            }
            let dataLength = status & 0xF0 == 0xC0 || status & 0xF0 == 0xD0 ? 1 : 2
            guard dataStart + dataLength <= bytes.count else { break }
            let first = bytes[dataStart]
            let channelMode = status & 0xF0 == 0xB0 && first >= 120
            if !channelMode {
                output.append(status)
                output.append(contentsOf: bytes[dataStart..<(dataStart + dataLength)])
            }
            index = dataStart + dataLength
        }
        return output
    }

    private static func systemCommonLength(_ status: UInt8) -> Int {
        switch status {
        case 0xF1, 0xF3: return 2
        case 0xF2: return 3
        default: return 1
        }
    }
}

final class CueStore {
    private let defaults: UserDefaults
    private let key = "mesh.cues.v1"
    private(set) var policy: CuePolicy

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            policy = saved.policy
        } else {
            #if os(macOS)
            policy = CuePolicy(sends: true, receives: true)
            #else
            policy = CuePolicy(sends: false, receives: true)
            #endif
        }
    }

    func setSends(_ on: Bool) {
        policy.sends = on
        save()
    }

    func setReceives(_ on: Bool) {
        policy.receives = on
        save()
    }

    func setAccepts(_ on: Bool, from uuid: String) {
        let id = uuid.lowercased()
        guard !id.isEmpty else { return }
        if on {
            policy.blockedSources.remove(id)
        } else {
            policy.blockedSources.insert(id)
        }
        save()
    }

    func setDelivers(_ on: Bool, to uuid: String) {
        let id = uuid.lowercased()
        guard !id.isEmpty else { return }
        if on {
            policy.blockedDestinations.remove(id)
        } else {
            policy.blockedDestinations.insert(id)
        }
        save()
    }

    private func save() {
        let saved = Saved(policy)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        defaults.set(data, forKey: key)
    }

    private struct Saved: Codable {
        var sends: Bool
        var receives: Bool
        var blockedSources: [String]
        var blockedDestinations: [String]

        init(_ policy: CuePolicy) {
            sends = policy.sends
            receives = policy.receives
            blockedSources = policy.blockedSources.sorted()
            blockedDestinations = policy.blockedDestinations.sorted()
        }

        var policy: CuePolicy {
            CuePolicy(
                sends: sends,
                receives: receives,
                blockedSources: Set(blockedSources),
                blockedDestinations: Set(blockedDestinations)
            )
        }
    }
}
