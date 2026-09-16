#if os(iOS)
import SwiftUI
import XCTest
@testable import Silo

final class MainTabLayoutSelectionTests: XCTestCase {
    func testIPadUsesSidebarOnlyInRegularWidth() {
        XCTAssertTrue(MainTabView.prefersSidebarLayout(isPad: true, horizontalSizeClass: .regular))
        XCTAssertFalse(MainTabView.prefersSidebarLayout(isPad: true, horizontalSizeClass: .compact))
        XCTAssertFalse(MainTabView.prefersSidebarLayout(isPad: true, horizontalSizeClass: nil))
    }

    /// Plus/Max iPhones become regular-width while the player is rotated to
    /// landscape. The tab tree must survive that so the Search tab is not
    /// rebuilt (and refocused) underneath the player.
    func testIPhoneKeepsTabsInRegularWidth() {
        XCTAssertFalse(MainTabView.prefersSidebarLayout(isPad: false, horizontalSizeClass: .regular))
        XCTAssertFalse(MainTabView.prefersSidebarLayout(isPad: false, horizontalSizeClass: .compact))
    }
}
#endif
