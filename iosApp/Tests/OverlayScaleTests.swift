import SwiftUI
import XCTest
@testable import Silo

/// Card overlay badges follow both the card's size and the viewer's text size.
final class OverlayScaleTests: XCTestCase {
    func testPosterBadgesScaleWithTheCardWidth() {
        let reference = CardOverlays.posterReferenceWidth
        XCTAssertEqual(OverlayScale.cardScale(cardWidth: reference, variant: .poster, posterSize: .standard), 1)
        XCTAssertEqual(OverlayScale.cardScale(cardWidth: reference * 1.2, variant: .poster, posterSize: .standard), 1.2, accuracy: 0.0001)
        // The width already carries the card-size setting; it is not applied twice.
        XCTAssertEqual(OverlayScale.cardScale(cardWidth: reference, variant: .poster, posterSize: .large), 1)
    }

    func testWideBadgesFollowTheCardSizeSetting() {
        for size in CardPosterSize.allCases {
            XCTAssertEqual(OverlayScale.cardScale(cardWidth: 999, variant: .wide, posterSize: size), size.scale)
        }
    }

    func testTextSizeGrowsBadgesWithinTheCap() {
        XCTAssertEqual(OverlayScale.textFactor(.large), 1, accuracy: 0.0001)
        // Smaller text never shrinks a badge.
        XCTAssertEqual(OverlayScale.textFactor(.xSmall), 1, accuracy: 0.0001)
        XCTAssertLessThanOrEqual(OverlayScale.textFactor(.accessibility5), OverlayScale.maxTextFactor)

        let sizes = DynamicTypeSize.allCases
        let factors = sizes.map(OverlayScale.textFactor)
        XCTAssertEqual(factors, factors.sorted(), "a larger text size never draws smaller badges")

        #if os(iOS)
        XCTAssertGreaterThan(OverlayScale.textFactor(.xxLarge), 1)
        XCTAssertEqual(OverlayScale.textFactor(.accessibility5), OverlayScale.maxTextFactor, accuracy: 0.0001)
        #else
        // tvOS and macOS have no text-size setting.
        XCTAssertEqual(Set(factors), [1])
        #endif
    }

    func testTheWatchedChecksUseTheirCardsScale() {
        let width = CardOverlays.posterReferenceWidth * 0.8
        XCTAssertEqual(
            OverlayScale.poster(cardWidth: width, dynamicTypeSize: .xxLarge),
            OverlayScale.value(cardWidth: width, variant: .poster, posterSize: .large, dynamicTypeSize: .xxLarge)
        )
        XCTAssertEqual(
            OverlayScale.wide(posterSize: .compact, dynamicTypeSize: .xxLarge),
            OverlayScale.value(cardWidth: 400, variant: .wide, posterSize: .compact, dynamicTypeSize: .xxLarge)
        )
    }

    func testTheScaleIsTheCardScaleTimesTheTextFactor() {
        let width = CardOverlays.posterReferenceWidth * 0.8
        let value = OverlayScale.value(cardWidth: width, variant: .poster, posterSize: .standard, dynamicTypeSize: .xxxLarge)
        XCTAssertEqual(value, 0.8 * OverlayScale.textFactor(.xxxLarge), accuracy: 0.0001)
    }
}
