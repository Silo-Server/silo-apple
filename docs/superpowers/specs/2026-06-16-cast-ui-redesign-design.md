# iOS Cast Remote Redesign — "Native Now-Playing" — Design Spec

- **Date:** 2026-06-16
- **Status:** Approved (design); ready for implementation planning
- **Platform:** iOS only (the tvOS receiver, the cast wire protocol, the server, and the Android client are all unchanged)
- **Related:** `iosApp/iosApp/Cast/` (the working feature Codex landed), `docs/tvos-player/` (player behavior the receiver drives)

## 1. Summary

A **view-layer redesign** of the iOS side of the remote-control / cast feature so
it looks and feels like a native iOS "Now Playing" surface. The networking,
Bonjour discovery, TLS session, wire protocol, and the tvOS receiver that Codex
built all **work and stay untouched** — this changes only how the phone *presents*
casting.

Three surfaces are reworked:

1. **The remote-control screen** (`SiloCastRemoteControlView`) — today a black
   screen of centered text, a slider, three transport buttons, and a cramped row
   of six `.bordered` menu buttons. It becomes an **immersive, artwork-forward
   now-playing screen** (the Apple Music / TV-app idiom).
2. **The target picker** (`SiloCastTargetPickerView`) — gains a proper
   **"Searching…"** state instead of flashing the "No Silo TVs Found" failure
   card the instant it opens.
3. **The control-mode button** (`SiloCastControlModeButton`) in the Home top bar
   — aligned to the app's chrome tokens with a clearer **active/connected** read.

The defining new capability is **artwork**: the remote shows poster/backdrop art
resolved **client-side from the `contentId` already in the cast state**, so no
protocol field needs to be added.

## 2. What's wrong today (the problems being fixed)

From `iosApp/iosApp/Cast/iOS/SiloCastViews.swift`:

