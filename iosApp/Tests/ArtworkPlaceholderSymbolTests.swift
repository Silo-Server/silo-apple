import XCTest
@testable import Silo

final class ArtworkPlaceholderSymbolTests: XCTestCase {
    func testSeriesSeasonAndEpisodeUseTelevisionGlyph() {
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("series"), "tv")
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("Series"), "tv")
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("season"), "tv")
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("episode"), "tv")
    }

    func testMovieAndUnknownTypesKeepFilmGlyph() {
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("movie"), "film")
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType(nil), "film")
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType(""), "film")
    }

    func testAudiobookUsesHeadphonesGlyph() {
        XCTAssertEqual(ArtworkPlaceholderSymbol.forMediaType("audiobook"), "headphones")
    }
}
