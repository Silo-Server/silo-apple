import Foundation
import XCTest
@testable import Silo

/// Stage 2 wave 3: the control plane's one owner, driven end to end.
///
/// `PlaybackReducerTests` pins the decision function; these pin the *routing* —
/// that an intent becomes the right effects in the right order, that an event
/// belonging to a superseded load changes nothing, and that the two pieces of
/// state the actor holds because no session can (design §2.8's wave-2b
/// disclosed gaps) behave the way the view model's did before wave 2b.
///
/// The actor is built with `shell: nil`. `PlayerViewModel` is the only shell
/// there is and the suite has never been able to construct one (inventory-4
/// A.0: `PlayerViewModel(` is 0 hits), so the main-actor arms — the engine
/// install, the transport commands, the publish — are no-ops here and
/// `recordedEffects` is what proves they were routed. Every effect that does
/// *not* need the shell (the bridge reports, the timers) really runs, against a
/// real `PlaybackSessionBridge` over `FakePlaybackTransport`.
final class PlaybackSessionActorTests: XCTestCase {

    // MARK: - Fresh load

    func testFreshLoadReachesPlayingAndSchedulesTheProgressHeartbeat() async throws {
        let actor = try makeActor()
        let request = makeRequest()

        await actor.send(.load(request, origin: .userInitiated, options: LoadOptions()))
        let loadID = try unwrap(await actor.currentState().loadID)
        guard case .preparing(let preparing) = await actor.currentState() else {
            return XCTFail("expected .preparing")
        }
        XCTAssertEqual(preparing.phase, .resolvingSession)
        let started0 = await effects(actor)
        XCTAssertTrue(started0.contains { effect in
            if case .startSession(_, _, let id) = effect { return id == loadID }
            return false
        })

        let identity = makeIdentity()
        await actor.ingest(
            .session(.prepared(try makePreparedRef(), makePlan(), for: loadID), identity)
        )
        // The plan arrives with the prepared session, so the load goes straight
        // to `.startingEngine` and the engine load is issued.
        guard case .preparing(let started) = await actor.currentState() else {
            return XCTFail("expected .preparing")
        }
        XCTAssertEqual(started.phase, .startingEngine)
        let started1 = await effects(actor)
        XCTAssertTrue(started1.contains { effect in
            if case .loadEngine(_, let id, let reuse) = effect { return id == loadID && !reuse }
            return false
        })

        await actor.ingestEngineEvent(.fileLoaded(reason: "test"), loadID: loadID)
        guard case .playing(let playing) = await actor.currentState() else {
            return XCTFail("expected .playing")
        }
        XCTAssertEqual(playing.loadID, loadID)
        XCTAssertEqual(playing.identity, identity)
        let started2 = await effects(actor)
        XCTAssertTrue(started2.contains(
            .schedule(.progress, after: .seconds(PlaybackReducer.progressReportIntervalSeconds), loadID)
        ))
    }

    /// The rewrite of `PlaybackProtocolV3Tests`'
    /// `testStaleStreamGenerationCannotConsumePendingTrackIntent`, which pinned
    /// `PlayerViewModel.isCurrentStreamCallback` — the by-value generation
    /// compare this wave deleted. Same contract, expressed over `LoadID`.
    func testStaleLoadEventIsIgnored() async throws {
        let actor = try makeActor()
        let loadID = try await startPlaying(actor)

        let superseded = LoadID()
        await actor.ingest(.engine(.time(seconds: 500), superseded))
        guard case .playing(let playing) = await actor.currentState() else {
            return XCTFail("expected .playing")
        }
        XCTAssertEqual(playing.transport.positionSeconds, 0, accuracy: 0.001)

        await actor.ingest(.engine(.time(seconds: 12), loadID))
        guard case .playing(let advanced) = await actor.currentState() else {
            return XCTFail("expected .playing")
        }
        XCTAssertEqual(advanced.transport.positionSeconds, 12, accuracy: 0.001)
    }

    /// The engine-event pump applies the same guard from the other side: an
    /// event a *disposed* load's stream still owes cannot reach the reducer
    /// once a newer load has minted its own id.
    func testEngineEventForASupersededPumpIsIgnored() async throws {
        let actor = try makeActor()
        let loadID = try await startPlaying(actor)

        await actor.ingestEngineEvent(.time(seconds: 400), loadID: LoadID())
        guard case .playing(let playing) = await actor.currentState() else {
            return XCTFail("expected .playing")
        }
        XCTAssertEqual(playing.transport.positionSeconds, 0, accuracy: 0.001)
        XCTAssertEqual(playing.loadID, loadID)
    }

