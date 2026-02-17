import Foundation

/// Connection state machine for the ReconnectManager.
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case authenticating
    case connected
    case backgrounded
    case reconnecting

    var isUsable: Bool {
        self == .connected
    }

    var statusLabel: String {
        switch self {
        case .disconnected: return "Disconnected"
        case .connecting: return "Connecting..."
        case .authenticating: return "Authenticating..."
        case .connected: return "Connected"
        case .backgrounded: return "Backgrounded"
        case .reconnecting: return "Reconnecting..."
        }
    }

    var statusColor: String {
        switch self {
        case .connected: return "green"
        case .reconnecting, .connecting, .authenticating, .backgrounded: return "yellow"
        case .disconnected: return "red"
        }
    }
}
