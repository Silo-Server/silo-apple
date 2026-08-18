# Silo Apple playback pipeline — independent architecture review

**Repository:** `/Volumes/NVMe/dev/github/SiloServer/silo-apple`
**Branch (verified):** `player/one-player-cleanup` — **HEAD `36393b47`** (working tree clean)
**Siblings (read-only comparison):** `silo-server` `main` @ `5fdb5d73` (2026-08-15); `silo-android` `fix/tv-login-overflow` @ `d6c91e62`
**Date:** 2026-08-17
**Method:** six independent read-only slice reviews (VM orchestration; AVPlayerBackend/recovery; loopback writer/store/server/proxy; Protocol V3 across Apple/server/Android; track identity/selection; tests/observability/migration) followed by an adversarial pass instructed to flip verdicts in both directions, then synthesis. Every line reference below was re-derived at `36393b4` (docs' numbers were not trusted). File aliases: `PVM` = `iosApp/iosApp/Screens/Player/PlayerViewModel.swift`; `backend` = `…/AVPlayerRoute/AVPlayerBackend.swift`; `writer` = `…/AVPlayerRoute/LoopbackSegmentWriter.swift`; `bridge` = `…/PlaybackSessionBridge.swift`; `planner` = `…/ApplePlaybackRoutePlanner.swift`; `adapter` = `…/ProtocolV3/ApplePlaybackV3PlanAdapter.swift`.

**Status (2026-08-18):** Rounds 1, 2, 2b and the server pairing (silo-server PR #670) have landed on `player/architecture-remediation`; see `docs/cleanup/app-cleanup-backlog.md` §0 for the round table, what remains (Round 3+, #10, #11, P1/P2), and the open hardware finding. This document is the review as written; §3 rows are not edited retroactively.

**Evidence labels used throughout:** **[static]** = proven by reading control flow at HEAD; **[plausible]** = mechanism proven, runtime frequency/impact not reproduced; **[historical]** = git history or docs, not current-checkout behaviour. **No runtime reproduction was performed anywhere in this review.**

---

## 1. Executive verdict

1. **A major rewrite is justified — but of the control plane, not the media plane.** The VM lifecycle core (~1.1k lines of `PVM` around load/adopt/recover/seek), `PlaybackSessionBridge` identity handling, and the backend's six recovery ladders should be replaced by a typed state model with one recovery-policy owner. `AVPlayerBackend` should be *split* (thin AVFoundation adapter + extracted pure policy), not rewritten. `LoopbackSegmentWriter` should be *narrowed and point-fixed*, not rewritten: its hard-won behaviour lives in constants and comments traceable to specific device incidents, and its irreducible core (DV RPU conversion, `dvcC`/`dvvC`/`dec3` box synthesis, keyframe-gated cutting, TrueHD→FLAC) is essential media complexity.

2. **Recommended end state = "Option D": Option B's local matrix + control-plane rewrite + server-authoritative planning tightening.** Keep loopback for copy-only H.264/HEVC/DV in MKV/TS (the daily-traffic case stays local and stays exercised), FLAC-only audio normalization, VOD-plan-only serving. Delete the video-bridge tier, `.passthroughAV1`, the EC3/AC3/AAC encoder ladders, and (after gating fix C2) the plan-less EVENT fallback. This is **conditional on two product decisions** (§10 P1/P2): whether "Dolby Vision presented as DV (P8.1) rather than HDR10" and "lossless multichannel audio rather than AAC" are product commitments, and whether the common MKV case may move to server remux. If P1 is "no", Option C becomes viable and cheaper than the slices assumed (§7).

3. **Ship four point fixes regardless of any option** (§3 #1, #2, #3, #5): a one-day-old unreleased regression that silently disables all backend→VM callbacks after any same-engine replan; the near-end→EOF classifier that provably can never take its own "premature" branch on the error path; backend recovery running concurrently with a VM replan; and the tvOS untracked stop-session task.

4. **The pipeline's largest complexity multipliers are not the biggest files.** They are: (a) recovery authored in four places with a suppression handshake between them; (b) three staleness idioms (`streamLoadGeneration`, `loopbackGeneration`, `activeLoopbackSessionID` string compare) plus six mirrored session ids; (c) two planners in series with the second one's execution decisions never reported back to the server; (d) `String` as the only failure channel out of the backend, re-parsed by four substring classifiers; (e) `videoOutputMode × videoMode × VOD/EVENT × restart` in the writer; (f) subtitle selection decided at eleven sites over eight `pending*` optionals.

5. **Protocol V3 is authoritative for delivery, advisory-plus for execution.** Within `original_http` Apple legitimately re-decides engine/DV display/local resolvability, but also silently re-decides audio and video recipe and reports `local_mutations: []`, so the server's attempt-key exclusion cannot see what actually failed.

6. **Three preconditions block any staged migration today:** zero composed lifecycle tests (no test constructs `PlayerViewModel`, `AVPlayerBackend`, or `PlaybackSessionBridge`); no remote kill switch for any route (rollback = TestFlight); and `docs/tvos-player/validations/` is empty, so there is no validated hardware baseline to regress against.

---

## 2. Current pipeline and ownership map

### 2.1 Data path (online, `original_http` → loopback)

```
PVM.beginFreshLoad → bridge.startSession (subtitle intent resolved BEFORE wire, bridge:523-624)
  → server PlanPlaybackV3 (silo-server internal/playback/plan_v3.go:116-484)
  → adapter.validate (adapter:43-85) → synthesized legacy PlaybackSessionResponse (adapter:87-165)
  → PVM.makeExecutionPlan (PVM:2301-2328): ApplePlaybackRoutePlanner runs UNCONDITIONALLY (PVM:2306),
     then adapter overrides engine per delivery (adapter:225-239; original_http → basePlan.engine)
  → PVM.prepareSourceProxy (PVM:2845-2971) — REBUILDS LoopbackSessionSpec (PVM:2934-2945)
  → PVM.loadStream (PVM:2671) → prepareBackend/installBackend (PVM:1145/1130) → loadBackend (PVM:1157)
  → backend.load(sessionSpec:) → startSiloLoopback (backend:1809-1852) → writer/store/server
  → PlaybackSourceProxy (127.0.0.1) ← writer FFmpeg demux → copy remux → cutter/plan → store → LoopbackSegmentServer → AVPlayer
```
Offline: `Downloads/OfflinePlayback.swift:218-271` builds a synthetic `direct` session, no `protocolV3` (:266-270) → planner output reaches the backend un-adapted; `file://` skips the proxy (PVM:2848-2862).

### 2.2 Ownership today (who decides; who *also* acts)

| Concern | Nominal owner | Also acts (duplicated policy) |
|---|---|---|
| Delivery / fallback rung | **Server** online (PVM:1520-1522 returns before local ladders; bridge:999 replan, cap 8 at :1016; server exclusion `plan_v3.go:1045-1053`) | Local ladder `attemptNativeDirectRouteRecovery` PVM:2124 / `attemptSiloRouteHLSFallback` :2208 — **reachable offline only** (see §12). Pre-load bounce `needsServerReplanBeforeLoad` PVM:2378 |
| Execution recipe within `original_http` | Apple planner (`loopbackVideoOutputMode` planner:590-621; `loopbackAudioOutputMode` :667-680; container→local fMP4 :972-982) | Server already decided codec copy/transcode + audio channels (`plan_v3.go:634-649`); Apple never reports (`localMutations: []` bridge:1121-1123) |
| Session identity | bridge `sessionId` (:244; adopt :349; clear :1538) | VM mirror `activePlaybackSessionId` PVM:835 + three single-flight echoes :607/:627/:844; bridge attempt ids :248-252 |
| Load generation | `streamLoadGeneration` PVM:353 (single increment :2695) | `freshLoadGeneration` :639; `serverOutageRecoveryGeneration` :626; backend `loopbackGeneration` :703 + `activeLoopbackSessionID` string compare (~16 guards) |
| Source renewal | VM `attemptBackgroundSessionRenewal` PVM:3983 (bridge `renewDirectSession` :816-862, 22-field `canRetargetDirectSession` :864-893) + `attemptStaleSessionRenewal` :4110 | Five triggers (:1525/1528, :2883/2889, :7359/7365, :1623, :4103); proxy self-probes outage (`PlaybackSourceProxy.swift:918/:942`) while VM nudges `reprobeOrigin` :4205 |
| Recovery | **Four owners:** writer/ingest policy (`LoopbackIngestEndPolicy.swift:53`); backend six in-route ladders (backend:3572 startup, :2790 playhead, :2904 starvation, :3367 item-death, :2985 edge, :3325 playlist-unchanged); VM error ladder `handlePlaybackError` :1505; VM outage ride-through :4178/:4283 | Backend muzzled by VM via `setExternalStallSuppression` (backend:545 → :2911,:2951) and kicked via :559 — an explicit two-owner handshake |
| Track selection | Server plan intent (adapter:154; PVM:3549) | `SubtitleAutoResolver` (`PlaybackPrefsResolver.swift:95-188`), `applyTrackList` PVM:7078-7181, `appendSidecarTracks` :6944-7070 (own forced policy :7057-7065), planner `resolveLoopbackSelectedAudioTrack` :1265-1287, AVPlayer default, `LiveSubtitleCoordinator`, user — **11 sites** |
| Output-route change | Backend player-scoped KVO backend:775-785 → item reload :978 | Same KVO body hands VM a pause decision (:782-783 → PVM:1435 → :4725); AVAudioSession observer PVM:1083-1108 schedules a *replan* |
| Seek / reanchor | backend `seek()` :1011 (deadline :1069) | Recovery seeks bypass deadline (:1748,:1785,:3671); VM pre-emptors PVM:4984/:5063/:5120; VM seek-filter triple written from four places |
| Teardown | PVM `cleanup` :6224 | `deinit` :6346, `finalizeTerminalPlaybackError` :3947, `resetPublishedLoadState` :3390, `disposeActivePlayerForFreshLoad` :3718, `suspendForBackground` :7469, `installBackend` :1129; backend `teardownMediaPipeline` :4129 resets ~35 fields by hand |

### 2.3 Sizes (for scale)
`PVM` 7,867 lines; `writer` 7,000; `backend` 4,464; `PlaybackSourceProxy` 2,333; `PlaybackSessionBridge` 1,666; `planner` 1,379. Player total 57.8k raw lines. Player tests: 60 files / ~18.2k LOC.

---

## 3. Ranked confirmed defects

| # | Defect | Sev | Evidence | Verdict / smallest correction |
|---|---|---|---|---|
| 1 | **Same-engine V3 replan leaves old-generation backend callbacks installed; all new-stream events discarded** (`isLoading` never clears, tracks never applied, errors/EOF swallowed). Callbacks installed only in `makeAVPlayerBackend` PVM:1118-1124 ← `installBackend` :1130; `prepareBackend` :1145-1152 returns existing backend untouched; `loadStream` bumps generation :2695 then reuses when `.protocolV3Replan` (:2436-2439, :2738-2740; origin never disposes :2523-2524); handlers capture generation by value (:1200,:1217,:1408) vs strict `==` guard :5839-5844. Triggers: every audio/subtitle/quality/output-route/seek-reanchor replan that returns the same engine (:5488,:5515,:5539,:4536,:1102,:5022,:1560). | **HIGH** | [static]; [historical] pre-`e458784` code re-applied callbacks unconditionally (`git show e458784^`, old :2541-2549); regression from `e458784` (2026-08-16), unreleased | **Confirmed.** Re-apply `applyCallbacks(makeCallbacks(), to:)`, `wireSubtitleCallbacks(to:)`, `setServerChapters` after :2738-2740 (3 lines). Structural fix: handlers owned by a per-load token. Add the one test that asserts a live callback after same-engine reload. |
| 2 | **Near-end→EOF classifier is the exact negation of `handleEndOfFile`'s premature check**, so on the error path the "premature/Connection lost" branch is unreachable and a mid-stream failure at ≥98.5% (or ≤8 s remaining) marks the title completed and autoplays Next Up. `shouldTreatPlaybackErrorAsNaturalEnd` PVM:1655-1662 (`remaining <= 8 \|\| progress >= 0.985`) vs `isPremature` :3298-3307 (`remaining > 8 && progress < 0.985`), same guards, no await between :1515 and :3298; `handleEndOfFile()` takes no parameter. Also pre-empts V3 replan :1520, renewal :1524, outage recovery :1532. Pinned by `PlayerErrorClassifierPinTests.swift:74-77` (10 s title, t=2.1 ⇒ natural end). | **HIGH** | [static] | **Confirmed.** Corroborate: require buffer empty && no outage && `remaining <= 8` (drop the ratio arm), and route via `handleEndOfFile(forcedPremature:)`. ~10 lines. |
| 3 | **Backend recovery ladders keep running during a VM-owned V3 replan.** `attemptProtocolV3Replan` PVM:1567 sets `isLoading` :1583 and awaits the server; `adoptPreparedPlayback` :2483 disposes only on quality-switch (:2532; replan origin `break` :2523). Backend playhead/startup watchdogs, seek deadline, item-death and stall handlers stay armed and can reanchor (:3455), reload (:1761) or rebuild the session (:3406) mid-negotiation. Suppression :545 covers only two rungs (:2911,:2951). | **HIGH** | [static]; consequence [plausible] | **Confirmed.** Generalize `setExternalStallSuppression` into `suspendRecovery(reason:)` checked at backend:2791,:3432,:3348,:3459; set at PVM:1583, clear in defer :1587. |
| 4 | **Uniform (untrusted-keyframe) VOD plans in copy mode advertise segment indices the cutter never produces; the miss cannot heal.** `keyframeIndexIsTrustworthy` fails → `buildUniformPlan` (`LoopbackSegmentPlan.swift:94-120,:152-158,:209-245`); `forceUniformStride` only when bridged (writer:1389); cutter deliberately skips boundaries (`LoopbackSegmentCutter.swift:33-46`); playlist emits `0..<segmentCount`+ENDLIST (writer:6681-6698); no backfill (NAMING-DRIFT detector :6242-6259 logs only). Server: GET with resolver → early-200 read-until-close at 2 s then cancel; HEAD/no-resolver → 503 (`LoopbackSegmentServer.swift:601-625`). `requestVODProducerRestart` backend:1679-1697 swallows a restart for an already-marched-past index; only the starvation rebuild (:2904-2925) escapes, once. | **HIGH** mechanism / **MED** frequency | [static] mechanism; hole rate GOP-dependent [plausible] | **Confirmed (mechanism).** At writer:1017 refuse VOD when `!plan.usedKeyframeIndex && videoOutputMode == .copy` (fall to EVENT), or emit placeholder entries for skipped indices. This gate must land **before** the EVENT fallback is deleted. |
| 5 | **tvOS background suspension launches an untracked `stopSession`; identity-unconditional clear after three awaits can erase a session resumed in between.** `suspendForBackground` PVM:7469 bare `Task` :7507-7510 (after `cancelAll` :7491); bridge `stopSession` :1492 reads `sid` :1493, awaits :1507/:1520/:1529, clears :1538-1543 unconditionally; resume `beginFreshLoad(progressPosition:nil)` :7521 skips the only await site :3641. Consequence: `reportProgress` returns `.transientFailure` :1430 (renewal ladder never fires), replans return nil :1011-1013 → terminal. | **MED** (tvOS-only) | [static] mechanism; interleaving [plausible] — needs slow DELETE vs cached reads | **Confirmed (mechanism), narrowed to tvOS.** `guard sessionId == sid else { return }` before :1538; register the task. Same window shape at :3643/:6326 is already guarded/ordered. |
| 6 | **`initSegmentWritten` latched with no `init.mp4` ever published** (moof-before-moov arm writer:5779-5787); VOD playlist carries `EXT-X-MAP` :6693 + ENDLIST → permanent 404 on map; startup gate :6565-6567 still fires. | **MED-HIGH** | [static] | Fail the session instead of latching. |
| 7 | **Open progressive segment held in three unbounded, partly unaccounted buffers**: `boxBuffer` :532 (whole fragment), `pendingSegmentBytes` :5985 (many fragments in progressive mode :5815-5835, no cap), `Store.progressiveSegments` :141 (second copy :6041-6044 → `Store:455-463`, not in `memoryBytes`). Cut is keyframe-gated only :1672-1696; anchors "30–60 MB" (writer:5996-5998) on ≤3.5 GB devices (:6303). | **MED-HIGH** on constrained tvOS | [static] | Count progressive bytes in `memoryBytes`; hard ceiling that force-cuts. |
| 8 | **AVIO buffer leaked per writer lifecycle (= per producer restart / seek).** `av_malloc` 64 KiB writer:3063-3067; only `av_free` is the alloc-failure arm :3092; teardown :6857-6861 `avio_context_free` then drops `ioBuffer` with a wrong comment :6859; no `av_freep(&ctx->buffer)`, `avio_closep` anywhere. New writer per restart backend:1706-1719. | **MED** | [static] in-repo; FFmpeg 7.1 contract is external knowledge (headers not vendored) | `av_freep(&avio.pointee.buffer)` before `avio_context_free`; demote `ioBuffer` field :521. |
| 9 | **`prepareSourceProxy` rebuilds `LoopbackSessionSpec` field-by-field and drops `videoOutputMode`, dimensions, bridged parameter sets** (PVM:2934-2945 vs designated init defaults `PlaybackExecutionPlan.swift:217-231`); stripped spec reaches the backend (:2947-2966→:2733→:2754→:1169); `makeFallbackLoopbackSession` :6730-6749 same omission. Bridge therefore structurally unreachable for network sources. | **MED (latent)** — bridge is also unreachable via advertised capabilities (#13), so no live user impact today; significance is the reconstruct-by-hand pattern | [static] | **Confirmed, dormant online.** Replace with a `withSource(url:headers:)` copy helper on the spec (mirror `reanchored(at:)`). |
| 10 | **Server's chosen audio track silently dropped on native-direct / server-HLS routes**: `applyTrackList` PVM:7121-7128 matches via `audioSelectionIndex = srcId ?? ffIndex` (planner:1289-1291), both nil for AVFoundation rows (backend:3949-3950). Honoured on loopback only. | **MED** | [static] | Give AVF rows a server index or match by language/ordinal explicitly. |
| 11 | **`srcId` overloaded three ways; translate menu sends an FFmpeg stream index as a server combined index** (`Sheets/SubtitleTranslateMenu.swift:80` admits any non-bitmap `srcId`; `Subtitles/SubtitleAIController.swift:287,294-299`; doc :281-285 claims embedded excluded — it isn't). | **MED** | [static] | Typed subtitle identity (see §8). |
| 12 | **Protocol V3 drift**: server has `output_change` replan op (`protocol_v3.go:411`, feature `output_change_v1` :22, schema `replan-request.schema.json:35,:743`, conformance :4151-4158); Apple and Android both lack it (bridge:899-908 maps to `failure_recovery` + classification `"output_route_changed"` :1030-1033; Android `PlaybackProtocolV3.kt:44-48`, `PlayerViewModel.kt:851`). Fixture SHAs: `capability_response`/`conformance_matrix`/`decision_response` differ from server HEAD; Android hand-edited `replan_request`/`start_request`; neither client's vendored server commit is an ancestor of server `main`. Behaviour masked by server shim `playback_v3.go:1819-1820`. | **MED** | [static] | Re-vendor + pin SHA (will fail `PlaybackProtocolV3ConformanceFixtureTests.swift:25` 9→10); add `ReplanOperation.outputChange` gated on feature like `seek_reanchor` (:1039-1042). |
| 13 | **Flat capability cross-product advertises unexecutable combos** (`ApplePlaybackV3Capabilities.swift:154-170`: 16 containers × h264/hevc): h264-in-`avi`/`webm` → server `original_http` (`plan_v3.go:340-351`) → planner `container_not_normalizable` (:643-647, because #9 guarantees `.copy`) → `engine=.avPlayerHLS, delivery=.direct` → abort-and-replan PVM:2378-2380/:2686-2692. Same root as #9. | **MED** | [static]; real-library frequency unknown | Restrict `original_http` containers at `ApplePlaybackV3Capabilities.swift:159` to `nativeDirect ∪ siloSource ∪ audioContainers`. |
| 14 | **`SiloControl` LAN remote can trigger replans with no `isLoading` guard** (`applySiloControlCommand` PVM:7567; realtime path has `guard !isLoading` :6446) — most reachable external trigger for #1. | **MED** | [static] | Add the guard. |
| 15 | Backend flag hazards [static]: recovery seeks with no deadline (:1748,:1785,:3671); `resumeLocalLoopbackPlaybackIfNeeded` :3458 lacks `hasReachedItemEnd` guard; starvation latch reset by the rebuild it guards (:2919→:3415, no session-scoped rebuild budget); `hasReachedItemEnd` sticky across reloads (:1761/:3679); `isPreservingTVDisplayCriteriaForReload` can stay latched (:1564 vs :4280). | LOW-MED each | [static] | Listed in §9 stage 1. |
| 16 | FFmpeg send-EAGAIN drops input silently at six sites; comment `LoopbackVideoBridge.swift:410-411` false. Unreachable on happy path (each send followed by drain loop). | **LOW (dormant)** | [static] | Fix comment; count drops; `continue` instead of `return` at bridge:433-435 / writer:4614-4617. |

---

## 4. Ranked architectural trouble spots

1. **Recovery has four owners and a negotiation protocol between two of them** (§2.2). Six backend ladders with independent thresholds/budgets/reset semantics (16 timers/watchdogs enumerated in slice 2); VM ladder with ten branches and no in-flight latch (PVM:1505-1557); outage ride-through vs outage recovery are two escalation systems for one condition (:4170-4247 vs :4283).
2. **Identity is scattered.** Six session-id stores + three generation counters in the VM/bridge, plus `loopbackGeneration` and `activeLoopbackSessionID` in the backend (three staleness idioms for one lifetime), plus `plan_attempt_id` frozen across seek reanchor (bridge:1242-1247) and `output_context_id` compared against different bases client vs server (PVM:1094 vs `playback_v3.go:1820`). Where a check is missing you get #1/#5.
3. **Two replan pipelines with no mutual exclusion**: `attemptProtocolV3Replan` (guard :1576) vs `restartCurrentTranscodeHLS` :5120 occupying `freshLoadTask` :5160-5163; both call `adoptPreparedPlayback` mutating ~20 fields with no generation guard.
4. **`String` is the only failure channel out of the backend** (`onError: (String)->Void` backend:506; six free-form `reportError` sites) → four VM substring classifiers (PVM:1634,:4427,:4446,:6712) whose quirks are pinned as bugs (`PlayerErrorClassifierPinTests.swift:40-43,:161-163,:174-186`).
5. **Two planners in series; second stage's execution decisions invisible to the server.** Planner runs on every load PVM:2306 (its `sourceMetadata`/`decisionTrace` are consumed by the adapter :259/:263/:289, so it cannot simply be skipped); within `original_http` it re-decides audio/video/container and reports `localMutations: []`. ~30 blocker/trace tokens consumed by nothing but one log line (adapter :288 `parityBlockers: []`). Four capability surfaces (`AppleDecodeCapabilities.swift:3-17` names the problem; `ApplePlaybackRouteCapabilities` 440 lines duplicates `plan.claims`).
6. **Track selection: eleven decision sites, eight `pending*` optionals, three restore mechanisms armed together on replan** (PVM:3549,:2549-2558), two resolvers disagreeing on forced subtitles (:7057-7065 vs `PlaybackPrefsResolver.swift:166-177`), appearance toggle discarding explicit track choice (:3158), audio change re-running subtitle policy (:5486), user selections dropped while suspended (:5482 et al.).
7. **Writer axes**: `videoOutputMode(4) × videoMode(5) × VOD/EVENT × restart/recycle × 6 audio modes`, plus three `+delay_moov` workarounds and historical patch layers each naming one incident (writer:5577,:5622-5678,:5232,:6163-6178,:87,:213). Buffering policy triplicated across proxy/store/writer with a shared clamp but no shared accounting.
8. **14 unregistered `Task {}` in the VM** (incl. :5114 launching a full `loadStream`) beside a 23-key × 4-scope hand-maintained task registry.
9. **Platform divergence inside single functions**: `handleScenePhase` PVM:4632-4715 — tvOS full suspend/resume machine, iOS four exemptions, **macOS unconditional pause on background with no AirPlay/PiP/suspend handling** (:4674-4680); `#if os(iOS)` inside `applyCallbacks` (:1431-1476).
10. **Six error-recovery rungs are unreachable online** (PVM:1524-1553; V3 is the only online start path bridge:501-504; `activePreparedProtocolV3` set :2540, cleared :3436/:3966) — dead weight that misleads readers and reviewers (it misled two slices here).
11. **Observability split**: `cmpLog` (only path into diagnostics bundles, `PlayerLog.swift:37`) used once in `PVM` (:2365) vs 106 `Self.logger` sites; `playbackSessionId` appears in one VM log line (:2348); `streamLoadGeneration` never logged. No remote route kill switch (only `player.dolby_vision_enabled` changes a route; six `player.apple.*` keys are local `defaults write`).
12. **A second V3 client nobody reviews**: the audiobook engine (`Screens/Audio/AudioPlayerViewModel.swift`, `AudioPlayerEngine.swift`) emits its own capability snapshot (`ApplePlaybackV3Capabilities.swift:225-320`).

---

## 5. Essential vs accidental complexity

**Essential (imposed by AVPlayer / FFmpeg / HLS-fMP4 / DV / audio / subtitles / AirPlay / PiP / offline):**
- AVFoundation: KVO fan-in on 8 item/player properties, three notifications, `AVPlayerItemErrorLog` polling as the only signal for "trouble without `.failed`" (backend:3078-3275); off-main audio-session serialization (:299-378); zero-tolerance seeks + late-completion filtering; tvOS display-criteria write→settle→attach ordering (:4262-4331, `HDRDisplayCriteriaPolicy`); PiP delegate binding; AirPlay receiver URL rewriting (:920-945); telling AVPlayer not to poll a paused local playlist (:2205-2209). ~700–900 lines of genuine adapter.
- FFmpeg/fMP4/DV: `ISOBoxSurgery` (690) — `dvcC`/`dvvC`/`hvcC` synthesis FFmpeg's muxer does not emit for this input (writer:754-758); P7→8.1 RPU conversion via libdovi + EL drop (writer:5304-5367); `dec3` JOC extension (`ISOBoxSurgery.swift:480-580`); keyframe-gated cutting under B-frame reorder (`Cutter.swift:8-15`); TrueHD major-sync; `+delay_moov` ordering; CODECS/SUPPLEMENTAL-CODECS exactness (writer:6770-6778); TrueHD/DTS→FLAC (mp4 cannot carry them).
- Subtitles: libass rendering, PGS/VobSub decode, three real index spaces (FFmpeg stream index, server combined ordinal `subtitle_inventory_v3.go:106`, AVMediaSelection ordinals) — translations at route boundaries are irreducible (adapter:171-212).
- Product-essential: keeping the live backend across an in-place replan on tvOS to avoid HDMI renegotiation (PVM:1139-1143) — the mechanism is right, only its wiring broke (#1).

**Accidental (ownership, duplicated policy, mutable state, ladders, residue):**
- Four recovery owners; six backend ladders where one pure policy would do (the codebase already proves the pattern: `LoopbackStartupRecoveryPolicy`, `LoopbackIngestEndPolicy`, `LoopbackRestartCoalescer`, `HDRDisplayCriteriaPolicy`, `AVPlayerSeekDeadlineState`).
- Generation-capture callback discipline; six mirrored session ids; `LoadRequest.copyForRecovery` reconstructed at four sites; seek-filter triple; ~35-field hand reset in `teardownMediaPipeline`.
- String failure channel + classifiers.
- Two planners; ~30 dead trace tokens; four capability surfaces; quality in four representations incl. legacy `/transcode/start` helpers for an endpoint that no longer exists (`ApplePlaybackQuality.swift:261-354`, :299-305).
- Writer: bridge tier (dead online, dead-ish offline), `.passthroughAV1` (dead everywhere), `transcodeEC3/AC3` (no producer), diagnostics probes in hot paths, `[CMP-MEM]` "temporary" block (backend:454-482), `SILO_KEEP_DV_HLS` threading, six `UserDefaults` forks.
- Subtitles: VTT/SRT→ASS conversion + `SubtitleStylingOverride` (~1,100 lines) so one renderer serves all; live-AI websocket stack (~2,100 lines; Android polls only); three acquisition UIs (1,436 lines); forced-sidecar side policy; four parallel slot collections in `SubtitleSession`.

**Real-but-challengeable product features (§10):** DV-as-DV vs HDR10; lossless multichannel vs AAC; client PGS decode vs server burn-in; live-AI subtitles; client ASS styling; bridge codecs; MKV downloads.

---

## 6. Recommended policy ownership (server / Apple / Android)

| Concern | Owner | Notes |
|---|---|---|
| Delivery + fallback policy | **Server** (already, online). Apple must (a) report `local_mutations` for what it actually executes so attempt-key exclusion is complete (`plan_key_v3.go:49-50,69`; `playback_v3.go:1961-1973` already handle it), (b) narrow the planner's job to *execution detail* within `original_http` (engine kind, DV display resolution, local resolvability, client bitmap subs) — not codec/container re-decision, (c) delete the offline-only local ladder or make it explicitly offline. Android already has no local route planner (`PlaybackSessionManager.kt:686`) — the cleaner model. |
| Concrete Apple execution | **Apple** `PlaybackEngineSession` (§8). |
| Session identity | **Server** mints; **client** mints correlation ids (`playback_attempt_id`, `plan_attempt_id`, `output_context_id`). Apple: collapse the six mirrors into one `SessionIdentity` value; make every bridge mutation identity-conditional (idiom exists at bridge:310-321). |
| Source renewal | **Client**, against a server-declared contract (`header_refresh`, `expires_at`, `direct_stream_resume` feature). Apple's `renewDirectSession` is the reference design; **Android lacks it entirely** (`expires_at` decoded `PlaybackProtocolV3.kt:182`, no renewal) — parity gap, Apple ahead. |
| Recovery | **One owner per layer, one policy object**: a pure `RecoveryPolicy` (observation → `RecoveryAction`) inside the engine session for in-route recovery; the server for cross-route. The VM neither runs watchdogs nor decides rungs. |
| Track selection | **Server** default seeded by client-resolved preference (already); Apple: one `TrackSelectionCoordinator` owning a typed `TrackSelection`. Resolve the persistence fork (Apple server per-series PVM:5551-5561 vs Android local per (contentId,fileId) `UserItemStatePort.kt:98-103`) — product decision. |
| Output-route changes | **Engine session** (AirPlay URL swap, PiP layer) reports typed `PlayerEvent.outputRouteChanged`; **one** policy responder (platform-command coordinator) decides pause/replan; server sees it as `output_change` (once #12 lands). |
| Seek / reanchor | **Engine session** owns a single `SeekRequest` value (all seeks, including recovery seeks, carry a deadline); the VM issues intents only. |

---

## 7. Comparison of rewrite options

Numbers: `AVPlayerRoute/` = 16,194 lines total, of which `AVPlayerBackend`+`AVPlayerSurface` serve all routes; loopback-only files ≈ 11,600 lines; proxy/origin stream/chunk fetcher = 4,335 lines and **survive every option** (proxy serves native-direct too, PVM:2846-2848, :2984-3001). Player tests: ~4,000 LOC / 17 files are loopback-only.

| | **A. Control-plane rewrite, preserve all local behaviour** | **B. Narrow loopback** (native direct; known-plan H.264/HEVC copy remux, strict set; server HLS for bridge/uncommon audio/bitmap/unknown-duration/long tail) | **C. Native direct + server HLS only** | **D (recommended). B's matrix + control-plane rewrite + server-authoritative tightening** |
|---|---|---|---|---|
| Preserves | Everything users see today | Common MKV/TS local remux, DV P5/7→8.1/8.x, lossless→FLAC, PGS client decode (product call), offline MKV | mp4/mov/m4v native; everything else server | As B, plus one recovery owner, typed state, honest server contract |
| Deletes | Nothing in media plane | Bridge tier (~1,500–1,700), `.passthroughAV1`, EC3/AC3/AAC ladders (~60), EVENT fallback (~450–600, after #4 gate), dead planner arms | ~11.6k loopback lines + FFmpeg xcframework (still linked by `Downloads/LocalMediaProbe.swift`) + 17 test files; `PlaybackEngineKind.siloPlayerLoopback`, planner allowlists :195-244, `assessSiloRoute` etc. | B's deletions + VM lifecycle core (~1.1k) replaced, backend six ladders → one policy, four classifiers → typed failure, dead online rungs, ~30 trace tokens, `ApplePlaybackRouteCapabilities` premium claims |
| Product tradeoffs | None visible; keeps dead/dormant paths (bridge) forever | Bridge codecs (VP9/AV1/MPEG-2/VC-1) go server-side (they already do online); unknown-duration → server HLS; long-tail audio → server | **DV → HDR10** (`dovi_rpu=strip=1`, `transcode.go:99`); **lossless multichannel → AAC** (server has no FLAC/ALAC/EAC3 recipe, `transformations_v3.go:37-40`); every MKV play = server remux session | As B |
| Offline | Unchanged | Unchanged (MKV downloads still local) | Requires flipping `download.transcode_enabled` (default false, `admin_settings.go:109`) so downloads are remuxed to MP4 (`prepare_file.go:33-34`); **TrueHD/DTS downloads become AAC**; existing MKV downloads on devices become unplayable → migration | Unchanged |
| DV / TrueHD-Atmos | Unchanged | Unchanged (note: TrueHD is FLAC/LPCM, **not passthrough**; Atmos preserved only for E-AC-3 JOC copy — docs/07:102,:146,:148-149) | DV P7/P5/P8 → HDR10 unless server HLS remux preserves DV metadata (**unverified in either repo — validation row**); no lossless | Unchanged |
| Subtitles / AirPlay / PiP | Unchanged | Bitmap subs: keep client decode (recommended) or server burn-in (product call) | Server burn-in for bitmap; AirPlay/PiP simplify (one URL family) | Unchanged from B |
| Outage | Ride-through survives server restart | Same | Lost — server HLS session dies with server | Same as B, but one owner |
| Server capacity | None | Slight increase (bridge/long-tail) | **Large**: every non-mp4 play (the majority) becomes a server remux/transcode session; availability coupling | Slight |
| Removable surface | ~1.5–2k (VM/backend refactor is replacement, not deletion) | ~2.5–3k product + ~1k tests | ~11.6k product + ~4k tests + FFmpeg dep, minus interwoven backend/VM residue | ~4–5k product + rewritten ~3k |
| Migration / rollback | Flag on control plane (needs new remote key); rollback = flag | Allowlist edits are one-line reverts but **no remote switch exists** → build a `player.apple.route_policy` remote key first | Revert = TestFlight cycle; needs full B release first | Staged (§9); every stage flag-gated |
| Validation | Composed tests + §11 rows 1,3,7,14 | + rows 6, 11 | + DV-through-server-HLS row; download remux row | Full §11 |
| Reduces complexity or moves it? | Reduces control-plane; keeps all media-plane multipliers | Reduces writer axes (bridge, EVENT, audio ladder) genuinely; keeps recovery ladders (they are loopback-essential — 15/16 guarded `.siloLoopback`) | Deletes the ladders and the writer wholesale; **moves** the wedge classes to server transcode capacity/availability and to product regressions | Reduces both; the ladders shrink to one policy rather than vanish |

**Adjudication of the adversarial counter-case.** The adversarial pass argued "narrowed is worst" against a variant where loopback serves *only* DV/TrueHD/offline. That is not Option B: B keeps the common h264/hevc MKV/TS case local, so the machinery stays exercised daily. Its surviving points are incorporated: no kill switch, no validation records, TrueHD ≠ passthrough, DV value = DV-as-DV, and the ladders are loopback-caused (so their *consolidation*, not deletion, is what the control-plane work delivers). Option C is more viable than the loopback slice claimed (download remux exists server-side), but it costs DV-as-DV, lossless audio, outage tolerance and server capacity — which is why it is gated on P1/P2 rather than rejected.

---

## 8. Recommended target architecture (Option D control plane)

Design principle: **make invalid states unrepresentable, put identity on every effect, and give each policy exactly one owner.** Moving today's flags into one big actor would fail; the following is what actually removes the defect classes found.

```
PlayerPresentationModel (@Observable, thin)      — projects PlaybackState → UI; no policy
PlaybackReducer (pure)                            — (PlaybackState, PlayerEvent|PlayerIntent) → (PlaybackState, [Effect])
PlaybackSessionActor                             — runs effects; every mutation conditional on LoadID/SessionID/PlanAttemptID
PlaybackEngineSession (one per load)             — owns AVPlayerBackend adapter + source transport (+ loopback host if any)
RecoveryPolicy (pure)                            — Observation → RecoveryAction?  (ONE owner)
Coordinators: TrackSelection, Seek, NextUp, Progress, PlatformCommands (PiP/AirPlay/NowPlaying/SiloControl/scene phase)
```

**Types (sketch):**
```swift
struct LoadID: Hashable { let raw: UUID }             // per loadStream; owns callbacks' lifetime
struct SessionIdentity: Equatable { let serverSessionId: String?; let playbackAttemptId: String; let planAttemptKey: String?; let planAttemptId: String; let outputContextId: String }

enum ExecutablePlan {                                  // valid by construction
  case nativeDirect(NativeDirectPlan)                  // URL, headers, startMode
  case serverHLS(ServerHLSPlan)                        // manifest URL, startMode(.startOfManifest|.absolute), quality ladder
  case localHLS(LocalHLSPlan)                          // LoopbackSessionSpec (non-optional), plan mode(.vod|.event), audio mode
}                                                      // kills PlaybackEngineLoadError.missingLoopbackSession (PlaybackExecutionPlan.swift:374)

enum PlaybackState {
  case idle
  case preparing(LoadID, SessionIdentity, PreparingPhase)          // .resolvingSession, .planning, .startingEngine
  case playing(LoadID, SessionIdentity, ExecutablePlan, Transport, Sub)   // Sub: .steady | .recovering(RecoveryStep) | .replanning(ReplanIntent) | .seeking(SeekRequest) | .ended
  case suspended(SuspendedContext)                                  // tvOS background; resume replays intent
  case failed(PlaybackFailure)
  case disposed
}
enum PlayerIntent { load(LoadRequest), play, pause, seek(SeekTarget, origin: SeekOrigin), selectTrack(TrackSelection), changeQuality(Q), outputRouteChanged(OutputContext), scenePhase(ScenePhase), dismiss }
enum PlayerEvent  { engine(EngineEvent, LoadID), session(SessionEvent, SessionIdentity), transport(TransportEvent, LoadID), timer(TimerID, LoadID) }
enum PlaybackFailure { itemFailed(code:Int?, domain:String?), stalledStartup, playheadWedged, itemDeath(evidence), transportExpired, transportOutage, ingest(IngestFailure), remux(RemuxFailure), engineLoad(...), serverTerminal(V3Terminal) }  // exhaustive; no strings
enum RecoveryAction { reassertPlay, nudgeSeek(to:), reloadItem(at:), reanchor(at:), rebuildLocalSession(at:), renewSource, rideThroughOutage(budget:), requestServerReplan(classification:), fail(PlaybackFailure) }
struct SeekRequest { let id: UUID; let target: CMTime; let origin: SeekOrigin; let deadline: Date }   // ALL seeks incl. recovery
```

**How this eliminates the found defect classes:**
- **#1 dead callbacks:** callbacks are created by and owned by `PlaybackEngineSession(loadID:)`; there is no "reuse existing backend with old closures" — reuse means the session actor re-binds the adapter to a new `LoadID` and the adapter's event stream is stamped with it. The reducer ignores events whose `LoadID` ≠ current; there is no by-value generation capture to forget.
- **#5 / identity erasure:** the session actor's `stopSession(expected: SessionIdentity)` mutates only if `state.identity == expected` — the idiom already at bridge:310-321 becomes the only way to mutate.
- **#3 split recovery:** `RecoveryPolicy` is the single consumer of engine observations; the VM has no watchdogs; a `.replanning` sub-state makes "recover while replanning" unrepresentable.
- **Two replan pipelines (§4.3):** `Sub.replanning(intent)` is one slot; a second intent while replanning is a reducer decision (queue/replace), not a race.
- **Seek filter surviving stream swap:** `SeekRequest` lives inside `.playing(LoadID,…)`; a new load discards it structurally; recovery seeks are `SeekRequest`s and therefore always have deadlines (kills backend B8-1/B8-6).
- **String classifiers:** `PlaybackFailure` is exhaustive; `replanOperation(forClassification:)` becomes a total switch, testable (slice 6 test #8).
- **`hasReachedEndOfFile` + near-end:** `.ended` is a sub-state; the near-end conversion is a reducer rule over a typed failure with corroborating transport evidence.
- **Six session ids / three generations:** one `SessionIdentity` + one `LoadID`; the backend's `loopbackGeneration`/`activeLoopbackSessionID` collapse into the `LocalHLSHost` value owned by the engine session.
- **14 untracked tasks:** effects are returned by the reducer and run by the actor under structured concurrency; there is no other place to spawn.
- **Track selection:** `TrackSelection { audio: .serverIndex|.engine(TrackRef)|.unset; primary/secondary: .off|.embedded(ffIndex)|.sidecar(combined)|.serverRendered(combined)|.liveAI(ordinal); origin: .user|.serverPlan|.autoPolicy|.recovered }` replaces eight `pending*` fields; `hasExplicitSubtitleChoice` becomes `origin == .user`; `srcId` disappears (each case names its index space).

**What remains irreducible and stays in the adapter/writer:** the AVFoundation observation set, display-criteria ordering, PiP layer binding, AirPlay URL rewrite, and the entire essential FFmpeg/DV/box-surgery core. The writer keeps its serial mux queue; only its lifecycle (`LocalHLSHost`: writer+store+server+plan+tap as one value with one restart coalescer) moves under the engine session.

**Where NOT to over-reach:** do not fold the writer into the actor; do not "state-machine" the writer's segment phase in the first pass (it is mux-queue-local); do not rewrite `ISOBoxSurgery`, `LoopbackSegmentPlan/Cutter`, or the subtitle renderer.

---

## 9. Staged migration plan with safe deletion points

**Stage 0 — point fixes + preconditions (no architecture change; ship regardless).**
- Fixes #1, #2, #3, #5, #14 above; comment fix backend:3632-3634 (`CompatibilityPlayer` fallback no longer exists, [historical] `f1b1bba`).
- Add the two smallest tests: "same-engine reload keeps a live `onTimeChange`"; "`stopSession` on a superseded id leaves `sessionId` intact".
- Build the **remote control-plane/route key** via the existing pattern (`SettingKeys.generated.swift`, `PlayerSettings.swift:339-370`, `flusher.enqueue`); until it exists no stage below has a non-TestFlight rollback.
- Fill `docs/tvos-player/validations/` with baseline records for §11 rows 1,3,7,14 **on the current build**, capturing the known 4K loopback `-17223` blip so it isn't misread later.
- Land the 15 characterization tests slice 6 identified as writable today (V3 decision→plan per fixture; `decisionTrace` snapshot; `logExecutionPlan` string; `needsServerReplanBeforeLoad`; `makeLoopbackFallbackPlan` nil/non-nil; classifier ×30; `replanOperation` totality; `canRetargetDirectSession`; `isMaterialOutputRouteChange`; `HDRDisplayCriteriaPolicy.selection`; proxy eligibility predicate; `sourceCacheBudget`; offline manifest→plan; V3 fixture round-trip).

**Stage 1 — seams and media-plane point fixes (behaviour-preserving).**
- `protocol PlaybackBackend` at `makeAVPlayerBackend` PVM:1118; inject `AVPlayer` (backend:571); inject a transport into `PlaybackSessionBridge` (`SiloAPI.shared` ×19).
- Typed `onError: (PlaybackFailure)->Void` (backend:506) with a temporary string bridge; then delete the four classifiers.
- Writer/store fixes #4 (gate), #6, #7, #8, #16; `LoopbackSessionSpec.withSource(url:headers:)` for #9; flat-caps fix #13; backend flag hazards #15.
- Re-vendor V3 fixtures + `output_change` (#12), coordinated with Android and the audiobook snapshot.

**Stage 2 — extract the control plane behind the flag** (`player.apple.control_plane`: `off|native_direct|loopback|all`). Reducer + session actor + engine session + `RecoveryPolicy` (merging the six backend ladders and the VM outage ride-through into one policy with the same constants). Native-direct flips first. Extract the subtitle half of the VM along its MARK seams (~2.4k lines, PVM:5476-7867) into `TrackSelectionCoordinator` + live-AI coordinator adapters — mechanical, separate PR.
  **Safe deletion points after this stage:** the offline-only local ladder (PVM:2124-2224) once offline is routed through the same reducer; `hasAttempted*` latches :845/:846; `ProtocolV3SidecarRestoreIntent`/`pending*` fields; `[CMP-MEM]`; `SILO_KEEP_DV_HLS` threading; the 8×200 ms initial-seek retry once `SeekRequest` lands.

**Stage 3 — narrow the local matrix (Option B deletions), each behind the route key.**
1. Bridge tier + `.passthroughAV1`: empty `siloBridgeSourceContainers`/`siloVideoBridgeCodecs` (planner:210-227), delete `LoopbackVideoBridge.swift`, drift governor, bridged audio anchoring, `bridgedVideoParameterSets` plumbing, planner :590-648 bridge arms, and their tests/fixtures. (Dormant online **and** blocked offline by `DownloadCaps` — lowest-risk deletion in the tree.)
2. EC3/AC3/AAC encoder ladders (writer:4407-4419, :4423-4451): TrueHD/DTS/other → FLAC only; ≤2ch → server HLS or FLAC (product call).
3. Plan-less EVENT fallback (~450–600 lines; ~30 `vodActive` branches, store non-VOD path) — **only after** #4's gate makes untrusted-keyframe copy sources fall to server HLS instead. Needs one device pass on a zero-duration source.
4. Server-authoritative tightening: planner limited to execution detail within `original_http` (keep its `sourceMetadata`/`decisionTrace` production for the adapter); populate `local_mutations` from resolved `videoOutputMode`/`selectedAudio.outputMode`; delete `ApplePlaybackRouteCapabilities` premium-claim machinery in favour of `plan.claims`; delete legacy `/transcode/start` quality helpers.

**Stage 4 — default the new control plane on; one release later delete the old VM core and the six backend ladders.**

**Stage 5 (only if P1 = "no") — Option C:** flip `download.transcode_enabled` + narrow `AppleDecodeCapabilities.containers`; migrate on-device MKV downloads; delete loopback files listed in §7; keep proxy/origin stream. Rollback is a TestFlight cycle — must trail a full release of Stage 3.

**Rollback per stage:** 0–1 `git revert`; 2–3 remote key flip; 4 flip back; 5 revert+TestFlight.

---

## 10. Product decisions required (before implementation)

- **P1 — Is "Dolby Vision presented as DV (P8.1 conversion) rather than HDR10" a commitment, and is "lossless multichannel (FLAC/LPCM) rather than AAC" a commitment?** These are the only capabilities loopback provides that the server cannot (server has `dovi_rpu=strip=1` → HDR10 and no lossless encoder recipe). Yes → loopback stays (Options B/D). No → Option C is on the table.
- **P2 — May the common h264/hevc MKV/TS case move to server remux (`server_remux_progressive`/HLS)?** Determines server capacity and outage-tolerance posture. Yes → C viable; No → B/D.
- **P3 — Offline downloads:** keep MKV downloads playable locally (needs loopback offline) or remux to MP4 on download (flip `download.transcode_enabled`; TrueHD/DTS become AAC; migration for existing downloads)?
- **P4 — Bridge codecs (VP9/AV1/VP8/MPEG-2/4/VC-1/WMV3):** delete the tier (recommended; it is unreachable online and blocked offline) or advertise them (needs server `capabilities_v3.go:135` change to accept `hardware:false`).
- **P5 — Unknown-duration / untrusted-keyframe sources:** server HLS instead of local growing playlist (enables deleting the EVENT fallback).
- **P6 — Bitmap subtitles (PGS/VobSub/DVD):** keep client RGBA decode or move to server burn-in.
- **P7 — Live-AI websocket subtitles:** keep (~2,100 lines) or poll-only like Android.
- **P8 — Client VTT/SRT→ASS restyling** vs server-produced styled sidecars (~1,100 lines).
- **P9 — Track-persistence policy fork:** Apple server per-series vs Android local per file — pick one.
- **P10 — Near-end EOF policy:** what corroboration is required to convert an error into a natural end (currently 8 s or 98.5%).
- **P11 — Kill-switch/flag contract:** agree the remote key(s) with silo-server before Stage 2.
- **P12 — Validation gate:** require §11 baseline records before any Stage ≥2 flag flips.
- **P13 — `output_change` adoption timing across Apple/Android/audiobook clients.**

---

## 11. Minimal characterization-test and hardware-validation matrix

**Characterization tests (write first; all pin product/wire contracts, none freeze the defects):** the 15 in Stage 0 plus, once the Stage 1 seam exists: (16) exactly one recovery action per failure while `.replanning`; (17) same-engine replan re-binds callbacks (no dead stream); (18) `stopSession(expected:)` no-op on superseded identity; (19) `PlaybackFailure` → `RecoveryAction` table for the six ladders' constants; (20) uniform copy-mode plan → server HLS (or placeholder emission) rather than an advertised hole; (21) `TrackSelection` survives fallback/replan without fuzzy match when ids are stable; (22) reducer rejects a second replan intent while replanning; (23) macOS/iOS/tvOS scene-phase tables.

**Existing tests to keep vs retire:** keep the 27 "P" files (~11.5k LOC) and the wire-fixture tests; **rewrite** the two `PinTests` (they pin bugs #2 and the classifier quirks by design — replace with the typed-failure table); retire the 17 loopback-only files only under Option C; retire bridge tests in Stage 3.1.

**Hardware matrix (14 baseline rows + 2 new (15–16); run each on HEAD baseline and on the rewrite; record per `06-validation-record-template.md`):**
1. Apple TV 4K → HDR TV + AVR: DV **P7** MKV + TrueHD — loopback (`convertProfile7To81`); DV mode switch on TV, FLAC/LPCM on AVR (**not** Atmos); capture `-17223` baseline. *(core)*
2. Apple TV: DV **P5** mp4 + EAC3 — loopback ahead of native-direct (pin `ApplePlaybackRoutePlannerPinTests.swift:384-387`).
3. Apple TV: HDR10 MKV — `player.apple.hdr_display_criteria_enabled` on **and** off. *(core)*
4. Apple TV: h264/AAC mp4 — native-direct control (first route to flip).
5. Apple TV: MKV with PGS primary + ASS secondary — client bitmap + overlay together.
6. Apple TV: MKV with DVB subs — planned fallback to server HLS burn-in.
7. Apple TV: 4K HEVC long-GOP — seek-heavy (20+ scrubs; progressive anchor; reanchor). *(core)*
8. Apple TV → AirPlay receiver: HEVC/EAC3 loopback (LAN URL swap).
9. iPhone: h264 mp4 native — PiP enter/exit + background grace.
10. iPhone: HEVC/EAC3 loopback — background/lock/Now Playing; tvOS suspend/resume analogue.
11. iPhone airplane mode: offline MKV download (loopback, unproxied) and — if P3 flips — offline remuxed MP4.
12. Apple TV: source expiry mid-play (force 404) → background renewal, no visible interruption.
13. Apple TV: server stop/restart mid-play → ride-through → resume at position.
14. Apple TV: source that fails native-direct startup → **exactly one** rung-1 then ≤1 rung-2, selections preserved. *(core)*
15. **(new, Option C gate)** DV P5/P8 through **server** HLS remux — does DV metadata survive to the TV? Unverified in either repo.
16. **(new)** macOS: background/AirPlay behaviour (currently unconditional pause PVM:4674-4680).

---

## 12. Claims rejected or narrowed

| Claim | Outcome | Basis |
|---|---|---|
| Same-engine replan callback discard | **Confirmed, strengthened** — no other assignment site; same-engine is the majority of replans; unreleased regression `e458784` | §3 #1 |
| tvOS untracked stop erases resumed session | **Confirmed mechanism, narrowed** to tvOS-only, medium; cleanup and fresh-load paths already ordered | §3 #5 |
| Source-proxy spec reconstruction drops fields | **Confirmed, dormant online** (bridge also blocked by capabilities); latent | §3 #9 |
| Uniform plan holes | **Confirmed mechanism**; wire detail narrowed (early-200/cancel for GET, 503 for HEAD); restart is swallowed; one escape via starvation rebuild | §3 #4 |
| EAGAIN drains without resend | **Confirmed as written, dormant** | §3 #16 |
| AVIO buffer leak | **Confirmed** (in-repo); FFmpeg contract external | §3 #8 |
| Progressive segment memory unbounded/duplicated | **Confirmed, stronger** (three buffers) | §3 #7 |
| Apple/Android drifted from `output_change` | **Confirmed** (contract + fixtures); behaviour masked by server shim | §3 #12 |
| Apple plans twice | **Narrowed**: legit half (DV display, encoder probe, local resolvability, bitmap subs) vs re-decision half (audio/video/container) unreported; **skipping the planner for HLS deliveries would break the adapter** (it consumes `sourceMetadata`/`decisionTrace`) — narrow its job instead | §4.5 |
| Flat capability lists / dormant bridge | **Both confirmed**; `.passthroughAV1` additionally dead everywhere; C1 and flat-caps are one defect | §3 #13 |
| Little composed lifecycle testing | **Confirmed, stronger**: zero constructions; no UI test target | §11 |
| String classifiers / near-end heuristics | **Confirmed, stronger**: exact negation; pre-empts replan/renewal/outage too | §3 #2 |
| "Backend re-plans routes / falls back to another engine" | **Refuted** for engine selection (backend never selects another engine; stale comment :3632-3634); confirmed for within-route re-planning | slice 2 |
| "Five VM recovery ladders can interleave" | **Narrowed**: online there is **one** ladder — six rungs at PVM:1524-1553 are unreachable when V3 is active (always, online). Interleaving risk applies offline only | adversarial §4.1 |
| "Option C kills offline playback" | **Refuted on the server half**: `prepare_file.go:33-34` remuxes downloads to MP4; gated `download.transcode_enabled` (default false); the client *chooses* MKV by advertising containers. Caveat: TrueHD/DTS → AAC; existing device downloads need migration | adversarial T9 |
| "Loopback needed for DV P7 playback" | **Narrowed** to DV-as-DV: server strips RPU → HDR10 (`transcode.go:99`); no server P8.1 recipe | adversarial T10a |
| "TrueHD passthrough / Atmos" | **Refuted**: TrueHD → `.requireFLAC` (planner:667-680); Atmos preserved only for E-AC-3 JOC copy; docs/07 disclaims; validations dir empty | adversarial T10b |
| Option C removable surface 24–26k | **Narrowed to ~11.6k product + ~4k tests**: proxy/origin stream (4,335 lines) serve native-direct and survive | slice 6 vs slice 3 |
| "16,068 vs 16,194 loopback lines" | Disjoint measurements, both correct; use `AVPlayerRoute/` = 16,194 incl. shared backend | — |
| Offline mapping "hardcoded in OfflinePlayback.swift" | Corrected: derived by the shared planner (`nativeDirectContainers`) | — |
| Server route-event endpoint doc | Server schema says `/route-event`, router registers `/route-events`; Apple uses the correct plural | slice 4 |

Not verified in either direction (listed, not asserted): DV metadata survival through server HLS remux; real-library frequency of untrusted-keyframe copy sources and of h264-in-avi/webm; whether `session.audioTrackIndex` is an ordinal or stream index (decides `pendingAudioFfIndex` semantics).

---

## 13. Read-only statement

This review made **no changes**: no files were edited or created inside `silo-apple`, `silo-server`, or `silo-android`; no builds, tests, branch changes, commits, deployments, or device/simulator access. All work products live outside the repositories in the session scratchpad. All findings are static code analysis at the stated HEADs; none is a runtime reproduction.
