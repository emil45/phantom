import Foundation
import CryptoKit

/// Manages P256 key pair for device authentication.
/// Uses Secure Enclave on real devices, software keys on Simulator.
final class KeyManager {
    private var privateKey: SecureEnclave.P256.Signing.PrivateKey?
    private var softwareKey: P256.Signing.PrivateKey?

    /// Whether we're using Secure Enclave (real device) or software keys (Simulator).
    let usesSecureEnclave: Bool

    init() {
        usesSecureEnclave = SecureEnclave.isAvailable
        if usesSecureEnclave {
            loadOrCreateSecureEnclaveKey()
        } else {
            loadOrCreateSoftwareKey()
        }
    }

    // MARK: - Key Management

    private static let keyTag = "com.phantom.device.p256"
    private static let softwareKeyKey = "phantom.software.p256.key"

    private func loadOrCreateSecureEnclaveKey() {
        // Try to load existing key from Keychain
        if let existingKey = loadSecureEnclaveKey() {
            self.privateKey = existingKey
            return
        }
        // Create new key
        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(
                accessControl: SecAccessControlCreateWithFlags(
                    nil,
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                    .privateKeyUsage,
                    nil
                )!
            )
            self.privateKey = key
            saveSecureEnclaveKey(key)
        } catch {
            NSLog("KeyManager: failed to create SE key: \(error), falling back to software")
            loadOrCreateSoftwareKey()
        }
    }

    private func loadSecureEnclaveKey() -> SecureEnclave.P256.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keyTag,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
    }

    private func saveSecureEnclaveKey(_ key: SecureEnclave.P256.Signing.PrivateKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keyTag,
            kSecValueData as String: key.dataRepresentation,
        ]
        SecItemDelete(query as CFDictionary) // remove old if exists
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadOrCreateSoftwareKey() {
        if let keyData = UserDefaults.standard.data(forKey: Self.softwareKeyKey),
           let key = try? P256.Signing.PrivateKey(rawRepresentation: keyData) {
            self.softwareKey = key
            return
        }
        let key = P256.Signing.PrivateKey()
        UserDefaults.standard.set(key.rawRepresentation, forKey: Self.softwareKeyKey)
        self.softwareKey = key
    }

    // MARK: - Public Key Export

    /// Returns the public key as base64-encoded SEC1 (X9.63) representation.
    /// This is the format the daemon expects.
    var publicKeyBase64: String {
        if let key = privateKey {
            return key.publicKey.x963Representation.base64EncodedString()
        } else if let key = softwareKey {
            return key.publicKey.x963Representation.base64EncodedString()
        }
        fatalError("KeyManager: no key available")
    }

    // MARK: - Signing

    /// Sign data with the device's P256 private key.
    /// Returns DER-encoded signature (compatible with Rust p256 crate's from_der).
    func sign(_ data: Data) throws -> Data {
        if let key = privateKey {
            let signature = try key.signature(for: data)
            return signature.derRepresentation
        } else if let key = softwareKey {
            let signature = try key.signature(for: data)
            return signature.derRepresentation
        }
        throw KeyManagerError.noKeyAvailable
    }
}

enum KeyManagerError: Error {
    case noKeyAvailable
}
