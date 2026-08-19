<!-- Stage 2 inventory, generated 2026-08-19 by a read-only mapping agent at 20ba06b/acc3004; line anchors are from that tip. -->

# Track/subtitle half of `PlayerViewModel` — inventory for Stage 2

**Anchoring.** Repo root `/Volumes/NVMe/dev/github/SiloServer/silo-apple`. Branch `player/architecture-remediation`, **HEAD is `acc3004`** (`20ba06b` is the round-6 merge two commits back). All line numbers below were re-derived at `acc3004`; the review doc's numbers are stale.

**Path legend** (absolute; short aliases used below for density):
- `PVM` = `/Volumes/NVMe/dev/github/SiloServer/silo-apple/iosApp/iosApp/Screens/Player/PlayerViewModel.swift` (8007 lines)
- `bridge` = `/Volumes/NVMe/dev/github/SiloServer/silo-apple/iosApp/iosApp/Screens/Player/PlaybackSessionBridge.swift`
- `backend` = `/Volumes/NVMe/dev/github/SiloServer/silo-apple/iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift`
- `planner` = `/Volumes/NVMe/dev/github/SiloServer/silo-apple/iosApp/iosApp/Screens/Player/ApplePlaybackRoutePlanner.swift`
- `adapter` = `/Volumes/NVMe/dev/github/SiloServer/silo-apple/iosApp/iosApp/Screens/Player/ProtocolV3/ApplePlaybackV3PlanAdapter.swift`
- `resolver` = `/Volumes/NVMe/dev/github/SiloServer/silo-apple/iosApp/iosApp/Screens/Player/PlaybackPrefsResolver.swift`
- `SUB/` = `/Volumes/NVMe/dev/github/SiloServer/silo-apple/iosApp/iosApp/Screens/Player/Subtitles/`
- `P/` = `/Volumes/NVMe/dev/github/SiloServer/silo-apple/iosApp/iosApp/Screens/Player/`
- `M/` = `/Volumes/NVMe/dev/github/SiloServer/silo-apple/iosApp/iosApp/macOS/`
- `T/` = `/Volumes/NVMe/dev/github/SiloServer/silo-apple/iosApp/Tests/`

---

## 0. Shape of the slice

`PVM:5536–8007` is **not** contiguous track code. Track-half code inside it totals **1421 of 2472 lines**, in 16 runs:

```
5541-5706  selection commands + persistence      6901-7008  apply funnels + breadcrumbs
5714-5723  AI subtitle forwarders                7009-7065  live-AI seam (backend forwarders)
5726-5892  provider search + handoff context     7067-7193  appendSidecarTracks
5893-5916  ProtocolV3SidecarRestoreIntent        7201-7305  applyTrackList
5938-5972  pending-intent + url filter statics   7306-7319  bestTrackMatch
5989-6028  registerCompletedAISubtitle           7320-7464  auto-prefs / system policy / replan
6030-6168  live AI bridge (M4)                   7856-8007  coordinator adapters
6170-6212  cycle/toggle
6818-6900  loadPendingExternalSubtitles
```

Interleaved **non-track** code that must stay on the VM: `isCurrentStreamCallback`/`isUnexpectedBackwardPlaybackTime` (5918-5936), chapters/controls/HUD (6213-6302), `cleanup`/`waitForCleanupCompletion` (6303-6443), realtime event+command (6444-6654), stream request/route helpers (6656-6817), progress + scheduleHideControls + suspend/resume (7466-7655), SiloControl extension (7692-7854).

Additional track-half code **outside** 5536-8007: `PVM:195-207` (published lists/ids), `:200` `subtitleOrderingLanguage`, `:399-427` (ordering projections), `:413-426` `orderedSubtitles`, `:493-508` `subtitleAI` lazy init, `:555-569` `makeLiveSubtitleCoordinator`, `:724-828` (state block), `:1062-1076` system-caption observer, `:1194-1205` `wireSubtitleCallbacks`, `:1334-1342` `onTracksChange`, `:2210-2246` route-recovery snapshot/restore, `:2360-2364` planner input, `:2502-2529` `applySidecarRestoreIntent`, `:2554-2568` + `:2590-2607` adopt, `:3160-3221` appearance funnels, `:3502-3546` reset, `:3549-3641` resume resolvers + V3 intent arming, `:3846-3860` initial-prefs → wire, `:4147-4149` renewal, `:5201-5214`/`:5277` transcode-restart snapshot, `:6330-6336` cleanup clears, `:6764-6766` fallback loopback spec.

---

## 1. Stored state (who writes / who reads)

