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
            request: RequestState(status: nil, state: nil, requestable: true, reason: nil, requestId: nil)
        )
    }

    private func section(_ key: String, _ results: [RequestMediaResult]) -> RequestDiscoverySection {
        RequestDiscoverySection(
            key: key,
            title: key,
            page: 1,
            totalPages: 1,
            totalResults: results.count,
            results: results,
            nextPage: nil
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

    func testALayoutShowsTheServersRowsInItsOrder() {
        var anime = section("r_anime", [result(5, type: .series)])
        anime = RequestDiscoverySection(key: anime.key, title: "Anime", page: 1, totalPages: 4, totalResults: 80, results: anime.results, nextPage: nil)
        let layout = RequestDiscoverLayout(
            sections: [section("trending_movies", [result(1)]), anime, section("r_empty", [])],
            rowOrder: [
                RequestDiscoverRowRef(key: "r_anime", type: "tmdb_discover", title: "Anime"),
                RequestDiscoverRowRef(key: "studios", type: "studios", title: "Studios"),
                RequestDiscoverRowRef(key: "trending_movies", type: "tmdb_chart", title: "Trending Movies"),
                RequestDiscoverRowRef(key: "r_empty", type: "mdblist", title: "Empty"),
            ]
        )
        let carousels = RequestCarouselMerge.carousels(from: layout)
        // The brand row has no section and the empty row has no titles: both skipped.
        XCTAssertEqual(carousels.map(\.id), ["r_anime", "trending_movies"])
        XCTAssertEqual(carousels.map(\.seeAll), [true, false])
        // A one-page row trimmed to its size still has more to see.
        var trimmed = section("r_list", [result(7)])
        trimmed = RequestDiscoverySection(key: trimmed.key, title: "List", page: 1, totalPages: 1, totalResults: 12, results: trimmed.results, nextPage: nil)
        let trimmedLayout = RequestDiscoverLayout(sections: [trimmed], rowOrder: [RequestDiscoverRowRef(key: "r_list", type: "mdblist", title: "List")])
        XCTAssertEqual(RequestCarouselMerge.carousels(from: trimmedLayout).map(\.seeAll), [true])
        // Without a row order, the two merged carousels.
        XCTAssertEqual(RequestCarouselMerge.carousels(from: RequestDiscoverLayout(sections: layout.sections, rowOrder: [])).map(\.id), ["trending"])
    }

    func testSeeAllPagesFollowTheServersCursor() {
        func page(_ total: Int, next: Int? = nil) -> RequestDiscoverySection {
            RequestDiscoverySection(key: "r", title: "R", page: 1, totalPages: total, totalResults: total * 20, results: [], nextPage: next)
        }
        XCTAssertEqual(RequestDiscoverPaging.nextPage(after: page(3), requested: 1), 2)
        XCTAssertNil(RequestDiscoverPaging.nextPage(after: page(3), requested: 3))
        XCTAssertEqual(RequestDiscoverPaging.nextPage(after: page(40, next: 4), requested: 1), 4)
        // A page that read one source page, after cursor pages: page + 1.
        XCTAssertEqual(RequestDiscoverPaging.nextPage(after: page(40), requested: 9), 10)
        // A cursor past the last page: the read used the row up.
        XCTAssertNil(RequestDiscoverPaging.nextPage(after: page(2, next: 3), requested: 1))
    }
}
