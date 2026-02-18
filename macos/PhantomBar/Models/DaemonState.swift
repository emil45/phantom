import Foundation
import SwiftUI

// MARK: - Types

enum ConnectionStatus: Equatable {
    case stopped
    case connecting
    case running(uptime: UInt64)
    case error(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

struct DaemonSnapshot: Equatable {
    var status: ConnectionStatus = .stopped
    var devices: [DeviceInfo] = []
    var sessions: [SessionInfo] = []
    var version: String = ""
    var bindAddress: String = ""
    var certFingerprint: String = ""
}

// MARK: - State

@MainActor
class DaemonState: ObservableObject {
    @Published var snapshot = DaemonSnapshot()

    private let client = DaemonClient()
    private let monitor = DaemonMonitor()
    private var pollingTask: Task<Void, Never>?

    var hasConnectedDevices: Bool {
        snapshot.devices.contains { $0.isConnected }
    }

    // MARK: - Polling

    /// Start polling. `fast: true` polls every 3s (popover open), `fast: false` every 15s (background icon updates).
    func startPolling(fast: Bool) {
        pollingTask?.cancel()
        let interval: Duration = fast ? .seconds(3) : .seconds(15)
        pollingTask = Task { [weak self] in
            // Immediate poll on start
            await self?.poll()
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { break }
                await self?.poll()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Force an immediate poll (e.g. from a manual retry action).
    func refresh() {
        Task { await poll() }
    }

    private func poll() async {
        guard monitor.isDaemonRunning else {
            if snapshot.status != .stopped {
                snapshot = DaemonSnapshot()
            }
            return
        }

        // Only show "connecting" on first connect, not during refresh polls
        if !snapshot.status.isRunning {
            snapshot.status = .connecting
        }

        do {
            async let s = client.status()
            async let d = client.listDevices()
            async let sess = client.listSessions()

            let (daemonStatus, deviceList, sessionList) = try await (s, d, sess)

            let newSnapshot = DaemonSnapshot(
                status: .running(uptime: daemonStatus.uptimeSecs),
                devices: deviceList,
                sessions: sessionList,
                version: daemonStatus.version,
                bindAddress: daemonStatus.bindAddress,
                certFingerprint: daemonStatus.certFingerprint
            )

            // Skip redundant publishes — SwiftUI diffing is cheap but not free
            if snapshot != newSnapshot {
                snapshot = newSnapshot
            }
        } catch {
            snapshot.status = .error(error.localizedDescription)
        }
    }

    // MARK: - Actions

    func startDaemon() async {
        do {
            try await monitor.startDaemon()
            try? await Task.sleep(for: .seconds(1))
            await poll()
        } catch {
            snapshot.status = .error(error.localizedDescription)
        }
    }

    func stopDaemon() async {
        do {
            try await monitor.stopDaemon()
            try? await Task.sleep(for: .milliseconds(500))
            await poll()
        } catch {
            snapshot.status = .error(error.localizedDescription)
        }
    }

    func revokeDevice(_ deviceId: String) {
        Task {
            do {
                try await client.revokeDevice(deviceId: deviceId)
                await poll()
            } catch {
                snapshot.status = .error(error.localizedDescription)
            }
        }
    }

    func destroySession(_ sessionId: String) {
        Task {
            do {
                try await client.destroySession(sessionId: sessionId)
                await poll()
            } catch {
                snapshot.status = .error(error.localizedDescription)
            }
        }
    }

    func createPairing() async throws -> PairingInfo {
        try await client.createPairing()
    }
}
