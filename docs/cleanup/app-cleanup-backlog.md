# App cleanup — backlog and watch list

Status as of 2026-08-17, after cleanup rounds 1–4 landed on `player/one-player-cleanup`
(round 1: `20f5aff` → `5f1f17d`; round 2: `155d9bc` → `e5360ae`; round 3: `a835b59` → `6267a5a`;
round 4: `702ce7d` → `1768542`). This is the list of what is still known to be removable, what was
deliberately left alone, and where a closer look is likely to pay off. Line references are
against `1768542`; re-grep before acting on any of them.

## 0. Where we are

**Update 2026-08-18 — player architecture remediation (branch `player/architecture-remediation`, on top of
`player/one-player-cleanup` @ `36393b4`).** An independent architecture review
(`docs/cleanup/player-review/2026-08-17-architecture-review.md`, slice evidence alongside) ranked 16 defects and
recommended a control-plane rewrite + narrowed loopback ("Option D"). Rounds so far:

| Round | Landed | Result |
|---|---|---|
| R1 (Stage 0/1 point fixes) | review §3 #1–#9, #11, #13–#16 + 73 characterization tests | suite 1346→1419 tests, 14 env failures unchanged |
| R2 (Stage 1 seams) | typed `PlaybackFailure` channel (VM string classifiers retired, oracle tests); V3 fixtures re-vendored from server `5fdb5d73` + `output_change` op; `silo://` scheme; dormant video-bridge tier + `.passthroughAV1` deleted (−2,185) | 1407 / 14 |
| R2b (brand) | full `continuum` → `silo` migration of every persisted / OS-registered / on-disk / wire literal with one-time migrations (§2.6 below); only `LegacyBrandKeys` still names the old brand | 1414 / 14 / 3 skipped |
| Server pairing | silo-server PR #670 `client_audio_track_selection_v1`; Apple advertises it, routes non-default audio to loopback, marks `progressive` unsupported on device (AVPlayer −12939) | 1419 / 14 / 3 skipped |
| Cleanup tail | dead client API/cache/legacy-quality surface; shared phone/tvOS similar-item loading and episode formatting; documentation truth pass | net −275 raw lines; local iOS/tvOS/macOS builds; focused 76 / 0; suite 1,524 / 2; shared-dev iOS/tvOS smoke |
| Round 5 (DRY/KISS/YAGNI survey, `0064fc8` → merge of eight `cleanup/*` branches) | second-generation survey (`.claude/workflows/app-cleanup-survey-v2.js`: Sonnet mechanical inventory → Opus finders → Opus skeptics → packager; 25 agents, 72 findings, 67 survived, 8 file-disjoint packages) then `app-cleanup-fix` (Opus implementer + independent Opus reviewer per package). Landed: video-bridge deletion residue (spec fields, writer callback, backend pinning) and the one-case `VideoOutputMode` enum; `PlayerTrack.selecting` (×4 rebuilds), throughput-probe `measure` helper (×9), constrained-device predicate (×4), `PlayerOnDeckItem` trimmed to what the view reads, seek-reanchor preamble (×3) and ETag validation (×2) shared; caption-appearance snapshot collapse (×10), renderer lock accessors (×6), session open/clear dedupe; subtitle-sheet language list, palette sampler, audio VM/engine dupes; phone/tvOS detail track/resume/next-up helpers hoisted onto `DetailPlaybackFormatting`/`DetailVersionSelection`/`TrackSelectionPersistence` (rules that were written out ×6), cast sections, tvOS 16 `#available` fallbacks; `loadCurrentProfile` (×4), `playAction` (×3), `refreshAuthState` → `AppRouter`, sign-out overlay (×3), `TVNavPreferences` alias file + no-op `#if` fork, write-only `AccentStrategy`; `HTTPClient` refresh tail (×2), `HostedDiagnosticsAPI` perform (×3), decode-only model fields, `PairingDeviceAPI` decoder reuse, `TVControlReceiver` idle-state/session-wipe (×2 each), `includeTechnical` knob, single-element `acceptedSchemes`; test plumbing (`TestPolling`, `TestHTTPStubSupport`, `ISOBoxTestTree`, tautological `LoopbackBufferPolicyTests`, test-only `activeQualityId`). Skipped by the implementers with evidence: `card-title-episode-badge-dupes` (`HomeFeedMeta` is `#if !os(tvOS)`), and `PlayerOnDeckItem.artworkUrl/Thumbhash` (read by `PlayerView.backgroundArtwork`). | 104 files, +1,148 / −2,231 raw (net −1,083); every package built Silo/SiloTV/SiloMac and ran the suite on a cloned sim at 1,525–1,526 / 14 env / 3 skipped |

