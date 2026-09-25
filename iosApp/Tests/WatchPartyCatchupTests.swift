import Foundation
import XCTest
@testable import Silo

/// Mirrors the web client's `roomSyncCatchup.test.ts`, so native and browser
/// members converge on the room the same way.
final class WatchPartyCatchupTests: XCTestCase {
    // Small, exact offsets keep interval arithmetic free of rounding.
    private let start = Date(timeIntervalSinceReferenceDate: 0)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testCatchupConvergesOnTheAdvancingRoomPosition() {
        XCTAssertEqual(WatchPartyCorrection.expectedPosition(100, elapsed: -0.5), 100)
        XCTAssertEqual(WatchPartyCorrection.expectedPosition(100, elapsed: 3), 103)
        XCTAssertTrue(WatchPartyCorrection.converged(target: 100, elapsed: 3, local: 102.8))
        XCTAssertFalse(WatchPartyCorrection.converged(target: 100, elapsed: 3, local: 102))
        // A member slowed from ahead of the room converges once the advancing
        // room position reaches it, not the command's static target.
        XCTAssertFalse(WatchPartyCorrection.converged(target: 100, elapsed: 0, local: 102.8))
        XCTAssertFalse(WatchPartyCorrection.converged(target: 100, elapsed: 2, local: 102.8))
        XCTAssertTrue(WatchPartyCorrection.converged(target: 100, elapsed: 2.5, local: 102.8))
    }

    func testOneLoadAtATimeAimsTheNextAheadByTheMeasuredLoadTime() {
        var budget = WatchPartyReloadBudget()
        XCTAssertTrue(budget.allowed(at: at(0)))
        XCTAssertEqual(budget.begin(roomPosition: 100, at: at(0), duration: 0), 100)
        XCTAssertFalse(budget.allowed(at: at(5)))

        // Until the load's seek is taken, even the target belongs to the
        // stream being replaced.
        XCTAssertFalse(budget.landed(at: 100))
        budget.noteLoading()
        XCTAssertFalse(budget.landed(at: 95))
        XCTAssertTrue(budget.landed(at: 100))
        budget.land(at: at(6))
        XCTAssertEqual(budget.lead, 6)
        XCTAssertFalse(budget.allowed(at: at(6 + WatchPartyReloadBudget.minInterval - 0.001)))
        XCTAssertTrue(budget.allowed(at: at(6 + WatchPartyReloadBudget.minInterval)))
        XCTAssertEqual(budget.begin(roomPosition: 200, at: at(20), duration: 0), 206)
    }

    func testEveryLoadHasItsOwnGeneration() {
        var budget = WatchPartyReloadBudget()
        _ = budget.begin(roomPosition: 100, at: at(0), duration: 0)
        let first = budget.generation
        budget.abandon(at: at(1))
        _ = budget.begin(roomPosition: 100, at: at(40), duration: 0)
        let second = budget.generation
        XCTAssertNotEqual(second, first)
        // Converging does not end a load in flight.
        budget.settle()
        XCTAssertEqual(budget.generation, second)
        budget.noteLoading()
        budget.land(at: at(42))
        XCTAssertNotEqual(budget.generation, second)
    }

    func testLeadNeverAimsPastTheEndOfTheMedia() {
        var budget = WatchPartyReloadBudget()
        _ = budget.begin(roomPosition: 100, at: at(0), duration: 0)
        budget.noteLoading()
        budget.land(at: at(8))
        XCTAssertEqual(budget.lead, 8)
        XCTAssertEqual(budget.begin(roomPosition: 5_995, at: at(60), duration: 6_000), 6_000)
        XCTAssertEqual(budget.begin(roomPosition: 5_000, at: at(120), duration: 6_000), 5_008)
        // A room already past the reported end keeps its own position.
        XCTAssertEqual(budget.begin(roomPosition: 6_010, at: at(180), duration: 6_000), 6_010)
    }

    func testABackwardLoadDoesNotSettleOnTheStreamItReplaces() {
        var budget = WatchPartyReloadBudget()
        _ = budget.begin(roomPosition: 100, at: at(0), duration: 0)
        budget.noteLoading()
        XCTAssertFalse(budget.landed(at: 105))
        XCTAssertTrue(budget.landed(at: 100.3))
    }

    func testLoadsBackOffUntilTheViewerConverges() {
        var budget = WatchPartyReloadBudget()
        var now = at(0)
        var intervals: [TimeInterval] = []
        for _ in 0..<5 {
            _ = budget.begin(roomPosition: 100, at: now, duration: 0)
            budget.land(at: now)
            intervals.append(budget.nextAllowedAt.timeIntervalSince(now))
            now = budget.nextAllowedAt
        }
        XCTAssertEqual(intervals, [10, 20, 40, 60, 60])

        budget.settle()
        XCTAssertTrue(budget.allowed(at: now))
        _ = budget.begin(roomPosition: 100, at: now, duration: 0)
        budget.land(at: now)
        XCTAssertEqual(budget.nextAllowedAt.timeIntervalSince(now), WatchPartyReloadBudget.minInterval)
    }

    func testLeadIsBoundedAndAnUnlandedLoadStopsBlocking() {
        var budget = WatchPartyReloadBudget()
        _ = budget.begin(roomPosition: 100, at: at(0), duration: 0)
        budget.land(at: at(60))
        XCTAssertEqual(budget.lead, WatchPartyReloadBudget.maxLead)

        _ = budget.begin(roomPosition: 100, at: at(100), duration: 0)
        XCTAssertFalse(budget.allowed(at: at(100 + WatchPartyReloadBudget.staleAfter - 0.001)))
        XCTAssertTrue(budget.allowed(at: at(100 + WatchPartyReloadBudget.staleAfter)))

        budget.abandon(at: at(200))
        XCTAssertNil(budget.target)
        XCTAssertFalse(budget.allowed(at: at(200)))
    }
}
