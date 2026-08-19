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
        fileId: Int = 7,
        protocolV3: PreparedPlaybackV3? = nil
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
                activeQualityId: activeQualityId,
                protocolV3: protocolV3
            )
        )
    }

    /// A minimal but *real* `PreparedPlaybackV3`, decoded rather than
    /// hand-built so the fixture cannot drift from the wire shape. The
    /// selected subtitle is an external sidecar, which is the branch of
    /// `LoadRequest.adoptingProtocolV3Intent` (PVM:885-918) that produces a
    /// sidecar track id and no embedded FFmpeg index — no `FileVersion`
    /// subtitle streams needed.
    private func makePreparedV3(
        effectiveMediaFileId: Int = 9,
        audioIndex: Int = 5,
        subtitleCombinedIndex: Int? = 3
    ) throws -> PreparedPlaybackV3 {
        var selectedSubtitle = ""
        var inventory = ""
        if let index = subtitleCombinedIndex {
            selectedSubtitle = #", "subtitle": {"id": "file:9:subtitle:\#(index)", "index": \#(index)}"#
            inventory = #"""
            {"track_id": "file:9:subtitle:\#(index)", "combined_index": \#(index),
             "source": "external", "forced": false, "default": false,
             "hearing_impaired": false, "delivery": "sidecar",
             "url": "https://example.invalid/subs.vtt"}
            """#
        }
        let json = Data("""
        {
          "protocol_version": 3,
          "plan_id": "plan:fixture",
          "session_id": "session-v3",
          "delivery": "original_http",
          "plan_attempt_key": "v3:opaque-fixture",
          "stream": {"url": "/stream/session-v3", "protocol": "http_progressive",
                     "headers": {}, "header_refresh": "session"},
          "timeline": {"source_start_seconds": 0, "stream_origin_seconds": 0,
                       "player_start_seconds": 0, "timeline_offset_seconds": 0,
                       "can_seek_anywhere": true, "seek_restoration": "player_position"},
          "selected_tracks": {"audio": {"id": "file:9:audio:\(audioIndex)", "index": \(audioIndex)}\(selectedSubtitle)},
          "effective_recipe": {},
          "claims": {
            "video": {"hdr10": false, "hdr10_plus": false, "hlg": false, "dolby_vision": false},
            "audio": {"passthrough": false, "atmos_preserved": false},
            "subtitles": {"ass_styling_preserved": false, "bitmap_overlay": false,
                          "bitmap_sidecar": false}
          },
          "subtitle": {"mode": "external", "inventory": [\(inventory)]},
          "transformations": [],
          "applied_quirks": [],
          "runtime_corrections": [],
          "degradation_warnings": [],
          "decision_reason": "validated_original_playback",
          "requested_media_file_id": \(effectiveMediaFileId),
          "effective_media_file_id": \(effectiveMediaFileId),
          "source": {"media_file_id": \(effectiveMediaFileId), "hdr10_plus": false,
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
        hasProtocolV3: Bool = true,
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
                hasProtocolV3: hasProtocolV3,
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
        hasProtocolV3: Bool = true,
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
                hasProtocolV3: hasProtocolV3,
                resumeSelections: resumeSelections ?? .seeded(from: makeRequest()),
                interruption: interruption
            )
        )
    }

    private func playing(_ state: PlaybackState) -> Playing? {
        guard case .playing(let playing) = state else { return nil }
        return playing
    }

    private func preparing(_ state: PlaybackState) -> Preparing? {
        guard case .preparing(let preparing) = state else { return nil }
        return preparing
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
            .disposeEngine(previous, sourceCache: .stash),
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

    /// `beginReanchorSeekUI` (PVM:5063-5076) arms the origin/target filter and
    /// moves the scrubber, with **no** safety timeout and **no** engine seek:
    /// the anchoring is the stream rebuild that follows (a `seek_reanchor`
    /// replan, a fresh load, or a re-anchored loopback `loadStream`), which is
    /// also what releases the filter. Seeking the outgoing item to a position
    /// it does not contain is exactly what the re-anchor exists to avoid.
    func testReanchorSeekArmsTheFilterWithoutSeekingTheEngine() {
        let (next, effects) = PlaybackReducer.reduce(
            makePlaying(),
            intent: .seek(targetSeconds: 300, origin: .reanchor),
            now: now
        )
        // `beginReanchorSeekUI` (PVM:5063-5076) issues no engine seek and arms
        // no timeout — and *cancels* the one an earlier plain seek may have
        // left running, because the re-anchor filter is released by the
        // rebuild that follows, not by a clock.
        XCTAssertEqual(effects, [.cancelTimer(.seekFilterTimeout)])
        guard let request = playing(next)?.seek else {
            return XCTFail("expected the filter to be armed")
        }
        XCTAssertEqual(request.origin, .reanchor)
        XCTAssertEqual(request.fromSeconds, 100)
        XCTAssertEqual(request.targetSeconds, 300)
        XCTAssertEqual(playing(next)?.transport.positionSeconds, 300)

        // And the filter still behaves: a drainage frame is dropped, the first
        // frame past the midpoint lands.
        let loadID = playing(next)!.loadID
        let (stale, _) = PlaybackReducer.reduce(
            next,
            event: .engine(.time(seconds: 140), loadID),
            now: now
        )
        XCTAssertEqual(playing(stale)?.transport.positionSeconds, 300)
        let (landed, _) = PlaybackReducer.reduce(
            next,
            event: .engine(.time(seconds: 260), loadID),
            now: now
        )
        XCTAssertNil(playing(landed)?.seek)
    }

    /// The cancel is not decoration: a plain seek arms the 5 s safety valve,
    /// and a re-anchor inside that window must take it back down — otherwise
    /// it fires mid-rebuild and drops the filter early, letting the outgoing
    /// item's drainage frames drag the scrubber off the anchor.
    func testAReanchorCancelsAFilterTimeoutAnEarlierSeekLeftArmed() {
        let (seeking, seekEffects) = PlaybackReducer.reduce(
            makePlaying(),
            intent: .seek(targetSeconds: 300, origin: .user),
            now: now
        )
        XCTAssertTrue(
            seekEffects.contains(
                .schedule(
                    .seekFilterTimeout,
                    after: .seconds(PlaybackReducer.seekFilterTimeoutSeconds),
                    playing(seeking)!.loadID
                )
            )
        )

        let (_, effects) = PlaybackReducer.reduce(
            seeking,
            intent: .seek(targetSeconds: 900, origin: .reanchor),
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(effects, [.cancelTimer(.seekFilterTimeout)])
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
            // "Keep watching" really seeks the item it is on; the reanchor only
            // arms the filter and lets the stream rebuild do the anchoring.
            XCTAssertEqual(
                effects.contains { if case .seek = $0 { return true } else { return false } },
                origin == .nextUpKeepWatching,
                "\(origin)"
            )
        }
    }

    // MARK: - End of file

    func testEndOfFileEntersTheEndedSubStateAndPauses() {
        let loadID = LoadID()
        let state = makePlaying(
            loadID: loadID,
            transport: TransportState(positionSeconds: 100, durationSeconds: 1000, isBuffering: true)
        )
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
        // `handleEndOfFile` clears all three published transport bits together
        // (PVM:3422-3424). The engine is drained, so no further
        // `.buffering(false)` can arrive to clear the capsule later.
        XCTAssertEqual(playing(next)?.transport.isBuffering, false)
        guard case .publish(let postroll) = effects.last else {
            return XCTFail("expected a publish")
        }
        XCTAssertFalse(postroll.isBuffering)
        XCTAssertFalse(postroll.isPlaying)
        XCTAssertFalse(postroll.isLoading)

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

        guard case .failed(let recorded, let failedLoadID, let failedIdentity, let request, let position, _) = next else {
            return XCTFail("expected failed")
        }
        XCTAssertEqual(recorded, failure)
        XCTAssertEqual(failedLoadID, loadID)
        XCTAssertEqual(
            failedIdentity,
            identity,
            "the bridge still holds the session; cleanup() and retry() both reach it"
        )
        XCTAssertEqual(request, makeRequest(), "retry replays the last request")
        XCTAssertEqual(position, 100, "finalizeTerminalPlaybackError keeps currentTime")
        XCTAssertTrue(effects.contains(.disposeEngine(loadID, sourceCache: .discard)))
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
        guard case .failed(let failure, _, _, _, _, _) = next else { return XCTFail("expected failed") }
        XCTAssertEqual(failure.legacyMessage, "No further playback plans are available.")
    }

    /// `retry()` PVM:4557-4566 replays the last request at `currentTime`,
    /// which `finalizeTerminalPlaybackError` deliberately keeps — Retry must
    /// resume where playback died, not restart the title.
    func testRetryResumesWherePlaybackDied() {
        let loadID = LoadID()
        let identity = makeIdentity()
        let (failed, _) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID, identity: identity),
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
        // `beginFreshLoad`'s `progressPosition` really is reported: the
        // terminal path never stopped the session, so the bridge still has it.
        XCTAssertTrue(
            effects.contains(.reportProgress(identity, position: 100, isPaused: true)),
            "retry() reports currentTime against the session that outlived the failure"
        )
    }

    /// `cleanup()` stops the server session whenever the load was not offline
    /// (PVM:6358/6404) — including from the error screen, because
    /// `finalizeTerminalPlaybackError` only drops the view model's
    /// `activePlaybackSessionId` mirror and never stops the session itself.
    func testDismissFromTheErrorScreenStillStopsTheSession() {
        let loadID = LoadID()
        let identity = makeIdentity()
        let (failed, failEffects) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID, identity: identity),
            event: .recovery(.fail(PlaybackFailure(legacyMessage: "boom")), loadID),
            now: now
        )
        XCTAssertFalse(
            failEffects.contains { if case .stopSession = $0 { return true } else { return false } },
            "the failure itself lets the session lapse"
        )

        let (next, effects) = PlaybackReducer.reduce(failed, intent: .dismiss, now: now)
        XCTAssertEqual(next, .disposed)
        XCTAssertTrue(effects.contains(.stopSession(identity, position: 100, isPaused: true)))
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

        // The remaining single-shot actions. They are spelled out in the
        // reducer's switch rather than caught by a `default:` — wave 2 owns
        // `RecoveryAction`, and a case it adds must fail to compile until
        // someone classifies it as single-shot or multi-step.
        let startupReload = run(.reloadStartupItem)
        XCTAssertEqual(startupReload.1, [.runRecovery(.reloadStartupItem, loadID)])
        XCTAssertEqual(playing(startupReload.0)?.sub, .recovering(.reloadingItem))

        for action: RecoveryAction in [
            .restartProducer(atSegmentIndex: 12, authoritative: true),
            .deferUntilPlay(mediaSeconds: 120),
            .resumePlayback,
        ] {
            let single = run(action)
            XCTAssertEqual(single.1, [.runRecovery(action, loadID)], "\(action)")
            XCTAssertEqual(playing(single.0)?.sub, .steady, "\(action)")
        }
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

    /// The visible server-outage recovery drops the engine, probes immediately
    /// (`waitForServerReady` PVM:4493-4504 probes before its first sleep) and
    /// shows the reconnecting projection while it waits.
    func testServerOutageRecoveryDisposesTheEngineAndPolls() {
        let loadID = LoadID()
        let (next, effects) = PlaybackReducer.reduce(
            makePlaying(loadID: loadID),
            event: .recovery(.recoverFromServerOutage(reason: "network_unavailable"), loadID),
            now: now
        )
        XCTAssertEqual(playing(next)?.sub, .recovering(.recoveringFromServerOutage))
        // PVM:4405-4410 supersedes the silent renewal and ends the
        // ride-through *before* the teardown: the actor performs
        // `retargetOrigin` inside `.renewSource` without coming back through
        // the reducer, so overwriting `Sub` is not enough to stop it, and the
        // ride-through poll would otherwise keep probing under a superseded
        // sub-state.
        XCTAssertEqual(Array(effects.prefix(5)), [
            .cancelTimer(.backgroundRenewal),
            .cancelTimer(.sourceOutageRideThrough),
            .cancelTimer(.progress),
            .disposeEngine(loadID, sourceCache: .stash),
            .pollServerHealth(.serverOutageRecovery, after: .zero, loadID),
        ])
        guard case .publish(let presentation) = effects.last else {
            return XCTFail("expected a publish")
        }
        XCTAssertTrue(presentation.isReconnecting)
        XCTAssertFalse(presentation.isPlaying, "PVM:4438 writes isPlaying = false by hand")
    }

    /// A `source_entity_changed` outage is the one reason whose cached prefix
    /// is *known* to belong to the replaced entity (PVM:4429-4432), so it
    /// must not be offered to the recovery plan. Every other reason stashes.
    func testServerOutageRecoveryDiscardsTheCacheOnlyForAChangedSourceEntity() {
        let loadID = LoadID()
        let cases: [(String, SourceCacheDisposition)] = [
            ("source_entity_changed", .discard),
            ("network_unavailable", .stash),
            ("server_unavailable_503", .stash),
            ("premature_eof", .stash),
        ]
        for (reason, expected) in cases {
            let (_, effects) = PlaybackReducer.reduce(
                makePlaying(loadID: loadID),
                event: .recovery(.recoverFromServerOutage(reason: reason), loadID),
                now: now
            )
            XCTAssertTrue(
                effects.contains(.disposeEngine(loadID, sourceCache: expected)),
                "\(reason) must dispose with \(expected)"
            )
        }
    }

    /// The four teardown sites disagree about the outgoing source proxy's
    /// cached prefix, and the effect has to carry the disagreement: a fresh
    /// load hands it on (PVM:2759/3524), the terminal path and `cleanup()`
    /// release it (PVM:4063/6386), and the tvOS suspend disposes only the
    /// backend and leaves the proxy — and its cache — running (PVM:7627).
    func testEveryDisposeSiteCarriesItsOwnSourceCacheDisposition() {
        func disposition(in effects: [Effect]) -> SourceCacheDisposition? {
            for effect in effects {
                if case .disposeEngine(_, let sourceCache) = effect { return sourceCache }
            }
            return nil
        }

        let loadID = LoadID()
        let state = makePlaying(loadID: loadID)

        let (_, load) = PlaybackReducer.reduce(
            state,
            intent: .load(makeRequest(contentId: "content-2"), origin: .userInitiated, options: LoadOptions()),
            now: now
        )
        XCTAssertEqual(disposition(in: load), .stash)

        let (_, failed) = PlaybackReducer.reduce(
            state,
            event: .recovery(.fail(PlaybackFailure(legacyMessage: "boom")), loadID),
            now: now
        )
        XCTAssertEqual(disposition(in: failed), .discard)

        let (_, dismissed) = PlaybackReducer.reduce(state, intent: .dismiss, now: now)
        XCTAssertEqual(disposition(in: dismissed), .discard)

        let (_, suspended) = PlaybackReducer.scenePhase(
            state,
            phase: .background,
            platform: .tvOS,
            now: now
        )
        XCTAssertEqual(disposition(in: suspended), .retainProxy)

        let (_, outage) = PlaybackReducer.reduce(
            state,
            event: .recovery(.recoverFromServerOutage(reason: "source_entity_changed"), loadID),
            now: now
        )
        XCTAssertEqual(disposition(in: outage), .discard)
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
        // The silent renewal is superseded first (PVM:4224-4227) so a late
        // `retargetOrigin` cannot land mid-teardown, then the force-overwrite
        // progress write (PVM:4262-4267).
        XCTAssertEqual(effects.first, .cancelTimer(.backgroundRenewal))
        XCTAssertEqual(
            effects.dropFirst().first,
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
        // A visible renewal is a fresh load, so it stashes like one.
        XCTAssertTrue(effects.contains(.disposeEngine(loadID, sourceCache: .stash)))
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
            event: .session(
                .renewed(
                    try makePreparedRef(durationSeconds: 1234, activeQualityId: "720p", fileId: 12),
                    replacing: identity
                ),
                renewedIdentity
            ),
            now: now
        )
        XCTAssertEqual(playing(adopted)?.identity, renewedIdentity)
        XCTAssertEqual(playing(adopted)?.sub, .steady)
        XCTAssertTrue(adoptedEffects.isEmpty)
        // A renewal can land on a re-probed source, so it adopts the renewed
        // session's duration, quality label and selected version too
        // (PVM:4142/4149-4151) — keeping the outgoing ones published a stale
        // scrubber length and a stale quality label for the rest of the load.
        XCTAssertEqual(playing(adopted)?.transport.durationSeconds, 1234)
        XCTAssertEqual(playing(adopted)?.activeQualityId, "720p")
        XCTAssertEqual(playing(adopted)?.resumeSelections.selectedFileId, 12)
        XCTAssertEqual(
            playing(adopted)?.transport.positionSeconds,
            100,
            "the retarget is silent; the playhead is not re-anchored"
        )
        // The `?? current` fallback: a renewal that reports no duration keeps
        // the one already published.
        let (noDuration, _) = PlaybackReducer.reduce(
            renewing,
            event: .session(
                .renewed(
                    try makePreparedRef(durationSeconds: nil, fileId: 7),
                    replacing: identity
                ),
                renewedIdentity
            ),
            now: now
        )
        XCTAssertEqual(
            playing(noDuration)?.transport.durationSeconds,
            900,
            "the selected version's duration is the first fallback"
        )

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

    /// `switchQuality` returns early when the resolved id already equals
    /// `activeQualityId` (PVM:4603-4608), so re-picking the rung that is
    /// playing issues no server call — and it resolves the id through
    /// `ApplePlaybackQuality.protocolV3QualityId` first, which is why "4k" and
    /// "2160p" are the same rung.
    func testChangingToTheActiveQualityIsANoOp() {
        let state = makePlaying(activeQualityId: ApplePlaybackQuality.ultraHDId)

        for id in ["2160p", "4K", "uhd"] {
            let (next, effects) = PlaybackReducer.reduce(
                state,
                intent: .changeQuality(id),
                now: now
            )
            XCTAssertEqual(next, state, "\(id) resolves to the active rung")
            XCTAssertTrue(effects.isEmpty)
        }

        let (switching, effects) = PlaybackReducer.reduce(
            state,
            intent: .changeQuality("1080p"),
            now: now
        )
        guard case .replanning(let intent) = playing(switching)?.sub else {
            return XCTFail("expected the replanning sub-state")
        }
        XCTAssertEqual(intent.qualityPreference, "1080p")
        XCTAssertTrue(intent.completesQualitySwitch)
        XCTAssertFalse(effects.isEmpty)
    }

    /// `adoptProtocolV3RenewalIntent` (PVM:2589/3596-3607): every adopt
    /// rewrites `lastLoadRequest` from the plan the server just authorised.
    /// The two fields that only live there — `preferredQualityOverride` and
    /// the authoritative `preferredProtocolV3SubtitleIndex` — are carried by
    /// `copyForRecovery` from its *receiver* (PVM:860-880), so a request
    /// frozen at `.load` drops the user's mid-stream quality choice and the
    /// server's subtitle ordinal out of every replay: tvOS suspend/resume,
    /// visible renewal, outage recovery, interruption recovery and Retry. Both
    /// are wire arguments to `startSession`
    /// (PlaybackSessionBridge.swift:401-511).
    func testAQualitySwitchIsReplayedAfterATvOSSuspendAndResume() throws {
        let identity = makeIdentity()
        let state = makePlaying(identity: identity)
        XCTAssertNil(playing(state)?.request.preferredQualityOverride)

        // 1. The user picks 720p mid-stream.
        let (replanning, _) = PlaybackReducer.reduce(
            state,
            intent: .changeQuality("720p"),
            now: now
        )

        // 2. The server answers with the authorised plan.
        let prepared = try makePreparedRef(
            activeQualityId: "720p",
            fileId: 9,
            protocolV3: makePreparedV3(effectiveMediaFileId: 9, audioIndex: 5, subtitleCombinedIndex: 3)
        )
        let (preparing, _) = PlaybackReducer.reduce(
            replanning,
            event: .session(.replanned(prepared, makePlan()), identity),
            now: now
        )
        guard case .preparing(let adopting) = preparing else { return XCTFail("expected preparing") }
        XCTAssertEqual(adopting.request.preferredQualityOverride, "720p")
        XCTAssertEqual(adopting.request.preferredProtocolV3SubtitleIndex, 3)
        XCTAssertEqual(adopting.request.preferredFileId, 9, "plan.effectiveMediaFileId")
        XCTAssertEqual(adopting.request.preferredAudioTrackIndex, 5)
        XCTAssertEqual(
            adopting.request.preferredSidecarSubtitleTrackId,
            SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 3)
        )
        XCTAssertTrue(adopting.hasProtocolV3)

        // 3. The replacement stream plays.
        let (playingAgain, _) = PlaybackReducer.reduce(
            preparing,
            event: .engine(.fileLoaded(reason: "replan"), adopting.loadID),
            now: now
        )
        XCTAssertEqual(playing(playingAgain)?.request.preferredQualityOverride, "720p")

        // 4. The Apple TV backgrounds and is resumed. `copyForRecovery` keeps
        //    both fields from the adopted request, so `startSession` asks the
        //    server for the switched rung and the same subtitle ordinal again.
        let (suspended, _) = PlaybackReducer.scenePhase(
            playingAgain,
            phase: .background,
            platform: .tvOS,
            now: now
        )
        guard case .suspended(let context) = suspended else { return XCTFail("expected suspended") }
        XCTAssertEqual(context.request.preferredQualityOverride, "720p")
        XCTAssertEqual(context.request.preferredProtocolV3SubtitleIndex, 3)

        let (_, resumeEffects) = PlaybackReducer.reduce(suspended, intent: .resumeSuspended, now: now)
        guard case .startSession(let replayed, _, _) = resumeEffects.last else {
            return XCTFail("expected the replacement session start")
        }
        XCTAssertEqual(replayed.preferredQualityOverride, "720p")
        XCTAssertEqual(replayed.preferredProtocolV3SubtitleIndex, 3)
    }

    /// The same adoption runs on a fresh prepare and on a silent renewal —
    /// `adoptPreparedPlayback` calls it at PVM:2589 and
    /// `attemptBackgroundSessionRenewal` at PVM:4146 — and it is skipped for
    /// an offline load, whose request has no server plan to adopt
    /// (PVM:3596-3600).
    func testTheReplayRequestIsAdoptedOnPrepareAndOnRenewalButNotWhenOffline() throws {
        let identity = makeIdentity()
        let prepared = try makePreparedRef(
            activeQualityId: "1080p",
            fileId: 9,
            protocolV3: makePreparedV3()
        )

        let loadID = LoadID()
        let (prepareNext, _) = PlaybackReducer.reduce(
            makePreparing(loadID: loadID, identity: nil, phase: .resolvingSession, plan: makePlan()),
            event: .session(.prepared(prepared, makePlan(), for: loadID), identity),
            now: now
        )
        guard case .preparing(let adopted) = prepareNext else { return XCTFail("expected preparing") }
        XCTAssertEqual(adopted.request.preferredQualityOverride, "1080p")
        XCTAssertEqual(adopted.request.preferredProtocolV3SubtitleIndex, 3)
        XCTAssertTrue(adopted.hasProtocolV3)

        // A silent renewal can land on a re-probed source, so it adopts too.
        let renewing = makePlaying(identity: identity, sub: .renewingSource(
            SourceRenewal(
                reason: "progress",
                observedPosition: 100,
                startedAt: now,
                issuedFor: identity
            )
        ))
        let renewedIdentity = makeIdentity(session: "session-2")
        let (renewed, _) = PlaybackReducer.reduce(
            renewing,
            event: .session(.renewed(prepared, replacing: identity), renewedIdentity),
            now: now
        )
        XCTAssertEqual(playing(renewed)?.request.preferredQualityOverride, "1080p")
        XCTAssertEqual(playing(renewed)?.request.preferredProtocolV3SubtitleIndex, 3)

        // Offline: no server plan, so the request is left exactly as it was.
        let offlineLoadID = LoadID()
        let offlineRequest = makeRequest(offlineDownloadId: "download-1")
        let (offlinePreparing, _) = PlaybackReducer.reduce(
            .idle,
            intent: .load(offlineRequest, origin: .userInitiated, options: LoadOptions()),
            now: now
        )
        _ = offlineLoadID
        guard let startedID = offlinePreparing.loadID else { return XCTFail("expected a LoadID") }
        let (offlineAdopted, _) = PlaybackReducer.reduce(
            offlinePreparing,
            event: .session(
                .prepared(prepared, makePlan(), for: startedID),
                SessionIdentity.offline()
            ),
            now: now
        )
        guard case .preparing(let offline) = offlineAdopted else { return XCTFail("expected preparing") }
        XCTAssertEqual(offline.request, offlineRequest, "an offline request adopts nothing")
        XCTAssertTrue(offline.hasProtocolV3, "the prepare itself still carried a plan")
    }

    /// Both intents that mint a server replan need a *live* V3 plan:
    /// `switchQuality` only takes the replan branch when
    /// `activePreparedProtocolV3 != nil` (PVM:4600-4622) and the route
    /// observer guards on the same field before it samples the snapshot
    /// (PVM:1082-1086). `SessionIdentity.offline()` publishes
    /// `outputContextId: ""`, which no real snapshot equals, so without the
    /// bit an offline load would find every route notification "material".
    func testAnOfflineLoadIgnoresTheQualityAndRouteIntents() {
        let offline = makePlaying(
            identity: SessionIdentity.offline(),
            request: makeRequest(offlineDownloadId: "download-1"),
            hasProtocolV3: false
        )

        let (afterQuality, qualityEffects) = PlaybackReducer.reduce(
            offline,
            intent: .changeQuality("720p"),
            now: now
        )
        XCTAssertEqual(afterQuality, offline)
        XCTAssertTrue(qualityEffects.isEmpty)

        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        let (afterRoute, routeEffects) = PlaybackReducer.reduce(
            offline,
            intent: .outputRouteChanged(snapshot),
            now: now
        )
        XCTAssertEqual(afterRoute, offline)
        XCTAssertTrue(routeEffects.isEmpty)

        // With a live V3 plan the same route change is material and replans.
        let online = makePlaying(identity: makeIdentity(outputContext: "stale-output"))
        let (_, onlineEffects) = PlaybackReducer.reduce(
            online,
            intent: .outputRouteChanged(snapshot),
            now: now
        )
        XCTAssertTrue(onlineEffects.contains { effect in
            if case .replan(let intent, _) = effect {
                return intent.classification == "output_route_changed"
            }
            return false
        })
    }

    /// The two replan pipelines have different prologues.
    /// `attemptProtocolV3Replan` cancels the heartbeat and raises the overlay;
    /// `restartCurrentTranscodeHLS` takes the fresh-load slot instead and
    /// reports progress against the outgoing session at the position it is
    /// leaving (PVM:5234-5236) before the round trip.
    func testTranscodeRestartReportsProgressAgainstTheOutgoingSession() {
        let identity = makeIdentity()
        let state = makePlaying(identity: identity)

        // No intent mints a `.transcodeRestart` yet (wave 3 does), so the
        // shared replan entry point is called directly.
        func restart(_ origin: TranscodeRestartOrigin, position: Double) -> [Effect] {
            PlaybackReducer.requestReplan(
                playing(state)!,
                intent: ReplanIntent(
                    kind: .transcodeRestart(origin),
                    position: position,
                    classification: "quality_changed",
                    message: "m"
                )
            ).1
        }

        // A quality restart leaves from where it is.
        let quality = restart(.qualityChange(qualityId: "720p"), position: 100)
        XCTAssertEqual(quality.first, .reportProgress(identity, position: 100, isPaused: true))
        XCTAssertFalse(
            quality.contains(.cancelTimer(.progress)),
            "the transcode restart does not cancel the heartbeat"
        )
        XCTAssertFalse(
            quality.contains { if case .publish = $0 { return true } else { return false } },
            "the quality restart raises the overlay at the adopt, not at the request"
        )
        guard case .replan(let replanned, let replanIdentity)? = quality.last else {
            return XCTFail("expected the replan")
        }
        XCTAssertEqual(replanIdentity, identity)
        XCTAssertEqual(replanned.kind, .transcodeRestart(.qualityChange(qualityId: "720p")))

        // A seek re-anchor carries the position it is leaving.
        let reanchor = restart(.seekReanchor(origin: 42), position: 900)
        XCTAssertEqual(reanchor.first, .reportProgress(identity, position: 42, isPaused: true))

        // The same `origin.isFinite && origin >= 0` guard the view model has.
        let negative = restart(.seekReanchor(origin: -1), position: 900)
        XCTAssertFalse(
            negative.contains { if case .reportProgress = $0 { return true } else { return false } }
        )
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
        // `pauseBackgroundPlaybackIfUnrouted` (PVM:4829-4835) issues the pause
        // and leaves `isPlaying` to `onPauseChange`, like every other pause
        // site — see `testPlayPauseIssuesTheCommandAndLetsPauseChangedBeTheSoleWriter`.
        XCTAssertEqual(iOSNext, state, "no optimistic transport write")

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
        XCTAssertEqual(macNext, state, "no optimistic transport write")
        let (macAirplayNext, macAirplayEffects) = PlaybackReducer.scenePhase(
            airplay,
            phase: .background,
            platform: .macOS,
            now: now
        )
        XCTAssertEqual(macAirplayEffects, [.transport(.pause, loadID)], "macOS has no exemptions")
        XCTAssertEqual(macAirplayNext, airplay, "no optimistic transport write")

        // tvOS: suspend the load, dispose the engine, stop the session.
        let (tvNext, tvEffects) = PlaybackReducer.scenePhase(
            state,
            phase: .background,
            platform: .tvOS,
            now: now
        )
        guard case .suspended(let context) = tvNext else { return XCTFail("expected suspended") }
        XCTAssertEqual(context.resumePosition, 100)
        XCTAssertTrue(tvEffects.contains(.disposeEngine(loadID, sourceCache: .retainProxy)))
        XCTAssertTrue(tvEffects.contains(.stopSession(identity, position: 100, isPaused: true)))
        for timer in [
            TimerID.interruptionRecovery, .sourceOutageRideThrough, .serverOutageRecovery,
            .backgroundRenewal, .staleSessionRecovery, .freshLoad, .protocolV3Replan,
            .progress, .seekFilterTimeout,
        ] {
            XCTAssertTrue(tvEffects.contains(.cancelTimer(timer)), "\(timer) must be cancelled")
        }
        // `suspendForBackground` clears the buffering capsule and the loading
        // overlay and drops `isPlaying` (PVM:7616-7623) after the sweep and
        // before the dispose. A suspended load produces no further engine
        // ticks to coalesce, so without this publish the wake screen keeps the
        // pre-suspend projection.
        guard let publishIndex = tvEffects.firstIndex(where: {
            if case .publish = $0 { return true } else { return false }
        }) else {
            return XCTFail("expected the suspend publish")
        }
        guard case .publish(let suspendPresentation) = tvEffects[publishIndex] else {
            return XCTFail("expected a publish")
        }
        XCTAssertFalse(suspendPresentation.isPlaying)
        XCTAssertFalse(suspendPresentation.isLoading)
        XCTAssertFalse(suspendPresentation.isBuffering)
        XCTAssertEqual(suspendPresentation.currentTime, 100)
        XCTAssertLessThan(
            publishIndex,
            tvEffects.firstIndex(of: .disposeEngine(loadID, sourceCache: .retainProxy))!,
            "published before the dispose, as suspendForBackground does"
        )

        // The same holds when the suspend interrupts a load: the overlay the
        // load raised must not survive the wake.
        let (tvFromLoad, tvFromLoadEffects) = PlaybackReducer.scenePhase(
            makePreparing(loadID: loadID, identity: identity),
            phase: .background,
            platform: .tvOS,
            now: now
        )
        guard case .suspended = tvFromLoad else { return XCTFail("expected suspended") }
        guard case .publish(let fromLoadPresentation)? = tvFromLoadEffects.first(where: {
            if case .publish = $0 { return true } else { return false }
        }) else {
            return XCTFail("expected the suspend publish")
        }
        XCTAssertFalse(fromLoadPresentation.isLoading)
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
        // `pauseForForegroundInterruptionIfNeeded` (PVM:7571-7589) records the
        // interruption and calls `pause()`; `isPlaying` stays `onPauseChange`'s.
        XCTAssertEqual(playing(tvNext)?.transport, playing(state)?.transport)
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
        // The `.active` arm sets only `isLoading = true; error = nil`
        // (PVM:4728-4730) before `play()`; the resulting `onPauseChange` is
        // what republishes `isPlaying`.
        XCTAssertEqual(playing(tvNext)?.transport, playing(interrupted)?.transport)
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

        // This wake resumes the *same* stream, so there is no `fileLoaded` to
        // complete the interruption: `onTimeChange`'s
        // `completeInterruptionRecoveryIfNeeded(requiresForwardProgress: true)`
        // (PVM:3976-3996) does, once the playhead really moved forward.
        let (stillPending, stillPendingEffects) = PlaybackReducer.reduce(
            tvNext,
            event: .engine(.time(seconds: 100.05), loadID),
            now: now
        )
        XCTAssertEqual(playing(stillPending)?.interruption?.isPending, true, "under the 0.1 s threshold")
        XCTAssertFalse(stillPendingEffects.contains(.cancelTimer(.interruptionRecovery)))
        let (recovered, recoveredEffects) = PlaybackReducer.reduce(
            tvNext,
            event: .engine(.time(seconds: 100.2), loadID),
            now: now
        )
        XCTAssertNil(playing(recovered)?.interruption)
        XCTAssertTrue(recoveredEffects.contains(.cancelTimer(.interruptionRecovery)))

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

        let (next, suspendEffects) = PlaybackReducer.scenePhase(
            failed,
            phase: .background,
            platform: .tvOS,
            now: now
        )
        guard case .suspended(let context) = next else { return XCTFail("expected suspended") }
        XCTAssertEqual(context.request.contentId, makeRequest().contentId)
        XCTAssertEqual(context.resumePosition, 100)
        XCTAssertEqual(context.failure, failure)
        // `suspendForBackground`'s stop is unconditional (PVM:7634-7637), and
        // the failure never stopped the session — so it is still reachable.
        XCTAssertTrue(
            suspendEffects.contains(.stopSession(makeIdentity(), position: 100, isPaused: true))
        )
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
    /// interruption rides the recovery load (PVM:3691-3693) so that
    /// `handleFileLoaded` can complete it —
    /// `completeInterruptionRecoveryIfNeeded(requiresForwardProgress: false)`
    /// (PVM:1513-1516), i.e. the replacement stream reaching `fileLoaded`
    /// **is** the recovery landing. Without the slot the completion could
    /// never fire and the loading overlay would stick.
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
        let (playingAgain, fileLoadedEffects) = PlaybackReducer.reduce(
            prepared,
            event: .engine(.fileLoaded(reason: "status_ready"), preparing.loadID),
            now: now
        )
        XCTAssertNil(
            playing(playingAgain)?.interruption,
            "fileLoaded completes it; it does not wait for a forward time report"
        )
        XCTAssertTrue(fileLoadedEffects.contains(.cancelTimer(.interruptionRecovery)))
        // A scene `.active` in the window after fileLoaded must therefore find
        // nothing pending — it would otherwise re-publish the overlay and
        // re-arm the timer where the view model does neither.
        let (afterWake, wakeEffects) = PlaybackReducer.scenePhase(
            playingAgain,
            phase: .active,
            platform: .tvOS,
            now: now
        )
        XCTAssertEqual(afterWake, playingAgain)
        XCTAssertTrue(wakeEffects.isEmpty)

        // A load that does not preserve it drops it, as `beginFreshLoad` does.
        let (plainLoad, _) = PlaybackReducer.reduce(
            state,
            intent: .load(makeRequest(), origin: .userInitiated, options: LoadOptions()),
            now: now
        )
        guard case .preparing(let plain) = plainLoad else { return XCTFail("expected preparing") }
        XCTAssertNil(plain.interruption)
    }

    /// The three tvOS interruption arms are **state-agnostic** in the view
    /// model and must be here too. `pauseForForegroundInterruptionIfNeeded`
    /// (PVM:7571-7589) guards only on `!isBackgroundSuspended` and `isPlaying`,
    /// the `.active` re-arm (PVM:4725-4750) only on `isBackgroundSuspended` and
    /// a pending `wasPlaying` interruption, and the deadline task
    /// (PVM:4738-4747) → `triggerAutomaticInterruptionRecovery` (PVM:4005-4025)
    /// only on `lastLoadRequest`/`isPending`/`!didAutoRecover`. None of them
    /// looks at whether a load is in flight, and `resetPublishedLoadState`
    /// (PVM:3475-3546) writes neither `playbackInterruption` nor `isPlaying` —
    /// so an Apple TV that goes inactive while a quality switch, a Retry or an
    /// interruption reload is still resolving must pause, re-arm and
    /// auto-recover exactly as a steady load does. Gating these on `.playing`
    /// would leave `fileLoaded` clearing `isPaused` with no `.transport(.play)`
    /// ever issued: the UI would report playing against a paused engine.
    func testTvOSInterruptionArmsAlsoCoverALoadInFlight() {
        let loadID = LoadID()
        let state = makePreparing(
            loadID: loadID,
            transport: TransportState(positionSeconds: 617, durationSeconds: 1000)
        )

        // (a) inactive mid-load records the interruption and pauses.
        let (inactive, inactiveEffects) = PlaybackReducer.scenePhase(
            state,
            phase: .inactive,
            platform: .tvOS,
            now: now
        )
        XCTAssertEqual(preparing(inactive)?.interruption?.wasPlaying, true)
        XCTAssertEqual(preparing(inactive)?.interruption?.isPending, true)
        XCTAssertEqual(preparing(inactive)?.interruption?.positionSeconds, 617)
        // `isPlaying` stays `onPauseChange`'s, here as everywhere.
        XCTAssertEqual(preparing(inactive)?.transport, preparing(state)?.transport)
        XCTAssertEqual(
            inactiveEffects,
            [.cancelTimer(.interruptionRecovery), .transport(.pause, loadID)]
        )

        // A load that is already paused has nothing to interrupt.
        let (pausedNext, pausedEffects) = PlaybackReducer.scenePhase(
            makePreparing(loadID: loadID, transport: TransportState(isPaused: true)),
            phase: .inactive,
            platform: .tvOS,
            now: now
        )
        XCTAssertEqual(pausedNext, makePreparing(loadID: loadID, transport: TransportState(isPaused: true)))
        XCTAssertTrue(pausedEffects.isEmpty)

        // (b) active mid-load re-arms the deadline, raises the overlay and plays.
        let (active, activeEffects) = PlaybackReducer.scenePhase(
            inactive,
            phase: .active,
            platform: .tvOS,
            now: now
        )
        XCTAssertEqual(
            preparing(active)?.interruption?.recoveryDeadline,
            now.addingTimeInterval(3),
            "interruptionRecoveryTimeout"
        )
        guard case .publish(let presentation) = activeEffects.first else {
            return XCTFail("expected the loading publish")
        }
        XCTAssertTrue(presentation.isLoading)
        XCTAssertNil(presentation.error)
        XCTAssertEqual(activeEffects.count, 3)
        XCTAssertEqual(activeEffects[1], .transport(.play, loadID))
        XCTAssertEqual(
            activeEffects[2],
            .schedule(.interruptionRecovery, after: .seconds(3), loadID)
        )

        // (c) the deadline task has no state precondition either: before the
        // deadline it is a no-op, after it the reload runs from `.preparing`.
        let (early, earlyEffects) = PlaybackReducer.reduce(
            active,
            event: .timer(.interruptionRecovery, loadID),
            now: now
        )
        XCTAssertEqual(early, active, "the deadline has not passed")
        XCTAssertTrue(earlyEffects.isEmpty)

        let deadline = now.addingTimeInterval(3)
        let (recovering, recoveringEffects) = PlaybackReducer.reduce(
            active,
            event: .timer(.interruptionRecovery, loadID),
            now: deadline
        )
        guard let reload = preparing(recovering) else { return XCTFail("expected a reload") }
        XCTAssertNotEqual(reload.loadID, loadID, "every load mints a new LoadID")
        XCTAssertTrue(reload.options.preserveInterruptionState)
        XCTAssertEqual(reload.options.resumePosition, 617)
        XCTAssertEqual(reload.interruption?.didAutoRecover, true)
        XCTAssertEqual(reload.interruption?.isPending, true)
        XCTAssertTrue(reload.transport.isPaused, "the hand-written isPlaying = false at PVM:4016")
        XCTAssertEqual(recoveringEffects.first, .cancelTimer(.interruptionRecovery))
        XCTAssertTrue(
            recoveringEffects.contains { if case .startSession = $0 { return true } else { return false } }
        )
        XCTAssertTrue(recoveringEffects.contains(.disposeEngine(loadID, sourceCache: .stash)))

        // Nothing pending mid-load is still nothing to do.
        let (steady, steadyEffects) = PlaybackReducer.scenePhase(
            makePreparing(loadID: loadID),
            phase: .active,
            platform: .tvOS,
            now: now
        )
        XCTAssertEqual(steady, makePreparing(loadID: loadID))
        XCTAssertTrue(steadyEffects.isEmpty)
    }

    /// The other half of the arm above: `pauseForForegroundInterruptionIfNeeded`
    /// guards on `isPlaying` (PVM:7573), and a cold start, a Retry and an
    /// explicit resume all run with `isPlaying == false` — the initial value
    /// (PVM:185), `finalizeTerminalPlaybackError`'s (PVM:4072) and
    /// `suspendForBackground`'s (PVM:7621), none of which
    /// `resetPublishedLoadState` overwrites. So those loads carry
    /// `transport.isPaused`, record no interruption when tvOS goes inactive,
    /// and publish no playing capsule under the loading overlay.
    func testLoadsFromANotPlayingStateStayNotPlaying() {
        let failed = PlaybackState.failed(
            PlaybackFailure(legacyMessage: "boom"),
            LoadID(),
            identity: makeIdentity(),
            request: makeRequest(),
            position: 617,
            selections: .seeded(from: makeRequest())
        )
        let suspended = PlaybackState.suspended(
            SuspendedContext(request: makeRequest(), resumePosition: 617)
        )

        let starts: [(String, PlaybackState, PlayerIntent)] = [
            ("cold start", .idle, .load(makeRequest(), origin: .userInitiated, options: LoadOptions())),
            ("retry", failed, .retry),
            ("resume", suspended, .resumeSuspended),
        ]

        for (label, from, intent) in starts {
            let (loading, _) = PlaybackReducer.reduce(from, intent: intent, now: now)
            guard let inFlight = preparing(loading) else {
                return XCTFail("\(label): expected preparing")
            }
            XCTAssertTrue(inFlight.transport.isPaused, "\(label): isPlaying is false here")
            XCTAssertFalse(
                PlaybackReducer.presentation(for: loading).isPlaying,
                "\(label): no playing capsule under the loading overlay"
            )

            let (inactive, effects) = PlaybackReducer.scenePhase(
                loading,
                phase: .inactive,
                platform: .tvOS,
                now: now
            )
            XCTAssertEqual(inactive, loading, "\(label): nothing to interrupt")
            XCTAssertTrue(effects.isEmpty, "\(label): guard isPlaying, PVM:7573")
        }
        // `fileLoaded` is what makes a load playing (PVM:1518) — see
        // `testFileLoadedStartsPlaybackFromTheAdoptedTransport`.
    }

    /// `handleFileLoaded` calls `startProgressReporting()` (PVM:7466-7495)
    /// unconditionally, and that cancels and restarts the 10 s heartbeat — so
    /// an in-route reload/reanchor re-phases it exactly as a load's first
    /// `fileLoaded` does.
    func testInRouteFileLoadedRestartsTheProgressHeartbeat() {
        let loadID = LoadID()
        let state = makePlaying(loadID: loadID, sub: .recovering(.reloadingItem))
        let (next, effects) = PlaybackReducer.reduce(
            state,
            event: .engine(.fileLoaded(reason: "reload"), loadID),
            now: now
        )
        XCTAssertEqual(playing(next)?.sub, .steady)
        XCTAssertEqual(Array(effects.prefix(2)), [
            .cancelTimer(.serverOutageRecovery),
            .schedule(.progress, after: .seconds(10), loadID),
        ])
        guard case .publish = effects.last else { return XCTFail("expected a publish") }
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

    /// `togglePlayPause` documents the rule this pins (PVM:4573-4576):
    /// "`isPlaying` is driven by the backend's `onPauseChange` callback; let
    /// that be the single writer so the UI can't drift out of sync with the
    /// actual pipeline state on error paths." So the intent issues the command
    /// and writes nothing — no optimistic `isPaused`, no publish — and
    /// `.pauseChanged` is what moves the state and republishes.
    func testPlayPauseIssuesTheCommandAndLetsPauseChangedBeTheSoleWriter() {
        let loadID = LoadID()
        let state = makePlaying(loadID: loadID)
        let (afterPause, pauseEffects) = PlaybackReducer.reduce(state, intent: .pause, now: now)
        XCTAssertEqual(afterPause, state, "no optimistic transport write")
        XCTAssertEqual(pauseEffects, [.transport(.pause, loadID)])

        let (paused, pauseChanged) = PlaybackReducer.reduce(
            afterPause,
            event: .engine(.pauseChanged(true), loadID),
            now: now
        )
        XCTAssertEqual(playing(paused)?.transport.isPaused, true)
        guard case .publish(let pausedPresentation) = pauseChanged.last else {
            return XCTFail("expected a publish")
        }
        XCTAssertFalse(pausedPresentation.isPlaying)

        // The toggle reads the backend-driven flag, so it now asks to play.
        let (afterToggle, resumeEffects) = PlaybackReducer.reduce(
            paused,
            intent: .togglePlayPause,
            now: now
        )
        XCTAssertEqual(afterToggle, paused)
        XCTAssertEqual(resumeEffects, [.transport(.play, loadID)])
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
        XCTAssertTrue(effects.contains(.disposeEngine(loadID, sourceCache: .discard)))
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