### 1a. Published (views read these; `@Observable`, no `@Published`)
| Decl | Field | Writers | Readers |
|---|---|---|---|
| PVM:195 | `audioTracks: [PlayerTrack]` | `applyTrackList` :7202; `resetPublishedLoadState` :3502 | views (4 files), `persistAudioSelection`, breadcrumb :6963, `cycleAudioTrack`, `resolvedAudioTrackIndexForResume`, SiloControl :7727 |
| PVM:196 | `subtitleTracks: [PlayerTrack]` | :7228 (applyTrackList), :7112 (appendSidecar), :7041 (appendLive), :6065 (removeLiveRow), :3503 (reset) | views (4 files), `orderedSubtitles`, resolvers, `selectLiveSubtitleTrack`, `restoreLiveSubtitleSelection` |
| PVM:205 | `selectedAudioId: Int64?` | :5544 user, :7239 AVF-reported, :7248 pending-ff, :7275 fuzzy, :3519 reset | views, `makeExecutionPlan` :2360, `resolvedAudioTrackIndexForResume` :3550, `applyAutoSubtitlePreferencesIfNeeded` :7331 |
| PVM:206 | `selectedSubtitleId: Int64?` | 13 sites: :5575, :5608, :7123, :7136, :7166, :7185, :7232, :7241, :7259, :7265, :7284, :7427/:7433, :7456; :3520 reset | views, resume resolvers :3562/:3578/:3590, snapshots :2221/:5210, coordinator `selectionSnapshot` :566 |
| PVM:207 | `selectedSecondarySubtitleId: Int64?` | :5572, :5605, :5694, :5702, :7144, :7236, :7293, :3521 | views (2), `makeExecutionPlan` :2364, snapshot :5203 |

### 1b. The eight `pending*` fields + flags (all `private`)
| Decl | Field | Written by | Read/consumed by |
|---|---|---|---|
| :724 | `pendingExternalSubtitles: [SubtitleUrl]` | :2241 route-recovery, :2590 adopt, :4147 renewal, :6824 (drain) | :6819-6822 `loadPendingExternalSubtitles`, log :1521 |
| :728 | `knownExternalSubtitles: [SubtitleUrl]` | :2242, :2591, :4148, :6003 (AI register), :3531/:6330 clear | :2217/:5201 snapshots, :6821 restore-from-cache |
| :766 | `pendingRecoveredAudioSelection: TrackSelectionSnapshot?` | :2243, :3532/:6333 clear | :7271-7278 `applyTrackList` fuzzy |
| :767 | `pendingRecoveredSubtitleSelection: TrackSelectionSnapshot?` | :2244, :2604 (transcode restart), :3533/:6334 | :7280-7287 embedded fuzzy; :7159-7172 sidecar fuzzy |
| :768 | `pendingRecoveredSecondarySubtitleId: Int64?` | :2245, :2606, :3534/:6335 | :7140-7147 (sidecar), :7289-7296 (embedded) |
| :773 | `pendingAudioFfIndex: Int?` | :3538 reset, :3638 V3 arm, :5543 (cleared by user), :7246 | :2362 planner input, :6766 fallback spec, :7244 match |
| :774 | `pendingSubtitleFfIndex: Int?` | :3539, :3639, :5570/:5603 (cleared by user), :7257/:7263 | :7253-7269 (incl. `<0` = explicit Off) |
| :778 | `hasExplicitSubtitleChoice: Bool` | :3541 (derived from 3 request fields), :2246, :2605, :3216 (**cleared by appearance toggle**), :5569/:5602 (set by user) | :1072, :3617, :3847 (wire intent), :7150, :7169, :7181, :7321, :7355 |
| :782 | `pendingSidecarSubtitleTrackId: Int64?` | :3540, :3640, :2512/:2515, :6019 (AI autoselect), :7119 | :7118-7130 appendSidecar |
| :787 | `pendingServerRenderedSubtitleTrackId: Int64?` | :2513/:2516/:2520, :3535/:6336, :7133 | :7132-7138 appendSidecar (picker-only, no local open) |
| :794 | `pendingLiveSubtitleCloseTrackId: Int64?` | :6084 arm, :6092/:6106 consume, :6332 cleanup | :6081, :6091, :6105 |
| :798 | `deferredLiveSubtitleCloseTask` (task-registry backed, key `.deferredLiveSubtitleClose`) | :6085 | :6107 |
| :807 | `prefsForCurrentItem: PrefsSnapshot?` (struct :808-819) | :1073, :2240, :2564, :3217, :3618, :3545, :7358 | :7321 |
| :821 | `prefsResolvedForCurrentItem: Bool` | :1074, :3220, :3546, :3619, :7328, :7350, :7359 | :7322 |
| :200 | `subtitleOrderingLanguage: String?` | :1070, :2555, :3213, :7356 | :414 only (display projection) |
| :577 | `liveSubtitlePreparingNoticeId: UUID?` | :6143, :6152 | :6151 |
| :515/:520 | `realtimeConnectedSnapshot` / `realtimeUnavailableSnapshot` | realtime observers :1030-1050 | :527 `subtitleAILiveOverlayAvailable` |

`TrackSelectionSnapshot` (struct PVM:729-765): 7 normalized attributes + `score(against:)` :748-759 (title 4, lang 3, codec 2, layout 2, forced/external/HI 1 each); threshold `>= 3` at `bestTrackMatch` PVM:7316.

### 1c. Appearance state is **not** on the VM
It lives on `PlayerSettings.shared` (`P/PlayerSettings.swift`): `subtitleAppearance` :230, `subtitleUsesDeviceAppearanceOverride` :249, `subtitleMatchesSystemAppearance` :262, `subtitleSystemSelectionPreferences` :274, `effectiveSubtitleAppearance` :277, `subtitleSyncMs` :291. The VM owns only the funnels `PVM:3159-3221` and the coupling at :3216.

