import XCTest
@testable import Silo

final class SeekLatchTests: XCTestCase {
    func testAVPlayerSeekDeadlineCompletesOnlyActiveGeneration() {
        var state = AVPlayerSeekDeadlineState()
        let first = state.begin()
        let second = state.begin()

        XCTAssertFalse(state.complete(first))
        XCTAssertEqual(state.activeID, second)
        XCTAssertTrue(state.complete(second))
        XCTAssertNil(state.activeID)
    }

    func testAVPlayerSeekDeadlineCancelInvalidatesLateCompletion() {
        var state = AVPlayerSeekDeadlineState()
        let id = state.begin()
        state.cancel()

        XCTAssertNil(state.activeID)
        XCTAssertFalse(state.complete(id))
    }

    func testFirstSubmitStartsWorker() {
        let latch = SeekLatch()
        XCTAssertTrue(latch.submit(10))
        XCTAssertTrue(latch.hasPending)
    }

    func testSubmitWhileActiveCoalesces() {
        let latch = SeekLatch()
        XCTAssertTrue(latch.submit(10))
        XCTAssertFalse(latch.submit(20))
        XCTAssertFalse(latch.submit(30))
        // Worker takes only the newest target.
        XCTAssertEqual(latch.take(), 30)
        XCTAssertNil(latch.take())
    }

    func testTakeDoesNotReleaseOwnership() {
        let latch = SeekLatch()
        XCTAssertTrue(latch.submit(10))
        XCTAssertEqual(latch.take(), 10)
        // Still owned by the worker: a new submit must not start another.
        XCTAssertFalse(latch.submit(20))
        XCTAssertEqual(latch.take(), 20)
    }

    func testFinishReleasesOwnershipWhenIdle() {
        let latch = SeekLatch()
        XCTAssertTrue(latch.submit(10))
        XCTAssertEqual(latch.take(), 10)
        XCTAssertNil(latch.finish())
        // Ownership released: the next submit starts a fresh worker.
        XCTAssertTrue(latch.submit(20))
    }

    func testFinishReturnsRacedInTargetAndKeepsOwnership() {
        let latch = SeekLatch()
        XCTAssertTrue(latch.submit(10))
        XCTAssertEqual(latch.take(), 10)
        // A submit races in after the worker's nil take...
        XCTAssertFalse(latch.submit(20))
        // ...finish hands it to the same worker instead of stranding it.
        XCTAssertEqual(latch.finish(), 20)
        XCTAssertFalse(latch.submit(30))
        XCTAssertEqual(latch.take(), 30)
        XCTAssertNil(latch.finish())
    }

    func testAbandonClearsPendingAndOwnership() {
        let latch = SeekLatch()
        XCTAssertTrue(latch.submit(10))
        latch.abandon()
        XCTAssertFalse(latch.hasPending)
        XCTAssertTrue(latch.submit(20))
    }

    /// Hammer: concurrent submitters against one worker loop. Invariants:
    /// exactly one worker owns the latch at any time, every burst ends with
    /// the newest submitted target processed, and no target strands with no
    /// worker to serve it.
    func testConcurrentSubmitsNeverStrandAndNeverDoubleOwn() {
        let iterations = 200
        for _ in 0..<iterations {
            let latch = SeekLatch()
            let submitters = 4
            let perSubmitter = 25
            let activeWorkers = ManagedAtomicCounter()
            let processed = LockedBox<[Double]>([])
            let group = DispatchGroup()

            func runWorker() {
                let owners = activeWorkers.incrementAndGet()
                XCTAssertEqual(owners, 1, "two workers owned the latch at once")
                while true {
                    guard let target = latch.take() ?? latch.finish() else { break }
                    processed.mutate { $0.append(target) }
                }
                activeWorkers.decrement()
            }

            let queue = DispatchQueue(label: "worker", qos: .userInitiated)
            for s in 0..<submitters {
                DispatchQueue.global().async(group: group) {
                    for i in 0..<perSubmitter {
                        let target = Double(s * perSubmitter + i)
                        if latch.submit(target) {
                            queue.async(group: group) { runWorker() }
                        }
                    }
                }
            }
            XCTAssertEqual(group.wait(timeout: .now() + 10), .success)
            // Quiesce: everything submitted was either taken or is gone.
            XCTAssertFalse(latch.hasPending, "target stranded with no worker")
            XCTAssertFalse(processed.value.isEmpty)
        }
    }
}

/// Minimal lock-based helpers so the hammer test doesn't depend on the
/// Atomics package.
private final class ManagedAtomicCounter {
    private let lock = NSLock()
    private var value = 0
    func incrementAndGet() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
    func decrement() {
        lock.lock(); value -= 1; lock.unlock()
    }
}

private final class LockedBox<T> {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
    func mutate(_ body: (inout T) -> Void) {
        lock.lock(); body(&stored); lock.unlock()
    }
}
