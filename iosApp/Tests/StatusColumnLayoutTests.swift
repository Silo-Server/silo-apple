#if os(iOS)
import SwiftUI
import XCTest
@testable import Silo

/// The iPhone Duo's folded screen is 466 x 678pt with the time and connection
/// status in an 84pt column down its right side and no inset across the top.
final class StatusColumnLayoutTests: XCTestCase {
    func testFoldedDuoScreenGetsTheColumn() throws {
        let layout = try XCTUnwrap(StatusColumnLayout(
            safeArea: EdgeInsets(top: 0, leading: 0, bottom: 34, trailing: 84)
        ))
        XCTAssertEqual(layout.edge, .trailing)
        XCTAssertEqual(layout.width, 84)
    }

    /// Right-to-left layouts report the same physical column as leading.
    func testRightToLeftReportsTheColumnAsLeading() throws {
        let layout = try XCTUnwrap(StatusColumnLayout(
            safeArea: EdgeInsets(top: 0, leading: 84, bottom: 34, trailing: 0)
        ))
        XCTAssertEqual(layout.edge, .leading)
    }

    /// Portrait phones and iPads have a status bar across the top, and
    /// landscape phones inset both sides; all keep the bottom tab bar.
    func testOtherWindowsKeepTheTabBar() {
        let windows = [
            EdgeInsets(top: 62, leading: 0, bottom: 34, trailing: 0),
            EdgeInsets(top: 0, leading: 62, bottom: 21, trailing: 62),
            EdgeInsets(top: 24, leading: 0, bottom: 20, trailing: 0),
            EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0),
        ]
        for safeArea in windows {
            XCTAssertNil(StatusColumnLayout(safeArea: safeArea), "\(safeArea)")
        }
    }

    func testFiveDestinationsAllFit() {
        let split = StatusColumnLayout.split(Array(1...5))
        XCTAssertEqual(split.primary, [1, 2, 3, 4, 5])
        XCTAssertEqual(split.overflow, [])
    }

    /// Past five, the fifth slot becomes More, as in the system tab bar.
    func testExtraDestinationsMoveBehindMore() {
        let split = StatusColumnLayout.split(Array(1...9))
        XCTAssertEqual(split.primary, [1, 2, 3, 4])
        XCTAssertEqual(split.overflow, [5, 6, 7, 8, 9])
    }
}
#endif
