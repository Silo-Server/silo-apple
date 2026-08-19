<!-- Stage 2 inventory, generated 2026-08-19 by a read-only mapping agent at 20ba06b; line anchors are from that tip. -->

# STAGE-2 PRE-CUTOVER INVENTORY — silo-apple @ `20ba06b` (`player/architecture-remediation`)

Framing read: review §8 (Option D control plane), §9 Stage 0/Stage 2, §11 items 16–23; `docs/cleanup/player-review/slices/slice6-tests.md`; `docs/cleanup/HANDOFF.md` §2/§4.
Scale of the subject: `iosApp/iosApp/Screens/Player/PlayerViewModel.swift` 8007 LOC · `AVPlayerRoute/AVPlayerBackend.swift` 4884 · `PlaybackSessionBridge.swift` 1705.
Whole suite: 132 files / 1543 `func test` (baseline run 1539 executed, 3 skipped).

---

## PART A — TESTS

### A.0 The single most load-bearing fact

`grep` over all of `iosApp/Tests/` at `20ba06b`:

- `PlayerViewModel(` → **0 hits**
- `AVPlayerBackend(` → **0 hits**
- `PlaybackSessionBridge(` → **0 hits**
- `AVPlayer(` → **0 hits**

Slice 6's "orchestration gap" is unchanged after R1/R2. Every VM/backend/bridge reference in the suite is a **static or a nested type**. The R1 seam exists but is unused: `AVPlayerBackend.init(player: AVPlayer = AVPlayer())` at `AVPlayerRoute/AVPlayerBackend.swift:895`, constructed only by `PlayerViewModel.makeAVPlayerBackend()` (`PlayerViewModel.swift:1113-1114`, call site `:1125`) with no argument.

Complete list of VM/backend/bridge call sites in tests (9 symbols, ~15 call sites) — every one is MECHANICAL RETARGET, none REWRITE:

| symbol | called from |
|---|---|
| `PlayerViewModel.needsServerReplanBeforeLoad(plan:)` | `ApplePlaybackRoutePlannerPinTests.swift:668,681,695`; `ApplePlaybackDecisionTraceSnapshotTests.swift:543` |
| `PlayerViewModel.shouldTreatPlaybackErrorAsNaturalEnd(duration:currentTime:bufferedAheadSeconds:isSourceOutageActive:)` | `PlayerErrorClassifierPinTests.swift:73-85` |
| `PlayerViewModel.LoadRequest` + `.adoptingProtocolV3Intent` / `.copyForRecovery` | `PlaybackProtocolV3Tests.swift:667,709,1093`; `PlayerSettingsFlushTests.swift:1649-1670` |
| `PlayerViewModel.isCurrentStreamCallback` / `isUnexpectedBackwardPlaybackTime` / `shouldAdoptBackendDuration` / `protocolV3*` statics | `PlaybackProtocolV3Tests.swift:1044-1207` |
| `AVPlayerBackend.isReceiverFetchableAsset(url:headers:)` | `LoopbackStartupRecoveryPolicyTests.swift:103-135` |
| `AVPlayerBackend.vodRetentionBudget(availableBytes:)` | `PlaybackSourceCacheDiskSpillTests.swift:113` |
| `AVPlayerBackend.isLoopbackHost` | `PlaybackStatsComposer.swift:38` (prod, not test) |
| `PlaybackSessionBridge.{replanOperation, canRetargetDirectSession, isMaterialOutputRouteChange, replanFailure, initialProtocolV3SubtitleIntent, supportsNeutralProtocolV3, isMissingProtocolV3Capability, terminalStartRouteEvent, isPlaybackSessionMissing}` | `PlaybackSessionBridgeReplanContractTests.swift` (all 8 tests); `PlaybackProtocolV3Tests.swift:147-1023`; `PlaybackV3FixtureRoundTripTests.swift:87` |
| `PlaybackSessionBridge.selectVersion(from:lastFileId:preferredQuality:)` | `PlayerSettingsFlushTests.swift:1551,1559` |

Zero tests reference `ScenePhase`/`handleScenePhase`, `PictureInPictureCoordinator`, `NowPlayingController`/`MPRemoteCommandCenter`, AirPlay/`isExternalPlaybackActive`, `SleepTimer`, `PlayerTaskRegistry`, or `PlaybackRealtimeClient`. §11 item 23 (scene-phase tables) has **no** existing coverage to retarget.

### A.1 The 73 R1 characterization tests — exact identification

The "73" in `HANDOFF.md:49` / `app-cleanup-backlog.md:18` ("suite 1346→1419") is the **test-count delta of the whole R1 round**, not one commit. Verified by counting `+func test` per commit:

| commit | subject | +tests | files |
|---|---|---|---|
| `b214b69` | `test(player): land the stage-0 player characterization tests` | **59** | 8 new files (below) |
| `ca04fdd` | loopback writer/store VOD plan, init, memory, FFmpeg fixes | 4 | `LoopbackSegmentPlanTests`, `LoopbackSegmentStoreTests` |
| `845006a` | rewire backend callbacks on same-engine replan; near-end EOF | 2 | `PlaybackProtocolV3Tests` |
| `b56331d` | harden `AVPlayerBackend` recovery ladders | 3 | `LoopbackStartupRecoveryPolicyTests` |
| `09bf0a0` | advertise only executable containers on V3 original delivery | 1 | `AppleDecodeCapabilitiesTests` |
| `8c73c37` | stop sending an FFmpeg stream index as AI-translate source index | 4 | `SubtitleAIControllerTests` |
| | | **73** | |

The 8 files of `b214b69` (59 tests at landing → 55 today):

| file | then | now | drift |
|---|---|---|---|
| `ApplePlaybackDecisionTraceSnapshotTests.swift` | 5 | 5 | trimmed by `91ebf35` (bridge delete) |
| `LoopbackSegmentPlanTrustTests.swift` | 5 | **0 — file deleted** | `91ebf35` |
| `LoopbackSessionSpecCopyHelperTests.swift` | 7 | 4 | `91ebf35` dropped bridged-param-set cases |
| `OfflinePlaybackMappingMatrixTests.swift` | 7 | 7 | — |
| `PlaybackSessionBridgeReplanContractTests.swift` | 8 | 8 | `fe69a5c` added `output_change` |
| `PlaybackV3ExecutionPlanMatrixTests.swift` | 13 | 13 | — |
| `PlaybackV3FixtureRoundTripTests.swift` | 8 | 10 | +2 from `fe69a5c` |
| `PlayerErrorClassificationMatrixTests.swift` | 6 | 8 | R2 rewrite, below |

Self-declared marker: every one of these files opens `/// Stage-0 characterization: …` (e.g. `PlaybackV3ExecutionPlanMatrixTests.swift:5`, `OfflinePlaybackMappingMatrixTests.swift:5`, `PlaybackSessionBridgeReplanContractTests.swift:5`, `PlaybackV3FixtureRoundTripTests.swift:5`, `LoopbackSessionSpecCopyHelperTests.swift:5`, `ApplePlaybackDecisionTraceSnapshotTests.swift:5`).

### A.2 The R2 oracle tests

`0210df1 fix(player): give the backend a typed failure channel` — the only "oracle"-shaped tests in the repo. `PlayerErrorClassificationMatrixTests.swift` holds four **verbatim copies of the retired `PlayerViewModel` string ladders** as private oracles:

