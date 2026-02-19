import Foundation

/// Actor that communicates with the Phantom daemon over a Unix domain socket.
actor DaemonClient {
    private let socketPath: String
    private var requestId: UInt64 = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        socketPath = "\(home)/.phantom/daemon.sock"
    }

    // MARK: - Public API

    func status() async throws -> DaemonStatus {
        let data = try await call(method: "status")
        return try decoder.decode(DaemonStatus.self, from: data)
    }

    func listSessions() async throws -> [SessionInfo] {
        let data = try await call(method: "list_sessions")
        return try decoder.decode([SessionInfo].self, from: data)
    }

    func listDevices() async throws -> [DeviceInfo] {
        let data = try await call(method: "list_devices")
        return try decoder.decode([DeviceInfo].self, from: data)
    }

    func createPairing() async throws -> PairingInfo {
        let data = try await call(method: "create_pairing")
        return try decoder.decode(PairingInfo.self, from: data)
    }

    func revokeDevice(deviceId: String) async throws {
        let data = try await call(method: "revoke_device", params: ["device_id": deviceId])
        let result = try decoder.decode(SuccessResult.self, from: data)
        if !result.success {
            throw IPCError.operationFailed("revoke_device returned success=false")
        }
    }

    func destroySession(sessionId: String) async throws {
        let data = try await call(method: "destroy_session", params: ["session_id": sessionId])
        let result = try decoder.decode(SuccessResult.self, from: data)
        if !result.success {
            throw IPCError.operationFailed("destroy_session returned success=false")
        }
    }

    // MARK: - Low-level

    private func call(method: String, params: [String: String]? = nil) async throws -> Data {
        requestId += 1
        let req = IPCRequest(id: requestId, method: method, params: params)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw IPCError.connectionFailed("socket() failed: \(errno)")
        }
        defer { close(fd) }

        // Set 5-second timeouts on send and receive to prevent hangs
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw IPCError.connectionFailed("socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for (i, byte) in pathBytes.enumerated() {
                    dest[i] = byte
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw IPCError.connectionFailed("connect() failed: \(errno)")
        }

        // Send request as JSON line
        var reqData = try encoder.encode(req)
        reqData.append(0x0A) // newline
        let sent = reqData.withUnsafeBytes { buf in
            Darwin.send(fd, buf.baseAddress!, buf.count, 0)
        }
        guard sent == reqData.count else {
            throw IPCError.sendFailed
        }

        // Read response line
        var responseData = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n <= 0 { break }
            responseData.append(contentsOf: buffer[..<n])
            if buffer[..<n].contains(0x0A) { break }
        }

        guard !responseData.isEmpty else {
            throw IPCError.emptyResponse
        }

        // Trim trailing newline
        if responseData.last == 0x0A {
            responseData.removeLast()
        }

        let response = try decoder.decode(IPCResponse.self, from: responseData)
        if let error = response.error {
            throw IPCError.serverError(error)
        }

        guard let result = response.result, let data = result.jsonData else {
            throw IPCError.emptyResponse
        }
        return data
    }
}

enum IPCError: LocalizedError {
    case connectionFailed(String)
    case sendFailed
    case emptyResponse
    case serverError(String)
    case operationFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .sendFailed: return "Failed to send request"
        case .emptyResponse: return "Empty response from daemon"
        case .serverError(let msg): return "Daemon error: \(msg)"
        case .operationFailed(let msg): return "Operation failed: \(msg)"
        }
    }
}
