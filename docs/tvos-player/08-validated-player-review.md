> [!WARNING]
> **Historical pre-AetherEngine archive.** This document describes the removed custom-player architecture or its pre-migration validation model. It is retained for history only and must not be used as current implementation guidance. See the [AetherEngine-only replacement specification](aetherengine-replacement-spec.md).

Repo snapshot date: 2026-04-29 (HEAD `6c2b4af`)

# Silo tvOS/iOS Player Validated Review

This report is a corrected, code-grounded review of the Apple player stack after
section-by-section verification against the current repository. It keeps only
findings that were confirmed or narrowed by source inspection, and calls out
claims that should not be carried forward as implementation work.

Status meanings:

- **Confirmed**: the claim is supported by current source or docs.
- **Narrowed**: the claim points at a real issue, but the original wording was
  too broad or assigned the issue to the wrong file/path.
- **False**: current source contradicts the claim.

## Executive Summary

The route taxonomy is correct:

- **NativePlayer** covers `avPlayerNativeDirect` and `avPlayerHLS` routes through
  [`AVPlayerBackend.swift`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift).
- **SiloPlayer** currently means `avPlayerLocalDVLoopback`: local FFmpeg remux,
  fragmented MP4/HLS segmenting, ISO box patching, and localhost AVPlayer
  playback.
- **CompatibilityPlayer** means `playerCoreDirect`: FFmpeg demux/decode helpers,
  VideoToolbox where possible, `AVSampleBufferDisplayLayer`, and
  `AVAudioEngine` output in [`PlayerCore.swift`](../../iosApp/iosApp/Screens/Player/CoreMedia/PlayerCore.swift).

The highest-value work from this review is:

1. Fix stale docs and capability wording around CompatibilityPlayer audio and
   route-limited subtitle behavior.
2. Surface SiloPlayer mux/file-write failures through the player error path.
3. Surface CompatibilityPlayer audio engine setup/start failures through
   `onError`.
4. Add route-plan validity/device-output capability modeling before making
   stronger HDR/Dolby Vision promises.
5. Treat bitmap subtitles as a real user-visible gap, not a logging-only issue.
6. Add bounded failure/diagnostic behavior for playback session reporting,
   realtime reconnects, and source-proxy stalls.

## Architecture Findings

| Finding | Status | Evidence | Notes |
| --- | --- | --- | --- |
| NativePlayer is the AVPlayer-backed route family for native-direct and HLS. | Confirmed, narrowed | [`PlaybackExecutionPlan.swift`](../../iosApp/iosApp/Screens/Player/PlaybackExecutionPlan.swift), [`ApplePlaybackRoutePlanner.swift`](../../iosApp/iosApp/Screens/Player/ApplePlaybackRoutePlanner.swift), [`AVPlayerBackend.swift`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift) | Native direct is not just "mp4/mov/m4v"; it is gated by container, codecs, subtitles, and route capabilities. Direct playback can also be rewritten through `PlaybackSourceProxy` to a localhost source URL. |
| SiloPlayer is the local Dolby Vision loopback implementation. | Confirmed, narrowed | [`DVSegmentWriter.swift`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/DVSegmentWriter.swift), [`DVSegmentServer.swift`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/DVSegmentServer.swift), [`ISOBoxSurgery.swift`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/ISOBoxSurgery.swift) | Silo is not a general "all non-native remux" path. H.264 and SDR HEVC loopback are explicitly blocked back toward CompatibilityPlayer in the planner. |
| CompatibilityPlayer is the owned FFmpeg/CoreMedia path. | Confirmed, narrowed | [`PlayerCore.swift`](../../iosApp/iosApp/Screens/Player/CoreMedia/PlayerCore.swift), [`PlayerSurface.swift`](../../iosApp/iosApp/Screens/Player/CoreMedia/PlayerSurface.swift) | VideoToolbox is the normal video path, but H.264 can switch to software decode after VT failures. |
| `ApplePlaybackRoutePlanner` chooses routes from more than source metadata. | Confirmed | [`ApplePlaybackRoutePlanner.swift`](../../iosApp/iosApp/Screens/Player/ApplePlaybackRoutePlanner.swift), [`PlaybackSessionBridge.swift`](../../iosApp/iosApp/Screens/Player/PlaybackSessionBridge.swift) | Decisions also depend on server delivery method, route requirements, selected tracks, the HLS feature flag, session data, and Profile 7 fallback preference. |

## Docs And Capability Matrix

