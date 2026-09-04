> [!WARNING]
> **Historical pre-AetherEngine archive.** This document describes the removed custom-player architecture or its pre-migration validation model. It is retained for history only and must not be used as current implementation guidance. See the [AetherEngine-only replacement specification](aetherengine-replacement-spec.md).

Repo snapshot date: 2026-04-29

# Dolby Vision And SiloPlayer Route

## 1. Routing matrix

CompatibilityPlayer (`PlayerCore`) still owns some Dolby Vision detection
logic, but AVPlayer-backed playback is no longer a DV-only backend. The current
route families are:

- CompatibilityPlayer
- NativePlayer Direct
- NativePlayer HLS
- SiloPlayer

Within that family, Dolby Vision-specific routing currently works as follows:

- **Profile 4**  
  stays on CompatibilityPlayer and follows the HDR10-compatible path with DV
  signaling omitted
- **Profile 5**  
  routes to SiloPlayer through the local Dolby Vision loopback
- **Profile 7**  
  routes to the SiloPlayer loopback as `profile7_to81_base_layer`; this must not
  be treated as raw P7 HLS support or full FEL reconstruction. The user-facing
  `preferProfile7HDR10Fallback` setting (Settings → Player) flips this branch:
  when on, P7 streams stay on the HDR10-compatible CompatibilityPlayer HEVC
  passthrough path with DV signaling omitted; when off (default), the route
  takes the SiloPlayer 8.1 conversion loopback. This is the single setting
  name that gates the runtime choice; the planner exposes it as
  `ApplePlaybackRoutePlanner.Input.preferProfile7HDR10Fallback`.
- **Profiles 8 / 9**  
  use the NativePlayer Direct allowlist when the container and codecs are
  already Apple-native, otherwise stay on CompatibilityPlayer's HEVC path with
  native `dvcC`
- **Profile 10**  
  is not a live direct-play claim today. `PlayerCore` has metadata routing for
  AV1 Dolby Vision, but the active format-description and native-direct allowlist
  paths still exclude AV1 video.

There is also a second fallback trigger:

- if `VTDecompressionSessionCreate` returns `unimpErr` for HEVC+PQ and the code
  suspects unsignalled Dolby Vision, CompatibilityPlayer rejects to SiloPlayer
  even if DOVI side data was not surfaced cleanly

## 2. What "fallback" means in practice

When CompatibilityPlayer (`PlayerCore`) rejects a stream:

1. it does **not** pick the fallback backend itself
2. it fires `onUnsupportedStream(reason, url, headers, startTime)`
3. `PlayerViewModel.handleUnsupportedStream(...)` disposes `PlayerCore`
4. the view model instantiates `AVPlayerBackend`
5. the same callback surface is attached to the new backend
6. `PlayerView` switches from `PlayerSurface` to `AVPlayerSurface`

So the Dolby Vision fallback decision is centralized in the view model, not
buried inside the decode core or mixed up with NativePlayer HLS/Direct.

## 3. tvOS display matching and the dormant DV gate

The tvOS display behavior lives in `PlayerCore`, and the codebase currently has
two different helpers:

- `applyDisplayCriteria(...)` for the normal HDR / refresh-rate path
- `applyDvGatedDisplayCriteria(...)` for a stricter Profile 5 gate

Important current truth: only the normal HDR helper is reached in the active
load flow. The stricter Profile 5 gate exists in code, but the current
`.p5Passthrough` route returns out of `buildVideoFormatDescription(...)` before
the later `needsDvGate` branch in `openAndDemux(...)` can run. So the P5 gate
is present in the source tree but dormant in today's executable flow.

If it were wired back in, the gate would:

- refuse immediately if `Match Content: Dynamic Range` is off
- wait up to 3 seconds for display-mode switching to settle

## 4. What AVPlayerBackend actually does for SiloPlayer

The Dolby Vision fallback path is not "just use AVPlayer on the original URL."

`AVPlayerBackend` builds a local remux pipeline:

1. require `PlaybackSourceProxy` for remote HTTP(S) direct Silo sources
2. rewrite `LoopbackSessionSpec.sourceURL` to the local proxy URL
3. create a loopback generation and `DVSegmentStore`
4. enable generated-HLS temp spill for sources above 40 Mbps
5. start `DVSegmentServer` on `127.0.0.1:<random-port>`
6. start `DVSegmentWriter`
7. wait for the first playlist/segment runway to be ready
8. create an `AVURLAsset` pointed at the local playlist
9. build an `AVPlayerItem`
10. attach observers
11. play through `AVPlayer`

`AVPlayerSurface` is only the render layer:

- `UIViewRepresentable`
- `AVPlayerLayer`
- black background
- `.resizeAspect`

All of the interesting fallback logic is in `PlayerViewModel`,
`PlaybackSourceProxy`, `AVPlayerBackend`, `DVSegmentWriter`, `DVSegmentStore`,
and `DVSegmentServer`.

## 5. Why the fallback exists

The writer file is explicit about the design:

- the FFmpeg build has the `mp4` muxer, not the `hls` muxer
- so the app produces fragmented MP4 output itself
- Swift code splits the emitted BMFF boxes into `init.mp4` plus `.m4s` segments
- the video track is forced to `dvh1`
- a Dolby Vision configuration box is injected into the visual sample entry
  when the source carries a DV configuration record. Which box type is written
  follows the record's *output* profile: `dvcC` up to Profile 7 (so Profile 5
  gets the `dvh1` + `dvcC` pairing Apple requires) and `dvvC` for the
  cross-compatible Profile 8 and above. The injection is
  **nil-on-box-tree-failure**: an unexpected MP4 box layout (no `hvcC` in the
  visual sample entry, etc.) returns `nil` and the original init segment is
  written as-is. It is not nil-on-every-failure — common cases like P7→8.1
  conversion synthesize a derived 8.1 DV record from the P7 input, and pure
  HEVC modes intentionally skip injection.
