# App cleanup — backlog and watch list

Status as of 2026-08-16, after cleanup round 1 landed on `player/one-player-cleanup`
(`20f5aff` → `5f1f17d`). This is the list of what is still known to be removable, what was
deliberately left alone, and where a closer look is likely to pay off. Line references are
against `5f1f17d`; re-grep before acting on any of them.

## 0. Where we are

Round 1 (survey → verify → 7 file-disjoint packages, each implemented and independently
reviewed) removed **2,804 lines of Swift code** (cloc, comments/blanks excluded; −4,368 / +513
raw git lines):

| | Before | After |
|---|---|---|
| App Swift code (`iosApp/iosApp` + `TopShelf`) | 122,609 | 119,805 |
| Player (`Screens/Player`) | 43,323 | 42,564 |
| Tests | 34,567 (1,367 cases) | 34,412 (1,355 cases) |

Verification: `Silo`, `SiloTV`, `SiloMac` build; iOS suite at the same baseline as before
(14 failures, all pre-existing — see §4.6). Full survey/fix reports live in the workflow run
records; the survey covered six slices with a cap of 12 findings each, so the tail below every
slice's top-12 was **not** captured — a second survey pass will find more.

## 1. Ready to do — small, mechanical, unblocked

Each of these is a pure deletion/rename that round 1 either exposed or could not reach because
of package file boundaries. Together roughly −250 lines. Good candidates for one small PR.

| # | Item | Where | Notes |
|---|---|---|---|
| 1.1 | Delete the now-orphaned **Collections screen** | `Screens/Collections/CollectionsView.swift`, `CollectionsViewModel.swift`, `CacheKey.collections` | The only constructors were the never-constructed `Route.collections` arms removed in round 1. Zero construction sites repo-wide. |
| 1.2 | Remove the backend/session half of **`SubtitleLoadStatus`** | `AVPlayerBackend.onSubtitleLoadStatusChange` (+ forwarding closure), `SubtitleSession.publishStatus`/`onStatusChange` (10 call sites), `enum SubtitleLoadStatus` in `SubtitleTrackIdentity.swift` | VM half already gone; the hook now fires into a nil closure. ~−25. |
| 1.3 | **`TVLibraryTypeTabView.selectedPill`** is a `@Binding` never written | `tvOS/Screens/Libraries/TVLibraryTypeTabView.swift:28`, `TVMainTabView` `pillSelection(for:)`/`shortcutPillSelection` (~897–924) | Make it a `let`; drop the `Binding(get:set:)` wrappers whose setters never fire. ~−15. |
| 1.4 | **`TVLibraryGridView.initialFilter`** is always `.none` | `tvOS/Screens/Libraries/TVLibraryGridView.swift` | Follow-on of the `.tvLibraryGrid` route removal. |
| 1.5 | **`PINEntryView.isShaking`** is permanently false | `Screens/Profiles/PINEntryView.swift:10, 119–124` | Either drop the state + `.offset`/`.animation` modifiers, or restore the wrong-PIN shake if that feedback was intended (it never had a caller). |
| 1.6 | **`OverlayPrefsStore.usesLegacyAPI` / `resolvedLegacyAPI`** are write-only after the write path went | `Networking/OverlayPrefsStore.swift:55–57, 118, 162, 187` | Behaviour-neutral either way; at minimum reword the comment (it describes the deleted write path). Also line 31 still says "Mirrors the `PlaybackPrefsStore` pattern" — that file no longer exists. |
| 1.7 | **`FavoritesView.swift` no longer contains a `FavoritesView`** | `Screens/Personal/FavoritesView.swift` | Holds `PersonalListKind` + `PersonalListGridView`; `git mv` to `PersonalListGridView.swift` (folder glob, no project.yml change). |
| 1.8 | **`PhoneHeroMetadata` is compiled on tvOS via typealias** | `Screens/Detail/Phone/PhoneHeroMetadata.swift`, typealiases in `tvOS/Screens/Detail/TVDetailHero.swift:414` | Rename to a neutral `HeroMetadata`/`HeroFactToken`, move beside `DetailFacts.swift`, drop the typealiases (12 tvOS + 14 iOS call sites). Until then the `Phone/` folder name is a trap: re-adding a `#if !os(tvOS)` gate or excluding `Screens/Detail/Phone/**` from SiloTV silently breaks the tvOS hero. |
| 1.9 | Subtitle sheets own each other's shared types | `Sheets/SubtitleTranslateMenu.swift` declares `SubtitleLanguageChoice`; `Sheets/SubtitleSearchMenu.swift` declares `TVSearchRow`; each consumes the other's | Move both into one small shared file under `Screens/Player/Sheets/`; `TVSearchRow` deserves a non-search name. |
| 1.10 | **`TVPlayerControls.applyHUDEntryPoint(_:)`** ignores its parameter | `Screens/Player/tvOS/TVPlayerControls.swift:~615`, call site ~164 | Switch collapsed to one arm; drop the parameter (and consider whether `TVHUDEntryPoint` still needs to be an enum with one case). |
| 1.11 | **Runtime-minutes formatting** copied 7× with 3 divergent outputs | `OverlayRegistry.swift:360`, `HomeFeedKit.swift:59`, `PhoneEpisodeFormatting.swift:56` = `TVEpisodeRail.swift:400`, `PhoneHeroMetadata.swift:231` = `TVDetailHero.swift:636`, `TVFocusMarquee.swift:173` | Collapse only the two byte-identical pairs onto shared helpers (`DetailFacts.swift` now exists as a home). Do **not** unify the `"m"` / `" min"` / dropped-zero variants — that is a visible change and should be a product decision. |
| 1.12 | Docs citing deleted symbols | `docs/tvos-player/04-tvos-controls-and-current-behavior.md:78, 179, 314` (`supportsBufferedAhead`); `docs/superpowers/specs/2026-06-15-tvos-detail-redesign-design.md:71` (`pillCornerRadius`); `docs/skyline-design-guide.md §5.5` (compact library marquee, stale since `0f4cc66`) | Keep the behavioural claims, drop the symbol names. |
| 1.13 | iOS/macOS carry tvOS-only `SettingsViewModel` members | `Screens/Settings/SettingsViewModel.swift` — `isAdmin`, `displayName`, `accountSubtitle`, `profileAvatar`, `resetSubtitleAppearance()` | Cost of the twin merge; harmless. Either accept, or `#if os(tvOS)` them. `TVSettingsView.swift:483` also keeps a now-unreachable `.isEmpty` guard. |