    // MARK: - Replan

    func testInPlaceReplanKeepsTheEngineAndMintsANewLoadID() async throws {
        let actor = try makeActor()
        let loadID = try await startPlaying(actor)
        let identity = try unwrap(await actor.currentState().identity)

        await actor.send(.changeQuality("1080p"))
        guard case .playing(let replanning) = await actor.currentState(),
              case .replanning = replanning.sub else {
            return XCTFail("expected .replanning")
        }

        await actor.clearRecordedEffects()
        await actor.ingest(
            .session(.replanned(try makePreparedRef(), makePlan()), identity)
        )
        // Same implementation route, so the live `AVPlayerBackend` survives
        // (design §4 I4) — but the load identity never does.
        let replanned = await effects(actor)
        let installed = replanned.compactMap { effect -> (LoadID, Bool)? in
            if case .loadEngine(_, let id, let reuse) = effect { return (id, reuse) }
            return nil
        }
        XCTAssertEqual(installed.count, 1)
        XCTAssertTrue(installed[0].1, "an unchanged route must reuse the engine")
        XCTAssertNotEqual(installed[0].0, loadID)
    }

    func testRouteChangeReplanRebuildsTheEngine() async throws {
        let actor = try makeActor()
        _ = try await startPlaying(actor)
        let identity = try unwrap(await actor.currentState().identity)

        await actor.send(.changeQuality("1080p"))
        await actor.clearRecordedEffects()
        await actor.ingest(
            .session(
                .replanned(try makePreparedRef(), makePlan(engine: .avPlayerHLS)),
                identity
            )
        )
        let rebuilt = await effects(actor)
        XCTAssertTrue(rebuilt.contains { effect in
            if case .loadEngine(_, _, let reuse) = effect { return !reuse }
            return false
        })
    }

    func testSecondReplanIsDroppedWhileOneIsInFlight() async throws {
        let actor = try makeActor()
        _ = try await startPlaying(actor)

        await actor.send(.changeQuality("1080p"))
        await actor.clearRecordedEffects()
        // A different rung, so the "already on this quality" guard cannot be
        // what refuses it: the single replan slot is.
        await actor.send(.changeQuality("720p"))
        let afterSecond = await effects(actor)
        XCTAssertFalse(afterSecond.contains { effect in
            if case .replan = effect { return true }
            return false
        })
    }

    // MARK: - Silent source renewal

    func testBackgroundRenewalIsSingleFlighted() async throws {
        let actor = try makeActor()
        let loadID = try await startPlaying(actor)

        await actor.ingest(.recovery(.renewSourceInBackground(reason: "player_error"), loadID))
        guard case .playing(let renewing) = await actor.currentState(),
              case .renewingSource = renewing.sub else {
            return XCTFail("expected .renewingSource")
        }
        await actor.clearRecordedEffects()
        await actor.ingest(.recovery(.renewSourceInBackground(reason: "proxy_404"), loadID))
        let afterSecondRenewal = await effects(actor)
        XCTAssertFalse(afterSecondRenewal.contains { effect in
            if case .renewSource = effect { return true }
            return false
        })
    }

    func testRenewalAnswerForASupersededSessionIsRefused() async throws {
        let actor = try makeActor()
        let loadID = try await startPlaying(actor)
        let identity = try unwrap(await actor.currentState().identity)

        await actor.ingest(.recovery(.renewSourceInBackground(reason: "player_error"), loadID))
        // An answer to a renewal that was issued against a *different* session.
        let stale = makeIdentity(session: "session-stale", attempt: "apple:attempt-stale")
        await actor.ingest(
            .session(.renewed(try makePreparedRef(), replacing: stale), makeIdentity(session: "session-2"))
        )
        guard case .playing(let playing) = await actor.currentState(),
              case .renewingSource = playing.sub else {
            return XCTFail("the in-flight renewal must survive a superseded answer")
        }
        XCTAssertEqual(playing.identity, identity)
    }

    // MARK: - Outage ride-through (design §2.8 wave-2b gap (b))

