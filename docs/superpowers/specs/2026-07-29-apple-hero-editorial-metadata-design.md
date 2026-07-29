# Apple Hero Editorial Metadata Design

**Date:** 2026-07-29
**Status:** Approved
**Repository:** `silo-apple`
**Clients:** iOS, tvOS, and macOS

## Goal

Make Apple-client heroes describe the title rather than the selected file.
Preserve the intentionally hero-free iOS Home design, remove hard-coded
technical tokens from detail heroes, simplify the tvOS marquee, and keep cast
in dedicated cast sections.

## Product contract

Movie and series browse heroes use this priority:

1. Year
2. Runtime
3. IMDb rating
4. One or two genres
5. Content rating

Episode browse heroes use:

1. Season and episode identity
2. Runtime
3. Content rating when useful

Detail heroes use:

- Movies and episodes: year or air date, runtime, IMDb rating, one or two
  genres, and content rating
- Series: year, season count, IMDb rating, one or two genres, and content
  rating

Hard-coded technical metadata does not appear in Home marquees or detail
facts:

- Resolution or 4K
- HDR or Dolby Vision
- Audio codec, layout, or Atmos
- Subtitle or CC availability

Cast names do not appear as hero overlays. Cast remains available in the
dedicated cast rails.

## Scope decisions

- iOS Home remains hero-free and its current feed cards remain unchanged.
- The non-tvOS detail implementation is shared by iOS and macOS, so both adopt
  the editorial-only detail facts.
- The tvOS focus marquee is shared by Home and library Browse; both adopt the
  same editorial policy.
- Configurable/admin-controlled card or artwork overlays are separate from the
  hard-coded hero facts and remain unchanged.
- Playback/version selectors and technical detail formatters remain unchanged.
- No networking model, API, or server change is required.

## Architecture

### iOS Home

`HomeView` continues to render feed rows without a hero. `HomeFeedRow`,
`HomeFeedKit`, and their selective row/card badge policy are not redesigned.
The recent card treatment intentionally uses technical badges only where they
differentiate items in a row; this design does not remove that configurable
card-level information.

### iOS and macOS detail

`PhoneHeroMetadata` remains the pure metadata builder for the shared non-tvOS
detail surface. Its movie/episode facts retain air date or year, runtime, and
valid IMDb rating. Series facts retain year, season count, and valid IMDb
rating.

The builder stops appending resolution, HDR/Dolby Vision, audio, and CC
tokens. Its selected-version argument is removed if it has no remaining
editorial purpose. `MovieDetailContent` is updated accordingly.

Content rating and genres remain in their current source/facts locations, with
blank values omitted. Existing configurable backdrop overlays supplied by
`OverlayData.from(detail)` remain available because they are user/admin
presentation choices rather than hard-coded facts.

Generic `.chip` rendering may remain if another caller needs it. Hero-only
quality resolution helpers and selected-version coupling are removed.

### tvOS Home and library Browse marquee

`TVMarqueeContent` keeps title/logo, synopsis, artwork, year, runtime,
IMDb rating, episode identity/title, progress-derived time remaining, and
content rating.

It stops deriving resolution, HDR/Dolby Vision, and audio badges from
`OverlaySummary`. Content rating remains a classification badge. Movie and
series editorial metadata is ordered year, runtime, IMDb, then up to two
genres. Episode metadata keeps season/episode identity, episode title,
runtime, and time remaining without adding duplicate series genres.

`TVMarqueeEnrichment` retains air-date formatting and detail-level backdrop
data. It stops appending cast names. The enrichment fetch and model lifecycle
remain because episodes depend on the enriched series backdrop and thumbhash;
removing cast must not regress episode artwork quality.

The poster/thumbnail overlay system used by tvOS rows remains unchanged.

### tvOS detail

`TVHeroMetadata.movieFactsLine` and `seriesFactsLine` stop appending technical
quality tokens. Selected-version parameters are removed when no editorial
facts depend on them.

`TVDetailHero` removes the right-aligned `starringText` input and
`starringOverlay`. Movie, series, and season detail call sites stop supplying
starring text. `TVHeroMetadata.starringText` and hero-only quality helpers are
deleted.

Dedicated movie, series, and season cast rails remain. `TVPlaybackSelectorRow`,
`PhonePlaybackSelectorRow`, `DetailPlaybackFormatting`,
`DetailVersionSelection`, and playback screens remain unchanged.

## Validation and fallback rules

- Runtime values must be positive; unavailable runtime is omitted.
- IMDb ratings must be finite, greater than zero, and no greater than ten.
- Genres and content ratings are trimmed; blank values are omitted; genres
  are first-seen deduplicated and capped according to the surface.
- No `Unknown`, zero, blank chip, or empty separator is rendered.
- Metadata overflow continues using each native surface's existing truncation
  behavior.
- No additional detail fetch is introduced.
- No focus, navigation, playback, artwork, caching, or session semantics
  change.

## Expected files

iOS/macOS detail:

- `iosApp/iosApp/Screens/Detail/Phone/PhoneHeroMetadata.swift`
- `iosApp/iosApp/Screens/Detail/MovieDetailContent.swift`
- A focused metadata regression test under `iosApp/Tests/`

tvOS marquee:

- `iosApp/iosApp/tvOS/Components/TVFocusMarquee.swift`

tvOS detail:

- `iosApp/iosApp/tvOS/Screens/Detail/TVDetailHero.swift`
- `iosApp/iosApp/tvOS/Screens/Detail/TVMovieDetailView.swift`
- `iosApp/iosApp/tvOS/Screens/Detail/TVSeriesDetailView.swift`
- `iosApp/iosApp/tvOS/Screens/Detail/TVSeasonDetailView.swift`

`iosApp/project.yml` is not expected to change because the test target already
includes `Tests/**`.

## Test design

The iOS-hosted metadata tests use rich `ItemDetail` and `FileVersion` fixtures
to prove:

- Movie, episode, and series facts retain their editorial order
- Resolution, HDR/Dolby Vision, audio, and CC are absent
- Content rating and genre normalization remains correct
- Invalid ratings and runtimes are omitted
- Playback/version formatting still exposes technical information outside the
  hero

tvOS-only metadata helpers currently compile only into the tvOS target, and
the repository has no tvOS unit-test target. Adding a new target is
disproportionate to this presentation change. tvOS verification therefore
uses:

- iOS-hosted tests for any platform-neutral formatter extracted during
  implementation
- Unsigned tvOS compilation
- Simulator visual checks for Home, library Browse, movie detail, episode
  detail, series detail, and season detail
- Explicit confirmation that enriched episode backdrops still load

Final verification includes iOS tests, unsigned iOS/tvOS/macOS builds, and
visual smoke checks on one phone-size surface and one TV-size surface. No
physical-device installation is part of this work.

## Non-goals

- Adding an iOS Home hero
- Removing configurable card/backdrop overlays
- Removing technical information from selectors, playback, or file details
- Removing dedicated cast sections
- Server, API, schema, or networking changes
- Adding a tvOS unit-test target solely for this cleanup
- Changing focus, navigation, artwork caching, or playback behavior
