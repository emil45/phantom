import SwiftUI

@main
struct PhantomBarApp: App {
    @StateObject private var daemonState = DaemonState()
    @StateObject private var setupManager = SetupManager()

    var body: some Scene {
        MenuBarExtra {
            StatusPopover()
                .environmentObject(daemonState)
                .environmentObject(setupManager)
                .onAppear {
                    setupManager.ensureSetup()
                    daemonState.startPolling()
                }
        } label: {
            Image(systemName: daemonState.hasConnectedDevices ? "terminal.fill" : "terminal")
        }
        .menuBarExtraStyle(.window)
    }
}
