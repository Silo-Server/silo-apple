<!-- Stage 2 inventory, generated 2026-08-19 by a read-only mapping agent at 20ba06b; line anchors are from that tip. -->

# STAGE 2 SOURCE INVENTORY — AVPlayerBackend / PlaybackSessionBridge / loopback lifecycle
Branch `player/architecture-remediation` @ 20ba06b. All anchors re-derived at CURRENT HEAD (review doc line numbers are stale; several Stage-0/Stage-1 fixes already landed — typed `onError`, `setRecoverySuspended`, `LoopbackRebuildBudget`, `LoopbackSessionSpec.withSource`).
Aliases: `B` = `iosApp/iosApp/Screens/Player/AVPlayerRoute/AVPlayerBackend.swift` (4,884); `PVM` = `iosApp/iosApp/Screens/Player/PlayerViewModel.swift` (7,872); `BR` = `iosApp/iosApp/Screens/Player/PlaybackSessionBridge.swift` (1,705).

---

## 1. BACKEND PUBLIC SURFACE (= the future `PlaybackBackend` protocol)

### 1.1 Construction / disposal
- `B:895 init(player: AVPlayer = AVPlayer())` — injectable player (Stage-1 seam already present). Installs the ONLY player-scoped KVO (`\.isExternalPlaybackActive`, B:908-919) plus `SubtitleSession` + `AVPlayerEmbeddedSubtitleExtractor` wiring (B:920-939). Caller: `PVM:1118` region (`makeAVPlayerBackend`).
- `B:942 deinit` → `dispose()`.
- `B:1391 func dispose()` — idempotent via `isDisposed`; invalidates `externalPlaybackObs`, nils `onExternalPlaybackActiveChange` + `isPictureInPictureActiveProvider`, then `teardownMediaPipeline()`. VM callers: `PVM:1124, 2247, 2582, 3821 (disposable.backend), 4064, 4437, 5240, 6381, 6435, 7628`.

### 1.2 Load / transport
- `B:946 func load(sessionSpec: LoopbackSessionSpec, startTime: Double)` — VM: `PVM:1164`.
- `B:958 func loadRemoteHLS(url: URL, headers: [String: String], startTime: Double)` — VM: `PVM:1157`.
- `B:967 func loadDirectFile(url: URL, headers: [String: String], startTime: Double)` — VM: `PVM:1159`.
  All three set `isUserPaused = false`, `loopbackRebuildBudget.reset()`, then private `load(strategy:startTime:)` `B:1732`.
- `B:976 func play()` — clears `isUserPaused`; fires `onPauseChange?(false)`; **has a hidden recovery branch**: if `pendingLocalLoopbackRecoveryMediaTime != nil` it issues a full reanchoring `load(.siloLoopback(spec.reanchored(at:)))` instead of `avPlayer.play()` (B:979-990). VM: `PVM:2111, 2114, 3458, 4581, 4735, 5519, 6499, 6511, 7710, 7869`.
- `B:993 func pause()` — sets `isUserPaused = true`, `loopbackItemDeathConfirmationState.resetCandidate()`, `onPauseChange?(true)`. VM: `PVM:1059, 2753, 3418, 3459, 4579, 4594, 4756, 4834, 6489, 6513, 6571, 7589, 7723, 7868`.
- `B:1152 func seek(to seconds: Double)` — media-time in; clears `hasReachedItemEnd`; on loopback latches `vodPendingSeekMediaTarget` and **drops `latestLoopbackGeneratedStats`**; `beginSeekDeadline(kind:.interactive)`; zero-tolerance seek; completion re-guards `completeSeekDeadline(seekID)` + `seekItem === currentItem`. VM: `PVM:3465, 5040`.
- `B:1387 func isPaused() -> Bool` (returns `isUserPaused`) — VM: `PVM:3462, 6509`.
- `B:1359 func currentTime() -> Double` (player axis, NOT media axis).
- `B:1402 func setSpeed(_ rate: Double)` — VM: `PVM:3162, 3226, 3240, 3249`.
- `B:1412 func setUserVolume(_ v: Float)` / `B:1420 func setUserMuted(_ m: Bool)` / `B:1424 var currentUserVolume: Float` — VM: `PVM:1180, 1184, 1190, 1191`.
- `B:1144 func setMediaTimelineOffset(_ offset: Double)` — VM: `PVM:2807`. Also self-called from the plan-resolved writer callback (B:2165) and `load()` (B:1783).
- `B:1133 func videoSurfaceBecameReadyForDisplay()` — called by the *view*, not the VM: `AVPlayerRoute/AVPlayerSurface.swift:127`, `macOS/AVPlayerSurface.swift:70`.

### 1.3 Recovery handshake (the two-owner protocol)
- `B:632 func setRecoverySuspended(_ suspended: Bool, reason: String)` — reason-counted `Set<String>`; `B:627 isRecoverySuspended`. VM: `PVM:1625` (set) / `PVM:1628` (defer clear) with `B:625 static let serverReplanRecoverySuspensionReason = "server_replan"`.
- `B:644 func setExternalStallSuppression(_ active: Bool)` — thin alias onto reason `B:621 originOutageRecoverySuspensionReason = "origin_outage"`. VM: `PVM:4288` (on), `PVM:4316`, `PVM:4346` (off).
- `B:656 @MainActor func kickPlaybackAfterExternalStallCleared()` — guards `!isDisposed`, `.siloLoopback`, `!isUserPaused`, `timeControlStatus == .waitingToPlayAtSpecifiedRate`, `bufferedAhead < 2.0`; then calls `performVODStallRecovery(attempt: 1, …)`. VM: `PVM:4331`.

### 1.4 Tracks / subtitles / chapters
- `B:1450 func selectAudioTrack(_ trackId: Int64)` — on loopback rebuilds the whole `LoopbackSessionSpec` field-by-field (B:1467-1489) and calls `load()`; off loopback it is `item.select(option, in: group)` + `emitTrackList()`. VM: `PVM:6903`.
- `B:1511 func selectSubtitleTrack(_ trackId: Int64?)` — 5-way route (tap / bitmap tap / extractor / sidecar / AVMediaSelection). VM: `PVM:6914`.
- `B:1613 func setSecondarySubtitleTrack(_ trackId: Int64?)` — VM: `PVM:7006`.
- `B:1646 func registerSidecarSubtitles(_ descriptors: [SidecarSubtitleDescriptor])` — VM: `PVM:6027, 6864`.
- `B:1661 func openLiveSubtitleTrack(slot: SubtitleSlot, label: String?, language: String?)` — VM: `PVM:7015`.
- `B:1666 func feedLiveSubtitleCue(slot: SubtitleSlot, eventText: String, startMs: Int64, durationMs: Int64)` — VM: `PVM:7026`.
- `B:1681 func closeLiveSubtitleTrack(slot: SubtitleSlot)` — VM: `PVM:7032`.
- `B:1433 func setSubtitleDelay(_ seconds: Double)` — VM: `PVM:3163, 3262`.
- `B:1440 func applySubtitleAppearance(_ appearance: SubtitleAppearance)` — VM: `PVM:3164, 3168`.
- `B:1685 func setServerChapters(_ chapters: [PlayerChapterInfo])` — replays `onChaptersChange` if `didFireFileLoaded`. VM: `PVM:1117, 2802`.

### 1.5 View-layer surface (NOT VM)
- `B:670 let avPlayer: AVPlayer` — `AVPlayerSurface.swift:75`, `macOS/AVPlayerSurface.swift:50-51`; the `AVPlayerLayer` built from it is what `iOS/PictureInPictureCoordinator.swift:58 attach(playerLayer:)` binds.
- `B:672 var subtitleOverlay: SubtitleOverlayView?`, `B:676 func attachSubtitleOverlay(_:owner:)`, `B:680 func detachSubtitleOverlay(owner:)`, `B:683 var subtitleRendererForOverlay: SubtitleRenderer?` — `AVPlayerSurface.swift:25-26, 33-34, 71, 96`.
- `B:686 var hasControlledSubtitleSelection: Bool` — `PVM:345`.
- `B:1031 var isExternalPlaybackActive: Bool` — `PVM:4770, 4831`. `B:1035 var isExternalPlaybackAllowed: Bool` — `PVM:1479`.

