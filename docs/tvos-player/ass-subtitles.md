# Local ASS subtitles

The Apple video player renders primary ASS/SSA tracks with libass through
AssKit. Aether retains raw ASS events and exposes script headers and embedded
fonts. The overlay renders these over the video without encoding new video
frames. The server receives ASS styling and font capabilities for the original
and packaged video routes; audio-only playback still advertises no subtitles.

`ASSSubtitleSession` owns each load's font requests and selection generation.
Embedded fonts come from Aether. Sidecar fonts use the selected inventory's
font-bundle URL with the same origin-scoped headers as subtitle artifacts.
Requests time out after 20 seconds. A failed font request produces a visible
subtitle error; switching off and back on retries it. A stale request cannot
change the next selection's loading or error state.

`ASSSubtitleRenderer` confines libass to an actor. It appends new events,
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

The secondary companion subtitle channel keeps Aether's existing text
rendering. PiP and AirPlay continue to use Aether's native text renditions;
authored ASS layout belongs to the local video overlay.

## Verification

`ASSSubtitleRendererTests` uses actual libass output to check authored colors,
positions, overlapping events with repeated ReadOrder, animation, backward
seeking, expired/replaced cues, and font shaping. Its original test font draws
X as a rectangle, making attachment use distinguishable from a fallback font.
A bundled MKV exercises the full Aether/controller/rendering path for embedded
tracks, track changes, a sidecar, and Off. Another test holds font requests
across a selection change to check cancellation and late completions.

`AetherPlaybackBoundaryTests` runs server fixture subtitle and font URLs
through the production resolver and load specification, including the bearer
headers. `PlaybackProtocolV3Tests` verifies capability declarations and the
existing selection/timeline contracts. Physical playback diagnostics record
one `Local ASS frame ready` breadcrumb per selection, including cue/font counts
and embedded-versus-sidecar source, without subtitle text or media URLs.
