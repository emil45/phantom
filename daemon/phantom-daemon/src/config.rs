use clap::{Parser, Subcommand};
use std::net::SocketAddr;

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
        #[arg(long, default_value = "[::]:4433")]
        bind: SocketAddr,
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
