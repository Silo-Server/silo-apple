# Stage 2 — playback control-plane extraction: design and wave plan

**Status:** draft for implementation, 2026-08-19. Base for wave 1: `player/architecture-remediation` @ `acc3004`
(round 6 + tail merged; suite 1539 / 3 skipped / 0). Owner decisions that bound this design: **P11 = no remote
key → hard cutover** (legacy VM core + backend ladders are deleted in the same effort; rollback = new
TestFlight build); **P1 = yes** (loopback tier is permanent); **P2/P5 = no** (local matrix stays); PR #172
remains the single PR. The architecture review this realises is
`docs/cleanup/player-review/2026-08-17-architecture-review.md` (§2.2 ownership map, §4 trouble spots, §5
essential/accidental, **§8 target**, §9 Stage 2, §11 test/validation matrix). Evidence re-anchored at the
current tip lives in `stage2/inventory-1..4*.md` — every spec cites those, not the review's 08-17 lines.

This document is what every Stage 2 package implements against. Deliverable names below are **binding**; an
implementer who cannot realise one without breaking an invariant stops and reports rather than improvising.

---

## 0. What Stage 2 is, in one paragraph

Today the player's control plane is `PlayerViewModel` (8,007 lines: ~5.5k control core + ~1.4k track half +
glue) driving `AVPlayerBackend` (4,884 lines: ~1k AVFoundation adapter, ~1.2k loopback lifecycle glue, six
in-route recovery ladders) through 17 by-value-generation-guarded closures, with a `PlaybackSessionBridge` actor
for the server session. Identity is spread over 3 generation counters + 5 session-id mirrors/echoes in the VM, a
string `activeLoopbackSessionID` compared 14 times in the backend, and ~16 unregistered `Task {}`s (inventory-1
§1a/§5, inventory-3 §3). Recovery has four owners and a two-owner handshake (`setRecoverySuspended` /
`setExternalStallSuppression` / `kickPlaybackAfterExternalStallCleared`). Stage 2 replaces that with: a
**pure `PlaybackReducer`** over an explicit `PlaybackState`; a **`PlaybackSessionActor`** that runs the
reducer's effects under structured concurrency with every effect stamped by `LoadID` / `SessionIdentity`; a
**`PlaybackEngineSession`** (one per load) that owns the backend adapter, the source proxy and — for loopback —
a `LocalHLSHost` value; **one pure `RecoveryPolicy`** holding every ladder's constants; and a
**`TrackSelectionCoordinator`** holding the track half behind a small port. `PlayerViewModel` becomes a thin
presentation model that projects `PlaybackState` and forwards view commands as intents. Behaviour on
iOS/tvOS/macOS is identical except for the items in §7.

---

## 1. Target architecture (the §8 sketch, made concrete for this codebase)

```
PlayerViewModel (@Observable, @MainActor, thin)        projects PlaybackState → the 130 view members (inv-4 B.2);
                                                      forwards view commands as PlayerIntent; owns no policy
PlaybackSessionActor (actor)                          holds PlaybackState; runs PlaybackReducer; executes [Effect]
                                                      under structured concurrency; every mutation conditional on
                                                      LoadID / SessionIdentity; owns PlayerTaskRegistry
PlaybackReducer (pure, enum namespace)                (PlaybackState, PlayerIntent | PlayerEvent) → (PlaybackState, [Effect])
RecoveryPolicy (pure, enum namespace)                 (RecoveryObservation, RecoveryContext) → (RecoveryAction?, RecoveryContext)
PlaybackEngineSession (@MainActor final class, one per LoadID)
    ├─ backend: any PlaybackBackend (AVPlayerBackend)  AVFoundation adapter: observers, audio session, display criteria,
    │                                                   PiP/AirPlay, seek deadline, initial-display gate — emits EngineEvent
    ├─ transport: PlaybackSourceProxy?                 unchanged data plane (retargetOrigin for silent renewal)
    └─ localHost: LocalHLSHost?                        writer + store + server + VOD plan + subtitle tap + restart
                                                       coalescer + session dir as ONE value with ONE lifecycle
PlaybackSessionBridge (actor, unchanged shape)         + injected PlaybackTransport, + SessionIdentity, + stopSession(expected:)
TrackSelectionCoordinator (@Observable @MainActor)     the track half behind TrackSelectionPorts; views keep reading VM forwarders
Coordinators kept as-is (glue, not policy):            NowPlayingController, SleepTimer, PictureInPictureCoordinator,
                                                       SubtitleAIController/LiveSubtitleCoordinator, PlayerSettings
```

**Ownership after Stage 2 (one owner per row — compare review §2.2):**

