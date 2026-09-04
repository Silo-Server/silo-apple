# Implementation prompt — Skyline Phase 2: focus marquee (tvOS)

> **Status:** Phase 1 (chrome) is **complete** on `feature/skyline-phase-1`
> (type-derived tabs · pill row · Libraries/For You roots removed · profile
> dropdown · `SiloTheme.Skyline` tokens). This prompt targets **Phase 2 —
> the focus marquee** from guide Rev 2. Write the Phase 3 (cascading selector)
> and Phase 4 (polish & parity) prompts after this phase merges.

Copy everything below the line into a fresh Claude Code session at the root of
`silo-apple`. An Android adaptation note is at the end.

---

Implement **Phase 2 of the Skyline navigation redesign** for the tvOS app: the
**focus marquee** replaces the Featured hero carousel on TV surfaces.

## Read these first, in order

1. `docs/skyline-design-guide.md` — the approved spec (Rev 2). Source of truth
   for IA, tokens, components, focus model, and the tvOS file mapping (§10).
   For this phase read §5.4/§5.5 (marquee), §4.2 (motion), §5.7 (row rhythm),
   §6.1/§6.2 (screens), §7 (focus model), §9 (marquee payloads). Where this
   prompt and the guide conflict, the guide wins.
2. The rendered mockups `docs/tvos-redesign-mockups/shots/a4-skyline-home-marquee.png`
   and `a5-skyline-movies-marquee.png` — the visual target. (`a6` is the
   Phase 3 cascade; context only, do not build it.)
3. The Phase 1 result before changing it:
   `iosApp/iosApp/tvOS/Navigation/TVMainTabView.swift`,
   `iosApp/iosApp/tvOS/Navigation/TVTopMenuBar.swift`,
   `iosApp/iosApp/tvOS/Screens/Libraries/TVLibraryTypeTabView.swift`,
   `iosApp/iosApp/tvOS/Screens/Libraries/TVLibraryPillRow.swift`,
   `iosApp/iosApp/tvOS/Screens/Libraries/TVLibraryFeaturedView.swift`,
   `iosApp/iosApp/Screens/Home/HomeView.swift`,
   `iosApp/iosApp/Screens/Home/FeaturedCarousel.swift`,
   `iosApp/iosApp/tvOS/Components/TVRootHeroBackdrop.swift`,
   `iosApp/iosApp/Theme/SiloTheme.swift` (the `Skyline` namespace).

## What Phase 1 already built (do not redo)

- **Type-derived tabs**: `TVMainTabView`/`TVRootDestination` carry per-type
  cases from visible libraries; `TVLibrariesTabView` and the full-screen picker
  are gone. Multi-library types scope to the first library with a
  `// Skyline Phase 2: scope dropdown` marker — that marker is now **Phase 3**;
  update the comments but do not build the dropdown.
- **Pill row**: `TVLibraryPillRow` (press-to-commit) with per-pill content:
  `TVLibraryFeaturedView` (Featured = carousel + section rows),
  `TVLibraryCollectionsView`, `TVLibraryGenresView`, `TVLibraryGridView` for
  A–Z/Recently Added. `TVLibraryLandingView` and `TVLibraryModeSlider` are
  deleted.
- **Home**: For You rows folded in after Continue Watching; the Featured
  carousel still renders at the top — replacing it is this phase.
- **Profile dropdown** rows (Watchlist/Favorites/History/Settings/…) and the
  §5.1–§5.2 chrome metrics/states.

## Phase 2 scope (and nothing more)

1. **`TVFocusMarquee` component** (new, tvOS-only) per guide §5.4/§5.5: two
   scales — Home (block top 218, title 84, eyebrow 17) and library (top 246,
   title 66, eyebrow 16). Eyebrow = the **source row's title**, preceded by the
   `marquee.tick` dash (white @ 85%, 26×3, r 2 — add to `SiloTheme.Skyline`).
   Meta line: codec/HDR badges, then year·genre·runtime, or
   `S2 E7 · episode title · 23 min left` for episodic items. 2-line synopsis,
   max-width 780 (clamp to 1 line if the title wraps to 2). Title falls back to
   text immediately; cached server logo art (capped 880×200) may swap in
   without blocking. **Passive**: never focusable, no buttons.
