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

    enum CodingKeys: String, CodingKey {
        case id
        case alive
        case createdAt = "created_at"
        case shell
        case attached
    }

    init(id: String, alive: Bool, createdAt: String, shell: String?, attached: Bool) {
        self.id = id
        self.alive = alive
        self.createdAt = createdAt
        self.shell = shell
        self.attached = attached
    }
}

// MARK: - Request ID Generator

func generateRequestId() -> String {
    UUID().uuidString.lowercased().prefix(8).description
}
