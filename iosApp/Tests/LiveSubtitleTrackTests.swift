import XCTest
@testable import Silo

/// Contract tests for the app-owned, engine-neutral realtime subtitle seam.
final class LiveSubtitleTrackTests: XCTestCase {
    func testCueUsesSourceTimeMilliseconds() {
        var track = LiveSubtitleTrack()

        let cue = track.makeCue(start: 1.2345, end: 4.25, text: "Hello")

        XCTAssertEqual(cue?.text, "Hello")
        XCTAssertEqual(cue?.startMs, 1_235)
        XCTAssertEqual(cue?.endMs, 4_250)
        XCTAssertEqual(cue?.durationMs, 3_015)
        XCTAssertEqual(cue?.startTime ?? -1, 1.235, accuracy: 0.000_1)
        XCTAssertEqual(cue?.endTime ?? -1, 4.25, accuracy: 0.000_1)
    }

    func testTextNormalizationPreservesContentWithoutEngineMarkup() {
        var track = LiveSubtitleTrack()

        let cue = track.makeCue(
            start: 0,
            end: 1,
            text: "  {\\b1}literal\\path\r\nsecond line  "
        )

        XCTAssertEqual(cue?.text, "{\\b1}literal\\path\nsecond line")
    }

    func testInvalidOrEmptyCueIsRejected() {
        var track = LiveSubtitleTrack()

        XCTAssertNil(track.makeCue(start: .nan, end: 1, text: "x"))
        XCTAssertNil(track.makeCue(start: 0, end: .infinity, text: "x"))
        XCTAssertNil(track.makeCue(start: 2, end: 2, text: "x"))
        XCTAssertNil(track.makeCue(start: 3, end: 2, text: "x"))
        XCTAssertNil(track.makeCue(start: 0, end: 1, text: " \n "))
    }

    func testNegativeStartClampsToZero() {
        var track = LiveSubtitleTrack()

        let cue = track.makeCue(start: -5, end: 1, text: "x")

        XCTAssertEqual(cue?.startMs, 0)
        XCTAssertEqual(cue?.endMs, 1_000)
    }

    func testHugeFiniteTimestampClampsToInt64Max() {
        var track = LiveSubtitleTrack()

        let cue = track.makeCue(
            start: 1,
            end: Double.greatestFiniteMagnitude,
            text: "x"
        )

        XCTAssertEqual(cue?.endMs, Int64.max)
    }

    func testDuplicateNormalizedCueIsDropped() {
        var track = LiveSubtitleTrack()

        XCTAssertNotNil(track.makeCue(start: 1, end: 2, text: " same\r\nline "))
        XCTAssertNil(track.makeCue(start: 1, end: 2, text: "same\nline"))
    }

    func testDifferentTextOrTimeIsNotDuplicate() {
        var track = LiveSubtitleTrack()

        XCTAssertNotNil(track.makeCue(start: 1, end: 2, text: "alpha"))
        XCTAssertNotNil(track.makeCue(start: 1, end: 2, text: "beta"))
        XCTAssertNotNil(track.makeCue(start: 2, end: 3, text: "alpha"))
    }

    func testOverlappingAndOutOfOrderCuesRetainTheirOwnTimes() {
        var track = LiveSubtitleTrack()

        let later = track.makeCue(start: 10, end: 12, text: "later")
        let earlier = track.makeCue(start: 1, end: 5, text: "earlier")
        let overlap = track.makeCue(start: 2, end: 4, text: "overlap")

        XCTAssertEqual(later?.startMs, 10_000)
        XCTAssertEqual(earlier?.startMs, 1_000)
        XCTAssertEqual(overlap?.startMs, 2_000)
        XCTAssertEqual(overlap?.endMs, 4_000)
    }
}
