# Slice 2 — AVPlayerBackend (HEAD 36393b4) — KEY FINDINGS (condensed from agent report)

## Ownership
- Recovery has FOUR owners: writer/ingest policy (LoopbackIngestEndPolicy.swift:53, writer:2088), backend in-route ladders (AVPlayerBackend.swift:1735 performVODStallRecovery, :3406 rebuildSiloLoopbackSession, :3427 recoverLocalLoopbackStallIfNeeded, :3367 item-death, :3635 startup ladder), VM error ladder (PlayerViewModel.swift:1505 handlePlaybackError; :2124 native-direct recovery; :2208 silo→HLS fallback; :2227; :1567 attemptProtocolV3Replan), VM outage ride-through (:4178, :4283) — needs explicit backend muzzle setExternalStallSuppression (backend:545, consumed :2872,:2911,:2951) and kick (:559).
- Backend never selects another engine (refuted "backend replans route"); but re-plans within route: strategy rewrite :1982, audio change = full session rebuild :1313, reanchor :851/:3421/:3455, producer restart :1670 (+ coalescer, + server resolver :1832, + server 503/404 LoopbackSegmentServer.swift:611), AirPlay :903/:933/:991, HDR criteria :4272/:4333/:2669, buffer policy :2202/:3774, spill budgets :491/:1649.
- Stale comment :3632-3634 references CompatibilityPlayer fallback (removed f1b1bba).
- Six recovery ladders: S startup (:3572 watchdog, policy LoopbackStartupRecoveryPolicy:31, stages :688; nudge :3660, reload :3679, report :3649; 60s backstop :3619; -15628 accelerator :3270), P playhead wedge (:2790; reassert :2879; reanchor ≤3/90s :431-432,:2975; exhaustion rebuild :2949; starvation 30s+15s :2904), D item death (state :33; -12889/-15628/"No response for media file" strings :48-53; :3256,:3308; reload max1 :83; escalate :3393), E edge watchdog (:2985→:3427→:3455 full load(); 10s cooldown :3437), X PlaybackStalled (:3198), Y "Playlist File unchanged"/-12888 (:3325; else silently dropped :3326).
- VM rung V order (PlayerViewModel:1505): EOF suppress :1507 → outage :1511 → near-end⇒EOF :1515 → V3 replan :1520 → session-missing renewal :1524 → premature-source-end⇒outage :1532 → interruption :1546 → native-direct recovery :1550 → silo→HLS :1553 → terminal :1556.
- 16 timers/watchdogs enumerated (startup 1s/6s/60s :413-415; playhead 1s/10s/12s/3-per-90s/30s/15s :426-441; seek deadline 15s :416; video display fallback 3s :3749; displayMode settle ~6s HDRDisplayCriteriaPolicy:73-76; edge max(3,td*2+1) :3020; item-death 3s :118; cooldown 10s :3437; initial-seek 8×200ms :3533/:1144; time observer 0.1s :2372; display link :2393; segment-miss wait 8s :1626/:1837; VM heartbeat 10s PVM:7345; VM outage 90s PVM:964; interruption 3s PVM:960; PiP grace 1s PVM:4735).
- Output routes: backend :775-785 KVO → :978 reloadEstablishedLoopbackItem AND VM :1435→:4725 pause decision from same KVO body :782-783. PiP coordinator iOS/PictureInPictureCoordinator.swift:58,:181-213; backend :870; VM :1472→:4744→:4753. Audio session backend :299. Remote commands NowPlayingController:231-304 wired PVM:3378; backend also infers intent :865.
- Track application: audio backend :1246 (loopback = full rebuild :1313; remote item.select :1326); subtitles :1330 5-way; secondary :1432.

