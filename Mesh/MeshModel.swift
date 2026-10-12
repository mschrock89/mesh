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

    var connectedCount: Int {
        peers.filter { $0.status == .connected }.count
    }

    private let engine = MeshEngine()
    private var didStart = false
    private let loginDefaultsKey = "mesh.didApplyLoginDefault"

    func start() {
        guard !didStart else { return }
        didStart = true
        engine.onUpdate = { [weak self] snapshot in
            DispatchQueue.main.async {
                self?.apply(snapshot)
            }
        }
        engine.start()
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
        let connected = snapshot.peers.filter { $0.status == .connected }.count
        if let error = snapshot.error {
            statusText = "Needs attention"
            detailText = error
        } else if !snapshot.ready {
            statusText = "Starting"
            detailText = "Opening the MIDI network"
        } else if connected == 0 {
            statusText = "Searching"
            detailText = "Waiting for other Macs running Mesh"
        } else if connected == 1 {
            statusText = "Connected"
            detailText = "1 Mac on this network"
        } else {
            statusText = "Connected"
            detailText = "\(connected) Macs on this network"
        }
    }
}
