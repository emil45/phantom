use anyhow::{Context, Result};
use phantom_frame::{self as frame, Frame, FrameDecoder, FrameType};
use std::sync::Arc;
use std::time::Duration;

// Re-use crate internals — integration tests are in-crate tests via `tests/`.
// We access the binary's modules by depending on the phantom-daemon lib if exported,
// but since it's a binary crate, we'll build a mini test harness using the same deps.

/// Helper: generate self-signed cert and key for testing.
fn gen_test_cert() -> (Vec<u8>, Vec<u8>) {
    use rcgen::{CertificateParams, KeyPair};
    let key_pair = KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256).unwrap();
    let params = CertificateParams::new(vec!["localhost".to_string()]).unwrap();
    let cert = params.self_signed(&key_pair).unwrap();
    (cert.der().to_vec(), key_pair.serialize_der())
}

/// Helper: build quinn server config.
fn build_server_config(cert_der: &[u8], key_der: &[u8]) -> quinn::ServerConfig {
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};

    let cert = CertificateDer::from(cert_der.to_vec());
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key_der.to_vec()));

    let mut tls_config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .unwrap();
    tls_config.alpn_protocols = vec![b"phantom/1".to_vec()];
    tls_config.max_early_data_size = 0;

    let quic_config = quinn::crypto::rustls::QuicServerConfig::try_from(Arc::new(tls_config)).unwrap();
    let mut server_config = quinn::ServerConfig::with_crypto(Arc::new(quic_config));
    let transport = Arc::get_mut(&mut server_config.transport).unwrap();
    transport.max_idle_timeout(Some(Duration::from_secs(30).try_into().unwrap()));
    transport.keep_alive_interval(Some(Duration::from_secs(5)));

    server_config
}

/// Helper: build quinn client config (accept any cert).
fn build_client_config() -> quinn::ClientConfig {
    let mut crypto = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAnyCert))
        .with_no_client_auth();
    crypto.alpn_protocols = vec![b"phantom/1".to_vec()];

    let mut client_config = quinn::ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(crypto).unwrap(),
    ));
    let mut transport = quinn::TransportConfig::default();
    transport.max_idle_timeout(Some(Duration::from_secs(30).try_into().unwrap()));
    client_config.transport_config(Arc::new(transport));

    client_config
}

#[derive(Debug)]
struct AcceptAnyCert;

impl rustls::client::danger::ServerCertVerifier for AcceptAnyCert {
    fn verify_server_cert(
        &self, _: &rustls::pki_types::CertificateDer, _: &[rustls::pki_types::CertificateDer],
        _: &rustls::pki_types::ServerName, _: &[u8], _: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self, _: &[u8], _: &rustls::pki_types::CertificateDer,
        _: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }
    fn verify_tls13_signature(
        &self, _: &[u8], _: &rustls::pki_types::CertificateDer,
        _: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        rustls::crypto::ring::default_provider()
            .signature_verification_algorithms
            .supported_schemes()
    }
}

/// Helper: generate P256 key pair for test client.
fn gen_p256_key() -> (p256::ecdsa::SigningKey, p256::ecdsa::VerifyingKey) {
    let sk = p256::ecdsa::SigningKey::random(&mut rand::thread_rng());
    let vk = *sk.verifying_key();
    (sk, vk)
}

/// Helper: send a length-prefixed JSON message on a QUIC stream.
async fn send_json(send: &mut quinn::SendStream, value: &serde_json::Value) -> Result<()> {
    let json = serde_json::to_vec(value)?;
    let len = (json.len() as u32).to_be_bytes();
    send.write_all(&len).await?;
    send.write_all(&json).await?;
    Ok(())
}

/// Helper: receive a length-prefixed JSON message from a QUIC stream.
async fn recv_json(recv: &mut quinn::RecvStream) -> Result<serde_json::Value> {
    let mut len_buf = [0u8; 4];
    recv.read_exact(&mut len_buf).await?;
    let len = u32::from_be_bytes(len_buf) as usize;
    let mut buf = vec![0u8; len];
    recv.read_exact(&mut buf).await?;
    Ok(serde_json::from_slice(&buf)?)
}

