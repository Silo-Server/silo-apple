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
        // The pure decision protects whatever anchor it is handed: with a
        // high-water of 50 the produced forward span stays in-window. Who
        // owns that anchor is the store's business — it re-anchors it on a
        // seek (see testBackwardSeekReleasesTheOldForwardSpan).
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
        LoopbackSegmentStore(
            generation: 1,
            memoryBudgetBytes: 64 * 1024 * 1024,
            spillPolicy: .enabled(reason: "test", maxBytes: 64 * 1024 * 1024),
            vodRetentionBudgetBytes: budget,
            vodForwardWindow: 3,
            vodBackwardWindow: 2
        )
    }

    private func segName(_ index: Int) -> String {
        String(format: "seg_%06d.m4s", index)
    }

    func testPrunedSegmentIsMissingNotGoneAndReproducible() {
        let store = makeVODStore(budget: 64)  // window + almost nothing
        let payload = Data(repeating: 0xAB, count: 16)
        for index in 0...10 {
            store.putSegment(name: segName(index), data: payload, duration: 4)
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
        store.putSegment(name: segName(0), data: payload, duration: 4)
        guard case .found = store.resource(path: segName(0), waitForNearFuture: false) else {
            return XCTFail("re-produced segment must serve")
        }
    }

    func testBackwardSeekReleasesTheOldForwardSpan() {
        // Forward watch to 20, then seek back to 5. The hard window follows
        // the new target, so the abandoned span around 20 is ordinary history
        // and evicts once the re-anchored producer's own output puts the
        // store over budget. A lifetime-monotonic high-water mark would
        // protect [3, 20] entirely and blow the budget instead.
        let store = makeVODStore(budget: 96)  // 6 x 16-byte segments
        let payload = Data(repeating: 0xAB, count: 16)
        for index in 0...20 {
            store.declareVODTarget(index)
            store.putSegment(name: segName(index), data: payload, duration: 4)
        }
        guard case .found = store.resource(path: segName(20), waitForNearFuture: false) else {
            return XCTFail("the watched head must be resident before the seek")
        }

        store.declareVODTarget(5)
        for index in 5...8 {  // the re-anchored producer refills [target, target+forward]
            store.putSegment(name: segName(index), data: payload, duration: 4)
        }

        for index in 5...8 {
            guard case .found = store.resource(path: segName(index), waitForNearFuture: false) else {
                return XCTFail("segment \(index) is inside the new hard window")
            }
        }
        for index in 17...20 {
            if case .found = store.resource(path: segName(index), waitForNearFuture: false) {
                XCTFail("segment \(index) is stale forward span and must be evictable")
            }
        }
    }

    func testForwardPlaybackKeepsTheProducersForwardSpanProtected() {
        // The re-anchor must not fire on ordinary forward playback: each
        // target advance stays inside the producer band, so what the writer
        // has produced ahead of the playhead stays protected.
        let store = makeVODStore(budget: 32)  // 2 x 16-byte segments
        let payload = Data(repeating: 0xCD, count: 16)
        for index in 0...10 {
            store.putSegment(name: segName(index), data: payload, duration: 4)
        }
        for index in 0...2 {
            store.declareVODTarget(index)
        }
        // target(2) + forward(3) = 5, so 6...10 are protected only by the
        // producer high-water mark — dropping it on every declare would evict
        // the writer's live output.
        for index in 6...10 {
            guard case .found = store.resource(path: segName(index), waitForNearFuture: false) else {
                return XCTFail("produced segment \(index) is ahead of the playhead, not history")
            }
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

    func testProducerWindowIsIndependentOfSegmentByteSize() {
        let store = LoopbackSegmentStore(
            generation: 1,
            memoryBudgetBytes: 64 * 1024 * 1024,
            spillPolicy: .enabled(reason: "test", maxBytes: 64 * 1024 * 1024),
            vodRetentionBudgetBytes: 10_000_000,
            vodForwardWindow: 10,
            vodBackwardWindow: 2
        )
        store.declareVODTarget(0)
        let bigPayload = Data(repeating: 0xEF, count: 600 * 1024)
        for index in 0...9 {
            store.putSegment(name: segName(index), data: bigPayload, duration: 4)
        }
        XCTAssertTrue(store.vodProducerMayAppend(segmentIndex: 10))
        XCTAssertFalse(store.vodProducerMayAppend(segmentIndex: 11))
    }

    func testVODSpillDirectoryIsUniqueAcrossGenerationReuse() throws {
        let first = makeVODStore(budget: 1 << 20)
        let second = makeVODStore(budget: 1 << 20)
        let firstDirectory = try XCTUnwrap(first.spillDirectoryForTesting)
        let secondDirectory = try XCTUnwrap(second.spillDirectoryForTesting)
        XCTAssertNotEqual(firstDirectory, secondDirectory)
    }

    func testVODDiskWriteRecreatesDeletedSessionDirectory() throws {
        let store = makeVODStore(budget: 1 << 20)
        let directory = try XCTUnwrap(store.spillDirectoryForTesting)
        try FileManager.default.removeItem(at: directory)

        let payload = Data(repeating: 0xA5, count: 4_096)
        store.putSegment(name: segName(0), data: payload, duration: 4)

        guard case .found(let resource) = store.resource(
            path: segName(0), waitForNearFuture: false
        ) else {
            return XCTFail("segment must survive a deleted spill directory")
        }
        guard case .disk(let url, let byteCount, _) = resource else {
            return XCTFail("retried VOD write should remain disk-first")
        }
        XCTAssertEqual(byteCount, payload.count)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.stats().memoryBytes, 0)
    }

    func testWaitForSegmentReturnsWhenProducerFills() {
        let store = makeVODStore(budget: 10_000)
        let payload = Data(repeating: 0xCD, count: 8)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            store.putSegment(name: self.segName(4), data: payload, duration: 4)
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
            store.putSegment(name: self.segName(10), data: payload, duration: 4)
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

    func testWaitForSegmentSurvivesTransientFarTargetSwing() {
        // A transient far GET (e.g. a fresh AVPlayerItem probing position 0
        // during in-place recovery) declares an out-of-band target once; the
        // restart triggered by the waited miss re-declares at the waited
        // index right after. A single out-of-band observation must not
        // permanently kill the wait — the late put still serves.
        let store = makeVODStore(budget: 10_000)
        let payload = Data(repeating: 0xAB, count: 8)
        store.declareVODTarget(10)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            store.declareVODTarget(50)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
            store.declareVODTarget(10)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            store.putSegment(name: self.segName(10), data: payload, duration: 4)
        }
        let result = store.waitForSegment(
            named: segName(10),
            deadline: Date().addingTimeInterval(3.0)
        )
        guard case .found(let resource) = result else {
            return XCTFail("one transient far declare must not supersede a live wait")
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

    // MARK: - Consumer-fetch wedge signal (start-over deadlock, 2026-07-06)

    // The producer's park-wedge escape distinguishes "consumer is slow"
    // (park is healthy backpressure) from "consumer never attached" (park
    // would deadlock: only consumer fetches advance the target). The signal
    // must latch on the first declared fetch and never before.
    func testConsumerFetchSignalLatchesOnFirstDeclaredTarget() {
        let store = makeVODStore(budget: 1 << 20)
        XCTAssertFalse(store.vodConsumerHasFetchedSegment(),
                       "no fetch declared yet — producer park must be escapable")
        // Producing segments does NOT count as consumption.
        store.putSegment(name: segName(0), data: Data(repeating: 1, count: 8), duration: 4)
        XCTAssertFalse(store.vodConsumerHasFetchedSegment())
        store.declareVODTarget(0)
        XCTAssertTrue(store.vodConsumerHasFetchedSegment(),
                      "a segment-0 fetch is still a fetch — target index 0 must latch the signal")
    }

    func testProducerWindowBlocksAheadOfUnfetchedConsumer() {
        // Matches the field wedge: target stays at 0 (never fetched),
        // forwardWindow 3 → segment 4 must park while segment 3 may append.
        let store = makeVODStore(budget: 1 << 20)
        XCTAssertTrue(store.vodProducerMayAppend(segmentIndex: 3))
        XCTAssertFalse(store.vodProducerMayAppend(segmentIndex: 4))
        XCTAssertFalse(store.vodConsumerHasFetchedSegment(),
                       "the blocked state with no fetch is exactly the wedge the escape must detect")
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
