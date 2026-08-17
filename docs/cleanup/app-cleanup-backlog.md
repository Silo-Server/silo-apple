# App cleanup — backlog and watch list

Status as of 2026-08-16, after cleanup rounds 1 and 2 landed on `player/one-player-cleanup`
(round 1: `20f5aff` → `5f1f17d`; round 2: `155d9bc` → `e5360ae`). This is the list of what is still known to be removable, what was
deliberately left alone, and where a closer look is likely to pay off. Line references are
against `e5360ae` (§1) or `5f1f17d` (§2–4); re-grep before acting on any of them.

## 0. Where we are

Round 1 (survey → verify → 7 file-disjoint packages, each implemented and independently
reviewed) removed **2,804 lines of Swift code**; round 2 (the §1 quick wins below, 6 packages)
removed another **618**. cloc, comments/blanks excluded:

| | Before round 1 | After round 1 | After round 2 |
|---|---|---|---|
| App Swift code (`iosApp/iosApp` + `TopShelf`) | 122,609 | 119,805 | **119,187** |
| Player (`Screens/Player`) | 43,323 | 42,564 | 42,540 |
| Tests | 34,567 (1,367 cases) | 34,412 (1,355 cases) | 34,412 (1,355 cases) |

Raw git: round 1 −4,368 / +513, round 2 −866 / +165. Verification after each round: `Silo`,
`SiloTV`, `SiloMac` build; iOS suite at the same baseline as before (14 failures, all
pre-existing — see §4.6). The survey covered six slices with a cap of 12 findings each, so the
tail below every slice's top-12 was **not** captured — a second survey pass will find more.

## 1. Ready to do — small, mechanical, unblocked

**Round 2 (2026-08-16, `155d9bc` → `e5360ae`) closed the original 13 quick wins:** orphaned
Collections screen trimmed out of `CollectionsView.swift` (+ `CollectionsViewModel.swift`,
`CacheKey.collections`); backend/session half of `SubtitleLoadStatus`; `TVLibraryTypeTabView.
selectedPill` binding → value; `TVLibraryGridView.initialFilter`; `PINEntryView.isShaking`;
`OverlayPrefsStore.usesLegacyAPI`/`resolvedLegacyAPI` + both stale comments; `FavoritesView.swift`
→ `PersonalListGridView.swift`; `PhoneHeroMetadata` → `Screens/Detail/HeroMetadata.swift`
(`HeroMetadata`/`HeroFactToken`, typealiases gone); shared subtitle-sheet types moved to
`Sheets/SubtitleLanguageChoice.swift` (row renamed); `applyHUDEntryPoint()` parameter dropped;
identical episode runtime formatter hoisted into `DetailFacts.swift` (divergent variants left
alone, as intended); docs 04 / tvOS-detail spec no longer cite deleted symbols; tvOS-only
`SettingsViewModel` members wrapped in `#if os(tvOS)`.

**Left over / newly exposed by round 2** (all small, all mechanical):

| # | Item | Where | Notes |
|---|---|---|---|
| 1.14 | **`Route.collectionDetail` + `CollectionDetailView` are now orphaned** | `Navigation/Route.swift:29`, `Screens/Collections/CollectionDetailView.swift`, arms in `ContentView.swift` (~2191) and `TVMainTabView.swift` (~1217), `AppRouter.diagnosticsTarget` | The only constructor of `.collectionDetail(collectionId:)` was inside the deleted `CollectionsView`. Delete the case, the arms, and the view. Also removes one dispatcher call-site file (helps §2.1). |
| 1.15 | **`CollectionsResponse`, `CreateCollectionRequest`** have no app consumer other than `ContinuumAPI` itself | `Networking/Models.swift` (~1497, ~1515), `Networking/ContinuumAPI.swift` (typed `collections()`/`createCollection` + dispatcher arm ~213) | Remove as a unit with the dispatcher arm — best folded into §2.1 rather than done alone. |
| 1.16 | **`CollectionsView.swift` now only holds `LibraryCollections*`** | `Screens/Collections/CollectionsView.swift` (744 → ~350 lines: `LibraryCollectionsViewModel`, `LibraryCollectionsView`, `LibraryCollectionCard`, `LibraryCollectionDetailView`, `libraryCollectionAccessibilityLabel`) | `git mv` to `LibraryCollectionsView.swift` (folder glob; no project.yml change). |
| 1.17 | **`TVLibraryGridView` header path is dead** | `tvOS/Screens/Libraries/TVLibraryGridView.swift:13, 17, 47–48` + the `header` view | Its single remaining call site passes `showsHeader: false`; `subtitle`, `showsHeader` and `header` can go. |
| 1.18 | Divergent runtime formatters (3 styles) | `HomeFeedKit.swift:57`, `OverlayRegistry.swift:356`, `TVFocusMarquee.swift:173`, `HeroMetadata.swift` (`" min"`), `DetailFacts` (`"m"`) | **Product decision, not cleanup** — unify only if one output format is chosen for the whole app. |

