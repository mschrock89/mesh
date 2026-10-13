import Foundation

struct MeshRoom: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var revision: Int64

    static let defaultID = "sanctuary-1"
    static let sanctuaries: [MeshRoom] = [
        MeshRoom(id: "sanctuary-1", name: "Sanctuary 1", revision: 1),
        MeshRoom(id: "sanctuary-2", name: "Sanctuary 2", revision: 1),
        MeshRoom(id: "sanctuary-3", name: "Sanctuary 3", revision: 1)
    ]
    static let sanctuaryIDs = Set(sanctuaries.map(\.id))

    var isSanctuary: Bool { Self.sanctuaryIDs.contains(id) }

    static func cleaned(_ raw: String) -> String? {
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(40))
    }

    static func cleanedID(_ raw: String) -> String? {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (1...80).contains(id.count) else { return nil }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-")
        guard id.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return id
    }

    static func revisionNow() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }
}

struct AnnouncedRoom: Equatable {
    var id: String
    var name: String
    var revision: Int64
}

enum RoomGate {
    static func same(_ remote: String, _ local: String) -> Bool {
        let remoteID = MeshRoom.cleanedID(remote) ?? ""
        let localID = MeshRoom.cleanedID(local) ?? ""
        return !localID.isEmpty && remoteID == localID
    }
}

enum RoomCatalogTXT {
    static func fields(selected: MeshRoom, rooms: [MeshRoom]) -> [String: String] {
        var fields = [
            "room": selected.id,
            "roomRev": String(selected.revision)
        ]
        if !selected.name.isEmpty {
            fields["roomName"] = selected.name
        }
        for (index, room) in rooms.prefix(16).enumerated() {
            fields["c\(index)"] = "\(room.id)\t\(room.name)\t\(room.revision)"
        }
        return fields
    }

    static func announced(from fields: [String: String]) -> [AnnouncedRoom] {
        var found: [AnnouncedRoom] = []
        if let id = MeshRoom.cleanedID(fields["room"] ?? ""),
           let name = MeshRoom.cleaned(fields["roomName"] ?? "") {
            found.append(AnnouncedRoom(id: id, name: name, revision: Int64(fields["roomRev"] ?? "") ?? 0))
        }
        for index in 0..<16 {
            guard let raw = fields["c\(index)"] else { continue }
            let parts = raw.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3,
                  let id = MeshRoom.cleanedID(parts[0]),
                  let name = MeshRoom.cleaned(parts[1]),
                  let revision = Int64(parts[2]) else { continue }
            found.append(AnnouncedRoom(id: id, name: name, revision: revision))
        }
        return found
    }
}

/// Rooms live in Application Support so the selected room is on disk as soon as it changes.
final class RoomStore {
    private(set) var rooms: [MeshRoom] = []
    private(set) var selectedID: String = MeshRoom.defaultID
    private(set) var elsewhere: [MeshRoom] = []
    private var suppressed: Set<String> = []
    private let defaults: UserDefaults
    private let fileURL: URL
    private static let storageKey = "mesh.rooms.v1"

    init(defaults: UserDefaults = .standard, fileURL: URL? = nil) {
        self.defaults = defaults
        self.fileURL = fileURL ?? Self.storageURL()
        load()
        repair()
        save()
    }

    var selected: MeshRoom {
        rooms.first { $0.id == selectedID } ?? MeshRoom.sanctuaries[0]
    }

    func canDelete(_ id: String) -> Bool {
        !MeshRoom.sanctuaryIDs.contains(id) && rooms.contains { $0.id == id }
    }

    @discardableResult
    func select(_ id: String) -> Bool {
        guard rooms.contains(where: { $0.id == id }), id != selectedID else { return false }
        selectedID = id
        save()
        return true
    }

    @discardableResult
    func add(named raw: String) -> MeshRoom? {
        guard let name = MeshRoom.cleaned(raw) else { return nil }
        let room = MeshRoom(id: UUID().uuidString.lowercased(), name: name, revision: MeshRoom.revisionNow())
        rooms.append(room)
        pinSanctuaries()
        save()
        return room
    }

