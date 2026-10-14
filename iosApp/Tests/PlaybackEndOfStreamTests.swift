import AetherEngine
import XCTest
@testable import Silo

/// An end of stream from a source that went away (a seek past the buffer
/// while the server is down) is a lost connection, not the item finishing
/// (playback protocol v3 §6.2).
final class PlaybackEndOfStreamTests: XCTestCase {
    private let hour: Double = 3600

    // MARK: - Lost connection or natural end

    func testFailingSourceShortOfTheEndReconnectsAtThePlayhead() {
        XCTAssertEqual(
            PlaybackReconnectPolicy.endOfStreamReconnectPosition(
                playhead: 2160, duration: hour, sourceStalled: true, serverUnreachable: false,
                delivery: nil, lastEndReconnect: nil
            ),
            2160
        )
        // The app's own requests failing is enough when the engine's stall
        // was not seen.
        XCTAssertEqual(
            PlaybackReconnectPolicy.endOfStreamReconnectPosition(
                playhead: 2160, duration: hour, sourceStalled: false, serverUnreachable: true,
                delivery: nil, lastEndReconnect: nil
            ),
            2160
        )
        // A source that fails again where the last reconnect resumed is still
        // failing; only a clean end there is the end of the media.
        XCTAssertEqual(
            PlaybackReconnectPolicy.endOfStreamReconnectPosition(
                playhead: 2160, duration: hour, sourceStalled: true, serverUnreachable: false,
                delivery: PlaybackProtocolV3.PlanDelivery.transcodeHLS, lastEndReconnect: 2160
            ),
            2160
        )
    }

    func testEndAtTheEndIsNaturalEvenWhileTheSourceFails() {
        for playhead in [hour - 8, hour - 1, hour * 0.99, hour] {
            XCTAssertNil(
                PlaybackReconnectPolicy.endOfStreamReconnectPosition(
                    playhead: playhead, duration: hour, sourceStalled: true, serverUnreachable: true,
                    delivery: nil, lastEndReconnect: nil
                ),
                "playhead \(playhead)"
            )
        }
    }

    func testHealthySourceKeepsTheReportedEnd() {
        XCTAssertNil(
            PlaybackReconnectPolicy.endOfStreamReconnectPosition(
                playhead: 2160, duration: hour, sourceStalled: false, serverUnreachable: false,
                delivery: nil, lastEndReconnect: nil
            )
        )
    }

    /// A server restart loses the session a remux or transcode is produced
    /// from. AVPlayer skips the segments it then refuses and ends cleanly at
    /// the end of its buffer, with no stall and the API still answering.
    func testServerProducedStreamThatEndsEarlyReconnects() {
        let deliveries = [
            PlaybackProtocolV3.PlanDelivery.transcodeHLS,
            PlaybackProtocolV3.PlanDelivery.remuxHLS,
            PlaybackProtocolV3.PlanDelivery.remuxProgressive,
        ]
        for delivery in deliveries {
            XCTAssertEqual(
                PlaybackReconnectPolicy.endOfStreamReconnectPosition(
                    playhead: 2394, duration: 3003, sourceStalled: false, serverUnreachable: false,
                    delivery: delivery, lastEndReconnect: nil
                ),
                2394,
                delivery
            )
        }
    }

    /// A later restart ends the stream again further on; that is another
    /// lost session, not the same end.
    func testServerProducedStreamThatEndsEarlyAgainFurtherOnReconnects() {
        for playhead in [2396.1, 2700] {
            XCTAssertEqual(
                PlaybackReconnectPolicy.endOfStreamReconnectPosition(
                    playhead: playhead, duration: 3003, sourceStalled: false, serverUnreachable: false,
                    delivery: PlaybackProtocolV3.PlanDelivery.transcodeHLS, lastEndReconnect: 2394
                ),
                playhead
            )
        }
    }

    func testEarlyEndThatIsNoLostSessionKeepsTheReportedEnd() {
        let transcode = PlaybackProtocolV3.PlanDelivery.transcodeHLS
        let cases: [(String, String?, Double, Double?)] = [
            // The reconnect's stream ended where the last one did, even when
            // it restarted a segment before it: that is where the media
            // ends, and reconnecting would replay the same tail.
            ("same end again", transcode, 2394.2, 2394),
            ("same end, a frame early", transcode, 2393.96, 2394),
            ("same end, just inside the window", transcode, 2395.9, 2394),
            // The engine reconnects an original file itself.
            ("original file", PlaybackProtocolV3.PlanDelivery.originalHTTP, 2394, nil),
            ("unknown delivery", nil, 2394, nil),
            ("natural end", transcode, 2990, nil),
            ("an end at the start", transcode, 0, nil),
        ]
        for (label, delivery, playhead, lastEndReconnect) in cases {
            XCTAssertNil(
                PlaybackReconnectPolicy.endOfStreamReconnectPosition(
                    playhead: playhead, duration: 3003, sourceStalled: false, serverUnreachable: false,
                    delivery: delivery, lastEndReconnect: lastEndReconnect
                ),
                label
            )
        }
    }

    func testUnknownDurationKeepsTheReportedEnd() {
        for duration in [0, -1, .nan, .infinity] {
            XCTAssertNil(
                PlaybackReconnectPolicy.endOfStreamReconnectPosition(
                    playhead: 2160, duration: duration, sourceStalled: true, serverUnreachable: true,
                    delivery: nil, lastEndReconnect: nil
                ),
                "duration \(duration)"
            )
        }
    }

