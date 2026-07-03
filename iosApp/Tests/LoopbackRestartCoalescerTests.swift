import XCTest
@testable import Silo

final class LoopbackRestartCoalescerTests: XCTestCase {
    func testBurstCoalescesToLatestTarget() {
        var coalescer = LoopbackRestartCoalescer()
        XCTAssertTrue(coalescer.begin(10))
        XCTAssertFalse(coalescer.begin(20))
        XCTAssertFalse(coalescer.begin(35))
        // The worker finishes 10; the burst collapsed to its newest target.
        XCTAssertEqual(coalescer.next(justRan: 10), 35)
        XCTAssertNil(coalescer.next(justRan: 35))
        // Fully settled: a fresh request becomes the worker again.
        XCTAssertTrue(coalescer.begin(40))
    }

    func testSequentialRequestsEachRun() {
        var coalescer = LoopbackRestartCoalescer()
        XCTAssertTrue(coalescer.begin(1))
        XCTAssertNil(coalescer.next(justRan: 1))
        XCTAssertTrue(coalescer.begin(2))
        XCTAssertNil(coalescer.next(justRan: 2))
    }

    func testPendingEqualToJustRanTerminates() {
        // Restarting to the same index forever would livelock; an identical
        // pending target is dropped.
        var coalescer = LoopbackRestartCoalescer()
        XCTAssertTrue(coalescer.begin(10))
        XCTAssertFalse(coalescer.begin(10))
        XCTAssertNil(coalescer.next(justRan: 10))
        XCTAssertFalse(coalescer.isInFlight)
    }

    func testAuthoritativeTargetSurvivesLaterScrub() {
        // A recovery re-base must not be displaced by a stale burst-tail
        // scrub, or the producer ends up anchored away from where the
        // engine clock reconciled.
        var coalescer = LoopbackRestartCoalescer()
        XCTAssertTrue(coalescer.begin(618))
        XCTAssertFalse(coalescer.begin(700))
        XCTAssertFalse(coalescer.begin(978, authoritative: true))
        XCTAssertFalse(coalescer.begin(1393))
        XCTAssertEqual(coalescer.next(justRan: 618), 978)
    }

    func testNewerAuthoritativeReplacesOlder() {
        // The player moved between two recovery re-bases: the newer one wins.
        var coalescer = LoopbackRestartCoalescer()
        XCTAssertTrue(coalescer.begin(500, authoritative: true))
        XCTAssertFalse(coalescer.begin(510, authoritative: true))
        XCTAssertFalse(coalescer.begin(560, authoritative: true))
        XCTAssertEqual(coalescer.next(justRan: 500), 560)
    }

    func testAuthoritativeWhenIdleRunsImmediately() {
        var coalescer = LoopbackRestartCoalescer()
        XCTAssertTrue(coalescer.begin(42, authoritative: true))
    }

    func testOrdinaryCoalescingResumesAfterAuthoritativeConsumed() {
        var coalescer = LoopbackRestartCoalescer()
        XCTAssertTrue(coalescer.begin(618))
        XCTAssertFalse(coalescer.begin(978, authoritative: true))
        XCTAssertEqual(coalescer.next(justRan: 618), 978)
        // The authoritative claim was consumed with the slot; ordinary
        // scrubs park normally again.
        XCTAssertFalse(coalescer.begin(700))
        XCTAssertEqual(coalescer.next(justRan: 978), 700)
    }

    func testInFlightSignalExposedForFetchRide() {
        var coalescer = LoopbackRestartCoalescer()
        XCTAssertFalse(coalescer.isInFlight)
        _ = coalescer.begin(3)
        XCTAssertTrue(coalescer.isInFlight)
        _ = coalescer.next(justRan: 3)
        XCTAssertFalse(coalescer.isInFlight)
    }
}
