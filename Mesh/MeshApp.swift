#if os(macOS)
import AppKit
import Combine
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    let model = MeshModel()
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var iconObserver: AnyCancellable?
    private var menuBarObservers: [NSObjectProtocol] = []
    private var iconWatch: Timer?
    private var replacingStatusItem = false
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
        // SwiftUI finishes its scenes after this returns and can remove a status
        // item created here. Install on the next turn, then check that it stuck.
        DispatchQueue.main.async { [weak self] in
            self?.installStatusItem()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self?.reassertStatusItem(redraw: true, recreateIfDetached: true)
            }
        }
        model.start()
    }

    private func installStatusItem() {
        // Square length stays put when the artwork updates. A variable-width item
        // slides the open panel around, which reconnect does constantly.
        let item = makeStatusItem()
        popoverAnchor.statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        let hosting = MeshPanelController(rootView: MeshPanel(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        self.popover = popover
        popoverAnchor.popover = popover

        iconObserver = model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.reassertStatusItem(redraw: false) }
            }
        observeMenuBar()
    }

    private func makeStatusItem() -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.isVisible = true
        if let button = item.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.title = ""
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        statusItem = item
        applyIcon(force: true)
        return item
    }

    /// The menu bar drops this item on wake, display changes, and when an accessory
    /// app activates to show the panel. Put the same icon back. A healthy item is left alone.
    private func reassertStatusItem(redraw: Bool, recreateIfDetached: Bool = false) {
        guard let item = statusItem, !replacingStatusItem else { return }
        let detached = item.button == nil || (recreateIfDetached && item.button?.window == nil)
        if detached {
            replaceStatusItem()
            return
        }
        if item.length == 0 {
            item.length = NSStatusItem.squareLength
        }
        applyIcon(force: redraw)
        if popover?.isShown != true {
            item.button?.highlight(false)
        }
    }

    private func replaceStatusItem() {
        guard !replacingStatusItem else { return }
        replacingStatusItem = true
        defer { replacingStatusItem = false }
        let shown = popover?.isShown == true
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        let item = makeStatusItem()
        popoverAnchor.statusItem = item
        guard shown, let button = item.button, let popover else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popoverAnchor.watch()
    }

    private func applyIcon(force: Bool) {
        guard let button = statusItem?.button else { return }
        if button.action == nil || button.target as AnyObject !== self {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
        }
        if force || button.image == nil, let image = MenuBarIcon.image() {
            button.image = image
        }
        let tip = "Mesh · \(model.roomName)"
        if button.toolTip != tip {
            button.toolTip = tip
        }
    }

    private func observeMenuBar() {
        let workspace = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didWakeNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ]
        for name in names {
            menuBarObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.reassertStatusItem(redraw: true, recreateIfDetached: true)
            })
        }
        menuBarObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reassertStatusItem(redraw: true, recreateIfDetached: true)
        })
        menuBarObservers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reassertStatusItem(redraw: true, recreateIfDetached: true)
        })
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.reassertStatusItem(redraw: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        iconWatch = timer
    }

    func popoverDidClose(_ notification: Notification) {
        statusItem?.button?.highlight(false)
        reassertStatusItem(redraw: true)
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
            return
        }
        button.highlight(true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popoverAnchor.watch()
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        DispatchQueue.main.async { [weak self] in
            self?.reassertStatusItem(redraw: true)
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
    static func image() -> NSImage? {
        let points: CGFloat = 18
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let pixels = Int((points * scale).rounded())
        guard pixels > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixels,
                pixelsHigh: pixels,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            return nil
        }
        rep.size = NSSize(width: points, height: points)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.shouldAntialias = true
        context.cgContext.scaleBy(x: scale, y: scale)
        NSColor.black.set()

        let top = NSPoint(x: 9, y: 16)
        let left = NSPoint(x: 2.5, y: 3.5)
        let right = NSPoint(x: 15.5, y: 3.5)
        let connections = NSBezierPath()
        connections.move(to: top)
        connections.line(to: left)
        connections.line(to: right)
        connections.close()
        connections.lineWidth = 1.6
        connections.lineCapStyle = .round
        connections.lineJoinStyle = .round
        connections.setLineDash([1.2, 2.2], count: 2, phase: 0)
        connections.stroke()

        for point in [top, left, right] {
            NSBezierPath(
                ovalIn: NSRect(x: point.x - 1.7, y: point.y - 1.7, width: 3.4, height: 3.4)
            ).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: NSSize(width: points, height: points))
        image.addRepresentation(rep)
        image.isTemplate = true
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

#else
import AVFoundation
import SwiftUI
import UIKit

@main
struct MeshApp: App {
    @StateObject private var model = MeshModel()

    var body: some Scene {
        WindowGroup {
            MeshIOSRoot(model: model)
        }
    }
}

private struct MeshIOSRoot: View {
    @ObservedObject var model: MeshModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var hasBeenActive = false

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                MeshPanel(model: model)
                    .padding(.vertical, 12)
                    .frame(width: proxy.size.width)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            MeshKeepAlive.shared.start()
            model.start()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            MeshKeepAlive.shared.start()
            if hasBeenActive {
                model.noteForeground()
            }
            hasBeenActive = true
        }
    }
}

/// iOS suspends a silent app. An inaudible playback session is what keeps the
/// MIDI ports and the room connection alive with the screen locked.
final class MeshKeepAlive {
    static let shared = MeshKeepAlive()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var started = false

    private init() {
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .ended else { return }
            self?.start()
        }
    }

    func start() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            return
        }
        UIApplication.shared.isIdleTimerDisabled = true
        if started {
            if !engine.isRunning {
                try? engine.start()
            }
            if !player.isPlaying {
                player.play()
            }
            return
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410) else { return }
        buffer.frameLength = 4_410
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = 0
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        started = true
        do {
            try engine.start()
        } catch {
            return
        }
        player.play()
    }
}
#endif
