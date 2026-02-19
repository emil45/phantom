import Foundation
import SwiftUI
import Network
import os

/// Central coordinator for QUIC connection lifecycle, authentication,
/// session management, and frame-based terminal I/O.
@MainActor
final class ReconnectManager: ObservableObject {
    @Published var state: ConnectionState = .disconnected
    @Published var sessions: [SessionInfo] = []
    @Published var activeSessionId: String?

    private var client: QUICClient?
    private var controlStream: NWConnection?
    private var dataStream: NWConnection?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var keystrokeBuffer: [Data] = []
    private let maxKeystrokeBuffer = 10_000
    private var isBuffering = false
    private var frameDecoder = FrameDecoder()
    private var seqOut: UInt64 = 1
    private var receiveWindow: UInt64 = 262144 // 256KB
    private var bytesReceived: UInt64 = 0
    private let windowThreshold: UInt64 = 65536 // send update after consuming 64KB

    let deviceStore: DeviceStore
    let keyManager: KeyManager

    /// Called when terminal data arrives from the server.
    var onTerminalData: ((Data) -> Void)?
    /// Called when scrollback data arrives (on reattach).
    var onScrollbackData: ((Data) -> Void)?

    init(deviceStore: DeviceStore, keyManager: KeyManager) {
        self.deviceStore = deviceStore
        self.keyManager = keyManager
    }

    // MARK: - Connection

    func connect() {
        guard state == .disconnected || state == .reconnecting else { return }
        guard let host = deviceStore.serverHost else { return }
        let port = deviceStore.serverPort

        state = .connecting
        frameDecoder = FrameDecoder()
        seqOut = 1
        bytesReceived = 0

        let client = QUICClient(
            host: host,
            port: port,
            fingerprint: deviceStore.serverFingerprint
        )
        self.client = client

        client.onTunnelReady = { [weak self] in
            Task { @MainActor in
                self?.onTunnelReady()
            }
        }

        client.onTunnelFailed = { [weak self] error in
            Task { @MainActor in
                Logger.quic.error("QUIC tunnel failed: \(String(describing: error))")
                self?.state = .disconnected
                self?.scheduleReconnect()
            }
        }

        client.connect()
    }

    /// Connect for initial pairing (before server info is persisted).
    func connectForPairing(host: String, port: UInt16, fingerprint: String, token: String, serverName: String) {
        Logger.auth.info("connectForPairing: host=\(host), port=\(port), fp=\(fingerprint)")
        state = .connecting

        let client = QUICClient(host: host, port: port, fingerprint: fingerprint)
        self.client = client

        client.onTunnelReady = { [weak self] in
            Logger.auth.info("connectForPairing: tunnel ready!")
            Task { @MainActor in
                self?.performPairing(
                    host: host,
                    port: port,
                    fingerprint: fingerprint,
                    token: token,
                    serverName: serverName
                )
            }
        }

        client.onTunnelFailed = { [weak self] error in
            Logger.auth.error("connectForPairing: tunnel FAILED: \(String(describing: error))")
            Task { @MainActor in
                self?.state = .disconnected
            }
        }

        Logger.auth.info("connectForPairing: calling client.connect()")
        client.connect()
    }

    private func onTunnelReady() {
        state = .authenticating
        openControlStreamAndAuth()
    }

    // MARK: - Authentication

    private func openControlStreamAndAuth() {
        guard let stream = client?.firstStream else {
            state = .disconnected
            scheduleReconnect()
            return
        }
        controlStream = stream
        performChallengeAuth(on: stream)
    }

    private func performChallengeAuth(on stream: NWConnection) {
        let deviceId = deviceStore.deviceId
        let requestId = generateRequestId()

        // Send auth_request with device_id
        let request: [String: Any] = [
            "type": "auth_request",
            "request_id": requestId,
            "device_id": deviceId,
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: request) else { return }

        stream.sendControlMessage(json) { [weak self] error in
            if let error = error {
                Logger.auth.error("Auth send error: \(error)")
                Task { @MainActor in
                    self?.state = .disconnected
                    self?.scheduleReconnect()
                }
                return
            }
            // Wait for challenge
            self?.receiveAuthChallenge(on: stream, requestId: requestId, deviceId: deviceId)
        }
    }

