# Skyline Design Guide

**Silo TV client navigation redesign — tvOS & Android TV**

Status: approved direction (chosen over "Rail" and "Stage" candidates)
Rev 2 (2026-06-12): the Featured hero carousel is removed in favor of the
**focus marquee** (`a4`/`a5`), and the scope dropdown becomes a focus-opened
**cascading switcher** with a sections flyout (`a6`). The first pill is renamed
`Featured` → `Browse` to match.
Rev 3 (2026-06-12): the **`All <Type>` merged scope is removed** (user decision).
Multi-library types are always scoped to exactly one library; the cascading
selector (§5.3) is how the user picks/switches which library — there is no
merged view. References to `All <Type>` below are superseded (see §3.1, §5.3, §9).
Mockups: `docs/tvos-redesign-mockups/` (`a1`–`a6` + rendered PNGs in `shots/`)
Scope: this guide covers the 10-foot clients only (tvOS + Android TV). Phone/tablet/macOS unchanged.

---

## 1. What Skyline is

Skyline replaces the current "Libraries is a place" model with **content-type-first
navigation**: each library type the user has is a top-level tab in a persistent,
slim top bar. The existing pain points are removed structurally, not patched:

| Today | Skyline |
|---|---|
| One "Libraries" tab → full-screen modal picker → library landing | Each library type **is** a tab: `Movies`, `Series`, `Music`, `Audiobooks` |
| Recommended ↔ Collections mode slider (stateful toggle, top-right corner) | Sub-destination **pill row** under the bar: `Browse · Collections · Genres · A–Z · Recently Added` — peer destinations, no hidden state |
| Multiple libraries of one type = more modal rows | Tab grows a focus-opened **cascading selector** (libraries → sections flyout) |
| Curated Featured carousel: its own focus stop, action buttons, auto-advance | Passive **focus marquee** — the top of the screen always previews the card the user is focused on |
| "For You" as separate tab | Folded into Home as rows (see §6.1) |

### Principles

1. **Content is the destination.** Users think "I want a movie," not "I want to enter my Movies library." Navigation labels are types, not server containers.
2. **No hidden modes.** Anything that changes what the grid shows is a visible, selectable destination (pill), never a sticky toggle.
3. **One press beats one modal.** Library scope changes happen in an anchored dropdown over the page, never a full-screen takeover.
4. **Keep the brand DNA.** OLED black, monochrome white-at-opacity, invert-to-white focus, existing radii and motion. Skyline changes chrome, not skin.
5. **The two platforms are one design.** Identical IA, components, and behavior; only focus-engine idioms differ.
6. **The top of the screen mirrors focus.** No curated hero competes for presses; the marquee previews whatever the user is pointing at, and chrome reveals itself on focus (cascade), not behind gestures.

---

## 2. Units & cross-platform scaling

All dimensions in this guide are **mockup pixels at 1920×1080**, which map:

| Platform | Rule | Example (tab height 64) |
|---|---|---|
| tvOS (SwiftUI) | 1 px = **1 pt** (tvOS renders at 1920×1080 pt) | 64 pt |
| Android TV (Compose) | 1 px = **0.5 dp** (1080p TV ≈ xhdpi → 960×540 dp window) | 32 dp |

Sanity check against existing code: tvOS poster `260×390 pt` ≡ Android `130×195 dp`
(already true in `SiloTheme.swift` / `Spacing.kt`), so existing token files
already follow this rule. Android text sizes below assume the TV app's global
0.86 font-scale stays in place — give Compose the sp values listed, not px/2 of type.

---

## 3. Information architecture

