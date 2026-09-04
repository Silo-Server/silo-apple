# Silo Companion Pairing — Design Spec

- **Date:** 2026-06-14
- **Status:** Approved design, pre-implementation
- **Repo:** silo-apple (iOS + tvOS). Server endpoints already exist; Android is a documented follow-on.
- **Related:** `docs/tvos-onboarding/` (Tandem "companion" direction), tvOS first-run redesign.
- **Review history:** 2026-06-14 adversarial review (Codex). HIGH "persist-before-verify" → fixed (persist-on-success, §5/§6). CRITICAL "confirm-once multi-server MITM" → accepted as a documented v1 risk (§6, *Accepted risk*). 2026-06-14 second adversarial review: Face ID gate removed (a signed-in phone + the confirmation tap is the authorization); receiver poll loop made cancellable so peer cancel/drop aborts immediately (plan Task 8); confirm-once CRITICAL re-affirmed as accepted.

## 1. Summary

Let the **iOS app set up the Apple TV**. When the Silo iOS app is open on the same
Wi-Fi as an Apple TV sitting on its onboarding / add-server screen, the phone
discovers the TV automatically and offers a one-tap "Set up this Apple TV." The
phone hands the TV the server address(es) it already knows and approves the
TV's sign-in, so the user types **no URL and no password on the remote**.

This rides the Silo server's **existing** device-authorization endpoints
(`/auth/device/start`, `/poll`, `/approve`, `GET /auth/device`). v1 is therefore
**Apple-client work only** — no new server endpoints required.

### "Hands-off," stated honestly

Discovery and connection are automatic. The user makes exactly **one**
confirmation: they glance at a short match code shown on the TV and confirm it on
the phone. The phone is already signed in to the server, so that tap is the
authorization — there is no separate biometric step. The match-code confirmation
is the security anchor (§6) and cannot be removed without opening an
impersonation hole on a shared network. It
is still dramatically faster than thumb-typing a URL and password on a remote.

## 2. Goals / Non-goals

### Goals (v1)
1. iOS auto-discovers a waiting Apple TV on the LAN and surfaces a setup prompt.
2. Phone pushes the **server URL** to a blank, first-run TV (kills URL typing).
3. Phone approves the TV's sign-in via the server (kills password typing on TV).
4. User can **pick which** of the phone's servers to push (one or several).
5. Profiles/accounts are **not** separately synced — they come down from each
   server after the TV authenticates (the server is the sync layer).
6. Manual entry and the existing QR sign-in remain first-class fallbacks.

### Non-goals (deliberately out of v1 — YAGNI)
- **Push-to-phone** (server notifies an unopened phone). Needs push infra.
- **iCloud / CloudKit / Keychain sync** of servers or tokens. tvOS does not
  participate in iCloud Keychain for third-party apps, and syncing long-lived
  tokens out-of-band is a security smell. The server is the sync layer.
- **Replicating Apple's system proximity setup card.** That is a private
  entitlement (same tech as Quick Start / AirPods); third-party apps cannot
  silently sense an unopened phone or force an app to launch.
- **Playback control / remote handoff.** Mentioned as "later." The wire protocol
  is shaped so a future `PlaybackControl` message slots into the same channel
  without rework, but none of it is built in v1.

## 3. Roles & existing pieces this builds on

| Role | Platform | Behavior | Reuses |
|------|----------|----------|--------|
| **Receiver** | tvOS | Advertises on the LAN; waiting to be set up | `TVServerSetupView`, `ServerSetupViewModel` (URL normalize), `QRLoginViewModel`, `AppRouter` (auth state), `AppleDeviceIdentity`, `ServerRegistry`, `TokenStore` |
| **Companion** | iOS | Browses; in-hand; already signed in | `ServerRegistry`, `TokenStore`, `SiloAPI`, `HTTPClient` |
| **Server** | Go | Mints tokens; unchanged in v1 | `/auth/device/{start,poll,approve}`, `GET /auth/device`, `GET /auth/sessions` |

### Server endpoints (already implemented — verified in silo-server)
- `POST /auth/device/start` → `{ deviceCode, userCode, matchCode, verificationUri, verificationUriComplete, expiresAt, interval }`. `deviceCode` is the TV's secret; `matchCode` is a human-readable adjective-noun pair issued by the server.
- `GET /auth/device?code=<userCode>` (or `?token=<browserCode>`) → pending request metadata (device name, match code, masked IP).
- `POST /auth/device/approve` (authenticated) → marks the pending request `approved`, records `approved_by_user_id`.
- `POST /auth/device/poll` (device, with `deviceCode`) → `pending` until approved, then mints access/refresh tokens, creates an `auth_session`, marks `consumed`.
- State table `device_login_requests`: `pending → approved → consumed`, `pending → denied`, 10-minute TTL.

