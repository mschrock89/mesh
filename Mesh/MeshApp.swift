import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MeshModel()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var iconObserver: AnyCancellable?
    private let popoverAnchor = PopoverAnchor()

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
        // Square length stays put when the artwork updates. A variable-width item
        // slides the open panel around, which reconnect does constantly.
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.title = ""
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.toolTip = "Mesh"
        }
        statusItem = item
        updateIcon()

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        let hosting = MeshPanelController(rootView: MeshPanel(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        self.popover = popover
        popoverAnchor.statusItem = item
        popoverAnchor.popover = popover

        iconObserver = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateIcon() }
            }
    }

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        if button.image == nil {
            button.image = MenuBarIcon.image()
        }
        let tip = "Mesh · \(model.roomName)"
        if button.toolTip != tip {
            button.toolTip = tip
        }
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popoverAnchor.watch()
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

enum MenuBarIcon {
    /// SF Symbols never shipped `point.3.trianglepath.dotted`. That name resolved to
    /// a nil image whenever the room was idle, the status item collapsed, and the
    /// open panel followed it. The mark that does exist stays in the menu bar.
    static let symbolName = "point.3.connected.trianglepath.dotted"

    static func image() -> NSImage? {
        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Mesh")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        image?.isTemplate = true
        return image
    }
}

/// Ignores the empty and sub-pixel sizes SwiftUI reports while reconnect updates
/// the panel. Each of those was a content-size change, and the popover moved for it.
final class MeshPanelController: NSHostingController<MeshPanel> {
    private var applyingSize = false

    override var preferredContentSize: NSSize {
        get { super.preferredContentSize }
        set {
            guard !applyingSize else { return }
            guard newValue.width >= 200, newValue.height >= 100 else { return }
            let current = super.preferredContentSize
            guard abs(current.width - newValue.width) >= 1 || abs(current.height - newValue.height) >= 1 else { return }
            let rounded = NSSize(width: newValue.width.rounded(), height: newValue.height.rounded())
            applyingSize = true
            super.preferredContentSize = rounded
            applyingSize = false
        }
    }
}

enum PopoverPlacement {
    /// The panel belongs under the status item. A window that has jumped elsewhere does not.
    static func isAttached(window: CGRect, anchor: CGRect) -> Bool {
        guard anchor.width > 1, anchor.height > 1, window.width > 1, window.height > 1 else {
            return false
        }
        let overlapsStatusItem = window.minX < anchor.maxX + 8 && window.maxX > anchor.minX - 8
        let gap = anchor.minY - window.maxY
        return overlapsStatusItem && gap > -30 && gap < 30
    }
}

final class PopoverAnchor: NSObject {
    weak var popover: NSPopover?
    weak var statusItem: NSStatusItem?
    private var watched: NSWindow?
    private var tokens: [NSObjectProtocol] = []
    private var scheduled = false
    private var corrections = 0

    func watch() {
        guard let window = popover?.contentViewController?.view.window else { return }
        window.animationBehavior = .none
        guard watched !== window else {
            scheduleCorrection()
            return
        }
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens.removeAll()
        watched = window
        corrections = 0
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            tokens.append(NotificationCenter.default.addObserver(
                forName: name,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleCorrection()
            })
        }
        scheduleCorrection()
    }

    private func scheduleCorrection() {
        guard !scheduled else { return }
        scheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.scheduled = false
            self?.correctIfDetached()
        }
    }

    private func correctIfDetached() {
        guard let popover, popover.isShown,
              let button = statusItem?.button,
              let buttonWindow = button.window,
              let window = popover.contentViewController?.view.window else {
            corrections = 0
            return
        }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        guard anchor.width > 1, anchor.height > 1 else { return }
        guard !PopoverPlacement.isAttached(window: window.frame, anchor: anchor) else {
            corrections = 0
            return
        }
        guard corrections < 2 else { return }
        corrections += 1
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }
}
