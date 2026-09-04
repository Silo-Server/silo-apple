> [!WARNING]
> **Historical pre-AetherEngine archive.** This document describes the removed custom-player architecture or its pre-migration validation model. It is retained for history only and must not be used as current implementation guidance. See the [AetherEngine-only replacement specification](aetherengine-replacement-spec.md).

Repo snapshot date: 2026-04-29 (HEAD `6c2b4af`)

# CoreMedia Pipeline

## 1. What runs by default

On tvOS, the default backend is
[`PlayerCore.swift`](../../iosApp/iosApp/Screens/Player/CoreMedia/PlayerCore.swift).
Its top-level pipeline is:

- `libavformat` demux
- VideoToolbox video decode (with H.264 software fallback after VT failure)
- `AVSampleBufferDisplayLayer` video output, driven by a host-clock
  `controlTimebase` and a `CADisplayLink` tick
- FFmpeg software audio decode plus `SwrContext`
- `AVAudioEngine` graph with an `AVAudioSourceNode` for PCM playback

The key render companion is
[`PlayerSurface.swift`](../../iosApp/iosApp/Screens/Player/CoreMedia/PlayerSurface.swift),
which hosts the `AVSampleBufferDisplayLayer` inside a `UIViewRepresentable`.

## 2. Why the video path is push-driven

The current tvOS implementation does **not** use Apple's more typical
`AVSampleBufferVideoRenderer` pull model.

Instead, `PlayerCore.attach(to:)` creates:

- a host-clock `controlTimebase` on the display layer
- a `CADisplayLink` on `.main` / `.common`

The file comment explains why: the team observed that the sample-buffer video
renderer pull path never actually delivered video frames on tvOS 18, while the
audio side still worked. The code therefore uses a push model:

1. VideoToolbox decodes asynchronously.
2. Decoded frames are inserted into a PTS-sorted queue.
3. The display-link tick peeks the head frame, syncs it against the audio
   clock, and enqueues it onto the display layer.

That detail is central to understanding this player. It is not a generic
AVPlayer-style black box.

## 3. Load path

`PlayerCore.load(url:headers:startTime:)` does all of the following before
playback becomes visible:

- activates the app audio session
- drains old packet queues and feed loops
- resets per-load flags
- starts a buffering watchdog
- dispatches `openAndDemux(...)` onto the demux queue

`openAndDemux(...)` then:

1. allocates an `AVFormatContext`
2. installs an FFmpeg interrupt callback so blocked network I/O can time out
3. sets HTTP headers, reconnect options, and 10-second read/connect timeouts
4. opens the remote stream with `avformat_open_input`
5. probes stream info
6. finds streams and picks default audio/video
7. builds the compressed video format description
8. creates the VideoToolbox decompression session
9. sets up audio decode/resample when audio exists
10. opens a subtitle decoder only if a subtitle stream has already been chosen
11. publishes tracks and chapters
12. applies tvOS display criteria for dynamic range / refresh rate
13. seeks to the requested start time if needed
14. seeds the synchronizer, control timebase, and audio clock
15. starts decode/feed loops
16. fires `onFileLoaded`

`onFileLoaded` intentionally happens before the first decoded frame. The code
comment says this broke a deadlock where the UI waited for the callback before
it would finish setting the player up.

## 4. Stream selection defaults

`findStreams()` currently does the following:

- video: first video stream wins
- audio: prefer the first audio stream with `<= 6` channels
- audio fallback: if no `<= 6ch` track exists, use the first audio stream

The audio preference is deliberate. The comment calls out tvOS/HDMI behavior:
some Atmos soundbar setups do not like 8-channel LPCM output, so the default is
biased toward `<= 6ch` unless the user manually changes tracks later.

## 5. Video decode and presentation

The video side is:

1. `runDemuxLoop()` reads packets and pushes video packets into a bounded queue.
2. `startVideoFeed()` pulls packets from that queue on a serial decode queue.
3. `decodeVideoPacket(...)` wraps compressed payloads as `CMSampleBuffer`s and
   submits them to `VTDecompressionSessionDecodeFrame`.
