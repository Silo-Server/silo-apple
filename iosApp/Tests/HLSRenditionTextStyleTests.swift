import AVFoundation
import CoreMedia
import XCTest
@testable import Silo

/// AVPlayer draws a server HLS stream's subtitle renditions itself, so Silo's
/// appearance reaches them as text style rules instead of through the overlay.
final class HLSRenditionTextStyleTests: XCTestCase {
    func testDefaultAppearanceKeepsAVPlayersSizeAndDrawsTheBox() throws {
        let attributes = HLSRenditionTextStyle.attributes(
            for: AetherSubtitleRenderStyle(appearance: .default))
        XCTAssertEqual(attributes[kCMTextMarkupAttribute_ForegroundColorARGB as String] as? [Double], [1, 1, 1, 1])
        XCTAssertEqual(attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] as? [Double],
                       [0.75, 0, 0, 0])
        XCTAssertEqual(try XCTUnwrap(attributes[kCMTextMarkupAttribute_RelativeFontSize as String] as? Double),
                       100, accuracy: 0.001)
        XCTAssertEqual(attributes[kCMTextMarkupAttribute_GenericFontFamilyName as String] as? String,
                       kCMTextMarkupGenericFontName_SansSerif as String)
        XCTAssertEqual(attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] as? String,
                       kCMTextMarkupCharacterEdgeStyle_None as String)
    }

    func testShadowAppearanceDropsTheBoxAndShadowsTheText() {
        var appearance = SubtitleAppearance.default
        appearance.backgroundStyle = .shadow
        appearance.fontColor = "#facc15"
        appearance.fontSize = .small
        let attributes = HLSRenditionTextStyle.attributes(for: AetherSubtitleRenderStyle(appearance: appearance))
        XCTAssertEqual(attributes[kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String] as? [Double],
                       [0, 0, 0, 0], "no box is a transparent one, not AVPlayer's backdrop")
        XCTAssertEqual(attributes[kCMTextMarkupAttribute_CharacterEdgeStyle as String] as? String,
                       kCMTextMarkupCharacterEdgeStyle_DropShadow as String)
        let foreground = attributes[kCMTextMarkupAttribute_ForegroundColorARGB as String] as? [Double]
        XCTAssertEqual(foreground?.first, 1)
        XCTAssertEqual(foreground?[1] ?? 0, 0xfa / 255.0, accuracy: 0.001)
        XCTAssertLessThan(attributes[kCMTextMarkupAttribute_RelativeFontSize as String] as? Double ?? 100, 100)
    }

    func testMatchingTheDeviceLeavesAVPlayerOnItsOwnStyle() {
        XCTAssertNil(HLSRenditionTextStyle.rules(appearance: .default, matchesSystemAppearance: true))
        XCTAssertEqual(HLSRenditionTextStyle.rules(appearance: .default, matchesSystemAppearance: false)?.count, 1)
    }
}
