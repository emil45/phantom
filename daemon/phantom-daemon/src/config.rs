use clap::{Parser, Subcommand};
use serde::Deserialize;
use std::net::SocketAddr;
use std::path::Path;

#[derive(Parser, Debug)]
#[command(name = "phantom", about = "Phantom terminal daemon")]
pub struct Cli {
    #[command(subcommand)]
    pub command: Option<Command>,
}

#[derive(Subcommand, Debug)]
pub enum Command {
    /// Start the daemon (default if no subcommand)
    Daemon {
        /// Address to bind
        #[arg(long)]
        bind: Option<SocketAddr>,
    },
    /// Rotate the TLS certificate
    RotateCert,
    /// Generate a pairing token for a new device
    Pair {
        /// Print token string instead of QR code (for remote machines)
        #[arg(long)]
        token: bool,
    },
    /// Manage paired devices
    Device {
        #[command(subcommand)]
        action: DeviceAction,
    },
}

#[derive(Subcommand, Debug)]
pub enum DeviceAction {
    /// List paired devices
    List,
    /// Revoke a paired device
    Revoke {
        /// Device ID to revoke
        id: String,
    },
}

/// Configuration file (~/.phantom/config.toml)
#[derive(Debug, Deserialize, Default)]
#[serde(default)]
pub struct DaemonConfig {
    pub bind: Option<String>,
    pub rate_limit: RateLimitConfig,
    pub session: SessionConfig,
}

#[derive(Debug, Deserialize)]
#[serde(default)]
pub struct RateLimitConfig {
    /// Max connections per IP per window
    pub connection_limit: usize,
    /// Connection rate limit window (seconds)
    pub connection_window_secs: u64,
    /// Max auth failures per IP per window
    pub auth_failure_limit: usize,
    /// Auth failure rate limit window (seconds)
    pub auth_failure_window_secs: u64,
}

impl Default for RateLimitConfig {
    fn default() -> Self {
        Self {
            connection_limit: 5,
            connection_window_secs: 60,
            auth_failure_limit: 3,
            auth_failure_window_secs: 300,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(default)]
pub struct SessionConfig {
    /// Scrollback buffer size in bytes
    pub scrollback_bytes: usize,
    /// Session reaper interval (seconds)
    pub reaper_interval_secs: u64,
}

impl Default for SessionConfig {
    fn default() -> Self {
        Self {
            scrollback_bytes: 65536,
            reaper_interval_secs: 5,
        }
    }
}

impl DaemonConfig {
    pub fn load(phantom_dir: &Path) -> Self {
        let path = phantom_dir.join("config.toml");
        if path.exists() {
            match std::fs::read_to_string(&path) {
                Ok(contents) => match toml::from_str(&contents) {
                    Ok(config) => return config,
                    Err(e) => {
                        tracing::warn!("failed to parse config.toml: {e}, using defaults");
                    }
                },
                Err(e) => {
                    tracing::warn!("failed to read config.toml: {e}, using defaults");
                }
            }
        }
        Self::default()
    }
}
