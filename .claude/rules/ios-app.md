---
paths:
  - "ios/**/*.swift"
---

# iOS App

## Module Map

- `PhantomApp.swift` — Entry point. `ReconnectManager` + `TerminalDataSource` are `@StateObject`s here
- `Network/QUICClient.swift` — QUIC via NWConnection with cert fingerprint pinning
- `Network/ReconnectManager.swift` — Central coordinator: connection lifecycle, auth, session CRUD, frame I/O, reconnect with exponential backoff
- `Network/FrameCodec.swift` — Swift port of phantom-frame binary codec
- `Crypto/KeyManager.swift` — Secure Enclave P256 keypair for auth
- `Crypto/PairingPayload.swift` — QR JSON parsing
- `Storage/DeviceStore.swift` — Keychain-backed pairing data
- `Terminal/TerminalDataSource.swift` — Bridges ReconnectManager events to SwiftTerm TerminalView
- `Terminal/TerminalContainerView.swift` — UIViewRepresentable with safeAreaLayoutGuide constraints
- `Views/` — PairingView (QR scanner + manual entry), SessionListView, TerminalScreen

## Pitfalls

- `NWProtocolQUIC.Options` has no `keepaliveInterval` property — daemon handles keepalive via pings
- `multipathServiceType` must be `.disabled` — `.handover` requires Apple entitlement
- QUIC idle timeout on iOS = 90_000ms (must be > daemon's 60s)
- `TerminalContainerView` must constrain to `safeAreaLayoutGuide` (not plain anchors) to avoid left-edge clipping
- `detachSession()` disconnects + reconnects to get fresh control stream (bridge mode consumes the stream)
- Control stream errors in session methods (list/create/attach/destroy) trigger `handleControlStreamError()` -> reconnect
