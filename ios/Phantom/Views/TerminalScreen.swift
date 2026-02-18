import SwiftUI

/// Toolbar mode: quick keys or full extended panel.
enum ToolbarMode {
    case quickKeys
    case extended
    case hidden
}

/// Full-screen terminal view with session tab bar and keyboard toolbar.
/// Layout: Terminal (greedy) → SessionTabBar → Toolbar.
/// Terminal viewport is immovable — all chrome animates around it.
struct TerminalScreen: View {
    @ObservedObject var reconnectManager: ReconnectManager
    let dataSource: TerminalDataSource
    let onDetach: () -> Void
    @State private var toolbarMode: ToolbarMode = .quickKeys
    @State private var showThemePicker = false
    @Environment(\.phantomColors) private var colors

    var body: some View {
        VStack(spacing: 0) {
            // Zone 1: Terminal — takes all available space, never animates
            ZStack(alignment: .topTrailing) {
                TerminalContainerView(terminalView: dataSource.terminalView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Connection status pill (only when not connected)
                if reconnectManager.state != .connected {
                    statusPill
                        .padding(PhantomSpacing.sm)
                }
            }
            .layoutPriority(1)

            // Zone 2: Session tab bar
            SessionTabBar(
                sessions: reconnectManager.sessions,
                activeSessionId: reconnectManager.activeSessionId,
                onSelectSession: { sessionId in
                    reconnectManager.detachSession()
                    // Brief delay for stream teardown before reattach
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        reconnectManager.attachSession(sessionId)
                    }
                },
                onCloseSession: { sessionId in
                    reconnectManager.destroySession(sessionId)
                },
                onNewSession: {
                    reconnectManager.createSession(rows: 24, cols: 80)
                },
                onBack: {
                    reconnectManager.detachSession()
                    onDetach()
                }
            )

            // Zone 3: Keyboard toolbar — animates content, not frame
            toolbarContent
                .animation(.panelReveal, value: toolbarMode)
        }
        .background(colors.base)
        .navigationBarHidden(true)
        .sheet(isPresented: $showThemePicker) {
            ThemePickerView(dataSource: dataSource)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Status Pill

    private var statusPill: some View {
        HStack(spacing: PhantomSpacing.xs) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(reconnectManager.state.statusLabel)
                .font(PhantomFont.caption)
                .foregroundStyle(colors.textPrimary)
        }
        .padding(.horizontal, PhantomSpacing.sm)
        .padding(.vertical, PhantomSpacing.xxs + 2)
        .background(
            Capsule()
                .fill(colors.surface.opacity(0.9))
        )
    }

    private var statusColor: Color {
        switch reconnectManager.state {
        case .connected: return colors.accent
        case .reconnecting, .connecting, .authenticating, .backgrounded:
            return Color(hex: 0xEBCB8B)  // Warm amber
        case .disconnected:
            return Color(hex: 0xBF616A)  // Muted red
        }
    }

    // MARK: - Toolbar Content

    @ViewBuilder
    private var toolbarContent: some View {
        switch toolbarMode {
        case .quickKeys:
            QuickKeyToolbar(
                onKeyPress: { data in
                    reconnectManager.sendInput(data)
                },
                onToggleExtended: {
                    toolbarMode = .extended
                }
            )
        case .extended:
            ExtendedKeyPanel(
                onKeyPress: { data in
                    reconnectManager.sendInput(data)
                },
                onDismiss: {
                    toolbarMode = .quickKeys
                },
                onShowThemePicker: {
                    showThemePicker = true
                }
            )
        case .hidden:
            EmptyView()
        }
    }
}
