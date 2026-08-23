# AetherEngine-Only Playback Replacement

Status: Aether-only source migration and Apple TV 4K engine-declared streaming capabilities implemented; physical hardware breadth and release gates pending
Date: 2026-08-23
Silo Apple baseline: `4910372c2ccb34d0f6bbde9419b6806e3971ff3f`
AetherEngine pin: `6.34.0` / `0ae80496ab6f3fda135f43ef195ff10961c0e625`

## Decision

Silo Apple will replace its custom library-media playback implementations with
AetherEngine. The first installable test artifact from this work must contain
one media engine only: AetherEngine.

The candidate must not compile, link, ship, or retain a runtime fallback to
PlayerCore, AVPlayerBackend, Silo's local-HLS/loopback implementation, the
custom source proxy/cache, or the vendored FFmpeg package. Rollback is an older
Silo build, not an in-process engine switch.

This decision applies literally across the production app:

- video on iOS, tvOS, and macOS;
- downloaded/offline video;
- audiobooks through AetherEngine's audio-only path;
- any other media playback surface added in the future.

Silo production source constructs no `AVPlayer` directly. The startup treatment
is native SwiftUI rather than decorative video, and any future trailer or
decorative-media surface must use AetherEngine or revise this specification
explicitly.

## Goals

1. Make AetherEngine the exclusive owner of media bytes-to-presentation work.
2. Preserve Silo's server session, product, UI, progress, realtime, download,
   and privacy contracts.
3. Remove the custom engine rather than wrapping or hiding it.
4. Advertise only Protocol V3 capabilities the exact pinned Aether build and
   Silo adapter have proven on the relevant Apple platform.
5. Produce independently installable Aether-only builds that can be compared
   with the existing release on the same hardware and media.

## Non-goals

- Teaching the server about the AetherEngine package name.
- Keeping a dormant legacy engine as a kill switch.
- Retaining `PlaybackSourceProxy` or replacing it with a permanent custom
  `IOReader` to conceal a missing Aether API.
- Reimplementing Aether's codec routing, recovery, demux, decode, remux,
  buffering, cache, local HLS, or AVPlayer/sample-buffer hosting.
- Recreating Aether's per-stream routing decision in the app. The online
  manifest must match the exact pinned engine/build, while the engine probes
  the actual source and device at load time.

## Ownership boundary

```text
Silo controls, settings, queue, progress, realtime, downloads
                              |
                 PlaybackSessionBridge / V3
                              |
                  AetherPlaybackController
                    |                    |
             V3 timeline map       product projection
                    |                    |
                         AetherEngine
        source I/O -> probe -> demux -> route -> decode/remux
             -> audio/video -> tracks/cues -> presentation
```

### Silo owns

- Playback V3 start, replan, renewal, stop, progress, and attempt identity.
- User quality intent, server-delivery/output policy, and Protocol V3
  capability assembly.
- Resume, Next Up, intro/credits, markers, queueing, and exactly-once end work.
- Realtime commands and SiloControl behavior.
- Download lifecycle, persistent storage, and offline item metadata.
- Controls, sheets, HUDs, subtitle appearance, selection memory, and AI
  subtitle job state.
- The coordinate transform between the V3 timeline and Aether's media clock.
- Privacy redaction and the semantic projection of Aether telemetry/errors.

### AetherEngine owns

- Media URL/file reads, HTTP ranges, reconnects, probing, demux, and decode.
- Native/software/audio route selection.
- Audio bridging, video remux, local HLS, local HTTP serving, and segment cache.
- AVPlayer and sample-buffer hosts, A/V synchronization, seek execution, and
  media-level recovery.
- Track extraction and media subtitle/sidecar decoding.
- HDR/Dolby Vision signaling, Match Content handshakes, PiP media sources, and
  AirPlay media-path handling.

`AetherEngine.videoRoute` is diagnostic execution state. It is not a Silo
engine-selection input.

## Target components

### `AetherPlaybackController`

One `@MainActor` controller owns one `AetherEngine` per player presentation.
It is the only production object allowed to drive Aether's load and transport
APIs.

Responsibilities:

- construct Aether once and set creation-time options before the first load;
- generation-fence every load, subscription, async completion, and recovery;
- map a prepared online/offline Silo plan into an `AetherLoadSpec`;
- project Aether phase, clock, duration, buffer, tracks, chapters, cues, seek
  events, first-frame state, route, telemetry, and typed failures into Silo;
- drive play, pause, seek, rate, volume, audio selection, subtitle selection,
  PiP state, background policy, and teardown;
- expose no alternative engine kind or concrete AVPlayer/PlayerCore target.

The controller may have a test-only protocol/fake. The production target must
construct AetherEngine directly and must not contain a general runtime engine
selector.

### `AetherLoadSpec`

A pure mapper replaces `ApplePlaybackRoutePlanner` and the engine-bearing
`PlaybackExecutionPlan`.

Inputs:

- prepared V3 plan or offline manifest;
- selected tracks and quality intent;
- resume position;
- current platform/output context;
- relevant user settings.

Outputs:

- URL or Aether-supported source;
- start position on Aether's source axis;
- `LoadOptions` including headers, languages, external subtitles, native
  subtitle preparation, content matching, audio bridge policy, and remote-HLS
  behavior;
- product-only metadata used for timeline projection and progress.

