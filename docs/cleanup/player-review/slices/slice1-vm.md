# Slice 1 — PlayerViewModel orchestration (HEAD 36393b4) — KEY FINDINGS

## Ownership
- Session id: authoritative PlaybackSessionBridge.sessionId/currentSession (:244-245; adoptSession :349; stopSession clears :1538-1541). VM mirror activePlaybackSessionId PVM:835 (:2489,:4040; cleared :3965,:6241) + 4 echoes as single-flight keys :607,:627,:844 + bridge ActiveProtocolV3 ids (bridge:248-252). Identity gates :6366,:4021, bridge:310-321.
- Generations: streamLoadGeneration :353 (single increment loadStream:2695; captured by value :1200,:1217,:1408; strict == at :5839-5844); freshLoadGeneration :639 (:3625, :5161); serverOutageRecoveryGeneration :626. PlayerTaskRegistry 23 keys/4 scopes (PlayerTaskRegistry.swift:22-94).
- Source renewal: two ladders attemptBackgroundSessionRenewal :3983 (bridge.renewDirectSession :816) & attemptStaleSessionRenewal :4110 → beginFreshLoad :4158; five triggers :1525/1528, :7359/7365, :2883/2889, :1623 (skips bg), :4103.
- Recovery: five ladders ordered in handlePlaybackError :1505-1557 (V3 recovery :1559→:1567; native-direct :2124; silo→HLS :2208/:2229; outage :4283 (also :2896,:4216); interruption :3925). No top-level in-flight latch.
- Seek: commitSeek :4950 nominal; pre-emptors reloadServerBackedHLSForSeek :4984, reloadLocalLoopbackForSeekBeforeAnchor :5063, restartCurrentTranscodeHLS :5120; other writers :4915,:4817-4913,:5416-5479,:6515,:3386,:7567.
- Output route: AVAudioSession observer :1083-1108 → replan (guard !isLoading :1091); external playback :1435→:4725; :1444→:461; :1453. PiP singleton iOS/PictureInPictureCoordinator.swift:18 bound :1472 released :6235; grace :4734/:4744. Scene phase handleScenePhase :4632 three #if bodies; tvOS suspendForBackground :7469 / resumeSuspendedPlayback :7513.
- Next Up :1664-2122; presentation :1265→:1902; postroll from handleEndOfFile :3369; completion policy duplicated PlayerNextUpCompletionPolicy.swift:1-56 (used :6282) vs inline :3298-3307.
- Progress: startProgressReporting :7343 (10s) + six flush points :3643/3645,:5175,:4149,:6326,:7509, offline :7380.
- Teardown: cleanup :6224 (PlayerView.swift:351,:381; macOS/PlayerView.swift:118), deinit :6346, finalizeTerminalPlaybackError :3947, resetPublishedLoadState :3390, disposeActivePlayerForFreshLoad :3718, suspendForBackground :7469, installBackend :1129; PlayerView.swift:307-314 replaces disposed VM.

