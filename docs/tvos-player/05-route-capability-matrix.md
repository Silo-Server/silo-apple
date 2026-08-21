# Apple Route Capability Matrix

Last verified against the code: 2026-08-20 (one-player consolidation; re-verified after the
Stage 2 control-plane extraction).
Prior snapshots: 2026-07-24 (SiloPlayer AirPlay hardware validation),
2026-07-03 (SiloPlayer loopback-primary Stages 0–4).

This matrix is the implementation-facing truth source for the current Apple
player routes in `silo-apple`. It mirrors
[`ApplePlaybackRouteCapabilities.swift`](../../iosApp/iosApp/Screens/Player/ApplePlaybackRouteCapabilities.swift),
which is the executable version of the same table. It separates:

- `Repo-verified`: behavior grounded in the current code path
- `Validation required`: behavior that may exist on some device/output paths
  but cannot be claimed yet
- `Unsupported` / `Unclaimed`: behavior Silo does not currently promise on that
  route

The matrix is informational. It feeds the per-route status rows in the player
options UI, and the Dolby Vision / Atmos claim flags on
`PlaybackRouteRequirements` still raise degradation warnings. It no longer gates
route selection: the requirements-vs-capabilities blocker check
(`blockingReasons(for:)`) was removed on 2026-08-17 because every capability it
could block on was `Repo-verified` on every surviving route, so it never
produced a blocker. Route eligibility is decided by the container / codec /
subtitle allowlists in `ApplePlaybackRoutePlanner` alone.

## Routes

The `playerCoreDirect` / CompatibilityPlayer column is **gone** — the backend
was deleted on 2026-08-16 (see
[02](02-retired-compatibility-player.md)). Three routes remain, all AVPlayer.

| Implementation route | Route family | Display label | Current role |
| --- | --- | --- | --- |
| `avPlayerNativeDirect` | NativePlayer | Native Player Direct | Narrow native-direct path for allowlisted `mp4` / `mov` / `m4v` assets whose video, audio, and embedded subtitle codecs all match the Apple allowlist |
| `siloPlayerLoopback` | SiloPlayer | Direct Stream | **Primary** direct playback. Remuxes H.264/HEVC/Dolby Vision and nothing else — the on-device video bridge that once covered the non-copyable codec tail was retired 2026-08-17 (see [09](09-video-bridge.md)). Static VOD is the only serving path: `LoopbackSegmentWriter.emitMediaPlaylist` writes the whole plan up front with `#EXT-X-PLAYLIST-TYPE:VOD` and `#EXT-X-ENDLIST`, and a session whose plan is unresolvable or untrusted throws `bootstrapFailed("vod_plan_unavailable" / "vod_plan_untrusted_keyframe_index")` so the ladder replans instead of degrading. The EVENT serving mode and its `player.apple.siloplayer_primary_enabled` kill switch were retired 2026-08-17; the writer's internal EVENT degrade followed on 2026-08-20. Hardware-validated 2026-07-03 (DV P8 + EAC3 on Apple TV 4K) |
| `avPlayerHLS` | NativePlayer | Native Player HLS | Server-produced HLS for `remux` / `transcode` deliveries, and the **terminal fallback rung** for anything the loopback cannot normalize. No longer feature-flag gated |

## Matrix

| Capability | `avPlayerNativeDirect` | `siloPlayerLoopback` | `avPlayerHLS` |
| --- | --- | --- | --- |
| Primary audio selection | Repo-verified | Repo-verified | Repo-verified |
| Primary subtitle selection | Repo-verified on allowlisted assets | Repo-verified | Repo-verified |
| Sidecar primary subtitles | Repo-verified | Repo-verified | Repo-verified |
| Secondary subtitles | Repo-verified, sidecar-only | Repo-verified, sidecar-only | Repo-verified, sidecar-only |
| Embedded text subtitles (ASS/SSA/SRT/mov_text/WebVTT) | Repo-verified, Silo-rendered via the extractor | Repo-verified, extracted or registered by the writer's subtitle tap | Repo-verified, server or sidecar |
| Embedded bitmap subtitles — PGS / DVD-sub / VobSub | Unsupported (blocker `embedded_subtitles_require_hls`, route falls to loopback or HLS) | Repo-verified, client-rendered as RGBA cues | Server burn-in / server-selected |
| Embedded bitmap subtitles — DVB | Unsupported | Unsupported (blocker `bitmap_subtitles_require_hls`) | Server burn-in / server-selected |
| Subtitle delay | Silo-rendered tracks only | Silo-rendered tracks only | Silo-rendered tracks only |
| Subtitle styling | Silo-rendered tracks only | Silo-rendered tracks only | Silo-rendered tracks only |
| Chapters | Repo-verified | Repo-verified | Repo-verified |
| Buffered-ahead reporting | Repo-verified | Repo-verified | Repo-verified |
| Video gravity control | Repo-verified | Repo-verified | Repo-verified |
| HDR passthrough toggle | Removed | Removed | Removed |
| Audio delay | Unsupported | Unsupported | Unsupported |
| tvOS custom shell / Siri Remote ownership | Repo-verified | Repo-verified | Repo-verified |
| Now Playing / remote commands | Repo-verified | Repo-verified | Repo-verified |
| PiP | Validation required | Validation required | Validation required |
| AirPlay / external playback | Unsupported | Repo-verified | Validation required, downloads only |
| Premium HDR / DV / Atmos claims | Validation required | Validation required | Validation required |