| Concern | Owner | Notes |
|---|---|---|
| Delivery / fallback rung | server (V3 replan via bridge) | VM ladder rungs 5–10 (inv-1 §4, online-unreachable) are deleted; the offline-only native→loopback and loopback→HLS rungs become `RecoveryAction.switchRoute(.loopbackFallback / .serverHLS)` decided by `RecoveryPolicy` with the *same* preconditions |
| Execution recipe in `original_http` | Apple planner (unchanged) | out of scope (Stage 3 cancelled) |
| Session identity | `SessionIdentity` minted by the bridge; `LoadID` minted by the actor | the five VM mirrors/echoes and the backend string id are deleted |
| Load generation | `LoadID` | `streamLoadGeneration`, `freshLoadGeneration`, `serverOutageRecoveryGeneration`, backend `loopbackGeneration`/`activeLoopbackSessionID` deleted |
| Source renewal | actor effect `.renewSource` (bridge `renewDirectSession` + proxy `retargetOrigin`) | single-flight becomes a reducer sub-state, not two `*SessionId` echoes |
| Recovery | `RecoveryPolicy` consumed by the actor; engine session only *executes* actions | six backend ladders + VM outage ride-through + VM error ladder → one policy, same constants (inv-3 §2 table) |
| Track selection | `TrackSelectionCoordinator` | same decision sites, same order (inv-2 §2); the eight `pending*` fields collapse into `TrackSelection` in wave 4 only after the coordinator is stable |
| Output-route change | actor: `PlayerIntent.outputRouteChanged` | the AVAudioSession observer lives in the VM shell and only forwards an intent |
| Seek / reanchor | `SeekRequest` inside `.playing` | recovery seeks are `SeekRequest`s with deadlines; the 8 × 200 ms initial-seek retry (inv-3 timer #11) is deleted |
| Teardown | `PlaybackEngineSession.dispose()` + `LocalHLSHost.teardown()` | the ~51-field hand reset (inv-3 §4.7) becomes "drop the value" |

---

## 2. Types (binding names and shapes)

New files under `iosApp/iosApp/Screens/Player/ControlPlane/` unless noted. All types are `internal`. Swift 5
mode; no macros; no new third-party code.

### 2.1 Identity — `PlaybackIdentity.swift` (wave 1E)
```swift
struct LoadID: Hashable, Sendable { let raw: UUID; init() }           // one per loadStream; owns callback lifetime
struct SessionIdentity: Equatable, Sendable {
    let serverSessionId: String?        // bridge.sessionId
    let playbackAttemptId: String       // "apple:<uuid>" (bridge ActiveProtocolV3.playbackAttemptId)
    let planAttemptId: String?          // "apple-plan:<uuid>"
    let planAttemptKey: String?         // server plan_attempt_key
    let outputContextId: String         // ApplePlaybackV3CapabilitySnapshot.outputContextId
}
```
`SessionIdentity` is produced only by `PlaybackSessionBridge.currentIdentity` (wave 1D) and carried by every
session-scoped effect/event. Offline loads use `SessionIdentity(serverSessionId: nil, playbackAttemptId:
"offline:<uuid>", …)`.

### 2.2 Plan — `ExecutablePlan.swift` (wave 1E)
```swift
enum ExecutablePlan: Equatable {                 // valid by construction; kills PlaybackEngineLoadError.missingLoopbackSession
    case nativeDirect(NativeDirectPlan)          // url, headers, startSeconds
    case serverHLS(ServerHLSPlan)                // manifestURL, headers, startSeconds, startMode (.startOfManifest | .absolute)
    case localHLS(LocalHLSPlan)                  // LoopbackSessionSpec (non-optional), startSeconds
    var engine: PlaybackEngineKind { … }
    init(_ plan: PlaybackExecutionPlan, request: StreamRequest) throws   // total over PlaybackExecutionPlan; throws only
                                                                        // for .siloPlayerLoopback with loopbackSession == nil
}
```
`PlaybackExecutionPlan` (planner/adapter output, decisionTrace, claims…) stays as the *planning* artefact;
`ExecutablePlan` is what the engine session executes. `logExecutionPlan`'s `cmpLog` line is unchanged.

### 2.3 State machine — `PlaybackState.swift` (wave 1E)
```swift
enum PlaybackState: Equatable {
    case idle
    case preparing(Preparing)                 // LoadID, SessionIdentity?, phase: .resolvingSession | .planning | .startingEngine, request: LoadRequest
    case playing(Playing)                     // LoadID, SessionIdentity, ExecutablePlan, transport: TransportState, sub: Sub
    case suspended(SuspendedContext)          // tvOS background: LoadRequest + resume position (replaces suspendedPlayback)
    case failed(PlaybackFailure, LoadID?)     // terminal; presentation shows `error`
    case disposed
}
enum Sub: Equatable { case steady; case recovering(RecoveryStep); case replanning(ReplanIntent); case seeking(SeekRequest);
                      case renewingSource(SourceRenewal); case ridingOutOutage(OutageRideThrough); case ended }
struct SeekRequest: Equatable { let id: UUID; let targetSeconds: Double; let origin: SeekOrigin; let deadline: Date }
enum SeekOrigin: Equatable { case user, scrub, skip, chapter, intro, credits, nextUpKeepWatching, recovery(String), reanchor }
enum PlayerIntent: Equatable { case load(LoadRequest, origin: LoadOrigin); case play; case pause; case togglePlayPause
    case seek(targetSeconds: Double, origin: SeekOrigin); case selectTrack(TrackSelectionIntent)   // forwarded to the coordinator
    case changeQuality(String); case outputRouteChanged(ApplePlaybackV3CapabilitySnapshot)
    case scenePhase(ScenePhase); case resumeSuspended; case retry; case dismiss }
enum PlayerEvent: Equatable { case engine(EngineEvent, LoadID); case session(SessionEvent, SessionIdentity)
    case transport(TransportEvent, LoadID); case recovery(RecoveryAction, LoadID); case timer(TimerID, LoadID) }
enum Effect: Equatable {   // run by PlaybackSessionActor; every case carries the identity it is conditional on
    case startSession(LoadRequest, LoadID)                       // bridge.startSession / OfflinePlaybackBuilder → .session(.prepared)
    case stopSession(SessionIdentity, position: Double?, isPaused: Bool)
    case loadEngine(ExecutablePlan, LoadID, reuseEngine: Bool)   // reuseEngine == today's prepareBackend(for:) path — product-essential
    case disposeEngine(LoadID)
    case seek(SeekRequest, LoadID)
    case replan(ReplanIntent, SessionIdentity)                   // bridge.replanProtocolV3 → .session(.replanned | .terminal | .missing)
    case renewSource(SourceRenewal, SessionIdentity)             // bridge.renewDirectSession + proxy.retargetOrigin
    case runRecovery(RecoveryAction, LoadID)                     // engine-session-level actions (nudge/reload/reanchor/rebuild/reassert)
    case pollServerHealth(TimerID, after: Duration, LoadID)      // outage ride-through / wait-for-server-ready
    case schedule(TimerID, after: Duration, LoadID)
    case cancelTimer(TimerID)
    case reportProgress(SessionIdentity, position: Double, isPaused: Bool)
    case reportFirstFrame(SessionIdentity, ms: Int)
    case reportPlanExecutionStarted(SessionIdentity)
    case publish(Presentation)                                   // the only path to UI state (see §2.6)
}
```
`EngineEvent` (backend → actor, stamped by the engine session): `fileLoaded(reason)`, `firstFrame(ms)`,
`time(seconds)`, `duration(seconds)`, `pauseChanged(Bool)`, `buffering(Bool)`, `bufferedAhead(PlaybackBufferedAhead)`,
`stats(PlaybackStats)`, `tracks([PlayerTrack])`, `chapters([PlayerChapterInfo])`, `timelineOffset(Double)`,
`endOfFile`, `failed(PlaybackFailure)`, `externalPlayback(active:)`, `externalPlaybackAllowed(Bool)`,
`externalPlaybackUnavailable`, `sidecarTracksRegistered([SidecarSubtitleDescriptor])`, and the recovery
observations in §2.4 wrapped as `observation(RecoveryObservation)`.
`SessionEvent`: `prepared(PreparedPlayback)`, `replanned(PreparedPlayback)`, `replanUnavailable`,
`terminal(PlaybackV3TerminalFailure)`, `sessionMissing`, `renewed(PreparedPlayback)`, `renewalFailed(transient: Bool)`.
`TransportEvent`: `sessionMissing`, `sourceInterrupted(reason)`, `originOutage(active: Bool)`.
`TimerID`: the keys of `PlayerTaskRegistry.swift:37-62` that are control-plane (freshLoad, protocolV3Replan,
staleSessionRecovery, backgroundRenewal, sourceOutageRideThrough, serverOutageRecovery, interruptionRecovery,
seekFilterTimeout, progress) — UI timers (hideControls, noticeDismiss, skipDebounce, holdSeek*, nextUp*,
autoSkipIntro) stay on the presentation model.

**As built (wave 1E), the realised types differ from the sketch above — waves 2/3 plan against these:**

1. **No `Sub.seeking`.** The outstanding seek is `Playing.seek: SeekRequest?`, a field beside `sub`:
   `seekOriginTime`/`seekTargetTime` are independent of the replan/renewal slots today, so a seek during a
   quality switch is performed *and* the replan still lands; a `Sub` case dropped whichever arrived second. A
   new `LoadID` still drops the seek structurally (I5). `SeekRequest` gained `fromSeconds` (the pre-seek
   position the filter compares against), and `SeekOrigin.reanchor` emits **no** `Effect.seek` — only
   `.cancelTimer(.seekFilterTimeout)`: `beginReanchorSeekUI` (PVM:5063-5076) arms the filter *and* takes down
   the 5 s safety valve an earlier plain seek may have left running, because the re-anchor filter is released
   by the rebuild that follows, not by a clock.
2. **Two `Effect` cases added:** `transport(TransportCommand, LoadID)` (the view's play/pause) and
   `syncProgress(contentId:position:duration:forceOverwrite:LoadID)` (the visible renewal's content-scoped
   force-write, PVM:4262-4267 — the actor completes it *before* the `.startSession` after it). `startSession`
   and `PlayerIntent.load` carry `LoadOptions` (progressPosition, finalizeCurrentSession, resumePosition,
   allowNearEndResume, preserveInterruptionState). `PlayerIntent.selectTrack` is dropped: track intents go to
   `TrackSelectionCoordinator` directly. **`disposeEngine` carries a `SourceCacheDisposition`** —
   `disposeEngine(LoadID, sourceCache: .stash | .discard | .retainProxy)` — because the teardown sites
   disagree and the effect must carry the disagreement, not average it: a fresh load (including the visible
   renewal) stashes the outgoing proxy's cached prefix for a same-file successor (PVM:2759/3524), the terminal
   path and `cleanup()` release it (PVM:4063/6386), a server-outage recovery stashes *unless* its reason is
   `source_entity_changed` (PVM:4429-4434, where the validator proved the prefix belongs to the replaced
   entity), and the tvOS background suspend disposes only the backend and deliberately leaves the proxy — and
   its cache — running (PVM:7627), which is what `.retainProxy` pins for wave 2's `PlaybackEngineSession`
   (it owns backend *and* proxy, so a blind `dispose()` would tear the proxy down on every Apple TV suspend).
3. **`.failed(PlaybackFailure, LoadID?, identity: SessionIdentity?, request:, position:, selections:)`.** The
   terminal path still emits no `.stopSession` (it lets the session lapse), but the identity, playhead, replay
   request and live selections are carried, because `cleanup()` (PVM:6358/6404), `retry()` (PVM:4557-4566) and
   the tvOS error-screen suspend all still reach that session. `SuspendedContext` carries the failure likewise.
   The playhead is carried, never reset, across `Preparing.transport` / `.failed(position:)` /
   `SuspendedContext.resumePosition` — Retry and the tvOS resume depend on it.
4. **New value types:** `ScenePhasePlatform` (the scene-phase rule takes the platform as a *parameter*; `#if os`
   appears once, in `.current`, so the iOS-only test bundle exercises all three tables), `TrackResumeSelections`
   (the live `copyForRecovery` inputs — its resolvers read player track lists the reducer does not own),
   `LoadOptions`, `PlaybackAdoption`, `ReplanIntent.Kind`, `SourceCacheDisposition`, `PreparedPlaybackRef`
   (identity-keyed `Equatable` box for the non-`Equatable` `PreparedPlayback`), `TransportState`,
   `TransportCommand`, `Playing.Interruption` (`PlaybackInterruptionState` as a field on **both** `Preparing`
   and `Playing` — see item 8) and a top-level `LoadOrigin`. `LoadRequest` stays nested on the view model and
   is referenced as `PlayerViewModel.LoadRequest`; `LoadOrigin` could **not** stay there because
   `PlayerViewModel.LoadOrigin` is `private` (PVM:922) and therefore unreachable, so wave 1E declares its own
   copy (`PlaybackState.swift`) and **wave 3 deletes the private one** rather than leaving two.
5. **The replay request is adopted, not frozen.** `Preparing.request` / `Playing.request` are `var` and are
   rewritten at `.prepared`, `.replanned` and `.renewed` through
   `LoadRequest.adoptingProtocolV3Intent(plan:selectedVersion:activeQualityId:)` under
   `adoptProtocolV3RenewalIntent`'s own two preconditions (the prepare carries a V3 plan; the request is not an
   offline download) — PVM:2589 / PVM:4146 / PVM:3596-3607. A replan additionally applies the pre-adopt quality
   latch first (`attemptProtocolV3Replan` PVM:1652-1654, `restartCurrentTranscodeHLS` PVM:5264-5266). Without
   this the user's mid-stream quality choice and the server's authoritative V3 subtitle ordinal are dropped
   from every replay — `copyForRecovery` (PVM:860-880) carries `preferredQualityOverride` and
   `preferredProtocolV3SubtitleIndex` from its *receiver*, and both are wire arguments to `startSession`
   (PlaybackSessionBridge.swift:401-511).
6. **`Preparing`/`Playing` carry `hasProtocolV3`** (`activePreparedProtocolV3 != nil`, PVM:2588/3515/4066).
   It is the precondition of both intents that mint a server replan and neither is derivable from the rest of
   the state: `switchQuality` only takes the replan branch when a live plan owns the load (PVM:4600-4622) and
   the route observer guards on the same field before it samples the snapshot (PVM:1082-1086) —
   `isMaterialOutputRouteChange` is a bare id inequality and `SessionIdentity.offline()` publishes
   `outputContextId: ""`, so without the bit an offline load would treat every route notification as material.
7. **Transport commands write nothing.** `.play` / `.pause` / `.togglePlayPause` and the four scene-phase pause
   /resume arms emit `Effect.transport(command, LoadID)` and neither write `TransportState.isPaused` nor
   publish: `isPlaying` has one writer, the backend's `onPauseChange` (PVM:4573-4576, and none of
   `pauseForForegroundInterruptionIfNeeded` PVM:7571-7589, the tvOS `.active` arm PVM:4728-4735, the macOS
   arm PVM:4753-4756 or `pauseBackgroundPlaybackIfUnrouted` PVM:4829-4835 touches it). The three sites that
   *do* write it by hand are ported as such: `handleEndOfFile` (PVM:3424, which also clears the buffering
   capsule at PVM:3423), `triggerAutomaticInterruptionRecovery` (PVM:4016) and `attemptServerOutageRecovery`
   (PVM:4438).
