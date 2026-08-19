<!-- Stage 2 inventory, generated 2026-08-19 by a read-only mapping agent at acc3004/20ba06b; line anchors are from that tip. -->

# PlayerViewModel.swift lines 1–5535 — control-core inventory

All line numbers re-derived at HEAD `acc3004` (branch `player/architecture-remediation`).
Primary file (`PVM:` below) = `/Volumes/NVMe/dev/github/SiloServer/silo-apple/iosApp/iosApp/Screens/Player/PlayerViewModel.swift`
Also cited: `/Volumes/NVMe/dev/github/SiloServer/silo-apple/iosApp/iosApp/Screens/Player/PlayerTaskRegistry.swift`, `.../PlaybackFailure.swift`, `.../PlaybackSessionBridge.swift`, `.../AVPlayerRoute/AVPlayerBackend.swift`.
Type is `@Observable class PlayerViewModel` (PVM:178-179), Swift-5 mode, effectively main-actor by convention (individual members carry `@MainActor`).

---

## 1. STATE

### 1a. Identity / generation / staleness / latch fields

**Generation counters (3 in this range; a 4th + a string-compare live in the backend)**
- `streamLoadGeneration: UInt64` PVM:337 — single increment at PVM:2745 (inside `loadStream`). Captured *by value* into every callback closure (`makeCallbacks` PVM:1212, `applyCallbacks` PVM:1416, `wireSubtitleCallbacks` PVM:1195); compared via `Self.isCurrentStreamCallback` (defined PVM:5918, out of range). Never logged.
- `freshLoadGeneration: UInt64` PVM:631 — incremented at PVM:3709 (`beginFreshLoad`) and PVM:5221 (`restartCurrentTranscodeHLS`); used only to decide whether the completing task may nil out `freshLoadTask` (PVM:3716-3718, PVM:5227-5229).
- `serverOutageRecoveryGeneration: UInt64` PVM:618 — incremented at PVM:4401 (`attemptServerOutageRecovery`) and again at PVM:4487 (`clearServerOutageRecoveryState`, i.e. clear-by-bump). Checked in `waitForServerReady` loop PVM:4499 and after the await PVM:4457.

**Session-id mirrors (all mirrors of `PlaybackSessionBridge` state)**
- `activePlaybackSessionId: String?` PVM:827 — mirror of bridge `sessionId`. Written at PVM:2536 (adopt), PVM:4139 (background renewal success), cleared PVM:4062 (terminal). Read by: subtitleAI closure PVM:495, `subtitleAILiveOverlayAvailable` PVM:527, intro/credits skip keys PVM:5462/5470, both renewal single-flights.
- `staleSessionRecoverySessionId: String?` PVM:836 — single-flight echo for `attemptStaleSessionRenewal` (set PVM:4224, compared PVM:4221, cleared PVM:2551/2578/4147).
- `backgroundRenewalSessionId: String?` PVM:599 — single-flight echo for `attemptBackgroundSessionRenewal` (set PVM:4098, compared PVM:4096, cleared PVM:2555/4148/4177/4204/4267/4409, and PVM:7625 in suspend).
- `activeServerOutageRecoverySessionId: String?` PVM:619 — single-flight echo + a global suppression gate: it makes `handlePlaybackError` PVM:1543 and `handleEndOfFile` PVM:3344 return early.
- `sourceProxyFileId: Int?` PVM:2844 — identity of the file the live proxy was built for (stash metadata for the cache handoff).

**Attempt latches (booleans, once-per-load)**
- `hasAttemptedNativeDirectRouteRecovery` PVM:837 — set PVM:2200/2205, reset only in `resetPublishedLoadState` PVM:3527 when `resetRouteRecoveryFlags == true`.
- `hasAttemptedSiloRouteHLSFallback` PVM:838 — set PVM:2268, reset PVM:3528.
- `hasReachedEndOfFile` PVM:450 — terminal latch; set PVM:3411, cleared PVM:1510, PVM:3685, PVM:2110, PVM:5038, PVM:5064. Gates ~12 public entry points (`seek`, `skipForward`, `beginScrub`, `togglePlayPause` via `pauseForTimelineSelection`, …) and `onTimeChange` PVM:1229.
- `prefsResolvedForCurrentItem: Bool` PVM:821 — "resolver has fired once" latch.
- `hasExplicitSubtitleChoice: Bool` PVM:778 — "user owns the subtitle choice" latch, computed at PVM:3540-3543.
- `isDisposed: Bool` PVM:427 — global dispose latch, guarded in ~40 closures; projected as `needsReplacementForPresentation` PVM:428.
- `nextUpAutoplayCancelled` PVM:970, `nextUpPromptDismissed` PVM:976 — Next-Up suppression latches.
- `autoSkippedIntroKey` PVM:828 / `autoSkippedCreditsKey` PVM:829 / `autoSkipIntroCancelledKey` PVM:830 / `pendingAutoSkipIntroKey` PVM:831 — string-keyed marker latches, key = `"\(sessionId):\(fileId):\(range.start):\(range.end)"` (PVM:5460-5474) → an implicit 5th identity idiom.
- `backgroundRenewalTransientFailures: Int` PVM:600, cap `backgroundRenewalTransientFailureLimit = 3` PVM:601.

**Seek-filter triple** (all written from four sites: `commitSeek` PVM:5038-5040, `beginReanchorSeekUI` PVM:5064-5066, `resetPublishedLoadState` PVM:3486-3487, the timeout task PVM:5055-5056, plus release inside `onTimeChange` PVM:1251-1254)
- `seekOriginTime: Double?` PVM:695, `seekTargetTime: Double?` PVM:696, `seekFilterTimeoutTask` PVM:697 (registry key `.seekFilterTimeout`), constant `seekFilterNanos = 5_000_000_000` PVM:701.

