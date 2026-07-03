import XCTest
@testable import Silo

final class GeneratedAheadThrottlePolicyTests: XCTestCase {
    func testThrottleWaitBudgetStaysBelowLivePlaylistReloadFailureWindow() {
        let targetDuration = 4.0
        let budget = LoopbackSegmentWriter.generatedAheadThrottleWaitBudgetSeconds(
            targetDuration: targetDuration
        )

        XCTAssertLessThan(budget, targetDuration * 1.5)
    }

    func testThrottleWaitBudgetHasSmallFloorForShortSegments() {
        XCTAssertEqual(
            LoopbackSegmentWriter.generatedAheadThrottleWaitBudgetSeconds(targetDuration: 0.5),
            0.5
        )
    }
}
