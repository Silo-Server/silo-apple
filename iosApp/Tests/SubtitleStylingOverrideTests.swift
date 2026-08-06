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

    func testSystemForegroundOpacityReachesASSPrimaryColour() {
        var appearance = SubtitleAppearance.default
        appearance.fontColor = "#ffffff"
        appearance.fontOpacity = 40
        let params = SubtitleStylingOverride.Parameters.from(appearance: appearance, syncOffsetMs: 0)

        XCTAssertEqual(styleFields(params: params)[3], "&H99FFFFFF")
        XCTAssertEqual(
            SubtitleStylingOverride.assColor(
                hexRGBUInt: params.textColorHex,
                alphaByte: params.textAlphaByte
            ),
            0xFFFFFF99
        )
    }

    func testSystemRelativeSizeDoesNotQuantizeToPresetLadder() {
        var appearance = SubtitleAppearance.default
        appearance.systemRelativeFontScale = 1.75
        let params = SubtitleStylingOverride.Parameters.from(appearance: appearance, syncOffsetMs: 0)

        XCTAssertEqual(
            params.fontSize,
            SubtitleStylingOverride.Parameters.referenceFontSize * 1.75,
            accuracy: 0.001
        )
    }

    func testSystemWindowParametersRemainSeparateFromGlyphBackground() {
        var appearance = SubtitleAppearance.default
        appearance.backgroundColor = "#000000"
        appearance.backgroundOpacity = 80
        appearance.captionWindowColor = "#ff00ff"
        appearance.captionWindowOpacity = 50
        appearance.captionWindowCornerRadius = 8
        appearance.systemContentOverrides = [.font, .window]
        let params = SubtitleStylingOverride.Parameters.from(appearance: appearance, syncOffsetMs: 0)

        XCTAssertEqual(params.backgroundColorHex, "#000000")
        XCTAssertEqual(params.backgroundOpacityPercent, 80)
        XCTAssertEqual(params.captionWindowColorHex, "#ff00ff")
        XCTAssertEqual(params.captionWindowOpacityPercent, 50)
        XCTAssertEqual(params.captionWindowCornerRadius, 8)
        XCTAssertEqual(params.systemContentOverrides, [.font, .window])
    }

    func testSystemOnlyAppearanceFieldsAreNotServerEncoded() {
        var appearance = SubtitleAppearance.default
        appearance.fontOpacity = 25
        appearance.systemRelativeFontScale = 1.75
        appearance.systemTextEdgeStyle = .raised
        appearance.captionWindowColor = "#ff00ff"
        appearance.captionWindowOpacity = 50
        appearance.captionWindowCornerRadius = 8
        appearance.systemContentOverrides = [.font, .window]

        let json = appearance.jsonString
        XCTAssertFalse(json.contains("fontOpacity"))
        XCTAssertFalse(json.contains("systemRelativeFontScale"))
        XCTAssertFalse(json.contains("captionWindow"))
        XCTAssertFalse(json.contains("systemContentOverrides"))
    }

    func testNativeColorOverridesRemainPerProperty() {
        var appearance = SubtitleAppearance.default
        appearance.fontColor = "#22c55e"
        appearance.fontOpacity = 40
        appearance.backgroundColor = "#ff00ff"
        appearance.backgroundOpacity = 50
        appearance.systemContentOverrides = [.foregroundColor, .backgroundOpacity]

        let params = SubtitleStylingOverride.Parameters.from(appearance: appearance, syncOffsetMs: 0)
        XCTAssertEqual(params.nativeForegroundColorOverride?.0, 0x22)
        XCTAssertEqual(params.nativeForegroundColorOverride?.1, 0xC5)
        XCTAssertEqual(params.nativeForegroundColorOverride?.2, 0x5E)
        XCTAssertNil(params.nativeForegroundAlphaOverride)
        XCTAssertNil(params.nativeBackgroundColorOverride)
        XCTAssertEqual(params.nativeBackgroundAlphaOverride, 127)
    }

    func testDropShadowWithGlyphBoxUsesIndependentCompositorEdge() {
        var params = SubtitleStylingOverride.Parameters.default
        params.backgroundStyle = .box
        params.backgroundOpacityPercent = 80
        params.systemTextEdgeStyle = .dropShadow

        XCTAssertEqual(params.assBorderStyle, 4)
        XCTAssertEqual(params.assShadow, params.boxPadding)
        XCTAssertNotNil(params.compositedEdgeShadow)
    }

    func testRaisedAndDepressedEdgesUseVisibleBackColours() {
        var raised = SubtitleStylingOverride.Parameters.default
        raised.backgroundStyle = SubtitleBackgroundStylePreset.none
        raised.systemTextEdgeStyle = .raised
        XCTAssertEqual(raised.effectiveBackColorHex, "#FFFFFF")
        XCTAssertNotEqual(raised.backgroundAlphaByte, 0xFF)
        XCTAssertEqual(raised.assShadow, 0)
        XCTAssertEqual(raised.compositedEdgeShadow?.offsetX, -1)
        XCTAssertEqual(raised.compositedEdgeShadow?.offsetY, -1)

        var depressed = raised
        depressed.systemTextEdgeStyle = .depressed
        XCTAssertEqual(depressed.effectiveBackColorHex, "#000000")
        XCTAssertNotEqual(depressed.backgroundAlphaByte, 0xFF)
        XCTAssertGreaterThan(depressed.assShadow, 0)
    }

    func testCaptionWindowGroupingSeparatesDistantSimultaneousCues() {
        let leftCue = [
            CGRect(x: 20, y: 400, width: 80, height: 30),
            CGRect(x: 110, y: 400, width: 70, height: 30),
        ]
        let positionedSign = CGRect(x: 700, y: 80, width: 120, height: 40)

        let groups = SubtitleRenderer.groupedPaintedBounds(
            leftCue + [positionedSign],
            joiningDistance: 20
        )

        XCTAssertEqual(groups.count, 2)
        XCTAssertTrue(groups.contains(where: { $0.contains(CGPoint(x: 50, y: 410)) }))
        XCTAssertTrue(groups.contains(where: { $0.contains(CGPoint(x: 750, y: 90)) }))
    }

    func testNativeCaptionWindowRequiresItsOwnOpacityOverride() {
        XCTAssertFalse(SubtitleRenderer.shouldDrawCaptionWindow(
            isNativeASS: true,
            opacityPercent: 50,
            overrides: [.windowCornerRadius]
        ))
        XCTAssertTrue(SubtitleRenderer.shouldDrawCaptionWindow(
            isNativeASS: true,
            opacityPercent: 50,
            overrides: [.windowOpacity]
        ))
    }

    func testNativeBackgroundIsSynthesizedWhenEitherPropertyOverridesContent() {
        XCTAssertTrue(SubtitleRenderer.shouldSynthesizeGlyphBackground(
            isNativeASS: true,
            opacityPercent: 50,
            overrides: [.backgroundColor],
            hasAuthoredBackground: false
        ))
        XCTAssertTrue(SubtitleRenderer.shouldSynthesizeGlyphBackground(
            isNativeASS: true,
            opacityPercent: 50,
            overrides: [.backgroundOpacity],
            hasAuthoredBackground: false
        ))
        XCTAssertFalse(SubtitleRenderer.shouldSynthesizeGlyphBackground(
            isNativeASS: true,
            opacityPercent: 50,
            overrides: [.backgroundColor],
            hasAuthoredBackground: true
        ))
        XCTAssertFalse(SubtitleRenderer.shouldSynthesizeGlyphBackground(
            isNativeASS: false,
            opacityPercent: 50,
            overrides: [.backgroundOpacity],
            hasAuthoredBackground: false
        ))
    }

    func testSolidBackgroundMaskDetectionRejectsGlyphMasks() {
        let solid = [UInt8](repeating: 0xFF, count: 12)
        var glyph = solid
        glyph[5] = 0

        solid.withUnsafeBufferPointer {
            XCTAssertTrue(SubtitleRenderer.isSolidBackgroundMask(
                $0.baseAddress,
                width: 4,
                height: 3,
                stride: 4
            ))
        }
        glyph.withUnsafeBufferPointer {
            XCTAssertFalse(SubtitleRenderer.isSolidBackgroundMask(
                $0.baseAddress,
                width: 4,
                height: 3,
                stride: 4
            ))
        }
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

    // MARK: - Outline color source

    func testOutlineColorAlwaysComesFromUserOutlineColor() {
        // Regression: legacy "outline" background style borrowed the
        // background color for the glyph outline, contradicting the web
        // player, Android, and every preview (which all use the user's
        // outline color).
        var params = SubtitleStylingOverride.Parameters.default
        params.borderSize = 2
        params.borderColorHex = "#7f1d1d"
        params.backgroundColorHex = "#14532d"
        params.backgroundStyle = .outline
        XCTAssertEqual(params.effectiveOutlineColorHex, "#7f1d1d")

        params.backgroundStyle = .box
        params.textOutline = true
        XCTAssertEqual(params.effectiveOutlineColorHex, "#7f1d1d")
    }

    func testLegacyOutlineAppearanceProducesOutlineParameters() {
        var appearance = SubtitleAppearance.default
        appearance.backgroundStyle = .outline
        appearance.textOutline = false
        appearance.textOutlineColor = "#1e3a5f"

        let params = SubtitleStylingOverride.Parameters.from(appearance: appearance, syncOffsetMs: 0)
        // sanitized() folds legacy outline into the text-outline axis.
        XCTAssertEqual(params.backgroundStyle, SubtitleBackgroundStylePreset.none)
        XCTAssertTrue(params.textOutline)
        XCTAssertEqual(params.borderSize, 2)
        XCTAssertEqual(params.effectiveOutlineColorHex, "#1e3a5f")
        XCTAssertEqual(params.backgroundOpacityPercent, 0)
    }

    // MARK: - Appearance sanitization

    func testSanitizedMigratesLegacyOutlineBackgroundStyle() {
        var appearance = SubtitleAppearance.default
        appearance.backgroundStyle = .outline
        appearance.textOutline = false

        let sanitized = appearance.sanitized()
        XCTAssertEqual(sanitized.backgroundStyle, SubtitleBackgroundStylePreset.none)
        XCTAssertTrue(sanitized.textOutline)
    }

    func testDecodeAppliesLegacyOutlineMigration() {
        let json = #"{"backgroundStyle":"outline","textOutline":false}"#
        let decoded = SubtitleAppearance.decode(from: json)
        XCTAssertEqual(decoded.backgroundStyle, SubtitleBackgroundStylePreset.none)
        XCTAssertTrue(decoded.textOutline)
    }

    func testSelectableBackgroundStylesExcludeLegacyOutline() {
        XCTAssertEqual(
            SubtitleBackgroundStylePreset.selectableCases,
            [.box, .shadow, SubtitleBackgroundStylePreset.none]
        )
    }

    // MARK: - Legibility hint

    func testLowLegibilityRiskFlagsDarkPlainText() {
        var appearance = SubtitleAppearance.default
        appearance.fontColor = "#000000"
        appearance.backgroundStyle = SubtitleBackgroundStylePreset.none
        appearance.textOutline = false
        XCTAssertTrue(appearance.isLowLegibilityRisk)

        appearance.textOutline = true
        XCTAssertFalse(appearance.isLowLegibilityRisk)

        appearance.textOutline = false
        appearance.backgroundStyle = .box
        appearance.backgroundOpacity = 75
        XCTAssertFalse(appearance.isLowLegibilityRisk)

        appearance.fontColor = "#ffffff"
        appearance.backgroundStyle = SubtitleBackgroundStylePreset.none
        XCTAssertFalse(appearance.isLowLegibilityRisk)
    }
}
