#if os(iOS)
import SwiftUI
import XCTest
@testable import Silo

final class MainTabLayoutSelectionTests: XCTestCase {
    /// Split View, Slide Over, and resized windows get the iPhone tab bar even
    /// when they are regular width.
    func testIPadUsesSidebarOnlyWhenFullScreen() {
        XCTAssertTrue(MainTabView.prefersSidebarLayout(
            isPad: true, isiOSAppOnMac: false, windowFillsScreen: true
        ))
        XCTAssertFalse(MainTabView.prefersSidebarLayout(
            isPad: true, isiOSAppOnMac: false, windowFillsScreen: false
        ))
    }

    /// Plus/Max iPhones become regular-width while the player is rotated to
    /// landscape. The tab tree must survive that so the Search tab is not
    /// rebuilt (and refocused) underneath the player.
    func testIPhoneAlwaysUsesTabs() {
        XCTAssertFalse(MainTabView.prefersSidebarLayout(
            isPad: false, isiOSAppOnMac: false, windowFillsScreen: true
        ))
    }

    func testIOSAppOnMacAlwaysUsesSidebar() {
        XCTAssertTrue(MainTabView.prefersSidebarLayout(
            isPad: true, isiOSAppOnMac: true, windowFillsScreen: false
        ))
    }
}
#endif
