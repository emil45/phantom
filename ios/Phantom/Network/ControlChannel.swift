import Foundation

// MARK: - Control Message Types

/// All control messages have a `type` and `request_id` field.
/// Sent as length-prefixed JSON over QUIC streams.

struct SessionInfo: Codable, Identifiable {
    let id: String
    let alive: Bool
    let createdAt: String
    let shell: String?
    let attached: Bool
    let createdByDeviceId: String?
    let lastAttachedAt: String?
    let lastAttachedBy: String?
    let lastActivityAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case alive
        case createdAt = "created_at"
        case shell
        case attached
        case createdByDeviceId = "created_by_device_id"
        case lastAttachedAt = "last_attached_at"
        case lastAttachedBy = "last_attached_by"
        case lastActivityAt = "last_activity_at"
    }

    init(id: String, alive: Bool, createdAt: String, shell: String?, attached: Bool,
         createdByDeviceId: String? = nil, lastAttachedAt: String? = nil,
         lastAttachedBy: String? = nil, lastActivityAt: String? = nil) {
        self.id = id
        self.alive = alive
        self.createdAt = createdAt
        self.shell = shell
        self.attached = attached
        self.createdByDeviceId = createdByDeviceId
        self.lastAttachedAt = lastAttachedAt
        self.lastAttachedBy = lastAttachedBy
        self.lastActivityAt = lastActivityAt
    }
}

// MARK: - Request ID Generator

func generateRequestId() -> String {
    UUID().uuidString.lowercased().prefix(8).description
}
