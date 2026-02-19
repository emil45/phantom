use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

use crate::device_store::DeviceStore;
use crate::session::SessionManager;

/// Maximum concurrent IPC connections (defense in depth).
const MAX_CONNECTIONS: usize = 5;
/// Maximum line length for IPC messages (64KB).
const MAX_LINE_LENGTH: usize = 65536;
/// Maximum length for ID parameters.
const MAX_ID_LENGTH: usize = 128;
/// Maximum requests per second per IPC connection.
const MAX_REQUESTS_PER_SEC: u32 = 20;

#[derive(Debug, Deserialize)]
struct Request {
    id: u64,
    method: String,
    #[serde(default)]
    params: serde_json::Value,
}

#[derive(Debug, Serialize)]
struct Response {
    id: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    result: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    error: Option<String>,
}

impl Response {
    fn ok(id: u64, result: serde_json::Value) -> Self {
        Self { id, result: Some(result), error: None }
    }
    fn err(id: u64, error: impl Into<String>) -> Self {
        Self { id, result: None, error: Some(error.into()) }
    }
}

/// Validate that an ID parameter contains only safe characters.
fn validate_id(id: &str) -> Result<()> {
    if id.is_empty() || id.len() > MAX_ID_LENGTH {
        bail!("id must be 1-{MAX_ID_LENGTH} characters");
    }
    if !id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') {
        bail!("id must contain only alphanumeric characters, hyphens, or underscores");
    }
    Ok(())
}

pub struct IpcServer {
    socket_path: PathBuf,
    session_manager: Arc<SessionManager>,
    device_store: Arc<DeviceStore>,
    fingerprint: String,
    bind_address: String,
    start_time: std::time::Instant,
}

impl IpcServer {
    pub fn new(
        phantom_dir: &Path,
        session_manager: Arc<SessionManager>,
        device_store: Arc<DeviceStore>,
        fingerprint: String,
        bind_address: String,
    ) -> Self {
        Self {
            socket_path: phantom_dir.join("daemon.sock"),
            session_manager,
            device_store,
            fingerprint,
            bind_address,
            start_time: std::time::Instant::now(),
        }
    }

    pub async fn run(self: Arc<Self>, cancel: CancellationToken) -> Result<()> {
        // Clean up stale socket
        if self.socket_path.exists() {
            std::fs::remove_file(&self.socket_path)
                .context("remove stale IPC socket")?;
        }

        let listener = UnixListener::bind(&self.socket_path)
            .context("bind IPC socket")?;

        // Set socket permissions to 0o600
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(
                &self.socket_path,
                std::fs::Permissions::from_mode(0o600),
            ).context("set IPC socket permissions")?;
        }

        info!("IPC server listening on {}", self.socket_path.display());

        let semaphore = Arc::new(tokio::sync::Semaphore::new(MAX_CONNECTIONS));

        loop {
            tokio::select! {
                accept = listener.accept() => {
                    let (stream, _) = accept.context("accept IPC connection")?;

                    let permit = match semaphore.clone().try_acquire_owned() {
                        Ok(permit) => permit,
                        Err(_) => {
                            warn!("IPC connection rejected: max connections reached");
                            continue;
                        }
                    };

                    let server = self.clone();
                    tokio::spawn(async move {
                        if let Err(e) = server.handle_client(stream).await {
                            warn!("IPC client error: {e:#}");
                        }
                        drop(permit);
                    });
                }
                _ = cancel.cancelled() => {
                    break;
                }
            }
        }