**Pending / intent fields in this range** (subtitle half is the other agent's; these are the ones the control core writes)
- `pendingAudioFfIndex` PVM:773, `pendingSubtitleFfIndex` PVM:774, `pendingSidecarSubtitleTrackId` PVM:782, `pendingServerRenderedSubtitleTrackId` PVM:787, `pendingLiveSubtitleCloseTrackId` PVM:794.
- `pendingRecoveredAudioSelection` PVM:766, `pendingRecoveredSubtitleSelection` PVM:767, `pendingRecoveredSecondarySubtitleId` PVM:768 — `TrackSelectionSnapshot` (PVM:729-765) fuzzy-match carriers written by route recovery (PVM:2242-2244) and transcode restart (PVM:2601-2603).
- `pendingExternalSubtitles` PVM:724 / `knownExternalSubtitles` PVM:728.
- `prefsForCurrentItem: PrefsSnapshot?` PVM:807 (struct PVM:808-819).

### 1b. Sub-state flags (control-plane mode bits)
- `sourceOutageActive` PVM:612 + `sourceOutageNoticeShown` PVM:613 — origin-outage ride-through mode.
- `suspendedPlayback: SuspendedPlaybackContext?` PVM:969 (struct PVM:965-968) — tvOS background suspend; projected as `isBackgroundSuspended` PVM:986 and `suspendedNotice` PVM:987.
- `playbackInterruption: PlaybackInterruptionState?` PVM:951 (struct PVM:944-950: `wasPlaying/positionSeconds/recoveryDeadline/didAutoRecover/isPending`) — tvOS transient-inactive interruption.
- `isQualitySwitching` PVM:210 (also a UI projection) — the replanning-for-quality bit.
- "isReplanning" is not a stored flag: it is `protocolV3ReplanTask != nil` (guard PVM:1610, PVM:2277) — and `restartCurrentTranscodeHLS` does **not** consult it (it occupies `freshLoadTask` instead, PVM:5220-5223). This is review §4.3 at current lines.
- `offlinePlaybackContext: OfflinePlaybackContext?` PVM:716 (struct PVM:712-715) — "offline mode" bit; gates the proxy, realtime bind, Next-Up, progress routing.
- `isSceneBackgrounded` PVM:434 (`#if os(iOS)`).
- `hasReachedEndOfFile` PVM:450 doubles as the `.ended` sub-state.

### 1c. Published UI projections (`@Observable` stored, read by views)
Stored: `isPlaying` PVM:185, `currentTime` :186, `duration` :187, `title` :188, `isLoading` :189, `isBuffering` :190, `error` :191, `showControls` :192, `activeNotice` :193, `remoteDismissToken` :194, `audioTracks` :195, `subtitleTracks` :196, `chapters` :202, `introRange` :203, `creditsRange` :204, `introAutoSkipCountdownSeconds` :205, `selectedAudioId` :206, `selectedSubtitleId` :207, `selectedSecondarySubtitleId` :208, `qualityOptions` :209, `activeQualityId` :210, `isQualitySwitching` :211, `qualitySwitchError` :212, `isScrubbing` :213, `scrubPreviewTime` :214, `isHoldFastForwarding` :218, `bufferedAheadSeconds` :224, `playbackRunwaySeconds` :230, `playbackStats` :252, `showNextUpScreen` :253, `nextUpEpisode` :254, `nextUpOnDeckItems` :255, `isLoadingNextUpEpisode` :256, `isLoadingNextUpOnDeck` :257, `nextUpLookupError` :258, `nextUpStartError` :264, `nextUpCountdownSeconds` :265, `nextUpCountdownTotalSeconds` :266, `nextUpScreenVideoEnded` :267, `metadata` :281, `isHUDPresented` :287, `holdSeekRate` :302, `requestedTVHUDEntryPoint` :311 (tvOS), `contentIdsNeedingDetailRefresh` :977, `supportsExternalPlayback` :445 (iOS).
Computed: `bufferedFraction` :232, `scrubDisplayTime` :238, `progressFraction` :243, `currentChapterIndex` :249, `showIntroSkip` :292, `isHoldSeeking` :304, `backendCapabilities` :338, `activeRouteLabel` :347, `playbackRouteDisplay` :355, `routeStatusRows` :361, `routeDecisionSummary` :396, `routeWarnings` :400, `hasTrackSelectionOptions` :403, `supportsSecondarySubtitles` :404, `orderedSubtitleTracks` :410, `availableSecondarySubtitleTracks` :411, `needsReplacementForPresentation` :428, `currentUserVolume` :1168, `subtitleAILiveOverlayAvailable` :527, `isBackgroundSuspended` :986, `suspendedNotice` :987, `nextUpCarouselItems` :990, `canShowNextUpScreen` :995, `currentRouteCapabilities` :1001.

### 1d. Backend/bridge mirrors and owned collaborators
- `avPlayerBackend: AVPlayerBackend?` PVM:326 — single backend slot; `activeRouteKind: PlaybackEngineKind` PVM:327 is its route mirror; `activeExecutionPlan` PVM:335 mirrors the plan handed to it.
- `userVolume` PVM:333 / `userMuted` PVM:334 — VM is canonical, backend is the mirror (re-pushed by `reapplyUserGain` PVM:1189).
- `playbackTimelineOffset: Double` PVM:705 — mirror of the backend/session timeline anchor, written from 4 sites (PVM:2687/2690/2694 in adopt, PVM:2803 in loadStream, PVM:5164 in loopback reanchor, PVM:1478 from `onTimelineOffsetChange`).
- `realtimeConnectedSnapshot` PVM:515 / `realtimeUnavailableSnapshot` PVM:520 — mirrors of `PlaybackRealtimeClient` actor state; tokens PVM:533/534.
- `sourceProxy: PlaybackSourceProxy?` PVM:336; `sourceCacheHandoff` PVM:2840 (struct PVM:2836-2839).
- `currentWatchDetail` PVM:824, `currentSelectedVersion` PVM:825, `activePreparedProtocolV3: PreparedPlaybackV3?` PVM:826, `currentDeliveryStrategy` PVM:823, `resolvedServerUrl` PVM:822 — mirrors of the bridge's prepared session.
- `lastLoadRequest: LoadRequest?` PVM:950 (`LoadRequest` PVM:839-919 incl. `copyForRecovery` :861 and `adoptingProtocolV3Intent` :885) — the replay intent every recovery path rebuilds from.
- Immutable collaborators: `settings` PVM:452, `sleepTimer` PVM:453, `nowPlaying` PVM:454, `sessionBridge` PVM:467, `tasks` PVM:472, `realtimeClient` PVM:474, `subtitleAI` PVM:492.

### 1e. Constants declared in range
`autoplayPlayerDisposeTimeout = 5` PVM:941; `autoplayStartSessionTimeout = 15` PVM:942; `interruptionRecoveryTimeout = 3` PVM:952; `interruptionResumeSuccessThresholdSeconds = 0.1` PVM:953; `serverOutageRecoveryInitialDelay = 1` PVM:954; `serverOutageRecoveryMaxDelay = 8` PVM:955; `serverOutageRecoveryTimeout = 90` PVM:956; `nextUpCountdownDefaultSeconds = 10` PVM:957; `nextUpHUDCountdownThresholdSeconds = 100` PVM:958; `introAutoSkipCountdownDefaultSeconds = 5` PVM:959; `nearEndPlaybackErrorThresholdSeconds = 8` PVM:960; `nearEndPlaybackErrorMaxBufferedAheadSeconds = 1` PVM:964; `offlineWatchedFraction = 0.9` PVM:721; `backgroundRenewalTransientFailureLimit = 3` PVM:601; `skipDebounceNanos = 200ms` PVM:662; `holdSeekBaseStep = 2.0` PVM:679; `holdSeekTickNanos = 100ms` PVM:680; `seekFilterNanos = 5s` PVM:701; `seekRates` ladder PVM:320; `suspendedPlaybackNotice` PVM:980.

---

## 2. LOAD PIPELINE

### Fresh load chain
`loadAndPlay` PVM:4529 (or `retry` :4557, `playNextEpisodeNow` :2130, `playOnDeckItemNow` :2148, `resumeSuspendedPlayback` :7640, `triggerAutomaticInterruptionRecovery` :4005, `attemptStaleSessionRenewal` :4250, `attemptServerOutageRecovery` :4471, `reloadServerBackedHLSForSeek` :5125, `switchQuality` :4653/:4685)
→ **`beginFreshLoad(request:progressPosition:finalizeCurrentSession:resumePositionOverride:allowNearEndResume:preserveInterruptionState:origin:)` PVM:3669**
 synchronously mutates: `lastLoadRequest` :3682, `offlinePlaybackContext = nil` :3683, `contentIdsNeedingDetailRefresh` :3684, `hasReachedEndOfFile = false` :3685, `cancelNextUpFlow()` :3686, conditional `clearServerOutageRecoveryState()` :3688, `clearForegroundInterruptionState()` :3691, `clearSuspendedPlaybackState()` :3693, `attachNowPlayingIfNeeded()` :3694, `resetPublishedLoadState(...)` :3695 (~50 field reset, PVM:3469-3546), cancels `freshLoadTask`+`protocolV3ReplanTask` :3702-3704, bumps `freshLoadGeneration` :3705.
 → `freshLoadTask` PVM:3713: `stopSession`/`reportProgress` :3722-3726 → `realtimeClient.unbind()` :3730 → `disposeActivePlayerForFreshLoad` PVM:3798 (→ `disposePlayerOffMain` PVM:3813, off-main `dispose()` with optional timeout, `DisposableBackend` `@unchecked Sendable` PVM:3806) → `await settingsRefreshTask?.value` :3745 → `OfflinePlaybackBuilder.loadPreparedPlayback` :3755 **or** `runStartSession` PVM:3840 (timeout race, PVM:3862-3892) → `adoptPreparedPlayback(origin: .freshLoad)` :3781.
 Failure path: `handleBeginFreshLoadFailure` PVM:3914 (three arms by `LoadOrigin` PVM:922-933: `.userInitiated` → `finalizeTerminalPlaybackError`; `.autoplay` → postroll + `nextUpStartError`; `.recovery` → notice only).

**`adoptPreparedPlayback(_:origin:)` PVM:2531** — the single ~190-line publish used by all three pipelines; origin enum `PlaybackAdoptionOrigin` PVM:2437-2495 (`.freshLoad(FreshLoad)`, `.protocolV3Replan(Replan)`, `.transcodeRestart(TranscodeRestart)`; `reusesActiveEngine` PVM:2484). Mutates, in order: `activePlaybackSessionId` :2536; per-origin pre-publish block :2539-2578 (fresh: marker latches, renewal single-flights, `subtitleOrderingLanguage`, `prefsForCurrentItem`, `title`, `metadata`; restart: marker latches + optional dispose); `currentWatchDetail` :2581, `currentSelectedVersion` :2582, `activePreparedProtocolV3` :2583, `adoptProtocolV3RenewalIntent` :2584 (PVM:3596), `pendingExternalSubtitles`/`knownExternalSubtitles` :2585-2586; sidecar restore per origin :2588-2604 (`applySidecarRestoreIntent` PVM:2502); `duration` :2611, `currentTime` :2612, `qualityOptions` :2613, `activeQualityId` :2617; fresh-only chapters/markers/artwork/NextUp :2620-2640; realtime (re)bind :2645-2667; `makeStreamRequest` :2669 → `resolvedServerUrl` :2676; `makeExecutionPlan` :2678; `currentDeliveryStrategy` :2679; `playbackTimelineOffset` per origin :2681-2695; `logExecutionPlan` :2696; per-origin `reportProtocolV3PlanExecutionStarted` :2700/:2707 (restart deliberately does **not** report, :2712-2715); `await loadStream(plan:reusingActiveEngine:)` :2717. **No LoadID/generation guard on any of it.**

**`loadStream(plan:reusingActiveEngine:)` PVM:2719** — pre-flight `needsServerReplanBeforeLoad` bounce PVM:2725-2745 (static predicate PVM:2426); `streamLoadGeneration &+= 1` :2745; `avPlayerBackend?.pause()` :2752; `rearmAdoptedProtocolV3TrackIntent()` :2757 (PVM:3623); `stashSourceCacheHandoff()` :2758; proxy stop/nil :2759-2760; `prepareSourceProxy` :2763 (with two generation re-checks :2765/:2773); `sourceProxy`/`sourceProxyFileId` :2779-2781; `activeExecutionPlan = loadPlan` :2783; **`reusingActiveEngine && avPlayerBackend != nil ? prepareBackend : installBackend`** :2787-2789; unconditional re-wire `applyCallbacks(makeCallbacks(), to:)` + `wireSubtitleCallbacks` + `setServerChapters` :2799-2801 (this is the R-round fix for review §3 #1); `setMediaTimelineOffset` :2806; `proxyStatsProvider` :2808, `sourceOutageStateProvider` :2811; `loadBackend` :2815 + `reapplyUserGain` :2816.

**`prepareBackend/installBackend/loadBackend`**
- `makeAVPlayerBackend` PVM:1113 — `AVPlayerBackend()` (default init; the injectable `init(player:)` at AVPlayerBackend.swift:895 is **not** used here).
- `installBackend(for:)` PVM:1123 — disposes old, makes new, sets `avPlayerBackend` + `activeRouteKind`, logs `[CMP-ENGINE] installed`.
- **`prepareBackend(for:)` PVM:1140 — the "keep live backend across in-place replan" mechanism.** Returns the existing backend when `activeRouteKind == engine`; the doc comment PVM:1136-1139 states the product reason (audio session + identical tvOS display criteria, avoiding HDMI renegotiation). Reached only via `loadStream(reusingActiveEngine: true)` PVM:2787, which only `.protocolV3Replan` sets (`reusesActiveEngine` PVM:2484-2487). **Product-essential; must survive.**
- `loadBackend(_:plan:)` PVM:1152 — total switch on `plan.engine` → `loadRemoteHLS` / `loadDirectFile` / `load(sessionSpec:)`; throws `PlaybackEngineLoadError.missingLoopbackSession` PVM:1163.

**`makeExecutionPlan(prepared:streamRequest:)` PVM:2350** — `makeRouteRequirements` (PVM:6694, out of range) → `ApplePlaybackRoutePlanner().makeExecutionPlan` unconditionally PVM:2352 → if `prepared.protocolV3 != nil`, `ApplePlaybackV3PlanAdapter.makeExecutionPlan` PVM:2367 overrides. `logExecutionPlan` PVM:2378 is the sole `cmpLog` in the control core (PVM:2424).

**`prepareSourceProxy(for:)` PVM:2907** — eligibility guard :2910-2912 (`.direct`, engine ≠ `.avPlayerHLS`, http/https) else `discardSourceCacheHandoff` + pass-through; budget `sourceCacheBudget` PVM:3034 (thresholds 200 Mbps → 512 MB, 80 Mbps → loopback budget, constrained-memory variants); cache adoption `takeAdoptableSourceCache` PVM:2868 → `SourceCacheAdoptionPolicy.shouldAdopt`; builds `PlaybackSourceProxy` with four callbacks (PVM:2941-2971, see §4); `proxy.start()` :2973, `setSourceBitrate` :2982, `startPrefetch(at: initialSourcePrefetchOffset)` :2986; **rebuilds the plan** PVM:2995-3020 including `loopbackSession.withSource(url:headers:)` :2999 (R1 seam) and `decisionTrace + ["source_proxy_enabled"]`; loopback-without-session throws :3021-3024; catch: loopback rethrows, others degrade to no-proxy :3026-3032.

### Replan pipelines (two, no mutual exclusion)
- **`attemptProtocolV3Replan(position:classification:message:operation:qualityPreference:completesQualitySwitch:outputRouteSnapshot:)` PVM:1600.** Guard PVM:1610-1611 (`protocolV3ReplanTask == nil` && `currentWatchDetail != nil`). Mutates before the task: snapshots `selectedSubtitleId` :1614, cancels `progressTask` :1615, `isLoading = true` :1616, `setBuffering(false, "replan")` :1617, **`replanBackend.setRecoverySuspended(true, reason: AVPlayerBackend.serverReplanRecoverySuspensionReason)`** :1624 released in `defer` :1628. Task: `sessionBridge.replanProtocolV3(...)` :1632-1642 → nil ⇒ `finalizeTerminalPlaybackError` :1644 → `adoptPreparedPlayback(origin: .protocolV3Replan)` :1654. Catch: `isPlaybackSessionMissing` ⇒ `attemptStaleSessionRenewal` :1663-1668, else terminal :1670.
  Callers: `attemptProtocolV3Recovery` PVM:1592 (from `handlePlaybackError` :1554), `requestServerHLSRouteFallback` PVM:2288, AVAudioSession route observer PVM:1090, `switchQuality` PVM:4617, `reloadServerBackedHLSForSeek` PVM:5106.
- **`restartCurrentTranscodeHLS(to:origin:qualityId:source:)` PVM:5180.** Guards :5186-5188 (active V3 + snapshots) and :5195-5198 (`seek` requires `seekReanchorFeature`). Snapshots six subtitle/quality fields :5202-5217; **cancels `freshLoadTask` and bumps `freshLoadGeneration`** :5220-5222 — i.e. it occupies the fresh-load slot, and never checks `protocolV3ReplanTask`. Task: `reportProgress` :5233 → conditional `avPlayerBackend?.dispose()` :5238 (only when `source != "quality"`) → `replanProtocolV3` :5242-5255 → `adoptPreparedPlayback(origin: .transcodeRestart)` :5265. Catch: quality ⇒ restore `activeQualityId`, set `qualitySwitchError`; seek ⇒ terminal :5283-5291.
- **Seek-side entries:** `reloadServerBackedHLSForSeek` PVM:5078 (≤30 s transcode seeks stay local :5093-5098; `remux|transcode` ⇒ `beginReanchorSeekUI` :5104 then either V3 replan :5106 or a whole `beginFreshLoad` :5125) and `reloadLocalLoopbackForSeekBeforeAnchor` PVM:5135 (loopback seek *before* the current anchor ⇒ rebuild the plan with `loopbackSession.reanchored(at:)` :5152, `beginReanchorSeekUI` :5164, set `playbackTimelineOffset` :5165, then an **unregistered** `Task { loadStream }` :5174).

---

## 3. CALLBACKS

`PlayerCallbacks` struct PVM:71-86 — 12 closures: `onTimeChange, onDurationChange, onPauseChange, onFileLoaded(String reason), onFirstFrame(Int ms), onError(PlaybackFailure), onEndOfFile, onBufferingChange, onBufferedAheadChange(PlaybackBufferedAhead), onPlaybackStatsChange(PlaybackStats), onTracksChange([PlayerTrack]), onChaptersChange([PlayerChapterInfo])`.

**`makeCallbacks()` PVM:1211** captures `let callbackGeneration = streamLoadGeneration` PVM:1212 once, by value; every closure repeats the identical 3-part guard `guard let self, !self.isDisposed, Self.isCurrentStreamCallback(callbackGeneration, currentGeneration: self.streamLoadGeneration)`.
- `onTimeChange` :1214 — extra guards `seconds.isFinite`, `!hasReachedEndOfFile` :1229; applies `playbackTimelineOffset` :1230; monotonic-backwards filter `Self.isUnexpectedBackwardPlaybackTime` :1235; seek origin/target filter :1244-1255; writes `currentTime`; then `completeInterruptionRecoveryIfNeeded` :1257, `updateNextUpPresentation` :1260, `autoSkipIntroIfNeeded` :1261, `autoSkipCreditsIfNeeded` :1262, `pushNowPlayingIfDue` :1263. (5 responsibilities in one callback.)
- `onDurationChange` :1265 — gated by `Self.shouldAdoptBackendDuration` :1272 (PVM:3117).
- `onPauseChange` :1280 — sole writer of `isPlaying` :1287; pins/schedules controls :1294-1298; pushes NowPlaying.
- `onFileLoaded` :1306 → `handleFileLoaded` PVM:1509 (clears EOF latch, `error`, `clearServerOutageRecoveryState`, completes interruption, `clearLoadingOverlay`, `isPlaying = true`, `applySettingsToPlayer`, `loadPendingExternalSubtitles`, `startProgressReporting`, hides controls, NowPlaying).
- `onFirstFrame` :1315 — spawns an **unregistered** `Task { sessionBridge.reportProtocolV3FirstFrame }` :1323.
- `onError` :1325 → `handlePlaybackError(failure)` :1333.
- `onTracksChange` :1335 → `applyTrackList` :1343 (other agent's half).
- `onChaptersChange` :1345 — writes `chapters`.
- `onBufferingChange` :1355 — on `true` spawns an **unregistered** `Task { noteBufferingDuringSourceOutage() }` :1360; then `setBuffering(cause: "buffer_empty"|"likely_to_keep_up")` :1365.
- `onBufferedAheadChange` :1370 — writes `bufferedAheadSeconds`/`playbackRunwaySeconds` :1379-1380.
- `onPlaybackStatsChange` :1382 — `PlaybackStatsComposer.compose` with proxy stats + engine + nominal bitrate + origin host :1390-1400; then `reconcileDynamicRangeBadge` :1403 (writes `metadata.badges`).
- `onEndOfFile` :1405 → `handleEndOfFile` PVM:3343.

**`applyCallbacks(_:to:)` PVM:1415** re-captures `callbackGeneration` PVM:1416 (a second, independent capture) and assigns the 12 fields :1417-1428, plus:
- `onTimelineOffsetChange` :1429 — declared only here (not in `PlayerCallbacks`), writes `playbackTimelineOffset` :1478.
- `#if os(iOS)` fork :1440-1490: `isPictureInPictureActiveProvider` :1441, `onExternalPlaybackActiveChange` :1444 → `handleExternalPlaybackActiveChange` :1452, `onExternalPlaybackAllowedChange` :1454 → `supportsExternalPlayback` :1462, `onExternalPlaybackUnavailable` :1464 (wraps an **unregistered** `Task { @MainActor }` to reach `showNotice`), eager `supportsExternalPlayback = backend.isExternalPlaybackAllowed` :1486, `PictureInPictureCoordinator.shared.bindLifecycle(owner:)` :1487.
- **Not routed through `PlayerCallbacks`:** `wireSubtitleCallbacks` PVM:1194 sets `onSidecarTracksRegistered` with its own third generation capture PVM:1195; `proxyStatsProvider` PVM:2808 and `sourceOutageStateProvider` PVM:2811 are set in `loadStream`, ungenerationed.

---

## 4. RECOVERY IN THE VM

### `handlePlaybackError(_ failure: PlaybackFailure)` PVM:1537 — 10 ordered rungs
1. :1540 `hasReachedEndOfFile` ⇒ log + return.
2. :1543 `activeServerOutageRecoverySessionId != nil` ⇒ log + return.
3. :1547 `shouldTreatPlaybackErrorAsNaturalEnd()` PVM:1678/static PVM:1697 ⇒ `handleEndOfFile()`. Corroborated: `duration>0 && currentTime>0`, `!isSourceOutageActive` (`sourceOutageActive || sourceProxy?.isOriginOutageActive`), `bufferedAheadSeconds <= 1` (PVM:964), `duration - currentTime <= 8` (PVM:960).
4. :1552 `activePreparedProtocolV3 != nil` ⇒ `attemptProtocolV3Recovery` PVM:1592 ⇒ `attemptProtocolV3Replan`. **This returns before every rung below whenever V3 is active — i.e. rungs 5–10 are online-unreachable** (V3 is the only online start path; `activePreparedProtocolV3` is set at PVM:2583 and cleared at PVM:3515/4063).
5. :1556 `failure.isPlaybackSessionMissing` ⇒ `attemptBackgroundSessionRenewal(reason:"player_error")` then `attemptStaleSessionRenewal(reason:"player_error")`.
6. :1564 `failure.isPrematureSourceEnd` ⇒ **unregistered** `Task { attemptServerOutageRecovery(.networkUnavailable) }` :1569.
7. :1577 `progressTask?.cancel()`.
8. :1578 `shouldAutoRecoverFromInterruption()` PVM:3999 ⇒ `triggerAutomaticInterruptionRecovery()` PVM:4005.
9. :1582 `attemptNativeDirectRouteRecovery`.
10. :1585 `attemptSiloRouteHLSFallback`; else :1588 `finalizeTerminalPlaybackError(message)`.
No in-flight latch anywhere on this ladder.

### `attemptNativeDirectRouteRecovery(after:) -> Bool` PVM:2174
Trigger: rung 9. Conditions :2175-2179 — `!isDisposed`, plan exists, `engine == .avPlayerNativeDirect`, `!hasAttemptedNativeDirectRouteRecovery`. Builds `makeLoopbackFallbackPlan` PVM:2300 (needs `currentSelectedVersion`; picks `.passthroughH264|.passthroughHEVC` via `isH264Video`; `makeFallbackLoopbackSession` PVM:6755); nil ⇒ escalate to `requestServerHLSRouteFallback(classification:"native_direct_avplayer_failed")` :2196. Otherwise: sets the latch :2205, snapshots 10 fields :2210-2229, calls `resetPublishedLoadState(resetRouteRecoveryFlags: false)` :2230, **restores** 9 of those fields :2236-2245, `avPlayerBackend?.dispose()` :2246, `logExecutionPlan` :2247, **unregistered** `Task { loadStream(plan:) }` :2249. Start position = `currentTime` if >0 else `plan.startMode.seconds` :2182-2184.

### `attemptSiloRouteHLSFallback(after:) -> Bool` PVM:2258
Conditions :2259-2263 — `engine == .siloPlayerLoopback`, `!hasAttemptedSiloRouteHLSFallback`. Delegates to `requestServerHLSRouteFallback(classification:"silo_loopback_failed")` :2264; sets the latch :2268.
`requestServerHLSRouteFallback` PVM:2279 — guard `currentWatchDetail != nil && protocolV3ReplanTask == nil` :2284; logs `[CMP-ROUTE]` with `failure.stableToken`; calls `attemptProtocolV3Replan(classification:message:)` :2288. Returns `false` iff a replan is already in flight (used at PVM:2734 to terminate rather than loop).

### `attemptBackgroundSessionRenewal(reason:observedPosition:) -> Bool` PVM:4085
Triggers (5): `handlePlaybackError` :1557; proxy `onPlaybackSessionMissing` :2946 (`reason:"source_404"`); progress heartbeat PVM:7484 (`reason:"progress"`).
Conditions :4086-4092 — `!isDisposed`, `offlinePlaybackContext == nil`, `currentDeliveryStrategy == .direct`, `currentWatchDetail != nil`, `sourceProxy != nil`. Single-flight on `backgroundRenewalSessionId` :4095-4098.
Task PVM:4107: `sessionBridge.renewDirectSession(watchDetail:position:audioTrackIndex:nil, subtitleTrackIndex:nil)` :4110 → identity re-check `activePlaybackSessionId == staleSessionId` && proxy still live :4123 → `makeStreamRequest` :4129 → **`proxy.retargetOrigin(url:headers:)` :4138** (player, remuxer, cache untouched) → rewrites `activePlaybackSessionId`, `currentWatchDetail`, `currentSelectedVersion`, `activePreparedProtocolV3`, `adoptProtocolV3RenewalIntent`, `pendingExternalSubtitles`/`knownExternalSubtitles`, `loadPendingExternalSubtitles`, `duration`, `activeQualityId`, `qualityOptions`, clears both single-flights and the failure counter :4139-4152 → realtime unbind/rebind :4153-4156.
Failure classes: `DirectSessionRenewalError` ⇒ `failBackgroundRenewal` :4162 (escalate); any other error ⇒ `backgroundRenewalTransientFailures += 1`, escalate at ≥3 (PVM:601) else leave the flag clear so the 10 s heartbeat retries :4171-4194.
`failBackgroundRenewal` PVM:4199 → `attemptStaleSessionRenewal(reason: "<reason>_bg_renewal_failed")`.

### `attemptStaleSessionRenewal(reason:observedPosition:) -> Bool` PVM:4212
Triggers (5): `handlePlaybackError` :1560; replan catch :1664; proxy `onPlaybackSessionMissing` :2951; progress heartbeat :7490; `failBackgroundRenewal` :4205.
Conditions :4213-4216 — `!isDisposed`, `lastLoadRequest != nil`. Single-flight on `staleSessionRecoverySessionId` :4219-4224. Cancels the background renewal :4227-4229. Builds `renewalRequest` via `copyForRecovery` with the three resolved-track helpers (PVM:3549/3558/3589) :4239-4245. Task PVM:4249: `sessionBridge.syncProgress(forceOverwrite: true)` :4251 → `progressTask?.cancel()` → `beginFreshLoad(origin: .recovery, allowNearEndResume: true, preserveInterruptionState: true)` :4259.

### Origin-outage ride-through — `handleOriginOutageChanged(_:)` PVM:4280
Trigger: proxy `onOriginOutageChanged` :2967.
**Entry** (active) :4283-4322 — skipped if a visible outage recovery owns it :4285 or already active :4286; sets `sourceOutageActive`/`sourceOutageNoticeShown` :4287-4288; **`avPlayerBackend?.setExternalStallSuppression(true)` :4289** (backend side: `AVPlayerBackend.swift:644` → `setRecoverySuspended(_:reason: originOutageRecoverySuspensionReason)`); if already buffering, `noteBufferingDuringSourceOutage()` :4293; starts `sourceOutageRideThroughTask` :4297 — exponential poll `probeServerHealthOnce()` PVM:4353 (`/api/v1/health`; 401/403 counts as up) with delay `1 → ×2 → cap 8` (PVM:954-955) inside a `serverOutageRecoveryTimeout = 90 s` deadline (PVM:956); each success ⇒ `sourceProxy?.reprobeOrigin()` :4306. Budget exhausted ⇒ clears the flags, `setExternalStallSuppression(false)` :4316, then `attemptServerOutageRecovery(.networkUnavailable)` :4318.
**Exit** (inactive) :4323-4340 — `clearSourceOutageRideThroughState()` PVM:4343 (clears flags, un-suppresses, cancels the task) then **`avPlayerBackend?.kickPlaybackAfterExternalStallCleared()` :4331** (backend `AVPlayerBackend.swift:656`) — the second half of the two-owner handshake; optional "Reconnected" notice :4333.
`noteBufferingDuringSourceOutage()` PVM:4371 — the runway gate; shows "Reconnecting" once, duration = 90 s.

### `attemptServerOutageRecovery(reason:observedPosition:) -> Bool` PVM:4385
Triggers: proxy `onPlaybackSourceInterrupted` :2958; premature-source-end rung :1571; ride-through budget exhaustion :4318.
Conditions :4390-4394 — `!isDisposed`, `!hasReachedEndOfFile`, `lastLoadRequest != nil`; single-flight on `activeServerOutageRecoverySessionId` :4397-4399.
Mutations: bumps `serverOutageRecoveryGeneration` :4401, sets the single-flight :4403, cancels background renewal :4406-4409, `clearSourceOutageRideThroughState()` :4410; builds `recoveryRequest` :4415-4421; cancels `progressTask` :4427; **cache handoff policy** :4429-4436 — `.sourceEntityChanged` ⇒ `discardSourceCacheHandoff()`, otherwise `stashSourceCacheHandoff()`; stops the proxy :4437, disposes the backend :4439, clears overlay, `isPlaying = false`, `error = nil`, 90 s "Reconnecting" notice :4440-4447. Task :4449: `waitForServerReady(timeout:90, generation:)` PVM:4494 (same 1→8 s backoff, 401/403 = ready) → generation re-check :4455-4459 → not ready ⇒ clear + `finalizeTerminalPlaybackError("The server did not come back online in time.")` :4468 → ready ⇒ `beginFreshLoad(origin: .recovery)` :4475.
`clearServerOutageRecoveryState()` PVM:4486 — bump generation, nil the single-flight, cancel the task. Called from `handleFileLoaded` :1512, `handleEndOfFile` :3412, `beginFreshLoad` :3688, `finalizeTerminalPlaybackError` :4058, `handleBeginFreshLoadFailure(.recovery)` :3966, `suspendForBackground` :7620.

### Interruption recovery (tvOS-originated)
`pauseForForegroundInterruptionIfNeeded` PVM:7571 (out of range, called from `handleScenePhase` :4715) sets `playbackInterruption`. `shouldAutoRecoverFromInterruption` PVM:3999 — pending, not already auto-recovered, `Date() <= recoveryDeadline`. `triggerAutomaticInterruptionRecovery` PVM:4005 — latches `didAutoRecover`, `beginFreshLoad(origin:.recovery, preserveInterruptionState:true, allowNearEndResume:true)` :4016. `completeInterruptionRecoveryIfNeeded` PVM:3976 — clears when observed time ≥ `positionSeconds + 0.1` (PVM:953) or unconditionally when `requiresForwardProgress == false`.

### `finalizeTerminalPlaybackError(_:)` PVM:4027
DiagTrace breadcrumb (iOS/tvOS) :4035-4049 using `PlaybackFailure.stableToken(forLegacyMessage:)`; cancels `progressTask`, `staleSessionRecoveryTask`, `backgroundRenewalTask` :4051-4056 (deliberately does **not** sweep `.activeStream` — comment :4057-4059); `clearForegroundInterruptionState` / `clearSuspendedPlaybackState` / `clearServerOutageRecoveryState` / `discardSourceCacheHandoff` :4060-4063; disposes backend, stops proxy; nils `activePlaybackSessionId`, `activePreparedProtocolV3`, `activeExecutionPlan` :4062-4064; `error = message`, `clearLoadingOverlay(reason:"failure")`, `isPlaying = false`.

### Pre-emptive / non-user seeks in this range
- `commitSeek` PVM:5029 — the only ordinary seek; arms the filter + a 5 s timeout task.
- `beginReanchorSeekUI` PVM:5063 — arms the filter with **no** timeout task (`seekFilterTimeoutTask` explicitly cancelled and nilled :5069-5070) and sets `isLoading`.
- `keepWatchingCurrentEpisode` PVM:2087 — pre-emptive `commitSeek(to: duration - 10)` :2110 to escape the terminal postroll.
- `autoSkipIntroIfNeeded` PVM:5353 / `beginIntroAutoSkipCountdown` PVM:5384 (5 s countdown) / `autoSkipCreditsIfNeeded` PVM:5438 (`CreditsAutoSkipPolicy.target` PVM:21) — both issue `seekTo(seconds:)`; credits sets its latch *before* seeking :5453.
- Loopback pre-anchor seek PVM:5135 and HLS reanchor PVM:5078 (both rebuild the stream rather than seek).

---

## 5. TASKS AND TIMERS

### Registry keys used in this range (`PlayerTaskRegistry.swift:37-62`, 23 keys, 4 scopes)
| Key | VM accessor | Declared | Installed at | Scopes (registry:66-99) |
|---|---|---|---|---|
| `.cleanupCompletion` | `cleanupCompletionTask` | PVM:535 | out of range | none |
| `.suspendStopSession` | `suspendStopSessionTask` | PVM:543 | PVM:7633 | none |
| `.settingsRefresh` | `settingsRefreshTask` | PVM:623 | PVM:1105 | teardown |
| `.freshLoad` | `freshLoadTask` | PVM:627 | PVM:3713, **PVM:5223** | teardown, activeStream |
| `.protocolV3Replan` | `protocolV3ReplanTask` | PVM:632 | PVM:1626 | teardown, activeStream |
| `.progress` | `progressTask` | PVM:582 | PVM:7468 | teardown, activeStream |
| `.nextUpCountdown` | `nextUpCountdownTask` | PVM:644 | PVM:2024 | teardown, activeStream |
| `.autoSkipIntroCountdown` | `autoSkipIntroCountdownTask` | PVM:832 | PVM:5392 | teardown, activeStream |
| `.staleSessionRecovery` | `staleSessionRecoveryTask` | PVM:586 | PVM:4249 | teardown, sessionRecovery |
| `.backgroundRenewal` | `backgroundRenewalTask` | PVM:595 | PVM:4107 | teardown, sessionRecovery |
| `.sourceOutageRideThrough` | `sourceOutageRideThroughTask` | PVM:608 | PVM:4297 | teardown, sessionRecovery |
| `.serverOutageRecovery` | `serverOutageRecoveryTask` | PVM:614 | PVM:4449 | teardown, sessionRecovery |
| `.interruptionRecovery` | `interruptionRecoveryTask` | PVM:648 | PVM:4738 | teardown, sessionRecovery |
| `.nextUpLookup` | `nextUpLookupTask` | PVM:636 | PVM:1732 | teardown |
| `.nextUpOnDeck` | `nextUpOnDeckTask` | PVM:640 | PVM:1775 | teardown |
| `.deferredLiveSubtitleClose` | `deferredLiveSubtitleCloseTask` | PVM:798 | out of range | teardown |
| `.pictureInPictureBackgroundGrace` | (iOS) PVM:437 | PVM:437 | PVM:4815 | teardown |
| `.hideControls` | `hideControlsTask` | PVM:566 | PVM:7530 | teardown, interaction |
| `.noticeDismiss` | `noticeDismissTask` | PVM:570 | out of range | teardown, interaction |
| `.remoteDismiss` | `remoteDismissTask` | PVM:578 | out of range | teardown, interaction |
| `.skipDebounce` | `skipDebounceTask` | PVM:658 | PVM:5006 | teardown, interaction |
| `.seekFilterTimeout` | `seekFilterTimeoutTask` | PVM:697 | PVM:5053 | teardown, interaction |
| `.holdSeek` | `holdSeekTask` | PVM:668 | PVM:4916 | teardown, interaction |
| `.holdSeekAutoRamp` | `holdSeekAutoRampTask` | PVM:676 | PVM:4969 | teardown, interaction |

Scope sweeps invoked in range: `tasks.cancelAll(in: .interaction)` PVM:3480 (`resetPublishedLoadState`); `tasks.cancelAll(in: .interaction, .activeStream, .sessionRecovery)` PVM:7626 (`suspendForBackground`).

### Unregistered `Task {` / raw dispatch in lines 1–5535 (14 sites)
1. **PVM:1030** — `init`: detached `Task` that installs `observeConnectivity` + `observeUnavailability` on the realtime actor and stores the two tokens. Never cancelled; the tokens are the only handle.
2. **PVM:1323** — `onFirstFrame`: `Task { sessionBridge.reportProtocolV3FirstFrame(milliseconds:) }`.
3. **PVM:1360** — `onBufferingChange(true)`: `Task { @MainActor noteBufferingDuringSourceOutage() }`.
4. **PVM:1464** — `onExternalPlaybackUnavailable` (iOS): `Task { @MainActor showNotice("AirPlay Unavailable") }`.
5. **PVM:1569** — `handlePlaybackError` premature-source-end rung: `Task { @MainActor attemptServerOutageRecovery(.networkUnavailable) }`.
6. **PVM:1826** — `makeOnDeckItems`: `withTaskGroup` + `group.addTask` for parallel artwork resolution (structured; inherits `nextUpOnDeckTask`).
7. **PVM:2249** — `attemptNativeDirectRouteRecovery`: `Task { await loadStream(plan: fallbackPlan) }` — **launches a full stream load off any registry**.
8. **PVM:2943** — proxy `onPlaybackSessionMissing`: `Task { @MainActor }` → background then stale renewal.
9. **PVM:2958** — proxy `onPlaybackSourceInterrupted`: `Task { @MainActor attemptServerOutageRecovery(reason:) }`.
10. **PVM:2967** — proxy `onOriginOutageChanged`: `Task { @MainActor handleOriginOutageChanged(active) }`.
11. **PVM:3187** — `mutateSubtitleAppearance`: `Task { await setSubtitleAppearance(next) }`.
12. **PVM:3198** — `setSubtitlePosition`: `Task { [settings] await settings.setSubtitleAppearance(next) }`.
13. **PVM:3284** — `pushNowPlayingArtwork`: `Task { SiloAPI.shared.itemDetail(...) }` (network fetch).
14. **PVM:3381** — `handleEndOfFile` premature branch: `Task { @MainActor showNotice("Connection lost") }`.
15. **PVM:3439** — `handleEndOfFile` natural-end offline branch: `Task { @MainActor recordOfflineProgress(markCompleted: true) }`.
16. **PVM:5174** — `reloadLocalLoopbackForSeekBeforeAnchor`: `Task { await loadStream(plan: updatedPlan) }` — **second untracked full stream load**.
Locally-scoped structured tasks (not leaks, but hand-rolled): `startTask`/`timeoutTask` in `runStartSession` PVM:3863/3877; two `DispatchQueue.global` blocks + a manual `asyncAfter` timeout in `disposePlayerOffMain` PVM:3820/3826 arbitrated by `OneShotContinuation` (PVM:48-69).

### Timer-shaped loops in range
`sourceOutageRideThroughTask` poll loop PVM:4300-4312 (1→8 s, 90 s deadline); `waitForServerReady` PVM:4498-4522 (same shape); `nextUpCountdownTask` 1 Hz PVM:2026-2033; `autoSkipIntroCountdownTask` 1 Hz PVM:5392-5420; `holdSeekTask` 10 Hz PVM:4916-4926; `holdSeekAutoRampTask` PVM:4969; `skipDebounceTask` 200 ms trailing edge PVM:5006; `seekFilterTimeoutTask` 5 s one-shot PVM:5053; `pictureInPictureBackgroundGraceTask` 1 s one-shot PVM:4815; `interruptionRecoveryTask` 3 s one-shot PVM:4738; `progressTask` 10 s heartbeat PVM:7469 (out of range).

---

## 6. PLATFORM

**`handleScenePhase(_:)` PVM:4711** — three fully disjoint bodies:
- **tvOS** :4712-4753 — `.inactive` ⇒ `pauseForForegroundInterruptionIfNeeded()` PVM:7571; `.background` ⇒ `suspendForBackground()` PVM:7592; `.active` ⇒ if `isBackgroundSuspended`, only reveal controls and await an explicit resume :4720-4724; else if a pending interruption with `wasPlaying`, extend `recoveryDeadline` by 3 s, `isLoading = true`, `avPlayerBackend?.play()`, arm `interruptionRecoveryTask` :4738-4750 which calls `triggerAutomaticInterruptionRecovery()` on expiry.
- **macOS** :4754-4763 — `.background` ⇒ unconditional `avPlayerBackend?.pause()` if playing; `.inactive`/`.active` ⇒ nothing. No AirPlay/PiP/suspend handling.
- **iOS** :4764-4785 — writes `isSceneBackgrounded`; `.background` exempts (a) `isExternalPlaybackActive`, (b) `PictureInPictureCoordinator.shared.isEngaged`, (c) `isPossible` ⇒ `schedulePictureInPictureBackgroundGrace()` (1 s, PVM:4813), else `pauseBackgroundPlaybackIfUnrouted()` PVM:4829; `.active` cancels the grace task.

**`suspendForBackground()` PVM:7592** (tvOS) — guard not already suspended + `makeSuspendedPlaybackContext()` PVM:3643 (rebuilds a `LoadRequest` from `lastLoadRequest` + the three resolved-track helpers, snapshots `currentTime`); sets `suspendedPlayback`; then `clearForegroundInterruptionState`, `clearSourceOutageRideThroughState`, `clearServerOutageRecoveryState`, `cancelPendingIntroAutoSkip`, `cancelNextUpCountdown`, `backgroundRenewalSessionId = nil`, `tasks.cancelAll(in: .interaction, .activeStream, .sessionRecovery)`, `sleepTimer.cancel()`; UI reset :7628-7638; `nowPlaying.detach()`; `avPlayerBackend?.dispose()`; installs `suspendStopSessionTask` (unbind + `stopSession`) — registered but in **no** sweep, relying on the bridge's identity guard.
**`resumeSuspendedPlayback()` PVM:7640** — clears the context and `beginFreshLoad(resumePositionOverride: resumePosition, allowNearEndResume: true)`. Entry point: `togglePlayPause` PVM:4569-4573 (tvOS only).

**Output-route change** — `outputRouteObserverToken` PVM:1008, installed `#if !os(macOS)` in `init` PVM:1073-1099 on `AVAudioSession.routeChangeNotification` (main queue). Guards: `activePreparedProtocolV3 != nil`, `!isDisposed`, `!isLoading`; snapshot `ApplePlaybackV3Capabilities.snapshot()`; materiality via `PlaybackSessionBridge.isMaterialOutputRouteChange(activeOutputContextId:observedOutputContextId:)` PVM:1082; then `attemptProtocolV3Replan(classification: "output_route_changed", outputRouteSnapshot:)` PVM:1090. The *other* route-change owner is the backend's player-scoped KVO, which reaches the VM only as `onExternalPlaybackActiveChange` PVM:1444.
**System caption observer** — `systemCaptionObserverToken` PVM:1005, installed PVM:1060-1072; re-applies appearance, re-snapshots `subtitleOrderingLanguage`, and (when `!hasExplicitSubtitleChoice`) resets `prefsForCurrentItem` + `prefsResolvedForCurrentItem` and forces re-evaluation.
**iOS-only members:** `isSceneBackgrounded` :434, `pictureInPictureBackgroundGraceTask` :437, `supportsExternalPlayback` :445, `handleExternalPlaybackActiveChange` :4804, `schedulePictureInPictureBackgroundGrace` :4813, `handlePictureInPictureEngagementEnded` :4823, `pauseBackgroundPlaybackIfUnrouted` :4829, the `applyCallbacks` fork :1440-1490.
**tvOS-only members:** `TVHUDEntryPoint`/`requestedTVHUDEntryPoint` :306-311, `pauseForTimelineSelection` :4591, `PosterImageCache.trimDecodedMemory()` in `beginFreshLoad` :3679, suspend/resume machinery.
**macOS-only:** `backendCapabilities` uses `PlayerBackendCapabilities.macAVFoundation` PVM:339-341; no route observer.

---

## 7. EXISTING SEAMS (R1/R2 and rounds 5/6)

- **Typed failure channel landed.** `PlaybackFailure` (PlaybackFailure.swift:29) is the backend's `onError` type (`AVPlayerBackend.swift:580`, `PlayerCallbacks.onError` PVM:77). The four substring classifiers now have one owner: `classification(forLegacyMessage:)` PlaybackFailure.swift:166, `stableToken(forLegacyMessage:)` :183, `isPlaybackSessionMissing(legacyMessage:)` :195, `isPrematureSourceEnd(legacyMessage:)` :205. Typed shortcut exists only for `.writerFailed(.prematureSourceEnd, _)` (:158). VM-authored failures enter as `.unknown` via `PlaybackFailure(legacyMessage:)` (PVM:2733). The enum is **not** exhaustive over the review's §8 sketch — it still carries a `.unknown(String)` escape hatch.
- **Injected `AVPlayer`** exists at `AVPlayerBackend.swift:895` (`init(player: AVPlayer = AVPlayer())`) but the VM constructs `AVPlayerBackend()` with the default (PVM:1114) — the seam is available, unused.
- **No `protocol PlaybackBackend`.** `avPlayerBackend` PVM:326 is the concrete class; `makeAVPlayerBackend` PVM:1113 is the intended factory seam.
- **Bridge transport is NOT injected** — `PlaybackSessionBridge` still calls `SiloAPI.shared` directly (~19 sites, e.g. PlaybackSessionBridge.swift:701, :1132, :1453, :1560).
- **Recovery-suspension handshake is explicit and typed by reason string:** `AVPlayerBackend.serverReplanRecoverySuspensionReason` (backend :625) used at PVM:1624/1628; `setExternalStallSuppression` (backend :644 → `setRecoverySuspended(_:reason:)` :632) at PVM:4289/4318/4348; `kickPlaybackAfterExternalStallCleared` (backend :656) at PVM:4331.
- **`PlayerTaskRegistry`** (whole file) — scope-tagged task ownership, already a partial "effects run in one place" seam.
- **Pure policies already extracted and called from this range:** `CreditsAutoSkipPolicy.target` PVM:21 (called :5439); `PlayerNextUpCompletionPolicy.progressPosition` / `.isInPromptWindow` (:2165, :1968); `SourceCacheAdoptionPolicy.shouldAdopt` (:2874); `PlaybackStatsComposer.compose` (:1389); `SubtitleDisplayOrder.order` (:414); `ApplePlaybackQuality.playbackOptions/shouldForceTranscode/shouldReselectSource/normalizeStoredId/protocolV3QualityId` (:2613, :4626, :4640, :4602-4603); `AppleQualityAxes.resolvedBitrateCap` (:4623); `ApplePlaybackRoutePlanner.audioSelectionIndex/videoRange/normalizationSummary` (:3552, :2306, :2343); `ApplePlaybackV3PlanAdapter.*` (:2367, :3585, :898); `PlaybackSessionBridge.isMaterialOutputRouteChange` (:1082), `.isPlaybackSessionMissing` (:1663), `.diagnosticsPositionMilliseconds` (:3406, :4047).
- **Static (already-pure) VM predicates in range:** `shouldTreatPlaybackErrorAsNaturalEnd` PVM:1697; `needsServerReplanBeforeLoad` PVM:2426; `shouldAdoptBackendDuration` PVM:3117; `horizontalArtwork` PVM:1853; `nonEmpty` PVM:1890; plus (just past the boundary, but used from this range) `isCurrentStreamCallback` PVM:5918, `isUnexpectedBackwardPlaybackTime` PVM:5925, `protocolV3SidecarRestoreIntent` PVM:5898, `protocolV3PendingTrackIntent` PVM:5944.
- **`PlaybackAdoptionOrigin`** PVM:2437 is a partial reducer-intent type already: it names exactly what the three pipelines disagree about, including `reusesActiveEngine` PVM:2484.

---

## 8. PRESENTATION-MODEL vs CONTROL-PLANE SPLIT

**Clearly UI-projection / NowPlaying / progress / Next-Up / sleep-timer / marker glue (thin presentation model candidates)**
- Every stored/computed field in §1c, plus `orderedSubtitles` PVM:413, `routeStatusRows` PVM:361, `playbackRouteDisplay` PVM:355, `routeDecisionSummary` PVM:396, `routeWarnings` PVM:400, `backendCapabilities` PVM:338, `humanReadableRouteReason` (PVM:6787).
- Next-Up suite: `loadNextUpCandidate` :1714, `loadNextUpOnDeckItems` :1769, `resolveOnDeckItems` :1797, `makeOnDeckItems` :1823, `horizontalArtwork` :1853, `resolveNextUpEpisode` :1898, `updateNextUpPresentation` :1952, `shouldShowNextUpBeforeEnd` :1966, `showNextUpNow` :1975, `beginNextUpPostroll` :1980, `startNextUpCountdownIfNeeded` :2008, `updateNextUpCountdownForActivePlayback` :2038, `cancelNextUpCountdown` :2066, `cancelNextUpFlow` :2073, `cancelNextUpAutoPlay` :2081, `keepWatchingCurrentEpisode` :2087 (has one control-plane action: the `commitSeek` at :2110), `setNextUpAutoPlayEnabled` :2120, `completionProgressPositionForCurrentItem` :2164.
- NowPlaying glue: `pushNowPlayingArtwork` :3272, `preferredArtworkCandidate` :3309, `applyArtworkURLHints` :3321, `pushNowPlayingIfDue` :3328, `attachNowPlayingIfNeeded` :3451, the artwork hints :459-460, `lastNowPlayingPush` :465.
- Settings/appearance glue: `applySettingsToPlayer` :3160, `applySubtitleAppearanceToPlayer` :3167, `refreshSettingsFromServer` :3172, `setSubtitleAppearance` :3178, `mutateSubtitleAppearance` :3184, `setSubtitlePosition` :3191, `setSubtitleDeviceOverrideEnabled` :3204, `setSubtitleMatchesSystemAppearance` :3210, `setPlaybackSpeed` :3224, `beginHoldFastForward` :3237, `endHoldFastForward` :3246, `setVideoGravity` :3255, `setSubtitleSyncMilliseconds` :3259, `applyUserVolume` :1175, `applyUserMuted` :1182, `currentUserVolume` :1168.
- Scrub/hold-seek UI: `beginScrub` :5476, `updateScrub` :5487, `endScrub` :5494, `cancelScrub` :5528, `beginHoldSeek` :4896, `adjustHoldSeekRate` :4934, `commitHoldSeek` :4946, `cancelHoldSeek` :4958, `startHoldSeekAutoRamp` :4967, `tearDownHoldSeek` :4982, `queueSkipDebounce` :4994, `skipForward` :4844, `skipBackward` :4856, `skipIntro` :4868, `cancelIntroAutoSkip` :4877.
- Marker/chapter presentation: `applyMarkerRanges` :5325, `validTimeRange` :5342, `chapterInfoList` :3136, `beginIntroAutoSkipCountdown` :5384, `cancelPendingIntroAutoSkip` :5431, `currentIntroSkipKey` :5460, `currentCreditsSkipKey` :5468. (`autoSkipIntroIfNeeded` :5353 / `autoSkipCreditsIfNeeded` :5438 straddle: policy is pure, the `seekTo` is control-plane.)
- Sleep timer: `sleepTimer` :453 + `sleepTimer.configure` closure :1058 + `sleepTimer.cancel()` :7625.
- Offline progress reporting: `recordOfflineProgress` (:7503) and `offlineWatchedFraction` :721.

**Control-plane (reducer / session actor / engine session / RecoveryPolicy candidates)**
- Load pipeline: `beginFreshLoad` :3669, `runStartSession` :3840, `disposeActivePlayerForFreshLoad` :3798 + `disposePlayerOffMain` :3813 + `OneShotContinuation` :48, `adoptPreparedPlayback` :2531 + `PlaybackAdoptionOrigin` :2437, `loadStream` :2719, `makeExecutionPlan` :2350, `needsServerReplanBeforeLoad` :2426, `logExecutionPlan` :2378, `timelineOffset` :3072, `avPlayerTimelineOffset` :3099, `movieTime(for:)` :3130.
- Engine session: `makeAVPlayerBackend` :1113, `installBackend` :1123, **`prepareBackend` :1140**, `loadBackend` :1152, `makeCallbacks` :1211, `applyCallbacks` :1415, `wireSubtitleCallbacks` :1194, `reapplyUserGain` :1189.
- Source transport: `prepareSourceProxy` :2907, `stashSourceCacheHandoff` :2849, `discardSourceCacheHandoff` :2858, `takeAdoptableSourceCache` :2868, `sourceCacheBudget` :3034, `sourceBitrateBps` :3055, `initialSourcePrefetchOffset` :3065, `SourceProxyPreparation` :2827, `SourceProxyPreparationError` :2884.
- Recovery policy: `handlePlaybackError` :1537, `attemptProtocolV3Recovery` :1592, `attemptProtocolV3Replan` :1600, `attemptNativeDirectRouteRecovery` :2174, `attemptSiloRouteHLSFallback` :2258, `requestServerHLSRouteFallback` :2279, `makeLoopbackFallbackPlan` :2300, `attemptBackgroundSessionRenewal` :4085, `failBackgroundRenewal` :4199, `attemptStaleSessionRenewal` :4212, `handleOriginOutageChanged` :4280, `clearSourceOutageRideThroughState` :4343, `probeServerHealthOnce` :4353, `noteBufferingDuringSourceOutage` :4371, `attemptServerOutageRecovery` :4385, `clearServerOutageRecoveryState` :4486, `waitForServerReady` :4494, `finalizeTerminalPlaybackError` :4027, `handleBeginFreshLoadFailure` :3914, `shouldAutoRecoverFromInterruption` :3999, `triggerAutomaticInterruptionRecovery` :4005, `completeInterruptionRecoveryIfNeeded` :3976, `handleEndOfFile` :3343 (premature classifier :3355-3365), `handleFileLoaded` :1509.
- Seek coordinator: `commitSeek` :5029, `beginReanchorSeekUI` :5063, `reloadServerBackedHLSForSeek` :5078, `reloadLocalLoopbackForSeekBeforeAnchor` :5135, `restartCurrentTranscodeHLS` :5180, `seek(to:)` :5298, `seekTo(seconds:)` :5313.
- Identity/intent plumbing that must move onto `SessionIdentity`/`LoadID`: `resetPublishedLoadState` :3469, `resolvedAudioTrackIndexForResume` :3549, `resolvedSubtitleTrackIndexForResume` :3558, `resolvedProtocolV3SubtitleIndexForResume` :3576, `resolvedSidecarSubtitleTrackIdForResume` :3589, `adoptProtocolV3RenewalIntent` :3596, `rearmAdoptedProtocolV3TrackIntent` :3623, `armAdoptedProtocolV3TrackIntent` :3629, `applySidecarRestoreIntent` :2502, `makeSuspendedPlaybackContext` :3643, `clearForegroundInterruptionState` :3659, `clearSuspendedPlaybackState` :3665, `LoadRequest` :839, `LoadOrigin` :922, `TrackSelectionSnapshot` :729.
- Platform command surface: `handleScenePhase` :4711, `togglePlayPause` :4568, `pauseForTimelineSelection` :4591, `switchQuality` :4600, `loadAndPlay` :4529, `retry` :4557, plus the iOS AirPlay/PiP quartet :4804-4842.