Last verified against the code: 2026-08-20

# Overview And Entrypoints

## 1. Main owners

The Apple player spans a small set of files:

- [`PlayerView.swift`](../../iosApp/iosApp/Screens/Player/PlayerView.swift)
  SwiftUI screen shell. Chooses the render surface and installs tvOS remote
  handlers.
- [`PlayerViewModel.swift`](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift)
  The presentation shell. Projects the control plane's `Presentation` value
  onto the members the views read, forwards view commands as `PlayerIntent`s
  through `send(_:)`, and owns the *presentation* half of playback: settings
  application, overlays and notices, Now Playing, next-up, and cleanup. It
  decides no playback policy.
- [`ControlPlane/PlaybackSessionActor.swift`](../../iosApp/iosApp/Screens/Player/ControlPlane/PlaybackSessionActor.swift)
  The control plane. Holds `PlaybackState`, is the only caller of
  `PlaybackReducer`, and runs the reducer's `[Effect]` with every effect
  conditional on the `LoadID` / `SessionIdentity` it carries.
- [`ControlPlane/PlaybackReducer.swift`](../../iosApp/iosApp/Screens/Player/ControlPlane/PlaybackReducer.swift)
  Pure `(PlaybackState, PlayerIntent | PlayerEvent) → (PlaybackState, [Effect])`.
  Every load / seek / replan / scene-phase decision is here.
- [`Recovery/RecoveryPolicy.swift`](../../iosApp/iosApp/Screens/Player/Recovery/RecoveryPolicy.swift)
  The one recovery decision owner — every in-route ladder rung, the failure
  ladder, the origin-outage ride-through and the server-outage wait, with
  their constants. `Recovery/RecoveryDriver.swift` is its only runtime caller,
  one per load.
- [`Engine/PlaybackEngineSession.swift`](../../iosApp/iosApp/Screens/Player/Engine/PlaybackEngineSession.swift)
  One engine session per `LoadID`: it owns the backend adapter, the source
  proxy, the load's `RecoveryDriver`, and a single ordered `EngineEvent`
  stream. Disposing it *is* the teardown.
- [`AVPlayerRoute/AVPlayerBackend.swift`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift)
  The one and only backend, and now only an AVFoundation adapter: items and
  observers, display criteria, the initial-display gate, audio session,
  PiP/AirPlay, seek deadlines, the subtitle plane. It reports
  `RecoveryObservation`s where the ladders used to decide.
- [`Engine/LocalHLSHost.swift`](../../iosApp/iosApp/Screens/Player/Engine/LocalHLSHost.swift)
  The loopback lifecycle as one value: segment store, loopback HTTP server,
  the producing writer and its demand-driven restarts, and the session
  directory. The backend owns exactly one live host.
- [`PlaybackSessionBridge.swift`](../../iosApp/iosApp/Screens/Player/PlaybackSessionBridge.swift)
  Talks to the Silo API, picks a version, starts playback sessions, mints the
  `SessionIdentity`, and negotiates direct vs HLS delivery.
- [`Tracks/TrackSelectionCoordinator.swift`](../../iosApp/iosApp/Screens/Player/Tracks/TrackSelectionCoordinator.swift)
  The audio/subtitle track half behind `TrackSelectionPorts`. The view model
  forwards to it; the views keep reading the same member names.
- [`NowPlayingController.swift`](../../iosApp/iosApp/Screens/Player/NowPlayingController.swift)
  Bridges the current backend into `MPNowPlayingInfoCenter` and
  `MPRemoteCommandCenter`.

There is still no engine *abstraction* in the old sense — no second decode
core to select. `PlaybackBackend` is a protocol only so the control-plane
tests can drive a fake; `AVPlayerBackend` is its one production conformance,
constructed on every platform and for every `PlaybackEngineKind`. What the
view model holds is not the backend but the load's engine session:
`private(set) var engineSession: PlaybackEngineSession?`, with
`avPlayerBackend` a computed forwarder (`engineSession?.surfaceBackend`) for
the view surface and the settings appliers.

## 2. Startup flow

