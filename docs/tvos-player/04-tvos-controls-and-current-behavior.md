Repo snapshot date: 2026-08-16 (branch `player/one-player-cleanup`, HEAD `6818819`)

# tvOS Controls And Current Behavior

## 1. Shell structure

The tvOS player shell lives in:

- [`PlayerView.swift`](../../iosApp/iosApp/Screens/Player/PlayerView.swift)
- [`tvOS/TVPlayerControls.swift`](../../iosApp/iosApp/Screens/Player/tvOS/TVPlayerControls.swift)
- [`tvOS/TVPlayerScrubber.swift`](../../iosApp/iosApp/Screens/Player/tvOS/TVPlayerScrubber.swift)
- [`tvOS/TVPlayerTransportCluster.swift`](../../iosApp/iosApp/Screens/Player/tvOS/TVPlayerTransportCluster.swift)
- [`tvOS/TVPlayerInfoHUD.swift`](../../iosApp/iosApp/Screens/Player/tvOS/TVPlayerInfoHUD.swift)
- [`tvOS/TVPressCaptureView.swift`](../../iosApp/iosApp/Screens/Player/tvOS/TVPressCaptureView.swift)
- [`tvOS/HoldSeekIndicator.swift`](../../iosApp/iosApp/Screens/Player/tvOS/HoldSeekIndicator.swift)

The UI is a two-state shell:

- **idle overlay** — bottom scrubber and transport row over video
- **floating HUD** — top-center panel with tabs

Before reading further, note the shell is now **route-uniform**. With a single
AVPlayer family there is no "the other backend does this differently" branch
left in the tvOS UI; what varies is capability flags on
`PlayerBackendCapabilities`, and all three routes use
`PlayerBackendCapabilities.avFoundation`.

## 2. Overlay visibility

Visibility comes from `PlayerViewModel.showControls` plus
`TVPlayerControls.isHUDPresented`:

- the idle overlay auto-hides after 5 seconds while playing
- any control interaction calls `scheduleHideControls()`, which shows the
  overlay first and then restarts the timer
- opening the HUD pins the controls visible and marks `isHUDPresented = true`
- closing the HUD restores normal auto-hide behavior

When the overlay is hidden, `PlayerView` installs an invisible full-screen focus
sink so the Siri Remote still has a target. Pressing Select on that sink
re-opens the overlay.

## 3. Siri Remote behavior

`PlayerView` installs the global tvOS commands:

- **Play/Pause button** — toggles playback and re-shows the overlay timer path
- **Menu / Exit button**
  - if the HUD is up, let the HUD handle dismissal
  - else if the overlay is visible, hide the overlay first
  - else dismiss the player entirely

Inside the overlay:

- D-pad Down from the scrubber opens the HUD
- D-pad Down from the transport row opens the HUD
- transport buttons live inside a `focusSection()` so left/right movement stays
  in the cluster

When the HUD closes, focus is restored to the transport `options` button.

## 4. Scrubber behavior

The scrubber is a scrubbing mode, not a passive progress bar:

- focus entering the scrubber calls `beginScrub(...)`
- left/right nudge the preview by 10 seconds
- Select commits immediately
- blur commits too, unless the shell set `cancelOnBlur = true`

`cancelOnBlur` is used specifically when opening the HUD so that moving focus
away from the scrubber does not turn the current preview position into a seek.

The scrubber also shows chapter ticks from `viewModel.chapters`, a floating time
bubble while focused, and buffered-ahead fill.

Current truth: `bufferedAheadSeconds` is published on **every** route now, so
the buffered fill is always live. The old "empty on the default path" caveat
was a `PlayerCore` limitation.

## 5. Transport row

The bottom transport row is icon-only:

- skip back 10 s
- play / pause
- skip forward 10 s
- options
- close player

The options button is the dedicated transport-row entry into the HUD, but not
the only one: D-pad Down from the scrubber or any transport button opens the
same HUD.

## 6. HUD tabs

`TVPlayerInfoHUD.Tab` is `{info, stats, video, audio, subtitles, chapters}`.
Info and Video are always available. Audio, Subtitles, and Chapters are hidden
when the stream has none — the HUD hides rather than disables, to keep the tab
bar tidy. Subtitles is an exception: it also appears when the stream has no
subtitle tracks but the server can still produce them (AI transcription /
translation, or a provider search), gated on the same `hasActionableSource`
probe the pane uses, so a track-less file still exposes "AI Subtitles…" and
"Search Subtitles…".

### Info

Series / title / episode tag, year and runtime, overview, stream badges,
selected audio summary, selected subtitle summary, current chapter summary.
Data comes from `PlayerMetadata`, derived from the already-fetched `WatchDetail`
plus the selected `FileVersion`.

### Stats

The diagnostics pane. It renders
[`PlaybackStatsPanel`](../../iosApp/iosApp/Screens/Player/PlaybackStatsPanel.swift)
over `viewModel.playbackStats` in a two-column TV layout, paging between the
Source/Media, Buffer, Network, and Device sections. Loopback sessions surface
their store, temp-spill, and playable-ahead counters here.

