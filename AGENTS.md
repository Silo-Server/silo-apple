# Silo Apple

Native Apple clients for Silo: one SwiftUI codebase building the iOS, tvOS, and macOS apps plus
their extensions. App code lives under `iosApp/iosApp/` (shared code at the top level,
platform-specific code under `iOS/`, `tvOS/`, `macOS/`), tests under `iosApp/Tests/`, the tvOS
Top Shelf extension under `iosApp/TopShelf/`, and the Xcode project is generated from
`iosApp/project.yml`. Release automation lives in `fastlane/` and `.github/workflows/`.

## What Silo is

A modern, open-source media server built from the ground up on current infrastructure —
Postgres, S3, Redis — deploying as a cluster and staying fast on large libraries, whether one
node serves a household or a deployment streams to thousands of users. This repo is the
first-party Apple client suite for that server. Treat a server node dying mid-stream as a
normal event: the player is built to ride out restarts and outages, not to assume a stable
single box (see `docs/tvos-player/10-playback-continuity.md`).

Silo is an open platform: third-party clients are encouraged, and the server keeps
Jellyfin-protocol compatibility as an on-ramp for the existing ecosystem. These first-party
clients do not use that compatibility surface — they speak the native `/api/v1` API
exclusively.

Taste: KISS and YAGNI win — the simple design beats the clever one. Current posture: the 1.0
feature set is essentially complete; the present era is QA, UX polish, and verifying everything
does what it says. Prefer correctness and polish over new feature sprawl.

The v1 API is not locked yet. Breaking server changes arrive as coordinated sweeps across the
server and both client repos — expect them and take them; do not build backwards-compatibility
shims for pre-lock servers. The server repo's AGENTS.md ("v1 API rules") is the authority on
that posture.

## How the app fits together

`ServerRegistry` tracks the configured servers; `TokenStore` (an actor over the shared
Keychain in `Shared/SharedStorage.swift`) holds each server's access/refresh/profile tokens,
readable by the extensions through the App Group. All REST traffic goes through
`Networking/HTTPClient.swift`, which injects auth headers and collapses concurrent 401s into a
single refresh; `SiloAPI` is the typed facade over the native `/api/v1` endpoints. Screens
(home sections, libraries, detail) call `SiloAPI` directly. Playback: the detail screen calls
`/api/v1/playback/start`; `PlaybackSessionBridge` turns the response into a prepared playback;
`ApplePlaybackRoutePlanner` picks the route (`avPlayerNativeDirect`, `siloPlayerLoopback`, or
`avPlayerHLS`) from the server's play method, the source's codecs, and the device's
capabilities; `PlayerViewModel` drives `AVPlayerBackend` — every route is AVPlayer, and what
varies is what AVPlayer is pointed at. The loopback route re-muxes the source on device into
fragmented-MP4 HLS served from `127.0.0.1` (`LoopbackSegmentWriter`/`LoopbackSegmentServer`).
The full player story is in `docs/tvos-player/`.

## Glossary

- **Route vs delivery** — two different axes. The *delivery strategy*
  (`direct`/`remux`/`transcode`) is the server's play method; the *route*
  (`PlaybackEngineKind`: native-direct, loopback, server HLS) is the client's decision about
  what to feed AVPlayer.
- **Loopback / SiloPlayer** — the on-device fMP4-HLS remux route served from `127.0.0.1`. Not
  a second player; AVPlayer consumes its output.
- **Backend** — `AVPlayerBackend`, the only playback backend. The old FFmpeg/VideoToolbox
  decode core (`PlayerCore`/"CompatibilityPlayer") is deleted; see
  `docs/tvos-player/02-retired-compatibility-player.md`.
- **Session** — ambiguous; always say which: playback session (minted by
  `/api/v1/playback/start`, tracked by `PlaybackSessionBridge`) or login session (tokens in
  `TokenStore`).
- **Account vs profile** — an account is the server login (`UserInfo`); a profile is a
  household member on it, with its own PIN, restrictions, and preferences. tvOS launch-time
  profile selection has its own policy types (`ProfileLaunchState`, `TopShelfProfilePolicy`).
