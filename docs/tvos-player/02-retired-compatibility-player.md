Repo snapshot date: 2026-08-16 (branch `player/one-player-cleanup`, HEAD `6818819`)

# Retired: CompatibilityPlayer (PlayerCore)

> This file used to document the CoreMedia pipeline. That pipeline no longer
> exists. The filename changed from `02-coremedia-pipeline.md`; the slot is kept
> so the numbered suite stays contiguous.

## 1. What it was

`CompatibilityPlayer` was the implementation route name for `PlayerCore`, a
hand-rolled playback engine that lived in
`iosApp/iosApp/Screens/Player/CoreMedia/`. It was not AVPlayer. Its pipeline
was:

- `libavformat` demux
- VideoToolbox video decode, with an H.264 software-decode fallback after
  repeated VT failures
- `AVSampleBufferDisplayLayer` video output, driven by a host-clock
  `controlTimebase` and a `CADisplayLink` push loop (the pull-model
  `AVSampleBufferVideoRenderer` never delivered frames on tvOS 18)
- FFmpeg software audio decode plus `SwrContext`
- an `AVAudioEngine` graph with an `AVAudioSourceNode`, whose render-notify
  callback drove a local `AudioClock` used as the A/V master clock

It rendered through `PlayerSurface` (and a macOS sibling), owned sample-buffer
Picture in Picture plumbing, and reported unplayable streams to the view model
through `onUnsupportedStream` so a route handoff could occur.

Its role in the route taxonomy was the "codec tail": containers and codecs the
AVPlayer routes could not accept — AV1, VP9, MPEG-2, MPEG-4 Part 2, VC-1, WMV3,
and the long-GOP H.264 / SDR HEVC that the loopback's growing EVENT playlist
started unreliably.

## 2. Why it was removed

Removed on 2026-08-16 in `f1b1bba`, *"refactor(player): remove the
PlayerCore/CompatibilityPlayer backend"* (net −11,048 lines). Three reasons:

1. **One player is cheaper than two.** Every feature — subtitles, chapters,
   Now Playing, stats, settings, PiP, AirPlay, display criteria, seek/resume,
   volume — had to be implemented and validated twice, on two different
   clocking models. Roughly half the capability matrix existed only to say
   which of the two halves a given behavior worked on.
2. **On-device bridges cover its unique formats.** The loopback gained a
   [video bridge](09-video-bridge.md): software decode → `hevc_videotoolbox` /
   `h264_videotoolbox` re-encode for the codecs AVPlayer will not take, plus an
   AV1 remux path on hardware-AV1 devices. Combined with the already-shipping
   audio bridge and the static VOD serving mode (which removed the long-GOP
   startup risk that used to bounce H.264 and SDR HEVC back to
   CompatibilityPlayer), the codec tail no longer needed its own decoder.
3. **The HDR/DV story is AVPlayer's.** `PlayerCore` could decode a Dolby Vision
   Profile 5 bitstream but could not present it as Dolby Vision on an Apple TV
   output path; only AVPlayer negotiates that. Keeping a second engine meant
   keeping a path that would always under-deliver on the premium claim.

Retired along with it:

- **Decode-time `StreamRejection` recovery.** `PlayerCore` used to discover
  mid-decode that a stream was unplayable (VT `unimpErr` on HEVC+PQ, suspected
  unsignalled Dolby Vision) and fire `onUnsupportedStream` to trigger a route
  swap. Signalled Dolby Vision is now routed up front by
  `ApplePlaybackRoutePlanner`, and anything the loopback cannot handle is a
  plan-time blocker rather than a decode-time surprise.
- `PlaybackRecoveryPlanner` and `CompatibilityPlayerEngine`.
- The macOS `PlayerSurface`.
- The HDR-passthrough toggle and audio-delay controls, which only ever did
  anything on this route (see
  [04 - tvOS controls](04-tvos-controls-and-current-behavior.md)).
- The `playerCoreDirect` column of the capability matrix (see
  [05](05-route-capability-matrix.md)).

## 3. Where those formats go now