### Loopback source eligibility (SiloPlayer only)

There is no video output-mode axis any more. The loopback writer copies the
video bitstream and does nothing else, so eligibility is just "is this codec
in the copy set, in a container the writer can open": `assessSiloRoute` tests
`ApplePlaybackRoutePlanner.siloVideoCopyCodecs` and
`siloContainerIsNormalizable(_:)` directly. `LoopbackSessionSpec.VideoOutputMode`
and `loopbackVideoOutputMode(for:)` were deleted on 2026-08-18 (`c87dc6e`),
once the on-device decode → VideoToolbox re-encode bridge and `.passthroughAV1`
had gone the day before and left the enum with a single `.copy` case.
Historical detail in [09 - On-device video bridge (retired)](09-video-bridge.md).

| Sub-capability | `siloPlayerLoopback` |
| --- | --- |
| Video codecs copied | Repo-verified — `h264`, `hevc`, and every Dolby Vision `VideoMode` |
| Every other video codec | Blocked with `video_not_copyable`; the route falls to `avPlayerHLS` and the server transcodes |
| Containers | Repo-verified — `mkv`/`matroska`, `ts`/`m2ts`/`mts`/`mpegts`, `mp4`/`mov`/`m4v`. Anything else is `container_not_normalizable` |
| Audio | Not a copy-only axis: `loopbackAudioOutputMode(for:)` copies `aac`/`ac3`/`eac3` and transcodes everything else to FLAC (>2 channels, or TrueHD) or AAC |

## Notes

- Audio delay is not implemented on any AVPlayer route, so it must not be
  surfaced as supported anywhere. The only surviving surface is a read-only
  status row in the macOS options panel.
- The HDR passthrough toggle was removed with `PlayerCore`. HDMI mode selection
  is negotiated from the stream's own colour signalling by
  [`TVDisplayCriteria`](../../iosApp/iosApp/Screens/Player/Shared/TVDisplayCriteria.swift).
  `PlayerSettings.setHDREnabled(_:)` survives for settings-wire compatibility
  only, and the cast channel no longer accepts a `set_hdr_enabled` command
  (see [cast-remote.md](cast-remote.md)).
- `avPlayerNativeDirect` is intentionally narrow. It applies only to direct
  assets whose container, codecs, and embedded subtitle shape all match the
  client-side allowlist.
- Secondary subtitles remain sidecar-only on every route. The UI must not imply
  arbitrary embedded-secondary parity.
- "Silo-rendered tracks" means subtitle tracks whose presentation goes through
  the shared libass session: text sidecars, FFmpeg-extracted text tracks, and
  ASS/SSA streams. Silo delay and styling apply only to those tracks.
- Bitmap subtitles changed shape. `siloClientRenderedBitmapSubtitleCodecs`
  (`pgs`, `hdmv_pgs_subtitle`, `dvd_subtitle`, `vobsub`) are decoded into RGBA
  cue images by the AVPlayer subtitle extractor and rendered in the overlay, so
  they no longer force a server burn-in route. DVB is deliberately excluded —
  its broadcast region/CLUT model is unvalidated here — and still raises
  `bitmap_subtitles_require_hls`.
- Native AVFoundation caption fallback (used when the libass extraction path is
  unavailable for a given asset/route) does not honor Silo delay/styling. The
  rows above describe what Silo can promise per route; they are not a claim
  about every embedded subtitle on an asset.
- PiP stays conservative until Silo has route-specific lifecycle handling and
  device/output validation. PiP itself is enabled on the iOS AVPlayer routes;
  tvOS PiP is unsupported. Silo-rendered subtitles do not appear in the PiP
  window.
