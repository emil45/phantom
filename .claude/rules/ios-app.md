---
paths:
  - "ios/**/*.swift"
---

# iOS App

## Architecture

Terminal-first design: `TerminalScreen` is the root surface when paired. Sessions and settings are presented as sheets — the terminal never unmounts.

## Module Map

- `PhantomApp.swift` — Entry point. `ReconnectManager` + `TerminalDataSource` are `@StateObject`s here. `RootView` shows `PairingView` (unpaired) or `TerminalScreen` (paired) with auto-create-first-session logic.
- `Network/QUICClient.swift` — QUIC via NWConnection with cert fingerprint pinning
- `Network/ReconnectManager.swift` — Central coordinator: connection lifecycle, auth, session CRUD, frame I/O, reconnect with exponential backoff
- `Network/FrameCodec.swift` — Swift port of phantom-frame binary codec
- `Logging.swift` — `os.Logger` extensions (.quic, .auth, .session, .crypto)
- `Crypto/KeyManager.swift` — Secure Enclave P256 key (with `.userPresence` biometric on device) + Keychain-backed software fallback (simulator)
- `Crypto/PairingPayload.swift` — QR JSON parsing
- `Storage/DeviceStore.swift` — UserDefaults pairing data, `deviceId` is a `let` constant (thread-safe)
- `Terminal/TerminalDataSource.swift` — Bridges ReconnectManager events to SwiftTerm TerminalView
- `Terminal/TerminalContainerView.swift` — UIViewRepresentable with safeAreaLayoutGuide constraints + pinch-to-zoom for font size
- `DesignSystem/PhantomTokens.swift` — Spacing (4pt grid), radii, Dynamic Type typography (SF Pro Rounded chrome, monospace terminal), animation curves, semantic chrome colors derived from terminal theme
- `DesignSystem/PhantomHaptic.swift` — Centralized haptic vocabulary (keyPress, modifierToggle, sessionSwitch, connected, disconnected, pairingSuccess, tick)
- `Views/PairingView.swift` — Multi-step onboarding: Welcome → QR Scanner → Connecting → Success
- `Views/TerminalScreen.swift` — Terminal-first root: full-screen terminal with SessionPill overlay, ConnectionOverlay, sessions sheet, swipe-between-sessions gesture
- `Views/SessionListView.swift` — `SessionsSheet`: bottom sheet with server info, session list, settings navigation
- `Views/SessionPill.swift` — Compact capsule at top of terminal showing current session + connection status
- `Views/ConnectionOverlay.swift` — Centered reconnection overlay with pulse animation and "session preserved" messaging
- `Views/SettingsView.swift` — Appearance, Connection (with tappable fingerprint), Security (unpair with confirmation), About
- `Views/QuickKeyToolbar.swift` — Horizontal quick-key row with paste key, centralized haptics
- `Views/ExtendedKeyPanel.swift` — Segmented key groups (Ctrl/Nav/Brackets/Symbols/Fn) with F1-F12
- `Views/ThemePickerView.swift` — Real terminal content previews, font size stepper with current size display

## Pitfalls

- `NWProtocolQUIC.Options` has no `keepaliveInterval` property — daemon handles keepalive via pings
- `multipathServiceType` must be `.disabled` — `.handover` requires Apple entitlement
- QUIC idle timeout on iOS = 90_000ms (must be > daemon's 60s)
- `TerminalContainerView` must constrain to `safeAreaLayoutGuide` (not plain anchors) to avoid left-edge clipping
- `detachSession()` disconnects + reconnects to get fresh control stream (bridge mode consumes the stream)
- Control stream errors in session methods (list/create/attach/destroy) trigger `handleControlStreamError()` -> reconnect
- `FrameDecoder` buffer capped at 1MB, keystroke buffer at 10K entries
- `NWConnection.State` doesn't conform to `CustomStringConvertible` — use `String(describing:)` in os.Logger interpolation
- `removeDeviceAndDisconnect()` sends `remove_device` RPC then clears local pairing
- Reconnect backoff includes 30% jitter to prevent thundering herd
- `SessionTabBar.swift` was removed — replaced by `SessionPill` + `SessionsSheet` architecture
- `PhantomColors` is derived from terminal theme and injected via SwiftUI Environment
- Typography uses Dynamic Type semantic styles (`.headline`, `.subheadline`, `.caption`) with `.rounded` design — never use fixed `size:` for chrome UI text
