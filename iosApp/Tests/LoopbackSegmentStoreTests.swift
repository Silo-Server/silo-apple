import XCTest
import Foundation
@testable import Silo

/// The store has exactly one storage mode: disk-first segments under a
/// positive retention budget, pruned around the consumer's declared target.
/// These pin that mode's accounting — what is resident, what is reclaimed,
/// and what a retired name reports afterwards.
final class LoopbackSegmentStoreTests: XCTestCase {
    private func makeStore(
        budgetBytes: Int64,
        forwardWindow: Int = 10,
        backwardWindow: Int = 20
    ) -> LoopbackSegmentStore {
        LoopbackSegmentStore(
            generation: UInt64(Date().timeIntervalSince1970 * 1000),
            memoryBudgetBytes: 1_000_000,
            spillPolicy: .enabled(reason: "test", maxBytes: 100_000_000),
            vodRetentionBudgetBytes: budgetBytes,
            vodForwardWindow: forwardWindow,
            vodBackwardWindow: backwardWindow
        )
    }

    private func segName(_ index: Int) -> String {
        String(format: "seg_%06d.m4s", index)
    }

    func testRetiringASegmentReclaimsItsSpillBytesAndIsTerminal() {
        let store = makeStore(budgetBytes: 10_000_000)
        let payload = Data(repeating: 0x42, count: 10)

        for index in 0..<10 {
            store.putSegment(name: segName(index), data: payload, duration: 1)
        }

        let before = store.stats()
        XCTAssertEqual(before.spilledSegmentCount, 10, "every segment is disk-first")
        XCTAssertEqual(before.tempSpillBytes, 100)

        let retired = store.retireSegments(names: [segName(0)])
        XCTAssertEqual(retired, [segName(0)])

        let after = store.stats()
        XCTAssertEqual(after.tempSpillBytes, 90, "retiring must reclaim the segment's bytes")
        XCTAssertEqual(after.spilledSegmentCount, 9)

        // Retirement is deliberate and terminal — unlike a retention prune,
        // which stays `.missing` so a restarted producer can refill it.
        guard case .gone = store.resource(path: segName(0), waitForNearFuture: false) else {
            return XCTFail("retired segment should be reported gone")
        }
    }

    func testLargeSegmentsStayDiskResidentInsteadOfGrowingTheHeap() {
        // The reason the store is disk-first: Blu-ray-remux segments run
        // ~30 MB, so holding a warm tail of them in RAM cost more than a
        // constrained device's whole store budget. Nothing lands in
        // `memoryBytes` now.
        let store = makeStore(budgetBytes: 10_000_000)
        let big = Data(repeating: 0xAA, count: 600_000)

        for index in 0..<8 {
            store.putSegment(name: segName(index), data: big, duration: 4)
        }

        let stats = store.stats()
        XCTAssertEqual(stats.memoryBytes, 0, "no encoded media may be resident")
        XCTAssertEqual(stats.segmentCount, 0)
        XCTAssertEqual(stats.spilledSegmentCount, 8)
        guard case .found(.disk(_, let byteCount, let mimeType)) = store.resource(
            path: segName(0), waitForNearFuture: false
        ) else {
            return XCTFail("stored segment must serve from disk")
        }
        XCTAssertEqual(byteCount, big.count)
        XCTAssertEqual(mimeType, "video/mp4")
    }

    func testRetentionKeepsTheProtectedWindowEvenWhenItExceedsTheBudget() {
        // Correctness beats budget: the hard window
        // [target - backward, max(target + forward, highWater)] covers the
        // playhead and the producer's forward span, so it is never pruned —
        // only history beyond it is.
        let store = makeStore(budgetBytes: 32, forwardWindow: 3, backwardWindow: 2)
        let payload = Data(repeating: 0xAB, count: 16)

        for index in 0...10 {
            store.putSegment(name: segName(index), data: payload, duration: 4)
        }
        store.declareVODTarget(10)

        for index in 8...10 {
            guard case .found = store.resource(path: segName(index), waitForNearFuture: false) else {
                return XCTFail("segment \(index) is inside the protected window")
            }
        }
        // Pruned history reads as `.missing` (regenerable by a producer
        // restart), never `.gone`.
        switch store.resource(path: segName(0), waitForNearFuture: false) {
        case .missing:
            break
        case .found:
            XCTFail("segment 0 is far behind the target and over budget")
        case .gone:
            XCTFail("a pruned segment must not be terminal")
        }
    }

    func testNonPositiveRetentionBudgetIsFlooredRatherThanDisablingRetention() {
        // There is no "retention off" mode: a degenerate budget floors, so the
        // coupled producer window still bounds how far production may race.
        let store = makeStore(budgetBytes: 0, forwardWindow: 10)

        XCTAssertTrue(store.vodProducerMayAppend(segmentIndex: 10), "inside target(0)+forward(10)")
        XCTAssertFalse(store.vodProducerMayAppend(segmentIndex: 11), "past the window")

        store.putSegment(name: segName(0), data: Data(repeating: 1, count: 8), duration: 4)
        guard case .found = store.resource(path: segName(0), waitForNearFuture: false) else {
            return XCTFail("a floored budget still stores segments")
        }
    }

    func testProgressiveBytesAreReportedAndClearedWhenTheSegmentLands() {
        // Progressive publications are a SECOND resident copy of the open
        // segment (the writer's pending buffer is the first). They are not
        // eviction candidates, so they stay out of `memoryBytes`, but stats
        // must not understate resident memory by hiding them entirely.
        let store = LoopbackSegmentStore(
            generation: UInt64(Date().timeIntervalSince1970 * 1000) + 2,
            memoryBudgetBytes: 1_000_000,
            spillPolicy: .disabled(reason: "test")
        )
        let name = segName(0)

        XCTAssertEqual(store.stats().progressiveBytes, 0)

        store.beginProgressiveSegment(named: name)
        store.appendProgressiveSegment(named: name, bytes: Data(repeating: 0x41, count: 40))
        store.appendProgressiveSegment(named: name, bytes: Data(repeating: 0x42, count: 60))

        let streaming = store.stats()
        XCTAssertEqual(streaming.progressiveBytes, 100, "both published fragments must be accounted")
        XCTAssertEqual(streaming.memoryBytes, 0, "progressive bytes must stay out of the resident budget")

        // The complete segment supersedes the in-progress publication.
        store.putSegment(name: name, data: Data(repeating: 0x43, count: 100), duration: 1)

        let landed = store.stats()
        XCTAssertEqual(landed.progressiveBytes, 0, "the superseded publication must stop being counted")
        XCTAssertEqual(landed.memoryBytes, 100, "the stored segment is resident when no spill directory exists")
    }
}