### 1d. Sub-objects owned by the VM
- `subtitleAI: SubtitleAIController` — `PVM:493-508` lazy, `@ObservationIgnored`, built inside `MainActor.assumeIsolated`. 7 closures capture VM state: `mediaFileId`, `currentTime`, `sessionId`, `realtimeUnavailable`, `handoffContext`, `registerAndSelectDescriptor`, `registerDescriptorWithoutSelecting`.
- `LiveSubtitleCoordinator` — built in `makeLiveSubtitleCoordinator` PVM:555-569, handed to `subtitleAI`; VM never calls it directly.
- `LiveSubtitlePlaybackAdapter` (PVM:7863-7877) / `LiveSubtitleSinkAdapter` (PVM:7879-8007) — `fileprivate final class`, hold `weak var owner: PlayerViewModel`. Sink owns its own state: `converters [String: LiveSubtitleTrack]`, `ordinals [String: Int]`, `nextOrdinal`, `installedTrackId`, `installedTrackKey`, `diagCueLogBudget`.

---

## 2. Track-selection decision sites (now ~20, not 11)

**Audio**
1. `bridge:444-445` — `resolvedAudioTrackIndex = preferredAudioTrackIndex ?? selectedVersion.effectiveAudioTrackIndex`; decides the wire intent before any plan exists.
2. `PVM:3629-3641 armAdoptedProtocolV3TrackIntent` ← `protocolV3PendingTrackIntent` PVM:5944-5958 — server plan's `selectedTracks.audio?.index` becomes `pendingAudioFfIndex`.
3. `PVM:7244-7251 applyTrackList` — matches `pendingAudioFfIndex` against `planner.audioSelectionIndex(for:)`; applies with reason `"pending_audio_index"`.
4. `PVM:7239` — unconditional adoption of whatever AVFoundation reports selected (`audioTracks.first(where: \.isSelected)`), *before* the pending match runs.
5. `PVM:7271-7278` — fuzzy `TrackSelectionSnapshot` restore, reason `"restored_selection"`.
6. `planner:1028-1049 resolveLoopbackSelectedAudioTrack` — independent chain (`selectedAudioTrackId` → `pendingAudioFfIndex` → `preferredAudioTrackIndex` → `isDefault` → `.first`) used to build the loopback mux spec; inputs supplied at `PVM:2360-2363` and `PVM:6764-6766`.
7. `backend:1450-1508 selectAudioTrack` — on loopback rebuilds the whole `LoopbackSessionSpec` (a stream restart); on AVF selects the media option.
8. User: `PVM:5541 selectAudio`, `PVM:6170 cycleAudioTrack`, `PVM:7725-7731` (SiloControl LAN remote).

**Subtitles**
9. `bridge:523-623 initialProtocolV3SubtitleIntent` (called :449) — pre-wire. Explicit combined index wins (:539-544); else explicit ffIndex → translated (:546-554); else synthesizes `PlayerTrack` candidates from `version.subtitleTracks` (:556-588, external ordinals minted here) and runs `SubtitleAutoResolver.resolve` (:589); `.noChange` is *frozen* into a concrete pick — `isDefault` else `isForced` (:611-612).
10. `PVM:3629-3641` — plan intent: `embeddedSubtitleIndex` = `request.preferredSubtitleTrackIndex` when `plan.subtitle.mode == "render"`, else the `-1` "Off" sentinel; `sidecarSubtitleTrackId` likewise (PVM:5949-5955).
11. `PVM:2502-2529 applySidecarRestoreIntent` ← static `protocolV3SidecarRestoreIntent` PVM:5898-5915 — 3-way: `.renderLocally` / `.serverRendered` / nil, keyed on `subtitleMode ∈ {"render","burn_in"}` and snapshot ↔ `plan.selectedTracks.subtitle?.index` equality.
12. `PVM:7253-7269 applyTrackList` pending-ff: `< 0` ⇒ explicit Off (`"pending_subtitle_off"`); else match `embeddedSubs.ffIndex` (`"pending_subtitle_index"`).
13. `PVM:7241` — adopt AVF/extractor-reported `isSelected`.
14. `PVM:7280-7287` — embedded fuzzy restore.
15. `PVM:7289-7296` — secondary restore against embedded rows.
16. `PVM:7118-7130 appendSidecarTracks` — `pendingSidecarSubtitleTrackId` → select (`"restored_sidecar_selection"`), then `performDeferredLiveSubtitleCloseIfNeeded()` (M5 seamless swap).
17. `PVM:7132-7138` — `pendingServerRenderedSubtitleTrackId` → sets `selectedSubtitleId` **without** an apply call (picker-only).
18. `PVM:7159-7172` — sidecar fuzzy restore (`"restored_selection_as_sidecar"`), gated by `!subtitleMatchesSystemAppearance || hasExplicitSubtitleChoice` at :7150/:7169.
19. `PVM:7173-7188` — **forced-sidecar auto-select** (`"forced_sidecar_auto"`), guarded by `!subtitleMatchesSystemAppearance && !hasExplicitSubtitleChoice && selectedSubtitleId == nil`. Contradicts the shared resolver's rule at `resolver:166-177`.
20. `PVM:7320-7352 applyAutoSubtitlePreferencesIfNeeded` → `SubtitleAutoResolver.resolve` (`resolver:95`) → `PVM:7420-7440 applyAutoSubtitle` (reason `"auto_preference"`). Called from :7190 (appendSidecar), :7303 (applyTrackList), :1076 (system-caption notification), :3221 (mode toggle), :7361 (`reapplySystemSubtitlePolicy`).
21. `PVM:7442-7464 replanAutomaticProtocolV3SubtitleSelection` — on V3, converts an automatic verdict into a server replan instead of a local apply; writes `selectedSubtitleId` and `lastLoadRequest?.preferredProtocolV3SubtitleIndex` first.
22. `PVM:7354-7361 reapplySystemSubtitlePolicy` — **called from `selectAudio` :5546**, so every audio change can move subtitles.
23. `backend:4264 loadMediaSelectionGroup(for: .legible)` + `backend:4356 group.defaultOption` — AVPlayer's own default; no `appliesMediaSelectionCriteriaAutomatically = false` anywhere in the tree.
24. `SUB/LiveSubtitleCoordinator.swift:328-334` (`installLiveTrack` + `selectLive`) and `:501-504` (`closeLiveTrack` + `restorePriorSelection`), via the sink adapter → `PVM:6041/:6048/:6114`.
25. `PVM:6017-6020 registerCompletedAISubtitle` — `autoSelect` seeds `pendingSidecarSubtitleTrackId`; the M5 `subtitle_ready` broadcast path passes `autoSelect: false` (PVM:504).
26. `PVM:6093-6095` — deferred-close fallback timer disables subtitles if the persisted selection never lands within 5 s.
27. User: `PVM:5567 selectSubtitle`, `:5600 disableSubtitles`, `:5688/:5699` secondary, `:6182 cycleSubtitleTrack`, `:6204 toggleSubtitles`, `:7733-7740` SiloControl.