The mapper does not choose a media engine or reproduce Aether codec tables.

### `PlaybackTimelineMapper`

Silo retains a small pure type that maps among:

- V3 source, stream-origin, player, progress, and seek-window axes;
- Aether `clock.currentTime` and `clock.sourceTime`;
- subtitle artifact timing origins;
- AI/synthetic cue timestamps.

It owns server-HLS seek re-anchor decisions. Aether owns the physical seek once
the active plan and target source position are known.

## Delivery mapping

The server wire contract remains engine-neutral:

| V3 delivery | Aether mapping |
| --- | --- |
| `original_http` | `load(url:startPosition:options:)` with plan headers |
| `server_remux_progressive` | same URL load contract |
| `server_remux_hls` | remote-HLS capable URL load with V3 timeline mapping |
| `server_transcode_hls` | remote-HLS capable URL load with V3 timeline mapping |

Aether may internally reroute a load among its native, loopback, software, or
audio paths. Silo does not second-guess that decision.

Every online Aether-only plan also requires the engine-neutral Protocol V3
feature `header_authenticated_media_v1`. An opting-in client receives only
relative API-local media routes (`/stream/{session}` or
`/playback/transcode/{session}/...`) and sends its current API bearer header on
every media request. The Apple resolver rejects absolute URLs, off-origin
URLs, non-media API paths, credentials embedded in a URL, and a plan-provided
`Authorization` value. The current authenticated session is authoritative.

The server preserves the old signed/token routes for clients that do not opt
in. For an opted-in session, direct, progressive, HLS manifest, HLS segment,
and subtitle access all remain behind API authentication; HLS requests are
also owner-bound for the lifetime of the session. Remote-node transcodes keep
their origin egress behind the API route instead of exposing a node URL.

## Session renewal without the source proxy

AetherEngine 6.34.0 accepts URL and headers per load, including authenticated
remote HLS through `AVURLAssetHTTPHeaderFieldsKey`, but has no public API to
retarget a running source's URL or headers in place.

The Aether-only behavior is therefore:

1. Capture the current V3-mapped playback position.
2. Stage a renewed or replanned server session without cross-wiring it into a
   newer load.
3. Validate the new plan and map it to a fresh `AetherLoadSpec`.
4. Start a new Aether load at the mapped position.
5. Commit the new session, progress target, external subtitles, and realtime
   binding only if the load generation is still current.
6. Stop staged/stale server sessions on failure or supersession.

Renewal triggers distinguish:

- authentication-shaped source refusal;
- terminal VOD/source failure that can plausibly represent an expired session;
- rate limiting, which backs off rather than immediately renewing;
- ordinary media incompatibility, which may request a V3 replan but never a
  different local engine;
- `CancellationError`, which means a newer load or stop won and is not a
  playback failure.

All current deliveries use a bounded replan or renewed session followed by a
fresh, generation-fenced Aether load. The obsolete in-place direct-session
retarget path was deleted with the source proxy. A later public Aether
credential-refresh API could reduce interruption, but it must not change the
server's engine-neutral contract.

Known expiration should be renewed proactively when reliable expiry metadata
exists. Otherwise the progress heartbeat and typed Aether failure are the
bounded triggers.

A short visible rebuffer is acceptable only for internal evaluation. Before
external distribution it needs a measured and accepted UX budget. If it is
not acceptable, implementation pauses for an upstream Aether credential/source
refresh API. Silo's proxy or a permanent custom reader is not restored.

## Capabilities and server compatibility

The current engine-name feature tokens are removed from new Apple capability
snapshots:

- `apple_playercore`
- `apple_local_loopback`
- `apple_native_direct`
- `apple_avplayer_progressive`
- `apple_avplayer_hls`

The audiobook snapshot is included in this cleanup.

The first Aether-only build deliberately underclaimed with handwritten,
fixture-bounded decoder envelopes. That was safe for migration but could make
the server reject a source before Aether's runtime probe saw it. The current
Apple TV policy separates an engine/build declaration from device/output and
persistent-artifact constraints:

- a physical Apple TV 4K sends `video_evidence: declared`, the flat decoder and
  demuxer manifest of pinned AetherEngine 6.34.0 plus FFmpegBuild 2.4.3, and no
  per-profile/bit-depth/performance `video_decode[]` envelope;
- Aether probes the actual source and exact device during `load`, selects its
  native or software path, and a typed load failure enters Silo's bounded V3
  replan path;
- Apple TV HD stays on the bounded `platform_attested` policy because it has
  materially less software-decode headroom and Aether does not yet emit a
  typed decoder-underperforming signal;
- simulators, iOS, and macOS also retain `platform_attested` until their rollout
  policy is changed explicitly;
- downloads retain the bounded attestation because an offline artifact cannot
  ask the server for a different plan.

Rules:

- every advertised recipe must have a working Aether executor in the same
  build;
- server planner fixtures must prove no advertised recipe is unexecutable;
- released legacy Apple clients remain supported by their own old capability
  snapshots;
- Android semantics remain unchanged;
- the server does not branch on the AetherEngine package name;
- `header_authenticated_media_v1` describes a transport security property,
  not an Aether implementation, and is required by this Apple snapshot;