8. **The tvOS interruption arms are state-agnostic.** `pauseForForegroundInterruptionIfNeeded`
   (PVM:7571-7589), the `.active` re-arm (PVM:4725-4750) and `triggerAutomaticInterruptionRecovery` plus its
   deadline task (PVM:4005-4025 / 4738-4747) key only off `playbackInterruption` and `isPlaying`, neither of
   which `resetPublishedLoadState` clears (PVM:3475-3546) and the first of which a
   `preserveInterruptionState` load deliberately keeps (PVM:3691-3693). `Preparing` therefore carries
   `interruption` as well as `transport`, and all three arms go through `PlaybackReducer.interruptionSlot` /
   `mutatingInterruptionSlot` instead of matching `case .playing` — an Apple TV going inactive while a
   quality switch, a Retry or an interruption reload is still resolving pauses, re-arms and auto-recovers
   exactly as a steady load does. Narrowing any of them to `.playing` would leave `fileLoaded` clearing
   `isPaused` with no `.transport(.play)` ever issued, i.e. the UI reporting "playing" against a paused engine.
   The other side of the same guard: a load started from `.idle`, `.failed` or `.suspended` is seeded
   `transport.isPaused = true`, because `isPlaying` really is false in all three (PVM:185 initial,
   PVM:4072 terminal, PVM:7621 suspend) and `resetPublishedLoadState` never overwrites it — so a cold start,
   a Retry and an explicit resume record no interruption and publish no playing capsule under the overlay.

9. **One `EngineEvent` case added in wave 2b: `recoveryAction(RecoveryAction)`.** The sketch above wrapped the
   §2.4 observations as `observation(RecoveryObservation)` on the same stream; as built the *observations*
   never leave the engine session — they go straight into that load's `RecoveryDriver` (§2.4 policy, one
   `decide` call site), and the in-route arms are performed on the backend synchronously, where the ladder ran.
   What rides the stream is the other half: the `RecoveryAction`s whose execution belongs to the shell
   (`treatAsNaturalEnd`, `requestServerReplan`, `switchRoute`, `renewSourceInBackground`, `renewSessionFresh`,
   `rideThroughOutage`, `endOutageRideThrough`, `recoverFromServerOutage`, `waitForServerReady`,
   `autoRecoverInterruption`, `fail`). No `observation` case exists or is needed. This is what lets a
   superseded load's decision die with its session instead of needing a generation guard; wave 3 delivers the
   same value to the actor as `PlayerEvent.recovery(RecoveryAction, LoadID)`, which already exists.

**Contract notes waves 2/3 must honour:** (a) `TransportState.isPictureInPictureEngaged` is
`PictureInPictureCoordinator.isEngaged` (`isActive || isTransitioning`), *not* the backend's
`isPictureInPictureActiveProvider`; (b) the third iOS background exemption — `isPossible` plus the bounded 1 s
grace — stays in the iOS shell, which resolves it *before* forwarding `.scenePhase(.background)`; (c) the
shell/track coordinator must keep `TrackResumeSelections` current (the `-1` "Off" sentinel included): the actor
performs the `copyForRecovery` substitution from it; (d) a `.transcodeRestart` replan emits its progress report
here, but the engine dispose (implied by `reuseEngine == false`) and the quality restart's overlay (raised at
the *adopt*, PVM:2578-2582) are wave 3's; (e) `commitSeek`'s first branch (`reloadServerBackedHLSForSeek`
PVM:5078-5131, `reloadLocalLoopbackForSeekBeforeAnchor` PVM:5133-5175) has no reducer model — wiring `.seek`
straight through would regress seeking past the anchor; (f) `Presentation` is a stub (`metadata` never filled,
`playbackStats` only from transport), so wave 3 must **merge** a `.publish` onto the view model, not assign it;
(g) the high-frequency transport arms (`.time`/`.duration`/`.buffering`/`.bufferedAhead`/`.stats`) emit no
`.publish` — the actor owes one coalesced publish per tick, which carries the optimistic seek jump and the
adopted position/duration/quality to the UI; (h) `Effect.transport` is fire-and-forget — the actor must let the
resulting `EngineEvent.pauseChanged` come back through the reducer, and must **not** synthesise one, or the
single-writer rule in as-built item 7 is broken from the other side.