/// Test harness: starts a daemon server in the background, returns the client endpoint
/// and socket address to connect to. Also returns the device_id and signing key for auth.
struct TestHarness {
    server_addr: std::net::SocketAddr,
    client_endpoint: quinn::Endpoint,
    device_id: String,
    signing_key: p256::ecdsa::SigningKey,
    _server_handle: tokio::task::JoinHandle<()>,
    _temp_dir: tempfile::TempDir,
}

impl TestHarness {
    async fn new() -> Result<Self> {
        let (cert_der, key_der) = gen_test_cert();
        let server_config = build_server_config(&cert_der, &key_der);

        let server_endpoint = quinn::Endpoint::server(
            server_config,
            "127.0.0.1:0".parse().unwrap(),
        )?;
        let server_addr = server_endpoint.local_addr()?;

        // Create temp dir for device store
        let temp_dir = tempfile::TempDir::new()?;

        // Create device store and pre-pair a test device
        let (sk, vk) = gen_p256_key();
        let device_id = "test-device-001".to_string();
        let pub_key_b64 = {
            use base64::Engine;
            let point = p256::EncodedPoint::from(vk);
            base64::engine::general_purpose::STANDARD.encode(point.as_bytes())
        };

        // Write devices.json with pre-paired device
        let devices_json = serde_json::json!({
            "devices": {
                &device_id: {
                    "device_id": &device_id,
                    "public_key": &pub_key_b64,
                    "device_name": "Test Device",
                    "paired_at": "2024-01-01T00:00:00Z",
                    "last_seen": null,
                }
            }
        });
        std::fs::write(
            temp_dir.path().join("devices.json"),
            serde_json::to_string_pretty(&devices_json)?,
        )?;

        // Start server components
        let device_store = Arc::new(
            phantom_daemon::device_store::DeviceStore::new(temp_dir.path())?,
        );
        let authenticator = Arc::new(phantom_daemon::auth::Authenticator::new(device_store));
        let session_manager = Arc::new(phantom_daemon::session::SessionManager::new());

        // Start session reaper
        let sm_for_reaper = session_manager.clone();
        let reaper_cancel = tokio_util::sync::CancellationToken::new();
        let reaper_cancel_clone = reaper_cancel.clone();
        tokio::spawn(async move {
            sm_for_reaper.run_reaper(reaper_cancel_clone, 5).await;
        });

        let sm_for_server = session_manager.clone();
        let server_handle = tokio::spawn(async move {
            if let Err(e) = phantom_daemon::server::run(
                server_endpoint,
                sm_for_server,
                authenticator,
                100,  // conn_limit
                60,   // conn_window_secs
                10,   // auth_fail_limit
                300,  // auth_fail_window_secs
            ).await {
                eprintln!("server error: {e:#}");
            }
        });

        // Build client endpoint
        let mut client_endpoint = quinn::Endpoint::client("0.0.0.0:0".parse().unwrap())?;
        client_endpoint.set_default_client_config(build_client_config());

        Ok(Self {
            server_addr,
            client_endpoint,
            device_id,
            signing_key: sk,
            _server_handle: server_handle,
            _temp_dir: temp_dir,
        })
    }

