import Foundation
import XCTest
@testable import Silo

/// Stage 2 wave 1: the control plane's decision function, pinned against the
/// view-model behaviour it replaces (`beginFreshLoad`, `adoptPreparedPlayback`,
/// `loadStream`, `attemptProtocolV3Replan`, `restartCurrentTranscodeHLS`,
/// `commitSeek`, `handleScenePhase`, `finalizeTerminalPlaybackError`).
///
/// The reducer is pure, so every test is `(state, input, now) -> (state,
/// effects)` with a fixed `now`. The `#if os(tvOS)` / `#if os(macOS)`
/// scene-phase branches are compile-verified by the SiloTV and SiloMac scheme
/// builds — `SiloTests` is an iOS-only bundle (`project.yml` `SiloTests`
/// `platform: iOS`), so the assertions below are the iOS table.
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

    private func makePreparedRef() throws -> PreparedPlaybackRef {
        let json = Data("""
        {
          "content_id": "content-1",
          "type": "movie",
          "title": "Test",
          "versions": [{"file_id": 7, "duration": 1000}]
        }
        """.utf8)
        let watchDetail = try HTTPClient.makeJSONDecoder().decode(WatchDetail.self, from: json)
        let session = PlaybackSessionResponse(
            sessionId: "session-1",
            userId: nil,
            profileId: nil,
            mediaFileId: 7,
            playMethod: "direct",
            position: 0,
            isPaused: false,
            streamUrl: "https://example.invalid/movie.mkv",
            audioTrackIndex: nil,
            durationSeconds: 1000,
            subtitleUrls: nil,
            playbackInfo: nil
        )
        return PreparedPlaybackRef(
            PreparedPlayback(
                watchDetail: watchDetail,
                selectedVersion: watchDetail.versions[0],
                session: session
            )
        )
    }

    private func makePlaying(
        loadID: LoadID = LoadID(),
        identity: SessionIdentity? = nil,
        plan: ExecutablePlan? = nil,
        adoption: PlaybackAdoption = .freshLoad(.userInitiated),
        transport: TransportState = TransportState(positionSeconds: 100, durationSeconds: 1000),
        sub: Sub = .steady,
        interruption: Playing.Interruption? = nil
    ) -> PlaybackState {
        .playing(
            Playing(
                loadID: loadID,
                identity: identity ?? makeIdentity(),
                plan: plan ?? makePlan(),
                request: makeRequest(),
                adoption: adoption,
                transport: transport,
                sub: sub,
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
        carriedPosition: Double = 0,
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
                carriedPosition: carriedPosition,
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
            event: .session(.prepared(try makePreparedRef(), plan, for: loadID), identity),
            now: now
        )

        XCTAssertEqual(effects, [.loadEngine(plan, loadID, reuseEngine: false)])
        guard case .preparing(let state) = next else { return XCTFail("expected preparing") }
        XCTAssertEqual(state.phase, .startingEngine)
        XCTAssertEqual(state.identity, identity)
        XCTAssertEqual(state.plan, plan)
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

    func testFileLoadedReportsPlanExecutionForAFreshLoad() throws {
        let loadID = LoadID()
        let identity = makeIdentity()
        let plan = makePlan()
        let state = makePreparing(loadID: loadID, identity: identity, plan: plan)

        let (next, effects) = PlaybackReducer.reduce(
            state,
            event: .engine(.fileLoaded(reason: "status_ready"), loadID),
            now: now
        )

        XCTAssertEqual(playing(next)?.sub, .steady)
        XCTAssertEqual(playing(next)?.plan, plan)
        XCTAssertEqual(Array(effects.prefix(3)), [
            .cancelTimer(.serverOutageRecovery),
            .reportPlanExecutionStarted(identity),
            .schedule(.progress, after: .seconds(10), loadID),
        ])
        guard case .publish(let presentation) = effects.last else {
            return XCTFail("expected a publish")
        }
        XCTAssertTrue(presentation.isPlaying)
    }

    /// `adoptPreparedPlayback`'s per-origin rule: a V3 replan reports plan
    /// execution, the in-place transcode restart deliberately never has.
    func testFileLoadedReportRuleFollowsTheAdoptionOrigin() {
        func effects(for adoption: PlaybackAdoption) -> [Effect] {
            let loadID = LoadID()
            let state = makePreparing(loadID: loadID, adoption: adoption)
            return PlaybackReducer.reduce(
                state,
                event: .engine(.fileLoaded(reason: "status_ready"), loadID),
                now: now
            ).1
        }

        XCTAssertTrue(
            effects(for: .replan(.serverReplan))
                .contains { if case .reportPlanExecutionStarted = $0 { return true } else { return false } }
        )
        XCTAssertFalse(
            effects(for: .replan(.transcodeRestart(.seekReanchor(origin: 100))))
                .contains { if case .reportPlanExecutionStarted = $0 { return true } else { return false } }
        )
        XCTAssertFalse(
            effects(for: .replan(.transcodeRestart(.qualityChange(qualityId: "1080p"))))
                .contains { if case .reportPlanExecutionStarted = $0 { return true } else { return false } }
        )
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
        XCTAssertEqual(effects, [.loadEngine(replacement, preparing.loadID, reuseEngine: true)])
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
            guard case .loadEngine(_, _, let reuseEngine) = effects.first else {
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

        guard case .seeking(let request) = playing(next)?.sub else {
            return XCTFail("expected a seek request")
        }
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
        XCTAssertEqual(playing(landed)?.sub, .steady)
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
        XCTAssertEqual(playing(next)?.sub, .steady)
        XCTAssertTrue(effects.isEmpty)
    }

    /// Review §11 #17/#5: a new load drops an outstanding seek structurally —
    /// there is no `.seeking` sub-state to carry, and the old `LoadID` no
    /// longer matches, so the late time report is ignored.
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
        XCTAssertEqual(playing(landed)?.sub, .steady)
        XCTAssertEqual(playing(landed)?.transport.positionSeconds, 12)
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

    func testFailStopsTheSessionAndPublishesTheError() {
        let loadID = LoadID()
        let identity = makeIdentity()
        let state = makePlaying(loadID: loadID, identity: identity)
        let failure = PlaybackFailure(legacyMessage: "The stream could not be played.")

        let (next, effects) = PlaybackReducer.reduce(
            state,
            event: .recovery(.fail(failure), loadID),
            now: now
        )

        guard case .failed(let recorded, let failedLoadID, let request, let position) = next else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(recorded, failure)
        XCTAssertEqual(failedLoadID, loadID)
        XCTAssertEqual(request, makeRequest(), "retry replays the last request")
        XCTAssertEqual(position, 100, "finalizeTerminalPlaybackError keeps currentTime")
        XCTAssertTrue(effects.contains(.disposeEngine(loadID)))
        XCTAssertTrue(effects.contains(.stopSession(identity, position: 100, isPaused: true)))
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
        guard case .failed(let failure, _, _, _) = next else { return XCTFail("expected failed") }
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

    /// `attemptStaleSessionRenewal`: the visible renewal is a fresh load of
    /// the same request at the observed position, as a recovery.
    func testRenewSessionFreshReloadsTheSameRequest() {
        let loadID = LoadID()
        let identity = makeIdentity()
        let (next, effects) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID, identity: identity),
            event: .recovery(.renewSessionFresh(reason: "player_error"), loadID),
            now: now
        )

        guard case .preparing(let preparing) = next else { return XCTFail("expected preparing") }
        XCTAssertEqual(preparing.request, makeRequest())
        XCTAssertEqual(preparing.adoption, .freshLoad(.recovery))
        XCTAssertEqual(preparing.options.resumePosition, 100)
        XCTAssertTrue(preparing.options.allowNearEndResume)
        XCTAssertTrue(preparing.options.preserveInterruptionState)
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

    /// The iOS background rule (`pauseBackgroundPlaybackIfUnrouted` and its
    /// AirPlay/PiP exemptions). tvOS suspends instead and macOS pauses
    /// unconditionally; both branches are compiled by their schemes.
    func testScenePhaseBackgroundFollowsThePlatformTable() {
        let loadID = LoadID()
        let state = makePlaying(loadID: loadID)
        let (next, effects) = PlaybackReducer.reduce(state, intent: .scenePhase(.background), now: now)

        #if os(iOS)
        XCTAssertEqual(effects, [.transport(.pause, loadID)])
        XCTAssertEqual(playing(next)?.transport.isPaused, true)

        let airplay = makePlaying(
            loadID: loadID,
            transport: TransportState(positionSeconds: 100, isExternalPlaybackActive: true)
        )
        let (airplayNext, airplayEffects) = PlaybackReducer.reduce(
            airplay,
            intent: .scenePhase(.background),
            now: now
        )
        XCTAssertEqual(airplayNext, airplay, "AirPlay plays on the receiver")
        XCTAssertTrue(airplayEffects.isEmpty)

        let pip = makePlaying(
            loadID: loadID,
            transport: TransportState(positionSeconds: 100, isPictureInPictureEngaged: true)
        )
        let (pipNext, pipEffects) = PlaybackReducer.reduce(
            pip,
            intent: .scenePhase(.background),
            now: now
        )
        XCTAssertEqual(pipNext, pip, "PiP (engaged, i.e. active or transitioning) keeps its window")
        XCTAssertTrue(pipEffects.isEmpty)
        #elseif os(macOS)
        XCTAssertEqual(effects, [.transport(.pause, loadID)])
        XCTAssertEqual(playing(next)?.transport.isPaused, true)
        #elseif os(tvOS)
        guard case .suspended(let context) = next else { return XCTFail("expected suspended") }
        XCTAssertEqual(context.resumePosition, 100)
        XCTAssertTrue(effects.contains(.disposeEngine(loadID)))
        XCTAssertTrue(effects.contains(.stopSession(makeIdentity(), position: 100, isPaused: true)))
        #endif
    }

    /// The inactive and active phases: only tvOS has an interruption table;
    /// iOS and macOS leave the load alone.
    func testScenePhaseInactiveFollowsThePlatformTable() {
        let state = makePlaying()
        let (next, effects) = PlaybackReducer.reduce(state, intent: .scenePhase(.inactive), now: now)

        #if os(tvOS)
        XCTAssertEqual(playing(next)?.interruption?.wasPlaying, true)
        XCTAssertEqual(playing(next)?.transport.isPaused, true)
        XCTAssertEqual(effects.last, .transport(.pause, playing(state)!.loadID))
        #else
        XCTAssertEqual(next, state)
        XCTAssertTrue(effects.isEmpty)
        #endif
    }

    /// Backgrounding mid-replan must resume the live playhead, not 0.
    /// `makeSuspendedPlaybackContext` (PVM:3652) snapshots `currentTime`, and
    /// neither `resetPublishedLoadState` nor a replan clears it, so the
    /// replacement `Preparing` carries it.
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
            event: .session(.replanned(try makePreparedRef(), makePlan()), makeIdentity()),
            now: now
        )

        let (next, _) = PlaybackReducer.reduce(preparing, intent: .scenePhase(.background), now: now)

        #if os(tvOS)
        guard case .suspended(let context) = next else { return XCTFail("expected suspended") }
        XCTAssertEqual(context.resumePosition, 617)
        XCTAssertEqual(context.request, makeRequest())
        #else
        XCTAssertEqual(next, preparing, "only tvOS suspends on background")
        #endif
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

        let (next, _) = PlaybackReducer.reduce(failed, intent: .scenePhase(.background), now: now)

        #if os(tvOS)
        guard case .suspended(let context) = next else { return XCTFail("expected suspended") }
        XCTAssertEqual(context.request, makeRequest())
        XCTAssertEqual(context.resumePosition, 100)
        XCTAssertEqual(context.failure, failure)
        XCTAssertEqual(PlaybackReducer.presentation(for: next).error, failure.legacyMessage)
        #else
        XCTAssertEqual(next, failed, "only tvOS suspends on background")
        #endif
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
        guard case .seeking(let firstRequest) = playing(first.0)?.sub,
              case .seeking(let secondRequest) = playing(second.0)?.sub else {
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
            NativeDirectPlan(url: request.url, headers: request.headers, startSeconds: 30)
        ))
        XCTAssertEqual(native.engine, .avPlayerNativeDirect)

        let hls = try ExecutablePlan(
            plan(engine: .avPlayerHLS, loopbackSession: nil, startMode: .startOfManifest),
            request: request
        )
        XCTAssertEqual(hls, .serverHLS(
            ServerHLSPlan(manifestURL: request.url, headers: request.headers, startMode: .startOfManifest)
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
