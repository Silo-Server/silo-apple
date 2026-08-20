Last verified against the code: 2026-08-20

# tvOS Video Player Documentation

This suite documents the **actual tvOS player implementation** in the current
`silo-apple` working tree. It is intentionally code-grounded: the source of
truth is the live player code under
[`iosApp/iosApp/Screens/Player`](../../iosApp/iosApp/Screens/Player), not older
plan documents or stale comments.

## One AVPlayer family, three routes

The player used to be a hybrid of a hand-rolled FFmpeg/VideoToolbox decode core
(`PlayerCore` / "CompatibilityPlayer") and an AVPlayer stack. That is over.
`PlayerCore` was deleted; **every** playback route is now `AVPlayer` behind
[`AVPlayerBackend.swift`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift).
The backend is owned per load by a
[`PlaybackEngineSession`](../../iosApp/iosApp/Screens/Player/Engine/PlaybackEngineSession.swift)
(the old `ActivePlayer`/`PlaybackCoordinator` abstraction was collapsed in
`e458784`, and the view model's own `installBackend`/`prepareBackend` pair went
with the control-plane extraction).

## Who owns what

Playback is a control plane plus an execution plane:

| Concern | Owner |
| --- | --- |
| Playback state and every load/seek/replan/scene-phase decision | [`PlaybackReducer`](../../iosApp/iosApp/Screens/Player/ControlPlane/PlaybackReducer.swift) (pure), run by [`PlaybackSessionActor`](../../iosApp/iosApp/Screens/Player/ControlPlane/PlaybackSessionActor.swift) |
| Every recovery decision, and only there | [`RecoveryPolicy`](../../iosApp/iosApp/Screens/Player/Recovery/RecoveryPolicy.swift) (pure), reached only through the load's [`RecoveryDriver`](../../iosApp/iosApp/Screens/Player/Recovery/RecoveryDriver.swift) |
| The backend, the source proxy and the load's recovery driver, per `LoadID` | [`PlaybackEngineSession`](../../iosApp/iosApp/Screens/Player/Engine/PlaybackEngineSession.swift) |
| AVFoundation itself: items, observers, display criteria, audio session, PiP/AirPlay, seek deadlines, subtitles | [`AVPlayerBackend`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift) |
| The loopback pipeline's lifecycle: store, server, writer, restarts, session directory | [`LocalHLSHost`](../../iosApp/iosApp/Screens/Player/Engine/LocalHLSHost.swift) |
| The server playback session and `SessionIdentity` | [`PlaybackSessionBridge`](../../iosApp/iosApp/Screens/Player/PlaybackSessionBridge.swift) |
| Audio/subtitle track selection | [`TrackSelectionCoordinator`](../../iosApp/iosApp/Screens/Player/Tracks/TrackSelectionCoordinator.swift) |
| Presentation: overlays, notices, settings application, Now Playing, next-up | [`PlayerViewModel`](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift) |

Identity is explicit: `LoadID` is minted by the control plane, `SessionIdentity`
by the bridge, and every effect carries the one it is conditional on.

What varies is *what AVPlayer is pointed at*.
[`PlaybackEngineKind`](../../iosApp/iosApp/Screens/Player/PlaybackExecutionPlan.swift)
names the three routes, and `PlaybackRouteFamily` groups them:

| Engine kind | Route family | What AVPlayer consumes |
| --- | --- | --- |
| `avPlayerNativeDirect` | `nativePlayer` | The remote asset itself, when the container / codecs / embedded subtitles match a narrow Apple allowlist (`mp4` / `mov` / `m4v`, h264 or hevc, aac/ac3/eac3/alac/mp3). |
| `siloPlayerLoopback` | `siloPlayer` | A fragmented-MP4 HLS presentation this device produces, served from `127.0.0.1`. Remux for h264/hevc/Dolby Vision; on-device decode → VideoToolbox re-encode for the codecs AVPlayer cannot take. |
| `avPlayerHLS` | `nativePlayer` | A server-produced HLS manifest (remux or transcode). The terminal rung. |

There is no longer a second decoder, so "fall back" no longer means "swap
engines". It means "point AVPlayer at something else", and the last thing left
to point it at is the server.

## Table of contents

- **[01 - Overview and entrypoints](01-overview-and-entrypoints.md)**
  Screen ownership, session bootstrap, route selection, the fallback ladder,
  metadata, progress reporting, and teardown.
- **[02 - Retired: CompatibilityPlayer (PlayerCore)](02-retired-compatibility-player.md)**
  What the deleted decode core was, why it went away, and where the formats it
  used to serve go now.
- **[03 - Dolby Vision and the SiloPlayer loopback](03-dolby-vision-and-avplayer-route.md)**
  Dolby Vision routing decisions, the local HLS remux path, loopback server,
  `AVPlayerLayer`, and the gaps that remain.
- **[04 - tvOS controls and current behavior](04-tvos-controls-and-current-behavior.md)**
  Siri Remote handling, overlay auto-hide, scrubber behavior, HUD tabs, and
  what the tvOS shell exposes today.
- **[05 - Apple route capability matrix](05-route-capability-matrix.md)**
  Route-by-route truth for subtitles, chapters, PiP, external playback, the
  loopback video output mode, and premium-media claims.
- **[06 - Apple validation record template](06-validation-record-template.md)**
  The validation fields required before Dolby Vision, Atmos, PiP, or external
  playback claims can be treated as real.
- **[07 - Profile 7 Dolby Vision and TrueHD loopback spec](07-profile7-dv-truehd-loopback-spec.md)**
  Product and implementation contract for P7 MKV playback on Apple TV,
  including why the route exists, the Infuse/VidHub inference, and the
  FLAC-to-multichannel-LPCM target plus Dolby Vision validation checklist.