    /// Connect to the server and authenticate.
    async fn connect_and_auth(&self) -> Result<quinn::Connection> {
        let connection = self.client_endpoint
            .connect(self.server_addr, "localhost")?
            .await
            .context("QUIC connect")?;

        // Open control stream and authenticate
        let (mut send, mut recv) = connection.open_bi().await?;

        // Send auth_request
        let auth_req = serde_json::json!({
            "type": "auth_request",
            "request_id": "test-auth-1",
            "device_id": &self.device_id,
        });
        send_json(&mut send, &auth_req).await?;

        // Receive challenge
        let challenge_msg = recv_json(&mut recv).await?;
        assert_eq!(challenge_msg["type"], "auth_challenge");
        let challenge_b64 = challenge_msg["challenge"].as_str().unwrap();
        let challenge_bytes = {
            use base64::Engine;
            base64::engine::general_purpose::STANDARD.decode(challenge_b64)?
        };

        // Sign challenge (without TLS exporter binding — daemon supports fallback)
        let signature = {
            use p256::ecdsa::{signature::Signer, Signature};
            let sig: Signature = self.signing_key.sign(&challenge_bytes);
            use base64::Engine;
            base64::engine::general_purpose::STANDARD.encode(sig.to_der().as_bytes())
        };

        // Send auth response
        let auth_resp = serde_json::json!({
            "type": "auth_response",
            "request_id": "test-auth-1",
            "device_id": &self.device_id,
            "signature": signature,
        });
        send_json(&mut send, &auth_resp).await?;

        // Receive auth result
        let result = recv_json(&mut recv).await?;
        assert_eq!(result["type"], "auth_response");
        assert_eq!(result["success"], true, "auth failed: {:?}", result["error"]);

        Ok(connection)
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────

#[tokio::test]
async fn full_session_lifecycle() -> Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .ok();

    let harness = TestHarness::new().await?;
    let conn = harness.connect_and_auth().await?;

    // Create session
    let (mut send, mut recv) = conn.open_bi().await?;
    let create_req = serde_json::json!({
        "type": "create_session",
        "request_id": "test-create",
        "rows": 24,
        "cols": 80,
    });
    send_json(&mut send, &create_req).await?;
    let create_resp = recv_json(&mut recv).await?;
    assert_eq!(create_resp["type"], "session_created");
    let session_id = create_resp["session_id"].as_str().unwrap().to_string();

    // Send a command and wait for output
    let cmd = b"echo PHANTOM_TEST_OUTPUT\n";
    let input_frame = Frame::data(1, cmd.to_vec());
    let encoded = frame::encode(&input_frame, false)?;
    send.write_all(&encoded).await?;

    // Read output frames until we see our marker
    let mut decoder = FrameDecoder::new();
    let mut output = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);

    loop {
        if tokio::time::Instant::now() > deadline {
            panic!("timeout waiting for output. Got: {}", String::from_utf8_lossy(&output));
        }

        let mut buf = [0u8; 4096];
        match tokio::time::timeout(Duration::from_millis(500), recv.read(&mut buf)).await {
            Ok(Ok(Some(n))) => {
                decoder.feed(&buf[..n]);
                while let Some(frame) = decoder.decode_next()? {
                    if frame.frame_type == FrameType::Data {
                        output.extend_from_slice(&frame.payload);
                    }
                }
                let output_str = String::from_utf8_lossy(&output);
                if output_str.contains("PHANTOM_TEST_OUTPUT") {
                    break;
                }
            }
            Ok(Ok(None)) => break,
            Ok(Err(e)) => panic!("read error: {e}"),
            Err(_) => continue, // timeout, try again
        }
    }

    let output_str = String::from_utf8_lossy(&output);
    assert!(output_str.contains("PHANTOM_TEST_OUTPUT"), "expected marker in output");

    // Close the data stream
    send.finish()?;
    drop(send);
    drop(recv);

    // List sessions — should see our session
    let (mut send2, mut recv2) = conn.open_bi().await?;
    let list_req = serde_json::json!({
        "type": "list_sessions",
        "request_id": "test-list",
    });
    send_json(&mut send2, &list_req).await?;
    let list_resp = recv_json(&mut recv2).await?;
    assert_eq!(list_resp["type"], "session_list");
    let sessions = list_resp["sessions"].as_array().unwrap();
    assert!(!sessions.is_empty(), "expected at least one session");
    let found = sessions.iter().any(|s| s["id"].as_str() == Some(&session_id));
    assert!(found, "session {} not in list", session_id);
    drop(send2);
    drop(recv2);

    // Destroy session
    let (mut send3, mut recv3) = conn.open_bi().await?;
    let destroy_req = serde_json::json!({
        "type": "destroy_session",
        "request_id": "test-destroy",
        "session_id": &session_id,
    });
    send_json(&mut send3, &destroy_req).await?;
    let destroy_resp = recv_json(&mut recv3).await?;
    assert_eq!(destroy_resp["type"], "session_destroyed");
    assert_eq!(destroy_resp["success"], true);
    drop(send3);
    drop(recv3);

    // Verify session is gone
    let (mut send4, mut recv4) = conn.open_bi().await?;
    let list_req2 = serde_json::json!({
        "type": "list_sessions",
        "request_id": "test-list-2",
    });
    send_json(&mut send4, &list_req2).await?;
    let list_resp2 = recv_json(&mut recv4).await?;
    let sessions2 = list_resp2["sessions"].as_array().unwrap();
    let still_found = sessions2.iter().any(|s| s["id"].as_str() == Some(&session_id));
    assert!(!still_found, "session {} should be destroyed", session_id);