## 2. Larger deferred cleanups — need their own PR and/or an owner decision

### 2.1 Retire `ContinuumAPI`'s string-path dispatcher (~−360, medium risk)

`Networking/ContinuumAPI.swift:45–331` is a `// MARK: - Path-based dispatcher (legacy)` that
string-matches `/api/v1/...` and forwards to typed methods via `cast<T>()`/`requireBody`. After
round 2 the call sites are in 7 files: `PersonalListGridView`, `SettingsViewModel`,
`SearchViewModel`, `TVLibraryGridViewModel`, `ItemDetailViewModel`, `CollectionDetailView`
(goes away with 1.14), `PlaybackSessionBridge`. Every path used already
has a typed method. Plan: retarget the call sites (keeping the dispatcher's default
`offset`/`limit` values — 100 for favorites/watchlist, 200 for collection items), delete the
dispatcher + `pathComponents`/`queryInt`/`cast`/`requireBody` + the `APIError`
`.invalidPathParameter`/`.unsupportedPath` cases, then delete the now-unreachable
`startPlayback(request:)`, `startTranscode`, `history(offset:limit:)` and their models
(`StartPlaybackRequest`, `TranscodeStartRequest`, `TranscodeStartResponse`,
`CreateCollectionRequest`). Worth doing: it also removes ~20 route branches that nothing hits.

### 2.2 The legacy EVENT loopback serving mode behind the kill switch (~−800, **high risk**, product decision)

`LoopbackServingMode.event` is documented as legacy (`PlaybackExecutionPlan.swift:346–349`);
`gated` returns `.vodPlan` unless `player.apple.siloplayer_primary_enabled` is explicitly false
("Stage 3 flipped the default ON", 2026-07-03). The video bridge is VOD-plan only. If the team is
ready to retire the kill switch: delete `.event`/`gated`, make the planner always emit
`.vodPlan`, then remove the ~34 `vodActive` branches in `LoopbackSegmentWriter`
(`waitForGeneratedAheadIfNeeded`, `retireSegmentsBehindPlaybackIfNeeded`, live runway + sliding
playlist emission, generated-ahead throttle constants), the memory-spill/eviction path in
`LoopbackSegmentStore` (`SpillPolicy`, `spill*`, `retireSegments`, `generatedHLSSpillPolicy` in
the backend) and the backend's EVENT-only seek-reanchor/live-edge code; update
`LoopbackBufferPolicyTests` and `ApplePlaybackRoutePlannerPinTests`. **Needs a device pass on
Apple TV and an explicit go from the player owner; do not bundle with mechanical cleanups.**
This is the single largest lever left in the player.

### 2.3 Route-capability blocker scaffolding (~−80, medium risk, currently vacuous)

`ApplePlaybackRouteCapabilities.blockingReasons()` can never return a blocker today (all six
gated entries are `.repoVerified` on all four routes) and `keeps*DisabledUntilValidated` are
always false in production. It was **kept on purpose**: `docs/tvos-player/05` calls the file the
executable capability matrix, and the `needs*`/`keeps*` fields feed `summaryTokens` →
`decisionTrace` (pinned in three test files). If the matrix is never going to be downgraded
again, this can go along with its trace tokens; otherwise leave it. Decide once the player
consolidation settles.

### 2.4 `OverlayPrefsStore` legacy `card_overlays` fallback (~−55) — **not a cleanup**

