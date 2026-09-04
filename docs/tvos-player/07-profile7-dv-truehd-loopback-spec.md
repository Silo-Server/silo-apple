> [!WARNING]
> **Historical pre-AetherEngine archive.** This document describes the removed custom-player architecture or its pre-migration validation model. It is retained for history only and must not be used as current implementation guidance. See the [AetherEngine-only replacement specification](aetherengine-replacement-spec.md).

Snapshot date: 2026-04-29

# Profile 7 Dolby Vision And TrueHD Loopback Spec

## 1. Goal

Silo should play a direct-play UHD Blu-ray remux on Apple TV when the
source looks like:

- container: `mkv`
- video: HEVC Dolby Vision Profile 7, usually dual-layer BL+EL+RPU
- audio: Dolby TrueHD, often 5.1/7.1 and sometimes TrueHD Atmos
- subtitles: often PGS plus sidecars

The desired user-facing result is:

- Dolby Vision presentation on a Dolby Vision-capable Apple TV output path
- primary audio preserved as multichannel surround, ideally lossless
  multichannel LPCM over HDMI
- no false Atmos claim for TrueHD-derived output
- no silent downgrade from 7.1/5.1 TrueHD to stereo AAC
- no server-side remux/transcode dependency for this route

The route remains Apple TV first. macOS and iOS can share code where useful,
but the validation target is physical Apple TV hardware connected to a real TV
or AVR.

## 2. Why this needs to exist

Apple TV is the primary high-end client for many Silo users, but Blu-ray
remuxes do not map directly onto the native Apple playback contract.

The three blockers are independent:

- `mkv` is not an AVPlayer-native direct-play container for this media shape.
- Dolby Vision Profile 7 is a Blu-ray-oriented profile and is not the normal
  Apple TV app-delivery profile.
- Dolby TrueHD is not an Apple-native HLS/AVPlayer audio delivery format, and
  TrueHD Atmos cannot be passed through as TrueHD Atmos on Apple TV.

`PlayerCore` can demux and decode many compatibility assets, but it cannot
truthfully present this case as Dolby Vision on Apple TV. AVPlayer can negotiate
Apple's Dolby Vision output path, but only if we feed it Apple-compatible media.

That is why this feature exists: bridge the user's existing remux file into an
Apple-native presentation without requiring the server to pre-convert the
library.

## 3. External constraints

### 3.1 Apple video delivery

For AVPlayer, the stable target is local HLS over fragmented MP4/CMAF-style
segments. Apple HLS uses the `CODECS` attribute to declare sample types and has
explicit Dolby Vision signaling forms for Apple devices.

For Profile 7 sources, Silo should not attempt to hand AVPlayer raw P7
dual-layer media. The target is a derived single-layer Dolby Vision stream:

- keep the base-layer HEVC video
- remove enhancement-layer NAL units that Apple TV cannot consume in this path
- convert/rewrite RPU metadata to Profile 8.1-style signaling
- package as HEVC in fMP4
- signal Apple-compatible Dolby Vision through the sample description and/or
  HLS metadata

The implemented route token is `profile7_to81_base_layer`.

The KSPlayer issue #875 discussion lines up with this boundary: regular FFmpeg
HLS remuxing is enough for Apple-supported DV delivery shapes, but not for raw
Blu-ray Profile 7. A plain P7-to-HLS copy leaves Dolby Vision metadata in a form
AVPlayer is not expected to consume. Jellyfin's special FFmpeg
`hevc_metadata=delete_dovi=1` path is an HDR10 fallback, not a Dolby Vision P7
solution; it removes DOVI metadata so the base layer can play as plain HDR10.

So Silo has two separate responsibilities:

- keep Apple-native profiles healthy: P5 and P8.1 use PQ DV signaling, P8.4 uses
  an HLG base layer plus supplemental DV signaling, and AV1/P10 requires a real
  AV1-capable route before it can be claimed
- keep P7 separate: either explicitly derive a single-layer P8.1-style stream, or
  truthfully fall back to HDR10; do not present regular P7 HLS remuxing as DV

### 3.2 Apple audio output

