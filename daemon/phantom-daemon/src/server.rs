use anyhow::{Context, Result};
use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::time::timeout;
use tracing::{error, info, warn};

use crate::auth::Authenticator;
use crate::session::SessionManager;

/// Rate limiter: max N events per IP per window.
struct RateLimiter {
    /// Map of IP → list of event timestamps
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

    /// Returns true if the event should be allowed, and records it.
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

    /// Returns true if under the limit, without recording a new event.
    fn is_allowed(&self, ip: IpAddr) -> bool {
        let mut map = self.connections.lock().expect("rate limiter lock");
        let now = Instant::now();
        let timestamps = map.entry(ip).or_default();
        timestamps.retain(|t| now.duration_since(*t) < self.window);
        timestamps.len() < self.max_per_window
    }

    /// Record an event without checking limits (for tracking failures).
    fn record(&self, ip: IpAddr) {
        let mut map = self.connections.lock().expect("rate limiter lock");
        let now = Instant::now();
        let timestamps = map.entry(ip).or_default();
        timestamps.retain(|t| now.duration_since(*t) < self.window);
        timestamps.push(now);
    }
}

/// Run the QUIC server accept loop.
pub async fn run(
    endpoint: quinn::Endpoint,
    session_manager: Arc<SessionManager>,
    authenticator: Arc<Authenticator>,
) -> Result<()> {
    let rate_limiter = Arc::new(RateLimiter::new(5, Duration::from_secs(60)));
    // Separate limiter for auth failures: max 3 failed auths per IP per 5 minutes
    let auth_fail_limiter = Arc::new(RateLimiter::new(3, Duration::from_secs(300)));

    info!("accepting connections on {}", endpoint.local_addr()?);

    while let Some(incoming) = endpoint.accept().await {
        let remote = incoming.remote_address();
        let ip = remote.ip();

        if !rate_limiter.check(ip) {
            warn!("rate limited connection from {remote}");
            incoming.refuse();
            continue;
        }

        // Check if this IP has too many auth failures (read-only check)
        if !auth_fail_limiter.is_allowed(ip) {
            warn!("auth-failure rate limited connection from {remote}");
            incoming.refuse();
            continue;
        }

        let sm = session_manager.clone();
        let auth = authenticator.clone();
        let fail_limiter = auth_fail_limiter.clone();

        tokio::spawn(async move {
            if let Err(e) = handle_connection(incoming, sm, auth, fail_limiter).await {
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
    auth_fail_limiter: Arc<RateLimiter>,
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

    // Authenticate the connection (returns streams back for reuse)
    let (device_id, control_send, control_recv) = match authenticator
        .handle_auth(&connection, control_send, control_recv)
        .await
    {
        Ok(tuple) => tuple,
        Err(e) => {
            // Record auth failure for rate limiting
            auth_fail_limiter.record(remote.ip());
            return Err(e).context("authentication");
        }
    };

    info!("authenticated device {device_id} from {remote}");

    // Track this connection for the device
    session_manager.register_connection(&device_id, &connection);

    // Continue handling session requests on the same control stream.
    // The first bidi stream serves as both auth and session management.
    if let Err(e) = crate::bridge::handle_session_stream(
        control_send, control_recv, &session_manager, &device_id,
    )
    .await
    {
        info!("session stream ended for {device_id}: {e:#}");
    }

    // Also accept additional bidi streams (for future multi-stream support)
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

// macOS sleep prevention via IOKit IOPMAssertion
#[cfg(target_os = "macos")]
mod sleep_prevention {
    use std::sync::atomic::{AtomicU32, Ordering};

    // IOPMAssertionID
    static ASSERTION_ID: AtomicU32 = AtomicU32::new(0);

    // CoreFoundation and IOKit FFI
    type CFStringRef = *const std::ffi::c_void;
    type IOPMAssertionID = u32;

    extern "C" {
        fn CFStringCreateWithCString(
            alloc: *const std::ffi::c_void,
            c_str: *const std::ffi::c_char,
            encoding: u32,
        ) -> CFStringRef;
        fn CFRelease(cf: *const std::ffi::c_void);
        fn IOPMAssertionCreateWithName(
            assertion_type: CFStringRef,
            level: u32,
            reason: CFStringRef,
            assertion_id: *mut IOPMAssertionID,
        ) -> i32;
        fn IOPMAssertionRelease(assertion_id: IOPMAssertionID) -> i32;
    }

    const K_CF_STRING_ENCODING_UTF8: u32 = 0x08000100;
    // kIOPMAssertionTypePreventUserIdleSystemSleep
    const ASSERTION_TYPE: &[u8] = b"PreventUserIdleSystemSleep\0";
    const REASON: &[u8] = b"Phantom daemon active\0";
    // kIOPMAssertionLevelOn
    const K_IOPM_ASSERTION_LEVEL_ON: u32 = 255;

    pub fn prevent_sleep() {
        unsafe {
            let assertion_type = CFStringCreateWithCString(
                std::ptr::null(),
                ASSERTION_TYPE.as_ptr() as *const std::ffi::c_char,
                K_CF_STRING_ENCODING_UTF8,
            );
            let reason = CFStringCreateWithCString(
                std::ptr::null(),
                REASON.as_ptr() as *const std::ffi::c_char,
                K_CF_STRING_ENCODING_UTF8,
            );

            let mut assertion_id: IOPMAssertionID = 0;
            let result = IOPMAssertionCreateWithName(
                assertion_type,
                K_IOPM_ASSERTION_LEVEL_ON,
                reason,
                &mut assertion_id,
            );

            CFRelease(reason);
            CFRelease(assertion_type);

            if result == 0 {
                ASSERTION_ID.store(assertion_id, Ordering::Relaxed);
                tracing::info!("system sleep prevention enabled (IOPMAssertion {assertion_id})");
            } else {
                tracing::warn!("failed to create IOPMAssertion: error {result}");
            }
        }
    }

    pub fn allow_sleep() {
        let id = ASSERTION_ID.swap(0, Ordering::Relaxed);
        if id != 0 {
            unsafe {
                let result = IOPMAssertionRelease(id);
                if result == 0 {
                    tracing::info!("system sleep prevention disabled");
                } else {
                    tracing::warn!("failed to release IOPMAssertion: error {result}");
                }
            }
        }
    }
}

#[cfg(target_os = "macos")]
pub use sleep_prevention::{allow_sleep, prevent_sleep};

#[cfg(not(target_os = "macos"))]
pub fn prevent_sleep() {}
#[cfg(not(target_os = "macos"))]
pub fn allow_sleep() {}
