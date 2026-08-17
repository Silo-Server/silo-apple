# tvOS Item Detail Redesign — "Squared Skyline" — Design Spec

- **Date:** 2026-06-15
- **Status:** Approved (design); ready for implementation planning
- **Platform:** tvOS only (iOS/iPadOS/macOS detail pages unchanged)
- **Related:** `docs/skyline-design-guide.md` (the TV content language this extends),
  `docs/tvos-detail-mockups/` (the brainstorm mockups: `directions`, `buttons`,
  `refined-page`, `playback-selection`, `audiobook`).

## 1. Summary

A **refinement** of the existing tvOS item-detail pages (movie, series, season,
episode, audiobook) — not a restructure. The current cinematic layout
(full-bleed hero → stacked rails) is kept; what changes is:

1. **Every on-page control is squared** to an 8 pt corner family (buttons,
   version control, overflow menu, season chips) — replacing today's capsule
   pills and circular icon buttons.
2. A **pre-Play playback-selection row** (Edition · Version · Audio · Subtitles)
   is added under the action buttons, mirroring the Silo **webapp**, so the user
   sees and can change what will play before pressing Play.
3. The **audiobook** page is reworked from a flat side-by-side header into a
   **cover-forward** member of the same cinematic family.
4. The **focus/scroll model** is cleaned up so the D-pad never dead-ends on a
   non-interactive paragraph (the `ReadableFocusSection` workaround is removed).

This is largely a **view-layer change**. Auth, networking, the player core, and
the detail view models are not rewritten; the one behavioral addition is wiring
the chosen audio/subtitle tracks into the player's initial selection (the data
already exists).

## 2. Design language (source of truth)

The detail page is a **Skyline-native** full-screen route — the visual
continuation of the browse experience, *not* the Aurora onboarding language.
Conceptual north star: **the detail page is the Skyline focus marquee bloomed to
full screen** — the same backdrop, eyebrow "tick," title, and metadata the
marquee was already previewing expand into an interactive page.

Reused from `docs/skyline-design-guide.md` and `ContinuumTheme.swift`:

- Background OLED black `#000000`; surfaces `#0A0A0A` / elevated `#15171C`.
- Monochrome chrome — primary text `#EDEDED`, secondary @ 60%, tertiary @ 38%,
  hairline white @ 12%. **No chromatic accent.** Rating amber `#FFC107` and the
  outlined format badges are the only non-monochrome marks; backdrop artwork is
  the only place full color lives.
- `marquee.tick` eyebrow dash (white @ 85%, 26×3, r 2) precedes section/eyebrow
  labels.
- Menus, the selector menus, and the overflow menu use Skyline `glass.strong`
  (`#16171B` @ 86% + blur 40).
- Radii: the squared-control family is **8 pt** (`ContinuumTheme.smallCornerRadius`).
  Cards keep 12 pt; section card backgrounds 18 pt.

## 3. Scope — locked decisions

| # | Decision | Choice |
|---|---|---|
| 1 | Overall direction | **Refine the current cinematic page** (mockup "A"); not the tabbed-shelf ("B") or companion-panel ("C") restructures. |
| 2 | Hero size | **Kept dominant** (full, ~980 pt). Not trimmed to let rails peek. |
| 3 | Button shape | **Squared, 8 pt** ("D"): labeled primary, Resume + Start-Over pair, compact square icon tiles for toggles. |
| 4 | Other controls | **All squared** — version control, overflow `⋯` menu, season chips. |
| 5 | Playback selection | **Selector row in the hero** ("A", webapp parity): Edition · Version · Audio · Subtitles. |
| 6 | Selection persistence | **Sticky per profile** (remembered next visit); otherwise show the auto-resolved pick. |
| 7 | Audiobook | **Cover-forward facelift** into the cinematic family. |
| 8 | Synopsis / long text | **Expand in place** (no overlay panel). |
| 9 | Focus model | **"Every stop is a control"** — remove `ReadableFocusSection`. |

