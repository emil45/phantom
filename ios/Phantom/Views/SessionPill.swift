import SwiftUI

/// Compact capsule showing current session info at the top of the terminal.
/// Tappable to open sessions sheet. Minimal chrome, maximum content.
struct SessionPill: View {
    let sessions: [SessionInfo]
    let activeSessionId: String?
    let connectionState: ConnectionState
    let onTap: () -> Void
    @Environment(\.phantomColors) private var colors

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: PhantomSpacing.xs) {
                // Connection status dot
                Circle()
                    .fill(statusColor)
                    .frame(width: 6, height: 6)

                // Session name
                Text(sessionName)
                    .font(PhantomFont.captionMono)
                    .foregroundStyle(colors.textPrimary)
                    .lineLimit(1)

                // Session count (if multiple)
                if sessions.count > 1 {
                    Text("\(currentIndex + 1)/\(sessions.count)")
                        .font(PhantomFont.captionMono)
                        .foregroundStyle(colors.textSecondary)
                }

                // Chevron affordance
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(colors.textSecondary)
            }
            .padding(.horizontal, PhantomSpacing.sm)
            .padding(.vertical, PhantomSpacing.xxs + 2)
            .background(.ultraThinMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var sessionName: String {
        guard let activeId = activeSessionId,
              let session = sessions.first(where: { $0.id == activeId }) else {
            return "No Session"
        }
        if let shell = session.shell {
            let name = (shell as NSString).lastPathComponent
            return name.isEmpty ? String(session.id.prefix(8)) : name
        }
        return String(session.id.prefix(8))
    }

    private var currentIndex: Int {
        guard let activeId = activeSessionId else { return 0 }
        return sessions.firstIndex(where: { $0.id == activeId }) ?? 0
    }

    private var statusColor: Color {
        switch connectionState {
        case .connected: return colors.statusConnected
        case .reconnecting, .connecting, .authenticating, .backgrounded:
            return colors.statusWarning
        case .disconnected:
            return colors.statusError
        }
    }
}
