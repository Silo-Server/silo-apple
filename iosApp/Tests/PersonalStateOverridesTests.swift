import XCTest
@testable import Silo

/// `PersonalStateOverrides` shows a requested value only while its change is
/// in flight, so a finished tap never masks a later server change (F205).
final class PersonalStateOverridesTests: XCTestCase {
    @MainActor
    func testRequestedValueShowsOnlyWhileTheChangeIsInFlight() async {
        let overrides = PersonalStateOverrides()

        let outcome = await overrides.run(.watched, contentId: "e1", value: true) {
            XCTAssertTrue(overrides.value(.watched, for: "e1", incoming: false))
            return .applied
        }

        XCTAssertEqual(outcome, .applied)
        // A later server-side unwatch arrives as `incoming: false` and must show.
        XCTAssertFalse(overrides.value(.watched, for: "e1", incoming: false))
    }

    @MainActor
    func testUnappliedOutcomesFallBackToTheIncomingValue() async {
        let overrides = PersonalStateOverrides()

        for expected in [PersonalStateOutcome.failed(nil), .skipped] {
            let outcome = await overrides.run(.favorite, contentId: "e1", value: true) { expected }

            XCTAssertEqual(outcome, expected)
            XCTAssertFalse(overrides.value(.favorite, for: "e1", incoming: false))
        }
    }

    @MainActor
    func testAChangeOverridesOnlyItsOwnFlagAndEpisode() async {
        let overrides = PersonalStateOverrides()

        let outcome = await overrides.run(.favorite, contentId: "e1", value: true) {
            XCTAssertTrue(overrides.value(.favorite, for: "e1", incoming: false))
            XCTAssertFalse(overrides.value(.watchlist, for: "e1", incoming: false))
            XCTAssertFalse(overrides.value(.watched, for: "e1", incoming: false))
            XCTAssertFalse(overrides.value(.favorite, for: "e2", incoming: false))
            return .applied
        }

        // The assertions above ran only if `update` did, which is the only
        // way `run` gets this outcome back.
        XCTAssertEqual(outcome, .applied)
    }
}
