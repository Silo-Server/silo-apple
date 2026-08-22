> [!WARNING]
> **Historical pre-AetherEngine archive.** This document describes the removed custom-player architecture or its pre-migration validation model. It is retained for history only and must not be used as current implementation guidance. See the [AetherEngine-only replacement specification](aetherengine-replacement-spec.md).

Repo snapshot date: 2026-04-18 (current working tree)

# tvOS Controls And Current Behavior

## 1. Shell structure

The tvOS player shell is spread across:

- [`PlayerView.swift`](../../iosApp/iosApp/Screens/Player/PlayerView.swift)
- [`TVPlayerControls.swift`](../../iosApp/iosApp/Screens/Player/tvOS/TVPlayerControls.swift)
- [`TVPlayerScrubber.swift`](../../iosApp/iosApp/Screens/Player/tvOS/TVPlayerScrubber.swift)
- [`TVPlayerTransportCluster.swift`](../../iosApp/iosApp/Screens/Player/tvOS/TVPlayerTransportCluster.swift)
- [`TVPlayerInfoHUD.swift`](../../iosApp/iosApp/Screens/Player/tvOS/TVPlayerInfoHUD.swift)

The current UI is a two-state shell:

- **idle overlay**  
  bottom scrubber and transport row over video
- **floating HUD**  
  top-center panel with tabs for Info / Video / Audio / Subtitles / Chapters

This is the real implementation today. It is **not** the older fullscreen
sheet model still mentioned in some comments.

## 2. Overlay visibility

The visibility rules come from `PlayerViewModel.showControls` plus
`TVPlayerControls.isHUDPresented`:

- the idle overlay auto-hides after 5 seconds while playing
- any control interaction calls `scheduleHideControls()`, which shows the
  overlay first and then restarts the timer
- opening the HUD pins the controls visible and marks `isHUDPresented = true`
- closing the HUD restores normal auto-hide behavior

When the overlay is hidden, `PlayerView` installs an invisible full-screen
focus sink so the Siri Remote still has a target. Pressing Select on that sink
re-opens the overlay.

## 3. Siri Remote behavior

`PlayerView` installs the global tvOS commands:

- **Play/Pause button**  
  toggles playback and re-shows the overlay timer path
- **Menu / Exit button**
  - if the HUD is up, let the HUD handle dismissal
  - else if the overlay is visible, hide the overlay first
  - else dismiss the player entirely

Inside the overlay itself:

- D-pad Down from the scrubber opens the HUD
- D-pad Down from the transport row opens the HUD
- transport buttons are kept inside a `focusSection()` so left/right movement
  stays inside the cluster

When the HUD closes, focus is restored to the transport `options` button.

## 4. Scrubber behavior

The scrubber is not a passive progress bar. On tvOS it becomes a small
scrubbing mode:

- focus entering the scrubber calls `beginScrub(...)`
- left/right nudge the preview by 10 seconds
- Select commits immediately
- blur commits too, unless the shell set `cancelOnBlur = true`

`cancelOnBlur` is used specifically when opening the HUD so that moving focus
away from the scrubber does not accidentally turn the current preview position
into a seek.

The scrubber also shows:

- chapter ticks from `viewModel.chapters`
- a floating time bubble while focused
- buffered-ahead fill, but only when `bufferedAheadSeconds > 0`

Important current truth:

- `bufferedAheadSeconds` is only emitted by `AVPlayerBackend`
- on the default `PlayerCore` path, the buffered fill stays empty

## 5. Transport row

The bottom transport row is deliberately small and icon-only:

- skip back 10s
- play / pause
- skip forward 10s
- options
- close player

The options button is the dedicated transport-row entry point into the floating
HUD, but it is not the only one: D-pad Down from the scrubber or from any
transport button opens the same HUD. The old track/settings/chapter entry
points are no longer separate tvOS buttons.

## 6. HUD tabs

The floating HUD always includes:

- `Info`
- `Video`

It conditionally adds:

- `Audio` when `audioTracks` is not empty
- `Subtitles` when `subtitleTracks` is not empty
- `Chapters` when `chapters` is not empty

### Info

The Info tab shows:

- series / title / episode tag
- year and runtime
- overview
- stream badges
- selected audio summary
- selected subtitle summary
- current chapter summary

This data comes from `PlayerMetadata`, which is derived from the already-fetched
`WatchDetail` plus the selected `FileVersion`.

### Video

The Video tab exposes:

- speed
- aspect / video gravity
- HDR passthrough toggle
- auto-play-next toggle

Route-gated controls appear only when the current backend actually supports
them:

- audio delay is hidden on every current route because it is not implemented
- subtitle delay appears for routes with Silo-controlled subtitle rendering

Current truth:

- subtitle delay is implemented through the shared libass subtitle session
- speed works on both CompatibilityPlayer (`PlayerCore`) and AVPlayer-backed
  routes through `activePlayer`

### Audio

The Audio tab shows:

- a list of discovered audio streams
- selected layout
- selected codec

On CompatibilityPlayer (`PlayerCore`), selecting a row switches FFmpeg stream
index locally and rebuilds the audio decoder around the current playback
position.

The Audio pane no longer claims audio delay support when the active route does
not have it.

### Subtitles

The Subtitles tab shows:

- primary subtitle list, including `Off`
- optional secondary subtitle list when a primary subtitle is already selected
- stored subtitle-delay value
- stored subtitle font size

Current truth:

- primary subtitle selection works on CompatibilityPlayer and on
  AVPlayer-backed routes
- NativePlayer/SiloPlayer secondary subtitles are currently sidecar-only
- subtitle delay and styling work for Silo-rendered subtitle tracks

### Chapters

The Chapters tab lists chapter numbers, titles, timestamps, and highlights the
current chapter.

Selecting a row:

1. calls `viewModel.seekTo(seconds:)`
2. closes the HUD

There is no separate chapter-play mode.

## 7. NativePlayer/SiloPlayer behavior in the tvOS shell

The tvOS shell no longer treats AVPlayer-backed playback as a single no-tracks
route. In practice:

- the HUD still always shows `Info` and `Video`
- `Audio`, `Subtitles`, and `Chapters` appear whenever the active route has
  published rows for them
- NativePlayer Direct, NativePlayer HLS, and SiloPlayer routes can now keep
  those tabs populated through AVFoundation media selection plus bridge-supplied
  chapters

## 8. Comment mismatches worth remembering

One mismatch is easy to miss if you only skim comments:

- `PlayerView.swift` still says tvOS uses fullscreen sheets for
  tracks/chapters/settings. The implementation is now the floating HUD.

The docs in this folder follow the implementation, not that stale comment.

## Validation log

- verified: overlay auto-hide is owned by `PlayerViewModel`, not by the HUD
  views themselves.
- verified: D-pad Down is the main gesture for entering the floating HUD from
  the idle overlay.
- corrected: the tvOS player no longer uses fullscreen sheets for these
  controls; it uses a floating top-center HUD.