- a Profile 5 session with no usable DV record never reaches the mux: its base
  layer is IPT-PQ-c2, so a sample entry without a configuration box has no
  viewable fallback, and the writer fails the session
  (`LoopbackWriterError.profile5ConfigUnusable`) so the route ladder moves on.
- AVPlayer then consumes the resulting local HLS presentation

The goal is to get DV Profile 5 through AVPlayer's own Dolby Vision-capable
pipeline, because the VideoToolbox path used by `PlayerCore` does not create a
working P5 decoder session.

## 6. Loopback server and ATS

`DVSegmentServer` is intentionally tiny:

- bound to `127.0.0.1`
- supports `GET` and `HEAD`
- serves `.m3u8`, `.m4s`, and `.mp4` from `DVSegmentStore`
- supports byte ranges and brief near-future waits
- no real auth layer

This is why both `Info.plist` files enable:

- `NSAppTransportSecurity`
  - `NSAllowsLocalNetworking = true`

Without that ATS exception, AVPlayer cannot load the loopback playlist.

## 7. What AVPlayerBackend reports back

Across the NativePlayer and SiloPlayer route families, the backend publishes:

- time updates
- duration
- pause state
- buffering state
- buffered-ahead seconds
- end-of-file
- terminal errors

On the local Dolby Vision loopback path, AVFoundation media selection plus
server-supplied chapters now keep Audio / Subtitles / Chapters populated. That
is different from the older empty-array behavior this doc used to describe.

## 8. Current limitations on NativePlayer and SiloPlayer routes

These are explicit in the current code:

- no audio-delay path
- native AVFoundation caption fallback does not support Silo subtitle
  delay/styling; controlled tracks render through the shared libass overlay
- no video-gravity path
- no tvOS-side HDR toggle logic inside the backend itself

One especially important nuance:

- `AVPlayerBackend` does expose `setSpeed(_:)`
- `PlayerViewModel.setPlaybackSpeed(...)` now routes through `activePlayer`
  for both backends

So speed changes continue to work after NativePlayer/SiloPlayer route switches.

## 9. Source-auth detail

The fallback route has two separate HTTP layers:

- `PlaybackSourceProxy` owns the authenticated original Silo stream URL,
  performs origin range fetching, and exposes a session-tokenized localhost URL
- `DVSegmentWriter` opens the localhost source-proxy URL without remote auth
  headers
- `AVPlayer` reads from the local loopback server

The local HLS asset does not need remote auth headers. Origin auth is hidden from
FFmpeg and AVPlayer-facing clients.

## 10. Generated HLS storage policy

`DVSegmentStore` is memory-first with a 128 MB generated segment budget. For
Silo sources above 40 Mbps, the backend enables bounded session-scoped temp spill
so append-only `EVENT` playlists do not reference segments that have disappeared
from memory. Lower-bitrate sessions remain memory-first when practical.

Temp spill is not debug mirroring:

- generated HLS temp spill: `tmp/continuum-dv-hls/<generation>/`, removed on
  teardown
- debug artifacts: `tmp/continuum-dv-hls-debug/<session>/`, only when
  `SILO_KEEP_DV_HLS=1`
- source cache disk spill: separate optional path, controlled by
  `SILO_ENABLE_SOURCE_DISK_SPILL=1`

The HUD/log stats keep source cache bytes, generated store bytes, generated temp
spill bytes, debug mirror bytes, and AVPlayer playable ahead separate.

## 11. Audio policy

For the high-quality Silo route:

- AAC / AC-3 / E-AC-3 copy when compatible.
- TrueHD / MLP / MLPA / Dolby TrueHD use `require_flac` and emit `fLaC` in the
  local fMP4/HLS output.
- Required FLAC does not silently fall back to E-AC-3, AC-3, or AAC.
- TrueHD-to-FLAC preserves the lossless channel bed but does not preserve Atmos
  object metadata; `preservesAtmos=0` is the expected log value.

## Validation log

- corrected: AVPlayer-backed playback is no longer a DV-specific fallback
  backend; NativePlayer covers the native-direct allowlist and gated HLS, while
  SiloPlayer covers local normalized Dolby Vision paths.
- verified: DV Profile 5 and the current Profile 7-to-8.1 experiment are the
  explicit DOVI routes to SiloPlayer's local AVPlayer loopback; Profile 7 is now
  logged as `profile7_to81_base_layer`.
- corrected: the `strippedHdr10` routing name is stronger than the current live
  behavior; the code no longer strips EL/RPU NALs and instead omits DV
  signaling while keeping playback on the HDR10-compatible path.
- corrected: `applyDvGatedDisplayCriteria(...)` exists but is currently dormant
  in the active Profile 5 flow.
- corrected: NativePlayer and SiloPlayer routes now keep track/chapter
  publication and live speed controls aligned with the shared route-aware
  player shell.
- corrected: Silo loopback now requires the localhost source proxy and hides
  remote auth from FFmpeg and AVPlayer-facing clients.
- corrected: high-bitrate generated HLS uses bounded temp spill above 40 Mbps;
  debug artifacts remain opt-in through `SILO_KEEP_DV_HLS=1`.
- corrected: TrueHD-family audio on the high-quality Silo path now requires FLAC
  and does not silently degrade to lossy audio.
