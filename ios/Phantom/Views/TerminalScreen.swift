import SwiftUI

/// Full-screen terminal view with connection status indicator.
struct TerminalScreen: View {
    @ObservedObject var reconnectManager: ReconnectManager
    let dataSource: TerminalDataSource

    var body: some View {
        ZStack(alignment: .topTrailing) {
            TerminalContainerView(terminalView: dataSource.terminalView)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea(.keyboard)

            // Connection status indicator
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
                .padding(8)
        }
    }

    private var statusColor: Color {
        switch reconnectManager.state {
        case .connected:
            return .green
        case .reconnecting, .connecting, .authenticating, .backgrounded:
            return .yellow
        case .disconnected:
            return .red
        }
    }
}