| Finding | Status | Recommended Fix |
| --- | --- | --- |
| [`02-coremedia-pipeline.md:15, 117`](./02-coremedia-pipeline.md) and [`README.md:38`](./README.md) still say CompatibilityPlayer audio uses `AVSampleBufferAudioRenderer`. Current code uses `AVAudioEngine` ([`PlayerCore.swift:74`](../../iosApp/iosApp/Screens/Player/CoreMedia/PlayerCore.swift#L74)) plus `AVAudioSourceNode`. | Confirmed | Update both docs to describe `AVAudioEngine` output. |
| H.264 software fallback is missing from `docs/tvos-player`, but not from every repo doc. | Narrowed | Add a short current-behavior note to the tvOS docs and link the existing plan doc if useful. |
| `PlaybackSourceProxy` downstream high/low water behavior is partially documented in plan docs, but not the concrete 128 MiB / 64 MiB implementation detail or tvOS-player behavior. | Narrowed | Add a concise source-proxy/backpressure note in this docs suite. |
| `preferProfile7HDR10Fallback` is not documented by literal setting/flag name. | Confirmed, narrowed | Document the setting name, route effect, and user-visible Profile 7 HDR10 fallback behavior. Existing docs mention the general fallback concept. |
| `05-route-capability-matrix.md` says subtitle delay/styling are "Controlled tracks only" for Native/Silo, while capability code marks those route capabilities `.repoVerified`. | Confirmed, narrowed | Align the table and code wording around the actual scope: Silo-rendered sidecar/controlled tracks, not all native embedded subtitle behavior. |

## Critical Issues

| Issue | Status | Severity | Evidence | Recommended Fix |
| --- | --- | --- | --- | --- |
| `PlayerView` owns `PlayerViewModel` with `@State`. The VM `init()` launches a fire-and-forget `Task` calling `refreshSettingsFromServer()`. | Narrowed | Low | [`PlayerView.swift:18`](../../iosApp/iosApp/Screens/Player/PlayerView.swift#L18), [`PlayerViewModel.swift:696`](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift#L696) | `@State` with an `@Observable` VM is valid. Two distinct concerns: (a) the init-time refresh races with `loadAndPlay`, so defer it or make load wait on settings; (b) the `Task` has no handle, so cancellation on dismiss isn't possible. Hold it as an owned `Task` field and cancel in cleanup. |
| `progressTask` and `hideControlsTask` capture `self` strongly. | Confirmed | High for progress, medium for hide | [`PlayerViewModel.swift:4279, 4296`](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift#L4279) | Add `[weak self]` and exit if `self` is gone. Cleanup normally cancels these, but missed cleanup can retain the VM. |
| `DVSegmentServer.start()` blocks on a semaphore for up to 2 seconds. | Confirmed | Medium | [`DVSegmentServer.swift:106`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/DVSegmentServer.swift#L106), [`AVPlayerBackend.swift`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift) | Convert server start to async/throwing startup so Silo setup does not block the main actor path. |
| Silo mux write failures are not consistently fatal. | Confirmed, narrowed | High | [`DVSegmentWriter.swift:374, 767, 1654`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/DVSegmentWriter.swift#L374) | The main loop (`:374`) and pending-audio path (`:767`) log failures from `av_interleaved_write_frame` but continue; only the encoded-audio path (`:1654`) throws. Count/surface the log-only sites and abort through `onFinished(error)` after a small threshold. |
| Silo file write failures are logged but not surfaced. | Confirmed | High | [`DVSegmentWriter.swift:2212, 2260, 2477, 2503`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/DVSegmentWriter.swift#L2212) | Init segment (`:2212`), media segment (`:2260`), media playlist (`:2477`), and master playlist (`:2503`) writes catch-and-log without firing `onFinished(error)`. Route them through the error path. |
| CompatibilityPlayer audio graph/start failures do not fire player errors. | Confirmed | High | [`PlayerCore.swift:177, 197`](../../iosApp/iosApp/Screens/Player/CoreMedia/PlayerCore.swift#L177) | Setup (`:177`) and `engine.start()` (`:197`) only assign `lastErrorDescription`. Wire both into `onError` so the VM can fall back or surface a user-visible failure. |
| Playback progress and stop-session API calls discard errors with `try?`. | Confirmed | Medium | [`PlaybackSessionBridge.swift:452, 465, 471`](../../iosApp/iosApp/Screens/Player/PlaybackSessionBridge.swift#L452) | Log failures at minimum; track stale stop/progress failures so orphaned server sessions are observable. |
| Realtime websocket reconnect retries indefinitely while bound. | Confirmed | Low/medium | [`PlaybackRealtimeClient.swift:15-20, 92`](../../iosApp/iosApp/Screens/Player/PlaybackRealtimeClient.swift#L15) | `reconnectDelaysNanos` plateaus at the last entry (~5s) and reconnects forever. Add a consecutive-failure cap or auth-specific circuit breaker, and surface a non-fatal "realtime control unavailable" state. |
| `Thread.sleep(0.002)` polling exists on the video feed path. | Confirmed | Low | [`PlayerCore.swift:3944`](../../iosApp/iosApp/Screens/Player/CoreMedia/PlayerCore.swift#L3944) | Replace with the existing wait/broadcast style used elsewhere when touching this path. |
| AVPlayer FFmpeg-extracted subtitle tracks force SDH metadata false, and bitmap subtitles are ignored. (See also Subtitles #1, #3.) | Confirmed | Medium | [`AVPlayerEmbeddedSubtitleExtractor.swift:403-406, 433-441`](../../iosApp/iosApp/Screens/Player/Subtitles/AVPlayerEmbeddedSubtitleExtractor.swift#L403) | Preserve disposition flags for text tracks; add bitmap subtitle rendering or a user-visible unsupported-subtitle warning. |
| `PlaybackSourceProxy` handles send errors and has a startup timeout, but no stall-without-error watchdog during active streaming. | Narrowed | Medium | [`PlaybackSourceProxy.swift:278-279, 527-528`](../../iosApp/iosApp/Screens/Player/PlaybackSourceProxy.swift#L278) | Startup timeout exists at `:278-279`; high/low water marks (128 MiB / 64 MiB) at `:527-528`. Add a progress watchdog for the active-streaming state where downstream bytes remain high and neither send completion nor URLSession completion fires. |
| Earlier `onSidecarTracksRegistered` disposed-state concern. | False | None | [`PlayerViewModel.swift:742`](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift#L742), [`PlayerCore.swift:2011`](../../iosApp/iosApp/Screens/Player/CoreMedia/PlayerCore.swift#L2011) | Do not carry this forward. The VM callback at `:742` guards `!isDisposed`, and `PlayerCore.registerSidecarSubtitles` at `:2011` also guards. |

## CompatibilityPlayer Priorities

| Finding | Status | Recommended Fix |
| --- | --- | --- |
| VT output HDR/color attachments are not manually applied the way the software path applies them. | Narrowed | Treat as a validation gap. VT format description color keys and HDR metadata propagation are present, so runtime buffer inspection is needed before claiming the VT output is untagged. |
| The report claimed `kVTDecompressionPropertyKey_PropagatePerFrameHDRDisplayMetadata` is never set. | False | Do not carry this forward. Current code sets the property on the VT session. |
| `AudioEngineAudioOutput.render` takes an `NSLock` on the real-time audio callback. | Confirmed ([`PlayerCore.swift:76`](../../iosApp/iosApp/Screens/Player/CoreMedia/PlayerCore.swift#L76) declares `stateLock`; ~35 acquisitions, several inside the render path) | Move real-time state to a lock-free or bounded strategy, such as a single-producer/single-consumer ring buffer or carefully scoped unfair lock if unavoidable. |
| The display-link path has stall recovery, but no dedicated "CADisplayLink stopped ticking" watchdog. | Narrowed | Add a specific display-link/no-frame-progress diagnostic if freezes are observed or when working in this area. |
| `AVAudioSession` route-change and media-services reset notifications are not observed. | Confirmed | Add route-reset handling in the playback owner or shared audio-session coordinator. |

## SiloPlayer Priorities

| Finding | Status | Recommended Fix |
| --- | --- | --- |
| Serial mux queue, fMP4 box walker, `dvvC` injection, and `hvcC` synthesis exist. | Confirmed, narrowed | Keep this architecture. Note that `dvvC` injection is nil-on-box-tree failure, not nil-on-every-failure. |
| `DVSegmentServer` is GET-only, ignores byte ranges, and always serves whole files as `200 OK`. | Confirmed ([`DVSegmentServer.swift:14-18`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/DVSegmentServer.swift#L14) header comment matches code) | Add HEAD and RFC 7233 byte-range support. |
| Old segments are not evicted during playback. | Confirmed | Add rolling segment retention and playlist media-sequence handling. |
| Loopback forward buffer is hardcoded. | Narrowed | Starts at 4 seconds ([`AVPlayerBackend.swift:32`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift#L32) `loopbackStartupForwardBuffer`), then ramps to hardcoded 30 seconds ([`:41`](../../iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift#L41) `loopbackSteadyStateForwardBuffer`). The `01dc0df` perf commit tightened the writer's startup runway but did not touch these constants. Make the steady-state target adaptive or configurable by bitrate. |
| `canUseNetworkResourcesForLiveStreamingWhilePaused` is not set on the loopback item. | Confirmed | Consider enabling it for the loopback HLS item if pause behavior benefits and battery/network implications are acceptable. |
| Existing PiP plumbing is disabled sample-buffer PiP in `PlayerCore`. | Narrowed ([`PlayerCore.swift:1336-1339`](../../iosApp/iosApp/Screens/Player/CoreMedia/PlayerCore.swift#L1336) early-returns the PiP setup; uses `AVSampleBufferDisplayLayer`) | Treat Native/Silo PiP as separate AVPlayer-route work, not a free reuse of current `PlayerCore` PiP code. |

## Route Planner Priorities

| Finding | Status | Recommended Fix |
| --- | --- | --- |
| `PlaybackExecutionPlan` has no typed validity enum. | Narrowed | Add a typed validity model if consumers need behavior changes. Current consumers mostly log/pass `parityBlockers`; string matching happens mainly inside planner assessment. |
| Planner inputs are not pure source metadata. | Confirmed | Split pure metadata decision inputs from runtime session/stream URL state to make route tests smaller and clearer. |
| No planner-level display/output capability probing exists. | Confirmed | Add an explicit device/display capability input instead of over-promising HDR/DV from source metadata and settings alone. |
| H.264 and SDR HEVC loopback branches are intentionally blocked in normal planner selection. | Confirmed, narrowed ([`ApplePlaybackRoutePlanner.swift:518-530`](../../iosApp/iosApp/Screens/Player/ApplePlaybackRoutePlanner.swift#L518) — `passthroughH264` returns `blockedSilo` with sentinel `h264_loopback_startup_unreliable`; commit `f59b7bc` restored this guard) | Keep or comment these as sentinels if backend support remains. They are not globally impossible, but normal route planning blocks them. |

## PlayerViewModel And Lifecycle

| Finding | Status | Recommended Fix |
| --- | --- | --- |
| State is independent booleans, not a finite state model. | Confirmed, narrowed ([`PlayerViewModel.swift:293, 297, 299`](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift#L293)) | A transient `isPlaying && isLoading && error != nil` assignment state is reachable. A typed playback state would reduce contradictory UI states. |
| Three recovery/escalation paths exist. | Confirmed, narrowed ([`PlayerViewModel.swift:1378, 1441, 1795`](../../iosApp/iosApp/Screens/Player/PlayerViewModel.swift#L1378) — native→compat, silo→compat, VT-H.264→silo HEVC) | The paths are not all feature-flag gated. They are guarded by active engine, prior-attempt flags, and rejection reason. |
| `MPNowPlayingInfoCenter` lacks artwork. | Confirmed ([`NowPlayingController.swift:78-88`](../../iosApp/iosApp/Screens/Player/NowPlayingController.swift#L78) populates title/duration/position/rate; no `MPMediaItemPropertyArtwork`) | Extend `NowPlayingController` to publish artwork when metadata/artwork is available. |
| Local and remote seeks share the same seek path. | Narrowed | The filter can reject backend time updates, not realtime ACKs. Keep this as a seek-state race risk, not an ACK bug. |
| `AVAudioSession` category is set independently by backends, not the VM. | Confirmed | Consider a shared audio-session coordinator if route switching or reset handling continues to grow. |

## Subtitles, Stats, And Backpressure

| Finding | Status | Recommended Fix |
| --- | --- | --- |
| Bitmap subtitles are user-silently not rendered. (Same code path as Critical Issues #10.) | Confirmed, narrowed ([`AVPlayerEmbeddedSubtitleExtractor.swift:403-406, 548-572`](../../iosApp/iosApp/Screens/Player/Subtitles/AVPlayerEmbeddedSubtitleExtractor.swift#L403)) | Logs exist, but users do not get visible feedback. Add rendering support or a visible warning. |
| "Forced subs when foreign audio" is not owned by [`SubtitleTrackIdentity.swift`](../../iosApp/iosApp/Screens/Player/Subtitles/SubtitleTrackIdentity.swift). | Narrowed | The cited file only defines identity/types. The real gap is policy: no explicit rule enables forced subtitles when audio is foreign. |
| AVPlayer FFmpeg-extracted SDH metadata is forced false. (Same code path as Critical Issues #10.) | Confirmed, narrowed ([`AVPlayerEmbeddedSubtitleExtractor.swift:433-441`](../../iosApp/iosApp/Screens/Player/Subtitles/AVPlayerEmbeddedSubtitleExtractor.swift#L433) preserves `isDefault`/`isForced` but does not detect SDH) | Native AVFoundation media-selection tracks detect SDH; the FFmpeg extractor path does not. |
| `SubtitleOverlayView` has no accessibility label. | Confirmed ([`SubtitleOverlayView.swift:31-50`](../../iosApp/iosApp/Screens/Player/Subtitles/SubtitleOverlayView.swift#L31)) | Decide whether the rendered subtitle bitmap surface should be hidden from VoiceOver or exposed through a better text/accessibility model. Do not add a misleading static label. |
| Stats lack p50/p95 bitrate, seek latency, packet loss, and JSON export. | Confirmed ([`PlaybackStats.swift:7-46`](../../iosApp/iosApp/Screens/Player/PlaybackStats.swift#L7) — bitrate/buffer/codec fields only; no aggregates or export) | Add fields only if they will be populated truthfully per route. |
| Source-proxy backpressure lacks a no-progress watchdog. | Confirmed, narrowed ([`PlaybackSourceProxy.swift:278-279`](../../iosApp/iosApp/Screens/Player/PlaybackSourceProxy.swift#L278) startup timeout exists; nothing comparable for active streaming) | Listener startup has a timeout; active streaming does not. |

## KSPlayer Comparison

The comparison is useful if framed as a parts-catalog review, not as a source
dependency plan.

| Claim | Status | Notes |
| --- | --- | --- |
| NativePlayer roughly maps to KSPlayer's AVPlayer wrapper layer. | Confirmed | Silo already has AVPlayer-backed routes. There is little to lift here. |
| SiloPlayer is not equivalent to a tag-aware AVPlayer wrapper. | Confirmed | Silo fixes the local source by remuxing/patching/signaling before handing it to AVPlayer. |
| CompatibilityPlayer is the closest area to KSPlayer's FFmpeg/VT path. | Confirmed | Audio strategy, Metal rendering, bitmap subtitles, scrubber thumbnails, and buffer/ABR ideas belong here if copied conceptually. |
| Typed `StreamRejection` handoff exists. | Confirmed, narrowed | P5 and HEVC HDR/PQ can build loopback plans; H.264 bad-data remains terminal. |
| Public KSPlayer source dependency carries licensing risk. | Confirmed | KSPlayer public source is GPL by default, with paid LGPL/commercial options described upstream. Reimplementation of concepts remains the safer route. |

## Corrected Claims Not To Carry Forward

- Do not call `PlayerView.swift:18` a proven SwiftUI re-init bug. The lifecycle
  risk is the init-time async task, not `@State` itself.
- Do not claim the VT HDR metadata propagation property is never set. It is set.
- Do not say realtime ACKs are rejected by the local seek filter. Backend time
  updates can be filtered; ACK/result messages are separate.
- Do not say `PlaybackSourceProxy` and H.264 software fallback have zero docs
  repo-wide. They are underdocumented in the tvOS docs, with partial plan-doc
  coverage.
- Do not treat existing `PlayerCore` PiP plumbing as something that benefits
  NativePlayer/SiloPlayer without AVPlayer-route PiP work.
- Do not keep the `onSidecarTracksRegistered` disposed-state finding. It is
  already guarded.

## Recommended Implementation Order

1. Documentation truth pass: CompatibilityPlayer audio output, route capability
   matrix wording, Profile 7 HDR10 fallback setting, source-proxy/backpressure.
2. Silo error propagation: mux write failures, file write failures, localhost
   server startup behavior.
3. CompatibilityPlayer audio failure propagation and audio callback lock
   cleanup.
4. Bitmap subtitle user-facing behavior: visible unsupported warning first,
   renderer work later.
5. Route planner validity and display capability modeling.
6. Lifecycle/observability cleanup: weak task captures, session bridge logging,
   realtime circuit breaker, source-proxy stall watchdog.

### Coverage caveat

The iOS/tvOS Xcode project has no test target (see `CLAUDE.md`). Most of the
fixes above will have to be verified by instrumentation and on-device runs, not
unit tests. When the test target is added, the highest-priority regression
candidates are: the single-flight 401 refresh in `HTTPClient`, route-planner
selection given fixture sources, and the Silo mux/file-write error paths once
they propagate through `onFinished(error)`.
