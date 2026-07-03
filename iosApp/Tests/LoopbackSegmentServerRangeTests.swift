import XCTest
@testable import Silo

final class LoopbackSegmentServerRangeTests: XCTestCase {
    func testParsesClosedByteRangeForPartialContent() {
        XCTAssertEqual(
            LoopbackSegmentServer.parseByteRange("bytes=4-9", totalLength: 20),
            .satisfiable(lower: 4, upper: 9)
        )
    }

    func testRejectsUnsatisfiableRange() {
        XCTAssertEqual(
            LoopbackSegmentServer.parseByteRange("bytes=20-30", totalLength: 20),
            .notSatisfiable
        )
    }
}
