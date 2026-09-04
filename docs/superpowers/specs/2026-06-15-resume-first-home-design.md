# Resume-First Home — Design Spec

**Date:** 2026-06-15
**Status:** Approved (pending implementation plan)
**Scope:** iPhone, iPad, macOS (all non-tvOS clients). tvOS is unchanged.

## Summary

Remove the featured **card carousel** (`FeaturedCarousel`) from the iOS/iPadOS/macOS
clients and render the home and library-recommended screens as plain, resume-first
section rows led by Continue Watching. This brings the touch/desktop clients in line
with the philosophy already shipped on tvOS Skyline ("no curated hero competes for the
user's attention"), adapted for touch — there is no focus marquee equivalent on a phone,
so the result is simply rows with no hero on top.

The change is mostly **subtraction**: the clients already filter the server's `featured`
section out of their row lists, and the carousel is the only thing that renders it. So
"stop special-casing `featured`" plus "delete the now-unused carousel" is the bulk of the
work.

## Background & Motivation

- tvOS removed its featured carousel during the Skyline redesign (see
  `docs/skyline-design-guide.md`, §1, §3.3, §5.4). The rationale: the curated hero was its
  own focus stop with action buttons and auto-advance, interrupting the path to the rows
  users actually browse. Skyline replaced it with a passive focus marquee that previews
  whatever card the user points at.
- The iOS/iPadOS/macOS clients still render `FeaturedCarousel`: an 8-second auto-advancing,
  3-card deck hero (`iosApp/iosApp/Screens/Home/FeaturedCarousel.swift`, ~1,600 lines).
- Silo is a self-hosted, **library-centric** product. Unlike a commercial service, it has
  no marketing imperative to push a curated billboard. Competitor research (see "Research"
  below) shows the closest analog — Plex — deliberately ships **no** home hero and leads
  with Continue Watching. For a returning user of their own library, "get me back into what
  I was watching" outranks "show me a marketing hero."

### Design decision

Of three resume-first directions explored visually (A: no hero / pure resume; B: a
full-bleed "resume hero" showing the top in-progress title; C: a compact inset spotlight),
the chosen direction is **A — no hero, pure resume**. Continue Watching is the first thing
on screen. The server's `featured` content is **dropped** from the touch/desktop clients
entirely (matching tvOS), not demoted to a row or used as a fallback.

## Research (condensed)

Phone home-screen "featured" treatments across the industry group into four patterns:

1. **Full-bleed rotating hero** (Prime, Disney+, Apple TV, Hulu) — the mainstream default;
   on a phone its documented weaknesses are burying Continue Watching below the fold and
   auto-rotation fighting the user's thumb.
2. **Single editorial spotlight** (Netflix) — one confident pick with artwork-derived color
   theming.
3. **No hero / resume-first** (Plex) — opens straight into Continue Watching. The closest
   analog to Silo (self-hosted, library-centric).
4. **Feed-first / vertical video** (YouTube, Spotify, "Clips") — engagement play, not our lane.

Cross-cutting 2025–26 trends: full-bleed art under transparent chrome; UI color sampled
from artwork. Silo's tvOS Skyline already samples a backdrop tint, so the DNA exists — but
on touch there is no focused card to source an ambient backdrop from, which is part of why
direction A (flat background) is the honest fit.

## Detailed Design

### Home screen (`HomeView`, non-tvOS path)

- **Top bar:** unchanged. The existing floating header — profile avatar · "Home" title ·
  `TabTopBarActions` (search / switch profile / switch server / sign out) — stays, including
  its scroll-driven glass chrome fade (`homeHeaderChrome` / `headerChromeOpacity`).
- **Content:** a vertical `ScrollView` + `LazyVStack` of `SectionRow`s built from
  `viewModel.regularSections` (already excludes `featured`), rendered in **server order**.
  The first row is Continue Watching when the server returns it.
- **Top runway:** today the `noFeaturedTopSpacer` (`Color.clear` of height
  `noFeaturedTopSpacing(...)`) is rendered only in the no-featured branch to keep row 1 from
  sliding under the floating header. With the hero permanently gone, this spacer becomes the
  **permanent** first element of the stack.
- **Background:** **flat OLED** (`Color.siloBackground` / `.siloBackground()`).
  Remove the page-level ambient hero machinery that exists only to back the carousel:
  `heroTintBackground`, `heroBackdropImage`, `heroBackdropFadeMask`, `heroTintColor`,
  `heroBackdropURL`, `heroBackdropThumbhash`, `computedHeroHeight`,
  `heroBackdropFadeExtension`, `heroBackdropHorizontalBleed`, and the carousel's
  `onBackdropTintChange` / `onBackdropArtworkChange` callbacks.
  - *Rejected alternative:* re-source a subtle top tint from the first Continue Watching
    item's artwork. Keeps a hint of Skyline warmth but adds sampling code and a
    background that shifts with the resume row. Not worth it for this pass.
- **Empty state:** when the server returns zero non-empty sections **and** the view is not
  loading and has no error, show an `EmptyStateView` (the component already used by
  `LibraryRecommendedView`) instead of today's blank `Color.clear`. Do **not** show it during
  the initial load (`viewModel.isLoading`) to avoid a flash before cached/fetched rows paint.

### Library "Recommended" screen (`LibraryRecommendedView` in `Screens/Browse/BrowseView.swift`)

- Remove the `FeaturedCarousel` branch from `content`; render `viewModel.regularSections`
  rows directly.
- Remove `LibraryRecommendedViewModel.featuredSection`.
- Simplify the hero-bleed special-casing: the `.ignoresSafeArea(.container, edges:
  (extendsBackdropToTop && viewModel.featuredSection != nil) ? .top : [])` condition is now
  always `[]`. Drop the `extendsBackdropToTop` hero-bleed path and any hero-specific top
  insets (`libraryHeroTopInset`, hero-tuned `refreshStatusTopPadding`) so the first row sits
  normally beneath the Libraries tab's two-tier chrome. **This is the one spot that needs
  layout verification rather than pure deletion** — confirm the first row is not clipped by,
  nor gapped from, the library switcher + tab chips after the hero is gone.
- The existing `EmptyStateView` ("No recommendations yet") is retained.

### Startup prefetch (`StartupContentPrefetcher`)

- The non-tvOS (`#else`) branch currently warms the featured item's backdrop + logo
  (lines ~135–138) before warming the rest. With no hero, that is pointless.
- Replace it to warm the **first content row's** art (logo + backdrops/posters), which is
  exactly what the existing tvOS branch already does. Because the two branches become
  identical, collapse the `#if os(tvOS) / #else / #endif` into a single shared path.

### Deletions

- **Delete** `iosApp/iosApp/Screens/Home/FeaturedCarousel.swift` (~1,600 lines). Confirmed
  used only by `HomeView` and `LibraryRecommendedView`; no tests or other platforms
  reference it. Remove the stale doc comment in `HomeView` that references
  `FeaturedCarousel.preferredHeroHeight`.
- **Delete** `HomeViewModel.featuredSection` and `LibraryRecommendedViewModel.featuredSection`.
  `regularSections` is unchanged (it already excludes `featured`).
- Remove now-dead Home helpers: `navigateToPlayer(_:)` (the hero's play action — verify no
  other caller; if it was the only user of the `audioStore` environment in this view, drop
  that too) and the `HomeFocusTarget.featured` case. Keep the top-spacer and `.row` cases
  (rename `.noFeaturedTopSpacer` → `.topSpacer` for clarity).
- After deleting the file, run `cd iosApp && xcodegen generate` so the project drops the
  source reference.

## Scope

- **In scope:** iPhone, iPad, macOS — every `#if !os(tvOS)` code path in the files above.
  All changes live in non-tvOS branches or shared view models, so tvOS behavior is preserved.
- **Out of scope:** tvOS (already done); the Android client (separate repo — see below);
  any server change; redesign of `SectionRow`, the top bar, or navigation.

## Coordination

- **Server (`silo-server`):** no change required. The server may keep sending the `featured`
  section; clients ignore it, exactly as noted in `docs/skyline-design-guide.md` §9. **One
  thing to confirm:** the non-tvOS `/api/v1/home/sections` payload should order Continue
  Watching first, because the client now renders server order verbatim with no client-side
  reordering. (tvOS already relies on this ordering.)
- **Android (`silo-android`):** the Android **phone** client likely still renders a featured
  carousel. For cross-client parity it should adopt the same resume-first home. Tracked as a
  follow-up in that repo; not addressed here.

## Testing

Per `CLAUDE.md`, avoid tests for UI-only and small changes. This change is predominantly
removal. Optional, low-cost coverage if desired:

- A `HomeViewModel` test asserting `regularSections` preserves server order and filters
  empty/`featured` sections.
- A view-model-level assertion that the empty state is reported only when not loading and
  with no error.

Manual verification: build and run iOS (`Silo` scheme), iPad, and macOS (`SiloMac` scheme);
confirm Home and a library's Recommended tab lead with Continue Watching, no hero, no
clipping under the header/chrome, and a graceful empty state on a server with no content.

## Non-Goals / Future

- No "resume hero" or compact spotlight (directions B/C were considered and rejected).
- No ambient artwork tint on the touch/desktop home (rejected alternative above).
- No new home personalization, "Top 10," or vertical-feed surfaces.

## Affected Files (reference)

- `iosApp/iosApp/Screens/Home/HomeView.swift` — remove hero machinery + carousel branch;
  flat background; permanent top spacer; empty state; helper cleanup.
- `iosApp/iosApp/Screens/Home/HomeViewModel.swift` — remove `featuredSection`.
- `iosApp/iosApp/Screens/Browse/BrowseView.swift` (`LibraryRecommendedView` +
  `LibraryRecommendedViewModel`) — remove carousel + `featuredSection`; simplify hero-bleed
  insets.
- `iosApp/iosApp/Startup/StartupContentPrefetcher.swift` — warm first row instead of
  featured; collapse the platform branch.
- `iosApp/iosApp/Screens/Home/FeaturedCarousel.swift` — **delete**.
- `iosApp/project.yml` — regenerate via `xcodegen generate` after the deletion.