**Wave-3 obligations from the reducer review** — reducer-visible gaps deliberately left for the wiring wave,
each of which wave 3 must close explicitly rather than inherit silently:

* `PlaybackReducer.swift` `beginSeek` (`.reanchor` arm) — `beginReanchorSeekUI` (PVM:5063-5076) also raises the
  loading overlay, clears the buffering flag, reveals the controls and cancels the hide timer; the reducer
  emits only the filter arm + `.cancelTimer(.seekFilterTimeout)`, because that arm is reachable **only** from
  `commitSeek`'s unmodelled first branch (contract note (e)), which is the code wave 3 has to write anyway.
* `PlaybackReducer.swift` `.changeQuality` — the pre-V3 branches of `switchQuality` (PVM:4623-4710: source
  reselection, transcode → direct, `normalizeStoredId`, `qualitySwitchError` re-arming) stay in the shell,
  which must issue the corresponding `.load` itself; the reducer refuses the intent when `hasProtocolV3` is
  false rather than guessing.
* `PlaybackReducer.swift` `.recoverFromServerOutage` — the reducer cancels the ride-through timer, but
  `clearSourceOutageRideThroughState`'s `setExternalStallSuppression(false)` (PVM:4346) has no effect of its
  own; it is subsumed by the `.disposeEngine` two effects later. If wave 2's engine session ever survives an
  outage recovery, that release needs an explicit effect.
* `PlaybackState.swift` `TrackResumeSelections` — still only the four `copyForRecovery` arguments. The adopted
  request now carries `preferredProtocolV3SubtitleIndex`/`preferredQualityOverride`, so the shell owes only
  the three live track resolvers (contract note (c)); it must re-arm them from the adopted plan at each adopt
  (`armAdoptedProtocolV3TrackIntent`, PVM:3629-3641), which is where the resolvers' fallbacks read from while
  the replacement stream's track lists are still empty.
* `PlaybackState.swift` `Presentation` — `Playing.hasProtocolV3` is control-plane state, but the view's
  quality menu also reads `qualityOptions` (PVM:2615-2618), which is not projected here; wave 3 keeps it on
  the presentation model and must not re-derive "V3 is active" from it.

**As built (wave 3) — wave 4 plans against these (three review rounds; the round-2/3 fixes are part of the
contract):**
- **The `.time` axis contract:** `EngineEvent.time` carries MOVIE time. The one conversion site is
  `PlaybackEngineSession.bindBackend` (a verbatim `mediaTime(for:)` copy over the session's
  `mediaTimelineOffsetSeconds` mirror, fed only by `onTimelineOffsetChange` and seeded across `reusing:`).
  The VM's `playbackTimelineOffset` survives only as the loopback re-anchor guard input and two `[CMP-SEEK]`
  log fields — never as a conversion. Do not add a second `onTimeChange` binder.
- **`PlaybackReducer.promotedForRecovery`:** a `.preparing(.startingEngine)` load is promoted onto `Playing`
  at the seven mid-ladder recovery rungs (base had no load-state gate in `handlePlaybackError`), gated on the
  action set + phase; `.resolvingSession` excluded. `Preparing.lastFailureMessage` feeds the server-HLS rung's
  replan text (the frozen `RecoveryAction` was deliberately not widened).
- **`SuspendedContext.retainedLoadID`:** the tvOS `.retainProxy` suspend keeps `engineSession` set (base
  shape) and the resume emits `.disposeEngine(retained, .stash)` via `previousEngineLoadID`.
