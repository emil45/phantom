import Foundation
import Network
import CryptoKit
import os

/// QUIC client using Network.framework.
/// Uses NWConnection directly — each connection is a QUIC stream within the same tunnel.
/// The first connection establishes the QUIC tunnel and acts as the first bidi stream.
final class QUICClient {
    private var tunnelConnection: NWConnection?
    private let host: String
    private let port: UInt16
    private let fingerprint: String?
    let queue = DispatchQueue(label: "phantom.quic", qos: .userInteractive)

    var onTunnelReady: (() -> Void)?
    var onTunnelFailed: ((Error?) -> Void)?

    /// The first connection doubles as the QUIC tunnel and first bidi stream.
    /// After tunnel is ready, callers can use this directly or open new streams.
    var firstStream: NWConnection? { tunnelConnection }

    init(host: String, port: UInt16, fingerprint: String? = nil) {
        self.host = host
        self.port = port
        self.fingerprint = fingerprint
    }

    /// Establish the QUIC tunnel. The first NWConnection becomes both
    /// the QUIC connection and the first bidirectional stream.
    func connect() {
        let options = NWProtocolQUIC.Options(alpn: ["phantom/1"])
        options.direction = .bidirectional
        options.idleTimeout = 90_000 // 90 seconds (ms) — daemon uses 60s, be generous

        let expectedFingerprint = self.fingerprint
        sec_protocol_options_set_verify_block(
            options.securityProtocolOptions,
            { metadata, trust, complete in
                if let fp = expectedFingerprint {
                    let valid = QUICClient.verifyCertFingerprint(trust: trust, expected: fp)
                    complete(valid)
                } else {
                    complete(true)
                }
            },
            queue
        )

        let params = NWParameters(quic: options)
        params.multipathServiceType = .disabled

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )

        let connection = NWConnection(to: endpoint, using: params)
        self.tunnelConnection = connection

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                Logger.quic.info("QUICClient: tunnel + first stream ready")
                self?.onTunnelReady?()
            case .failed(let error):
                Logger.quic.error("tunnel failed: \(error)")
                self?.onTunnelFailed?(error)
            case .cancelled:
                break
            case .waiting(let error):
                Logger.quic.warning("tunnel waiting: \(error)")
            default:
                break
            }
        }

        connection.start(queue: queue)
    }

    /// Return the first stream (the tunnel connection itself).
    /// For the control channel, this is all we need.
    func openStream(completion: @escaping (NWConnection?) -> Void) {
        guard let conn = tunnelConnection else {
            completion(nil)
            return
        }
        // Set handler first to avoid race between state check and handler install.
        // Use a flag to ensure completion is only called once.
        var called = false
        let prevHandler = conn.stateUpdateHandler
        conn.stateUpdateHandler = { [weak self] state in
            prevHandler?(state)
            if state == .ready && !called {
                called = true
                completion(conn)
            }
        }
        // If already ready, fire immediately (handler won't fire again for .ready)
        if conn.state == .ready && !called {
            called = true
            completion(conn)
        }
    }

    func disconnect() {
        tunnelConnection?.cancel()
        tunnelConnection = nil
    }

    deinit {
        disconnect()
    }

    // MARK: - Certificate Fingerprint Verification

    private static func verifyCertFingerprint(trust: sec_trust_t, expected: String) -> Bool {
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()

        guard SecTrustGetCertificateCount(secTrust) > 0 else { return false }

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
            let labelLen = label.utf8.count
            if contextData.isEmpty {
                guard let exported = sec_protocol_metadata_create_secret(
                    secMeta,
                    labelLen,
                    labelPtr,
                    length
                ) else { return nil }
                return dispatchDataToData(exported)
            } else {
                return contextData.withUnsafeBytes { contextBytes -> Data? in
                    guard let exported = sec_protocol_metadata_create_secret_with_context(
                        secMeta,
                        labelLen,
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