2. **Focused-item plumbing.** Rows publish `(item, rowTitle)` on card focus
   (preference-key or `@FocusState` observation — follow the existing hand-down
   token pattern rather than inventing new machinery). The marquee updates
   after focus rests **150 ms** (guide §4.2): text + backdrop crossfade 240 ms;
   scrubbing through a row must not thrash. While focus is in chrome (bar,
   pills, dropdown) the marquee **retains** the last item, undimmed.
3. **Backdrop follows focus.** Extend `TVRootHeroBackdrop` to track the
   published focused item instead of a carousel index, same scrim stack. It
   also backs Calendar and Recommendations — keep those call sites working
   unchanged.
4. **Home (tvOS only).** Remove the `FeaturedCarousel` from the tvOS rendering
   of `HomeView` and mount the marquee; entry focus → **first Continue
   Watching card**; up from row 1 → top bar. Delete the now-dead tvOS hero
   focus targets (`HomeFocusTarget.featured` / `noFeaturedTopSpacer` paths) and
   simplify the hero-height mirroring. **`HomeView` and `FeaturedCarousel` are
   shared sources compiled for iOS/macOS — gate every change so iOS/macOS
   render exactly as today; do not delete `FeaturedCarousel.swift`.**
5. **Library Browse landing.** In `TVLibraryFeaturedView`: drop the carousel,
   mount the library-scale marquee, make row 1 an **items** row (dense
   208×312 posters; collections row follows it per §6.2). Row rhythm: library
   rows at ~510/~910; Home at ~545/~884 (§5.7). Entry focus → first card of
   row 1; up → pill row.
6. **Rename `Featured` → `Browse`** (guide Rev 2): the `TVLibraryPill` case,
   its label, and the per-type pill sets (`Browse · Collections · Genres ·
   A–Z · Recently Added`; Music/Audiobooks variants per §3). Pill selection is
   session-only state, so no persistence migration. Rename
   `TVLibraryFeaturedView` → `TVLibraryBrowseView` and regenerate the project.
7. **Prefetch sanity.** `StartupContentPrefetcher` warms featured-hero images;
   point the tvOS path at first-row items + their backdrops instead so the
   marquee is warm on cold start.

Marquee data comes from **section-item models only** (guide §9): render
whatever synopsis/badge/runtime fields the payloads already carry, omit what's
missing without blocking on a detail fetch, and report any gaps you find in
the models so we can take them to the server team.

Out of scope: the cascading selector / scope dropdown and `All <Type>` merged
queries (Phase 3), single-library sections panel (Phase 3), collection fan
cards and Android Calendar (Phase 4), first-run hints (none exist in Rev 2),
any server changes, any iOS/macOS behavior changes.

## Repo constraints

- After any target/file-layout change: `cd iosApp && xcodegen generate`. Never
  hand-edit `Silo.xcodeproj`. Never touch signing.
- Platform code stays under `iosApp/iosApp/tvOS/`; shared screens (Home,
  Search, Calendar, Recommendations) are also compiled for iOS/macOS — guard
  tvOS-only changes and keep the other platforms building unchanged.
- Match existing style: types `PascalCase`, the `TV` prefix for tvOS views,
  tokens from `SiloTheme` / `Colors.swift` — no hardcoded values, add new
  tokens to the theme (`SiloTheme.Skyline` exists from Phase 1). No new
  dependencies. No tests for this UI work unless shared logic changes (per
  `CLAUDE.md`).
- Branch `feature/skyline-phase-2` stacked on `feature/skyline-phase-1` (or on
  `main` once Phase 1 has merged). Commit in reviewable increments (marquee
  component → focus plumbing/backdrop → Home swap → Browse landing swap →
  rename), not one mega-commit.

## Focus & navigation requirements (treat as acceptance criteria)

The codebase already encodes several tvOS lessons — preserve them:

- **Keep the single shared `NavigationStack`** at the root with
  `navigationDestination(for: Route.self)`. Do not nest stacks per tab, do not
  mix in `NavigationLink(destination:)`, and register each destination type
  once. Tab switches swap content under the stack; they are not pushes.
- **The top menu is custom on purpose** (the system `TabView` sidebar steals
  leftward focus). Keep the custom bar; keep `.focusEffectDisabled()` +
  chrome driven by focus state (`SiloFlatButtonStyle` pattern) rather
  than the system halo.
