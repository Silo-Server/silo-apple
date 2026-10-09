import XCTest
@testable import Silo

final class ArtworkPlaceholderSymbolTests: XCTestCase {
    func testSeriesSeasonAndEpisodeUseTelevisionGlyph() {
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("series"), "tv")
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("Series"), "tv")
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("season"), "tv")
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("episode"), "tv")
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("Episodes"), "tv")
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("season_premiere"), "tv")
    }

    func testMovieAndUnknownTypesKeepFilmGlyph() {
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("movie"), "film")
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType(nil), "film")
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType(""), "film")
    }

    func testAudioUsesHeadphonesGlyph() {
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("audiobook"), "headphones")
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("podcast"), "headphones")
    }

    func testReadingFormatsUseBookGlyph() {
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("ebook"), "book.closed")
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("manga"), "book.closed")
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("comic"), "book.closed")
    }
}
