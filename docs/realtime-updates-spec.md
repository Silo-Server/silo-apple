# Real-Time Media Updates for Apple Clients (tvOS + iOS)

**Status:** Draft for review
**Author:** (Apple client)
**Date:** 2026-06-13
**Repos touched:** `silo-apple` (this repo). **No server changes required.**
**Related:** `silo-android` (parity follow-up), `silo-server` events hub.

---

## 1. Problem & Goals

Today the Apple Home screen (tvOS + iOS) is **pull-only**. "Continue Watching" and per-item
progress only refresh when the user re-enters the screen, dismisses an item, or pulls to refresh.
If progress changes on another device — or the server adds/updates an item — an idle Home screen
never finds out.

### Goals

1. **Live updates while idle on Home.** Sitting on the tvOS Home, progress changes made on any
   device (phone, web, another TV) update the Continue Watching row within ~1s, with no navigation.
2. **Fresh on return-to-app.** Returning the app to the foreground refreshes Home.
3. **Fresh on return-to-page.** Already mostly handled (`.onAppear`); keep it and don't regress.
4. **Cross-device progress sync feels instant**, not eventually-consistent.
5. **Shared implementation** usable by both tvOS and iOS.

### Non-Goals

- Real-time updates for arbitrary deep screens (detail view live-refresh is a nice-to-have, not required).
- Changing how playback progress is *reported* (stays HTTP `POST .../progress`).
- Any server-side change. The transport and channels already exist and are live.
- Offline/replay/durable event log on the client. The socket is a "refetch signal" accelerator;
  REST remains the source of truth.

---

## 2. Background / Current State

### 2.1 Apple clients today (pull-only)

- Networking is REST via `HTTPClient` (actor) → `SiloAPI` (actor). No shared HTTP cache.
- `Screens/Home/HomeView.swift` refresh triggers:
  - `.task` — first load (`HomeViewModel.loadSections()` + recommendations). (~L79–83)
  - `.onAppear` — refetch on return to page, skipped on first appear. (~L84–91)
  - `.onReceive(NotificationCenter … .homeSectionsShouldRefresh)` — after the user dismisses /
    marks-watched an item. (~L92–94)
  - iOS only: `.refreshable` pull-to-refresh. (~L161–163)
- `HomeViewModel` is `@Observable @MainActor`; paints cached sections instantly from
  `ResponseCache` (stale-while-revalidate) then refetches.
- **Gaps:** (a) no live updates while idle; (b) no `scenePhase`-based refresh for Home (only the
  player handles `scenePhase`).

### 2.2 Existing WebSocket precedent in this repo

`Screens/Player/PlaybackRealtimeClient.swift` is a production `URLSessionWebSocketTask` **actor** we
will mirror. Key properties to reuse as a pattern:

- Auth via header: `request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")`
  (`makeRequest`, ~L236–272). **Apple clients can set handshake headers** (browsers cannot).
- Reconnect backoff `[0.5s, 1s, 2s, 5s]` (~L17–22) + **circuit breaker** after 8 consecutive
  failures (~L27, surfaces a non-fatal "realtime unavailable" flag).
- `http→ws` / `https→wss` scheme conversion (~L252–259).
- **Generation-based binding** to cancel stale connection loops on rebind/unbind.
- `SiloAPI.shared.currentServerUrl()` and `.currentAccessToken()` provide base URL + token.

### 2.3 Server events hub (already live — verify in `silo-server`)

- **Endpoint:** `GET /api/v1/events/ws` — `internal/api/handlers/events_ws.go`.
- **Auth:** standard JWT claims middleware. The web passes `?token=`; **header `Authorization:
  Bearer` also works** (same middleware the playback control WS uses).
- **Handshake:**
  1. Server → `hello` `{type, schema_version:1, connection_id, available_channels, required_action:"subscribe"}`.
  2. Client → `subscribe` `{type:"subscribe", request_id, channels:[…]}` **within 5 seconds** or the
     server closes the socket.
  3. Server → `subscribed` `{type, request_id, channels:[accepted], rejected:[{channel,code,message}]}`.
  4. Server → one `snapshot` per accepted channel `{type:"snapshot", channel, timestamp, data}`.
  5. Server → live `event` frames `{type:"event", channel, event, event_id, timestamp, data}`.
