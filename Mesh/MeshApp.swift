import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MeshModel()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var iconObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--self-test") {
            let passed = SelfTest.run()
            fflush(stdout)
            exit(passed ? EXIT_SUCCESS : EXIT_FAILURE)
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.mitchellschrock.Mesh"
        let alreadyRunning = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != getpid() }
        if alreadyRunning {
            NSApp.terminate(nil)
            return
        }

        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        model.start()
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.isVisible = true
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "Mesh"
        }
        statusItem = item
        updateIcon()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        let hosting = NSHostingController(rootView: MeshPanel(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        self.popover = popover

        iconObserver = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateIcon() }
            }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol = model.connectedCount > 0
            ? "point.3.connected.trianglepath.dotted"
            : "point.3.trianglepath.dotted"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Mesh")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        image?.isTemplate = true
        button.image = image
        button.title = ""
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

@main
struct MeshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
