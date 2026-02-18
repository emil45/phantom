pub mod auth;
pub mod bridge;
pub mod config;
pub mod device_store;
pub mod ipc;
pub mod server;
pub mod session;
pub mod tls;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
