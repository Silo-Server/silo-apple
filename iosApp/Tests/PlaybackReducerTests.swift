import Foundation
import XCTest
@testable import Silo

/// Stage 2 wave 1: the control plane's decision function, pinned against the
/// view-model behaviour it replaces (`beginFreshLoad`, `adoptPreparedPlayback`,
/// `loadStream`, `attemptProtocolV3Replan`, `restartCurrentTranscodeHLS`,
/// `commitSeek`, `handleScenePhase`, `finalizeTerminalPlaybackError`).
///
/// The reducer is pure, so every test is `(state, input, now) -> (state,
/// effects)` with a fixed `now`.
///
/// `SiloTests` is an **iOS-only** bundle (`project.yml` `SiloTests:
/// platform: iOS`), so an `#if os(tvOS)` / `#if os(macOS)` assertion here
/// would compile and never run. There is therefore no `#if os` in this file:
/// the scene-phase rule takes a `ScenePhasePlatform` parameter and the tables
/// below drive all three platforms from the iOS bundle.
final class PlaybackReducerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Fixtures

    private func makeRequest(
        contentId: String = "content-1",
        offlineDownloadId: String? = nil
    ) -> PlayerViewModel.LoadRequest {
        PlayerViewModel.LoadRequest(
            contentId: contentId,
            preferredFileId: 7,
            preferredAudioTrackIndex: 1,
            preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: nil,
            startFromBeginning: false,
            offlineDownloadId: offlineDownloadId
        )
    }

    private func makeIdentity(
        session: String? = "session-1",
        attempt: String = "apple:attempt-1",
        planAttempt: String? = "apple-plan:1",
        planAttemptKey: String? = "plan-key-1",
        outputContext: String = "output-1"
    ) -> SessionIdentity {
        SessionIdentity(
            serverSessionId: session,
            playbackAttemptId: attempt,
            planAttemptId: planAttempt,
            planAttemptKey: planAttemptKey,
            outputContextId: outputContext
        )
    }

    private func makePlan(
        engine: PlaybackEngineKind = .avPlayerNativeDirect,
        startSeconds: Double = 0
    ) -> ExecutablePlan {
        switch engine {
        case .avPlayerNativeDirect:
            return .nativeDirect(
                NativeDirectPlan(
                    url: URL(string: "https://example.invalid/movie.mkv")!,
                    headers: ["Authorization": "Bearer x"],
                    startSeconds: startSeconds
                )
            )
        case .avPlayerHLS:
            return .serverHLS(
                ServerHLSPlan(
                    manifestURL: URL(string: "https://example.invalid/master.m3u8")!,
                    headers: [:],
                    startMode: startSeconds == 0 ? .startOfManifest : .absolutePosition(startSeconds)
                )
            )
        case .siloPlayerLoopback:
            return .localHLS(LocalHLSPlan(sessionSpec: makeSessionSpec(), startSeconds: startSeconds))
        }
    }

    private func makeSessionSpec(
        sourceStartTimeSeconds: Double = 0
    ) -> LoopbackSessionSpec {
        LoopbackSessionSpec(
            sourceURL: URL(string: "https://example.invalid/movie.mkv")!,
            headers: [:],
            sourceStartTimeSeconds: sourceStartTimeSeconds,
            sourceBitrateBps: 20_000_000,
            videoMode: .passthroughHEVC,
            sourceVideoFrameRate: 23.976,
            selectedAudio: .absent,
            availableAudioTracks: [],
            manifestMetadata: LoopbackSessionSpec.ManifestMetadata(
                advertisedDolbyVisionProfile: nil,
                compatibilityBrand: nil,
                videoRange: "SDR",
                mayClaimAtmos: false
            )
        )
    }

    private func makePreparedRef(
        position: Double = 0,
        timelineOffsetSeconds: Double = 0,
        durationSeconds: Double? = 1000,
        activeQualityId: String = ApplePlaybackQuality.autoId,
        fileId: Int = 7
    ) throws -> PreparedPlaybackRef {
        let json = Data("""
        {
          "content_id": "content-1",
          "type": "movie",
          "title": "Test",
          "versions": [{"file_id": \(fileId), "duration": 900}]
        }
        """.utf8)
        let watchDetail = try HTTPClient.makeJSONDecoder().decode(WatchDetail.self, from: json)
        let session = PlaybackSessionResponse(
            sessionId: "session-1",
            userId: nil,
            profileId: nil,
            mediaFileId: fileId,
            playMethod: "direct",
            position: position,
            isPaused: false,
            streamUrl: "https://example.invalid/movie.mkv",
            audioTrackIndex: nil,
            durationSeconds: durationSeconds,
            timelineOffsetSeconds: timelineOffsetSeconds,
            subtitleUrls: nil,
            playbackInfo: nil
        )
        return PreparedPlaybackRef(
            PreparedPlayback(
                watchDetail: watchDetail,
                selectedVersion: watchDetail.versions[0],
                session: session,
                activeQualityId: activeQualityId
            )
        )
    }

    private func makePlaying(
        loadID: LoadID = LoadID(),
        identity: SessionIdentity? = nil,
        plan: ExecutablePlan? = nil,
        request: PlayerViewModel.LoadRequest? = nil,
        adoption: PlaybackAdoption = .freshLoad(.userInitiated),
        transport: TransportState = TransportState(positionSeconds: 100, durationSeconds: 1000),
        sub: Sub = .steady,
        seek: SeekRequest? = nil,
        activeQualityId: String? = ApplePlaybackQuality.autoId,
        resumeSelections: TrackResumeSelections? = nil,
        interruption: Playing.Interruption? = nil
    ) -> PlaybackState {
        let request = request ?? makeRequest()
        return .playing(
            Playing(
                loadID: loadID,
                identity: identity ?? makeIdentity(),
                plan: plan ?? makePlan(),
                request: request,
                adoption: adoption,
                transport: transport,
                sub: sub,
                seek: seek,
                activeQualityId: activeQualityId,
                resumeSelections: resumeSelections ?? .seeded(from: request),
                interruption: interruption
            )
        )
    }

    private func makePreparing(
        loadID: LoadID = LoadID(),
        identity: SessionIdentity? = nil,
        phase: Preparing.Phase = .startingEngine,
        options: LoadOptions = LoadOptions(),
        adoption: PlaybackAdoption = .freshLoad(.userInitiated),
        plan: ExecutablePlan? = nil,
        transport: TransportState = TransportState(),
        activeQualityId: String? = ApplePlaybackQuality.autoId,
        resumeSelections: TrackResumeSelections? = nil,
        interruption: Playing.Interruption? = nil
    ) -> PlaybackState {
        .preparing(
            Preparing(
                loadID: loadID,
                identity: identity ?? makeIdentity(),
                phase: phase,
                request: makeRequest(),
                options: options,
                adoption: adoption,
                plan: plan ?? makePlan(),
                transport: transport,
                activeQualityId: activeQualityId,
                resumeSelections: resumeSelections ?? .seeded(from: makeRequest()),
                interruption: interruption
            )
        )
    }

    private func playing(_ state: PlaybackState) -> Playing? {
        guard case .playing(let playing) = state else { return nil }
        return playing
    }

    // MARK: - Fresh load

    /// `beginFreshLoad` order: outage/interruption clears, the two task
    /// cancels, the outgoing session's progress report, the engine dispose,
    /// then the replacement start.
    func testFreshLoadEmitsBeginFreshLoadEffectsInOrder() {
        let previous = LoadID()
        let identity = makeIdentity()
        let state = makePlaying(loadID: previous, identity: identity)
        let request = makeRequest(contentId: "content-2")
        let options = LoadOptions(progressPosition: 100, resumePosition: 12)

        let (next, effects) = PlaybackReducer.reduce(
            state,
            intent: .load(request, origin: .userInitiated, options: options),
            now: now
        )

        guard let loadID = next.loadID else { return XCTFail("expected a minted LoadID") }
        XCTAssertNotEqual(loadID, previous, "every load mints a new LoadID")
        XCTAssertEqual(effects, [
            .cancelTimer(.serverOutageRecovery),
            .cancelTimer(.interruptionRecovery),
            .publish(PlaybackReducer.presentation(for: next)),
            .cancelTimer(.freshLoad),
            .cancelTimer(.protocolV3Replan),
            .reportProgress(identity, position: 100, isPaused: true),
            .disposeEngine(previous),
            .startSession(request, options, loadID),
        ])
        guard case .preparing(let preparing) = next else { return XCTFail("expected preparing") }
        XCTAssertEqual(preparing.phase, .resolvingSession)
        XCTAssertEqual(preparing.request, request)
        XCTAssertNil(preparing.identity)
        XCTAssertEqual(preparing.adoption, .freshLoad(.userInitiated))

        // `resetPublishedLoadState` raises the overlay and clears the error
        // (PVM:3476-3477) — the load path's only publish before `fileLoaded`.
        guard case .publish(let overlay) = effects[2] else {
            return XCTFail("expected the loading publish")
        }
        XCTAssertTrue(overlay.isLoading)
        XCTAssertNil(overlay.error)
        XCTAssertEqual(overlay.currentTime, 100, "the load keeps the playhead it resumes from")
        XCTAssertEqual(overlay.duration, 1000, "and the duration it already published")
    }

    /// `shouldFinalizeCurrentSession`: an explicit finalize, or any offline
    /// load, stops the outgoing session instead of only reporting against it.
    /// A recovery load does not clear the outage-recovery timer.
    func testFreshLoadFinalizesTheOutgoingSessionAndSkipsUserOnlyClears() {
        let identity = makeIdentity()
        let state = makePlaying(identity: identity)
        let offlineRequest = makeRequest(offlineDownloadId: "download-1")
        let options = LoadOptions(progressPosition: 42, preserveInterruptionState: true)

        let (_, effects) = PlaybackReducer.reduce(
            state,
            intent: .load(offlineRequest, origin: .recovery, options: options),
            now: now
        )

        XCTAssertFalse(effects.contains(.cancelTimer(.serverOutageRecovery)))
        XCTAssertFalse(effects.contains(.cancelTimer(.interruptionRecovery)))
        XCTAssertTrue(effects.contains(.stopSession(identity, position: 42, isPaused: true)))
        XCTAssertFalse(effects.contains(.reportProgress(identity, position: 42, isPaused: true)))
    }

    /// From idle there is no outgoing session and no engine, so neither the
    /// report nor the dispose is emitted.
    func testFreshLoadFromIdleOnlyStartsTheSession() {
        let request = makeRequest()
        let (next, effects) = PlaybackReducer.reduce(
            .idle,
            intent: .load(request, origin: .userInitiated, options: LoadOptions(progressPosition: 12)),
            now: now
        )
        guard let loadID = next.loadID else { return XCTFail("expected a minted LoadID") }
        XCTAssertEqual(effects, [
            .cancelTimer(.serverOutageRecovery),
            .cancelTimer(.interruptionRecovery),
            .publish(PlaybackReducer.presentation(for: next)),
            .cancelTimer(.freshLoad),
            .cancelTimer(.protocolV3Replan),
            .startSession(request, LoadOptions(progressPosition: 12), loadID),
        ])
    }

    // MARK: - Prepare → engine

    func testPreparedStartsTheEngineWithoutReusingIt() throws {
        let request = makeRequest()
        let (preparing, _) = PlaybackReducer.reduce(
            .idle,
            intent: .load(request, origin: .userInitiated, options: LoadOptions()),
            now: now
        )
        let loadID = try XCTUnwrap(preparing.loadID)
        let identity = makeIdentity()
        let plan = makePlan(engine: .siloPlayerLoopback)

        let (next, effects) = PlaybackReducer.reduce(
            preparing,
            event: .session(
                .prepared(
                    try makePreparedRef(
                        position: 610,
                        timelineOffsetSeconds: 7,
                        activeQualityId: "1080p",
                        fileId: 9
                    ),
                    plan,
                    for: loadID
                ),
                identity
            ),
            now: now
        )

        // `adoptPreparedPlayback` reports plan execution *before* `loadStream`
        // (PVM:2704/2708 vs PVM:2716).
        XCTAssertEqual(effects, [
            .reportPlanExecutionStarted(identity),
            .loadEngine(plan, loadID, reuseEngine: false),
        ])
        guard case .preparing(let state) = next else { return XCTFail("expected preparing") }
        XCTAssertEqual(state.phase, .startingEngine)
        XCTAssertEqual(state.identity, identity)
        XCTAssertEqual(state.plan, plan)
        // The adopt establishes the playhead and the duration before the
        // engine load, so nothing downstream ever sees 0/0 (PVM:2612-2613).
        XCTAssertEqual(state.transport.positionSeconds, 617, "movieTime = position + timelineOffset")
        XCTAssertEqual(state.transport.durationSeconds, 1000)
        XCTAssertEqual(state.activeQualityId, "1080p")
        XCTAssertEqual(state.resumeSelections.selectedFileId, 9)
    }

    /// The duration fallback chain, `session.durationSeconds ??
    /// selectedVersion.duration ?? fallback` (PVM:2609-2612): a fresh load
    /// falls back to 0, a replan to the duration it already published.
    func testAdoptedDurationFallsBackThroughTheVersionThenTheOrigin() throws {
        let loadID = LoadID()
        let (next, _) = PlaybackReducer.reduce(
            makePreparing(
                loadID: loadID,
                phase: .resolvingSession,
                transport: TransportState(durationSeconds: 4321)
            ),
            event: .session(
                .prepared(try makePreparedRef(durationSeconds: nil), makePlan(), for: loadID),
                makeIdentity()
            ),
            now: now
        )
        guard case .preparing(let preparing) = next else { return XCTFail("expected preparing") }
        XCTAssertEqual(preparing.transport.durationSeconds, 900, "the version's duration")
    }

    /// A prepare that answers a superseded load is dropped structurally —
    /// this is what the `streamLoadGeneration` capture used to do by value.
    func testPreparedForASupersededLoadIsIgnored() throws {
        let (preparing, _) = PlaybackReducer.reduce(
            .idle,
            intent: .load(makeRequest(), origin: .userInitiated, options: LoadOptions()),
            now: now
        )
        let (next, effects) = PlaybackReducer.reduce(
            preparing,
            event: .session(
                .prepared(try makePreparedRef(), makePlan(), for: LoadID()),
                makeIdentity()
            ),
            now: now
        )
        XCTAssertEqual(next, preparing)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - fileLoaded

    /// `fileLoaded` starts the progress heartbeat and publishes — and it
    /// carries the playhead, duration and quality the adopt established, so the
    /// scrubber never blinks to 0/0 on a load or an in-place replan.
    func testFileLoadedStartsPlaybackFromTheAdoptedTransport() throws {
        let loadID = LoadID()
        let identity = makeIdentity()
        let plan = makePlan()
        let (preparing, _) = PlaybackReducer.reduce(
            makePreparing(loadID: loadID, identity: identity, phase: .resolvingSession, plan: plan),
            event: .session(
                .prepared(
                    try makePreparedRef(position: 610, timelineOffsetSeconds: 7, activeQualityId: "4k"),
                    plan,
                    for: loadID
                ),
                identity
            ),
            now: now
        )

        let (next, effects) = PlaybackReducer.reduce(
            preparing,
            event: .engine(.fileLoaded(reason: "status_ready"), loadID),
            now: now
        )

        XCTAssertEqual(playing(next)?.sub, .steady)
        XCTAssertEqual(playing(next)?.plan, plan)
        XCTAssertEqual(playing(next)?.transport.positionSeconds, 617)
        XCTAssertEqual(playing(next)?.transport.durationSeconds, 1000)
        XCTAssertEqual(playing(next)?.activeQualityId, "4k")
        // The report already went out with the plan, not here.
        XCTAssertFalse(
            effects.contains { if case .reportPlanExecutionStarted = $0 { return true } else { return false } }
        )
        XCTAssertEqual(Array(effects.prefix(2)), [
            .cancelTimer(.serverOutageRecovery),
            .schedule(.progress, after: .seconds(10), loadID),
        ])
        guard case .publish(let presentation) = effects.last else {
            return XCTFail("expected a publish")
        }
        XCTAssertTrue(presentation.isPlaying)
        XCTAssertEqual(presentation.currentTime, 617)
        XCTAssertEqual(presentation.duration, 1000)
        XCTAssertEqual(presentation.activeQualityId, "4k")
    }

    /// `adoptPreparedPlayback`'s per-origin rule: a fresh load and a V3 replan
    /// report plan execution, the in-place transcode restart deliberately
    /// never has (PVM:2696-2715).
    func testPlanExecutionReportRuleFollowsTheAdoptionOrigin() throws {
        func reportsForReplan(kind: ReplanIntent.Kind) throws -> Bool {
            let state = makePlaying(
                sub: .replanning(
                    ReplanIntent(kind: kind, position: 100, classification: "c", message: "m")
                )
            )
            let (_, effects) = PlaybackReducer.reduce(
                state,
                event: .session(.replanned(try makePreparedRef(), makePlan()), makeIdentity()),
                now: now
            )
            return effects.contains {
                if case .reportPlanExecutionStarted = $0 { return true } else { return false }
            }
        }

        // Fresh load: reported at the prepare.
        let loadID = LoadID()
        let (_, freshEffects) = PlaybackReducer.reduce(
            makePreparing(loadID: loadID, phase: .resolvingSession),
            event: .session(.prepared(try makePreparedRef(), makePlan(), for: loadID), makeIdentity()),
            now: now
        )
        XCTAssertTrue(
            freshEffects.contains {
                if case .reportPlanExecutionStarted = $0 { return true } else { return false }
            }
        )

        XCTAssertTrue(try reportsForReplan(kind: .serverReplan))
        XCTAssertFalse(try reportsForReplan(kind: .transcodeRestart(.seekReanchor(origin: 100))))
        XCTAssertFalse(try reportsForReplan(kind: .transcodeRestart(.qualityChange(qualityId: "1080p"))))
    }

    // MARK: - Replan

    /// Review §11 #22: one replan slot. The second request — from either
    /// pipeline — produces nothing at all.
    func testSecondReplanWhileReplanningIsRefused() {
        let intent = ReplanIntent(
            kind: .serverReplan,
            position: 100,
            classification: "player_error",
            message: "boom"
        )
        let state = makePlaying(sub: .replanning(intent))

        let (afterQuality, qualityEffects) = PlaybackReducer.reduce(
            state,
            intent: .changeQuality("1080p"),
            now: now
        )
        XCTAssertEqual(afterQuality, state)
        XCTAssertTrue(qualityEffects.isEmpty)

        let (afterRecovery, recoveryEffects) = PlaybackReducer.reduce(
            state,
            event: .recovery(
                .requestServerReplan(classification: "player_error", message: "boom again"),
                playing(state)!.loadID
            ),
            now: now
        )
        XCTAssertEqual(afterRecovery, state)
        XCTAssertTrue(recoveryEffects.isEmpty)
    }

    /// A renewal in flight is about to rewrite the same session, so it refuses
    /// a replan too (today's two `*SessionId` echoes, now one sub-state).
    func testReplanWhileRenewingSourceIsRefused() {
        let renewal = SourceRenewal(
            reason: "progress",
            observedPosition: 100,
            startedAt: now,
            issuedFor: makeIdentity()
        )
        let state = makePlaying(sub: .renewingSource(renewal))
        let (next, effects) = PlaybackReducer.reduce(state, intent: .changeQuality("720p"), now: now)
        XCTAssertEqual(next, state)
        XCTAssertTrue(effects.isEmpty)
    }

    /// `prepareBackend(for:)` survives an in-place server replan onto the same
    /// engine — but the `LoadID` never does (review #1: callbacks re-bind).
    func testReplannedKeepsTheEngineAndMintsANewLoadID() throws {
        let loadID = LoadID()
        let identity = makeIdentity()
        let intent = ReplanIntent(
            kind: .serverReplan,
            position: 100,
            classification: "output_route_changed",
            message: "The Apple audio output route changed."
        )
        let state = makePlaying(
            loadID: loadID,
            identity: identity,
            plan: makePlan(engine: .siloPlayerLoopback),
            sub: .replanning(intent)
        )
        let replacement = makePlan(engine: .siloPlayerLoopback, startSeconds: 100)
        // The replan keeps the session and playback attempt and mints a new
        // plan attempt.
        let replannedIdentity = makeIdentity(planAttempt: "apple-plan:2", planAttemptKey: "plan-key-2")

        let (next, effects) = PlaybackReducer.reduce(
            state,
            event: .session(.replanned(try makePreparedRef(), replacement), replannedIdentity),
            now: now
        )

        guard case .preparing(let preparing) = next else { return XCTFail("expected preparing") }
        XCTAssertNotEqual(preparing.loadID, loadID)
        XCTAssertEqual(preparing.identity, replannedIdentity)
        XCTAssertEqual(preparing.adoption, .replan(.serverReplan))
        XCTAssertEqual(effects, [
            .reportPlanExecutionStarted(replannedIdentity),
            .loadEngine(replacement, preparing.loadID, reuseEngine: true),
        ])
    }

    /// Reuse is engine-scoped: a replan onto a different engine, and every
    /// transcode restart, installs a fresh backend.
    func testReplannedOntoADifferentEngineOrARestartDoesNotReuse() throws {
        func reuse(kind: ReplanIntent.Kind, replacement: ExecutablePlan) throws -> Bool {
            let state = makePlaying(
                plan: makePlan(engine: .siloPlayerLoopback),
                sub: .replanning(
                    ReplanIntent(kind: kind, position: 100, classification: "c", message: "m")
                )
            )
            let (_, effects) = PlaybackReducer.reduce(
                state,
                event: .session(.replanned(try makePreparedRef(), replacement), makeIdentity()),
                now: now
            )
            guard case .loadEngine(_, _, let reuseEngine) = effects.last else {
                XCTFail("expected loadEngine")
                return false
            }
            return reuseEngine
        }

        XCTAssertFalse(try reuse(kind: .serverReplan, replacement: makePlan(engine: .avPlayerHLS)))
        XCTAssertFalse(
            try reuse(
                kind: .transcodeRestart(.qualityChange(qualityId: "720p")),
                replacement: makePlan(engine: .siloPlayerLoopback)
            )
        )
    }

    /// A replan answer for another session (the one before a fresh load, or a
    /// renewed one) never lands.
    func testReplannedForADifferentSessionIsIgnored() throws {
        let state = makePlaying(
            sub: .replanning(
                ReplanIntent(kind: .serverReplan, position: 100, classification: "c", message: "m")
            )
        )
        let (next, effects) = PlaybackReducer.reduce(
            state,
            event: .session(
                .replanned(try makePreparedRef(), makePlan()),
                makeIdentity(session: "session-2", attempt: "apple:attempt-2")
            ),
            now: now
        )
        XCTAssertEqual(next, state)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - Seeking

    func testSeekArmsTheDeadlineAndTheFilterTimeout() {
        let loadID = LoadID()
        let state = makePlaying(loadID: loadID)

        let (next, effects) = PlaybackReducer.reduce(
            state,
            intent: .seek(targetSeconds: 300, origin: .user),
            now: now
        )

        guard let request = playing(next)?.seek else {
            return XCTFail("expected a seek request")
        }
        XCTAssertEqual(playing(next)?.sub, .steady, "a seek does not take the load")
        XCTAssertEqual(request.fromSeconds, 100)
        XCTAssertEqual(request.targetSeconds, 300)
        XCTAssertEqual(request.deadline, now.addingTimeInterval(15))
        XCTAssertEqual(playing(next)?.transport.positionSeconds, 300, "the scrubber jumps optimistically")
        XCTAssertEqual(effects, [
            .seek(request, loadID),
            .schedule(.seekFilterTimeout, after: .seconds(5), loadID),
        ])
    }

    /// `beginReanchorSeekUI` arms the filter with no safety timeout — the
    /// stream rebuild that follows releases it.
    func testReanchorSeekArmsNoFilterTimeout() {
        let (_, effects) = PlaybackReducer.reduce(
            makePlaying(),
            intent: .seek(targetSeconds: 300, origin: .reanchor),
            now: now
        )
        XCTAssertEqual(effects.count, 1)
        XCTAssertFalse(
            effects.contains { if case .schedule = $0 { return true } else { return false } }
        )
    }

    /// The `onTimeChange` filter: reports still closer to the pre-seek
    /// position are stale drainage frames; the first past the midpoint lands.
    func testSeekFilterDropsStaleTimeReportsAndClearsOnLanding() {
        let loadID = LoadID()
        let (seeking, _) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID),
            intent: .seek(targetSeconds: 300, origin: .user),
            now: now
        )

        let (stale, staleEffects) = PlaybackReducer.reduce(
            seeking,
            event: .engine(.time(seconds: 120), loadID),
            now: now
        )
        XCTAssertEqual(stale, seeking, "a stale frame changes nothing")
        XCTAssertTrue(staleEffects.isEmpty)

        let (landed, landedEffects) = PlaybackReducer.reduce(
            seeking,
            event: .engine(.time(seconds: 260), loadID),
            now: now
        )
        XCTAssertNil(playing(landed)?.seek)
        XCTAssertEqual(playing(landed)?.transport.positionSeconds, 260)
        XCTAssertEqual(landedEffects, [.cancelTimer(.seekFilterTimeout)])
    }

    func testSeekFilterTimeoutReleasesTheFilter() {
        let loadID = LoadID()
        let (seeking, _) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID),
            intent: .seek(targetSeconds: 300, origin: .user),
            now: now
        )
        let (next, effects) = PlaybackReducer.reduce(
            seeking,
            event: .timer(.seekFilterTimeout, loadID),
            now: now
        )
        XCTAssertNil(playing(next)?.seek)
        XCTAssertTrue(effects.isEmpty)
    }

    /// Review §11 #17/#5: a new load drops an outstanding seek structurally —
    /// the `SeekRequest` lives on `Playing`, which the load replaces, and the
    /// old `LoadID` no longer matches, so the late time report is ignored.
    func testANewLoadDropsAnOutstandingSeekRequest() {
        let loadID = LoadID()
        let (seeking, _) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID),
            intent: .seek(targetSeconds: 300, origin: .user),
            now: now
        )
        let (reloaded, _) = PlaybackReducer.reduce(
            seeking,
            intent: .load(makeRequest(), origin: .userInitiated, options: LoadOptions()),
            now: now
        )

        XCTAssertNotEqual(reloaded.loadID, loadID)
        let (afterLateTime, effects) = PlaybackReducer.reduce(
            reloaded,
            event: .engine(.time(seconds: 260), loadID),
            now: now
        )
        XCTAssertEqual(afterLateTime, reloaded)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - Time reports

    /// PVM:1228-1235, immediately ahead of the seek filter: outside an explicit
    /// seek playback time is monotonic, so a report that jumps backwards is a
    /// replacement item's anchor frame rather than a playhead. Without it a
    /// loopback reload would drag the scrubber — and the progress reporter —
    /// backwards, which is the bug the predicate was added for.
    func testBackwardTimeReportsAreDroppedUnlessASeekIsInFlight() {
        let loadID = LoadID()
        let steady = makePlaying(loadID: loadID)

        let (afterBackwards, backwardsEffects) = PlaybackReducer.reduce(
            steady,
            event: .engine(.time(seconds: 12), loadID),
            now: now
        )
        XCTAssertEqual(afterBackwards, steady, "an anchor frame must not move the scrubber")
        XCTAssertTrue(backwardsEffects.isEmpty)

        // Inside the predicate's 0.75 s tolerance the report still lands.
        let (afterJitter, _) = PlaybackReducer.reduce(
            steady,
            event: .engine(.time(seconds: 99.5), loadID),
            now: now
        )
        XCTAssertEqual(playing(afterJitter)?.transport.positionSeconds, 99.5)

        // A seek in flight disables the rule — that is what makes a backwards
        // seek land at all.
        let (seeking, _) = PlaybackReducer.reduce(
            steady,
            intent: .seek(targetSeconds: 10, origin: .user),
            now: now
        )
        let (landed, _) = PlaybackReducer.reduce(
            seeking,
            event: .engine(.time(seconds: 12), loadID),
            now: now
        )
        XCTAssertNil(playing(landed)?.seek)
        XCTAssertEqual(playing(landed)?.transport.positionSeconds, 12)
    }

    /// The seek filter is orthogonal to whatever owns the load, exactly as
    /// `seekOriginTime`/`seekTargetTime` are orthogonal to
    /// `protocolV3ReplanTask` in the view model: a remote/SiloControl seek
    /// arriving mid-replan is performed **and** the server's answer still
    /// lands. Modelling the seek as a `Sub` case dropped whichever arrived
    /// second and stranded the load behind the loading overlay.
    func testASeekDuringAReplanKeepsBothTheSeekAndTheReplan() throws {
        let loadID = LoadID()
        let identity = makeIdentity()
        let (replanning, _) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID, identity: identity),
            intent: .changeQuality("1080p"),
            now: now
        )

        let (seeking, seekEffects) = PlaybackReducer.reduce(
            replanning,
            intent: .seek(targetSeconds: 300, origin: .skip),
            now: now
        )
        guard case .replanning = playing(seeking)?.sub else {
            return XCTFail("the replan still owns the load")
        }
        XCTAssertNotNil(playing(seeking)?.seek)
        XCTAssertTrue(
            seekEffects.contains { if case .seek = $0 { return true } else { return false } }
        )

        // ... and the replan answer is still accepted.
        let (replanned, replannedEffects) = PlaybackReducer.reduce(
            seeking,
            event: .session(.replanned(try makePreparedRef(), makePlan()), identity),
            now: now
        )
        guard case .preparing = replanned else {
            return XCTFail("the server's answer must not be dropped")
        }
        XCTAssertTrue(
            replannedEffects.contains { if case .loadEngine = $0 { return true } else { return false } }
        )
    }

    /// A silent renewal must not silently discard an outstanding seek either
    /// — the two are independent in the view model, so they are here too.
    func testABackgroundRenewalLeavesAnOutstandingSeekAlone() {
        let loadID = LoadID()
        let (seeking, _) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID),
            intent: .seek(targetSeconds: 300, origin: .user),
            now: now
        )
        let (renewing, _) = PlaybackReducer.reduce(
            seeking,
            event: .recovery(.renewSourceInBackground(reason: "progress"), loadID),
            now: now
        )
        guard case .renewingSource = playing(renewing)?.sub else {
            return XCTFail("expected the renewal sub-state")
        }
        XCTAssertEqual(playing(renewing)?.seek, playing(seeking)?.seek)
    }

    /// Every seek entry point refuses once the postroll latch is set
    /// (`skipForward` PVM:4846, `skipBackward` PVM:4858, `seek(to:)` PVM:5300,
    /// `seekTo(seconds:)` PVM:5315) — except the two that clear the latch
    /// themselves before seeking: leaving the postroll with "Keep watching"
    /// (PVM:2093-2110) and a reanchor (PVM:5063-5064).
    func testSeekIsRefusedAfterTheEndOfFileExceptWhereTheLatchIsClearedFirst() {
        let loadID = LoadID()
        let state = makePlaying(loadID: loadID, sub: .ended)

        for origin in [
            SeekOrigin.user, .scrub, .skip, .chapter, .intro, .credits, .recovery("stall"),
        ] {
            let (next, effects) = PlaybackReducer.reduce(
                state,
                intent: .seek(targetSeconds: 300, origin: origin),
                now: now
            )
            XCTAssertEqual(next, state, "\(origin) must be refused at EOF")
            XCTAssertTrue(effects.isEmpty)
        }

        for origin in [SeekOrigin.nextUpKeepWatching, .reanchor] {
            let (next, effects) = PlaybackReducer.reduce(
                state,
                intent: .seek(targetSeconds: 990, origin: origin),
                now: now
            )
            XCTAssertEqual(playing(next)?.sub, .steady, "\(origin) clears the latch")
            XCTAssertEqual(playing(next)?.seek?.targetSeconds, 990)
            XCTAssertTrue(
                effects.contains { if case .seek = $0 { return true } else { return false } }
            )
        }
    }

    // MARK: - End of file

    func testEndOfFileEntersTheEndedSubStateAndPauses() {
        let loadID = LoadID()
        let state = makePlaying(loadID: loadID)
        let (next, effects) = PlaybackReducer.reduce(
            state,
            event: .engine(.endOfFile, loadID),
            now: now
        )

        XCTAssertEqual(playing(next)?.sub, .ended)
        XCTAssertEqual(playing(next)?.transport.positionSeconds, 1000, "the playhead pins to duration")
        XCTAssertEqual(Array(effects.prefix(2)), [
            .cancelTimer(.serverOutageRecovery),
            .transport(.pause, loadID),
        ])

        // The EOF latch drops later time reports, as `onTimeChange` does.
        let (afterTime, timeEffects) = PlaybackReducer.reduce(
            next,
            event: .engine(.time(seconds: 12), loadID),
            now: now
        )
        XCTAssertEqual(afterTime, next)
        XCTAssertTrue(timeEffects.isEmpty)
    }

    /// `handleEndOfFile` PVM:3344-3347: EOF is ignored while server-outage
    /// recovery is active. The recovery keeps the same `LoadID` while it
    /// disposes the engine, so the teardown's own EOF passes the identity
    /// guard — accepting it would abort the recovery and strand the player on
    /// the postroll.
    func testEndOfFileIsIgnoredWhileServerOutageRecoveryOwnsTheLoad() {
        let loadID = LoadID()
        for step in [RecoveryStep.recoveringFromServerOutage, .waitingForServerReady] {
            let state = makePlaying(loadID: loadID, sub: .recovering(step))
            let (next, effects) = PlaybackReducer.reduce(
                state,
                event: .engine(.endOfFile, loadID),
                now: now
            )
            XCTAssertEqual(next, state, "\(step) must survive a late EOF")
            XCTAssertTrue(effects.isEmpty)
        }

        // A replacement owning the load survives a late EOF too: `Sub` is
        // exclusive, so accepting it would refuse the server's answer and
        // strand the load. `handleEndOfFile` never touches the replan or
        // renewal slots.
        let replanning = makePlaying(
            loadID: loadID,
            sub: .replanning(
                ReplanIntent(kind: .serverReplan, position: 100, classification: "c", message: "m")
            )
        )
        let (afterReplanEOF, replanEOFEffects) = PlaybackReducer.reduce(
            replanning,
            event: .engine(.endOfFile, loadID),
            now: now
        )
        XCTAssertEqual(afterReplanEOF, replanning)
        XCTAssertTrue(replanEOFEffects.isEmpty)

        let renewing = makePlaying(
            loadID: loadID,
            sub: .renewingSource(
                SourceRenewal(
                    reason: "progress",
                    observedPosition: 100,
                    startedAt: now,
                    issuedFor: makeIdentity()
                )
            )
        )
        let (afterRenewEOF, renewEOFEffects) = PlaybackReducer.reduce(
            renewing,
            event: .engine(.endOfFile, loadID),
            now: now
        )
        XCTAssertEqual(afterRenewEOF, renewing)
        XCTAssertTrue(renewEOFEffects.isEmpty)

        // Every other in-route recovery still ends naturally.
        let (ended, _) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID, sub: .recovering(.reloadingItem)),
            event: .engine(.endOfFile, loadID),
            now: now
        )
        XCTAssertEqual(playing(ended)?.sub, .ended)
    }

    /// The near-end rung reaches the same terminal-but-clean state.
    func testTreatAsNaturalEndEndsTheLoad() {
        let loadID = LoadID()
        let (next, _) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID),
            event: .recovery(.treatAsNaturalEnd, loadID),
            now: now
        )
        XCTAssertEqual(playing(next)?.sub, .ended)
    }

    // MARK: - Failure

    /// `finalizeTerminalPlaybackError` (PVM:4027-4071) disposes the engine,
    /// cancels the recovery timers, keeps `currentTime` and publishes the
    /// error — and deliberately does **not** stop the server session: it drops
    /// `activePlaybackSessionId` and lets the session lapse. Synthesising a
    /// stop here would be a new server call on a wire-visible path.
    func testFailDisposesTheEngineAndPublishesTheErrorWithoutStoppingTheSession() {
        let loadID = LoadID()
        let identity = makeIdentity()
        let state = makePlaying(loadID: loadID, identity: identity)
        let failure = PlaybackFailure(legacyMessage: "The stream could not be played.")

        let (next, effects) = PlaybackReducer.reduce(
            state,
            event: .recovery(.fail(failure), loadID),
            now: now
        )

        guard case .failed(let recorded, let failedLoadID, let request, let position, _) = next else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(recorded, failure)
        XCTAssertEqual(failedLoadID, loadID)
        XCTAssertEqual(request, makeRequest(), "retry replays the last request")
        XCTAssertEqual(position, 100, "finalizeTerminalPlaybackError keeps currentTime")
        XCTAssertTrue(effects.contains(.disposeEngine(loadID)))
        XCTAssertFalse(
            effects.contains { if case .stopSession = $0 { return true } else { return false } },
            "the terminal path lets the session lapse; the stop belongs to teardown"
        )
        guard case .publish(let presentation) = effects.last else {
            return XCTFail("expected a publish")
        }
        XCTAssertEqual(presentation.error, failure.legacyMessage)
        XCTAssertFalse(presentation.isPlaying)
    }

    /// A terminal replan failure lands on the same path.
    func testTerminalSessionFailureFails() {
        let identity = makeIdentity()
        let state = makePlaying(
            identity: identity,
            sub: .replanning(
                ReplanIntent(kind: .serverReplan, position: 100, classification: "c", message: "m")
            )
        )
        let (next, _) = PlaybackReducer.reduce(
            state,
            event: .session(
                .terminal(
                    PlaybackV3TerminalFailure(
                        reason: "attempt_limit_reached",
                        message: "No further playback plans are available.",
                        retryable: false
                    )
                ),
                identity
            ),
            now: now
        )
        guard case .failed(let failure, _, _, _, _) = next else { return XCTFail("expected failed") }
        XCTAssertEqual(failure.legacyMessage, "No further playback plans are available.")
    }

    /// `retry()` PVM:4557-4566 replays the last request at `currentTime`,
    /// which `finalizeTerminalPlaybackError` deliberately keeps — Retry must
    /// resume where playback died, not restart the title.
    func testRetryResumesWherePlaybackDied() {
        let loadID = LoadID()
        let (failed, _) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID),
            event: .recovery(.fail(PlaybackFailure(legacyMessage: "boom")), loadID),
            now: now
        )

        let (next, effects) = PlaybackReducer.reduce(failed, intent: .retry, now: now)

        guard case .preparing(let preparing) = next else { return XCTFail("expected preparing") }
        XCTAssertEqual(preparing.request, makeRequest())
        XCTAssertEqual(preparing.options.progressPosition, 100)
        XCTAssertEqual(preparing.options.resumePosition, 100)
        XCTAssertTrue(preparing.options.allowNearEndResume)
        XCTAssertTrue(
            effects.contains(.startSession(makeRequest(), preparing.options, preparing.loadID))
        )
        XCTAssertEqual(PlaybackReducer.presentation(for: failed).currentTime, 100)
    }

    // MARK: - Recovery actions

    /// One action, one effect set. The engine-scoped rungs execute without
    /// owning the load; only the multi-step ones take a `.recovering`
    /// sub-state.
    func testRecoveryActionsMapToExactlyOneEffectSet() {
        let loadID = LoadID()
        let identity = makeIdentity()

        func run(_ action: RecoveryAction, sub: Sub = .steady) -> (PlaybackState, [Effect]) {
            PlaybackReducer.reduce(
                makePlaying(loadID: loadID, identity: identity, sub: sub),
                event: .recovery(action, loadID),
                now: now
            )
        }

        let reassert = run(.reassertPlay)
        XCTAssertEqual(reassert.1, [.runRecovery(.reassertPlay, loadID)])
        XCTAssertEqual(playing(reassert.0)?.sub, .steady)

        let nudge = run(.nudgeStartup)
        XCTAssertEqual(nudge.1, [.runRecovery(.nudgeStartup, loadID)])
        XCTAssertEqual(playing(nudge.0)?.sub, .steady)

        let reanchor = run(.reanchor(atMediaSeconds: 120, reason: "vod_stall_nudge"))
        XCTAssertEqual(
            reanchor.1,
            [.runRecovery(.reanchor(atMediaSeconds: 120, reason: "vod_stall_nudge"), loadID)]
        )
        XCTAssertEqual(playing(reanchor.0)?.sub, .steady)

        let reload = run(.reloadItem(atMediaSeconds: 120, reason: "playhead_watchdog"))
        XCTAssertEqual(
            reload.1,
            [.runRecovery(.reloadItem(atMediaSeconds: 120, reason: "playhead_watchdog"), loadID)]
        )
        XCTAssertEqual(playing(reload.0)?.sub, .recovering(.reloadingItem))

        let rebuild = run(.rebuildLocalSession(atMediaSeconds: 120, reason: "loopback_starvation"))
        XCTAssertEqual(playing(rebuild.0)?.sub, .recovering(.rebuildingLocalSession))

        // `attemptProtocolV3Replan` PVM:1614-1616: heartbeat off, overlay on,
        // then the round trip — in that order.
        let replan = run(.requestServerReplan(classification: "player_error", message: "boom"))
        XCTAssertEqual(replan.1.count, 3)
        XCTAssertEqual(replan.1.first, .cancelTimer(.progress))
        guard case .publish(let replanPresentation) = replan.1[1] else {
            return XCTFail("expected the loading publish")
        }
        XCTAssertTrue(replanPresentation.isLoading)
        XCTAssertFalse(replanPresentation.isBuffering, "setBuffering(false, cause: \"replan\")")
        XCTAssertEqual(
            replan.1.last,
            .replan(
                ReplanIntent(
                    kind: .serverReplan,
                    position: 100,
                    classification: "player_error",
                    message: "boom"
                ),
                identity
            )
        )
        guard case .replanning = playing(replan.0)?.sub else {
            return XCTFail("expected the replanning sub-state")
        }

        let renew = run(.renewSourceInBackground(reason: "progress"))
        XCTAssertEqual(renew.1, [
            .renewSource(
                SourceRenewal(
                    reason: "progress",
                    observedPosition: 100,
                    startedAt: now,
                    issuedFor: identity
                ),
                identity
            ),
        ])
        guard case .renewingSource = playing(renew.0)?.sub else {
            return XCTFail("expected the renewingSource sub-state")
        }

        let routeFallback = run(.switchRoute(.loopbackFallback))
        XCTAssertEqual(routeFallback.1, [.runRecovery(.switchRoute(.loopbackFallback), loadID)])
        XCTAssertEqual(playing(routeFallback.0)?.sub, .recovering(.switchingRoute))

        let serverHLS = run(.switchRoute(.serverHLS(classification: "silo_loopback_failed")))
        XCTAssertEqual(serverHLS.1.first, .cancelTimer(.progress))
        XCTAssertEqual(
            serverHLS.1.last,
            .replan(
                ReplanIntent(
                    kind: .serverReplan,
                    position: 100,
                    classification: "silo_loopback_failed",
                    message: "silo_loopback_failed"
                ),
                identity
            )
        )

        let waitForServer = run(.waitForServerReady(probeAfter: .seconds(2)))
        XCTAssertEqual(
            waitForServer.1,
            [.pollServerHealth(.serverOutageRecovery, after: .seconds(2), loadID)]
        )
        XCTAssertEqual(playing(waitForServer.0)?.sub, .recovering(.waitingForServerReady))
    }

    /// `handleOriginOutageChanged(true)`: the load rides its buffered runway
    /// while the health poll runs, and a second entry is a no-op.
    func testOutageRideThroughPollsServerHealthOnceAndIsSingleFlight() {
        let loadID = LoadID()
        let state = makePlaying(loadID: loadID)

        let (riding, effects) = PlaybackReducer.reduce(
            state,
            event: .recovery(.rideThroughOutage(probeAfter: .seconds(1)), loadID),
            now: now
        )
        XCTAssertEqual(
            effects,
            [.pollServerHealth(.sourceOutageRideThrough, after: .seconds(1), loadID)]
        )
        guard case .ridingOutOutage(let outage) = playing(riding)?.sub else {
            return XCTFail("expected the ride-through sub-state")
        }
        XCTAssertEqual(outage.startedAt, now)
        XCTAssertEqual(outage.nextProbeDelay, .seconds(1))

        let (again, againEffects) = PlaybackReducer.reduce(
            riding,
            event: .recovery(.rideThroughOutage(probeAfter: .seconds(2)), loadID),
            now: now
        )
        XCTAssertEqual(again, riding)
        XCTAssertTrue(againEffects.isEmpty)

        // Exit hands the kick back to the engine session.
        let (ended, endedEffects) = PlaybackReducer.reduce(
            riding,
            event: .recovery(.endOutageRideThrough(kick: true), loadID),
            now: now
        )
        XCTAssertEqual(playing(ended)?.sub, .steady)
        XCTAssertEqual(endedEffects, [
            .cancelTimer(.sourceOutageRideThrough),
            .runRecovery(.endOutageRideThrough(kick: true), loadID),
        ])
    }

    /// The visible server-outage recovery drops the engine and shows the
    /// reconnecting projection while it waits.
    func testServerOutageRecoveryDisposesTheEngineAndPolls() {
        let loadID = LoadID()
        let (next, effects) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID),
            event: .recovery(.recoverFromServerOutage(reason: "network_unavailable"), loadID),
            now: now
        )
        XCTAssertEqual(playing(next)?.sub, .recovering(.recoveringFromServerOutage))
        XCTAssertEqual(Array(effects.prefix(3)), [
            .cancelTimer(.progress),
            .disposeEngine(loadID),
            .pollServerHealth(.serverOutageRecovery, after: .seconds(1), loadID),
        ])
        guard case .publish(let presentation) = effects.last else {
            return XCTFail("expected a publish")
        }
        XCTAssertTrue(presentation.isReconnecting)
    }

    /// `attemptStaleSessionRenewal` (PVM:4225-4270): the visible renewal
    /// force-writes the content's progress, then re-loads the request rebuilt
    /// through `copyForRecovery` from the **live** selection — the selected
    /// version's file id, the resolved audio/subtitle/sidecar rows, no offline
    /// download and `startFromBeginning: false`.
    func testRenewSessionFreshSyncsProgressAndReloadsTheResolvedRequest() {
        let loadID = LoadID()
        let identity = makeIdentity()
        var request = makeRequest(offlineDownloadId: "download-1")
        request = PlayerViewModel.LoadRequest(
            contentId: request.contentId,
            preferredFileId: request.preferredFileId,
            preferredAudioTrackIndex: request.preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: request.preferredSubtitleTrackIndex,
            preferredSidecarSubtitleTrackId: request.preferredSidecarSubtitleTrackId,
            startFromBeginning: true,
            offlineDownloadId: "download-1"
        )
        // What the user changed after the load started.
        let selections = TrackResumeSelections(
            selectedFileId: 12,
            audioTrackIndex: 3,
            subtitleTrackIndex: -1,
            sidecarSubtitleTrackId: 55
        )

        let (next, effects) = PlaybackReducer.reduce(
            makePlaying(
                loadID: loadID,
                identity: identity,
                request: request,
                resumeSelections: selections
            ),
            event: .recovery(.renewSessionFresh(reason: "player_error"), loadID),
            now: now
        )

        guard case .preparing(let preparing) = next else { return XCTFail("expected preparing") }
        XCTAssertEqual(preparing.request.preferredFileId, 12, "currentSelectedVersion?.fileId wins")
        XCTAssertEqual(preparing.request.preferredAudioTrackIndex, 3)
        XCTAssertEqual(preparing.request.preferredSubtitleTrackIndex, -1, "the Off sentinel survives")
        XCTAssertEqual(preparing.request.preferredSidecarSubtitleTrackId, 55)
        XCTAssertNil(preparing.request.offlineDownloadId, "a renewal is a server session")
        XCTAssertFalse(
            preparing.request.startFromBeginning,
            "copyForRecovery must not re-honour Start Over against the resume override"
        )
        XCTAssertEqual(preparing.adoption, .freshLoad(.recovery))
        XCTAssertEqual(preparing.options.resumePosition, 100)
        XCTAssertTrue(preparing.options.allowNearEndResume)
        XCTAssertTrue(preparing.options.preserveInterruptionState)
        // The force-overwrite progress write runs first (PVM:4262-4267).
        XCTAssertEqual(
            effects.first,
            .syncProgress(
                contentId: "content-1",
                position: 100,
                duration: 1000,
                forceOverwrite: true,
                loadID
            )
        )
        // A recovery load keeps the outage timer and the interruption timer.
        XCTAssertFalse(effects.contains(.cancelTimer(.serverOutageRecovery)))
        XCTAssertFalse(effects.contains(.cancelTimer(.interruptionRecovery)))
        XCTAssertTrue(effects.contains(.disposeEngine(loadID)))
    }

    /// The one mutation that rewrites `Playing.identity` needs its own guard:
    /// a renewal mints a new server session by definition, so
    /// `belongsToSameSession` cannot be it. PVM:4123-4130 re-checks
    /// `activePlaybackSessionId == staleSessionId` instead, which is the
    /// identity the renewal was issued against.
    func testRenewalAnswerIsGuardedByTheIdentityItWasIssuedAgainst() throws {
        let loadID = LoadID()
        let identity = makeIdentity()
        let (renewing, _) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID, identity: identity),
            event: .recovery(.renewSourceInBackground(reason: "progress"), loadID),
            now: now
        )
        let renewedIdentity = makeIdentity(session: "session-2", attempt: "apple:attempt-2")

        let (stale, staleEffects) = PlaybackReducer.reduce(
            renewing,
            event: .session(
                .renewed(
                    try makePreparedRef(),
                    replacing: makeIdentity(session: "session-0", attempt: "apple:attempt-0")
                ),
                renewedIdentity
            ),
            now: now
        )
        XCTAssertEqual(stale, renewing, "an answer to a superseded renewal never lands")
        XCTAssertTrue(staleEffects.isEmpty)

        let (adopted, adoptedEffects) = PlaybackReducer.reduce(
            renewing,
            event: .session(.renewed(try makePreparedRef(), replacing: identity), renewedIdentity),
            now: now
        )
        XCTAssertEqual(playing(adopted)?.identity, renewedIdentity)
        XCTAssertEqual(playing(adopted)?.sub, .steady)
        XCTAssertTrue(adoptedEffects.isEmpty)

        // The *failure* answer is guarded by the same identity (design §4 I2):
        // a load can cycle and start a second renewal while the first one's
        // failure is still in flight, and that stale answer must not clear the
        // new renewal's single-flight slot.
        let (staleFailure, staleFailureEffects) = PlaybackReducer.reduce(
            renewing,
            event: .session(
                .renewalFailed(transient: true),
                makeIdentity(session: "session-0", attempt: "apple:attempt-0")
            ),
            now: now
        )
        XCTAssertEqual(staleFailure, renewing)
        XCTAssertTrue(staleFailureEffects.isEmpty)

        let (released, releasedEffects) = PlaybackReducer.reduce(
            renewing,
            event: .session(.renewalFailed(transient: true), identity),
            now: now
        )
        XCTAssertEqual(playing(released)?.sub, .steady)
        XCTAssertTrue(releasedEffects.isEmpty)
    }

    /// `onDurationChange` (PVM:1265-1278) never adopts a backend duration
    /// under a `.transcode` delivery — a growing transcode playlist reports the
    /// published length, which is shorter than the real one — and otherwise
    /// only adopts one that does not go backwards.
    func testBackendDurationIsAdoptedOnlyWhenThePurePredicateAllowsIt() {
        func duration(after reported: Double, delivery: PlaybackDeliveryStrategy) -> Double? {
            let loadID = LoadID()
            let plan = ExecutablePlan.serverHLS(
                ServerHLSPlan(
                    manifestURL: URL(string: "https://example.invalid/master.m3u8")!,
                    headers: [:],
                    startMode: .startOfManifest,
                    delivery: delivery
                )
            )
            let (next, _) = PlaybackReducer.reduce(
                makePlaying(
                    loadID: loadID,
                    plan: plan,
                    transport: TransportState(positionSeconds: 100, durationSeconds: 1000)
                ),
                event: .engine(.duration(seconds: reported), loadID),
                now: now
            )
            return playing(next)?.transport.durationSeconds
        }

        XCTAssertEqual(duration(after: 1200, delivery: .remux), 1200, "a longer duration is adopted")
        XCTAssertEqual(duration(after: 800, delivery: .remux), 1000, "a shorter one is not")
        XCTAssertEqual(duration(after: 1200, delivery: .transcode), 1000, "transcode never adopts")
        XCTAssertEqual(duration(after: .nan, delivery: .direct), 1000)
        XCTAssertEqual(duration(after: 0, delivery: .direct), 1000)
    }

    /// `activeQualityId` is the adopted label (PVM:2619) and it persists.
    /// Deriving it from the replan intent cleared the label the user sees on
    /// every steady-state publish, and set it before the server agreed.
    func testActiveQualityIdIsPublishedFromTheAdoptedValueNotTheReplanIntent() {
        let state = makePlaying(activeQualityId: "1080p")
        XCTAssertEqual(PlaybackReducer.presentation(for: state).activeQualityId, "1080p")
        XCTAssertFalse(PlaybackReducer.presentation(for: state).isQualitySwitching)

        let (switching, _) = PlaybackReducer.reduce(state, intent: .changeQuality("4k"), now: now)
        let presentation = PlaybackReducer.presentation(for: switching)
        XCTAssertEqual(presentation.activeQualityId, "1080p", "still the adopted label")
        XCTAssertTrue(presentation.isQualitySwitching)
    }

    /// A recovery decision for a superseded load never lands.
    func testRecoveryForASupersededLoadIsIgnored() {
        let state = makePlaying()
        let (next, effects) = PlaybackReducer.reduce(
            state,
            event: .recovery(.reassertPlay, LoadID()),
            now: now
        )
        XCTAssertEqual(next, state)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - Scene phase, suspend and resume

    /// The three background tables (`handleScenePhase` PVM:4711-4794), driven
    /// through the platform parameter so all three run in this iOS-only bundle:
    /// iOS pauses unless AirPlay or PiP owns playback, macOS always pauses,
    /// tvOS suspends the whole load.
    func testScenePhaseBackgroundFollowsThePlatformTable() {
        let loadID = LoadID()
        let identity = makeIdentity()
        let state = makePlaying(loadID: loadID, identity: identity)

        // iOS: pause, unless a route or PiP is carrying playback.
        let (iOSNext, iOSEffects) = PlaybackReducer.scenePhase(
            state,
            phase: .background,
            platform: .iOS,
            now: now
        )
        XCTAssertEqual(iOSEffects, [.transport(.pause, loadID)])
        XCTAssertEqual(playing(iOSNext)?.transport.isPaused, true)

        let airplay = makePlaying(
            loadID: loadID,
            transport: TransportState(positionSeconds: 100, isExternalPlaybackActive: true)
        )
        let (airplayNext, airplayEffects) = PlaybackReducer.scenePhase(
            airplay,
            phase: .background,
            platform: .iOS,
            now: now
        )
        XCTAssertEqual(airplayNext, airplay, "AirPlay plays on the receiver")
        XCTAssertTrue(airplayEffects.isEmpty)

        let pip = makePlaying(
            loadID: loadID,
            transport: TransportState(positionSeconds: 100, isPictureInPictureEngaged: true)
        )
        let (pipNext, pipEffects) = PlaybackReducer.scenePhase(
            pip,
            phase: .background,
            platform: .iOS,
            now: now
        )
        XCTAssertEqual(pipNext, pip, "PiP (engaged, i.e. active or transitioning) keeps its window")
        XCTAssertTrue(pipEffects.isEmpty)

        // macOS: always pause (design §7 item 6 — recorded, not changed).
        let (macNext, macEffects) = PlaybackReducer.scenePhase(
            state,
            phase: .background,
            platform: .macOS,
            now: now
        )
        XCTAssertEqual(macEffects, [.transport(.pause, loadID)])
        XCTAssertEqual(playing(macNext)?.transport.isPaused, true)
        let (macAirplayNext, macAirplayEffects) = PlaybackReducer.scenePhase(
            airplay,
            phase: .background,
            platform: .macOS,
            now: now
        )
        XCTAssertEqual(macAirplayEffects, [.transport(.pause, loadID)], "macOS has no exemptions")
        XCTAssertEqual(playing(macAirplayNext)?.transport.isPaused, true)

        // tvOS: suspend the load, dispose the engine, stop the session.
        let (tvNext, tvEffects) = PlaybackReducer.scenePhase(
            state,
            phase: .background,
            platform: .tvOS,
            now: now
        )
        guard case .suspended(let context) = tvNext else { return XCTFail("expected suspended") }
        XCTAssertEqual(context.resumePosition, 100)
        XCTAssertTrue(tvEffects.contains(.disposeEngine(loadID)))
        XCTAssertTrue(tvEffects.contains(.stopSession(identity, position: 100, isPaused: true)))
        for timer in [
            TimerID.interruptionRecovery, .sourceOutageRideThrough, .serverOutageRecovery,
            .backgroundRenewal, .staleSessionRecovery, .freshLoad, .protocolV3Replan,
            .progress, .seekFilterTimeout,
        ] {
            XCTAssertTrue(tvEffects.contains(.cancelTimer(timer)), "\(timer) must be cancelled")
        }
    }

    /// `makeSuspendedPlaybackContext` (PVM:3645-3651) rebuilds the request
    /// through `copyForRecovery` from the **live** selection, so backgrounding
    /// the Apple TV after changing the audio track resumes on that track.
    func testTVOSSuspendStoresTheResolvedRequest() {
        let request = makeRequest(offlineDownloadId: "download-1")
        let selections = TrackResumeSelections(
            selectedFileId: 12,
            audioTrackIndex: 3,
            subtitleTrackIndex: 4,
            sidecarSubtitleTrackId: 55
        )
        let (next, _) = PlaybackReducer.scenePhase(
            makePlaying(request: request, resumeSelections: selections),
            phase: .background,
            platform: .tvOS,
            now: now
        )
        guard case .suspended(let context) = next else { return XCTFail("expected suspended") }
        XCTAssertEqual(context.request.preferredAudioTrackIndex, 3)
        XCTAssertEqual(context.request.preferredSubtitleTrackIndex, 4)
        XCTAssertEqual(context.request.preferredSidecarSubtitleTrackId, 55)
        XCTAssertEqual(
            context.request.preferredFileId,
            request.preferredFileId,
            "the suspend keeps the request's file id; only the renewal prefers the selected version"
        )
        XCTAssertEqual(
            context.request.offlineDownloadId,
            "download-1",
            "a suspended offline load resumes offline"
        )
        XCTAssertFalse(context.request.startFromBeginning)
    }

    /// The inactive and active phases: only tvOS has an interruption table;
    /// iOS and macOS leave the load alone.
    func testScenePhaseInactiveFollowsThePlatformTable() {
        let state = makePlaying()
        let loadID = playing(state)!.loadID

        let (tvNext, tvEffects) = PlaybackReducer.scenePhase(
            state,
            phase: .inactive,
            platform: .tvOS,
            now: now
        )
        XCTAssertEqual(playing(tvNext)?.interruption?.wasPlaying, true)
        XCTAssertEqual(playing(tvNext)?.interruption?.isPending, true)
        XCTAssertEqual(playing(tvNext)?.transport.isPaused, true)
        XCTAssertEqual(tvEffects, [.cancelTimer(.interruptionRecovery), .transport(.pause, loadID)])

        // A paused player has nothing to interrupt.
        let paused = makePlaying(
            loadID: loadID,
            transport: TransportState(isPaused: true, positionSeconds: 100, durationSeconds: 1000)
        )
        let (pausedNext, pausedEffects) = PlaybackReducer.scenePhase(
            paused,
            phase: .inactive,
            platform: .tvOS,
            now: now
        )
        XCTAssertEqual(pausedNext, paused)
        XCTAssertTrue(pausedEffects.isEmpty)

        for platform in [ScenePhasePlatform.iOS, .macOS] {
            let (next, effects) = PlaybackReducer.scenePhase(
                state,
                phase: .inactive,
                platform: platform,
                now: now
            )
            XCTAssertEqual(next, state, "\(platform) ignores inactive")
            XCTAssertTrue(effects.isEmpty)
        }
    }

    /// tvOS `.active`: a pending transient interruption resumes with the
    /// overlay up and arms the recovery deadline; a suspended player awaits an
    /// explicit resume; iOS/macOS do nothing the control plane owns.
    func testScenePhaseActiveFollowsThePlatformTable() {
        let loadID = LoadID()
        let interrupted = makePlaying(
            loadID: loadID,
            transport: TransportState(isPaused: true, positionSeconds: 100, durationSeconds: 1000),
            interruption: Playing.Interruption(
                wasPlaying: true,
                positionSeconds: 100,
                recoveryDeadline: now,
                didAutoRecover: false,
                isPending: true
            )
        )

        let (tvNext, tvEffects) = PlaybackReducer.scenePhase(
            interrupted,
            phase: .active,
            platform: .tvOS,
            now: now
        )
        XCTAssertEqual(playing(tvNext)?.transport.isPaused, false)
        XCTAssertEqual(
            playing(tvNext)?.interruption?.recoveryDeadline,
            now.addingTimeInterval(3),
            "interruptionRecoveryTimeout"
        )
        XCTAssertEqual(tvEffects.count, 3)
        guard case .publish(let presentation) = tvEffects.first else {
            return XCTFail("expected the loading publish")
        }
        XCTAssertTrue(presentation.isLoading, "isLoading = true; error = nil")
        XCTAssertNil(presentation.error)
        XCTAssertEqual(tvEffects[1], .transport(.play, loadID))
        XCTAssertEqual(tvEffects[2], .schedule(.interruptionRecovery, after: .seconds(3), loadID))

        // A suspended player is not woken by the scene phase on any platform.
        let suspended = PlaybackState.suspended(
            SuspendedContext(request: makeRequest(), resumePosition: 617)
        )
        for platform in ScenePhasePlatform.allCases {
            let (next, effects) = PlaybackReducer.scenePhase(
                suspended,
                phase: .active,
                platform: platform,
                now: now
            )
            XCTAssertEqual(next, suspended, "\(platform) awaits an explicit resume")
            XCTAssertTrue(effects.isEmpty)

            // A steady load has no pending interruption, so `.active` is a
            // no-op everywhere.
            let (steadyNext, steadyEffects) = PlaybackReducer.scenePhase(
                makePlaying(loadID: loadID),
                phase: .active,
                platform: platform,
                now: now
            )
            XCTAssertTrue(steadyEffects.isEmpty, "\(platform): nothing pending, nothing to do")
            XCTAssertEqual(steadyNext.loadID, loadID)
        }
    }

    /// The intent entry point uses the platform the bundle is compiled for, so
    /// the table above is what actually runs on this host (iOS).
    func testScenePhaseIntentUsesTheHostPlatformTable() {
        let loadID = LoadID()
        let state = makePlaying(loadID: loadID)
        let (viaIntent, intentEffects) = PlaybackReducer.reduce(
            state,
            intent: .scenePhase(.background),
            now: now
        )
        let (viaTable, tableEffects) = PlaybackReducer.scenePhase(
            state,
            phase: .background,
            platform: .current,
            now: now
        )
        XCTAssertEqual(viaIntent, viaTable)
        XCTAssertEqual(intentEffects, tableEffects)
        XCTAssertEqual(ScenePhasePlatform.current, .iOS, "SiloTests is an iOS-only bundle")
    }

    /// Backgrounding mid-replan must resume the live playhead, not 0.
    /// `makeSuspendedPlaybackContext` (PVM:3652) snapshots `currentTime`, and
    /// neither `resetPublishedLoadState` nor a replan clears it, so the
    /// replacement `Preparing` carries it — and after the adopt it carries the
    /// replacement session's position.
    func testSuspendDuringAReplanKeepsTheLivePlayhead() throws {
        let loadID = LoadID()
        let state = makePlaying(
            loadID: loadID,
            transport: TransportState(positionSeconds: 617, durationSeconds: 1000)
        )
        let (replanning, _) = PlaybackReducer.reduce(
            state,
            intent: .changeQuality("1080p"),
            now: now
        )
        let (preparing, _) = PlaybackReducer.reduce(
            replanning,
            event: .session(
                .replanned(try makePreparedRef(position: 617), makePlan()),
                makeIdentity()
            ),
            now: now
        )

        let (next, _) = PlaybackReducer.scenePhase(
            preparing,
            phase: .background,
            platform: .tvOS,
            now: now
        )
        guard case .suspended(let context) = next else { return XCTFail("expected suspended") }
        XCTAssertEqual(context.resumePosition, 617)
        XCTAssertEqual(context.request.contentId, makeRequest().contentId)

        // And the replacement engine starts playing from there, not from 0 —
        // which is what the `fileLoaded` transport seeding is for.
        let (playingAgain, _) = PlaybackReducer.reduce(
            preparing,
            event: .engine(.fileLoaded(reason: "status_ready"), preparing.loadID!),
            now: now
        )
        XCTAssertEqual(playing(playingAgain)?.transport.positionSeconds, 617)
        XCTAssertEqual(playing(playingAgain)?.transport.durationSeconds, 1000)
    }

    /// `suspendForBackground` (PVM:7592-7594) needs only `lastLoadRequest`,
    /// which the terminal path keeps — so tvOS suspends from the error screen
    /// too, and the wake path (PVM:4720-4724) awaits an explicit resume. The
    /// failure rides on the context so the projection keeps publishing it.
    func testSuspendFromTheErrorScreenKeepsTheRequestAndTheFailure() {
        let loadID = LoadID()
        let failure = PlaybackFailure(legacyMessage: "The stream could not be played.")
        let (failed, _) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID),
            event: .recovery(.fail(failure), loadID),
            now: now
        )

        let (next, _) = PlaybackReducer.scenePhase(
            failed,
            phase: .background,
            platform: .tvOS,
            now: now
        )
        guard case .suspended(let context) = next else { return XCTFail("expected suspended") }
        XCTAssertEqual(context.request.contentId, makeRequest().contentId)
        XCTAssertEqual(context.resumePosition, 100)
        XCTAssertEqual(context.failure, failure)
        XCTAssertEqual(PlaybackReducer.presentation(for: next).error, failure.legacyMessage)

        for platform in [ScenePhasePlatform.iOS, .macOS] {
            let (other, effects) = PlaybackReducer.scenePhase(
                failed,
                phase: .background,
                platform: platform,
                now: now
            )
            XCTAssertEqual(other, failed, "only tvOS suspends on background")
            XCTAssertTrue(effects.isEmpty)
        }
    }

    /// `preserveInterruptionState` has to actually preserve it: the pending
    /// interruption rides the recovery load (PVM:3691-3693) so the first
    /// forward time report can complete it (PVM:3976-3996). Without the slot
    /// the completion could never fire and the loading overlay would stick.
    func testPreservedInterruptionSurvivesTheRecoveryLoadAndCompletes() throws {
        let loadID = LoadID()
        let state = makePlaying(
            loadID: loadID,
            interruption: Playing.Interruption(
                wasPlaying: true,
                positionSeconds: 100,
                recoveryDeadline: now,
                didAutoRecover: false,
                isPending: true
            )
        )

        let (loading, _) = PlaybackReducer.reduce(
            state,
            event: .recovery(.autoRecoverInterruption, loadID),
            now: now
        )
        guard case .preparing(let preparing) = loading else { return XCTFail("expected preparing") }
        XCTAssertTrue(preparing.options.preserveInterruptionState)
        XCTAssertEqual(preparing.interruption?.didAutoRecover, true)

        let (prepared, _) = PlaybackReducer.reduce(
            loading,
            event: .session(
                .prepared(try makePreparedRef(), makePlan(), for: preparing.loadID),
                makeIdentity()
            ),
            now: now
        )
        let (playingAgain, _) = PlaybackReducer.reduce(
            prepared,
            event: .engine(.fileLoaded(reason: "status_ready"), preparing.loadID),
            now: now
        )
        XCTAssertEqual(playing(playingAgain)?.interruption?.isPending, true)

        let (completed, effects) = PlaybackReducer.reduce(
            playingAgain,
            event: .engine(.time(seconds: 100.2), preparing.loadID),
            now: now
        )
        XCTAssertNil(playing(completed)?.interruption)
        XCTAssertTrue(effects.contains(.cancelTimer(.interruptionRecovery)))

        // A load that does not preserve it drops it, as `beginFreshLoad` does.
        let (plainLoad, _) = PlaybackReducer.reduce(
            state,
            intent: .load(makeRequest(), origin: .userInitiated, options: LoadOptions()),
            now: now
        )
        guard case .preparing(let plain) = plainLoad else { return XCTFail("expected preparing") }
        XCTAssertNil(plain.interruption)
    }

    /// Resuming a suspended player replays the stored request at the stored
    /// position (`resumeSuspendedPlayback`), on every platform — tvOS reaches
    /// it through `togglePlayPause` as well.
    func testSuspendedPlayerResumesTheStoredRequest() {
        let context = SuspendedContext(request: makeRequest(), resumePosition: 617)
        let state = PlaybackState.suspended(context)

        for intent in [PlayerIntent.resumeSuspended, .togglePlayPause] {
            let (next, effects) = PlaybackReducer.reduce(state, intent: intent, now: now)
            guard case .preparing(let preparing) = next else {
                return XCTFail("expected preparing for \(intent)")
            }
            XCTAssertEqual(preparing.request, context.request)
            XCTAssertEqual(preparing.options.resumePosition, 617)
            XCTAssertTrue(preparing.options.allowNearEndResume)
            XCTAssertNil(preparing.options.progressPosition, "suspend already stopped the session")
            XCTAssertTrue(
                effects.contains { if case .startSession = $0 { return true } else { return false } }
            )
        }
    }

    // MARK: - Transport and dismissal

    func testPlayPauseEmitsATransportCommandAndPublishes() {
        let loadID = LoadID()
        let (paused, pauseEffects) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID),
            intent: .pause,
            now: now
        )
        XCTAssertEqual(playing(paused)?.transport.isPaused, true)
        XCTAssertEqual(pauseEffects.first, .transport(.pause, loadID))
        guard case .publish(let pausedPresentation) = pauseEffects.last else {
            return XCTFail("expected a publish")
        }
        XCTAssertFalse(pausedPresentation.isPlaying)

        let (resumed, resumeEffects) = PlaybackReducer.reduce(paused, intent: .togglePlayPause, now: now)
        XCTAssertEqual(playing(resumed)?.transport.isPaused, false)
        XCTAssertEqual(resumeEffects.first, .transport(.play, loadID))
    }

    func testDismissCancelsEveryTimerStopsTheSessionAndDisposes() {
        let loadID = LoadID()
        let identity = makeIdentity()
        let (next, effects) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID, identity: identity),
            intent: .dismiss,
            now: now
        )

        XCTAssertEqual(next, .disposed)
        for timer in TimerID.allCases {
            XCTAssertTrue(effects.contains(.cancelTimer(timer)), "\(timer) must be cancelled")
        }
        XCTAssertTrue(effects.contains(.disposeEngine(loadID)))
        XCTAssertTrue(effects.contains(.stopSession(identity, position: 100, isPaused: true)))

        // A disposed player accepts nothing else.
        let (afterLoad, loadEffects) = PlaybackReducer.reduce(
            next,
            intent: .load(makeRequest(), origin: .userInitiated, options: LoadOptions()),
            now: now
        )
        XCTAssertEqual(afterLoad, .disposed)
        XCTAssertTrue(loadEffects.isEmpty)
    }

    // MARK: - Progress

    func testProgressTimerReportsAndReschedulesItself() {
        let loadID = LoadID()
        let identity = makeIdentity()
        let (next, effects) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID, identity: identity),
            event: .timer(.progress, loadID),
            now: now
        )
        XCTAssertEqual(effects, [
            .reportProgress(identity, position: 100, isPaused: false),
            .schedule(.progress, after: .seconds(10), loadID),
        ])
        XCTAssertEqual(playing(next)?.transport.positionSeconds, 100)
    }

    // MARK: - Purity

    /// No `Date()`, no I/O: the same inputs produce the same outputs, and the
    /// only non-determinism (a minted `LoadID`) is confined to the state.
    func testReducerIsDeterministicForTheSameInputs() {
        let state = makePlaying()
        let first = PlaybackReducer.reduce(state, intent: .seek(targetSeconds: 300, origin: .skip), now: now)
        let second = PlaybackReducer.reduce(state, intent: .seek(targetSeconds: 300, origin: .skip), now: now)
        // The seek id is minted per request, so compare everything else.
        guard let firstRequest = playing(first.0)?.seek,
              let secondRequest = playing(second.0)?.seek else {
            return XCTFail("expected two seek requests")
        }
        XCTAssertEqual(firstRequest.fromSeconds, secondRequest.fromSeconds)
        XCTAssertEqual(firstRequest.targetSeconds, secondRequest.targetSeconds)
        XCTAssertEqual(firstRequest.deadline, secondRequest.deadline)
        XCTAssertEqual(first.1.count, second.1.count)
    }

    // MARK: - ExecutablePlan

    func testExecutablePlanResolvesEveryEngineAndOnlyThrowsForALoopbackWithoutASession() throws {
        let request = StreamRequest(
            url: URL(string: "https://example.invalid/stream")!,
            headers: ["Authorization": "Bearer x"],
            serverUrl: "https://example.invalid"
        )

        func plan(
            engine: PlaybackEngineKind,
            loopbackSession: LoopbackSessionSpec?,
            startMode: PlaybackStartMode
        ) -> PlaybackExecutionPlan {
            PlaybackExecutionPlan(
                delivery: engine == .siloPlayerLoopback ? .direct : .transcode,
                engine: engine,
                startMode: startMode,
                streamRequest: request,
                loopbackSession: loopbackSession,
                requirements: .baseline,
                parityBlockers: [],
                decisionTrace: [],
                degradationWarnings: [],
                reason: "test"
            )
        }

        let native = try ExecutablePlan(
            plan(engine: .avPlayerNativeDirect, loopbackSession: nil, startMode: .absolutePosition(30)),
            request: request
        )
        XCTAssertEqual(native, .nativeDirect(
            NativeDirectPlan(
                url: request.url,
                headers: request.headers,
                startSeconds: 30,
                delivery: .transcode
            )
        ))
        XCTAssertEqual(native.engine, .avPlayerNativeDirect)
        XCTAssertEqual(native.delivery, .transcode, "the planner's delivery rides the plan")

        let hls = try ExecutablePlan(
            plan(engine: .avPlayerHLS, loopbackSession: nil, startMode: .startOfManifest),
            request: request
        )
        XCTAssertEqual(hls, .serverHLS(
            ServerHLSPlan(
                manifestURL: request.url,
                headers: request.headers,
                startMode: .startOfManifest,
                delivery: .transcode
            )
        ))
        XCTAssertEqual(hls.startSeconds, 0, "a remux manifest is anchored server-side")

        let spec = makeSessionSpec(sourceStartTimeSeconds: 42)
        let loopback = try ExecutablePlan(
            plan(engine: .siloPlayerLoopback, loopbackSession: spec, startMode: .absolutePosition(42)),
            request: request
        )
        XCTAssertEqual(loopback, .localHLS(LocalHLSPlan(sessionSpec: spec, startSeconds: 42)))
        XCTAssertNotEqual(
            loopback,
            .localHLS(LocalHLSPlan(sessionSpec: makeSessionSpec(sourceStartTimeSeconds: 0), startSeconds: 42)),
            "the spec takes part in equality"
        )
        XCTAssertNotEqual(
            loopback,
            .localHLS(LocalHLSPlan(sessionSpec: spec, startSeconds: 42, delivery: .transcode)),
            "so does the delivery"
        )

        XCTAssertThrowsError(
            try ExecutablePlan(
                plan(engine: .siloPlayerLoopback, loopbackSession: nil, startMode: .startOfManifest),
                request: request
            )
        ) { error in
            XCTAssertEqual(error as? PlaybackEngineLoadError, .missingLoopbackSession)
        }
    }

    // MARK: - Identity

    func testSessionIdentityMatchesTheSessionAcrossAReplanButNotAcrossASession() {
        let original = makeIdentity()
        let replanned = makeIdentity(planAttempt: "apple-plan:2", planAttemptKey: "plan-key-2")
        let renewed = makeIdentity(session: "session-2", attempt: "apple:attempt-2")

        XCTAssertTrue(replanned.belongsToSameSession(as: original))
        XCTAssertFalse(renewed.belongsToSameSession(as: original))
        XCTAssertNotEqual(replanned, original)

        let offline = SessionIdentity.offline()
        XCTAssertNil(offline.serverSessionId)
        XCTAssertTrue(offline.playbackAttemptId.hasPrefix("offline:"))
        XCTAssertNotEqual(SessionIdentity.offline(), offline)
    }

    /// `LoadRequest`'s `Equatable` conformance is hand-written (the type is
    /// nested in `PlayerViewModel`, so it cannot be synthesized from the
    /// control plane). If a stored property is added, extend both.
    func testLoadRequestEqualityCoversEveryStoredProperty() {
        let mirrored = Set(Mirror(reflecting: makeRequest()).children.compactMap(\.label))
        XCTAssertEqual(mirrored, [
            "contentId",
            "preferredFileId",
            "preferredAudioTrackIndex",
            "preferredSubtitleTrackIndex",
            "preferredSidecarSubtitleTrackId",
            "startFromBeginning",
            "preferredProtocolV3SubtitleIndex",
            "offlineDownloadId",
            "preferredQualityOverride",
        ])

        var changed = makeRequest()
        changed.preferredProtocolV3SubtitleIndex = 4
        XCTAssertNotEqual(changed, makeRequest())
        XCTAssertEqual(makeRequest(), makeRequest())
    }
}
