# iOS → tvOS Cast Remote Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the iOS→tvOS Silo cast remote feel native and stay reliable: smooth scrubbing, instant controls, a persistent now-playing entry point, one-step "cast this item", volume + next-episode controls, and a transport layer that survives drops and reconnects.

**Architecture:** The cast feature is a peer-to-peer LAN link — a shared wire protocol (`SiloCastProtocol`) over a TLS-PSK `SiloCastSession` (actor wrapping `NWConnection`), an `@Observable` `SiloCastController` on the phone and an `@Observable` `TVCastReceiver` singleton on the TV. This plan (a) hardens the transport (ordered sends, heartbeat liveness, takeover, re-advertise on server change), (b) adds phone-side reconnect + a local playback clock for smooth/optimistic UI, (c) adds UX surfaces (mini-bar, cast-from-detail, idle state, volume row, next-episode), and (d) extends the player backends with volume/mute. No server or Android changes — the cast channel is Apple-only and LAN-local.

**Tech Stack:** Swift 6 / SwiftUI, Network.framework (`NWConnection`/`NWListener`/`NWBrowser`), `@Observable`, Swift Concurrency (actors, `AsyncStream`), `AVAudioEngine`/`AVPlayer` for audio gain. XCTest for shared-logic tests.

---

## Decisions Locked (from review Q&A)

