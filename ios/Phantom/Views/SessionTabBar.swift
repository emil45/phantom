import SwiftUI
import UIKit

/// Horizontal scrolling tab strip for active sessions.
/// Sits between the terminal viewport and the keyboard toolbar.
struct SessionTabBar: View {
    let sessions: [SessionInfo]
    let activeSessionId: String?
    let onSelectSession: (String) -> Void
    let onCloseSession: (String) -> Void
    let onNewSession: () -> Void
    let onBack: () -> Void

    @Environment(\.phantomColors) private var colors
    private let haptic = UISelectionFeedbackGenerator()

    var body: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(colors.separator)
                .frame(height: 0.5)

            HStack(spacing: PhantomSpacing.xs) {
                // Back button
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: 36, height: 36)
                }

                // Session tabs
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: PhantomSpacing.xs) {
                        ForEach(sessions) { session in
                            SessionTab(
                                session: session,
                                isActive: session.id == activeSessionId,
                                onSelect: {
                                    haptic.selectionChanged()
                                    onSelectSession(session.id)
                                },
                                onClose: { onCloseSession(session.id) }
                            )
                        }
                    }
                    .padding(.horizontal, PhantomSpacing.xxs)
                }

                // New session button
                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: 32, height: 32)
                        .background(
                            RoundedRectangle(cornerRadius: PhantomRadius.key)
                                .fill(colors.elevated)
                        )
                }
            }
            .padding(.horizontal, PhantomSpacing.xs)
            .padding(.vertical, PhantomSpacing.xs)
            .background(colors.surface)
        }
        .onAppear { haptic.prepare() }
    }
}

// MARK: - Individual Session Tab

private struct SessionTab: View {
    let session: SessionInfo
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @Environment(\.phantomColors) private var colors

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: PhantomSpacing.xs) {
                // Status dot
                Circle()
                    .fill(session.alive ? colors.accent : colors.textSecondary.opacity(0.4))
                    .frame(width: 6, height: 6)

                // Session label
                Text(sessionLabel)
                    .font(PhantomFont.secondaryLabel)
                    .foregroundStyle(isActive ? colors.textPrimary : colors.textSecondary)
                    .lineLimit(1)

                // Close button
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(colors.textSecondary)
                        .frame(width: 18, height: 18)
                        .background(
                            Circle()
                                .fill(colors.textSecondary.opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, PhantomSpacing.sm)
            .padding(.vertical, PhantomSpacing.xs)
            .background(
                RoundedRectangle(cornerRadius: PhantomRadius.key)
                    .fill(isActive ? colors.elevated : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var sessionLabel: String {
        if let shell = session.shell {
            let name = (shell as NSString).lastPathComponent
            return name.isEmpty ? session.id.prefix(8).description : name
        }
        return session.id.prefix(8).description
    }
}
