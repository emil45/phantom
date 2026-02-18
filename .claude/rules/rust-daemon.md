---
paths:
  - "daemon/**/*.rs"
  - "daemon/**/*.toml"
---

# Rust Daemon

## Module Map

- `server.rs` — QUIC accept loop, rate limiting (connection + auth-failure), per-connection task spawn
- `auth.rs` — Challenge-response (P256/ECDSA) + pairing flow. Returns `(device_id, SendStream, RecvStream)` tuple so streams are reused after auth
- `bridge.rs` — Control message loop; list/destroy loop back, create/attach enter `run_bridge()` which consumes the stream
- `session.rs` — PTY session manager (portable-pty). Create/attach/destroy/list
- `device_store.rs` — `~/.phantom/devices.json` for paired devices, `~/.phantom/pairing_tokens.json` for one-time tokens (SystemTime-based expiry)
- `tls.rs` — Self-signed cert gen (rcgen), SHA-256 fingerprint (base64)
- `config.rs` — CLI args (clap) + `DaemonConfig` TOML deserialization (`~/.phantom/config.toml` for rate limits, reaper interval, bind)

## Pitfalls

- `RateLimiter.is_allowed()` = read-only check; `.check()` = records attempt. Use `is_allowed()` in accept loop, `check()` only on auth failure
- `handle_auth` returns ownership of `(SendStream, RecvStream)` back to caller — Rust ownership pattern to avoid borrow issues
- QUIC idle timeout = 60s, keepalive interval = 10s (via Quinn transport config)
- Pairing tokens are file-based (not in-memory) so `phantom pair` CLI and `phantom daemon` can share them across processes
- PTY size clamped to 1..=500 rows/cols in both create and resize paths
- `server::run()` uses `tokio::select!` with `ctrl_c()` for graceful shutdown — closes endpoint, destroys all sessions
- Bridge send loop waits on `Notify` when flow control window=0 (5s timeout fallback)
- Expired pairing tokens pruned on every `load_tokens()` call
