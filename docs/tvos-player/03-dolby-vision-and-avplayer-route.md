Repo snapshot date: 2026-08-16 (branch `player/one-player-cleanup`, HEAD `6818819`)

# Dolby Vision And The SiloPlayer Loopback

## 1. Routing matrix

Every route is AVPlayer now (see
[README](README.md#one-avplayer-family-three-routes)), so Dolby Vision routing
is purely a question of *what AVPlayer is fed*. The engine kinds are
`avPlayerNativeDirect`, `siloPlayerLoopback`, and `avPlayerHLS`.

Dolby Vision is decided **first** in
[`ApplePlaybackRoutePlanner.makeExecutionPlan(input:)`](../../iosApp/iosApp/Screens/Player/ApplePlaybackRoutePlanner.swift):
if `sourceMetadata.dolbyVisionProfile` is 5, 7, or 8 and a
`LoopbackSessionSpec` resolves, the engine is `siloPlayerLoopback` before the
native-direct assessment is even consulted. The Silo assessment short-circuits
with `silo_dv_profile_owned_by_dv_policy` for the same reason.

| Profile | `LoopbackSessionSpec.VideoMode` | Notes |
| --- | --- | --- |
| 4 | n/a | Not in the `[5, 7, 8]` set. Falls through to the ordinary native-direct / loopback / HLS assessment as plain HEVC. |
| 5 | `.passthroughProfile5` | `dvh1` sample entry, `dvcC` config box. A P5 session with no usable DV record fails the writer (`LoopbackWriterError.profile5ConfigUnusable`) rather than muxing an unviewable IPT-PQ-c2 base layer. |
| 7 | `.convertProfile7To81` | Base-layer conversion to Profile 8.1 (`db1p` brand, `PQ` video range). **Unchanged by the one-player work.** Not raw P7 HLS support and not FEL reconstruction. |
| 7, with `preferProfile7HDR10Fallback` on | `.passthroughHEVC` | The Settings → Player toggle. When `DolbyVisionPolicy.resolution(forProfile:snapshot:)` returns `.profile7HDR10Fallback`, the loopback carries the HDR10-compatible base layer with DV signaling omitted. |
| 8 | `.passthroughProfile8(baseLayer)` | Base layer from `transferKind(for:)`: PQ → 8.1 (`db1p`), SDR → 8.2 (`db2g`), HLG → 8.4 (`db4h`). |
| 8, with Dolby Vision disabled | `.passthroughHEVC` | `dolby_vision_disabled_base_layer_loopback`. |
| 10 (AV1 DV) | none | Not a live claim. `DolbyVisionFormat` recognizes AV1 DV metadata, but AV1 never reaches a DV `VideoMode`: the planner's DV arm only builds specs for profiles 5/7/8, and `loopbackVideoOutputMode` blocks any non-copyable codec with `video_not_copyable`. |

## 2. Dolby Vision is never re-encoded

Since the on-device video bridge was retired (2026-08-17, see
[09](09-video-bridge.md)) this holds structurally rather than by a dedicated
gate: `ApplePlaybackRoutePlanner.loopbackVideoOutputMode(for:)` has only one
answer, and it is `.copy`.

```swift
siloVideoCopyCodecs.contains(videoCodec) ? (.copy, nil) : (.copy, "video_not_copyable")
```

- DV on `h264` / `hevc` → `.copy`. The bitstream, RPU, and enhancement layer
  are remuxed byte-for-byte.
- DV on anything else → blocked with `video_not_copyable`, which routes the
  session to `avPlayerHLS`.

The original reason still stands: an RPU and enhancement layer cannot survive
decode → re-encode, and Profile 5's IPT-PQ-c2 base has no viewable fallback if
the DV metadata is stripped. There is no longer a local re-encode tier that
could get this wrong.

The planner reinforces it at the call site: `directVideoOutputMode` is forced
to `.copy` whenever `directDolbyVisionProfile != nil`, so even if the Silo
assessment had produced a bridged mode it cannot claim a DV session.

## 3. tvOS display matching

`AVPlayerBackend` drives
[`TVDisplayCriteria`](../../iosApp/iosApp/Screens/Player/Shared/TVDisplayCriteria.swift)
before item creation (when stream FPS and dynamic range are known) and releases
the criteria on dispose so the system UI returns to its preferred HDMI mode.
`TVDisplayCriteria.ContentFormat` carries `dolbyVision(baseLayer:)` because the
compositor picks its mode from the base-layer transfer: PQ for 8.1, Rec.709 SDR
for 8.2, HLG for 8.4. The same mapping
(`VideoColorMetadata.dolbyVisionBaseLayerColorimetry`) supplies the colour
attachments, so the HDMI mode and the served bitstream describe one base layer.

Two behaviors worth knowing:

- After applying criteria, the backend can `await
  TVDisplayCriteria.waitForModeSwitchSettle()` before attaching, with poll
  budgets from
  [`HDRDisplayCriteriaPolicy`](../../iosApp/iosApp/Screens/Player/HDRDisplayCriteriaPolicy.swift).
- `shouldPreserveTVDisplayCriteriaDuringReload(...)` keeps the negotiated mode
  across an in-place item reload, which is why
  `PlaybackCoordinator.prepareEngine(for:)` reuses the engine when the route
  kind is unchanged. Renegotiating HDMI mid-session is visible and slow.

The old `applyDvGatedDisplayCriteria(...)` Profile 5 gate documented here
previously lived in `PlayerCore` and went away with it.

## 4. What the loopback actually does

The SiloPlayer route is not "AVPlayer on the original URL". `AVPlayerBackend`:

1. requires [`PlaybackSourceProxy`](../../iosApp/iosApp/Screens/Player/PlaybackSourceProxy.swift)
   for remote HTTP(S) direct Silo sources
2. rewrites `LoopbackSessionSpec.sourceURL` to the local proxy URL
3. creates a loopback generation and a
   [`LoopbackSegmentStore`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/LoopbackSegmentStore.swift)
4. configures the generated-HLS temp spill policy
5. starts [`LoopbackSegmentServer`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/LoopbackSegmentServer.swift)
   on `127.0.0.1:<random-port>`
6. starts [`LoopbackSegmentWriter`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/LoopbackSegmentWriter.swift)
7. waits for the first playlist/segment runway to be ready
8. creates an `AVURLAsset` pointed at the local playlist
9. builds an `AVPlayerItem`, attaches observers, and plays

`AVPlayerSurface` is only the render layer: a `UIViewRepresentable` hosting an
`AVPlayerLayer` with a black background and `.resizeAspect`.

The loopback normally serves a static VOD playlist built from a load-time segment
plan. Its explicit EVENT serving mode and
`player.apple.siloplayer_primary_enabled` kill switch were retired on 2026-08-17;
the key is no longer read. The writer still falls back internally to a growing
EVENT playlist when no safe VOD plan is available; see the cleanup backlog's
section 2.5.

## 5. Why the loopback exists

The writer file is explicit about the design:

- the FFmpeg build has the `mp4` muxer, not the `hls` muxer
- so the app produces fragmented MP4 output itself
- Swift code splits the emitted BMFF boxes into `init.mp4` plus `.m4s` segments
- Dolby Vision video is forced to a `dvh1` sample entry
- a Dolby Vision configuration box is injected into the visual sample entry when
  the source carries a DV configuration record. Which box type is written
  follows the record's *output* profile: `dvcC` up to Profile 7 (so Profile 5
  gets the `dvh1` + `dvcC` pairing Apple requires) and `dvvC` for the
  cross-compatible Profile 8 and above. The injection is
  **nil-on-box-tree-failure**: an unexpected MP4 box layout returns `nil` and the
  original init segment is written as-is. It is not nil-on-every-failure —
  P7→8.1 conversion synthesizes a derived 8.1 DV record from the P7 input, and
  pure HEVC modes intentionally skip injection.
- a Profile 5 session with no usable DV record never reaches the mux
  (`LoopbackWriterError.profile5ConfigUnusable`), so the route ladder moves on
- AVPlayer then consumes the resulting local HLS presentation

The goal has always been to get Dolby Vision through AVPlayer's own
DV-capable pipeline. What changed with the one-player consolidation is that this
is no longer a *special* path for DV: it is the primary direct-play path for
almost everything, with DV as one `VideoMode` among several and the
[video bridge](09-video-bridge.md) as an orthogonal `VideoOutputMode`.

## 6. Loopback server and ATS

`LoopbackSegmentServer` is intentionally tiny:

- bound to `127.0.0.1`
- supports `GET` and `HEAD`
- serves `.m3u8`, `.m4s`, and `.mp4` from `LoopbackSegmentStore`
- supports byte ranges and brief near-future waits
- no real auth layer

This is why the `Info.plist` files (iOS, tvOS, macOS, and the extensions) set
`NSAppTransportSecurity` → `NSAllowsLocalNetworking = true`. Without that
exception AVPlayer cannot load the loopback playlist.

## 7. What AVPlayerBackend reports back

Across all three routes the backend publishes time updates, duration, pause
state, buffering state, buffered-ahead seconds, end-of-file, and terminal
errors. On the loopback path, AVFoundation media selection plus server-supplied
chapters keep Audio / Subtitles / Chapters populated.

Loopback-specific callbacks worth knowing:

- `onSegmentPlanResolved` publishes the `LoopbackSegmentPlan` (the VOD
  timeline).
- `onSegmentAppended` advances the writer head index for the consumer window.

## 8. Current limitations

- No audio-delay path on any route.
- No per-route HDR passthrough toggle; the control was removed with
  `PlayerCore`.
- Native AVFoundation caption fallback does not honor Silo subtitle
  delay/styling; controlled tracks render through the shared libass overlay.
- Video gravity is a shared player setting rather than a backend capability
  row.
- Speed works through `activePlayer.setSpeed(_:)` on every route, so it
  survives a route swap.

## 9. Source-auth detail

The loopback has two separate HTTP layers:

- `PlaybackSourceProxy` owns the authenticated original Silo stream URL,
  performs origin range fetching, and exposes a session-tokenized localhost URL
- `LoopbackSegmentWriter` opens the localhost source-proxy URL without remote
  auth headers
- `AVPlayer` reads from the local loopback server

The local HLS asset does not need remote auth headers. Origin auth is hidden
from FFmpeg and AVPlayer-facing clients.

## 10. Generated HLS storage policy

`LoopbackSegmentStore` is memory-first with a 128 MB generated-segment budget
(96 MB on constrained-memory devices — `AVPlayerBackend.loopbackSegmentStoreMemoryBudgetBytes`).
Bounded session-scoped temp spill is now enabled for **every** loopback session
with a 4 GB budget (`generatedHLSSpillBudgetBytes`), reported as
`local_hls_event_playlist` or `source_bitrate_unknown`;
`SILO_ENABLE_HLS_DISK_SPILL=1` forces it with reason `env`.

Temp spill is not debug mirroring:

- generated HLS temp spill: `tmp/continuum-dv-hls/<generation>/`, removed on
  teardown
- debug artifacts: `tmp/continuum-dv-hls-debug/<session>/`, only when
  `SILO_KEEP_DV_HLS=1`
- source cache disk spill: a separate optional path, controlled by
  `SILO_ENABLE_SOURCE_DISK_SPILL=1`

The HUD/log stats keep source cache bytes, generated store bytes, generated
temp spill bytes, debug mirror bytes, and AVPlayer playable ahead separate.

## 11. Audio policy

For the loopback route (`ApplePlaybackRoutePlanner.loopbackAudioOutputMode`):

- AAC / AC-3 / E-AC-3 copy.
- TrueHD / MLP / MLPA use `.requireFLAC` and emit `fLaC` in the local fMP4/HLS
  output. Required FLAC does not silently fall back to E-AC-3, AC-3, or AAC.
- Everything else transcodes: `.transcodeFLAC` above 2 channels, `.transcodeAAC`
  at 2 or fewer.
- TrueHD-to-FLAC preserves the lossless channel bed but not Atmos object
  metadata; `preservesAtmos=0` is the expected log value. Only copied E-AC-3/JOC
  sets `preservesAtmos=1`.

## Validation log

- verified: Dolby Vision profiles 5/7/8 claim `siloPlayerLoopback` ahead of the
  native-direct assessment in `makeExecutionPlan`, and `assessSiloRoute` returns
  early with `silo_dv_profile_owned_by_dv_policy` for any DV source.
- corrected 2026-08-17: `loopbackVideoOutputMode` now returns
  `video_not_copyable` for any non-copy codec (the DV-specific
  `dv_not_bridgeable` arm went with the bridge tier), and the planner
  independently forces `.copy` for DV sessions.
- verified: the Profile 7 → 8.1 base-layer conversion, its `db1p` brand, and the
  `preferProfile7HDR10Fallback` escape hatch are unchanged by the one-player
  consolidation.
- corrected: the classes are `LoopbackSegmentWriter` / `LoopbackSegmentStore` /
  `LoopbackSegmentServer`. The `DVSegment*` names this file used are historical.
- corrected: generated-HLS temp spill is no longer conditional on a 40 Mbps
  source bitrate; `generatedHLSSpillPolicy(for:)` returns `.enabled` for every
  session.
- corrected: `applyDvGatedDisplayCriteria(...)`, the dormant Profile 5 display
  gate, was `PlayerCore` code and no longer exists.
- corrected: AVPlayer-backed playback is not a DV-specific fallback. It is the
  only playback stack; DV is one `VideoMode` on the loopback route.
