use anyhow::{Context, Result};
use phantom_frame::{self as frame, Frame, FrameDecoder, FrameType};
use quinn::{RecvStream, SendStream};
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use tokio::sync::{mpsc, Notify};
use tokio_util::sync::CancellationToken;
use tracing::{error, info, warn};

use crate::session::{PtySession, ScrollbackBuffer, SessionManager};

/// Default client receive window (256KB).
const DEFAULT_WINDOW: u64 = 262144;

/// Handle session requests on a control stream from an authenticated client.
/// Loops to handle multiple control requests (list, destroy) on the same stream.
/// Exits when create/attach transitions to bridge mode, or the stream ends.
pub async fn handle_session_stream(
    mut send: SendStream,
    mut recv: RecvStream,
    session_manager: &SessionManager,
    device_id: &str,
) -> Result<()> {
    loop {
        // Read the session request (length-prefixed JSON like control messages)
        let mut len_buf = [0u8; 4];
        match recv.read_exact(&mut len_buf).await {
            Ok(()) => {}
            Err(e) => {
                // Stream closed or reset — normal disconnect
                info!("session stream read ended: {e}");
                return Ok(());
            }
        }
        let len = u32::from_be_bytes(len_buf) as usize;

        let mut msg_buf = vec![0u8; len];
        recv.read_exact(&mut msg_buf)
            .await
            .context("read session request body")?;

        let req: serde_json::Value =
            serde_json::from_slice(&msg_buf).context("parse session request")?;

        let msg_type = req["type"].as_str().unwrap_or("");

        match msg_type {
            "create_session" => {
                let rows = (req["rows"].as_u64().unwrap_or(24) as u16).clamp(1, 500);
                let cols = (req["cols"].as_u64().unwrap_or(80) as u16).clamp(1, 500);
                let request_id = req["request_id"].as_str().unwrap_or("");

                let session_id = session_manager
                    .create_session(rows, cols, Some(device_id))
                    .context("create session")?;

                // Set initial attach metadata (create immediately enters bridge)
                if let Some(session) = session_manager.get_session(&session_id) {
                    let mut s = session.lock().expect("session lock");
                    s.last_attached_at = Some(chrono::Utc::now());
                    s.last_attached_by = Some(device_id.to_string());
                }

                let resp = serde_json::json!({
                    "type": "session_created",
                    "request_id": request_id,
                    "session_id": session_id,
                });
                write_json(&mut send, &resp).await?;

                // Transition to bridge mode (consumes the stream)
                return run_bridge(send, recv, session_manager, &session_id).await;
            }
            "attach_session" => {
                let session_id = req["session_id"]
                    .as_str()
                    .context("missing session_id")?;
                let request_id = req["request_id"].as_str().unwrap_or("");

                let session = session_manager
                    .get_session(session_id)
                    .context("session not found")?;

                // Update attach metadata
                {
                    let mut s = session.lock().expect("session lock");
                    s.last_attached_at = Some(chrono::Utc::now());
                    s.last_attached_by = Some(device_id.to_string());
                }

                let resp = serde_json::json!({
                    "type": "session_attached",
                    "request_id": request_id,
                    "session_id": session_id,
                });
                write_json(&mut send, &resp).await?;

                // Send scrollback before live data
                let scrollback_data = {
                    let s = session.lock().expect("session lock");
                    let sb = s.scrollback.clone();
                    drop(s);
                    let data = sb.lock().expect("scrollback lock").read_from_clean_point();
                    data
                };
                if !scrollback_data.is_empty() {
                    let frame = Frame::scrollback(0, scrollback_data);
                    let encoded = frame::encode(&frame, true)
                        .context("encode scrollback frame")?;
                    send.write_all(&encoded).await.context("send scrollback")?;
                }

                // Transition to bridge mode (consumes the stream)
                return run_bridge(send, recv, session_manager, session_id).await;
            }
            "list_sessions" => {
                let request_id = req["request_id"].as_str().unwrap_or("");
                let sessions = session_manager.list_sessions();
                let resp = serde_json::json!({
                    "type": "session_list",
                    "request_id": request_id,
                    "sessions": sessions,
                });
                write_json(&mut send, &resp).await?;
                // Continue looping for more requests
            }
            "destroy_session" => {
                let session_id = req["session_id"]
                    .as_str()
                    .context("missing session_id")?;
                let request_id = req["request_id"].as_str().unwrap_or("");

                let result = session_manager.destroy_session(session_id);
                let resp = serde_json::json!({
                    "type": "session_destroyed",
                    "request_id": request_id,
                    "success": result.is_ok(),
                    "error": result.err().map(|e| e.to_string()),
                });
                write_json(&mut send, &resp).await?;
                // Continue looping for more requests
            }
            "remove_device" => {
                let request_id = req["request_id"].as_str().unwrap_or("");
                info!("device requested self-removal");
                let resp = serde_json::json!({
                    "type": "device_removed",
                    "request_id": request_id,
                    "success": true,
                });
                write_json(&mut send, &resp).await?;
                return Ok(());
            }
            other => {
                warn!("unknown session request type: {other}");
                let resp = serde_json::json!({
                    "type": "error",
                    "error": format!("unknown request type: {other}"),
                });
                write_json(&mut send, &resp).await?;
            }
        }
    }
}