**Suppression:** every user entry point is `guard !isBackgroundSuspended else { return }` (PVM:5542, 5568, 5601, 5689, 5700, 6171, 6183, 6205) — selections made while tvOS-suspended are silently dropped.

---

## 3. The three (really four) index spaces

1. **FFmpeg stream index** — `SubtitleTrack.index`, `PlayerTrack.ffIndex`, and the low bits of `SubtitleTrackIdSpace.avPlayerEmbeddedBase` ids. Minted at `SUB/AVPlayerEmbeddedSubtitleExtractor.swift:54-55` (sets **both** `ffIndex` and `srcId` to the stream index).
2. **Server combined ordinal** — dense, **external-first**, over embedded+external+downloaded (`P/ProtocolV3/PlaybackProtocolV3Models.swift:385-390`). Carried by `SubtitleUrl.index`, `PlaybackV3SubtitleInventoryItem.combinedIndex`, sidecar `PlayerTrack.srcId`, and the low bits of `sidecarBase` ids.
3. **AVMediaSelection ordinal** — synthesized at `backend:4295-4311` (`optionsByTrackId[makeTrackId(kind:index:)]`) with bases `10_000` audio / `20_000` legible (`backend:4368-4380`). These rows carry `ffIndex: nil, srcId: nil` (`backend:4362-4363`).
4. **Audio array ordinal** — `PlayerTrack.srcId` for audio, minted from `(version.audioTracks ?? []).enumerated()` at `planner:1006-1007`/`:1139`.

**Translations:**
- combined ← ffIndex: `adapter:214-232 serverCombinedSubtitleIndex(ffmpegStreamIndex:in:)` — `externalCount + embeddedOrdinal`, over `partitionedSubtitleTracks` `adapter:207-212`. Callers: `bridge:549`, `bridge:638`, `T/PlaybackProtocolV3Tests.swift:589/596/603`.
- combined ← `PlayerTrack`: `adapter:234-246 serverCombinedSubtitleIndex(for:in:)` — external branch **passes `srcId` through untranslated**; embedded branch delegates. Callers: `bridge:619`, `PVM:3583`, `PVM:7450`.
- ffIndex ← combined: `adapter:248-259 ffmpegSubtitleStreamIndex(serverCombinedIndex:in:)`. Callers: `PVM:899` (`LoadRequest.adoptingProtocolV3Intent`), `PVM:7082` (appendSidecar shadowing), `PVM:7210` (applyTrackList shadowing).
- track ← combined: `adapter:374-383 subtitleTrack(atServerCombinedIndex:in:)` (private, used at `adapter:160`).
- audio: **no adapter translation** — `adapter:194` copies `plan.selectedTracks.audio?.index` straight into `PlaybackSessionResponse.audioTrackIndex`, matched against `srcId` at `planner:348/:360`, `P/PlaybackExecutionPlan.swift:185`, `backend:1453`. `planner:1052-1054 audioSelectionIndex(for:) = track.srcId ?? track.ffIndex` merges spaces 4 and 1 behind one `Int?`; used at `PVM:5649`, `PVM:3552`, `PVM:6963`, `PVM:7245`.
- trackId ↔ ordinal: `SUB/SubtitleTrackIdentity.swift:42-96` (`avPlayerEmbeddedBase 0x2000_0000`, `sidecarBase 0x4000_0000`, `aiLiveBase 0x6000_0000`); `isSyntheticNonEmbedded` :94 gates both recovery snapshots (PVM:2227, PVM:5213).
- `srcId` overload is documented and now defensively gated: `SUB/SubtitleAIController.swift:282-296 translationSourceIndex` refuses non-sidecar tracks (the slice-5 "lossy #1" finding is fixed).

---

## 4. Dependency surface: core ⇄ track half

