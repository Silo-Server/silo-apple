import AetherEngine
import AVFoundation
import UIKit
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
        trouble: Bool = false,
        bufferedMs: Int? = nil,
        frozen: Bool = false
    ) -> Snapshot {
        Snapshot(
            hasActiveLoad: load, wantsToPlay: play, phase: phase, engineBuffering: buffering,
            nativeTransport: native, seekInFlight: seek, reloadInProgress: reload, reachedEnd: end,
            connectionTrouble: trouble, bufferedAheadMs: bufferedMs, playheadFrozen: frozen
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
            [],
            "the outage lasts until media data arrives"
        )
        XCTAssertEqual(
            mapper.update(Self.snapshot(native: Self.avWaiting(.toMinimizeStalls), bufferedMs: 500)),
            [.transportTroubleChanged(false)],
            "data arrived: the stall goes on, now timed by the controller"
        )
        XCTAssertEqual(
            mapper.update(Self.snapshot(native: Self.avPlaying, trouble: true)),
            [.transportTroubleChanged(true), .playing]
        )
        XCTAssertEqual(
            mapper.update(Self.snapshot(native: Self.avPlaying)),
            [.transportTroubleChanged(false)],
            "playback running ends it too"
        )
    }

    /// A reconnect or a device back online does not end an outage on its own:
    /// only media data arriving or playback running does, after a seek too.
    func testAnOutageEndsOnlyWhenDataArrives() {
        var mapper = BufferingSignalMapper()
        let starved = { (ms: Int?) in Self.snapshot(native: Self.avWaiting(.toMinimizeStalls), bufferedMs: ms) }
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying)), [.playing])
        XCTAssertEqual(
            mapper.update(Self.snapshot(native: Self.avWaiting(.toMinimizeStalls), trouble: true, bufferedMs: 800)),
            [.transportTroubleChanged(true), .waiting(.network)]
        )
        XCTAssertEqual(mapper.update(starved(800)), [], "no new data")
        XCTAssertTrue(mapper.outageAwaitsData)
        XCTAssertEqual(mapper.update(starved(0)), [], "a seek lowered it")
        XCTAssertEqual(mapper.update(starved(400)), [.transportTroubleChanged(false)])
        XCTAssertFalse(mapper.outageAwaitsData)
    }

    /// A failed media request starts an outage that no timer ends: only media
    /// data arriving or playback running does.
    func testAFailedMediaRequestStartsAnOutageThatDataEnds() {
        var mapper = BufferingSignalMapper()
        let starved = { (ms: Int) in Self.snapshot(native: Self.avWaiting(.toMinimizeStalls), bufferedMs: ms) }
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying)), [.playing])
        mapper.noteMediaRequestFailed()
        XCTAssertEqual(mapper.update(starved(300)), [.transportTroubleChanged(true), .waiting(.network)])
        XCTAssertEqual(mapper.update(starved(300)), [], "still no data")
        XCTAssertEqual(mapper.update(starved(900)), [.transportTroubleChanged(false)])

        mapper.noteMediaRequestFailed()
        XCTAssertEqual(mapper.update(starved(900)), [.transportTroubleChanged(true)])
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying)), [.transportTroubleChanged(false), .playing])
    }

    /// An adopted plan starts with no outage, even while the one before it
    /// still waited for data; an outage still signalled begins again.
    func testAnAdoptedPlanStartsWithNoOutage() {
        var mapper = BufferingSignalMapper()
        let starved = Self.snapshot(native: Self.avWaiting(.toMinimizeStalls))
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying)), [.playing])
        mapper.noteMediaRequestFailed()
        XCTAssertEqual(mapper.update(starved), [.transportTroubleChanged(true), .waiting(.network)])
        mapper.planAdopted()
        XCTAssertEqual(mapper.update(starved), [.transportTroubleChanged(false), .waiting(.network)])

        mapper.planAdopted()
        XCTAssertEqual(
            mapper.update(Self.snapshot(native: Self.avWaiting(.toMinimizeStalls), trouble: true)),
            [.transportTroubleChanged(true), .waiting(.network)],
            "the device is still offline"
        )
    }

    /// Until a plan first runs, a seek, the start position included, leaves
    /// the start's wait running; the paused-seek rule applies only after.
    func testASeekBeforeTheFirstFrameStaysTheStartsWait() {
        var mapper = BufferingSignalMapper()
        mapper.planAdopted()
        XCTAssertEqual(mapper.update(Self.snapshot(phase: .loading)), [.waiting(.network)])
        XCTAssertEqual(mapper.update(Self.snapshot(phase: .seeking)), [], "the engine seeking to the start")
        XCTAssertEqual(mapper.update(Self.snapshot(phase: .loading, seek: true)), [], "the viewer seeking")
        XCTAssertEqual(mapper.update(Self.snapshot(phase: .loading)), [])
        XCTAssertEqual(mapper.update(Self.snapshot()), [.playing])
        XCTAssertEqual(mapper.update(Self.snapshot(phase: .seeking)), [.waiting(.seek)])

        // A plan opened paused has not run: a seek then is not the seek's.
        var paused = BufferingSignalMapper()
        paused.planAdopted()
        XCTAssertEqual(paused.update(Self.snapshot(play: false, phase: .paused)), [.paused])
        XCTAssertEqual(paused.update(Self.snapshot(play: false, phase: .paused, seek: true)), [])
        XCTAssertEqual(paused.update(Self.snapshot(phase: .loading)), [.waiting(.network)])
    }

    /// A subtitle rendition's failed request is not a media failure: it
    /// starts no outage. The video's playlists and segments are.
    func testASubtitleRenditionFailureIsNotAMediaFailure() {
        let subtitle = [
            "http://127.0.0.1:8080/subs_2.m3u8",
            "http://127.0.0.1:8080/subs_2_14.vtt",
            "https://silo.example/api/v2/stream/s/master.m3u8?silo_rendition=subtitles",
            "https://silo.example/api/v2/stream/s/subtitles_3.vtt?token=x",
        ]
        let media = [
            "https://silo.example/api/v2/stream/s/master.m3u8",
            "https://silo.example/api/v2/stream/s/master.m3u8?silo_rendition=video",
            "https://silo.example/api/v2/stream/s/segment_12.m4s",
            "http://127.0.0.1:8080/stream.m3u8",
        ]
        for uri in subtitle {
            XCTAssertTrue(AetherPlaybackController.isSubtitleRenditionRequest(uri: uri), uri)
        }
        for uri in media {
            XCTAssertFalse(AetherPlaybackController.isSubtitleRenditionRequest(uri: uri), uri)
        }
        XCTAssertFalse(AetherPlaybackController.isSubtitleRenditionRequest(uri: nil), "unknown counts as media")
    }

    /// Until a plan first runs or pauses, a start the viewer means to play
    /// is the plan's wait, through a reload of its transport. After that a
    /// reload is a reload.
    func testASlowStartStaysTimedThroughAReload() {
        var mapper = BufferingSignalMapper()
        mapper.planAdopted()
        XCTAssertEqual(mapper.update(Self.snapshot(phase: .loading)), [.waiting(.network)])
        XCTAssertEqual(mapper.update(Self.snapshot(phase: .loading, reload: true)), [], "still the start's wait")
        XCTAssertEqual(mapper.update(Self.snapshot(load: false)), [])
        XCTAssertEqual(
            mapper.update(Self.snapshot(phase: .loading, native: Self.avWaiting(.noItemToPlay))), []
        )
        XCTAssertEqual(mapper.update(Self.snapshot()), [.playing])
        XCTAssertEqual(mapper.update(Self.snapshot(phase: .loading, reload: true)), [.waiting(.reload)])

        // A pause ends the start: a reload after it is a reload.
        var paused = BufferingSignalMapper()
        paused.planAdopted()
        XCTAssertEqual(paused.update(Self.snapshot(play: false, phase: .loading)), [.paused])
        XCTAssertEqual(paused.update(Self.snapshot(phase: .loading, reload: true)), [.waiting(.reload)])

        // So does the engine tearing the video down outside a reload.
        var background = BufferingSignalMapper()
        background.planAdopted()
        let torn = Transport(status: .waitingToPlayAtSpecifiedRate, waitingReason: .noItemToPlay, hasItem: false)
        XCTAssertEqual(background.update(Self.snapshot(phase: .loading, native: torn)), [.waiting(.reload)])
    }

    func testASeekThatStartsWhileNotWaitingDiscardsAnyStall() {
        var mapper = BufferingSignalMapper()
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying)), [.playing])
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying, seek: true)), [.waiting(.seek)])
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avWaiting(.toMinimizeStalls), seek: true)), [])

        // From a network wait the seek wait itself ends the stall.
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying)), [.playing])
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avWaiting(.toMinimizeStalls))), [.waiting(.network)])
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avWaiting(nil), seek: true)), [.waiting(.seek)])
    }

    /// The seek lands before the player has buffered enough to run: that
    /// buffering is still the seek's, and only a wait after playback runs
    /// again can be a stall.
    func testBufferingAfterASeekLandsIsTheSeeksUntilPlaybackRuns() {
        var native = BufferingSignalMapper()
        _ = native.update(Self.snapshot(native: Self.avPlaying))
        _ = native.update(Self.snapshot(native: Self.avPlaying, seek: true))
        XCTAssertEqual(native.update(Self.snapshot(native: Self.avWaiting(.toMinimizeStalls))), [])
        XCTAssertEqual(native.update(Self.snapshot(native: Self.avPlaying)), [.playing])
        XCTAssertEqual(native.update(Self.snapshot(native: Self.avWaiting(.toMinimizeStalls))), [.waiting(.network)])

        var software = BufferingSignalMapper()
        _ = software.update(Self.snapshot())
        _ = software.update(Self.snapshot(phase: .seeking))
        XCTAssertEqual(software.update(Self.snapshot(phase: .rebuffering)), [])
        XCTAssertEqual(software.update(Self.snapshot()), [.playing])
    }

    /// A seek that lands while paused owns the buffering after Play until
    /// playback runs.
    func testBufferingAfterASeekMadeWhilePausedIsTheSeeks() {
        var mapper = BufferingSignalMapper()
        XCTAssertEqual(mapper.update(Self.snapshot(play: false, phase: .paused, native: Self.avPaused)), [.paused])
        XCTAssertEqual(mapper.update(Self.snapshot(play: false, phase: .paused, native: Self.avPaused, seek: true)), [])
        XCTAssertEqual(mapper.update(Self.snapshot(play: false, phase: .paused, native: Self.avPaused)), [])
        XCTAssertEqual(
            mapper.update(Self.snapshot(native: Self.avWaiting(.toMinimizeStalls))),
            [.waiting(.seek)],
            "Play after the landing waits on the seek"
        )
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying)), [.playing])
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avWaiting(.toMinimizeStalls))), [.waiting(.network)])
    }

    /// Aether tears the video down when the app leaves the foreground: a stall
    /// in progress ends as a pause, even after the item reported a stall.
    func testATornDownItemEndsAStallAsAPause() {
        var mapper = BufferingSignalMapper()
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying)), [.playing])
        mapper.noteItemStalled()
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPaused)), [.waiting(.network)])
        let tornDown = Transport(status: .paused, waitingReason: nil, hasItem: false)
        XCTAssertEqual(mapper.update(Self.snapshot(phase: .paused, native: tornDown)), [.paused])
        XCTAssertEqual(
            mapper.update(Self.snapshot(native: Self.avPaused)), [],
            "the old item's stall does not carry over to the rebuilt one"
        )
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

    /// The spec's renderer wait: a wait that begins with more than a second
    /// buffered is the decoder falling behind, until the buffer drains.
    func testAWaitWithMediaBufferedIsTheRenderersUntilTheBufferDrains() {
        var mapper = BufferingSignalMapper()
        let starved = { (ms: Int?) in Self.snapshot(native: Self.avWaiting(.toMinimizeStalls), bufferedMs: ms) }
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying, bufferedMs: 8_000)), [.playing])
        XCTAssertEqual(mapper.update(starved(3_000)), [.waiting(.renderer)])
        XCTAssertEqual(mapper.update(starved(1_001)), [], "still more than the threshold")
        XCTAssertEqual(mapper.update(starved(1_000)), [.waiting(.network)], "the stall begins as it drains")
        XCTAssertEqual(mapper.update(starved(5_000)), [], "a stall stays one until playback resumes")
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying, bufferedMs: 5_000)), [.playing])

        XCTAssertEqual(mapper.update(starved(900)), [.waiting(.network)], "an empty buffer is a stall at once")
        XCTAssertEqual(mapper.update(Self.snapshot(native: Self.avPlaying)), [.playing])
        XCTAssertEqual(mapper.update(starved(nil)), [.waiting(.network)], "an unknown buffer counts as empty")
    }

    /// AetherEngine's software host pauses its clock to rebuffer without
    /// reporting it, so a playing engine whose clock stopped is waiting.
    func testAFrozenSoftwareClockIsAWait() {
        var mapper = BufferingSignalMapper()
        XCTAssertEqual(mapper.update(Self.snapshot()), [.playing])
        XCTAssertEqual(mapper.update(Self.snapshot(frozen: true)), [.waiting(.network)], "starved")
        XCTAssertEqual(mapper.update(Self.snapshot()), [.playing], "the clock moved again")
        XCTAssertEqual(
            mapper.update(Self.snapshot(bufferedMs: 5_000, frozen: true)), [.waiting(.renderer)],
            "the decoder is behind, with media buffered"
        )
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

    private static func watchDetail() throws -> WatchDetail {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let version = try decoder.decode(FileVersion.self, from: Data(#"{"file_id":42}"#.utf8))
        return WatchDetail(
            contentId: "movie-1", type: "movie", title: "Movie", year: nil, overview: nil,
            versions: [version], subtitles: nil, intro: nil, credits: nil, userData: nil,
            seriesId: nil, seriesTitle: nil, seasonNumber: nil, episodeNumber: nil,
            effectiveSubtitleLanguage: nil, effectiveSubtitleMode: nil,
            effectiveShowForcedSubtitles: nil, effectiveSubtitleTrackSignature: nil
        )
    }

    /// `prepared` as the playing v3 plan, adopted by the buffering controller,
    /// so a quality pick takes `switchQuality`'s v3 path as in playback.
    private func play(_ prepared: PreparedPlaybackV3, on model: PlayerViewModel, quality: String) throws {
        model.installPlayingProtocolV3(watchDetail: try Self.watchDetail(), prepared: prepared)
        model.adoptBufferingPlan(prepared, sessionId: "session", activeQualityId: quality)
    }

    /// A lowering the server never answers keeps the current plan playing;
    /// it must not end playback the way a failed viewer switch does.
    func testAFailedLoweringKeepsPlaying() async throws {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        try play(try preparedPlan(), on: model, quality: "auto")

        // The bridge holds no session, so the replan comes back without a plan.
        model.issueBufferingReplan(.init(qualityPreference: "auto", bandwidthEstimateKbps: 5_600))
        XCTAssertTrue(model.isLoading, "the replan is under way")
        for _ in 0..<200 where model.isLoading && model.error == nil {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(model.error)
        XCTAssertFalse(model.isLoading)
    }

    /// An audio-session interruption pauses playback for the controller on
    /// every route, until it ends with a resume or the viewer plays.
    func testAnAudioInterruptionIsAPause() throws {
        let controller = try AetherPlaybackController()
        let center = NotificationCenter.default
        let began = AVAudioSession.InterruptionType.began.rawValue
        let ended = AVAudioSession.InterruptionType.ended.rawValue
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: began])
        XCTAssertTrue(controller.isAudioSessionInterrupted)
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: ended, AVAudioSessionInterruptionOptionKey: UInt(0)])
        XCTAssertTrue(controller.isAudioSessionInterrupted, "ended without a resume: still stopped")
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: ended,
                               AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        XCTAssertFalse(controller.isAudioSessionInterrupted)
        center.post(name: AVAudioSession.interruptionNotification, object: nil,
                    userInfo: [AVAudioSessionInterruptionTypeKey: began])
        controller.play()
        XCTAssertFalse(controller.isAudioSessionInterrupted, "the viewer played")
    }

    /// A Restore that arrives while a replan is in flight owes its clear
    /// until it goes out after that replan, then owes nothing.
    func testADeferredRestoreOwesItsClearOnce() async throws {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        let prepared = try preparedPlan()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let version = try decoder.decode(FileVersion.self, from: Data(#"{"file_id":42}"#.utf8))
        model.installPlayingProtocolV3(
            watchDetail: WatchDetail(
                contentId: "movie-1", type: "movie", title: "Movie", year: nil, overview: nil,
                versions: [version], subtitles: nil, intro: nil, credits: nil, userData: nil,
                seriesId: nil, seriesTitle: nil, seasonNumber: nil, episodeNumber: nil,
                effectiveSubtitleLanguage: nil, effectiveSubtitleMode: nil,
                effectiveShowForcedSubtitles: nil, effectiveSubtitleTrackSignature: nil
            ),
            prepared: prepared
        )
        model.adoptBufferingPlan(prepared, sessionId: "session", activeQualityId: "auto")

        model.issueBufferingReplan(.init(qualityPreference: "auto", bandwidthEstimateKbps: 5_600))
        var restore = BufferingQualityController.ReplanRequest(qualityPreference: "auto")
        restore.learnedLimit = PlaybackProtocolV3.LearnedLimit.clear
        model.issueBufferingReplan(restore)
        XCTAssertTrue(model.owesBufferingLearnedLimitClear, "held for the replan in flight")
        for _ in 0..<300 where model.owesBufferingLearnedLimitClear {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.owesBufferingLearnedLimitClear, "sent once that replan settled")
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
        XCTAssertEqual(picked.quality, "1080p-high", "the server's label for the quality asked for")
        XCTAssertNil(picked.activeQuality, "the fixture's server names no rung")
        XCTAssertFalse(picked.qualityReductionUnavailable)
    }

    /// Lower quality steps from the rung the server names in `active_quality`,
    /// or from the delivered bitrate when that is lower or no rung is named.
    func testLowerQualityStepsFromTheNamedRung() throws {
        let unnamed = PlayerViewModel.bufferingPlan(id: "1:p", prepared: try preparedPlan(), activeQualityId: "1080p-high")
        XCTAssertEqual(BufferingQualityController.lowerRung(in: unnamed)?.label, "1080p-high", "the rung below 8000")

        func named(_ rung: String) throws -> BufferingQualityController.Plan {
            let base = try preparedPlan()
            var plan = base.plan
            plan.activeQuality = rung
            let reported = PreparedPlaybackV3(
                playbackAttemptId: base.playbackAttemptId, planAttemptId: base.planAttemptId,
                planAttemptKey: base.planAttemptKey, outputContextId: base.outputContextId,
                serverFeatures: base.serverFeatures + [PlaybackProtocolV3.planActiveQualityFeature],
                plan: plan
            )
            return PlayerViewModel.bufferingPlan(id: "1:p", prepared: reported, activeQualityId: "1080p-high")
        }
        let high = try named("1080p-high")
        XCTAssertEqual(high.quality, "1080p-high", "still the quality asked for")
        XCTAssertEqual(high.activeQuality, "1080p-high")
        XCTAssertEqual(BufferingQualityController.lowerRung(in: high)?.label, "720p-high", "below the named 6000")
        XCTAssertNil(BufferingQualityController.lowerRung(in: try named("720p-high")), "nothing below the named 4000")
        XCTAssertEqual(
            BufferingQualityController.lowerRung(in: try named("2160p-ultra"))?.label, "1080p-high",
            "a rung that matches no entry: from the delivered 8000"
        )
    }

    /// A picked quality is asked about even in `always`: shows the prompt.
    private func showPrompt(on model: PlayerViewModel, clock: ManualBufferingQualityClock) throws {
        try play(try preparedPlan(), on: model, quality: "1080p-high")
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
        XCTAssertNil(model.qualitySwitchError, "the player took the pick")
        XCTAssertNil(model.bufferingPill)
    }

    /// A pick the player refuses, here because a replan is already in
    /// flight, is not a quality change: the prompt stays.
    func testARefusedQualityPickKeepsTheBufferingPill() throws {
        let clock = ManualBufferingQualityClock()
        let model = PlayerViewModel(bufferingQualityClock: clock)
        defer { model.cleanup() }
        try showPrompt(on: model, clock: clock)
        model.issueBufferingReplan(.init(qualityPreference: "auto", bandwidthEstimateKbps: 5_600))
        XCTAssertTrue(model.isLoading, "a replan is in flight")
        model.switchQuality("720p")
        XCTAssertNotNil(model.qualitySwitchError, "the player refused the pick")
        XCTAssertEqual(model.bufferingPill?.kind, .prompt)
    }

    /// A lowering's estimate rides on the player's own Auto replans until the
    /// viewer picks a quality.
    func testTheViewersQualityPickDropsTheKeptEstimate() throws {
        let clock = ManualBufferingQualityClock()
        let model = PlayerViewModel(bufferingQualityClock: clock)
        defer { model.cleanup() }
        try play(try preparedPlan(), on: model, quality: "auto")
        model.bufferingQuality.mode = .always
        model.bufferingQuality.playing()
        clock.advance(to: 20_000)
        model.bufferingQuality.waiting(cause: .network)
        clock.advance(to: 26_000)
        XCTAssertEqual(model.bufferingQuality.keptEstimateKbps, 5_600, "7/10 of the plan's 8000 kbps")
        XCTAssertEqual(
            model.bufferingQuality.clientReplan(operation: PlaybackProtocolV3.ReplanOperation.trackChange)?
                .bandwidthEstimateKbps,
            5_600
        )

        model.switchQuality("720p")
        XCTAssertNil(model.qualitySwitchError, "the player took the pick")
        XCTAssertNil(model.bufferingQuality.keptEstimateKbps)
    }

    /// Which replans repeat the kept estimate: the player's own, never the
    /// controller's or a quality change.
    func testOnlyThePlayersOwnReplansRepeatTheKeptEstimate() throws {
        let clock = ManualBufferingQualityClock()
        let model = PlayerViewModel(bufferingQualityClock: clock)
        defer { model.cleanup() }
        model.adoptBufferingPlan(try preparedPlan(), sessionId: "session", activeQualityId: "auto")
        model.bufferingQuality.mode = .always
        model.bufferingQuality.playing()
        clock.advance(to: 20_000)
        model.bufferingQuality.waiting(cause: .network)
        clock.advance(to: 26_000)
        let kept = { (operation: String, controllers: Bool) in
            PlayerViewModel.keptReplanEstimateKbps(
                operation: operation, issuedByBufferingQuality: controllers, controller: model.bufferingQuality
            )
        }
        XCTAssertEqual(kept(PlaybackProtocolV3.ReplanOperation.seekReanchor, false), 5_600)
        XCTAssertEqual(kept(PlaybackProtocolV3.ReplanOperation.trackChange, false), 5_600)
        XCTAssertNil(kept(PlaybackProtocolV3.ReplanOperation.qualityChange, false))
        XCTAssertNil(kept(PlaybackProtocolV3.ReplanOperation.seekReanchor, true))
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

    /// Picture in picture or the app in the background shows no pills, so a
    /// pill waits with the rest of its timer, as behind another pill.
    func testABackgroundedPlayerHoldsTheBufferingPill() async throws {
        let clock = ManualBufferingQualityClock()
        let model = PlayerViewModel(bufferingQualityClock: clock)
        defer { model.cleanup() }
        try showPrompt(on: model, clock: clock)

        NotificationCenter.default.post(name: backgroundNotification, object: nil)
        await eventually { model.bufferingPill == nil }
        XCTAssertNil(model.bufferingPill)
        clock.advance(to: 60_000)

        NotificationCenter.default.post(name: foregroundNotification, object: nil)
        await eventually { model.bufferingPill != nil }
        XCTAssertEqual(model.bufferingPill?.kind, .prompt, "its timer did not run out unseen")
    }

    /// A sheet over the player hides its pills the same way.
    func testASheetOverThePlayerHoldsTheBufferingPill() async throws {
        let clock = ManualBufferingQualityClock()
        let model = PlayerViewModel(bufferingQualityClock: clock)
        defer { model.cleanup() }
        try showPrompt(on: model, clock: clock)

        model.playerSheetCoversPlayer(true)
        await eventually { model.bufferingPill == nil }
        XCTAssertNil(model.bufferingPill)
        clock.advance(to: 60_000)

        model.playerSheetCoversPlayer(false)
        await eventually { model.bufferingPill != nil }
        XCTAssertEqual(model.bufferingPill?.kind, .prompt, "its timer did not run out unseen")
    }

    /// A buffering notice is information. It waits while another notice
    /// holds the slot or the player can't show it, then shows.
    func testABufferingNoticeWaitsForTheSlot() async {
        let model = PlayerViewModel()
        defer { model.cleanup() }
        let other = PlayerNotice(title: "Other", message: "", tone: .warning)
        model.activeNotice = other
        model.playerSheetCoversPlayer(true)
        model.bufferingQuality.onOutput?(.notice(.cantLower))
        XCTAssertEqual(model.presentedNotice, other)

        model.activeNotice = nil
        await eventually { model.presentedNotice != nil }
        XCTAssertNil(model.presentedNotice, "the sheet still covers the player")

        model.playerSheetCoversPlayer(false)
        await eventually { model.presentedNotice != nil }
        XCTAssertEqual(model.presentedNotice?.title, BufferingQualityController.cantLowerNotice)
        XCTAssertEqual(model.presentedNotice?.tone, .info)
    }

    private let backgroundNotification = UIApplication.didEnterBackgroundNotification
    private let foregroundNotification = UIApplication.willEnterForegroundNotification

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
