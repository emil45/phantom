import SwiftUI

/// Centered overlay shown when the terminal is not connected.
/// Communicates state calmly with pulse animation and reassuring messaging.
struct ConnectionOverlay: View {
    let state: ConnectionState
    let isBuffering: Bool
    @Environment(\.phantomColors) private var colors
    @State private var pulse = false

    var body: some View {
        VStack(spacing: PhantomSpacing.md) {
            // Animated pulse indicator
            ZStack {
                Circle()
                    .stroke(statusColor.opacity(0.3), lineWidth: 2)
                    .frame(width: 48, height: 48)
                    .scaleEffect(pulse ? 1.4 : 1.0)
                    .opacity(pulse ? 0 : 0.6)

                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
                    pulse = true
                }
            }

            VStack(spacing: PhantomSpacing.xxs) {
                Text(state.statusLabel)
                    .font(PhantomFont.headline)
                    .foregroundStyle(colors.textPrimary)

                if state == .reconnecting {
                    Text("Your session is preserved")
                        .font(PhantomFont.caption)
                        .foregroundStyle(colors.textSecondary)

                    if isBuffering {
                        Text("Keystrokes are buffered")
                            .font(PhantomFont.caption)
                            .foregroundStyle(colors.textSecondary.opacity(0.7))
                    }
                }

                if state == .disconnected {
                    Text("Check your network connection")
                        .font(PhantomFont.caption)
                        .foregroundStyle(colors.textSecondary)
                }
            }
        }
        .padding(PhantomSpacing.lg)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: PhantomRadius.card))
    }

    private var statusColor: Color {
        switch state {
        case .connected: return colors.statusConnected
        case .reconnecting, .connecting, .authenticating, .backgrounded:
            return colors.statusWarning
        case .disconnected:
            return colors.statusError
        }
    }
}
