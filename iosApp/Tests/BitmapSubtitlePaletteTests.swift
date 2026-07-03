import XCTest
@testable import Silo

/// Pure conversion tests for the PAL8 → premultiplied-RGBA path used by
/// bitmap subtitle decoding (PGS/DVD). Palette entries are 4 bytes in
/// FFmpeg's little-endian memory order: [B, G, R, A].
final class BitmapSubtitlePaletteTests: XCTestCase {

    /// 256-entry transparent palette with select entries overridden.
    private func makePalette(_ entries: [Int: (b: UInt8, g: UInt8, r: UInt8, a: UInt8)]) -> [UInt8] {
        var palette = [UInt8](repeating: 0, count: 256 * 4)
        for (index, value) in entries {
            palette[index * 4] = value.b
            palette[index * 4 + 1] = value.g
            palette[index * 4 + 2] = value.r
            palette[index * 4 + 3] = value.a
        }
        return palette
    }

    // MARK: - Premultiply rounding

    func testPremultiplyRoundHalfUpExactness() {
        // (channel × alpha + 127) / 255, integer division.
        XCTAssertEqual(BitmapSubtitlePalette.premultiply(255, by: 255), 255)
        XCTAssertEqual(BitmapSubtitlePalette.premultiply(255, by: 0), 0)
        XCTAssertEqual(BitmapSubtitlePalette.premultiply(0, by: 255), 0)
        XCTAssertEqual(BitmapSubtitlePalette.premultiply(255, by: 128), 128)
        XCTAssertEqual(BitmapSubtitlePalette.premultiply(200, by: 100), 78)  // 20127/255
        XCTAssertEqual(BitmapSubtitlePalette.premultiply(1, by: 127), 0)     // 254/255
        XCTAssertEqual(BitmapSubtitlePalette.premultiply(1, by: 128), 1)     // 255/255
    }

    // MARK: - Byte order

    func testPaletteBGRAConvertsToRGBAOutput() {
        let palette = makePalette([1: (b: 10, g: 20, r: 30, a: 255)])
        let plane = BitmapSubtitlePalette.premultipliedRGBA(
            indexes: [1],
            width: 1,
            height: 1,
            stride: 1,
            palette: palette
        )
        XCTAssertEqual(plane?.rgba, [30, 20, 10, 255])
    }

    func testSemiTransparentPixelIsPremultiplied() {
        let palette = makePalette([2: (b: 60, g: 120, r: 240, a: 100)])
        let plane = BitmapSubtitlePalette.premultipliedRGBA(
            indexes: [2],
            width: 1,
            height: 1,
            stride: 1,
            palette: palette
        )
        // (240*100+127)/255 = 94, (120*100+127)/255 = 47, (60*100+127)/255 = 24
        XCTAssertEqual(plane?.rgba, [94, 47, 24, 100])
    }

    // MARK: - Alpha bounding-box crop

    func testCropToSingleOpaquePixel() {
        let palette = makePalette([1: (b: 0, g: 0, r: 255, a: 255)])
        // 4×4 plane, single opaque pixel at (x: 2, y: 1).
        var indexes = [UInt8](repeating: 0, count: 16)
        indexes[1 * 4 + 2] = 1
        let plane = BitmapSubtitlePalette.premultipliedRGBA(
            indexes: indexes,
            width: 4,
            height: 4,
            stride: 4,
            palette: palette
        )
        XCTAssertEqual(plane?.cropX, 2)
        XCTAssertEqual(plane?.cropY, 1)
        XCTAssertEqual(plane?.cropWidth, 1)
        XCTAssertEqual(plane?.cropHeight, 1)
        XCTAssertEqual(plane?.rgba, [255, 0, 0, 255])
    }

    func testCropSpansOpaqueExtremes() {
        let palette = makePalette([1: (b: 0, g: 0, r: 0, a: 255)])
        // Opaque pixels at (1,0) and (3,2) → box x:1...3, y:0...2.
        var indexes = [UInt8](repeating: 0, count: 5 * 3)
        indexes[0 * 5 + 1] = 1
        indexes[2 * 5 + 3] = 1
        let plane = BitmapSubtitlePalette.premultipliedRGBA(
            indexes: indexes,
            width: 5,
            height: 3,
            stride: 5,
            palette: palette
        )
        XCTAssertEqual(plane?.cropX, 1)
        XCTAssertEqual(plane?.cropY, 0)
        XCTAssertEqual(plane?.cropWidth, 3)
        XCTAssertEqual(plane?.cropHeight, 3)
    }