## 2. Larger deferred cleanups — need their own PR and/or an owner decision

### 2.1 Retire `ContinuumAPI`'s string-path dispatcher (~−360, medium risk)

`Networking/ContinuumAPI.swift:45–331` is a `// MARK: - Path-based dispatcher (legacy)` that
string-matches `/api/v1/...` and forwards to typed methods via `cast<T>()`/`requireBody`. There
are 24 call sites in ~8 files (fewer than before now that Watchlist/Favorites and the settings
VMs merged): `PersonalListGridView`, `SettingsViewModel`, `SearchViewModel`,
`TVLibraryGridViewModel`, `ItemDetailViewModel`, `CollectionDetailView`,
`CollectionsViewModel` (goes away with 1.1), `PlaybackSessionBridge`. Every path used already
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
`AVPlayerBackend.swift` **3,780** code lines — 15.2k of the player's 42.6k. Round 1 only trimmed
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
vs `Networking/ResponseCache`, and the remaining `Screens/Detail/Phone/` helpers that are in
fact platform-neutral. Rule of thumb from `docs/tvos-focus.md`: share models and formatting,
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
ignores `.claude/*` except `skills/`. Rules learned in round 1: keep packages file-disjoint;
split mechanical deletions from riskier refactors; fixers must reset their worktree to the
target branch's full SHA first (the harness worktrees start from `main`); run tests on cloned
simulators; treat "green" as the documented baseline, not zero failures.