    // MARK: - Playhead

    func testSeekPastTheBufferOverADeadSourceKeepsTheSeekTarget() {
        var watch = PlaybackSourceWatch()
        watch.observe(.playing)
        watch.observePlayhead(20)
        watch.seekCommitted(to: 2160)
        watch.observe(.seeking)
        watch.observe(.stalled(reconnecting: true))
        // Aether's clock runs on without a frame, then the reader gives up
        // and the clock parks wherever it got to.
        for time in stride(from: 2160.0, through: 3598, by: 1) {
            watch.observePlayhead(time)
        }
        watch.observe(.stalled(reconnecting: false))
        watch.observe(.ended)

        XCTAssertTrue(watch.isStalled)
        XCTAssertEqual(watch.playhead(currentTime: 3598), 2160)
        XCTAssertEqual(
            PlaybackReconnectPolicy.endOfStreamReconnectPosition(
                playhead: watch.playhead(currentTime: 3598),
                duration: hour,
                sourceStalled: watch.isStalled,
                serverUnreachable: false,
                delivery: nil,
                lastEndReconnect: nil
            ),
            2160
        )
    }

    func testClockJumpingToTheEndDoesNotPlayFromTheTarget() {
        // The clock can land on a parked end of media before the engine
        // reports the stall; one step that far is not playback.
        var watch = PlaybackSourceWatch()
        watch.seekCommitted(to: 2160)
        watch.observe(.playing)
        watch.observePlayhead(hour)
        watch.observe(.stalled(reconnecting: false))
        XCTAssertEqual(watch.playhead(currentTime: hour), 2160)
    }

    func testSeekWhileStalledMovesTheTarget() {
        var watch = PlaybackSourceWatch()
        watch.observe(.stalled(reconnecting: true))
        watch.seekCommitted(to: 600)
        watch.seekCommitted(to: 2160)
        XCTAssertEqual(watch.playhead(currentTime: 2200), 2160)
    }

    func testPlaybackFromTheTargetHandsThePlayheadBackToTheClock() {
        var watch = PlaybackSourceWatch()
        watch.seekCommitted(to: 2160)
        watch.observe(.seeking)
        // A seek that lands, even briefly reported as playing, has not
        // played from the target until the clock moves on with the source
        // delivering.
        watch.observe(.playing)
        watch.observePlayhead(2161)
        XCTAssertEqual(watch.playhead(currentTime: 2161), 2160)

        watch.observePlayhead(2162)
        XCTAssertNil(watch.unconfirmedSeekTarget)
        XCTAssertEqual(watch.playhead(currentTime: 2400), 2400)
    }

    func testSeekWithinTheBufferOverAStalledSourcePlaysFromTheTarget() {
        // The server is down, but the engine still plays from its read-ahead
        // buffer. A seek inside that buffer plays, so a later reconnect
        // resumes where playback got to, not at the seek target.
        var watch = PlaybackSourceWatch()
        watch.observe(.stalled(reconnecting: true))
        watch.seekCommitted(to: 600)
        watch.observePlayhead(601, hasMediaAhead: true)
        XCTAssertEqual(watch.playhead(currentTime: 601), 600)
        watch.observePlayhead(602, hasMediaAhead: true)
        XCTAssertNil(watch.unconfirmedSeekTarget)
        XCTAssertTrue(watch.isStalled)
        XCTAssertEqual(watch.playhead(currentTime: 780), 780)
    }

    func testRunningClockWithNothingBufferedOverAStalledSourceKeepsTheTarget() {
        var watch = PlaybackSourceWatch()
        watch.observe(.stalled(reconnecting: true))
        watch.seekCommitted(to: 2160)
        for time in stride(from: 2160.0, through: 2200, by: 1) {
            watch.observePlayhead(time, hasMediaAhead: false)
        }
        XCTAssertEqual(watch.playhead(currentTime: 2200), 2160)
    }

    func testSourceDeliveringAgainClearsTheStall() {
        var watch = PlaybackSourceWatch()
        watch.observe(.stalled(reconnecting: true))
        watch.observe(.loading)
        XCTAssertTrue(watch.isStalled)
        for phase: PlaybackPhase in [.playing, .paused, .seeking, .rebuffering] {
            watch.observe(.stalled(reconnecting: false))
            watch.observe(phase)
            XCTAssertFalse(watch.isStalled, "\(phase)")
        }
    }

    // MARK: - Natural end window

    func testNaturalEndWindowMatchesTheNearEndErrorRule() {
        XCTAssertTrue(PlaybackReconnectPolicy.isBeforeNaturalEnd(position: 2160, duration: hour))
        XCTAssertTrue(PlaybackReconnectPolicy.isBeforeNaturalEnd(position: 0, duration: hour))
        XCTAssertFalse(PlaybackReconnectPolicy.isBeforeNaturalEnd(position: hour - 8, duration: hour))
        // 98.5 % of an hour is 54 s from the end.
        XCTAssertFalse(PlaybackReconnectPolicy.isBeforeNaturalEnd(position: hour * 0.985, duration: hour))
        XCTAssertTrue(PlaybackReconnectPolicy.isBeforeNaturalEnd(position: hour * 0.98, duration: hour))
    }
}
