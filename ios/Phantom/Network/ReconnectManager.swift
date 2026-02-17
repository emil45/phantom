import Foundation
import SwiftUI
import Network

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
                NSLog("QUIC tunnel failed: \(String(describing: error))")
                self?.state = .disconnected
                self?.scheduleReconnect()
            }
        }

        client.connect()
    }

    /// Connect for initial pairing (before server info is persisted).
    func connectForPairing(host: String, port: UInt16, fingerprint: String, token: String, serverName: String) {
        state = .connecting

        let client = QUICClient(host: host, port: port, fingerprint: fingerprint)
        self.client = client

        client.onTunnelReady = { [weak self] in
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
            Task { @MainActor in
                NSLog("Pairing tunnel failed: \(String(describing: error))")
                self?.state = .disconnected
            }
        }

        client.connect()
    }

    private func onTunnelReady() {
        state = .authenticating
        openControlStreamAndAuth()
    }

    // MARK: - Authentication

    private func openControlStreamAndAuth() {
        client?.openStream { [weak self] stream in
            guard let stream = stream else {
                Task { @MainActor in
                    self?.state = .disconnected
                    self?.scheduleReconnect()
                }
                return
            }
            Task { @MainActor in
                self?.controlStream = stream
                self?.performChallengeAuth(on: stream)
            }
        }
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
                NSLog("Auth send error: \(error)")
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
                NSLog("Auth receive error: \(error)")
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
            var signedData = challengeBytes
            // TODO: Add TLS exporter binding when NWProtocolTLS metadata access is validated
            // if let exporter = stream.exportKeyingMaterial(context: receiveContext, label: "phantom-auth", contextData: Data(), length: 32) {
            //     signedData.append(exporter)
            // }

            guard let signature = try? keyManager.sign(signedData) else {
                NSLog("Failed to sign challenge")
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
                    NSLog("Auth response send error: \(error)")
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
            NSLog("Unexpected auth message type: \(type)")
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
                NSLog("Auth result receive error: \(error)")
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

            // If we had an active session, reattach
            if let sessionId = activeSessionId {
                attachSession(sessionId)
            }
        } else {
            let error = json["error"] as? String ?? "unknown"
            NSLog("Auth failed: \(error)")
            state = .disconnected
        }
    }

    // MARK: - Pairing

    private func performPairing(host: String, port: UInt16, fingerprint: String, token: String, serverName: String) {
        client?.openStream { [weak self] stream in
            guard let self = self, let stream = stream else {
                Task { @MainActor in self?.state = .disconnected }
                return
            }
            Task { @MainActor in
                self.controlStream = stream
                self.sendPairingRequest(
                    on: stream, host: host, port: port,
                    fingerprint: fingerprint, token: token, serverName: serverName
                )
            }
        }
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

        guard let json = try? JSONSerialization.data(withJSONObject: request) else { return }

        stream.sendControlMessage(json) { [weak self] error in
            if let error = error {
                NSLog("Pairing send error: \(error)")
                Task { @MainActor in self?.state = .disconnected }
                return
            }
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
                            NSLog("Pairing failed: \(error)")
                            self?.state = .disconnected
                        }
                    }
                case .failure(let error):
                    NSLog("Pairing response error: \(error)")
                    Task { @MainActor in self?.state = .disconnected }
                }
            }
        }
    }

    // MARK: - Session Management

    func listSessions() {
        client?.openStream { [weak self] stream in
            guard let stream = stream else { return }
            let requestId = generateRequestId()
            let request: [String: Any] = [
                "type": "list_sessions",
                "request_id": requestId,
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: request) else { return }
            stream.sendControlMessage(json) { error in
                if let error = error {
                    NSLog("list_sessions send error: \(error)")
                    return
                }
                stream.receiveControlMessage { result in
                    switch result {
                    case .success(let data):
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let sessionsJson = json["sessions"] as? [[String: Any]] {
                            let sessions = sessionsJson.compactMap { s -> SessionInfo? in
                                guard let id = s["id"] as? String,
                                      let alive = s["alive"] as? Bool else { return nil }
                                return SessionInfo(
                                    id: id,
                                    alive: alive,
                                    createdAt: s["created_at"] as? String ?? "",
                                    shell: s["shell"] as? String,
                                    attached: s["attached"] as? Bool ?? false
                                )
                            }
                            Task { @MainActor in
                                self?.sessions = sessions
                            }
                        }
                        stream.cancel()
                    case .failure(let error):
                        NSLog("list_sessions receive error: \(error)")
                        stream.cancel()
                    }
                }
            }
        }
    }

    func createSession(rows: UInt16, cols: UInt16) {
        client?.openStream { [weak self] stream in
            guard let self = self, let stream = stream else { return }
            let requestId = generateRequestId()
            let request: [String: Any] = [
                "type": "create_session",
                "request_id": requestId,
                "rows": rows,
                "cols": cols,
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: request) else { return }
            stream.sendControlMessage(json) { error in
                if let error = error {
                    NSLog("create_session send error: \(error)")
                    return
                }
                stream.receiveControlMessage { result in
                    switch result {
                    case .success(let data):
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let sessionId = json["session_id"] as? String {
                            Task { @MainActor in
                                self.activeSessionId = sessionId
                                self.dataStream = stream
                                self.startFrameReceiving(on: stream)
                                self.replayBufferedKeystrokes()
                            }
                        }
                    case .failure(let error):
                        NSLog("create_session receive error: \(error)")
                        stream.cancel()
                    }
                }
            }
        }
    }

    func attachSession(_ sessionId: String) {
        client?.openStream { [weak self] stream in
            guard let self = self, let stream = stream else { return }
            let requestId = generateRequestId()
            let request: [String: Any] = [
                "type": "attach_session",
                "request_id": requestId,
                "session_id": sessionId,
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: request) else { return }
            stream.sendControlMessage(json) { error in
                if let error = error {
                    NSLog("attach_session send error: \(error)")
                    return
                }
                stream.receiveControlMessage { result in
                    switch result {
                    case .success(let data):
                        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           json["type"] as? String == "session_attached" {
                            Task { @MainActor in
                                self.activeSessionId = sessionId
                                self.dataStream?.cancel()
                                self.dataStream = stream
                                self.frameDecoder = FrameDecoder()
                                self.startFrameReceiving(on: stream)
                                self.replayBufferedKeystrokes()
                            }
                        }
                    case .failure(let error):
                        NSLog("attach_session receive error: \(error)")
                        stream.cancel()
                    }
                }
            }
        }
    }

    func destroySession(_ sessionId: String) {
        client?.openStream { [weak self] stream in
            guard let stream = stream else { return }
            let requestId = generateRequestId()
            let request: [String: Any] = [
                "type": "destroy_session",
                "request_id": requestId,
                "session_id": sessionId,
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: request) else { return }
            stream.sendControlMessage(json) { error in
                if error != nil { return }
                stream.receiveControlMessage { _ in
                    stream.cancel()
                    Task { @MainActor in
                        if self?.activeSessionId == sessionId {
                            self?.activeSessionId = nil
                            self?.dataStream?.cancel()
                            self?.dataStream = nil
                        }
                        self?.listSessions()
                    }
                }
            }
        }
    }

    // MARK: - Frame I/O

    func sendInput(_ data: Data) {
        if isBuffering || !state.isUsable || dataStream == nil {
            keystrokeBuffer.append(data)
            if !isBuffering { isBuffering = true }
            return
        }

        let frame = Frame.data(seq: seqOut, payload: data)
        seqOut += 1
        let compress = data.count > compressThreshold
        guard let encoded = try? encodeFrame(frame, compress: compress) else { return }

        dataStream?.send(content: encoded, completion: .contentProcessed { error in
            if let error = error {
                NSLog("Frame send error: \(error)")
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
                NSLog("Data stream FIN")
                Task { @MainActor in
                    self.dataStream = nil
                }
                return
            }
            if let error = error {
                NSLog("Data stream error: \(error)")
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
                    NSLog("Server sent Close frame")
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
            NSLog("Frame decode error: \(error)")
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
        let delay = delays[min(reconnectAttempt, delays.count - 1)]
        reconnectAttempt += 1

        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if state == .reconnecting {
                connect()
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
