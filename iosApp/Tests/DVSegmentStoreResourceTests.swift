import XCTest
@testable import Silo

final class DVSegmentStoreResourceTests: XCTestCase {
    func testDiskSpilledSegmentIsExposedAsDiskResource() {
        let store = DVSegmentStore(
            generation: 101,
            memoryBudgetBytes: 1,
            spillPolicy: .enabled(reason: "test", maxBytes: 1024 * 1024)
        )

        for index in 0..<9 {
            let name = String(format: "seg_%06d.m4s", index)
            _ = store.putSegment(name: name, data: Data(repeating: UInt8(index), count: 16), duration: 4)
        }

        switch store.resource(path: "seg_000000.m4s", waitForNearFuture: false) {
        case .found(.disk(_, let byteCount, let mimeType)):
            XCTAssertEqual(byteCount, 16)
            XCTAssertEqual(mimeType, "video/mp4")
        default:
            XCTFail("expected first segment to spill to a disk-backed resource")
        }

        XCTAssertEqual(store.stats().tempSpillBudgetBytes, 1024 * 1024)
    }

    func testUnproducedSegmentIsPendingNotMissing() {
        let store = DVSegmentStore(
            generation: 102,
            memoryBudgetBytes: 1024 * 1024,
            spillPolicy: .disabled(reason: "test")
        )
        _ = store.putSegment(name: "seg_000000.m4s", data: Data(repeating: 1, count: 16), duration: 4)

        switch store.resource(path: "seg_000001.m4s", waitForNearFuture: false) {
        case .pending:
            break
        default:
            XCTFail("an un-produced, non-evicted segment must report .pending")
        }
    }

    func testNonSegmentJunkPathIsMissing() {
        let store = DVSegmentStore(
            generation: 103,
            memoryBudgetBytes: 1024 * 1024,
            spillPolicy: .disabled(reason: "test")
        )

        switch store.resource(path: "nope.txt", waitForNearFuture: false) {
        case .missing:
            break
        default:
            XCTFail("a non-segment junk path must stay .missing (404)")
        }
    }
}