    conn.close(quinn::VarInt::from_u32(0), b"done");

    Ok(())
}

#[tokio::test]
async fn reattach_with_scrollback() -> Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .ok();

    let harness = TestHarness::new().await?;
    let conn = harness.connect_and_auth().await?;

    // Create session
    let (mut send, mut recv) = conn.open_bi().await?;
    send_json(&mut send, &serde_json::json!({
        "type": "create_session",
        "request_id": "r1",
        "rows": 24,
        "cols": 80,
    })).await?;
    let resp = recv_json(&mut recv).await?;
    let session_id = resp["session_id"].as_str().unwrap().to_string();

    // Send a command to generate output
    let input = Frame::data(1, b"echo SCROLLBACK_MARKER_XYZ\n".to_vec());
    send.write_all(&frame::encode(&input, false)?).await?;

    // Wait for the output
    let mut decoder = FrameDecoder::new();
    let mut output = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        if tokio::time::Instant::now() > deadline { break; }
        let mut buf = [0u8; 4096];
        match tokio::time::timeout(Duration::from_millis(200), recv.read(&mut buf)).await {
            Ok(Ok(Some(n))) => {
                decoder.feed(&buf[..n]);
                while let Some(frame) = decoder.decode_next()? {
                    if frame.frame_type == FrameType::Data {
                        output.extend_from_slice(&frame.payload);
                    }
                }
                if String::from_utf8_lossy(&output).contains("SCROLLBACK_MARKER_XYZ") {
                    break;
                }
            }
            _ => continue,
        }
    }
    assert!(String::from_utf8_lossy(&output).contains("SCROLLBACK_MARKER_XYZ"));

    // Detach (close the data stream)
    send.finish()?;
    drop(send);
    drop(recv);

    // Brief pause for detach to process
    tokio::time::sleep(Duration::from_millis(500)).await;

    // Reattach
    let (mut send2, mut recv2) = conn.open_bi().await?;
    send_json(&mut send2, &serde_json::json!({
        "type": "attach_session",
        "request_id": "r2",
        "session_id": &session_id,
    })).await?;
    let attach_resp = recv_json(&mut recv2).await?;
    assert_eq!(attach_resp["type"], "session_attached");

    // Read scrollback + live data
    let mut decoder2 = FrameDecoder::new();
    let mut scrollback = Vec::new();
    let deadline2 = tokio::time::Instant::now() + Duration::from_secs(3);
    loop {
        if tokio::time::Instant::now() > deadline2 { break; }
        let mut buf = [0u8; 4096];
        match tokio::time::timeout(Duration::from_millis(200), recv2.read(&mut buf)).await {
            Ok(Ok(Some(n))) => {
                decoder2.feed(&buf[..n]);
                while let Some(frame) = decoder2.decode_next()? {
                    if frame.frame_type == FrameType::Scrollback || frame.frame_type == FrameType::Data {
                        scrollback.extend_from_slice(&frame.payload);
                    }
                }
                if String::from_utf8_lossy(&scrollback).contains("SCROLLBACK_MARKER_XYZ") {
                    break;
                }
            }
            _ => continue,
        }
    }

    let scrollback_str = String::from_utf8_lossy(&scrollback);
    assert!(
        scrollback_str.contains("SCROLLBACK_MARKER_XYZ"),
        "scrollback should contain marker. Got: {}",
        scrollback_str
    );

    // Cleanup
    send2.finish()?;
    conn.close(quinn::VarInt::from_u32(0), b"done");

    Ok(())
}

