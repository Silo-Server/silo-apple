Repo snapshot date: 2026-08-16 (branch `player/one-player-cleanup`, HEAD `6818819`)

# Overview And Entrypoints

## 1. Main owners

The Apple player spans a small set of files:

- [`PlayerView.swift`](../../iosApp/iosApp/Screens/Player/PlayerView.swift)
  SwiftUI screen shell. Chooses the render surface and installs tvOS remote
  handlers.
- [`PlayerViewModel.swift`](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift)
  Playback coordinator. Owns route planning, player state, settings
  application, the fallback ladder, progress reporting, and cleanup.
- [`PlaybackCoordinator.swift`](../../iosApp/iosApp/Screens/Player/PlaybackCoordinator.swift)
  Owns the active `PlaybackEngine` and centralizes route installation.
- [`AVPlayerBackend.swift`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift)
  The one and only backend. Loads a plan onto `AVPlayer`, and for the
  SiloPlayer route also stands up the local loopback (writer, store, server).
- [`PlaybackSessionBridge.swift`](../../iosApp/iosApp/Screens/Player/PlaybackSessionBridge.swift)
  Talks to the Silo API, picks a version, starts playback sessions, and
  negotiates direct vs HLS delivery.
- [`NowPlayingController.swift`](../../iosApp/iosApp/Screens/Player/NowPlayingController.swift)
  Bridges the current backend into `MPNowPlayingInfoCenter` and
  `MPRemoteCommandCenter`.

The view model's engine abstraction is now trivial:

```swift
enum ActivePlayer: @unchecked Sendable {
    case none
    case avPlayer(AVPlayerBackend)
}
```

`PlaybackCoordinator.installEngine(for:)` only ever constructs an
`AVFoundationPlayerEngine` wrapping an `AVPlayerBackend`, on every platform and
for every `PlaybackEngineKind`. There is no second decode core to select.

## 2. Startup flow

1. `PlayerView.onAppear` calls `viewModel.loadAndPlay(...)`.
2. `PlayerViewModel.loadAndPlay(...)` attaches `NowPlayingController` command
   handlers that dispatch through `activePlayer`.
3. The view model calls `PlaybackSessionBridge.startSession(...)`.
4. `PlaybackSessionBridge`:
   - fetches `/api/v1/watch/{contentId}`
   - selects a version from `WatchDetail.versions`
   - builds the client capability payload
   - posts `/api/v1/playback/start`
   - if the server chose `remux` or `transcode`, posts
     `/api/v1/playback/transcode/start`
5. The view model turns the returned `streamUrl` into an absolute URL, adds a
   Bearer token header if one exists, builds a `PlaybackExecutionPlan` through
   `ApplePlaybackRoutePlanner.makeExecutionPlan(input:)`, and loads it.

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
  simulator). The client does not claim AV1/VP9/MPEG-2/VC-1 to the server even
  though the loopback's video bridge can now play them — the bridge is a local
  normalization capability, not a decode claim the server should plan against.
- Advertised **video containers** are `mp4`, `mov`, `m4v`, `mkv`, `matroska`,
  `webm`, `avi`, `ts`, `m2ts`, `mpegts` on device (no `webm`/`avi` on
  simulator), with both spellings of the aliased pairs so a scanner-recorded
  token always matches.
- Simulator clamps to `1080p` / `maxDecodeHeight = 1080`.

## 4. Metadata and state flow back to UI

The view model wires a shared callback surface into the backend. Those
callbacks drive:

- `currentTime`
- `duration`
- `isPlaying`
- `isBuffering`
- `audioTracks`
- `subtitleTracks`
- `chapters`
- `bufferedAheadSeconds`
- terminal `error`

Secondary overlay metadata does not come from a second API call. It is derived
from the already-fetched `WatchDetail` and chosen `FileVersion` through
`PreparedPlayback.playerMetadata(...)`.

The view model also:

- applies player settings on `onFileLoaded`
- starts periodic progress reporting every 10 seconds
- updates Now Playing state, rate-limited to one push every 2 seconds

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
   resolves the video output mode (copy / bridge / AV1 passthrough — see
   [09](09-video-bridge.md)), checks the container against the tier that mode
   unlocks, checks subtitles, and resolves the audio bridge mode.
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
`silo_video_bridge_hevc`, `silo_vod_gate_open`, `silo_eligible`,
`silo_reason_<reason>`, `silo_blocker_<blocker>`, and one of
`fallback_order_native_silo_hls` / `fallback_order_silo_hls` /
`fallback_order_hls_controlled_retry`.

