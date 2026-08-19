import Foundation
import XCTest
@testable import Silo

/// Wave 2b — `PlaybackEngineSession` owns the backend, the source proxy and the
/// load's `RecoveryDriver` for exactly one `LoadID`.
///
/// These tests drive it through `FakePlaybackBackend`, so what is pinned is the
/// wiring: the load verb the plan picks, the callback → `EngineEvent`
/// translation, the identity that ends a superseded load's stream, the in-place
/// replan that must keep the live backend instance (design §4 I4), and the
/// observation → policy → execute split (I3).
final class PlaybackEngineSessionTests: XCTestCase {

    // MARK: - Fixtures

    private func loopbackSpec(sourceStartTimeSeconds: Double = 0) -> LoopbackSessionSpec {
        LoopbackSessionSpec(
            sourceURL: URL(string: "http://127.0.0.1:9/source.mkv")!,
            headers: [:],
            sourceStartTimeSeconds: sourceStartTimeSeconds,
            sourceBitrateBps: nil,
            videoMode: .passthroughH264,
            sourceVideoFrameRate: 24,
            selectedAudio: LoopbackSessionSpec.SelectedAudio(
                trackIndex: 0,
                ffIndex: 1,
                sourceCodec: "eac3",
                sourceChannelCount: 2,
                sourceChannelLayout: "stereo",
                outputMode: .copy,
                preservesAtmos: false
            ),
            availableAudioTracks: [],
            manifestMetadata: LoopbackSessionSpec.ManifestMetadata(
                advertisedDolbyVisionProfile: nil,
                compatibilityBrand: nil,
                videoRange: "SDR",
                mayClaimAtmos: false
            )
        )
    }

    private func localHLSPlan() -> ExecutablePlan {
        .localHLS(LocalHLSPlan(sessionSpec: loopbackSpec(), startSeconds: 12.5))
    }

    private func nativeDirectPlan() -> ExecutablePlan {
        .nativeDirect(
            NativeDirectPlan(
                url: URL(string: "https://example.test/movie.mp4")!,
                headers: ["X-Silo": "1"],
                startSeconds: 30
            )
        )
    }

    @discardableResult
    private func makeSession(
        plan: ExecutablePlan,
        backend: FakePlaybackBackend,
        reusing existing: PlaybackEngineSession? = nil,
        loadID: LoadID = LoadID()
    ) -> PlaybackEngineSession {
        PlaybackEngineSession(
            loadID: loadID,
            plan: plan,
            backendFactory: { backend },
            reusing: existing,
            transport: nil
        )
    }

    /// Drains everything the session has published so far. The stream is
    /// unbuffered-unbounded and produced from the same actor the test runs on,
    /// so a `finish()` before iteration yields the whole ordered batch.
    private func drain(_ session: PlaybackEngineSession) async -> [EngineEvent] {
        session.dispose(reason: "test_drain")
        var collected: [EngineEvent] = []
        for await event in session.events {
            collected.append(event)
        }
        return collected
    }

    // MARK: - start

    func testStartPicksTheLoadVerbFromThePlan() {
        let loopbackBackend = FakePlaybackBackend()
        let loopback = makeSession(plan: localHLSPlan(), backend: loopbackBackend)
        loopback.start(startSeconds: 12.5)
        XCTAssertEqual(loopbackBackend.calls, ["load(loopback,12.5)"])

        let directBackend = FakePlaybackBackend()
        let direct = makeSession(plan: nativeDirectPlan(), backend: directBackend)
        direct.start(startSeconds: 30)
        XCTAssertEqual(
            directBackend.calls,
            ["loadDirectFile(https://example.test/movie.mp4,1,30.0)"]
        )
    }

    // MARK: - dispose

    /// Disposal unbinds every callback, disposes the engine, stops the proxy
    /// and ends the stream. It is what replaced the by-value generation guard:
    /// a late callback from a superseded load lands nowhere.
    func testDisposeUnbindsTheBackendAndEndsTheStream() async {
        let backend = FakePlaybackBackend()
        let session = makeSession(plan: localHLSPlan(), backend: backend)
        backend.fireTime(1)

        session.dispose(reason: "test")

        XCTAssertTrue(session.isDisposed)
        XCTAssertTrue(backend.calls.contains("dispose()"))
        XCTAssertNil(backend.onTimeChange)
        XCTAssertNil(backend.onRecoveryObservation)
        // Nothing the retired backend fires after this can reach the shell.
        backend.fireTime(2)
        backend.fireError(.unknown("late"))

        var collected: [EngineEvent] = []
        for await event in session.events {
            collected.append(event)
        }
        XCTAssertEqual(collected, [.time(seconds: 1)])
    }