- **Cast-channel security (#12): defer + document.** Keep the static TLS-PSK for this plan; the `serverId` gate is the only authorization. Phase G writes the threat model and a per-pair-auth follow-up into the docs. No pairing-key exchange in this plan.
- **Volume (#5): playback attenuation + mute, honestly scoped.** tvOS exposes **no** system/TV volume API (`MPVolumeView` is absent from the tvOS SDK; `AVAudioSession.outputVolume` is read-only — confirmed via Apple docs/forums). What *is* controllable is per-player gain: `AVPlayer.volume` (decoded-PCM routes only) and the `PlayerCore` `AVAudioEngine` main-mixer `outputVolume` (always, since it decodes to PCM). So the remote gets a **playback-volume slider + mute** that attenuates 0–100% of the current TV volume (cannot boost above it) and is a no-op on bitstream/passthrough/AirPlay audio on the AVPlayer route. The UI labels it "Volume", the cast state echoes the *applied* value, and Phase G documents the route caveat.
- **Next-episode (#5): included.** The player already exposes `nextUpEpisode` and `playNextEpisodeNow()` — wire a remote transport to them.

## Testing Approach (honors CLAUDE.md)

CLAUDE.md: *"Do not add tests for small changes or UI changes unless requested. For shared logic changes, add focused tests only for critical or high-risk behavior."* So:

- **Unit-tested (shared logic):** new `SiloCastMessage`/`SiloCastControlCommand`/`SiloCastPlaybackState` codec round-trips; the `RemotePlaybackClock` interpolation + optimistic-override math; volume clamping.
- **Build + simulator-verified (UI / networking):** everything else. Build commands per platform are below; two-simulator cast verification follows the `companion-pairing-sim-test` memory pattern (two booted sims share the host network so Bonjour + TLS-PSK works sim-to-sim).

**Build commands (run after each phase):**
```bash
cd iosApp && xcodegen generate   # only after adding/removing files
cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme Silo   -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO
cd iosApp && xcodebuild build -project Silo.xcodeproj -scheme SiloTV -destination 'platform=tvOS Simulator,name=Apple TV 4K (3rd generation)' CODE_SIGNING_ALLOWED=NO
```
**Test command:**
```bash
cd iosApp && xcodebuild test -project Silo.xcodeproj -scheme Silo   -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:SiloTests/SiloCastTests CODE_SIGNING_ALLOWED=NO
```
(If the test target is named differently, mirror the existing target under `iosApp/Tests/`; create `SiloCastTests.swift` there.)

---

## File Structure

**Shared protocol/transport (`iosApp/iosApp/Cast/`):**
- `SiloCastProtocol.swift` *(modify)* — add `.ping`/`.pong` messages; add `.setVolume`/`.setMuted`/`.playNext` control names + a `volume: Double?` command field; add `volume`/`isMuted`/`hasNextEpisode`/`nextEpisodeTitle` to `SiloCastPlaybackState`.
- `SiloCastSession.swift` *(modify)* — ordered outbound queue (`AsyncStream` drain) so messages never reorder; `enqueue(_:)` fire-and-forget API.

**iOS (`iosApp/iosApp/Cast/iOS/`):**
- `RemotePlaybackClock.swift` *(create)* — `@Observable` projection: latest authoritative state + monotonic interpolation anchor + optimistic play/pause/seek overrides. Pure, testable `displayTime(asOf:)`.
- `SiloCastController.swift` *(modify)* — own a `RemotePlaybackClock`; heartbeat send + miss-counter teardown; auto-reconnect with `isReconnecting`; optimistic command echoes; `playNext`, `setVolume`, `setMuted` helpers.
- `SiloCastRemoteControlView.swift` *(modify)* — drive scrubber/transport from the clock via `TimelineView`; idle/connected state when `contentId == nil`; volume row; next-episode button; restructure secondary controls into a scrollable row; a11y values.
- `SiloCastMiniBar.swift` *(create)* — persistent now-playing bar shown across tabs; taps reopen the remote.
- `SiloCastTargetPickerView.swift` *(modify)* — unchanged logic, but now reached with a non-nil `request` from detail (cast-and-play).

**iOS integration:**
- `Screens/Home/HomeView.swift` *(modify)* — unchanged cast button (already present).
- `Screens/Detail/ItemDetailView.swift` *(modify)* — add a Cast button that casts-this-item (launch if session, else open picker with the request).
- `ContentView.swift` *(modify)* — mount `SiloCastMiniBar` in `MainTabView` above the tab content.

**tvOS (`iosApp/iosApp/Cast/tvOS/`):**
- `TVCastReceiver.swift` *(modify)* — ordered sends; heartbeat reply + liveness teardown; **takeover** on new connection; re-advertise on active-server change; gate the state timer on a connected controller; handle `.setVolume`/`.setMuted`/`.playNext`.

**tvOS integration:**
- `tvOS/Navigation/TVMainTabView.swift` *(modify)* — `.onChange(of: ServerRegistry.shared.activeServerId)` re-advertise.

**Player backends (`iosApp/iosApp/Screens/Player/`):**
- `PlayerViewModel.swift` *(modify)* — `applySiloCastControl` cases for volume/mute/playNext; `makeSiloCastPlaybackState` emits volume/mute/next-episode and uses the *live* content id.
- `CoreMedia/PlayerCore.swift` *(modify)* — `setVolume/setMuted/currentVolume/currentMuted` on the `AVAudioEngine` main mixer; re-apply after `reloadAudioOutput()`.
- `AVPlayerRoute/AVPlayerBackend.swift` *(modify)* — user volume/mute stored + applied via `avPlayer.volume` (never `isMuted`, reserved for the initial-display gate).
- `PlayerViewModel.swift` `ActivePlayer` enum *(modify)* — `setVolume/setMuted/volume()/isMuted()` forwarding.

**Tests (`iosApp/Tests/`):**
- `SiloCastTests.swift` *(create)* — codec round-trips, clock interpolation/override, volume clamping.

**Docs (`docs/`):**
- `docs/tvos-player/cast-remote.md` *(create)* — protocol overview, volume route caveats, deferred security follow-up + threat model.

---

# Phase A — Transport hardening (shared)

## Task A1: Ordered outbound queue in `SiloCastSession`

Today every caller wraps sends in `Task { try? await session.send(...) }`. Multiple tasks race to enter the actor, so a stale state snapshot can overwrite a fresh one (playhead jumps backward). Fix: a single FIFO drain inside the session.

**Files:**
- Modify: `iosApp/iosApp/Cast/SiloCastSession.swift`

- [ ] **Step 1: Add an outbound stream created in `init`.**

Add stored properties and build the stream in both initializers. Replace the property block near the top:

```swift
actor SiloCastSession {
    enum SessionError: Error {
        case closed
    }

    private let connection: NWConnection
    private var frameBuffer = PairingFrameBuffer()
    private var continuation: AsyncThrowingStream<SiloCastMessage, Error>.Continuation?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var isOpen = false

    // Ordered outbound queue: enqueue() is nonisolated + FIFO; a single
    // drain task sends one frame at a time so messages never reorder.
    private let outbound: AsyncStream<SiloCastMessage>
    private let outboundContinuation: AsyncStream<SiloCastMessage>.Continuation
    private var drainTask: Task<Void, Never>?

    init(connection: NWConnection) {
        self.connection = connection
        (outbound, outboundContinuation) = AsyncStream.makeStream()
    }

    init(endpoint: NWEndpoint) {
        connection = NWConnection(to: endpoint, using: Self.tlsParameters())
        (outbound, outboundContinuation) = AsyncStream.makeStream()
    }
```

- [ ] **Step 2: Start the drain loop when the connection is ready.**

In `open()`, inside the `.ready` case, also start the drain loop:

```swift
                case .ready:
                    Task { await self.receiveLoop() }
                    Task { await self.startDrainLoop() }
```

- [ ] **Step 3: Add `enqueue` + the drain loop, and route `send` through the raw writer.**

Add these methods. Keep the existing awaitable `send` for the initial hello (it must be sent before any `enqueue`), but have it share the raw writer:

```swift
    /// Fire-and-forget, ordered. Safe to call from any context; FIFO is
    /// preserved by call order because all call sites are @MainActor.
    nonisolated func enqueue(_ message: SiloCastMessage) {
        outboundContinuation.yield(message)
    }

    private func startDrainLoop() async {
        for await message in outbound {
            guard isOpen else { continue }
            do {
                try await writeRaw(message)
            } catch {
                teardown(error)
                return
            }
        }
    }

    func send(_ message: SiloCastMessage) async throws {
        guard isOpen else { throw SessionError.closed }
        try await writeRaw(message)
    }

    private func writeRaw(_ message: SiloCastMessage) async throws {
        let payload = try encoder.encode(message)
        let framed = try PairingFrame.encode(payload)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: framed, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }
```

- [ ] **Step 4: Tear down the drain loop in `teardown`.**

In `teardown`, after `connection.cancel()` add:

```swift
        drainTask?.cancel()
        drainTask = nil
        outboundContinuation.finish()
```

(Note: because `startDrainLoop` is launched fire-and-forget in Step 2, capture it: change that line to `drainTask = Task { await self.startDrainLoop() }` — but `drainTask` is actor-isolated and the `.ready` closure is nonisolated, so set it inside an `await`-hop helper. Simplest: add a `private func beginLoops()` that sets `drainTask` and calls `receiveLoop`, and call `Task { await self.beginLoops() }` from `.ready`.)

Replace the `.ready` case with:
```swift
                case .ready:
                    Task { await self.beginLoops() }
```
and add:
```swift
    private func beginLoops() {
        receiveLoop()
        drainTask = Task { [weak self] in await self?.startDrainLoop() }
    }
```

- [ ] **Step 5: Build both platforms.**

Run the iOS + tvOS build commands. Expected: PASS (no behavior change yet at call sites; they still use `send`).

- [ ] **Step 6: Commit.**

```bash
git add iosApp/iosApp/Cast/SiloCastSession.swift
git commit -m "cast: ordered outbound queue in SiloCastSession to prevent message reorder"
```

## Task A2: Heartbeat messages in the protocol

**Files:**
- Modify: `iosApp/iosApp/Cast/SiloCastProtocol.swift`
- Test: `iosApp/Tests/SiloCastTests.swift`

- [ ] **Step 1: Write the failing codec test.**

Create `iosApp/Tests/SiloCastTests.swift`:

```swift
import XCTest
@testable import Silo

final class SiloCastTests: XCTestCase {
    private func roundTrip(_ message: SiloCastMessage) throws -> SiloCastMessage {
        let data = try JSONEncoder().encode(message)
        return try JSONDecoder().decode(SiloCastMessage.self, from: data)
    }

    func testPingPongRoundTrip() throws {
        XCTAssertEqual(try roundTrip(.ping), .ping)
        XCTAssertEqual(try roundTrip(.pong), .pong)
    }
}
```

- [ ] **Step 2: Run it — expect FAIL.**

Run the test command. Expected: FAIL ("type 'SiloCastMessage' has no member 'ping'").

- [ ] **Step 3: Add `.ping`/`.pong` to the enum and codec.**

In `SiloCastMessage`, add cases:
```swift
    case error(SiloCastErrorMessage)
    case ping
    case pong
    case close
```
In the `Kind` enum add `case ping`, `case pong`. In `encode(to:)` add:
```swift
        case .ping:
            try c.encode(Kind.ping, forKey: .type)
        case .pong:
            try c.encode(Kind.pong, forKey: .type)
```
In `init(from:)` add:
```swift
        case .ping:
            self = .ping
        case .pong:
            self = .pong
```

- [ ] **Step 4: Run the test — expect PASS.** Run the test command. Expected: PASS.

- [ ] **Step 5: Commit.**
```bash
git add iosApp/iosApp/Cast/SiloCastProtocol.swift iosApp/Tests/SiloCastTests.swift
git commit -m "cast: add ping/pong heartbeat messages to protocol"
```

## Task A3: Add volume/mute/next control + state fields to the protocol

**Files:**
- Modify: `iosApp/iosApp/Cast/SiloCastProtocol.swift`
- Test: `iosApp/Tests/SiloCastTests.swift`

- [ ] **Step 1: Write failing tests for the new fields.**

Append to `SiloCastTests`:
```swift
    func testVolumeAndMuteAndNextCommandsRoundTrip() throws {
        let setVol = SiloCastControlCommand.setVolume(0.4)
        XCTAssertEqual(try roundTrip(.control(setVol)), .control(setVol))
        let mute = SiloCastControlCommand.setMuted(true)
        XCTAssertEqual(try roundTrip(.control(mute)), .control(mute))
        XCTAssertEqual(try roundTrip(.control(.playNext)), .control(.playNext))
    }

    func testPlaybackStateCarriesVolumeAndNext() throws {
        let state = SiloCastPlaybackState.fixture(volume: 0.5, isMuted: true,
                                                  hasNextEpisode: true, nextEpisodeTitle: "Ep 5")
        let decoded = try roundTrip(.state(state))
        guard case let .state(s) = decoded else { return XCTFail() }
        XCTAssertEqual(s.volume, 0.5)
        XCTAssertTrue(s.isMuted)
        XCTAssertTrue(s.hasNextEpisode)
        XCTAssertEqual(s.nextEpisodeTitle, "Ep 5")
    }
```

Add a `fixture` helper at the bottom of the test file (fill all `SiloCastPlaybackState` fields with defaults; the two relevant ones are parameters):
```swift
private extension SiloCastPlaybackState {
    static func fixture(volume: Double, isMuted: Bool, hasNextEpisode: Bool,
                        nextEpisodeTitle: String?) -> SiloCastPlaybackState {
        SiloCastPlaybackState(
            contentId: "c", sessionId: nil, title: "T", subtitle: nil,
            isPlaying: true, isLoading: false, isBuffering: false,
            currentTime: 0, duration: 100,
            audioTracks: [], subtitleTracks: [],
            selectedAudioTrackId: nil, selectedSubtitleTrackId: nil,
            qualityOptions: [], activeQualityId: "auto", isQualitySwitching: false,
            playbackSpeed: 1.0, videoGravity: "fit", hdrEnabled: false,
            supportsVideoGravity: false, supportsHDRToggle: false,
            volume: volume, isMuted: isMuted,
            hasNextEpisode: hasNextEpisode, nextEpisodeTitle: nextEpisodeTitle,
            error: nil
        )
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (missing members). Run the test command.

- [ ] **Step 3: Extend `SiloCastControlCommand`.**

Add to `Name`:
```swift
        case setVolume = "set_volume"
        case setMuted = "set_muted"
        case playNext = "play_next"
```
Add a `volume: Double?` stored field and init param (place after `speed`):
```swift
    let volume: Double?
```
```swift
    init(
        name: Name,
        seconds: Double? = nil,
        trackId: Int64? = nil,
        speed: Double? = nil,
        volume: Double? = nil,
        value: String? = nil,
        enabled: Bool? = nil
    ) {
        self.name = name
        self.seconds = seconds
        self.trackId = trackId
        self.speed = speed
        self.volume = volume
        self.value = value
        self.enabled = enabled
    }
```
Add factories:
```swift
    static let playNext = SiloCastControlCommand(name: .playNext)

    static func setVolume(_ volume: Double) -> SiloCastControlCommand {
        SiloCastControlCommand(name: .setVolume, volume: volume)
    }

    static func setMuted(_ muted: Bool) -> SiloCastControlCommand {
        SiloCastControlCommand(name: .setMuted, enabled: muted)
    }
```

- [ ] **Step 4: Extend `SiloCastPlaybackState`.**

Add fields right before `error`:
```swift
    let volume: Double
    let isMuted: Bool
    let hasNextEpisode: Bool
    let nextEpisodeTitle: String?
    let error: String?
```

> **Type-consistency note:** every `SiloCastPlaybackState(...)` constructor in the codebase must add these args. They are at: `TVCastReceiver.idleState()`, `TVCastReceiver.sendLoadingState(for:)`, `PlayerViewModel.makeSiloCastPlaybackState`, and the DEBUG `previewPlaying()` in `SiloCastRemoteControlView.swift`. Tasks A4, E2, E3, and D-phase tasks update each; for now add `volume: 1.0, isMuted: false, hasNextEpisode: false, nextEpisodeTitle: nil` to make the project compile.

- [ ] **Step 5: Add the defaults to all existing constructors so the build is green.**

Add `volume: 1.0, isMuted: false, hasNextEpisode: false, nextEpisodeTitle: nil` (before `error:`) to: `TVCastReceiver.idleState()` (`TVCastReceiver.swift:340`), `TVCastReceiver.sendLoadingState` (`:289`), `PlayerViewModel.makeSiloCastPlaybackState` (`PlayerViewModel.swift:~5350`), and `previewPlaying()` (`SiloCastRemoteControlView.swift:387`).

- [ ] **Step 6: Run tests + both builds — expect PASS.**

- [ ] **Step 7: Commit.**
```bash
git add iosApp/iosApp/Cast/SiloCastProtocol.swift iosApp/iosApp/Cast/tvOS/TVCastReceiver.swift iosApp/iosApp/Screens/Player/PlayerViewModel.swift iosApp/iosApp/Cast/iOS/SiloCastRemoteControlView.swift iosApp/Tests/SiloCastTests.swift
git commit -m "cast: add volume/mute/next-episode fields to cast protocol"
```

---

# Phase B — tvOS receiver reliability

## Task B1: Heartbeat reply + liveness teardown + takeover

**Files:**
- Modify: `iosApp/iosApp/Cast/tvOS/TVCastReceiver.swift`

- [ ] **Step 1: Add heartbeat + takeover state.**

Add properties near the top of `TVCastReceiver`:
```swift
    private var heartbeatTask: Task<Void, Never>?
    private var missedHeartbeats = 0
    private static let heartbeatInterval: Duration = .seconds(3)
    private static let maxMissedHeartbeats = 3   // ~9s of silence ⇒ dead
```

- [ ] **Step 2: Takeover — replace the reject-on-busy guard in `accept`.**

`accept(_:)` currently does `guard activeSession == nil else { connection.cancel(); return }`. Replace with takeover so a reconnecting (or new) controller wins instead of being locked out:
```swift
    private func accept(_ connection: NWConnection) async {
        if activeSession != nil {
            // Newest controller wins (matches AirPlay/Cast). Close the old.
            closeActiveSession(sendClose: true)
        }

        let session = SiloCastSession(connection: connection)
        // ... rest unchanged (UUID, assign activeSession, refreshStandbyState,
        // open stream, startReadLoop, startStateUpdates if player present) ...
```
After `startReadLoop(...)` and before `do { try await session.send(makeHello()) ... }`, start the heartbeat watchdog:
```swift
        startHeartbeat(connectionId: connectionId)
```

- [ ] **Step 3: Reset the miss-counter on every inbound message, and reply to ping.**

In `handle(_:connectionId:)`, at the top after the `guard activeConnectionId == connectionId`:
```swift
        missedHeartbeats = 0
```
Add cases:
```swift
        case .ping:
            session(for: connectionId)?.enqueue(.pong)
        case .pong:
            break
        case .state, .error:
            break
```
Add the helper:
```swift
    private func session(for connectionId: UUID) -> SiloCastSession? {
        activeConnectionId == connectionId ? activeSession : nil
    }
```

- [ ] **Step 4: Add the watchdog and tear it down everywhere the session closes.**

```swift
    private func startHeartbeat(connectionId: UUID) {
        heartbeatTask?.cancel()
        missedHeartbeats = 0
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard let self, self.activeConnectionId == connectionId else { return }
                self.missedHeartbeats += 1
                if self.missedHeartbeats > Self.maxMissedHeartbeats {
                    Self.logger.info("cast: controller heartbeat timed out; closing session")
                    self.closeActiveSession(sendClose: false)
                    return
                }
                self.activeSession?.enqueue(.ping)
            }
        }
    }
```
In `closeActiveSession` and `handleConnectionClosed`, add:
```swift
        heartbeatTask?.cancel()
        heartbeatTask = nil
        missedHeartbeats = 0
```

- [ ] **Step 5: Build tvOS — expect PASS. Commit.**
```bash
git add iosApp/iosApp/Cast/tvOS/TVCastReceiver.swift
git commit -m "cast(tvOS): heartbeat liveness, ping reply, and controller takeover"
```

## Task B2: Route receiver sends through the ordered queue + gate the state timer

**Files:**
- Modify: `iosApp/iosApp/Cast/tvOS/TVCastReceiver.swift`

- [ ] **Step 1: Replace racy `Task { try? await session.send(...) }` with `enqueue`.**

In `sendState`, `sendLoadingState`, `sendError`, and `accept` (the hello+state pair) and `handle .ping`, replace the `Task { try? await session.send(X) }` wrappers with `session.enqueue(X)`. Keep `makeHello()` as the awaitable `send` in `accept` (must precede queued state), then `sendState()` which now enqueues. Example for `sendState`:
```swift
    private func sendState() {
        guard let session = activeSession else { return }
        let state: SiloCastPlaybackState
        if let playerViewModel {
            state = playerViewModel.makeSiloCastPlaybackState(contentId: playerContentId)
        } else {
            state = idleState()
        }
        session.enqueue(.state(state))
    }
```

- [ ] **Step 2: Only run the 1 Hz state timer while a controller is connected.**

`registerPlayer` calls `startStateUpdates()` unconditionally, so a 1 Hz task runs during *all* tvOS playback even with nobody casting. Gate it:
```swift
    private func startStateUpdates() {
        stateTask?.cancel()
        guard activeSession != nil else { return }
        stateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.sendState()
            }
        }
    }