- `software_video_decode_v1` is an engine-neutral, explicit opt-in that lets a
  strict evidence-tier client qualify bounded `hardware: false`
  `video_decode` entries. Without it, exact/platform-attested planning retains
  its historical hardware-only behavior. It remains relevant to downloads and
  conservative streaming surfaces; `declared` Apple TV 4K planning uses the
  flat engine list by definition;
- only `original_http` receives the broad Aether manifest and its
  `client_managed_dynamic_range_v1` validated claim. That claim lets the
  server deliver an HDR/Dolby Vision source even when the current output does
  not advertise the source range, because Aether owns the post-delivery
  display handshake and local presentation. Packaged progressive/HLS delivery
  stays on the VideoToolbox-backed codec list and remains gated by the live
  output snapshot;
- download creation sends detailed decoder entries and the feature opt-in
  rather than inheriting the online declaration. Its legacy flat list stays
  hardware-only, so older servers that ignore additive fields fail safely;
- Dolby Vision client transformations remain scoped to `original_http` and to
  the same live display/output evidence used by the server. They are preferred
  when the server can describe an exact Profile 7 outcome; the managed-range
  claim is the engine-owned fallback and does not invent a selectable recipe;
- `authHeaderRefresh` is `false` in the first Aether snapshot. Protocol V3
  defines it as refreshing credentials without restarting playback; a fresh
  Aether load does not satisfy that contract;
- codec, audio, container, hardware-probe, device-generation, and bounded
  fallback logic live in `AppleDecodeCapabilities`; diagnostics, downloads,
  and V3 shape adapters consume that owner instead of maintaining independent
  lists.

The claim changes admission, not ownership. Protocol V3 still supplies the
authenticated original URL, freezes attempt identity, records the output
snapshot, and excludes a failed plan key on replan. Aether probes the received
file and may demux, locally repackage, bridge audio, switch the panel, or map
the source onto SDR without a server-selected transformation. If that load
returns a typed failure, the server tries a different version or delivery; an
exhausted HDR route remains terminal until a real server tone-map recipe is
installed.

The migration justified coordinated server changes only where direct evidence
showed an engine-neutral contract gap. First, signed media URLs can
put reusable credentials in Aether and AVFoundation logs, caches, diagnostics,
and receiver-facing state outside Silo's redaction boundary. The generic
header-authenticated media feature above removes URL credentials without
teaching the server an engine name. It is implemented in an isolated server
worktree as commit `07383f7d` against baseline `91c3d7bd`; old clients retain
their current wire contract. That exact change is deployed on shared
development and has been validated through the exact Apple build's Aether
boundary.

Second, the pinned Aether stack successfully software-decoded five otherwise
transcode-only opaque fixtures, which established the strict fallback and
download envelopes. The server accepts those `hardware: false` entries only
with `software_video_decode_v1` and enforces their profile, bit depth, frame
size, frame rate, and bitrate bounds. Those bounds remain deliberately narrow:
1080p30 at rounded 10/3/3/32 Mbps ceilings for H.264/AV1/VP9/VC-1, and 720x480
at 31 fps and 7 Mbps for MPEG-2. They no longer constrain online Apple TV 4K
`original_http`; there, the pinned engine manifest gets the source to Aether's
own probe. Broader physical-hardware validation is still required before
release, especially for sustained software decode where a load can succeed
but fail to maintain real-time playback.

## Tracks and subtitles

### Track identity

Silo retains stable server/product identity and maps it to Aether `TrackInfo`
for the active load. Mapping uses explicit source indices/IDs and metadata; it
must not fuzzy-match unrelated tracks when fields are absent.

Initial preferred audio/subtitle choices are supplied before load where Aether
requires that for mux/init construction. Later local switches use Aether APIs;
server-backed switches still request a V3 replan and a fresh Aether load when
the server recipe changes.

### First subtitle build: normalized Aether cues

The first Aether-only build uses only Aether public subtitle output:

- `.text` and `.richText` cues;
- placement metadata;
- `.image` cues for supported bitmap formats;
- independent primary and secondary text cue channels;
- native subtitle rendition handoff for PiP/AirPlay when available.

Silo owns a thin UIKit/AppKit/SwiftUI overlay that paints those outputs and
applies user appearance/delay. It does not demux, decode, fetch, parse ASS,
manage a libass session, or open a second media context.

Live AI cues remain product data rendered by the same overlay on Aether's
source-time axis. `LiveSubtitleTrack` and `LiveSubtitleCoordinator` are
rewritten to emit normalized cue values directly; their current ASS chunks,
libass session installation, and `VTTToASSConverter` coupling are deleted.
They do not become a parallel subtitle engine.

The following custom subtitle machinery is removed:

- `SubtitleRenderer` and direct libass bindings;
- `SubtitleSession` media parsing/session ownership;
- embedded subtitle extractors and loopback subtitle taps;
- custom sidecar fetch/decode paths;
- VTT-to-ASS conversion and bitmap stores used by the old engine.

### Optional authored-ASS parity build

A later Aether-only build may add a presentation-only ASS renderer if full
authored effects, karaoke, drawings, and transforms are required. It consumes
only Aether public outputs (`preserveASSMarkup`, headers, fonts, cues, and
clock/frame timing) and owns no transport, track selection, retry, or session
logic.

This is not another playback engine, but its full native dependency graph and
licenses must be pinned and reviewed. It is not part of the first purity build.