### New client method
`SiloAPI.approveDevice(code:)` and `SiloAPI.lookupDevice(code:)` — the
endpoints exist but approval was previously web-only (`web/src/pages/ActivateDevice.tsx`),
so the iOS client needs these thin wrappers over `HTTPClient`.

## 4. Components

Each unit has one purpose, a defined interface, and is testable in isolation.

### Shared (compiled into both targets)
- **`PairingProtocol`** — versioned `Codable` message envelope (the wire format).
  Pure data, no I/O. Platform-neutral and documented so silo-android can mirror it.
- **`PairingSession`** — wraps a single `NWConnection`. Length-prefixed JSON
  framing, async `send`/`receive`, TLS configuration. One instance per connection.
  Testable over an in-memory loopback pair.

### iOS — Companion
- **`TVPairingBrowser`** — wraps `NWBrowser` over `_silopair._tcp`. Publishes
  discovered TVs (name, deviceId, state, endpoint). Owns Local Network permission
  state and foreground/background lifecycle.
- **`CompanionPairingCoordinator`** — phone-side state machine. Connects to the
  chosen TV, runs the per-server loop, calls `SiloAPI` / `ServerRegistry` /
  `TokenStore`. Publishes observable state for the UI.
- **UI:**
  - `SetUpTVBanner` — auto-appears when a TV in `setup` state is discovered while
    the app is foreground. This **is** the hands-off detection surface. Also
    reachable from Settings → "Set up an Apple TV."
  - `TVPairingView` — server multi-select (only servers with valid tokens),
    match-code confirmation, per-server progress, success/failure summary.

### tvOS — Receiver
- **`TVPairingAdvertiser`** — wraps `NWListener` advertising `_silopair._tcp` + TXT.
  Accepts one inbound connection at a time. Lifecycle bound to the onboarding screen.
- **`ReceiverPairingCoordinator`** — TV-side state machine. On `PushServer`:
  normalize the URL and hold it as a **pending candidate** (not yet persisted),
  call `device/start`, display the match code, send `DeviceStarted`, then `poll`.
  Only after the poll returns tokens does it persist — store tokens in
  `TokenStore` and register the server in `ServerRegistry` — then send
  `ServerResult`, loop per server, and finally advance `AppRouter`. On any
  failure, decline, timeout, cancel, or dropped connection the pending candidate
  is discarded and nothing is persisted.
- **UI:** a "Set up with iPhone" state inside the in-progress **Tandem** first-run
  flow ("Looking for your iPhone…" → match code when a phone connects), with QR
  and manual entry kept as siblings/fallbacks.

## 5. Wire protocol & flow

### Discovery
- Bonjour service type **`_silopair._tcp`**, domain `local.`
- **TV advertises** (it is the device waiting to be found). TXT record carries
  **non-secret** fields only:
  - `v` — protocol version (e.g. `"1"`)
  - `name` — TV friendly name ("Living Room")
  - `id` — TV stable device id (from `AppleDeviceIdentity`); lets the phone
    de-dupe and recognize a previously-paired TV
  - `st` — `setup` (blank, needs a server) or `login` (has a server, needs a user)
- **Phone browses** with `NWBrowser`, then opens an `NWConnection`.

### Messages (envelope: flat `{ type, v, ...fields }`)
| Message | Direction | Payload |
|---------|-----------|---------|
| `Hello` | TV → phone | `{ tvName, tvDeviceId, state, supportedVersions }` |
| `PushServer` | phone → TV | `{ serverURL, serverName? }` |
| `DeviceStarted` | TV → phone | `{ serverURL, userCode, matchCode, expiresAt }` |
| `ServerResult` | TV → phone | `{ serverURL, status: signedIn \| failed, error? }` |
| `Done` | phone → TV | `{}` (no more servers; finish) |
| `Cancel` | either | `{ reason }` |

Version negotiation: `Hello.supportedVersions` ∩ phone's supported set; if empty,
phone shows "update one of your apps" and offers QR fallback.

### First-run sequence (blank TV, two servers picked)
1. TV enters onboarding → `TVPairingAdvertiser` advertises (`st=setup`). Screen
   shows "Open Silo on your iPhone to set this up" + QR + "Enter manually."
2. Phone (foreground, signed into ≥1 server) discovers the TV → `SetUpTVBanner`:
   "Set up Apple TV 'Living Room'?"
3. Tap → phone opens TLS `NWConnection` → receives `Hello`.
4. Phone shows its servers from `ServerRegistry` (**only** those with valid
   tokens) → user ticks S1, S2 → **Continue**. The phone's existing authenticated
   sessions authorize the approvals; there is no separate biometric step.
