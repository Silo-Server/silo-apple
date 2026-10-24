#if os(iOS)
import XCTest
@testable import Silo

final class MobileScrubDragTests: XCTestCase {
    private let width: CGFloat = 400

    func testOnTheBarThePlayheadFollowsTheFinger() {
        var drag = MobileScrubDrag(startX: 100, width: width)
        XCTAssertEqual(drag.fraction, 0.25, accuracy: 0.0001)
        drag.move(toX: 300, heightAboveBar: 10, width: width)
        XCTAssertEqual(drag.speed, .full)
        XCTAssertEqual(drag.fraction, 0.75, accuracy: 0.0001)
    }

    func testSpeedSlowsOneStepPerTierAboveTheBar() {
        XCTAssertEqual(MobileScrubSpeed(heightAboveBar: -40), .full)
        XCTAssertEqual(MobileScrubSpeed(heightAboveBar: 49), .full)
        XCTAssertEqual(MobileScrubSpeed(heightAboveBar: 50), .half)
        XCTAssertEqual(MobileScrubSpeed(heightAboveBar: 100), .quarter)
        XCTAssertEqual(MobileScrubSpeed(heightAboveBar: 150), .fine)
        XCTAssertEqual(MobileScrubSpeed(heightAboveBar: 600), .fine)
    }

    /// Changing speed never jumps the playhead, including on the way back
    /// down to the bar; travel after that moves it at the new speed.
    func testSpeedChangesKeepThePlayheadInPlace() {
        var drag = MobileScrubDrag(startX: 200, width: width)
        drag.move(toX: 200, heightAboveBar: 160, width: width)
        XCTAssertEqual(drag.speed, .fine)
        XCTAssertEqual(drag.fraction, 0.5, accuracy: 0.0001)

        drag.move(toX: 300, heightAboveBar: 160, width: width)
        XCTAssertEqual(drag.fraction, 0.525, accuracy: 0.0001)

        drag.move(toX: 300, heightAboveBar: 0, width: width)
        XCTAssertEqual(drag.speed, .full)
        XCTAssertEqual(drag.fraction, 0.525, accuracy: 0.0001)

        drag.move(toX: 340, heightAboveBar: 0, width: width)
        XCTAssertEqual(drag.fraction, 0.625, accuracy: 0.0001)
    }

    /// At full speed, dragging past the end of the bar pins the playhead
    /// there, and coming back moves it straight away rather than after the
    /// overshoot.
    func testOvershootingTheBarEndDoesNotOffsetThePlayhead() {
        var drag = MobileScrubDrag(startX: 390, width: width)
        drag.move(toX: 520, heightAboveBar: 0, width: width)
        XCTAssertEqual(drag.fraction, 1)
        drag.move(toX: 390, heightAboveBar: 0, width: width)
        XCTAssertEqual(drag.fraction, 0.975, accuracy: 0.0001)
    }

    /// Below full speed, travel past the end of the bar isn't banked:
    /// turning back moves the playhead straight away.
    func testReducedSpeedOvershootDoesNotStickAtTheEnd() {
        var drag = MobileScrubDrag(startX: 396, width: width)
        drag.move(toX: 200, heightAboveBar: 160, width: width)
        drag.move(toX: 300, heightAboveBar: 160, width: width)
        XCTAssertEqual(drag.fraction, 1)
        drag.move(toX: 290, heightAboveBar: 160, width: width)
        XCTAssertEqual(drag.fraction, 0.9975, accuracy: 0.0001)
    }
}
#endif
