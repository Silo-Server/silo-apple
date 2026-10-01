import XCTest
@testable import Silo

/// Favorites and Watchlist filter and sort the whole saved list on device.
final class PersonalListFilterTests: XCTestCase {
    private func item(
        _ id: String,
        title: String? = nil,
        year: Int? = nil,
        genres: [String]? = nil,
        imdb: Double? = nil,
        tmdb: Double? = nil,
        rtAudience: Int? = nil,
        releaseDate: String? = nil,
        played: Bool? = nil
    ) throws -> BrowseItem {
        var json: [String: Any] = ["contentId": id, "type": "movie", "title": title ?? id]
        if let year { json["year"] = year }
        if let genres { json["genres"] = genres }
        if let imdb { json["ratingImdb"] = imdb }
        if let tmdb { json["ratingTmdb"] = tmdb }
        if let rtAudience { json["ratingRtAudience"] = rtAudience }
        if let releaseDate { json["releaseDate"] = releaseDate }
        if let played {
            json["userState"] = ["played": played, "isFavorite": false, "inWatchlist": true]
        }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(BrowseItem.self, from: data)
    }

    func testDefaultFilterKeepsListOrder() throws {
        let items = try [item("c"), item("a"), item("b")]
        XCTAssertEqual(PersonalListFilter().apply(to: items).map(\.contentId), ["c", "a", "b"])
    }

    func testWatchFilterTreatsMissingUserStateAsUnwatched() throws {
        let items = try [item("seen", played: true), item("unseen", played: false), item("unknown")]
        var filter = PersonalListFilter()

        filter.watch = .unwatched
        XCTAssertEqual(filter.apply(to: items).map(\.contentId), ["unseen", "unknown"])

        filter.watch = .watched
        XCTAssertEqual(filter.apply(to: items).map(\.contentId), ["seen"])
    }

    func testGenresMatchAnySelectedGenre() throws {
        let items = try [
            item("drama", genres: ["Drama"]),
            item("comedy", genres: ["Comedy", "Romance"]),
            item("horror", genres: ["Horror"]),
            item("none"),
        ]
        var filter = PersonalListFilter()
        filter.toggleGenre("Drama")
        filter.toggleGenre("Romance")

        XCTAssertEqual(filter.apply(to: items).map(\.contentId), ["drama", "comedy"])
        XCTAssertEqual(filter.activeFilterCount, 1)
    }

    func testAvailableGenresAreDistinctAndSorted() throws {
        let items = try [item("a", genres: ["Drama", "action"]), item("b", genres: ["Drama", " Comedy "])]
        XCTAssertEqual(PersonalListFilter.availableGenres(in: items), ["action", "Comedy", "Drama"])
    }

    func testPruneDropsGenresMissingFromTheSection() {
        var filter = PersonalListFilter()
        filter.toggleGenre("Drama")
        filter.toggleGenre("Anime")
        filter.pruneGenres(to: ["Drama", "Comedy"])
        XCTAssertEqual(filter.genres, ["Drama"])
    }

    func testYearAndRatingSortDescendingWithMissingValuesLast() throws {
        let items = try [
            item("old", year: 1999, imdb: 8.0),
            item("noYear", tmdb: 9.1),
            item("new", year: 2024),
            item("mid", year: 2010, imdb: 6.5),
        ]
        var filter = PersonalListFilter()

        filter.sort = .releaseYear
        XCTAssertEqual(filter.apply(to: items).map(\.contentId), ["new", "mid", "old", "noYear"])

        filter.sort = .rating
        XCTAssertEqual(filter.apply(to: items).map(\.contentId), ["noYear", "old", "mid", "new"])
    }

    func testItemsMissingTheSortValueAreSortedByTitleAtTheEnd() throws {
        let items = try [
            item("z", title: "Zodiac"),
            item("rated", title: "Heat", imdb: 8.3),
            item("a", title: "Alien"),
            item("m", title: "Memento"),
        ]
        var filter = PersonalListFilter()

        filter.sort = .rating
        XCTAssertEqual(filter.apply(to: items).map(\.contentId), ["rated", "a", "m", "z"])

        filter.sort = .releaseYear
        XCTAssertEqual(filter.apply(to: items).map(\.contentId), ["a", "rated", "m", "z"])
    }

    func testYearFallsBackToReleaseDateAndRatingToRottenTomatoes() throws {
        let items = try [
            item("old", year: 1990),
            item("dated", releaseDate: "2021-05-01"),
            item("rt", rtAudience: 91),
            item("imdb", imdb: 7.0),
        ]
        var filter = PersonalListFilter()

        filter.sort = .releaseYear
        XCTAssertEqual(filter.apply(to: items).prefix(2).map(\.contentId), ["dated", "old"])

        filter.sort = .rating
        XCTAssertEqual(filter.apply(to: items).prefix(2).map(\.contentId), ["rt", "imdb"])
    }

    func testTitleSortIsNaturalAndStable() throws {
        let items = try [
            item("2", title: "Movie 10"),
            item("1", title: "Movie 2"),
            item("3a", title: "Alien"),
            item("3b", title: "Alien"),
        ]
        var filter = PersonalListFilter()
        filter.sort = .title
        XCTAssertEqual(filter.apply(to: items).map(\.contentId), ["3a", "3b", "1", "2"])
    }

    func testClearFiltersKeepsSort() {
        var filter = PersonalListFilter(watch: .watched, genres: ["Drama"], sort: .title)
        filter.clearFilters()
        XCTAssertEqual(filter, PersonalListFilter(sort: .title))
        XCTAssertFalse(filter.hasActiveFilters)
    }
}