    func testOutageRideThroughKeepsItsDeadlineAcrossARouteChangeReplan() async throws {
        let actor = try makeActor()
        let loadID = try await startPlaying(actor)
        let identity = try unwrap(await actor.currentState().identity)

        await actor.ingest(.recovery(.rideThroughOutage(probeAfter: .zero), loadID))
        let entered = try unwrap(await actor.carriedOutage)

        // A route change retires the backend the ride-through was riding on.
        // Wave 2b dropped the ride-through with it; the actor-scoped carry is
        // what keeps the original 90 s deadline.
        await actor.send(.changeQuality("1080p"))
        await actor.ingest(
            .session(
                .replanned(try makePreparedRef(), makePlan(engine: .avPlayerHLS)),
                identity
            )
        )
        let replacement = try unwrap(await actor.currentState().loadID)
        await actor.ingestEngineEvent(.fileLoaded(reason: "test"), loadID: replacement)

        let carried = try unwrap(await actor.carriedOutage)
        XCTAssertEqual(carried.rideThroughStart, entered.rideThroughStart)
    }

    func testOutageRideThroughReentryKeepsTheOriginalDeadline() async throws {
        let actor = try makeActor()
        let loadID = try await startPlaying(actor)

        await actor.ingest(.recovery(.rideThroughOutage(probeAfter: .zero), loadID))
        let entered = try unwrap(await actor.carriedOutage)
        // The policy re-emits `.rideThroughOutage` after every probe as the
        // *continuation* of the loop, so re-entry must not restart the budget.
        await actor.ingest(.recovery(.rideThroughOutage(probeAfter: .seconds(2)), loadID))
        let continued = try unwrap(await actor.carriedOutage)
        XCTAssertEqual(continued.rideThroughStart, entered.rideThroughStart)
        XCTAssertEqual(continued.nextProbeDelay, 2, accuracy: 0.001)
    }

    func testEndingTheRideThroughReleasesTheCarriedHold() async throws {
        let actor = try makeActor()
        let loadID = try await startPlaying(actor)

        await actor.ingest(.recovery(.rideThroughOutage(probeAfter: .zero), loadID))
        let entered = await actor.carriedOutage
        XCTAssertNotNil(entered)
        await actor.ingest(.recovery(.endOutageRideThrough(kick: true), loadID))
        // Dropping the carry *is* the release of the `origin_outage` hold for
        // every session installed after this point (wave-3 obligation 3).
        let released = await actor.carriedOutage
        XCTAssertNil(released)
    }

    // MARK: - Post-outage suppression window (design §2.8 wave-2b gap (a))

    func testPostOutageSuppressionWindowSurvivesIntoTheReplacementLoad() async throws {
        let actor = try makeActor()
        let loadID = try await startPlaying(actor)

        await actor.ingest(.recovery(.recoverFromServerOutage(reason: "source_gone"), loadID))
        let raised = await actor.suppressesEngineFailuresAfterOutage
        XCTAssertTrue(raised)

        // The visible recovery waits the server out and then re-loads. Legacy's
        // `activeServerOutageRecoverySessionId` was view-model state, so the
        // window survived into the replacement load.
        await actor.send(.load(makeRequest(), origin: .recovery, options: LoadOptions()))
        let survived = await actor.suppressesEngineFailuresAfterOutage
        XCTAssertTrue(survived)
    }

    func testPostOutageSuppressionWindowReleasesAtTheReplacementFileLoaded() async throws {
        let actor = try makeActor()
        let loadID = try await startPlaying(actor)

        await actor.ingest(.recovery(.recoverFromServerOutage(reason: "source_gone"), loadID))
        await actor.send(.load(makeRequest(), origin: .recovery, options: LoadOptions()))
        let replacement = try unwrap(await actor.currentState().loadID)
        await actor.ingest(
            .session(.prepared(try makePreparedRef(), makePlan(), for: replacement), makeIdentity())
        )
        await actor.ingestEngineEvent(.fileLoaded(reason: "test"), loadID: replacement)
        // `handleFileLoaded` cancelled the outage-recovery slot, and the window
        // closes with it.
        let released = await actor.suppressesEngineFailuresAfterOutage
        XCTAssertFalse(released)
    }

    // MARK: - Scene phase