        // Clean up socket on shutdown
        let _ = std::fs::remove_file(&self.socket_path);
        info!("IPC server shut down");
        Ok(())
    }

    async fn handle_client(&self, stream: tokio::net::UnixStream) -> Result<()> {
        let (reader, mut writer) = stream.into_split();
        let mut lines = BufReader::new(reader).lines();
        let mut window_start = tokio::time::Instant::now();
        let mut request_count: u32 = 0;

        while let Some(line) = lines.next_line().await? {
            // Per-connection rate limiting
            let now = tokio::time::Instant::now();
            if now.duration_since(window_start) >= std::time::Duration::from_secs(1) {
                request_count = 0;
                window_start = now;
            }
            request_count += 1;
            if request_count > MAX_REQUESTS_PER_SEC {
                let resp = Response::err(0, "rate limit exceeded");
                let mut out = serde_json::to_vec(&resp)?;
                out.push(b'\n');
                writer.write_all(&out).await?;
                continue;
            }

            if line.len() > MAX_LINE_LENGTH {
                let resp = Response::err(0, "request too large");
                let mut out = serde_json::to_vec(&resp)?;
                out.push(b'\n');
                writer.write_all(&out).await?;
                continue;
            }

            let req: Request = match serde_json::from_str(&line) {
                Ok(r) => r,
                Err(e) => {
                    let resp = Response::err(0, format!("invalid JSON: {e}"));
                    let mut out = serde_json::to_vec(&resp)?;
                    out.push(b'\n');
                    writer.write_all(&out).await?;
                    continue;
                }
            };

            let resp = self.dispatch(req).await;
            let mut out = serde_json::to_vec(&resp)?;
            out.push(b'\n');
            writer.write_all(&out).await?;
        }

        Ok(())
    }

    async fn dispatch(&self, req: Request) -> Response {
        match req.method.as_str() {
            "status" => self.handle_status(req.id),
            "list_sessions" => self.handle_list_sessions(req.id),
            "list_devices" => self.handle_list_devices(req.id),
            "create_pairing" => self.handle_create_pairing(req.id),
            "revoke_device" => self.handle_revoke_device(req.id, &req.params),
            "destroy_session" => self.handle_destroy_session(req.id, &req.params),
            _ => Response::err(req.id, format!("unknown method: {}", req.method)),
        }
    }

    fn handle_status(&self, id: u64) -> Response {
        let uptime = self.start_time.elapsed().as_secs();
        let connected = self.session_manager.connected_device_ids();
        let connected_devices: Vec<serde_json::Value> = {
            let devices = self.device_store.list_devices();
            connected.iter().filter_map(|cid| {
                devices.iter().find(|d| d.device_id == *cid).map(|d| {
                    serde_json::json!({
                        "device_id": d.device_id,
                        "device_name": d.device_name,
                    })
                })
            }).collect()
        };

        Response::ok(id, serde_json::json!({
            "running": true,
            "uptime_secs": uptime,
            "version": crate::VERSION,
            "bind_address": self.bind_address,
            "cert_fingerprint": self.fingerprint,
            "connected_devices": connected_devices,
        }))
    }

    fn handle_list_sessions(&self, id: u64) -> Response {
        let sessions = self.session_manager.list_sessions();
        let list: Vec<serde_json::Value> = sessions.into_iter().map(|s| {
            serde_json::json!({
                "id": s.id,
                "alive": s.alive,
                "created_at": s.created_at.to_rfc3339(),
                "shell": s.shell,
                "attached": s.attached,
                "created_by_device_id": s.created_by_device_id,
                "last_attached_at": s.last_attached_at.map(|t| t.to_rfc3339()),
                "last_attached_by": s.last_attached_by,
                "last_activity_at": s.last_activity_at.to_rfc3339(),
            })
        }).collect();
        Response::ok(id, serde_json::json!(list))
    }

    fn handle_list_devices(&self, id: u64) -> Response {
        let devices = self.device_store.list_devices();
        let connected = self.session_manager.connected_device_ids();
        let list: Vec<serde_json::Value> = devices.into_iter().map(|d| {
            serde_json::json!({
                "device_id": d.device_id,
                "device_name": d.device_name,
                "paired_at": d.paired_at.to_rfc3339(),
                "last_seen": d.last_seen.map(|t| t.to_rfc3339()),
                "is_connected": connected.contains(&d.device_id),
            })
        }).collect();
        Response::ok(id, serde_json::json!(list))
    }

    fn handle_create_pairing(&self, id: u64) -> Response {
        let port = self.bind_address
            .rsplit(':')
            .next()
            .and_then(|p| p.parse::<u16>().ok())
            .unwrap_or(4433);

        let data = self.device_store.generate_pairing_data(&self.fingerprint, port);
        Response::ok(id, serde_json::json!({
            "qr_payload_json": data.qr_payload_json,
            "token": data.token,
            "host": data.host,
            "port": data.port,
            "fingerprint": data.fingerprint,
            "expires_in_secs": data.expires_in_secs,
        }))
    }

    fn handle_revoke_device(&self, id: u64, params: &serde_json::Value) -> Response {
        let device_id = match params.get("device_id").and_then(|v| v.as_str()) {
            Some(id) => id,
            None => return Response::err(id, "missing device_id parameter"),
        };
        if let Err(e) = validate_id(device_id) {
            return Response::err(id, format!("invalid device_id: {e}"));
        }
        match self.device_store.revoke_device(device_id) {
            Ok(()) => Response::ok(id, serde_json::json!({"success": true})),
            Err(e) => Response::err(id, format!("{e}")),
        }
    }

    fn handle_destroy_session(&self, id: u64, params: &serde_json::Value) -> Response {
        let session_id = match params.get("session_id").and_then(|v| v.as_str()) {
            Some(id) => id,
            None => return Response::err(id, "missing session_id parameter"),
        };
        if let Err(e) = validate_id(session_id) {
            return Response::err(id, format!("invalid session_id: {e}"));
        }
        match self.session_manager.destroy_session(session_id) {
            Ok(()) => Response::ok(id, serde_json::json!({"success": true})),
            Err(e) => Response::err(id, format!("{e}")),
        }
    }
}
