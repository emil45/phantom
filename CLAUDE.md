# Phantom

Secure remote terminal over QUIC: iOS app → Rust daemon on macOS.

<architecture>
- `daemon/` — Rust workspace (`phantom-daemon` + `phantom-frame`)
- `ios/` — SwiftUI + Network.framework + SwiftTerm
- `macos/` — Menu bar app (PhantomBar), daemon lifecycle via LaunchAgent, IPC over Unix socket
- Config: `~/.phantom/config.toml` · Pairing tokens: `~/.phantom/pairing_tokens.json` · Devices: `~/.phantom/devices.json`
</architecture>

<build>
- Daemon: `cd daemon && cargo build` / `cargo test`
- iOS: open `ios/Phantom.xcodeproj` in Xcode (iOS 16+)
- macOS: `cd macos && xcodebuild -project PhantomBar.xcodeproj -scheme PhantomBar build`
- ALWAYS `cd daemon/` before cargo commands — Xcode builds change cwd
</build>

<versioning>
- NEVER find-replace version strings — pbxproj object IDs contain digit sequences that will get corrupted
- ALWAYS use: `./scripts/bump-version.sh <new-version>` (updates 6 files, 8 locations, validates)
- Run with no args to see current version (0.5.0)
</versioning>

<constraints>
- Bridge mode consumes the QUIC stream — client must disconnect+reconnect to return to control mode
- `TerminalDataSource` MUST be `@StateObject` in PhantomApp, not in views — SwiftUI recreation breaks the terminal data pipeline
- PhantomBar uses NSMenu, NOT NSPopover — do not change this
- Menu bar icon MUST use `isTemplate = true` for correct light/dark rendering
- Pairing flow opens in a floating NSPanel, not a sheet on a popover
- Quitting PhantomBar does NOT stop the daemon — sessions are daemon-owned
- Destructive actions (remove device, end session) MUST show confirmation dialogs on both platforms
- `macos/PhantomBar/DeviceRow.swift` and `SessionRow.swift` are dead code — do not use or extend them
</constraints>

<memory_maintenance>
After every significant feature, refactor, or dev session: review whether `.claude/rules/*.md` or this file need updates.
- New pitfalls or constraints discovered during implementation
- Changed architecture or removed/added components
- New build steps, scripts, or workflow changes
- Gotchas that wasted time and should be captured
- Prune stale entries — outdated rules cause wrong behavior
</memory_maintenance>
