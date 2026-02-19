---
paths:
  - "daemon/**/*.rs"
  - "daemon/**/*.toml"
---

# Rust Daemon

<pitfalls>
- `RateLimiter.is_allowed()` = read-only check; `.check()` = records attempt. Use `is_allowed()` in accept loop, `check()` only on auth failure
- `handle_auth` returns ownership of `(SendStream, RecvStream)` — do not borrow, move the tuple
- Pairing tokens are file-based (not in-memory) so `phantom pair` and `phantom daemon` share them across processes. Expired tokens are pruned on every `load_tokens()` call
- PTY size MUST be clamped to 1..=500 rows/cols in both create and resize
</pitfalls>

<bridge>
- Send loop waits on `Notify` when flow control window=0 (5s timeout fallback)
- Window accounting uses wire (post-compression) payload size, not raw size
</bridge>

<networking>
- QUIC idle timeout = 60s, keepalive = 10s (Quinn transport config)
- `server::run()` uses `tokio::select!` with `ctrl_c()` for graceful shutdown — closes endpoint, destroys all sessions
- IPC has per-connection rate limiting (20 req/s sliding window)
</networking>

<sessions>
- `damaged` flag marks unrecoverable PTY reader failure — these are auto-reaped
</sessions>