Known upstream gaps such as secondary bitmap subtitles or secondary external
authored ASS are reported upstream or accepted explicitly. They are not filled
by retaining Silo's old subtitle engine.

## System integration

- iOS/tvOS custom controls set `ownsVideoNowPlayingSession` before the first
  Aether load, use the resulting session command center, and stage identity
  through Aether's metadata API.
- macOS retains a small product-level `MPNowPlayingInfoCenter` bridge because
  Aether's video Now Playing session API is iOS/tvOS-only.
- PiP uses Aether's native layer or software PiP source. tvOS software-route
  PiP is an explicit platform limitation.
- AirPlay route UI remains Silo-owned; Aether owns media-path rewriting and
  native subtitle handoff.
- `AetherPlaybackController` is the sole owner of the active native player's
  external-playback flags. Aether loopback is receiver-reachable through its
  LAN rewrite. Headerless remote HLS is eligible. Header-authenticated
  remote-bypass HLS is not advertised because a receiver cannot replay
  sender-only asset headers; a generation fence prevents a newly staged spec
  from reopening external playback on the outgoing player before load commit.
- Video Now Playing binds to Aether's player-scoped session on native routes
  and uses a mutually exclusive shared fallback for software/macOS. Silo
  publishes the V3 source axis and routes remote seeks back through the V3
  seek/replan boundary.
- Audiobooks use a separate Aether audio-only instance and its audio-scoped
  Now Playing session when available. Silo publishes the stitched whole-book
  timeline rather than per-file transport time.
- Aether owns display criteria. Silo maps its Match Content preference into
  Aether options and removes its duplicate display-criteria engine code.

## Offline playback

Downloads and their durable metadata remain Silo-owned. Playback uses Aether
with the downloaded file URL and local sidecars.

`LocalMediaProbe` is deleted unless a non-playback UI demonstrably requires a
pre-play badge that cannot come from persisted download metadata. If a probe is
still necessary, use public `AetherEngine.probe`; do not retain direct Libav.

Offline acceptance requires arbitrary supported downloaded originals to start,
seek, switch tracks/subtitles, resume, and finish in airplane mode without a
server fallback.

## Diagnostics and privacy

- Classify on Aether's stable string-backed `PlaybackErrorKind`; always provide
  a safe unknown bucket because minor releases may add kinds.
- Never classify localized error messages.
- Mirror `EngineLog` only through Silo's redaction and bounded capture path.
- Upstream Aether's unified-log output is treated as device-local support
  data and is never harvested into a Silo diagnostics bundle. On iOS and tvOS,
  its optional host callback is mirrored only into Silo's consent-gated,
  Debug Logging ring after media URL, filename, path, and credential redaction.
- Project semantic metrics rather than fabricating removed PlayerCore/loopback
  counters.
- Audit Aether's clear temporary fMP4 cache, data protection, stale-directory
  cleanup, and exclusion from backups before external distribution.
- No media URL credentials, headers, subtitle contents, or filenames enter
  uploaded diagnostics without the existing privacy policy's transformation.
- Silo sanitizes all projected media failures before public OSLog output.
  AetherEngine 6.34.0 itself still logs request URLs publicly. The upstream-
  ready Aether hardening commits `ac84b2e6` and `0765ce08`, based on current
  upstream `main`, redact URLs, standard and custom credential headers, paths,
  and secrets at the logging boundary and remove source filenames from known
  call sites. That remains a desirable upstream defense-in-depth change, but
  is not a Silo distribution blocker under the accepted device-local log
  boundary: Silo never collects the unified log and masks the separate host
  callback before it enters an uploadable diagnostics artifact.

## Scrub previews

Silo's controls continue to own preview presentation and request scheduling.
Local frame extraction uses Aether's public `makeFrameExtractor` API with the
same source headers and generation fencing as playback. Server trickplay may be
used when the active plan supplies it. The old player decoder and source proxy
are never retained solely to generate thumbnails.

The implemented provider is bounded to one active and one latest pending
request, coalesces rapid scrub input, uses Aether's native cache first, and
falls back to an independently tear-downable Aether frame extractor only on
software-capable sources. Ending a gesture, replacing a plan, or disposing the
player invalidates every late image.

## Dependency, license, and supply-chain policy

- Pin AetherEngine to exact commit
  `0ae80496ab6f3fda135f43ef195ff10961c0e625`.
- Commit `Package.resolved`; the Aether pin alone does not freeze its transitive
  FFmpegBuild and LibDovi ranges.
- Treat Nuke/NukeUI as shipped package products at their exact resolved
  revision. SMBClient may appear in resolution because Aether publishes a
  separate optional SMB product, but it is not a shipped Silo component unless
  an installable Silo target actually links `AetherEngineSMB`.
- Remove Silo's `Vendor/ffmpeg-build` package and every direct Libav/Libass
  consumer before producing a test artifact.
- Verify the app embeds only Aether's expected dynamic FFmpeg frameworks and
  that symbols bind the expected FFmpeg/libavcodec major.
- Ship the required Aether, FFmpegBuild, FFmpeg-component, LibDovi, and other
  notices plus exact corresponding-source links.
- Preserve AetherEngine's LGPLv3 license and Apple Store / DRM exception plus
  the incorporated GPLv3 text. Preserve FFmpeg/libzvbi LGPLv2.x, dav1d BSD,
  zimg WTFPL, LibDovi/libdovi MIT, and Nuke MIT texts in every installable host
  app.
