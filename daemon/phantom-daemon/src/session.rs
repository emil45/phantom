use anyhow::{Context, Result};
use portable_pty::{native_pty_system, CommandBuilder, MasterPty, PtySize};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

/// Ring buffer for PTY scrollback with clean-point tracking.
pub struct ScrollbackBuffer {
    buf: Vec<u8>,
    capacity: usize,
    write_pos: usize,
    len: usize,
    /// Byte offset of the last position where the terminal was in ground state
    /// (no pending escape sequence). Safe to replay from here on reattach.
    clean_point: usize,
}

impl ScrollbackBuffer {
    pub fn new(capacity: usize) -> Self {
        Self {
            buf: vec![0; capacity],
            capacity,
            write_pos: 0,
            len: 0,
            clean_point: 0,
        }
    }

    /// Append data to the ring buffer, updating the clean point.
    pub fn append(&mut self, data: &[u8]) {
        for &byte in data {
            self.buf[self.write_pos] = byte;
            self.write_pos = (self.write_pos + 1) % self.capacity;
            if self.len < self.capacity {
                self.len += 1;
            }
        }
        // Update clean point: scan for ground state.
        // A simple heuristic: after any byte that isn't part of an escape sequence.
        // The ground state is when the last byte is not ESC (0x1B) and we're not
        // inside a CSI sequence (ESC [ ... final_byte).
        self.update_clean_point(data);
    }

    fn update_clean_point(&mut self, data: &[u8]) {
        // Track whether we're inside an escape sequence.
        // Simple state machine: if we see ESC, we're in-escape until we see
        // a byte in 0x40..=0x7E (for CSI) or any non-control char (for other escapes).
        // For v1, we just mark clean point after any byte >= 0x20 that isn't preceded by ESC.
        let mut in_escape = false;
        for &byte in data {
            if byte == 0x1B {
                in_escape = true;
            } else if in_escape {
                if byte == b'[' {
                    // CSI sequence, continue until 0x40..=0x7E
                    continue;
                }
                if (0x40..=0x7E).contains(&byte) {
                    // End of escape sequence
                    in_escape = false;
                    self.clean_point = self.len;
                }
            } else if byte >= 0x20 || byte == b'\n' || byte == b'\r' {
                self.clean_point = self.len;
            }
        }
    }

    /// Read all scrollback data from the buffer.
    /// Returns the full ring buffer contents in order.
    /// For v1, we send the entire buffer on reattach. The clean point
    /// optimization (only replaying from the last safe terminal state)
    /// is deferred — in practice the full buffer works fine since
    /// SwiftTerm's parser handles partial escape sequences gracefully.
    pub fn read_from_clean_point(&self) -> Vec<u8> {
        if self.len == 0 {
            return Vec::new();
        }

        let mut result = Vec::with_capacity(self.len);
        let read_start = if self.len < self.capacity {
            0
        } else {
            self.write_pos
        };

        for i in 0..self.len {
            result.push(self.buf[(read_start + i) % self.capacity]);
        }

        result
    }
}

/// A single PTY session.
pub struct PtySession {
    pub id: String,
    pub reader: Option<Box<dyn Read + Send>>,
    pub writer: Arc<Mutex<Box<dyn Write + Send>>>,
    pub child: Box<dyn portable_pty::Child + Send + Sync>,
    pub master: Box<dyn MasterPty + Send>,
    pub scrollback: Arc<Mutex<ScrollbackBuffer>>,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub shell: String,
    /// Set when a client is attached
    pub attached: bool,
    /// Cancellation token for the current bridge tasks
    pub bridge_cancel: Option<CancellationToken>,
    /// Device that created this session
    pub created_by_device_id: Option<String>,
    /// Last time a client attached to this session
    pub last_attached_at: Option<chrono::DateTime<chrono::Utc>>,
    /// Device that last attached to this session
    pub last_attached_by: Option<String>,
    /// Last time the session had client input activity
    pub last_activity_at: chrono::DateTime<chrono::Utc>,
}