```
And in `accept`, after assigning the session, if a player is already registered, (re)start updates — it already calls `startStateUpdates()` when `playerViewModel != nil`, which now passes the guard. Good.

- [ ] **Step 2b: Increase the state cadence while playing for a smoother phone scrubber.**

Change the sleep to a shorter interval so the phone's interpolation re-anchors more often (the phone interpolates between snapshots in Phase D, but a tighter cadence reduces drift). Use `.milliseconds(500)`.

- [ ] **Step 3: Build tvOS — expect PASS. Commit.**
```bash
git add iosApp/iosApp/Cast/tvOS/TVCastReceiver.swift
git commit -m "cast(tvOS): ordered sends; gate state timer on connected controller"
```

## Task B3: Re-advertise on active-server change

**Files:**
- Modify: `iosApp/iosApp/tvOS/Navigation/TVMainTabView.swift`

- [ ] **Step 1: Re-call `start` when the active server changes.**

`TVCastReceiver.start` early-returns if `advertisedServerId == server.id` and is only invoked once from `.task`. After a tvOS in-app server switch the Bonjour TXT still advertises the old `serverId`. Add an `onChange` next to the existing `.task { castReceiver.start(router: router) ... }`:
```swift
        .onChange(of: ServerRegistry.shared.activeServerId) {
            castReceiver.start(router: router)
        }
