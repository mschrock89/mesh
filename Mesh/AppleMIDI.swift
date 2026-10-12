import Foundation

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}

enum AppleMIDIClock {
    private static let numer: UInt64 = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return UInt64(info.numer)
    }()

    private static let denom: UInt64 = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return max(UInt64(info.denom), 1)
    }()

    /// Apple network MIDI timestamps count 100-microsecond ticks.
    static func now() -> UInt64 {
        let nanos = mach_absolute_time() * numer / denom
        return nanos / 100_000
    }
}

enum AppleMIDI {
    static let signature: UInt16 = 0xFFFF
    static let version: UInt32 = 2

    enum Command: UInt16 {
        case invitation = 0x494E
        case accepted = 0x4F4B
        case rejected = 0x4E4F
        case exit = 0x4259
        case synchronization = 0x434B
        case feedback = 0x5253
    }

    struct Exchange {
        var command: Command
        var token: UInt32
        var ssrc: UInt32
        var name: String
    }

    struct Sync {
        var ssrc: UInt32
        var count: UInt8
        var timestamp1: UInt64
        var timestamp2: UInt64
        var timestamp3: UInt64
    }

    struct MIDIPayload {
        var sequence: UInt16
        var timestamp: UInt32
        var ssrc: UInt32
        var midi: Data
    }

    enum Packet {
        case exchange(Exchange)
        case sync(Sync)
        case feedback(ssrc: UInt32, sequence: UInt16)
        case midi(MIDIPayload)
    }

    static func encodeExchange(_ message: Exchange) -> Data {
        var data = Data()
        data.appendBE(signature)
        data.appendBE(message.command.rawValue)
        data.appendBE(version)
        data.appendBE(message.token)
        data.appendBE(message.ssrc)
        if message.command == .invitation || message.command == .accepted {
            var name = Array(message.name.utf8.prefix(63))
            name.append(0)
            data.append(contentsOf: name)
        }
        return data
    }

    static func encodeSync(_ message: Sync) -> Data {
        var data = Data()
        data.appendBE(signature)
        data.appendBE(Command.synchronization.rawValue)
        data.appendBE(message.ssrc)
        data.append(message.count)
        data.append(contentsOf: [0, 0, 0])
        data.appendBE(message.timestamp1)
        data.appendBE(message.timestamp2)
        data.appendBE(message.timestamp3)
        return data
    }

    static func encodeMIDI(sequence: UInt16, timestamp: UInt32, ssrc: UInt32, midi: Data) -> Data {
        var data = Data()
        data.append(0x80)
        data.append(0xE1)
        data.appendBE(sequence)
        data.appendBE(timestamp)
        data.appendBE(ssrc)
        let length = min(midi.count, 4095)
        if length < 16 {
            data.append(UInt8(length))
        } else {
            data.append(0x80 | UInt8((length >> 8) & 0x0F))
            data.append(UInt8(length & 0xFF))
        }
        data.append(midi.prefix(length))
        return data
    }

    static func decode(_ data: Data) -> Packet? {
        guard data.count >= 4, let signature: UInt16 = readBE(data, 0), signature == Self.signature else {
            return decodeMIDI(data)
        }
        guard let raw: UInt16 = readBE(data, 2), let command = Command(rawValue: raw) else { return nil }
        switch command {
        case .synchronization:
            return decodeSync(data).map(Packet.sync)
        case .feedback:
            return decodeFeedback(data)
        default:
            return decodeExchange(data, command: command).map(Packet.exchange)
        }
    }

    private static func decodeExchange(_ data: Data, command: Command) -> Exchange? {
        guard data.count >= 16,
              let token: UInt32 = readBE(data, 8),
              let ssrc: UInt32 = readBE(data, 12) else { return nil }
        return Exchange(command: command, token: token, ssrc: ssrc, name: readName(data, 16))
    }

    private static func decodeSync(_ data: Data) -> Sync? {
        guard data.count >= 36,
              let ssrc: UInt32 = readBE(data, 4),
              let timestamp1: UInt64 = readBE(data, 12),
              let timestamp2: UInt64 = readBE(data, 20),
              let timestamp3: UInt64 = readBE(data, 28) else { return nil }
        return Sync(
            ssrc: ssrc,
            count: data[8],
            timestamp1: timestamp1,
            timestamp2: timestamp2,
            timestamp3: timestamp3
        )
    }

    private static func decodeFeedback(_ data: Data) -> Packet? {
        guard data.count >= 12,
              let ssrc: UInt32 = readBE(data, 4),
              let sequence: UInt16 = readBE(data, 8) else { return nil }
        return .feedback(ssrc: ssrc, sequence: sequence)
    }

    private static func decodeMIDI(_ data: Data) -> Packet? {
        guard data.count >= 13, data[0] >> 6 == 2, data[1] & 0x7F == 0x61 else { return nil }
        guard let sequence: UInt16 = readBE(data, 2),
              let timestamp: UInt32 = readBE(data, 4),
              let ssrc: UInt32 = readBE(data, 8) else { return nil }
        let header = data[12]
        let length: Int
        let start: Int
        if header & 0x80 != 0 {
            guard data.count >= 14 else { return nil }
            length = (Int(header & 0x0F) << 8) | Int(data[13])
            start = 14
        } else {
            length = Int(header & 0x0F)
            start = 13
        }
        guard data.count >= start + length else { return nil }
        let midi = length == 0 ? Data() : data.subdata(in: start..<(start + length))
        return .midi(MIDIPayload(sequence: sequence, timestamp: timestamp, ssrc: ssrc, midi: midi))
    }

    private static func readName(_ data: Data, _ offset: Int) -> String {
        guard offset < data.count else { return "" }
        let bytes = data[offset...].prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func readBE<T: FixedWidthInteger>(_ data: Data, _ offset: Int) -> T? {
        let size = MemoryLayout<T>.size
        guard offset >= 0, offset + size <= data.count else { return nil }
        let end = offset + size
        let loaded = data[offset..<end].withUnsafeBytes { $0.loadUnaligned(as: T.self) }
        return T(bigEndian: loaded)
    }
}
