import XCTest
@testable import Silo

final class LogRingTests: XCTestCase {
    func testCapacityOrderingAndDroppedCount() {
        let ring = LogRing(capacity: 3)

        for index in 0..<5 {
            ring.append("line-\(index)")
        }

        let snapshot = ring.snapshot()
        XCTAssertEqual(snapshot.lines, ["line-2", "line-3", "line-4"])
        XCTAssertEqual(snapshot.droppedCount, 2)
    }

    func testSnapshotBeforeCapacityHasOldestFirstOrdering() {
        let ring = LogRing(capacity: 5)

        ring.append("line-0")
        ring.append("line-1")
        ring.append("line-2")

        let snapshot = ring.snapshot()
        XCTAssertEqual(snapshot.lines, ["line-0", "line-1", "line-2"])
        XCTAssertEqual(snapshot.droppedCount, 0)
    }

    func testConcurrentAppendsDoNotLoseEntriesBeforeCapacity() {
        let iterations = 500
        let ring = LogRing(capacity: iterations)

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            ring.append("line-\(index)")
        }

        let snapshot = ring.snapshot()
        XCTAssertEqual(snapshot.lines.count, iterations)
        XCTAssertEqual(Set(snapshot.lines).count, iterations)
        XCTAssertEqual(snapshot.droppedCount, 0)
    }

    func testClearDropsAllLinesAndResetsDroppedCount() {
        let ring = LogRing(capacity: 3)

        for index in 0..<5 {
            ring.append("line-\(index)")
        }
        // Filled past capacity, so there is a non-zero dropped count to reset.
        XCTAssertEqual(ring.snapshot().droppedCount, 2)

        ring.clear()

        let cleared = ring.snapshot()
        XCTAssertTrue(cleared.lines.isEmpty)
        XCTAssertEqual(cleared.droppedCount, 0)

        // The ring is reusable after clearing: new lines start a fresh window
        // with no carryover from before the clear.
        ring.append("fresh-0")
        ring.append("fresh-1")
        let reused = ring.snapshot()
        XCTAssertEqual(reused.lines, ["fresh-0", "fresh-1"])
        XCTAssertEqual(reused.droppedCount, 0)
    }

    func testConcurrentAppendsAccountForDroppedLines() {
        let iterations = 500
        let capacity = 100
        let ring = LogRing(capacity: capacity)

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            ring.append("line-\(index)")
        }

        let snapshot = ring.snapshot()
        XCTAssertEqual(snapshot.lines.count, capacity)
        XCTAssertEqual(snapshot.droppedCount, iterations - capacity)
    }
}