- **`Presentation.isLoading` is `Bool?`:** `nil` = "leave the shell's overlay alone"; the `.pauseChanged`
  publish is the one arm that sends it (base's `onPauseChange` never touched the overlay). There is no
  state-derived overlay predicate — do not reintroduce one.
- The two wave-2b disclosed gaps are CLOSED as legacy restorations (actor-scoped ride-through carry with
  drop-on-fresh-load/terminal/EOF; the visible outage recovery reloads on a reachable probe).
- Shell coverage note: actor tests run with `shell: nil` — `installEngine`/`teardownEngine`/
  `applyPresentation` are pinned only at the effect level; §6 device rows 13/14 exercise the real paths.

### 2.4 Recovery — `Recovery/RecoveryPolicy.swift` + `Recovery/RecoveryObservation.swift` (wave 1B)
```swift
enum RecoveryObservation: Equatable {
    // backend-originated (loopback route unless noted)
    case startupTick(servedRequests: Int, secondsSinceStart: Double, displayModeSwitchInProgress: Bool)   // inv-3 §2 S
    case playheadTick(PlayheadSample)          // position, timeControl, bufferedAhead, generatedAhead, secondsSinceLastServe, userPaused, playbackEstablished
    case itemDeathEvidence(statusCode: Int?, description: String, weight: Int, position: Double, userPaused: Bool)   // D
    case edgeSample(EdgeSample)                // loadedEnd, playlistEnd, playlistHash, loadedAhead, visibleAhead, targetDuration, longestSegment
    case playbackStalled                       // X
    case playlistUnchanged(userPaused: Bool)   // Y
    case likelyToKeepUp(rate: Double, bufferedAhead: Double, reachedEnd: Bool)   // auto-resume rung
    case seekDeadlineExpired(kind: SeekDeadlineKind)
    case engineFailed(PlaybackFailure)         // any route
    // transport / session
    case originOutage(active: Bool)            // proxy
    case sourceInterrupted                     // proxy
    case sessionMissing(source: SessionMissingSource)   // .playerError | .proxy404 | .progressHeartbeat | .replanCatch
    case serverHealthProbe(ok: Bool)
    case bufferingChanged(Bool)                // for the outage "Reconnecting" runway gate
}
struct RecoveryContext: Equatable {            // threaded state; replaces the backend's watchdog fields + VM latches
    var route: PlaybackEngineKind; var playbackEstablished: Bool; var userPaused: Bool
    var suspendedReasons: Set<String>          // "server_replan", "origin_outage" — same strings as today
    var startup: StartupState                  // stage (.initial/.nudged/.reloaded), startedAt, lastProgressAt, lastRequestCount
    var playhead: PlayheadState                // stationarySince, reanchorCount, windowStart, didEscalateStarvation, lastStallRecoveryAt
    var itemDeath: LoopbackItemDeathRecoveryState; var itemDeathConfirmation: LoopbackItemDeathConfirmationState   // reuse verbatim
    var edge: LoopbackEdgeWatch?
    var rebuildBudget: LoopbackRebuildBudget   // reuse verbatim
    var outage: OutageState?                   // rideThroughStart, nextProbeDelay (1→8 s), noticeShown
    var serverOutageRecovery: ServerOutageRecoveryState?   // waitStart, nextDelay
    var backgroundRenewalTransientFailures: Int
    var attemptedNativeDirectFallback: Bool; var attemptedLoopbackHLSFallback: Bool   // replace the two hasAttempted* latches, per LoadID
    var nearEnd: NearEndInputs?                // duration, currentTime, bufferedAhead, sourceOutageActive — for the natural-end rule
}
enum RecoveryAction: Equatable {
    case reassertPlay                                   // bare avPlayer.play()
    case nudgeStartup                                   // S .initial
    case reloadStartupItem                              // S .nudged
    case reanchor(atMediaSeconds: Double, reason: String)          // recoverLocalLoopbackStallIfNeeded / vod_stall_nudge
    case reloadItem(atMediaSeconds: Double, reason: String)        // reloadEstablishedLoopbackItem
    case restartProducer(atSegmentIndex: Int, authoritative: Bool) // requestVODProducerRestart
    case rebuildLocalSession(atMediaSeconds: Double, reason: String)   // rebuildSiloLoopbackSession (budgeted)
    case deferUntilPlay(mediaSeconds: Double)           // Y while paused (pendingLocalLoopbackRecoveryMediaTime)
    case resumePlayback                                 // auto-resume rung
    case treatAsNaturalEnd                              // VM rung 3 (8 s / ≤1 s buffered)
    case requestServerReplan(classification: String, message: String)   // VM rung 4 + HLS fallback rungs
    case switchRoute(RouteFallback)                     // .loopbackFallback(plan) | .serverHLS(classification) — offline-only rungs
    case renewSourceInBackground(reason: String)        // attemptBackgroundSessionRenewal
    case renewSessionFresh(reason: String)              // attemptStaleSessionRenewal
    case rideThroughOutage(probeAfter: Duration)        // handleOriginOutageChanged(active)
    case endOutageRideThrough(kick: Bool)               // clearSourceOutageRideThroughState + kickPlaybackAfterExternalStallCleared
    case recoverFromServerOutage(reason: String)        // attemptServerOutageRecovery
    case waitForServerReady(probeAfter: Duration)       // waitForServerReady loop
    case autoRecoverInterruption                        // triggerAutomaticInterruptionRecovery
    case fail(PlaybackFailure)                          // terminal
}
enum RecoveryPolicy {
    static func decide(_ o: RecoveryObservation, context: RecoveryContext, now: Date) -> (RecoveryAction?, RecoveryContext)
    // CONSTANTS — copied verbatim from inv-3 §2 (B:440-506, B:145-146, B:67-69, B:41, B:3677 10 s cooldown, B:3184 4 s,
    // B:3235-3243 edge thresholds, B:443 seek deadline 15 s) and inv-1 §1e/§4 (PVM:954-964, PVM:601). Each is a
    // `static let` with the same name as today where one existed.
}
```
Precedence inside `decide` for `.playheadTick` is exactly the tick order in inv-3 §2 P (item-death confirmation
→ suspension gate → starvation → wedge qualification → window reset → exhaustion → fetch-high-water bail →
reanchor). `engineFailed` follows the VM ladder order in inv-1 §4 with rungs 5–10 reduced to the ones that are
reachable: `sessionMissing` (renewal), `prematureSourceEnd` (server outage), interruption auto-recover,
`switchRoute` (offline only, same preconditions), else `.fail`. Suppression: when `suspendedReasons` is
non-empty the policy returns `nil` for every loopback in-route observation **except** item-death confirmation
(which takes `recoverySuppressed` as input and degrades to `.none`, as today) and the startup backstop —
**note**: today the startup tick's `failBackstop` arm ignores suspension (inv-3 §2 S); the policy keeps that
quirk and pins it in a test so it is a conscious decision, not drift.

### 2.5 Backend protocol — `PlaybackBackend.swift` (wave 1A)
```swift
@MainActor protocol PlaybackBackend: AnyObject {
    // load / transport (inv-3 §1.2)
    func load(sessionSpec: LoopbackSessionSpec, startTime: Double)
    func loadRemoteHLS(url: URL, headers: [String: String], startTime: Double)
    func loadDirectFile(url: URL, headers: [String: String], startTime: Double)
    func play(); func pause(); func isPaused() -> Bool; func currentTime() -> Double
    func seek(to seconds: Double); func setSpeed(_ rate: Double)
    func setUserVolume(_ v: Float); func setUserMuted(_ m: Bool); var currentUserVolume: Float { get }
    func setMediaTimelineOffset(_ offset: Double); func dispose()
    // recovery handshake (inv-3 §1.3) — kept in wave 1; deleted in wave 2 when the ladders move
    func setRecoverySuspended(_ suspended: Bool, reason: String); func setExternalStallSuppression(_ active: Bool)
    func kickPlaybackAfterExternalStallCleared()
    // tracks / subtitles / chapters (inv-3 §1.4)
    func selectAudioTrack(_ trackId: Int64); func selectSubtitleTrack(_ trackId: Int64?); func setSecondarySubtitleTrack(_ trackId: Int64?)
    func registerSidecarSubtitles(_ descriptors: [SidecarSubtitleDescriptor])
    func openLiveSubtitleTrack(slot: SubtitleSlot, label: String?, language: String?)
    func feedLiveSubtitleCue(slot: SubtitleSlot, eventText: String, startMs: Int64, durationMs: Int64)
    func closeLiveSubtitleTrack(slot: SubtitleSlot)
    func setSubtitleDelay(_ seconds: Double); func applySubtitleAppearance(_ appearance: SubtitleAppearance)
    func setServerChapters(_ chapters: [PlayerChapterInfo])
    var hasControlledSubtitleSelection: Bool { get }
    var isExternalPlaybackActive: Bool { get }; var isExternalPlaybackAllowed: Bool { get }
    // callbacks (inv-3 §1.6) — wave 1 keeps the 17 closures + 3 providers exactly as declared on AVPlayerBackend;
    // wave 2 replaces them with `var events: AsyncStream<EngineEvent>` owned by PlaybackEngineSession
    var onTimeChange: ((Double) -> Void)? { get set }  … (all 17) …
    var isPictureInPictureActiveProvider: (() -> Bool)? { get set }
    var proxyStatsProvider: (() -> PlaybackSourceProxyStats?)? { get set }
    var sourceOutageStateProvider: (() -> Bool)? { get set }
}
```
`AVPlayerBackend` conforms by declaration only (no body changes in wave 1). The **view surface** (`avPlayer`,
`subtitleOverlay`, `attach/detachSubtitleOverlay`, `subtitleRendererForOverlay`) is *not* in the protocol —
`AVPlayerSurface` keeps taking the concrete `AVPlayerBackend`, reached through `PlayerViewModel.avPlayerBackend`
(wave 1) and `PlaybackEngineSession.surfaceBackend` (wave 3). Test double: `iosApp/Tests/FakePlaybackBackend.swift`
(records calls, lets tests fire any callback).

### 2.6 Presentation — `Presentation` value (wave 3)
`struct Presentation: Equatable` carries exactly the stored projections in inv-1 §1c that the actor changes
(isPlaying, currentTime, duration, isLoading, isBuffering, error, activeQualityId, isQualitySwitching,
bufferedAheadSeconds, playbackRunwaySeconds, playbackStats, metadata badges…). The VM applies `.publish` on the
main actor. View-local/UI state (showControls, scrubbing, hold-seek, HUD, next-up, notices, sleep timer) stays VM-owned.

### 2.7 Track coordinator — `Tracks/TrackSelectionCoordinator.swift` + `Tracks/TrackSelectionPorts.swift` (wave 1C)
`@MainActor @Observable final class TrackSelectionCoordinator` owning the state in inv-2 §1b + §7 "moves
wholesale", the five published lists/ids (`audioTracks`, `subtitleTracks`, `selectedAudioId`,
`selectedSubtitleId`, `selectedSecondarySubtitleId` — the VM keeps **forwarding computed properties** with the
same names so the 17 view files compile untouched), the `subtitleAI` controller and the two live-subtitle
adapters (re-pointed from `PlayerViewModel` to the coordinator). Ports (a `struct TrackSelectionPorts` of
closures, built by the VM; replaced by the engine session/actor in wave 3 without touching the coordinator):
`backend: () -> (any PlaybackBackend)?`, `requestReplan: (classification, message, subtitleIndex?) -> Void`,
`isReplanInFlight: () -> Bool`, `context: () -> TrackSelectionContext` (activePreparedProtocolV3,
currentSelectedVersion, currentWatchDetail, activePlaybackSessionId, resolvedServerUrl, activeRouteKind,
backendCapabilities, offlinePlaybackContext, currentTime, isBackgroundSuspended), `showNotice`,
`dismissNotice`, `scheduleHideControls`, `setLastLoadRequestSubtitleIndex`. The five non-clean boundaries in
inv-2 §7 are handled as: (a) `resetPublishedLoadState` calls `coordinator.resetForLoad(keepingTrackPrefs:)`;
(b) `adoptPreparedPlayback` calls `coordinator.adopt(prepared, origin:)`; (c) route recovery calls
`coordinator.snapshotForRecovery()` / `restore(_:)`; (d) `setSubtitleMatchesSystemAppearance` forwards to
`coordinator.setMatchesSystemAppearance`; (e) `selectAudio` stays on the coordinator (it already owns
`reapplySystemSubtitlePolicy`). The `TrackSelection` enum model of review §8 is **wave 4** (collapsing the
`pending*` fields) — only once the coordinator is stable.

**As built (wave 1C), four bindings differ from the sketch above — wave 3 must plan around these, not around
the sketch:**

