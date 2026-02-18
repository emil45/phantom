import SwiftUI

@main
struct PhantomApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var reconnectManager: ReconnectManager
    @StateObject private var dataSource: TerminalDataSource

    init() {
        let store = DeviceStore()
        let keys = KeyManager()
        let rm = ReconnectManager(deviceStore: store, keyManager: keys)
        _reconnectManager = StateObject(wrappedValue: rm)
        _dataSource = StateObject(wrappedValue: TerminalDataSource(reconnectManager: rm))
    }

    var body: some Scene {
        WindowGroup {
            RootView(reconnectManager: reconnectManager, dataSource: dataSource)
                .environment(\.phantomColors, PhantomColors(from: TerminalTheme.saved))
                .onChange(of: scenePhase) { newPhase in
                    reconnectManager.handleScenePhase(newPhase)
                    if newPhase == .active {
                        PhantomHaptic.prepare()
                    }
                }
                .preferredColorScheme(.dark)
        }
    }
}

/// Root view: shows onboarding if not paired, otherwise terminal-first layout.
struct RootView: View {
    @ObservedObject var reconnectManager: ReconnectManager
    let dataSource: TerminalDataSource
    @State private var hasAutoCreated = false

    var body: some View {
        if reconnectManager.deviceStore.isPaired {
            TerminalScreen(
                reconnectManager: reconnectManager,
                dataSource: dataSource
            )
            .onAppear {
                if reconnectManager.state == .disconnected {
                    reconnectManager.connect()
                }
            }
            .onChange(of: reconnectManager.state) { newState in
                autoCreateFirstSession(state: newState)
            }
        } else {
            PairingView(reconnectManager: reconnectManager)
        }
    }

    /// Auto-create a session when connected with no sessions.
    private func autoCreateFirstSession(state: ConnectionState) {
        guard state == .connected,
              !hasAutoCreated,
              reconnectManager.sessions.isEmpty,
              reconnectManager.activeSessionId == nil else { return }
        hasAutoCreated = true
        // Brief delay to let session list load
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            if reconnectManager.sessions.isEmpty && reconnectManager.activeSessionId == nil {
                reconnectManager.createSession(rows: 24, cols: 80)
            }
        }
    }
}
