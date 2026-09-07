# Local ASS subtitles

The Apple video player renders primary ASS/SSA tracks with libass through
SwiftLibass 1.4.0 and SwiftAssRenderer 1.3.1. Aether retains raw ASS events for the primary channel and exposes
script headers and embedded fonts. The overlay renders these over the video
without encoding new video frames. The server receives ASS styling and font
capabilities for the original and packaged video routes; audio-only playback
still advertises no subtitles.

`ASSSubtitleSession` owns each load's font requests and selection generation.
Embedded fonts come from Aether. Sidecar fonts use the selected inventory's
font-bundle URL with the same origin-scoped headers as subtitle artifacts.
Network requests time out after 20 seconds; local font bundles use the file
system directly. A failed font request produces a visible subtitle error;
switching off and back on retries it. A stale request cannot change the next
selection's loading or error state.

`ASSSubtitleRenderer` confines libass to an actor and uses SwiftAssRenderer's
`BlendImagePipeline` to composite frames. It owns the library, renderer, and
track allocations directly and frees them in order. The package's 1.3.1
convenience renderer copies parsed tracks without freeing them, so Silo uses
its lower-level image API instead of repeatedly loading whole scripts.
It appends new events,
deduplicates by content and timestamps rather than Matroska ReadOrder, and
rebuilds when Aether removes cues or the header/fonts change. Font stores and
old events are released with their renderer. Rendering has one awaited frame
at a time while the overlay is visible, and selection/load changes reject
outgoing frames. Authored positioning uses the displayed video rectangle.

Embedded events use Aether's displayed source clock. Complete sidecars add the
server's timeline offset to that clock. Positive subtitle delay subtracts from
render time. Between Aether's 100 ms native clock publications, the overlay
samples the same AVPlayer for smooth ASS animation, without extrapolating
through a seek, buffer stall, player replacement, or clock discontinuity.

Secondary ASS subtitles are decoded into normalized text, supported text
styles, and placement for the companion overlay. They do not receive raw ASS
event fields or use libass. The software PiP compositor likewise normalizes
the primary ASS cues while leaving the primary overlay's raw events intact.
These text paths preserve the ordinary decoder's supported formatting, not
the complete authored libass layout and animation.

For packaged HLS, an injected ASS sidecar supplies raw cues and its header to
the local overlay while retaining a native text rendition for PiP and external
playback, including AirPlay. Aether deselects that native rendition during
local overlay rendering to avoid duplicate captions. Native-rendering requests
select it without discarding the raw cues; returning to the overlay or choosing
Off cancels pending native selection work.

## Verification

`ASSSubtitleRendererTests` uses actual libass output to check authored colors,
positions, overlapping events with repeated ReadOrder, animation, backward
seeking, expired/replaced cues, and font shaping. Its original test font draws
X as a rectangle, making attachment use distinguishable from a fallback font.
A bundled MKV exercises the full Aether/controller/rendering path for embedded
tracks, track changes, a sidecar, and Off, and checks that secondary ASS is
normalized while primary ASS stays raw. Another test holds font requests
across a selection change to check cancellation and late completions.

Aether's `ASSSubtitlePresentationTests` compare software PiP normalization with
the ordinary decoder, including supported styles, placement, and cue order.
Its injected-HLS tests check raw cue retention, native-rendering intent across
reloads, and rejection of stale selections after a track change or Off.
These checks cover cue data and selection state; they do not establish visual
correctness on physical tvOS or actual PiP/AirPlay output.

`AetherPlaybackBoundaryTests` runs server fixture subtitle and font URLs
through the production resolver and load specification, including the bearer
headers. `PlaybackProtocolV3Tests` verifies capability declarations and the
existing selection/timeline contracts. Playback diagnostics emit one
`Local ASS frame ready` breadcrumb per selection, including cue/font counts
and embedded-versus-sidecar source, without subtitle text or media URLs.

## Distribution

SwiftLibass supplies static `.a` libraries and headers inside XCFrameworks.
The app links their code without embedding subtitle `.framework` wrappers.
This avoids the stub-executable/MinimumOSVersion mismatch observed with AssKit.
Keep the exact package versions in `project.yml` and `Package.resolved` aligned
with `scripts/ci/swift-libass-sources.json` and the bundled acknowledgements.
The release-source job includes the native sources and a local rebuild entry
point that preserves modifications to those sources.

The TestFlight lanes validate the exported IPA before uploading, and sideload
lanes validate the archived app before creating the IPA. The packaging gate
rejects the old subtitle framework wrappers while allowing Aether's dynamic
media frameworks and the new Swift packages' resource bundles.