## State audit
26 lifecycle booleans (:230,:234,:235,:255,:257,:262,:270,:273,:274,:284,:301,:350,:443,:450,:461,:466,:531,:536,:620,:621,:786,:829,:845,:846,:975,:981); 3 generation counters + holdSeekRate:318; 11 pending* (:732,:774-776,:781,:782,:790,:795,:802,:839,:815); ~25 Optional-as-state; 23 registry task slots + 14 UNREGISTERED Task{} (:1035,:1328,:1366,:1456,:1536,:2881,:2896,:2905,:3323,:3360,:5114,:6292,:6359,:7507) + bridge stopStaleSession :343-348; string classifiers as control flow (:1634-1649; literals :1104,:2688,:5024/5187,:4538,:5490,:5517/5541; source "quality"/"seek" :5130-5225; "render"/"burn_in" :5829-5833; :906/:913; activeQualityId String :254).
Reachable invalid combos (static):
1. Live backend with dead callbacks (see D1) → isLoading true forever (only clear handleFileLoaded:1487 via cb.onFileLoaded:1312).
2. hasReachedEndOfFile true with new stream loading: set :3333; replan :1567-1631 never resets; onTimeChange bails :1227.
3. finalizeTerminalPlaybackError :3947 doesn't sweep .activeStream (:3955-3957) → error :3968 + dispose :3962 while replan/freshLoad tasks continue to adoptPreparedPlayback :2483.
4. Seek filter armed without timeout, survives stream swap: commitSeek arms :4959-4960/:4973-4980; reanchor paths cancel+nil timeout without rearming :5011-5014,:5032-5035,:5098-5101; cleared only :1255-1258,:3407-3408 (V3 replan never calls). Combined with #1: no onTimeChange ever.
5. Two replan pipelines: attemptProtocolV3Replan guard only :1576; restartCurrentTranscodeHLS occupies freshLoadTask :5160-5163, no cross-check; both call bridge.replanProtocolV3 (:1592,:5184) and adoptPreparedPlayback (:1611,:5208) mutating ~20 fields incl :2489 with no generation guard.
6. VM holds session bridge forgot (see D2) → reportProgress returns .transientFailure :1430 not .missingSession → renewal ladder :7358 never fires; replan returns nil :1011-1013 → terminal :1603.
7. suspendedPlayback set :7478, untracked stop :7507-7510, cleared :7518, new load :7521.

## Multiple responders
- onError :1330 → ten branches, no in-flight latch; second onError re-enters; :1536-1543 untracked Task.
- Stall suppression writers :4186 on / :4214,:4244 off; clearSourceOutageRideThroughState :4241 from :4225,:4307,:6261,:7486.
- EOF: onEndOfFile :1395→handleEndOfFile :3285; also error path :1515-1518; no early-return when already reached → beginNextUpPostroll :3369 twice; four completion judgements (:6282 policy, :3298-3307 inline).
- Seek triple four writers (:1255-1258, :4977-4979, :3407-3408, reanchor blocks).
- Route change: AVAudioSession observer :1083-1108 replan AND KVO :1435→:4725→:4750 pause; interlock only :1091.
- Replan: nine call sites (:1102,:1560,:2238,:4536,:5022,:5488,:5515,:5539,:7335) + parallel restartCurrentTranscodeHLS :5120 (from :4624) + :2229 + :2686.
- Background: iOS four callers converge pauseBackgroundPlaybackIfUnrouted :4750 (:4706,:4731,:4740,:4747); tvOS :7448 vs :7469 overlapping (:7485 discards :7456).

## Claims
- D1 same-engine replan dead callbacks: CONFIRMED, HIGH, high conf (static). Trace: increment :2695; capture-by-value :1200/:1217/:1408; strict == :5839-5844; 17 handler guards; install only makeAVPlayerBackend :1118-1124 ← installBackend :1130; prepareBackend :1145-1152 returns existing backend untouched; loadStream :2738-2740 uses prepareBackend when reusingActiveEngine (true only for .protocolV3Replan :2436-2439; that origin never disposes :2523-2524); backend stores closures as var :501-530, dispose :1187-1196 nils only two. Old installed callbacks discard NEW-stream events → isLoading never clears, applyTrackList never runs (intent re-armed :2707 wasted), errors/EOF swallowed. Triggers: audio change :5488, subtitle :5515/:5539, quality :4536, route :1102, seek reanchor :5022, error recovery :1560. HISTORICAL: pre-e458784 code re-applied callbacks unconditionally (git show e458784^ old lines 2540-2549); regression from commit e458784 (2026-08-16 "collapse backend abstraction, unify replan adoption, add task registry") — one-day-old, unreleased. Fix: after :2738-2740 re-apply applyCallbacks(makeCallbacks(), to:), wireSubtitleCallbacks(to:), backend.setServerChapters(serverProvidedChapters).
- D2 tvOS untracked stop erases resumed session: CONFIRMED mechanism (unguarded clear-after-await + untracked task), PLAUSIBLE for the interleaving; med-high. suspendForBackground :7469 (from :4638) bare Task :7507-7510 not in registry; cancelAll :7491 before it. bridge.stopSession :1492 reads sid :1493, awaits :1507,:1520,:1529, unconditional clear :1538-1543, no sid re-check/isCancelled. Resume :4489-4494→:7513→:7518→beginFreshLoad :7521 (progressPosition nil → skips :3641-3647) → :3654 → :3694 → startSession :3812 → adoptSession :349-351 between awaits → old resume erases new. Consequence: progress silently dies, replans terminal, cleanup stop no-ops. Counter: bridge already has idiom :310-321,:335. Same window at PVM:3643 (inside tracked freshLoadTask, precedes own startSession) and :6326. Fix: `guard sessionId == sid else { return }` before :1538; register :7507 task.
- D3 orchestration untested: CONFIRMED. Zero `PlayerViewModel(` / `PlaybackSessionBridge(` in iosApp/Tests. Only static/pure member tests (PlayerErrorClassifierPinTests, PlayerSettingsFlushTests:1742 LoadRequest). ~25 suites below VM.

