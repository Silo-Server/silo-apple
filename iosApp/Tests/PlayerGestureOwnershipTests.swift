#if os(iOS)
import XCTest
@testable import Silo

/// Hold for 2×, edge drags, and pinch share one touch; only the first to
/// start may act until it ends.
final class PlayerGestureOwnershipTests: XCTestCase {
    func testHoldBlocksEdgeDragUntilReleased() {
        var ownership = PlayerGestureOwnership()
        XCTAssertTrue(ownership.claim(.hold))
        XCTAssertFalse(ownership.claim(.edgeAdjustment))
        XCTAssertFalse(ownership.claim(.pinch))

        ownership.release(.hold)
        XCTAssertTrue(ownership.claim(.edgeAdjustment))
    }

    func testEdgeDragBlocksHold() {
        var ownership = PlayerGestureOwnership()
        XCTAssertTrue(ownership.claim(.edgeAdjustment))
        XCTAssertFalse(ownership.claim(.hold))
    }

    func testReleaseByNonOwnerKeepsOwner() {
        var ownership = PlayerGestureOwnership()
        XCTAssertTrue(ownership.claim(.pinch))
        ownership.release(.hold)
        XCTAssertEqual(ownership.owner, .pinch)
    }

    func testOwnerReclaimIsIdempotent() {
        var ownership = PlayerGestureOwnership()
        XCTAssertTrue(ownership.claim(.pinch))
        XCTAssertTrue(ownership.claim(.pinch))
    }

    func testResetFreesTouch() {
        var ownership = PlayerGestureOwnership()
        XCTAssertTrue(ownership.claim(.hold))
        ownership.reset()
        XCTAssertNil(ownership.owner)
        XCTAssertTrue(ownership.claim(.edgeAdjustment))
    }
}
#endif