## 4. The squared control family

All interactive controls move to one 8 pt-radius family. Retire the capsule
(`Capsule()`) and circle geometries on the detail page.

- **Primary — Play / Resume.** Solid white, black label, icon + label, 8 pt
  radius. Default focus target. Resume shows position (e.g. `Resume S2·E4` for
  series, `Resume · 6h 12m left` for audiobooks, `Resume 1:24:30` for movies).
- **Secondary labeled — Start Over.** Translucent white fill (white @ 0.08) +
  hairline border (white @ 0.22), white label, 8 pt. Appears only when
  resumable.
- **Icon tiles — Watchlist (`＋`), Favorite (`♥`), Watched, More (`⋯`).** Square
  (equal width/height), 8 pt, icon-only, same fill/border as the secondary.
  Active state fills the glyph (favorited/on-watchlist/watched). `⋯` opens a
  squared `glass.strong` menu (audio/subtitle deep options that don't fit the
  selector row, go-to-series/season, etc.).
- **Focus treatment (all squared controls).** Suppress the native tvOS halo;
  use **scale 1.04 + 2–3 pt white ring + drop shadow** (consistent with the
  existing `.ring` card grammar). The white primary brightens slightly on focus.
  Under **Reduce Motion**: ring only, no scale/lift.

Implementation note: this is a reshape of the existing button styles
(`TVPrimaryPillButton`, `TVSecondaryPillButton`, `TVCircleMenuButton`,
`TVPillButtonStyle`, `TVCircleButtonStyle`) — same components and call sites,
new geometry — or a single new `TVActionButtonStyle`. The standalone
`TVVersionPillButton` is **absorbed** into the selector row (§6) as "Version".

## 5. Hero (kept dominant)

Unchanged in structure from `TVDetailHero` (full-bleed backdrop, left + bottom
scrim stack, lower-left content column). Content, top→bottom:

- **Eyebrow** — `marquee.tick` dash + caps label (genre/status), as today.
- **Title** — `TVHeroTitle` / logo art / episode-hierarchy title (unchanged).
- **Meta line** — year · rating · runtime/seasons · `★` IMDb · **format badges**
  (`4K` / `DOLBY VISION` / `ATMOS` / `CC`) as outlined chips (unchanged).
- **Synopsis** — clamped to ~3 lines; an **expand-in-place** control (§7).
- **Action row** — the squared controls (§4).
- **Selector row** — playback selection (§6), directly beneath the actions.

## 6. Playback selection row (webapp parity)

A second row directly under the action buttons, matching the webapp's model and
terminology (see `silo-server/web/src/pages/ItemDetail/components/`).

**Items** (each a squared 8 pt selector button: `[icon] LABEL  value  ⌄`, caps
tertiary label, white value, tertiary chevron):

| Selector | Shown when | Value examples | Notes |
|---|---|---|---|
| **Edition** | ≥2 distinct editions exist | "Director's Cut" | Derived by grouping `FileVersion.edition`. Changing it re-resolves Version/Audio/Subtitle for that edition. |
| **Version** | ≥2 versions, or any edition selected | "4K · HDR" | Quality summary `resolution · codec · HDR · audio`. Replaces the old version pill. |
| **Audio** | selected version has ≥2 audio tracks | "English 5.1" + `AUTO` tag | `Auto · <resolved>` when auto-picked; badges Atmos/TrueHD/DTS, channels, Default. |
| **Subtitles** | a version is selected (always) | "Off" / "English" | `Auto` / `Off` entries; badges Forced / HI / Default. |

The whole row hides only when no selector exists at all (single edition, single
version, single audio, no subs). Each selector opens a focus-managed
`glass.strong` squared menu listing options with a check on the current one and
the badges above — same strings as the webapp (`Auto`, `Off`, `Default`,
`Forced`, `HI`).

**Default resolution (what the row shows before any change):**
- Version: existing logic — sticky `lastFileId`, else quality-preference best
  match (`DetailVersionSelection` / `MovieDetailContent`).
