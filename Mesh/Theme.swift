import AppKit
import SwiftUI

enum Theme {
    static let background = Color(red: 0.071, green: 0.078, blue: 0.086)
    static let card = Color(red: 0.110, green: 0.118, blue: 0.129)
    static let blue = Color(red: 0.208, green: 0.690, blue: 0.898)
    static let blueDark = Color(red: 0.153, green: 0.455, blue: 0.616)
    static let teal = Color(red: 0.0, green: 0.553, blue: 0.702)
    static let yellow = Color(red: 1.0, green: 0.722, blue: 0.220)
    static let muted = Color.white.opacity(0.68)
    static let faint = Color.white.opacity(0.42)
    static let border = Color(red: 0.2, green: 0.2, blue: 0.2)
    static let nsBackground = NSColor(srgbRed: 0.071, green: 0.078, blue: 0.086, alpha: 1)

    static func display(_ size: CGFloat) -> Font {
        .custom("Avenir Next Demi Bold", size: size)
    }

    static func body(_ size: CGFloat) -> Font {
        .custom("Avenir Next", size: size)
    }

    static func medium(_ size: CGFloat) -> Font {
        .custom("Avenir Next Medium", size: size)
    }
}

struct WindowBackground: NSViewRepresentable {
    var color: NSColor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { paint(view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { paint(nsView) }
    }

    private func paint(_ view: NSView) {
        guard let window = view.window else { return }
        window.backgroundColor = color
        window.isOpaque = true
        window.titlebarAppearsTransparent = true
    }
}