1. **The class is `@Observable final class`, not `@MainActor @Observable`.** `PlayerViewModel` is a
   nonisolated `@Observable class` and the targets set only `SWIFT_VERSION 5`; annotating the coordinator
   would have changed the isolation of members that were nonisolated before the move. `@MainActor` sits on
   exactly the members that carried it in `PlayerViewModel` (the AI/search surface and the live-subtitle
   notice seam). Wave 3 cannot assume it may hand the ports to a `MainActor`-isolated coordinator: the
   coordinator is not actor-isolated, so a `MainActor` engine session must keep calling it the way the view
   model does today.
2. **`resetForLoad` has no `keepingTrackPrefs:` parameter.** No such flag exists on the base
   `resetPublishedLoadState`; its parameters are the four `preferred*` values (audio index, subtitle index,
   sidecar track id, V3 subtitle index) plus `resetRouteRecoveryFlags`, which is not a track concern and
   stays in the view model. The realised signature is
   `resetForLoad(preferredAudioTrackIndex:preferredSubtitleTrackIndex:preferredSidecarSubtitleTrackId:preferredProtocolV3SubtitleIndex:)`.
3. **The display members do not use `context()`.** `subtitleSearchVisible` / `Enabled` /
   `UnavailableReason` and `availableSecondarySubtitleTracks` are evaluated inside SwiftUI bodies (tvOS info
   HUD, both subtitle panes, `SubtitleSearchMenu`), and `@Observable` makes a body's invalidation set equal to
   whatever those members touch. They therefore read three **narrow** ports — `backendCapabilities()`,
   `activePlaybackSessionId()`, `currentSelectedVersion()` — in the original short-circuit order, instead of
   the whole context, which carries `currentTime` (written 10×/s by the 0.1 s periodic time observer) and
   would have re-run those bodies at that rate. Whatever produces the ports in wave 3 must keep these three
   narrow; `TrackSelectionCoordinatorTests.testDisplayMembersReadOnlyTheNarrowPorts` pins it.
4. **`requestReplan`'s `subtitleIndex` is descriptive only.** `attemptProtocolV3Replan` takes no such
   argument and the view model's producer discards it; the durable write happens through
   `setLastLoadRequestProtocolV3SubtitleIndex`, called immediately before at the single site that has a value.
   A wave-3 producer may start consuming it, but nothing depends on it today.

### 2.8 Engine session + local host — `Engine/PlaybackEngineSession.swift`, `Engine/LocalHLSHost.swift` (wave 2)
```swift
@MainActor final class PlaybackEngineSession {
    let loadID: LoadID
    let plan: ExecutablePlan
    private(set) var backend: any PlaybackBackend            // reused across an in-place replan when reuseEngine == true
    var surfaceBackend: AVPlayerBackend? { backend as? AVPlayerBackend }
    private(set) var transport: PlaybackSourceProxy?
    private(set) var localHost: LocalHLSHost?               // .localHLS only
    let events: AsyncStream<EngineEvent>                     // every element already stamped with loadID by the actor wrapper
    init(loadID:plan:backendFactory:reusing existing: PlaybackEngineSession?)   // existing != nil ⇔ reuseEngine
    func start(startSeconds:) throws; func perform(_ action: RecoveryAction) async; func seek(_ r: SeekRequest)
    func retargetSource(url:headers:) ; func dispose(reason:)
}
final class LocalHLSHost {                                   // inv-3 §4.1–4.5 glue, one value
    init(spec: LoopbackSessionSpec, startSeconds: Double, sessionDirectory: URL, store/server/writer factories…)
    var writer: LoopbackSegmentWriter?; let store: LoopbackSegmentStore; let server: LoopbackSegmentServer
    var vodPlan: LoopbackSegmentPlan?; var baseIndex/headIndex; var coalescer: LoopbackRestartCoalescer; var subtitleTap: LoopbackSubtitleTap?
    func start() async throws -> URL (playlist URL, after first segment)   // startSiloLoopback steps 1–11 + handleFirstSegmentReady's URL choice
    func requestProducerRestart(atSegment:authoritative:)                  // requestVODProducerRestart + coalescer
    func restartWriter(atSegment:recycling:)                               // startSiloLoopbackWriter
    func teardown(keepArtifacts: Bool)                                     // the loopback half of teardownMediaPipeline + session dir disposal
    var onEvent: (EngineEvent) -> Void                                     // writer/store callbacks → events (firstSegmentReady, planResolved, stats, failed…)
}
```
**As built (wave 2a), `LocalHLSHost` differs from the sketch above — 2b/3 plan against these:**
- Plain `final class`, NOT `@MainActor`: the moved bodies are entered from the writer's mux thread and the
  server's resolver queue; per-member isolation is preserved exactly (`requestProducerRestart(atSegmentIndex:authoritative:)`
  and `startWriter(vodBaseIndex:recycledInput:)` are `@MainActor` as their originals were; `start()`, `teardown()`
  and the first-segment handler are non-isolated; every `DispatchQueue.main.async` hop stayed where it was).
- `start()` is synchronous (as `startSiloLoopback` was) and does not return the playlist URL; the URL choice
  (`playlistURLDecision`, incl. the AirPlay external branch and the abandon-handoff fallback) lives in the host
  and is delivered via `onFirstSegmentReady: ((url: URL, playlistName: String, usesExternalURL: Bool)) -> Void`.
  `startWriter(vodBaseIndex:recycledInput:)` replaces the sketch's `restartWriter`; `teardown()` takes no
  argument (`SILO_KEEP_DV_HLS` is read once at init, §7.2). There is no single `onEvent`: the surface is 4 pull
  closures + 3 init closures (`playbackPositionProvider`, `isSourceOutageActive`, `subtitleTap`) + 11 push
  closures, all nil'd by `teardown()`. The first-segment attach gate (`canAttachFirstSegment`) fails closed when
  no gate is installed (reviewer minor, applied post-merge).
- The subtitle tap STAYS backend-owned (source-keyed; deliberately outlives a session so a same-source reanchor
  re-enables instantly); the host pulls it through `subtitleTap: (URL) -> LoopbackSubtitleTap?`. **2b:**
  `PlaybackEngineSession` inherits the same outlives-the-session problem — carry the tap above the session the
  way `carriedVODPlan` carries the plan; do not session-scope it.
- Ownership: `AVPlayerBackend.loopbackHost: LocalHLSHost?` owns the host; the engine session owns it
  transitively through the backend — 2b does not re-parent it. `carriedVODPlan: LocalHLSHost.ResolvedVODPlan?`
  on the backend reproduces the old `loopbackVODPlan`/`loopbackVODPlanSourceURL` survival semantics (seeded
  unfiltered into each new host; refreshed only when a teardown actually retires a host, so native-route loads
  leave it in place). `segmentWriter`/`segmentServer`/`segmentStore` survive as private read-only computed views
  onto the host so every ladder/stats/AirPlay/subtitle reader line is unchanged — those views go away with the
  ladders in 2b. `installLoopbackHostCallbacks(_:)` holds the former writer-callback bodies; the
  `handleFirstSegmentReady` tail (criteria → settle → attach) stays in the backend;
  `performVODStallRecovery` calls `loopbackHost?.requestProducerRestart(atSegmentIndex:authoritative:)`.
- Session guard: every backend-installed closure that mutates backend state guards
  `self.loopbackHost === host` (+ `!isDisposed`) — object identity, no string compares.
  `activeLoopbackSessionID`/`loopbackGeneration` are deleted; the store's `generation:` tag is a process-wide
  static counter on the host (diagnostics-only — reaches only log lines and the stats overlay; replace with a
  UUID-derived value if strict concurrency lands).

