import Foundation
import ServiceManagement

final class MeshModel: ObservableObject {
    @Published var localName: String = Host.current().localizedName ?? "This Mac"
    @Published var port: UInt16 = 0
    @Published var peers: [PeerSnapshot] = []
    @Published var ready = false
    @Published var statusText = "Starting"
    @Published var detailText = "Opening the MIDI network"
    @Published var errorText: String?
    @Published var launchAtLogin = false
    @Published var launchAtLoginNote: String?
    @Published private(set) var rooms: [MeshRoom] = []
    @Published private(set) var roomID: String = MeshRoom.defaultID
    @Published private(set) var elsewhere: [MeshRoom] = []

    var roomName: String {
        rooms.first { $0.id == roomID }?.name ?? MeshRoom.sanctuaries[0].name
    }

    var connectedCount: Int {
        peers.filter(\.isReachable).count
    }

    private let engine = MeshEngine()
    private let roomStore: RoomStore
    private var didStart = false
    private let loginDefaultsKey = "mesh.didApplyLoginDefault"

    init() {
        let store = RoomStore()
        roomStore = store
        rooms = store.rooms
        roomID = store.selectedID
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        engine.onUpdate = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.apply(snapshot)
            }
        }
        engine.onAdvertisedRooms = { [weak self] announced in
            DispatchQueue.main.async {
                self?.applyAdvertised(announced)
            }
        }
        engine.start(room: roomStore.selected, catalog: roomStore.rooms)
        if !UserDefaults.standard.bool(forKey: loginDefaultsKey) {
            setLaunchAtLogin(true)
            let status = SMAppService.mainApp.status
            if status == .enabled || status == .requiresApproval {
                UserDefaults.standard.set(true, forKey: loginDefaultsKey)
            }
        } else {
            refreshLogin()
        }
    }

    func reconnect() {
        engine.reconnect()
    }

    func selectRoom(_ id: String) {
        guard roomStore.select(id) else { return }
        syncRooms()
        advertise()
    }

    @discardableResult
    func addRoom(named name: String) -> Bool {
        guard roomStore.add(named: name) != nil else { return false }
        syncRooms()
        advertise()
        return true
    }

    func renameRoom(_ id: String, to name: String) {
        guard roomStore.rename(id, to: name) else { return }
        syncRooms()
        advertise()
    }

    func deleteRoom(_ id: String) {
        guard roomStore.delete(id) else { return }
        syncRooms()
        advertise()
    }

    func canDeleteRoom(_ id: String) -> Bool {
        roomStore.canDelete(id)
    }

    func restoreRoom(_ id: String) {
        guard roomStore.restore(id) else { return }
        syncRooms()
        advertise()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            let service = SMAppService.mainApp
            if enabled {
                if service.status != .enabled {
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
            errorText = nil
        } catch {
            launchAtLoginNote = error.localizedDescription
        }
        refreshLogin()
    }

    func refreshLogin() {
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled || status == .requiresApproval
        if status == .requiresApproval {
            launchAtLoginNote = "Allow Mesh in System Settings → General → Login Items & Extensions."
        } else if launchAtLogin {
            launchAtLoginNote = nil
        }
    }

    private func apply(_ snapshot: MeshEngine.Snapshot) {
        localName = snapshot.localName
        port = snapshot.port
        peers = snapshot.peers
        ready = snapshot.ready
        errorText = snapshot.error
        refreshStatus(ready: snapshot.ready, error: snapshot.error, connected: snapshot.peers.filter(\.isReachable).count)
    }

    private func applyAdvertised(_ announced: [AnnouncedRoom]) {
        let beforeRooms = roomStore.rooms
        let beforeSelected = roomStore.selected
        guard roomStore.merge(announced) else { return }
        syncRooms()
        if roomStore.rooms != beforeRooms || roomStore.selected != beforeSelected {
            advertise()
        }
    }

    private func advertise() {
        engine.advertise(room: roomStore.selected, catalog: roomStore.rooms)
    }

    private func syncRooms() {
        rooms = roomStore.rooms
        roomID = roomStore.selectedID
        elsewhere = roomStore.elsewhere
        refreshStatus(ready: ready, error: errorText, connected: connectedCount)
    }

    private func refreshStatus(ready: Bool, error: String?, connected: Int) {
        if let error {
            statusText = "Needs attention"
            detailText = error
        } else if !ready {
            statusText = "Starting"
            detailText = "Opening the MIDI network"
        } else if connected == 0 {
            statusText = "Searching"
            detailText = "Waiting for other Macs in \(roomName)"
        } else if connected == 1 {
            statusText = "Connected"
            detailText = "1 Mac in \(roomName)"
        } else {
            statusText = "Connected"
            detailText = "\(connected) Macs in \(roomName)"
        }
    }
}