    func testScenePhaseSuspendRetainsTheProxyAndStopsTheSession() async throws {
        let actor = try makeActor()
        let loadID = try await startPlaying(actor)
        await actor.clearRecordedEffects()

        // The scene-phase rule takes the platform from `ScenePhasePlatform`;
        // `PlaybackReducerTests` drives all three tables, so what this asserts
        // is only that the actor routes the intent and runs what comes back.
        await actor.send(.scenePhase(.background))
        let ran = await effects(actor)
        guard case .macOS = ScenePhasePlatform.current else {
            // iOS/tvOS: the suspend disposes the engine and keeps the proxy.
            XCTAssertTrue(ran.contains { effect in
                if case .disposeEngine(let id, let cache) = effect {
                    return id == loadID && cache == .retainProxy
                }
                if case .transport(.pause, let id) = effect { return id == loadID }
                return false
            })
            return
        }
        XCTAssertTrue(ran.contains(.transport(.pause, loadID)))
    }

    // MARK: - Seeking

    func testSeekEmitsAnEngineSeekAndItsSafetyValve() async throws {
        let actor = try makeActor()
        let loadID = try await startPlaying(actor)
        await actor.clearRecordedEffects()

        await actor.send(.seek(targetSeconds: 120, origin: .user))
        let ran = await effects(actor)
        XCTAssertTrue(ran.contains { effect in
            if case .seek(let request, let id) = effect {
                return id == loadID && request.targetSeconds == 120
            }
            return false
        })
        XCTAssertTrue(ran.contains(
            .schedule(.seekFilterTimeout, after: .seconds(PlaybackReducer.seekFilterTimeoutSeconds), loadID)
        ))
    }

    /// Seeking past the loopback anchor rebuilds the stream instead of seeking
    /// it, so the re-anchor origin arms the filter and takes the safety valve
    /// down — and issues **no** engine seek (design §2.3 contract note (e)).
    func testSeekPastAnchorArmsTheFilterWithoutAnEngineSeek() async throws {
        let actor = try makeActor()
        let loadID = try await startPlaying(actor)
        await actor.clearRecordedEffects()

        await actor.send(.seek(targetSeconds: 30, origin: .reanchor))
        let ran = await effects(actor)
        XCTAssertFalse(ran.contains { effect in
            if case .seek = effect { return true }
            return false
        })
        XCTAssertTrue(ran.contains(.cancelTimer(.seekFilterTimeout)))
        guard case .playing(let playing) = await actor.currentState() else {
            return XCTFail("expected .playing")
        }
        XCTAssertEqual(playing.seek?.origin, .reanchor)
        XCTAssertEqual(playing.transport.positionSeconds, 30, accuracy: 0.001)
        XCTAssertEqual(playing.loadID, loadID)
    }

    // MARK: - Progress

    func testProgressTimerReportsAndRearms() async throws {
        let actor = try makeActor()
        let loadID = try await startPlaying(actor)
        let identity = try unwrap(await actor.currentState().identity)
        await actor.ingest(.engine(.time(seconds: 42), loadID))
        await actor.clearRecordedEffects()

        await actor.ingest(.timer(.progress, loadID))
        let ran = await effects(actor)
        XCTAssertTrue(ran.contains(
            .reportProgress(identity, position: 42, isPaused: false)
        ))
        XCTAssertTrue(ran.contains(
            .schedule(.progress, after: .seconds(PlaybackReducer.progressReportIntervalSeconds), loadID)
        ))
    }

    // MARK: - Terminal and teardown

    func testTerminalFailureCarriesTheIdentityAndPlayhead() async throws {
        let actor = try makeActor()
        let loadID = try await startPlaying(actor)
        let identity = try unwrap(await actor.currentState().identity)
        await actor.ingest(.engine(.time(seconds: 90), loadID))
        await actor.clearRecordedEffects()

        await actor.ingest(
            .recovery(.fail(PlaybackFailure(legacyMessage: "boom")), loadID)
        )
        let terminalState = await actor.currentState()
        guard case .failed(let failure, let failedLoad, let failedIdentity, let request, let position, _)
            = terminalState else {
            return XCTFail("expected .failed")
        }
        XCTAssertEqual(failure.legacyMessage, "boom")
        XCTAssertEqual(failedLoad, loadID)
        XCTAssertEqual(failedIdentity, identity)
        XCTAssertEqual(request?.contentId, "content-1")
        XCTAssertEqual(position, 90, accuracy: 0.001)
        // The terminal path lets the session lapse rather than stopping it.
        let terminal = await effects(actor)
        XCTAssertFalse(terminal.contains { effect in
            if case .stopSession = effect { return true }
            return false
        })
        XCTAssertTrue(terminal.contains(.disposeEngine(loadID, sourceCache: .discard)))
    }