    func testAlphaFloorBoundary() {
        // Alpha 7 is below the default floor of 8 → invisible; 8 counts.
        let below = makePalette([1: (b: 0, g: 0, r: 0, a: 7)])
        XCTAssertNil(BitmapSubtitlePalette.premultipliedRGBA(
            indexes: [1], width: 1, height: 1, stride: 1, palette: below
        ))

        let at = makePalette([1: (b: 0, g: 0, r: 0, a: 8)])
        let plane = BitmapSubtitlePalette.premultipliedRGBA(
            indexes: [1], width: 1, height: 1, stride: 1, palette: at
        )
        XCTAssertEqual(plane?.rgba[3], 8)
    }

    func testFullyTransparentPlaneReturnsNil() {
        let palette = makePalette([:])
        XCTAssertNil(BitmapSubtitlePalette.premultipliedRGBA(
            indexes: [UInt8](repeating: 0, count: 16),
            width: 4,
            height: 4,
            stride: 4,
            palette: palette
        ))
    }

    // MARK: - Stride handling

    func testStrideLargerThanWidthSkipsRowPadding() {
        let palette = makePalette([
            1: (b: 0, g: 0, r: 255, a: 255),
            2: (b: 255, g: 0, r: 0, a: 255)
        ])
        // width 2, stride 4: padding bytes reference entry 2 and must be
        // ignored; visible pixels are entry 1 at (0,0) and (1,1).
        var indexes = [UInt8](repeating: 0, count: 4 * 2)
        indexes[0] = 1          // row 0, col 0
        indexes[2] = 2          // row 0, padding
        indexes[4 + 1] = 1      // row 1, col 1
        indexes[4 + 3] = 2      // row 1, padding
        let plane = BitmapSubtitlePalette.premultipliedRGBA(
            indexes: indexes,
            width: 2,
            height: 2,
            stride: 4,
            palette: palette
        )
        XCTAssertEqual(plane?.cropWidth, 2)
        XCTAssertEqual(plane?.cropHeight, 2)
        // Red at (0,0), transparent at (1,0), transparent at (0,1), red at (1,1).
        XCTAssertEqual(plane?.rgba, [
            255, 0, 0, 255, 0, 0, 0, 0,
            0, 0, 0, 0, 255, 0, 0, 255
        ])
    }

    func testStrideShorterThanWidthIsRejected() {
        let palette = makePalette([1: (b: 0, g: 0, r: 0, a: 255)])
        XCTAssertNil(BitmapSubtitlePalette.premultipliedRGBA(
            indexes: [UInt8](repeating: 1, count: 16),
            width: 4,
            height: 4,
            stride: 3,
            palette: palette
        ))
    }

    func testUndersizedBuffersAreRejected() {
        let palette = makePalette([1: (b: 0, g: 0, r: 0, a: 255)])
        // Index buffer too small for the claimed geometry.
        XCTAssertNil(BitmapSubtitlePalette.premultipliedRGBA(
            indexes: [1, 1],
            width: 2,
            height: 2,
            stride: 2,
            palette: palette
        ))
        // Palette shorter than 256 entries.
        XCTAssertNil(BitmapSubtitlePalette.premultipliedRGBA(
            indexes: [1, 1, 1, 1],
            width: 2,
            height: 2,
            stride: 2,
            palette: [0, 0, 0, 255]
        ))
    }

    // MARK: - CGImage factory

    func testMakeImageProducesMatchingDimensions() {
        let palette = makePalette([1: (b: 0, g: 128, r: 255, a: 255)])
        guard let plane = BitmapSubtitlePalette.premultipliedRGBA(
            indexes: [UInt8](repeating: 1, count: 6),
            width: 3,
            height: 2,
            stride: 3,
            palette: palette
        ) else {
            return XCTFail("conversion failed")
        }
        let image = BitmapSubtitlePalette.makeImage(from: plane)
        XCTAssertEqual(image?.width, 3)
        XCTAssertEqual(image?.height, 2)
        XCTAssertEqual(image?.alphaInfo, .premultipliedLast)
    }
}
