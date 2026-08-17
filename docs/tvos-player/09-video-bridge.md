Repo snapshot date: 2026-08-16 (branch `player/one-player-cleanup`, HEAD `6818819`)

# On-Device Video Bridge — RETIRED 2026-08-17

> **This tier no longer exists.** `LoopbackVideoBridge.swift`, the
> `.transcodeHEVC` / `.transcodeH264` / `.passthroughAV1` video output modes,
> the bridge container and codec allowlists, the 1080p cap and the
> `videoBridgeTooSlow` watchdog were all deleted on 2026-08-17.
>
> Reason: the tier was unreachable. Online, the V3 capability snapshot only
> ever advertised `h264`/`hevc`
> (`AppleDecodeCapabilities.videoCodecs`), and the server fails closed on a
> codec it was not offered (`capabilities_v3.go` `videoEligibleV3`), so no
> `original_http` plan could ever name a bridge codec. Offline,
> `DownloadCaps.current()` reports the same two codecs, so no bridgeable
> artifact could be downloaded either. See
> `docs/cleanup/player-review/2026-08-17-architecture-review.md`
> §3 row 13, §7 Option B, §9 Stage 3.1 and §10 P4.
>
> The non-copyable codec tail is the server's job again: the planner blocks
> the silo route with `video_not_copyable` and the source comes back as
> server HLS. Everything below is retained as the historical record of what
> the tier did and why.

## 1. Purpose

The SiloPlayer loopback used to be a pure remux: demux the source, rewrite the
container, hand AVPlayer an fMP4/HLS presentation of the *same* bitstream. That
works for H.264, HEVC, and Dolby Vision, and for nothing else. Everything in the
long tail of a real library — VP9 in `.webm`, MPEG-4 Part 2 in `.avi`, WMV3 in
`.wmv`, MPEG-2 in `.vob`, VC-1, AV1 on older hardware — used to be the
CompatibilityPlayer's job.

With CompatibilityPlayer deleted (see
[02](02-retired-compatibility-player.md)) that tail needed somewhere to go, and
"always server transcode" is a bad answer: it burns server CPU for content a
modern Apple TV can normalize locally, and it throws away the direct-play
bitrate ladder.

The video bridge is the answer:
[`LoopbackVideoBridge`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/LoopbackVideoBridge.swift)
decodes the source in FFmpeg software, converts to NV12 through swscale, and
re-encodes through `hevc_videotoolbox` (or `h264_videotoolbox`) — inside the
same loopback writer, feeding the same segment cutter, with the same PTS axis.

Its shape is deliberately a mirror of the existing audio bridge:

> Both ends are FFmpeg `AVCodecContext`s, exactly like the audio bridge in
> `LoopbackSegmentWriter`. That buys the muxer contract for free.

Three properties make an encoded packet indistinguishable from a copied one
downstream:

1. The encoder runs on the **source stream's time base** and the source PTS
   rides through untouched, so encoded packets go through the very same
   `routeVideoPacketToMux` → `rewritePacketForOutput` path.
2. **No B-frames** (`max_b_frames = 0`), so PTS == DTS on every sample. The
   look-behind duration telescoping, the monotonic-DTS normalizer, and the
   missing-DTS repair path all stay out of the picture.
3. Encoder output already carries `AV_PKT_FLAG_KEY` — the single most
   load-bearing bit in the pipeline, because it is what advances
   `LoopbackSegmentCutter` and what `+frag_keyframe` cuts on.

## 2. The planner decision

`LoopbackSessionSpec.VideoOutputMode` is a deliberate sibling of `VideoMode`,
not more cases on it: `VideoMode` is the Dolby-Vision / sample-entry decision
and is switched exhaustively in a dozen places, while `VideoOutputMode` answers
the orthogonal "copy or re-encode" question.

```swift
enum VideoOutputMode: Equatable {
    case copy            // today's remux; the only value for DV, HEVC, H.264
    case transcodeHEVC   // SW decode → hevc_videotoolbox
    case transcodeH264   // same, through h264_videotoolbox
    case passthroughAV1  // AV1 remuxed as-is on hardware-AV1 devices
}
```

