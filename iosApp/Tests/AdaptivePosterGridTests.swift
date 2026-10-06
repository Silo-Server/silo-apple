import SwiftUI
import XCTest
@testable import Silo

final class AdaptivePosterGridTests: XCTestCase {
    private let minimum = AdaptiveColumns.tabletMinimumPosterWidth
    private let spacing = AdaptiveColumns.tabletPosterSpacing

    private func fit(_ width: CGFloat, minimum: CGFloat? = nil) -> AdaptiveColumns.PosterGridFit? {
        AdaptiveColumns.widthFittedPosters(
            containerWidth: width,
            minimumCardWidth: minimum ?? self.minimum,
            spacing: spacing
        )
    }

    /// iPad Pro 11" portrait: 834pt less the grid's 16pt side padding.
    func testPortraitTabletFillsFiveColumns() throws {
        let fit = try XCTUnwrap(fit(802))
        XCTAssertEqual(fit.columnCount, 5)
        XCTAssertEqual(fit.cardWidth, 150.8, accuracy: 0.01)
    }

    /// iPad Pro 11" landscape gains columns rather than wider gaps.
    func testLandscapeTabletAddsColumns() throws {
        let fit = try XCTUnwrap(fit(1_178))
        XCTAssertEqual(fit.columnCount, 7)
        XCTAssertEqual(fit.cardWidth, (1_178 - 6 * spacing) / 7, accuracy: 0.01)
    }

    /// A Slide Over pane is narrower than two minimum cards; it still gets
    /// two columns, slightly under the minimum, rather than one huge poster.
    func testNarrowPaneKeepsTwoColumns() throws {
        let fit = try XCTUnwrap(fit(288))
        XCTAssertEqual(fit.columnCount, 2)
        XCTAssertEqual(fit.cardWidth, 138, accuracy: 0.01)
    }

    func testLargeCardPreferenceUsesFewerWiderColumns() throws {
        let fit = try XCTUnwrap(fit(802, minimum: minimum * CardPosterSize.large.scale))
        XCTAssertEqual(fit.columnCount, 4)
        XCTAssertEqual(fit.cardWidth, 191.5, accuracy: 0.01)
    }

    func testUnmeasuredContainerHasNoFit() {
        XCTAssertNil(fit(0))
    }

    /// Split View and Stage Manager can size the window to any width. Cards
    /// always fill the row exactly and stay between the minimum and twice it.
    func testEveryWidthFillsTheRowWithoutGaps() throws {
        for width in stride(from: CGFloat(300), through: 1_600, by: 1) {
            let fit = try XCTUnwrap(fit(width))
            let used = CGFloat(fit.columnCount) * fit.cardWidth + CGFloat(fit.columnCount - 1) * spacing
            XCTAssertEqual(used, width, accuracy: 0.001, "width \(width)")
            XCTAssertGreaterThanOrEqual(fit.cardWidth, minimum, "width \(width)")
            XCTAssertLessThan(fit.cardWidth, minimum * 2 + spacing, "width \(width)")
        }
    }

    #if !os(tvOS)
    /// The detail chrome times its backing strip from the same choice the
    /// hero makes, so both must agree on every width.
    func testHeroLayoutChoice() {
        XCTAssertFalse(PhoneDetailHeroLayout.usesExpandedLayout(
            availableWidth: 900, horizontalSizeClass: .compact, verticalSizeClass: .regular
        ))
        XCTAssertTrue(PhoneDetailHeroLayout.usesExpandedLayout(
            availableWidth: 834, horizontalSizeClass: .regular, verticalSizeClass: .regular
        ))
        XCTAssertFalse(PhoneDetailHeroLayout.usesExpandedLayout(
            availableWidth: 640, horizontalSizeClass: .regular, verticalSizeClass: .regular
        ))
        XCTAssertTrue(PhoneDetailHeroLayout.usesExpandedLayout(
            availableWidth: 0, horizontalSizeClass: .regular, verticalSizeClass: .regular
        ))
    }
    #endif
}
