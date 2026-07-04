import XCTest
import Foundation
@testable import Silo

final class LoopbackSegmentStoreTests: XCTestCase {
    func testRetiringSpilledSegmentReclaimsSpillBudget() {
        let store = LoopbackSegmentStore(
            generation: UInt64(Date().timeIntervalSince1970 * 1000),
            memoryBudgetBytes: 20,
            spillPolicy: .enabled(reason: "test", maxBytes: 1_000_000)
        )
        let payload = Data(repeating: 0x42, count: 10)

        for index in 0..<10 {
            _ = store.putSegment(
                name: String(format: "seg_%06d.m4s", index),
                data: payload,
                duration: 1
            )
        }

        let before = store.stats()
        // Byte-capped eviction floor: resident stops at 30 bytes
        // (<= 1.5x the 20-byte budget), so 7 of the 10 segments spill.
        XCTAssertTrue(before.tempSpillBytes == 70, "expected seven 10-byte spilled segments, got \(before.tempSpillBytes)")
        XCTAssertTrue(before.spilledSegmentCount == 7, "expected seven spilled segments, got \(before.spilledSegmentCount)")

        let retired = store.retireSegments(names: ["seg_000000.m4s"])
        XCTAssertTrue(retired == ["seg_000000.m4s"], "expected retired segment name")

        let after = store.stats()
        XCTAssertTrue(after.tempSpillBytes == 60, "retiring a spilled segment must reclaim spill bytes")
        XCTAssertTrue(after.spilledSegmentCount == 6, "retiring a spilled segment must remove its spill entry")

        guard case .gone = store.resource(path: "seg_000000.m4s", waitForNearFuture: false) else {
            XCTFail("retired segment should be reported gone")
            return
        }
    }

    func testEvictionFloorIsByteCappedForLargeSegments() {
        // The 8-segment warm floor must not override the memory budget at
        // Blu-ray-remux segment sizes (measured on a 3 GB Apple TV: ~30 MB
        // segments held the store at 210-239 MiB against a 96 MiB budget).
        let store = LoopbackSegmentStore(
            generation: 1,
            memoryBudgetBytes: 1_000_000,
            spillPolicy: .enabled(reason: "test", maxBytes: 100_000_000)
        )
        let big = Data(repeating: 0xAA, count: 600_000)
        for index in 0..<8 {
            _ = store.putSegment(
                name: String(format: "seg_%06d.m4s", index),
                data: big,
                duration: 4
            )
        }
        let stats = store.stats()
        // Floor: resident bytes capped at 1.5x budget (never below the
        // 2-segment hard minimum), remainder spilled — not dropped.
        XCTAssertLessThanOrEqual(stats.memoryBytes, 1_500_000, "resident bytes must respect the byte-capped floor")
        XCTAssertEqual(stats.segmentCount, 2, "eviction stops at the hard minimum")
        XCTAssertEqual(stats.spilledSegmentCount, 6, "evicted large segments must spill, not vanish")
        guard case .found = store.resource(path: "seg_000000.m4s", waitForNearFuture: false) else {
            return XCTFail("spilled segment must remain servable from disk")
        }
    }

    func testEvictionFloorKeepsWarmTailForSmallSegments() {
        // Small segments keep the legacy warm-tail behavior: the count
        // floor holds because their resident bytes stay within 1.5x budget.
        let store = LoopbackSegmentStore(
            generation: 1,
            memoryBudgetBytes: 20,
            spillPolicy: .enabled(reason: "test", maxBytes: 1_000_000)
        )
        let payload = Data(repeating: 0xBB, count: 3)
        for index in 0..<12 {
            _ = store.putSegment(
                name: String(format: "seg_%06d.m4s", index),
                data: payload,
                duration: 1
            )
        }
        let stats = store.stats()
        // 12 x 3 bytes = 36 > 20 budget; eviction stops at the 8-segment
        // warm floor (24 bytes <= 30 = 1.5x budget) despite being over.
        XCTAssertEqual(stats.memoryBytes, 24, "warm tail retained over budget while under the byte cap")
        XCTAssertEqual(stats.spilledSegmentCount, 4)
    }

    func testAppendCapacityReflectsCurrentSpillBudget() {
        let store = LoopbackSegmentStore(
            generation: UInt64(Date().timeIntervalSince1970 * 1000) + 1,
            memoryBudgetBytes: 20,
            spillPolicy: .enabled(reason: "test", maxBytes: 20)
        )
        let payload = Data(repeating: 0x42, count: 10)

        for index in 0..<10 {
            _ = store.putSegment(
                name: String(format: "seg_%06d.m4s", index),
                data: payload,
                duration: 1
            )
        }

        XCTAssertFalse(
            store.canAppendSegment(byteCount: 10),
            "spill-full store should apply backpressure before appending a segment that would require another spill"
        )

        _ = store.retireSegments(names: ["seg_000000.m4s"])
        XCTAssertTrue(
            store.canAppendSegment(byteCount: 10),
            "retiring a spilled segment should free enough spill budget for one more append"
        )
    }
}
