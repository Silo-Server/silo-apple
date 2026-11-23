import XCTest
@testable import Silo

/// `/sync/progress` judges offline progress by percentage alone, so a
/// download stopped in its end credits goes up at the end of the file for
/// the server to store it watched. Any other stop keeps its real position,
/// so the server's own watched threshold still decides.
@MainActor
final class OfflineCreditsProgressTests: XCTestCase {
    // A 2600 s episode whose end credits start at 2200 s (84.6%).
    private let duration = 2_600.0
    private let creditsStart = 2_200.0

    func testStopInTheCreditsBelowNinetyPercentGoesUpAsFinished() {
        let sample = sample(at: 2_250)
        XCTAssertTrue(sample.completed)
        XCTAssertEqual(sample.queuedPosition, duration)
    }

    func testStopBeforeTheCreditsKeepsItsPosition() {
        let sample = sample(at: 2_190)
        XCTAssertFalse(sample.completed)
        XCTAssertEqual(sample.queuedPosition, 2_190)
    }

    /// Past the player's 90% default but before any credits: the device
    /// counts it watched, while the server applies its own threshold to the
    /// real position, which may be set higher.
    func testStopPastNinetyPercentWithoutCreditsKeepsItsPosition() {
        let sample = PlayerViewModel.offlineProgressSample(
            position: 2_400, duration: duration, markCompleted: false, endCreditsStart: nil
        )
        XCTAssertTrue(sample.completed)
        XCTAssertEqual(sample.queuedPosition, 2_400)
    }

    func testUnknownDurationIgnoresTheCredits() {
        let sample = PlayerViewModel.offlineProgressSample(
            position: 2_250, duration: 0, markCompleted: false, endCreditsStart: creditsStart
        )
        XCTAssertFalse(sample.completed)
        XCTAssertEqual(sample.queuedPosition, 2_250)
    }

    private func sample(at position: Double) -> (completed: Bool, queuedPosition: Double) {
        PlayerViewModel.offlineProgressSample(
            position: position, duration: duration, markCompleted: false, endCreditsStart: creditsStart
        )
    }
}
