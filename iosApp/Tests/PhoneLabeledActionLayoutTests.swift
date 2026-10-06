#if !os(tvOS)
import SwiftUI
import UIKit
import XCTest
@testable import Silo

@MainActor
final class PhoneLabeledActionLayoutTests: XCTestCase {
    /// At the default text size every caption fits its fifth of a phone row.
    func testAllActionsShareOneLineWhenCaptionsFit() {
        XCTAssertEqual(
            PhoneLabeledActionColumns.count(itemCount: 5, widestItemWidth: 48, availableWidth: 361),
            5
        )
    }

    /// A caption may shrink to `minimumCaptionScale` before the row wraps.
    func testSlightlyTooWideCaptionShrinksInsteadOfWrapping() {
        // 361 / 5 = 72.2, and 85 * 0.8 = 68 still fits.
        XCTAssertEqual(
            PhoneLabeledActionColumns.count(itemCount: 5, widestItemWidth: 85, availableWidth: 361),
            5
        )
    }

    /// Five actions that only fit four across split 3 + 2, not 4 + 1.
    func testWrappedLinesAreBalanced() {
        // 361 / 4 = 90.25 fits 110 * 0.8 = 88; 361 / 5 does not.
        XCTAssertEqual(
            PhoneLabeledActionColumns.count(itemCount: 5, widestItemWidth: 110, availableWidth: 361),
            3
        )
    }

    /// At the largest accessibility sizes the widest caption may need the
    /// whole width, giving one action per line.
    func testVeryWideCaptionGetsItsOwnLine() {
        XCTAssertEqual(
            PhoneLabeledActionColumns.count(itemCount: 5, widestItemWidth: 400, availableWidth: 361),
            1
        )
    }

    func testUnboundedWidthKeepsOneLine() {
        XCTAssertEqual(
            PhoneLabeledActionColumns.count(itemCount: 4, widestItemWidth: 500, availableWidth: .infinity),
            4
        )
        XCTAssertEqual(
            PhoneLabeledActionColumns.count(itemCount: 0, widestItemWidth: 50, availableWidth: 361),
            0
        )
    }

    /// The default size keeps a single line of actions; the largest
    /// accessibility size wraps it onto more lines instead of breaking a
    /// caption inside a word.
    func testRowGrowsTallerAtAccessibilitySizes() {
        func height(_ size: DynamicTypeSize) -> CGFloat {
            let row = PhoneLabeledActionLayout {
                ForEach(["Favorite", "Watchlist", "Watched", "Download", "More"], id: \.self) { label in
                    PhoneLabeledAction(icon: "heart", label: label, action: {})
                }
            }
            .environment(\.dynamicTypeSize, size)
            let host = UIHostingController(rootView: row)
            return host.sizeThatFits(in: CGSize(width: 361, height: CGFloat.greatestFiniteMagnitude)).height
        }

        let standard = height(.large)
        XCTAssertLessThan(standard, 80, "default size should stay one line")
        XCTAssertGreaterThan(height(.accessibility5), standard * 2)
    }
}
#endif
