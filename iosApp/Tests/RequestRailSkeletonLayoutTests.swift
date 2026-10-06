import SwiftUI
import UIKit
import XCTest
@testable import Silo

@MainActor
final class RequestRailSkeletonLayoutTests: XCTestCase {
    /// A phone's page column is narrower than four placeholder posters. The
    /// rail must clip them instead of widening the page, which pushed the
    /// Requests hub off the leading edge on a cold start.
    func testRailStaysWithinANarrowColumn() {
        let columnWidth: CGFloat = 361
        let host = UIHostingController(rootView: RequestRailSkeleton(title: "Your requests", cardCount: 4))

        let size = host.sizeThatFits(in: CGSize(width: columnWidth, height: .greatestFiniteMagnitude))

        XCTAssertEqual(size.width, columnWidth, accuracy: 0.5)
    }
}