### 1.6 Callback closures (all `var … ?`, all set by `PVM applyCallbacks` around `PVM:1417-1478`)
| Line | Closure | Fired at |
|---|---|---|
| B:574 | `onTimeChange: ((Double) -> Void)?` | periodic observer B:2573, seek completion B:1204, initial start B:3730 |
| B:575 | `onDurationChange: ((Double) -> Void)?` | `durationObs` B:3396 |
| B:576 | `onPauseChange: ((Bool) -> Void)?` | `play()` B:977, `pause()` B:995, `rateObs` B:3313 |
| B:578 | `onFileLoaded: ((String) -> Void)?` | `finishInitialLoadIfNeeded` B:4242 (carries gate release reason) |
| B:579 | `onFirstFrame: ((Int) -> Void)?` | TTFF emit B:1725 |
| B:580 | `onError: ((PlaybackFailure) -> Void)?` | `reportFailure` B:4665 → `PVM:1422` → `handlePlaybackError` `PVM:1537` |
| B:581 | `onEndOfFile: (() -> Void)?` | `.AVPlayerItemDidPlayToEndTime` B:3423 |
| B:582 | `onBufferingChange: ((Bool) -> Void)?` | `bufferEmptyObs` B:3375, `bufferFullObs` B:3383 |
| B:583 | `onBufferedAheadChange: ((PlaybackBufferedAhead) -> Void)?` | `emitBufferedAhead` B:2614 |
| B:584 | `onPlaybackStatsChange: ((PlaybackStats) -> Void)?` | B:2755 |
| B:585 | `onTracksChange: (([PlayerTrack]) -> Void)?` | `emitTrackList` B:4316 / B:4335 |
| B:586 | `onChaptersChange: (([PlayerChapterInfo]) -> Void)?` | B:4245, B:1689 |
| B:587 | `onTimelineOffsetChange: ((Double) -> Void)?` | B:1146 |
| B:592 | `onExternalPlaybackActiveChange: ((Bool) -> Void)?` | player KVO B:916 → `PVM:1443` |
| B:596 | `onExternalPlaybackAllowedChange: ((Bool) -> Void)?` | `setExternalPlaybackAllowed` B:1090 → `PVM:1452` |
| B:599 | `onExternalPlaybackUnavailable: (() -> Void)?` | `abandonExternalPlaybackHandoff` B:1130 → `PVM:1461` |
| B:604 | `onSidecarTracksRegistered: (([SidecarSubtitleDescriptor]) -> Void)?` | B:922 → `PVM:1196` |
- **Inbound providers (backend pulls from VM):** `B:603 isPictureInPictureActiveProvider: (() -> Bool)?` (`PVM:1440`); `B:608 proxyStatsProvider: (() -> PlaybackSourceProxyStats?)?` (`PVM:2809`); `B:612 sourceOutageStateProvider: (() -> Bool)?` (`PVM:2812`, forwarded to the writer at B:2088).

### 1.7 Static helpers on the class (pure, callable without an instance)
`B:1069 isReceiverFetchableAsset(url:headers:) -> Bool`; `B:1077 isLoopbackHost(_:) -> Bool`; `B:1831 vodRetentionBudgetBytes() -> Int64`; `B:1844 vodRetentionBudget(availableBytes: Int64?) -> Int64`; `B:561 loopbackSteadyStateForwardBufferTarget`; `B:621/625` suspension reason keys.

### 1.8 Failure channel
`PlaybackFailure` (`AVPlayerRoute/../PlaybackFailure.swift:29`) is already typed. Cases: `.itemFailed(ItemFailure)` :76, `.loopbackServerBindFailed(detail:)` :78, `.loopbackPlaylistURLUnavailable` :80, `.loopbackRebuildBudgetExhausted(reason:rebuilds:)` :82, `.loopbackStartupBackstop(seconds:requestsServed:stage:)` :84, `.loopbackStartupStalled(trigger:)` :86, `.loopbackStartupItemUnreloadable` :88, `.writerFailed(kind:detail:)` :90, `.unknown(String)` :93. `WriterFailureKind` :60 (prematureSourceEnd/initSegmentMissing/unsupportedSelectedAudioCodec/sourceUnavailable/remux/other). Legacy string bridge still present: `.legacyMessage` :104, `.classification` :143, `.stableToken` :148, `.isPlaybackSessionMissing` :153, `.isPrematureSourceEnd` :159 plus four `forLegacyMessage` statics :169/:187/:202/:212.
`reportFailure` sites (9): B:2049 (server bind), B:2180 (writer onFinished), B:2280 (playlist URL), B:3643 (rebuild budget), B:3868 (startup backstop), B:3899 (startup stalled), B:3931 (item unreloadable), B:4812 (item failed), definition B:4665.

---

## 2. THE IN-ROUTE RECOVERY LADDERS

All constants are `private static` on `AVPlayerBackend` unless noted.

### S — STARTUP LADDER (pre-`didFireFileLoaded`, loopback only)
- Arm: `B:3811 armLoopbackStartupWatchdogIfNeeded()` from `finishPreparingAssetPlayback` B:2404. Timer 1 Hz `B:440 loopbackStartupWatchdogTickSeconds = 1.0`.
- Observation: `segmentServer.servedRequestCount` delta (B:3843-3847) → `loopbackStartupLastProgressAt`; `isTVDisplayModeSwitchInProgress()` re-bases progress (B:3849-3853).
- Policy: `LoopbackStartupRecoveryPolicy.verdict(secondsSinceProgress:secondsSinceStart:displayModeSwitchInProgress:stallWindow:absoluteBackstop:)` (`LoopbackStartupRecoveryPolicy.swift:31`). Thresholds injected: `B:441 loopbackStartupStallWindowSeconds = 6.0`, `B:442 loopbackStartupAbsoluteBackstopSeconds = 60.0`.
- Ladder: `B:3883 escalateLoopbackStartupRecovery(trigger:)` over `B:816 enum LoopbackStartupRecoveryStage { initial, nudged, reloaded }`:
  `.initial` → `B:3907 nudgeLoopbackStartupConsumer()` (zero-tolerance seek to `playerTime(forMediaTime: pendingStartTime)` + gate rebase);
  `.nudged` → `B:3927 reloadLoopbackStartupItem()` (detach observers, fresh `AVPlayerItem` on same URL, `applyLoopbackItemBufferPolicy(.startup)`, clears `hasReachedItemEnd`, `replaceCurrentItem`, re-issue VOD pre-seek);
  `.reloaded` → `reportFailure(.loopbackStartupStalled(trigger:))`.
  `.failBackstop` verdict → `reportFailure(.loopbackStartupBackstop(60, served, stage))` B:3868.
- Direct entry (bypasses the tick): errorLog `-15628` while `!didFireFileLoaded` → `escalateLoopbackStartupRecovery(trigger:"errorLog_-15628")` B:3499.
- Reset: `armLoopbackStartupWatchdogIfNeeded` re-sets stage/startedAt/lastProgress/lastRequestCount each load. Cancel: `B:3956 cancelLoopbackStartupWatchdog()` from status `.readyToPlay` B:3300, status `.failed` B:3303, `finishInitialLoadIfNeeded` B:4240, teardown B:4599.
- Suppression: `escalateLoopbackStartupRecovery` guards `!isRecoverySuspended` (B:3884). The **tick's `failBackstop` arm does NOT check suspension** — it can fire and report during a VM replan.
- Mutual exclusion with P: S guards `!didFireFileLoaded` (B:3831), P guards `didFireFileLoaded` (B:3014). Clean.

### P — PLAYHEAD-WEDGE / STARVATION / ITEM-DEATH-CONFIRMATION (one 1 Hz tick)
`B:2990 installLoopbackPlayheadWatchdog()` (from `startSiloLoopback` B:1984) → `B:3010 loopbackPlayheadWatchdogTick()`. Tick 1 s `B:491 playheadWatchdogTickSeconds = 1.0`.
Entry guards B:3011-3015: `!isDisposed`, `.siloLoopback`, `currentItem`, `didFireFileLoaded`, `!isSeekPending`.
Observations computed each tick: `position`, `stationaryFor` (advance tracked by |Δ|>0.05 in EITHER direction, B:3027-3032), `timeControlStatus`, `bufferedAhead` (`playableAheadSeconds`), `generatedAhead` (`latestLoopbackGeneratedStats.playlistVisibleEndSeconds ?? store.stats().generatedMediaSeconds`), `segmentStore.secondsSinceLastSegmentServe()`.