- Audio / Subtitle: the player's auto-resolution, surfaced as `Auto · <pick>` so
  the user sees the predicted track.

**Sticky (per profile):** a change is remembered and pre-selected next visit:
- Version → `userData.lastFileId` (already persisted).
- Audio / Subtitle → the existing `AudioTrackSignature` / `SubtitleTrackSignature`
  preference model (`PlaybackPrefsModels`).
- Edition → derived from the sticky version's edition (or a server
  `lastEditionKey`; see §11).

**Hand-off to the player:** the chosen audio/subtitle tracks become the player's
**initial** track selection at launch. Today track selection happens in-player;
the data is present, so this is wiring, not new modeling.

**Per-type behavior:**
- **Movie / Episode:** full row as above.
- **Series / Season:** the row reflects the **next-up episode's** file (as the
  version pill does today), loaded in the background with the existing placeholder.
- **Audiobook:** the row collapses to a single **Narration** selector (maps to
  alternate narrations); no Version/Audio/Subtitles.

## 7. Focus & scroll model — "every stop is a control"

Removes the `ReadableFocusSection` workaround (which made paragraphs focusable
just to scroll them into view, so the user "landed" on inert text).

**Vertical focus path** (down):

```
Synopsis (expand)            ← reachable by Up from the action row
  ↑↓
Action row:    Play → Start Over → ＋ → ♥ → Watched → ⋯
  ↓
Selector row:  Edition → Version → Audio → Subtitles
  ↓
Body rails:    Cast & Crew → [Episodes / Chapters] → More Like This
```

- **Down** from the hero never stops on text — it moves action row → selector
  row → first body rail, then rail-to-rail. Left/right traverse within a row.
- **Synopsis** is the only text focus stop, reachable by **Up** from the action
  row (nothing sits above it on a pushed route). Select **expands it in place**
  (full overview + tagline); Select again or Back collapses. Landing there is
  meaningful because Select acts.
- **Details (facts grid)** is **not** a focus stop. It rides directly above its
  neighboring rail and scrolls fully into view when that rail gains focus.
- The separate body **"About"** section is folded into the hero synopsis expand
  (the full overview + tagline live there), removing a duplicate text block.
  *(Flagged for review — see §11.)*
- Per-rail focus memory and "land on current/first card" behavior are unchanged.

## 8. Per-type pages

Section order is otherwise as today; only the control language, the selector
row, and the focus model change.

- **Movie:** hero (+ selector row) → Cast & Crew → Details (rides above) → More
  Like This.
- **Series:** hero (next-up selector row) → **squared season chips** + episode
  rail → Cast & Crew → Details → More Like This.
- **Season:** hero → squared season chips + episode rail → Cast & Crew →
  Details. (No More Like This, as today.)
- **Episode:** hero (+ selector row) → episode rail (current highlighted) → Cast
  & Crew → Details. (No More Like This, as today.)
- **Audiobook:** §9.

**Season chips** (`TVSeasonChip`) change from capsule to 8 pt squared: selected =
solid white / black label; idle = hairline outline; focus = white ring. Auto-
center + land-on-selected behavior unchanged.

## 9. Audiobook facelift

From the current flat side-by-side header to a **cover-forward** cinematic hero
in the same family (audiobooks have square cover art, not a 16:9 still):

- **Hero:** the square cover featured left over a **cover-tinted, scrimmed
  backdrop**; same eyebrow tick and squared controls. Right column: title,
  `by <author> · Read by <narrator>`, meta line (Unabridged · total time ·
  chapter count · `★`), expandable synopsis. Actions: `Resume · <time left>` +
  `Start Over` + tiles. A single **Narration** selector (§6).
- **Body:** **Chapters** as squared rows (number · title · duration, current
  chapter highlighted), Parts where present, then **More by Author** and
  **Related** rails (square cover cards). Alternate narrations are reachable via
  the Narration selector.
