# Local ASS subtitles

The Apple video player renders primary ASS/SSA tracks with libass through
SwiftLibass 1.4.0. Aether retains raw ASS events for the primary channel and exposes
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

`ASSSubtitleRenderer` owns the libass library, renderer, and track
allocations and frees them in order. Aether republishes its whole retained cue
array on every change; the renderer appends only cues it has not seen, keyed by
Aether cue ID, and deduplicates events by content and millisecond window rather
than Matroska ReadOrder. Cues Aether prunes after they age out stay in libass
for a backward seek. A cue that disappears or changes timing while it can still
be drawn flushes the event list with `ass_flush_events`, keeping the renderer's
font and glyph caches. So do the first cues of a reload held under the
outgoing ones, which may have deleted events the pruning rule would keep; a
held reload that ends with no cues clears them when loading finishes.
Only a new header or font set rebuilds libass.

`ASSImageCompositor` blends libass's alpha masks straight into premultiplied
BGRA canvases from a pixel-buffer pool, so the cost follows the drawn area.
The SwiftAssRenderer float pipeline it replaces allocated and converted the
whole bounding box every frame, tens of megabytes for a full-screen sign at
4K. Libass renders at most 1920 × 1080 pixels; a 4K output shows that canvas
scaled up. Authored positioning uses the displayed video rectangle.

`ASSOverlayPresenter` renders a fraction of a second ahead of the picture and
queues each canvas on an `AVSampleBufferDisplayLayer` whose control timebase
is the video's own clock: the player item's timebase on AVPlayer paths, the
software synchronizer on the software path. Core Animation pairs each canvas
with the frame it belongs to, so neither render time nor a busy main thread
shifts it. Canvases render at the exact timestamps of the frames Aether
reports (`setNativeVideoFrameTimeObserver`, `setSoftwareVideoFrameTimeObserver`)
and carry those timestamps unrounded. Typesetters place event boundaries
between frames, so sampling a running clock instead lands on a neighbouring
frame's event part of the time, which shows on a tracked sign as a one-frame
shake. Only frames whose pixels libass reports changed are queued. A seek,
detected as the clock leaving the position its rate predicts, flushes the
layer and refills it from the frame on screen; cues that arrive for frames
already queued replace them while the current canvas stays up. A selection or
load change clears the layer at once. The session tags each selection with a
generation and tells the layer which one to accept before it awaits the
presenter, so canvases a step renders for an outgoing selection never show.

Embedded events use Aether's source clock: the native path converts item time
through Aether's `presentationAxisMap`, and the software path presents on the
source clock. Remote HLS, where Aether reports no frames, spaces frames by the
source's nominal frame rate and subtracts the measured lead of item time over
Aether's picture time. Complete sidecars add the server's timeline offset to
the cue clock. Positive subtitle delay subtracts from render time. The overlay
logs, every ten seconds while it renders, its frame count, how many timestamps
Aether reported, and average and slowest render times.

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
seeking, expired/replaced cues, aged-out versus retracted cues, and font
shaping. Its original test font draws X as a rectangle, making attachment use
distinguishable from a fallback font. Presenter tests drive a fake clock to
check that every reported frame renders its own frame-timed event on the
native, software, and remote-HLS clocks, that unchanged frames are not queued,
and how seeks, late cues, and selection changes flush the layer. The
compositor has an exact premultiplied-blending test.
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