/// Run the frame-based bridge for an attached session.
async fn run_bridge(
    send: SendStream,
    recv: RecvStream,
    session_manager: &SessionManager,
    session_id: &str,
) -> Result<()> {
    let session = session_manager
        .get_session(session_id)
        .context("session not found for bridge")?;

    let cancel = CancellationToken::new();

    // Take the PTY reader (only one bridge at a time)
    let pty_reader = {
        let mut s = session.lock().expect("session lock");
        if s.attached {
            anyhow::bail!("session {session_id} already attached");
        }
        s.attached = true;
        s.bridge_cancel = Some(cancel.clone());
        s.reader
            .take()
            .context("PTY reader already taken")?
    };

    let writer = {
        let s = session.lock().expect("session lock");
        s.writer.clone()
    };

    let scrollback = {
        let s = session.lock().expect("session lock");
        s.scrollback.clone()
    };

    let master_for_resize = {
        // We can't move master out, but we need resize.
        // Store a reference to the session for resize handling.
        session.clone()
    };

    let result = run_bridge_inner(
        send,
        recv,
        pty_reader,
        writer,
        scrollback,
        master_for_resize,
        cancel.clone(),
    )
    .await;

    // On disconnect: clone a fresh reader from master, mark detached
    {
        let mut s = session.lock().expect("session lock");
        s.attached = false;
        s.bridge_cancel = None;
        // Clone a new reader for future reattach
        if s.reader.is_none() {
            match s.master.try_clone_reader() {
                Ok(reader) => {
                    s.reader = Some(reader);
                }
                Err(e) => {
                    warn!("failed to clone PTY reader on detach, marking session damaged: {e}");
                    s.damaged = true;
                }
            }
        }
    }

    result
}