- `oracleClassification(_:)` :25 · `oracleStableToken(_:)` :42 · `oracleIsSessionMissing(_:)` :56 · `oracleIsPrematureSourceEnd(_:)` :62
- Header :16 "…oracles, against every typed case's `legacyMessage` and asserts the new"; :23 `// MARK: - Oracles (the pre-migration PlayerViewModel implementations)`
- Three tests added by `0210df1`: `testTypedFailuresAgreeWithTheRetiredViewModelClassifiers` (asserts at :183/:188/:193/:201/:205), `testLegacyMessagesAreReproducedByteForByte`, `testPrematureSourceEndIsDecidedByTheTypedCaseNotTheSpelling`.
- Same commit rewrote `PlayerErrorClassifierPinTests.swift` (+87/−57) onto `PlaybackFailure`.

These are the template for §11 item 19 (`PlaybackFailure → RecoveryAction` table): a frozen legacy implementation kept in-test as the differential oracle.

### A.3 The two named PinTests (pre-R1, `ad052c3`) — review §11 says *rewrite*

**`ApplePlaybackRoutePlannerPinTests.swift`** — 25 tests, 983 LOC. Self-described characterization (`:4-14`). Constructs via `makeSession`/`makeVersion`/`makeAudioTrack`/`makeVideoTrack`/`makeSubtitleTrack` + `plan(version:session:requirements:dolbyVisionPolicy:selectedPrimarySubtitleTrackId:)` `:136-155` → the shared `makeTestExecutionPlan` (`PlaybackV3FixtureTestSupport.swift:34-57`, landed by round-6 tail `6d35b4d`). Direct statics: `ApplePlaybackRoutePlanner.normalizedVideoCodec` :725, `.normalizedAudioCodec` :765, `.loopbackAudioOutputMode` :796, `.loopbackAudioPreservesAtmos` :848, `.makeLoopbackSessionSpec` :880/:918, `.makeRouteRequirements` :949.
PIN comments: `:13` "PIN: current behavior; likely bug, see cleanup notes"; `:376` DV in a native-direct container still takes loopback (review §11 hardware row 2); `:582` only mandatory/selected embedded subs gate the route; `:712` `av01` not folded to `av1` (likely bug); `:753` Matroska `A_EAC3`/`A_AC3`/`A_TRUEHD` not folded (likely bug); `:836` lossless FLAC/PCM "transcoded"; `:902` `FileVersion.bitrate` ×1000 as if kbps (likely bug).
**Verdict:** 23/25 SURVIVE UNCHANGED (the planner is *not* in the extraction's blast radius). Only `testTheoraOGVFallsToServerHLSWhileDeliveryStaysDirect` :653 and `testNeedsServerReplanBeforeLoadOnlyFiresForDirectDeliveryOnTheHLSRoute` :673 retarget. **The review's "rewrite the two PinTests" is now over-broad** — the classifier half was already superseded by R2; the planner half is untouched by Stage 2 and only carries the six pinned-bug rows.

**`PlayerErrorClassifierPinTests.swift`** — 9 tests, 229 LOC. Already migrated onto `PlaybackFailure` statics by `0210df1`. PINs at :47, :103, :125, :203, :216. Only the two `PlayerViewModel.shouldTreatPlaybackErrorAsNaturalEnd` tests retarget (→ §11 item 19 / P10).

### A.4 Per-file inventory — SURVIVES UNCHANGED (pure policy/adapter/data-plane)

Format: file — tests/LOC — pins — subject construction.

**Planner / plan / V3 wire**
- `PlaybackV3FixtureTestSupport.swift` — 0/57 — HELPER. `PlaybackV3FixtureTestSupport.{decoder, fixtureURL(named:bundleClass:), decode}` :5-29 + free `makeTestExecutionPlan(...)` :34-57 → `ApplePlaybackRoutePlanner().makeExecutionPlan(input: ApplePlaybackPlannerInput(...))`. Depended on by 8 files.
- `PlaybackV3ExecutionPlanMatrixTests.swift` — 13/386 — WIRE CONTRACT + trace-order mechanism. Mutates `Fixtures/PlaybackV3/decision_response.json` as a dict, re-decodes into `PlaybackV3Plan` (`plan(mutating:…)` :26-54), wraps in `PreparedPlaybackV3` :56, literal `PlaybackExecutionPlan` :91-113 and `LoopbackSessionSpec` :70-86; subject `ApplePlaybackV3PlanAdapter.makeExecutionPlan(v3:basePlan:streamRequest:routeRequirements:)` via `execute(_:base:)` :123-133.
- `PlaybackV3FixtureRoundTripTests.swift` — 10/281 — WIRE CONTRACT. `Self.allFixtures` :16-26, generic `roundTrip(_:named:)` :52-65 over `PlaybackV3{DecisionResponse,CapabilityResponse,StartRequest,ReplanRequest,RouteEvent}`. PINs :118-122 (`local_mutations` omitempty asymmetry), :196-201 (vendored `route_event.json` not decodable — `applied_quirk_ids`).
- `PlaybackProtocolV3ConformanceFixtureTests.swift` — 5/369 — WIRE CONTRACT only. Decodes `conformance_matrix.json` / `error_response.json` into 15 file-private mirror structs :207-369; hard-coded counts :24-26 (17 planner / 10 replan / 8 protocol scenarios).
- `ApplePlaybackAudioSelectionRouteTests.swift` — 5/118 — PRODUCT RULE + wire (`client_audio_track_selection_v1`). `plan(version:session:)` :66; `ApplePlaybackV3Capabilities.snapshot()` :110-117. (Added by `22259bc`, silo-server #670.)
- `AppleDecodeCapabilitiesTests.swift` — 10/150 — WIRE CONTRACT. `ApplePlaybackV3Capabilities.snapshot()`, `DownloadCaps.current()`, `AppleDecodeCapabilities.*`, `ApplePlaybackRoutePlanner.{nativeDirectContainers, siloSourceContainers, siloContainerIsNormalizable}` :64-88. `testSimulatorClaimStaysConservative` :143 is `XCTSkipUnless`.
- `HDRDisplayCriteriaPolicyTests.swift` — 17/343 — PRODUCT RULE + one constant-pin block :268-274. Per-test `UserDefaults(suiteName:)` :9-21; `HDRDisplayCriteriaPolicy.*`, `ApplePlaybackRoutePlanner.dvProfile8BaseLayer` :92 / `.hevcLoopbackVideoRange` :228, `VideoColorMetadata.dolbyVisionBaseLayerColorimetry` :113.
- `DolbyVisionPolicyTests.swift` — 6/86 — PRODUCT RULE. Four `DolbyVisionPolicy.Snapshot(...)` :5-20 → `.resolution(forProfile:snapshot:)`, `.claimsDolbyVisionOutput(_:)`. **This is the cleanest existing model of a policy-table test** (the shape §11 items 19/23 want).
- `OfflinePlaybackMappingTests.swift` 13/278 and `OfflinePlaybackMappingMatrixTests.swift` 7/222 — PRODUCT RULE. Inline `OfflineManifest` JSON → `OfflinePlaybackBuilder.makePreparedPlayback(...)` → `makeTestExecutionPlan`.
- `PlaybackMediaFixtureTests.swift` — 5/286 — environment sanity. Real libavformat/libavcodec decode of 9 bundled media fixtures (`decodesFrame(from:mediaType:)` :230-285); `AVURLAsset` :67 but no `AVPlayer`.
- `DetailVersionSelectionTests.swift` — 25/725 — Detail-screen file; only playback touches are `ApplePlaybackRoutePlanner.unambiguousColorRange` :84/:101 and `PlaybackDeliveryStrategy.preservesSourceVideoMetadata` :105-107.
- `LoopbackSessionSpecCopyHelperTests.swift` — 4/167 — structural invariant. `makeSpec()` :41-69, `assertCarriesEverything` :72-115, **Mirror-based completeness guard `testAssertionsCoverEveryStoredProperty` :122-135** pinning the exact 9-property set — will fail loudly if Stage 2 adds a field to `LoopbackSessionSpec`.

**Recovery / data plane / policy**
- `LoopbackStartupRecoveryPolicyTests.swift` — 25/501 — PRODUCT RULE (transport-intent reconciliation, item-death confirmation, startup ladder) + rebuild-budget constants. `AVPlayerSystemTransportIntent.Context` via `transportContext` :6-26 → `.resolve`; `LoopbackItemDeathRecoveryState.isItemDeath`; `LoopbackStartupRecoveryPolicy.verdict(...) -> .Verdict`. **This is already the closest thing in the tree to a `RecoveryPolicy` table test** and is the natural donor for §11 item 19.
- `LoopbackRestartCoalescerTests.swift` — 8/80 — value-type `LoopbackRestartCoalescer()`, `begin(_:authoritative:)`/`next(justRan:)`/`isInFlight`.
- `LoopbackIngestEndPolicyTests.swift` — 14/189 — `LoopbackIngestEndPolicy.classify(...)` via `classify` :8-24.
- `PlaybackOriginOutageTests.swift` — 10/209, three classes — `PlaybackOriginOutagePolicy.shouldPark(cause:sessionMissingObserved:rideThroughEnabled:)` :4; **real sockets** at :45 (`RangeOriginStub` + real `PlaybackSourceProxy(originURL:originHeaders:onOriginOutageChanged:outageRideThroughEnabled:)` :103, in-file `CountingReader: URLSessionDataDelegate` :47, mutates static `PlaybackOriginOutagePolicy.probeDelaySeconds` :97-99); `LoopbackInterruptTokenDeadlineTests` :151.
- `PlaybackOriginStreamResumeTests.swift` — 33/2367 — the largest data-plane net. `PlaybackOriginStream(originURL:…:clock:)` via `makeStream` :961 against a full double set (below).
- `PlaybackOriginStreamPolicyTests.swift` — 30/507, six classes :5/:125/:280/:357/:397/:457 — pure routing/claim/detach/reconnect statics + one real `PlaybackSourceCache`. Constant pin `testRoutingConstantsArePinned` :100 (4/8/8 MiB).
- `PlaybackSourceProxyRetargetTests.swift` — 2/100 — `proxy.retargetOrigin(url:headers:)` — the data-plane half of silent source renewal.
- `PlaybackSourceCacheDiskSpillTests.swift` — 6/117; `SourceCacheAdoptionPolicyTests.swift` — 7/61 (`SourceCacheAdoptionPolicy.shouldAdopt(...)` — cache handoff across a replan, control-plane-adjacent); `PlaybackSourcePrefetchPolicyTests.swift` — 2/20.
- `PlaybackRunwayPolicyTests.swift` — 4/68 — `PlaybackRunwayPolicy.runwaySeconds(playableAheadSeconds:generatedVisibleAheadSeconds:)`; header :4-7 notes nilness encodes the route. Direct input to any reducer stall watchdog.
- `PlaybackStatsComposerTests.swift` — 12/247 — `PlaybackStatsComposer.compose(Inputs(backend:proxy:engine:nominalFileBitrateBps:))` with hand-built `PlaybackSourceProxyStats` :14 / `PlaybackStats()` :35. Already fully injected.

**Track selection / subtitles (the `TrackSelectionCoordinator` safety net)**
- `TrackSelectionPersistenceTests.swift` — 9/207 — WIRE CONTRACT. `TrackSelectionPersistence.{prefKey, audioRequest(version:ordinal:), audioRequest(track:ordinal:), subtitleRequest(version:ffIndex:showForced:), subtitleRequest(track:showForced:)}`; `FileVersion` from inline JSON via `decodedVersion` :172; `PlayerTrack` via `playerTrack` :178.
- `SubtitleAutoResolverTests.swift` — 18/303 — `SubtitleAutoResolver.resolve(Inputs(...))` via `inputs` :42 + statics `titleIndicatesHearingImpaired` :138, `languagesMatch` :209. The auto-selection ladder §8 wants folded into `TrackSelection.origin == .autoPolicy`.
- `SubtitleDisplayOrderTests.swift` — 10/149 — `SubtitleDisplayOrder.order(_:preferredLanguage:)` with a `Descriptor` projection :26; `formatRank` total order pinned :127.
- `LiveSubtitleCoordinatorTests.swift` — 19/400, `@MainActor` — **the one well-seamed orchestrator in the tree.** Real `LiveSubtitleCoordinator(controls:sink:clock:selectionSnapshot:)` over `FakeControls: LivePlaybackControls` :31, `FakeSink: LiveSubtitleSink` :43, `ManualClock: LiveSubtitleClock` :81 + `Handle: LiveSubtitleCancellable` :82. Header :7 "No libass, no websocket, no player". `LivePlaybackControls` is a seam Stage 2 must keep supplying.
- `SubtitleAIControllerTests.swift` — 12/553, `@MainActor` — real `SubtitleAIController(mediaFileId:currentTime:sessionId:realtimeUnavailable:liveCoordinator:handoffContext:registerAndSelectDescriptor:registerDescriptorWithoutSelecting:downloadedSubtitlesFetch:)` :112 — **every player dependency is already a closure**. The four wires Stage 2 must re-provide: `currentTime`, `sessionId`, `registerAndSelectDescriptor`, `registerDescriptorWithoutSelecting`.
- `CreditsAutoSkipPolicyTests.swift` 5/82; `PlayerNextUpCompletionPolicyTests.swift` 4/52; `StartupPrefetchFailureReasonTests.swift` 7/171.

**Settings / control / diagnostics**
- `PlayerSettingsFlushTests.swift` — 76/2007, `@MainActor` — the biggest single file. Sections at :19 debounce, :181 durability, :527 mutation ids, :571 retry, :723 deletes, :774 `PlayerSettings` integration, :1082 typed defaults, :1349 playback speed, :1377 quality axes. `PlayerSettingsFlusher(transport:debounce:)` over `FakeSettingsTransport` :1705 + `InMemoryWriteJournal` :1924 + `PlayerSettingsHarness` :1983 (real `PlayerSettings(defaults:flusher:)` on a UUID `UserDefaults` suite). Uses `waitUntil` from `TestPolling.swift`.
- `SiloControlTests.swift` — 9/138 — WIRE CONTRACT (message/command/handoff JSON round trip, `SiloControlProtocol.negotiatedVersion`) + `RemotePlaybackClock()` with injected `asOf:`. **Stale header at :4-6** claims "no unit-test target wired into project.yml yet" — false since the `SiloTests` glob; verify before counting it as a net.
- `HostedDiagnosticsAPITests.swift` — 53/3193, one playback test: `testHostedFrozenLogsAndBreadcrumbsDropPrivatePlaybackAttributes` :505. It consumes **emitted log text**, with the literal breadcrumb tags `"CMP playback_session_id=…"` and `"PlaybackSessionBridge session_id=…"` hardcoded at :532. That string coupling breaks (or needs updating) if the cutover renames the bridge in its log tags.

### A.5 REWRITE candidates (pin the legacy mechanism; → §11 items 16–23)

All six live in one block of `PlaybackProtocolV3Tests.swift` (lines 1043-1215) — they pin exactly the machinery §8 deletes:

| test | line | pins | §11 target |
|---|---|---|---|
| `testStaleStreamGenerationCannotConsumePendingTrackIntent` | :1118 | `PlayerViewModel.isCurrentStreamCallback` — by-value generation capture | 16/17 (`LoadID` stamping) |
| `testReplacementLoaderCannotMovePlaybackBackwardsWithoutASeek` | :1127 | `isUnexpectedBackwardPlaybackTime` | 17 |
| `testGrowingTranscodePlaylistCannotReplaceKnownVODDuration` | :1151 | `shouldAdoptBackendDuration` | 20 |
| `testV3AudioIntentOverridesBackendDefaultAfterReplan` | :1083 | `protocolV3PendingTrackIntent` (one of the eight `pending*` fields) | 21 |
| `testV3ReplanRestoresServerRenderedSubtitleAsDisplayOnlySelection` | :1047 | `ProtocolV3SidecarRestoreIntent` (explicitly listed as a Stage-2 deletion) | 21 |
| `testV3RouteSubtitleFilteringRetainsOnlySelectedEmbeddedSidecar` | :1182 | `protocolV3SubtitleUrlsForCurrentRoute` | 21 |

The remaining ~33 of `PlaybackProtocolV3Tests`' 39 split ~28 SURVIVE / ~5 MECHANICAL RETARGET.

### A.6 Aggregate

Player-adjacent test surface: **75 files / 845 tests / 21,681 LOC** (vs slice 6's 60 files / 18,225 LOC at `36393b4`).
Of everything reviewed: **~6 REWRITE**, **~15 MECHANICAL RETARGET**, the rest survives unchanged. There is **no** existing composed-lifecycle test to break — and equally, **no** safety net for the parts of Stage 2 that matter most (effect ordering, recovery ladders end-to-end, scene phase, PiP/AirPlay/NowPlaying, task lifetime).

### A.7 Test doubles / support files in `iosApp/Tests/`

Shared, no `XCTestCase`:
- `RangeOriginStub.swift:28` `final class RangeOriginStub` — NWListener HTTP/1.1 range origin on 127.0.0.1; knobs `responseDelay`, `stallAfterByte`, `goDown()`/`goUp()`, `bodyChunkBytes`, `observedOffsets()`. Seam: real socket under `PlaybackSourceProxy`/`PlaybackOriginStream`.
- `TestHTTPStubSupport.swift:3` `URLRequest.drainedHTTPBody`; `:27` `URLProtocol.respond(status:body:contentType:headers:)`.
- `TestPolling.swift:6` `waitUntil(_:timeout:_:file:line:)`; `:24` async `waitUntil(timeout:_:) -> Bool`.
- `InMemoryKeychainBackend.swift:23` `InMemoryKeychainBackend: KeychainBackend` (the round-7 env-baseline seam).
- `PlaybackV3FixtureTestSupport.swift:5` `enum PlaybackV3FixtureTestSupport` + `makeTestExecutionPlan` :34.
- `SettingsContractResolve.swift:51-250` — 11 mirror types + a fourth cross-platform settings resolver living in the test target.
- `ISOBoxTestTree.swift:4` `enum ISOBoxTestTree` — synthetic MP4 box trees.
- `Fixtures/`: `PlaybackV3/*.json` (9), `SettingsContract/`, `DiagnosticsContract/`, plus real media (`v3_h264_aac.{mp4,mkv,mov,ts,m2ts,m4v,m3u8}`, `v3_vp9_opus.webm`, `v3_mpeg4_mp3.avi`, `v3_hls_0{0,1}.ts`, `loopback_continuity_h264_eac3.mp4`, `delayed_truehd_probe.mkv`).

Declared in-file (player-relevant):
- `PlayerSettingsFlushTests.swift:1705` `FakeSettingsTransport: PlayerSettingsTransport`; `:1924` `InMemoryWriteJournal: PlayerSettingsWriteJournal`; `:1957` `LockedScopeValue`; `:1983` `PlayerSettingsHarness`.
- `LiveSubtitleCoordinatorTests.swift:31/43/81/82` `FakeControls: LivePlaybackControls`, `FakeSink: LiveSubtitleSink`, `ManualClock: LiveSubtitleClock`, `Handle: LiveSubtitleCancellable`.
- `SubtitleAIControllerTests.swift:28/35/58/148` same trio (counting variant) + `HandoffCounters`.
- `PlaybackOriginStreamResumeTests.swift:6` `ManualClock: PlaybackOriginStreamClock`; `:49 Recorder`, `:93 ProxyRecorder`, `:123 PendingReader`, `:142 ExactReader`, `:178 StartCompletion`, `:191 EntityValidator`, `:209 ChunkRecorder`, `:323 ChunkCallbackRaceRecorder`, `:350 StubOrigin` (~15 `ReopenBehavior` cases).
- `PlaybackOriginOutageTests.swift:47` and `PlaybackSourceProxyRetargetTests.swift:13` `CountingReader: NSObject, URLSessionDataDelegate`.
- `HostedDiagnosticsAPITests.swift:2834/2864/3128` credential store + two `URLProtocol` stubs.

**There is no fake `PlaybackBackend`, no fake session bridge, no `AVPlayer` double anywhere.** Stage 2 has to author them.

---

## PART B — VIEW SURFACE (what a thin `PlayerPresentationModel` must keep)

### B.1 Ownership and lifecycle

Two `PlayerView`s, two `@State` owners, no other creator anywhere in the app:
- `iosApp/iosApp/Screens/Player/PlayerView.swift:29` `@State private var viewModel = PlayerViewModel()` — **shared iOS + tvOS** (`#if os(tvOS)` branches at :98-226, :228-239, :255-293, :302-310, :337-342, :344-353, :355-379, :393-453; iOS at :33-35, :324-326, :363-365, :481-503).
- `iosApp/iosApp/macOS/PlayerView.swift:19` `@State private var viewModel = PlayerViewModel()`.

`PlayerView.swift` lifecycle, in order:
- `.onChange(of: scenePhase)` :294-296 → `viewModel.handleScenePhase(newPhase)` (macOS twin at `macOS/PlayerView.swift:96-98`).
- `.onChange(of: viewModel.isPlaying)` :298 → fires `onPlaybackStarted?()` once (`didNotifyPlaybackStarted` latch).
- tvOS `.onChange(of: viewModel.showControls)` :303-309.
- `.onChange(of: viewModel.remoteDismissToken)` :311-314 → `dismissPlayer()`.
- `.onAppear` :315-343: **VM replacement dance** — `if viewModel.needsReplacementForPresentation { let replacement = PlayerViewModel(); viewModel = replacement }` :316-323 (`needsReplacementForPresentation` = `isDisposed`, `PlayerViewModel.swift:428`); then iOS `orientationCoordinator.activatePlayer()` :325; then `activeViewModel.applyArtworkURLHints(posterURL:backdropURL:)` :327; then `activeViewModel.loadAndPlay(contentId:preferredFileId:preferredAudioTrackIndex:preferredSubtitleTrackIndex:startFromBeginning:resumePositionOverride:offlineDownloadId:)` :328-336; then tvOS `TVControlReceiver.shared.registerPlayer(activeViewModel, contentId:)` :338 + `RemotePlaybackIdentityManager.shared.activeIdentity` :339-341.
- `.onDisappear` :354-381: `viewModel.cleanup()` :359 → tvOS `TVControlReceiver.shared.unregisterPlayer(viewModel)` :361 → iOS `orientationCoordinator.deactivatePlayer()` :364 → tvOS drains `viewModel.contentIdsNeedingDetailRefresh` :371 into `ItemDetailCache.shared.markStaleFamily`.
- `dismissPlayer()` :387-390 = `viewModel.cleanup(); dismiss()`.
- macOS `.onAppear` `macOS/PlayerView.swift:108-118` `viewModel.loadAndPlay(...)`; `.onDisappear` :119-121 `viewModel.cleanup()`.

Video surface: `playerSurface(ignoresSafeArea:)` :462-479 reads `viewModel.avPlayerBackend` :464 and `viewModel.settings.videoGravity.avGravity` :467 → `AVPlayerSurface(backend:videoGravity:)`. macOS twin `macOS/PlayerView.swift:137`.

tvOS remote at shell level: `.onPlayPauseCommand` :257-263; `.onExitCommand` ladder :270-291 (`showNextUpScreen` → `keepWatchingCurrentEpisode()` → `isHoldSeeking`/`cancelHoldSeek` → `isBackgroundSuspended` → `isLoading` → `isHUDPresented`/`closeHUD` → `!isPlaying` → `showControls`/`dismissControls` → dismiss).

Non-view VM holder: `Control/tvOS/TVControlReceiver.swift:42` `private weak var playerViewModel: PlayerViewModel?`, set in `registerPlayer(_:contentId:)` :198-209 and cleared in `unregisterPlayer(_:)` :211-227 (which awaits `viewModel?.waitForCleanupCompletion()` :225).

### B.2 The referenced surface — **130 distinct members** across 17 files

Platform key: **A** = all three, **iT** = iOS+tvOS (shared `PlayerView`), **i** = iOS only, **t** = tvOS only, **m** = macOS only.

*Transport / state (read)* — `isPlaying`:185 A · `currentTime`:186 t,m · `duration`:187 A · `title`:188 A · `isLoading`:189 A · `isBuffering`:190 A · `error`:191 A · `showControls`:192 A · `activeNotice`:193 iT,m · `remoteDismissToken`:194 A · `metadata`:279 A (`.primaryTitle`, `.seriesTitle`, `.episodeTag`, `.badges`, `.overview`, `.year`) · `progressFraction`:244 iT,m · `bufferedFraction`:233 iT,m · `playbackRunwaySeconds`:230 i · `playbackStats`:253 i,t,m (`.hasRows`, `.bufferRows`, `.networkRows`, `.deviceRows`) · `playbackRouteDisplay`:355 t · `routeStatusRows`:361 i,m · `routeWarnings`:396 i · `routeDecisionSummary`:392 i · `backendCapabilities`:338 i,t (`.supportsSubtitleDelay`, `.supportsSubtitleStyling`, `.supportsVideoGravity`) · `avPlayerBackend`:326 iT,m · `settings`:451 A · `sleepTimer`:452 i,t · `subtitleAI`:493 i.

*Transport (write)* — `togglePlayPause`:4568 A · `skipForward(_:revealingControls:)`:4844 A · `skipBackward(_:revealingControls:)`:4856 A · `seekTo(seconds:)`:5313 i,t,m · `seekToAdjacentChapter(forward:)`:6213 m · `pauseForTimelineSelection`:4591 t · `retry`:4557 iT,m · `loadAndPlay`:4529 A · `cleanup`:6303 A · `applyArtworkURLHints`:3321 iT · `handleScenePhase`:4711 A · `waitForCleanupCompletion` t · `applyUserVolume`:1175 i · `currentUserVolume`:1171 i.

*Scrub / hold-seek* — `isScrubbing`:212 i,t,m · `scrubPreviewTime`:213 iT,m · `scrubDisplayTime`:239 i,t · `beginScrub(fraction:)`:5476 i,t,m · `updateScrub(fraction:)`:5487 i,t,m · `endScrub(resumePlayback:shouldSeek:)`:5494 i,t,m · `cancelScrub`:5528 t · `holdSeekRate`:302 t · `isHoldSeeking`:304 t · `beginHoldSeek(forward:)`:4896 t · `adjustHoldSeekRate(delta:)`:4934 t · `commitHoldSeek`:4946 t · `cancelHoldSeek`:4958 t · `beginHoldFastForward(rate:)`:3237 i · `endHoldFastForward`:3246 i · `isHoldFastForwarding`:217 i.

*Controls visibility / HUD* — `revealControls`:6238 A · `dismissControls`:6250 iT · `toggleControls`:6227 i · `pinControlsVisible`:6262 i,t · `resumeAutoHide`:6268 i · `openHUD`:6274 t · `openSettingsHUD`:6284 t · `closeHUD`:6296 t · `isHUDPresented`:285 t · `consumeTVHUDEntryRequest`:6289 t · `requestedTVHUDEntryPoint`:311 t.

*Tracks / subtitles* — `audioTracks`:195 i,t,m · `subtitleTracks`:196 i,t,m · `orderedSubtitleTracks`:405 i,t,m · `availableSecondarySubtitleTracks`:408 i,t · `selectedAudioId`:205 i,t,m · `selectedSubtitleId`:206 i,t,m · `selectedSecondarySubtitleId`:207 i,t · `supportsSecondarySubtitles`:400 i,t · `selectAudio(_:)`:5541 i,t,m · `selectSubtitle(_:)`:5567 i,t,m · `disableSubtitles`:5600 i,t,m · `selectSecondarySubtitle(_:)`:5688 i,t · `disableSecondarySubtitles`:5699 i,t · `cycleAudioTrack`:6170 m · `cycleSubtitleTrack`:6182 m · `toggleSubtitles`:6204 m · `hasTrackSelectionOptions`:399 m.

*Subtitle search / AI* — `subtitleSearchEnabled`:5757 i,t · `subtitleSearchUnavailableReason`:5766 i,t · `subtitleSearchVisible`:5738 i,t · `searchSubtitles(languages:)`:5775 i · `downloadSearchedSubtitle(_:)`:5798 i · `startSubtitleTranslation(track:to:)`:5714 i · `startSubtitleTranscription(audioIndex:translateTo:)`:5722 i.

*Subtitle appearance* — `setSubtitleAppearance(_:) async`:3178 i · `mutateSubtitleAppearance(_:)`:3184 t (landed by round-6 tail `5a0cefa`) · `setSubtitleDeviceOverrideEnabled(_:) async`:3204 i,t · `setSubtitleMatchesSystemAppearance(_:)`:3210 i,t · `setSubtitleSyncMilliseconds(_:)`:3259 i,t.

*Quality / output* — `qualityOptions`:208 i,t · `activeQualityId`:209 i,t · `isQualitySwitching`:210 i,t · `qualitySwitchError`:211 i,t · `switchQuality(_:)`:4600 i,t · `setPlaybackSpeed(_:)`:3224 i,t,m · `setVideoGravity(_:)`:3255 i,t · `supportsExternalPlayback`:445 i.

*Chapters / intro / credits* — `chapters`:201 i,t,m · `currentChapterIndex`:250 i,t,m · `introRange`:202 i,t · `showIntroSkip`:287 iT · `skipIntro`:4868 i,t · `cancelIntroAutoSkip`:4877 i,t · `introAutoSkipCountdownSeconds`:204 i,t.

*Next-Up / on-deck* — `showNextUpScreen`:254 iT · `canShowNextUpScreen`:992 t · `showNextUpNow`:1975 t · `nextUpEpisode`:255 iT · `nextUpCarouselItems`:987 iT · `nextUpCountdownSeconds`:266 iT · `nextUpCountdownTotalSeconds`:267 iT · `nextUpScreenVideoEnded`:268 iT · `nextUpStartError`:265 iT · `nextUpLookupError`:259 iT · `isLoadingNextUpEpisode`:257 iT · `playNextEpisodeNow`:2130 iT · `playOnDeckItemNow(_:)`:2148 iT · `keepWatchingCurrentEpisode() -> Bool`:2087 t · `setNextUpAutoPlayEnabled(_:)`:2120 iT.

*Lifecycle / suspend* — `isBackgroundSuspended`:983 t · `suspendedNotice`:984 iT,m · `needsReplacementForPresentation`:428 iT · `contentIdsNeedingDetailRefresh`:977 t.

*Remote control (tvOS receiver)* — `applySiloControlCommand(_:) throws`:7694 · `makeSiloControlPlaybackState(contentId:)`:7794.

*Second-level `settings` surface actually referenced by views* (`PlayerSettings.shared`, `PlayerViewModel.swift:451`): `subtitleAppearance` (44 refs), `subtitleSyncMs` (9), `playbackSpeed` (8), `videoGravity` (6), `autoPlayNextEpisode` (4), `subtitleMatchesSystemAppearance` (4), `subtitleUsesDeviceAppearanceOverride` (2), `setAutoPlayNextEpisode` (2), `effectiveSubtitleAppearance` (1). `sleepTimer`: `isActive`, `remainingSeconds` (+ `cancel()`/`start(minutes:)` via the passed-down `SleepTimer` in `Sheets/PlayerSettingsSheet.swift:15,320-322,399-404`).

Per-file consumer counts: `PlayerView.swift` 46 · `iOS/MobilePlayerControls.swift` 55 · `tvOS/TVPlayerInfoHUD.swift` 41 (7 sub-views each taking `let viewModel:` at :19/:227/:353/:408/:582/:628/:996) · `tvOS/TVPlayerControls.swift` 26 · `tvOS/TVPlayerScrubber.swift` 17 · `macOS/PlayerView.swift` 23 · `macOS/MacPlayerOptionsPanel.swift` 17 · `Sheets/PlayerSettingsSheet.swift` 14 · `iOS/MobilePlayerGestureLayer.swift` 13 · `macOS/MacPlayerTimeline.swift` 10 · `macOS/MacPlayerControls.swift` 9 · `tvOS/TVPlayerTransportCluster.swift` 6 · `Sheets/SubtitleTranslateMenu.swift` 5 (+2 statics taking a VM at :88/:96) · `Sheets/SubtitleSearchMenu.swift` 4 · `tvOS/SubtitleAppearanceDialog.swift` 3 · `Control/tvOS/TVControlReceiver.swift` 3.

Files that touch player state but hold **no** VM: `iOS/PictureInPictureCoordinator.swift` (reached via `.shared`), `AVPlayerRoute/AVPlayerSurface.swift` + `macOS/AVPlayerSurface.swift` (take `AVPlayerBackend` directly), `iOS/AirPlayRoutePicker.swift`, `iOS/MobilePlaybackStatsOverlay.swift`, `PlaybackStatsPanel.swift`, `PlayerBufferingCapsule.swift`, `PlayerNoticeOverlay.swift`, `tvOS/HoldSeekIndicator.swift`, `tvOS/TVPressCaptureView.swift`, `tvOS/HUDKit/*`.

---

## PART C — PLATFORM HOOKS

### C.1 `AVAudioSession` (iOS/tvOS only; macOS compiles it out)
- `AVPlayerRoute/AVPlayerBackend.swift:323-345` `final class AVPlayerAudioSessionCoordinator: @unchecked Sendable` — serializes blocking category/activation off the main thread, with generation tracking; `:340-344` one **process-wide `sharedWorkQueue`** (`org.siloserver.silo.avplayer-audio-session`) so a stale teardown deactivation can't land after the next activation.
- `AVPlayerBackend.swift:857-882` the instance: activation sets `.playback`/`.moviePlayback` + `setSupportsMultichannelContent(true)` + `setActive(true)`; deactivation `setActive(false, options: [.notifyOthersOnDeactivation])`; macOS branch is `{}` / `{}`.
- `PlayerViewModel.swift:1077-1105` `outputRouteObserverToken = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, …, queue: .main)` — guards on `activePreparedProtocolV3`, `!isDisposed`, `!isLoading`; takes `ApplePlaybackV3Capabilities.snapshot()`, gates on `PlaybackSessionBridge.isMaterialOutputRouteChange(activeOutputContextId:observedOutputContextId:)`, then `attemptProtocolV3Replan(position:classification:"output_route_changed",message:)`. `:1007` comment marks the macOS divergence. Bridge-side note at `PlaybackSessionBridge.swift:893`.
- `ProtocolV3/ApplePlaybackV3Capabilities.swift:427` reads `AVAudioSession.sharedInstance().currentRoute.outputs` to build the output context id — i.e. the wire snapshot is a live AVFoundation read.
- `Shared/Diagnostics/DiagnosticsCapabilityProbe.swift:49` same read for diagnostics.

### C.2 `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`
- `Screens/Player/NowPlayingController.swift` — `final class NowPlayingController` :19; `MPRemoteCommandCenter.shared()` at :115 (attach), :232, :323 (detach); `MPNowPlayingInfoCenter.default().nowPlayingInfo` at :102 (clear), :137-152 (push), :214-221 (artwork).
- **Three independent owners**, each with its own instance: `PlayerViewModel.swift:453` `private let nowPlaying = NowPlayingController()`, `Screens/Audio/AudioPlayerViewModel.swift:15`, `Control/iOS/SiloControlClient.swift:58`.
- VM wiring `PlayerViewModel.swift:3457-3466`: `nowPlaying.attach(handlers: NowPlayingController.Handlers(play: { avPlayerBackend?.play() }, pause: { avPlayerBackend?.pause() }, isPaused: { hasReachedEndOfFile || avPlayerBackend?.isPaused() ?? true }, currentTime: { currentTime }, seek: { avPlayerBackend?.seek(to:) }))` — five closures straight onto the backend, no identity/`LoadID` guard.
- Artwork push referenced from `Screens/Detail/ItemDetailView.swift:877` (comment only).

### C.3 Picture-in-Picture (iOS)
- `iOS/PictureInPictureCoordinator.swift` — singleton `.shared` :18; `isPossible` :27, `isActive` :29, `isTransitioning` :33, `isEngaged` :37, `isSupported` :39; `attach(playerLayer:)` :58 (creates `AVPictureInPictureController(playerLayer:)` :66, KVO on `\.isPictureInPicturePossible` :79), `detach(playerLayer:)` :103, `endSession(owner:)` :121, `bindLifecycle(owner:onEngagementEnded:)` :133, `toggle()` :138; `DelegateProxy: NSObject, AVPictureInPictureControllerDelegate` :217-259.
- Layer binding is **view-driven**, not VM-driven: `AVPlayerRoute/AVPlayerSurface.swift:81` `attach(playerLayer:)`, `:40` `detach(playerLayer:)`.
- VM ↔ PiP: `PlayerViewModel.swift:1440-1441` `backend.isPictureInPictureActiveProvider = { PictureInPictureCoordinator.shared.isActive }` (backend side `AVPlayerBackend.swift:603` decl, `:1006` read, `:1398` clear); `:1480-1483` `bindLifecycle(owner: self) { handlePictureInPictureEngagementEnded() }`; `:4775` `isEngaged` in the background branch; `:4781` `isPossible` → `schedulePictureInPictureBackgroundGrace()`; `:4832` `isEngaged` guard in `pauseBackgroundPlaybackIfUnrouted()`; `:6314` `endSession(owner: self)` in cleanup.
- View: `ContentView.swift:16` and `iOS/MobilePlayerControls.swift:27` each `@State private var pictureInPicture = PictureInPictureCoordinator.shared`.

### C.4 AirPlay / external playback
- Backend: `AVPlayerBackend.swift:899` `avPlayer.allowsExternalPlayback = false` (default off); `:908-913` KVO `\.isExternalPlaybackActive`; `:1031` `var isExternalPlaybackActive`; `:1005` folds it into `systemControlsAreActive`; `:1130` fires `onExternalPlaybackUnavailable?()`; `:230-250` "transport commands issued outside the app" doc.
- Callbacks (`AVPlayerBackend.swift:592/596/599`): `onExternalPlaybackActiveChange`, `onExternalPlaybackAllowedChange`, `onExternalPlaybackUnavailable`.
- VM (`PlayerViewModel.swift:1443-1477`, all `#if os(iOS)`): each closure re-checks `!isDisposed` + `Self.isCurrentStreamCallback(callbackGeneration, currentGeneration: streamLoadGeneration)`; `:1459` sets `supportsExternalPlayback` (:445); `:1461-1476` posts the "AirPlay Unavailable" notice via `Task { @MainActor }`; `:1479` seeds `supportsExternalPlayback = backend.isExternalPlaybackAllowed`.
- Policy: `handleExternalPlaybackActiveChange(_:)` :4808-4816, `pauseBackgroundPlaybackIfUnrouted()` :4830-4837, `:4770` background-branch bail-out.
- LAN URL swap for loopback: `AVPlayerRoute/LoopbackSegmentServer.swift:55,172,207,262,441`. Capability claims: `ApplePlaybackRouteCapabilities.swift:98,196-198,267-269,338-340,409`; surfaced as `PlayerRouteStatusRow(label: "External playback", …)` `PlayerViewModel.swift:371`. Picker: `iOS/AirPlayRoutePicker.swift:13`, mounted at `iOS/MobilePlayerControls.swift:168-169` gated on `viewModel.supportsExternalPlayback`.

### C.5 Scene phase
- Single entry point `PlayerViewModel.handleScenePhase(_ phase: ScenePhase)` `:4711-4795`, with a **hard `#if os(tvOS)` / `#else` fork**:
  - tvOS `:4712-4757`: `.inactive` → `pauseForForegroundInterruptionIfNeeded()` (:7571); `.background` → `suspendForBackground()` (:7592, snapshots `makeSuspendedPlaybackContext()` :3643 into `suspendedPlayback` :969); `.active` → if `isBackgroundSuspended` log `[CMP-LIFECYCLE] tvOS player woke from background suspend; awaiting explicit resume` + force controls, **else** run the transient-interruption recovery (`playbackInterruption`, `interruptionRecoveryTask`, `avPlayerBackend?.play()`, `Self.interruptionRecoveryTimeout`).
  - iOS/macOS `:4759-4794`: sets `isSceneBackgrounded`; `.background` bails for active AirPlay (:4770), then PiP engaged (:4775), then PiP possible → `schedulePictureInPictureBackgroundGrace()` (:4781), else `pauseBackgroundPlaybackIfUnrouted()`; `.active` cancels the grace task.
- **macOS divergence** (review §11 row 16): `macOS/PlayerView.swift:96-98` calls the same method, which on macOS takes the `#else` branch whose PiP/AirPlay guards are themselves `#if os(iOS)` — so macOS effectively falls to `pauseBackgroundPlaybackIfUnrouted()`.
- tvOS explicit resume: `resumeSuspendedPlayback()` :7640-7655, reached only from `retry()` :4571. `clearSuspendedPlaybackState()` :3665, called at :3693, :4061, :6351.
- `isBackgroundSuspended` (:983) is used as a **guard in 20+ command methods** (:4592, :4601, :4845, :4857, :4897, :5299, :5314, :5356, :5409, :5477, :5488, :5495, :5542, :5568, :5601, :5689, :5700, :6171, :6183, :6205, :6214, :6228, :6239, :6251, :6275, :7528, :7572) plus `:5442 playbackEligible:`.
- `PlayerTaskRegistry.swift:6` names `resetPublishedLoadState`, `suspendForBackground` as scope owners.

### C.6 tvOS display criteria
Entirely inside the backend + a `Shared/` helper; the VM never touches it.
- `Shared/TVDisplayCriteria.swift`: `activeTVWindow() -> UIWindow?` :38, `setCriteria(_ contentFormat: ContentFormat, refreshRate: Float) -> ApplyOutcome` :69, `makeFormatDescription` :89, `waitForModeSwitchSettle() async -> Bool` :164, `panelIsHostingHDR() -> Bool` :215.
- `AVPlayerBackend.swift`: state `didApplyTVDisplayCriteriaForStart` :807, `isPreservingTVDisplayCriteriaForReload` :855; `shouldPreserveTVDisplayCriteriaDuringReload(...)` :2894 used at :1737-1745; `applyTVDisplayCriteriaForLoopbackIfNeeded(context:)` :4720-4770 (`TVDisplayCriteria.setCriteria` :4737/:4764); `clearTVDisplayCriteria(context:)` :4783-4791 (`preferredDisplayCriteria = nil` :4790); settle wait at :2293-2309; `activeTVWindow()?.avDisplayManager` at :3949, :4702, :4786; teardown resets :4554-4556, :4596.
- The **initial-video-display blocker ladder** log line `AVPlayerBackend.swift:4154` `[CMP-AVP] initial video display gate released reason=… criteriaApplied=… switchInProgress=… audioAnchor=…` — this is the HANDOFF §2 item 8 work and is the most timing-sensitive thing Stage 2 must not disturb.
- Gate flag `HDRDisplayCriteriaPolicy` `player.apple.hdr_display_criteria_enabled` (default true); poll budgets :64.

### C.7 SiloControl / `TVControlReceiver`
- `Control/tvOS/TVControlReceiver.swift:42` `private weak var playerViewModel: PlayerViewModel?`; `registerPlayer(_:contentId:)` :198-209 (cancels `readyTimeoutTask`, sets `playerContentId`/`playerHandoffGeneration`, `startStateUpdates()`, `sendState()`, `setPlaybackAdvertised(true)`); `unregisterPlayer(_:)` :211-227 (identity-guarded `playerViewModel === viewModel` :212, then `await viewModel?.waitForCleanupCompletion()` :225 tied to `RemotePlaybackIdentityManager.shared.activeIdentity?.generationID`).
- `handleControl(_ command: SiloControlCommand)` :486-506 — `.stop` short-circuits to `stopRemotePlayback()`; everything else `try playerViewModel.applySiloControlCommand(command)` :500 then `sendState()`; `player_not_ready` / `command_failed` error codes.
- `sendState()` :634-643 → `playerViewModel.makeSiloControlPlaybackState(contentId: playerContentId)` :638.
- VM side `applySiloControlCommand(_:)` `PlayerViewModel.swift:7694-7790`: **first switch** :7703-7708 drops `.seek/.selectAudioTrack/.selectSubtitleTrack/.setQuality` while `isLoading` (an ad-hoc reducer guard); **second switch** :7709+ maps `.play/.pause` → `avPlayerBackend?.play()/pause()` + `scheduleHideControls()`, `.playPause` → `togglePlayPause()`, `.seek` → `seekTo(seconds:)`, `.stop` → `avPlayerBackend?.pause()` + `requestRemoteDismiss()`, `.selectAudioTrack`/`.selectSubtitleTrack` → track lookup by `trackId` with `SiloControlPlayerError.{missingSeekPosition, missingTrackId, trackNotFound}`.
- `makeSiloControlPlaybackState(contentId:)` :7794-7835 projects 25 VM fields (`lastLoadRequest?.contentId`, `activePlaybackSessionId`, `metadata.*`, tracks, `qualityOptions`, `settings.playbackSpeed/videoGravity/subtitleSyncMs/effectiveSubtitleAppearance.position`, `backendCapabilities.*`, `userVolume`) — **the full remote wire projection lives in the VM**.
- Command vocabulary `Control/SiloControlProtocol.swift:124-218`; iOS sender `Control/iOS/SiloControlClient.swift:350`; `SiloControlRemoteView.swift:156`.

### C.8 The audiobook engine as a second V3 client
- `Screens/Audio/AudioPlayerEngine.swift:5-75` `final class AudioPlayerEngine` — its **own** `private let player = AVPlayer()` :6, `AVPlayerItem(asset:)` :45, `.AVPlayerItemDidPlayToEndTime` observer :47, `load(url:headers:startSeconds:)` :34, `pause` :59, `setRate(_:shouldResume:)` :63, `seek(to:)` :70, `stop` :75. No `AVPlayerBackend`, no loopback, no `PlaybackSessionBridge`.
- `Screens/Audio/AudioPlayerViewModel.swift` reuses the V3 **types and adapter**, not the control plane:
  - `:273` `ApplePlaybackV3Capabilities.audiobookSnapshot()`; `:279` `PlaybackProtocolV3.version`; `:280` `ApplePlaybackV3Capabilities.audiobookFeatures`
  - `:277-296` builds `PlaybackV3StartRequest(...)` directly (`progressPersistence: "client"`, `subtitleFidelityPreference: "preserve"`, `qualityPreference: ApplePlaybackQuality.autoId`)
  - `:300`/`:305` `SiloAPI.shared.startPlaybackV3(request:)` with a manual idempotent retry on `HTTPError.network`
  - `:308-312` `ApplePlaybackV3PlanAdapter.resolvePlayablePlan(response, playbackAttemptId:snapshot:)` — **shared with the video path since round-6 tail `5a0cefa`**; the reviewer's Stage-2 note in HANDOFF §6a is that this prologue is no longer side-effect-free and belongs in the session actor
  - `:323-328` `ApplePlaybackV3PlanAdapter.playbackSession(plan:sessionId:selectedVersion:serverFeatures:)`
  - `:316`/`:350` `SiloAPI.shared.stopPlayback(sessionId:)`; `:404`/`:418` progress reporting; `:230`/`:234` teardown stops
  - `:497-503` its **own** `configureAudioSession()` — `.playback` / `.spokenAudio`, `setActive(true)`, no coordinator, no serialization against `AVPlayerAudioSessionCoordinator.sharedWorkQueue`
  - `:15` its own `NowPlayingController()`; `:432-441` `attachNowPlaying()` / `pushNowPlaying()`
- Owner: `Screens/Audio/AudioPlaybackStore.swift:6` `let player = AudioPlayerViewModel()`. Views: `AudioFullPlayerView.swift`, `AudioMiniPlayerView.swift`, `AudioChaptersSheet.swift` (each takes `let player: AudioPlayerViewModel`).
- Test coverage of the shared surface: `PlaybackProtocolV3Tests` exercises `ApplePlaybackV3Capabilities.audiobookSnapshot/audiobookFeatures`; `DetailVersionSelectionTests` exercises `AudioPlaybackTimeline.{trackIndex, localTime, globalTime}` and `SiloMediaType.isAudiobook`. Nothing tests `AudioPlayerEngine` or the audiobook start path end-to-end.

### C.9 Backend → VM callback surface (what a `PlaybackBackend` protocol has to cover)
`AVPlayerRoute/AVPlayerBackend.swift:574-604`, all `var on…: (…) -> Void)?`, all bound in `PlayerViewModel` under a by-value `callbackGeneration` compared against `streamLoadGeneration`:
`onTimeChange`:574 · `onDurationChange`:575 · `onPauseChange`:576 · `onFileLoaded`:578 · `onFirstFrame`:579 · `onError: ((PlaybackFailure) -> Void)?`:580 (R2 typed channel) · `onEndOfFile`:581 · `onBufferingChange`:582 · `onBufferedAheadChange`:583 · `onPlaybackStatsChange`:584 · `onTracksChange`:585 · `onChaptersChange`:586 · `onTimelineOffsetChange`:587 · `onExternalPlaybackActiveChange`:592 · `onExternalPlaybackAllowedChange`:596 · `onExternalPlaybackUnavailable`:599 · `onSidecarTracksRegistered`:604. Plus the pull-direction providers `isPictureInPictureActiveProvider`:603 and (per `:606-611`) the proxy/stats providers the VM injects.
Subtitle overlay is attached **from the view, to the backend, bypassing the VM**: `AVPlayerBackend.attachSubtitleOverlay(_:owner:)` :676 / `detachSubtitleOverlay(owner:)`, `subtitleOverlay` :672, `subtitleSession: SubtitleSession?` :726 (created :920, extractor :929); callers `AVPlayerRoute/AVPlayerSurface.swift:26,34,38,95-96` and `macOS/AVPlayerSurface.swift:24,44`.