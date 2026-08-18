# Companion pairing (iOS ↔ tvOS)

The LAN pairing flow that lets a signed-in iPhone set up a blank Apple TV: the
phone pushes a server URL and approves the TV's device-login request, and the
server mints the TV's tokens over HTTPS. This documents the shipped protocol
and, above all, its security model. The code under `iosApp/iosApp/Pairing/` is
the source of truth.

## Roles and transport

- **Receiver (tvOS)** advertises Bonjour service `_silopair._tcp`
  (`PairingProtocol.swift`) while waiting to be set up. The TXT record carries
  non-secret fields only: protocol version, friendly name, stable device id,
  and state (`setup` = needs a server, `login` = has a server, needs a user).
- **Companion (iOS)** browses with `NWBrowser` and opens one `NWConnection`.
  The TV accepts a single connection at a time.
- Messages are a flat JSON envelope `{ type, v, ...fields }` framed over the
  socket (`PairingProtocol.swift`, `PairingSession.swift`): `hello`,
  `pushServer`, `deviceStarted`, `serverResult`, `done`, `cancel`. Version
  negotiation happens on `hello.supportedVersions`; an unsupported version
  ends the session with an "update Silo on both devices" error (the TV's
  standing QR/manual sign-in remains the fallback path).
- Server side is the standard device-login flow
  (`/api/v1/auth/device/start`, `/api/v1/auth/device/poll`,
  `/api/v1/auth/device/approve`, lookup via `GET /api/v1/auth/device?code=`
  — see `PairingDeviceAPI.swift`); pairing adds no server endpoints.

## Security model

These are the invariants; do not weaken them for convenience.

- **Tokens never cross the LAN.** The server mints tokens and the TV receives
  them over HTTPS via `poll`. The local channel only ever carries a server URL
  and a short-lived user/match code.
- **The channel TLS is not an authentication boundary.** `PairingSession` uses
  TLS with a fixed pre-shared key compiled into the app — opportunistic
  confidentiality against casual sniffing, nothing more. Anyone with the app
  binary has the PSK. Integrity of an approval rests on the match code, never
  on the channel.
- **The match code is the human trust anchor — and the phone displays the
  server's copy, not the channel's.** On `deviceStarted`, the companion
  re-fetches the pending request from the server over authenticated HTTPS
  (`CompanionPairingCoordinator.handleDeviceStarted`) and shows *that* match
  code for the user to compare against the TV screen. A missing server match
  code is a hard failure, never an empty prompt. The channel's copy is
  advisory display only (`PairingProtocol.swift`).
- **A pushed URL is a pending candidate until sign-in succeeds.** The receiver
  displays it and persists the server entry only after polling succeeds
  (`ReceiverPairingCoordinator`). Tampered URL ⇒ the TV polls a bogus server
  that cannot mint tokens for the real account, the user sees the wrong name
  and aborts, and nothing is persisted. Connection drop or a declined match
  discards the candidate the same way.
- **Authorization is the confirmation tap on an already-authenticated phone.**
  The resulting TV session shows up in the server's session list, named by
  device, and is user-revocable. There is deliberately no extra biometric gate.

### Accepted risk (v1): confirm-once multi-server approval

When the user pushes several servers in one session, only the first server's
match code is visually confirmed. Later approvals are automatic, with one
shipped hardening: the coordinator refuses to auto-approve unless the server's
authoritative match code equals the code the TV displayed over the channel
(`handleDeviceStarted` in `CompanionPairingCoordinator.swift`) — a spliced
session with diverging codes is rejected. This does **not** close the full
exposure: an active on-path LAN attacker present during the pairing window can
still substitute a later `deviceStarted` with a pending request of their own,
and the unauthenticated PSK channel cannot detect it.

- **Preconditions (all required):** active on-path attacker (ARP spoof / rogue
  AP) during the window; multi-server pairing in one pass; the app-embedded
  PSK channel. Single-server pairing and the first server of any session are
  not affected — their match code is always confirmed.
- **Why accepted:** self-hosted home-media context, low likelihood of an
  active on-path attacker on a trusted home LAN, blast radius limited to
  media-account access on the affected server, and only the optional
  multi-server convenience path is exposed.
- **If the threat model changes:** switch to confirm-per-server (a localized
  policy change in `CompanionPairingCoordinator`, no protocol change) or add
  real channel authentication (cert pinning / SPAKE2 with channel binding).
- **Tripwire — revisit before** deploying on shared/public/multi-tenant
  networks or extending pairing beyond the local link.

## Cross-repo notes

- The transport currently relies on Apple `Network.framework` TLS-PSK
  behavior. Android interop needs matching TLS-PSK support or a coordinated
  transport change in both clients.
- Protocol or message changes must stay in step with `silo-android` and follow
  the device-login contract owned by `silo-server`.