async fn run_bridge_inner(
    mut send: SendStream,
    recv: RecvStream,
    pty_reader: Box<dyn Read + Send>,
    pty_writer: Arc<Mutex<Box<dyn Write + Send>>>,
    scrollback: Arc<Mutex<ScrollbackBuffer>>,
    session_ref: Arc<Mutex<PtySession>>,
    cancel: CancellationToken,
) -> Result<()> {
    let mut seq_out: u64 = 1;
    let client_window = Arc::new(std::sync::atomic::AtomicU64::new(DEFAULT_WINDOW));
    let window_notify = Arc::new(Notify::new());

    // PTY → channel (blocking thread)
    let (tx, mut rx) = mpsc::channel::<Vec<u8>>(128);
    let cancel_read = cancel.clone();

    let pty_read_handle = tokio::task::spawn_blocking(move || {
        let mut reader = pty_reader;
        let mut buf = [0u8; 16384];
        loop {
            if cancel_read.is_cancelled() {
                break;
            }
            match reader.read(&mut buf) {
                Ok(0) => {
                    info!("PTY reader EOF");
                    break;
                }
                Ok(n) => {
                    if tx.blocking_send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
                Err(e) => {
                    if e.raw_os_error() == Some(5) { // EIO
                        info!("PTY reader got EIO (child exited)");
                    } else {
                        error!("PTY read error: {e}");
                    }
                    break;
                }
            }
        }
    });

    // Channel → QUIC send (with framing and flow control)
    let window_for_send = client_window.clone();
    let notify_for_send = window_notify.clone();
    let scrollback_for_send = scrollback.clone();
    let cancel_send = cancel.clone();

    let send_handle = tokio::spawn(async move {
        while let Some(first) = rx.recv().await {
            if cancel_send.is_cancelled() {
                break;
            }

            // Coalesce: drain any additional queued data into a single buffer
            let mut data = first;
            while let Ok(more) = rx.try_recv() {
                if data.len() + more.len() > frame::MAX_PAYLOAD {
                    break;
                }
                data.extend_from_slice(&more);
            }

            // Append to scrollback
            {
                let mut sb = scrollback_for_send.lock().expect("scrollback lock");
                sb.append(&data);
            }

            // Wait for flow control window to have space
            loop {
                let window = window_for_send.load(std::sync::atomic::Ordering::Relaxed);
                if window > 0 || cancel_send.is_cancelled() {
                    break;
                }
                // Wait for window update notification (with timeout to avoid deadlock)
                tokio::select! {
                    _ = notify_for_send.notified() => {}
                    _ = tokio::time::sleep(std::time::Duration::from_secs(5)) => {
                        warn!("flow control: window still 0 after 5s, resuming");
                        break;
                    }
                    _ = cancel_send.cancelled() => break,
                }
            }

            // Encode frame with compression for larger payloads
            let compress = data.len() > 256;
            let frame = Frame::data(seq_out, data);
            seq_out += 1;

            match frame::encode(&frame, compress) {
                Ok(encoded) => {
                    let wire_payload = encoded.len().saturating_sub(15) as u64; // 15 = frame header
                    if send.write_all(&encoded).await.is_err() {
                        break;
                    }
                    // Saturating subtraction to prevent underflow wrapping
                    window_for_send.fetch_update(
                        std::sync::atomic::Ordering::Relaxed,
                        std::sync::atomic::Ordering::Relaxed,
                        |w| Some(w.saturating_sub(wire_payload)),
                    ).ok();
                }
                Err(e) => {
                    error!("frame encode error: {e}");
                    break;
                }
            }
        }
        let _ = send.finish();
    });

    // QUIC recv → frame decode → PTY write / handle control frames
    let window_for_recv = client_window;
    let notify_for_recv = window_notify;
    let cancel_recv = cancel.clone();

    let recv_handle = tokio::spawn(async move {
        let mut decoder = FrameDecoder::new();
        let mut recv = recv;
        let mut buf = [0u8; 16384];

        loop {
            if cancel_recv.is_cancelled() {
                break;
            }

            match recv.read(&mut buf).await {
                Ok(Some(n)) => {
                    decoder.feed(&buf[..n]);

                    loop {
                        match decoder.decode_next() {
                            Ok(Some(frame)) => {
                                match frame.frame_type {
                                    FrameType::Data => {
                                        let data = frame.payload;
                                        let mut w = pty_writer.lock()
                                            .expect("pty writer lock");
                                        if w.write_all(&data).is_err() {
                                            return;
                                        }
                                        drop(w);
                                        // Track last input activity
                                        if let Ok(mut s) = session_ref.try_lock() {
                                            s.last_activity_at = chrono::Utc::now();
                                        }
                                    }
                                    FrameType::Resize => {
                                        if let Some((cols, rows)) = frame.parse_resize() {
                                            let cols = cols.clamp(1, 500);
                                            let rows = rows.clamp(1, 500);
                                            let s = session_ref.lock()
                                                .expect("session lock");
                                            if let Err(e) = s.resize(rows, cols) {
                                                warn!("resize error: {e}");
                                            }
                                        }
                                    }
                                    FrameType::WindowUpdate => {
                                        if let Some(window) = frame.parse_window_update() {
                                            window_for_recv.store(
                                                window,
                                                std::sync::atomic::Ordering::Relaxed,
                                            );
                                            notify_for_recv.notify_one();
                                        }
                                    }
                                    FrameType::Close => {
                                        info!("received Close frame");
                                        return;
                                    }
                                    FrameType::Heartbeat => {
                                        // No-op, connection keepalive is handled by QUIC
                                    }
                                    FrameType::Scrollback => {
                                        // Client shouldn't send scrollback frames
                                        warn!("unexpected Scrollback frame from client");
                                    }
                                }
                            }
                            Ok(None) => break, // need more data
                            Err(e) => {
                                error!("frame decode error: {e}");
                                return;
                            }
                        }
                    }
                }
                Ok(None) => {
                    info!("QUIC recv stream finished");
                    break;
                }
                Err(e) => {
                    error!("QUIC recv error: {e}");
                    break;
                }
            }
        }
    });

    // Wait for any task to end
    tokio::select! {
        _ = pty_read_handle => info!("PTY read task ended"),
        _ = send_handle => info!("QUIC send task ended"),
        _ = recv_handle => info!("QUIC recv task ended"),
        _ = cancel.cancelled() => info!("bridge cancelled"),
    }

    Ok(())
}

async fn write_json(send: &mut SendStream, value: &serde_json::Value) -> Result<()> {
    let json = serde_json::to_vec(value).context("serialize JSON")?;
    let len = (json.len() as u32).to_be_bytes();
    send.write_all(&len).await.context("write JSON length")?;
    send.write_all(&json).await.context("write JSON body")?;
    Ok(())
}