`sampleEntryCodec` returns `hvc1` / `avc1` / `av01`, or `nil` for `.copy` so
`VideoMode.sampleEntryCodec` keeps owning the Dolby Vision `dvh1` distinction.
`logToken` is `copy` / `bridge_hevc` / `bridge_h264` / `av1_passthrough`, and
`LoopbackSessionSpec.videoNormalizationLogToken` reports the output mode
whenever it is not `.copy` — otherwise a bridged session would log as a plain
remux.

### Decision order

All four gates in
`ApplePlaybackRoutePlanner.loopbackVideoOutputMode(for:version:capabilities:)`
are load-bearing, and the function is **pure**: every device fact arrives
through `AppleVideoBridgeCapabilities`, so the truth table is unit-testable
without touching VideoToolbox.

1. **Dolby Vision never bridges.** DV on `h264`/`hevc` → `.copy`; DV on anything
   else → blocker `dv_not_bridgeable`. The RPU and enhancement layer cannot
   survive decode → re-encode, and Profile 5's IPT-PQ-c2 base has no viewable
   fallback, so it is blocked rather than silently stripped.
2. **AV1 with hardware decode is remuxed, not bridged** → `.passthroughAV1`.
3. **`h264` / `hevc` copy** exactly as before.
4. **Bridge codecs re-encode when SDR and at most 1080p** →
   `.transcodeHEVC`, or `.transcodeH264` when
   `AppleVideoBridgeCapabilities.supportsHEVCEncode` is false.

### Tiers

| Tier | Members |
| --- | --- |
| `siloVideoCopyCodecs` | `h264`, `hevc` |
| `siloVideoBridgeCodecs` | `av1`, `vp9`, `vp8`, `mpeg2video`, `mpeg2`, `mpeg4`, `msmpeg4v3`, `vc1`, `wmv3` |
| `siloSourceContainers` (copy tier, plus the native-direct containers) | `mkv`, `matroska`, `ts`, `m2ts`, `mts`, `mpegts`, `mp4`, `mov`, `m4v` |
| `siloBridgeSourceContainers` (bridged / AV1-passthrough only) | `avi`, `wmv`, `asf`, `webm`, `flv`, `mpg`, `mpeg`, `m2v`, `vob`, `ogm`, `ogv`, `3gp`, `3g2`, `divx` |

The container tier exists because the long tail of a real catalog is
*container*-shaped, not just codec-shaped: mpeg4 lives in `.avi`, wmv3/vc1 in
`.wmv`/`.asf`, vp9/av1 in `.webm`. A bridge tier that only widened the codec set
would still be refused with `container_not_normalizable`. libavformat demuxes
all of them; the copy tier is deliberately left alone because a *copied*
bitstream out of these containers has never been validated against AVPlayer's
fMP4 expectations.

`siloContainerIsNormalizable(_:videoOutputMode:)` is therefore
mode-dependent, and the planner calls it **after** resolving the video mode.

### Gates

| Gate | Value | Rationale |
| --- | --- | --- |
| Dynamic range | SDR only (`transferKind(for:) ?? "SDR"` must be `"SDR"`) | A PQ/HLG re-encode needs the full 10-bit colour chain — P010 buffers, Main10 profile, explicit primaries/transfer/matrix, mastering-display side data — and missing any one paints washed-out or over-bright |
| Resolution | ≤ 1920 × 1080 (`bridgeResolutionIsSupported`) | Software decode of 4K VP9/AV1 is CPU-bound even threaded and would stutter ahead of the playhead on Apple TV. An **unknown** resolution passes: the server's metadata is missing, not large, and the runtime watchdog is the backstop |
| Serving mode | VOD plan only | The bridge cuts segments by forcing encoder keyframes at plan boundaries, which needs a resolved plan. Since the EVENT serving mode was retired on 2026-08-17 this is the only loopback mode, so it is no longer a bridge-specific requirement |

### Blockers and trace tokens

