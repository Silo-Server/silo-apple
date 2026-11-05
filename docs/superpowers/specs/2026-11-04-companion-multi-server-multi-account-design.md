---
title: Companion Setup with Several Servers and Accounts — Design Spec
description: Let a phone sign a TV in to any chosen set of saved servers and accounts, on Apple, Android and Roku.
date: 2026-11-04
tags:
  - silo
  - apple
  - android
  - roku
  - pairing
  - accounts
  - design-spec
---

# Companion Setup with Several Servers and Accounts — Design Spec

- **Date:** 2026-11-04
- **Status:** Approved design, implemented (see §12 for decisions taken while implementing). Decisions D1–D4 (§9) settled 2026-11-04.
- **Repos:** `silo-apple` (iOS sender, tvOS receiver), `silo-android` (phone sender, Android TV
  receiver), `silo-roku` (receiver), `silo-server` (session binding, tests)
- **Baselines:** `silo-apple` `ffa6e518`; `silo-android` `61e4d3254`; `silo-roku` `1dd2d6cf`;
  `silo-server` `origin/main` `e3af98b06`
- **Builds on:** `2026-06-14-companion-pairing-design.md` (protocol v1),
  `2026-06-14-android-cross-platform-companion-pairing-design.md`,
  `2026-11-02-multi-account-design.md`, silo-roku `docs/companion-pairing.md`
- **Amends:** `2026-11-02-multi-account-design.md` §4.6 "Phone-assisted setup" (see §4.4 here),
  and closes the 2026-06-14 "confirm-once multi-server" accepted risk (see §6).

## 1. Summary

A phone that sets up a TV should be able to send it **any set of its saved servers and, on each
server, any of its saved accounts**, in one session, on every phone and TV we ship. Today only part
of that works, and differently on each platform (§2).

The plan is mostly client work on the existing v1 protocol:

1. The phone's chooser lists accounts under each server, with a checkbox per account. Only the
   phone's current account starts selected (§4.1).
2. A TV on its sign-in screen gets one account, and the phone lets the person choose which (§4.2).
3. Every TV that can keep several pushes per session advertises `acct=1`, which Apple already
   defines. Android TV and Roku start advertising it once they handle it (§5).
4. When one account signed in, the TV opens its "Who's watching?" as today. When several did, the
   TV opens Change Account so the person picks (§4.4).
5. To make one code comparison safe for many approvals, the server binds every request in a
   session to a secret only the real TV holds (§6). Against a server without that change, the
   phone asks the person to compare each account's code.

## 2. What happens today

Facts from code at the baselines; file references are in §11. Nothing here was run on devices.

### 2.1 Senders

| | iPhone / iPad | Android phone |
|---|---|---|
| Chooses several servers | Yes (Apple TV, Android TV) | Yes (Apple TV, Android TV) |
| Servers to a Roku | One (single-select) | One (radio buttons) |
| Accounts per server | Every signed-in account, automatically, but only to a TV advertising `acct=1` (Apple TV). Otherwise the server's in-use account. No per-account choice. | The server's current account only. No `acct` support. |
| TV on its sign-in screen (`st=login`) | Its server, with the phone's in-use account. No account choice. | Same. |
| "Not you?" on the LAN card | No (only on the QR / code approval card) | No (only on the QR / code approval screen) |
| One server fails | Continues with the rest, reports each | **Stops the whole session**; `done` is never sent |
| Confirmation | Compare once, then auto-approve the rest | Same |

### 2.2 Receivers