- Do not describe the FFmpeg graph as GPL-free from package naming alone.
  Verify the pinned build script, FFmpeg configure strings, and final archive;
  the current 2.4.3 recipe removes the three GPL-family libzvbi source files
  and does not enable FFmpeg GPL, version-3, or nonfree components.
- Before external distribution, publish or make a license-compliant offer for
  an immutable corresponding-source/rebuild archive for the exact binary, and
  obtain legal approval for the distribution channel's signing/DRM terms. An
  in-app acknowledgements screen alone does not complete the LGPL process.
- Publish any Aether modifications under its LGPL terms. Prefer upstream
  contributions and an unmodified pin for the first build.
- Record exact binary provenance and a reproducible rebuild path for prebuilt
  media frameworks.
- The current FFmpegBuild and LibDovi rebuild scripts clone upstream tag names,
  not immutable commits, and the prebuilt frameworks do not carry a source-lock
  manifest. The package revisions pin the binary bytes but do not prove which
  upstream commit each tag named at build time. Archive the actual
  corresponding source or reproducibly rebuild from audited immutable commits
  before external distribution.

## Compile-time deletion manifest

Delete or replace all of the following before the first installable candidate:

- `iosApp/iosApp/Screens/Player/CoreMedia/**`
- `iosApp/iosApp/Screens/Player/AVPlayerRoute/**`
- `iosApp/iosApp/macOS/PlayerSurface.swift`
- `iosApp/iosApp/macOS/AVPlayerSurface.swift`
- `PlaybackSourceProxy.swift`
- `PlaybackSourceOriginStream.swift`
- `PlaybackOriginChunkFetcher.swift`
- `PlaybackSourcePrefetchPolicy.swift`
- `PlaybackDiskBudget.swift`
- `SourceCacheAdoptionPolicy.swift`
- `PlaybackCoordinator.swift`
- `PlaybackEngine.swift`
- engine-bearing `PlaybackExecutionPlan.swift`
- `PlaybackRecoveryPlanner.swift`
- `ApplePlaybackRoutePlanner.swift`
- old route-capability and display-criteria helpers
- old iOS/tvOS/macOS player surfaces
- direct Libav/libass offline and subtitle consumers
- `Downloads/LocalMediaProbe.swift` after its remaining UI callers move to
  persisted metadata or public Aether probing
- `Subtitles/SubtitleRenderer.swift`, `SubtitleStylingOverride.swift`, and
  `AVPlayerEmbeddedSubtitleExtractor.swift`
- `iosApp/Vendor/ffmpeg-build/**`
- FFmpeg module-map/macOS preparation scripts and Fastlane invocations
- `SiloPlayerBridging.h` and all target bridging-header settings
- startup installation of Silo's FFmpeg log filter
- `iOSApp.swift`'s `ContinuumInstallFFmpegLogFilter` call
- custom-engine fixture runners and debug toggles
- `AudioPlayerEngine`'s AVPlayer implementation
- old engine/proxy/loopback/FFmpeg implementation tests
- every SiloTests bridging-header and FFmpeg dependency plus Libav-importing
  test fixture

Behavioral fixture intent is retained by replacing implementation tests with
Aether-facing adapter and real-media acceptance tests.

### Implementation record (2026-08-21)

- All paths in the deletion manifest have been removed from installable
  targets, including 69 custom playback/subtitle source files and the direct
  media package, bridging-header, vendor, script, and Fastlane graph.
- Video, offline playback, audiobooks, tracks, chapters, subtitles, PiP,
  AirPlay/HDMI policy, lifecycle, scrub previews, Now Playing, diagnostics,
  and V3 timeline/replan execution now enter through Aether-owned APIs.
- Silo's diagnostics panel projects only public `LiveTelemetry`, route, phase,
  track, decoder, and HDR state; source labels never expose signed URL paths,
  query values, or request headers.
- The exact resolution lock includes AetherEngine at
  `0ae80496ab6f3fda135f43ef195ff10961c0e625`, FFmpegBuild 2.4.3 at
  `b2185fa842b829cd53d182a5e9a53182c1d9c84c`, and LibDovi 2.0.0 at
  `89be93431c2a5f2e54fb77e93059071b8d2ddb3a`, plus Nuke/NukeUI 12.9.0 at
  `83e19143355b02e9261edb2323b3e1e93287ebb9`. SMBClient 0.3.1 is resolved for
  Aether's optional SMB product but is not linked by Silo's selected product.
- Exact component notices and full license texts are configured through the
  shared `Resources` source for all three host apps and exposed locally from
  Settings. Generated-project and built-bundle verification remains part of
  validation. This implements the notice surface, not the external-
  distribution gate: the final source archive/offer, release-binary linkage
  scan, and legal approval remain pending.
- A coordinated server change now implements the engine-neutral
  `header_authenticated_media_v1` opt-in. Apple refuses online playback when
  that feature is absent, resolves only same-origin API media routes, and
  supplies the current bearer header. Focused server tests cover legacy
  compatibility, direct/progressive/HLS/subtitle route generation, remote-node
  proxying, and per-request HLS owner authorization. Commit `07383f7d` is
  deployed on shared development. A live V3 start returned a tokenless,
  API-relative `original_http` route; authenticated ranges returned `206`, the
  same request without a bearer returned `401`, and the exact route/header pair
  loaded through `AetherPlaybackController` on an iOS simulator. Aether opened
  the H.264/AAC source, reached ready/presenting, and advanced its media clock.