- AirPlay video hands the receiver a URL and nothing else: the receiver opens
  its own HTTP connection without the asset's `AVURLAssetHTTPHeaderFieldsKey`
  headers. NativePlayer assets are receiver-fetchable when their server URL
  carries the signed `st` playback capability, because the client deliberately
  omits the shorter-lived account `Authorization` header. They remain
  unfetchable when `prepareSourceProxy` rewrites the URL to the on-device
  caching proxy at 127.0.0.1. External playback and the route picker are enabled
  only for assets that survive that reachability check; unsigned legacy server
  URLs still use account-header auth and therefore remain device-local.
- On iOS, SiloPlayer publishes its generated HLS through a LAN URL carrying a
  per-session access token, so the selected receiver can fetch the playlist and
  segments. The server binds to the LAN but refuses off-device connections until
  a handoff is live, and advertises only a Wi-Fi/Ethernet RFC1918 address. If no
  such address exists, playback stays on the device with a notice instead of
  stranding the receiver. Hardware-validated 2026-07-24 from an iPhone 16 Pro to
  Apple TV with a Dolby Vision source. This validates external playback for that
  route, not a generalized Dolby Vision output-mode or premium-format claim.
- Premium-media claims stay validation-gated on every route.

## Validation log

- verified: `ApplePlaybackRouteCapabilities` declares exactly four profiles —
  `avPlayerHLS`, `avPlayerNativeDirect`, `siloPlayerLoopback`, and
  `macAVFoundation`. There is no `playerCoreDirect` profile.
- verified: every route's `backendCapabilities` is
  `PlayerBackendCapabilities.avFoundation` (macOS uses `macAVFoundation`), so
  buffered-ahead, chapters, external primary subtitles, secondary subtitles, and
  video gravity are uniformly available; subtitle delay/styling are raised
  per-track by `withSubtitleControls(_:)`.
- corrected 2026-08-17: the video-bridge rows and their
  `LoopbackVideoBridgePlannerTests` pin are gone with the tier. The surviving
  copy/blocked truth table is pinned by
  [`ApplePlaybackRoutePlannerPinTests`](../../iosApp/Tests/ApplePlaybackRoutePlannerPinTests.swift)
  and [`ApplePlaybackDecisionTraceSnapshotTests`](../../iosApp/Tests/ApplePlaybackDecisionTraceSnapshotTests.swift).
- corrected: the `HDR toggle` row previously read `Repo-verified` for
  `playerCoreDirect`. Both the route and the toggle are gone.
- corrected: bitmap subtitles are no longer a blanket gap. PGS/DVD-sub/VobSub
  render client-side on the loopback route; only DVB still forces the server.
- corrected (2026-08-17): the matrix no longer blocks routes. `blockingReasons`
  and the `needs*` / `keeps*` requirement flags it consumed are gone; the two
  premium-claim flags and the per-route capability entries stay.
- corrected (2026-08-20): the `siloPlayerLoopback` role cell claimed an
  internal growing-playlist fallback for sources without a safe VOD plan. There
  is none. `LoopbackSegmentWriter.emitMediaPlaylist` is the only media-playlist
  emitter and always writes `#EXT-X-PLAYLIST-TYPE:VOD` + `#EXT-X-ENDLIST`;
  `resolveVODPlanIfNeeded` throws `bootstrapFailed(...)` when the plan is
  missing or untrusted, so the route ladder replans. The degrade was removed in
  `0921dad`, and `LocalHLSPlaylistPolicy.playlistType` / `.liveSliding` survive
  with no production caller (tests only).
- corrected (2026-08-20): the "Video output mode" section described
  `LoopbackSessionSpec.VideoOutputMode` and
  `ApplePlaybackRoutePlanner.loopbackVideoOutputMode(for:)` in the present
  tense. Both were deleted on 2026-08-18 (`c87dc6e`); the section is now
  "Loopback source eligibility" and cites `siloVideoCopyCodecs` /
  `siloContainerIsNormalizable(_:)`, the symbols `assessSiloRoute` actually
  reads. Its VideoToolbox-encoder hardware-validation row went with the
  section — no route encodes video.
- verified (2026-08-20): the matrix is untouched by the Stage 2 control-plane
  extraction. `ApplePlaybackRouteCapabilities` still has the same four profiles
  and the same per-route entries; route choice is still
  `ApplePlaybackRoutePlanner`. Recovery moved to `RecoveryPolicy`, but recovery
  never fed this matrix.