## State audit
~90 mutable fields. Booleans list (:601,:603,:604,:605,:620,:678-680,:700,:714,:715,:718,:721,:722,:723,:543,:668,:1516,:641). Generations: seekDeadlineState :12-13, loopbackGeneration :703, activeLoopbackSessionID string compare (:1913,:1953,...) = three staleness idioms. Only real enum: loopbackStartupRecoveryStage :687. teardownMediaPipeline :4129 resets ~35 fields by hand, called from load() :1560 and dispose() :1195.
Invalid combos (static proof):
- B8-1 recovery seeks (:1748,:1785,:3671) never set isSeekPending/deadline.
- B8-2 resumeLocalLoopbackPlaybackIfNeeded :3458 lacks hasReachedItemEnd guard (set :3194); called from :3177/:3158 → play() after EOF (narrow window; VM pause :3338 sets isUserPaused :858).
- B8-3 didEscalateLoopbackStall set :2919 then reset :3415 by rebuild → unbounded rebuild loop across sessions (no global rebuild counter).
- B8-4 hasReachedItemEnd sticky across reloads (:1761,:3679 don't clear; cleared only :1014/:1589) → transport intent resolve nil :244.
- B8-5 isPreservingTVDisplayCriteriaForReload latched (:1564 set; cleared only :4280 via :2105).
- B8-6 isSeekPending vs seekDeadlineState.activeID vs isInitialSeekInFlight three-way redundancy (:1111,:1099-1103,:2378,:2398).

## Multiple responders
- FailedToPlayToEndTime :3210 → note :3227 consumed by watchdog tick :2866 OR :3235.
- PlaybackStalled :3198 vs watchdog rungs (:2904,:2975) different thresholds; 10s cooldown does not cover performVODStallRecovery.
- isPlaybackLikelyToKeepUp :3152 reports AND acts (play()).
- Segment miss: server :515-540 → resolver :1832 restart+8s wait; server 503/404 :611-629; errorLog → item-death evidence :3245-3275 (three responders).
- External playback KVO :782-783 → backend reload + VM pause.
- Watchdogs S/P mutually exclusive (:2794 vs :3584) — clean.

## Claims
- D1 string classifiers/near-end: CONFIRMED, high, high conf. shouldTreatPlaybackErrorAsNaturalEnd PVM:1655 (remaining≤8 || progress≥0.985) is exact negation of handleEndOfFile premature check :3305-3306 → premature branch :3310-3329 unreachable on error path; error at 0.986 progress marks completed :3357-3364 + next-up autoplay :3368. Pin test PlayerErrorClassifierPinTests.swift:74-77 (duration 10, t 2.1 ⇒ true). Recoverable dropped: :3325-3326 silent return. Substring collisions pinned as bugs in PinTests :52-57,:163,:177-184. Six free-form reportError sites (:1865,:2010,:2092,:3621,:3650,:3683,:4363); onError: (String)->Void :506. Fix: gate on buffered≤0.1 && !outage && remaining≤8 (drop ratio arm), route via handleEndOfFile(forcedPremature:).
- D2 split ownership both act on one failure: CONFIRMED, high. attemptProtocolV3Replan PVM:1567 sets isLoading :1583, awaits replan :1592; adoptPreparedPlayback :2483 only disposes on quality-switch :2532, protocolV3Replan origin `break` :2523 → backend watchdogs stay armed during replan round-trip. Suppression :545 coarse (:2911,:2951 only). Fix: suspendRecovery(reason:) latch at :2791,:3432,:3348,:3459 set at PVM:1583/defer :1587.
- D3: REFUTED for engine selection; CONFIRMED for within-route re-planning.

## Rewrite verdict (slice): don't rewrite backend; split into ~900-line AVPlayer adapter + one pure RecoveryPolicy state machine + LoopbackSessionHost value + SeekRequest + StartupGate values; typed PlaybackFailure first. Pattern already exists (LoopbackStartupRecoveryPolicy, LoopbackIngestEndPolicy, LoopbackRestartCoalescer, HDRDisplayCriteriaPolicy, AVPlayerSeekDeadlineState).
Ordered small fixes: PVM:1515 near-end; backend :3459 guard; :3632 comment; :1748/:1785/:3671 deadlines; :2919/:3413 budget; generalize :545; typed onError :506.
Accidental deletions: [CMP-MEM] :454-482,:2846-2860,:534,PVM:2747; SILO_KEEP_DV_HLS :722,:1806,:4208,:4376; 8×200ms retry :3533/:1144; AVPlayerSystemTransportIntent :214-255.