    private func receiveAuthChallenge(on stream: NWConnection, requestId: String, deviceId: String) {
        stream.receiveControlMessage { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let data):
                Task { @MainActor in
                    self.handleAuthChallenge(data, on: stream, requestId: requestId, deviceId: deviceId)
                }
            case .failure(let error):
                Logger.auth.error("Auth receive error: \(error)")
                Task { @MainActor in
                    self.state = .disconnected
                    self.scheduleReconnect()
                }
            }
        }
    }

    private func handleAuthChallenge(_ data: Data, on stream: NWConnection, requestId: String, deviceId: String) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            state = .disconnected
            return
        }

        if type == "auth_challenge" {
            guard let challengeB64 = json["challenge"] as? String,
                  let challengeBytes = Data(base64Encoded: challengeB64) else {
                state = .disconnected
                return
            }

            // Build signed data: challenge || tls_exporter_keying_material
            // For now, sign just the challenge. TLS exporter binding will be
            // validated in Phase 4 integration testing.
            let signedData = challengeBytes
            // TODO: Add TLS exporter binding when NWProtocolTLS metadata access is validated
            // if let exporter = stream.exportKeyingMaterial(context: receiveContext, label: "phantom-auth", contextData: Data(), length: 32) {
            //     signedData.append(exporter)
            // }

            guard let signature = try? keyManager.sign(signedData) else {
                Logger.auth.error("Failed to sign challenge")
                state = .disconnected
                return
            }

            let response: [String: Any] = [
                "type": "auth_response",
                "request_id": requestId,
                "device_id": deviceId,
                "signature": signature.base64EncodedString(),
            ]

            guard let responseJson = try? JSONSerialization.data(withJSONObject: response) else { return }

            stream.sendControlMessage(responseJson) { [weak self] error in
                if let error = error {
                    Logger.auth.error("Auth response send error: \(error)")
                    Task { @MainActor in
                        self?.state = .disconnected
                    }
                    return
                }
                self?.receiveAuthResult(on: stream)
            }
        } else if type == "auth_response" {
            // Direct response (e.g., from pairing flow)
            handleAuthResult(json)
        } else {
            Logger.auth.error("Unexpected auth message type: \(type)")
            state = .disconnected
        }
    }

    private func receiveAuthResult(on stream: NWConnection) {
        stream.receiveControlMessage { [weak self] result in
            switch result {
            case .success(let data):
                guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    Task { @MainActor in self?.state = .disconnected }
                    return
                }
                Task { @MainActor in
                    self?.handleAuthResult(json)
                }
            case .failure(let error):
                Logger.auth.error("Auth result receive error: \(error)")
                Task { @MainActor in
                    self?.state = .disconnected
                    self?.scheduleReconnect()
                }
            }
        }
    }

    private func handleAuthResult(_ json: [String: Any]) {
        let success = json["success"] as? Bool ?? false
        if success {
            state = .connected
            reconnectAttempt = 0
            isBuffering = false
            replayBufferedKeystrokes()

            // If we had an active session, reattach; otherwise refresh session list
            if let sessionId = activeSessionId {
                attachSession(sessionId)
            } else {
                listSessions()
            }
        } else {
            let error = json["error"] as? String ?? "unknown"
            Logger.auth.error("Auth failed: \(error)")
            state = .disconnected
        }
    }

    // MARK: - Pairing

    private func performPairing(host: String, port: UInt16, fingerprint: String, token: String, serverName: String) {
        Logger.auth.info("performPairing: using first stream for pairing")
        guard let stream = client?.firstStream else {
            Logger.auth.error("performPairing: no first stream available")
            state = .disconnected
            return
        }
        Logger.auth.info("performPairing: stream state = \(String(describing: stream.state))")
        controlStream = stream
        sendPairingRequest(
            on: stream, host: host, port: port,
            fingerprint: fingerprint, token: token, serverName: serverName
        )
    }

    private func sendPairingRequest(
        on stream: NWConnection,
        host: String, port: UInt16, fingerprint: String,
        token: String, serverName: String
    ) {
        let deviceId = deviceStore.deviceId
        let requestId = generateRequestId()

        let request: [String: Any] = [
            "type": "auth_request",
            "request_id": requestId,
            "device_id": deviceId,
            "public_key": keyManager.publicKeyBase64,
            "device_name": UIDevice.current.name,
            "pairing_token": token,
        ]

        guard let json = try? JSONSerialization.data(withJSONObject: request) else {
            Logger.auth.error("sendPairingRequest: JSON serialization FAILED")
            return
        }
        Logger.auth.debug("sendPairingRequest: sending \(json.count) bytes on stream state=\(String(describing: stream.state))")

        stream.sendControlMessage(json) { [weak self] error in
            if let error = error {
                Logger.auth.error("sendPairingRequest: send ERROR: \(error)")
                Task { @MainActor in self?.state = .disconnected }
                return
            }
            Logger.auth.info("sendPairingRequest: send completed OK, waiting for response")
            // Receive pairing result
            stream.receiveControlMessage { result in
                switch result {
                case .success(let data):
                    guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        Task { @MainActor in self?.state = .disconnected }
                        return
                    }
                    Task { @MainActor in
                        let success = json["success"] as? Bool ?? false
                        if success {
                            self?.deviceStore.savePairing(
                                host: host, port: port,
                                fingerprint: fingerprint, serverName: serverName
                            )
                            self?.state = .connected
                            self?.reconnectAttempt = 0
                        } else {
                            let error = json["error"] as? String ?? "unknown"
                            Logger.auth.error("Pairing failed: \(error)")
                            self?.state = .disconnected
                        }
                    }
                case .failure(let error):
                    Logger.auth.error("Pairing response error: \(error)")
                    Task { @MainActor in self?.state = .disconnected }
                }
            }
        }
    }

    // MARK: - Session Management

    /// Handle a control stream error by triggering reconnect.
    private func handleControlStreamError() {
        Task { @MainActor in
            if self.state == .connected {
                self.state = .disconnected
                self.scheduleReconnect()
            }
        }
    }

    func listSessions() {
        guard let stream = controlStream else { return }
        let requestId = generateRequestId()
        let request: [String: Any] = [
            "type": "list_sessions",
            "request_id": requestId,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: request) else { return }
        stream.sendControlMessage(json) { [weak self] error in
            if let error = error {
                Logger.session.error("list_sessions send error: \(error)")
                self?.handleControlStreamError()
                return
            }
            stream.receiveControlMessage { result in
                switch result {
                case .success(let data):
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let sessionsData = try? JSONSerialization.data(withJSONObject: json["sessions"] ?? []) {
                        let decoder = JSONDecoder()
                        if let sessions = try? decoder.decode([SessionInfo].self, from: sessionsData) {
                            Task { @MainActor in
                                self?.sessions = sessions
                            }
                        }
                    }
                case .failure(let error):
                    Logger.session.error("list_sessions receive error: \(error)")
                    self?.handleControlStreamError()
                }
            }
        }
    }

    func createSession(rows: UInt16, cols: UInt16) {
        guard let stream = controlStream else {
            Logger.session.error("createSession: no control stream!")
            return
        }
        let requestId = generateRequestId()
        let request: [String: Any] = [
            "type": "create_session",
            "request_id": requestId,
            "rows": rows,
            "cols": cols,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: request) else { return }
        stream.sendControlMessage(json) { [weak self] error in
            if let error = error {
                Logger.session.error("create_session send error: \(error)")
                self?.handleControlStreamError()
                return
            }
            stream.receiveControlMessage { result in
                switch result {
                case .success(let data):
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let sessionId = json["session_id"] as? String {
                        Task { @MainActor in
                            self?.activeSessionId = sessionId
                            self?.dataStream = stream
                            self?.startFrameReceiving(on: stream)
                            self?.replayBufferedKeystrokes()
                        }
                    }
                case .failure(let error):
                    Logger.session.error("create_session receive error: \(error)")
                    self?.handleControlStreamError()
                }
            }
        }
    }

    func attachSession(_ sessionId: String) {
        guard let stream = controlStream else { return }
        let requestId = generateRequestId()
        let request: [String: Any] = [
            "type": "attach_session",
            "request_id": requestId,
            "session_id": sessionId,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: request) else { return }
        stream.sendControlMessage(json) { [weak self] error in
            if let error = error {
                Logger.session.error("attach_session send error: \(error)")
                self?.handleControlStreamError()
                return
            }
            stream.receiveControlMessage { result in
                switch result {
                case .success(let data):
                    if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                       json["type"] as? String == "session_attached" {
                        Task { @MainActor in
                            self?.activeSessionId = sessionId
                            self?.dataStream = stream
                            self?.frameDecoder = FrameDecoder()
                            self?.startFrameReceiving(on: stream)
                            self?.replayBufferedKeystrokes()
                        }
                    }
                case .failure(let error):
                    Logger.session.error("attach_session receive error: \(error)")
                    self?.handleControlStreamError()
                }
            }
        }
    }

    /// Detach from the current session and reconnect for a fresh control stream.
    /// The single QUIC stream is consumed by bridge mode, so we must reconnect.
    func detachSession() {
        activeSessionId = nil
        dataStream = nil
        controlStream = nil
        client?.disconnect()
        client = nil
        state = .disconnected
        reconnectAttempt = 0
        connect()
    }

    func destroySession(_ sessionId: String) {
        guard let stream = controlStream else { return }
        let requestId = generateRequestId()
        let request: [String: Any] = [
            "type": "destroy_session",
            "request_id": requestId,
            "session_id": sessionId,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: request) else { return }
        stream.sendControlMessage(json) { [weak self] error in
            if let error = error {
                Logger.session.error("destroy_session send error: \(error)")
                self?.handleControlStreamError()
                return
            }
            stream.receiveControlMessage { result in
                switch result {
                case .success:
                    Task { @MainActor in
                        if self?.activeSessionId == sessionId {
                            self?.activeSessionId = nil
                            self?.dataStream = nil
                        }
                        self?.listSessions()
                    }
                case .failure(let error):
                    Logger.session.error("destroy_session receive error: \(error)")
                    self?.handleControlStreamError()
                }
            }
        }
    }

    // MARK: - Frame I/O

    func sendInput(_ data: Data) {
        if isBuffering || !state.isUsable || dataStream == nil {
            if keystrokeBuffer.count < maxKeystrokeBuffer {
                keystrokeBuffer.append(data)
            }
            if !isBuffering { isBuffering = true }
            return
        }

        let frame = Frame.data(seq: seqOut, payload: data)
        seqOut += 1
        let compress = data.count > compressThreshold
        guard let encoded = try? encodeFrame(frame, compress: compress) else { return }

        dataStream?.send(content: encoded, completion: .contentProcessed { error in
            if let error = error {
                Logger.quic.error("Frame send error: \(error)")
            }
        })
    }

    func sendResize(cols: UInt16, rows: UInt16) {
        guard state.isUsable, let stream = dataStream else { return }
        let frame = Frame.resize(seq: seqOut, cols: cols, rows: rows)
        seqOut += 1
        guard let encoded = try? encodeFrame(frame) else { return }
        stream.send(content: encoded, completion: .contentProcessed { _ in })
    }

    private func startFrameReceiving(on stream: NWConnection) {
        receiveFrameData(on: stream)
    }

    private func receiveFrameData(on stream: NWConnection) {
        stream.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, context, isComplete, error in
            guard let self = self else { return }

            if let data = content, !data.isEmpty {
                self.frameDecoder.feed(data)
                self.processDecodedFrames()
            }

            if isComplete {
                Logger.quic.info("Data stream FIN")
                Task { @MainActor in
                    self.dataStream = nil
                }
                return
            }
            if let error = error {
                Logger.quic.error("Data stream error: \(error)")
                Task { @MainActor in
                    self.dataStream = nil
                    if self.state == .connected {
                        self.state = .disconnected
                        self.scheduleReconnect()
                    }
                }
                return
            }

            self.receiveFrameData(on: stream)
        }
    }

    private func processDecodedFrames() {
        do {
            while let frame = try frameDecoder.decodeNext() {
                switch frame.type_ {
                case .data:
                    let payload = frame.payload
                    Task { @MainActor in
                        self.onTerminalData?(payload)
                    }
                    trackBytesReceived(UInt64(payload.count))

                case .scrollback:
                    let payload = frame.payload
                    Task { @MainActor in
                        self.onScrollbackData?(payload)
                    }
                    trackBytesReceived(UInt64(payload.count))

                case .heartbeat:
                    break // keepalive handled by QUIC

                case .close:
                    Logger.quic.info("Server sent Close frame")
                    Task { @MainActor in
                        self.activeSessionId = nil
                        self.dataStream?.cancel()
                        self.dataStream = nil
                    }

                case .resize, .windowUpdate:
                    break // client doesn't process these from server
                }
            }
        } catch {
            Logger.quic.error("Frame decode error: \(error)")
        }
    }

    private func trackBytesReceived(_ count: UInt64) {
        bytesReceived += count
        if bytesReceived >= windowThreshold {
            sendWindowUpdate()
            bytesReceived = 0
        }
    }

    private func sendWindowUpdate() {
        guard let stream = dataStream else { return }
        let frame = Frame.windowUpdate(seq: seqOut, window: receiveWindow)
        seqOut += 1
        guard let encoded = try? encodeFrame(frame) else { return }
        stream.send(content: encoded, completion: .contentProcessed { _ in })
    }

    private func replayBufferedKeystrokes() {
        let buffered = keystrokeBuffer
        keystrokeBuffer.removeAll()
        isBuffering = false
        for data in buffered {
            sendInput(data)
        }
    }

    // MARK: - Background/Foreground Lifecycle

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            enterBackground()
        case .active:
            enterForeground()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    private func enterBackground() {
        guard state == .connected else { return }
        state = .backgrounded
        isBuffering = true

        backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in
            self?.endBackgroundTask()
        }
    }

    private func enterForeground() {
        endBackgroundTask()

        switch state {
        case .backgrounded:
            // Check if data stream is still alive
            if dataStream != nil {
                // Optimistic: assume connection still alive
                state = .connected
                isBuffering = false
                replayBufferedKeystrokes()
            } else {
                // Connection died during background
                state = .disconnected
                reconnect()
            }
        case .disconnected:
            reconnect()
        case .reconnecting:
            break
        default:
            break
        }
    }

    private func endBackgroundTask() {
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    // MARK: - Reconnect

    private var reconnectAttempt = 0

    func reconnect() {
        disconnect()
        connect()
    }

    private func scheduleReconnect() {
        guard state == .disconnected else { return }
        guard deviceStore.isPaired else { return }
        state = .reconnecting
        isBuffering = true

        let delays: [TimeInterval] = [0.5, 1, 2, 4, 8]
        let base = delays[min(reconnectAttempt, delays.count - 1)]
        let jitter = TimeInterval.random(in: 0...(base * 0.3))
        let delay = base + jitter
        reconnectAttempt += 1

        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if state == .reconnecting {
                connect()
            }
        }
    }

    /// Notify server that this device is unpairing, then disconnect.
    func removeDeviceAndDisconnect() {
        guard let stream = controlStream else {
            disconnect()
            deviceStore.clearPairing()
            return
        }
        let requestId = generateRequestId()
        let request: [String: Any] = [
            "type": "remove_device",
            "request_id": requestId,
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: request) else {
            disconnect()
            deviceStore.clearPairing()
            return
        }
        stream.sendControlMessage(json) { [weak self] _ in
            Task { @MainActor in
                self?.disconnect()
                self?.deviceStore.clearPairing()
            }
        }
    }

    func disconnect() {
        dataStream?.cancel()
        dataStream = nil
        controlStream?.cancel()
        controlStream = nil
        client?.disconnect()
        client = nil
        state = .disconnected
        isBuffering = false
        keystrokeBuffer.removeAll()
        reconnectAttempt = 0
    }
}