Refuted in round 1: it is a deliberate degraded path for pre-contract servers (added in
`50409d1`, #118) with wire-format parity to the web `useOverlayPrefs.ts` hook. Removing it
changes behaviour on old servers. Only revisit as a coordinated server/web/Android decision to
drop pre-contract support.

## 3. Intentionally kept — don't re-flag without new information

- `LoopbackSegmentWriter` throughput probe (`traceThroughput`, `ThroughputTiming`, 11 timed/untimed
  branch pairs, ~100 lines): opt-in field diagnostic (`SILO_TRACE_DV_THROUGHPUT` /
  `player.apple.loopback_trace_throughput`) that identified the 2026-07-05 ingest ceiling; gated
  the same way as the sibling `SILO_TRACE_DV_SEGMENTS` probe. If it stays, the duplicated call
  bodies could collapse onto one `measure(into:)` helper — but that's a refactor, not a deletion.
- `LoopbackVideoBridge` and the on-device bridge path: dormant on the live path by design
  (`docs/tvos-player/09-video-bridge.md`).
- `PlayerTaskRegistry.Key.protocolV3Replan`: live (single-flight guard in the VM) despite looking
  unused to a naive grep.
- Keychain/registry migrations, `SiloControl` v1 peer compatibility, and the onboarding
  legacy-suppression record: TestFlight-continuity and user-data paths, deliberately not surveyed.

## 4. Areas worth a closer look (not yet surveyed for deletion, or needing a different brief)

### 4.1 The three files that are a third of the player
`PlayerViewModel.swift` **6,294**, `LoopbackSegmentWriter.swift` **5,151**,
`AVPlayerBackend.swift` **~3,780** code lines — 15.2k of the player's 42.5k. Round 1 only trimmed
write-only state from them; the "delete dead code" brief cannot make them smaller. What would:
(a) §2.2 (EVENT mode) takes a real bite out of the writer; (b) the VM still hosts several
distinct concerns behind `// MARK:` fences (route planning glue, subtitle sink adapter, HUD/entry
points, stats enrichment, task registry, live-subtitle diagnostics) — a structural pass would
extract these along existing seams rather than "split by size"; (c) `AVPlayerBackend` still
carries EVENT-only seek/live-edge logic that §2.2 removes. Treat any structural pass as a
separate, reviewed effort with pinned behaviour tests — not as cleanup.

### 4.2 Comment density in the player
`Screens/Player` carries 11.6k comment lines against 42.6k code (27%; the rest of the app is
~19%). Much of it is investigation history and rationale — valuable — but round 1 found six
stale `TrackSelectionSheet` references, "CoreMedia" buffer comments for a deleted backend, and
docs pointing at removed symbols. A comment-accuracy pass over the loopback writer/store/server
and the VM would be cheap and reduce future misdirection. Don't strip rationale.

### 4.3 Per-platform twins as a pattern
Round 1 folded `TVSettingsViewModel`, `TVHeroMetadata`, `TVDetailFactsSection`'s model,
`TVItemDetailView`'s loaders, `WatchlistView`, and eight focus-helper copies. The pattern
(copy an iOS type into `tvOS/` and let it drift) is likely to recur. Candidates not yet audited:
`tvOS/Screens/**` views vs `Screens/**` (episode rails, cast rails, search), `tvOS/Caching/`
vs `Networking/ResponseCache`, and any remaining `Screens/Detail/Phone/` helpers that are in
fact platform-neutral (`HeroMetadata` was moved out in round 2; `PhoneEpisodeFormatting` etc.
may follow). Rule of thumb from `docs/tvos-focus.md`: share models and formatting,
keep focus ownership per-platform.

### 4.4 `ContinuumAPI` surface after §2.1
Round 1 removed nine dead endpoints and six wire models; the reviewers noted the durable
consequence is *reduced client API surface* (per-library playback prefs, `/settings/effective`,
collection reordering, batch manifests, subscriptions list, continue-watching undo). Worth a
deliberate check against `silo-server`'s current API contract to see whether any of these are
planned client features (re-add on demand) or truly retired server-side (then also drop the
server routes).

### 4.5 `ResponseCache` is "intentionally dumb"
Plain dictionary, no TTL/LRU. Round 1 removed a write-only entry (`itemWatchDetail`); a survey
of which keys still have readers, and whether the cache is doing anything on tvOS where
`ItemDetailCache` also exists, is cheap.

### 4.6 The 14 baseline test failures
`ProfileLaunchIdentityTests` (2), `ProfileLaunchMigrationTests` (1), `SettingValuesAPITests`
(2), `UICustomizationPreferencesTests` (2, counted more than once by xcresult) fail on the base
branch and on `main`, independent of the cleanup — they look like keychain / profile-identity
environment assumptions in the simulator. Either fix the environment or mark them; a suite that
is "green at 14 failures" hides regressions.

### 4.7 tvOS focus helpers
Round 1 consolidated eight private copies onto three shared `View` extensions in
`Extensions/ViewExtensions.swift` (`applyDefaultFocusIfPresent`, `applyFocusBindingIfPresent`,
play/pause wrapper). Behaviour was verified identical (same modifiers, same
`.userInitiated` priority), but this is exactly the area `docs/tvos-focus.md` warns about —
if any tvOS focus regression shows up on device, check these three helpers first.

### 4.8 Deferred survey tail
The survey capped each slice at 12 findings ranked by (LOC × confidence / risk). Slices where
the finder said "more below the cut": player-avroute (definition-only members), infra
(member-level deletions in Downloads/Pairing/Diagnostics), screens (formatting helpers). A
second survey pass after §1 and §2.1 land will surface those; expect a few hundred more lines,
not thousands.

### 4.9 Benchmarks
For orientation: AetherEngine (a full FFmpeg-demux / VideoToolbox / dav1d engine with disc,
SMB, DVR and frame extraction, no UI) is 44.7k code lines. The Silo player is 42.6k with ~7k of
UI. Nothing to act on directly, but it's a fair yardstick for how much of the player is
accidental complexity vs. essential.

## 5. Running the next round

The two-stage workflow (survey → review packages → fix → merge) lives in `.claude/workflows/`
(`app-cleanup-survey.js`, `app-cleanup-fix.js`, README) — local-only because `.gitignore`
ignores `.claude/*` except `skills/`. Rules learned in rounds 1–2: keep packages file-disjoint;
split mechanical deletions from riskier refactors; fixers must reset their worktree to the
target branch's full SHA first (the harness worktrees start from `main`); run tests on cloned
simulators; treat "green" as the documented baseline, not zero failures.
