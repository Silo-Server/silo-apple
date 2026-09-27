#if os(tvOS)
import XCTest
@testable import Silo

final class TVCrossAxisGateTests: XCTestCase {
    private let start = ContinuousClock.now

    private func at(_ milliseconds: Int) -> ContinuousClock.Instant {
        start.advanced(by: .milliseconds(milliseconds))
    }

    func testSwipeTailSoonAfterOtherAxisMoveIsIgnored() {
        XCTAssertFalse(TVCrossAxisGate.allows(
            axis: .vertical,
            now: at(600),
            lastOtherAxisMove: at(0),
            lastPress: nil
        ))
    }

    func testCommandAfterQuietPeriodPasses() {
        XCTAssertTrue(TVCrossAxisGate.allows(
            axis: .vertical,
            now: at(700),
            lastOtherAxisMove: at(0),
            lastPress: nil
        ))
    }

    func testClickRightAfterOtherAxisMovePasses() {
        XCTAssertTrue(TVCrossAxisGate.allows(
            axis: .vertical,
            now: at(200),
            lastOtherAxisMove: at(100),
            lastPress: at(195)
        ))
    }

    func testStaleClickDoesNotVouchForALaterSwipeTail() {
        XCTAssertFalse(TVCrossAxisGate.allows(
            axis: .horizontal,
            now: at(900),
            lastOtherAxisMove: at(500),
            lastPress: at(0)
        ))
    }

    func testCommandWithNoOtherAxisMovePasses() {
        XCTAssertTrue(TVCrossAxisGate.allows(
            axis: .vertical,
            now: at(0),
            lastOtherAxisMove: nil,
            lastPress: nil
        ))
    }

    func testSameAxisMoveDoesNotGate() {
        var gate = TVCrossAxisGate()
        gate.recordMove(.vertical, at: at(0))
        XCTAssertTrue(MainActor.assumeIsolated { gate.allows(.down, at: at(100)) })
        XCTAssertFalse(MainActor.assumeIsolated { gate.allows(.left, at: at(100)) })
    }
}
#endif
