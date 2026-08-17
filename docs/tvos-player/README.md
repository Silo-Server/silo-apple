Repo snapshot date: 2026-08-16 (branch `player/one-player-cleanup`, HEAD `6818819`)

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
[`AVPlayerBackend.swift`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift),
and `ActivePlayer` in
[`PlayerViewModel.swift`](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift)
has exactly two cases, `.none` and `.avPlayer`.

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
  video bridge, and premium-media claims.
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
- **[09 - On-device video bridge](09-video-bridge.md)**
  The software-decode → VideoToolbox-encode path that lets the loopback take
  VP9/VP8/AV1/MPEG-2/MPEG-4/VC-1/WMV3 sources.
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
  Dolby Vision is **never** bridged: `loopbackVideoOutputMode` returns `.copy`
  for DV on a copyable codec and the blocker `dv_not_bridgeable` for DV on
  anything else, because an RPU/enhancement layer cannot survive decode →
  re-encode.
- **What is the video bridge?**
  The loopback can now decode a source in software (libdav1d / vp9 / vp8 /
  mpeg2video / mpeg4 / msmpeg4v3 / vc1 / wmv3) and re-encode through
  `hevc_videotoolbox` (falling back to `h264_videotoolbox`) instead of copying
  the bitstream. Phase 1 gates it to SDR at ≤ 1080p. See
  [09 - On-device video bridge](09-video-bridge.md).
- **Are subtitle features complete?**
  Text subtitles are Silo-rendered on controlled tracks: primary, secondary
  sidecar, delay, styling, and chapters are route-aware. PGS / DVD-sub /
  VobSub are now decoded client-side into RGBA cues
  (`siloClientRenderedBitmapSubtitleCodecs`) and no longer force a server
  route; DVB subtitles still do (`bitmap_subtitles_require_hls`).
- **What still falls to server transcode?**
  Sources the loopback cannot open or normalize: an unknown container or video
  codec, a codec outside both the copy and bridge sets
  (`video_not_bridgeable`), an HDR source on a bridge codec
  (`video_hdr_bridge_unsupported`), a bridge codec above 1080p
  (`video_bridge_resolution_unsupported`), DVB subtitles, plus any runtime
  loopback failure — including the bridge throughput watchdog
  (`LoopbackWriterError.videoBridgeTooSlow`).
- **Is HDR mode matching public API?**
  Yes. tvOS uses `AVDisplayCriteria(refreshRate:formatDescription:)` (tvOS 17+)
  via [`TVDisplayCriteria`](../../iosApp/iosApp/Screens/Player/Shared/TVDisplayCriteria.swift),
  which `AVPlayerBackend` drives before item creation and releases on dispose.

## Scope and conventions

- These docs describe the **current implementation** in this checkout.
- "Current limitation" means the behavior is explicitly true in code today,
  not just planned or suspected.
- Phase-2 / planned work is labelled as such and is never written as current
  behavior.
- Historical context lives in the dated audit files in this folder
  ([08](08-validated-player-review.md), the 2026-07-07 AetherEngine parity
  audit) and in the commit history. Those explain why the stack moved this way;
  this suite explains what it does now. Note that several older documents and a
  few source comments still cite a `docs/plans/` directory that does not exist
  in this repository.
- When a source-file comment disagrees with the executable control flow, this
  suite follows the executable control flow and calls the mismatch out.

## Validation log

- verified: `CompatibilityPlayer` / `PlayerCore` were removed on 2026-08-16
  (`f1b1bba`, "refactor(player): remove the PlayerCore/CompatibilityPlayer
  backend"). `iosApp/iosApp/Screens/Player/CoreMedia/` no longer exists;
  `TVDisplayCriteria`, `VideoColorMetadata`, `DolbyVisionFormat`, and
  `FFmpegLogFilter` were relocated to
  [`Screens/Player/Shared/`](../../iosApp/iosApp/Screens/Player/Shared).
- verified: `ActivePlayer` has exactly two cases (`.none`, `.avPlayer`) in
  `PlayerViewModel.swift`; `PlaybackCoordinator.installEngine(for:)` only ever
  builds an `AVFoundationPlayerEngine`.
- verified: `PlaybackEngineKind` is `{avPlayerHLS, avPlayerNativeDirect,
  siloPlayerLoopback}` and `PlaybackRouteFamily` is `{nativePlayer,
  siloPlayer}`.
- corrected: the AVPlayer HLS route is no longer feature-flag gated. The
  planner's `.remux` / `.transcode` arm always selects `.avPlayerHLS`, and the
  vestigial flag plumbing has been removed.
- corrected: earlier revisions of this suite described a hybrid backend and
  quoted stale `mpv` comments. Neither the second backend nor those comments
  remain in the player tree.