| # | Problem | Why it reads as non-native |
|---|---|---|
| 1 | No artwork — remote is centered text on flat black. | Every native now-playing surface (Music, Podcasts, TV app, Control Center's Apple TV remote) is artwork-forward. Biggest tell. |
| 2 | Six `.buttonStyle(.bordered)` menu buttons (`Audio · Subtitles · Quality · Speed · Display · Stop`) crammed in one horizontal row. | Overflows / clips on phone widths; reads like a debug panel. |
| 3 | `Stop` is a stray button wedged between `Speed` and the menus. | Destructive/terminal action with no deliberate placement. |
| 4 | `Spacer`-driven vertical stack, no hierarchy, no material, no grouping. | Flat and unstructured vs. the layered system look. |
| 5 | Quality/Display chips render even when empty/unsupported. | Dead controls; iOS hides what doesn't apply. |
| 6 | Picker shows `ContentUnavailableView("No Silo TVs Found")` immediately, before discovery has had time to find anything. | Looks broken on first open; AirPlay shows a spinner while it scans. |
| 7 | Connecting state is a bare centered `ProgressView` + text; error is raw red `.footnote`. | No skeleton, no styled banner. |

## 3. Design language (source of truth)

Reuse the existing iOS tokens — do not introduce new colors or a new type scale.
From `iosApp/iosApp/Theme/Colors.swift`:

- Background OLED black `siloBackground` `#000000`; elevated surface
  `siloSurfaceElevated` `#15171C`; glass `siloGlassStrong`
  (`#16171B` @ 86%).
- Monochrome chrome — primary `siloOnSurface` `#EDEDED`, secondary
  `siloSecondaryText` (`#EDEDED` @ 60%), hairline `siloOutline`
  (white @ 12%). Active/selected chrome uses `siloChromeSelectedFill`
  (white @ 14%) / resting `siloChromeRestingFill` (white @ 7%).
- **No chromatic accent.** The play button is a white (`#EDEDED`) filled circle
  with a black glyph; artwork is the only place full color lives. Errors use
  `siloError`.

Typography uses the system text styles already in the file (`.title2`,
`.headline`, `.subheadline`, `.caption.monospacedDigit()`), not custom fonts.
Time strings go through the existing `PlayerTimeFormatter.formatHMS`.

## 4. Scope — locked decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Overall direction | **A — Immersive now-playing** (full-screen, artwork-forward), not the compact control-sheet (B). |
| 2 | Foreground artwork | **Poster (2:3) preferred**; episode 16:9 still used only when no poster exists. |
| 3 | Background | **Blurred + heavily dimmed artwork** filling the screen (backdrop preferred, poster fallback); flat black until artwork resolves. |
| 4 | Artwork source | **Client-side from `contentId`** — no new protocol field, no tvOS change. |
| 5 | Secondary controls | A bottom **icon row**, each opening a native `Menu`; **adaptive** (a chip is omitted when it has no content/support). |
| 6 | Stop / Disconnect / Choose TV | Moved into the **top-right `•••` menu**; chevron-down only **minimizes** (keeps the session). |
| 7 | Surfaces in scope | Remote screen **+** target picker **+** control-mode button. |
| 8 | Out of scope | Wire protocol, tvOS `TVCastReceiver`, `PlayerViewModel` cast extensions, server, Android. |

## 5. Remote screen anatomy (`SiloCastRemoteControlView`)

Presented as today via `.fullScreenCover` from `MainTabView`, driven by
`controller.isShowingRemoteControl`. Top-to-bottom, over a blurred-artwork
background:

1. **Top bar** — leading `chevron.down` (minimize: `hideRemoteControl()` +
   `dismiss()`, session stays alive); trailing `•••` overflow menu (see §8).
   The TV name moves out of the nav title into the now-playing block.
2. **Artwork card** — rounded (`siloSurfaceElevated` placeholder), poster
   aspect, rendered with `AsyncImageView(url:thumbhash:contentMode:)`. Modest
   max height so the controls always fit without scrolling on small devices.
3. **Title / subtitle** — `state.title` (`.title2`, semibold) and `state.subtitle`
   (`.subheadline`, secondary), centered, line-limited (2).
4. **"Playing on {TV}" pill** — `airplayvideo`/`tv` glyph + `activeTarget.name`
   in a subtle `siloChromeRestingFill` capsule.
5. **Scrubber** (§6).
6. **Transport row** (§6).
7. **Secondary control row** (§7).
8. **Error banner** (§9) when present.

### Background
A full-bleed `AsyncImageView` of the backdrop (poster fallback), `.blur(radius:)`
+ a `siloBackground` scrim at high opacity for legibility, behind the
foreground stack. This is the single biggest contributor to the native feel.

## 6. Artwork resolution, scrubber & transport

### Artwork resolution (no protocol change)
A small resolver keyed on `state.contentId`:

- Driven from the view with `.task(id: contentId)`.
- Resolves through the **same path the detail screen uses**: check
  `ResponseCache.shared` under `CacheKey.itemDetail(contentId)` first (warm and
  instant when the user cast from a detail page), otherwise
  `SiloAPI.shared.itemDetail(contentId:)`, reading `posterUrl` /
  `backdropUrl` off the returned `ItemDetail`.
- Holds `posterURL` / `backdropURL` in `@State`; nil `contentId` (idle) → flat
  black, no artwork. Failures degrade silently to the flat background.

### Scrubber
Keep the existing scrub-preview logic (`scrubPreview` state; commit
`controller.send(.seek(seconds:))` on editing end). Restyle to the native thin
track. Times: **elapsed** (leading) and **−remaining** (trailing),
`.caption.monospacedDigit()`, secondary color. Disabled when `duration <= 0`.

### Transport
`gobackward.10` · large white filled play/pause circle · `goforward.30` — the
same commands (`.seek`, `.playPause`) at system sizing/spacing. Play/pause glyph
follows `state.isPlaying`; show a spinner in place of the glyph while
`state.isLoading || state.isBuffering`.

## 7. Secondary controls (replaces the six bordered buttons)

A single bottom row of icon controls, each a native `Menu` (anchored popover —
the iOS-correct pattern), each labeled with a small caption and reflecting the
current value:

- **Audio** (`waveform`) — `state.audioTracks`, check on `selectedAudioTrackId`.
- **Subtitles** (`captions.bubble`) — `Off` + `state.subtitleTracks`, check on
  `selectedSubtitleTrackId`.
- **Quality** (`slider.horizontal.3`) — `state.qualityOptions`, check on
  `activeQualityId`; whole chip disabled while `isQualitySwitching`.
- **Speed** (`speedometer`) — the existing `[0.75, 1.0, 1.25, 1.5, 2.0]`.
- **Aspect / HDR** (`rectangle.inset.filled`) — `VideoGravity.allCases` and the
  HDR toggle.

**Adaptive rule:** render a chip only when it has content/support — no audio
tracks → omit Audio; `supportsVideoGravity == false && supportsHDRToggle == false`
→ omit Aspect; empty `qualityOptions` → omit Quality. (Today they appear empty.)

## 8. Stop / Disconnect / Choose TV (top-right `•••` menu)

- **Choose a different TV** — re-presents the target picker.
- **Stop playback** — `controller.send(.stop)`.
- **Disconnect** (`role: .destructive`) — `controller.disconnect()` + `dismiss()`.

The chevron-down is *minimize only*. This removes `Stop` from the controls row
and gives the destructive actions a deliberate, conventional home. The
`SiloCastControlModeButton` menu (Remote Control / Choose TV / Turn Off) is kept
as the entry point from Home.

## 9. States

- **Connecting** (`state == nil`, no error): artwork-placeholder skeleton +
  "Connecting to {TV}…" + spinner — not a bare centered `ProgressView`.
- **Loading / buffering** (`isLoading` / `isBuffering`): spinner replaces the
  play/pause glyph; scrubber disabled if `duration <= 0`.
- **Error** (`state.error ?? controller.errorMessage`): compact inline banner on
  `siloSurfaceElevated` with `siloError` text, not raw red caption.

## 10. Target picker (`SiloCastTargetPickerView`)

- **Found TVs**: keep the clean `List` of rows (glyph + name + server name +
  trailing spinner while connecting). Restyle rows to the token system.
- **Searching** (`found.isEmpty`, within ~8s of `browser.start()`): centered
  "Searching for Silo TVs…" + `ProgressView` — the AirPlay-style state.
- **Empty** (`found.isEmpty`, after the timeout): the existing
  `ContentUnavailableView("No Silo TVs Found", …)`.
- Implemented with a `@State` "searching" flag flipped by a `.task` timeout; no
  change to `SiloCastBrowser`.

## 11. Control-mode button (`SiloCastControlModeButton`, Home top bar)

Keep the `airplayvideo`-in-a-circle. Replace the ad-hoc `Color.white`/`.clear`
fills with the chrome tokens (`siloChromeSelectedFill` /
`siloChromeRestingFill`, `siloOutline` border). Active/connected state
reads clearly (filled + subtle connected indicator). Behavior (menu vs. picker)
is unchanged.

## 12. Accessibility & motion

- Every control keeps/gains an `accessibilityLabel` (transport, scrubber, each
  menu, minimize, overflow). Icon-only buttons must not be unlabeled.
- Respect **Reduce Motion** for any added transitions (artwork cross-fade, sheet
  presentation) — fall back to no animation, consistent with the tvOS detail work.
- Maintain contrast: foreground text/controls sit on the dimming scrim, not raw
  artwork.

## 13. Files touched

- `iosApp/iosApp/Cast/iOS/SiloCastViews.swift` — the bulk (remote screen, picker,
  control-mode button). May be split into focused files
  (`SiloCastRemoteControlView.swift`, `SiloCastTargetPickerView.swift`,
  `SiloCastControlModeButton.swift`) plus a small artwork resolver — at the
  implementer's discretion. **If files are added, regenerate with
  `cd iosApp && xcodegen generate`.**
- `iosApp/iosApp/Screens/Home/HomeView.swift` — only if the button restyle needs
  a call-site tweak (likely none).
- No other files. Verified build target: `SiloTV` is unaffected; iOS builds via
  scheme `Silo`.

## 14. Non-goals

- **No** new wire-protocol fields, message types, or version bump.
- **No** changes to `TVCastReceiver`, `PlayerViewModel` cast extensions,
  `SiloCastController`, `SiloCastSession`, or `SiloCastBrowser` logic (only the
  picker's view adds a local "searching" flag).
- **No** server or Android changes — this is purely the iOS presentation layer.
- **No** new playback capabilities beyond what the protocol already exposes.

## 15. Success criteria

- The remote reads as a native now-playing screen: artwork-forward, layered,
  with a single clean control row — no row of bordered buttons, no stray Stop.
- Artwork appears (instantly when cast from a detail page) with no protocol change.
- The picker shows "Searching…" before "No TVs," never the failure card on open.
- iOS builds clean (`xcodebuild build -project Silo.xcodeproj -scheme Silo
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' CODE_SIGNING_ALLOWED=NO`).
- tvOS is byte-for-byte unaffected.