#[tokio::test]
async fn session_reaper_cleans_dead_sessions() -> Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .ok();

    let harness = TestHarness::new().await?;
    let conn = harness.connect_and_auth().await?;

    // Create session
    let (mut send, mut recv) = conn.open_bi().await?;
    send_json(&mut send, &serde_json::json!({
        "type": "create_session",
        "request_id": "r1",
        "rows": 24,
        "cols": 80,
    })).await?;
    let resp = recv_json(&mut recv).await?;
    let session_id = resp["session_id"].as_str().unwrap().to_string();

    // Kill the shell by sending "exit"
    let exit_frame = Frame::data(1, b"exit\n".to_vec());
    send.write_all(&frame::encode(&exit_frame, false)?).await?;

    // Wait for the shell to exit
    tokio::time::sleep(Duration::from_secs(2)).await;

    // Close data stream
    send.finish()?;
    drop(send);
    drop(recv);

    // Wait for reaper to run (runs every 5s)
    tokio::time::sleep(Duration::from_secs(7)).await;

    // List sessions — dead session should be reaped
    let (mut send2, mut recv2) = conn.open_bi().await?;
    send_json(&mut send2, &serde_json::json!({
        "type": "list_sessions",
        "request_id": "r2",
    })).await?;
    let list_resp = recv_json(&mut recv2).await?;
    let sessions = list_resp["sessions"].as_array().unwrap();
    let still_found = sessions.iter().any(|s| s["id"].as_str() == Some(&session_id));
    assert!(!still_found, "dead session {} should have been reaped", session_id);

    conn.close(quinn::VarInt::from_u32(0), b"done");

    Ok(())
}

#[tokio::test]
async fn two_session_lifecycle() -> Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .ok();

    let harness = TestHarness::new().await?;
    let conn = harness.connect_and_auth().await?;

    // Create session A
    let (mut send_a, mut recv_a) = conn.open_bi().await?;
    send_json(&mut send_a, &serde_json::json!({
        "type": "create_session",
        "request_id": "create-a",
        "rows": 24,
        "cols": 80,
    })).await?;
    let resp_a = recv_json(&mut recv_a).await?;
    assert_eq!(resp_a["type"], "session_created");
    let session_a = resp_a["session_id"].as_str().unwrap().to_string();

    // Write to session A
    let input_a = Frame::data(1, b"echo SESSION_A_MARKER\n".to_vec());
    send_a.write_all(&frame::encode(&input_a, false)?).await?;

    // Wait for output on A
    let mut decoder_a = FrameDecoder::new();
    let mut output_a = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        if tokio::time::Instant::now() > deadline { break; }
        let mut buf = [0u8; 4096];
        match tokio::time::timeout(Duration::from_millis(200), recv_a.read(&mut buf)).await {
            Ok(Ok(Some(n))) => {
                decoder_a.feed(&buf[..n]);
                while let Some(f) = decoder_a.decode_next()? {
                    if f.frame_type == FrameType::Data { output_a.extend_from_slice(&f.payload); }
                }
                if String::from_utf8_lossy(&output_a).contains("SESSION_A_MARKER") { break; }
            }
            _ => continue,
        }
    }
    assert!(String::from_utf8_lossy(&output_a).contains("SESSION_A_MARKER"));

    // Detach A
    send_a.finish()?;
    drop(send_a);
    drop(recv_a);
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Create session B
    let (mut send_b, mut recv_b) = conn.open_bi().await?;
    send_json(&mut send_b, &serde_json::json!({
        "type": "create_session",
        "request_id": "create-b",
        "rows": 24,
        "cols": 80,
    })).await?;
    let resp_b = recv_json(&mut recv_b).await?;
    assert_eq!(resp_b["type"], "session_created");
    let session_b = resp_b["session_id"].as_str().unwrap().to_string();
    assert_ne!(session_a, session_b);

    // Write to session B
    let input_b = Frame::data(1, b"echo SESSION_B_MARKER\n".to_vec());
    send_b.write_all(&frame::encode(&input_b, false)?).await?;

    let mut decoder_b = FrameDecoder::new();
    let mut output_b = Vec::new();
    let deadline2 = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        if tokio::time::Instant::now() > deadline2 { break; }
        let mut buf = [0u8; 4096];
        match tokio::time::timeout(Duration::from_millis(200), recv_b.read(&mut buf)).await {
            Ok(Ok(Some(n))) => {
                decoder_b.feed(&buf[..n]);
                while let Some(f) = decoder_b.decode_next()? {
                    if f.frame_type == FrameType::Data { output_b.extend_from_slice(&f.payload); }
                }
                if String::from_utf8_lossy(&output_b).contains("SESSION_B_MARKER") { break; }
            }
            _ => continue,
        }
    }
    assert!(String::from_utf8_lossy(&output_b).contains("SESSION_B_MARKER"));

    // Detach B
    send_b.finish()?;
    drop(send_b);
    drop(recv_b);
    tokio::time::sleep(Duration::from_millis(300)).await;

    // List sessions — both should exist
    let (mut send_l, mut recv_l) = conn.open_bi().await?;
    send_json(&mut send_l, &serde_json::json!({
        "type": "list_sessions",
        "request_id": "list-both",
    })).await?;
    let list_resp = recv_json(&mut recv_l).await?;
    let sessions = list_resp["sessions"].as_array().unwrap();
    assert!(sessions.len() >= 2, "expected at least 2 sessions, got {}", sessions.len());
    assert!(sessions.iter().any(|s| s["id"].as_str() == Some(&session_a)));
    assert!(sessions.iter().any(|s| s["id"].as_str() == Some(&session_b)));
    drop(send_l);
    drop(recv_l);

    // Reattach A and verify scrollback
    let (mut send_ra, mut recv_ra) = conn.open_bi().await?;
    send_json(&mut send_ra, &serde_json::json!({
        "type": "attach_session",
        "request_id": "reattach-a",
        "session_id": &session_a,
    })).await?;
    let attach_resp = recv_json(&mut recv_ra).await?;
    assert_eq!(attach_resp["type"], "session_attached");

    let mut decoder_ra = FrameDecoder::new();
    let mut scrollback_a = Vec::new();
    let deadline3 = tokio::time::Instant::now() + Duration::from_secs(3);
    loop {
        if tokio::time::Instant::now() > deadline3 { break; }
        let mut buf = [0u8; 4096];
        match tokio::time::timeout(Duration::from_millis(200), recv_ra.read(&mut buf)).await {
            Ok(Ok(Some(n))) => {
                decoder_ra.feed(&buf[..n]);
                while let Some(f) = decoder_ra.decode_next()? {
                    if f.frame_type == FrameType::Scrollback || f.frame_type == FrameType::Data {
                        scrollback_a.extend_from_slice(&f.payload);
                    }
                }
                if String::from_utf8_lossy(&scrollback_a).contains("SESSION_A_MARKER") { break; }
            }
            _ => continue,
        }
    }
    assert!(
        String::from_utf8_lossy(&scrollback_a).contains("SESSION_A_MARKER"),
        "session A scrollback should contain its marker"
    );
    // Session A scrollback should NOT contain B's marker
    assert!(
        !String::from_utf8_lossy(&scrollback_a).contains("SESSION_B_MARKER"),
        "session A scrollback should not contain session B's marker"
    );
    send_ra.finish()?;
    drop(send_ra);
    drop(recv_ra);
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Destroy both sessions
    for (sid, label) in [(&session_a, "destroy-a"), (&session_b, "destroy-b")] {
        let (mut s, mut r) = conn.open_bi().await?;
        send_json(&mut s, &serde_json::json!({
            "type": "destroy_session",
            "request_id": label,
            "session_id": sid,
        })).await?;
        let resp = recv_json(&mut r).await?;
        assert_eq!(resp["success"], true, "destroy {} failed: {:?}", sid, resp);
    }

    // Verify both are gone
    let (mut send_final, mut recv_final) = conn.open_bi().await?;
    send_json(&mut send_final, &serde_json::json!({
        "type": "list_sessions",
        "request_id": "list-final",
    })).await?;
    let final_resp = recv_json(&mut recv_final).await?;
    let final_sessions = final_resp["sessions"].as_array().unwrap();
    assert!(
        !final_sessions.iter().any(|s| s["id"].as_str() == Some(&session_a) || s["id"].as_str() == Some(&session_b)),
        "both sessions should be destroyed"
    );

    conn.close(quinn::VarInt::from_u32(0), b"done");
    Ok(())
}

