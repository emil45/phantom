//! Test client for Phase 0 spike.
//! Connects to the daemon, authenticates with shared secret,
//! and bridges stdin/stdout to the QUIC terminal stream.
//!
//! Usage: cargo run --example test_client
//! Press Ctrl-] to exit.

use anyhow::{Context, Result};
use std::io::{self, Read, Write};
use std::sync::Arc;
use tokio::sync::mpsc;

const SHARED_SECRET: &[u8; 32] = b"phantom-spike-secret-0123456789!";

#[tokio::main]
async fn main() -> Result<()> {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("install crypto provider");

    let mut rustls_config = rustls::ClientConfig::builder()
        .dangerous()
        .with_custom_certificate_verifier(Arc::new(AcceptAnyCert))
        .with_no_client_auth();

    rustls_config.alpn_protocols = vec![b"phantom/0".to_vec()];

    let client_config = quinn::ClientConfig::new(Arc::new(
        quinn::crypto::rustls::QuicClientConfig::try_from(rustls_config)?,
    ));

    let mut endpoint = quinn::Endpoint::client("0.0.0.0:0".parse()?)?;
    endpoint.set_default_client_config(client_config);

    eprintln!("Connecting to localhost:4433...");
    let connection = endpoint
        .connect("127.0.0.1:4433".parse()?, "phantom.local")?
        .await
        .context("QUIC handshake")?;
    eprintln!("Connected!");

    let (mut send, mut recv) = connection.open_bi().await.context("open stream")?;
    eprintln!("Authenticating...");

    send.write_all(SHARED_SECRET).await.context("send secret")?;
    eprintln!("OK. Terminal session active. Press Ctrl-] to exit.\r");

    let _raw = RawTerminal::enter().ok(); // Fails gracefully if stdin is piped

    // stdin → channel → QUIC send
    let (tx, mut rx) = mpsc::channel::<Vec<u8>>(64);

    let stdin_handle = tokio::task::spawn_blocking(move || {
        let mut stdin = io::stdin();
        let mut buf = [0u8; 1024];
        loop {
            match stdin.read(&mut buf) {
                Ok(0) => {
                    // EOF on stdin (piped input). Wait briefly for output.
                    std::thread::sleep(std::time::Duration::from_secs(1));
                    break;
                }
                Ok(n) => {
                    if buf[..n].contains(&0x1d) {
                        break;
                    }
                    if tx.blocking_send(buf[..n].to_vec()).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    });

    let send_handle = tokio::spawn(async move {
        while let Some(data) = rx.recv().await {
            if send.write_all(&data).await.is_err() {
                break;
            }
        }
        let _ = send.finish();
    });

    let recv_handle = tokio::spawn(async move {
        let mut buf = [0u8; 4096];
        let mut stdout = io::stdout();
        loop {
            match recv.read(&mut buf).await {
                Ok(Some(n)) => {
                    let _ = stdout.write_all(&buf[..n]);
                    let _ = stdout.flush();
                }
                Ok(None) | Err(_) => break,
            }
        }
    });

    tokio::select! {
        _ = stdin_handle => {},
        _ = send_handle => {},
        _ = recv_handle => {},
    }

    Ok(())
}

#[derive(Debug)]
struct AcceptAnyCert;

impl rustls::client::danger::ServerCertVerifier for AcceptAnyCert {
    fn verify_server_cert(
        &self,
        _end_entity: &rustls::pki_types::CertificateDer<'_>,
        _intermediates: &[rustls::pki_types::CertificateDer<'_>],
        _server_name: &rustls::pki_types::ServerName<'_>,
        _ocsp_response: &[u8],
        _now: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn verify_tls13_signature(
        &self,
        _message: &[u8],
        _cert: &rustls::pki_types::CertificateDer<'_>,
        _dss: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        Ok(rustls::client::danger::HandshakeSignatureValid::assertion())
    }

    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        vec![
            rustls::SignatureScheme::ECDSA_NISTP256_SHA256,
            rustls::SignatureScheme::ECDSA_NISTP384_SHA384,
            rustls::SignatureScheme::ED25519,
            rustls::SignatureScheme::RSA_PSS_SHA256,
            rustls::SignatureScheme::RSA_PSS_SHA384,
            rustls::SignatureScheme::RSA_PSS_SHA512,
        ]
    }
}

struct RawTerminal {
    original: libc::termios,
}

impl RawTerminal {
    fn enter() -> io::Result<Self> {
        unsafe {
            let mut original: libc::termios = std::mem::zeroed();
            if libc::tcgetattr(0, &mut original) != 0 {
                return Err(io::Error::last_os_error());
            }
            let mut raw = original;
            libc::cfmakeraw(&mut raw);
            if libc::tcsetattr(0, libc::TCSANOW, &raw) != 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(Self { original })
        }
    }
}

impl Drop for RawTerminal {
    fn drop(&mut self) {
        unsafe {
            libc::tcsetattr(0, libc::TCSANOW, &self.original);
        }
    }
}