    /// The tvOS background suspend disposes the engine and deliberately leaves
    /// the source proxy — and its cache — running for the resume (wave 1E
    /// `SourceCacheDisposition.retainProxy`); a blind `dispose()` would tear it
    /// down on every Apple TV suspend.
    func testDisposeCanRetainTheTransport() {
        let backend = FakePlaybackBackend()
        let session = makeSession(plan: localHLSPlan(), backend: backend)
        session.dispose(reason: "background_suspend", retainingTransport: true)
        XCTAssertTrue(backend.calls.contains("dispose()"))
    }

    // MARK: - reuse (I4)

    /// An in-place replan keeps the live backend instance so tvOS keeps
    /// identical display criteria and the active audio session; only the
    /// callback binding moves to the new `LoadID`.
    func testReuseKeepsTheBackendInstanceAndRetiresTheOldStream() async {
        let backend = FakePlaybackBackend()
        let first = makeSession(plan: localHLSPlan(), backend: backend)
        backend.fireFileLoaded(reason: "first_frame")

        let neverBuilt = FakePlaybackBackend()
        let second = PlaybackEngineSession(
            loadID: LoadID(),
            plan: localHLSPlan(),
            backendFactory: { neverBuilt },
            reusing: first,
            transport: nil
        )

        XCTAssertTrue(second.backend === backend)
        XCTAssertFalse(backend.calls.contains("dispose()"))
        XCTAssertTrue(neverBuilt.calls.isEmpty)
        XCTAssertTrue(first.isDisposed)

        // The event now belongs to the second session, not the first.
        backend.fireTime(9)
        var firstEvents: [EngineEvent] = []
        for await event in first.events {
            firstEvents.append(event)
        }
        XCTAssertEqual(firstEvents, [.fileLoaded(reason: "first_frame")])
        let secondEvents = await drain(second)
        XCTAssertEqual(secondEvents, [.time(seconds: 9)])
    }

    /// A session that never reuses builds its backend from the factory.
    func testWithoutReuseTheFactoryBuildsAFreshBackend() {
        let backend = FakePlaybackBackend()
        let session = makeSession(plan: localHLSPlan(), backend: backend, reusing: nil)
        XCTAssertTrue(session.backend === backend)
    }

    // MARK: - Event translation

    /// Every backend callback has exactly one `EngineEvent`, delivered in the
    /// order the backend fired it.
    func testCallbacksTranslateIntoOrderedEngineEvents() async {
        let backend = FakePlaybackBackend()
        let session = makeSession(plan: localHLSPlan(), backend: backend)

        backend.fireFileLoaded(reason: "first_frame")
        backend.fireFirstFrame(420)
        backend.fireTime(3.5)
        backend.fireDuration(600)
        backend.firePauseChanged(true)
        backend.fireBuffering(true)
        backend.fireTracks([])
        backend.fireChapters([])
        backend.fireTimelineOffset(7)
        backend.fireExternalPlaybackActive(true)
        backend.fireExternalPlaybackAllowed(true)
        backend.fireExternalPlaybackUnavailable()
        backend.fireSidecarTracksRegistered([])
        backend.fireError(.unknown("boom"))
        backend.fireEndOfFile()

        let events = await drain(session)
        XCTAssertEqual(
            events,
            [
                .fileLoaded(reason: "first_frame"),
                .firstFrame(ms: 420),
                .time(seconds: 3.5),
                .duration(seconds: 600),
                .pauseChanged(true),
                .buffering(true),
                .tracks([]),
                .chapters([]),
                .timelineOffset(7),
                .externalPlayback(active: true),
                .externalPlaybackAllowed(true),
                .externalPlaybackUnavailable,
                .sidecarTracksRegistered([]),
                .failed(.unknown("boom")),
                .endOfFile,
            ]
        )
    }

    /// Three of those callbacks also feed the recovery context, because the
    /// pure policy cannot read the player: the play-intent latch, the
    /// file-loaded edge and the media-timeline offset.
    func testTransportCallbacksThreadTheRecoveryContext() {
        let backend = FakePlaybackBackend()
        let session = makeSession(plan: localHLSPlan(), backend: backend)

        XCTAssertFalse(session.driver.context.playbackEstablished)
        backend.fireFileLoaded(reason: "first_frame")
        XCTAssertTrue(session.driver.context.playbackEstablished)

        backend.firePauseChanged(true)
        XCTAssertTrue(session.driver.context.userPaused)

        backend.fireTimelineOffset(42)
        XCTAssertEqual(session.driver.context.mediaTimelineOffset, 42)
    }

    // MARK: - Observation → policy → execution (I3)