4. `handleDecodedVideoFrame(...)` inserts decoded frames into a PTS-sorted
   queue.
5. `videoDisplayLinkTick()` uses the audio clock as the sync reference:
   - hold if the frame is too early
   - drop if it is too late
   - otherwise build an image-buffer sample and enqueue it on the display layer

The sorted insert is there for a real reason: B-frames arrive in decode order,
not presentation order. The code comment explicitly calls out the old failure
mode where only I/P frames effectively reached screen timing.

## 6. Audio decode and clocking

Audio runs through an `AVAudioEngine` graph, modelled after KSPlayer's Apple
backend:

1. `runDemuxLoop()` pushes audio packets into the audio queue.
2. `startAudioFeed()` calls `requestMediaDataWhenReady(on:)` on the audio
   output, which polls `isReadyForMoreMediaData` and asks for the next decoded
   chunk.
3. `decodeAudioPacket(...)` sends packets through FFmpeg's audio decoder, then
   `enqueueResampledAudio(...)` resamples to interleaved Float32 PCM and pushes
   a `DecodedAudioChunk` into the audio output queue.
4. The output owns an `AVAudioSourceNode` whose render block pulls from the
   chunk queue and writes interleaved Float32 frames into the supplied
   `AudioBufferList` on the real-time audio thread.

The output node's audio unit installs a render notify callback. After each
render slice it computes the rendered presentation time (sample-counter +
`outputLatency`) and calls `onRenderedTime`. `PlayerCore` feeds that into the
local `AudioClock` struct, which becomes the audio master clock: the video
display-link tick reads `audioClockSnapshot()` and extrapolates the current
clock by playback rate to compare against frame PTS. There is no
`AVSampleBufferRenderSynchronizer` on this path.

## 7. Tracks, chapters, seeks, and switching

`buildTrackList()` walks `AVFormatContext.streams` and publishes:

- audio tracks
- subtitle tracks
- video tracks

Track IDs are the FFmpeg stream indices.

Manual operations behave like this:

- `seek(to:)` drains queues, flushes decoders/renderers, calls
  `avformat_seek_file`, resets clocks, and restarts feeds.
- `setAudioTrack(_:)` tears down and rebuilds the audio decoder around the new
  stream, seeks back to the current position, and restarts feeds.
- `setSubtitleTrack(_:)` tears down only the subtitle decoder and restarts that
  loop without flushing main A/V renderers.

## 8. Subtitles today

Text subtitles are Silo-rendered through the shared libass session:

- ASS/SSA events decode through FFmpeg and are fed to libass.
- SRT/WebVTT/MOV_TEXT sidecars and extracted text tracks are converted into
  generated ASS before rendering.
- `PlayerSurfaceHostView` hosts a `SubtitleOverlayView` above the video; the
  overlay receives libass-composited `CGImage` frames.
- Primary subtitles, secondary sidecars, delay, styling, and vertical position
  are implemented through the shared subtitle session.

Current gaps are important:

- Bitmap subtitles are filtered out of controlled subtitle selection until a
  bitmap renderer exists.
- Native AVFoundation caption fallback can still be used where extraction is
  unavailable, but it does not honor Silo delay/styling.

One more subtle truth: `openAndDemux(...)` comments that it should default to
the first non-forced subtitle stream, but the executable code only opens a
subtitle decoder when `pendingSubtitleTrackId` is already set. In practice,
embedded subtitles start off disabled until a preferred ffmpeg index or user
selection chooses one.

## 9. HDR and display matching on tvOS

On tvOS, HDR is handled through `AVDisplayManager`, not EDR on the layer:

- `onSigPeakChange` drives EDR on iOS and macOS only.
- tvOS calls `TVDisplayCriteria.apply(refreshRate:contentFormat:)`.
- The criteria are built with the public
  `AVDisplayCriteria(refreshRate:formatDescription:)` (tvOS 17+). The compositor picks its HDMI mode from the codec fourcc plus the colour
  signalling, so Dolby Vision carries its base-layer transfer — PQ for
  Profile 8.1, Rec.709 SDR for 8.2, HLG for 8.4. The same mapping
  (`VideoColorMetadata.dolbyVisionBaseLayerColorimetry`) supplies the colour
  attachments on the format description `PlayerCore` hands the decoder, so
  the HDMI mode and the decoded frames describe one base layer.

That means HDMI mode matching is part of the default `PlayerCore` path.

## 10. PiP and remote/system integration

`PlayerCore` also owns sample-buffer PiP:

- it lazily creates `AVPictureInPictureController`
- it implements the sample-buffer playback delegate
- it reports PiP active/inactive changes back through
  `onPictureInPictureActiveChange`

Separately, `NowPlayingController` exposes Play, Pause, Toggle, Skip +-10, and
position scrubbing through `MPRemoteCommandCenter`.

## 11. Current limitations

- `PlayerCore` only builds a compressed format description for H.264 and HEVC.
- `bufferedAheadSeconds` stays `0` on this path; only `AVPlayerBackend` emits a
  comparable buffered-range metric.
- Audio delay is still a TODO. Text subtitle delay, styling, external
  sidecars, and secondary sidecars are implemented through the shared subtitle
  session.
- Mid-stream format changes are handled with `displayLayer.flush()` rather than
  a full surface teardown.

## 12. H.264 software decode fallback

VideoToolbox is the normal video path. When the H.264 hardware decoder fails
in a way that suggests the content is incompatible with the VT session
(`unimpErr`, format-description rejection, repeated decode errors), `PlayerCore`
tears down the VT session and reopens the H.264 stream through FFmpeg's
software decoder. The display layer is unchanged; only the source of decoded
`CVPixelBuffer`s changes.

This fallback is per-load: once the software path is engaged it stays for the
remainder of the session. HEVC and Dolby Vision do not have an equivalent
software fallback today; HEVC failures route to SiloPlayer instead (see
[03 - Dolby Vision and SiloPlayer route](03-dolby-vision-and-avplayer-route.md)).

## 13. Source delivery via PlaybackSourceProxy

For routes that download from origin (CompatibilityPlayer and NativePlayer
HLS), the view model can interpose
[`PlaybackSourceProxy`](../../iosApp/iosApp/Screens/Player/PlaybackSourceProxy.swift)
between the active backend and the upstream Silo server. It rewrites the
source URL to a localhost listener and streams the origin response through to
the consumer.

The proxy provides downstream-aware backpressure on the active streaming path:

- the upstream `URLSessionDataTask` is suspended once unsent bytes on the
  local Network.framework connection cross **128 MiB** (`downstreamHighWaterBytes`)
- it resumes once the unsent buffer drains below **64 MiB**
  (`downstreamLowWaterBytes`)

This keeps the origin meaningfully ahead of the consumer (FFmpeg in
CompatibilityPlayer, AVPlayer in NativePlayer HLS) without letting the
local-send queue grow unbounded when the consumer stalls.

The listener has a 2-second startup timeout. The active streaming path does
not currently have an independent stall watchdog; if the upstream task and
downstream connection both go silent without firing completion, the proxy
relies on the active backend's higher-level buffering watchdog to surface the
stall.

## Validation log

- verified: tvOS uses a display-link push pipeline on top of
  `AVSampleBufferDisplayLayer`, not a pure AVPlayer surface.
- verified: the audio default-selection bias toward `<= 6ch` is explicit in
  code.
- verified: audio output is `AVAudioEngine` + `AVAudioSourceNode`; the audio
  master clock is a local `AudioClock` driven by the engine output unit's
  render notify, not `AVSampleBufferRenderSynchronizer`.
- corrected: subtitle auto-selection is not actually enabled by default despite
  the nearby comment about "first non-forced subtitle stream."