**Core → track half (call edges):**
| Core site | Calls | Purpose |
|---|---|---|
| PVM:1203 (`wireSubtitleCallbacks`, :1194) | `appendSidecarTracks` | backend `onSidecarTracksRegistered`, generation-gated by `isCurrentStreamCallback` |
| PVM:1341 (`makeCallbacks`, :1211) | `applyTrackList` | backend `onTracksChange`, same gate |
| PVM:1076 (system-caption observer, :1062) | `applySubtitleAppearanceToPlayer`, `applyAutoSubtitlePreferencesIfNeeded(force:)` | writes `subtitleOrderingLanguage`, `prefsForCurrentItem`, `prefsResolvedForCurrentItem` |
| PVM:1519 (`handleFileLoaded`) | `applySettingsToPlayer` :3159, `loadPendingExternalSubtitles` :6818 | per-load registration |
| PVM:2210-2246 (`attemptNativeDirectRouteRecovery`) | `resolvedAudio/Subtitle/SidecarTrackIndexForResume`, then re-seeds 6 fields after `resetPublishedLoadState` | offline-only ladder |
| PVM:2360-2364 (`makeExecutionPlan`) | reads `selectedAudioId`, `pendingAudioFfIndex`, `resolvedAudioTrackIndexForResume()`, `selectedSubtitleId`, `selectedSecondarySubtitleId` | planner input |
| PVM:2554-2568, :2590-2607 (`adoptPreparedPlayback`) | `systemCaptionPrefsSnapshot`/`serverSubtitlePrefsSnapshot`, `adoptProtocolV3RenewalIntent`, `applySidecarRestoreIntent` | three restore mechanisms armed together |
| PVM:3216 (`setSubtitleMatchesSystemAppearance`) | clears `hasExplicitSubtitleChoice` | appearance→selection coupling |
| PVM:3502-3546 (`resetPublishedLoadState`) | clears/seeds 11 track fields | called from :2231 and :3695 |
| PVM:3596-3621 (`adoptProtocolV3RenewalIntent`) | `armAdoptedProtocolV3TrackIntent` :3629 | + latches `prefsResolvedForCurrentItem = true` when explicit |
| PVM:3643-3658 (`makeSuspendedPlaybackContext`) | the three `resolved*ForResume` | tvOS suspend |
| PVM:3846-3860 (`runStartSession`) | `systemCaptionPrefsSnapshot()` → `InitialProtocolV3SubtitlePreferences` | only when `subtitleMatchesSystemAppearance && !hasExplicitSubtitleChoice` |
| PVM:1642-1643 (`attemptProtocolV3Replan`) & PVM:5257-5258 (`restartCurrentTranscodeHLS`) | `resolvedAudioTrackIndexForResume`, `resolvedProtocolV3SubtitleIndexForResume` | wire intent for the replan |
| PVM:4147-4150 (`attemptBackgroundSessionRenewal`) | re-seeds `pendingExternalSubtitles`, calls `loadPendingExternalSubtitles` | silent renewal |
| PVM:6330-6336 (`cleanup`) | `subtitleAI.reset()` + clears 5 pending fields | teardown |
| PVM:6479 (`handleRealtimeEvent`) | `subtitleAI.handle(_:)` | 4 realtime event names |
| PVM:6764-6766 (`makeFallbackLoopbackSession`) | `resolvedAudioTrackIndexForResume() ?? pendingAudioFfIndex` | |

**Track half → core (reads), counted only over the 16 track runs:**
`avPlayerBackend` ×10 (6027, 6864, 6903, 6914, 7006, 7015, 7026, 7032, 7868, 7869) · `activeRouteKind` ×11 (5864, 5995, 6827, 6832, 6862, 6867, 6881, 6888, 6911, 6963, 6990) · `currentSelectedVersion` ×9 (5652, 5672, 5740, 5776, 5799, 5811, 7077, 7204, 7444) · `activePreparedProtocolV3` ×8 (5547, 5580, 5611, 5873, 6876, 6877, 7443, 7452) · `isBackgroundSuspended` ×8 · `scheduleHideControls` ×8 · `backendCapabilities` ×7 · `settings.` ×7 (7150, 7169, 7180, 7191, 7355, 7356, 7364) · `currentTime` ×5 (5556, 5589, 5619, 7459, 7944) · `attemptProtocolV3Replan` ×4 (5555, 5588, 5618, 7458) · `resolveServerUrl`/`resolvedServerUrl` ×3 · `activeNotice` ×3 (6143, 6153, 6156) · `currentWatchDetail` ×3 (5635, 5667, 7446) · `activePlaybackSessionId` ×2 (5739, 5868) · `lastLoadRequest` ×1 (7457) · `protocolV3ReplanTask` ×1 (7445) · `offlinePlaybackContext` ×1 (5635) · `isPlaying` ×1 (7870).

No generation counter (`streamLoadGeneration`, `freshLoadGeneration`) is read inside the track half — the gating happens in the two callback closures (PVM:1197-1202, :1335-1340).

---

## 5. Public API the views use

Callers: `M/PlayerView.swift`, `M/MacPlayerOptionsPanel.swift`, `M/MacPlayerControls.swift`, `P/Sheets/PlayerSettingsSheet.swift`, `P/Sheets/SubtitleSearchMenu.swift`, `P/Sheets/SubtitleTranslateMenu.swift`, `P/tvOS/TVPlayerInfoHUD.swift`, `P/tvOS/SubtitleAppearanceDialog.swift`, `P/iOS/MobilePlayerControls.swift`, `/Volumes/NVMe/dev/github/SiloServer/silo-apple/iosApp/iosApp/Control/tvOS/TVControlReceiver.swift`.

