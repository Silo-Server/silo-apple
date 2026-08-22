> [!WARNING]
> **Historical pre-AetherEngine archive.** This document describes the removed custom-player architecture or its pre-migration validation model. It is retained for history only and must not be used as current implementation guidance. See the [AetherEngine-only replacement specification](aetherengine-replacement-spec.md).

Repo snapshot date: 2026-04-18 (current working tree)

# Overview And Entrypoints

## 1. Main owners

The tvOS player spans a small set of files:

- [`PlayerView.swift`](../../iosApp/iosApp/Screens/Player/PlayerView.swift)  
  SwiftUI screen shell. Chooses the render surface and installs tvOS remote
  handlers.
- [`PlayerViewModel.swift`](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift)  
  Playback coordinator. Owns the active backend, player state, settings
  application, progress reporting, and cleanup.
- [`PlaybackSessionBridge.swift`](../../iosApp/iosApp/Screens/Player/PlaybackSessionBridge.swift)  
  Talks to the Silo API, picks a version, starts playback sessions, and
  negotiates direct vs HLS delivery.
- [`NowPlayingController.swift`](../../iosApp/iosApp/Screens/Player/NowPlayingController.swift)  
  Bridges the current backend into `MPNowPlayingInfoCenter` and
  `MPRemoteCommandCenter`.

The view model's key abstraction is:

- `ActivePlayer.coreMedia(PlayerCore)`
- `ActivePlayer.avPlayer(AVPlayerBackend)`

On iOS/tvOS, the view model still initializes with `.coreMedia(PlayerCore)`,
but the actual playback route now lives in `PlaybackExecutionPlan`. The first
real load can stay on CompatibilityPlayer, move allowlisted direct assets onto
NativePlayer Direct, choose the gated NativePlayer HLS route, or hand off to
SiloPlayer for local normalized Dolby Vision playback. On macOS, the shared view
model stays on an AVPlayer-backed route.

## 2. Startup flow

The live startup sequence is:

1. `PlayerView.onAppear` calls `viewModel.loadAndPlay(...)`.
2. `PlayerViewModel.loadAndPlay(...)` attaches `NowPlayingController` command
   handlers that dispatch through `activePlayer`.
3. The view model calls `PlaybackSessionBridge.startSession(...)`.
4. `PlaybackSessionBridge`:
   - fetches `/api/v1/watch/{contentId}`
   - selects a version from `WatchDetail.versions`
   - builds a flat `StartPlaybackRequest`
   - posts `/api/v1/playback/start`
   - if the server chose `remux` or `transcode`, posts
     `/api/v1/playback/transcode/start`
5. The view model turns the returned `streamUrl` into an absolute URL, adds a
   Bearer token header if one exists, builds a `PlaybackExecutionPlan`, and
   loads the route selected by that plan.

Two details matter:

- For `remux`, the player starts at `0` because the generated manifest is
  already anchored to the requested stream origin.
- For `transcode` and direct-play style paths, the execution plan starts from
  `session.position`, which already carries the server-resolved start point.

## 3. Delivery negotiation

`PlaybackSessionBridge` currently sends:

- `fileId`
- `profileId`
- `audioTrackIndex`
- video/audio codec lists
- container list
- optional `maxResolution`
- `hdr`

On real devices the capability lists are broad: `h264`, `hevc`, `av1`, `vp9`,
`vp8`, `mpeg4`, `mpeg2video` for video; common compressed and PCM variants for
audio; and containers including `mkv`, `mp4`, `mov`, `m4v`, `webm`, `avi`,
`ts`, and `m2ts`. On simulator, the bridge clamps itself down to a safer
`h264`/`1080p` subset.

Important current truth: the bridge still contains stale `libmpv` wording in
its comments, but the executable behavior today is backend-agnostic session
bootstrap for `PlayerCore` / `AVPlayerBackend`.

## 4. Metadata and state flow back to UI

The view model wires a shared callback surface into whichever backend is active.
Those callbacks drive:

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

## 5. Backend switching

Route switching is now split into two layers:

1. `makeExecutionPlan(...)` chooses the initial route from the resolved
   playback session plus route requirements.
2. `installPlayer(for:)` instantiates the matching backend and re-attaches the
   shared callback surface.
3. `PlayerCore.onUnsupportedStream` can still force a runtime handoff into
   SiloPlayer.
4. A NativePlayer Direct failure now recovers back to CompatibilityPlayer direct
   rather than terminating playback immediately.

So the route model is no longer "always start on PlayerCore and maybe flip once
for Profile 5." The load path carries typed route data all the way through.

## 6. Teardown and lifecycle

`PlayerView.onDisappear` calls `viewModel.cleanup()`, which:

- marks the VM disposed
- cancels the overlay timer and progress task
- detaches Now Playing handlers
- disposes the active backend
- sends a final stop request through `PlaybackSessionBridge.stopSession(...)`

Separately, tvOS scene transitions now split into two paths:

- `.inactive`: transient interruption only; pause the active backend and allow
  quick foreground recovery if the player was already running
- `.background`: hard suspend; snapshot resume context, stop the server
  playback session, unbind realtime control, detach Now Playing, dispose the
  backend, and wait for an explicit user resume after wake

The player route stays mounted after a background suspend. Playback does not
auto-resume on wake, and tvOS Picture in Picture is currently unsupported.

## 7. Current truths and caveats

- `PlayerCore` auto-starts playback from `load(...)`; the UI does not call
  `play()` after a successful load.
- `PlaybackSessionBridge` chooses the version and server session before any
  local decoder setup begins.
- The bridge only sends `audioTrackIndex` to `/playback/start`; subtitle
  preference is re-applied locally later if a matching embedded subtitle track
  appears.
- Cleanup deletes the server playback session even though the player UI itself
  has already been torn down locally.

## Validation log

- verified: startup begins in `PlayerView.onAppear` and not in the tvOS HUD
  layer.
- verified: the view model owns route planning and runtime backend switching;
  `PlayerCore` only reports the rejection.
- corrected: `PlaybackSessionBridge` comments still say "libmpv" in several
  places, but the live session/bootstrap path is the shared Apple player stack.
