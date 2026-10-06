import SwiftUI
import UIKit
import XCTest
@testable import Silo

@MainActor
final class PosterRowsSkeletonLayoutTests: XCTestCase {
    /// Six phone posters per row are far wider than a phone's page, and three
    /// rows can be taller than a small screen. The skeleton must clip to the
    /// space it's offered instead of growing past it, which pushed Home's
    /// cold-start placeholders off the leading edge.
    func testRowsStayWithinAPhonePage() {
        let page = CGSize(width: 375, height: 560)
        let host = UIHostingController(rootView: PosterRowsSkeleton())

        let size = host.sizeThatFits(in: page)

        XCTAssertEqual(size.width, page.width, accuracy: 0.5)
        XCTAssertEqual(size.height, page.height, accuracy: 0.5)
    }
}