- An isolated distributed dev-builder sandbox exercised the complete server
  route matrix: original HTTP returned authenticated ranges, progressive remux
  returned MP4 bytes, remux HLS returned a manifest and fMP4 segment, and
  transcode HLS returned a manifest and media segment through the proxy and
  transcode nodes. After playback disconnected, the sessions disappeared,
  active jobs returned to zero, and transcode artifacts were pruned to zero.
- Five opaque release fixtures then proved Aether's bounded software path on
  the iOS simulator: H.264 High 10, AV1 Main 10, VP9, interlaced MPEG-2, and
  VC-1 all loaded through `AetherPlaybackController` and advanced its playback
  clock. The rebuilt isolated server advertised `software_video_decode_v1`;
  real V3 start requests using the exact software entries selected
  `playable` / `original_http` for all five. Focused server tests separately
  prove that an identical software entry is rejected without the feature and
  rejected when its declared bounds or supplied software profile are exceeded.
  The live planner likewise rejected mismatched High-10 and VP9 profile strings
  before selecting original delivery when the exact exercised profiles were
  supplied.
- Self-review caught a separate persistent-download overclaim: a flat codec
  list plus the device-wide 2160p limit could have admitted a 4K software
  original. Download capabilities now carry the same normalized, size-bounded
  detailed evidence. Resolver and handler tests cover opt-in, omission,
  out-of-bounds sources, incomplete probe facts, and invalid negative bounds.
- Aether's original local logging-hardening commit passed the 6.34.0 upstream
  suite (1,954 tests, zero failures) but is not remotely resolvable yet. Public
  release 6.34.1 and upstream `main` at
  `6e096e4d3856eb81dbb3e63a53458c20a76535e0` retain the same unredacted logger.
  The publish-ready `codex/redact-media-logs-upstream` branch is based directly
  on that `main`. A second self-review fix covers custom credential-bearing
  header names such as `X-Profile-Token` without swallowing later telemetry;
  seven focused redaction tests and the complete current suite pass, including
  1,955 Swift Testing tests in 282 suites with zero failures. Silo may retain
  the released 6.34.0 pin; publishing this patch is optional upstream
  hardening rather than a prerequisite for Aether-only candidates.
- The final self-review added a two-phase V3 execution commit, commit-scoped
  first-frame/progress telemetry, strict V3 subtitle transport resolution, and
  a literal no-direct-`AVPlayer` source policy. A Fable adversarial review then
  identified load-time failure/replan races, first-open ladder termination,
  query-credential acceptance, process-lifetime negative capability caching,
  dropped rapid seek reanchors, and premature audiobook session retirement.
  The verified findings were repaired: provisional errors have one owner;
  failed open attempts advance the bounded route ladder without success
  telemetry; header-authenticated URLs allow only the server contract's single
  finite non-negative `seek` query; negative probes retry; seek reanchors are
  latest-wins; and audiobook server sessions are retired only after the
  successor starts or actually replaces the prior Aether media and fails.
  Fable's route-event ordering concern is accepted by contract: events are
  best-effort diagnostics keyed by immutable attempt identity and are not a
  control channel. Its review also confirmed the engine-purity, two-phase,
  first-frame, timeline, realtime, offline, and subtitle-header boundaries it
  traced. The requested Opus run failed before returning a usable verdict and
  must be rerun rather than represented as completed.
- A final Fable follow-up through the isolated CLIProxy instance reviewed the
  frozen software-decode delta and rated it mergeable with high confidence. It
  verified that platform-attested software profiles are enforced, the 10-bit-
  only scope and per-codec performance ceilings match the spec, and all five
  planner routes plus packaged-codec exclusion are pinned. Its remaining low-
  severity observations were resolved by tightening the snapshot comment,
  using the exact shipped ceilings and case-varied profiles in server planner
  tests, asserting all five software bit depths, and naming the packaged-route
  test for the Apple contract it actually proves.

### Validation record (2026-08-22)

- XcodeGen generation succeeds. Signed iOS focused tests pass, including the
  Aether boundary, media-log redaction, Playback V3, timeline, telemetry, and
  offline mapping suites. The full iOS test run reached the entire suite and
  failed only three known, unrelated `UICustomizationPreferences` assertions.
  After the Fable repairs, the 40-test Aether boundary plus Playback V3 subset
  passes with 39 executed and one opt-in live shared-dev test skipped. The
  broader post-review iOS run passes 958 tests with that same live test skipped
  when the unrelated `UICustomizationPreferencesTests` suite is explicitly
  excluded. Post-review tvOS and macOS builds also succeed.
- The post-capability focused iOS run passes 48 tests with zero failures and
  one intentionally opt-in live test skipped. When supplied the isolated live
  envelope, that boundary test executes all five authenticated software-codec
  streams through the same Aether controller contract.
- After profile- and download-bound tightening, 39 focused capability/V3 tests
  pass with zero failures. A clean, signed iOS simulator run passes 961 tests
  with one opt-in live test skipped and zero failures when the same unrelated
  `UICustomizationPreferencesTests` suite is excluded. Running that broad lane
  unsigned makes 11 keychain-backed identity assertions fail; the identical
  79 affected tests pass in the signed lane, so those are signing-environment
  failures rather than playback regressions.
