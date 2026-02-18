use anyhow::{Context, Result};
use clap::Parser;
use phantom_daemon::config::{Cli, Command, DaemonConfig, DeviceAction};
use phantom_daemon::{auth, device_store, server, session, tls};
use std::sync::Arc;
use tokio_util::sync::CancellationToken;
use tracing::{info, warn};

#[tokio::main]
async fn main() -> Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("install crypto provider");

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info".into()),
        )
        .init();

    let cli = Cli::parse();

    match cli.command {
        None | Some(Command::Daemon { .. }) => {
            let phantom_dir = dirs::home_dir()
                .context("home dir")?
                .join(".phantom");
            std::fs::create_dir_all(&phantom_dir)?;

            let config = DaemonConfig::load(&phantom_dir);

            let cli_bind = match &cli.command {
                Some(Command::Daemon { bind }) => *bind,
                _ => None,
            };
            let bind = cli_bind
                .or_else(|| config.bind.as_ref().and_then(|b| b.parse().ok()))
                .unwrap_or_else(|| "[::]:4433".parse().unwrap());

            run_daemon(bind, &phantom_dir, &config).await
        }
        Some(Command::RotateCert) => {
            tls::rotate_cert()?;
            println!("Certificate rotated successfully.");
            Ok(())
        }
        Some(Command::Pair { token }) => {
            run_pair(token)
        }
        Some(Command::Device { action }) => {
            run_device_command(action)
        }
    }
}

async fn run_daemon(bind: std::net::SocketAddr, phantom_dir: &std::path::Path, config: &DaemonConfig) -> Result<()> {
    let (cert_der, key_der) = tls::load_or_generate()
        .context("load or generate TLS certificate")?;

    let fp = tls::fingerprint_base64(&cert_der);
    info!("certificate fingerprint: {fp}");

    let server_config = tls::build_server_config(&cert_der, &key_der)
        .context("build server config")?;

    let endpoint = quinn::Endpoint::server(server_config, bind)
        .context("bind QUIC endpoint")?;

    if bind.ip().is_unspecified() {
        warn!("listening on all interfaces ({bind}) — ensure firewall is configured");
    }

    let device_store = Arc::new(
        device_store::DeviceStore::new(phantom_dir)
            .context("initialize device store")?,
    );

    let authenticator = Arc::new(auth::Authenticator::new(device_store.clone()));

    if device_store.list_devices().is_empty() {
        warn!("no paired devices — run `phantom pair` to pair a device");
    }

    let session_manager = Arc::new(session::SessionManager::new());

    // Start the session reaper
    let cancel = CancellationToken::new();
    let sm_for_reaper = session_manager.clone();
    let cancel_for_reaper = cancel.clone();
    let reaper_interval = config.session.reaper_interval_secs;
    tokio::spawn(async move {
        sm_for_reaper.run_reaper(cancel_for_reaper, reaper_interval).await;
    });

    server::prevent_sleep();

    info!("Phantom daemon listening on {}", endpoint.local_addr()?);

    let rate_config = &config.rate_limit;
    let result = server::run(
        endpoint,
        session_manager,
        authenticator,
        rate_config.connection_limit,
        rate_config.connection_window_secs,
        rate_config.auth_failure_limit,
        rate_config.auth_failure_window_secs,
    ).await;

    server::allow_sleep();
    cancel.cancel();

    result
}

fn run_pair(token_only: bool) -> Result<()> {
    let phantom_dir = dirs::home_dir()
        .context("home dir")?
        .join(".phantom");

    let device_store = device_store::DeviceStore::new(&phantom_dir)
        .context("initialize device store")?;

    let token = device_store.create_pairing_token();

    let (cert_der, _) = tls::load_or_generate()
        .context("load TLS certificate")?;
    let fp = tls::fingerprint_base64(&cert_der);

    // Get local IP for QR code
    let host = local_ip().unwrap_or_else(|| "127.0.0.1".to_string());

    let qr_payload = serde_json::json!({
        "host": host,
        "port": 4433,
        "fp": fp,
        "tok": token,
        "name": hostname(),
        "v": 1,
    });

    let qr_json = serde_json::to_string(&qr_payload)?;

    if token_only {
        println!("Pairing token: {token}");
        println!("Host: {host}:4433");
        println!("Fingerprint: {fp}");
        println!("\nEnter these in the Phantom iOS app to pair.");
    } else {
        println!("Scan this QR code with the Phantom iOS app:\n");
        qr2term::print_qr(&qr_json)
            .context("print QR code")?;
        println!("\nOr use manual pairing:");
        println!("  Token: {token}");
        println!("  Host: {host}:4433");
        println!("  Fingerprint: {fp}");
    }

    println!("\nToken expires in 5 minutes.");
    Ok(())
}

fn run_device_command(action: DeviceAction) -> Result<()> {
    let phantom_dir = dirs::home_dir()
        .context("home dir")?
        .join(".phantom");

    let device_store = device_store::DeviceStore::new(&phantom_dir)
        .context("initialize device store")?;

    match action {
        DeviceAction::List => {
            let devices = device_store.list_devices();
            if devices.is_empty() {
                println!("No paired devices.");
            } else {
                println!("{:<20} {:<20} {:<30}", "DEVICE ID", "NAME", "LAST SEEN");
                for d in devices {
                    let last_seen = d
                        .last_seen
                        .map(|t| t.format("%Y-%m-%d %H:%M:%S").to_string())
                        .unwrap_or_else(|| "never".to_string());
                    println!("{:<20} {:<20} {:<30}", d.device_id, d.device_name, last_seen);
                }
            }
        }
        DeviceAction::Revoke { id } => {
            device_store.revoke_device(&id)?;
            println!("Device {id} revoked.");
        }
    }
    Ok(())
}

fn local_ip() -> Option<String> {
    use std::net::UdpSocket;
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    Some(socket.local_addr().ok()?.ip().to_string())
}

fn hostname() -> String {
    std::env::var("HOSTNAME")
        .or_else(|_| std::env::var("HOST"))
        .unwrap_or_else(|_| "phantom-host".to_string())
}
