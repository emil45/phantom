use anyhow::{Context, Result};
use quinn::crypto::rustls::QuicServerConfig;
use rcgen::{CertificateParams, KeyPair};
use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use sha2::{Digest, Sha256};
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tracing::info;

/// Paths for persistent TLS material under ~/.phantom/
fn phantom_dir() -> Result<PathBuf> {
    let home = dirs::home_dir().context("cannot determine home directory")?;
    let dir = home.join(".phantom");
    fs::create_dir_all(&dir).context("create ~/.phantom")?;
    Ok(dir)
}

fn cert_path() -> Result<PathBuf> {
    Ok(phantom_dir()?.join("server.crt"))
}

fn key_path() -> Result<PathBuf> {
    Ok(phantom_dir()?.join("server.key"))
}

/// SHA-256 fingerprint of a DER-encoded certificate, returned as raw bytes.
pub fn fingerprint(cert_der: &[u8]) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(cert_der);
    hasher.finalize().into()
}

/// SHA-256 fingerprint as a base64 string (for QR codes and display).
pub fn fingerprint_base64(cert_der: &[u8]) -> String {
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(fingerprint(cert_der))
}

/// Generate a new P256 self-signed certificate and persist to disk.
fn generate_and_persist() -> Result<(Vec<u8>, Vec<u8>)> {
    let key_pair = KeyPair::generate_for(&rcgen::PKCS_ECDSA_P256_SHA256)
        .context("generate P256 key pair")?;

    let params = CertificateParams::new(vec!["phantom.local".to_string()])
        .context("create cert params")?;

    let cert = params
        .self_signed(&key_pair)
        .context("self-sign certificate")?;

    let cert_der = cert.der().to_vec();
    let key_der = key_pair.serialize_der();

    let cert_pem = cert.pem();
    let key_pem = key_pair.serialize_pem();

    fs::write(cert_path()?, &cert_pem).context("write server.crt")?;
    fs::write(key_path()?, &key_pem).context("write server.key")?;

    let fp = fingerprint_base64(&cert_der);
    info!("generated new TLS certificate, fingerprint: {fp}");

    Ok((cert_der, key_der))
}

/// Load existing cert and key from disk, or generate new ones.
pub fn load_or_generate() -> Result<(Vec<u8>, Vec<u8>)> {
    let cp = cert_path()?;
    let kp = key_path()?;

    if cp.exists() && kp.exists() {
        let cert_pem = fs::read_to_string(&cp).context("read server.crt")?;
        let key_pem = fs::read_to_string(&kp).context("read server.key")?;

        let cert_der = pem_to_der(&cert_pem, "CERTIFICATE")
            .context("parse certificate PEM")?;
        let key_der = pem_to_der(&key_pem, "PRIVATE KEY")
            .context("parse key PEM")?;

        let fp = fingerprint_base64(&cert_der);
        info!("loaded TLS certificate, fingerprint: {fp}");

        Ok((cert_der, key_der))
    } else {
        generate_and_persist()
    }
}

/// Rotate: generate a new cert, replacing the old one on disk.
pub fn rotate_cert() -> Result<(Vec<u8>, Vec<u8>)> {
    info!("rotating TLS certificate");
    generate_and_persist()
}

/// Build a quinn ServerConfig from cert/key DER bytes.
pub fn build_server_config(cert_der: &[u8], key_der: &[u8]) -> Result<quinn::ServerConfig> {
    let cert = CertificateDer::from(cert_der.to_vec());
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(key_der.to_vec()));

    let mut rustls_config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .context("build rustls ServerConfig")?;

    rustls_config.alpn_protocols = vec![b"phantom/1".to_vec()];

    let quic_crypto = QuicServerConfig::try_from(rustls_config)
        .context("convert rustls config to QUIC config")?;

    let mut server_config = quinn::ServerConfig::with_crypto(Arc::new(quic_crypto));

    let transport = Arc::get_mut(&mut server_config.transport)
        .expect("transport config has no other refs at construction");
    transport.keep_alive_interval(Some(Duration::from_secs(10)));
    transport.max_idle_timeout(Some(
        Duration::from_secs(60)
            .try_into()
            .expect("60s fits in IdleTimeout"),
    ));
    server_config.migration(true);

    Ok(server_config)
}

/// Extract DER bytes from a PEM string. Simple parser, no external dep.
fn pem_to_der(pem: &str, expected_label: &str) -> Result<Vec<u8>> {
    use base64::Engine;
    let begin = format!("-----BEGIN {expected_label}-----");
    let end = format!("-----END {expected_label}-----");

    let b64: String = pem
        .lines()
        .skip_while(|l| !l.starts_with(&begin))
        .skip(1)
        .take_while(|l| !l.starts_with(&end))
        .collect();

    base64::engine::general_purpose::STANDARD
        .decode(&b64)
        .context("base64 decode PEM body")
}