Apple TV's HDMI output behavior is not the same thing as the app's input audio
codec. Apple documents that with Audio Format set to Auto, Apple TV decodes the
best audio format for the equipment and sends uncompressed audio to speakers.
It can also re-encode to Dolby Digital 5.1, or output stereo PCM, depending on
settings and output support.

Firecore documents the practical Infuse behavior more directly: Infuse can
decode high-resolution audio formats, then Apple TV outputs uncompressed
multichannel LPCM, up to 7.1 channels at 24-bit/48 kHz. Receivers may display
that as `PCM`, `LPCM`, or `Multi-Channel`.

So the target for TrueHD is not "TrueHD passthrough". It is:

- decode TrueHD in the app
- preserve the 5.1/7.1 bed as PCM
- let Apple TV output multichannel LPCM

TrueHD Atmos object metadata is out of scope for this target. Atmos may only be
claimed when the source is already Apple-compatible E-AC-3/JOC and that track is
preserved end to end.

## 4. Product contract

### 4.1 Supported source class

The first supported class is:

- direct-play Silo stream URL
- Matroska/WebM demuxable by libavformat
- one HEVC video stream with Dolby Vision side data
- Dolby Vision Profile 7 detected from DOVI configuration
- one selected source audio stream
- selected audio stream is either Apple-compatible copy audio or decodeable by
  the bundled FFmpeg libraries

### 4.2 Output claims

The route may claim Dolby Vision only when:

- route is SiloPlayer (current code: `avPlayerLocalDVLoopback`)
- video mode is `profile7_to81_base_layer` or a validated native Apple DV mode
- the emitted init segment and playlist advertise the final output shape, not
  just the input-side DOVI metadata
- tvOS receives explicit `AVDisplayCriteria` for Dolby Vision using the source
  frame rate before AVPlayer prepares the local loopback item
- a physical Apple TV validation run confirms the display enters Dolby Vision
  for this output

The route may claim Atmos only when:

- selected source audio is E-AC-3/JOC
- the output path preserves E-AC-3/JOC by copy or another validated
  Apple-native Atmos path
- an AVR/soundbar validation run confirms the Atmos indicator

The route must not claim Atmos for TrueHD-derived PCM output.

The route must not describe TrueHD-derived PCM as TrueHD passthrough. The honest
label is "lossless multichannel PCM" or "multichannel LPCM".

### 4.3 Bitmap subtitle policy

PGS, VobSub, and DVB subtitles are bitmap subtitle formats, not libass text
inputs. The current Apple subtitle stack renders text and ASS-like cues through
the shared subtitle session and skips FFmpeg `SUBTITLE_BITMAP` rects, so these
formats must not be treated as preserved by SiloPlayer or CompatibilityPlayer
today.

Do not solve bitmap subtitles with client-side burn-in. True burn-in requires
rewriting decoded video frames, which breaks the AVPlayer-owned HDR/Dolby
Vision presentation path and cannot truthfully preserve Dolby Vision dynamic
metadata after the pixels change. Server burn-in has the same Dolby Vision
metadata caveat unless a dedicated Dolby metadata regeneration path exists.

The preferred future direction is a client-side bitmap subtitle overlay: decode
PGS, VobSub, and DVB rectangles with FFmpeg, render them in a sibling overlay
beside the existing libass text overlay, and leave the underlying
AVPlayer/SiloPlayer video stream untouched. That can preserve HDR/Dolby Vision
video presentation because subtitles are composed as UI, not baked into the
video bitstream. Until that renderer exists, selectable/default/forced bitmap
subtitles should be reported as unsupported or unpreserved rather than silently
claimed.

### 4.4 Downgrade rules

Downgrades must be explicit.

- TrueHD 7.1 to LPCM 7.1 is acceptable.
- TrueHD 7.1 to LPCM 5.1 is acceptable only if 7.1 cannot be initialized and the
  UI/logs say so.
- TrueHD 7.1 or 5.1 to AAC stereo is not an acceptable silent fallback.
- If the only working output is stereo, playback may continue only with a clear
  degradation log and UI-visible downgrade state.

## 5. Target architecture

### 5.1 Video path

The video path remains the SiloPlayer local AVPlayer loopback route:

1. `PlayerViewModel` selects SiloPlayer (current code:
   `avPlayerLocalDVLoopback`) for direct-play P7.
2. `PlayerViewModel` requires `PlaybackSourceProxy` for the remote HTTP(S)
   direct stream and rewrites `LoopbackSessionSpec.sourceURL` to localhost.
3. `LoopbackSessionSpec.videoMode` is `.convertProfile7To81`, logged as
   `profile7_to81_base_layer`.
4. `DVSegmentWriter` opens the source proxy URL without remote auth headers.
5. libavformat demuxes the MKV.
6. The HEVC elementary stream is filtered:
   - keep base-layer video NALs
   - strip enhancement-layer NALs
   - convert RPU metadata through Libdovi mode 2
7. Output is fragmented MP4 stored in `DVSegmentStore` and served by
   `DVSegmentServer` from localhost.
8. AVPlayer consumes the local media playlist.

The HLS master playlist can exist for inspection and future validation, but the
currently known-good startup path is the media playlist until the multivariant
manifest has been validated by Apple TV and `mediastreamvalidator`.

### 5.2 Audio path options

There are three viable audio designs.

#### Option A: single AVPlayer pipeline for temporary bring-up

Encode selected audio into a lossy AVPlayer-compatible HLS audio codec:

- copy `aac`, `ac-3`, `ec-3`
- copy `ec-3` with JOC when Atmos preservation is desired
- transcode TrueHD to `ec-3` 7.1 where available
- fall back to `ac-3` 5.1 where E-AC-3 is unavailable
- only fall back to AAC stereo with explicit degradation

This is simpler because AVPlayer owns A/V sync. It is not Infuse-equivalent for
TrueHD because E-AC-3/AC-3 are lossy transcodes. It is acceptable as a temporary
bring-up or explicit degradation path, but it is not the product target for
TrueHD.

#### Option B: single AVPlayer pipeline with lossless audio conversion

Decode unsupported lossless audio, then re-encode the decoded PCM bed into an
AVPlayer-compatible lossless audio codec inside the same local HLS/fMP4 session:

- `DVSegmentWriter` decodes TrueHD/DTS-HD-style input to PCM.
- The decoded 5.1/7.1 bed is encoded as FLAC in fMP4/HLS using the `fLaC`
  sample entry.
- AVPlayer owns demux, decode, buffering, A/V sync, seeking, and media timing.
- Apple TV outputs the decoded result as multichannel LPCM where the connected
  chain supports it.

This is the implemented lossless path for the local Dolby Vision loopback
because it keeps the whole presentation inside AVPlayer while avoiding lossy
`ec-3`/`ac-3` conversion for TrueHD. It still does not preserve TrueHD Atmos
object metadata. The receiver should show PCM/LPCM/Multi-Channel, not Atmos,
unless the selected source audio was already E-AC-3/JOC and copied through.

Codec policy:

- FLAC is the primary lossless HLS carrier for TrueHD/DTS-HD-style conversion.
- ALAC is not the current target because local validation favored sticking with
  FLAC and avoiding ALAC-specific channel-mapping risk.
- `ec-3`/`ac-3` remain explicit lossy degradation paths.
- AAC stereo is a last-resort visible downgrade only.

Current implementation detail: TrueHD / MLP / MLPA / Dolby TrueHD selected audio
uses `require_flac`, which restricts the encoder candidate list to FLAC. If FLAC
cannot be opened or muxed, the high-quality Silo route fails clearly instead of
falling back to E-AC-3, AC-3, or AAC.

#### Option C: split AVPlayer video plus Core Audio PCM fallback

Use AVPlayer for the local Dolby Vision video presentation, but decode the
selected unsupported audio stream ourselves and render PCM through a native
audio output path:

- `DVSegmentWriter` or a sibling audio worker decodes TrueHD to PCM frames.
- A Core Audio/AVAudioEngine-style renderer outputs 5.1/7.1 PCM.
- Audio is clocked to AVPlayer current time and rebuilt on seek.
- The local HLS video playlist can be video-only, or carry a low-priority audio
  placeholder only if AVPlayer requires it.