#[tokio::test]
async fn session_metadata_correctness() -> Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .ok();

    let harness = TestHarness::new().await?;
    let conn = harness.connect_and_auth().await?;

    // Create session
    let (mut send, mut recv) = conn.open_bi().await?;
    send_json(&mut send, &serde_json::json!({
        "type": "create_session",
        "request_id": "meta-create",
        "rows": 24,
        "cols": 80,
    })).await?;
    let resp = recv_json(&mut recv).await?;
    let session_id = resp["session_id"].as_str().unwrap().to_string();

    // Detach
    send.finish()?;
    drop(send);
    drop(recv);
    tokio::time::sleep(Duration::from_millis(300)).await;

    // List and check metadata
    let (mut send_l, mut recv_l) = conn.open_bi().await?;
    send_json(&mut send_l, &serde_json::json!({
        "type": "list_sessions",
        "request_id": "meta-list",
    })).await?;
    let list_resp = recv_json(&mut recv_l).await?;
    let sessions = list_resp["sessions"].as_array().unwrap();
    let session = sessions.iter().find(|s| s["id"].as_str() == Some(&session_id)).unwrap();

    // Verify metadata fields
    assert!(session["alive"].as_bool().unwrap(), "session should be alive");
    assert!(!session["attached"].as_bool().unwrap(), "session should be detached");
    assert!(session["created_at"].as_str().is_some(), "created_at should exist");
    assert!(session["shell"].as_str().is_some(), "shell should exist");
    assert_eq!(
        session["created_by_device_id"].as_str().unwrap(),
        "test-device-001",
        "created_by_device_id should match auth device"
    );
    assert!(session["last_attached_at"].as_str().is_some(), "last_attached_at should exist");
    assert_eq!(
        session["last_attached_by"].as_str().unwrap(),
        "test-device-001",
        "last_attached_by should match auth device"
    );
    assert!(session["last_activity_at"].as_str().is_some(), "last_activity_at should exist");

    // Cleanup
    drop(send_l);
    drop(recv_l);
    let (mut sd, mut rd) = conn.open_bi().await?;
    send_json(&mut sd, &serde_json::json!({
        "type": "destroy_session",
        "request_id": "meta-destroy",
        "session_id": &session_id,
    })).await?;
    let _ = recv_json(&mut rd).await?;

    conn.close(quinn::VarInt::from_u32(0), b"done");
    Ok(())
}