Hardware records: `docs/tvos-player/validations/2026-08-17-*.yaml`, `2026-08-18-*.yaml` (HDR10 loopback + display
criteria validated on 08-17; DV rows blocked until PR #670 reaches the server the TV is on; **open**: an HDR10 loopback
`-11868/-17223` failure at anchor+21 s seen on 08-18 across all builds incl. a pre-R2 variant — display-path evidence
points at the TV/HDMI environment, unresolved). Still open from the review: Round 3 (Stage 2 control-plane extraction —
`PlaybackBackend` protocol, reducer/session actor, one `RecoveryPolicy` — behind a remote key that needs a silo-server
setting), #10 (needs the audio-index semantics on native-direct/HLS), #11 combined-index plumbing, macOS scene-phase
divergence, log-channel unification, six online-unreachable error rungs, and product decisions P1/P2 before Stage 3.
Skipped by design in R1: #10; the review's §12 lists rejected/narrowed claims.

**Round-5 deferred / refuted (for the next survey pass).** Deferred: `displayCapabilities:` planner argument the
planner never consumes (PVM ↔ `ApplePlaybackRoutePlanner`, file collision this round); two dead `TokenStore`
refresh overloads kept alive only by `SettingValuesAPITests` (a red-baseline file, §4.6); `VideoTrack` write-only
colour fields (collision with the bridge-residue package); the `NWListener` range-origin fake written three times in
tests (~−250, medium risk — needs the Retarget cursor/end recursion as the merged superset). Refuted and not to be
re-flagged: `ApplePlaybackRouteCapabilities` "unread" entries (it is the executable capability table, docs/05); the
×16 callback-generation guard (Stage 2 replaces it); the subtitle renderer primary/secondary twin (review §8 says do
not rewrite the renderer); `DiagnosticsJSONValue` vs `SettingJSONValue` (identical, but a merge crosses the
diagnostics/settings wire boundary — owner decision). Every finder reported zero orphan **types** in its slice after
a whole-repo identifier scan; what remains is repetition, not junk, and the big levers left are the gated ones
(review §9 Stage 2/3, §10 P1/P2).


Four rounds so far (survey → verify → file-disjoint packages, each implemented and independently
reviewed by Opus agents in isolated worktrees). Round 4 was the Continuum→Silo identifier rename
(303 files, net −47, no persisted/OS/wire string touched) plus 1.19. cloc, comments/blanks excluded:

| | Before round 1 | After round 1 | After round 2 | After round 3 |
|---|---|---|---|---|
| App Swift code (`iosApp/iosApp` + `TopShelf`) | 122,609 | 119,805 | 119,187 | **118,315** |
| Player (`Screens/Player`) | 43,323 | 42,564 | 42,540 | 42,212 |
| Tests | 34,567 (1,367 cases) | 34,412 (1,355) | 34,412 (1,355) | 34,234 (1,346) |
| `SiloAPI.swift` (née `ContinuumAPI.swift`) | 803 | | | 407 |

Total: **−4,294 code lines (−3.5%)**; raw git −6,705 / +924. Verification after each round:
`Silo`, `SiloTV`, `SiloMac` build; iOS suite at the same baseline (14 failures, all pre-existing —
see §4.6). The round-1 survey capped each of six slices at 12 findings, so the tail below every
slice's top-12 was **not** captured — a second survey pass will find more.

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

**Round 3 (2026-08-17, `a835b59` → `6267a5a`) closed 1.14–1.17:** `Route.collectionDetail` +
`CollectionDetailView` deleted; `CollectionsView.swift` → `LibraryCollectionsView.swift`;
`CollectionsResponse`/`CreateCollectionRequest` (+ `collections()`/`createCollection`/
`deleteCollection`/`collectionItems`) removed with the dispatcher; `TVLibraryGridView` header path
removed.

**Still open / newly exposed by round 3:**

| # | Item | Where | Notes |
|---|---|---|---|
| 1.18 | Divergent runtime formatters (3 styles) | `HomeFeedKit.swift`, `OverlayRegistry.swift`, `TVFocusMarquee.swift`, `HeroMetadata.swift` (`" min"`), `DetailFacts` (`"m"`) | **Product decision, not cleanup** — unify only if one output format is chosen for the whole app. |
| ~~1.19~~ | ~~`moveCollectionToGroup` + `UserCollection` + `UpdateUserCollectionGroupBody`~~ | | **Done in round 4.** |
| 1.20 | `generatedHLSSpillPolicy` reason string `"local_hls_event_playlist"` | `AVPlayerBackend.swift` | Log token only; the policy is live (VOD disk cache). Rename to something VOD-neutral if it bothers anyone. |
| 1.21 | Historical "Continuum" mentions in comments/docs | `DesignSystem/Aurora/AuroraTextField.swift:6`, `PlaybackRealtimeProtocol.swift:~452`, a few `docs/` pages | Prose only; left because rewriting them would make them factually wrong (they describe the old brand). Harmless. |