```
TOP BAR (persistent on all root screens)
├─ SILO wordmark                            (left, non-interactive)
├─ Tabs (center):
│   Home
│   Movies        ── cascading selector on focus (§5.3)
│   Series        ── cascading selector on focus (§5.3)
│   Music         ── only if a music library exists
│   Audiobooks    ── only if an audiobook library exists
│   Calendar
├─ Search (icon)                            (right)
└─ Profile avatar → anchored dropdown       (far right)
    Profiles · Watchlist · Favorites · History · Settings ·
    Admin Dashboard (admins) · Switch Server (Android) · Sign Out

LIBRARY TAB (Movies/Series/Music/Audiobooks) — sub-destination pills:
    Browse (default) · Collections · Genres · A–Z · Recently Added
    (Music: Browse · Artists · Albums · Playlists · Genres)
    (Audiobooks: Browse · Authors · Series · Collections · A–Z)

FULL-SCREEN (pushed over everything, no top bar):
    Item detail · Person · Collection detail · Player · Admin · Auth flow
```

### 3.1 Tab derivation rules

- Tabs represent **library types**, not libraries. Fixed order:
  `Home · Movies · Series · Music · Audiobooks · Calendar`. A type's tab appears
  only if the profile can see ≥1 library of that type.
- **Press** on a library tab always commits directly: one library of the type →
  that library's Browse landing; multiple → the current scope's Browse landing.
- **Focus-dwell** on a library tab opens its anchored selector (§5.3): with one
  library it is a single-level sections panel; with multiple it is the two-level
  cascade (each library, each cascading into its sections). The
  selected scope persists per tab, per profile, across launches.
- ~~`All <Type>` merged scope~~ **(removed, Rev 3)**: there is no merged view.
  A multi-library tab is always scoped to one library (the persisted choice, or
  the first by sort order on cold start); the user switches libraries via the
  cascade (§5.3).
- Tab cap: with every type present the bar holds 6 tabs + search + avatar, which
  fits 1920 with the specified paddings. We do not support arbitrary per-library
  tabs, so no overflow design is needed.

### 3.2 What is deleted

- The `Libraries` root tab, the full-screen library picker
  (tvOS `TVLibraryActionsModal` / Android `TvFullScreenPicker` use-for-libraries).
- The Recommended/Collections mode slider (tvOS `TVLibraryModeSlider`) and the
  `libraryMode` state it controls.
- The `For You` root tab on both platforms (content folds into Home).
- The Featured hero carousel on TV surfaces (`FeaturedCarousel` usage in tvOS
  Home and library landings — the component itself stays for iOS/iPadOS), along
  with its action buttons, position dots, and auto-advance.
- The long-press / second-press dropdown triggers and the `Hold to choose a
  library` first-run hint — superseded by the focus-dwell cascade (§5.3).

### 3.3 Where existing things go

| Existing | New home |
|---|---|
| Featured hero carousel (Home + library Recommended) | Focus marquee — passive, mirrors the focused card (§5.4/§5.5) |
| Hero `Play`/`More Info`/watchlist actions | Press the focused card → detail (or resume); long-press context menu; full actions live on detail |
| Library landing "Recommended" mode | Library tab → `Browse` pill (default) |
| Library landing "Collections" mode | Library tab → `Collections` pill, plus an inline "Collections" row on Browse |
| For You rows | Home rows, after Continue Watching |
| Watchlist / Favorites / History quick links | Profile dropdown (and stay in Settings) |
| Calendar tab | Unchanged position; Android TV must add the screen for parity |
| Search | Top bar icon → existing search screen |
| Settings | Profile dropdown → existing settings screen |

---

## 4. Design tokens

Unchanged from the current apps (`SiloTheme.swift`, `Color.kt`): background
`#000000`, surface `#0A0A0A`, elevated `#15171C`, primary text `#EDEDED`,
secondary = primary @ 60%, tertiary @ 38%, hairline white @ 12%, error `#B00020`,
rating amber `#FFC107`. Radii: 8 / 12 / 18 (+ pill = capsule). No chromatic accent.

New tokens introduced by Skyline (mockup px):