1. `PlayerView.onAppear` calls `viewModel.loadAndPlay(...)`.
2. `PlayerViewModel.loadAndPlay(...)` builds a `LoadRequest` and sends
   `PlayerIntent.load(request, origin: .userInitiated, options:)` to the
   session actor. Nothing about the load is decided in the view model.
3. The reducer answers with `Effect.startSession(request, options, LoadID)`;
   the actor runs it, which calls
   `PlaybackSessionBridge.startSession(...)` (or the offline builder).
4. `PlaybackSessionBridge`:
   - fetches `/api/v1/watch/{contentId}`
   - selects a version from `WatchDetail.versions`
   - builds the client capability payload
   - posts `/api/v1/playback/start`
   - if the server chose `remux` or `transcode`, posts
     `/api/v1/playback/transcode/start`
5. Still inside that effect, the shell turns the returned `streamUrl` into an
   absolute URL, adds a Bearer token header if one exists, and builds a
   `PlaybackExecutionPlan` through
   `ApplePlaybackRoutePlanner.makeExecutionPlan(input:)` (plan-building is
   adapter work, not reducer work). The prepared result comes back as
   `SessionEvent.prepared`, and the reducer answers with
   `Effect.loadEngine(plan, LoadID, reuseEngine:)` — that is what actually
   starts the engine.

Two details matter:

- For `remux`, `startMode` is `.startOfManifest` (seek target 0) because the
  generated manifest is already anchored to the requested stream origin.
- Everything else uses `.absolutePosition(session.position)`, which already
  carries the server-resolved start point.

## 3. Delivery negotiation

Client decode capability is stated once, in
[`AppleDecodeCapabilities`](../../iosApp/iosApp/Shared/AppleDecodeCapabilities.swift),
and consumed by all three reporting surfaces (the V3 capability snapshot in
[`ApplePlaybackV3Capabilities.swift`](../../iosApp/iosApp/Screens/Player/ProtocolV3/ApplePlaybackV3Capabilities.swift),
the playback bootstrap in `PlaybackSessionBridge.makeClientCaps`, and download
creation).

Current truth, and a common source of confusion:

- Advertised **video codecs are `h264` and `hevc` only** (`h264` alone on
  simulator), which is also everything the loopback can execute. The
  on-device video bridge that once played AV1/VP9/MPEG-2/VC-1 locally was
  retired on 2026-08-17 precisely because it was never advertised and so was
  never reachable (see [09](09-video-bridge.md)).
- Advertised **video containers** are `mp4`, `mov`, `m4v`, `mkv`, `matroska`,
  `webm`, `avi`, `ts`, `m2ts`, `mpegts` on device (no `webm`/`avi` on
  simulator), with both spellings of the aliased pairs so a scanner-recorded
  token always matches.
- Simulator clamps to `1080p` / `maxDecodeHeight = 1080`.

## 4. Metadata and state flow back to UI

The backend's callbacks are wired by the engine session, not by the view
model, and they do not write UI state. Each one emits an `EngineEvent` on the
session's single ordered stream; the session actor reduces it and answers with
`Effect.publish(Presentation)` — the only path to UI state. `Presentation`
carries:

- `currentTime`, `duration`, `isPlaying`, `isBuffering`
- `bufferedAheadSeconds`, `playbackRunwaySeconds`, `playbackStats`
- `isLoading` (three-valued: `nil` means "this publish owns no overlay
  decision"), `loadingReason`, `bufferingCause`
- `hasEnded`, `isBackgroundSuspended`, `isReconnecting`
- `activeQualityId`, `isQualitySwitching`, `metadata`
- `serverSessionId` (the one session-id mirror the shell still needs, for the
  SiloControl projection and the subtitle-AI gate)
- terminal `error`

`PlayerViewModel.applyPresentation(_:transportOnly:)` copies it onto the
published members the views read. Track lists and chapters stay off
`Presentation`: they ride the same event stream as `.tracks` / `.chapters` and
land in `TrackSelectionCoordinator` and the chapter list through
`applyEngineEventToPresentation`.

Secondary overlay metadata does not come from a second API call. It is derived
from the already-fetched `WatchDetail` and chosen `FileVersion` through
`PreparedPlayback.playerMetadata(...)`.

Alongside that:

- the view model applies player settings when the load reports its file loaded
- the reducer schedules the progress heartbeat on its own timer
  (`TimerID.progress`, `PlaybackReducer.progressReportIntervalSeconds = 10`),
  and the actor runs it as `Effect.reportProgress(SessionIdentity, …)`
- the view model updates Now Playing state, rate-limited to one push every
  2 seconds

## 5. Route selection

Route selection lives entirely in
[`ApplePlaybackRoutePlanner.swift`](../../iosApp/iosApp/Screens/Player/ApplePlaybackRoutePlanner.swift)
and produces a typed `PlaybackExecutionPlan`. For a `direct` delivery the order
is:

1. **Dolby Vision claims the session first.** If the source carries DV profile
   5, 7, or 8 *and* a loopback session spec resolves, the engine is
   `siloPlayerLoopback` with the DV-specific `VideoMode`
   (`passthroughProfile5`, `convertProfile7To81`, or
   `passthroughProfile8(baseLayer)`), gated by the user's
   [`DolbyVisionPolicy`](../../iosApp/iosApp/Screens/Player/DolbyVisionPolicy.swift)
   snapshot.
2. **Native direct**, when `assessNativeDirectRoute` finds no blockers: the
   container is `mp4`/`mov`/`m4v`, video is `h264`/`hevc`, audio is
   `aac`/`ac3`/`eac3`/`alac`/`mp3`, every embedded subtitle codec is in the
   native allowlist, and the route's capability contract satisfies the
   requirements. `reason = native_direct_asset`.
3. **SiloPlayer loopback**, when `assessSiloRoute` is eligible. That assessment
   resolves the video output mode (always `.copy` since the bridge tier was
   retired — see [09](09-video-bridge.md)), checks the container against the
   copy allowlists, checks subtitles, and resolves the audio bridge mode.
4. **Terminal rung.** If native direct is blocked and the Silo assessment is
   not eligible, the planner still takes `siloPlayerLoopback` when a loopback
   session spec exists at all (`native_direct_blocked_silo_fallback`);
   otherwise it lands on `avPlayerHLS`
   (`native_direct_blocked_hls_fallback`) so the server can produce the
   stream.

`remux` and `transcode` deliveries go straight to `avPlayerHLS` with
`reason = apple_hls_route_enabled`. This is unconditional: no feature flag
gates the HLS route, and the vestigial flag plumbing has been removed.

Every decision emits a trace. Useful tokens: `delivery_direct`,
`container_<x>`, `video_<x>`, `silo_container_<x>`, `silo_video_<x>`,
`silo_vod_gate_open`, `silo_eligible`,
`silo_reason_<reason>`, `silo_blocker_<blocker>`, and one of
`fallback_order_native_silo_hls` / `fallback_order_silo_hls` /
`fallback_order_hls_controlled_retry`.

## 6. The fallback ladder

Because there is only one engine, runtime recovery is about re-pointing
AVPlayer. The *decision* is `RecoveryPolicy.decideEngineFailed`'s bottom two
rungs — the only place the ladder exists — and the view model merely executes
what comes back as a `RecoveryAction.switchRoute`:

1. **Native direct fails → SiloPlayer loopback.** Rung 9. Fires only when the
   route is `avPlayerNativeDirect`, the load has not already used its one
   native-direct fallback (`RecoveryContext.attemptedNativeDirectFallback`),
   and a loopback plan can actually be built
   (`RecoveryContext.canBuildLoopbackFallback`, answered by the shell's
   `makeNativeDirectLoopbackFallbackPlan`). The executor,
   `performNativeDirectLoopbackFallback`, rebuilds that plan through
   `makeLoopbackFallbackPlan(...)` (`reason =
   native_direct_avplayer_failed_silo_fallback`, trace
   `fallback_silo_loopback_after_native_direct`), preserving the current
   position and the audio/subtitle selections, and reloads the engine in place
   inside the same server session. If no loopback plan exists, the same rung
   goes straight to server HLS with trace `native_direct_blocked_hls_fallback`.
2. **SiloPlayer loopback fails → server HLS.** Rung 10. Fires when the route is
   `siloPlayerLoopback`, the load has not used its one loopback-HLS fallback
   (`RecoveryContext.attemptedLoopbackHLSFallback`), a watch detail exists and
   no replan is already in flight. It becomes
   `.switchRoute(.serverHLS(classification: "silo_loopback_failed"))`, which
   the reducer turns into a protocol-V3 replan; `performServerHLSRouteFallback`
   only writes the `fallback_hls_after_silo` trace.

The one-shot latches live on the load's `RecoveryContext`, set by the policy
as it returns the action, so they are load-scoped by construction — the old
`hasAttempted*` fields on the view model are gone.

The executor's comment states the principle directly: "Every remaining engine
is AVPlayer-backed, so 'fall back' now means renegotiating the session with the
server rather than swapping in another local decoder."

Loopback writer failures that reach this rung include
`LoopbackWriterError.bootstrapFailed`, `.profile5ConfigUnusable`, `.vodMoovBlocked`, and
`.prematureSourceEnd` (see
[`LoopbackSegmentWriter.swift`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/LoopbackSegmentWriter.swift)).

An in-place replan keeps the live backend. The reducer emits
`Effect.loadEngine(plan, loadID, reuseEngine: true)`, the shell builds the
replacement `PlaybackEngineSession` with the outgoing one passed as `reusing:`,
and the *same* `AVPlayerBackend` instance carries over with its audio session
and its negotiated tvOS display criteria — only the callbacks and the event
stream re-bind to the new `LoadID`. That is what keeps an audio-track change on the
loopback route from renegotiating HDMI around the replacement item.

## 7. Teardown and lifecycle

`PlayerView.onDisappear` calls `viewModel.cleanup()`, which:

- marks the VM disposed
- cancels the shell's UI timers and tasks (`tasks.cancelAll(in: .teardown)`)
- detaches Now Playing handlers, cancels the sleep timer, resets the track
  selection
- shuts the control plane down (`PlaybackSessionActor.shutdown()`), which
  cancels every control-plane timer and the engine-event loop
- disposes the load's engine session (`engineSession?.dispose(reason:)`) and
  drops the reference
- sends a final stop request through `PlaybackSessionBridge.stopSession(...)`
  in a detached completion task, unless the load was an offline download

Dropping the engine session *is* the teardown: it disposes the backend (which
tears the AVPlayer item down, tears down its `LocalHLSHost` — writer, store,
server, session directory — and releases the tvOS display criteria), stops the
source proxy, and cancels the load's timers. The view model no longer
hand-resets the load's playback fields; the backend's own `dispose()` still
clears its per-item state (selection state, track lists, the display gate).

Scene transitions are `PlayerIntent.scenePhase(phase)`, reduced against the
reducer's per-platform scene-phase table. The shell resolves only what it
alone can know before forwarding (on iOS, whether an automatic PiP that has not
yet published `willStart` should hold the background off). The two outcomes:

- `.inactive`: transient interruption only; pause and allow quick foreground
  recovery if the player was already running
- `.background`: hard suspend; snapshot resume context, stop the server
  playback session, unbind realtime control, detach Now Playing, dispose the
  engine while *keeping* the source proxy
  (`SourceCacheDisposition.retainProxy`), and wait for an explicit user resume
  after wake

The player route stays mounted after a background suspend. Playback does not
auto-resume on wake, and tvOS Picture in Picture is unsupported.

## 8. Current truths and caveats

- `PlaybackSessionBridge` chooses the version and server session before any
  local loopback setup begins.
- The bridge only sends `audioTrackIndex` to `/playback/start`; subtitle
  preference is re-applied locally later if a matching embedded subtitle track
  appears.
- Cleanup deletes the server playback session even though the player UI itself
  has already been torn down locally.
- The `siloPlayerLoopback` route serves a static VOD plan and nothing else.
  `LoopbackSegmentWriter.emitMediaPlaylist` writes every planned segment up
  front with `#EXT-X-PLAYLIST-TYPE:VOD` and `#EXT-X-ENDLIST`, and the body
  never changes across a session. A session that cannot resolve a plan, or
  whose keyframe index is not trustworthy, fails closed:
  `resolveVODPlanIfNeeded` throws
  `LoopbackWriterError.bootstrapFailed("vod_plan_unavailable")` or
  `bootstrapFailed("vod_plan_untrusted_keyframe_index")`, which is a writer
  failure like any other — the ladder replans, normally onto `avPlayerHLS`.
  History: the explicit EVENT serving mode and the
  `player.apple.siloplayer_primary_enabled` kill switch were retired on
  2026-08-17 (the key is no longer read), taking the planner blockers that only
  existed when the gate was off (`h264_loopback_startup_unreliable`,
  `hevc_sdr_loopback_startup_unreliable`, `video_bridge_requires_vod_plan`)
  with them; the writer's internal growing-EVENT degrade followed on
  2026-08-20, which is what closed the mismatch between a plan-less session and
  the engine session's VOD wiring (retention/pruning, in-item-only seeks,
  VOD-sized runway). `LocalHLSPlaylistPolicy.playlistType(isFinal:)` and its
  `.liveSliding` case are the last residue and have no production caller.