5. **Per chosen server Sᵢ (sequential):**
   1. Phone → `PushServer(Sᵢ.url)`.
   2. TV holds Sᵢ as a **pending candidate** (not yet written to `ServerRegistry`),
      calls `POST Sᵢ/auth/device/start` → `{deviceCode, userCode, matchCode}`. TV
      **displays the candidate server URL/name and matchCode**. TV →
      `DeviceStarted{userCode, matchCode}`.
   3. Phone displays matchCode. **For the first server only**, the user confirms
      it matches the TV screen (the anti-impersonation gate — §6). On confirm,
      phone calls `POST Sᵢ/auth/device/approve{code: userCode}` on Sᵢ's
      authenticated session.
   4. TV's `poll` loop reaches `approved` → server mints tokens → **only now** TV
      commits Sᵢ to `ServerRegistry`, stores tokens in `TokenStore` under Sᵢ, and
      marks Sᵢ known/active → TV → `ServerResult(signedIn)`. On failure, decline,
      timeout, cancel, or dropped connection the pending candidate is discarded —
      nothing is persisted.
6. After all chosen servers: phone → `Done`. Phone shows "Apple TV set up with 2
   servers." TV advances to profile selection ("Who's watching?") for the active server.

**Confirm-once rationale:** the match-code check establishes that the phone is
talking to *this physical TV*. Once confirmed for the first server in a session,
subsequent servers pushed over the same verified connection are auto-approved
without re-confirming. (Alternative — confirm per server — is a one-line policy
change if we decide we want it.)

### Re-login on an already-configured TV (`st=login`)
Identical, minus the URL push: the TV already has the server, so it can
`device/start` immediately and the phone can also push *additional* servers.

## 6. Security model

- **Tokens never cross the LAN.** The server mints them and delivers them to the
  TV over HTTPS via `poll`. The local channel only carries a server URL and a
  short-lived user/match code.
- **TLS** on the `NWConnection` uses a **fixed pre-shared key compiled into the
  app** (no certificate management). This gives **opportunistic confidentiality
  only**: the PSK lives in the app binary, so it is not an authentication
  boundary — it defeats casual passive sniffing but **not** an attacker who
  extracts the key or is actively on-path. Integrity of the approval rests on the
  match code, not on TLS.
- **Match code = the human trust anchor.** It is *server-issued*, shown on the
  physical TV, and confirmed on the phone before approval — for single-server pairing and the
  first server of a session (the confirm-once caveat for additional servers is in
  *Accepted risk* below). An active LAN attacker
  who swaps the `userCode`/`matchCode` in transit cannot make the phone's
  displayed code match what the **real TV** renders (the TV got its code straight
  from the server over HTTPS) — so the user catches the mismatch and declines.
  This is why the single confirmation tap is retained.
- **Worst-case bound on the URL push:** the TV treats a pushed URL as a *pending
  candidate*, displays it, and persists it only after a successful sign-in. If an
  attacker tampered with the URL, the TV would poll a bogus server (which cannot
  mint tokens for the user's real account), the user sees the wrong server name on
  screen and aborts, and **no server entry is persisted** — no credential
  compromise and no lingering bad state.
- Resulting TV session appears in `GET /auth/sessions`, named by device, and is
  user-revocable. Authorization is the user's confirmation tap on a phone already
  authenticated to the server — there is no separate biometric gate (a deliberate
  v1 choice: the signed-in phone is the authority).
- **Future hardening (not v1):** SPAKE2 / ECDH with a short-authentication-string
  to also mutually authenticate the URL push, removing reliance on the user's
  visual compare.

### Accepted risk (v1): confirm-once multi-server approval

**Decision (2026-06-14):** keep the confirm-once multi-server UX and accept the
exposure below for v1.

- **The exposure.** When a user pushes 2+ servers in a single session, only the
  first server's match code is visually confirmed; later servers are auto-approved
  over the same `NWConnection`. Because v1's TLS uses an app-embedded PSK (not an
  authenticated channel), an active on-path attacker can — *after* the legitimate first
  confirmation — substitute a later `DeviceStarted` payload with a `userCode` from
  the attacker's own pending device request. The phone, not re-confirming, approves
  it with the user's authenticated session, minting tokens to the attacker's device
  for that server.
- **Preconditions (all required).** An active on-path LAN attacker (ARP spoof /
  rogue AP) present during the pairing window; the user pairing **multiple** servers
  in one pass; the unauthenticated (app-embedded PSK) channel. **Not affected:**
  single-server pairing and the first server of any session (their match code is
  always confirmed).
