import XCTest
@testable import Silo

final class LoopbackSegmentStoreVODRetentionTests: XCTestCase {
    // MARK: - Pure eviction decision

    private func inventory(_ indices: [Int], bytes: Int = 10) -> [(index: Int, bytes: Int)] {
        indices.map { ($0, bytes) }
    }

    func testHardWindowNeverEvictedEvenOverBudget() {
        // Window alone exceeds the budget: correctness beats budget.
        let victims = LoopbackSegmentStore.vodEvictionVictims(
            indicesWithBytes: inventory(Array(0...30)),
            targetIndex: 15,
            highWaterIndex: 30,
            forwardWindow: 10,
            backwardWindow: 20,
            budgetBytes: 50
        )
        XCTAssertTrue(victims.isEmpty, "everything is inside [−5, 30]")
    }

    func testBudgetEvictsFarthestFromTargetFirst() {
        // Target 100, window [80, 110]; backward history 0...79 outside.
        // Budget of 400 bytes keeps the window (310) plus the nearest 9
        // extras (79...71); everything farther evicts.
        let victims = LoopbackSegmentStore.vodEvictionVictims(
            indicesWithBytes: inventory(Array(0...110)),
            targetIndex: 100,
            highWaterIndex: 110,
            forwardWindow: 10,
            backwardWindow: 20,
            budgetBytes: 400
        )
        XCTAssertEqual(Set(victims), Set(0...70))
        XCTAssertFalse(victims.contains(71))
    }

    func testBackwardJumpKeepsForwardSpanViaHighWater() {
        // Producer reached 50; a transient backward fetch declares target 5.
        // The high-water anchor keeps the produced forward span in-window so
        // the jump can't evict forward progress.
        let victims = LoopbackSegmentStore.vodEvictionVictims(
            indicesWithBytes: inventory(Array(0...50)),
            targetIndex: 5,
            highWaterIndex: 50,
            forwardWindow: 10,
            backwardWindow: 20,
            budgetBytes: 10_000
        )
        XCTAssertTrue(victims.isEmpty)
    }

    func testZeroBudgetDisablesVODEviction() {
        let victims = LoopbackSegmentStore.vodEvictionVictims(
            indicesWithBytes: inventory(Array(0...100)),
            targetIndex: 100,
            highWaterIndex: 100,
            forwardWindow: 10,
            backwardWindow: 20,
            budgetBytes: 0
        )
        XCTAssertTrue(victims.isEmpty)
    }

    // MARK: - Store behavior

    private func makeVODStore(budget: Int64) -> LoopbackSegmentStore {
        let store = LoopbackSegmentStore(
            generation: 1,
            memoryBudgetBytes: 64 * 1024 * 1024,
            spillPolicy: .enabled(reason: "test", maxBytes: 64 * 1024 * 1024)
        )
        store.configureVODRetention(budgetBytes: budget, forwardWindow: 3, backwardWindow: 2)
        return store
    }

    private func segName(_ index: Int) -> String {
        String(format: "seg_%06d.m4s", index)
    }

    func testPrunedSegmentIsMissingNotGoneAndReproducible() {
        let store = makeVODStore(budget: 64)  // window + almost nothing
        let payload = Data(repeating: 0xAB, count: 16)
        for index in 0...10 {
            _ = store.putSegment(name: segName(index), data: payload, duration: 4)
        }
        // Fetching far forward prunes the backward tail beyond the budget.
        store.declareVODTarget(10)
        if case .found = store.resource(path: segName(0), waitForNearFuture: false) {
            XCTFail("seg 0 should have been pruned")
        }
        // Pruned must read as .missing (regenerable), never .gone.
        if case .gone = store.resource(path: segName(0), waitForNearFuture: false) {
            XCTFail("pruned VOD segment must not be terminal")
        }
        // The fetch that misses declares its target BEFORE resolution (the
        // server's order), moving the window to cover it; the restarted
        // producer's re-put is then protected from the stale window.
        store.declareVODTarget(0)
        _ = store.putSegment(name: segName(0), data: payload, duration: 4)
        guard case .found = store.resource(path: segName(0), waitForNearFuture: false) else {
            return XCTFail("re-produced segment must serve")
        }
    }

    func testProducerWindowBackpressure() {
        let store = makeVODStore(budget: 10_000)
        store.declareVODTarget(5)
        XCTAssertTrue(store.vodProducerMayAppend(segmentIndex: 8), "inside target+forward(3)")
        XCTAssertFalse(store.vodProducerMayAppend(segmentIndex: 9), "past the window")
        store.declareVODTarget(6)
        XCTAssertTrue(store.vodProducerMayAppend(segmentIndex: 9), "window follows the consumer")
    }

    func testWaitForSegmentReturnsWhenProducerFills() {
        let store = makeVODStore(budget: 10_000)
        let payload = Data(repeating: 0xCD, count: 8)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            _ = store.putSegment(name: self.segName(4), data: payload, duration: 4)
        }
        let result = store.waitForSegment(
            named: segName(4),
            deadline: Date().addingTimeInterval(3.0)
        )
        guard case .found(let resource) = result else {
            return XCTFail("waitForSegment should observe the late put")
        }
        XCTAssertEqual(resource.byteCount, payload.count)
    }

    func testWaitForSegmentTimesOutMissing() {
        let store = makeVODStore(budget: 10_000)
        let started = Date()
        let result = store.waitForSegment(
            named: segName(7),
            deadline: Date().addingTimeInterval(0.4)
        )
        guard case .missing = result else {
            return XCTFail("expected .missing on deadline")
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.35)
    }
}