```
(`start` already calls `stop()` before re-advertising when the id differs, so this is safe.)

- [ ] **Step 2: Build tvOS — expect PASS. Commit.**
```bash
git add iosApp/iosApp/tvOS/Navigation/TVMainTabView.swift
git commit -m "cast(tvOS): re-advertise cast service when active server changes"
```

---

# Phase C — Phone reliability & reconnect

## Task C1: Heartbeat consumption + auto-reconnect in the controller

**Files:**
- Modify: `iosApp/iosApp/Cast/iOS/SiloCastController.swift`

- [ ] **Step 1: Add reconnect/heartbeat state.**

Add to `SiloCastController`:
```swift
    private(set) var isReconnecting = false
    private var heartbeatTask: Task<Void, Never>?
    private var missedHeartbeats = 0
    private var reconnectTask: Task<Void, Never>?
    private var lastTarget: SiloCastTarget?
    private static let heartbeatInterval: Duration = .seconds(3)
    private static let maxMissedHeartbeats = 3
    private static let maxReconnectAttempts = 5
```

- [ ] **Step 2: Remember the target and start the heartbeat on connect.**

In `connect(to:)`, after `activeTarget = target`, add `lastTarget = target`. After `startReadLoop(...)` add `startHeartbeat(connectionId: connectionId)`.

- [ ] **Step 3: Reply to ping, reset miss-counter, and add the watchdog.**

In `handle(_:connectionId:)` add at the top (after the connectionId guard): `missedHeartbeats = 0`. Add cases:
```swift
        case .ping:
            session?.enqueue(.pong)
        case .pong:
            break
```
Add:
```swift
    private func startHeartbeat(connectionId: UUID) {
        heartbeatTask?.cancel()
        missedHeartbeats = 0
        heartbeatTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.heartbeatInterval)
                guard let self, self.connectionId == connectionId else { return }
                self.missedHeartbeats += 1
                if self.missedHeartbeats > Self.maxMissedHeartbeats {
                    self.beginReconnect(reason: "Lost connection to the TV.")
                    return
                }
                self.session?.enqueue(.ping)
            }
        }
    }
```

- [ ] **Step 4: Replace hard-fail teardown with reconnect on transient drop.**

Add:
```swift
    private func beginReconnect(reason: String) {
        guard let target = lastTarget, isShowingRemoteControl || hasActiveSession else {
            clearSession()
            return
        }
        heartbeatTask?.cancel(); heartbeatTask = nil
        readTask?.cancel(); readTask = nil
        Task { if let session { await session.close() } }
        session = nil
        connectionId = nil
        isReconnecting = true
        errorMessage = nil
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for attempt in 1...Self.maxReconnectAttempts {
                try? await Task.sleep(for: .seconds(Double(attempt)))   // backoff 1,2,3,4,5s
                if Task.isCancelled { return }
                if await self.connect(to: target) {
                    self.isReconnecting = false
                    return
                }
            }
            self.isReconnecting = false
            self.errorMessage = reason
            self.clearSession()
        }
    }
```
In `startReadLoop`'s `catch` (the stream threw) and in the normal-close branch where the *TV* dropped without an explicit `.close`, call `beginReconnect(reason:)` instead of `fail(...)`/`handleConnectionClosed`. Concretely, change the `catch` block to:
```swift
            } catch {
                await MainActor.run {
                    guard self?.connectionId == connectionId else { return }
                    self?.beginReconnect(reason: error.localizedDescription)
                }
            }
```
Keep an explicit `.close` from the TV (intentional disconnect / takeover) routed to `clearSession()` as today — do **not** reconnect on an intentional close.

- [ ] **Step 5: Cancel reconnect/heartbeat in `clearSession`, `disconnect`, `closeCurrentSession`.**

Add to each:
```swift
        heartbeatTask?.cancel(); heartbeatTask = nil
        reconnectTask?.cancel(); reconnectTask = nil
        missedHeartbeats = 0
```
In `clearSession` also set `isReconnecting = false` and `lastTarget = nil`.

- [ ] **Step 6: Build iOS — expect PASS. Commit.**
```bash
git add iosApp/iosApp/Cast/iOS/SiloCastController.swift
git commit -m "cast(iOS): heartbeat watchdog + auto-reconnect with backoff"
```

---

# Phase D — Phone UX

## Task D1: `RemotePlaybackClock` (interpolation + optimistic overrides)

**Files:**
- Create: `iosApp/iosApp/Cast/iOS/RemotePlaybackClock.swift`
- Test: `iosApp/Tests/SiloCastTests.swift`

- [ ] **Step 1: Write failing tests for the clock.**

Append to `SiloCastTests`:
```swift
    func testClockInterpolatesWhilePlaying() {
        let clock = RemotePlaybackClock()
        let t0 = Date(timeIntervalSince1970: 1000)
        clock.ingest(.fixture(volume: 1, isMuted: false, hasNextEpisode: false, nextEpisodeTitle: nil),
                     asOf: t0)
        // fixture: currentTime 0, duration 100, isPlaying true, speed 1.0
        XCTAssertEqual(clock.displayTime(asOf: t0.addingTimeInterval(3)), 3, accuracy: 0.01)
    }

    func testClockClampsToDuration() {
        let clock = RemotePlaybackClock()
        let t0 = Date(timeIntervalSince1970: 1000)
        clock.ingest(.fixture(volume: 1, isMuted: false, hasNextEpisode: false, nextEpisodeTitle: nil),
                     asOf: t0)
        XCTAssertEqual(clock.displayTime(asOf: t0.addingTimeInterval(999)), 100, accuracy: 0.01)
    }

    func testOptimisticPlayingWinsUntilConfirmed() {
        let clock = RemotePlaybackClock()
        let t0 = Date(timeIntervalSince1970: 1000)
        var paused = SiloCastPlaybackState.fixture(volume: 1, isMuted: false,
                                                   hasNextEpisode: false, nextEpisodeTitle: nil)
        paused = paused.with(isPlaying: false)
        clock.ingest(paused, asOf: t0)
        clock.setOptimisticPlaying(true, asOf: t0)
        XCTAssertTrue(clock.isPlaying)                 // override active
        clock.ingest(paused.with(isPlaying: true), asOf: t0.addingTimeInterval(0.5))  // confirmed
        XCTAssertTrue(clock.isPlaying)
    }
```

Add a small `with(isPlaying:)` test helper to the fixture extension:
```swift
    func with(isPlaying: Bool) -> SiloCastPlaybackState {
        SiloCastPlaybackState(
            contentId: contentId, sessionId: sessionId, title: title, subtitle: subtitle,
            isPlaying: isPlaying, isLoading: isLoading, isBuffering: isBuffering,
            currentTime: currentTime, duration: duration,
            audioTracks: audioTracks, subtitleTracks: subtitleTracks,
            selectedAudioTrackId: selectedAudioTrackId, selectedSubtitleTrackId: selectedSubtitleTrackId,
            qualityOptions: qualityOptions, activeQualityId: activeQualityId,
            isQualitySwitching: isQualitySwitching, playbackSpeed: playbackSpeed,
            videoGravity: videoGravity, hdrEnabled: hdrEnabled,
            supportsVideoGravity: supportsVideoGravity, supportsHDRToggle: supportsHDRToggle,
            volume: volume, isMuted: isMuted,
            hasNextEpisode: hasNextEpisode, nextEpisodeTitle: nextEpisodeTitle, error: error)
    }
