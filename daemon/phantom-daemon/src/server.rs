use anyhow::{Context, Result};
use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::time::timeout;
use tracing::{error, info, warn};

use crate::auth::Authenticator;
use crate::session::SessionManager;

/// Rate limiter: max N unauthenticated connections per IP per window.
struct RateLimiter {
    /// Map of IP → list of connection timestamps
    connections: Mutex<HashMap<IpAddr, Vec<Instant>>>,
    max_per_window: usize,
    window: Duration,
}

impl RateLimiter {
    fn new(max_per_window: usize, window: Duration) -> Self {
        Self {
            connections: Mutex::new(HashMap::new()),
            max_per_window,
            window,
        }
    }

    /// Returns true if the connection should be allowed.
    fn check(&self, ip: IpAddr) -> bool {
        let mut map = self.connections.lock().expect("rate limiter lock");
        let now = Instant::now();
        let timestamps = map.entry(ip).or_default();

        // Prune expired entries
        timestamps.retain(|t| now.duration_since(*t) < self.window);

        if timestamps.len() >= self.max_per_window {
            false
        } else {
            timestamps.push(now);
            true
        }
    }
}

/// Run the QUIC server accept loop.
pub async fn run(
    endpoint: quinn::Endpoint,
    session_manager: Arc<SessionManager>,
    authenticator: Arc<Authenticator>,
) -> Result<()> {
    let rate_limiter = RateLimiter::new(5, Duration::from_secs(60));

    info!("accepting connections on {}", endpoint.local_addr()?);

    while let Some(incoming) = endpoint.accept().await {
        let remote = incoming.remote_address();
        let ip = remote.ip();

        if !rate_limiter.check(ip) {
            warn!("rate limited connection from {remote}");
            incoming.refuse();
            continue;
        }

        let sm = session_manager.clone();
        let auth = authenticator.clone();

        tokio::spawn(async move {
            if let Err(e) = handle_connection(incoming, sm, auth).await {
                error!("connection from {remote} failed: {e:#}");
            }
        });
    }

    Ok(())
}

async fn handle_connection(
    incoming: quinn::Incoming,
    session_manager: Arc<SessionManager>,
    authenticator: Arc<Authenticator>,
) -> Result<()> {
    let connection = incoming
        .accept()
        .context("accept incoming")?
        .await
        .context("QUIC handshake")?;

    let remote = connection.remote_address();
    info!("connection established with {remote}");

    // First bidirectional stream = control channel.
    // Must authenticate within 10 seconds.
    let (control_send, control_recv) = timeout(
        Duration::from_secs(10),
        connection.accept_bi(),
    )
    .await
    .context("auth timeout")?
    .context("accept control stream")?;

    // Authenticate the connection
    let device_id = authenticator
        .handle_auth(&connection, control_send, control_recv)
        .await
        .context("authentication")?;

    info!("authenticated device {device_id} from {remote}");

    // Track this connection for the device
    session_manager.register_connection(&device_id, &connection);

    // Handle subsequent streams (session data streams)
    loop {
        match connection.accept_bi().await {
            Ok((send, recv)) => {
                let sm = session_manager.clone();
                let did = device_id.clone();
                tokio::spawn(async move {
                    if let Err(e) = crate::bridge::handle_session_stream(
                        send, recv, &sm, &did,
                    )
                    .await
                    {
                        error!("session stream error for {did}: {e:#}");
                    }
                });
            }
            Err(quinn::ConnectionError::ApplicationClosed { .. }) => {
                info!("connection closed by {device_id}");
                break;
            }
            Err(quinn::ConnectionError::ConnectionClosed { .. }) => {
                info!("connection closed for {device_id}");
                break;
            }
            Err(e) => {
                warn!("connection error for {device_id}: {e}");
                break;
            }
        }
    }

    session_manager.unregister_connection(&device_id);
    Ok(())
}

// macOS sleep prevention via IOKit (full implementation deferred to Phase 5)
#[cfg(target_os = "macos")]
mod sleep_prevention {
    pub fn prevent_sleep() {
        tracing::debug!("sleep prevention: IOPMAssertion deferred to Phase 5");
    }

    pub fn allow_sleep() {
        tracing::debug!("sleep prevention: IOPMAssertion release deferred to Phase 5");
    }
}

#[cfg(target_os = "macos")]
pub use sleep_prevention::{allow_sleep, prevent_sleep};

#[cfg(not(target_os = "macos"))]
pub fn prevent_sleep() {}
#[cfg(not(target_os = "macos"))]
pub fn allow_sleep() {}
