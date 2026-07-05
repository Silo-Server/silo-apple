import XCTest

@testable import Silo

final class PlaybackSourcePrefetchPolicyTests: XCTestCase {
    func testInitialOffsetUsesSourceStartAndBitrate() {
        let offset = PlaybackSourcePrefetchPolicy.initialOffset(
            sourceStartTimeSeconds: 641.218203251,
            sourceBitrateBps: 92_633_000
        )

        XCTAssertEqual(offset, Int64((641.218203251 * 92_633_000 / 8).rounded(.down)))
    }

    func testInitialOffsetRejectsInvalidInputs() {
        XCTAssertEqual(PlaybackSourcePrefetchPolicy.initialOffset(sourceStartTimeSeconds: 0, sourceBitrateBps: 92_633_000), 0)
        XCTAssertEqual(PlaybackSourcePrefetchPolicy.initialOffset(sourceStartTimeSeconds: 12, sourceBitrateBps: nil), 0)
        XCTAssertEqual(PlaybackSourcePrefetchPolicy.initialOffset(sourceStartTimeSeconds: .nan, sourceBitrateBps: 92_633_000), 0)
    }
}
