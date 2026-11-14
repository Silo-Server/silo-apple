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

    func testTvShowsKeepsSeriesAndEpisodes() {
        XCTAssertTrue(PersonalMediaFilter.tvShows.includes(type: "series"))
        XCTAssertTrue(PersonalMediaFilter.tvShows.includes(type: " Episode "))
        XCTAssertFalse(PersonalMediaFilter.tvShows.includes(type: "movie"))
    }
}