The `PlayerRouteStatusRow` list `PlayerViewModel` builds from
`ApplePlaybackRouteCapabilities` (Playback, Route, Subtitles, Audio delay,
Subtitle styling, Now Playing, Picture in Picture) is **not** shown on tvOS —
its only consumer is the macOS
[`MacPlayerOptionsPanel`](../../iosApp/iosApp/macOS/MacPlayerOptionsPanel.swift).
That is where the read-only `Audio delay: Unsupported` row appears.

### Video

`VideoPane` has two columns:

- **Playback** — Quality, Speed, and Aspect. Aspect is gated on
  `viewModel.backendCapabilities.supportsVideoGravity`, which is `true` for
  `avFoundation` and `false` for `macAVFoundation`.
- **Sync** — Subtitle delay (gated on `supportsSubtitleDelay`, which the view
  model raises via `withSubtitleControls(_:)` when the active track is
  Silo-rendered) and the Auto-play next toggle.

Two controls that used to live here are **gone**, removed with the
CompatibilityPlayer backend in `f1b1bba`:

- **HDR passthrough toggle.** It only did anything on the `PlayerCore` decode
  path; on AVPlayer the HDMI mode is negotiated by
  [`TVDisplayCriteria`](../../iosApp/iosApp/Screens/Player/Shared/TVDisplayCriteria.swift)
  from the stream's own colour signalling, so a user toggle had nothing to act
  on. `PlayerSettings.setHDREnabled(_:)` and the `hdrEnabled` preference still
  exist for settings-wire compatibility, but no player UI reads them and
  `PlayerViewModel`'s cast-command handler treats `.setHDREnabled` as an
  explicit no-op (see [cast-remote.md](cast-remote.md)).
- **Audio delay.** Never implemented on AVPlayer;
  `ApplePlaybackRouteCapabilities.audioDelay` is `.unsupported` on all four
  capability profiles, so the control had no route to appear on.

### Audio

A list of discovered audio streams with the selected layout and codec.
Selection goes through AVFoundation media selection (native direct / HLS) or
through a loopback replan that rebuilds the local session around the new track
(SiloPlayer). The pane makes no audio-delay claim.

### Subtitles

Primary subtitle list including `Off`; an optional secondary list once a primary
is selected; the stored subtitle-delay value; the stored subtitle font size; and
the entry points into AI subtitles and provider search.

Subtitle appearance (font, size, colour, outline, position) is edited through
`SubtitleAppearanceDialog`
([`tvOS/SubtitleAppearanceDialog.swift`](../../iosApp/iosApp/Screens/Player/tvOS/SubtitleAppearanceDialog.swift)),
a full-pane dialog with its own focus handling. The generic HUD control kit —
`HUDSettingRow`, `HUDToggleRow`, `HUDPickerDialog`, `HUDPickerOptions`,
`HUDDropdownOption`, `PaneColumn`, `HUDScrollablePane`, `TabPill`,
`HUDTrackRow`, `HUDChapterRow`, and the button styles — lives under
[`tvOS/HUDKit/`](../../iosApp/iosApp/Screens/Player/tvOS/HUDKit); the panes
themselves stay in `TVPlayerInfoHUD.swift`.

Current truth: `bufferedAheadSeconds` is published on **every** route now, so
the buffered fill is always live. The old "empty on the default path" caveat
was a `PlayerCore` limitation.

## 5. Transport row

The bottom transport row is icon-only:

- skip back 10 s
- play / pause
- skip forward 10 s
- options
- close player

The options button is the dedicated transport-row entry into the HUD, but not
the only one: D-pad Down from the scrubber or any transport button opens the
same HUD.

## 6. HUD tabs

`TVPlayerInfoHUD.Tab` is `{info, stats, video, audio, subtitles, chapters}`.
Info and Video are always available. Audio, Subtitles, and Chapters are hidden
when the stream has none — the HUD hides rather than disables, to keep the tab
bar tidy. Subtitles is an exception: it also appears when the stream has no
subtitle tracks but the server can still produce them (AI transcription /
translation, or a provider search), gated on the same `hasActionableSource`
probe the pane uses, so a track-less file still exposes "AI Subtitles…" and
"Search Subtitles…".

### Info

Series / title / episode tag, year and runtime, overview, stream badges,
selected audio summary, selected subtitle summary, current chapter summary.
Data comes from `PlayerMetadata`, derived from the already-fetched `WatchDetail`
plus the selected `FileVersion`.

### Stats

The diagnostics pane. It renders
[`PlaybackStatsPanel`](../../iosApp/iosApp/Screens/Player/PlaybackStatsPanel.swift)
over `viewModel.playbackStats` in a two-column TV layout, paging between the
Source/Media, Buffer, Network, and Device sections. Loopback sessions surface
their store, temp-spill, and playable-ahead counters here.