- Server sends WebSocket **ping** control frames; `URLSessionWebSocketTask` auto-replies with pong.
- **Channels** (`internal/events/types.go`): `catalog`, `history_import`, `user_state`,
  `notifications` for all roles; `jobs`, `sessions`, `tasks`, `scans` admin-only
  (`allowedChannelsForRole`).
- **Snapshot for `catalog` and `user_state` is `null`** (`events_ws.go` snapshotForChannel) — these
  are pure *"something changed, refetch"* signals, not payload syncs. This fits our existing
  `loadSections()` model exactly.
- **Filtering** (`allowsEventForClaims`): `user_state` events are scoped to the **account**
  (`env.UserID == claims.UserID`), **not** the profile. A multi-profile account receives events for
  *all* its profiles, each carrying a `profile_id` in the payload. The client must filter by the
  active profile.
- **`ws-ticket`** (`POST /api/v1/events/ws-ticket`) mints a single-use, profile-bound ticket passed
  as `?ticket=`. **Only required for the `notifications` channel.** `catalog`/`user_state` work on a
  plain authenticated (unbound) connection — **no ticket needed for this feature.**

#### Event payloads we consume

- **`user_state.changed`** (channel `user_state`):
  `{ profile_id, content_id, change, played, is_favorite, in_watchlist }`
  where `change ∈ { "progress", "favorite", "watchlist", "history", "watched", "home_dismissal" }`.
- **`catalog`** channel events: `catalog.item.changed`, `library.item_added`, `metadata.updated`
  (treat as "library surface changed → refetch Home").

### 2.4 Android parity (per workspace guidance)

`silo-android` already connects to `/api/v1/events/ws` but subscribes **only** to `notifications`
(`NotificationsRealtimeClient.kt`); its Home/Continue-Watching is pull-based too. It has the proven
transport + lifecycle infra (Ktor WS, **1s→30s capped backoff**, `ProcessLifecycleOwner` foreground
binding, profile-switch reconnect, ws-ticket minting). **Neither mobile client does live
continue-watching yet** — Apple leads here; Android should follow for parity (separate task).

---

## 3. Design Overview

Two independent, stackable layers:

- **Layer 1 — Foreground refresh (pull).** Add `scenePhase` `.active` → `loadSections()` to Home.
  Closes the "return to app" gap. ~15 lines, no socket. Ship first, independently valuable.
- **Layer 2 — Events WebSocket (push).** A new `EventsRealtimeClient` actor connects to
  `/api/v1/events/ws`, subscribes to `["user_state", "catalog"]`, and routes events to a
  **debounced** Home refresh (+ optional in-place progress patch and detail-view refresh). Delivers
  the headline "instant while idle" + cross-device sync.

```
                    ┌─────────────────────────── Layer 2 (push) ──────────────────────────┐
 server events hub  │   EventsRealtimeClient (actor)        RealtimeCoordinator (@MainActor)│
   /events/ws  ─────┼─►  connect / handshake / subscribe ─►  route + debounce + profile     │
   user_state ──────┤    reconnect+backoff+breaker          filter                          │
   catalog    ──────┘    lifecycle (scenePhase, profile)         │                          │
                                                                  ▼                          │
 HomeView ◄───────────────── HomeViewModel.loadSections() / applyProgress(contentId,pos) ◄───┘
   ▲  ▲
   │  └── Layer 1: .onChange(scenePhase == .active) → loadSections()   (pull)
   └───── existing: .task / .onAppear / .homeSectionsShouldRefresh / .refreshable
```

---

## 4. Detailed Design

### 4.1 Layer 1 — Foreground refresh for Home

In `HomeView.swift`, add `@Environment(\.scenePhase)` and refresh when becoming active (guarded so it
doesn't double-fire with the existing first-load `.task`, and coalesced through the same debounce as
Layer 2 to avoid a socket-reconnect + scene-active double refetch):