## 2. Larger deferred cleanups — need their own PR and/or an owner decision

### 2.1 ~~Retire `ContinuumAPI`'s (now `SiloAPI`) string-path dispatcher~~ — **done in round 3** (−484)
All 18 call sites retargeted to the existing typed methods with identical query defaults;
dispatcher, `pathComponents`/`queryInt`/`cast`/`requireBody`, `APIError.invalidPathParameter`/
`.unsupportedPath`, and the unreachable `startPlayback`/`startTranscode`/`history` +
`StartPlaybackRequest`/`TranscodeStartRequest`/`TranscodeStartResponse` removed. Only surface
delta: a malformed id is now 404'd by the server instead of rejected client-side (unreachable with
real ids). Leftover: 1.19.

### 2.2 ~~Legacy EVENT loopback serving mode + kill switch~~ — **done in round 3** (−462), with a correction
Retired: `LoopbackServingMode` (both cases), `primaryGateKey`/`gated`,
`LoopbackSessionSpec.servingMode`, `ApplePlaybackPlannerInput.siloPlayerPrimaryEnabled`, the three
gate-only planner blockers (`h264_loopback_startup_unreliable`,
`hevc_sdr_loopback_startup_unreliable`, `video_bridge_requires_vod_plan`),
`initialLoopbackTimelineOffset`, the backend's EVENT seek-teardown/reanchor path
(`reloadLocalLoopbackForSeek`, `localLoopbackReanchorReason`), the live-edge/bitrate
forward-buffer ladder (steady state is the flat 4 s VOD target — which it already was for every
default user), `writer.onTimelineAnchorResolved`, and 9 gate-only tests. Docs 01/02/03/05/08/09
note the retirement.

**Correctly NOT removed (this backlog's premise was wrong):**
- The writer's `vodActive == false` branches (`waitForGeneratedAheadIfNeeded`,
  `retireSegmentsBehindPlaybackIfNeeded`, live runway, sliding-playlist emission — ~33 sites) are
  a **live runtime fallback**, not the retired mode: `resolveVODPlanIfNeeded` degrades to a
  plan-less growing playlist whenever `harvestVODPlan()` returns nil (container duration ≤ 0,
  missing video stream, degenerate keyframe index) — log line "vod plan unavailable; degrading to
  EVENT serving". Retiring it means replacing the fallback with a typed failure that drops to the
  route ladder — a **behavior change needing an owner decision** (new item 2.5).
- `LoopbackSegmentStore` spill machinery (`SpillPolicy`, `spillSegmentToDisk`, `retireSegments`,
  `canAppendSegment`, `makeRoomForAppend`): `spillDirectory` is what `putVODSegmentOnDisk` writes
  into, and `generatedHLSSpillPolicy` always returns `.enabled`. Load-bearing for the VOD disk
  cache.

**Recommended on-device Apple TV pass** (status-quo coverage rather than regression hunt; the
default-user control flow is byte-identical): (1) DV Profile 7 title, run 2–3 min past the
initial-video gate, confirm `loopback buffer ramp forwardBuffer=4.0s` with no stall; (2)
high-bitrate remux with TrueHD→FLAC bridged audio resumed far mid-title (resume pre-seek + `vod
producer anchored`); (3) seek-heavy VOD session — far forward/back into never-produced regions,
expect `vod producer restart`, never a session teardown; (4) a bridged-codec title (VP9/AV1) to
confirm the removed `video_bridge_requires_vod_plan` blocker doesn't change the route; (5) any
title with unknown/zero container duration to exercise the surviving plan-less fallback.

### 2.3 ~~Route-capability blocker scaffolding~~ — **done in round 3** (−109), with a correction
`blockingReasons(for:)`, seven `needs*`/`keeps*` requirement fields, their trace tokens and the
PiP/external `degradationNotes` clauses removed; capability table + DV/Atmos claims kept; docs/05
updated. **Kept:** `needsSecondarySubtitles` — it is live (set from `session.subtitleUrls`, drives
the "secondary subtitles are sidecar-only" warning surfaced via `routeWarnings` →
`PlayerSettingsSheet`). Only visible delta: `decisionTrace`/`[CMP-ROUTE] requirements=` lose the
constant tokens `audio_selection`, `primary_subtitles`, `sidecar_primary_subtitles`, `chapters`,
`now_playing`.

