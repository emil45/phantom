import SwiftUI

/// Toolbar mode: quick keys or full extended panel.
enum ToolbarMode {
    case quickKeys
    case extended
    case hidden
}

/// Terminal-first root view. The terminal is always the primary surface.
/// Sessions and settings are presented as sheets — the terminal never unmounts.
struct TerminalScreen: View {
    @ObservedObject var reconnectManager: ReconnectManager
    let dataSource: TerminalDataSource
    @State private var toolbarMode: ToolbarMode = .quickKeys
    @State private var showThemePicker = false
    @State private var showSessionsSheet = false
    @GestureState private var dragOffset: CGFloat = 0
    @Environment(\.phantomColors) private var colors

    var body: some View {
        VStack(spacing: 0) {
            // Zone 1: Terminal viewport with overlays
            ZStack(alignment: .top) {
                TerminalContainerView(terminalView: dataSource.terminalView)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Session pill — top center
                if reconnectManager.activeSessionId != nil {
                    SessionPill(
                        sessions: reconnectManager.sessions,
                        activeSessionId: reconnectManager.activeSessionId,
                        connectionState: reconnectManager.state,
                        onTap: { showSessionsSheet = true }
                    )
                    .padding(.top, PhantomSpacing.xs)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Connection overlay — centered
                if !reconnectManager.state.isUsable && reconnectManager.activeSessionId != nil {
                    ConnectionOverlay(
                        state: reconnectManager.state,
                        isBuffering: reconnectManager.activeSessionId != nil,
                        authError: reconnectManager.authError
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .layoutPriority(1)
            .gesture(sessionSwipeGesture)

            // Zone 2: Keyboard toolbar
            toolbarContent
                .animation(.panelReveal, value: toolbarMode)
        }
        .background(colors.base)
        .sheet(isPresented: $showSessionsSheet) {
            SessionsSheet(
                reconnectManager: reconnectManager,
                dataSource: dataSource
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .environment(\.phantomColors, colors)
        }
        .sheet(isPresented: $showThemePicker) {
            ThemePickerView(dataSource: dataSource)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: reconnectManager.state) { newState in
            handleStateChange(newState)
        }
    }

    // MARK: - Session Swipe Gesture

    private var sessionSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .updating($dragOffset) { value, state, _ in
                state = value.translation.width
            }
            .onEnded { value in
                let sessions = reconnectManager.sessions.filter { $0.alive }
                guard sessions.count > 1,
                      let activeId = reconnectManager.activeSessionId,
                      let currentIndex = sessions.firstIndex(where: { $0.id == activeId }) else { return }

                if value.translation.width < -60 {
                    // Swipe left — next session
                    let nextIndex = (currentIndex + 1) % sessions.count
                    switchToSession(sessions[nextIndex].id)
                } else if value.translation.width > 60 {
                    // Swipe right — previous session
                    let prevIndex = (currentIndex - 1 + sessions.count) % sessions.count
                    switchToSession(sessions[prevIndex].id)
                }
            }
    }

    private func switchToSession(_ sessionId: String) {
        PhantomHaptic.sessionSwitch()
        reconnectManager.detachSession()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            reconnectManager.attachSession(sessionId)

            // VoiceOver announcement for session switch
            let aliveSessions = reconnectManager.sessions.filter { $0.alive }
            if let index = aliveSessions.firstIndex(where: { $0.id == sessionId }) {
                let announcement = "Session \(index + 1) of \(aliveSessions.count)"
                UIAccessibility.post(notification: .announcement, argument: announcement)
            }
        }
    }

    // MARK: - State Changes

    private func handleStateChange(_ newState: ConnectionState) {
        switch newState {
        case .connected:
            PhantomHaptic.connected()
        case .disconnected:
            if reconnectManager.activeSessionId != nil {
                PhantomHaptic.disconnected()
            }
        default:
            break
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