**Referenced by ≥3 files (must stay as forwarding members on the VM):** `audioTracks` (:195), `subtitleTracks` (:196), `orderedSubtitleTracks` (:405), `selectedAudioId` (:205), `selectedSubtitleId` (:206), `availableSecondarySubtitleTracks` (:408), `selectAudio(_:)` (:5541), `selectSubtitle(_:)` (:5567), `disableSubtitles()` (:5600), `subtitleSearchEnabled` (:5757), `subtitleSearchUnavailableReason` (:5766).

**Referenced by 2 files:** `selectedSecondarySubtitleId` (:207), `supportsSecondarySubtitles` (:400), `selectSecondarySubtitle(_:)` (:5688), `disableSecondarySubtitles()` (:5699), `hasTrackSelectionOptions` (:399), `subtitleSearchVisible` (:5738), `setSubtitleSyncMilliseconds(_:)` (:3259), `setSubtitleMatchesSystemAppearance(_:)` (:3210), `setSubtitleDeviceOverrideEnabled(_:)` (:3204), `mutateSubtitleAppearance(_:)` (:3184).

**Single-file:** `cycleAudioTrack` (:6170), `cycleSubtitleTrack` (:6182), `toggleSubtitles` (:6204) — all `M/PlayerView.swift` keyboard shortcuts; `searchSubtitles` (:5775), `downloadSearchedSubtitle` (:5798) — `SubtitleSearchMenu`; `subtitleAI` (:493), `startSubtitleTranslation` (:5714), `startSubtitleTranscription` (:5722) — `SubtitleTranslateMenu` (which does `private var controller: SubtitleAIController { viewModel.subtitleAI }` at `P/Sheets/SubtitleTranslateMenu.swift:65`, so all AI UI state flows through that one hop); `setSubtitleAppearance` (:3178) — `PlayerSettingsSheet`; `applySiloControlCommand` (:7694), `makeSiloControlPlaybackState` (:7794) — `TVControlReceiver` (:500, :638).

**Not called by any view:** `subtitleAILiveOverlayAvailable` (:526), `installLiveSubtitleTrackRow`, `selectLiveSubtitleTrack`, `closeLiveSubtitleTrackRow`, `removeLiveSubtitleTrackRow`, `armDeferredLiveSubtitleClose`, `restoreLiveSubtitleSelection`, `showLiveSubtitlePreparingNotice`, `dismissLiveSubtitlePreparingNotice`, `showLiveSubtitleFailureNotice`, `openLiveSubtitleTrack`, `feedLiveSubtitleCue`, `closeLiveSubtitleTrack`, `appendLiveSubtitleTrack` — these are `internal` **only** because the two fileprivate adapters can't reach `private` members (documented PVM:6030-6039). They are the adapter surface, not view API.

**Bindings:** there is **no** `$viewModel.x` projected binding anywhere in the tree; the VM is `@Observable` and views take `let viewModel`. One genuine direct write: `P/Sheets/PlayerSettingsSheet.swift:139` sets `viewModel.settings.subtitleSyncMs` *and then* calls `viewModel.setSubtitleSyncMilliseconds` (:140). All appearance controls are hand-built `Binding(get:set:)` pairs whose getter reads `viewModel.settings.*` and whose setter calls a VM method — `PlayerSettingsSheet.swift:136-142, 185-190, 193-199, 284-288, 421-431, 435-446, 449-460`; `tvOS/SubtitleAppearanceDialog.swift` getters at :52-231 with `mutateSubtitleAppearance` at :71, 92, 113, 134, 146, 168, 193, 210, 231; `tvOS/TVPlayerInfoHUD.swift:496-501, 910-915, 927-930, 937-947, 957-967`. Track pickers do **not** bind — they read `selected*Id` and call the command.

---

## 6. Existing tests pinning this half

**No test constructs `PlayerViewModel`, `AVPlayerBackend`, `PlaybackSessionBridge` or `SubtitleSession`.** Everything below tests statics or extracted types. Files referencing `PlayerViewModel` at all: `T/PlaybackProtocolV3Tests.swift`, `T/PlayerSettingsFlushTests.swift`, `T/PlayerErrorClassifierPinTests.swift`, `T/PlayerErrorClassificationMatrixTests.swift`, `T/ApplePlaybackRoutePlannerPinTests.swift`, `T/ApplePlaybackDecisionTraceSnapshotTests.swift`, `T/PlaybackSessionBridgeReplanContractTests.swift`.

The "R1 characterization" set is two commits: `ad052c3` (`T/ApplePlaybackRoutePlannerPinTests.swift` 1109 lines, `T/PlayerErrorClassifierPinTests.swift` 215) and `b214b69` (8 files, 2295 lines). Of those, only the planner pin tests touch tracks (audio route/mode selection); the rest are route/plan/classifier/offline.

Track-relevant test inventory (file → `func test` count → what is pinned):