| Source shape | Old route | Current route |
| --- | --- | --- |
| H.264 / HEVC in `mkv`, `ts`, `m2ts` | CompatibilityPlayer (or loopback when DV/HDR) | `siloPlayerLoopback`, `videoOutputMode = .copy` |
| SDR HEVC, long-GOP H.264 | CompatibilityPlayer (loopback was blocked as startup-unreliable) | `siloPlayerLoopback` under the VOD serving mode; the old `h264_loopback_startup_unreliable` / `hevc_sdr_loopback_startup_unreliable` blockers were deleted with the EVENT serving mode on 2026-08-17 |
| AV1, hardware-decode device | CompatibilityPlayer | `siloPlayerLoopback`, `videoOutputMode = .passthroughAV1` (remuxed with an `av01` sample entry) |
| AV1 without hardware decode; VP9, VP8, MPEG-2, MPEG-4 Part 2, MSMPEG4v3, VC-1, WMV3 — SDR, ≤ 1080p | CompatibilityPlayer | `siloPlayerLoopback`, `videoOutputMode = .transcodeHEVC` (or `.transcodeH264` when no HEVC encoder opens) |
| The same bridge codecs in `avi`, `wmv`, `asf`, `webm`, `flv`, `mpg`, `vob`, … | CompatibilityPlayer | `siloPlayerLoopback` — the bridge tier of `siloContainerIsNormalizable` opens these containers; the copy tier still does not |
| Bridge codecs that are HDR (PQ/HLG) | CompatibilityPlayer | `avPlayerHLS`; blocker `video_hdr_bridge_unsupported` (phase-2 item) |
| Bridge codecs above 1080p | CompatibilityPlayer | `avPlayerHLS`; blocker `video_bridge_resolution_unsupported` (phase-2 item) |
| Dolby Vision on a non-copyable codec | CompatibilityPlayer | `avPlayerHLS`; blocker `dv_not_bridgeable`. DV is never re-encoded |
| Anything else (e.g. Theora) | CompatibilityPlayer | `avPlayerHLS`; blocker `video_not_bridgeable`, so the server transcodes |
| H.264 after a VideoToolbox hardware-decode failure | `PlayerCore`'s per-load software fallback | Gone. There is no client-side H.264 software decode path; an AVPlayer failure walks the [fallback ladder](01-overview-and-entrypoints.md#6-the-fallback-ladder) |
| Sample-buffer Picture in Picture | `PlayerCore` (plumbing existed but early-returned) | iOS AVPlayer PiP via [`PictureInPictureCoordinator`](../../iosApp/iosApp/Screens/Player/iOS/PictureInPictureCoordinator.swift); tvOS PiP remains unsupported |

## 4. What survived the deletion

Four helpers were genuinely shared and moved from `CoreMedia/` to
[`Screens/Player/Shared/`](../../iosApp/iosApp/Screens/Player/Shared):

- [`TVDisplayCriteria.swift`](../../iosApp/iosApp/Screens/Player/Shared/TVDisplayCriteria.swift)
  — tvOS HDMI mode negotiation via `AVDisplayManager.preferredDisplayCriteria`.
  Its own header comment now names `AVPlayerBackend` as the driver: criteria are
  applied before item creation and released on dispose.
- [`VideoColorMetadata.swift`](../../iosApp/iosApp/Screens/Player/Shared/VideoColorMetadata.swift)
  — colour-signalling mapping, including `dolbyVisionBaseLayerColorimetry`
  (PQ for Profile 8.1, Rec.709 SDR for 8.2, HLG for 8.4).
- [`DolbyVisionFormat.swift`](../../iosApp/iosApp/Screens/Player/Shared/DolbyVisionFormat.swift)
  — pure functions over the FFmpeg DOVI side data. Its doc comment already
  anticipated this move: "there is no decode-core state captured here, so the
  same decisions can be made by alternate demux pipelines."
- [`FFmpegLogFilter.h`/`.m`](../../iosApp/iosApp/Screens/Player/Shared) plus the
  Objective-C bridging header
  [`SiloPlayerBridging.h`](../../iosApp/iosApp/Screens/Player/Shared/SiloPlayerBridging.h),
  referenced from `iosApp/project.yml` as
  `iosApp/Screens/Player/Shared/SiloPlayerBridging.h` for every target.

## Validation log

- verified: `iosApp/iosApp/Screens/Player/CoreMedia/` does not exist and no
  `PlayerCore` symbol remains anywhere under `iosApp/`.
- verified: the four shared helpers are renames, not rewrites, in `f1b1bba`
  (`{CoreMedia => Shared}/...` in the diffstat).
- verified: `ApplePlaybackRoutePlanner.loopbackVideoOutputMode(for:version:capabilities:)`
  is the single place the copy / bridge / AV1-passthrough decision is made, and
  its blocker vocabulary is what routes the remaining tail to `avPlayerHLS`.
- corrected: the H.264 VideoToolbox → FFmpeg software-decode fallback this file
  used to document has no successor. It was a `PlayerCore`-only behavior.
- corrected: the `<= 6ch` audio default-selection bias documented here was
  `PlayerCore.findStreams()`. Loopback audio selection now runs through
  `ApplePlaybackRoutePlanner.resolveLoopbackSelectedAudioTrack(...)`, which
  prefers an explicit selection, then a pending ff-index, then the preferred
  index, then the default-flagged track — no channel-count heuristic.
