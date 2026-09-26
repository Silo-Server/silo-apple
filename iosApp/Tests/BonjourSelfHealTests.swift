import XCTest
@testable import Silo

/// `BonjourSelfHeal` decides when a failed NWBrowser/NWListener comes back:
/// once after the delay while the owner still wants it running, never after a
/// deliberate stop or a newer start.
@MainActor
final class BonjourSelfHealTests: XCTestCase {
    func testRestartRunsAfterDelayWhileActive() async {
        let heal = BonjourSelfHeal(delay: .zero)
        var count = 0
        heal.activate()
        heal.scheduleRestart { count += 1 }
        await heal.pendingRestart?.value

        XCTAssertEqual(count, 1)
        XCTAssertNil(heal.pendingRestart)
    }

    func testDeactivateCancelsPendingRestart() async {
        let heal = BonjourSelfHeal(delay: .seconds(60))
        var count = 0
        heal.activate()
        heal.scheduleRestart { count += 1 }
        let task = heal.pendingRestart
        XCTAssertNotNil(task)

        heal.deactivate()
        await task?.value

        XCTAssertEqual(count, 0)
        XCTAssertNil(heal.pendingRestart)
    }

    func testActivateSupersedesPendingRestart() async {
        let heal = BonjourSelfHeal(delay: .seconds(60))
        var count = 0
        heal.activate()
        heal.scheduleRestart { count += 1 }
        let task = heal.pendingRestart
        XCTAssertNotNil(task)

        heal.activate()
        await task?.value

        XCTAssertEqual(count, 0)
        XCTAssertNil(heal.pendingRestart)
    }

    func testScheduleRestartIsCoalesced() async {
        let heal = BonjourSelfHeal(delay: .zero)
        var count = 0
        heal.activate()
        heal.scheduleRestart { count += 1 }
        heal.scheduleRestart { count += 1 }
        let task = heal.pendingRestart
        await task?.value

        XCTAssertEqual(count, 1)
    }

    func testScheduleRestartIgnoredWhenInactive() {
        let heal = BonjourSelfHeal(delay: .zero)
        heal.scheduleRestart {}
        XCTAssertNil(heal.pendingRestart)

        heal.activate()
        heal.deactivate()
        heal.scheduleRestart {}
        XCTAssertNil(heal.pendingRestart)
    }

    func testIsCurrentRejectsStaleAndStoppedGenerations() {
        let heal = BonjourSelfHeal(delay: .zero)
        let first = heal.activate()
        XCTAssertTrue(heal.isCurrent(first))

        let second = heal.activate()
        XCTAssertFalse(heal.isCurrent(first))
        XCTAssertTrue(heal.isCurrent(second))

        heal.deactivate()
        XCTAssertFalse(heal.isCurrent(second))
        XCTAssertFalse(heal.isCurrent(heal.generation))
    }
}