## Validation log

- verified: startup begins in `PlayerView.onAppear`, not in the tvOS HUD layer.
- corrected (2026-08-20): this file described the writer as still degrading to
  a growing EVENT playlist when it could not build a safe VOD plan, and called
  the resulting VOD/EVENT wiring mismatch a live gap. Neither survives:
  `emitMediaPlaylist` is the only media-playlist emitter and is VOD-only, and
  `resolveVODPlanIfNeeded` throws instead of degrading.
- corrected (2026-08-18): `ActivePlayer` and `PlaybackCoordinator` no longer
  exist (collapsed in `e458784`); `PlayerViewModel` holds an optional
  `AVPlayerBackend`. There is still no `PlayerCore` type in the tree.
- verified: the fallback ladder is native-direct → loopback → server HLS
  replan, each rung guarded by a one-shot latch.
- corrected (2026-08-20): the control plane moved out of `PlayerViewModel`.
  `PlaybackSessionActor` holds `PlaybackState` and runs `PlaybackReducer`;
  `RecoveryPolicy`/`RecoveryDriver` own every recovery decision;
  `PlaybackEngineSession` owns the backend + source proxy per `LoadID`;
  `LocalHLSHost` owns the loopback lifecycle; `TrackSelectionCoordinator` owns
  the track half. `installBackend(for:)` / `prepareBackend(for:)` /
  `loadStream(...)` and the three generation counters are gone — identity is
  `LoadID` / `SessionIdentity` on every effect.