```

- [ ] **Step 2: Run — expect FAIL** (no `RemotePlaybackClock`).

- [ ] **Step 3: Implement the clock.**

```swift
#if os(iOS)
import Foundation
import Observation

/// Bridges the 0.5–1 Hz authoritative cast state into a smooth, responsive
/// view model: interpolates `currentTime` between snapshots and lets transport
/// taps reflect instantly (optimistic) until the TV confirms.
@MainActor
@Observable
final class RemotePlaybackClock {
    private(set) var state: SiloCastPlaybackState?
    private var anchorTime: Double = 0
    private var anchorDate = Date(timeIntervalSince1970: 0)

    // Optimistic play/pause: the override wins until a snapshot confirms it
    // or it ages out.
    private var optimisticPlaying: Bool?
    private var optimisticPlayingDate = Date(timeIntervalSince1970: 0)
    private static let optimisticWindow: TimeInterval = 4

    func ingest(_ next: SiloCastPlaybackState, asOf now: Date = Date()) {
        state = next
        anchorTime = next.currentTime
        anchorDate = now
        if let optimisticPlaying, next.isPlaying == optimisticPlaying {
            self.optimisticPlaying = nil    // confirmed
        }
    }

    var isPlaying: Bool {
        if let optimisticPlaying,
           Date().timeIntervalSince(optimisticPlayingDate) < Self.optimisticWindow {
            return optimisticPlaying
        }
        return state?.isPlaying ?? false
    }

    func setOptimisticPlaying(_ playing: Bool, asOf now: Date = Date()) {
        optimisticPlaying = playing
        optimisticPlayingDate = now
        // Re-anchor so interpolation reflects the new direction immediately.
        anchorTime = displayTime(asOf: now)
        anchorDate = now
    }

    /// Pin the playhead after a local seek so the slider doesn't snap back to a
    /// stale snapshot before the next state arrives.
    func setOptimisticTime(_ seconds: Double, asOf now: Date = Date()) {
        anchorTime = seconds
        anchorDate = now
    }

    func displayTime(asOf now: Date = Date()) -> Double {
        guard let state else { return 0 }
        guard isPlaying, state.duration > 0 else { return min(anchorTime, max(state.duration, anchorTime)) }
        let elapsed = now.timeIntervalSince(anchorDate) * max(state.playbackSpeed, 0.0001)
        return min(anchorTime + elapsed, state.duration)
    }
}
#endif
```

- [ ] **Step 4: Run tests — expect PASS. Build iOS — expect PASS.**

- [ ] **Step 5: Commit.**
```bash
git add iosApp/iosApp/Cast/iOS/RemotePlaybackClock.swift iosApp/Tests/SiloCastTests.swift
git commit -m "cast(iOS): add RemotePlaybackClock for smooth + optimistic remote UI"
```

## Task D2: Wire the clock into the controller; optimistic command echoes

**Files:**
- Modify: `iosApp/iosApp/Cast/iOS/SiloCastController.swift`

- [ ] **Step 1: Own a clock and feed it state.**

Add `let clock = RemotePlaybackClock()`. In `handle(_:connectionId:)` `.state` case, after `self.state = state` add `clock.ingest(state)`.

- [ ] **Step 2: Add optimistic helpers used by the view.**

```swift
    func togglePlayPauseOptimistic() {
        clock.setOptimisticPlaying(!clock.isPlaying)
        send(.playPause)
    }

    func seekOptimistic(to seconds: Double) {
        clock.setOptimisticTime(seconds)
        send(.seek(seconds: seconds))
    }

    func playNext() { send(.playNext) }
    func setVolume(_ v: Double) { send(.setVolume(min(max(v, 0), 1))) }
    func setMuted(_ m: Bool) { send(.setMuted(m)) }
```

- [ ] **Step 3: Build iOS — expect PASS. Commit.**
```bash
git add iosApp/iosApp/Cast/iOS/SiloCastController.swift
git commit -m "cast(iOS): controller drives RemotePlaybackClock + optimistic transport"
```

## Task D3: Rebuild the remote UI on the clock (smooth scrubber, idle state, volume, next)

**Files:**
- Modify: `iosApp/iosApp/Cast/iOS/SiloCastRemoteControlView.swift`

- [ ] **Step 1: Render the connecting/idle/now-playing branches off `contentId` + reconnect.**

Replace `content` in `SiloCastRemoteControlView` with:
```swift
    @ViewBuilder
    private var content: some View {
        if controller.isReconnecting {
            statusView(title: "Reconnecting…", showSpinner: true)
        } else if let state = controller.state, state.contentId == nil {
            idleConnectedView(state: state)
        } else if let state = controller.state {
            RemoteNowPlayingContent(
                state: state,
                clock: controller.clock,
                targetName: controller.activeTarget?.name,
                posterURL: artwork.posterURL ?? artwork.backdropURL,
                onCommand: { controller.send($0) },
                onTogglePlayPause: { controller.togglePlayPauseOptimistic() },
                onSeek: { controller.seekOptimistic(to: $0) },
                onPlayNext: { controller.playNext() },
                onSetVolume: { controller.setVolume($0) },
                onSetMuted: { controller.setMuted($0) }
            )
        } else {
            connectingView
        }
    }

    private func idleConnectedView(state: SiloCastPlaybackState) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "airplayvideo")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color.siloOnSurface)
            Text("Connected to \(controller.activeTarget?.name ?? "Silo TV")")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.siloOnSurface)
            Text("Pick something from your library to start playing.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color.siloSecondaryText)
        }
        .padding(32)
    }

    private func statusView(title: String, showSpinner: Bool) -> some View {
        VStack(spacing: 14) {
            if showSpinner { ProgressView() }
            Text(title).font(.headline).foregroundStyle(Color.siloSecondaryText)
        }
        .padding(32)
    }
```

- [ ] **Step 2: Change `RemoteNowPlayingContent` to take the clock + callbacks.**

Update its stored properties:
```swift
private struct RemoteNowPlayingContent: View {
    let state: SiloCastPlaybackState
    let clock: RemotePlaybackClock
    let targetName: String?
    let posterURL: String?
    let onCommand: (SiloCastControlCommand) -> Void
    let onTogglePlayPause: () -> Void
    let onSeek: (Double) -> Void
    let onPlayNext: () -> Void
    let onSetVolume: (Double) -> Void
    let onSetMuted: (Bool) -> Void

    @State private var scrubPreview: Double?
    private let speedOptions: [Double] = [0.75, 1.0, 1.25, 1.5, 2.0]
```

- [ ] **Step 3: Drive the scrubber + transport from the clock via `TimelineView`.**

Wrap the scrubber + time labels in a `TimelineView(.periodic(from: .now, by: 0.25))` so the playhead advances smoothly between snapshots. Replace `scrubber`:
```swift
    private var scrubber: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let live = scrubPreview ?? clock.displayTime(asOf: ctx.date)
            VStack(spacing: 8) {
                Slider(
                    value: Binding(get: { live }, set: { scrubPreview = $0 }),
                    in: 0...max(state.duration, 1),
                    onEditingChanged: { editing in
                        guard !editing, let scrubPreview else { return }
                        onSeek(scrubPreview)
                        self.scrubPreview = nil
                    }
                )
                .tint(Color.siloOnSurface)
                .disabled(state.duration <= 0)
                .accessibilityLabel("Playback position")
                .accessibilityValue(PlayerTimeFormatter.formatHMS(live))

                HStack {
                    Text(PlayerTimeFormatter.formatHMS(live))
                    Spacer()
                    Text(remainingLabel(live: live))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(Color.siloSecondaryText)
            }
        }
    }

    private func remainingLabel(live: Double) -> String {
        guard state.duration > 0 else { return PlayerTimeFormatter.formatHMS(state.duration) }
        return "-" + PlayerTimeFormatter.formatHMS(max(0, state.duration - live))
    }
