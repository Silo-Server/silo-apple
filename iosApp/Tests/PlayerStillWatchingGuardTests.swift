import XCTest
@testable import Silo

final class PlayerStillWatchingGuardTests: XCTestCase {
    func testAllowsThresholdAutoAdvancesThenGates() {
        var guardState = PlayerStillWatchingGuard()
        for _ in 0..<2 { guardState.recordAutoAdvance() }
        XCTAssertFalse(guardState.shouldGate(threshold: 3))
        guardState.recordAutoAdvance()
        XCTAssertTrue(guardState.shouldGate(threshold: 3))
    }

    func testViewerActionClearsStreak() {
        var guardState = PlayerStillWatchingGuard()
        for _ in 0..<3 { guardState.recordAutoAdvance() }
        guardState.recordViewerAction()
        XCTAssertFalse(guardState.shouldGate(threshold: 3))
    }

    func testThresholdZeroNeverGates() {
        var guardState = PlayerStillWatchingGuard()
        for _ in 0..<25 { guardState.recordAutoAdvance() }
        XCTAssertFalse(guardState.shouldGate(threshold: 0))
    }
}