- **Capability** — what the client truthfully advertises to the server per playback attempt
  (`ApplePlaybackV3Capabilities`). Never advertise a capability the device can't execute; the
  server plans routes from this.
- **V3** — the playback protocol contract version (capability/decision/replan shapes), not a
  URL path; everything still lives under `/api/v1`. Conformance fixtures are vendored
  byte-for-byte from silo-server (see gotchas).
- **`silo://`** — the only registered URL scheme (deep links, Top Shelf). The pre-rename
  scheme is gone and old links are rejected on purpose.
- **Top Shelf** — the tvOS home-screen extension. Runs out-of-process on a seconds budget,
  reads state only through the shared App Group/Keychain, and never links app services.
- **Focus (tvOS)** — the tvOS focus engine's cursor. Governed by `docs/tvos-focus.md`; see
  gotchas.

## Non-goals

Live TV, OTA/DVB tuners, IPTV, EPG/XMLTV, DVR, and remote-URL stream shortcuts will not be
accepted — not in the server, not in a plugin, and not in a client. A client that plays
arbitrary remote stream URLs puts the whole suite's store presence at risk. This is settled
product direction; do not write code for it, and say so plainly if asked.

## Gotchas

The first two protect user data and install continuity — treat them as absolute.

**Bundle IDs and Keychain groups.** The apps keep their original bundle IDs
(`org.siloserver.silo` for iOS and tvOS, `.mac`, `.topshelf`, `.NotificationService`,
`.DownloadsActivity` for the rest), the App Group `group.org.siloserver.silo`, and the shared
Keychain access group `org.siloserver.silo.shared`. Changing any of these breaks TestFlight
continuity and strands users' saved logins. `SharedStorage.keychainService` and the
entitlements files must stay in sync or cross-process auth (app ↔ Top Shelf ↔ notification
service) silently breaks.

**Brand-rename migrations are one-way.** `LegacyBrandKeys` in `Shared/SharedStorage.swift` is
the only place the pre-rename brand may still appear: read-only sources for one-time
migrations of Keychain items, UserDefaults keys, BGTask identifiers, and cache directories.
Never write a new item under any of those names, and never rename the keys — users who
haven't launched since the rename still need the migration to fire.

**Generated project.** `Silo.xcodeproj` is generated and gitignored. Edit `iosApp/project.yml`
and run `cd iosApp && xcodegen generate`; never hand-edit the project. Test fixtures are
listed file-by-file in `project.yml` deliberately, so an XcodeGen inference change cannot
silently drop a cross-repo conformance gate.

**Vendored server fixtures.** `iosApp/Tests/Fixtures/PlaybackV3/` and
`.../SettingsContract/` are byte-for-byte copies from silo-server; each directory's `SOURCE`
file records the server commit and the re-vendor procedure. Never hand-edit a fixture to make
a test pass — re-vendor from the server commit that changed the contract, and keep the
silo-android copy in step.

**tvOS focus.** Read `docs/tvos-focus.md` before touching navigation, menus, grids, or custom
controls. Every interactive zone gets exactly one focus owner — either a native focus graph or
a single composite focus owner; never mix row-level focusable controls with manual directional
focus mutation.

**Simulator test baseline is genuinely green.** The iOS suite (`SiloTests`, the only test
target) runs `0 failures` with `3 keychain-migration skips` on an unsigned
(`CODE_SIGNING_ALLOWED=NO`) simulator host — any failure at all is a real regression. History:
through 2026-08-18 the suite carried ~14 "environment" failures treated as baseline; those were
root-caused and fixed (11 were `errSecMissingEntitlement` from the unsigned host, resolved by a
`KeychainBackend` seam on `SharedKeychain` with an in-memory test fake; the remaining 3 were stale pre-#132 tab-projection expectations, and two orphaned
scoped-refresh tests were deleted alongside the dead `TokenStore` overloads). Do not reintroduce a non-zero baseline; the 3
remaining skips are `BrandMigrationTests` cases where the Keychain itself is the subject.