- **[08 - Validated Apple player review](08-validated-player-review.md)**
  Historical (2026-04-29) source-verified review. Superseded in part by the
  one-player consolidation; see its header note.
- **[09 - On-device video bridge — RETIRED 2026-08-17](09-video-bridge.md)**
  Historical record of the software-decode → VideoToolbox-encode path. The tier
  was deleted on 2026-08-17: no online or offline plan could reach it, because
  the Apple capability surfaces only ever advertise `h264`/`hevc`.
- **[10 - Playback continuity](10-playback-continuity.md)**
  How playback rides out server restarts and origin outages: background
  session renewal, runway-aware outage parking, and cache adoption across
  recovery reloads.
- **[Cast remote](cast-remote.md)**
  The iOS → tvOS LAN remote protocol and the player commands it drives.

## Quick answers

- **What plays video on tvOS?**
  `AVPlayer`, always. Route choice happens in
  [`ApplePlaybackRoutePlanner.swift`](../../iosApp/iosApp/Screens/Player/ApplePlaybackRoutePlanner.swift)
  and is carried as typed data on `PlaybackExecutionPlan`.
- **What is the default route for a direct-play library file?**
  For the common case — an MKV that is not in the native-direct allowlist —
  `siloPlayerLoopback`. The planner only picks `avPlayerNativeDirect` when the
  source already matches the Apple allowlist end to end, and only falls to
  `avPlayerHLS` when neither the direct asset nor a local loopback session can
  be resolved.
- **How is Dolby Vision handled?**
  DV profiles 5 / 7 / 8 route to `siloPlayerLoopback`. Profile 7 is converted
  to a Profile 8.1 base layer (`convertProfile7To81`), 5 and 8 pass through.
  Dolby Vision is always a pure copy: `LoopbackSessionSpec.VideoMode` has only
  passthrough/convert cases (`passthroughProfile5`, `convertProfile7To81`,
  `passthroughProfile8`, `passthroughHEVC`, `passthroughH264`), and there is no
  re-encode tier to lose an RPU/enhancement layer to.
- **What was the video bridge?**
  A software-decode → VideoToolbox-encode tier inside the loopback writer,
  retired 2026-08-17 because nothing could route to it. The loopback only
  remuxes today. See
  [09 - On-device video bridge (retired)](09-video-bridge.md).
- **Are subtitle features complete?**
  Text subtitles are Silo-rendered on controlled tracks: primary, secondary
  sidecar, delay, styling, and chapters are route-aware. PGS / DVD-sub /
  VobSub are now decoded client-side into RGBA cues
  (`siloClientRenderedBitmapSubtitleCodecs`) and no longer force a server
  route; DVB subtitles still do (`bitmap_subtitles_require_hls`).
- **What still falls to server transcode?**
  Sources the loopback cannot open or normalize: an unknown container or video
  codec, any video codec outside the copy set (`video_not_copyable`), a
  container outside the native-direct and silo source lists
  (`container_not_normalizable`), DVB subtitles, plus any runtime loopback
  failure.
- **Is HDR mode matching public API?**
  Yes. tvOS uses `AVDisplayCriteria(refreshRate:formatDescription:)` (tvOS 17+)
  via [`TVDisplayCriteria`](../../iosApp/iosApp/Screens/Player/Shared/TVDisplayCriteria.swift),
  which `AVPlayerBackend` drives before item creation and releases on dispose.

## Scope and conventions

- These docs describe the **current implementation** in this repository.
- "Current limitation" means the behavior is explicitly true in code today,
  not just planned or suspected.
- Phase-2 / planned work is labelled as such and is never written as current
  behavior.
- Historical context lives in [08](08-validated-player-review.md) (dated,
  source-verified review) and in the commit history. Those explain why the
  stack moved this way; this suite explains what it does now.
- When a source-file comment disagrees with the executable control flow, this
  suite follows the executable control flow and calls the mismatch out.

## Validation log

- verified: `CompatibilityPlayer` / `PlayerCore` were removed on 2026-08-16
  (`f1b1bba`, "refactor(player): remove the PlayerCore/CompatibilityPlayer
  backend"). `iosApp/iosApp/Screens/Player/CoreMedia/` no longer exists;
  `TVDisplayCriteria`, `VideoColorMetadata`, `DolbyVisionFormat`, and
  `FFmpegLogFilter` were relocated to
  [`Screens/Player/Shared/`](../../iosApp/iosApp/Screens/Player/Shared).
- corrected (2026-08-18): the `ActivePlayer` enum and `PlaybackCoordinator`
  were collapsed in `e458784`; `PlayerViewModel` held an optional
  `AVPlayerBackend` directly (`installBackend(for:)` / `prepareBackend(for:)`).
- corrected (2026-08-20): those two methods are gone with the control-plane
  extraction. The backend is owned by the load's `PlaybackEngineSession`;
  `PlayerViewModel.avPlayerBackend` is a computed forwarder
  (`engineSession?.surfaceBackend`) kept for the render surface and the settings
  appliers. See the ownership table above.
- verified: `PlaybackEngineKind` is `{avPlayerHLS, avPlayerNativeDirect,
  siloPlayerLoopback}` and `PlaybackRouteFamily` is `{nativePlayer,
  siloPlayer}`.
- corrected: the AVPlayer HLS route is no longer feature-flag gated. The
  planner's `.remux` / `.transcode` arm always selects `.avPlayerHLS`, and the
  vestigial flag plumbing has been removed.
- corrected: earlier revisions of this suite described a hybrid backend and
  quoted stale `mpv` comments. Neither the second backend nor those comments
  remain in the player tree.