The `PlayerRouteStatusRow` list `PlayerViewModel` builds from
`ApplePlaybackRouteCapabilities` (Playback, Route, Subtitles, Audio delay,
Subtitle styling, Now Playing, Picture in Picture) is **not** shown on tvOS —
its only consumer is the macOS
[`MacPlayerOptionsPanel`](../../iosApp/iosApp/macOS/MacPlayerOptionsPanel.swift).
That is where the read-only `Audio delay: Unsupported` row appears.

### Video

`VideoPane` has two columns:

- **Playback** — Quality, Speed, and Aspect. Aspect is gated on
  `viewModel.backendCapabilities.supportsVideoGravity`, which is `true` for
  `avFoundation` and `false` for `macAVFoundation`.
- **Sync** — Subtitle delay (gated on `supportsSubtitleDelay`, which the view
  model raises via `withSubtitleControls(_:)` when the active track is
  Silo-rendered) and the Auto-play next toggle.

Two controls that used to live here are **gone**, removed with the
CompatibilityPlayer backend in `f1b1bba`:

- **HDR passthrough toggle.** It only did anything on the `PlayerCore` decode
  path; on AVPlayer the HDMI mode is negotiated by
  [`TVDisplayCriteria`](../../iosApp/iosApp/Screens/Player/Shared/TVDisplayCriteria.swift)
  from the stream's own colour signalling, so a user toggle had nothing to act
  on. `PlayerSettings.setHDREnabled(_:)` and the `hdrEnabled` preference still
  exist for settings-wire compatibility, but no player UI reads them and
  `PlayerViewModel`'s cast-command handler treats `.setHDREnabled` as an
  explicit no-op (see [cast-remote.md](cast-remote.md)).
- **Audio delay.** Never implemented on AVPlayer;
  `ApplePlaybackRouteCapabilities.audioDelay` is `.unsupported` on all four
  capability profiles, so the control had no route to appear on.

### Audio

A list of discovered audio streams with the selected layout and codec.
Selection goes through AVFoundation media selection (native direct / HLS) or
through a loopback replan that rebuilds the local session around the new track
(SiloPlayer). The pane makes no audio-delay claim.

### Subtitles

Primary subtitle list including `Off`; an optional secondary list once a primary
is selected; the stored subtitle-delay value; the stored subtitle font size; and
the entry points into AI subtitles and provider search.

Subtitle appearance (font, size, colour, outline, position) is edited through
`SubtitleAppearanceDialog`, a full-pane dialog with its own focus handling.
It is currently a `private struct` inside `TVPlayerInfoHUD.swift` alongside the
rest of the HUD control kit — `HUDSettingRow`, `HUDToggleRow`, `HUDPickerDialog`,
`HUDPickerOptions`, `HUDDropdownOption`, `PaneColumn`, `HUDScrollablePane`,
`TabPill`, `HUDTrackRow`, `HUDChapterRow`, and the button styles. Extracting the
control kit and the appearance dialog into their own files under
`Screens/Player/tvOS/` is queued UI-cleanup work on `player/cleanup-ui`; as of
this snapshot the file is not split and this doc will be updated when it lands.

Current truth:

- primary subtitle selection works on all three routes
- secondary subtitles are sidecar-only on all three routes
- subtitle delay and styling apply to Silo-rendered tracks only

### Chapters

Chapter numbers, titles, timestamps, with the current chapter highlighted.
Selecting a row calls `viewModel.seekTo(seconds:)` and closes the HUD. There is
no separate chapter-play mode.

## 7. Route behavior in the tvOS shell

The shell no longer branches on backend identity:

- `Info`, `Stats`, and `Video` always show
- `Audio`, `Subtitles`, and `Chapters` appear whenever the active route has
  published rows for them
- all three routes populate those tabs through AVFoundation media selection
  plus bridge-supplied chapters
- Silo keeps the custom tvOS shell and Siri Remote ownership on every route
  (`tvOSRemoteOwnership` is `.repoVerified` for all of them)

## Validation log

- verified: `TVPlayerInfoHUD.Tab` is `{info, stats, video, audio, subtitles,
  chapters}`; `VideoPane` exposes Quality / Speed / Aspect / Subtitle delay /
  Auto-play next and nothing else.
- verified: no HDR toggle exists anywhere in `tvOS/TVPlayerInfoHUD.swift`;
  `PlayerViewModel`'s `.setHDREnabled` case is a documented no-op.
- verified: `audioDelay` is `.unsupported` on `avPlayerHLS`,
  `avPlayerNativeDirect`, `siloPlayerLoopback`, and `macAVFoundation`; the only
  surviving surface is the read-only `Audio delay` status row in the macOS
  options panel, which tvOS never renders.
- verified: `bufferedAheadSeconds` is published on every route, so the
  scrubber's buffered fill is live everywhere.
- verified: the HUD control kit lives in `tvOS/HUDKit/` and
  `SubtitleAppearanceDialog` in its own file (pure moves, no behavior change).
- corrected: earlier revisions described route-specific Audio-pane behavior for
  `PlayerCore`. That backend no longer exists.
