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

    func testWaitForSegmentExitsEarlyWhenSupersededByFarTarget() {
        // Miss path: the fetch for seg 10 declares its own index first (the
        // server's order), then AVPlayer abandons it and scrubs far away —
        // the new fetch declares 50, outside the ±forwardWindow(3) band, so
        // the waiter must wake and exit instead of riding the deadline.
        let store = makeVODStore(budget: 10_000)
        store.declareVODTarget(10)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            store.declareVODTarget(50)
        }
        let started = Date()
        let result = store.waitForSegment(
            named: segName(10),
            deadline: Date().addingTimeInterval(5.0)
        )
        guard case .missing = result else {
            return XCTFail("superseded wait must resolve .missing")
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(started), 2.0,
            "supersede must not ride the full deadline"
        )
    }

    func testWaitForSegmentSurvivesCoveringTargetAndLatePut() {
        // A nearby declare (covering producer / pipelined adjacent fetch)
        // stays inside the ±forwardWindow band and must NOT kill a
        // legitimate wait: the late put still serves.
        let store = makeVODStore(budget: 10_000)
        let payload = Data(repeating: 0xEF, count: 8)
        store.declareVODTarget(10)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            store.declareVODTarget(12)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            _ = store.putSegment(name: self.segName(10), data: payload, duration: 4)
        }
        let result = store.waitForSegment(
            named: segName(10),
            deadline: Date().addingTimeInterval(3.0)
        )
        guard case .found(let resource) = result else {
            return XCTFail("in-band declare must not supersede the wait")
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

    // MARK: - Spill-exhaustion relief (living-room deadlock)

    /// 12 puts against a 1-byte memory budget: the memory evictor keeps the
    /// newest `minimumSegmentsToKeep` (8) in memory and spills segments
    /// 0...3 to disk, exactly filling a 64-byte spill budget.
    private func makeSpillFullStore(retentionBudget: Int64) -> LoopbackSegmentStore {
        let store = LoopbackSegmentStore(
            generation: 1,
            memoryBudgetBytes: 1,
            spillPolicy: .enabled(reason: "test", maxBytes: 64)
        )
        store.configureVODRetention(
            budgetBytes: retentionBudget, forwardWindow: 3, backwardWindow: 2
        )
        let payload = Data(repeating: 0xEF, count: 16)
        for index in 0...11 {
            _ = store.putSegment(name: segName(index), data: payload, duration: 4)
        }
        return store
    }

    func testMakeRoomForAppendForceEvictsSpilledFarFromTarget() {
        // Retention budget far above the payload: the normal prune
        // volunteers nothing — the append only fits if force-evict
        // reclaims the spilled segment farthest from the consumer's target.
        let store = makeSpillFullStore(retentionBudget: 1_000_000)
        store.declareVODTarget(11)
        XCTAssertEqual(store.stats().tempSpillBytes, 64, "spill budget should be exactly full")

        XCTAssertTrue(store.makeRoomForAppend(byteCount: 16))

        if case .found = store.resource(path: segName(0), waitForNearFuture: false) {
            XCTFail("farthest-from-target spilled segment should have been force-evicted")
        }
        // Force-evicted segments are regenerable: .missing, never .gone.
        if case .gone = store.resource(path: segName(0), waitForNearFuture: false) {
            XCTFail("force-evicted VOD segment must not be terminal")
        }
        // Only the farthest spilled segment goes; nearer spill and the
        // in-memory tail survive.
        guard case .found = store.resource(path: segName(3), waitForNearFuture: false) else {
            return XCTFail("nearer spilled segment must survive")
        }
        guard case .found = store.resource(path: segName(11), waitForNearFuture: false) else {
            return XCTFail("target segment must survive force-evict")
        }
        XCTAssertLessThanOrEqual(store.stats().tempSpillBytes + 16, 64)
    }

    func testMakeRoomForAppendSparesTargetNeighborhood() {
        // Target near the spilled tail: segments 0...3 sit inside
        // [target − backward, target + forward] — force-evict must refuse
        // to free room rather than evict under the playhead.
        let store = makeSpillFullStore(retentionBudget: 1_000_000)
        store.declareVODTarget(1)
        XCTAssertFalse(store.makeRoomForAppend(byteCount: 16))
        for index in 0...3 {
            guard case .found = store.resource(path: segName(index), waitForNearFuture: false) else {
                return XCTFail("in-window spilled segment \(index) must survive")
            }
        }
    }

    func testZeroBudgetConfigurationClampsToFloorInsteadOfDisabling() {
        // A non-positive configured budget must not leave retention off
        // (a 0 budget reads as "not configured" and disables every prune
        // path). Behavior proxy: makeRoomForAppend gates on a configured
        // retention, so it must still force-evict after a 0-budget
        // configure.
        let store = makeSpillFullStore(retentionBudget: 0)
        store.declareVODTarget(11)
        XCTAssertTrue(store.makeRoomForAppend(byteCount: 16))
        if case .found = store.resource(path: segName(0), waitForNearFuture: false) {
            XCTFail("retention must stay active on a degenerate budget")
        }
    }

    func testRetentionPruneSeesSpilledSegments() {
        // The living-room deadlock: spilled names leave `segmentOrder`, so
        // an order-based prune inventory never saw them and retention never
        // evicted a spilled byte. With a budget below the spilled payload,
        // declaring a far target must now evict spilled history.
        let store = makeSpillFullStore(retentionBudget: 100)
        store.declareVODTarget(11)
        // Hard window [9, 14] holds 3×16 = 48 bytes; extras fit only ~52
        // more — the farthest spilled segments must go.
        if case .found = store.resource(path: segName(0), waitForNearFuture: false) {
            XCTFail("spilled history beyond the retention budget must be pruned")
        }
        XCTAssertLessThan(store.stats().tempSpillBytes, 64)
    }

    // MARK: - Retention budget resolution (AVPlayerBackend)

    func testRetentionBudgetClampNeverZero() {
        let cap: Int64 = 2 << 30
        let floor: Int64 = 512 << 20
        XCTAssertEqual(AVPlayerBackend.vodRetentionBudget(availableBytes: nil), cap)
        XCTAssertEqual(AVPlayerBackend.vodRetentionBudget(availableBytes: 0), cap)
        XCTAssertEqual(AVPlayerBackend.vodRetentionBudget(availableBytes: -1), cap)
        XCTAssertEqual(AVPlayerBackend.vodRetentionBudget(availableBytes: 100 << 20), floor)
        XCTAssertEqual(AVPlayerBackend.vodRetentionBudget(availableBytes: 4 << 30), 1 << 30)
        XCTAssertEqual(AVPlayerBackend.vodRetentionBudget(availableBytes: 40 << 30), cap)
    }
}