## 6. The fallback ladder

Because there is only one engine, runtime recovery is about re-pointing
AVPlayer, and it is a strict two-step ladder in `PlayerViewModel`:

1. **Native direct fails → SiloPlayer loopback.**
   `attemptNativeDirectRouteRecovery(after:)` builds a loopback plan from the
   *same* source stream request via `makeLoopbackFallbackPlan(...)`
   (`reason = native_direct_avplayer_failed_silo_fallback`,
   trace `fallback_silo_loopback_after_native_direct`), preserving the current
   position and the audio/subtitle selections. Guarded by
   `hasAttemptedNativeDirectRouteRecovery` so it fires at most once.
   If no loopback session can be built, it goes straight to step 2 with
   trace `native_direct_blocked_hls_fallback`.
2. **SiloPlayer loopback fails → server HLS.**
   `attemptSiloRouteHLSFallback(after:)` calls `requestServerHLSRouteFallback`,
   which triggers a protocol-V3 replan (`attemptProtocolV3Replan`) with
   classification `silo_loopback_failed` and trace `fallback_hls_after_silo`.
   Guarded by `hasAttemptedSiloRouteHLSFallback`.

The method comment states the principle directly: "Every remaining engine is
AVPlayer-backed, so 'fall back' now means renegotiating the session with the
server rather than swapping in another local decoder."

Loopback writer failures that reach this rung include
`LoopbackWriterError.videoBridgeTooSlow`, `.videoTranscodeSetup`,
`.bootstrapFailed`, `.profile5ConfigUnusable`, `.vodMoovBlocked`, and
`.prematureSourceEnd` (see
[`LoopbackSegmentWriter.swift`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/LoopbackSegmentWriter.swift)).

`PlaybackCoordinator.prepareEngine(for:)` deliberately *reuses* an already
installed engine when the route kind is unchanged, so an in-place replan (an
audio-track change on the loopback route, for instance) keeps the audio session
and the negotiated tvOS display criteria instead of renegotiating HDMI around
the replacement item.

## 7. Teardown and lifecycle

`PlayerView.onDisappear` calls `viewModel.cleanup()`, which:

- marks the VM disposed
- cancels the overlay timer and progress task
- detaches Now Playing handlers
- disposes the active engine through `PlaybackCoordinator.dispose()`, which
  tears down the AVPlayer item, the loopback writer/store/server, and releases
  the tvOS display criteria
- sends a final stop request through `PlaybackSessionBridge.stopSession(...)`

Scene transitions split into two paths:

- `.inactive`: transient interruption only; pause the active backend and allow
  quick foreground recovery if the player was already running
- `.background`: hard suspend; snapshot resume context, stop the server
  playback session, unbind realtime control, detach Now Playing, dispose the
  backend, and wait for an explicit user resume after wake

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
- The `siloPlayerLoopback` route always serves the static VOD plan. The legacy
  growing EVENT playlist and the `player.apple.siloplayer_primary_enabled` kill
  switch were retired on 2026-08-17 (the key is no longer read), and with them
  the planner blockers that only existed when the gate was off
  (`h264_loopback_startup_unreliable`, `hevc_sdr_loopback_startup_unreliable`,
  `video_bridge_requires_vod_plan`).

## Validation log

- verified: startup begins in `PlayerView.onAppear`, not in the tvOS HUD layer.
- verified: `ActivePlayer` is `{none, avPlayer}` and `PlaybackCoordinator`
  builds only `AVFoundationPlayerEngine`; there is no `.coreMedia` case and no
  `PlayerCore` type in the tree.
- verified: the fallback ladder is native-direct → loopback → server HLS
  replan, each rung guarded by a one-shot flag on the view model.
- corrected: earlier revisions said the load path "can stay on
  CompatibilityPlayer" and that `PlayerCore.onUnsupportedStream` could force a
  runtime handoff. Both the type and that handoff are gone; decode-time
  `StreamRejection` recovery was retired with it.
- corrected: earlier revisions listed `av1`, `vp9`, `vp8`, `mpeg4`, and
  `mpeg2video` as advertised client video codecs. `AppleDecodeCapabilities`
  advertises `h264` and `hevc` only.
- corrected: the stale `libmpv` comments in `PlaybackSessionBridge.swift` and
  `PlayerViewModel.swift` no longer exist.