### 2.4 `OverlayPrefsStore` legacy `card_overlays` fallback (~−55) — **not a cleanup**

Refuted in round 1: it is a deliberate degraded path for pre-contract servers (added in
`50409d1`, #118) with wire-format parity to the web `useOverlayPrefs.ts` hook. Removing it
changes behaviour on old servers. Only revisit as a coordinated server/web/Android decision to
drop pre-contract support.

### 2.5 The plan-less "degrade to EVENT serving" writer fallback (~−300 to −400, **behavior change**)

See 2.2. `LoopbackSegmentWriter` still carries the growing-playlist producer path for sources whose
container duration/keyframe index can't be harvested, plus the store's spill/eviction that path
uses. Retiring it would (a) turn "vod plan unavailable" into a typed planner/backend failure that
falls to the next route rung (server HLS), (b) delete the ~33 `vodActive == false` branches and the
EVENT-only store helpers, (c) need a device pass on such a source. Decide whether "unknown
duration → server HLS instead of local growing playlist" is acceptable; if yes it is the last big
lever in the writer.

### 2.6 Continuum brand keys that are persisted / OS-registered / on the wire (**migration, not cleanup**)

Round 4 renamed every *code identifier* to Silo (`SiloAPI`, `SiloAI`, `SiloTheme`, `Color.silo*`,
`Font.silo*`, `Silo*ButtonStyle`, `SiloTextFieldStyle`, `SiloMacPlayerView`, `Silo*Transport`, the
`silo*` view modifiers, in-process `Notification.Name`s, the `SiloKeychainAccessGroup` /
`SiloUsesUserIndependentKeychain` plist keys, os_log subsystem `org.siloserver.silo`, dispatch-queue
labels, tvOS press tags, "Loading Silo"). These 29 literals were **deliberately kept** because
changing them either breaks existing installs or needs the server/Android side:

| Kind | Literals | Why kept / what a migration needs |
|---|---|---|
| Keychain service + accounts | `com.continuum.app` (service), `com.continuum.<serverID>.accessToken/.refreshToken/.profileToken/.accountEpoch`, `com.continuum.app.accessToken/.refreshToken/.profileToken`, `com.continuum.device.identity`, `com.continuum.serverRegistry.v2`, `com.continuum.topshelf.accessToken/.profileToken`, `com.continuum.diagnostics.hosted.installationID/.installationToken` | Renaming logs every user out and drops the tvOS server registry. Needs a one-time read-old/write-new/delete-old migration in `SharedKeychain`/`TokenStore` + Top Shelf, and TestFlight continuity (CLAUDE.md). |
| UserDefaults keys | `continuumServerRegistry.v1`, `continuumServerRegistry.migrated.v1` | Same shape of migration; `ProfileLaunchPolicyTests` asserts on the v1 key. |
| OS-registered ids | BGTask `com.continuum.play.downloads-refresh` (also in Info.plist), background `URLSession` `com.continuum.play.downloads` | Renaming orphans in-flight downloads on upgrade; needs plist + code together and a "resume old session id once" shim. |
| URL scheme | `continuum` (CFBundleURLSchemes, both plists) and the `continuum://item|play|downloads` builders/parsers | Server push payloads / Top Shelf / Home Screen use it. Add `silo` as a second scheme first, migrate senders (silo-server, silo-android parity), keep `continuum` for a deprecation window. |
| On-disk names | `continuum-source-cache`, `continuum-dv-hls`, `continuum-dv-hls-debug`, Nuke `DataCache(name: "com.continuum.app.apple.posters")` | Renaming orphans existing caches (GBs on tvOS). Needs a one-time delete-old-dir. |
| Wire values | realtime client names `continuum-ios` / `continuum-tvos` / `continuum-macos` (`X-Silo-Client` product names, `PlaybackRealtimeProtocol.swift`) | Server stores/keys on them — coordinate with silo-server before changing. |

**Resolved (R2b-brand-migration).** The owner decided the old brand must not exist anywhere in the
Apple clients, so every row above was migrated rather than merely renamed. The table stays as the
record of what the migrations read *from*; the only surviving occurrences in code are the
`LegacyBrandKeys` constants in `iosApp/iosApp/Shared/SharedStorage.swift`, which are read-only
migration sources. What landed:

- **Keychain** — service is `org.siloserver.silo`, accounts are `org.siloserver.silo.<…>`.
  `SharedKeychain.get` falls back on a read-miss to the pre-rename service + account (one prefix
  swap), copies the item forward with the same audience/accessibility, and deletes the old copy
  only after the new write confirms; `SharedKeychain.delete` drops both so sign-out cannot be
  undone by a later migration. Top Shelf and the notification service compile the same file, so
  they migrate the mirrored slots themselves if they run first. `ServerRegistry`'s pre-multi-server
  migration keeps reading `com.continuum.app.{access,refresh,profile}Token` — through the
  pre-rename service, which is where they actually live.
- **UserDefaults** — `siloServerRegistry.v1` / `.migrated.v1`, with a one-shot copy-then-remove of
  the pre-rename keys before the registry loads.
- **OS-registered ids** — BGTask `org.siloserver.silo.downloads-refresh` (plist + code together,
  plus a `cancel(taskRequestWithIdentifier:)` of the old id), background `URLSession`
  `org.siloserver.silo.downloads`. The old session is opened once and `invalidateAndCancel`ed
  rather than adopted: task identifiers are unique only within one `URLSession` and download events
  are keyed by that integer alone, so two live sessions could misroute a transfer. Records whose
  persisted task id no longer matches are re-queued by `reconnectActiveTasks`, i.e. an in-flight
  transfer restarts instead of resuming.
- **URL scheme** — `silo` only, in both plists and `SiloDeepLink`; the old scheme is rejected.
- **On-disk names** — `silo-source-cache`, `silo-dv-hls`, `silo-dv-hls-debug`, Nuke
  `org.siloserver.silo.posters`; the orphan sweep deletes the old trees wholesale and the poster
  cache deletes its old sibling directory.
- **Wire values** — `silo-{ios,tvos,macos}`. silo-server stores whatever the client announces and
  only checks it is non-empty (no occurrence of the old names in its Go code), so no coordination
  was needed.

## 3. Intentionally kept — don't re-flag without new information

- `LoopbackSegmentWriter` throughput probe (`traceThroughput`, `ThroughputTiming`, 11 timed/untimed
  branch pairs, ~100 lines): opt-in field diagnostic (`SILO_TRACE_DV_THROUGHPUT` /
  `player.apple.loopback_trace_throughput`) that identified the 2026-07-05 ingest ceiling; gated
  the same way as the sibling `SILO_TRACE_DV_SEGMENTS` probe. If it stays, the duplicated call
  bodies could collapse onto one `measure(into:)` helper — but that's a refactor, not a deletion.
- `PlayerTaskRegistry.Key.protocolV3Replan`: live (single-flight guard in the VM) despite looking
  unused to a naive grep.
- Keychain/registry migrations, `SiloControl` v1 peer compatibility, and the onboarding
  legacy-suppression record: TestFlight-continuity and user-data paths, deliberately not surveyed.

## 4. Areas worth a closer look (not yet surveyed for deletion, or needing a different brief)

### 4.1 The three files that are a third of the player
`PlayerViewModel.swift` **6,269**, `LoopbackSegmentWriter.swift` **5,145**,
`AVPlayerBackend.swift` **3,635** code lines — 15.0k of the player's 42.2k. Rounds 1–3 trimmed
write-only state and the EVENT kill-switch arms; the "delete dead code" brief cannot make them
much smaller. What would: (a) §2.5 (plan-less fallback) takes the next real bite out of the writer;
(b) the VM still hosts several
distinct concerns behind `// MARK:` fences (route planning glue, subtitle sink adapter, HUD/entry
points, stats enrichment, task registry, live-subtitle diagnostics) — a structural pass would
extract these along existing seams rather than "split by size"; (c) `AVPlayerBackend` lost its EVENT-only
seek/live-edge logic in round 3; what remains is the VOD recovery ladder. Treat any structural pass as a
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

### 4.4 `SiloAPI` (formerly `ContinuumAPI`) surface after §2.1
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
ignores `.claude/*` except `skills/`. Rules learned in rounds 1–4: keep packages file-disjoint;
split mechanical deletions from riskier refactors; fixers must reset their worktree to the
target branch's full SHA first (the harness worktrees start from `main`); run tests on cloned
simulators; treat "green" as the documented baseline, not zero failures; and expect the implementers to
push back on a brief — three times in round 3 the brief's premise was wrong (`vodActive` fallback,
store spill, `needsSecondarySubtitles`) and the agents kept the live code and said so.
