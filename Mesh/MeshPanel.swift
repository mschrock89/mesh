import AppKit
import SwiftUI

struct MeshPanel: View {
    @ObservedObject var model: MeshModel
    @StateObject private var updates = AppUpdateController()

    var body: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [Theme.blue, Theme.teal], startPoint: .leading, endPoint: .trailing)
                .frame(height: 4)

            VStack(alignment: .leading, spacing: 14) {
                header
                statusCard
                peerCard
                footer
            }
            .padding(16)
        }
        .frame(width: 360)
        .fixedSize(horizontal: true, vertical: true)
        .background(Theme.background)
        .background(WindowBackground(color: Theme.nsBackground))
        .onAppear { updates.refreshOnOpen() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            MeshMark()
            VStack(alignment: .leading, spacing: 2) {
                Text("Mesh")
                    .font(Theme.display(22))
                    .foregroundStyle(.white)
                Text("NETWORK MIDI")
                    .font(Theme.medium(10))
                    .tracking(1.6)
                    .foregroundStyle(Theme.blue)
            }
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        let live = model.connectedCount > 0 && model.errorText == nil
        return Text(model.statusText.uppercased())
            .font(Theme.medium(10))
            .tracking(0.8)
            .foregroundStyle(live ? Theme.yellow : Theme.blue)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background((live ? Theme.yellow : Theme.blue).opacity(0.16))
            .clipShape(Capsule())
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.detailText)
                .font(Theme.body(14))
                .foregroundStyle(.white)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("THIS MAC")
                        .font(Theme.medium(10))
                        .tracking(1.2)
                        .foregroundStyle(Theme.faint)
                    Text(model.localName)
                        .font(Theme.medium(14))
                        .foregroundStyle(.white)
                }
                Spacer()
                if model.port > 0 {
                    Text("Port \(model.port)")
                        .font(Theme.body(12))
                        .foregroundStyle(Theme.muted)
                }
            }
            if let note = model.errorText {
                Text(note)
                    .font(Theme.body(12))
                    .foregroundStyle(Color(red: 0.86, green: 0.28, blue: 0.28))
            }
        }
        .card()
    }

    private var peerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ON THIS NETWORK")
                .font(Theme.medium(10))
                .tracking(1.2)
                .foregroundStyle(Theme.faint)

            if model.peers.isEmpty {
                Text("Other Macs running Mesh will show up here and stay connected.")
                    .font(Theme.body(13))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.peers) { peer in
                            PeerRow(peer: peer)
                            if peer.id != model.peers.last?.id {
                                Divider().overlay(Theme.border)
                            }
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .card()
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: Binding(
                get: { model.launchAtLogin },
                set: { model.setLaunchAtLogin($0) }
            )) {
                Text("Open at login")
                    .font(Theme.body(14))
                    .foregroundStyle(.white)
            }
            .toggleStyle(.switch)
            .tint(Theme.blue)

            if let note = model.launchAtLoginNote {
                Text(note)
                    .font(Theme.body(12))
                    .foregroundStyle(Theme.yellow)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(action: model.reconnect) {
                    Text("Reconnect")
                        .font(Theme.display(13))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(
                            LinearGradient(
                                colors: [Theme.blue, Theme.blueDark],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)

                Button("Quit") {
                    NSApp.terminate(nil)
                }
                .font(Theme.body(13))
                .foregroundStyle(Theme.muted)
                .buttonStyle(.plain)
            }

            updateSection
        }
    }

    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(updates.statusText)
                .font(Theme.body(12))
                .foregroundStyle(updateTone)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: { updates.perform() }) {
                Text(updates.buttonTitle)
                    .font(Theme.body(13))
                    .foregroundStyle(updates.canInstall ? Theme.yellow : Theme.muted)
            }
            .buttonStyle(.plain)
            .disabled(updates.isButtonDisabled)
            .opacity(updates.isButtonDisabled ? 0.45 : 1)
            if updates.askingForToken {
                SecureField("GitHub token", text: $updates.tokenDraft)
                    .textFieldStyle(.plain)
                    .font(Theme.body(13))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Theme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .onSubmit { updates.perform() }
            }
        }
    }

    private var updateTone: Color {
        switch updates.tone {
        case .muted:
            return Theme.muted
        case .ready:
            return Theme.yellow
        case .failure:
            return Color(red: 0.86, green: 0.28, blue: 0.28)
        }
    }
}

private struct PeerRow: View {
    var peer: PeerSnapshot

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .shadow(color: color.opacity(isLive ? 0.7 : 0), radius: 4)
            VStack(alignment: .leading, spacing: 1) {
                Text(peer.name)
                    .font(Theme.medium(14))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if peer.status == .bridged, let via = peer.via {
                    Text("Through \(via)")
                        .font(Theme.body(11))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(label)
                .font(Theme.body(12))
                .foregroundStyle(isLive ? Theme.yellow : Theme.muted)
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private var isLive: Bool {
        peer.status == .connected || peer.status == .bridged
    }

    private var label: String {
        switch peer.status {
        case .connected, .bridged: return "Connected"
        case .connecting: return "Connecting"
        case .waiting: return "Waiting"
        }
    }

    private var color: Color {
        switch peer.status {
        case .connected, .bridged: return Theme.yellow
        case .connecting: return Theme.blue
        case .waiting: return Color.white.opacity(0.35)
        }
    }
}

private struct MeshMark: View {
    var body: some View {
        Canvas { context, size in
            let points = [
                CGPoint(x: size.width * 0.18, y: size.height * 0.72),
                CGPoint(x: size.width * 0.52, y: size.height * 0.22),
                CGPoint(x: size.width * 0.84, y: size.height * 0.64)
            ]
            var path = Path()
            path.move(to: points[0])
            path.addLine(to: points[1])
            path.move(to: points[1])
            path.addLine(to: points[2])
            path.move(to: points[0])
            path.addLine(to: points[2])
            context.stroke(path, with: .color(Theme.blue), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            for (index, point) in points.enumerated() {
                let rect = CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
                let fill = index == 1 ? Theme.yellow : Theme.blue
                context.fill(Path(ellipseIn: rect), with: .color(fill))
            }
        }
        .frame(width: 36, height: 28)
        .accessibilityHidden(true)
    }
}

private extension View {
    func card() -> some View {
        padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.border, lineWidth: 1)
            )
    }
}