```
In `transport`, change the play/pause button action to `onTogglePlayPause()` and base its icon/label on `clock.isPlaying` (optimistic) instead of `state.isPlaying`. Change the skip buttons to use `clock.displayTime()` as the base for the seek target. Add a **next-episode** button to the right of forward-30 when `state.hasNextEpisode`:
```swift
            if state.hasNextEpisode {
                Button { onPlayNext() } label: {
                    Image(systemName: "forward.end.fill").font(.system(size: 24, weight: .regular))
                }
                .accessibilityLabel(state.nextEpisodeTitle.map { "Next: \($0)" } ?? "Next episode")
            }
```

- [ ] **Step 4: Add a volume row above the secondary controls.**

Insert between `transport` and the `Spacer` before `secondaryControls` in `body`:
```swift
            volumeRow.padding(.top, 18)
```
Add:
```swift
    private var volumeRow: some View {
        HStack(spacing: 14) {
            Button { onSetMuted(!state.isMuted) } label: {
                Image(systemName: state.isMuted || state.volume <= 0.001
                      ? "speaker.slash.fill" : "speaker.fill")
                    .font(.system(size: 18, weight: .medium))
                    .frame(width: 28)
            }
            .accessibilityLabel(state.isMuted ? "Unmute" : "Mute")

            Slider(
                value: Binding(
                    get: { state.isMuted ? 0 : state.volume },
                    set: { onSetVolume($0) }
                ),
                in: 0...1
            )
            .tint(Color.siloOnSurface)
            .accessibilityLabel("Volume")
            .accessibilityValue("\(Int((state.isMuted ? 0 : state.volume) * 100)) percent")
        }
        .foregroundStyle(Color.siloOnSurface)
        .buttonStyle(.plain)
    }
```

- [ ] **Step 5: Make the secondary controls scroll horizontally (now 5–6 chips).**

Wrap `secondaryControls`' `HStack` in a horizontal `ScrollView` so audio + subtitle + quality + speed + display chips don't crush on a narrow phone:
```swift
    private var secondaryControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 8) {
                if !state.audioTracks.isEmpty { audioMenu.frame(minWidth: 76) }
                if !state.subtitleTracks.isEmpty { subtitleMenu.frame(minWidth: 76) }
                if !state.qualityOptions.isEmpty { qualityMenu.frame(minWidth: 76) }
                speedMenu.frame(minWidth: 76)
                if state.supportsVideoGravity || state.supportsHDRToggle { displayMenu.frame(minWidth: 76) }
            }
            .padding(.horizontal, 2)
        }
    }
```

- [ ] **Step 6: Relabel the display menu when it only holds HDR.**

Change `displayMenu`'s `RemoteChipLabel` caption from `"Aspect"` to `state.supportsVideoGravity ? "Aspect" : "HDR"`.

- [ ] **Step 7: Update the DEBUG preview to the new init signature.**

Update `#Preview("Now Playing")` to pass `clock: RemotePlaybackClock()` and the new closures (`onTogglePlayPause: {}`, `onSeek: { _ in }`, `onPlayNext: {}`, `onSetVolume: { _ in }`, `onSetMuted: { _ in }`), and add the new state fields to `previewPlaying()` (`volume: 0.8, isMuted: false, hasNextEpisode: true, nextEpisodeTitle: "Forks"`).

- [ ] **Step 8: Build iOS — expect PASS. Commit.**
```bash
git add iosApp/iosApp/Cast/iOS/SiloCastRemoteControlView.swift
git commit -m "cast(iOS): smooth interpolated scrubber, idle state, volume row, next-episode"
```

## Task D4: Persistent now-playing mini-bar

**Files:**
- Create: `iosApp/iosApp/Cast/iOS/SiloCastMiniBar.swift`
- Modify: `iosApp/iosApp/ContentView.swift`

- [ ] **Step 1: Build the mini-bar.**

```swift
#if os(iOS)
import SwiftUI

/// Persistent "Playing on <TV>" bar shown above the tab content whenever a cast
/// session is active and the full remote is dismissed. Tapping reopens the remote.
struct SiloCastMiniBar: View {
    @Bindable var controller: SiloCastController
    @State private var artwork = SiloCastArtworkResolver()

    var body: some View {
        if controller.hasActiveSession && !controller.isShowingRemoteControl {
            Button { controller.showRemoteControl() } label: {
                HStack(spacing: 12) {
                    thumb
                    VStack(alignment: .leading, spacing: 2) {
                        Text(controller.state?.title ?? "Connected")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text("Playing on \(controller.activeTarget?.name ?? "Silo TV")")
                            .font(.caption)
                            .foregroundStyle(Color.siloSecondaryText)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Button {
                        controller.send(.playPause)
                    } label: {
                        Image(systemName: (controller.clock.isPlaying) ? "pause.fill" : "play.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(controller.clock.isPlaying ? "Pause" : "Play")
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.siloOutline, lineWidth: 1))
                .foregroundStyle(Color.siloOnSurface)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: controller.state?.contentId) {
                await artwork.resolve(contentId: controller.state?.contentId)
            }
        }
    }

    @ViewBuilder
    private var thumb: some View {
        if let url = artwork.posterURL, !url.isEmpty {
            AsyncImageView(url: url, contentMode: .fill)
                .frame(width: 34, height: 50)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.siloSurfaceElevated)
                .frame(width: 34, height: 50)
                .overlay { Image(systemName: "tv").foregroundStyle(Color.siloSecondaryText) }
        }
    }
}
#endif
```

- [ ] **Step 2: Mount it in `MainTabView`.**

In `ContentView.swift`'s `MainTabView` body, place the bar in a bottom `safeAreaInset` (sits above the tab bar) inside the `#if os(iOS)` region:
```swift
        .safeAreaInset(edge: .bottom) {
            #if os(iOS)
            SiloCastMiniBar(controller: castController)
                .animation(.snappy, value: castController.hasActiveSession)
                .animation(.snappy, value: castController.isShowingRemoteControl)
            #endif
        }
```
(If `MainTabView` already has a bottom `safeAreaInset`, add the bar inside that closure instead of creating a second one.)

- [ ] **Step 3: regenerate the project, build iOS — expect PASS.**
```bash
cd iosApp && xcodegen generate
```
Then iOS build. Expected: PASS.

- [ ] **Step 4: Commit.**
```bash
git add iosApp/iosApp/Cast/iOS/SiloCastMiniBar.swift iosApp/iosApp/ContentView.swift iosApp/project.yml iosApp/Silo.xcodeproj
git commit -m "cast(iOS): persistent now-playing mini-bar reopens the remote"
```

## Task D5: Cast-this-item from the detail screen

**Files:**
- Modify: `iosApp/iosApp/Screens/Detail/ItemDetailView.swift`

- [ ] **Step 1: Add a Cast button + picker presentation state.**

