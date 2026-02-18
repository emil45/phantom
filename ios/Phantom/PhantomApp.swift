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
                }
                .preferredColorScheme(.dark)
        }
    }
}

/// Root view: shows PairingView if not paired, otherwise session navigation.
struct RootView: View {
    @ObservedObject var reconnectManager: ReconnectManager
    let dataSource: TerminalDataSource

    var body: some View {
        if reconnectManager.deviceStore.isPaired {
            NavigationStack {
                SessionListView(
                    reconnectManager: reconnectManager,
                    dataSource: dataSource
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
