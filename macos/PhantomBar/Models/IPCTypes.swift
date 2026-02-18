import Foundation

// MARK: - Request / Response

struct IPCRequest: Encodable {
    let id: UInt64
    let method: String
    let params: [String: String]?

    init(id: UInt64, method: String, params: [String: String]? = nil) {
        self.id = id
        self.method = method
        self.params = params
    }
}

struct IPCResponse: Decodable {
    let id: UInt64
    let result: AnyCodable?
    let error: String?
}

// MARK: - Status

struct DaemonStatus: Decodable {
    let running: Bool
    let uptimeSecs: UInt64
    let version: String
    let bindAddress: String
    let certFingerprint: String
    let connectedDevices: [ConnectedDevice]

    enum CodingKeys: String, CodingKey {
        case running
        case uptimeSecs = "uptime_secs"
        case version
        case bindAddress = "bind_address"
        case certFingerprint = "cert_fingerprint"
        case connectedDevices = "connected_devices"
    }
}

struct ConnectedDevice: Decodable {
    let deviceId: String
    let deviceName: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceName = "device_name"
    }
}

// MARK: - Sessions

struct SessionInfo: Decodable, Identifiable {
    let id: String
    let alive: Bool
    let createdAt: String
    let shell: String
    let attached: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case alive
        case createdAt = "created_at"
        case shell
        case attached
    }
}

// MARK: - Devices

struct DeviceInfo: Decodable, Identifiable {
    let deviceId: String
    let deviceName: String
    let pairedAt: String
    let lastSeen: String?
    let isConnected: Bool

    var id: String { deviceId }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case deviceName = "device_name"
        case pairedAt = "paired_at"
        case lastSeen = "last_seen"
        case isConnected = "is_connected"
    }
}

// MARK: - Pairing

struct PairingInfo: Decodable {
    let qrPayloadJson: String
    let token: String
    let host: String
    let port: UInt16
    let fingerprint: String
    let expiresInSecs: UInt64

    enum CodingKeys: String, CodingKey {
        case qrPayloadJson = "qr_payload_json"
        case token
        case host
        case port
        case fingerprint
        case expiresInSecs = "expires_in_secs"
    }
}

// MARK: - Success

struct SuccessResult: Decodable {
    let success: Bool
}

// MARK: - AnyCodable (minimal, for untyped JSON result)

struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int64.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if container.decodeNil() {
            value = NSNull()
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported type")
        }
    }

    var jsonData: Data? {
        try? JSONSerialization.data(withJSONObject: value)
    }
}
