use anyhow::{bail, Context, Result};
use quinn::{Connection, RecvStream, SendStream};
use serde::{Deserialize, Serialize};
use std::sync::Arc;
use tracing::{info, warn};

use crate::device_store::DeviceStore;

/// Handles authentication for incoming connections.
pub struct Authenticator {
    device_store: Arc<DeviceStore>,
}

// Control message types for auth
#[derive(Debug, Deserialize)]
struct AuthRequest {
    #[serde(rename = "type")]
    type_: String,
    request_id: String,
    device_id: String,
    #[serde(default)]
    public_key: Option<String>,
    #[serde(default)]
    device_name: Option<String>,
    #[serde(default)]
    pairing_token: Option<String>,
    #[serde(default)]
    signature: Option<String>,
}

#[derive(Debug, Serialize)]
struct AuthChallenge {
    #[serde(rename = "type")]
    type_: String,
    request_id: String,
    challenge: String,
}

#[derive(Debug, Serialize)]
struct AuthResult {
    #[serde(rename = "type")]
    type_: String,
    request_id: String,
    success: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

impl Authenticator {
    pub fn new(device_store: Arc<DeviceStore>) -> Self {
        Self { device_store }
    }

    /// Authenticate a connection via the control stream.
    /// Returns the device_id on success.
    pub async fn handle_auth(
        &self,
        connection: &Connection,
        mut send: SendStream,
        mut recv: RecvStream,
    ) -> Result<String> {
        // Read length-prefixed JSON auth request
        let msg = read_control_message(&mut recv).await?;
        let req: AuthRequest =
            serde_json::from_slice(&msg).context("parse auth request")?;

        match req.type_.as_str() {
            "auth_request" => {}
            other => bail!("expected auth_request, got {other}"),
        }

        let device_id = req.device_id.clone();

        // Validate device_id format (prevent oversized or empty IDs)
        if device_id.is_empty() || device_id.len() > 128 {
            bail!("invalid device_id length: {}", device_id.len());
        }

        // Check if this is a pairing request (has pairing_token + public_key)
        if let (Some(token), Some(pub_key), Some(name)) =
            (&req.pairing_token, &req.public_key, &req.device_name)
        {
            // Pairing flow
            if self.device_store.validate_pairing_token(token)? {
                self.device_store.add_device(
                    &device_id,
                    pub_key,
                    name,
                )?;
                info!("paired new device: {device_id} ({name})");

                let resp = AuthResult {
                    type_: "auth_response".to_string(),
                    request_id: req.request_id,
                    success: true,
                    error: None,
                };
                write_control_message(&mut send, &resp).await?;
                return Ok(device_id);
            } else {
                warn!("invalid pairing attempt from {device_id}");
                self.device_store.record_auth(&device_id, false);
                let resp = AuthResult {
                    type_: "auth_response".to_string(),
                    request_id: req.request_id,
                    success: false,
                    error: Some("invalid or expired pairing token".to_string()),
                };
                write_control_message(&mut send, &resp).await?;
                bail!("invalid pairing token from {device_id}");
            }
        }

        // Challenge-response flow for already-paired devices
        let stored_key = match self.device_store.get_public_key(&device_id) {
            Ok(key) => key,
            Err(_) => {
                warn!("auth attempt from unknown device {device_id}");
                self.device_store.record_auth(&device_id, false);
                let resp = AuthResult {
                    type_: "auth_response".to_string(),
                    request_id: req.request_id,
                    success: false,
                    error: Some("device not paired".to_string()),
                };
                write_control_message(&mut send, &resp).await?;
                bail!("unknown device {device_id}");
            }
        };

        // Send challenge
        let challenge_bytes: [u8; 32] = rand::Rng::gen(&mut rand::thread_rng());
        let challenge_b64 = {
            use base64::Engine;
            base64::engine::general_purpose::STANDARD.encode(&challenge_bytes)
        };

        let challenge_msg = AuthChallenge {
            type_: "auth_challenge".to_string(),
            request_id: req.request_id.clone(),
            challenge: challenge_b64,
        };
        write_control_message(&mut send, &challenge_msg).await?;

        // Read signed challenge response
        let resp_msg = read_control_message(&mut recv).await?;
        let resp: AuthRequest =
            serde_json::from_slice(&resp_msg).context("parse auth response")?;

        let signature_b64 = resp
            .signature
            .as_ref()
            .context("missing signature in auth response")?;

        // Verify P256 signature.
        // Try with TLS exporter binding first (challenge || exporter),
        // then fall back to challenge-only for clients that don't support exporter yet.
        let mut tls_exporter = vec![0u8; 32];
        let has_exporter = connection
            .export_keying_material(&mut tls_exporter, b"phantom-auth", b"")
            .is_ok();

        let valid = if has_exporter {
            let mut signed_data = Vec::with_capacity(64);
            signed_data.extend_from_slice(&challenge_bytes);
            signed_data.extend_from_slice(&tls_exporter);
            let with_binding = verify_p256_signature(&stored_key, &signed_data, signature_b64)?;
            if with_binding {
                true
            } else {
                // Fall back: verify challenge-only (for clients without TLS exporter)
                verify_p256_signature(&stored_key, &challenge_bytes, signature_b64)?
            }
        } else {
            verify_p256_signature(&stored_key, &challenge_bytes, signature_b64)?
        };

        if valid {
            let result = AuthResult {
                type_: "auth_response".to_string(),
                request_id: req.request_id,
                success: true,
                error: None,
            };
            write_control_message(&mut send, &result).await?;
            self.device_store.record_auth(&device_id, true);
            Ok(device_id)
        } else {
            let result = AuthResult {
                type_: "auth_response".to_string(),
                request_id: req.request_id,
                success: false,
                error: Some("signature verification failed".to_string()),
            };
            write_control_message(&mut send, &result).await?;
            self.device_store.record_auth(&device_id, false);
            bail!("auth failed: bad signature from {device_id}");
        }
    }
}

fn verify_p256_signature(
    pub_key_b64: &str,
    message: &[u8],
    signature_b64: &str,
) -> Result<bool> {
    use base64::Engine;
    use p256::ecdsa::{signature::Verifier, Signature, VerifyingKey};

    let pub_key_bytes = base64::engine::general_purpose::STANDARD
        .decode(pub_key_b64)
        .context("decode public key")?;
    let sig_bytes = base64::engine::general_purpose::STANDARD
        .decode(signature_b64)
        .context("decode signature")?;

    let verifying_key = VerifyingKey::from_sec1_bytes(&pub_key_bytes)
        .context("parse P256 public key")?;

    // iOS CryptoKit produces DER-encoded signatures
    let signature = Signature::from_der(&sig_bytes)
        .context("parse DER signature")?;

    Ok(verifying_key.verify(message, &signature).is_ok())
}

/// Read a length-prefixed JSON message from a QUIC stream.
async fn read_control_message(recv: &mut RecvStream) -> Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    recv.read_exact(&mut len_buf)
        .await
        .context("read control message length")?;
    let len = u32::from_be_bytes(len_buf) as usize;

    if len > 65536 {
        anyhow::bail!("control message too large: {len}");
    }

    let mut buf = vec![0u8; len];
    recv.read_exact(&mut buf)
        .await
        .context("read control message body")?;

    Ok(buf)
}

/// Write a length-prefixed JSON message to a QUIC stream.
async fn write_control_message<T: Serialize>(
    send: &mut SendStream,
    msg: &T,
) -> Result<()> {
    let json = serde_json::to_vec(msg).context("serialize control message")?;
    let len = (json.len() as u32).to_be_bytes();
    send.write_all(&len).await.context("write message length")?;
    send.write_all(&json).await.context("write message body")?;
    Ok(())
}