| | Apple TV | Android TV | Roku |
|---|---|---|---|
| Transport | `_silopair._tcp`, TLS-PSK | `_silopair._tcp`, TLS-PSK | `_silopair-roku._tcp`, plain TCP |
| Advertises `acct=1` | Yes | No | No |
| Several pushes per session | Yes | Yes | **No**: a push after a sign-in gets `auth_failed` |
| Saves each sign-in as an account, matched by server user ID | Yes (`AccountStore.saveSignIn`) | Yes, but a poll without `user` (older server) always creates a new account | Yes (`installAccount`, #32) |
| Advertises outside first run | Add server (`setup`), sign-in screen (`login`) | Add server (`setup`), sign-in screen (`login`) | Add server (`setup`), sign-in screen when signed out (`login`). Add an account on the active signed-in server advertises nothing. |
| Opens after `done` | First paired account when several signed in | **Last** committed account | The account that signed in |
| Storage limit | none relevant | none relevant | 32 KB registry: 7 saved servers + active, 12 accounts; LRU trimming |

### 2.3 Server

Nothing on the server limits a device to one account (checked on `origin/main`):

- Start, poll and approve have no per-device uniqueness, and session creation never revokes
  another user's session on the same device. `auth_sessions.device_id` is display data only.
- Each request is approved by exactly one account. A second account gets 409.
- `approve` takes the account from the caller's session and has no target-user field.
- All requests from one IP share a `device_poll` bucket of 120 per minute. Sequential pushes stay
  far below it.
- Push installations are one account per device ID, which matches multi-account §4.8: only the
  last-used account on a server gets notifications.
- No test covers several accounts approving separate requests from one device.

## 3. Goals and non-goals

**Goals**
- Send any subset of (server, account) pairs from either phone to any TV in one session.
- Keep the one-server, one-account case at today's speed: one tap on Set Up, one code comparison.
- Same chooser, rules and results on iPhone, iPad and Android phone; same receiver behavior on
  Apple TV, Android TV and Roku.
- Mixed versions keep working: old phone with new TV, new phone with old TV.

**Non-goals**
- Syncing profiles, PINs or remembered profiles. Profiles come from the server after sign-in.
- Moving tokens across the LAN. The server still mints them for the TV.
- A protocol v2 or a new transport. Every change is an additive v1 field or TXT key.
- Sending accounts the phone itself can't approve (needs sign-in again on the phone).
- Several accounts to a TV on its sign-in screen (D3).

## 4. User experience

### 4.1 Phone chooser (setup TV)

```
┌──────────────────────────────────────────┐
│ [tv] Choose accounts                     │
│      Sign Living Room in to…             │
│                                          │
│ [mark] Home                              │
│   (A) alex · this iPhone            (●)  │
│   (S) sam                           ( )  │
│ [mark] Lake House                        │
│   (A) alex                          ( )  │
│ [mark] Work                              │
│   (W) wkim   Sign in again on iPhone     │  ← disabled
│                                          │
│ [ Continue — 1 account ]                 │
│   Cancel                                 │
└──────────────────────────────────────────┘
```

- One section per saved server: server mark and name, then one row per account.
- A server with a single account shows the same layout with one row, so the layout never
  changes shape between cases.
- **Default selection (D2):** only the account the phone is using on its active server. Nobody
  signs a shared TV in as a housemate without ticking them.
- Accounts that need sign-in again on the phone are shown but disabled.
- The button counts what will be sent: "Continue — 3 accounts".
- **TV without `acct=1`** (older Apple TV, Android TV and Roku builds): account rows become
  single-select within a server ("one account per server on this TV"). An older Roku is
  single-select across the whole list, as today.
- **TV with a storage limit** (Roku, `lim` TXT key, §5.1): the phone disables further rows once
  the selection reaches the limit and says why.
- Order of sending: the phone's active account first, then list order. With several accounts the
  TV asks which to open (§4.4); the order sets which account it focuses first.

### 4.2 Phone card for a TV on its sign-in screen (`st=login`)

The TV already shows its own code for its own server. The card gains an account choice when the
phone has more than one signed-in account on that server (D3: one account):

```
Sign in Living Room to Home as
  (A) alex · this iPhone   ✓
  (S) sam
[ Sign In ]
```

- The phone's in-use account on that server starts selected.
- One account per sign-in screen. The person adds more from the TV's Change Account, or by
  choosing **Add server** on the TV, which advertises `setup`.
- This also covers multi-account §4.6 "Not you?" for the LAN path on both phones.

### 4.3 Progress and results

- After the first comparison, the card shows "Signing in sam on Home… (2 of 4)".
- When a target needs its own comparison (§6.3), the card shows the code step again for that
  account, naming it: "Check that Living Room shows … for sam on Lake House".
- A failure on one target continues with the next on both phones. Android changes to match Apple.
- The summary lists each target: "Home — alex, sam", "Lake House — alex", then failures with the
  existing per-code text from `CompanionPairingCoordinator.FailedServer.summary`.

### 4.4 TV

- Consent: the TV asks once per session, as now ("Allow this iPhone to set up this Apple TV?").
- While working, the TV shows the server name, the account name when the push carries one
  (§5.2), and the current request's code: "Signing in alex on Home".
- After `done`, or the connection closing after at least one sign-in, every TV does the same
  thing (D4):
  - **One account signed in this session:** open its "Who's watching?", as today. A single
    profile without a PIN opens directly.
  - **Several accounts signed in this session:** open **Change Account** (multi-account §4.1:
    server rail and accounts pane on TV). The rail selects the server of the first account that
    signed in, and focus starts on that account's card. Choosing a card opens that account's
    "Who's watching?".
  - The TV makes the first account that signed in the open account before showing Change
    Account, so it is marked **Current** and leaving Change Account with Back opens its picker.
    The person is never left without an open account.
  - This replaces multi-account §4.6 "opens the most recently used account's picker … does not
    add a separate Choose an Account step". It reuses the existing Change Account screen; there
    is no new screen.
  - Apple TV changes from switching straight to the first paired account
    (`TVServerSetupView.openPairedAccount`). Android TV changes from opening the last committed
    account. Roku changes from opening the only one.
- A pushed account that's already saved on the TV refreshes its credentials. It doesn't add a
  duplicate, and its remembered profile stays. It counts toward "several accounts signed in".

## 5. Protocol changes (v1, additive)

### 5.1 TXT keys

| Key | Meaning | Who sends it |
|---|---|---|
| `acct=1` | **Redefined, compatible with Apple's meaning:** the TV accepts any number of `pushServer` messages in one session, including the same server more than once, and keeps each sign-in as its own account. | Apple TV (already), Android TV and Roku once they handle it |
| `lim=<n>` | New, optional. Most sign-ins the TV can keep from this session. Absent means no limit worth stating. | Roku (from its registry budget); others omit it |

A phone treats a TV without `acct=1` exactly as today. No TV advertises `acct=1` until it handles
it, and old phones ignore the key.

### 5.2 Message fields

- `pushServer.accountName` — new, optional, **display-only**: the username the phone will approve
  with, so the TV can show "Signing in alex on Home". The TV never uses it for matching. It is an
  unverified LAN claim, and the account that signs in is read from the poll's `tokens.user`.
  Old TVs ignore it.
- No account ID is sent. Receivers already match accounts by the poll's `tokens.user.id`.
- New failure code `limit_reached`: the TV refused a push because it can't keep more sign-ins.
  Older phones read it as `auth_failed` through the existing unknown-code rule.

### 5.3 Receiver rules (all three TVs)

1. Accept `pushServer` after a sign-in in the same session. Roku drops its
   "one sign-in per session" rule when it advertises `acct=1`.
2. Run one device login at a time, as now. A new push while one is in flight replaces it
   (existing behavior on all three).
3. Show each request's code while it waits for approval, for every push, not only the first
   (needed for §6.3 comparisons).
4. Save each sign-in through the platform's multi-account install, matching by server user ID.
   - Android TV: when the poll has no `user` (older server), read `/me` with the new token
     before committing, so it doesn't create a duplicate account.
   - Android TV: stop clearing the matched account's remembered `profileId` when the same account
     is refreshed. That matches Apple and Roku.
5. Track every account committed in the session, in order. At the end, follow §4.4.
6. Roku: if accepting a push would push out an account saved earlier in this session, refuse it
   with `limit_reached` instead.
7. Session binding (§6.2): make the session secret when the session starts, and send it with
   every start and poll against a server that supports it.

## 6. Security: one comparison, many approvals

Decision D1 (a): add session binding on the server, and fall back to per-account comparison on
servers without it. This closes the 2026-06-14 "confirm-once multi-server" accepted risk on
updated servers.

### 6.1 The gap

After the person compares the first code, later approvals are automatic. An active on-path
attacker can swap a later `deviceStarted` for its own request, and the phone approves it with the
user's account. Multi-account turns one automatic approval per extra server into one per extra
account, and Roku's channel is plain TCP.

The current check, that the TV-relayed match code equals the server's lookup, does not close this.
An attacker relays its own request's code pair, which is consistent.

### 6.2 Fix: session binding (server change)

1. At the start of a session the TV makes a random 32-byte secret `s`. It never leaves the TV
   except over HTTPS to the server.
2. Every `device/start` in that session to an HTTPS server sends
   `binding = base64url(SHA-256(s))`. A TV signing in at a plain-HTTP address sends neither
   `binding` nor `binding_secret`, even when the capability says `session_binding`: there the same
   on-path attacker binding defends against could read the secret. Those requests take the
   per-account comparison (§6.3).
3. Lookup returns `binding`. Poll must send `binding_secret = s`. The server refuses to mint tokens
   when `SHA-256(binding_secret)` doesn't equal the stored `binding`.
4. The phone takes the trusted `binding` from the lookup of a request the person compared. For
   every later request, on any server, the phone checks that request's lookup:
   - **Same `binding`:** approve without a comparison.
   - **No `binding`** (server or TV without binding): ask the person to compare that request's
     code (§6.3). An attacker gains nothing by leaving it out, because the person would see a
     code the real TV doesn't show.
   - **A different `binding`:** refuse. The target fails and the session continues.

An attacker who swaps in its own request either uses another binding, which the phone refuses, or
copies the real one from a public lookup. The copy can't be polled without `s`, so no tokens are
minted to the attacker. The worst outcome is one target failing, and the phone reports it.

If the first target's lookup has no binding, the phone has no trusted binding yet, so later
targets need their own comparison (§6.3) until a compared target supplies one.

Server work in `silo-server` (`internal/auth/device_login.go`, `internal/apiv2/device_login.go`):
- Nullable `binding_hash` column on `device_login_requests`.
- `binding` on the v2 start request and on the lookup response.
- `binding_secret` on the poll request, checked in the poll transaction.
- Advertise support as `session_binding: true` in the existing
  `GET /api/v2/auth/device/capability`. TVs send `binding` and `binding_secret` only to servers
  that advertise it and that they reach over HTTPS. Phones don't need the flag: they act on what
  lookup returns.
- v1 routes stay frozen.

### 6.3 Fallback without binding

When a target's lookup has no binding to check, the phone asks the person to compare that
target's code too, because each request has its own code. Until servers update, that is one
comparison per account sent to an older server. The first target is always compared, so the
one-account case doesn't change. Multi-account sending ships with this fallback and does not wait
for servers to adopt binding.

### 6.4 Roku notes

- SHA-256 is available through `roEVPDigest`.
- `GetRandomUUID` isn't promised to be cryptographically random (silo-roku `docs/silocontrol.md`).
  Build `s` from several UUIDs plus `roEVPCipher` output, and have the Roku owners confirm the
  source. **Unconfirmed:** whether any Roku API gives cryptographic randomness.

## 7. Work per repo

### silo-server
1. Tests: two accounts approve two separate requests started from one device ID and IP; both
   sessions live; signing one out leaves the other.
2. Session binding (§6.2), with tests for a missing secret, a wrong secret, a copied binding,
   a request started without binding, and the capability flag.

### silo-apple
1. iOS chooser at account level, current account preselected (§4.1); stop sending every account
   automatically.
2. Sign-in TV card with account choice (§4.2).
3. Roku: multi-select once it advertises `acct=1`; honor `lim`; read `limit_reached`.
4. Send `pushServer.accountName`; tvOS shows it with each request's code.
5. Binding: tvOS sends `binding` and `binding_secret`; iOS checks lookup `binding`; per-target
   comparison fallback (§6.3).
6. tvOS end of session per §4.4: one account opens its picker; several open
   `TVChangeAccountView` with the first account current and focused. Covers first run and Add
   server while signed in (`TVServerSetupView.openPairedAccount`).

### silo-android
1. Phone chooser at account level, current account preselected, sending with the selected
   account's scope (`AuthScopeSnapshot` with `accountId`).
2. Continue after a failed target; send `done`; per-target summary.
3. Sign-in TV card with account choice.
4. Read `acct`, `lim` and `limit_reached`; send `accountName`.
5. Android TV: advertise `acct=1`; end of session per §4.4 (Change Account when several);
   `/me` before committing a poll without `user`; keep `profileId` on refresh.
6. Binding on both sides; fix the KDoc that promises a "with this account" fallback that never
   happens, or implement it.

### silo-roku
1. Accept several pushes per session; advertise `acct=1` and `lim`.
2. End of session per §4.4: Change Account (`AccountsScreen`) when several signed in.
3. Advertise `login` for Add an account on the active signed-in server, or drop the
   "Have Silo on your phone?" hint there.
4. Binding on start and poll.
5. Update `docs/companion-pairing.md` for #32 and this change.

## 8. Rollout

Each step ships on its own.

| Step | Ships | Effect alone |
|---|---|---|
| 1 | Server tests and session binding | None visible; clients don't send binding yet |
| 2 | iOS chooser at account level and sign-in card choice | iPhone stops sending every account automatically; Apple TV gets only what was ticked |
| 3 | Android TV and Roku accept several pushes, end-of-session per §4.4, then advertise `acct=1` | iPhone can send them several accounts |
| 4 | Android phone chooser, sign-in card choice, continue-on-failure | Android phones send several accounts |
| 5 | Binding in all clients | One comparison covers every target on updated servers |

iOS (step 2) must ship before any TV starts advertising `acct=1` (step 3). Today's iPhone sends
every signed-in account to an `acct=1` TV with no choice, so the reverse order would spread that.

Until step 5, every target after the first needs its own comparison (§6.3). Steps 2–4 can ship
the per-target comparison first and drop it per server as binding lands.

## 9. Decisions (settled 2026-11-04)

- **D1. Confirm-once with many approvals:** (a) add session binding on the server; compare each
  account's code on servers without it (§6).
- **D2. Default selection:** (a) only the phone's current account on its active server (§4.1).
- **D3. TV on its sign-in screen:** (a) the phone chooses one account (§4.2).
- **D4. Which account the TV opens:** (b) when several signed in, the TV opens Change Account so
  the person picks; one account opens its picker as today (§4.4).

## 10. Testing

- **Protocol:** golden frames shared by Apple and Android with `accountName`, `limit_reached`,
  `acct` and `lim`. Old decoders must ignore the new fields.
- **Senders:** account-level selection with the current account preselected, sending order,
  continue after failure, the sign-in card's account choice, old TVs without `acct=1`, a Roku
  `lim`, binding mismatch refused, a missing binding from a binding server refused, and the
  per-target comparison fallback (including a first server without binding).
- **Receivers:** several pushes per session, the same server twice with different accounts, the
  same account twice (refresh, no duplicate), the code shown for every push, end of session with
  one account (picker) and with several (Change Account, first account current and focused, Back
  opens its picker), a poll without `user` (Android TV), and Roku `limit_reached` without trimming
  accounts saved this session.
- **Server:** the binding cases in §7.
- **Cross-platform matrix on real LANs:** {iPhone, Android phone} × {Apple TV, Android TV, Roku},
  each with 2 servers × 2 accounts, plus one old build on each side.
- **Apple TV focus:** Change Account opened after pairing starts focus on the first account's
  card in the pane, using the native focus graph (`docs/tvos-focus.md`).
- **Rendered evidence** for the phone chooser, the sign-in card, each TV's progress screen and
  each TV's Change Account after pairing, on iPhone, iPad, Android phone, Apple TV, Android TV
  and Roku.

## 11. Code references

- Apple iOS sender: `iosApp/iosApp/Pairing/Companion/CompanionPairingCoordinator.swift`
  (`pushSelected`, `targets(for:)`, `sendsEveryAccount`, confirm-once in `handleDeviceStarted`),
  `CompanionPairingCard.swift` (`serverPicker`, `accountNames(on:)`).
- Apple protocol: `iosApp/iosApp/Pairing/PairingProtocol.swift` (`TXTKey.acceptsAccounts`).
- Apple tvOS receiver: `Pairing/Receiver/ReceiverPairingCoordinator.swift` (`persistServer`),
  `Pairing/Receiver/TVPairingAdvertiser.swift` (TXT `acct=1`),
  `Screens/Auth/TVServerSetupView.swift` (`openPairedAccount`),
  `tvOS/Screens/Auth/TVChangeAccountView.swift`.
- Android phone: `android-shared/.../pairing/CompanionPairingCoordinator.kt` (one account per
  server through `AuthScopeSnapshot.profileless`; abort on failure at `:339-357`),
  `androidApp/.../pairing/CompanionPairingBottomOverlay.kt`.
- Android TV: `android-shared/.../pairing/PairingReceiver.kt`, `PairingAuthPort.kt`
  (`persistApprovedSession`), `AndroidServerRegistry.commitAccountReplacement`,
  `TvServerSetupScreen.kt:133-144`.
- Roku: `source/control/pairing.bs`, `components/AppSceneCompanion.bs:311-317`,
  `source/auth/companion.bs`, `source/auth/accounts.bs:143-178`,
  `source/storage/registry.bs:62-71`, `docs/companion-pairing.md`.
- Server: `internal/auth/device_login.go`, `internal/apiv2/device_login.go`,
  `migrations/sql/073_device_login_requests.sql`, `internal/ratelimit/config.go:110-115`.

Not confirmed: runtime behavior on devices (all findings are from code reading), whether an
account with `password_change_required` can approve, whether Roku has a cryptographic random
source, whether the v2 start endpoint rejects unknown fields (the capability flag avoids relying
on it), and per-device stream limits across accounts on the server.

## 12. Implementation notes (2026-11-04)

Decisions taken while implementing, recorded so the spec matches the code:

- **Bad `binding` on start** returns `422 validation_failed` at `body.binding`, following
  `docs/architecture/api-contract.md`, not the 400 in the first contract draft.
- **v1 poll of a bound request** is refused with `403 device_binding_mismatch`, so a copied binding
  can't be collected through v1. Only v2 can create a bound request.
- **Rolling deploys:** a server node on an older release doesn't check the secret. Documented in
  silo-server `docs/architecture/device-login.md`.
- **Binding goes only to HTTPS servers.** TVs send `binding` and `binding_secret` only when the
  address they sign in at is `https`, whatever the capability says. A plain-HTTP server's
  requests are compared one by one (§6.3).
- **"Doesn't match" on any comparison ends the session.** Apple cancels the session, and the TV
  withdraws its request; Android also denies the request on the server before cancelling. After
  the first target, the message says "The codes didn't match, so setup stopped. Accounts already
  signed in stay on the TV."
- **On Apple, an approval with an unknown outcome ends the session.** When the approve call fails without a
  definite answer (transport error, timeout, 5xx), the server may have approved it, and the TV's
  late result could be credited to the next target. Definite refusals (401, 403, 404, 409, 410,
  `provider_unavailable`, update required) and the other failures (TV refusal, different binding)
  fail only their target. The phone also ignores a `serverResult` whose `serverURL` isn't the
  current target's.
- **A TV on its sign-in screen sends no binding.** It reuses the code it already showed, and the
  phone always compares that single account.
- **Remembered profile on refresh:** Android keeps it only when the profile has no PIN, because
  the server ties a PIN proof to the old login session.
- **Roku:** `lim=8` (12 accounts, 8 servers, about 2.5 KB budget per sign-in). `acct=1`/`lim` are
  advertised on the server screen only. Add an account on the active signed-in server drops the
  "Have Silo on your phone?" hint instead of advertising `login`. The binding secret is SHA-256 of
  eight `GetRandomUUID()` values plus uptime, clock and install ID; whether that source is
  cryptographic is unconfirmed.
- **Apple TV bug fixed during validation:** `ContentView`'s active-server handler opened profile
  selection mid-session after the first sign-in, ending multi-account setup. `AppRouter`
  `isReceivingCompanionSetup` now suppresses it while a phone is connected. The same handler is on
  `main`, so sending several servers to an Apple TV probably fails there today (untested).