```swift
@Environment(\.scenePhase) private var scenePhase

// in the view body modifiers:
.onChange(of: scenePhase) { _, phase in
    guard phase == .active, !viewModel.sections.isEmpty else { return }
    Task { await viewModel.refreshFromRealtime(reason: .foreground) }
}
```

`refreshFromRealtime(reason:)` is a thin debounced wrapper around `loadSections()` (see §4.6) so all
"freshness" triggers funnel through one coalescing point. This is the only Layer-1 change; it works
with or without Layer 2.

> tvOS note: `scenePhase` transitions fire on tvOS when the app is backgrounded/foregrounded
> (e.g., user presses Home/TV button and returns). Validate on-device; if a destination proves
> unreliable, fall back to `UIApplication.didBecomeActiveNotification`.

### 4.2 Layer 2 — `EventsRealtimeClient` actor

New file: `iosApp/iosApp/Networking/Realtime/EventsRealtimeClient.swift`. Modeled directly on
`PlaybackRealtimeClient`. Responsibilities: own the socket, handshake, subscribe, reconnect, and emit
**decoded, already-filtered** events to a handler. It does **not** know about Home/view models.

```swift
actor EventsRealtimeClient {
    typealias EventHandler = @MainActor (RealtimeEvent) async -> Void

    enum RealtimeEvent {
        case userState(UserStateChange)   // decoded user_state.changed payload
        case catalogChanged               // any catalog.* event → "refetch surfaces"
        case connected                    // (re)subscribed successfully → caller should reconcile via REST
    }

    init(session: URLSession = .shared, onEvent: @escaping EventHandler)

    func start()                          // begin connection loop (idempotent)
    func stop()                           // tear down, cancel loop
    func reconnect()                      // force a fresh connection (e.g., profile switch / token refresh)
}
```

#### Connection loop (mirrors `PlaybackRealtimeClient.runConnectionLoop`)

