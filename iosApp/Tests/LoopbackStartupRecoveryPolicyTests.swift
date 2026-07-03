import XCTest
@testable import Silo

final class LoopbackStartupRecoveryPolicyTests: XCTestCase {
    private func verdict(
        sinceProgress: Double,
        sinceStart: Double,
        displaySwitching: Bool = false
    ) -> LoopbackStartupRecoveryPolicy.Verdict {
        LoopbackStartupRecoveryPolicy.verdict(
            secondsSinceProgress: sinceProgress,
            secondsSinceStart: sinceStart,
            displayModeSwitchInProgress: displaySwitching,
            stallWindow: 6.0,
            absoluteBackstop: 60.0
        )
    }

    func testFreshProgressWaits() {
        XCTAssertEqual(verdict(sinceProgress: 0.5, sinceStart: 10), .wait)
        XCTAssertEqual(verdict(sinceProgress: 5.9, sinceStart: 30), .wait)
    }

    func testFrozenFetchesEscalate() {
        XCTAssertEqual(verdict(sinceProgress: 6.0, sinceStart: 10), .escalate)
        XCTAssertEqual(verdict(sinceProgress: 20.0, sinceStart: 30), .escalate)
    }

    func testSlowButFetchingConsumerNeverEscalates() {
        // The living-room DV P7 + TrueHD failure: 12+ seconds elapsed but
        // segment GETs flowing every 1-2 s. Progress stays fresh, so the
        // ladder must hold no matter how long startup takes (short of the
        // backstop).
        for elapsed in stride(from: 1.0, through: 59.0, by: 1.0) {
            XCTAssertEqual(verdict(sinceProgress: 1.2, sinceStart: elapsed), .wait)
        }
    }

    func testDisplayModeSwitchHoldsTheLadder() {
        XCTAssertEqual(
            verdict(sinceProgress: 30.0, sinceStart: 30, displaySwitching: true),
            .wait
        )
    }

    func testAbsoluteBackstopFailsEvenWithProgress() {
        XCTAssertEqual(verdict(sinceProgress: 0.1, sinceStart: 60.0), .failBackstop)
        XCTAssertEqual(verdict(sinceProgress: 0.1, sinceStart: 120.0), .failBackstop)
    }

    func testBackstopWinsOverDisplaySwitchHold() {
        XCTAssertEqual(
            verdict(sinceProgress: 0.1, sinceStart: 60.0, displaySwitching: true),
            .failBackstop
        )
    }
}
