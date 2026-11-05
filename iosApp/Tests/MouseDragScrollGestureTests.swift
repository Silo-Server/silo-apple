import XCTest
@testable import Silo

final class MouseDragScrollGestureTests: XCTestCase {
    private let start = CGPoint(x: 100, y: 100)

    func testSmallWobbleStaysAClick() {
        var gesture = MouseDragScrollGesture(start: start, time: 0)
        XCTAssertFalse(gesture.move(to: CGPoint(x: 103, y: 102), time: 0.05))
        XCTAssertEqual(gesture.phase, .pending)
        XCTAssertEqual(gesture.releaseVelocity(at: 0.06), 0)
    }

    func testSidewaysTravelBecomesADragThatFollowsThePointer() {
        var gesture = MouseDragScrollGesture(start: start, time: 0)
        XCTAssertTrue(gesture.move(to: CGPoint(x: 92, y: 101), time: 0.02))
        XCTAssertEqual(gesture.phase, .dragging)
        XCTAssertEqual(gesture.translation, -8)

        // Once dragging, moving back within the threshold keeps it a drag.
        XCTAssertTrue(gesture.move(to: CGPoint(x: 99, y: 100), time: 0.04))
        XCTAssertEqual(gesture.phase, .dragging)
        XCTAssertEqual(gesture.translation, -1)
    }

    func testMostlyVerticalTravelIsLeftAlone() {
        var gesture = MouseDragScrollGesture(start: start, time: 0)
        XCTAssertFalse(gesture.move(to: CGPoint(x: 104, y: 112), time: 0.02))
        XCTAssertEqual(gesture.phase, .ignored)
        // A later sideways move doesn't turn it into a rail drag.
        XCTAssertFalse(gesture.move(to: CGPoint(x: 160, y: 112), time: 0.1))
        XCTAssertEqual(gesture.releaseVelocity(at: 0.11), 0)
    }

    func testReleaseVelocityUsesRecentMotion() {
        var gesture = MouseDragScrollGesture(start: start, time: 0)
        for step in 1...10 {
            gesture.move(to: CGPoint(x: 100 + CGFloat(step) * 10, y: 100), time: Double(step) * 0.01)
        }
        // 10 points every 10 ms.
        XCTAssertEqual(gesture.releaseVelocity(at: 0.1), 1_000, accuracy: 1)
    }

    func testFlickArrivingAsOneMoveAfterAHoldStillGlides() {
        var gesture = MouseDragScrollGesture(start: start, time: 0)
        // Held still, then the whole flick lands in one drag event.
        XCTAssertTrue(gesture.move(to: CGPoint(x: 300, y: 100), time: 0.2))
        XCTAssertEqual(gesture.releaseVelocity(at: 0.205), 1_000, accuracy: 1)
    }

    func testFlickAfterAHoldMeasuresOnlyTheRecentMotion() {
        var gesture = MouseDragScrollGesture(start: start, time: 0)
        // Held still for a second, then 20 points every 10 ms.
        for step in 1...5 {
            gesture.move(to: CGPoint(x: 100 + CGFloat(step) * 20, y: 100), time: 1 + Double(step) * 0.01)
        }
        XCTAssertEqual(gesture.releaseVelocity(at: 1.05), 2_000, accuracy: 1)
    }

    func testPausingBeforeReleaseCancelsTheFling() {
        var gesture = MouseDragScrollGesture(start: start, time: 0)
        gesture.move(to: CGPoint(x: 140, y: 100), time: 0.02)
        XCTAssertEqual(gesture.releaseVelocity(at: 0.5), 0)
    }

    func testMomentumSlowsToAStopIndependentOfFrameRate() {
        var coarse = MouseDragScrollMomentum(velocity: 2_000)
        var fine = MouseDragScrollMomentum(velocity: 2_000)
        var coarseDistance: CGFloat = 0
        var fineDistance: CGFloat = 0
        for _ in 0..<60 { coarseDistance += coarse.step(by: 1.0 / 60.0) }
        for _ in 0..<120 { fineDistance += fine.step(by: 1.0 / 120.0) }
        XCTAssertEqual(coarseDistance, fineDistance, accuracy: 0.5)
        XCTAssertLessThan(coarse.velocity, 2_000)

        while !coarse.isFinished { coarseDistance += coarse.step(by: 1.0 / 60.0) }
        // Total glide is about half a second of the release speed.
        XCTAssertEqual(coarseDistance, 1_000, accuracy: 20)
    }
}
