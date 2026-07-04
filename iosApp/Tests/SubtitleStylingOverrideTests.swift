import XCTest

@testable import Silo

final class SubtitleStylingOverrideTests: XCTestCase {

    // MARK: - Helpers

    /// Splits the `Style: Default,...` line of a synthetic header into its
    /// comma-separated fields. Field indices follow the Format line:
    /// 0 name, 1 Fontname, 2 Fontsize, 3 Primary, 4 Secondary, 5 Outline,
    /// 6 Back, 7-10 attrs, 11-12 scale, 13-14 spacing/angle, 15 BorderStyle,
    /// 16 Outline size, 17 Shadow, 18 Alignment, 19-21 margins, 22 Encoding.
    private func styleFields(params: SubtitleStylingOverride.Parameters) -> [String] {
        let header = SubtitleStylingOverride.syntheticHeader(params: params, slot: .primary)
        guard let line = header.split(separator: "\n").first(where: { $0.hasPrefix("Style: Default,") }) else {
            XCTFail("no Default style line in header")
            return []
        }
        return line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    // MARK: - Box background opacity

    func testBoxHeaderUsesBorderStyle4WithOpacityInBackColour() {
        var params = SubtitleStylingOverride.Parameters.default
        params.backgroundStyle = .box
        params.backgroundOpacityPercent = 20
        params.backgroundColorHex = "#000000"

        let fields = styleFields(params: params)
        // 20% opacity → inverted ASS alpha = (100-20)*255/100 = 204 = 0xCC.
        XCTAssertEqual(fields[6], "&HCC000000") // BackColour carries the alpha
        XCTAssertEqual(fields[15], "4") // BorderStyle 4: box fill = BackColour
        XCTAssertGreaterThan(Double(fields[17]) ?? 0, 0) // Shadow field = box padding
    }

    func testFullyOpaqueBoxHeaderStillUsesBorderStyle4() {
        var params = SubtitleStylingOverride.Parameters.default
        params.backgroundStyle = .box
        params.backgroundOpacityPercent = 100

        let fields = styleFields(params: params)
        XCTAssertEqual(fields[6], "&H00000000")
        XCTAssertEqual(fields[15], "4")
    }

    func testZeroOpacityBoxHeaderFallsBackToPlainText() {
        var params = SubtitleStylingOverride.Parameters.default
        params.backgroundStyle = .box
        params.backgroundOpacityPercent = 0

        let fields = styleFields(params: params)
        XCTAssertEqual(fields[15], "1") // no box
        XCTAssertEqual(fields[17], "0.0") // no padding/shadow
    }

    // MARK: - Drop shadow visibility

    func testShadowHeaderHasVisibleShadowColor() {
        var params = SubtitleStylingOverride.Parameters.default
        params.backgroundStyle = .shadow

        let fields = styleFields(params: params)
        XCTAssertEqual(fields[15], "1") // outline+shadow border style
        XCTAssertEqual(fields[17], "1.5") // shadow depth
        // Shadow color must not be fully transparent (alpha 0xFF); expect
        // 50% black.
        XCTAssertEqual(fields[6], "&H80000000")
    }

    // MARK: - Struct color packing (libass internal RRGGBBAA)

    func testStructColorPackingIsInternalRGBA() {
        // Black box at 75% opacity: alpha byte (100-75)*255/100 = 63 = 0x3F
        // must land in the LOW byte, not the red channel — packing it high
        // rendered the default box as opaque dark red.
        XCTAssertEqual(
            SubtitleStylingOverride.assColor(hexRGBUInt: "#000000", alphaByte: 0x3F),
            0x0000003F
        )
        // Opaque white text.
        XCTAssertEqual(
            SubtitleStylingOverride.assColor(hexRGBUInt: "#FFFFFF", alphaByte: 0x00),
            0xFFFFFF00
        )
        // Channel order: pure red opaque → R in the high byte.
        XCTAssertEqual(
            SubtitleStylingOverride.assColor(hexRGBUInt: "#FF0000", alphaByte: 0x00),
            0xFF000000
        )
    }

    // MARK: - Font size presets (rebased so large == old xxlarge)

    func testFontSizePresetsRebasedAroundLarge() {
        #if os(iOS)
        XCTAssertEqual(SubtitleFontSizePreset.small.pointSize, 43)
        XCTAssertEqual(SubtitleFontSizePreset.medium.pointSize, 48)
        XCTAssertEqual(SubtitleFontSizePreset.large.pointSize, 54)
        XCTAssertEqual(SubtitleFontSizePreset.xlarge.pointSize, 65)
        XCTAssertEqual(SubtitleFontSizePreset.xxlarge.pointSize, 77)
        #endif
    }

    func testReferenceFontSizeTracksDefaultPreset() {
        XCTAssertEqual(
            SubtitleStylingOverride.Parameters.referenceFontSize,
            SubtitleAppearance.default.fontSize.pointSize
        )
    }
}