1. Build request: base URL from `SiloAPI.shared.currentServerUrl()`, path
   `/api/v1/events/ws`, `http→ws` / `https→wss`, `Authorization: Bearer <currentAccessToken()>`.
   No `?token=` and no `?ticket=` (we don't subscribe to `notifications`).
2. `webSocketTask(with:)`, `resume()`.
3. **Read `hello`.** Validate `schema_version == 1` (log + continue if mismatch — forward-compatible).
4. **Send `subscribe`** `{type:"subscribe", request_id:<ulid/uuid>, channels:["user_state","catalog"]}`.
5. **Read `subscribed`.** Log any `rejected` channels (shouldn't happen for these two at non-admin
   role). Emit `.connected` so the coordinator does one REST reconcile (covers events missed while
   disconnected — snapshots for these channels are null, so REST is the catch-up path).
6. **Receive loop:** decode frames; on `event` with `channel=="user_state"` decode payload →
   `.userState`; on `channel=="catalog"` → `.catalogChanged`. Ignore `snapshot` (null for these).
7. On read error / cancellation → close, backoff, reconnect (unless stopped).

#### Reconnect / resilience

- Backoff: reuse `[0.5s, 1s, 2s, 5s]` capped, **or** adopt Android's `1s → 30s` cap. **Recommend
  capping higher than the player client (e.g. up to 30s)** — Home realtime is a background niceness,
  not interactive, so a slower steady-state retry is fine and lighter on the server.
- **Circuit breaker:** after N consecutive failures (reuse 8), pause and surface a non-fatal
  `isRealtimeDegraded` flag. Home keeps working via pull (`.onAppear`/foreground). Resume attempts on
  the next lifecycle event (foreground / profile switch).
- **Subscribe-deadline awareness:** the server closes the socket if no `subscribe` arrives within 5s.
  We send it immediately after `hello`, so this only bites on a stalled connection — which the read
  loop already turns into a reconnect.

#### Auth / token refresh

- Each (re)connect pulls a fresh `currentAccessToken()`. If the token expired, the handshake fails →
  backoff → reconnect picks up the refreshed token (the `HTTPClient` single-flight refresh runs on
  normal REST traffic, e.g. the `.connected` reconcile or `loadSections`).
- Optional hardening: if the socket closes with a 401-ish status quickly after connect, proactively
  trigger a token refresh before the next attempt. **Open question (§8).**

### 4.3 Lifecycle ownership — `RealtimeCoordinator`

New `@MainActor @Observable` `RealtimeCoordinator` owns one `EventsRealtimeClient` for the app and
binds its lifecycle:

- Created at app root (`iOSApp` / tvOS app entry) and injected via `@Environment` or a shared
  singleton (match existing app-wide service conventions, e.g. how `AudioPlaybackStore` / session
  services are exposed).
- **scenePhase:** `.active` → `client.start()`; `.background` → `client.stop()`. (tvOS + iOS.)
  Connecting only while foregrounded avoids holding a socket open on a suspended app and matches
  Android's `ProcessLifecycleOwner` start/stop.
- **Profile switch:** on profile change, `client.reconnect()` (so account/profile scoping is correct)
  and clear any pending debounce. Hook into the same place that already clears `ResponseCache`
  per-profile prefixes.
- **Sign-out:** `client.stop()`.

### 4.4 Event routing & Home integration

The coordinator's `onEvent` handler routes to `HomeViewModel` (held weakly / via a registration so a
non-visible Home doesn't force work):

- `.connected` → `await home?.refreshFromRealtime(reason: .reconnect)` (one full REST reconcile).
- `.catalogChanged` → `await home?.refreshFromRealtime(reason: .catalog)` (debounced full refetch).
- `.userState(change)`:
  1. **Profile filter:** drop if `change.profileId != activeProfileId`.
  2. If `change.change == "progress"` **and** the item is already present in a Continue-Watching
     section → **optimistic in-place patch** (`home?.applyProgress(contentId:positionSeconds:)`),
     then schedule a debounced full refetch to reconcile ordering/section membership.
  3. Else (`watched`, `home_dismissal`, `watchlist`, `favorite`, `history`, or a `progress` for an
     item not currently shown) → debounced full `refreshFromRealtime(reason: .userState)`.

> Note: `user_state.changed` does **not** carry the new position (`{profile_id, content_id, change,
> played, is_favorite, in_watchlist}`). So the "in-place patch" can update *presence/played* state
> instantly but **not** the exact resume position — the debounced refetch supplies the position. If
> we want a true instant position bar without a refetch we'd need a server payload change (see §8 /
> §10). **Recommended v1: skip the position-patch micro-optimization; rely on the debounced refetch**
> (≤1–2s) which is already "instant enough" and far simpler. The `applyProgress` hook is documented
> here as a future option, not v1 scope.

### 4.5 HomeViewModel additions

```swift
extension HomeViewModel {
    enum RefreshReason { case foreground, reconnect, catalog, userState }
    func refreshFromRealtime(reason: RefreshReason) async   // debounced → loadSections()
    // Optional future: func applyProgress(contentId: String, positionSeconds: Double)
}
```

`refreshFromRealtime` coalesces bursts (see §4.6) and then calls the existing `loadSections()`. No
change to `loadSections()` itself or to `ResponseCache`.

### 4.6 Debounce / coalescing (important)

A foreign stream emits `user_state.changed(progress)` roughly **every 10s** per active session, and
catalog scans can burst many events. Without coalescing we'd hammer `/home/sections`.

- Trailing debounce window **~2s** (configurable). Multiple triggers within the window collapse to a
  **single** `loadSections()`.
- Layer-1 foreground refresh and Layer-2 `.connected` reconcile go through the **same** debounce, so
  "reconnect on foreground" + "scene became active" = one refetch, not two.
- Optional guard: skip a refetch if one completed < ~1s ago (min-interval), to ride out tight bursts.

### 4.7 Models (new, `Codable`)

In `Networking/Realtime/RealtimeModels.swift` (snake_case auto-converted by `HTTPClient`'s decoder
config — but the realtime client decodes frames itself, so set `keyDecodingStrategy =
.convertFromSnakeCase` on its own `JSONDecoder`):

