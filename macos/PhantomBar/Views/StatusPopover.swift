import SwiftUI

/// SwiftUI view embedded via NSHostingView as the status header menu item.
struct StatusHeaderView: View {
    let snapshot: DaemonSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)

                Text(statusTitle)
                    .font(.system(.body, weight: .medium))

                if case .running(let uptime) = snapshot.status {
                    Text("\u{00B7} \(formatUptime(uptime))")
                        .foregroundStyle(.secondary)
                }
            }

            if snapshot.status.isRunning, !snapshot.bindAddress.isEmpty {
                Text(snapshot.bindAddress)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusColor: Color {
        switch snapshot.status {
        case .running: .green
        case .connecting: .orange
        case .stopped: .secondary
        case .error: .red
        }
    }

    private var statusTitle: String {
        switch snapshot.status {
        case .running: "Phantom Running"
        case .connecting: "Connecting\u{2026}"
        case .stopped: "Phantom Stopped"
        case .error: "Error"
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