| Token | Value | Notes |
|---|---|---|
| `safeArea.x` | 88 | root horizontal inset (tvOS 88 pt / Android 44 dp) |
| `safeArea.top` | 56 | top bar offset |
| `glass.regular` | black @ 55% + blur 34 | shelves, dropdowns base |
| `glass.strong` | `#16171B` @ 86% + blur 40 | anchored dropdowns + flyout |
| `chrome.selected` | white @ 14% fill + white @ 10% inner border | selected-not-focused pills/tabs |
| `chrome.unfocused-bg` | white @ 7% | resting pills/chips |
| `scrim.dropdown` | black @ 55% + blur 26 | page behind any anchored dropdown |
| `marquee.tick` | white @ 85%, 26×3, r 2 | dash before the marquee eyebrow |

### 4.1 Type ramp

| Style | px (mock) | tvOS pt | Android sp | Weight / tracking |
|---|---|---|---|---|
| Wordmark | 26 | 26 | 13 | 800, +0.34 em, all-caps |
| Tab label | 23 | 23 | 12 | 600 |
| Sub-pill label | 19 | 19 | 10 | 600 |
| Marquee eyebrow | 17 (Home) / 16 (library) | 17 / 16 | 9 / 8 | 700, +0.30 em, caps, preceded by `marquee.tick` |
| Marquee title (Home) | 84 | 84 | 42 | 800, line 0.98, clamp 2 lines |
| Marquee title (library) | 66 | 66 | 33 | 800, line 1.02, clamp 2 lines |
| Marquee meta line | 20 (Home) / 19 (library) | 20 / 19 | 10 | 500, secondary |
| Synopsis | 22 / 1.45 | 22 | 11 | 400, 2-line clamp (1 line if title wraps), max-width 780 px |
| Button label | 23 | 23 | 12 | 700 |
| Row title | 30 | 30 | 15 | 700 |
| Row count suffix | 19 | 19 | 10 | 500, tertiary, +0.06 em |
| Card title (under thumb) | 20 | 20 | 10 | 600 |
| Card subtitle | 17 | 17 | 9 | 500, tertiary |
| Badge | 15 | 15 | 8 | 600, +0.08 em |
| Dropdown row | 22 | 22 | 11 | 600 |
| Dropdown section header | 14 mono | 14 (SF Mono) | 8 (mono) | 600, +0.26 em, caps, tertiary |
| Flyout section row | 20 | 20 | 10 | 600 |
| Flyout header | 13 mono | 13 (SF Mono) | 7 (mono) | 600, +0.26 em, caps, tertiary |

Use the platform system font (SF Pro / Roboto). The film-grain overlay in the
mockups is presentation-only — do not implement.

### 4.2 Motion

| Animation | Spec |
|---|---|
| Focus change (any element) | 120 ms ease-out (existing `fast`) |
| Tab content switch | 200 ms crossfade; outgoing content does not slide |
| Sub-pill content switch | 200 ms crossfade + 12 px upward drift of incoming content |
| Marquee update | text + backdrop crossfade 240 ms; fires after focus rests 150 ms (skipped while rolling through cards) |
| Cascade open/close | opens after 250 ms tab-focus dwell: 180 ms scale 0.96→1.0 + fade, anchored to the tab; scrim fades 150 ms |
| Sections flyout | 160 ms scale 0.97→1.0 + fade from the focused row; follows focus with the same 150 ms rest debounce |
| Focus scale | cards 1.05, pills/tabs none (they invert instead), spring response 0.35 damping 0.85 |

---

## 5. Components

### 5.1 Top bar

- Position: `safeArea.x` insets, top 56, height 64, single row, z-above content.
  Background: none (transparent over hero scrim). Never draws a band.
- Layout: wordmark (left) — tabs (true-center cluster, gap 8) — search icon
  button 52×52 — avatar 52×52 (right, gap 22).
- Scroll behavior: bar stays mounted on root screens; when the user moves focus
  down into content, bar opacity drops to 70% (200 ms) and restores on re-entry.
  It is never hidden entirely on root screens; it does not exist on pushed
  full-screen routes (detail/player).