    @discardableResult
    func rename(_ id: String, to raw: String) -> Bool {
        guard let index = rooms.firstIndex(where: { $0.id == id }) else { return false }
        guard let name = MeshRoom.cleaned(raw), name != rooms[index].name else { return false }
        rooms[index].name = name
        rooms[index].revision = MeshRoom.revisionNow()
        save()
        return true
    }

    @discardableResult
    func delete(_ id: String) -> Bool {
        guard canDelete(id), let index = rooms.firstIndex(where: { $0.id == id }) else { return false }
        rooms.remove(at: index)
        suppressed.insert(id)
        if selectedID == id {
            selectedID = rooms.first?.id ?? MeshRoom.defaultID
        }
        save()
        return true
    }

    @discardableResult
    func restore(_ id: String) -> Bool {
        guard let room = elsewhere.first(where: { $0.id == id }) else { return false }
        suppressed.remove(id)
        if !rooms.contains(where: { $0.id == id }) {
            rooms.append(room)
            pinSanctuaries()
        }
        elsewhere.removeAll { $0.id == id }
        save()
        return true
    }

    @discardableResult
    func merge(_ announced: [AnnouncedRoom]) -> Bool {
        var best: [String: AnnouncedRoom] = [:]
        for item in announced {
            guard let id = MeshRoom.cleanedID(item.id), let name = MeshRoom.cleaned(item.name) else { continue }
            let clean = AnnouncedRoom(id: id, name: name, revision: max(item.revision, 0))
            if let existing = best[id], existing.revision >= clean.revision { continue }
            best[id] = clean
        }

        var roomsChanged = false
        for item in best.values {
            if let index = rooms.firstIndex(where: { $0.id == item.id }) {
                guard item.revision > rooms[index].revision else { continue }
                if rooms[index].name != item.name {
                    rooms[index].name = item.name
                }
                rooms[index].revision = item.revision
                roomsChanged = true
            } else if !suppressed.contains(item.id) {
                rooms.append(MeshRoom(id: item.id, name: item.name, revision: item.revision))
                roomsChanged = true
            }
        }
        if roomsChanged { pinSanctuaries() }

        let nextElsewhere = best.values
            .filter { item in !rooms.contains(where: { $0.id == item.id }) }
            .map { MeshRoom(id: $0.id, name: $0.name, revision: $0.revision) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let elsewhereChanged = nextElsewhere != elsewhere
        elsewhere = nextElsewhere
        if roomsChanged { save() }
        return roomsChanged || elsewhereChanged
    }

    private func load() {
        let data = (try? Data(contentsOf: fileURL)) ?? defaults.data(forKey: Self.storageKey)
        guard let data, let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        rooms = snapshot.rooms
        selectedID = snapshot.selectedID
        suppressed = Set(snapshot.suppressed)
    }

    private func repair() {
        rooms = rooms.compactMap { room in
            guard let id = MeshRoom.cleanedID(room.id), let name = MeshRoom.cleaned(room.name) else { return nil }
            return MeshRoom(id: id, name: name, revision: room.revision)
        }
        var seen = Set<String>()
        rooms = rooms.filter { seen.insert($0.id).inserted }
        for sanctuary in MeshRoom.sanctuaries where !rooms.contains(where: { $0.id == sanctuary.id }) {
            rooms.append(sanctuary)
        }
        pinSanctuaries()
        suppressed.subtract(MeshRoom.sanctuaryIDs)
        if !rooms.contains(where: { $0.id == selectedID }) {
            selectedID = MeshRoom.defaultID
        }
    }

    private func pinSanctuaries() {
        let builtIn = MeshRoom.sanctuaries.compactMap { sanctuary in rooms.first { $0.id == sanctuary.id } }
        let custom = rooms.filter { !MeshRoom.sanctuaryIDs.contains($0.id) }
        rooms = builtIn + custom
    }

    private func save() {
        let snapshot = Snapshot(rooms: rooms, selectedID: selectedID, suppressed: suppressed.sorted())
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.storageKey)
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func storageURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Mesh/rooms.json")
    }

    private struct Snapshot: Codable {
        var rooms: [MeshRoom]
        var selectedID: String
        var suppressed: [String]
    }
}
