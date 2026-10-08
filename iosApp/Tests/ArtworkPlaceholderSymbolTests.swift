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

final class MissingArtworkTests: XCTestCase {
    /// A row of missing posters should not collapse into one colour.
    func testTitlesGetDifferentTints() {
        let hues = Set((1...60).map { PlaceholderTint.hue(for: "untitled feature \($0)") })
        XCTAssertGreaterThan(hues.count, 40)
    }

    /// A tile keeps its colour across launches, devices and releases;
    /// art-less tvOS collection tiles already use this formula.
    func testHueIsStable() {
        XCTAssertEqual(PlaceholderTint.hue(for: ""), 61.0 / 360)
        XCTAssertEqual(PlaceholderTint.hue(for: "rough diamond"), 26.0 / 360)
    }
}
