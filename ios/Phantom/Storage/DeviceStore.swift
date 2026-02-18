import Foundation

/// Persists paired server configuration and device identity.
/// Backed by UserDefaults for simplicity (no sensitive data — keys are in Secure Enclave).
final class DeviceStore {
    private let defaults = UserDefaults.standard
    /// Cached device ID (generated once, thread-safe via init)
    let deviceId: String

    private enum Keys {
        static let serverHost = "phantom.server.host"
        static let serverPort = "phantom.server.port"
        static let serverFingerprint = "phantom.server.fingerprint"
        static let serverName = "phantom.server.name"
        static let deviceId = "phantom.device.id"
        static let isPaired = "phantom.isPaired"
    }

    init() {
        let defaults = UserDefaults.standard
        if let id = defaults.string(forKey: Keys.deviceId) {
            self.deviceId = id
        } else {
            let id = UUID().uuidString.lowercased()
            defaults.set(id, forKey: Keys.deviceId)
            self.deviceId = id
        }
    }

    var isPaired: Bool {
        defaults.bool(forKey: Keys.isPaired)
    }

    var serverHost: String? {
        defaults.string(forKey: Keys.serverHost)
    }

    var serverPort: UInt16 {
        UInt16(defaults.integer(forKey: Keys.serverPort))
    }

    var serverFingerprint: String? {
        defaults.string(forKey: Keys.serverFingerprint)
    }

    var serverName: String? {
        defaults.string(forKey: Keys.serverName)
    }

    func savePairing(host: String, port: UInt16, fingerprint: String, serverName: String) {
        defaults.set(host, forKey: Keys.serverHost)
        defaults.set(Int(port), forKey: Keys.serverPort)
        defaults.set(fingerprint, forKey: Keys.serverFingerprint)
        defaults.set(serverName, forKey: Keys.serverName)
        defaults.set(true, forKey: Keys.isPaired)
    }

    func clearPairing() {
        defaults.removeObject(forKey: Keys.serverHost)
        defaults.removeObject(forKey: Keys.serverPort)
        defaults.removeObject(forKey: Keys.serverFingerprint)
        defaults.removeObject(forKey: Keys.serverName)
        defaults.removeObject(forKey: Keys.isPaired)
    }
}
