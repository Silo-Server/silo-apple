import AetherEngine
import AVFoundation
import XCTest
@testable import Silo

/// Which playback facts reach the buffering controller as a stall, and which
/// as one of the spec's exclusions (seek, pause, end, reload, outage).
final class BufferingSignalMapperTests: XCTestCase {
    private typealias Transport = AetherPlaybackController.NativeTransport
    private typealias Snapshot = BufferingSignalMapper.Snapshot

    private static let avPlaying = Transport(status: .playing, waitingReason: nil)
    private static let avPaused = Transport(status: .paused, waitingReason: nil)
    private static func avWaiting(_ reason: AVPlayer.WaitingReason?) -> Transport {
        Transport(status: .waitingToPlayAtSpecifiedRate, waitingReason: reason)
    }

    /// Playing on the software route unless a case says otherwise.
    private static func snapshot(
        load: Bool = true,
        play: Bool = true,
        phase: PlaybackPhase = .playing,
        buffering: Bool = false,
        native: Transport? = nil,
        seek: Bool = false,
        reload: Bool = false,
        end: Bool = false,
        trouble: Bool = false
    ) -> Snapshot {
        Snapshot(
            hasActiveLoad: load, wantsToPlay: play, phase: phase, engineBuffering: buffering,
            nativeTransport: native, seekInFlight: seek, reloadInProgress: reload, reachedEnd: end,
            connectionTrouble: trouble
        )
    }

    func testEachStateMapsToItsControllerCall() {
        let cases: [(String, Snapshot, [BufferingSignalMapper.Call])] = [
            ("no load, viewer playing", Self.snapshot(load: false), [.waiting(.reload)]),
            ("no load, viewer paused", Self.snapshot(load: false, play: false), [.paused]),
            ("end of media", Self.snapshot(native: Self.avPlaying, end: true), [.paused]),
            ("ended phase", Self.snapshot(phase: .ended), [.paused]),
            ("viewer paused while starved",
             Self.snapshot(play: false, phase: .rebuffering, native: Self.avWaiting(.toMinimizeStalls)), [.paused]),
            ("seek in flight", Self.snapshot(native: Self.avWaiting(.toMinimizeStalls), seek: true), [.waiting(.seek)]),
            ("seeking phase", Self.snapshot(phase: .seeking), [.waiting(.seek)]),
            ("no item to play", Self.snapshot(phase: .loading, native: Self.avWaiting(.noItemToPlay)), [.waiting(.reload)]),
            ("same-plan reload starting",
             Self.snapshot(phase: .loading, native: Self.avWaiting(.toMinimizeStalls), reload: true), [.waiting(.reload)]),
            ("reload under a transport still playing", Self.snapshot(native: Self.avPlaying, reload: true), [.playing]),
            ("coordinated playback",
             Self.snapshot(native: Self.avWaiting(.waitingForCoordinatedPlayback)), [.waiting(.pause)]),
            ("interstitial", Self.snapshot(native: Self.avWaiting(.interstitialEvent)), [.waiting(.pause)]),
            ("AVPlayer playing", Self.snapshot(native: Self.avPlaying), [.playing]),
            ("software playing", Self.snapshot(), [.playing]),
            ("software playing but buffering", Self.snapshot(buffering: true), [.waiting(.network)]),
            ("minimizing stalls", Self.snapshot(native: Self.avWaiting(.toMinimizeStalls)), [.waiting(.network)]),
            ("evaluating buffering rate",
             Self.snapshot(native: Self.avWaiting(.evaluatingBufferingRate)), [.waiting(.network)]),
            ("waiting with no reason", Self.snapshot(native: Self.avWaiting(nil)), [.waiting(.network)]),
            ("rebuffering", Self.snapshot(phase: .rebuffering), [.waiting(.network)]),
            ("new plan starting", Self.snapshot(phase: .loading), [.waiting(.network)]),
            ("new plan starting before AVPlayer rolls",
             Self.snapshot(phase: .loading, native: Self.avPaused), [.waiting(.network)]),
            ("AVPlayer paused under play intent", Self.snapshot(phase: .paused, native: Self.avPaused), [.paused]),
            ("idle", Self.snapshot(phase: .idle), [.paused]),
            ("error", Self.snapshot(phase: .error("failed")), [.paused]),
            // Media requests failing: trouble first, then the wait it explains.
            ("source stalled",
             Self.snapshot(phase: .stalled(reconnecting: true)), [.transportTroubleChanged(true), .waiting(.network)]),
            ("source stalled, playing from buffer",
             Self.snapshot(phase: .stalled(reconnecting: false), native: Self.avPlaying),
             [.transportTroubleChanged(true), .playing]),
            ("reconnecting",
             Self.snapshot(native: Self.avWaiting(.toMinimizeStalls), trouble: true),
             [.transportTroubleChanged(true), .waiting(.network)]),
        ]
        for (name, snapshot, expected) in cases {
            var mapper = BufferingSignalMapper()
            XCTAssertEqual(mapper.update(snapshot), expected, name)
        }
    }

