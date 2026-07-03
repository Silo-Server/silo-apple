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
        XCTAssertTrue(before.tempSpillBytes == 20, "expected two 10-byte spilled segments, got \(before.tempSpillBytes)")
        XCTAssertTrue(before.spilledSegmentCount == 2, "expected two spilled segments, got \(before.spilledSegmentCount)")

        let retired = store.retireSegments(names: ["seg_000000.m4s"])
        XCTAssertTrue(retired == ["seg_000000.m4s"], "expected retired segment name")

        let after = store.stats()
        XCTAssertTrue(after.tempSpillBytes == 10, "retiring a spilled segment must reclaim spill bytes")
        XCTAssertTrue(after.spilledSegmentCount == 1, "retiring a spilled segment must remove its spill entry")

        guard case .gone = store.resource(path: "seg_000000.m4s", waitForNearFuture: false) else {
            XCTFail("retired segment should be reported gone")
            return
        }
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
