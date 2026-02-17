import SwiftUI

@main
struct PhantomApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var reconnectManager: ReconnectManager

    init() {
        let store = DeviceStore()
        let keys = KeyManager()
        _reconnectManager = StateObject(wrappedValue: ReconnectManager(
            deviceStore: store,
            keyManager: keys
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView(reconnectManager: reconnectManager)
                .onChange(of: scenePhase) { newPhase in
                    reconnectManager.handleScenePhase(newPhase)
                }
        }
    }
}

/// Root view: shows PairingView if not paired, otherwise session navigation.
struct RootView: View {
    @ObservedObject var reconnectManager: ReconnectManager

    var body: some View {
        if reconnectManager.deviceStore.isPaired {
            NavigationStack {
                SessionListView(
                    reconnectManager: reconnectManager,
                    dataSource: TerminalDataSource(reconnectManager: reconnectManager)
                )
            }
            .onAppear {
                if reconnectManager.state == .disconnected {
                    reconnectManager.connect()
                }
            }
        } else {
            PairingView(reconnectManager: reconnectManager)
        }
    }
}