Rungs in tick order:
1. **Telemetry** every 3 s (B:3057) — `[CMP-AVP] loopback playhead state` + `[CMP-MEM]` footprint. Not suppressed.
2. **Item-death confirmation** B:3089 — `LoopbackItemDeathConfirmationState.evaluate(now:position:playbackEstablished:userPaused:transportState:recoverySuppressed:mediaAvailableAhead:)`. Constants `B:145 confirmationSeconds = 3.0`, `B:146 progressCancellationThresholdSeconds = 0.5`; `mediaAvailableAhead = bufferedAhead >= 0.5 || generatedAhead >= 2.0`. Actions: `.reassertPlay` → bare `avPlayer.play()` (B:3105); `.confirmed(trigger)` → `LoopbackItemDeathRecoveryState.confirm` → `performLoopbackItemDeathRecoveryAction` (rung D). Runs **before** the suspension gate but takes `recoverySuppressed` as an input, so it degrades to `.none`.
3. **Suspension gate** B:3131 `if isRecoverySuspended { return }` — everything below is muzzled.
4. **Starvation escalation** B:3136-3147: `!isUserPaused && tc == .waitingToPlayAtSpecifiedRate && bufferedAhead < 2.0 && stationaryFor >= B:505 playheadWatchdogStarvationEscalateSeconds (30.0) && secondsSinceLastSegmentServe >= B:506 playheadWatchdogStarvationServeQuietSeconds (15.0) && !didEscalateLoopbackStall` → `didEscalateLoopbackStall = true`; `rebuildSiloLoopbackSession(at:reason:"loopback_starvation")`.
5. **Wedge qualification** B:3151-3159: `believesPlayable = tc == .playing || (tc == .waiting && bufferedAhead >= 2.0)`; requires `!isUserPaused`, `stationaryFor >= B:492 playheadWatchdogStallSeconds (10.0)`, `generatedAhead >= B:495 playheadWatchdogMinGeneratedAhead (12.0)`.
6. **Rolling window reset** B:3164-3169: if window empty or `now - windowStart > B:497 playheadWatchdogReanchorWindowSeconds (90.0)` → `windowStart = now; watchdogReanchorCount = 0; didEscalateLoopbackStall = false`.
7. **Exhaustion** B:3171-3179: `watchdogReanchorCount >= B:496 playheadWatchdogMaxReanchors (3)` and `!didEscalateLoopbackStall` → latch + `rebuildSiloLoopbackSession(reason:"playhead_watchdog")`.
8. **Fetch-high-water bail** B:3181-3189: `secondsSinceLastSegmentServe < 4.0` → return (consumer is filling, not wedged).
9. **Reanchor attempt** B:3191-3199: `watchdogReanchorCount += 1`; `Task { performVODStallRecovery(attempt:count, frozenPosition:position) }`.

`B:1917 performVODStallRecovery(attempt:frozenPosition:)` (also entered from `kickPlaybackAfterExternalStallCleared` B:667 and the interactive seek deadline B:1310): anchor = `vodPendingSeekMediaTarget` if latched else frozen position; always issues `requestVODProducerRestart(at: plan.segmentIndex(forPlaylistSeconds:), authoritative: true)`; then `attempt <= 1` → `cancelPendingSeeks()` + `performRecoverySeek(reason:"vod_stall_nudge")` + `avPlayer.play()`; `attempt > 1` → `reloadEstablishedLoopbackItem(item, at: anchor, reason:"vod_stall")`.

### D — ITEM DEATH (evidence-based)
- Classifier `B:75 LoopbackItemDeathRecoveryState.isItemDeath(statusCode:errorDescription:)`: `-12889`, `-15628`, substring `"-12889"`, substring `"No response for media file"`.
- Evidence sources: item errorLog notification B:3484-3494 (weight `2` when `-15628`, else `1`); `.AVPlayerItemFailedToPlayToEndTime` → `recoverLocalLoopbackFailureIfNeeded` B:3536-3543 (weight `2`); post-`didFireFileLoaded` failedToEnd instead routes to `noteExplicitFailure` on the confirmation state (B:3454-3460).
- Entry `B:3569 handleLoopbackItemDeathEvidence(item:statusCode:errorDescription:evidenceWeight:trigger:)` guards `.siloLoopback`, `item === currentItem`, `didFireFileLoaded`, `!isRecoverySuspended`.
- Accumulator `B:82 record(position:evidenceWeight:userPaused:)`: constants `B:67 matchingPositionToleranceSeconds = 2.0`, `B:68 evidenceRequired = 2`, `B:69 maximumReloads = 1`. Position drift > 2 s resets evidence **and** reloads. `userPaused` → `.waitForConfirmation` always.
- Actions `B:3596 performLoopbackItemDeathRecoveryAction`: `.waitForConfirmation` → log; `.reload(attempt)` → `resetCandidate()` + `reloadEstablishedLoopbackItem(reason:"item_death_<trigger>_<attempt>")`; `.escalate` → `resetCandidate()` + `rebuildSiloLoopbackSession(reason:"loopback_item_death")`.

### E — EDGE WATCHDOG (playlist advances, loaded edge does not)
- `B:3201 sampleLocalLoopbackEdge(item:referenceTime:trigger:)`, sampled from the 10 Hz time observer (B:2579, trigger `"time"`) and every `onGeneratedMediaStats` (B:2255, trigger `"generated_stats"`).
- State `B:779 struct LoopbackEdgeWatch { lastLoadedEnd, lastLoadedEndAdvancedAt, lastPlaylistEnd, lastPlaylistHash }` (`B:785`), first sample only seeds.
- Thresholds: loaded-advance epsilon `0.25`; playlist-advance epsilon `0.25` OR body-hash change; fire requires `playlistAdvanced && !loadedAdvanced && loadedAhead <= 1.0 && visibleAhead >= max(6.0, targetDuration + longestSegmentDuration) && now - lastLoadedEndAdvancedAt >= max(3.0, targetDuration*2 + 1)` (B:3235-3243).
- Action: `recoverLocalLoopbackStallIfNeeded(item:requireBufferedEdge: true, reason:"edge_watchdog")`.
- Guards: `!isUserPaused`, `!isSeekPending`, `didFireFileLoaded`, `item === currentItem`. Reset: `loopbackEdgeWatch = nil` in `load()` B:1758 and teardown B:4632.

### X — `.AVPlayerItemPlaybackStalled`
- B:3428-3439 → `recoverLocalLoopbackStallIfNeeded(item:)` with defaults `requireBufferedEdge: true, reason: "stall"`.

### Y — "Playlist File unchanged" / `-12888`
- `B:3553 recoverLocalLoopbackFailureIfNeeded` tail: substring match on `"Playlist File unchanged"` or `"-12888"`; anything else **silently returns** (B:3553-3555 guard).
- If `isUserPaused`, latches `pendingLocalLoopbackRecoveryMediaTime` (B:3561) — consumed only by `play()` B:980. Otherwise `recoverLocalLoopbackStallIfNeeded(requireBufferedEdge: false, reason:"playlist_unchanged")`.

### Shared reanchor rung
`B:3666 recoverLocalLoopbackStallIfNeeded(item:requireBufferedEdge:reason:)` — guards `.siloLoopback(spec)`, `item === currentItem`, `didFireFileLoaded`, `!isUserPaused`, `!isRecoverySuspended`; **10 s cooldown** `now - lastLocalLoopbackStallRecoveryAt >= 10` (B:3677, literal); `bufferedAhead <= 0.5` when `requireBufferedEdge`; `generatedAhead > (playerSeconds < 10 ? loopbackStartupForwardBuffer (4.0) : 10)` (B:3686). Action: `subtitleSession.flushOnSeek()`, `extractor.seek()`, full `load(.siloLoopback(spec.reanchored(at: mediaSeconds)), startTime:)`.

