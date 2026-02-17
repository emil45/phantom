import Foundation
import Network
import CryptoKit

/// QUIC tunnel manager using Network.framework's NWConnectionGroup.
/// Manages the QUIC connection (tunnel) and stream extraction.
/// Each extracted stream is an NWConnection representing a bidirectional QUIC stream.
final class QUICClient {
    private var group: NWConnectionGroup?
    private let host: String
    private let port: UInt16
    private let fingerprint: String? // SHA-256 base64 of server cert DER for pinning
    let queue = DispatchQueue(label: "phantom.quic", qos: .userInteractive)

    var onTunnelReady: (() -> Void)?
    var onTunnelFailed: ((Error?) -> Void)?

    init(host: String, port: UInt16, fingerprint: String? = nil) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
    }

    /// Establish the QUIC tunnel.
    func connect() {
        let options = NWProtocolQUIC.Options(alpn: ["phantom/1"])
        options.direction = .bidirectional

        // Certificate pinning via SHA-256 fingerprint
        let expectedFingerprint = self.fingerprint
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { metadata, trust, complete in
                if let fp = expectedFingerprint {
                    let valid = QUICClient.verifyCertFingerprint(trust: trust, expected: fp)
                    complete(valid)
                } else {
                    // No fingerprint — accept any cert (Simulator/dev only)
                    complete(true)
                }
            },
            queue
        )

        let params = NWParameters(quic: options)
        params.multipathServiceType = .handover

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )

        let descriptor = NWMultiplexGroup(to: endpoint)
        let group = NWConnectionGroup(with: descriptor, using: params)
        self.group = group

        group.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.onTunnelReady?()
            case .failed(let error):
                self?.onTunnelFailed?(error)
            case .cancelled:
                break
            case .waiting(let error):
                NSLog("QUIC tunnel waiting: \(error)")
            default:
                break
            }
        }

        group.start(queue: queue)
    }

    /// Open a new bidirectional QUIC stream within the tunnel.
    func openStream(completion: @escaping (NWConnection?) -> Void) {
        guard let group = group else {
            completion(nil)
            return
        }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )

        group.extract(connectionTo: endpoint, using: nil) { [weak self] stream in
            stream.start(queue: self?.queue ?? .main)
            completion(stream)
        }
    }

    func disconnect() {
        group?.cancel()
        group = nil
    }

    deinit {
        disconnect()
    }

    // MARK: - Certificate Fingerprint Verification

    private static func verifyCertFingerprint(trust: sec_trust_t, expected: String) -> Bool {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()

        guard SecTrustGetCertificateCount(secTrust) > 0 else { return false }

        // Get the leaf certificate
        if #available(iOS 15.0, *) {
            guard let certs = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate],
                  let leaf = certs.first else { return false }
            let der = SecCertificateCopyData(leaf) as Data
            let hash = SHA256.hash(data: der)
            let actual = Data(hash).base64EncodedString()
            return actual == expected
        } else {
            return false
        }
    }
}

// MARK: - Stream I/O Helpers

extension NWConnection {
    /// Send length-prefixed JSON on this stream.
    func sendControlMessage(_ json: Data, completion: @escaping (Error?) -> Void) {
        var buf = Data(capacity: 4 + json.count)
        var len = UInt32(json.count).bigEndian
        buf.append(UnsafeBufferPointer(start: &len, count: 1))
        buf.append(json)
        send(content: buf, completion: .contentProcessed { error in
            completion(error)
        })
    }

    /// Receive a length-prefixed JSON message from this stream.
    func receiveControlMessage(completion: @escaping (Result<Data, Error>) -> Void) {
        // First read the 4-byte length prefix
        receive(minimumIncompleteLength: 4, maximumLength: 4) { content, context, isComplete, error in
            if let error = error {
                completion(.failure(error))
                return
            }
            guard let lenData = content, lenData.count == 4 else {
                completion(.failure(QUICError.protocolError("incomplete length prefix")))
                return
            }
            let len = Int(lenData.readBigEndianUInt32(at: 0))
            guard len > 0, len <= 65536 else {
                completion(.failure(QUICError.protocolError("invalid message length: \(len)")))
                return
            }

            // Read the JSON body
            self.receive(minimumIncompleteLength: len, maximumLength: len) { content, context, isComplete, error in
                if let error = error {
                    completion(.failure(error))
                    return
                }
                guard let body = content, body.count == len else {
                    completion(.failure(QUICError.protocolError("incomplete message body")))
                    return
                }
                completion(.success(body))
            }
        }
    }

    /// Get the TLS security metadata for exporter keying material.
    /// Available from receive context after the connection is established.
    func exportKeyingMaterial(
        context receiveContext: NWConnection.ContentContext?,
        label: String,
        contextData: Data,
        length: Int
    ) -> Data? {
        guard let ctx = receiveContext,
              let tlsMeta = ctx.protocolMetadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata else {
            return nil
        }

        let secMeta = tlsMeta.securityProtocolMetadata

        let result: Data? = label.withCString { labelPtr in
            if contextData.isEmpty {
                // Use the version without context for empty context
                guard let exported = sec_protocol_metadata_create_secret(
                    secMeta,
                    label.count,
                    labelPtr,
                    length
                ) else { return nil }
                return dispatchDataToData(exported)
            } else {
                return contextData.withUnsafeBytes { contextBytes -> Data? in
                    guard let exported = sec_protocol_metadata_create_secret_with_context(
                        secMeta,
                        label.count,
                        labelPtr,
                        contextData.count,
                        contextBytes.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        length
                    ) else { return nil }
                    return dispatchDataToData(exported)
                }
            }
        }

        return result
    }
}

private func dispatchDataToData(_ dd: __DispatchData) -> Data {
    var result = Data()
    (dd as DispatchData).enumerateBytes { buffer, _, _ in
        result.append(contentsOf: buffer)
    }
    return result
}

enum QUICError: Error, LocalizedError {
    case notConnected
    case authFailed(String)
    case protocolError(String)
    case tunnelFailed

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected"
        case .authFailed(let msg): return "Auth failed: \(msg)"
        case .protocolError(let msg): return "Protocol error: \(msg)"
        case .tunnelFailed: return "QUIC tunnel failed"
        }
    }
}