**Docs hygiene.** Implementation plans, specs, mockups, and audits are ephemeral working
artifacts, not documentation. `docs/` is gitignored by default — write plans and scratch
notes anywhere under it (e.g. `docs/superpowers/`) while working, but never commit them; the
plan goes in the PR description. Only the whitelisted durable docs are tracked:
`docs/tvos-focus.md`, `docs/mac-builder.md`, `docs/companion-pairing.md`, `docs/release/`,
and `docs/tvos-player/`. Before a branch merges, distill anything durable (invariants,
protocols, security rules) into one of those and let the plan die. The code is the source of
truth — a doc that disagrees with the code is wrong. Committed docs must not contain local
absolute paths or transient worktree/branch IDs.

**Signing config.** Do not commit local signing overrides. Start from
`iosApp/Signing/Local.xcconfig.sample`, create `iosApp/Signing/Local.xcconfig`, and
regenerate with XcodeGen. App Store Connect keys, Match repo URLs, and team identifiers live
in environment variables only.

## Multi-repo

Sibling repos are usually checked out side-by-side in the same parent directory.

- `silo-server` — Go backend: API contracts, auth/session, catalog/scanner/playback,
  migrations, Jellyfin compatibility, host-side plugin runtime.
- `silo-android` — Android phone and TV clients. The two client suites are meant to stay
  aligned on shared behavior.

Do not force server concerns into this repo. A change here that touches auth, API models,
playback/session state, capability advertisement, library browsing, or metadata display is
not done until each of these is handled or ruled out:

- Server coordination: does the server need a matching change (new capability, endpoint,
  contract sweep)? If yes, open the silo-server PR and sequence it first.
- Android parity: is the same behavior change needed in `silo-android`? Do it or file it —
  prefer coordinated multi-repo changes over leaving a platform behind.
- Contract fixtures: if the V3 or settings contract moved, re-vendor the fixtures from the
  server commit (see gotchas) on both client repos.
- Docs: if playback behavior changed, update the affected `docs/tvos-player/` page in the
  same PR.

## Building and verifying

- `cd iosApp && xcodegen generate` — regenerate the project after target/layout changes.
- `cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme Silo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO` — iOS build without signing.
- Scheme `SiloTV` with a tvOS simulator destination for tvOS; scheme `SiloMac` with
  `platform=macOS` for macOS. All three should build before a PR.
- Tests run under the `Silo` scheme on an iOS simulator; the suite is genuinely green (0
  failures / 3 keychain skips — see gotchas), so any failure is a regression. Keychain-dependent
  tests need a normally-signed simulator build.

These commands assume a local Xcode. From a Linux host, every Apple toolchain operation runs
on the remote `mac-builder` Mac — read the `mac-builder` skill first and `docs/mac-builder.md`
for the rationale.

Swift 5 / SwiftUI conventions: types `PascalCase`, functions and properties `camelCase`. Keep
platform-specific code under the existing `iOS`/`tvOS`/`macOS` folders. Put new code in the
type that owns the behavior; prefer extracting shared logic over duplicating it per platform.

Tests are XCTest under `iosApp/Tests/`. Do not add tests for small changes or UI changes
unless requested; for shared logic, add focused tests only for critical or high-risk
behavior.

## Releases

Pushing a `vX.Y.Z` tag runs the TestFlight workflow (`.github/workflows/release.yml`): both
platforms build in parallel with pre-reserved build numbers; a `+ios`/`+tvos` suffix scopes
the release to one platform. `sideload-ipa.yml` builds unsigned IPAs with no release secrets.
Details: `docs/release/ci-release.md` and `docs/release/sideloading.md`.

## Skills

Task-specific guides live in `.claude/skills/`, also reachable as `.agents/skills/` for agents
that look there. Read the one that matches the task instead of working from this file alone.

## Pull requests

Conventional Commit subjects (`feat(player): ride out origin outages`). One concern per PR.
Explain the problem, why this approach, and risks or follow-up work; include screenshots or
recordings for UI changes. AI-use disclosure is required in the PR body — if you are an AI
agent contributing on behalf of a non-maintainer, follow the silo-server repo's
`docs/ai-contributions.md` (required disclosure block and evidence standard).