```swift
struct EventsHello: Decodable { let type: String; let schemaVersion: Int; let connectionId: String
    let availableChannels: [String]; let requiredAction: String }
struct EventsSubscribe: Encodable { let type = "subscribe"; let requestId: String; let channels: [String] }
struct EventsSubscribed: Decodable { let type: String; let requestId: String?; let channels: [String]
    let rejected: [Rejected]?; struct Rejected: Decodable { let channel, code, message: String } }
struct EventsFrame: Decodable {   // generic envelope; decode `data` lazily per channel
    let type: String; let channel: String?; let event: String?; let eventId: String?
    let timestamp: String?; let data: JSONValue? }   // JSONValue = lightweight any-decoder
struct UserStateChange: Decodable {
    let profileId: String; let contentId: String; let change: String
    let played: Bool?; let isFavorite: Bool?; let inWatchlist: Bool? }
```

(Reuse an existing `AnyCodable`/`JSONValue` helper if one exists in the repo; otherwise add a minimal one.)

---

## 5. Edge Cases & Risks

| # | Case | Handling |
|---|------|----------|
| 1 | Multi-profile account: events for other profiles | Filter on `profile_id == activeProfileId` in the coordinator. |
| 2 | Event storm (foreign stream every 10s; scan bursts) | 2s trailing debounce + optional 1s min-interval (§4.6). |
| 3 | Token expiry while connected | Reconnect pulls fresh token; REST reconcile triggers `HTTPClient` refresh. (§4.2) |
| 4 | Server closes if no subscribe in 5s | We subscribe immediately after `hello`. |
| 5 | tvOS app suspended / idle for hours | Socket stopped on `.background`; `.active` reconnects + reconciles via REST. |
| 6 | Snapshot is `null` for catalog/user_state | Expected; we ignore snapshot and use `.connected` → REST reconcile as catch-up. |
| 7 | Duplicate/out-of-order events | We always reconcile via REST refetch (idempotent); in-place patch (if used) is best-effort. |
| 8 | Realtime endpoint unavailable / repeated failures | Circuit breaker → `isRealtimeDegraded`; pull-based refresh still fully works. No user-facing error. |
| 9 | Detail screen open during a relevant event | v1: optional — refresh the open detail's user-state. Can defer. |
| 10 | Battery / data (iOS) | Socket only while foregrounded; idle traffic is ping/pong + occasional small frames. Acceptable. |
| 11 | Two refetch paths racing (scenePhase + reconnect) | Shared debounce collapses them. |
| 12 | `loadSections()` overlap | `refreshFromRealtime` should drop/await an in-flight load (single-flight), reusing the existing prefetch single-flight pattern if applicable. |

---

## 6. Testing Plan

Focused tests only (per repo guidelines — no broad UI tests):

- **Frame decoding (unit):** `hello`, `subscribed` (with `rejected`), `event` for `user_state.changed`
  (all `change` values), `catalog.*`, malformed/unknown frames → ignored. Pure functions, no socket.
- **Routing/filter (unit):** profile filter drops foreign-profile events; each `change` maps to the
  right refresh path; debounce collapses N triggers → 1 `loadSections()` (inject a fake clock/home).
- **Reconnect/backoff (unit):** generation cancellation on `stop()`/`reconnect()`; circuit breaker
  flips `isRealtimeDegraded` after N failures and recovers on next `start()`.
- **Manual / on-device (tvOS + iOS):**
  1. Idle on Home (TV A). Play+scrub an item on web/phone (B). TV A's Continue Watching updates ≤2s.
  2. Background the app, change progress elsewhere, foreground → Home reflects it.
  3. Mark watched / dismiss on B → item leaves Continue Watching on A.
  4. Kill network mid-session → degrades quietly → restores on reconnect.
  5. Switch profiles → socket reconnects; only the active profile's changes apply.

---

## 7. Phasing / Rollout

- **Phase 1 (Layer 1):** `scenePhase` foreground refresh + `refreshFromRealtime` debounce scaffold.
  Ship for tvOS + iOS. Independently valuable, trivially revertible.
- **Phase 2 (Layer 2 core):** `EventsRealtimeClient` + `RealtimeCoordinator` + `user_state`/`catalog`
  subscribe → debounced Home refetch. tvOS + iOS. **This delivers the headline feature.**