**As built (wave 2b), `PlaybackEngineSession` differs from the sketch above — wave 3 plans against these:**
- **Not `@MainActor`.** `PlaybackEngineSession`, the new `Recovery/RecoveryDriver.swift` and the
  `PlaybackBackend` protocol are all plain non-isolated declarations, for exactly the reason `LocalHLSHost` is
  (wave 2a as-built above): every producer that reaches them — `AVPlayerBackend`'s notification observers and
  `RunLoop.main` timers, `PlayerViewModel`, the proxy's callbacks — is itself nonisolated, and every one of
  them already runs on the main queue. Annotating the classes would have forced a hop into each of those
  sites and deferred every in-route recovery decision by a run-loop turn, which is precisely the timing
  invariant (I1, "same action, same order") this wave had to hold. The two `MainActor.assumeIsolated` sites
  reached from `AVPlayerBackend.perform(_:)` — `.restartProducer`'s host call and the post-outage kick inside
  `kickPlaybackAfterOutage` (via the `.endOutageRideThrough` arm) — are the seam where a `@MainActor` body is
  reached from that nonisolated chain; each is fed only by main-queue producers. (The round-2 repair moved the
  other two arms — the watchdog reanchor and the vod-stall reload — back onto `Task { @MainActor }` hops to
  match legacy timing; the two `assumeIsolated` sites in the TV display-criteria path predate this wave.)
  Wave 3's actor cutover is where isolation is re-decided.
- `start(startSeconds:)` is non-throwing (the throw moved up into `ExecutablePlan.init`); `perform(_:)` is
  non-`async`; `dispose` gained `retainingTransport:` for the tvOS suspend (§2.3 as-built item 2's
  `.retainProxy`) and is joined by `disposeEngineOnly(reason:)`, which keeps the session alive as the load's
  recovery owner while the visible server-outage recovery waits out the server.
- No `localHost` property: the host stays owned by `AVPlayerBackend`, so the session owns it transitively
  (wave 2a ownership note above). The source-cache handoff is a shell-held slot, not session state, because
  its value outlives a session by construction.
- The session owns the load's `RecoveryDriver`, so every recovery latch, budget and rolling window is
  load-scoped. Two pieces of state are deliberately *carried* across an in-place replan, because their
  releasers outlive the load exactly as they did before the wave: `context.suspendedReasons` (the latch used
  to live on the reused `AVPlayerBackend` instance) and `context.outage` (the ride-through was view-model
  state, and it is the only thing able to release the `origin_outage` hold). A hold may only be adopted
  together with its releaser.
- **Disclosed divergence (route change during an outage ride-through):** the carry fires only on genuine
  backend reuse (an in-place replan). A route-change replan taken mid-ride-through drops the ride-through with
  its retired backend instead of escalating at the original 90 s deadline, and a still-failing origin then
  restarts the ride-through (fresh budget, fresh `origin_outage` hold) on the new session — legacy's
  view-model-scoped `sourceOutageActive` made re-entry a no-op and kept the original deadline. Worst case is a
  doubled ride-through (~180 s) before the visible recovery appears, on a path that needs the server to answer
  a replan while the origin is down. Full legacy fidelity needs shell-scoped ride-through state — wave 3, same
  bucket as the post-outage-reload suppression window (behavior_changes item 8).

`AVPlayerBackend` after wave 2 keeps: observers, audio session, display criteria, initial-display gate, PiP/AirPlay
policy, seek deadline, buffer policy, subtitle overlay pump, `attachLoopbackItem(url:)`,
`reloadEstablishedLoopbackItem`, and emits `RecoveryObservation`s instead of deciding. The six ladders, their
timers' *decisions* (the `Timer`s stay as observation sources), `activeLoopbackSessionID`/`loopbackGeneration`,
`startSiloLoopback*`, `requestVODProducerRestart`, `vodRestartCoalescer`, `sessionDirectory`/`SILO_KEEP_DV_HLS`,
`pendingLocalLoopbackRecoveryMediaTime`, `loopbackRebuildBudget`, `watchdogReanchor*`, `didEscalateLoopbackStall`,
`lastLocalLoopbackStallRecoveryAt`, `loopbackItemDeath*State`, `loopbackEdgeWatch` and the recovery handshake
API are **deleted** from it.

---

## 3. Waves (each wave = one `player-stage2-fix.js` run; packages in a wave are file-disjoint; waves are sequential and each leaves the tree green on all three schemes with the suite at baseline + added tests)

| Wave | Packages (parallel) | Touches | Behaviour | Est. |
|---|---|---|---|---|
| **1 — seams, types, policies** | 1A `PlaybackBackend` protocol + conformance + `FakePlaybackBackend`; 1B `RecoveryPolicy` + observation/context/action types + table tests; 1C `TrackSelectionCoordinator` extraction; 1D bridge `PlaybackTransport` injection + `SessionIdentity` publication + `stopSession(expected:)` + `FakePlaybackTransport`; 1E control-plane types + `PlaybackReducer` + reducer tests | 1A: `AVPlayerBackend.swift` (conformance line + protocol file) · 1B: new files only · 1C: `PlayerViewModel.swift` + new `Tracks/*` · 1D: `PlaybackSessionBridge.swift` + new · 1E: new files only | identical (1C is a mechanical move; the rest is additive) | 5 implementers + 5 reviewers |
| **2a — LocalHLSHost** | 2a: the loopback lifecycle glue (startSiloLoopback steps 1–11, writer wiring, VOD restart + coalescer, subtitle tap, session dir, the loopback half of teardown) leaves `AVPlayerBackend` for `Engine/LocalHLSHost.swift`; `activeLoopbackSessionID`/`loopbackGeneration` deleted; ladders/handshake untouched | `AVPlayerBackend.swift`, new `Engine/LocalHLSHost.swift`, tests | identical except §7.2 | 1 implementer (max) + 1 reviewer |
| **2b — engine session + one recovery owner** | 2b: backend ladders → `RecoveryObservation`s + `perform(RecoveryAction)`; `RecoveryDriver` (the only runtime caller of `RecoveryPolicy.decide`); `PlaybackEngineSession` owns backend + proxy + host per `LoadID` with one event stream; VM `loadStream/prepareBackend/installBackend/loadBackend/makeCallbacks/applyCallbacks/prepareSourceProxy` retargeted; VM outage ride-through + renewal single-flights fed through the policy; recovery handshake deleted | `AVPlayerBackend.swift`, `PlayerViewModel.swift`, `ControlPlane/PlaybackBackend.swift`, new `Engine/PlaybackEngineSession.swift`, `Recovery/RecoveryDriver.swift`, tests | identical except §7 items 1–3 (+ one extra health probe at the 90 s boundary) | 1 implementer (max) + 1 reviewer; device pass afterwards (§6) |
| **3 — reducer + actor cutover** | 3A `PlaybackSessionActor` runs `PlaybackReducer`; VM load/replan/seek/scene-phase/progress/session-id code replaced by intents + `Presentation` projection; `LoadID`/`SessionIdentity` everywhere; `SeekRequest`; scene-phase tables; legacy VM core deleted | `PlayerViewModel.swift`, `ControlPlane/*`, `Engine/*`, bridge call sites | identical except §7 items 4–6 | 1 implementer (max) + 1 reviewer; device pass (§6) |
| **4 — deletions + test rewrites + docs** | 4A `TrackSelection` model replacing the eight `pending*`; 4B remaining deletions (`[CMP-MEM]`, `SILO_KEEP_DV_HLS` threading leftovers, `hasAttempted*`, dead rungs, `ProtocolV3SidecarRestoreIntent`, 8×200 ms seek retry), the six `PlaybackProtocolV3Tests` rewrites (inv-4 A.5), docs 01–09 truth pass, HANDOFF/backlog | 4A: `Tracks/*` · 4B: rest | identical | 2 + 2 |

Wave 1 landed 2026-08-19 (see the as-built blocks in §2.3/§2.7; the reducer needed four review rounds — split later waves small). Wave 2a landed 2026-08-19 (one implementer + one reviewer, approved with two minors; as-built block above in §2.8). Wave 2b landed 2026-08-19 (one implementer + three review rounds — 8 issues, then 1 major + 5 minors, then approve; the wave-2b as-built block above and §2.3 item 9 are binding). Wave 3 landed 2026-08-20 (one implementer + three review rounds — 8+1 issues, then 2 blockers + 1 major + 3 minors, then one minor applied by the orchestrator; §2.3's wave-3 as-built block is binding; §6 rows 13/14 are the blockers' device paths and run on this tip before the PR is mergeable). Wave 4 landed 2026-08-20 (two packages, both approved first pass; `TrackSelection` as built: single-rung values bare, ladders only via setters, the secondary axis a space-agnostic id carrier). **Stage 2 implementation is complete**; the §6 gate on this tip is what remains before PR #172 is mergeable. (Historical note — the wave-4 specs were drafts that had to be re-anchored (line
numbers, names that wave 1 introduced) by the orchestrator before launch — each later wave's base is the
previous wave's merged tip.

