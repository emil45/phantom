import SwiftUI

@main
struct PhantomBarApp: App {
    @StateObject private var daemonState = DaemonState()

    var body: some Scene {
        MenuBarExtra {
            StatusPopover()
                .environmentObject(daemonState)
                .onAppear {
                    daemonState.startPolling()
                }
        } label: {
            Image(systemName: daemonState.hasConnectedDevices ? "terminal.fill" : "terminal")
        }
        .menuBarExtraStyle(.window)
    }
}