| Token | Kind | Meaning |
| --- | --- | --- |
| `dv_not_bridgeable` | blocker | Dolby Vision on a non-copyable codec |
| `video_not_bridgeable` | blocker | Codec in neither the copy nor the bridge set (e.g. Theora) |
| `video_hdr_bridge_unsupported` | blocker | Bridge codec with a PQ/HLG transfer |
| `video_bridge_resolution_unsupported` | blocker | Bridge codec above 1080p |
| `container_not_normalizable` | blocker | Container outside the tier the resolved mode unlocks |
| `silo_video_bridge_hevc` / `silo_video_bridge_h264` / `silo_video_av1_passthrough` | trace | The resolved output mode |
| `silo_reason_<codec>_video_bridge_loopback` | trace | e.g. `silo_reason_vp9_video_bridge_loopback` |
| `av1_passthrough_loopback` | reason | AV1 remux route reason |

Blockers from the Silo assessment are prefixed `silo_` when they reach
`PlaybackExecutionPlan.parityBlockers` (so `video_not_bridgeable` appears as
`silo_video_not_bridgeable`), and each also emits `blocker_<token>` in the
decision trace.

A bridged plan adds the degradation warning
**"Video is re-encoded on this device; quality is reduced."**

### Capability probe

```swift
struct AppleVideoBridgeCapabilities: Equatable {
    let supportsAV1HardwareDecode: Bool
    let supportsHEVCEncode: Bool
}
```

`probe()` reads `VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)` and
`LoopbackVideoBridge.hevcEncoderAvailable`. AV1 is forced to `false` inside the
simulator, because `VTIsHardwareDecodeSupported` answers for the **host Mac's
GPU** there — an AV1-capable development Mac would otherwise make the simulator
claim an AV1 passthrough the device cannot honor. Separating the probe from the
decision is exactly why `loopbackVideoOutputMode` can stay pure.

## 3. Encoder configuration

- Pixel format `AV_PIX_FMT_NV12`; swscale with `SWS_POINT` because dimensions
  never change (the bridge re-encodes, it does not rescale) so an interpolating
  filter would only cost CPU.
- `gop_size = ceil(targetSegmentDuration × fps)`; frame rate from
  `LoopbackSessionSpec.sourceVideoFrameRate`, defaulting to 24.
- Colour: source `color_range` / `primaries` / `trc` / `colorspace` when
  specified, else MPEG range + BT.709 across the board.
- `AV_CODEC_FLAG_GLOBAL_HEADER` when the output format asks for it, so the
  wrapper publishes `hvcC`/`avcC` as extradata instead of inlining parameter
  sets — which is what `moov` needs.
- VideoToolbox private options, all best-effort: `allow_sw=1` (keeps the
  simulator and any device without the hardware encoder working),
  `realtime=0` (the producer deliberately runs ahead of the playhead under the
  VOD window throttle; latency is not the scarce resource, quality-per-bit is),
  `prio_speed=1` (trades a little quality for thermal headroom).
- Decoder threading matches what the old software-decode path tuned:
  `thread_count = min(activeProcessorCount, 6)`, `FF_THREAD_FRAME |
  FF_THREAD_SLICE`, so decode does not starve the audio bridge, the ISO box
  splitter, and the segment writes sharing the mux thread.
- AV1 decode explicitly names `libdav1d` (falling back to the native decoder),
  since dav1d is dramatically faster and is a hard dependency of the vendored
  product.

Bitrate ladder (HEVC targets, ×1.6 for H.264), clamped to 1.2× the source's own
average so a 900 kbps 1080p web rip is not re-encoded to 6 Mbps and blown
through the generated-ahead and spill budgets, with a 400 kbps floor:

| Long edge | HEVC target |
| --- | --- |
| < 641 | 1 Mbps |
| < 1281 | 3 Mbps |
| < 1921 | 6 Mbps |
| < 2561 | 10 Mbps |
| ≥ 2561 | 18 Mbps |

`rc_max_rate` is 1.5× the target.

## 4. Writer integration

Every touchpoint in
[`LoopbackSegmentWriter`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/LoopbackSegmentWriter.swift)
is guarded by `videoOutputMode.isBridged` and mirrors the audio bridge's
equivalent:

- **Stream setup.** `openVideoTranscodePipeline(inputStream:outputStream:)`
  builds the bridge and fills the already-allocated output stream from the
  **encoder**, never the source. Dimensions and time base still come from the
  source. `nalLengthSize = 4` because VideoToolbox emits AVCC-style NALs with
  4-byte length prefixes.
- **Forced keyframes at plan boundaries.**
  `installBridgedVideoPlanIfNeeded()` hands the bridge the plan's source-PTS
  fences from the session's anchor segment onward. Before each frame,
  `consumeForcedKeyframe(pts:)` checks whether the PTS crossed the next
  boundary and, if so, stamps `AV_PICTURE_TYPE_I` plus the key flag on the
  frame. Output keyframes then land **exactly** on plan boundaries, so every
  cutter, restart gate, and naming-drift check works unmodified. EVENT sessions
  have no plan; the bridge synthesizes a uniform stride from
  `targetSegmentDuration` so `+frag_keyframe` still cuts on cadence.
- **Uniform plan.** `LoopbackSegmentPlan.build(..., forceUniformStride:
  videoOutputMode.isBridged)`. A bridged session's output keyframes are the
  encoder's, forced onto uniform fences; the *source* cue index describes a
  keyframe cadence that no longer exists downstream. The anchor-opener probe is
  skipped for the same reason — the plan's openers are random-access by
  construction.
- **Parameter-set carry-forward across VOD restarts.** AVPlayer fetches
  `EXT-X-MAP` once per item, so a restarted producer must install the **first**
  session's `hvcC`/`avcC` rather than whatever its own fresh encoder
  synthesizes. The first producer publishes them through
  `onBridgedVideoParameterSetsResolved`; `AVPlayerBackend` pins them onto the
  strategy's spec with
  `LoopbackSessionSpec.carryingBridgedVideoParameterSets(_:)`, and
  `reanchored(at:)` carries the field into every restart. On restart,
  `installBridgedVideoParameterSets(on:)` installs the carried record **and
  asserts the fresh encoder produced identical bytes** — a mismatch throws
  `videoTranscodeSetup("bridged video parameter sets drifted across producer
  restart")` rather than publishing segments the item's `init.mp4` cannot
  decode.
- **Restart pre-roll.** A bridged restart cannot gate on the *source* keyframe:
  the decoder needs the source keyframe preceding the boundary to produce
  anything at all. So `vodShouldDropPacket` lets everything through, the
  bridge's own `emitThresholdPTS` decodes-but-never-encodes below the anchor
  boundary, and `openBridgedRestartGateIfNeeded` opens the audio gate on the
  first *encoded* packet.
- **Priming.** If the wrapper did not publish parameter sets at
  `avcodec_open2`, `primeBridgedVideoExtradataIfNeeded()` reads up to 128 video
  packets (8000 total), encodes them into `pendingVideoPackets` for replay after
  `writeHeader`, and stops as soon as the record appears. This is the bridged
  twin of `bootstrapVideoExtradata`'s contract.
- **CODECS string.** `masterVideoCodecString()` builds the RFC 6381 token from
  the *encoder's* record. FFmpeg's VideoToolbox wrappers publish extradata as
  **Annex-B parameter sets**, not an ISO configuration record; `movenc`
  converts them on the way into `moov` (so `init.mp4` is correct) but parsing
  those bytes as `hvcC` yields a nonsense `hvc1.0.….L0` that AVPlayer's
  master-variant filter drops. `LoopbackVideoBridge.codecStringHeader`
  therefore synthesizes the prefix from the SPS — and strips `0x03`
  emulation-prevention bytes, which is load-bearing: an HEVC SPS for a
  Main-profile stream carries six zero constraint bytes right before
  `general_level_idc`, so the escape lands inside the very field range the
  codec string is read from.
- **Startup runway.** `defaultMinimumStartupMediaDuration` returns 4.0 s for
  bridged output, versus 12.0 s for `.passthroughH264`: bridged output has a
  tight, predictable GOP, so the long-GOP allowance buys nothing but latency.