This is the likely path to Infuse-class TrueHD behavior because it can preserve
the lossless 5.1/7.1 bed and let Apple TV output LPCM. It is more complex
because Silo owns A/V sync, buffering, audio track switching, pause/resume,
seeks, and teardown.

### 5.3 Recommended implementation target

The product target is Option B for TrueHD/DTS-HD-style sources:

- AVPlayer owns the local Dolby Vision video presentation.
- Silo decodes the selected TrueHD/DTS-HD-style audio stream to PCM and
  re-encodes the bed to lossless FLAC inside the HLS session.
- The Apple TV output path presents decoded multichannel LPCM where the connected
  chain supports it.
- TrueHD Atmos is not claimed as Atmos because object metadata is not preserved.
- E-AC-3/JOC remains the only Atmos-preserving path in this spec, and only when
  copied through a NativePlayer or SiloPlayer route and confirmed by receiver
  validation.

Option A remains useful as a possible explicit lossy fallback, but it must never
be described as preserving TrueHD or TrueHD Atmos. Option C remains the fallback
architecture if AVPlayer cannot reliably accept FLAC 5.1/7.1 audio in local
fMP4/HLS or if FLAC channel layout mapping cannot be made trustworthy on a
physical Apple TV chain.

## 6. Current Silo prototype state

The current implementation has proven several important pieces:

- route selection reaches `dolby_vision_profile7_to81_base_layer_loopback`
- selected audio track ordinal is resolved to a real FFmpeg stream
- the writer can emit `init.mp4` plus media segments
- AVPlayer can start when pointed directly at `playlist.m3u8`
- TrueHD 7.1 can be decoded and re-encoded as FLAC `fLaC` with 8 output
  channels in the local HLS session
- AVFoundation on macOS can load and advance the generated `dvh1` + `fLaC`
  local HLS stream
- physical Apple TV logs show startup and sustained local HLS segment serving
  for a 72.9 Mbps Profile 7 TrueHD remux with source download rates generally
  above the file bitrate after cooperative source-prefetch retargeting
- generated HLS temp spill is automatically enabled above 40 Mbps and accounted
  separately from debug mirroring

The current implementation still needs continued physical validation for:

- final emitted DV metadata is truly Profile 8.1 rather than input P7 metadata
- physical display mode is Dolby Vision for the derived output
- TrueHD-derived FLAC reaches a physical Apple TV receiver as multichannel LPCM
- FLAC 5.1/7.1 channel mapping is correct on a real HDMI chain
- long-session spill budget behavior and seek-back behavior after many spilled
  segments

The latest validated local fixture output was:

- source: TrueHD, 8 channels
- output: FLAC `fLaC`, 8 channels, `7.1`, 48 kHz

Earlier AAC stereo output was a bring-up milestone only. It is not the target
behavior for TrueHD 5.1/7.1 sources.

## 7. Competitor behavior inference

### 7.1 Infuse

Infuse is closed source, so we cannot verify its implementation directly. Public
Firecore and Jellyfin-facing material strongly suggests this model:

- Infuse supports direct playback for many containers and formats.
- Infuse supports Dolby Vision single-layer playback on Apple TV.
- Infuse Pro decodes high-resolution audio formats such as Dolby TrueHD and
  DTS-HD MA.
- Infuse decodes compressed audio before Apple TV outputs it as multichannel
  LPCM.
- Infuse supports Atmos for E-AC-3 tracks, but not TrueHD Atmos as TrueHD Atmos.

The likely architecture is not "raw TrueHD into AVPlayer". It is some
combination of:

- custom demux/decode for unsupported containers/audio
- AVPlayer or another Apple-native presentation path for supported DV video
- app-owned audio decode to PCM for TrueHD/DTS-HD-style sources
- Apple TV HDMI output as LPCM

For Profile 7 video, public Firecore community discussion repeatedly points at
the Apple TV boundary: raw P7 is not the native target, while converted P8.1
style files can play as Dolby Vision. That matches Silo's
`profile7_to81_base_layer` design.

### 7.2 KSPlayer issue #875

The useful signal from the KSPlayer thread is the split between Apple-supported
DV profiles and raw P7:

- HLG, HDR10/HDR10+, DV P5, DV P8.1, and DV P8.4 can be targeted through
  AVPlayer/HLS/fMP4 when the playlist and sample entry describe the actual base
  layer and Dolby Vision signaling.
- P8.4 is not the same as P8.1. It has an HLG base layer, so it needs HLG
  `VIDEO-RANGE` plus supplemental DV signaling rather than a plain PQ P8.1-style
  declaration.
- P7 should not be fed to AVPlayer as raw P7 HLS from regular FFmpeg. If DOVI is
  simply deleted, the result is HDR10 base-layer playback, not Dolby Vision.
- P10 is AV1 Dolby Vision and should remain hardware/route-gated until Silo
  has an actual AV1 direct path.

This means Silo should validate P5/P8/P8.4 separately from the P7-to-P8.1
derivation work. A P7 experiment succeeding or failing does not prove native P5
or P8 support is healthy.

### 7.3 VidHub

VidHub is also closed source. Public developer/community statements indicate:

- Apple TV support is aligned with iOS/tvOS framework-supported Dolby Vision
  profiles, namely Profile 5 and Profile 8.
- Profile 7 is not supported as Profile 7.
- VidHub's Apple TV Atmos notes say E-AC-3/JOC is supported and TrueHD Atmos is
  not.

That suggests VidHub is not publicly claiming a raw P7+TrueHD Atmos passthrough
path. Its Apple TV behavior appears closer to:

- use Apple-native DV profiles where available
- rely on E-AC-3/JOC for Atmos
- avoid claiming TrueHD Atmos
- possibly decode unsupported lossless audio to PCM, but this is not public
  enough to treat as confirmed

## 8. Open-source tvOS client survey

I did not find an open-source tvOS Plex/Jellyfin/Emby-style app that publicly
demonstrates the exact target behavior:

- P7 MKV direct play
- client-side P7 to P8.1 derivation
- TrueHD decode to multichannel LPCM
- AVPlayer/Apple TV Dolby Vision presentation

Known nearby projects:

- Swiftfin is open-source and native for Jellyfin on iOS/tvOS. Its docs list
  both a VLCKit player and a native AVPlayer path. Its documented capability
  matrix does not show TrueHD support, says AVPlayer cannot open MKV directly,
  and treats P7 as fallback-layer behavior rather than full dynamic-metadata
  Dolby Vision.
- JellyCon is an open-source Kodi add-on, not a native tvOS AVPlayer pipeline.
  It is useful ecosystem context, but it is not a reference for this Apple TV
  app-delivery problem.
- Emerging open-source Apple TV Jellyfin clients and forks exist, including
  Swiftfin-derived work, but I found no public evidence that any implement this
  exact P7-to-P8 plus TrueHD-to-LPCM pipeline.
- Plex and Emby official Apple TV clients are not open-source, and their public
  behavior should not be treated as implementation evidence.

Conclusion: Infuse is still the practical benchmark, but not an available source
reference. Silo needs to build and validate its own pipeline.

## 9. Validation requirements

### 9.1 Logs

Every loopback session must log:

- source container and source stream indexes
- input DOVI record
- final emitted DOVI record
- final video sample entry and final `CODECS` value
- whether RPU conversion happened
- selected source audio codec/channels/layout
- selected output audio mode
- final output audio codec/channels/layout
- lossless conversion codec when used (`flac` for the current target)
- whether final channel mapping matches the source layout
- whether Atmos is preserved, dropped, or not applicable
- whether a downgrade happened

The expected healthy TrueHD-derived lossless log line is:

```text
selected audio transcode sourceStream=1 sourceCodec=truehd outputCodec=fLaC sourceChannels=8 outputChannels=8 preservesAtmos=0 mode=fLaC
```

Any `sourceCodec=truehd outputCodec=mp4a.40.2 outputChannels=2` result is a
stereo downgrade and should be surfaced as a visible degradation, not as the
normal path.

### 9.2 Device validation

Required physical validation cases:

- Apple TV 4K connected directly to a Dolby Vision TV
- Apple TV 4K connected through an AVR/soundbar that reports channel layout
- Apple TV set to Audio Format Auto
- Apple TV set to Convert to Dolby Digital 5.1
- non-DV display chain for fallback honesty

Required media cases:

- P7 MKV + TrueHD 7.1
- P7 MKV + TrueHD 5.1
- P7 MKV + E-AC-3/JOC
- P7 MKV + DTS-HD/DTS-style lossless audio if we support the same lossless
  conversion path beyond TrueHD
- P8.1 MKV/MP4 regression asset
- P5 regression asset

Pass criteria:

- display enters Dolby Vision only when the output is truly Dolby Vision
- TrueHD-derived FLAC audio reaches AVR as multichannel PCM for the lossless
  path
- 7.1 channel order is correct for FLAC
- TrueHD Atmos is not claimed as Atmos
- E-AC-3/JOC Atmos is claimed only when the AVR confirms it
- stereo fallback is visible and never silent

### 9.3 Dolby Vision confirmation checklist

The TV's transient Dolby Vision badge is useful, but it is not the only source
of truth. Some displays only show the badge on HDMI mode changes, some suppress
it after the first switch, and some keep their Apple TV input in a Dolby Vision
container depending on system settings.

To confirm the local loopback is actually producing Dolby Vision:

1. Set Apple TV video output to a normal SDR format, then enable Match Dynamic
   Range in Settings > Video and Audio > Match Content. Apple documents that
   Apple TV 4K needs Match Dynamic Range enabled for 4K Dolby Vision content at
   lower cinematic frame rates.
2. Start the P7-to-8.1 loopback item and watch for an HDMI resync/black flash.
   No resync does not prove failure, but a resync from SDR into DV is strong
   evidence that the output mode changed.
3. Open the TV's HDMI signal information panel during playback, not just the
   picture-mode preset. Look for Dolby Vision, PQ, BT.2020, and the current
   frame rate. The exact menu name depends on the TV.
4. Compare against a known Dolby Vision title in the Apple TV app or another
   trusted app using the same HDMI input and Apple TV settings. The TV's signal
   panel should report the same Dolby Vision mode.
5. Capture Silo's route logs for the same playback session. A candidate DV
   session should show SiloPlayer, or today's implementation identifier
   `backend=avPlayerLocalDVLoopback`,
   `videoMode=profile7_to81_base_layer`, final `CODECS`/sample-entry values containing
   `dvh1`, a final DOVI record such as profile 8, compatibility 1, and
   `tv display apply ... dr=5`.
6. Preserve the local HLS artifacts when a physical validation run is ambiguous.
   Inspect both manifests. The media playlist proves segment delivery, but the
   multivariant `master.m3u8` is where `CODECS`, `SUPPLEMENTAL-CODECS`, and
   `VIDEO-RANGE` are advertised. If tvOS plays the media playlist but the TV
   reports HDR10/PQ only, the next experiment is to start AVPlayer from
   `master.m3u8` and validate that manifest path on-device.
7. Treat missing TV badge plus TV signal info showing HDR10/PQ only as a failed
   Dolby Vision validation, even if video plays correctly.

## 10. References

- Apple TV audio settings: https://support.apple.com/en-mide/guide/tv/atvba773c3c9/26/tvos/26
- Apple TV 4K HDR / Dolby Vision setup: https://support.apple.com/en-us/102339
- Apple HLS Authoring Specification appendixes: https://developer.apple.com/documentation/http-live-streaming/hls-authoring-specification-for-apple-devices-appendixes/
- Firecore Infuse audio capabilities: https://support.firecore.com/hc/en-us/articles/217735707-Audio-Options-Capabilities
- Jellyfin Infuse client spotlight: https://jellyfin.org/posts/client-infuse/
- Swiftfin repository: https://github.com/jellyfin/swiftfin
- Swiftfin player differences: https://github.com/jellyfin/Swiftfin/blob/main/Documentation/players.md
- Jellyfin client list: https://jellyfin.org/downloads/clients/?platform=iOS,tvOS
- VidHub DV profile discussion: https://www.reddit.com/r/VidHubvideoplayer/comments/1oal80m/what_dolby_vision_profiles_does_vidhub_support/
- VidHub Apple TV Atmos notes: https://www.reddit.com/r/VidHubvideoplayer/comments/1rw1mw8/apple_tv_dolby_atmos_passthrough_notes/