### Auto-resume rung
`B:3698 resumeLocalLoopbackPlaybackIfNeeded(for:trigger:)` — from `isPlaybackLikelyToKeepUp` KVO B:3385 and `loadedTimeRanges` KVO B:3405. Guards include `!hasReachedItemEnd` (B:3705, the #15 fix) and `!isRecoverySuspended`; requires `avPlayer.rate == 0` and `isPlaybackLikelyToKeepUp || bufferedAhead > 0.5`; action `avPlayer.play()`.

### Rebuild (terminal in-route rung)
`B:3635 rebuildSiloLoopbackSession(at:reason:)` — guards `.siloLoopback(spec)`, finite, `!isUserPaused`; **`LoopbackRebuildBudget.consume()`** (`B:41 maximumRebuildsPerLoad = 2`) else `reportFailure(.loopbackRebuildBudgetExhausted)`. On success resets `loopbackItemDeathRecoveryState`, `loopbackItemDeathConfirmationState.resetCandidate()`, `watchdogReanchorCount = 0`, `watchdogReanchorWindowStartWall = now`, `didEscalateLoopbackStall = false`, then full `load(reanchored)`. Budget reset ONLY in the three public `load*` entry points (B:951/960/969).

### VM-side rungs it interacts with
- `PVM:1537 handlePlaybackError(_ failure: PlaybackFailure)` order: EOF suppress `:1540` → active outage-recovery suppress `:1544` → near-end⇒EOF `:1548` (`shouldTreatPlaybackErrorAsNaturalEnd`, constants `PVM:960 nearEndPlaybackErrorThresholdSeconds = 8`, `PVM:964 nearEndPlaybackErrorMaxBufferedAheadSeconds = 1`) → `activePreparedProtocolV3 != nil` ⇒ `attemptProtocolV3Recovery` `:1553` → session-missing renewal `:1557-1563` → premature-source-end⇒outage `:1565` → interruption `:1580` → `attemptNativeDirectRouteRecovery` `:1584` → `attemptSiloRouteHLSFallback` `:1587` → terminal `:1590`.
- `PVM:1600 attemptProtocolV3Replan(...)` holds `setRecoverySuspended(true, reason:"server_replan")` at `PVM:1625` for the whole round trip, released in `defer` `PVM:1628`.
- `PVM:4279 handleOriginOutageChanged(_:)` ride-through: `setExternalStallSuppression(true)` `PVM:4288`; health poll loop with `PVM:954 serverOutageRecoveryInitialDelay = 1`, `PVM:955 serverOutageRecoveryMaxDelay = 8` (doubling), `PVM:956 serverOutageRecoveryTimeout = 90` budget; on exhaustion → suppression off + `attemptServerOutageRecovery`; on origin recovery → `clearSourceOutageRideThroughState()` + `kickPlaybackAfterExternalStallCleared()` `PVM:4331`.

### TIMER / WATCHDOG INVENTORY (period — owner — reset)
| # | Timer | Period / budget | Owner | Reset/cancel |
|---|---|---|---|---|
| 1 | startup watchdog `Timer` B:3819 | 1.0 s tick | backend | `cancelLoopbackStartupWatchdog` B:3956 |
| 2 | startup stall window | 6.0 s (B:441) | policy | any served-request delta / mode switch |
| 3 | startup absolute backstop | 60.0 s (B:442) | policy | per-arm `loopbackStartupWatchdogStartedAt` |
| 4 | playhead watchdog `Timer` B:2992 | 1.0 s tick | backend | teardown B:4577 |
| 5 | playhead stall | 10.0 s (B:492) | backend | any |Δpos|>0.05 |
| 6 | reanchor budget | 3 per 90 s (B:496/497) | backend | window expiry, rebuild |
| 7 | starvation escalate | 30 s + serve-quiet 15 s (B:505/506) | backend | `didEscalateLoopbackStall` (reset by rebuild + window expiry) |
| 8 | reanchor cooldown | 10 s literal B:3677 | backend | `lastLocalLoopbackStallRecoveryAt`, zeroed in `load()` B:1761 |
| 9 | fetch-high-water bail | 4.0 s B:3184 | backend | store serve timestamp |
| 10 | seek deadline `DispatchWorkItem` B:1218/1223 | 15.0 s (B:443) | backend | `completeSeekDeadline` / `cancelSeekDeadline` |
| 11 | initial-seek retry | 8 × 200 ms (B:1329-1332) | backend | `initialSeekRetryCount` zeroed B:1773/B:4588 |
| 12 | item-death confirmation | 3.0 s (B:145) | pure state | position drift > 0.5 s |
| 13 | edge watchdog delay | `max(3.0, targetDuration*2+1)` B:3236 | backend | loaded-edge advance |
| 14 | initial video display fallback tick | 3.0 s (B:473), re-arming | backend | gate release B:4140 |
| 15 | initial video display backstop | 15.0 s (B:474) | backend | gate release |
| 16 | tvOS display-mode settle `Task` B:2308 | poll 100×10 ms start + 50×100 ms settle (`HDRDisplayCriteriaPolicy:73-76`) | backend | `displayModeSettleTask.cancel()` B:4600 |
| 17 | periodic time observer B:2564 | 0.1 s | backend | teardown B:4562 |
| 18 | subtitle display link B:2587/2595 | 1/60 s | backend | teardown B:4565 |
| 19 | VOD segment-miss wait | 8.0 s (B:1808) | server resolver | store `waitForSegment` deadline |
| 20 | writer blocking read span | `readDeadlineSeconds` (writer:2219) / open `openDeadlineSeconds` (writer:2306) | `LoopbackInterruptToken` | `endBlockingSpan` |
| 21 | outage park backstop | 240 s (`LoopbackInputHandoff.swift:18`) | interrupt token | token cancel |
| 22 | VM progress loop | 10 s (`PVM:7470`) | VM | task registry |
| 23 | VM outage ride-through | 1→8 s backoff, 90 s budget (`PVM:954-956`) | VM | `clearSourceOutageRideThroughState` |
| 24 | VM interruption resume threshold | 0.1 s (`PVM:953`) | VM | — |

---

## 3. IDENTITY / STALENESS IDIOMS IN THE BACKEND

Four distinct idioms, none unified:
1. **`activeLoopbackSessionID: String?`** (`B:831`) — UUID string minted at `B:1982`, cleared at `B:4584`. **14 comparison guards**: B:1858 (restart precondition), B:2046, B:2058 (server-bind race), B:2099, B:2139, B:2150, B:2160, B:2178, B:2193, B:2218, B:2231, B:2254 (writer callbacks), B:2266 (`handleFirstSegmentReady`), B:2311 (display-settle task). String equality, no type.
2. **`loopbackGeneration: UInt64`** (`B:832`) — `&+= 1` at B:1985; the value is read exactly once (B:1986) and handed to `LoopbackSegmentStore(generation:)`. **It is never compared for staleness in the backend** — it is a store-scoped tag only. Effectively vestigial as an identity idiom.
3. **`item === currentItem` reference identity** — 17 sites: B:1194, B:1267, B:1331, B:1949, B:3203, B:3445, B:3479, B:3577, B:3615, B:3672, B:3700, B:3719, B:3750, B:4070, B:4128, B:4259, B:4266.
4. **`AVPlayerSeekDeadlineState` monotonic ID** (`B:11`, field B:705) — `begin()` B:1217, `complete(id)` B:1231, `cancel()` B:1251. Guards late/superseded seek completions at B:1186, B:1267, B:1348. Paired redundantly with `isSeekPending` (B:704) and `isInitialSeekInFlight` (B:724) plus `activeSeekDeadlineKind` (B:721) — a four-way representation of "a seek is outstanding".
5. **`isDisposed`** (`B:703`) — 53 occurrences; the universal escape hatch on every async hop.
6. **`didFireFileLoaded`** (`B:700`) — 18 read sites; the de-facto "playback established" phase bit that partitions S from P/D/E.

Not identity-guarded but session-lifetime state that survives `teardownMediaPipeline` (i.e. leaks across reanchors/rebuilds): `loopbackVODPlan`/`loopbackVODPlanSourceURL` (B:1798/1799 — keyed only by `sourceURL` equality, B:1801), `activeVODWriterBaseIndex`/`activeVODWriterHeadIndex` (B:1814/1821), `vodRestartCoalescer` (B:1813), `loopbackSubtitleTap`/`loopbackSubtitleTapSourceURL` (B:759/760, reset by URL change only, B:2445), `watchdogReanchorCount`/`watchdogReanchorWindowStartWall`/`didEscalateLoopbackStall`, `loopbackRebuildBudget`.

---

## 4. LOOPBACK LIFECYCLE

### 4.1 `startSiloLoopback(sessionSpec:)` `B:1979` — ordered steps
1. `sessionID = UUID().uuidString`; `activeLoopbackSessionID = sessionID` (B:1982-1983).
2. `installLoopbackPlayheadWatchdog()` (B:1984) — watchdog armed **before** any component exists.
3. `loopbackGeneration &+= 1` (B:1985).
4. `sessionDirectory = tmp/silo-dv-hls-debug/<sessionID>` (B:1987-1990); `debugDirectory` non-nil only under `SILO_KEEP_DV_HLS` (B:1992, gate `B:4822 keepLoopbackArtifacts` reading `ProcessInfo.environment["SILO_KEEP_DV_HLS"]`, B:4823).
5. `LoopbackSegmentStore(generation:memoryBudgetBytes:spillPolicy:debugDirectory:)` (B:1993) — budget `B:508 96 MiB constrained / 128 MiB` ; spill `B:567 generatedHLSSpillPolicy` with `B:507 generatedHLSSpillBudgetBytes = 4 GiB`.
6. `store.configureVODRetention(budgetBytes: vodRetentionBudgetBytes())` (B:2001) → `PlaybackDiskBudget.retentionBudget` (cap 2 GiB, floor 512 MiB).
7. `segmentStore = store`.
8. `LoopbackSegmentServer(segmentStore:exposure:)` — `.localNetwork` on iOS only (B:2008 vs B:2010).
9. `server.vodSegmentMissResolver` (B:2018-2026): hops to main for `requestVODProducerRestart(at:)`, then blocks on `store.waitForSegment(named:deadline: +8 s)`.
10. `segmentServer = server` **before** bind (B:2031, so a synchronous dispose can cancel the listener).
11. `Task { try await server.start() }` (B:2036-2062): bind failure → nil out `segmentServer`, guard `activeLoopbackSessionID == sessionID`, `reportFailure(.loopbackServerBindFailed)`. Success → two session guards → `startSiloLoopbackWriter(...)`.

### 4.2 `startSiloLoopbackWriter(sessionID:sessionSpec:sessionDir:segmentStore:vodBaseIndex:recycledInput:)` `B:2070`
`LoopbackSegmentWriter(sessionSpec:outputDirectory:segmentStore:vodPlan:vodBaseIndex:recycledInputHandoff:)` B:2078 → `ensureLoopbackSubtitleTap(for: sourceURL)` B:2086 (tap reused iff same source URL) → wires 13 callbacks, every one of them re-guarding `activeLoopbackSessionID == sessionID`:
`isSourceOutageActive` (B:2089, pulls `sourceOutageStateProvider`), `onSubtitleTapTracks`/`onSubtitleTapCue` (B:2092/2095), `onBitmapSubtitleTapTracks` (B:2098, re-routes a pending selection), `onBitmapSubtitleTapCue` (B:2115), `setBitmapSubtitleTapStream` (B:2122, selection survives restarts), `segmentStore.declareVODTarget(vodBaseIndex)` (B:2130), `onVODProducerAnchored` (B:2136), `onSegmentAppended` (B:2148 → head index), `onSegmentPlanResolved` (B:2157 → `loopbackVODPlan`, `server.setVODSegmentCount`, `setMediaTimelineOffset(plan.anchorSourceSeconds)`), `onFirstSegmentReady` (B:2170), `onFinished` (B:2175 → `reportFailure(.writerFailed)`), `playbackPositionProvider` (B:2186), `onSourceDownloadStats` (B:2189), `onGeneratedMediaStats` (B:2214), `onBridgedAudioAnchored` (B:2228), `onHDR10PlusMetadataDetected` (B:2245, installed only for `.passthroughHEVC` non-HLG non-SDR). Then `segmentWriter = writer; writer.start()` (B:2261-2262).

### 4.3 First-segment → item attach `B:2265 handleFirstSegmentReady(playlistName:sessionID:)`
Session guard → `currentItem == nil` guard → AirPlay URL choice (`server.resourceURL(for:reachableFromExternalDevice:)`, fallback `abandonExternalPlaybackHandoff`) → `loopbackPlaylistName`, `loopbackPlaybackUsesExternalURL`, `server.setAcceptsExternalClients` → `applyTVDisplayCriteriaForLoopbackIfNeeded(context:)` `B:4720` (writes criteria synchronously, returns "needs settle wait") → either `attachLoopbackItem(url:)` immediately or, on tvOS, `displayModeSettleTask = Task { await TVDisplayCriteria.waitForModeSwitchSettle(); … attachLoopbackItem }`.
`B:2332 attachLoopbackItem(url:)` → `prepareAssetPlayback(url:headers: [:], completion: issueVODResumePreSeekIfNeeded)`.
`B:2374 finishPreparingAssetPlayback` ordering (**load-bearing**): `applyLoopbackItemBufferPolicy(.startup)` → `currentItem = item` → `beginInitialVideoDisplayGate()` → `attachItemObservers(item)` → `avPlayer.replaceCurrentItem` → `armLoopbackStartupWatchdogIfNeeded()` → `installPeriodicTimeObserver()` → `installSubtitleDisplayLink()`.

### 4.4 Producer restart (writer only) `B:1852 requestVODProducerRestart(at:authoritative:)` — `@MainActor`
Guards: `!isDisposed`, `.siloLoopback(spec)`, `vodPlanForCurrentSource(spec:)` non-nil (URL-keyed, B:1801), `plan.segmentCount > 0`, `segmentStore`, `activeLoopbackSessionID`, `sessionDirectory`.
Coverage bail B:1861-1877: target within `[base, base + B:1811 vodProducerCoverageWindow(8)]` **and** `target <= max(head, base-1) + B:1825 vodProducerMarchAllowance(2)`.
Loop: `vodRestartCoalescer.begin(current, authoritative:)` (`LoopbackRestartCoalescer.swift:27`) → build `LoopbackInputHandoff`, `retiring.stop(recyclingInputInto: h)` → `startSiloLoopbackWriter(vodBaseIndex: current, recycledInput: handoff)` → `next = coalescer.next(justRan: current)`.
Three requesters: server miss resolver (B:2020), `performVODStallRecovery` (`authoritative: true`, B:1920), and the coalescer's own drain.

### 4.5 Seek reanchor
There is no `reloadLocalLoopbackForSeek` at HEAD. Seek reanchoring is: `seek(to:)` B:1152 latches `vodPendingSeekMediaTarget` and drops generated stats; the *fetch* for the missing segment drives `vodSegmentMissResolver` → `requestVODProducerRestart`. Full-session reanchor happens only via `load(.siloLoopback(spec.reanchored(at:)))` from four sites: `recoverLocalLoopbackStallIfNeeded` B:3695, `rebuildSiloLoopbackSession` B:3658, `selectAudioTrack` B:1494, `play()`'s deferred playlist-unchanged branch B:986. Item-only reload: `B:1943 reloadEstablishedLoopbackItem(_:at:reason:replacementURL:)` (preserves writer/store/server/plan/criteria/audio session/budgets).

### 4.6 VOD vs EVENT
Backend is VOD-only in its own logic: `loopbackVODPlan` gates every restart path; if the writer never emits `onSegmentPlanResolved`, `vodPlanForCurrentSource` returns nil and `requestVODProducerRestart` no-ops. EVENT (plan-less) mode is entirely writer/store-side (`vodActive` gating in `LoopbackSegmentWriter`).

### 4.7 `teardownMediaPipeline(clearDisplayCriteria:deactivateAudioSession:)` `B:4542` — the hand reset
Called from `load(strategy:startTime:)` B:1740 and `dispose()` B:1400. Ordered field resets (≈51 mutations):
`cancelSeekDeadline()` [→ seekDeadlineWorkItem, activeSeekDeadlineKind, isInitialSeekInFlight, seekDeadlineState, isSeekPending, lastSeekSettledAt, vodPendingSeekMediaTarget] · `loopbackItemDeathRecoveryState.reset()` · `loopbackItemDeathConfirmationState.reset()` · `isPreservingTVDisplayCriteriaForReload = false` · `clearTVDisplayCriteria` or `logTVDisplayManagerState` · `avPlayer.pause()` · `timeObserver` removed→nil · `subtitleDisplayLink` invalidate→nil · `subPumpRendersInFlight = 0` · `loopbackPlayheadWatchdog` invalidate→nil · `detachPerItemObservers()` [12 observers: statusObs, rateObs, timeControlObs, bufferFullObs, bufferEmptyObs, durationObs, loadedRangesObs, seekableRangesObs, endObserver, itemPlaybackStalledObserver, itemFailedToEndObserver, itemErrorLogObserver] · `audioSelectionState = nil` · `subtitleSelectionState = nil` · `currentLoopbackAudioTracks = []` · `selectedControlledSubtitleTrackId = nil` · `selectedSecondaryControlledSubtitleTrackId = nil` · `selectedBitmapTapStreamIndex = nil` · `bitmapTapAvailableStreams = []` · `sidecarDescriptorsByTrackId.removeAll()` · `loopbackSubtitleTap?.deactivate()` · `embeddedSubtitleExtractor?.teardown()` · `activeLoopbackSessionID = nil` · `loopbackPlaylistName = nil` · `loopbackPlaybackUsesExternalURL = false` · `isInitialSeekInFlight = false` · `initialSeekRetryCount = 0` · `isInitialVideoDisplayGatePrepared = false` · `isWaitingForInitialVideoDisplay = false` · `initialVideoDisplayGateStartTime = nil` · `initialVideoDisplayGateArmedAt = nil` · `didObserveVideoSurfaceReadyForDisplay = false` · `loopbackBridgedAudioAnchorSeconds = nil` · `tvDisplaySettleCompletedAt = nil` · `didApplyTVDisplayCriteriaForStart = false` · `initialVideoDisplayFallback` cancel→nil · `cancelLoopbackStartupWatchdog()` [timer + startedAt] · `displayModeSettleTask` cancel→nil · unmute if `didTemporarilyMuteForInitialVideoDisplay` · `avPlayer.replaceCurrentItem(nil)` · `deactivateAudioSession()` (conditional) · `currentItem = nil` · `subtitleSession?.teardown()` · `lastBitmapCueRenderKey = nil` · `textOverlayMayHaveFrame = false` · async `subtitleOverlay?.clear()` · `segmentWriter = nil` + 7 writer callbacks nil'd (onFirstSegmentReady, onSegmentAppended, onSourceDownloadStats, onGeneratedMediaStats, onHDR10PlusMetadataDetected, onBridgedAudioAnchored, onFinished) · `segmentServer?.stop(); segmentServer = nil` · `segmentStore = nil` · `latestLoopbackGeneratedStats = nil` · `loopbackEdgeWatch = nil` · `sessionDirectory = nil` + `writer.stop(completion: disposeSessionDirectory)` (deferred rm, honoring `keepLoopbackArtifacts`).
A **second** ~20-field reset lives in `load()` B:1747-1775 (currentSourceStrategy, external-playback policy, audio track list, extractor config, playback clock, rebufferCount, lastSeekSettledAt, lastStatsEmitWall, loopbackDemuxReadBitrateBps, loopbackHDR10PlusDetected, loopbackSourceBytesRead, latestLoopbackGeneratedStats, loopbackEdgeWatch, pendingLocalLoopbackRecoveryMediaTime, vodPendingSeekMediaTarget, lastLocalLoopbackStallRecoveryAt, watchdogLastPlayheadSeconds/AdvanceWall/StateLogWall, didFireFileLoaded, hasSeekedToStart, hasReachedItemEnd, pendingStartTime, initialSeekRetryCount, isInitialSeekInFlight).

### 4.8 Essential adapter vs lifecycle glue
**Essential (must stay in the AVFoundation adapter):** the 12-observer set `B:3293 attachItemObservers` + `B:3509 detachPerItemObservers`; the player-scoped external-playback KVO in `init` (B:908) and `B:1094 updateLoopbackURLForExternalPlayback` + `B:1069 isReceiverFetchableAsset` (AirPlay URL rewrite); the display-criteria write→settle→attach ordering (`B:4720`, `B:2293-2327`, `B:2894 shouldPreserveTVDisplayCriteriaDuringReload`); the audio-session serialization (`B:284 AVPlayerAudioSessionActivationState`, `B:326 AVPlayerAudioSessionCoordinator`, `B:2411/2415`, dedicated `sharedWorkQueue` B:341); the initial-video-display gate (`B:3962`–`B:4157`); buffer policy `B:4167/4187`; the `prepareAssetPlayback` ordering; PiP intent reconciliation (`B:241 AVPlayerSystemTransportIntent`, `B:1001 reconcileSystemTransportIntent`); seek deadline machinery; subtitle overlay pump `B:4415/4490`.
**Lifecycle glue movable under a `LocalHLSHost` / engine session:** steps 1-11 of `startSiloLoopback`, all of `startSiloLoopbackWriter`'s callback wiring, `requestVODProducerRestart` + coalescer + `activeVODWriterBaseIndex/HeadIndex`, `vodPlanForCurrentSource`/`loopbackVODPlan`, the session directory + `SILO_KEEP_DV_HLS`, `ensureLoopbackSubtitleTap`, `generatedHLSSpillPolicy`/`vodRetentionBudget*`/store budget selection, `segmentWriter/segmentServer/segmentStore/sessionDirectory/activeLoopbackSessionID/loopbackGeneration` and their half of `teardownMediaPipeline`.

---

## 5. BRIDGE — `PlaybackSessionBridge` (actor, `BR:235`)

**Identity fields.** `sessionId: String?` BR:244 (the only top-level identity); `currentSession: PlaybackSessionResponse?` BR:245 (mirror); `activeProtocolV3: ActiveProtocolV3?` BR:307 holding `playbackAttemptId` (let) BR:248, `planAttemptId` BR:249, `planAttemptKey` BR:250, `attemptedPlanKeys: [String]` BR:251, `attemptCount: Int` BR:252, `clientQualityId` BR:253, `bandwidthCapKbps` BR:256, `snapshot: ApplePlaybackV3CapabilitySnapshot` BR:257, `serverFeatures` BR:258, `plan: PlaybackV3Plan` BR:259. **There is no stored `outputContextId`** — always read as `active.snapshot.outputContextId` (BR:768, 936, 1243, 1319). Other state: `protocolV3FirstFramePlanIds: Set<String>` BR:308, `consecutiveProgressFailures` BR:1442, `emittedOrphanedSessionWarning` BR:1443, `orphanedSessionLogThreshold = 3` BR:1444. Statics `nearEndResumeSuppressionSeconds = 5` BR:236, `pastEndResumeClampSeconds = 0.25` BR:237.

**Identity comparator.** `private func isCurrentProtocolV3Attempt(_ expected: ProtocolV3AttemptIdentity, sessionId:) -> Bool` BR:310-321: `!Task.isCancelled && sessionId == expected && currentSession?.sessionId == expected && activeProtocolV3 != nil && ProtocolV3AttemptIdentity(active) == expected`. `ProtocolV3AttemptIdentity` BR:262 = (playbackAttemptId, planAttemptId, planAttemptKey). Used at BR:822, BR:1100, BR:1137.

**`stopSession(position:isPaused:)` BR:1521 — the expected-identity idiom.** Captures `guard let sid = sessionId else { return }` BR:1522; three awaits (progress report BR:1551, stop BR:1560, …); then BR:1576-1582 `guard sessionId == sid else { return }` before clearing `sessionId`, `currentSession`, `activeProtocolV3`, `protocolV3FirstFramePlanIds`, `consecutiveProgressFailures`, `emittedOrphanedSessionWarning`. (Fix #5 landed.) There is **no** `stopSession(expected:)` overload.

**Start path.** `startSession(contentId:preferredFileId:preferredAudioTrackIndex:preferredSubtitleTrackIndex:preferredProtocolV3SubtitleIndex:initialSubtitlePreferences:startFromBeginning:resumePosition:allowNearEndResume:preferredQualityOverride:) async throws -> PreparedPlayback` BR:378 → `startProtocolV3` BR:626 → **stage/adopt split**: `stageProtocolV3Start(...)` BR:656 mutates **no** actor state (capability gate BR:666, `playbackAttemptId = "apple:<uuid>"` BR:670, one idempotent retry on `HTTPError.network` reusing the same request BR:702-707, adapter resolve BR:709, effective-file check BR:714-723); `adoptProtocolV3Start(_:watchDetail:) -> PreparedPlayback` BR:743 is synchronous (no await) and is the atomic commit — mints `planAttemptId = "apple-plan:<uuid>"` BR:747, takes server `planAttemptKey` BR:749, `attemptCount = 1` BR:755, clears first-frame set BR:762, `adoptSession` BR:763.
`adoptSession(_:)` BR:349 sets `sessionId`, `currentSession`, `consecutiveProgressFailures = 0`; does NOT clear `emittedOrphanedSessionWarning`.
`InitialProtocolV3SubtitleIntent` resolution: `static func initialProtocolV3SubtitleIntent(...)` BR:523-624 (explicit combined index wins BR:537, else ffmpeg index → `serverCombinedSubtitleIndex` BR:549, else `SubtitleAutoResolver.resolve` BR:589).

**Replan.** `replanProtocolV3(watchDetail:position:classification:message:operation:qualityPreference:audioTrackIndex:subtitleTrackIndex:outputRouteSnapshot:) async throws -> PreparedPlayback?` BR:983-1258. **Cap is a bare literal `8` at BR:1005** (`guard active.attemptCount < 8`), throwing `attempt_limit_reached`; increment BR:1221 `attemptCount = invalidatesIntent ? 1 : attemptCount + 1`. Guard ladder in order: active+sessionId else nil BR:994 → operation from classification BR:1000 → identity captured BR:1004 → cap BR:1005 → snapshot refresh on `output_route_changed` BR:1014 → intent/invalidates/seek-reanchor classify BR:1019 → seek-reanchor requires `seekReanchorFeature` else nil BR:1023 → attemptedKeys set algebra BR:1027 → identity re-check pre-POST BR:1100 → identity re-check post-POST + `discardStaleProtocolV3Response` BR:1137 → `.terminal` BR:1142 → `.incompatible` BR:1150 → adapter `validate` BR:1160 → loop detection `replan_loop_detected` BR:1174 → effective-file check BR:1183 → seek-reanchor invariance block (8 fields) BR:1200-1216 → commit BR:1218-1228. Route event fired off an immutable copy in a detached Task BR:1089-1099.

**Direct renewal.** `renewDirectSession(watchDetail:position:audioTrackIndex:subtitleTrackIndex:) async throws -> PreparedPlayback` BR:790: pre-guards `activeProtocolV3`/`sessionId`/`delivery == "original_http"`/`playMethod == "direct"` BR:796-801; captures `expectedAttempt` BR:802; post-await `isCurrentProtocolV3Attempt` → stop staged + `CancellationError` BR:822; `Self.canRetargetDirectSession` → stop staged + `.replacementPlanChanged` BR:826. `static func canRetargetDirectSession(from:to:) -> Bool` BR:838-867 is a 22-clause conjunction.

**Progress / terminal.** `reportProgress(position:isPaused:) async -> PlaybackProgressReportResult` BR:1446 (mutates the two counters with **no identity re-check after the await**; returns `.success`/`.missingSession`/`.transientFailure` BR:83). `syncProgress(contentId:position:duration:forceOverwrite:) async -> Bool` BR:1480. `reportProtocolV3PlanExecutionStarted()` BR:1260. `reportProtocolV3FirstFrame(milliseconds:)` BR:1274 (de-dup via `protocolV3FirstFramePlanIds.insert(planId).inserted`). `emitProtocolV3Event(...)` BR:1299. `terminalReplanFailure(active:sessionId:abandoning:reason:message:retryable:)` BR:1333. `emitProtocolV3Terminal(...)` BR:1353. `static terminalStartRouteEvent` BR:919 / `static reportTerminalStart` BR:941. `resolvedStartPosition(...)` BR:1388. `stopStaleSession(_:)` BR:343 (unstructured fire-and-forget Task).
Pure statics: `replanOperation(forClassification:serverFeatures:)` BR:876, `isMaterialOutputRouteChange(activeOutputContextId:observedOutputContextId:)` BR:897, `supportsNeutralProtocolV3` BR:904, `isMissingProtocolV3Capability` BR:911, `replanFailure(operation:classification:message:)` BR:963, `isPlaybackSessionMissing(_:)` BR:1592, `selectVersion(from:lastFileId:preferredQuality:)` BR:1625, `diagnosticsPositionMilliseconds` BR:1514.

**Transport injection surface — 15 `SiloAPI.shared` call sites, 8 distinct methods:** BR:198 `playbackV3Capability` (inside `PlaybackV3CapabilityGate` BR:180, a separate actor with its own single-flight `probeByServerId` BR:184); BR:345, 717, 1163, 1342, 1560 `stopPlayback`; BR:391 `watchDetail`; BR:701, 706 `startPlaybackV3`; BR:952, 1323 `reportPlaybackRouteEventV3`; BR:1132 `replanPlaybackV3`; BR:1453, 1551 `reportPlaybackProgress`; BR:1493 `syncProgress`.

**What it publishes back.** Return values + thrown errors only — no closures, `AsyncStream`, continuations, or notifications anywhere in the file. Types: `PreparedPlayback` BR:7, `PlaybackProgressReportResult` BR:83, `PlaybackV3TerminalFailure` BR:89, `PlayerMetadata` BR:102, `PlaybackDeliveryStrategy` BR:140, `DirectSessionRenewalError` BR:274, `StagedProtocolV3Start` BR:279, `InitialProtocolV3SubtitleIntent` BR:291, `InitialProtocolV3SubtitlePreferences` BR:296.
VM anchors (`private let sessionBridge = PlaybackSessionBridge()` `PVM:467`): `PVM:1323` firstFrame · `PVM:1636` replan · `PVM:2704/2706` planExecutionStarted · `PVM:3723` stopSession / `PVM:3725` reportProgress · `PVM:3864, 3892` startSession · `PVM:4110` renewDirectSession (catch `DirectSessionRenewalError` `PVM:4165`) · `PVM:4251` syncProgress · `PVM:5235` reportProgress / `PVM:5244` replan (quality + seek-reanchor) · `PVM:6405` stopSession teardown · `PVM:7477` reportProgress 10 s loop · `PVM:7636` stopSession on suspend. Static-only: `PVM:1088` isMaterialOutputRouteChange, `PVM:3406/4046` diagnosticsPositionMilliseconds, `PVM:3846/3851` subtitle preferences.

---

## 6. EXISTING PURE POLICIES (the pattern `RecoveryPolicy` should follow)

- `LoopbackStartupRecoveryPolicy` (`LoopbackStartupRecoveryPolicy.swift:18`) — `enum Verdict {.wait, .escalate, .failBackstop}` :19; `static func verdict(secondsSinceProgress:secondsSinceStart:displayModeSwitchInProgress:stallWindow:absoluteBackstop:) -> Verdict` :31. **All thresholds injected**, none stored. Precedence backstop > mode-switch hold > stall window.
- `LoopbackIngestEndPolicy` (`:17`) — `enum Verdict {.finished, .prematureSourceEnd(shortfallBytes:shortfallSeconds:)}` :18; `static func classify(readResult:bytePosition:fileSizeBytes:reachedPlanSeconds:plannedTotalSeconds:deadlineAborted:) -> Verdict` :53. Constants `avErrorExit` :25, `byteShortfallToleranceFloor = 8 MiB` :30, `byteShortfallToleranceFraction = 0.02` :33, `planShortfallToleranceSeconds = 30.0` :38.
- `LoopbackRestartCoalescer` (`:11`) — `isInFlight` :12, `pending: Int?` :13, `pendingIsAuthoritative` :14; `mutating func begin(_ index: Int, authoritative: Bool = false) -> Bool` :27; `mutating func next(justRan index: Int) -> Int?` :45. No thresholds. Authoritative-owns-slot + same-index-livelock guard :47.
- `HDRDisplayCriteriaPolicy` (`HDRDisplayCriteriaPolicy.swift:14`) — `gateKey = "player.apple.hdr_display_criteria_enabled"` :19; `isEnabled(defaults:)` :21; `enum CriteriaSelection {.dolbyVision(baseLayer), .hdr10, .hlg, .none}` :27; `selection(videoMode:manifestVideoRange:hdrGateEnabled:)` :42; `switchStartPollAttempts = 100` :73, `switchStartPollIntervalMs = 10` :74, `switchSettlePollAttempts = 50` :75, `switchSettlePollIntervalMs = 100` :76, `hdrHeadroomFloor = 1.001` :79; `shouldEnableEDR(sigPeak:screenHeadroom:)` :88; `shouldPreserveCriteriaAcrossReload(current:next:currentRate:nextRate:)` :96 (rate epsilon 0.01 :103).
- `AVPlayerSeekDeadlineState` (`B:11`, inline in the backend) — `nextID` :12, `private(set) var activeID: UInt64?` :13; `begin() -> UInt64` :15 (0-wraparound guard :17), `complete(_:) -> Bool` :22, `cancel()` :28.
- `LoopbackRebuildBudget` (`B:40`) — `maximumRebuildsPerLoad = 2` :41; `used` :43; `isExhausted` :45; `consume() -> Bool` :49; `reset()` :55.
- `LoopbackItemDeathRecoveryState` (`B:60`) — `Action {.waitForConfirmation, .reload(attempt:), .escalate}` :61; `matchingPositionToleranceSeconds = 2.0` :67, `evidenceRequired = 2` :68, `maximumReloads = 1` :69; `static isItemDeath(statusCode:errorDescription:)` :75; `record(position:evidenceWeight:userPaused:) -> Action` :82; `confirm(position:userPaused:) -> Action` :101; `reset()` :115.
- `LoopbackItemDeathConfirmationState` (`B:126`) — `Trigger {failedToEnd, unexpectedPause}` :127; `TransportState {paused, waiting, playing, unknown}` :132; `Action {.none, .reassertPlay, .confirmed(trigger:)}` :139; `confirmationSeconds = 3.0` :145, `progressCancellationThresholdSeconds = 0.5` :146; `noteExplicitFailure(position:now:playbackEstablished:userPaused:)` :156; `evaluate(now:position:playbackEstablished:userPaused:transportState:recoverySuppressed:mediaAvailableAhead:) -> Action` :173; `resetCandidate()` :217; `reset()` :221. **Already has the `recoverySuppressed` input the merged policy needs.**
- `AVPlayerSystemTransportIntent` (`B:241`) — `.play`/`.pause`; `struct Context` :247 with 8 lets (timeControlStatus, isUserPaused, systemControlsAreActive, isInitialObservation, hasStartedPlayback, isSeekInFlight, isBufferStarved, hasReachedEnd); `static func resolve(_:) -> Self?` :266.
- `AVPlayerAudioSessionActivationState` (`B:284`) — `Request {id, needsActivation}` :285; `beginActivation() -> Request` :294; `finishActivation(id:succeeded:) -> Bool` :302; `cancelAndDeactivate() -> Bool` :309; `isCurrent(id:)` :318.
- `PlaybackRunwayPolicy` (`PlaybackStatsComposer.swift:125`) — `runwaySeconds(playableAheadSeconds:generatedVisibleAheadSeconds:) -> Double` :131 = `max(0, max(a, b ?? 0))`. Nilness of arg 2 encodes route. Backend caller `B:2635 runwaySeconds(for:referenceTime:playableAhead:)`.
- `PlaybackDiskBudget` (`PlaybackDiskBudget.swift:7`) — `retentionBudget(availableBytes:) -> Int64` :24 (cap `2<<30` :25, floor `512<<20` :26, quarter-of-available :28); `freeDiskSpaceBytes()` :13 (impure); `sweepOrphanedSpillDirectories` :38 (one-shot, 60-min staleness :40).
- `LocalHLSPlaylistPolicy` (`:3`) — `PlaylistType {liveSliding, vod}` :4; `shouldEmitStartTag(firstMediaSequence:)` :16; `playlistType(isFinal:)` :20; `fallbackMasterBandwidthBps = 18_000_000` :25; `bridgedLosslessAudioAllowanceBps = 4_000_000` :31; `masterPlaylistBandwidth(sourceBitrateBps:isAudioBridgedToLossless:) -> (peak:average:)` :42.
- `LocalHLSRequestLogPolicy` (`:3`) — `shouldLog(status:requestLogCount:startupRequestLogLimit:signatureAlreadyLogged:)` :4.
- `SourceCacheAdoptionPolicy` (`:14`) — `shouldAdopt(handoffFileId:planFileId:handoffBudgetBytes:planBudgetBytes:handoffDiskSpill:planDiskSpill:cachedTotalLength:expectedFileSize:) -> Bool` :27.
- `PlaybackSourcePrefetchPolicy` (`:3`) — `initialOffset(sourceStartTimeSeconds:sourceBitrateBps:) -> Int64` :4.
- `PlayerNextUpCompletionPolicy` (`:3`) — `isInPromptWindow` :4, `shouldFinalizeAsCompleted` :20, `progressPosition` :38.
- `DolbyVisionPolicy` (`:9`) — `Snapshot` :12 (`.default` :16); `Resolution {.dolbyVision, .profile7HDR10Fallback, .dolbyVisionDisabled}` :25; `resolution(forProfile:snapshot:)` :40; `claimsDolbyVisionOutput(_:)` :55.
- `LoopbackSegmentCutter` (`:16`) — `boundaries` :21, `baseIndex` :24, `current` :25; `init(boundaries:baseIndex:)` :27; `mutating func index(pts:isKeyframe:) -> Int` :38.
- `LoopbackSegmentPlan` (`:16`) — `duration(ofSegment:)` :30, `sourceStartSeconds(ofSegment:)` :37, `segmentIndex(forPlaylistSeconds:)` :46, `coalescingSegments(after:through:)` :65.
- Origin-stream family (`PlaybackSourceOriginStream.swift`): `PlaybackOriginRoutingPolicy` :17 (rideThroughBytes 8 MiB :20, chunkBytes 4 MiB :23, windowClaimBytes 8 MiB :28, `route(...)` :40); `PlaybackWindowClaimPolicy` :73 (`arbitrate(...)` :93); `PlaybackOriginStreamPolicy` :115 (`detachAfterSeconds = 25` :119 **var**, `detachGraceCeilingSeconds = 45` :123 **var**, `detachDrainMarginSeconds = 5` :126, `shouldPause(...)` :164); `PlaybackOriginReconnectPolicy` :180 (productiveBytesFloor 512 KiB :181, stallSeconds 20 :184, `decide(cause:unproductiveStreak:everProductive:)` :201, `backoffSeconds(streak:)` :219); `PlaybackOriginOutagePolicy` :231 (`probeDelaySeconds = 5.0` :236 **var**, `shouldPark(...)` :252).
- `LoopbackInterruptToken` (`LoopbackInputHandoff.swift:13`, **reference type**) — `outageParkAllowanceSeconds = 240` :18; `beginBlockingSpan(allowanceSeconds:)` :76, `endBlockingSpan()` :84, `shouldInterrupt(now:)` :112 (pure seam).
- Writer-local policies: `DVPreVideoAudioTailPolicy` (writer:39, maxPackets 512 / maxBytes 8 MiB), `LoopbackVideoSampleDurationPolicy` (:67), `LoopbackLengthPrefixedHEVCValidator` (:87), `LoopbackCorruptVideoRecoveryState` (:124), `LoopbackVODPreGateAudioBufferPolicy` (:146), `DVTrueHDMajorSyncScanner` (:179), `HDR10PlusSEIDetector` (:213), `LoopbackBridgedDriftGovernor` (:312).
- `CreditsAutoSkipPolicy` (`PVM:21`) — `target(enabled:playbackEligible:time:range:markerKey:lastSkippedKey:) -> Double?` :22 (pure, but embedded in the VM file).

---

## 7. TESTS PINNING BACKEND / BRIDGE / LOOPBACK LIFECYCLE

**Headline:** `grep -rn "AVPlayerBackend(\|PlaybackSessionBridge(" iosApp/Tests/` returns **zero matches** — no test constructs either type. Every test touching them touches `static` members only. There are **no files named `*Characterization*`**; the R1 work is spelled "Stage-0 characterization" in doc comments or `Pin`/`Contract` in names.

Touching backend/bridge statics:
- `LoopbackStartupRecoveryPolicyTests.swift` (501) — de-facto backend-state file: 25 tests over `AVPlayerSystemTransportIntent.resolve`, `AVPlayerBackend.isReceiverFetchableAsset` (:103,111,117,124,131), `AVPlayerAudioSessionActivationState` + the real `AVPlayerAudioSessionCoordinator`, `LoopbackItemDeathRecoveryState`, `LoopbackItemDeathConfirmationState`, `LoopbackStartupRecoveryPolicy.verdict` (:434-471), `LoopbackRebuildBudget` (:473-500).
- `PlaybackSessionBridgeReplanContractTests.swift` (274) — `replanOperation` totality over 13 classifications, `canRetargetDirectSession` swap rules, `isMaterialOutputRouteChange`; header states it deliberately avoids standing up the actor.
- `PlaybackProtocolV3Tests.swift` — bridge statics `canRetargetDirectSession` (:158-172), `replanOperation` (:187-252), `replanFailure` (:203-210).
- `PlaybackV3FixtureRoundTripTests.swift` — `supportsNeutralProtocolV3` (:87) over golden fixtures.
- `LoopbackSegmentStoreVODRetentionTests.swift` (310) — VOD eviction victims + `AVPlayerBackend.vodRetentionBudget` clamp table (:298-308).
- `PlaybackSourceCacheDiskSpillTests.swift` — `AVPlayerBackend.vodRetentionBudget(4<<30)` (:113).
- `PlayerSettingsFlushTests.swift` — `PlaybackSessionBridge.selectVersion` (:1551, 1559).

Pure-policy / lifecycle pins (no backend instance): `PlayerErrorClassifierPinTests.swift` (229, the four substring classifiers), `PlayerErrorClassificationMatrixTests.swift` (422, ~30 messages × two ladders vs inline oracles), `ApplePlaybackRoutePlannerPinTests.swift` (983), `ApplePlaybackDecisionTraceSnapshotTests.swift` (574, decisionTrace snapshot + `needsServerReplanBeforeLoad`), `LoopbackIngestEndPolicyTests.swift` (189), `LoopbackRestartCoalescerTests.swift` (80), `LoopbackSegmentCutterTests.swift` (182), `LoopbackSegmentPlanTests.swift` (292), `LoopbackSegmentServerRangeTests.swift` (247, real server), `LoopbackSegmentStoreTests.swift` (149) + `…ResourceTests.swift` (27), `LoopbackSegmentWriterVODContinuityTests.swift` (450, real writer over a 20 s H.264+EAC3 fixture — the closest thing to a loopback-lifecycle integration test), `LoopbackSessionSpecCopyHelperTests.swift` (167, Stage-0 characterization of the copy helpers), `LoopbackBridgedDriftGovernorTests.swift` (91), `TrueHDPrimingPolicyTests.swift` (126), `PlaybackRunwayPolicyTests.swift` (68), `PlaybackStatsComposerTests.swift` (247), `HDRDisplayCriteriaPolicyTests.swift` (343), `DolbyVisionPolicyTests.swift` (86), `LocalHLSPlaylistPolicyTests.swift` (80), `LocalHLSRequestLogPolicyTests.swift` (35), `SourceCacheAdoptionPolicyTests.swift` (61), `PlaybackSourcePrefetchPolicyTests.swift` (20), `PlayerNextUpCompletionPolicyTests.swift` (52), `PlaybackOriginOutageTests.swift` (209), `PlaybackOriginStreamPolicyTests.swift` (507), `PlaybackOriginStreamResumeTests.swift` (2367), `PlaybackSourceProxyRetargetTests.swift` (100), `PlaybackSourceResponseEndTests.swift` (114).