    /// A backend observation is decided by the one policy and the resulting
    /// in-route action is performed on the backend, synchronously, where the
    /// ladder used to run.
    func testInRouteObservationIsDecidedThenPerformedOnTheBackend() {
        let backend = FakePlaybackBackend()
        let session = makeSession(plan: localHLSPlan(), backend: backend)
        backend.fireFileLoaded(reason: "first_frame")
        backend.recoveryPlayheadSampleValue = PlayheadSample(
            position: 100,
            timeControl: .playing,
            bufferedAhead: 0,
            generatedAhead: 40,
            secondsSinceLastServe: .infinity,
            userPaused: false,
            playbackEstablished: true
        )

        backend.fireRecoveryObservation(.playbackStalled)

        XCTAssertEqual(
            backend.performedRecoveryActions,
            [.reanchor(atMediaSeconds: 100, reason: "stall")]
        )
        XCTAssertFalse(session.isDisposed)
    }

    /// An observation the policy declines produces no call at all — the
    /// suspension latch is the same one the retired handshake held.
    func testSuspendedInRouteObservationPerformsNothing() {
        let backend = FakePlaybackBackend()
        let session = makeSession(plan: localHLSPlan(), backend: backend)
        backend.fireFileLoaded(reason: "first_frame")
        backend.recoveryPlayheadSampleValue = PlayheadSample(
            position: 100,
            timeControl: .playing,
            bufferedAhead: 0,
            generatedAhead: 40,
            secondsSinceLastServe: .infinity,
            userPaused: false,
            playbackEstablished: true
        )
        session.suspendRecovery(true, reason: RecoveryDriver.serverReplanSuspensionReason)

        backend.fireRecoveryObservation(.playbackStalled)

        XCTAssertTrue(backend.performedRecoveryActions.isEmpty)
    }

    /// Session- and transport-level actions ride the same stream, because the
    /// shell owns their execution — and riding the stream is what makes a
    /// superseded load's decision die with its session.
    func testShellLevelActionRidesTheEventStream() async {
        let backend = FakePlaybackBackend()
        let session = makeSession(plan: nativeDirectPlan(), backend: backend)
        session.driver.note(
            isProtocolV3Active: true,
            isReplanInFlight: false,
            hasWatchDetail: true,
            canRenewSourceInBackground: false,
            canAutoRecoverInterruption: false,
            canBuildLoopbackFallback: false,
            nearEnd: nil
        )

        let failure = PlaybackFailure.unknown("bad")
        session.observe(.engineFailed(failure))

        XCTAssertTrue(backend.performedRecoveryActions.isEmpty)
        let events = await drain(session)
        XCTAssertEqual(
            events,
            [
                .recoveryAction(
                    .requestServerReplan(
                        classification: failure.classification,
                        message: failure.legacyMessage
                    )
                )
            ]
        )
    }

    /// Origin-outage entry holds the in-route suppression *synchronously*, so
    /// no rung can act in the window before the shell picks the ride-through
    /// action up off the stream — and re-feeds the runway gate when the player
    /// was already buffering (wave-1B obligation (c)).
    func testOriginOutageEntryHoldsSuppressionAndRefeedsTheRunwayGate() async {
        let backend = FakePlaybackBackend()
        let session = makeSession(plan: localHLSPlan(), backend: backend)
        backend.fireFileLoaded(reason: "first_frame")
        backend.fireBuffering(true)

        session.reportOriginOutage(true)

        XCTAssertEqual(
            session.driver.context.suspendedReasons,
            [RecoveryDriver.originOutageSuspensionReason]
        )
        XCTAssertEqual(session.driver.context.outage?.noticeShown, true)

        let events = await drain(session)
        XCTAssertEqual(
            events.last,
            .recoveryAction(.rideThroughOutage(probeAfter: .zero))
        )
    }

    /// Exit releases the latch before the post-outage kick runs — the kick's
    /// own rung reads it — and still tells the shell, which owns the
    /// "Reconnected" notice.
    func testOriginOutageExitReleasesSuppressionBeforeTheKick() async {
        let backend = FakePlaybackBackend()
        let session = makeSession(plan: localHLSPlan(), backend: backend)
        backend.fireFileLoaded(reason: "first_frame")
        session.reportOriginOutage(true)
        backend.clearCalls()

        session.reportOriginOutage(false)

        XCTAssertTrue(session.driver.context.suspendedReasons.isEmpty)
        XCTAssertEqual(
            backend.performedRecoveryActions,
            [.endOutageRideThrough(kick: true)]
        )
        let events = await drain(session)
        XCTAssertTrue(events.contains(.recoveryAction(.endOutageRideThrough(kick: true))))
    }

    // MARK: - Source proxy ownership

    /// The engine session owns the transport, so `retargetSource` is the silent
    /// renewal's only reach into it and `stopTransport` is what the fresh-load
    /// path calls before the backend goes away.
    func testTransportIsOwnedByTheSession() {
        let backend = FakePlaybackBackend()
        let session = makeSession(plan: localHLSPlan(), backend: backend)
        XCTAssertNil(session.transport)
        session.stopTransport()
        XCTAssertNil(session.transport)
        XCTAssertNil(backend.proxyStatsProvider)
        XCTAssertNil(backend.sourceOutageStateProvider)
    }

}
