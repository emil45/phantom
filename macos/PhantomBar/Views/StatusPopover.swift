import SwiftUI

// MARK: - Header View

/// SwiftUI view embedded via NSHostingView as the top menu item.
/// Shows app name, connection status, and a toggle to start/stop the daemon.
struct StatusHeaderView: View {
    let snapshot: DaemonSnapshot
    let isTransitioning: Bool
    let onToggle: (Bool) -> Void

    /// Optimistic override so the toggle animates immediately on click,
    /// before the menu closes and the actual state catches up.
    @State private var pendingState: Bool? = nil

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Phantom")
                    .font(.system(.body, weight: .semibold))

                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)

                    Text(statusSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Toggle("", isOn: toggleBinding)
                .toggleStyle(MenuSwitchStyle())
                .labelsHidden()
                .disabled(isTransitioning)
                .accessibilityLabel("Phantom connection")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minWidth: 260, alignment: .leading)
        .onAppear { pendingState = nil }
    }

    // MARK: - Toggle

    private var stateOn: Bool {
        switch snapshot.status {
        case .running, .connecting, .error: true
        case .stopped: false
        }
    }

    /// The value the toggle actually displays (optimistic or real).
    private var displayedOn: Bool {
        pendingState ?? stateOn
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { displayedOn },
            set: { newValue in
                pendingState = newValue
                onToggle(newValue)
            }
        )
    }

    // MARK: - Display

    private var statusColor: Color {
        switch snapshot.status {
        case .running: .green
        case .connecting: .orange
        case .stopped: .secondary
        case .error: .red
        }
    }

    private var statusSubtitle: String {
        switch snapshot.status {
        case .running(let uptime):
            "Connected \u{00B7} \(formatUptime(uptime))"
        case .connecting:
            "Connecting\u{2026}"
        case .stopped:
            "Not Connected"
        case .error:
            "Error"
        }
    }

    private func formatUptime(_ seconds: UInt64) -> String {
        switch seconds {
        case 0..<60:
            return "just now"
        case 60..<3600:
            return "\(seconds / 60)m"
        case 3600..<86400:
            let h = seconds / 3600
            let m = (seconds % 3600) / 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        default:
            let d = seconds / 86400
            let h = (seconds % 86400) / 3600
            return h > 0 ? "\(d)d \(h)h" : "\(d)d"
        }
    }
}

// MARK: - Custom Toggle Style

/// Renders a macOS-style switch with explicit colors so it displays correctly
/// inside NSMenu items, where vibrancy compositing washes out the system toggle.
struct MenuSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? Color.green : Color(.systemGray))
                .frame(width: 38, height: 22)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                        .frame(width: 18, height: 18)
                        .padding(2)
                }
                .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
                .opacity(isEnabled ? 1.0 : 0.5)
        }
        .buttonStyle(.plain)
    }
}