- The avatar is a 52 px circle with the profile color/initial ("A" in mockups).

**Tab states** (capsule, padding 11 vert × 26 horiz):

| State | Treatment |
|---|---|
| Resting | label @ 62% white, no background |
| Selected (focus elsewhere) | `chrome.selected` capsule, label 100% white |
| Focused | **inverted**: white capsule, black label |
| Focused library tab, dwell elapsed | inverted capsule + cascade panel open below (§5.3); tab drops to `chrome.selected` when focus enters the panel |

Focus inversion is the platform-native grammar both apps already use — do not
add the mockups' outline ring; it is a static-image stand-in for focus.

### 5.2 Sub-destination pill row

- Position: full width at `safeArea.x`, top 150 (i.e., 30 px below the bar),
  single row, gap 12. Right-aligned scope caption (18 px, tertiary):
  `"1,284 films · updated 2h ago"`.
- Pills: capsule, padding 9×22, `chrome.unfocused-bg` + 1 px white @ 9% border,
  blur 16. Selected pill = solid white, black label (selected and focused share
  the inverted look here; when focus leaves the row the selected pill stays
  white — it is the page's "you are here").
- Per-type pill sets are fixed (see §3 map). `Browse` is always first and the
  landing default. Pills never scroll; sets are ≤5 items by design.
- Selection activates on **press**, not on focus hover (unlike the old slider —
  this prevents accidental mode flips while traversing).
- The pill set and the cascade flyout sections (§5.3) are the **same
  destinations**: the flyout teleports from the bar, the pills navigate on-page.

### 5.3 Cascading library selector (the a3/a6 mockups)

Replaces the long-press scope dropdown. One component, two levels.

- **Trigger:** the panel (plus `scrim.dropdown`) fades in after the tab has held
  focus for **250 ms** — no hold, no second press, no chevron suffix. Sweeping
  across the bar never opens it; resting on a tab does. Focus stays on the tab
  until **d-pad down** enters the panel; moving sideways to another tab closes
  it (the next tab opens its own after its dwell). Available on every library
  tab: single-library tabs get the single-level sections panel, multi-library
  tabs get the two-level cascade below.
- **Level 1 — libraries.** Panel width 460, radius 22, `glass.strong`, 14 px
  padding, anchored centered under the tab with a 20 px notch. Mono section
  header (`MOVIE LIBRARIES`), then one row per scope: icon 30 — name — count
  (right, tertiary) — trailing glyph: `✓` on the current scope, `›` on the
  others (everything cascades). **(Rev 3: no `All <Type>` row — Level 1 lists only real libraries.)** Rows: 22 px
  text, padding 16×18, radius 14; entering focus lands on the current scope
  row; the focused row inverts to white. Maximum height 6 rows then internal
  scroll. Footer hairline + caption: `Press opens the library · → jumps to a
  section · Menu closes`.
- **Level 2 — sections flyout.** While a library row is focused, its sections
  appear in a flyout anchored to the row's right: 18 px gap from the panel,
  width 300, radius 18, `glass.strong`, 10 px padding, left-edge notch at the
  row's level, top-aligned with the focused row. Mono header = library name;
  then one row per section (fixed per type, mirrors the pill set: `Browse ·
  Collections · Genres · A–Z · Recently Added`). Rows: 20 px/600, padding
  13×16, radius 12. The flyout follows focus up/down the library list (150 ms
  rest debounce) and never steals focus.
- **Focus & commit:** up/down rolls through libraries one press per row;
  **right** enters the flyout (first section), up/down moves within it,
  **left** returns to the library row. **Press on a library row** sets the
  tab's scope and opens that library's Browse landing. **Press on a flyout
  row** sets the scope and lands directly on that section (pill preselected).
  Either way the page swaps **in place** (200 ms crossfade; pills and scroll
  reset, marquee refetches). **Menu/Back** closes the whole selector from
  either level without changing anything.

### 5.4 Marquee — Home (full-bleed)

The marquee is a **passive billboard**: it is never focusable, has no buttons,
and always previews the item whose card is focused in the rows below.

- Backdrop: full-bleed artwork of the focused item with the standard scrim
  stack (top 42% → clear, floor to black from 46% down; vignette), crossfaded
  per §4.2. Extend the existing root-backdrop machinery (`TVRootHeroBackdrop`)
  to track focus instead of a carousel index.
- Content block at `safeArea.x`, top 218, width 880:
  eyebrow = **the source row's title** (`CONTINUE WATCHING`), preceded by the
  `marquee.tick` dash; title 84 px text (or cached server logo art capped at
  880×200 — never block the crossfade on a logo fetch; fall back to text);
  meta line (badges `4K · DOLBY VISION · ATMOS`, then year/genre/runtime — or
  `S2 E7 · episode title · 23 min left` for episodic items); 2-line synopsis.
- No actions, no carousel, no position dots. Pressing the focused card opens
  it (resume for continue-watching); long-press keeps the context menu.
- While focus is in chrome (top bar, pills, dropdowns) the marquee **retains**
  the last previewed item, undimmed. It is never empty once content loads;
  on entry it shows the default-focused first card.

### 5.5 Marquee — library landing (compact)

Library tabs use the same component at spotlight scale, between the pill row
and row 1: content block at top 246, eyebrow 16 px (source row name), title
66 px, meta 19 px, 2-line synopsis. Same passivity, retention, and crossfade
rules as §5.4. This keeps row 1 fully visible above the fold while still
giving every focused poster a glanceable summary — the user can skim a row
and read what each item is without entering detail pages.

### 5.6 Cards

| Card | Size (px) | Notes |
|---|---|---|
| Poster (default) | 260×390, r 12 | unchanged from today; title overlays only in mock — real cards keep artwork + existing overlay options |
| Poster (dense rows) | 208×312, r 12 | used on landing rows so two rows + marquee fit |
| Continue-watching thumb | 372×209 (16:9), r 12 | progress bar inset 14/12, h 5, white on white @ 26%; meta block below: title 20 + right-aligned `S2 · E7 · 23m left` 17 tertiary |
| Collection fan card | 430×234, r 16 | three 104×156 mini posters fanned (−8°, −1°, +7°) left cluster; right block: name 25/700, count 17 caps tertiary. Surface: vertical `#2E3036→#121316` @ ~90% + hairline |
| Focus (all cards) | scale 1.05 + 2 px white border + drop shadow | existing grammar; no outline ring |

### 5.7 Rows / shelves

- Row title 30/700 with optional count suffix; 20 px gap to content; card gap
  24; rows bleed off the right edge (no end padding) to signal scrolling.
- Vertical rhythm — Home: marquee → first row at ~545 → second row peeks at
  ~884. Library landings: marquee → first row at ~510 → second row peeks at
  ~910 (deliberate cut at the fold).
- Each row keeps per-row focus memory (`focusRestorer` / `prefersDefaultFocus`).

### 5.8 Profile dropdown

Same level-1 panel spec as §5.3, anchored under the avatar, right-aligned to
`safeArea.x`, and the same open behavior (250 ms focus dwell, or press). Rows:
current profile header (avatar + name + server host, mono), then `Switch
Profile`, `Watchlist`, `Favorites`, `History`, divider, `Settings`, `Admin
Dashboard` (admins), `Switch Server` (Android, multi-server), `Sign Out`.
No flyout level.

---

## 6. Screens

### 6.1 Home (`a1`, revised by `a4`)

Zones top→bottom: top bar · focus marquee (§5.4) · `Continue Watching` row
(thumb cards) · further rows below the fold: `For You` (recommendation rows
migrate here, keeping their server-provided titles), `Recently Added in
<Library>` per visible library, any server-pinned sections. Row order comes
from the existing home-sections endpoint; the client folds recommendations in
after Continue Watching. Removing the carousel's button row means the second
row now peeks above the fold.

Focus map: entry → first card of Continue Watching (marquee previews it
immediately). Up from row 1 → top bar (Home tab). The marquee is never a stop.

### 6.2 Library tab — Browse pill (`a2`, revised by `a5`)

Top bar (tab selected) · pill row (`Browse` selected) + scope caption ·
focus marquee (§5.5) · `New This Week` (dense posters) · `Collections` row
(fan cards, §5.6) peeking · further server section rows.

Row 1 should be an **items** row (not collections) so entry focus gives the
marquee something rich to preview; the Collections row follows. Entry focus →
first card of row 1. Up from row 1 → pill row; up again → top bar.

The Collections row appears on Browse **and** Collections is a pill — both
paths are intentional (glanceable subset inline; full catalog one press away).
The row shows up to 8 collections by item-count descending, with a trailing
`See All` card that jumps to the Collections pill. When a fan card is focused,
the marquee shows the collection's name, count, and a poster-derived backdrop.

### 6.3 Library tab — Collections pill

Grid of fan cards (§5.6), 3 columns × 430 width at gap 26 within safe area,
group headers when the server returns collection sections (e.g. `MY
COLLECTIONS`, mono header style). Pressing a card pushes collection detail
(existing screen).

### 6.4 Library tab — Genres / A–Z / Recently Added pills

- **Genres:** chip cloud (capsule chips, 19/600, white @ 7% bg) → picking one
  shows the standard grid filtered.
- **A–Z:** existing grid + right-edge alphabet rail (mono 15, current letter
  inverts to a white rounded chip), prefix jumping as today.
- **Recently Added:** standard grid, newest first.
- All grids reuse the existing library grid component (tvOS `TVLibraryGridView`,
  Android `TvCatalogGrid`) with the pill row remaining visible and focusable.
  Grid screens have no marquee — the grid owns the full height below the pills.

### 6.5 Music & Audiobooks tabs

Same skeleton, type-specific pills (§3). Music Browse rows: `Recently
Played`, `New Albums`, `Playlists`. Audiobooks Browse rows: `Continue
Listening` (thumb cards show chapter/time-left), `New Arrivals`, `Authors`.
Square (1:1, 234×234) artwork for albums/playlists; audiobooks keep square
tiles per the recent tvOS work. The marquee previews the focused album/book
(artist/author in the meta line; album art tints the backdrop).

### 6.6 Calendar

Content unchanged from the current tvOS Calendar (week strip + day shelves);
it simply adopts the Skyline top bar. **Android TV must build this screen for
parity** — the server endpoints already exist (used by tvOS today).

### 6.7 Search / Settings

Search keeps the existing screen, reached via the top-bar icon (and it remains
a focus stop in the bar). Settings is reached via the profile dropdown;
remove its `Library` quick-links section once the dropdown ships (redundant).

---

## 7. Focus & input model

Vertical focus zones on root screens, top to bottom:
**top bar → pill row (library tabs only) → content rows**. The marquee is
display-only and never participates in focus.

- **Up** from the first content row lands on the pill row (library tabs) or the
  top bar (Home/Calendar). Up from pills → top bar.
- **Entry focus** on any root screen: the first card of the first row; the
  marquee previews it immediately. Switching scope or pill resets content
  focus to the first item; returning to a root screen restores the last
  focused element.
- Moving focus across tabs does **not** switch content. **Press** selects a tab
  and moves focus into the new page's default target. Resting on a library tab
  for 250 ms opens its cascade (§5.3) without stealing focus; **down** enters
  it, sideways movement dismisses it.
- Inside the cascade: up/down rolls libraries (flyout follows), **right**
  enters the sections flyout, **left** backs out of it, press commits (library
  → Browse landing; section → that section), **Menu/Back** closes the selector
  without change.
- **Back/Menu** on a root screen: content focus → top bar; top bar non-Home tab
  → select Home; Home tab → system home screen (tvOS HIG) / background app
  (Android default).
- **Long-press on any card** keeps the existing context menu (watchlist,
  favorite, mark played).
- The marquee debounce (150 ms rest, §4.2) keeps rapid horizontal scrubbing
  through a row from thrashing backdrops; the card focus ring still moves at
  the standard 120 ms.

Platform idioms: tvOS implements zone bridging with `@FocusState` +
`focusSection`/`prefersDefaultFocus` (as `TVMainTabView` does today), and the
dwell timer via a focus-change `Task` with 250 ms sleep; Android uses
`focusRequester` + `focusProperties { up/down }` + `focusRestorer` (as
`TvTopMenuBar`/`TvMediaRow` do today) with the dwell in a `LaunchedEffect`.
The flyout is geometry-native in both focus engines (nearest target to the
right). No new focus machinery is required.

---

## 8. State & persistence rules

| State | Persistence |
|---|---|
| Selected tab | Session only; cold start always lands on Home |
| Library scope per tab | Persisted per profile (UserDefaults / DataStore) |
| Selected pill per tab | Session only; cold start → Browse |
| Row scroll/focus memory | In-memory per screen visit (existing behavior) |
| Marquee item | Derived from focus, never persisted; retains the last focused item while focus is in chrome |

Empty/loading: skeleton shimmer placeholders matching card geometry (existing
pattern); a library type with zero items still shows its tab if the library
exists, with the standard empty state under the pills. The marquee region
stays empty (backdrop scrim only) until the first row has content.

---

## 9. API & server notes (coordinate with `silo-server`)

- **Merged scope (`All <Type>`): removed (Rev 3, user decision).** No server or
  client merge is needed; multi-library tabs scope to a single library chosen via
  the cascade (§5.3). This bullet is retained for history only.
- **Marquee payloads:** the marquee renders synopsis, runtime, codec/HDR
  badges, rating, and episode position straight from **section-item models** —
  verify the home/library section payloads already carry these fields (the TV
  clients must not block the marquee on a per-item detail fetch; if a field is
  missing, ship without it and backfill from a low-priority prefetch).
- **Featured sections:** the TV clients no longer render the server's featured
  hero section as a carousel. The server may keep sending it (iOS still uses
  it); tvOS/Android TV simply ignore it — no server change required.
- Home sections, library sections, collections, calendar, and recommendations
  endpoints are otherwise reused as-is; "For You" folding is purely a client
  presentation change.
- Top Shelf (tvOS) and deep links (`continuum://`) are unaffected — routes for
  detail/player don't change.

---

## 10. Implementation mapping

### tvOS (evolves, mostly in place)

| Area | Change |
|---|---|
| `TVMainTabView` / `TVRootDestination` | Done in Phase 1: per-type cases driven by visible libraries; single shared `NavigationStack` |
| `TVTopMenuBar` | Tabs type-derived (done); add the 250 ms dwell trigger that opens the cascade/profile panels; avatar dropdown rows (done) |
| New: cascade selector | Two-level anchored panel (§5.3): level 1 libraries, level 2 sections flyout; profile menu reuses level 1 |
| New: `TVFocusMarquee` | Shared marquee (Home + library scales) driven by a focused-item publisher with 150 ms debounce; backdrop via `TVRootHeroBackdrop` tracking focus instead of carousel index |
| `HomeView` | tvOS: drop `FeaturedCarousel` (component remains for iOS), mount the marquee, entry focus to first Continue Watching card; recommendations rows after Continue Watching (done) |
| `TVLibraryTypeTabView` / `TVLibraryPillRow` | Pill row done; rename `Featured` pill → `Browse`; pill preselection when arriving from a flyout section |
| `TVLibraryFeaturedView` | Becomes the Browse pill content: marquee + items row + Collections row (no carousel) |
| `TVLibraryGridView` | Reused by Genres/A–Z/Recently Added pills unchanged |

### Android TV (same shape, plus parity work)

| Area | Change |
|---|---|
| `TvMainRoute` / `TvMainShell` | Replace `Libraries`/`ForYou` routes with per-type tab routes + `Calendar` |
| `TvTopMenuBar` | Add type tabs + Calendar; move Search to right cluster with avatar; dwell-open cascade (no chevron suffix); widen `headerBandHeight` content to match §5.1 metrics |
| `TvLibrariesScreen` + `TvFullScreenPicker` (library use) | Delete; `TvLibraryDetailScreen` becomes the tab body with pill row + marquee |
| New: cascade selector composable | Two-level anchored panel + flyout (replaces `DropdownMenu` styling); shared with profile menu |
| New: focus marquee composable | Immersive-list pattern: row focus drives the marquee + backdrop crossfade |
| New: Calendar screen | Port of tvOS Calendar (week strip + shelves) |
| `TvHomeScreen` | Drop the hero carousel, mount the marquee; recommendation rows after Continue Watching |

### Suggested phasing

1. **Phase 1 — chrome** *(shipped on tvOS)*: type-derived tabs, pill row
   replacing the mode slider, Libraries/For You tabs removed, profile dropdown
   expanded.
2. **Phase 2 — marquee:** focus marquee replaces the Featured carousel on Home
   and the library Browse landings; rows-first focus maps; backdrop follows
   focus; `Featured` pill renamed `Browse`.
3. **Phase 3 — scopes:** cascading selector (dwell trigger, sections flyout),
   scope persistence, single-library sections panel.
4. **Phase 4 — polish & parity:** collections fan row + fan cards, Android
   Calendar, motion & reduced-motion pass, VoiceOver/TalkBack pass.

### Acceptance checklist (per platform)

- [ ] Cold start lands on Home, focus on the first Continue Watching card,
      marquee previewing it, < 1 s to chrome.
- [ ] Every visible library type reachable in ≤1 press from the top bar.
- [ ] Any section of any library reachable in ≤3 presses from the top bar
      (dwell → down/roll → right → press), no full-screen modal anywhere.
- [ ] Sweeping focus across the whole top bar without resting never opens a
      panel; resting 250 ms on a library tab always does.
- [ ] Marquee updates within 400 ms of focus resting on a card; scrubbing a
      row quickly never flashes intermediate backdrops; the marquee never
      takes focus.
- [ ] Collections reachable in ≤2 presses from anywhere in a library tab.
- [ ] No stateful mode toggles anywhere in the chrome.
- [ ] Back/Menu chain: content → bar → Home → system, never trapped; Menu
      inside the cascade closes it without changing scope.
- [ ] Focus never lost (every transition defines a target), VoiceOver/TalkBack
      labels on tabs ("Movies, tab, 2 of 6"), the cascade announced as a menu
      and the flyout as its submenu, marquee changes announced politely
      (non-interruptive).
- [ ] Reduced-motion setting: marquee updates snap (no crossfade), no drift
      animations.

---

## 11. Open questions

1. ~~Should `All <Type>` be server-side or client-merged?~~ **Resolved (Rev 3): `All <Type>` dropped; single-library scoping only.**
2. Music tab pill set: confirm `Playlists` exists server-side for TV contexts.
3. Do we keep the wordmark text or swap in the `SiloWordmark` asset at 26 px cap height?
4. Calendar on Android: ship in Phase 3 or cut scope to tvOS-only initially?
5. Cascade dwell duration: 250 ms is the spec start point — tune on device so
   deliberate landings always open it and bar sweeps never do; confirm the
   scrim-on-dwell doesn't feel flashy when moving slowly across the bar.
6. Marquee payloads: audit which synopsis/badge fields the section endpoints
   already return (§9) — decide ship-without vs. prefetch for any gaps.
7. Profile dropdown dwell-open (§5.8): validate it doesn't trigger annoyingly
   when targeting the adjacent Search button.