- **Flush.** `finishTranscodedVideo()` runs a clean-EOF drain (decoder flush →
  encode the tail → encoder flush) before `finishTranscodedAudio` and before
  `flushPendingMuxVideoPacket(nextDTS: nil)`, so the encoder's last GOP is
  routed while the look-behind can still telescope its duration. It is never
  called on cancellation — a cancelled session's tail is discarded, exactly like
  the audio bridge's.

### Throughput watchdog → server HLS

Wall-clock time is measured **inside** the bridge, not against the mux loop's
clock, because the producer legitimately parks for minutes in
`waitForVODWindowIfNeeded` — which would otherwise read as a stalled encoder.
After at least 10 s of accumulated encode wall time, if
`mediaSeconds / encodeWallSeconds` drops below **1.1× realtime**, the bridge
throws `LoopbackWriterError.videoBridgeTooSlow(fps:required:)`. That fails the
loopback session, and the view model's
[fallback ladder](01-overview-and-entrypoints.md#6-the-fallback-ladder) requests
a server HLS replan — stuttering forever behind a too-slow software decode is
strictly worse than a server transcode.

Decode errors are handled differently: a hard `avcodec_send_packet` /
`avcodec_receive_frame` failure is counted and logged (first five only), not
thrown. A damaged GOP must not fail the whole session.

## 5. Hardware findings (measured 2026-08-16)

On **Apple TV 4K (3rd gen), tvOS 26.6**:

- Hardware HEVC (`hvc1`) and H.264 (`avc1`) VideoToolbox **encoders** are
  available at both 1080p and 4K.
- HEVC **Main10** profile is accepted by the encoder.

In the vendored **mpvkit** FFmpeg build (the non-GPL product):

- `hevc_videotoolbox` and `h264_videotoolbox` encoders are present.
- `libdav1d`, `vp8`, `vp9`, `mpeg2video`, `mpeg4`, `msmpeg4v3`, `vc1`, and
  `wmv3` decoders are present — which is exactly the membership of
  `siloVideoBridgeCodecs`.

The 4K encoder and Main10 findings are what make the phase-2 items below
tractable: neither is blocked by missing hardware, only by unvalidated
correctness and CPU budget.

## 6. Phase-2 items

Not implemented. Do not read these as current behavior.

- **HDR10 through the bridge (Main10).** The encoder accepts Main10 on Apple TV
  4K, so the blocker is the rest of the chain: P010 pixel buffers end to end,
  explicit primaries / transfer / matrix on both the encoder context and the
  scaled frame, and mastering-display / content-light side data carried through
  so the HLS `VIDEO-RANGE` token and the tvOS display criteria agree with the
  bitstream. Until all of that lands, phase 1 blocks with
  `video_hdr_bridge_unsupported`. HLG would follow the same work.
- **Above 1080p.** The encoder is not the constraint; **software decode** is.
  Raising `siloVideoBridgeMaxWidth` / `siloVideoBridgeMaxHeight` needs a
  measured decode-throughput benchmark per codec on Apple TV hardware (4K
  VP9 and 4K AV1 are the interesting cases), not just a constant change.
- **Thermal handling.** `prio_speed=1` is the only concession today. A
  sustained-load policy — watching `ProcessInfo.thermalState` and either
  stepping the ladder down or handing off to server HLS before the device
  throttles — has not been designed or validated.
- **Dolby Vision** stays permanently out of scope for the bridge, by design.

## 7. Test coverage

- [`LoopbackVideoBridgePlannerTests`](../../iosApp/Tests/LoopbackVideoBridgePlannerTests.swift)
  pins the routing truth table with injected `AppleVideoBridgeCapabilities`, so
  the host's real VideoToolbox answers can never move the assertions. It covers:
  copy codecs stay on remux; every bridge codec resolves to `.transcodeHEVC`;
  the H.264 encoder fallback; AV1 passthrough only with hardware decode; unknown
  codecs blocked; **Dolby Vision never bridges** across profiles 5/7/8 and four
  codecs; the HDR block; the 1080p cap; the container tier split; and four
  end-to-end plans (VP9/WebM, MPEG-4/AVI, WMV3/WMV, H.264/MKV-still-copies) plus
  the Theora-falls-to-server-HLS case. It also pins the audio tail — mp3, mp2,
  vorbis, opus, wmav2, and multichannel dts/vorbis — because the containers the
  video bridge unlocks routinely carry codecs the mp4 muxer refuses to copy.
- [`LoopbackVideoBridgeWriterTests`](../../iosApp/Tests/LoopbackVideoBridgeWriterTests.swift)
  runs the **real** `LoopbackSegmentWriter` with the bridge engaged over
  committed fixtures (`v3_vp9_opus.webm`, `v3_mpeg4_mp3.avi`) and asserts the
  properties the rest of the pipeline depends on: the session finishes cleanly
  and produces media segments; `init.mp4` carries the encoder's codec, non-empty
  `hvcC`/`avcC`, and a matching `hvc1`/`avc1` sample entry; **every segment's
  first video sample is a sync sample**; the concatenated output decodes; and a
  bridged plan never uses the source keyframe index. The suite skips (rather
  than fails) when no VideoToolbox encoder can be opened, so a headless runner
  degrades gracefully.
- [`ApplePlaybackRoutePlannerPinTests`](../../iosApp/Tests/ApplePlaybackRoutePlannerPinTests.swift)
  was repinned in `6818819`: `testUncopyableVideoAndContainersRouteThroughTheVideoBridge`
  now asserts that `mkv`/av1, `mkv`/vp9, `avi`/mpeg4, and `mkv`/mpeg2video all
  reach the loopback instead of the removed CompatibilityPlayer, and defers the
  genuinely-unbridgeable case to
  `LoopbackVideoBridgePlannerTests.testUnbridgeableCodecFallsToServerHLS`.

## 8. Known gaps

- **Restart-with-bridge is untested on fixtures.** The writer tests only cover
  head-of-stream sessions. The parameter-set carry-forward assertion, the
  `emitThresholdPTS` pre-roll, and `openBridgedRestartGateIfNeeded` have no
  fixture-level coverage; a restarted bridged producer is currently only
  exercised by hand.
- **No hardware thermal validation.** The encoder capabilities were probed on
  Apple TV 4K, but no sustained-playback thermal soak has been run. The 1.1×
  throughput watchdog is the only runtime protection, and it measures
  throughput, not temperature.
- **The resolution cap passes unknown dimensions.** A source whose server
  metadata lacks width/height is admitted to the bridge regardless of its real
  size, relying entirely on the watchdog to catch a 4K file that slipped
  through. That is a deliberate trade (missing metadata is common; refusing on
  it would be worse) but it means the "≤ 1080p" guarantee is metadata-conditional.
- **Bitrate is source-clamped, not quality-measured.** The 1.2×-source clamp
  protects the spill budget but has no perceptual floor beyond 400 kbps; a
  pathologically low-bitrate source re-encodes to a pathologically low-bitrate
  output.

## Validation log

- verified: `LoopbackSessionSpec.VideoOutputMode` has exactly four cases and
  `isBridged` is true only for `.transcodeHEVC` / `.transcodeH264`.
- verified: `loopbackVideoOutputMode` is the only place the mode is decided, and
  it takes every device fact through `AppleVideoBridgeCapabilities`.
- verified: every decoder `siloVideoBridgeCodecs` names is present in the
  vendored non-GPL FFmpeg product, per the 2026-08-16 probe. (`mpeg2` is an
  alias token for `mpeg2video`, carried so a scanner-recorded spelling still
  matches.)
- verified: the bridge writes on the mux queue only — no worker thread, no
  callback thread; the FFmpeg VideoToolbox wrapper owns the
  `VTCompressionSession` and returns packets synchronously through
  `avcodec_receive_packet`.
- verified: `watchdogMinimumWallSeconds = 10` and
  `watchdogMinimumRealtimeRatio = 1.1` in `LoopbackVideoBridge`.
- verified: `bridgedVideoParameterSets` survives `reanchored(at:)` and is
  asserted for byte equality on restart.