impl PtySession {
    pub fn spawn(id: String, rows: u16, cols: u16, device_id: Option<&str>) -> Result<Self> {
        let pty_system = native_pty_system();
        let pair = pty_system
            .openpty(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("openpty")?;

        let mut cmd = CommandBuilder::new_default_prog();
        cmd.env("TERM", "xterm-256color");

        let child = pair.slave.spawn_command(cmd).context("spawn shell")?;
        drop(pair.slave);

        let reader = pair.master.try_clone_reader().context("clone PTY reader")?;
        let writer = pair.master.take_writer().context("take PTY writer")?;

        let shell = std::env::var("SHELL").unwrap_or_else(|_| "/bin/zsh".to_string());
        let now = chrono::Utc::now();

        Ok(Self {
            id,
            reader: Some(reader),
            writer: Arc::new(Mutex::new(writer)),
            child,
            master: pair.master,
            scrollback: Arc::new(Mutex::new(ScrollbackBuffer::new(65536))),
            created_at: now,
            shell,
            attached: false,
            bridge_cancel: None,
            created_by_device_id: device_id.map(|s| s.to_string()),
            last_attached_at: None,
            last_attached_by: None,
            last_activity_at: now,
        })
    }

    #[allow(dead_code)]
    pub fn is_alive(&mut self) -> bool {
        matches!(self.child.try_wait(), Ok(None))
    }

    pub fn resize(&self, rows: u16, cols: u16) -> Result<()> {
        self.master
            .resize(PtySize {
                rows,
                cols,
                pixel_width: 0,
                pixel_height: 0,
            })
            .context("resize PTY")
    }
}

/// Manages all PTY sessions.
pub struct SessionManager {
    sessions: Mutex<HashMap<String, Arc<Mutex<PtySession>>>>,
    /// device_id → active quinn::Connection
    connections: Mutex<HashMap<String, quinn::Connection>>,
}

impl SessionManager {
    pub fn new() -> Self {
        Self {
            sessions: Mutex::new(HashMap::new()),
            connections: Mutex::new(HashMap::new()),
        }
    }

    pub fn create_session(
        &self,
        rows: u16,
        cols: u16,
        device_id: Option<&str>,
    ) -> Result<String> {
        let id = uuid_short();
        let session = PtySession::spawn(id.clone(), rows, cols, device_id)
            .context("spawn session")?;

        self.sessions
            .lock()
            .expect("sessions lock")
            .insert(id.clone(), Arc::new(Mutex::new(session)));

        info!("created session {id}");
        Ok(id)
    }

    pub fn get_session(&self, id: &str) -> Option<Arc<Mutex<PtySession>>> {
        self.sessions.lock().expect("sessions lock").get(id).cloned()
    }

    pub fn list_sessions(&self) -> Vec<SessionInfo> {
        let sessions = self.sessions.lock().expect("sessions lock");
        sessions
            .values()
            .map(|s| {
                let mut s = s.lock().expect("session lock");
                SessionInfo {
                    id: s.id.clone(),
                    alive: matches!(s.child.try_wait(), Ok(None)),
                    created_at: s.created_at,
                    shell: s.shell.clone(),
                    attached: s.attached,
                    created_by_device_id: s.created_by_device_id.clone(),
                    last_attached_at: s.last_attached_at,
                    last_attached_by: s.last_attached_by.clone(),
                    last_activity_at: s.last_activity_at,
                }
            })
            .collect()
    }