    func testARepeatedStateIsReportedOnce() {
        var mapper = BufferingSignalMapper()
        let starved = Self.snapshot(native: Self.avWaiting(.toMinimizeStalls))
        XCTAssertEqual(mapper.update(starved), [.waiting(.network)])
        XCTAssertEqual(mapper.update(starved), [])
        // Another fact behind the same state changes nothing either.
        XCTAssertEqual(mapper.update(Self.snapshot(phase: .rebuffering)), [])
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying)), [.playing])
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying)), [])
    }

    func testTroubleIsReportedBeforeTheMediaCallAndOnlyWhenItChanges() {
        var mapper = BufferingSignalMapper()
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying)), [.playing])
        XCTAssertEqual(
            mapper.update(Self.snapshot(native: Self.avWaiting(.toMinimizeStalls), trouble: true)),
            [.transportTroubleChanged(true), .waiting(.network)]
        )
        XCTAssertEqual(mapper.update(Self.snapshot(phase: .stalled(reconnecting: true), trouble: true)), [])
        XCTAssertEqual(
            mapper.update(Self.snapshot(native: Self.avWaiting(.toMinimizeStalls))),
            [.transportTroubleChanged(false)],
            "the stall goes on, now timed by the controller"
        )
        XCTAssertEqual(
            mapper.update(Self.snapshot(native: Self.avPlaying, trouble: true)),
            [.transportTroubleChanged(true), .playing]
        )
    }

    func testASeekThatStartsWhileNotWaitingDiscardsAnyStall() {
        var mapper = BufferingSignalMapper()
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying)), [.playing])
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying, seek: true)), [.seeked, .waiting(.seek)])
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avWaiting(.toMinimizeStalls), seek: true)), [])

        // From a network wait the seek wait itself ends the stall.
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avWaiting(.toMinimizeStalls))), [.waiting(.network)])
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avWaiting(nil), seek: true)), [.waiting(.seek)])
    }

    func testAnItemStallCountsUntilPlaybackRuns() {
        var mapper = BufferingSignalMapper()
        let held = Self.snapshot(phase: .playing, native: Self.avPaused)
        XCTAssertEqual(mapper.update(held), [.paused])
        mapper.noteItemStalled()
        XCTAssertEqual(mapper.update(held), [.waiting(.network)])
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying)), [.playing])
        XCTAssertEqual(mapper.update(held), [.paused], "playing cleared the stall")
    }

    func testInvalidateReportsTheCurrentStateAgain() {
        var mapper = BufferingSignalMapper()
        let starting = Self.snapshot(phase: .loading)
        XCTAssertEqual(mapper.update(starting), [.waiting(.network)])
        mapper.invalidate()
        XCTAssertEqual(mapper.update(starting), [.waiting(.network)], "a newly adopted plan hears the wait")
        mapper.invalidate()
        XCTAssertEqual(mapper.update(Self.snapshot(seek: true)), [.waiting(.seek)], "no seeked without a known state")
    }
}

