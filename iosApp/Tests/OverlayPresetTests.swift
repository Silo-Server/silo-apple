import SwiftUI
import XCTest
@testable import Silo

/// Badge colours and the style layer, matched against the web client's
/// `presets.ts` and `applyOverlayStyle` in `style.ts`.
final class OverlayPresetTests: XCTestCase {
    private let gold = OverlayColor(rgb: 245, 197, 24)

    private func assertColor(
        _ actual: OverlayColor, _ expected: OverlayColor, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.red, expected.red, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(actual.green, expected.green, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(actual.blue, expected.blue, accuracy: 0.001, message, file: file, line: line)
        XCTAssertEqual(actual.alpha, expected.alpha, accuracy: 0.001, message, file: file, line: line)
    }

    func testAccentBackgroundsMatchTheWebColorMix() {
        // color-mix(in srgb, accent 28%, rgba(0,0,0,0.6)): premultiplied, so
        // the black's share takes its alpha with it.
        assertColor(
            OverlayPresets.preset(.classic).paint(gold).background,
            OverlayColor(red: gold.red * 0.28 / 0.712, green: gold.green * 0.28 / 0.712,
                         blue: gold.blue * 0.28 / 0.712, alpha: 0.712),
            "classic"
        )
        // color-mix(in srgb, accent 20%, rgba(20,20,30,0.7)).
        func pill(_ accent: Double, _ base: Double) -> Double { (0.2 * accent + 0.56 * base / 255) / 0.76 }
        assertColor(
            OverlayPresets.preset(.pill).paint(gold).background,
            OverlayColor(red: pill(gold.red, 20), green: pill(gold.green, 20), blue: pill(gold.blue, 30), alpha: 0.76),
            "pill"
        )
        // Without an accent the fill is the preset's own.
        assertColor(OverlayPresets.preset(.classic).paint(nil).background, .black.opacity(0.6))
    }

    func testHexColorsParseWithAndWithoutAlpha() {
        assertColor(try! XCTUnwrap(OverlayColor(hex: "#f5c518")), gold)
        assertColor(try! XCTUnwrap(OverlayColor(hex: "#00000080")), .black.opacity(128.0 / 255))
        XCTAssertNil(OverlayColor(hex: "f5c518"))
        XCTAssertNil(OverlayColor(hex: "#f5c51"))
        XCTAssertNil(OverlayColor(hex: "#gggggg"))
    }

    func testStyleSizeScalesTheBadgeAndShapeReplacesTheRadius() {
        let base = OverlayPresets.preset(.classic)
        let styled = base.applying(OverlayStyle(size: 1.5, shape: .square, fontWeight: .extrabold, uppercase: false))
        XCTAssertEqual(styled.fontSize, base.fontSize * 1.5)
        XCTAssertEqual(styled.paddingInline, base.paddingInline * 1.5)
        XCTAssertEqual(styled.iconSize, base.iconSize * 1.5)
        XCTAssertEqual(styled.stackGap, base.stackGap * 1.5)
        XCTAssertEqual(styled.cornerStyle, .rounded(2))
        XCTAssertEqual(styled.fontWeight, .heavy)
        XCTAssertFalse(styled.uppercase)
        // No style, no change.
        XCTAssertEqual(base.applying(nil).fontSize, base.fontSize)
    }

    func testFillOnBareTextPresetAddsPaddingAndReadableText() {
        // Minimal draws bare text: 4pt across, none down, white text with a shadow.
        let styled = OverlayPresets.preset(.minimal).applying(OverlayStyle(background: "#ffffffff"))
        XCTAssertEqual(styled.paddingInline, 9 * 0.6, accuracy: 0.001)
        XCTAssertEqual(styled.paddingBlock, 9 * 0.2, accuracy: 0.001)
        XCTAssertNil(styled.textShadow, "a shadow that lifts text off artwork muddies it on a fill")
        let paint = styled.paint(nil)
        assertColor(paint.background, .white)
        assertColor(paint.foreground, .black, "white text would not read on a white fill")
    }

    func testAccentTextThatWouldNotReadOnTheFillTintsItInstead() {
        let styled = OverlayPresets.preset(.minimal).applying(OverlayStyle(background: "#000000ff"))
        // Gold reads on black, so it stays the text colour.
        let readable = styled.paint(gold)
        assertColor(readable.foreground, gold)
        assertColor(readable.background, .black)
        // Near-black does not: it tints the fill, and the text is white.
        let dim = OverlayColor(rgb: 20, 20, 20)
        let tinted = styled.paint(dim)
        assertColor(tinted.foreground, .white)
        assertColor(tinted.background, dim.mixed(0.3, with: .black))
    }

    func testStyleColorsYieldToTheAccentWhereThePresetPaintsIt() {
        let style = OverlayStyle(background: "#20304080", textColor: "#abcdef", borderColor: "#11223344")
        let fill = try! XCTUnwrap(OverlayColor(hex: "#20304080"))
        let border = try! XCTUnwrap(OverlayColor(hex: "#11223344"))
        let text = try! XCTUnwrap(OverlayColor(hex: "#abcdef"))

        // Classic fills with the accent: the custom fill is tinted by it.
        let classic = OverlayPresets.preset(.classic).applying(style).paint(gold)
        assertColor(classic.background, gold.mixed(0.3, with: fill))
        assertColor(classic.foreground, text)
        assertColor(try! XCTUnwrap(classic.border), border)

        // Plate paints the accent on its border: the custom border yields.
        let plate = OverlayPresets.preset(.plate).applying(style).paint(gold)
        assertColor(plate.background, fill)
        assertColor(try! XCTUnwrap(plate.border), gold.mixed(0.45, with: .clear))
        assertColor(try! XCTUnwrap(OverlayPresets.preset(.plate).applying(style).paint(nil).border), border)
    }
}
