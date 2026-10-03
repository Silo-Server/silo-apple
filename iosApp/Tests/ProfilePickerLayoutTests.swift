#if !os(tvOS)
import SwiftUI
import XCTest
@testable import Silo

/// "Who's watching?" must lay out 1–20 profiles (plus "Add profile") on every
/// iPhone and iPad size: avatars that fit their columns and the screen, and
/// that only get smaller as the household grows.
final class ProfilePickerLayoutTests: XCTestCase {
    /// Grid room (width, height between title and footer) on representative
    /// screens, measured from the picker at default text size.
    private let screens: [(name: String, width: CGFloat, height: CGFloat)] = [
        ("iPhone SE", 327, 355),
        ("iPhone 17 Pro", 354, 486),
        ("iPhone 17 Pro Max", 392, 568),
        ("iPad", 440, 900),
    ]

    func testEveryHouseholdSizeFitsEveryScreen() {
        for screen in screens {
            var previous: ProfilePickerLayout?
            for profiles in 1...20 {
                let tiles = profiles + 1
                let layout = ProfilePickerLayout(tileCount: tiles, width: screen.width, height: screen.height)
                let context = "\(screen.name), \(profiles) profiles"

                XCTAssertGreaterThanOrEqual(layout.avatarSize, ProfilePickerLayout.minimumAvatar, context)
                XCTAssertLessThanOrEqual(CGFloat(layout.perRow) * layout.columnWidth, screen.width, context)
                XCTAssertLessThan(layout.avatarSize, layout.columnWidth, "\(context): avatar wider than its column")
                XCTAssertLessThanOrEqual(layout.addSize, layout.avatarSize, context)

                if !layout.scrolls {
                    let rows = CGFloat((tiles + layout.perRow - 1) / layout.perRow)
                    let used = rows * (layout.avatarSize + ProfilePickerLayout.labelHeight) + (rows - 1) * layout.rowSpacing
                    XCTAssertLessThanOrEqual(used, screen.height, "\(context): rows overflow without scrolling")
                }

                if let previous {
                    XCTAssertLessThanOrEqual(layout.avatarSize, previous.avatarSize, "\(context): avatars grew")
                    XCTAssertGreaterThanOrEqual(layout.perRow, previous.perRow, "\(context): fewer per row")
                    XCTAssertTrue(layout.scrolls || !previous.scrolls, "\(context): stopped scrolling")
                }
                previous = layout
            }
        }
    }

    func testSmallHouseholdGetsTwoLargeAvatarsPerRow() {
        let layout = ProfilePickerLayout(tileCount: 3, width: 354, height: 486)
        XCTAssertEqual(layout.perRow, 2)
        XCTAssertEqual(layout.avatarSize, 140)
        XCTAssertLessThan(layout.addSize, layout.avatarSize, "a lone Add profile tile is drawn smaller")
    }

    func testLargeHouseholdScrollsFourPerRow() {
        let layout = ProfilePickerLayout(tileCount: 21, width: 354, height: 486)
        XCTAssertEqual(layout.perRow, 4)
        XCTAssertTrue(layout.scrolls)
        XCTAssertEqual(layout.addSize, layout.avatarSize * 0.6, accuracy: 1)
    }

    func testLargerTextLeavesLessRoomAndSmallerAvatars() {
        let regular = ProfilePickerLayout(tileCount: 6, width: 354, height: 486)
        let largeText = ProfilePickerLayout(tileCount: 6, width: 354, height: 300)
        XCTAssertLessThanOrEqual(largeText.avatarSize, regular.avatarSize)
        XCTAssertGreaterThanOrEqual(largeText.perRow, regular.perRow)
    }
}

/// The PIN prompt keeps its whole keypad on screen, 0 and Delete included,
/// on the shortest phone it runs on.
@MainActor
final class PINEntryLayoutTests: XCTestCase {
    func testPINPadFitsTheSmallestPhone() {
        let profile = UserProfile(id: "kid", name: "Restricted", avatarEmoji: nil, hasPin: true, isChild: true)
        let host = UIHostingController(rootView: PINEntryView(profile: profile, onCancel: {}) { _ in })
        // iPhone SE in portrait, below the status bar.
        let available = CGSize(width: 375, height: 647)
        // Within a point: layout rounds to the screen's pixel grid.
        XCTAssertLessThanOrEqual(host.sizeThatFits(in: available).height, available.height + 1)
    }
}
#endif
