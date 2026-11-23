import XCTest
@testable import Silo

/// The player's sleep timer pickers (the iPhone settings sheet and the Apple
/// TV menu) drive the timer with one call per pick: a duration starts it
/// over, and Off, which is 0, cancels it.
@MainActor
final class SleepTimerTests: XCTestCase {
    func testPickingADurationRestartsTheTimerAndOffCancelsIt() {
        let timer = SleepTimer()
        addTeardownBlock { @MainActor in timer.cancel() }

        timer.start(minutes: 15)
        XCTAssertTrue(timer.isActive)
        XCTAssertEqual(timer.remainingSeconds, 15 * 60)
        XCTAssertEqual(timer.selectedDurationOption, 15)

        timer.start(minutes: 5)
        XCTAssertTrue(timer.isActive)
        XCTAssertEqual(timer.remainingSeconds, 5 * 60)
        XCTAssertEqual(timer.selectedDurationOption, 5)

        timer.start(minutes: 0)
        XCTAssertFalse(timer.isActive)
        XCTAssertEqual(timer.remainingSeconds, 0)
        XCTAssertEqual(timer.selectedDurationOption, 0)
    }
}
