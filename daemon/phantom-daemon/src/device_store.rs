use anyhow::{bail, Context, Result};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;
use std::sync::Mutex;
use tracing::{info, warn};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PairedDevice {
    pub device_id: String,
    pub public_key: String, // base64-encoded SEC1 P256 public key
    pub device_name: String,
    pub paired_at: DateTime<Utc>,
    pub last_seen: Option<DateTime<Utc>>,
}

#[derive(Debug, Serialize, Deserialize, Default)]
struct DeviceStoreData {
    devices: HashMap<String, PairedDevice>,
}

/// Manages paired devices, pairing tokens, and the audit log.
pub struct DeviceStore {
    data: Mutex<DeviceStoreData>,
    store_path: PathBuf,
    audit_path: PathBuf,
    token_path: PathBuf,
}

impl DeviceStore {
    pub fn new(phantom_dir: &std::path::Path) -> Result<Self> {
        let store_path = phantom_dir.join("devices.json");
        let audit_path = phantom_dir.join("auth.log");

        let data = if store_path.exists() {
            let contents = fs::read_to_string(&store_path)
                .context("read devices.json")?;
            serde_json::from_str(&contents).context("parse devices.json")?
        } else {
            DeviceStoreData::default()
        };

        info!("loaded {} paired device(s)", data.devices.len());

        let token_path = phantom_dir.join("pairing_tokens.json");

        Ok(Self {
            data: Mutex::new(data),
            store_path,
            audit_path,
            token_path,
        })
    }

    fn persist(&self) -> Result<()> {
        let data = self.data.lock().expect("device store lock");
        let json = serde_json::to_string_pretty(&*data)
            .context("serialize devices")?;
        fs::write(&self.store_path, json).context("write devices.json")?;
        Ok(())
    }

    /// Generate a single-use pairing token valid for 5 minutes.
    /// Tokens are stored on disk so `phantom pair` and `phantom daemon` share them.
    pub fn create_pairing_token(&self) -> String {
        use base64::Engine;
        let token_bytes: [u8; 32] = rand::Rng::gen(&mut rand::thread_rng());
        let token = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(token_bytes);
        let expiry_epoch = (std::time::SystemTime::now()
            + std::time::Duration::from_secs(300))
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();

        let mut tokens = self.load_tokens();
        tokens.insert(token.clone(), expiry_epoch);
        self.save_tokens(&tokens);

        token
    }

    /// Validate and consume a pairing token (single-use).
    pub fn validate_pairing_token(&self, token: &str) -> Result<bool> {
        let mut tokens = self.load_tokens();
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();

        // Prune expired tokens
        tokens.retain(|_, &mut exp| exp > now);

        if let Some(expiry) = tokens.remove(token) {
            self.save_tokens(&tokens);
            Ok(expiry > now)
        } else {
            self.save_tokens(&tokens);
            Ok(false)
        }
    }

    fn load_tokens(&self) -> HashMap<String, u64> {
        let mut tokens: HashMap<String, u64> = fs::read_to_string(&self.token_path)
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        // Prune expired tokens on every load
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs();
        let before = tokens.len();
        tokens.retain(|_, &mut exp| exp > now);
        if tokens.len() < before {
            self.save_tokens(&tokens);
        }
        tokens
    }

    fn save_tokens(&self, tokens: &HashMap<String, u64>) {
        if let Ok(json) = serde_json::to_string(tokens) {
            let _ = fs::write(&self.token_path, json);
        }
    }

    /// Add a newly paired device.
    pub fn add_device(
        &self,
        device_id: &str,
        public_key: &str,
        device_name: &str,
    ) -> Result<()> {
        let device = PairedDevice {
            device_id: device_id.to_string(),
            public_key: public_key.to_string(),
            device_name: device_name.to_string(),
            paired_at: Utc::now(),
            last_seen: None,
        };

        self.data
            .lock()
            .expect("device store lock")
            .devices
            .insert(device_id.to_string(), device);

        self.persist()?;
        self.append_audit(device_id, "pair");
        Ok(())
    }

    /// Get the stored public key for a device.
    pub fn get_public_key(&self, device_id: &str) -> Result<String> {
        let data = self.data.lock().expect("device store lock");
        data.devices
            .get(device_id)
            .map(|d| d.public_key.clone())
            .context("device not paired")
    }

    /// Record an authentication attempt in the audit log.
    pub fn record_auth(&self, device_id: &str, success: bool) {
        let action = if success { "auth_ok" } else { "auth_fail" };
        self.append_audit(device_id, action);

        if success {
            if let Ok(mut data) = self.data.lock() {
                if let Some(device) = data.devices.get_mut(device_id) {
                    device.last_seen = Some(Utc::now());
                }
            }
            let _ = self.persist();
        }
    }

    /// List all paired devices.
    pub fn list_devices(&self) -> Vec<PairedDevice> {
        self.data
            .lock()
            .expect("device store lock")
            .devices
            .values()
            .cloned()
            .collect()
    }

    /// Revoke (remove) a paired device.
    pub fn revoke_device(&self, device_id: &str) -> Result<()> {
        let mut data = self.data.lock().expect("device store lock");
        if data.devices.remove(device_id).is_none() {
            bail!("device {device_id} not found");
        }
        drop(data);
        self.persist()?;
        self.append_audit(device_id, "revoke");
        info!("revoked device {device_id}");
        Ok(())
    }

    /// Generate all data needed for a pairing QR code / manual entry.
    /// Creates a new pairing token and returns the payload.
    pub fn generate_pairing_data(&self, fingerprint: &str, port: u16) -> PairingData {
        let token = self.create_pairing_token();
        let host = local_ip().unwrap_or_else(|| "127.0.0.1".to_string());
        let name = hostname();
        let qr_payload = serde_json::json!({
            "host": host,
            "port": port,
            "fp": fingerprint,
            "tok": token,
            "name": name,
            "v": 1,
        });
        PairingData {
            qr_payload_json: serde_json::to_string(&qr_payload).unwrap(),
            token,
            host,
            port,
            fingerprint: fingerprint.to_string(),
            expires_in_secs: 300,
        }
    }

    fn append_audit(&self, device_id: &str, action: &str) {
        let line = format!(
            "{}\t{}\t{}\n",
            Utc::now().to_rfc3339(),
            device_id,
            action,
        );
        if let Err(e) = fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.audit_path)
            .and_then(|mut f| {
                use std::io::Write;
                f.write_all(line.as_bytes())
            })
        {
            warn!("failed to write audit log: {e}");
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct PairingData {
    pub qr_payload_json: String,
    pub token: String,
    pub host: String,
    pub port: u16,
    pub fingerprint: String,
    pub expires_in_secs: u64,
}

pub fn local_ip() -> Option<String> {
    use std::net::UdpSocket;
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    Some(socket.local_addr().ok()?.ip().to_string())
}

pub fn hostname() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| std::env::var("HOST"))
        .unwrap_or_else(|_| "phantom-host".to_string())
}
