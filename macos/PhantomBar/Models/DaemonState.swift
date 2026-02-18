import Foundation
import SwiftUI

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

@MainActor
class DaemonState: ObservableObject {
    @Published var status: ConnectionStatus = .stopped
    @Published var devices: [DeviceInfo] = []
    @Published var sessions: [SessionInfo] = []
    @Published var version: String = ""
    @Published var bindAddress: String = ""
    @Published var certFingerprint: String = ""

    private let client = DaemonClient()
    private let monitor = DaemonMonitor()
    private var pollTimer: Timer?

    var hasConnectedDevices: Bool {
        devices.contains { $0.isConnected }
    }

    func startPolling() {
        poll()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
    }

    func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    func poll() {
        guard monitor.isDaemonRunning else {
            status = .stopped
            devices = []
            sessions = []
            return
        }

        // Only show "connecting" on first connect, not during refresh polls
        if !status.isRunning {
            status = .connecting
        }

        Task {
            do {
                let daemonStatus = try await client.status()
                let deviceList = try await client.listDevices()
                let sessionList = try await client.listSessions()

                self.status = .running(uptime: daemonStatus.uptimeSecs)
                self.version = daemonStatus.version
                self.bindAddress = daemonStatus.bindAddress
                self.certFingerprint = daemonStatus.certFingerprint
                self.devices = deviceList
                self.sessions = sessionList
            } catch {
                self.status = .error(error.localizedDescription)
            }
        }
    }

    func startDaemon() {
        do {
            try monitor.startDaemon()
            // Give it a moment to start
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                self.poll()
            }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func stopDaemon() {
        do {
            try monitor.stopDaemon()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                self.poll()
            }
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func revokeDevice(_ deviceId: String) {
        Task {
            do {
                try await client.revokeDevice(deviceId: deviceId)
                poll()
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    func destroySession(_ sessionId: String) {
        Task {
            do {
                try await client.destroySession(sessionId: sessionId)
                poll()
            } catch {
                status = .error(error.localizedDescription)
            }
        }
    }

    func createPairing() async throws -> PairingInfo {
        try await client.createPairing()
    }
}
