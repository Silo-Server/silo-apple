import XCTest
@testable import Silo

final class MuxWriteFailurePolicyTests: XCTestCase {

    func testConsecutiveBurstAborts() {
        var policy = MuxWriteFailurePolicy()
        for _ in 0..<4 {
            XCTAssertFalse(policy.recordFailure())
        }
        XCTAssertTrue(policy.recordFailure(), "5th consecutive failure must abort")
    }

    func testSuccessResetsConsecutiveCount() {
        var policy = MuxWriteFailurePolicy()
        for _ in 0..<4 { _ = policy.recordFailure() }
        policy.recordSuccess()
        XCTAssertEqual(policy.consecutiveFailures, 0)
        XCTAssertFalse(policy.recordFailure(), "burst counter restarts after a success")
    }

    func testFlappingPatternAborts() {
        // The fail-4/succeed-1 pattern that a consecutive-only counter
        // never catches: each cycle stays below the burst threshold but
        // the failures keep accumulating.
        var policy = MuxWriteFailurePolicy()
        var aborted = false
        cycles: for _ in 0..<10 {
            for _ in 0..<4 {
                if policy.recordFailure() { aborted = true; break cycles }
            }
            policy.recordSuccess()
        }
        XCTAssertTrue(aborted, "persistent flapping must abort")
        XCTAssertEqual(policy.outstandingFailures, policy.maxOutstanding)
    }

    func testSparseFailuresAreForgivenByCleanRuns() {
        var policy = MuxWriteFailurePolicy()
        for _ in 0..<20 {
            XCTAssertFalse(policy.recordFailure(), "sparse one-off failures must not abort")
            for _ in 0..<policy.successesToForgiveOne {
                policy.recordSuccess()
            }
            XCTAssertEqual(policy.outstandingFailures, 0, "a sustained clean run retires the failure")
        }
    }

    func testShortCleanRunDoesNotForgive() {
        var policy = MuxWriteFailurePolicy()
        _ = policy.recordFailure()
        for _ in 0..<(policy.successesToForgiveOne - 1) {
            policy.recordSuccess()
        }
        XCTAssertEqual(policy.outstandingFailures, 1, "forgiveness requires the full clean run")
    }

    func testFailureResetsForgivenessProgress() {
        var policy = MuxWriteFailurePolicy()
        _ = policy.recordFailure()
        for _ in 0..<(policy.successesToForgiveOne - 1) {
            policy.recordSuccess()
        }
        _ = policy.recordFailure()
        for _ in 0..<(policy.successesToForgiveOne - 1) {
            policy.recordSuccess()
        }
        XCTAssertEqual(policy.outstandingFailures, 2, "a new failure restarts the clean-run requirement")
    }
}
