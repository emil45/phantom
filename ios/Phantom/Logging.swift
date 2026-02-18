import os

extension Logger {
    static let quic = Logger(subsystem: "com.phantom", category: "quic")
    static let auth = Logger(subsystem: "com.phantom", category: "auth")
    static let session = Logger(subsystem: "com.phantom", category: "session")
    static let crypto = Logger(subsystem: "com.phantom", category: "crypto")
}
