import SwiftUI

/// Centered overlay shown when the terminal is not connected.
/// Communicates state calmly with pulse animation and reassuring messaging.
struct ConnectionOverlay: View {
    let state: ConnectionState
    let isBuffering: Bool
    var authError: String? = nil
    var nextRetryDate: Date? = nil
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

                    if let retryDate = nextRetryDate {
                        RetryCountdown(targetDate: retryDate)
                            .font(PhantomFont.caption)
                            .foregroundStyle(colors.textSecondary.opacity(0.5))
                    }
                }

                if state == .disconnected {
                    if let authError = authError {
                        Text(authError)
                            .font(PhantomFont.caption)
                            .foregroundStyle(colors.statusError)
                            .multilineTextAlignment(.center)

                        Text("You may need to re-pair this device")
                            .font(PhantomFont.caption)
                            .foregroundStyle(colors.textSecondary.opacity(0.7))
                    } else {
                        Text("Check that your Mac is on and reachable")
                            .font(PhantomFont.caption)
                            .foregroundStyle(colors.textSecondary)
                    }
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

// MARK: - Retry Countdown

/// Shows a live countdown to the next reconnect attempt.
private struct RetryCountdown: View {
    let targetDate: Date
    @State private var remaining: Int = 0
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if remaining > 0 {
                Text("Retrying in \(remaining)s\u{2026}")
            } else {
                Text("Retrying now\u{2026}")
            }
        }
        .onAppear { updateRemaining() }
        .onReceive(timer) { _ in updateRemaining() }
    }

    private func updateRemaining() {
        remaining = max(0, Int(ceil(targetDate.timeIntervalSinceNow)))
    }
}

// MARK: - Switching Overlay

/// Brief overlay shown during session switching to prevent disconnect flash.
struct SwitchingOverlay: View {
    @Environment(\.phantomColors) private var colors

    var body: some View {
        VStack(spacing: PhantomSpacing.sm) {
            ProgressView()
                .tint(colors.accent)

            Text("Switching\u{2026}")
                .font(PhantomFont.caption)
                .foregroundStyle(colors.textSecondary)
        }
        .padding(PhantomSpacing.lg)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: PhantomRadius.card))
    }
}

// MARK: - Session Ended Overlay

/// Overlay shown when connected but no active session (session ended or not yet created).
struct SessionEndedOverlay: View {
    let hasOtherSessions: Bool
    let onNewSession: () -> Void
    let onShowSessions: () -> Void
    @Environment(\.phantomColors) private var colors

    var body: some View {
        VStack(spacing: PhantomSpacing.md) {
            Image(systemName: "terminal")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(colors.textSecondary.opacity(0.5))

            VStack(spacing: PhantomSpacing.xxs) {
                Text("Session ended")
                    .font(PhantomFont.headline)
                    .foregroundStyle(colors.textPrimary)

                Text(hasOtherSessions
                     ? "Switch to another session or start a new one"
                     : "Start a new session to continue")
                    .font(PhantomFont.caption)
                    .foregroundStyle(colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: PhantomSpacing.xs) {
                Button(action: onNewSession) {
                    Text("New Session")
                        .font(PhantomFont.headline)
                        .foregroundStyle(colors.base)
                        .padding(.horizontal, PhantomSpacing.lg)
                        .padding(.vertical, PhantomSpacing.xs)
                        .background(colors.accent, in: Capsule())
                }
                .buttonStyle(.plain)

                if hasOtherSessions {
                    Button(action: onShowSessions) {
                        Text("View Sessions")
                            .font(PhantomFont.secondaryLabel)
                            .foregroundStyle(colors.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(PhantomSpacing.lg)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: PhantomRadius.card))
    }
}