    pub fn destroy_session(&self, id: &str) -> Result<()> {
        let session = self
            .sessions
            .lock()
            .expect("sessions lock")
            .remove(id)
            .context("session not found")?;

        let mut s = session.lock().expect("session lock");

        // Cancel any active bridge
        if let Some(cancel) = s.bridge_cancel.take() {
            cancel.cancel();
        }

        // Send SIGHUP to the process group
        if let Some(pid) = s.child.process_id() {
            #[cfg(unix)]
            unsafe {
                libc::killpg(pid as i32, libc::SIGHUP);
            }
        }

        // Give it 2 seconds, then SIGKILL
        let killer = s.child.clone_killer();
        tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_secs(2)).await;
            let mut k = killer;
            let _ = k.kill();
        });

        info!("destroyed session {id}");
        Ok(())
    }

    /// Destroy all sessions (for graceful shutdown).
    pub fn destroy_all(&self) {
        let ids: Vec<String> = self
            .sessions
            .lock()
            .expect("sessions lock")
            .keys()
            .cloned()
            .collect();
        for id in ids {
            if let Err(e) = self.destroy_session(&id) {
                warn!("destroy_all: session {id}: {e}");
            }
        }
    }

    pub fn register_connection(&self, device_id: &str, conn: &quinn::Connection) {
        let mut conns = self.connections.lock().expect("connections lock");
        // Tear down old connection from same device (stale)
        if let Some(old) = conns.insert(device_id.to_string(), conn.clone()) {
            warn!("replacing stale connection for device {device_id}");
            old.close(quinn::VarInt::from_u32(0), b"replaced");
        }
    }

    pub fn unregister_connection(&self, device_id: &str) {
        self.connections
            .lock()
            .expect("connections lock")
            .remove(device_id);
    }

    /// Return the device IDs of all currently connected devices.
    pub fn connected_device_ids(&self) -> Vec<String> {
        self.connections
            .lock()
            .expect("connections lock")
            .keys()
            .cloned()
            .collect()
    }

    /// Run the session reaper: check for dead sessions periodically.
    pub async fn run_reaper(self: &Arc<Self>, cancel: CancellationToken, interval_secs: u64) {
        let mut interval = tokio::time::interval(std::time::Duration::from_secs(interval_secs));
        loop {
            tokio::select! {
                _ = interval.tick() => {}
                _ = cancel.cancelled() => break,
            }

            let session_ids: Vec<String> = {
                self.sessions
                    .lock()
                    .expect("sessions lock")
                    .keys()
                    .cloned()
                    .collect()
            };

            for id in session_ids {
                let session = {
                    self.sessions.lock().expect("sessions lock").get(&id).cloned()
                };
                if let Some(session) = session {
                    let mut s = session.lock().expect("session lock");
                    match s.child.try_wait() {
                        Ok(Some(status)) => {
                            info!("session {id} exited: {status}");
                            // Cancel bridge if active
                            if let Some(cancel) = s.bridge_cancel.take() {
                                cancel.cancel();
                            }
                            drop(s);
                            self.sessions.lock().expect("sessions lock").remove(&id);
                        }
                        Ok(None) => {} // still running
                        Err(e) => {
                            warn!("session {id} try_wait error: {e}");
                        }
                    }
                }
            }
        }
    }
}

#[derive(Debug, serde::Serialize)]
pub struct SessionInfo {
    pub id: String,
    pub alive: bool,
    pub created_at: chrono::DateTime<chrono::Utc>,
    pub shell: String,
    pub attached: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub created_by_device_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_attached_at: Option<chrono::DateTime<chrono::Utc>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_attached_by: Option<String>,
    pub last_activity_at: chrono::DateTime<chrono::Utc>,
}

fn uuid_short() -> String {
    use rand::Rng;
    let mut rng = rand::thread_rng();
    let bytes: [u8; 8] = rng.gen();
    hex::encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scrollback_empty() {
        let sb = ScrollbackBuffer::new(1024);
        assert!(sb.read_from_clean_point().is_empty());
    }

    #[test]
    fn scrollback_small_write() {
        let mut sb = ScrollbackBuffer::new(1024);
        sb.append(b"hello world");
        let data = sb.read_from_clean_point();
        assert_eq!(data, b"hello world");
    }

    #[test]
    fn scrollback_wraps_at_capacity() {
        let mut sb = ScrollbackBuffer::new(16);
        // Write 20 bytes into 16-byte buffer
        sb.append(b"AAAABBBBCCCCDDDDEEEE");
        let data = sb.read_from_clean_point();
        // Should contain only the last 16 bytes
        assert_eq!(data.len(), 16);
        assert_eq!(&data, b"BBBBCCCCDDDDEEEE");
    }

    #[test]
    fn scrollback_bounded_under_sustained_output() {
        let capacity = 65536;
        let mut sb = ScrollbackBuffer::new(capacity);
        // Write 1MB of data in chunks
        let chunk = vec![b'X'; 4096];
        for _ in 0..256 {
            sb.append(&chunk);
        }
        let data = sb.read_from_clean_point();
        assert_eq!(data.len(), capacity);
        // All bytes should be 'X'
        assert!(data.iter().all(|&b| b == b'X'));
    }

    #[test]
    fn scrollback_preserves_order_after_wrap() {
        let mut sb = ScrollbackBuffer::new(8);
        sb.append(b"12345678"); // fills exactly
        let data = sb.read_from_clean_point();
        assert_eq!(&data, b"12345678");

        // Now wrap
        sb.append(b"ABCD");
        let data = sb.read_from_clean_point();
        assert_eq!(data.len(), 8);
        assert_eq!(&data, b"5678ABCD");
    }

    #[test]
    fn scrollback_multiple_wraps() {
        let mut sb = ScrollbackBuffer::new(4);
        sb.append(b"AABB");
        sb.append(b"CCDD");
        sb.append(b"EE");
        let data = sb.read_from_clean_point();
        assert_eq!(data.len(), 4);
        assert_eq!(&data, b"DDEE");
    }
}