- After tightening the software performance claims to the exercised fixtures,
  the final Aether-boundary/capability/V3 run passes 51 tests with one expected
  opt-in live-fixture skip and zero failures. The isolated planner selected
  `playable` / `original_http` and returned authenticated `206` ranges for all
  five final entries. MPEG-2 first failed closed at a 30 fps claim because the
  server probe reports 30.303 fps; the documented 31 fps ceiling is the
  smallest rounded bound that admits that exact fixture, and its focused
  11-test capability rerun passes.
- Current focused server playback, contract, handler, and download suites pass.
  Every server package except `internal/jellycompat` passes as a full set; that
  unchanged package has two reproducible macOS process-identity lock failures
  when run alone and is outside this change.
- iOS, tvOS simulator, and macOS arm64 builds succeed. The signed iOS app
  installs and launches on the iOS 27 simulator.
- Built iOS, tvOS, and macOS apps contain only Aether's expected nine FFmpeg
  component frameworks and the configured license resources. Source, project,
  symbol, framework, and string scans found no legacy player engine, source
  proxy, loopback host, direct Libav consumer, or engine-name capability token
  in an installable target.
- A disposable local-package candidate then compiled all three Silo targets
  against the exact upstream-ready hardened Aether head `0765ce08`. iOS, tvOS,
  and macOS builds succeeded; each product again contained exactly the expected
  nine Aether media frameworks and no legacy-engine symbols. This proves the
  unpublished patchset integrates cleanly, but does not replace the required
  remotely resolvable production pin.
- Shared development is ready and advertises
  `header_authenticated_media_v1`. Its central integrated executor is the only
  enabled stream node. The deploy target also attempted to recreate four
  already-disabled distributed-node containers whose existing database
  topology is unreachable; the exact pre-deploy image failed identically, so
  those disabled crash loops were stopped rather than represented as a patch
  regression. Central readiness, database, auth, and integrated playback remain
  healthy.
- The paired physical iPhone is currently offline, so signed device install,
  hardware decode, PiP/AirPlay, lifecycle, and hardware media-matrix proof are
  not yet available. This is an outstanding validation lane, not evidence from
  simulator builds.
- The live Aether run also reproduced upstream 6.34.0's public source-URL log.
  The two-commit upstream-ready redaction patch removes that disclosure and
  custom credential-header leakage. Silo's diagnostics bridge separately
  proves uploaded Aether lines are redacted; the raw upstream line remains only
  in Apple unified logging under the accepted device-local support boundary.
- A follow-up CLIProxy Fable review found no blocking consent, handler-lifecycle,
  or upload-boundary defect. Its media-filename, spaced-path, underscore-header,
  bounded-input, stale-comment, and handler-composition findings were verified
  and repaired. The final focused diagnostics run passes 23 tests, and iOS,
  tvOS, and macOS builds pass against unmodified upstream Aether 6.34.0.

## Objective purity checks

Before any candidate is installed or distributed:

1. No app source or project setting references `PlayerCore`,
   `AVPlayerBackend`, `LoopbackSegment`, `PlaybackSourceProxy`,
   `PlaybackEngineKind`, `AVFoundationPlayerEngine`, or the old
   `AudioPlayerEngine`.
2. No Silo production source imports `Libav*`, `Libsw*`, `Libass`, or
   `Libdovi` directly.
3. No app target sets `SWIFT_OBJC_BRIDGING_HEADER` for player code.
4. No target depends on the old `FFmpeg` package or its scripts.
5. No new Apple capability contains old engine-name feature tokens.
6. An allowlist audit proves that all video, offline video, and audiobook
   playback constructs AetherEngine. Silo production source contains no direct
   `AVPlayer` construction; even the startup treatment is native SwiftUI.
7. `otool -L`, embedded-framework inventory, and `nm` inspection show only the
   expected Aether media dependency graph.
8. XcodeGen generates all targets from a clean checkout and iOS, tvOS, and
   macOS compile.

## Implementation chunks

### Chunk 0: baseline and contract

- Record the current clean baseline commit and media/device comparison matrix.
- Land this specification.
- Pin the exact Aether and transitive dependency graph.

Exit: the accepted boundary and purity checks are reviewable before product
code changes.

### Chunk 1: atomic single-Aether boundary

- Add Aether dependency.
- Add `AetherPlaybackController`, `AetherLoadSpec`, and
  `PlaybackTimelineMapper`.
- Replace platform player surfaces.
- Move basic load/play/pause/seek/time/end projection.
- In the same compiling change, remove the legacy package graph, bridging
  headers, implementation sources, and engine selector. The old and new
  FFmpeg graphs cannot coexist in an Xcode package resolution.

Exit: an Aether-only source tree resolves one FFmpeg graph and compiles far
enough to exercise a simple authenticated H.264/AAC item and an offline file,
without a legacy engine. Intermediate local edits may be non-compiling, but no
mixed-engine commit, installable artifact, or test build is produced.

### Chunk 2: product integration

- Move V3 session/replan/renewal and exact timeline mapping.
- Move audio/video/subtitle track selection.
- Add normalized Aether subtitle overlay and AI cue projection.
- Move progress, realtime, Next Up, Now Playing, PiP/AirPlay, lifecycle, and
  diagnostics.
