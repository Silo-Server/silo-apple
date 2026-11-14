import XCTest
@testable import Silo

final class PersonalMediaFilterTests: XCTestCase {
    func testAllKeepsEveryType() {
        for type in ["movie", "series", "episode", "audiobook", ""] {
            XCTAssertTrue(PersonalMediaFilter.all.includes(type: type), type)
        }
    }

    func testMoviesKeepsOnlyMovies() {
        XCTAssertTrue(PersonalMediaFilter.movies.includes(type: "Movie"))
        XCTAssertFalse(PersonalMediaFilter.movies.includes(type: "series"))
        XCTAssertFalse(PersonalMediaFilter.movies.includes(type: "episode"))
    }

    @MainActor
    func testDockOpensOnAllThenOnTheTypeUsedLast() throws {
        let suite = "PersonalMediaFilterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ForYouDockModel(defaults: defaults).mediaFilter, .all)
        ForYouDockModel(defaults: defaults).mediaFilter = .tvShows
        XCTAssertEqual(ForYouDockModel(defaults: defaults).mediaFilter, .tvShows)
    }

    func testTvShowsKeepsSeriesAndEpisodes() {
        XCTAssertTrue(PersonalMediaFilter.tvShows.includes(type: "series"))
        XCTAssertTrue(PersonalMediaFilter.tvShows.includes(type: " Episode "))
        XCTAssertFalse(PersonalMediaFilter.tvShows.includes(type: "movie"))
    }
}
