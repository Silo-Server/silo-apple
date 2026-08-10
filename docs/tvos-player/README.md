Repo snapshot date: 2026-04-29 (HEAD `6c2b4af`)

# tvOS Video Player Documentation

This suite documents the **actual tvOS player implementation** in the current
`silo-apple` working tree. It is intentionally code-grounded: the source of
truth is the live player code under
[`iosApp/iosApp/Screens/Player`](../../iosApp/iosApp/Screens/Player), not older
plan documents or stale comments that still mention `mpv`.

The most important thing to know up front is that the tvOS player is **not**
one backend:

- Direct compatibility playback still defaults to CompatibilityPlayer through
  [`PlayerCore.swift`](../../iosApp/iosApp/Screens/Player/CoreMedia/PlayerCore.swift).
- A narrow native-direct allowlist now routes Apple-friendly `mp4` / `mov` /
  `m4v` direct assets through NativePlayer Direct in
  [`AVPlayerBackend.swift`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift).
- `remux` and `transcode` sessions can route through NativePlayer HLS in
  [`AVPlayerBackend.swift`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift)
  when the local `player.apple.avplayer_hls_route_enabled` gate is on.
- CompatibilityPlayer can also hand off to SiloPlayer, currently implemented by
  [`AVPlayerBackend.swift`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift)
  for Dolby Vision Profile 5 and a specific VideoToolbox rejection case.
- The tvOS overlay and remote/focus behavior live in
  [`PlayerView.swift`](../../iosApp/iosApp/Screens/Player/PlayerView.swift),
  [`PlayerViewModel.swift`](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift),
  and the [`tvOS`](../../iosApp/iosApp/Screens/Player/tvOS) subfolder.

## Table of contents

- **[01 - Overview and entrypoints](01-overview-and-entrypoints.md)**  
  Screen ownership, session bootstrap, ActivePlayer switching, metadata,
  progress reporting, and teardown.
- **[02 - CoreMedia pipeline](02-coremedia-pipeline.md)**  
  The default tvOS path: FFmpeg demux, VideoToolbox decode (with H.264
  software fallback), `AVSampleBufferDisplayLayer`, `AVAudioEngine` audio
  output, tracks, subtitles, seeks, HDMI-mode selection, and source delivery
  through `PlaybackSourceProxy`.
- **[03 - Dolby Vision and SiloPlayer route](03-dolby-vision-and-avplayer-route.md)**
  Dolby Vision routing decisions, the local HLS remux path, loopback server,
  `AVPlayerLayer`, and the gaps that remain on that backend.
- **[04 - tvOS controls and current behavior](04-tvos-controls-and-current-behavior.md)**  
  Siri Remote handling, overlay auto-hide, scrubber behavior, HUD tabs, and
  what the tvOS shell exposes today.
- **[05 - Apple route capability matrix](05-route-capability-matrix.md)**  
  Route-by-route truth for subtitles, chapters, PiP, external playback, and
  premium-media claims.
- **[06 - Apple validation record template](06-validation-record-template.md)**  
  The validation fields required before Dolby Vision, Atmos, PiP, or external
  playback claims can be treated as real.
- **[07 - Profile 7 Dolby Vision and TrueHD loopback spec](07-profile7-dv-truehd-loopback-spec.md)**  
  Product and implementation contract for P7 MKV playback on Apple TV,
  including why the route exists, the Infuse/VidHub inference, and the
  FLAC-to-multichannel-LPCM target plus Dolby Vision validation checklist.
- **[08 - Validated Apple player review](08-validated-player-review.md)**
  Corrected source-verified review findings for NativePlayer, SiloPlayer,
  CompatibilityPlayer, the route planner, subtitles, stats, and lifecycle
  behavior.
- **[SiloPlayer normalization architecture findings](../plans/apple-playback-normalization-architecture.md)**
  Research notes comparing Silo's route direction with KSPlayer,
  Swiftfin/Jellyfin-style clients, VLCKit, MPVKit, and closed-source Apple
  players.
- **[Apple playback normalization spec](../plans/apple-playback-normalization-spec.md)**
  Route contract for NativePlayer, SiloPlayer, CompatibilityPlayer,
  normalization, fallbacks, logging, and validation.

## Quick answers

- **What backend does tvOS use by default?**  
  CompatibilityPlayer (`PlayerCore`) for compatibility-direct assets, with
  narrow NativePlayer routes for allowlisted native-direct files and gated HLS,
  plus SiloPlayer for local normalized Dolby Vision paths.
- **When does it switch away from CompatibilityPlayer?**
  Allowlisted native-direct MP4/MOV/M4V assets use NativePlayer Direct, HLS
  remux/transcode uses NativePlayer HLS when the feature flag is on, and local
  Dolby Vision normalization uses SiloPlayer.
- **Does tvOS use NativePlayer for all Dolby Vision?**
  No. Profile 5 currently routes to SiloPlayer Dolby Vision loopback. Profile 7
  currently routes to the experimental SiloPlayer-derived Profile 8.1 path,
  because raw P7 is not an Apple HLS target. Profiles 8/9 use NativePlayer
  Direct only when the asset is already in the native-direct allowlist;
  otherwise they stay on the CompatibilityPlayer HEVC path. Profile 10 is not a live direct-play claim today: the route code
  recognizes AV1 Dolby Vision metadata, but the active direct/native paths still
  do not admit AV1 video.
- **Are subtitle features complete?**  
  Text subtitles are now Silo-rendered on controlled tracks. Primary,
  secondary sidecar, delay, styling, and chapters are route-aware; bitmap
  subtitle formats remain outside the current renderer. The planned bitmap path
  is an overlay renderer, not client-side burn-in, so HDR/Dolby Vision video
  presentation can stay owned by the active video route.
- **Is HDR mode matching public API?**  
  Yes. tvOS uses `AVDisplayCriteria(refreshRate:formatDescription:)` (tvOS 17+)
  via [`TVDisplayCriteria`](../../iosApp/iosApp/Screens/Player/CoreMedia/TVDisplayCriteria.swift).
  The private initializer it replaced has been removed.

## Scope and conventions

- These docs describe the **current implementation**, including uncommitted
  player changes in this checkout.
- "Current limitation" means the behavior is explicitly true in code today,
  not just planned or suspected.
- Historical context lives in
  [`docs/plans/ios-unified-coremedia-player.md`](../plans/ios-unified-coremedia-player.md)
  and related plan docs. Those files explain why the stack moved this way; this
  suite explains what the stack does now.
- When a source-file comment disagrees with the executable control flow, this
  suite follows the executable control flow and calls the mismatch out.

## Validation log

- verified: tvOS playback starts from `PlayerView`/`PlayerViewModel` and
  defaults to CompatibilityPlayer (`PlayerCore`) for compatibility-direct
  assets.
- verified: the implementation is a hybrid backend, not a single native
  AVPlayer stack.
- corrected: older comments in `PlaybackSessionBridge.swift` and
  `PlayerViewModel.swift` still mention `mpv`; the live code now routes between
  CompatibilityPlayer, NativePlayer, and SiloPlayer implementations.