    func testDismissCancelsEveryTimerAndDisposesTheEngine() async throws {
        let actor = try makeActor()
        let loadID = try await startPlaying(actor)
        let identity = try unwrap(await actor.currentState().identity)
        await actor.clearRecordedEffects()

        await actor.send(.dismiss)
        let disposed = await actor.currentState()
        XCTAssertEqual(disposed, .disposed)
        let ran = await effects(actor)
        let cancelled = ran.compactMap { effect -> TimerID? in
            if case .cancelTimer(let id) = effect { return id }
            return nil
        }
        for timer in TimerID.allCases {
            XCTAssertTrue(cancelled.contains(timer), "\(timer) was not cancelled")
        }
        XCTAssertTrue(ran.contains(.disposeEngine(loadID, sourceCache: .discard)))
        XCTAssertTrue(ran.contains { effect in
            if case .stopSession(let carried, _, _) = effect { return carried == identity }
            return false
        })
    }

    func testDisposedPlayerAcceptsNothingButDismiss() async throws {
        let actor = try makeActor()
        _ = try await startPlaying(actor)
        await actor.send(.dismiss)
        await actor.clearRecordedEffects()

        await actor.send(.play)
        await actor.send(.seek(targetSeconds: 10, origin: .user))
        await actor.send(.load(makeRequest(), origin: .userInitiated, options: LoadOptions()))
        let stillDisposed = await actor.currentState()
        XCTAssertEqual(stillDisposed, .disposed)
        let ran = await effects(actor)
        XCTAssertTrue(ran.isEmpty)
    }

    // MARK: - Harness

    private func makeActor() throws -> PlaybackSessionActor {
        let transport = FakePlaybackTransport(
            capability: try PlaybackV3FixtureTestSupport.decode(
                PlaybackV3CapabilityResponse.self,
                named: "capability_response",
                bundleClass: Self.self
            ),
            watchDetail: try makeWatchDetail()
        )
        return PlaybackSessionActor(
            bridge: PlaybackSessionBridge(
                transport: transport,
                capabilityGate: PlaybackV3CapabilityGate(transport: transport)
            ),
            shell: nil
        )
    }

    /// Drive a load all the way to `.playing`, the state most of these tests
    /// start from. The shell is absent, so the `.startSession` and
    /// `.loadEngine` effects are routed and then no-op; the session and engine
    /// answers are fed in by hand, exactly as the shell would.
    @discardableResult
    private func startPlaying(_ actor: PlaybackSessionActor) async throws -> LoadID {
        await actor.send(.load(makeRequest(), origin: .userInitiated, options: LoadOptions()))
        let loadID = try unwrap(await actor.currentState().loadID)
        await actor.ingest(
            .session(.prepared(try makePreparedRef(), makePlan(), for: loadID), makeIdentity())
        )
        await actor.ingestEngineEvent(.fileLoaded(reason: "test"), loadID: loadID)
        await actor.clearRecordedEffects()
        return loadID
    }

    private func effects(_ actor: PlaybackSessionActor) async -> [Effect] {
        await actor.recordedEffects
    }

    /// `XCTUnwrap` takes an autoclosure, which cannot carry an `await`; this
    /// takes the already-awaited value.
    private func unwrap<T>(
        _ value: T?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        try XCTUnwrap(value, file: file, line: line)
    }

    private func makeRequest(contentId: String = "content-1") -> LoadRequest {
        LoadRequest(
            contentId: contentId,
            preferredFileId: 7,
            preferredAudioTrackIndex: 1,
            preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: nil,
            startFromBeginning: false
        )
    }

    private func makeIdentity(
        session: String? = "session-1",
        attempt: String = "apple:attempt-1"
    ) -> SessionIdentity {
        SessionIdentity(
            serverSessionId: session,
            playbackAttemptId: attempt,
            planAttemptId: "apple-plan:1",
            planAttemptKey: "plan-key-1",
            outputContextId: "output-1"
        )
    }