- Move audiobooks to Aether audio-only.

Exit: common online, offline, video, and audiobook flows are feature-complete
without the old engine.

### Chunk 3: deletion and capability reset

- Delete every item in the compile-time manifest.
- Remove old dependencies, scripts, settings, flags, stats, and tests.
- Introduce the minimal truthful Aether-backed capability snapshots.
- Update server fixtures if the generic behavioral contract requires it.

Exit: all objective purity checks pass.

### Chunk 4: builds and behavioral expansion

- Build/test iOS, tvOS, and macOS on the remote Apple builder.
- Compare current and Aether-only builds on the same devices/media.
- Expand capability claims one proven slice at a time.
- Use shared development for coordinated server-plan validation when needed.

Exit: the complete validation matrix passes or every accepted limitation is
explicitly recorded.

### Chunk 5: adversarial review and canary

- Self-review complete diffs and ownership boundaries after every chunk.
- Request independent Opus and Fable reviews at the boundary, deletion, and
  final-validation checkpoints.
- Verify advisor claims against source/build/runtime evidence before changing
  code.
- Apply validated findings and rerun affected validation.
- Publish an internal/TestFlight canary only after license and privacy gates.

Rollback: reinstall the previous Silo build. No runtime engine switch exists.

## Validation matrix

### Build and lifecycle

- iOS, tvOS, and macOS clean generation/build.
- Focused controller/timeline/capability tests.
- start -> first frame -> progress -> pause -> resume -> seek -> end.
- superseded loads, rapid episode handoff, dispose during load, app
  background/foreground, tvOS suspension, and server restart.
- exactly-once end/progress/Next Up; no late callbacks mutate successors.

### Delivery and session

- authenticated `original_http` and `server_remux_progressive`;
- `server_remux_hls` and `server_transcode_hls` from the real Silo server;
- range behavior, redirects, sidecar auth, 401/403, rate limiting, expired
  session, renewed session, output-route change, quality/track replan;
- HLS seek beyond the generated window and V3 seek re-anchor;
- fresh-load renewal interruption measured on device.

### Media

- H.264 8-bit/High 10/interlaced, HEVC/Main10, AV1 and VP9 where claimed,
  MPEG-2/VC-1 where claimed;
- MP4/MKV/MPEG-TS/WebM and large/high-latency remotes;
- SDR, HDR10, HDR10+, HLG, Dolby Vision P5/P7/P8 variants;
- AAC, AC3, EAC3/JOC, TrueHD/MLP, DTS variants, FLAC/ALAC/PCM/Opus;
- channel layout/downmix and AVR/sink-visible Atmos claims.

### Subtitles

- SRT, WebVTT, ASS-normalized rich cues, PGS, DVB, DVD bitmap;
- embedded, authenticated sidecar, downloaded sidecar, primary/secondary text,
  forced flags, delay/style, track switching, AI cues;
- PiP/AirPlay native-rendition behavior and prevention of double rendering;
- optional authored-ASS build tested separately if adopted.

### Platform and offline

- iPhone/iPad PiP, AirPlay, background audio, interruptions;
- Apple TV remote transport, Match Content, HDMI/AVR, SDR-parked and HDR/DV
  display paths, memory pressure;
- macOS surface, keyboard, fullscreen, Now Playing;
- arbitrary supported downloaded originals and sidecars in airplane mode.

### Release

- dependency graph and symbol provenance;
- licenses, acknowledgements, exact source links;
- cache privacy/data protection and diagnostic redaction;
- startup latency, memory, CPU, dropped frames, A/V sync, and error rate
  compared with the baseline on the same device/media.

## Known limitations requiring explicit acceptance

- No remote DASH.
- TrueHD Atmos object metadata is not preserved; EAC3/JOC stream-copy is the
  Atmos-preserving path.
- Default surround-compatible audio bridging caps 7.1 to 5.1; lossless FLAC is
  the alternative where appropriate.
- tvOS cannot present Aether's software route through sample-buffer PiP.
- Advanced secondary bitmap/authored-ASS parity needs upstream or presentation
  work.
- PiP/AirPlay subtitle styling may degrade to native WebVTT/OCR behavior.
- The app disables subtitle delay/style controls while the selected Aether
  track is natively rendered; fullscreen Aether overlay tracks retain Silo
  delay and appearance controls.
- Header-authenticated remote-bypass HLS is intentionally not offered to
  AirPlay because the receiver cannot reproduce the sender's bearer header.
  Aether loopback remains eligible because Aether performs the authenticated
  origin fetch and exposes its receiver-reachable LAN rewrite; headerless
  remote HLS also remains eligible.
- Aether is young and fast-moving with material maintainer concentration;
  every release is an explicit exact-pin upgrade with a repeated acceptance
  subset, not a floating dependency update.

## Go/no-go rule

Proceed with the Aether-only implementation and internal builds.

Do not distribute externally until all of the following are true:

- binary/source purity checks pass;
- V3 capabilities cannot overclaim;
- renewal is correct and its interruption meets the accepted UX budget;
- online and offline library playback pass the hardware/media matrix;
- license, dependency provenance, temporary-cache privacy, and diagnostics are
  approved;
- Opus and Fable adversarial findings have been verified and resolved or
  explicitly rejected with evidence.