/// The player's side of the buffering controller: plan adoptions, the
/// viewer's own quality pick, Watch Party and the other pills.
@MainActor
final class BufferingQualityPlayerTests: XCTestCase {
    /// The learned-limit fixture's plan, with a ladder below its 8000 kbps
    /// and the given warnings.
    private func preparedPlan(warnings: [String] = []) throws -> PreparedPlaybackV3 {
        var object = try APIv2FixtureTestSupport.jsonObject(
            APIv2FixtureTestSupport.data(named: "learned-limit-decision_response", bundleClass: Self.self)
        )
        var plan = try XCTUnwrap(object["playback_plan"] as? [String: Any])
        plan["available_qualities"] = [
            ["label": "original", "height": 1080, "bitrate_kbps": 8_000, "preserves_source": true],
            ["label": "1080p-high", "height": 1080, "bitrate_kbps": 6_000, "preserves_source": false],
            ["label": "720p-high", "height": 720, "bitrate_kbps": 4_000, "preserves_source": false],
        ]
        plan["degradation_warnings"] = warnings.map { ["code": $0, "message": $0] }
        object["playback_plan"] = plan
        let decision = try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3DecisionResponse.self, from: JSONSerialization.data(withJSONObject: object)
        )
        return PreparedPlaybackV3(
            playbackAttemptId: "apple:attempt", planAttemptId: "apple-plan:attempt",
            planAttemptKey: try XCTUnwrap(decision.playbackPlan).planAttemptKey, outputContextId: nil,
            serverFeatures: decision.serverFeatures, plan: try XCTUnwrap(decision.playbackPlan)
        )
    }

    private func eventually(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { await Task.yield() }
    }

    /// The server's `plan_id` hashes the route, so a lowering that comes back
    /// unchanged repeats it; the controller must still see a new plan.
    func testEveryAdoptionIsANewPlanEvenWhenPlanIdRepeats() throws {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        let prepared = try preparedPlan()
        model.adoptBufferingPlan(prepared, sessionId: "session", activeQualityId: "auto")
        let first = try XCTUnwrap(model.bufferingPlanId)
        model.adoptBufferingPlan(prepared, sessionId: "session", activeQualityId: "auto")
        let second = try XCTUnwrap(model.bufferingPlanId)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.hasSuffix(prepared.plan.planId))
        XCTAssertTrue(second.hasSuffix(prepared.plan.planId))
        XCTAssertTrue(model.bufferingQuality.sendsBufferingQualityFields, "the fixture advertises buffering_quality_v1")
    }

    func testThePlanCarriesDeliveredBitrateQualityLabelAndWarning() throws {
        let prepared = try preparedPlan(warnings: ["quality_reduction_unavailable"])
        let auto = PlayerViewModel.bufferingPlan(id: "1:p", prepared: prepared, activeQualityId: "auto")
        XCTAssertEqual(auto.quality, BufferingQualityController.autoQuality)
        XCTAssertEqual(auto.deliveredKbps, 8_000)
        XCTAssertTrue(auto.qualityReductionUnavailable)
        XCTAssertEqual(auto.availableQualities.map(\.label), ["original", "1080p-high", "720p-high"])

        let picked = PlayerViewModel.bufferingPlan(id: "1:p", prepared: try preparedPlan(), activeQualityId: "1080P-High")
        XCTAssertEqual(picked.quality, "1080p-high", "the server's label for the rung in effect")
        XCTAssertFalse(picked.qualityReductionUnavailable)
    }

    /// A picked quality is asked about even in `always`: shows the prompt.
    private func showPrompt(on model: PlayerViewModel, clock: ManualBufferingQualityClock) throws {
        model.adoptBufferingPlan(try preparedPlan(), sessionId: "session", activeQualityId: "1080p-high")
        model.bufferingQuality.mode = .always
        model.bufferingQuality.playing()
        clock.advance(to: 20_000)
        model.bufferingQuality.waiting(cause: .network)
        clock.advance(to: 26_000)
        XCTAssertEqual(model.bufferingPill?.kind, .prompt)
    }

    func testTheViewersQualityPickTakesTheBufferingPillDown() throws {
        let clock = ManualBufferingQualityClock()
        let model = PlayerViewModel(bufferingQualityClock: clock)
        defer { model.cleanup() }
        try showPrompt(on: model, clock: clock)
        model.switchQuality("720p")
        XCTAssertNil(model.bufferingPill)
    }

    func testAnotherPillHoldsTheBufferingPillUntilItHides() async throws {
        let clock = ManualBufferingQualityClock()
        let model = PlayerViewModel(bufferingQualityClock: clock)
        defer { model.cleanup() }
        try showPrompt(on: model, clock: clock)

        model.introSkipPrompt.update(IntroSkipPrompt.Inputs(
            position: 30, range: TimeRange(start: 10, end: 60), key: "intro", mode: .ask, activity: .playing
        ))
        XCTAssertTrue(model.showIntroSkip)
        await eventually { model.bufferingPill == nil }
        XCTAssertNil(model.bufferingPill)

        // The same path the intro pill's own timer takes down.
        model.introSkipPrompt.withdraw()
        await eventually { model.bufferingPill != nil }
        XCTAssertEqual(model.bufferingPill?.kind, .prompt)
    }

    func testWatchPartySuspendsTheController() {
        let solo = PlayerViewModel()
        defer { solo.cleanup() }
        XCTAssertFalse(solo.bufferingQuality.isSuspended)

        let player = PlayerViewModel()
        let adapter = WatchPartyPlaybackAdapter(player: player)
        defer { adapter.stop() }
        adapter.prepare(WatchPartyPlaybackContext(
            roomId: "room", selectionRevision: 1, contentId: "movie",
            fileId: 42, libraryId: nil, startPosition: 0
        ))
        XCTAssertTrue(player.bufferingQuality.isSuspended)
    }
}
