import Foundation

/// Decoded QR code payload from `phantom pair`.
/// JSON format: {"host","port","fp","tok","name","v":1}
struct PairingPayload {
    let host: String
    let port: UInt16
    let fingerprint: String
    let token: String
    let serverName: String
    let version: Int

    /// Decode from QR code JSON string.
    static func decode(from jsonString: String) -> PairingPayload? {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let host = json["host"] as? String,
              let port = json["port"] as? Int,
              let fp = json["fp"] as? String,
              let tok = json["tok"] as? String,
              let name = json["name"] as? String,
              let v = json["v"] as? Int else {
            return nil
        }
        return PairingPayload(
            host: host,
            port: UInt16(port),
            fingerprint: fp,
            token: tok,
            serverName: name,
            version: v
        )
    }
}
