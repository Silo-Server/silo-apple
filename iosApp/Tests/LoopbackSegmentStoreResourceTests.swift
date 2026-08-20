import XCTest
@testable import Silo

final class LoopbackSegmentStoreResourceTests: XCTestCase {
    func testStoredSegmentIsExposedAsDiskResource() {
        let store = LoopbackSegmentStore(
            generation: 101,
            memoryBudgetBytes: 1,
            spillPolicy: .enabled(reason: "test", maxBytes: 1024 * 1024)
        )

        for index in 0..<9 {
            let name = String(format: "seg_%06d.m4s", index)
            store.putSegment(name: name, data: Data(repeating: UInt8(index), count: 16), duration: 4)
        }

        switch store.resource(path: "seg_000000.m4s", waitForNearFuture: false) {
        case .found(.disk(_, let byteCount, let mimeType)):
            XCTAssertEqual(byteCount, 16)
            XCTAssertEqual(mimeType, "video/mp4")
        default:
            XCTFail("expected the segment to be served from its disk-backed copy")
        }

        XCTAssertEqual(store.stats().tempSpillBudgetBytes, 1024 * 1024)
    }
}