- Keep `AudiobookDetailContent` shared with iOS via `#if os(tvOS)`, but the tvOS
  branch becomes the cover-forward hero rather than the current header.

## 10. Motion

Reuse `ContinuumTheme` durations: focus 0.12 s, transitions 0.20 s, crossfades
0.30 s. Specifics: squared-control focus ring/scale 0.12 s; synopsis expand/
collapse 0.20 s height + fade; selector menu open = `glass.strong` scale
0.96→1.0 + fade. **Reduce Motion:** no scale/expand animation — snap; ring-only
focus.

## 11. Data, server & cross-platform coordination

- **Editions:** tvOS has `FileVersion.edition: String?` but **no `PlaybackVariant`
  grouping**. Client-side, group versions by `edition` to build the Edition
  selector. *Coordinate with `silo-server`:* confirm whether to surface the
  normalized `edition_key` (+ ranking) on the tvOS detail DTO for correct
  grouping/default selection, or rely on the raw string. (Open.)
- **Edition stickiness:** there is no `lastEditionKey` on tvOS. Derive the sticky
  edition from the sticky version, or add the field server-side. (Open.)
- **Audio/subtitle initial tracks:** `FileVersion.audioTracks`/`subtitleTracks`
  and the `*Signature` prefs already exist; the work is feeding the chosen tracks
  into the player at launch and surfacing the Auto resolution on the detail page.
- **Android TV:** the squared control family and the pre-Play selector row are a
  client UX choice worth mirroring later on the Android TV detail page for
  parity (non-blocking; note for that team).
- **Web:** no change; this matches the existing webapp behavior.
- Top Shelf / deep links / detail routes unaffected.

## 12. Non-goals / out of scope

- No tabbed-shelf ("B") or companion-panel ("C") restructure.
- Hero is **not** shrunk; rows-first hero trimming is explicitly declined.
- No rewrite of auth, networking, `ItemDetailViewModel`, the player core, or the
  recommendations/cast/episode endpoints.
- No iOS/iPadOS/macOS detail changes (those have their own `Phone*`/Mac layouts).
- No new editions/track *authoring* — only surfacing/selecting what the API
  already returns.

## 13. Acceptance criteria

- Every detail control (buttons, version, `⋯`, season chips) renders in the 8 pt
  squared family; no capsules or circles remain on tvOS detail pages.
- The action row reads Play/Resume (+ Start Over when resumable) + Watchlist +
  Favorite + Watched + More, with the focus ring/scale treatment; Play is the
  entry focus.
- The selector row shows Edition/Version/Audio/Subtitles per the show-logic,
  with resolved/Auto/Off values and correct badges; hides entirely when nothing
  is selectable; collapses to Narration for audiobooks.
- Changing a selector updates the resolved playback and, on next visit to the
  same item/profile, the change is pre-selected (sticky); audio/subtitle choices
  apply as the player's initial tracks.
- D-pad **down** from the hero moves action → selector → rails without ever
  stopping on a paragraph; the synopsis is reachable by **Up** and expands in
  place; `ReadableFocusSection` is gone; focus is never lost.
- The audiobook page renders as the cover-forward cinematic hero with a Chapters
  list and the Narration selector.
- Reduce Motion yields snap transitions and ring-only focus.
- iOS/iPadOS/macOS detail pages are visually unchanged.

## 14. Open questions

1. **Edition grouping/ranking:** group by the raw `edition` string client-side,
   or have `silo-server` surface `edition_key` (+ default ranking) on the tvOS
   DTO? (§11)
2. **Edition stickiness:** derive from the sticky version, or add a server
   `lastEditionKey`? (§11)
3. **"About" body section:** fold the full overview+tagline entirely into the
   hero synopsis expand (current plan), or retain a non-focusable About block in
   the body that rides with a rail? (§7)
4. **Audio/subtitle deep options:** anything that doesn't fit the selector menus
   (e.g. download-subtitle flows the webapp has) — keep in the `⋯` menu or out of
   scope for tvOS initially?