## Multipliers
1. 3 adoption origins × 3 engines × 2 backend-lifetime policies: PlaybackAdoptionOrigin :2390-2447, seven switches in adoptPreparedPlayback (:2492-2536,:2545-2559,:2561-2564,:2573-2594,:2596-2614,:2627-2645,:2648-2666), loadStream fork :2738-2740, loadBackend switch :1160-1170.
2. closures capture generation by value vs guard reads live.
3. five recovery ladders, ad-hoc single-flight keys.
4. six session-id stores + three generations; LoadRequest.copyForRecovery :869-888 reconstructed at :4134,:4312,:5047,:3565.
5. MainActor VM ↔ 2 actors ↔ 14 unstructured Tasks (:5114 launches full loadStream).
6. platform divergence in single functions :4632-4715; #if in applyCallbacks :1431-1476.
7. task registry 23×4 hand-maintained scope matrix (:66-93); finalizeTerminalPlaybackError opts out :3955-3957.
8. subtitle state machine entangled: 6 pending fields, restore-intent enum :5814-5837 applied :2454-2474, arm/rearm :3549/:3543 at :2707; live-AI bridge :5951-7050 adapters :7723-7870; every subtitle action is a replan.

## Essential vs accidental
Essential: backend rebuild on route change (loadBackend :1157-1171); preserving live backend across replan for tvOS HDMI/audio session (:1139-1143); stale time filtering :691-709,:1241-1259; EOF/error ambiguity :1651-1663,:3298-3307; PiP singleton :6228-6237; iOS background rules :4718-4763; route-change filter :1092-1101.
Accidental: generation-capture discipline; five ladders all ending in beginFreshLoad (:3937,:4158,:4372,:5054,:7521); six mirrored ids; seek triple; string classifiers. Deletions: hasAttempted* latches :845/:846 duplicate server attemptCount<8 bound (bridge:1016); outage ride-through :4170-4247 vs attemptServerOutageRecovery :4283 = two escalation systems for one condition; Next Up four booleans (:284,:975,:981,:289,:270); TranscodeRestart.subtitleUrlFallback :2421-2432,:2542.

## Rewrite assessment
Reducer collapses: LoadState (kills invalid 1,2,3); SeekState owned by StreamToken (kills 4); ReplanState single slot (kills 5); RecoveryState enum (ladder interleaving); typed PlaybackFailure retires classifiers and makes missing top-level latch visible. NOT solved by reducer: D2 (needs identity guard in actor regardless), D1 (wiring/ownership — handlers must die with stream token), 14 unstructured Tasks, platform divergence, subtitle domain.
MARK seams (5476,5628,5647,5951,6886,7716) all in subtitle half (~2.4k lines) — extract; but lifecycle core :224-5475 has no seams. Recommend: (1) point-patch D1/D2 + two tests; (2) extract subtitle half; (3) rewrite three clusters with typed state: adoption/load :2382-2760, recovery :3947-4450, seek :4915-5237 (~1.1k lines) — not full 7.9k. Do NOT fold D1 into a rewrite.
