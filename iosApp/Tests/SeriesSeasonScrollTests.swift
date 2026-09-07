import XCTest
@testable import Silo

final class SeriesSeasonScrollTests: XCTestCase {
    func testForwardAndBackwardTripsAreMonotonicAndFinishAtTheirDestination() {
        for (start, target): (CGFloat, CGFloat) in [(0, 8000), (8000, 0)] {
            let motion = SeriesSeasonScroll(startOffset: start, targetOffset: target, startedAt: 10)
            let samples = (0...60).map { motion.offset(at: 10 + Double($0) / 60) }
            for (previous, next) in zip(samples, samples.dropFirst()) {
                XCTAssertGreaterThanOrEqual((next - previous) * (target - start), 0)
            }
            XCTAssertEqual(samples.first, start)
            XCTAssertEqual(samples.last, target)
            XCTAssertTrue(motion.isComplete(at: 11))
        }
    }

    func testPrependingOrEvictingASeasonPreservesVisibleMotionAndCompletionTime() {
        let original = SeriesSeasonScroll(startOffset: 12000, targetOffset: 18000, startedAt: 10)
        for shift: CGFloat in [-8000, 8000] {
            var rebased = original
            rebased.rebase(by: shift)
            for frame in 0...60 {
                let time = 10 + Double(frame) / 60
                // Subtracting the changed origin gives exactly the same
                // screen-space position, including halfway through a trip.
                XCTAssertEqual(rebased.offset(at: time) - shift, original.offset(at: time), accuracy: 0.000001)
                XCTAssertEqual(rebased.isComplete(at: time), original.isComplete(at: time))
            }
        }
    }

    func testChangingDirectionStartsAtTheVisiblePosition() {
        let first = SeriesSeasonScroll(startOffset: 0, targetOffset: 8000, startedAt: 10)
        let visible = first.offset(at: 10.2)
        let replacement = SeriesSeasonScroll(startOffset: visible, targetOffset: 0, startedAt: 10.2)
        XCTAssertEqual(replacement.offset(at: 10.2), visible)
        XCTAssertLessThan(replacement.offset(at: 10.3), visible)
        XCTAssertEqual(replacement.offset(at: 11), 0)
    }

    func testFrameBeforeStartCannotOvershoot() {
        let motion = SeriesSeasonScroll(startOffset: 400, targetOffset: 8000, startedAt: 10)
        XCTAssertEqual(motion.offset(at: 9.99), 400)
        XCTAssertFalse(motion.isComplete(at: 9.99))
    }

    func testEpisodeMoveKeepsItsDeadlineWhenAPageArrivesMidAnimation() {
        let original = SeriesSeasonScroll(
            startOffset: 400, targetOffset: 800, startedAt: 10, timing: .episode
        )
        var rebased = original
        rebased.rebase(by: 8800)

        for frame in 0...30 {
            let time = 10 + Double(frame) / 100
            XCTAssertEqual(rebased.offset(at: time) - 8800, original.offset(at: time), accuracy: 0.000001)
        }
        XCTAssertFalse(rebased.isComplete(at: 10.29))
        XCTAssertTrue(rebased.isComplete(at: 10.30))
        XCTAssertEqual(rebased.offset(at: 10.30), 9600, accuracy: 0.000001)
    }

    func testBothScrollTimingsStayWithinBoundsInEitherDirection() {
        for timing in [SeriesSeasonScroll.Timing.season, .episode] {
            for (start, target): (CGFloat, CGFloat) in [(0, 8800), (8800, 0)] {
                let motion = SeriesSeasonScroll(
                    startOffset: start, targetOffset: target, startedAt: 10, timing: timing
                )
                let samples = (0...60).map { motion.offset(at: 10 + Double($0) / 60) }
                for (previous, next) in zip(samples, samples.dropFirst()) {
                    XCTAssertGreaterThanOrEqual((next - previous) * (target - start), 0)
                    XCTAssertGreaterThanOrEqual(next, min(start, target))
                    XCTAssertLessThanOrEqual(next, max(start, target))
                }
                XCTAssertEqual(samples.last, target)
            }
        }
    }

}