In `ItemDetailPhoneContent`, add (inside the existing `#if os(iOS)`):
```swift
    @State private var castRequest: SiloCastPlaybackRequest?
```
Add a Cast button to the detail action row (next to Play). Use the same play parameters the screen already resolves — extract the request-building into a helper so it matches `presentPlayerFromDetail`:
```swift
    private func castRequest(
        contentId: String, fileId: Int?, audioTrackIndex: Int?,
        subtitleTrackIndex: Int?, startFromBeginning: Bool, resumePosition: Double?
    ) -> SiloCastPlaybackRequest {
        SiloCastPlaybackRequest(
            contentId: contentId, fileId: fileId,
            audioTrackIndex: audioTrackIndex, subtitleTrackIndex: subtitleTrackIndex,
            startFromBeginning: startFromBeginning, resumePosition: resumePosition)
    }

    private func castFromDetail(_ request: SiloCastPlaybackRequest) {
        if castController.hasActiveSession {
            Task { await castController.launch(request) }   // already connected ⇒ play now
        } else {
            castRequest = request                            // no session ⇒ pick a TV, then cast-and-play
        }
    }
```
Add a `.sheet(item: $castRequest)` that opens the picker with the request — this wires the dormant `cast(to:request:)` path:
```swift
        .sheet(item: Binding(get: { castRequest.map { CastRequestBox($0) } },
                             set: { castRequest = $0?.request })) { box in
            SiloCastTargetPickerView(request: box.request, controller: castController)
        }
```
`SiloCastPlaybackRequest` isn't `Identifiable`; add a tiny boxed wrapper near the top of the file:
```swift
#if os(iOS)
private struct CastRequestBox: Identifiable {
    let request: SiloCastPlaybackRequest
    var id: String { request.contentId }
    init(_ request: SiloCastPlaybackRequest) { self.request = request }
}
#endif
```

- [ ] **Step 2: Render the Cast button.**

Wherever the detail Play button is built, add an adjacent icon button (only on iOS):
```swift
        #if os(iOS)
        Button {
            castFromDetail(castRequest(
                contentId: contentId, fileId: resolvedFileId,
                audioTrackIndex: selectedAudioTrackIndex, subtitleTrackIndex: selectedSubtitleTrackIndex,
                startFromBeginning: startFromBeginning, resumePosition: resumePosition))
        } label: {
            Image(systemName: castController.hasActiveSession ? "airplayvideo.circle.fill" : "airplayvideo")
        }
        .accessibilityLabel("Cast to TV")
        #endif
```
> **Note for the implementer:** use the exact same expressions the existing `presentPlayerFromDetail` call site passes for `fileId`, audio/subtitle indices, `startFromBeginning`, and `resumePosition` (read them at the Play button site in `ItemDetailView.swift` around line 480). Keep the local-Play behavior in `presentPlayerFromDetail` unchanged — Play stays local-or-cast-if-session; the new button is the explicit "cast this item" affordance.

- [ ] **Step 3: Build iOS — expect PASS. Commit.**
```bash
git add iosApp/iosApp/Screens/Detail/ItemDetailView.swift
git commit -m "cast(iOS): cast-this-item button on detail (pick TV + play in one step)"
```

---

# Phase E — Player backends (tvOS playback gain + next episode)

## Task E1: Volume/mute on the player backends

**Files:**
- Modify: `iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift`
- Modify: `iosApp/iosApp/Screens/Player/CoreMedia/PlayerCore.swift`
- Modify: `iosApp/iosApp/Screens/Player/PlayerViewModel.swift` (`ActivePlayer` enum)

- [ ] **Step 1: `AVPlayerBackend` — user gain via `volume`, never `isMuted`.**

`isMuted` is reserved for the initial-video-display gate (it toggles `avPlayer.isMuted` true→false and would clobber a user mute). Model user mute as volume 0. Add:
```swift
    private var userVolume: Float = 1.0
    private var userMuted = false

    func setUserVolume(_ v: Float) {
        userVolume = min(max(v, 0), 1)
        applyUserGain()
    }
    func setUserMuted(_ m: Bool) {
        userMuted = m
        applyUserGain()
    }
    var currentUserVolume: Float { userVolume }
    var currentUserMuted: Bool { userMuted }

    private func applyUserGain() {
        avPlayer.volume = userMuted ? 0 : userVolume
    }
```

- [ ] **Step 2: `PlayerCore` — user gain via the `AVAudioEngine` main mixer.**

PlayerCore decodes to PCM through `AVAudioEngine`, so its `mainMixerNode.outputVolume` is a reliable gain stage (works on every route, including passthrough fallbacks where it decodes). Add stored user gain and apply to the engine's main mixer. Locate the `AVAudioEngine` instance (the audio backend re-prepared in `reloadAudioOutput()` near line 1807) and add:
```swift
    private var userVolume: Float = 1.0
    private var userMuted = false

    func setUserVolume(_ v: Float) {
        userVolume = min(max(v, 0), 1)
        applyUserGain()
    }
    func setUserMuted(_ m: Bool) {
        userMuted = m
        applyUserGain()
    }
    var currentUserVolume: Float { userVolume }
    var currentUserMuted: Bool { userMuted }

    private func applyUserGain() {
        // <engine>.mainMixerNode.outputVolume — bind <engine> to the actual
        // AVAudioEngine property used by the audio graph.
        audioEngine?.mainMixerNode.outputVolume = userMuted ? 0 : userVolume
    }
```
Then **re-apply after the engine is re-prepared**: at the end of `reloadAudioOutput()` (after the "re-prepared AVAudioEngine format" log at line 1807) call `applyUserGain()` so a route change doesn't reset gain to 1.0.

> **Implementer note:** the exact engine property name must be read from PlayerCore (the file documents an `AVAudioEngine (AVAudioSourceNode)` graph). If the engine lives inside a dedicated audio-output helper type rather than directly on `PlayerCore`, add the four methods to that helper and forward from `PlayerCore`. Do not introduce a new engine.

- [ ] **Step 3: Forward through the `ActivePlayer` enum.**

In `PlayerViewModel.swift`'s `ActivePlayer` enum (after `setSpeed`):
```swift
    func setVolume(_ v: Float) {
        switch self {
        case .none: return
        case .coreMedia(let c): c.setUserVolume(v)
        case .avPlayer(let a): a.setUserVolume(v)
        }
    }
    func setMuted(_ m: Bool) {
        switch self {
        case .none: return
        case .coreMedia(let c): c.setUserMuted(m)
        case .avPlayer(let a): a.setUserMuted(m)
        }
    }
    func volume() -> Float {
        switch self {
        case .none: return 1.0
        case .coreMedia(let c): return c.currentUserVolume
        case .avPlayer(let a): return a.currentUserVolume
        }
    }
    func isMuted() -> Bool {
        switch self {
        case .none: return false
        case .coreMedia(let c): return c.currentUserMuted
        case .avPlayer(let a): return a.currentUserMuted
        }
    }
```

- [ ] **Step 4: Build both platforms — expect PASS. Commit.**
```bash
git add iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift iosApp/iosApp/Screens/Player/CoreMedia/PlayerCore.swift iosApp/iosApp/Screens/Player/PlayerViewModel.swift
git commit -m "player: per-player volume/mute gain on both backends (cast remote control)"
```

## Task E2: `applySiloCastControl` — volume/mute/next; live content id in state

**Files:**
- Modify: `iosApp/iosApp/Screens/Player/PlayerViewModel.swift`

- [ ] **Step 1: Handle the new control commands.**

In `applySiloCastControl(_:)`, add cases:
```swift
        case .setVolume:
            guard let volume = command.volume, volume.isFinite else {
                throw SiloCastPlayerControlError.missingValue
            }
            activePlayer.setVolume(Float(min(max(volume, 0), 1)))
        case .setMuted:
            guard let enabled = command.enabled else {
                throw SiloCastPlayerControlError.missingEnabledValue
            }
            activePlayer.setMuted(enabled)
        case .playNext:
            playNextEpisodeNow()
```

- [ ] **Step 2: Emit volume/mute/next-episode + live content id from `makeSiloCastPlaybackState`.**

Replace the `volume: 1.0, isMuted: false, hasNextEpisode: false, nextEpisodeTitle: nil` placeholders (added in A3) with live values, and derive the content id from the current load so it stays correct after `playNextEpisodeNow()`:
```swift
    func makeSiloCastPlaybackState(contentId: String?) -> SiloCastPlaybackState {
        let liveContentId = lastLoadRequest?.contentId ?? contentId
        // ... existing titleText / subtitleText ...
        return SiloCastPlaybackState(
            contentId: liveContentId,
            // ... existing fields unchanged through supportsHDRToggle ...
            volume: Double(activePlayer.volume()),
            isMuted: activePlayer.isMuted(),
            hasNextEpisode: nextUpEpisode != nil,
            nextEpisodeTitle: nextUpEpisode?.title,
            error: error
        )
    }
```