- `T/PlaybackProtocolV3Tests.swift` (39) — the only tests that hit VM track statics.
  - `:576 testSubtitleIdentityUsesDenseServerCombinedOrdinals` — asserts `serverCombinedSubtitleIndex(ffmpegStreamIndex:2)==1`, `(5)==2`, `(for: external srcId 0)==0`, `(for: embedded ffIndex 5)==2`, `ffmpegSubtitleStreamIndex(2)==5`, and that combined `0` (external) maps to nil.
  - `:642 testAdoptedPlanBecomesDurableRenewalIntent`, `:700 testAdoptedSubtitleOffPlanClearsDurableSubtitleIntent` — `LoadRequest.adoptingProtocolV3Intent` (PVM:885) mapping of `plan.selectedTracks` into `preferredAudioTrackIndex` / `preferredSubtitleTrackIndex` / `preferredSidecarSubtitleTrackId` / `preferredProtocolV3SubtitleIndex`.
  - `:734 testInitialAutoSubtitleIntentIsFrozenIntoProtocolV3Plan` — `bridge.initialProtocolV3SubtitleIntent` over a 3-track version (external SRT, embedded subrip, forced+default PGS).
  - `:1043 testEmptySubtitleInventoryStartsDownloadedIdentityAtZero` — `protocolV3DownloadedSubtitleBaseTrackCount([]) == 0`.
  - `:1047 testV3ReplanRestoresServerRenderedSubtitleAsDisplayOnlySelection` — full truth table of `protocolV3SidecarRestoreIntent`: `render`→`.renderLocally`, `burn_in`→`.serverRendered`, `off`→nil, index mismatch→nil ×2.
  - `:1083 testV3AudioIntentOverridesBackendDefaultAfterReplan` — `protocolV3PendingTrackIntent` yields `audioIndex 1`, `embeddedSubtitleIndex -1`, nil sidecar.
  - `:1118 testStaleStreamGenerationCannotConsumePendingTrackIntent` — `isCurrentStreamCallback` equality.
  - `:1182 testV3RouteSubtitleFilteringRetainsOnlySelectedEmbeddedSidecar` — `protocolV3SubtitleUrlsForCurrentRoute` keeps `[3,9]` under `render`, `[3]` under `burn_in`, and is identity when the route does not extract embedded.
  - `:330 testLoopbackSessionPublishesTheAudioTrackSelectedForMuxing`, `:367 …KeepsEveryExecutionDecision` — the loopback `SelectedAudio` ordinal.
- `T/SubtitleAutoResolverTests.swift` (18, 303 lines) — the resolver's rules: forced-does-not-steal (:61), audio-language-match select-forced/disable (:77, :90), non-HI preference (:105), title-only CC demotion (:121, :137), language stack order (:145, :159, :172, :185, :199), accessibility (:212), Apple forced-only (:226, :241, :265), empty-track disable (:253), `disableWhenNoLanguageMatch` split (:279 vs :292). Pure `Inputs`→`SubtitleAutoSelection`.
- `T/SubtitleAIControllerTests.swift` (12, 553 lines) — dual completion latch (`:229`, `:258`, `:283`, `:318`, `:352`), early-frame buffering (`:378`, `:407`), cancel-during-submit (`:425`), and the `srcId` index-space guard: `:498` sidecar translates with its combined index, `:509`/`:516` embedded is refused, `:525` sidecar is admitted. Uses fakes for API/poller/coordinator.
- `T/LiveSubtitleCoordinatorTests.swift` (19, 400 lines) — the M4 phase machine end-to-end against a fake `LiveSubtitleSink`/`LivePlaybackControls`/`LiveSubtitleClock`: preparing/pause (:142, :153, :169, :183), first-cue resume (:197, :210, :228), pre-`started` completion/cancel (:236, :246), safety timeout (:264, :278), completion + persisted handoff incl. nil-subtitleId (:292, :306, :316), failure restore (:334), stale `track_key` and post-teardown ignores (:348, :360, :369), supersession (:385). **This is the closest thing to a selection-behaviour test in the suite**, and it exercises exactly the sink protocol the VM adapters implement.
- `T/LiveSubtitleTrackTests.swift` (27) — cue→ASS conversion, dedupe, escaping, clamping.
- `T/SubtitleDisplayOrderTests.swift` (10) — grouping/format/preferred-language ordering, `formatRank`, `canonicalLanguageKey`. Pins `orderedSubtitleTracks` behaviour.
- `T/TrackSelectionPersistenceTests.swift` (9) — `prefKey` series-over-content (:13), audio signature from server metadata / ordinal range / PlayerTrack fallback (:32, :64, :73), subtitle embedded/external/off/unknown/PlayerTrack (:93, :115, :131, :144, :152). Pins `persistAudioSelection`/`persistSubtitleSelection` inputs.
- `T/ApplePlaybackAudioSelectionRouteTests.swift` (5) — container-default keeps native-direct (:85), non-default audio forces loopback (:91), no server selection (:99), single track (:104), `original_http` advertises client audio selection (:110).
- `T/SubtitleStreamEventTests.swift` (12), `T/SubtitleSearchModelTests.swift` (6), `T/SidecarSubtitleFetcherTests.swift` (3), `T/SubtitleStylingOverrideTests.swift` (24), `T/SystemCaptionAppearanceTests.swift` (17), `T/BitmapSubtitleCueStoreTests.swift` (11), `T/BitmapSubtitlePaletteTests.swift` (11) — wire decoding, fetch limits, styling and appearance mapping; no selection logic.

