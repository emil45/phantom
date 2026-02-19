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
        case .connecting: return "Connecting\u{2026}"
        case .authenticating: return "Connecting\u{2026}"
        case .connected: return "Connected"
        case .backgrounded: return "Resuming\u{2026}"
        case .reconnecting: return "Reconnecting\u{2026}"
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
