---
paths:
  - "ios/**/*.swift"
---

# iOS App

<architecture>
- Terminal-first: `TerminalScreen` is the root surface when paired
- Sessions and settings present as sheets — the terminal MUST never unmount
- `SessionTabBar.swift` was removed — replaced by `SessionPill` + `SessionsSheet`
</architecture>

<pitfalls>
- `NWProtocolQUIC.Options` has NO `keepaliveInterval` property — daemon handles keepalive
- `multipathServiceType` MUST be `.disabled` — `.handover` requires Apple entitlement
- QUIC idle timeout on iOS = 90_000ms (must be > daemon's 60s)
- `TerminalContainerView` MUST constrain to `safeAreaLayoutGuide` (not plain anchors) — left-edge clipping otherwise
- `FrameDecoder` buffer capped at 1MB, keystroke buffer at 10K entries
</pitfalls>

<session_lifecycle>
- `detachSession()` disconnects + reconnects to get fresh control stream (bridge consumes the stream)
- New session from sessions sheet: detach current first, then create after 0.3s delay (bridge consumes stream)
- Control stream errors in session methods trigger `handleControlStreamError()` → reconnect
- Auth failures do NOT auto-reconnect — user must re-pair
</session_lifecycle>

<reconnection>
- Connect timeout fires after 15s, cancels and schedules reconnect
- Backoff: `[0.5, 1, 2, 4, 8, 15, 30, 60]`s with 30% jitter
</reconnection>

<design_system>
- Typography: Dynamic Type semantic styles (`.headline`, `.subheadline`, `.caption`) with `.rounded` design — NEVER use fixed `size:` for chrome UI text
- Spacing: 4pt grid (`PhantomTokens`)
- Colors: `PhantomColors` derived from terminal theme, injected via SwiftUI Environment
- Haptics: use `PhantomHaptic` vocabulary — do not create ad-hoc haptic calls
</design_system>