**Nothing pins:** `applyTrackList`, `appendSidecarTracks`, `applyAutoSubtitlePreferencesIfNeeded`, `applyAutoSubtitle`, `replanAutomaticProtocolV3SubtitleSelection`, `reapplySystemSubtitlePolicy`, `bestTrackMatch`/`TrackSelectionSnapshot.score`, the forced-sidecar auto-select, or any of the `pending*` consumption order. Those are the behaviours a `TrackSelectionCoordinator` extraction must preserve blind.

---

## 7. Seam data for the extraction

**State that would move wholesale** (nothing outside the track half writes or reads it): `pendingExternalSubtitles` :724, `knownExternalSubtitles` :728, `TrackSelectionSnapshot` :729-765, `pendingRecoveredAudioSelection` :766, `pendingRecoveredSubtitleSelection` :767, `pendingRecoveredSecondarySubtitleId` :768, `pendingAudioFfIndex` :773, `pendingSubtitleFfIndex` :774, `hasExplicitSubtitleChoice` :778, `pendingSidecarSubtitleTrackId` :782, `pendingServerRenderedSubtitleTrackId` :787, `pendingLiveSubtitleCloseTrackId` :794, `deferredLiveSubtitleCloseTask` :798, `prefsForCurrentItem` :807, `PrefsSnapshot` :808-819, `prefsResolvedForCurrentItem` :821, `subtitleOrderingLanguage` :200, `liveSubtitlePreparingNoticeId` :577, and the `subtitleAI` sub-object :493.

**State that must stay published on the VM** (views observe it; §5): `audioTracks`, `subtitleTracks`, `selectedAudioId`, `selectedSubtitleId`, `selectedSecondarySubtitleId` — five stored properties. If they move into the coordinator, the VM needs five forwarding computed properties **and** the coordinator must be `@Observable` and observed transitively, or the VM re-publishes on change.

**Clean function-level seams (no core state read, movable verbatim):**
`orderedSubtitles` :413, `bestTrackMatch` :7306, `systemCaptionPrefsSnapshot` :7363, `serverSubtitlePrefsSnapshot` :7404, `applyAutoSubtitlePreferencesIfNeeded` :7320, `applyAutoSubtitle` :7420, `applyTrackList` :7201, `appendSidecarTracks` :7067, `appendLiveSubtitleTrack` :7038, `removeLiveSubtitleTrackRow` :6064, `performDeferredLiveSubtitleCloseIfNeeded` :6104, `recordAudioTrackSelectionBreadcrumb` :6939, `recordSubtitleTrackSelectionBreadcrumb` :6971, `subtitleTrackKind` :6999, and the 5 pure statics :5885, :5898, :5944, :5960, plus `TrackSelectionSnapshot`/`PrefsSnapshot`.

**Seams needing an injected port** (they touch exactly one core capability each):
- backend port (`selectAudioTrack`, `selectSubtitleTrack`, `setSecondarySubtitleTrack`, `registerSidecarSubtitles`, `openLiveSubtitleTrack`, `feedLiveSubtitleCue`, `closeLiveSubtitleTrack`, `applySubtitleAppearance`, `pause`/`play`/`isPlaying`) — 10 call sites listed in §4.
- replan port (`attemptProtocolV3Replan`) — 4 sites: :5555, :5588, :5618, :7458; plus `protocolV3ReplanTask == nil` guard read at :7445 and `lastLoadRequest?.preferredProtocolV3SubtitleIndex` write at :7457.
- session/plan context (`activePreparedProtocolV3`, `currentSelectedVersion`, `currentWatchDetail`, `activePlaybackSessionId`, `resolvedServerUrl`, `activeRouteKind`, `backendCapabilities`, `offlinePlaybackContext`, `currentTime`) — read-only, 40+ sites.
- notice port (`showNotice`, `activeNotice`, `noticeDismissTask`) — 3 sites, :6133/:6143/:6153-6156/:6162.
- UI-timer port (`scheduleHideControls`) — 8 sites, all in the user-command run 5541-5706.
- suspension gate (`isBackgroundSuspended`) — 8 sites, all in user commands.

**Boundaries that are already clean:** the two adapters at PVM:7856-8007 are `fileprivate` and hold the VM weakly — they can be re-pointed at the coordinator by changing one type in `owner` and the 14 forwarders they call. `SubtitleSession`, `SidecarSubtitleFetcher`, `AVPlayerEmbeddedSubtitleExtractor`, `SubtitleStylingOverride` are **never referenced by `PlayerViewModel`** — they are entirely behind `AVPlayerBackend`, so the extraction never touches the render plane.

**Boundaries that are not clean:** (a) `resetPublishedLoadState` PVM:3469-3546 interleaves 11 track writes with ~35 unrelated UI resets in one function; (b) `adoptPreparedPlayback` PVM:2531-2718 interleaves track restore with duration/quality/session adoption; (c) `attemptNativeDirectRouteRecovery` PVM:2210-2246 does a manual snapshot/restore of 6 track fields around a `resetPublishedLoadState` call; (d) `setSubtitleMatchesSystemAppearance` PVM:3210-3221 sits in the appearance block but writes 4 selection fields; (e) `selectAudio` PVM:5546 calls `reapplySystemSubtitlePolicy`. These five are where the "mechanical" move stops being mechanical.