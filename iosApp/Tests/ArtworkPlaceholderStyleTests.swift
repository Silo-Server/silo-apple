import XCTest
@testable import Silo

/// What a missing image shows, per placeholder style.
final class ArtworkPlaceholderStyleTests: XCTestCase {
    func testArtworkShowsDefaultArtworkWithoutThumbhash() {
        XCTAssertEqual(ImagePlaceholderStyle.artwork.whenMissing(hasThumbhash: false), .defaultArtwork)
    }

    func testArtworkKeepsThumbhash() {
        XCTAssertEqual(ImagePlaceholderStyle.artwork.whenMissing(hasThumbhash: true), .placeholder)
    }

    func testOtherStylesAreUnchanged() {
        XCTAssertEqual(ImagePlaceholderStyle.surface.whenMissing(hasThumbhash: false), .glyph)
        XCTAssertEqual(ImagePlaceholderStyle.surface.whenMissing(hasThumbhash: true), .glyph)
        XCTAssertEqual(ImagePlaceholderStyle.clear.whenMissing(hasThumbhash: false), .placeholder)
    }
}
