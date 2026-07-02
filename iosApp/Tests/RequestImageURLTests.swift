import XCTest
@testable import Silo

final class RequestImageURLTests: XCTestCase {
    func testBuildsTMDBURL() {
        XCTAssertEqual(
            RequestImageURL.build("/abc123.jpg", size: .poster),
            "https://image.tmdb.org/t/p/w342/abc123.jpg"
        )
        XCTAssertEqual(
            RequestImageURL.build("/abc123.jpg", size: .backdrop),
            "https://image.tmdb.org/t/p/w1280/abc123.jpg"
        )
    }

    func testAbsoluteURLPassesThrough() {
        XCTAssertEqual(
            RequestImageURL.build("https://example.com/x.jpg", size: .poster),
            "https://example.com/x.jpg"
        )
    }

    func testBlankAndMalformedPathsAreNil() {
        XCTAssertNil(RequestImageURL.build(nil, size: .poster))
        XCTAssertNil(RequestImageURL.build("", size: .poster))
        XCTAssertNil(RequestImageURL.build("abc123.jpg", size: .poster))
    }

    // MARK: - Carousel merge (small enough to share this file)

    private func result(_ id: Int, type: RequestMediaType = .movie) -> RequestMediaResult {
        RequestMediaResult(
            mediaType: type,
            tmdbId: id,
            title: "Title \(id)",
            year: 2026,
            overview: nil,
            posterPath: nil,
            backdropPath: nil,
            releaseDate: nil,
            voteAverage: nil,
            availability: .missing,
            libraryContentId: nil,
            request: RequestState(status: nil, requestable: true, reason: nil, requestId: nil)
        )
    }

    private func section(_ key: String, _ results: [RequestMediaResult]) -> RequestDiscoverySection {
        RequestDiscoverySection(
            key: key,
            title: key,
            page: 1,
            totalPages: 1,
            totalResults: results.count,
            results: results
        )
    }

    func testInterleaveRoundRobinsUnevenLists() {
        let merged = RequestCarouselMerge.interleave([
            [result(1), result(2), result(3)],
            [result(10, type: .series)],
        ])
        XCTAssertEqual(merged.map(\.tmdbId), [1, 10, 2, 3])
    }

    func testInterleaveDropsDuplicateIds() {
        let merged = RequestCarouselMerge.interleave([
            [result(1), result(2)],
            [result(1), result(3)],
        ])
        XCTAssertEqual(merged.map(\.tmdbId), [1, 2, 3])
    }

    func testCarouselsMergeTrendingAndPopular() {
        let carousels = RequestCarouselMerge.carousels(from: [
            section("trending_movies", [result(1)]),
            section("trending_series", [result(2, type: .series)]),
            section("popular_movies", [result(3)]),
            section("upcoming_movies", [result(4)]), // not surfaced in v1
        ])
        XCTAssertEqual(carousels.map(\.id), ["trending", "popular"])
        XCTAssertEqual(carousels[0].results.map(\.tmdbId), [1, 2])
        XCTAssertEqual(carousels[1].results.map(\.tmdbId), [3])
    }

    func testEmptySectionsProduceNoCarousels() {
        XCTAssertTrue(RequestCarouselMerge.carousels(from: []).isEmpty)
    }
}
