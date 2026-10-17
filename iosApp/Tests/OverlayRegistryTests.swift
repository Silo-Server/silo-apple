import XCTest
@testable import Silo

final class OverlayRegistryTests: XCTestCase {
    /// Posters draw the watched check in the top-right corner, so no badge
    /// starts there. A user can still move one in.
    func testNoBadgeDefaultsToTheWatchedCheckCorner() {
        for def in OverlayRegistry.all {
            XCTAssertNotEqual(def.defaultPosition, .topRight, def.id.rawValue)
        }
    }
}