- corrected (2026-08-20): the ladder's one-shot flags are
  `RecoveryContext.attemptedNativeDirectFallback` /
  `attemptedLoopbackHLSFallback` on the load's recovery context, not
  `hasAttemptedNativeDirectRouteRecovery` / `hasAttemptedSiloRouteHLSFallback`
  on the view model. Those fields no longer exist.
- corrected (2026-08-20): backend callbacks no longer write UI state. They emit
  `EngineEvent`s that the session actor reduces; `Effect.publish(Presentation)`
  is the only path to the published members.
- corrected (2026-08-20): the initial resume seek no longer retries itself
  8 × 200 ms. Its 15 s seek deadline is the whole budget, and the item's
  `seekableTimeRanges` / `loadedTimeRanges` observers re-enter
  `attemptInitialPlaybackStart` while the load has not landed its start point.
- corrected: earlier revisions said the load path "can stay on
  CompatibilityPlayer" and that `PlayerCore.onUnsupportedStream` could force a
  runtime handoff. Both the type and that handoff are gone; decode-time
  `StreamRejection` recovery was retired with it.
- corrected: earlier revisions listed `av1`, `vp9`, `vp8`, `mpeg4`, and
  `mpeg2video` as advertised client video codecs. `AppleDecodeCapabilities`
  advertises `h264` and `hevc` only.
- corrected: the stale `libmpv` comments in `PlaybackSessionBridge.swift` and
  `PlayerViewModel.swift` no longer exist.
