import XCTest
import Nuke
@testable import Silo

final class ArtworkDecodeSizeTests: XCTestCase {
    func testCardsAFewPointsApartShareOneDecode() throws {
        // iPhone grid cards are 115 or 120 pt wide depending on screen width.
        let narrow = try XCTUnwrap(PosterImageCache.decodePixelSize(forPointSize: CGSize(width: 115, height: 189.75), scale: 3))
        let wide = try XCTUnwrap(PosterImageCache.decodePixelSize(forPointSize: CGSize(width: 120, height: 198), scale: 3))
        XCTAssertEqual(narrow, wide)
    }

    func testDecodeCoversTheDrawnSizeAndKeepsItsShape() throws {
        let drawn = CGSize(width: 176 * 2, height: 264 * 2)
        let decode = try XCTUnwrap(PosterImageCache.decodePixelSize(forPointSize: CGSize(width: 176, height: 264), scale: 2))
        XCTAssertGreaterThanOrEqual(decode.width, drawn.width)
        XCTAssertGreaterThanOrEqual(decode.height, drawn.height)
        XCTAssertEqual(decode.width / decode.height, drawn.width / drawn.height, accuracy: 0.01)
        XCTAssertLessThan(decode.height, drawn.height * 1.27)
    }

    func testEmptyLayoutHasNoDecode() {
        XCTAssertNil(PosterImageCache.decodePixelSize(forPointSize: .zero, scale: 2))
    }

    func testLargerDecodeInMemoryServesSmallerCard() throws {
        let previous = ImagePipeline.shared
        ImagePipeline.shared = ImagePipeline { $0.imageCache = ImageCache() }
        defer { ImagePipeline.shared = previous }

        let url = try XCTUnwrap(URL(string: "https://example.test/variant-\(UUID().uuidString).jpg"))
        let large = try XCTUnwrap(PosterImageCache.displayRequest(url: url, pointSize: CGSize(width: 260, height: 390), scale: 2))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 15)).image { _ in }
        ImagePipeline.shared.cache[large] = ImageContainer(image: image)

        let smallCard = try XCTUnwrap(PosterImageCache.decodePixelSize(forPointSize: CGSize(width: 176, height: 264), scale: 2))
        let served = try XCTUnwrap(PosterImageCache.cachedVariant(of: url, for: smallCard))
        XCTAssertTrue(served.isSufficient)

        let hugeCard = try XCTUnwrap(PosterImageCache.decodePixelSize(forPointSize: CGSize(width: 600, height: 900), scale: 2))
        let placeholder = try XCTUnwrap(PosterImageCache.cachedVariant(of: url, for: hugeCard))
        XCTAssertFalse(placeholder.isSufficient)
    }
}