- [ ] **Step 3: Build both platforms — expect PASS. Commit.**
```bash
git add iosApp/iosApp/Screens/Player/PlayerViewModel.swift
git commit -m "cast(tvOS): apply volume/mute/next-episode controls; live content id in state"
```

## Task E3: Receiver handles next-episode content change cleanly

**Files:**
- Modify: `iosApp/iosApp/Cast/tvOS/TVCastReceiver.swift`

- [ ] **Step 1: Keep `playerContentId` in sync after a next-episode load.**

Since `playNextEpisodeNow()` loads new content into the *same* `PlayerView`/view model (no re-`registerPlayer`), `playerContentId` would go stale. The Phase E2 change already makes `makeSiloCastPlaybackState` derive the live id from `lastLoadRequest`, so the wire state is correct regardless. Confirm `handleControl(.playNext)` simply forwards via `applySiloCastControl` and then `sendState()` (it already does for the default path). No extra change needed beyond confirming the default control branch runs for `.playNext`. Add a brief comment at the `handleControl` default branch noting next-episode flows through here.

- [ ] **Step 2: Build tvOS — expect PASS. Commit (if changed).**
```bash
git add iosApp/iosApp/Cast/tvOS/TVCastReceiver.swift
git commit -m "cast(tvOS): note next-episode flows through standard control path"
```

---

# Phase F — Verification (two-simulator)

## Task F1: End-to-end cast verification on two simulators

Follow the `companion-pairing-sim-test` pattern (two booted sims share the host network, so Bonjour + TLS-PSK work sim-to-sim). No code; this is the acceptance gate.

- [ ] **Step 1: Boot an iPhone sim + an Apple TV sim, sign both into the same dev server (admin/water1234), same profile/server id.**
- [ ] **Step 2: Discovery + connect.** On iPhone Home tap the cast button → picker shows the TV within ~8s → connect. TV shows the standby "Ready for iPhone" screen. ✅ if standby appears.
- [ ] **Step 3: Cast-this-item.** Open a movie detail, tap the new Cast button → TV starts playing → phone shows the now-playing remote with poster/title. ✅
- [ ] **Step 4: Smooth scrubber.** Confirm the playhead advances continuously (not 1s steps) and that dragging + releasing seeks the TV. ✅
- [ ] **Step 5: Optimistic play/pause.** Tap play/pause; the phone icon flips instantly and the TV follows. ✅
- [ ] **Step 6: Volume + mute.** Drag the volume slider and toggle mute; confirm the TV audio attenuates/mutes on the active route. Note in the verification log which backend (PlayerCore vs AVPlayer) and whether audio was decoded or passthrough. ✅ (Expected: audible on PlayerCore + decoded AVPlayer; no-op on passthrough — that's the documented caveat.)
- [ ] **Step 7: Next episode.** On a series, confirm the next-episode button appears and advances the TV to the next episode; phone artwork/title updates. ✅
- [ ] **Step 8: Mini-bar.** Minimize the remote; confirm the mini-bar appears across tabs and reopens the remote on tap. ✅
- [ ] **Step 9: Reconnect.** Kill Wi-Fi on the iPhone sim (or background the app briefly); confirm the phone shows "Reconnecting…" and recovers within the backoff window; the TV does not lock out (takeover/heartbeat). ✅
- [ ] **Step 10: Takeover.** Connect from a second iPhone sim; confirm it takes over and the first is dropped cleanly (no TV lockout). ✅
- [ ] **Step 11: Server switch (tvOS).** Switch the TV's active server; confirm the phone on the new server can discover it and the phone on the old server cannot. ✅
- [ ] **Step 12: Capture a short GIF of the happy path for the PR.** Save as `cast-remote-demo.gif`.

---

# Phase G — Security documentation (deferred hardening)

## Task G1: Document the cast threat model + per-pair-auth follow-up

**Files:**
- Create: `docs/tvos-player/cast-remote.md`

- [ ] **Step 1: Write the doc.** Include:
  - **Protocol overview:** `_silocast._tcp` Bonjour service, TLS-PSK transport, JSON framed messages, message kinds, heartbeat, takeover semantics.
  - **Volume route caveat:** tvOS has no system-volume API; the remote controls per-player gain only (0–100% of current TV volume, cannot boost). PlayerCore (AVAudioEngine main mixer) always honors it; AVPlayer route honors it for decoded PCM but is a no-op for bitstream/passthrough/AirPlay audio. The cast state echoes the *set* value, which may not equal audible change on passthrough.
  - **Security (known limitation):** the TLS-PSK is a single static shared secret compiled into every build, so the channel is encrypted but not authenticated — the only authorization is the `serverId` match in the hello. Any device on the LAN running a Silo build can control any Silo TV bound to the same server.
  - **Deferred follow-up:** derive a per-pair / per-server secret from the existing companion-pairing (`_silopair`) trust and add it to the cast hello handshake, so only paired devices can control the TV. Reference `companion-pairing-sim-test` and the pairing code as the trust source.

- [ ] **Step 2: Commit.**
```bash
git add docs/tvos-player/cast-remote.md
git commit -m "docs: cast remote protocol, volume caveats, deferred per-pair auth"
```

---

## Self-Review

- **Spec coverage** (the 12 findings):
  1. Smooth scrubber → D1/D3 (clock + TimelineView). ✅
  2. Persistent mini-bar → D4. ✅
  3. Cast-and-play from detail (dormant `cast(to:request:)`) → D5. ✅
  4. Idle "Ready" looks like playback → D3 `idleConnectedView`. ✅
  5. Missing transports (next-episode + volume) → D3 + E1/E2 (+ researched volume constraints). ✅
  6. Stale-session lockout → B1 takeover + heartbeat teardown. ✅
  7. No phone auto-reconnect → C1. ✅
  8. Silent second-controller rejection → B1 takeover (resolves by accepting + closing old). ✅
  9. Out-of-order sends → A1 ordered queue (+ B2/receiver, C uses enqueue for ping). ✅
  10. Stale server advertisement → B3. ✅
  11. 1 Hz timer during all tvOS playback → B2 gate. ✅
  12. Static PSK → G1 documented + deferred (per locked decision). ✅
  Plus optimistic play/pause (D2), scrubber a11y value + display-menu label + chip crowding (D3).
- **Placeholder scan:** the two "bind to the actual engine property" notes in E1 and the "use the same expressions as the existing Play site" note in D5 are deliberate pointers to verified-existing code (`AVAudioEngine` graph in PlayerCore; the resolved play params at `ItemDetailView.swift:~480`), not unfinished work — each names exactly what to bind and where. No TBD/TODO logic steps.
- **Type consistency:** `SiloCastPlaybackState` gains `volume/isMuted/hasNextEpisode/nextEpisodeTitle` in A3 with all five existing constructors updated in the same task; `RemotePlaybackClock` API (`ingest/displayTime/isPlaying/setOptimisticPlaying/setOptimisticTime`) is used identically in tests (D1), controller (D2), and view (D3); `SiloCastControlCommand` gains `volume:` field + `setVolume/setMuted/playNext` used consistently across A3, D2, E2. `enqueue(_:)` (A1) is the call used in B1/B2/C1. Backend methods `setUserVolume/setUserMuted/currentUserVolume/currentUserMuted` (E1) match the `ActivePlayer` forwarders and `makeSiloCastPlaybackState` reads `activePlayer.volume()/isMuted()`.

---

**Plan complete and saved to `docs/superpowers/plans/2026-06-16-ios-tvos-cast-remote-improvements.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

**Which approach?** (The phases are independently shippable — A/B/C transport+reliability could merge before the D UX surfaces if you'd rather land it incrementally.)