    private func makePlan(engine: PlaybackEngineKind = .avPlayerNativeDirect) -> ExecutablePlan {
        switch engine {
        case .avPlayerNativeDirect:
            return .nativeDirect(
                NativeDirectPlan(
                    url: URL(string: "https://example.invalid/movie.mkv")!,
                    headers: [:],
                    startSeconds: 0
                )
            )
        case .avPlayerHLS:
            return .serverHLS(
                ServerHLSPlan(
                    manifestURL: URL(string: "https://example.invalid/master.m3u8")!,
                    headers: [:],
                    startMode: .startOfManifest
                )
            )
        case .siloPlayerLoopback:
            return .localHLS(
                LocalHLSPlan(
                    sessionSpec: LoopbackSessionSpec(
                        sourceURL: URL(string: "https://example.invalid/movie.mkv")!,
                        headers: [:],
                        sourceStartTimeSeconds: 0,
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
                    ),
                    startSeconds: 0
                )
            )
        }
    }

    private func makeWatchDetail() throws -> WatchDetail {
        let json = Data("""
        {
          "content_id": "content-1",
          "type": "movie",
          "title": "Test",
          "versions": [{"file_id": 7, "duration": 900}]
        }
        """.utf8)
        return try HTTPClient.makeJSONDecoder().decode(WatchDetail.self, from: json)
    }

    /// A minimal but *real* `PreparedPlaybackV3`, decoded rather than
    /// hand-built so the fixture cannot drift from the wire shape. It is what
    /// makes `Playing.hasProtocolV3` true, which is the precondition of both
    /// intents that mint a server replan.
    private func makePreparedV3() throws -> PreparedPlaybackV3 {
        let json = Data("""
        {
          "protocol_version": 3,
          "plan_id": "plan:fixture",
          "session_id": "session-1",
          "delivery": "original_http",
          "plan_attempt_key": "plan-key-1",
          "stream": {"url": "/stream/session-1", "protocol": "http_progressive",
                     "headers": {}, "header_refresh": "session"},
          "timeline": {"source_start_seconds": 0, "stream_origin_seconds": 0,
                       "player_start_seconds": 0, "timeline_offset_seconds": 0,
                       "can_seek_anywhere": true, "seek_restoration": "player_position"},
          "selected_tracks": {"audio": {"id": "file:7:audio:1", "index": 1}},
          "effective_recipe": {},
          "claims": {
            "video": {"hdr10": false, "hdr10_plus": false, "hlg": false, "dolby_vision": false},
            "audio": {"passthrough": false, "atmos_preserved": false},
            "subtitles": {"ass_styling_preserved": false, "bitmap_overlay": false,
                          "bitmap_sidecar": false}
          },
          "subtitle": {"mode": "external", "inventory": []},
          "transformations": [],
          "applied_quirks": [],
          "runtime_corrections": [],
          "degradation_warnings": [],
          "decision_reason": "validated_original_playback",
          "requested_media_file_id": 7,
          "effective_media_file_id": 7,
          "source": {"media_file_id": 7, "hdr10_plus": false,
                     "dv_enhancement_layer": "none"},
          "subtitle_fidelity_policy": "allow_simplified_rendering",
          "available_qualities": []
        }
        """.utf8)
        let plan = try HTTPClient.makeJSONDecoder().decode(PlaybackV3Plan.self, from: json)
        return PreparedPlaybackV3(
            playbackAttemptId: "apple:attempt-1",
            planAttemptId: "apple-plan:1",
            planAttemptKey: plan.planAttemptKey,
            outputContextId: "output-1",
            serverFeatures: [PlaybackProtocolV3.planFeature],
            plan: plan
        )
    }

    private func makePreparedRef(
        position: Double = 0,
        durationSeconds: Double? = 1000
    ) throws -> PreparedPlaybackRef {
        let watchDetail = try makeWatchDetail()
        return PreparedPlaybackRef(
            PreparedPlayback(
                watchDetail: watchDetail,
                selectedVersion: watchDetail.versions[0],
                session: PlaybackSessionResponse(
                    sessionId: "session-1",
                    userId: nil,
                    profileId: nil,
                    mediaFileId: 7,
                    playMethod: "direct",
                    position: position,
                    isPaused: false,
                    streamUrl: "https://example.invalid/movie.mkv",
                    audioTrackIndex: nil,
                    durationSeconds: durationSeconds,
                    timelineOffsetSeconds: 0,
                    subtitleUrls: nil,
                    playbackInfo: nil
                ),
                activeQualityId: ApplePlaybackQuality.autoId,
                protocolV3: try makePreparedV3()
            )
        )
    }
}