- **Phase 3 (polish, optional):** detail-view live user-state refresh; in-place progress patch
  (only if we add position to the server payload, §8/§10); `isRealtimeDegraded` UI affordance (likely
  none needed).
- **Feature flag:** gate Layer 2 behind a simple local flag/remote-config so it can be disabled
  without a rebuild if it misbehaves on a device class.
- **Android parity:** separate `silo-android` task to subscribe its existing events client to
  `user_state`/`catalog` and refresh Home. Tracked, not in this repo's scope.

---

## 8. Open Questions

1. **Position in payload.** `user_state.changed` lacks the new `position_seconds`. Accept
   debounced-refetch-for-position (recommended v1), or propose a server payload addition to enable a
   true zero-refetch instant progress bar? (Coordinate with server + Android if pursued.)
2. **Backoff cap.** Reuse player's 5s cap, or adopt Android's 30s cap for this lower-priority stream?
   (Recommend 30s.)
3. **Detail-view live refresh** in v1 or deferred to Phase 3? (Recommend defer.)
4. **Proactive token refresh** on fast 401 close, or rely on reconnect + REST-driven refresh?
   (Recommend rely on existing refresh; revisit if logs show churn.)
5. **Coordinator exposure** — `@Environment` injection vs. shared singleton. Match whatever the app
   already does for cross-cutting services.

---

## 9. Why this is low-risk

- **Zero server changes** — channels are live and already consumed by the web client.
- REST stays the source of truth; the socket only *triggers refetches*. Worst case (socket down) =
  today's behavior.
- We mirror an **existing, proven in-repo WebSocket actor** (`PlaybackRealtimeClient`) and an
  **existing proven client pattern** in Android, rather than inventing transport/reconnect logic.
- Gated behind a flag; each phase is independently revertible.

---

## 10. File-by-File Change List

**New:**
- `iosApp/iosApp/Networking/Realtime/EventsRealtimeClient.swift` — the socket actor (handshake,
  subscribe, reconnect, decode→emit).
- `iosApp/iosApp/Networking/Realtime/RealtimeModels.swift` — `Codable` frame + payload types.
- `iosApp/iosApp/Networking/Realtime/RealtimeCoordinator.swift` — `@MainActor @Observable` lifecycle
  owner + event router + profile filter + debounce.
- `iosApp/Tests/Realtime/EventsRealtimeDecodingTests.swift`,
  `.../RealtimeRoutingTests.swift` — unit tests.

**Modified:**
- `iosApp/iosApp/Screens/Home/HomeView.swift` — add `@Environment(\.scenePhase)` + `.onChange`
  foreground refresh (Layer 1); no structural change.
- `iosApp/iosApp/Screens/Home/HomeViewModel.swift` — add `refreshFromRealtime(reason:)` (debounced
  wrapper over `loadSections()`); optional `applyProgress(...)` (Phase 3).
- App entry (`iosApp/iosApp/iOSApp.swift` and the tvOS app entry) — create/own `RealtimeCoordinator`,
  bind `scenePhase`, register Home, reconnect on profile switch / stop on sign-out.
- `iosApp/project.yml` — only if new folders need explicit inclusion; regenerate with
  `xcodegen generate`.
- (Reference only, no change) `SiloAPI` — already exposes `currentServerUrl()`,
  `currentAccessToken()`, `homeSections()`.

**Server (`silo-server`): none.** (Possible *future* opt-in: add `position_seconds` to
`user_state.changed` for instant position — only if §8.1 is pursued.)

---

## 11. Cross-Team Coordination

- **Server:** no changes. (Confirm the header-auth path for `/events/ws` is acceptable; the playback
  control WS already authenticates via `Authorization` header through the same middleware.)
- **Android:** create a parity task — subscribe the existing events client to `user_state`/`catalog`
  and refresh Home. Keeps Apple/Android aligned on shared client behavior.
- **Web:** reference implementation (`web/src/components/RealtimeEventsProvider.tsx`) — same channels,
  same "refetch on user_state.changed" model; mirror its behavior, including refetch-on-focus.