- **Why accepted for v1.** Self-hosted home-media context; low probability of an
  active on-path attacker on a trusted home LAN; blast radius limited to
  media-account access on the affected server; the vulnerable surface is only the
  optional multi-server convenience path.
- **Mitigation if the threat model changes.** Switch to **confirm-per-server** — a
  localized policy change in `CompanionPairingCoordinator`, no protocol change — or
  add channel authentication (cert pinning / SPAKE2 with channel binding) so
  confirm-once becomes safe.
- **Tripwire — revisit before:** deploying for shared / public / multi-tenant
  networks, or exposing pairing beyond the local link.

## 7. Edge cases & error handling

| Case | Behavior |
|------|----------|
| iOS Local Network permission denied | Pairing browser inert; phone falls back to "open the app and scan the QR / enter the code." |
| TV not found (different Wi-Fi, AP/client isolation) | Phone times out (~10–15s), suggests QR/manual; TV keeps showing QR. |
| Match code mismatch | User declines → abort connection, discard the pending candidate (nothing persisted), log, allow retry. |
| Phone's token for Sᵢ expired | Refresh; if refresh fails, grey out Sᵢ in the picker with a "sign in on phone first" hint. |
| One server fails mid-loop | Continue remaining servers; the failed server's pending candidate is discarded (never persisted); report per-server status in the summary. |
| Connection drops | TV discards any pending candidate, returns to advertising; phone shows retry. |
| Multiple TVs discovered | Banner becomes a short list keyed by TXT `name`/`id`. |
| Second phone connects | TV accepts one connection at a time; rejects the second as busy. |
| iOS app backgrounded | `NWBrowser` suspends; resume on foreground. |
| Device-code expired (10-min TTL) before approval | TV restarts `device/start`, refreshes match code, re-sends `DeviceStarted`. |

## 8. Permissions & configuration

- **iOS Info.plist:** `NSLocalNetworkUsageDescription` (clear copy: "Silo uses your
  local network to find and set up your Apple TV") and `NSBonjourServices` listing
  `_silopair._tcp`. Browsing triggers the system Local Network prompt on first use.
- **tvOS Info.plist:** same `NSLocalNetworkUsageDescription` + `NSBonjourServices`
  (tvOS also enforces local-network privacy for advertising).
- Update `iosApp/project.yml` for any new source folders; regenerate with
  `xcodegen generate`. New shared files compile into both `Silo` (iOS) and `SiloTV`.

## 9. Testing (per CLAUDE.md — critical/high-risk logic only, not UI)

- **Unit:**
  - `PairingProtocol` encode/decode round-trip + version negotiation (including
    no-overlap).
  - `PairingSession` framing over an in-memory loopback pair (partial reads,
    multiple messages in one buffer, oversized frame rejection).
  - `CompanionPairingCoordinator` and `ReceiverPairingCoordinator` state machines
    against a **fake transport** + **fake `SiloAPI`**: happy path, multi-server,
    partial failure, match-code mismatch/decline, token expiry, cancel, code expiry.
    Assert **persist-on-success**: no `ServerRegistry` / `TokenStore` mutation until
    `signedIn`, and the pending candidate is rolled back on every
    failure / decline / cancel / timeout / drop.
- **Manual:** two-device (or two-simulator) pairing on a real LAN — Local Network
  prompt, AP isolation, match-code mismatch, multi-server pick.

## 10. Cross-repo coordination (workspace convention)

- **silo-server:** **No new endpoints for v1.** Awareness only. Nice-to-have
  later: surface `device_name` / `device_platform` (captured at `device/start`) in
  `GET /auth/sessions` so users recognize the TV in their session list.
- **silo-android:** `PairingProtocol` (the JSON messages) and the `_silopair._tcp`
  Bonjour type are defined platform-neutrally and documented here so Android
  phone↔TV can mirror the flow with Android NSD + sockets. Compare Android's
  onboarding copy/flow before finalizing strings. v1 ships Apple-only; this spec
  is the coordination artifact.
- **silo-apple:** all new client code + SwiftUI surfaces, wired into the Tandem
  first-run redesign.

## 11. Phasing

1. **v1 (this spec):** discovery → connect → confirm → pick servers → sign in.
   Apple-only client work, existing server endpoints.
2. **Later (not planned here):** push-to-phone notifications; playback/remote
   control over the same channel; SPAKE2 hardening; Android parity implementation.

## 12. Open questions

- Exact Local Network usage-description copy (legal/marketing review).
- Whether `SetUpTVBanner` should also appear in the iOS app's main UI (not just
  during onboarding) when a blank TV is detected, or only within an explicit
  "Set up an Apple TV" entry point.
