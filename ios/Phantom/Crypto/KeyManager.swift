import Foundation
import CryptoKit
import os

/// Manages P256 key pair for device authentication.
/// Uses Secure Enclave on real devices, Keychain-backed software keys on Simulator.
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
    private static let softwareKeyService = "com.phantom.device.p256.software"

    private func loadOrCreateSecureEnclaveKey() {
        if let existingKey = loadSecureEnclaveKey() {
            self.privateKey = existingKey
            return
        }
        do {
            var flags: SecAccessControlCreateFlags = .privateKeyUsage
            if !isSimulator {
                flags.insert(.userPresence)
            }
            let key = try SecureEnclave.P256.Signing.PrivateKey(
                accessControl: SecAccessControlCreateWithFlags(
                    nil,
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                    flags,
                    nil
                )!
            )
            self.privateKey = key
            saveSecureEnclaveKey(key)
        } catch {
            Logger.crypto.error("failed to create SE key: \(error.localizedDescription), falling back to software")
            loadOrCreateSoftwareKey()
        }
    }

    private var isSimulator: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
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
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    private func loadOrCreateSoftwareKey() {
        // Load from Keychain instead of UserDefaults
        if let key = loadSoftwareKeyFromKeychain() {
            self.softwareKey = key
            return
        }
        // Migrate from legacy UserDefaults storage
        if let key = migrateLegacySoftwareKey() {
            self.softwareKey = key
            return
        }
        let key = P256.Signing.PrivateKey()
        saveSoftwareKeyToKeychain(key)
        self.softwareKey = key
    }

    private func loadSoftwareKeyFromKeychain() -> P256.Signing.PrivateKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.softwareKeyService,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return try? P256.Signing.PrivateKey(rawRepresentation: data)
    }

    private func saveSoftwareKeyToKeychain(_ key: P256.Signing.PrivateKey) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.softwareKeyService,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: key.rawRepresentation,
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(query as CFDictionary, nil)
    }

    /// Migrate key from UserDefaults to Keychain (one-time).
    private func migrateLegacySoftwareKey() -> P256.Signing.PrivateKey? {
        let legacyKey = "phantom.software.p256.key"
        guard let keyData = UserDefaults.standard.data(forKey: legacyKey),
              let key = try? P256.Signing.PrivateKey(rawRepresentation: keyData) else {
            return nil
        }
        saveSoftwareKeyToKeychain(key)
        UserDefaults.standard.removeObject(forKey: legacyKey)
        return key
    }

    // MARK: - Public Key Export

    var publicKeyBase64: String {
        if let key = privateKey {
            return key.publicKey.x963Representation.base64EncodedString()
        } else if let key = softwareKey {
            return key.publicKey.x963Representation.base64EncodedString()
        }
        fatalError("KeyManager: no key available")
    }

    // MARK: - Signing

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
