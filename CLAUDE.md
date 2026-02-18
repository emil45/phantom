# Phantom

Zero-config secure remote terminal access over QUIC. iOS app connects to a Rust daemon on macOS for full terminal sessions over an encrypted tunnel.

## Architecture

- **daemon/** — Rust workspace: `phantom-daemon` (QUIC server, auth, PTY bridge) + `phantom-frame` (binary frame codec)
- **ios/** — SwiftUI app using Network.framework (QUIC) + SwiftTerm (terminal emulation)
- **macos/** — Menu bar app (PhantomBar): NSMenu-based status item, daemon lifecycle via LaunchAgent, IPC over Unix domain socket

CLI binary: `phantom daemon | pair | rotate-cert | device list|remove`

## Protocol

Single QUIC bidi stream. Control channel uses length-prefixed JSON (`[4B len BE][JSON]`). After `create_session`/`attach_session`, stream switches to binary frames (`[1B type][4B len BE][8B seq BE][2B flags][payload]`). Stream is consumed by bridge mode — client must disconnect+reconnect to return to control mode.

Frame types: Data(0x01), Resize(0x02), Heartbeat(0x03), Close(0x04), Scrollback(0x05), WindowUpdate(0x06). Flag bit 0 = zstd compressed.

## Build

- Daemon: `cd daemon && cargo build` / `cargo test`
- iOS: open `ios/Phantom.xcodeproj` in Xcode (iOS 16+, SPM deps: SwiftTerm, CodeScanner)
- macOS: `cd macos && xcodebuild -project PhantomBar.xcodeproj -scheme PhantomBar build` (macOS 13+)
- Always `cd daemon/` before cargo commands — Xcode builds can change cwd

## Key Design Decisions

- Single QUIC stream (not multiplexed) — NWConnectionGroup had reliability issues
- Secure Enclave P256 keys for challenge-response auth
- Self-signed cert with SHA-256 fingerprint pinning via pairing QR code
- File-based pairing tokens at `~/.phantom/pairing_tokens.json` (shared between `phantom pair` and `phantom daemon` processes)
- Optional TOML config at `~/.phantom/config.toml` (rate limits, reaper interval, bind address)
- `TerminalDataSource` must be `@StateObject` in PhantomApp, not in views (SwiftUI recreation breaks terminal data pipeline)
- PhantomBar uses NSMenu (not NSPopover) — native keyboard nav, VoiceOver, and appearance handling for free
- Menu bar icon must use `isTemplate = true` for correct light/dark/auto-hide rendering
- Pairing flow opens in a floating NSPanel, not a sheet on a popover
- DeviceRow.swift and SessionRow.swift are dead code (devices/sessions are standard NSMenuItems now)