---

## 4. Invariants (every package's reviewer traces these; "equivalent" must be derived from code)

I1. **No behaviour change** on iOS/tvOS/macOS/extensions except §7. Same server calls in the same order; same
    `cmpLog`/`Logger` lines that tests or diagnostics consume (`HostedDiagnosticsAPITests:532` pins the
    `"CMP playback_session_id="` and `"PlaybackSessionBridge session_id="` breadcrumb tags — keep them).
I2. **Identity on every effect.** After wave 3 there is no by-value generation capture, no string session-id
    compare, no `*SessionId` single-flight echo; mutation is `guard identity == current`.
I3. **One owner per policy**; `RecoveryPolicy` is the only place a recovery decision is made; the engine
    session/backend only execute `RecoveryAction`s; the VM never decides recovery.
I4. **The in-place replan keeps the live backend** (tvOS HDMI/criteria): `Effect.loadEngine(reuseEngine: true)`
    → `PlaybackEngineSession(reusing:)` → same `AVPlayerBackend` instance, same audio session, same display
    criteria; callbacks/event stream re-bound to the new `LoadID` (review #1 stays fixed).
I5. **Seeks always have deadlines** (recovery seeks are `SeekRequest`s through the same path), and a new
    `LoadID` structurally drops any outstanding `SeekRequest`.
I6. **Display-criteria ordering, initial-display gate, audio-session serialization, PiP layer binding, AirPlay URL
    rewrite and the `prepareAssetPlayback` ordering are untouched** (inv-3 §4.3/§4.8; HANDOFF layer 8).
I7. **Teardown is complete**: dropping a `PlaybackEngineSession` releases writer/store/server/tap/proxy/timers
    and removes the session directory unless `SILO_KEEP_DV_HLS`; `LoopbackSessionSpecCopyHelperTests`' Mirror guard
    still passes (no new stored property on `LoopbackSessionSpec`).
I8. **Audiobook engine unaffected** (`AudioPlayerViewModel` uses V3 types + `resolvePlayablePlan` only) — build +
    its tests green; Stage 2 may move `resolvePlayablePlan` into the bridge/actor only if both callers move with it.
I9. **Wire contracts unchanged**: V3 request/replan/route-event bodies byte-identical (fixture round-trip tests),
    `local_mutations: []` as today, SiloControl state projection unchanged.
I10. **tvOS focus** untouched (no view code changes beyond VM member renames that keep the same names).

---

## 5. Tests (names binding; "rewrite" = same contract, new entry point; never a silent delete)

Wave 1: `PlaybackReducerTests` (load → preparing → playing; replan while replanning rejected (§11 #22); second
replan intent queued/replaced per reducer rule; seek request dropped on new LoadID (#17/#5); suspend/resume
replay; ended sub-state; exactly one recovery action per failure while replanning (#16)); `RecoveryPolicyTests`
(table test per ladder rung with today's constants — startup S (incl. the backstop-ignores-suspension quirk),
playhead P (all nine rungs incl. precedence), item death D, edge E, stalled X, playlist-unchanged Y incl.
`deferUntilPlay`, auto-resume, rebuild budget exhaustion → `.fail(.loopbackRebuildBudgetExhausted)`, VM ladder
(near-end natural end 8 s/≤1 s; session-missing → background then fresh renewal; premature-source-end → server
outage; offline-only route switches with preconditions), outage ride-through backoff 1→2→4→8 capped at 8 within
90 s, server-outage wait) — with an in-test **oracle** copied from the legacy code where a rung is arithmetic
(the R2 `PlayerErrorClassificationMatrixTests` pattern); `TrackSelectionCoordinatorTests` (applyTrackList pending-ff
order incl. `<0` Off sentinel; appendSidecarTracks restore + forced-sidecar auto-select guard; fuzzy
`TrackSelectionSnapshot` threshold 3; replan-automatic-selection path; suspended-drop guard) — **these are new
coverage for behaviour that had none (inv-2 §6)**; `PlaybackSessionBridgeIdentityTests` (`currentIdentity`
round-trip; `stopSession(expected:)` no-op on superseded identity (§11 #18); `FakePlaybackTransport` drives
start/replan/renew/stop with fixture JSON); `PlaybackBackendProtocolTests` (FakePlaybackBackend smoke).
Wave 2: `PlaybackEngineSessionTests` (FakePlaybackBackend + FakeLocalHLSHost: start/dispose/reuse; event stamping;
`perform(RecoveryAction)` maps to the right backend call), `LocalHLSHostTests` (teardown releases everything;
restart coalescing; playlist URL choice incl. AirPlay external URL).
Wave 3: `PlaybackSessionActorTests` (intents → effects → events end-to-end over fakes: fresh load, in-place replan
(reuseEngine), stale-identity event ignored, stale replan dropped, background renewal, outage ride-through with
kick, scene-phase tables per platform (§11 #23), suspend/resume, dispose cancels all timers), progress reporting.
Wave 4: the six `PlaybackProtocolV3Tests` rewrites (inv-4 A.5) and `TrackSelectionTests` for the enum model.
Existing: the ~15 MECHANICAL RETARGET sites in inv-4 A.0 (the `PlayerViewModel.*`/`AVPlayerBackend.*`/
`PlaybackSessionBridge.*` statics) move with their functions; all other 845 player tests survive unchanged.

---

## 6. Validation gate (P12) — before the PR is considered mergeable after wave 3

Device rows from review §11 on the Living Room Apple TV 4K (gen 2) with the deep-link workflow
(`docs/tvos-player/README.md`; records in `docs/tvos-player/validations/`): **4** (h264/AAC native-direct), **7**
(4K HEVC seek-heavy, reanchor), **14** (native-direct startup failure → exactly one rung-1 then ≤1 rung-2,
selections preserved), **1/3** (DV P7 + TrueHD and HDR10 loopback — the criteria/gate path), **12** (source
expiry → silent renewal), **13** (server restart → ride-through → resume), **16** (macOS background). iPhone
rows 9–10 (PiP, background/Now Playing). Each recorded on the pre-wave-2 build and on the wave-3 tip.

---

## 7. Behaviour differences allowed (listed so they are decisions, not drift)

1. (wave 2) The terminal-start route-event `Task` and similar fire-and-forget reports are started from the
   actor's executor instead of inheriting the caller's actor — same POST, same ordering relative to the throw.
2. (wave 2) `SILO_KEEP_DV_HLS` is read once per `LocalHLSHost` at creation (it is an env var nothing mutates).
3. (wave 2) The startup watchdog, playhead watchdog and edge sampler keep their periods, but run as observation
   sources with no decision logic; telemetry log lines (`[CMP-AVP] loopback playhead state`, `[CMP-MEM]`) keep
   their text.
4. (wave 3) `streamLoadGeneration` is no longer logged (it never was); `LoadID`/`SessionIdentity` are logged on
   the existing `[CMP-ENGINE]`/`[CMP-ROUTE]` lines — additive.
5. (wave 3) The 8 × 200 ms initial-seek retry is replaced by a `SeekRequest` with the existing 15 s deadline.
6. (wave 3) macOS scene phase: still "pause on background" (review row 16 is *recorded*, not changed — changing it
   is a product call).

---

## 8. Out of scope (do not touch)

ISOBoxSurgery, LoopbackSegmentPlan/Cutter, the subtitle renderer and SubtitleSession, writer mux internals,
planner/adapter decisions, V3 wire models, the audiobook engine (beyond I8), NowPlayingController internals,
PictureInPictureCoordinator internals, TVDisplayCriteria/HDRDisplayCriteriaPolicy, the loading-overlay gate
(HANDOFF layer 8), any tvOS focus code, backlog §3.