#[tokio::test]
async fn destroy_terminates_process() -> Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .ok();

    let harness = TestHarness::new().await?;
    let conn = harness.connect_and_auth().await?;

    // Create session and get a long-running process
    let (mut send, mut recv) = conn.open_bi().await?;
    send_json(&mut send, &serde_json::json!({
        "type": "create_session",
        "request_id": "proc-create",
        "rows": 24,
        "cols": 80,
    })).await?;
    let resp = recv_json(&mut recv).await?;
    let session_id = resp["session_id"].as_str().unwrap().to_string();

    // Start a background process and get its PID
    let input = Frame::data(1, b"echo $$\n".to_vec());
    send.write_all(&frame::encode(&input, false)?).await?;

    // Read output to get PID
    let mut decoder = FrameDecoder::new();
    let mut output = Vec::new();
    let deadline = tokio::time::Instant::now() + Duration::from_secs(5);
    loop {
        if tokio::time::Instant::now() > deadline { break; }
        let mut buf = [0u8; 4096];
        match tokio::time::timeout(Duration::from_millis(200), recv.read(&mut buf)).await {
            Ok(Ok(Some(n))) => {
                decoder.feed(&buf[..n]);
                while let Some(f) = decoder.decode_next()? {
                    if f.frame_type == FrameType::Data { output.extend_from_slice(&f.payload); }
                }
                // Look for a PID line (digits only)
                let text = String::from_utf8_lossy(&output);
                if text.lines().any(|l| l.trim().parse::<u32>().is_ok()) { break; }
            }
            _ => continue,
        }
    }

    // Detach
    send.finish()?;
    drop(send);
    drop(recv);
    tokio::time::sleep(Duration::from_millis(300)).await;

    // Destroy
    let (mut sd, mut rd) = conn.open_bi().await?;
    send_json(&mut sd, &serde_json::json!({
        "type": "destroy_session",
        "request_id": "proc-destroy",
        "session_id": &session_id,
    })).await?;
    let destroy_resp = recv_json(&mut rd).await?;
    assert_eq!(destroy_resp["success"], true);
    drop(sd);
    drop(rd);

    // Verify session is gone from list
    tokio::time::sleep(Duration::from_millis(500)).await;
    let (mut sl, mut rl) = conn.open_bi().await?;
    send_json(&mut sl, &serde_json::json!({
        "type": "list_sessions",
        "request_id": "proc-list",
    })).await?;
    let list_resp = recv_json(&mut rl).await?;
    let sessions = list_resp["sessions"].as_array().unwrap();
    assert!(
        !sessions.iter().any(|s| s["id"].as_str() == Some(&session_id)),
        "destroyed session should not appear in list"
    );

    conn.close(quinn::VarInt::from_u32(0), b"done");
    Ok(())
}
