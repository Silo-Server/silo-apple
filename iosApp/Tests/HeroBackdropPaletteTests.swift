import XCTest
@testable import Silo

final class HeroBackdropPaletteTests: XCTestCase {
    private typealias RGB = HeroBackdropPalette.RGB

    func testAccentPicksTheVividHueOverALargerMutedArea() throws {
        // Mostly dusky blue sky with a small, saturated orange fire.
        let sky = Array(repeating: RGB(r: 0.20, g: 0.26, b: 0.36), count: 90)
        let fire = Array(repeating: RGB(r: 0.95, g: 0.45, b: 0.10), count: 10)

        let tints = try XCTUnwrap(HeroBackdropPalette.sample(pixels: sky + fire))

        XCTAssertGreaterThan(tints.accent.r, tints.accent.b)
        XCTAssertLessThan(tints.base.r, tints.base.b)
    }

    func testGrayscaleArtFallsBackToTheBaseForTheAccent() throws {
        let pixels = (0..<100).map { index in
            let value = Double(index) / 100
            return RGB(r: value, g: value, b: value)
        }

        let tints = try XCTUnwrap(HeroBackdropPalette.sample(pixels: pixels))

        XCTAssertEqual(tints.accent, tints.base)
    }

    func testShadowStaysDarkerThanTheBase() throws {
        let pixels = (0..<100).map { index in
            let value = Double(index) / 100
            return RGB(r: value, g: value * 0.8, b: value * 0.6)
        }

        let tints = try XCTUnwrap(HeroBackdropPalette.sample(pixels: pixels))

        XCTAssertLessThan(tints.shadow.luminance, tints.base.luminance)
        XCTAssertGreaterThan(tints.shadow.luminance, 0)
    }

    func testBrightArtIsDimmedForTheDarkTheme() throws {
        let pixels = Array(repeating: RGB(r: 0.9, g: 0.9, b: 0.85), count: 16)

        let tints = try XCTUnwrap(HeroBackdropPalette.sample(pixels: pixels))

        XCTAssertEqual(tints.base.luminance, 0.22, accuracy: 0.001)
    }
}