- **The marquee never participates in focus.** No focusable subviews, no
  `focusSection` membership; the vertical zone model becomes top bar → pill
  row (library tabs) → content rows. Up from row 1 must reach the pills
  (library) or the bar (Home) in one press — the marquee is not a stop.
- **Press-to-commit everywhere.** Moving focus across tabs or pills must never
  change content. Card focus changing the *marquee* is the one intended
  focus-driven effect — content rows themselves never swap on focus.
- **Stable identity around focus.** Never remove or rebuild the view that owns
  focus in the same transaction that moves focus: marquee updates are
  display-only crossfades and must not invalidate row identity; keep row item
  identity stable (`.id` on content ids) so focus memory survives refreshes.
  Debounce means: cancel the pending update task on every focus move, schedule
  at +150 ms (`Task.sleep` pattern), animate 240 ms.
- **Back/Menu chain** unchanged: content → top bar (`onExitCommand` at the
  content zone) → non-Home tab selects Home → Home exits to the system. Never
  trap focus; every conditional view change defines where focus goes next.
- **Layout-safe focus growth:** cards scale 1.05 via `scaleEffect` (transform,
  not frame); rows keep enough vertical padding that scaled cards aren't
  clipped, `zIndex` raised on the focused card.
- **Accessibility:** marquee exposed as a polite (non-interrupting) live
  region describing the focused item; tabs keep their VoiceOver labels.
  Respect Reduce Motion: marquee and backdrop updates snap instead of
  crossfading; no drift animations.

## Verification before you call it done

1. `cd iosApp && xcodegen generate`
2. Build all three:
   - `xcodebuild build -project Silo.xcodeproj -scheme SiloTV -destination 'platform=tvOS Simulator,name=Apple TV' CODE_SIGNING_ALLOWED=NO`
   - same for scheme `Silo` (iPhone 17 Pro sim) and `SiloMac` (`platform=macOS`)
3. Run the tvOS simulator and walk the focus map with the remote/arrow keys:
   - cold start → Home, focus on the **first Continue Watching card**, marquee
     previewing it (eyebrow `CONTINUE WATCHING`), no carousel/dots/buttons
   - scrub quickly across the row → marquee/backdrop update only after focus
     rests; no intermediate flashes
   - up → bar (marquee retains the last item), across all tabs (content must
     not change), press Movies → landing with `Browse` pill selected, focus on
     first poster, marquee mirrors it; row 1 is an items row
   - pills: right → `Collections`, press → collections grid (no marquee on
     grid pills, per §6.4)
   - Menu from content → bar; Menu on Movies → Home; Menu on Home → exits
   - Reduce Motion on → marquee snaps, no crossfade
4. Confirm iOS (`Silo` scheme) Home/Browse still show the Featured carousel
   exactly as before — screenshot-compare if in doubt.
5. Confirm Top Shelf deep links and `continuum://` routes still resolve.
6. Report results honestly, including anything you could not verify in the
   simulator, and list any synopsis/badge fields missing from section models
   (for the §9 server audit).

If a real device pass is wanted afterwards, the `tvos-deploy-and-log` skill
deploys to the physical Apple TV — ask before using it.

---

## Adapting this prompt for `silo-android` (androidTvApp)

Swap the read-first list for `TvAppNavigation.kt`, `TvMainShell.kt`,
`TvTopMenuBar.kt`, `TvHomeScreen.kt`, `TvLibraryDetailScreen.kt`, theme files
in `ui/theme/`; swap the file mapping for the Android column of guide §10.
Note Android has **not** shipped Phase 1 yet — run the chrome phase there
first (type tabs, pill row, roots removed), then this marquee phase.
Constraints become: Compose + `androidx.tv.material3` only (no Leanback),
tokens in `Color.kt`/`Spacing.kt`/`Type.kt`, dp = guide px ÷ 2, keep the 0.86
font scale. The marquee is the standard immersive-list pattern:
`Modifier.onFocusChanged` on cards feeds a state holder; debounce with a
`LaunchedEffect` + `delay(150)`; `Crossfade`/`AnimatedContent` (240 ms) for
text and backdrop; `focusRequester` + `focusProperties { up/down }` +
`focusRestorer` keep the zone model. Verify with
`./gradlew :androidTvApp:assembleDebug`. The Calendar tab remains Phase 4
parity work.
