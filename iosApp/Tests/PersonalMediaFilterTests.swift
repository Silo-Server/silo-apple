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

    #if os(iOS)
    @MainActor
    func testDockOpensOnAllThenOnTheTypeUsedLast() throws {
        let suite = "PersonalMediaFilterTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(ForYouDockModel(defaults: defaults).mediaFilter, .all)
        ForYouDockModel(defaults: defaults).mediaFilter = .tvShows
        XCTAssertEqual(ForYouDockModel(defaults: defaults).mediaFilter, .tvShows)
    }
    #endif

    func testAudiobooksKeepsOnlyAudiobooks() {
        XCTAssertTrue(PersonalMediaFilter.audiobooks.includes(type: "audiobook"))
        XCTAssertTrue(PersonalMediaSection.audiobooks.includes(type: " Audiobook "))
        for type in ["movie", "series", "episode", "ebook"] {
            XCTAssertFalse(PersonalMediaFilter.audiobooks.includes(type: type), type)
        }
    }

    /// Audiobooks are opt-in: with them off, the menus don't offer the type,
    /// and a list left on Audiobooks falls back instead of showing nothing.
    func testAudiobooksOnlyWhileAudiobooksAreOn() {
        XCTAssertEqual(PersonalMediaFilter.available(showAudiobooks: false), [.all, .movies, .tvShows])
        XCTAssertEqual(PersonalMediaSection.available(showAudiobooks: false), [.movies, .tvShows])
        XCTAssertEqual(PersonalMediaFilter.available(showAudiobooks: true).last, .audiobooks)
        XCTAssertEqual(PersonalMediaSection.available(showAudiobooks: true).last, .audiobooks)

        XCTAssertEqual(PersonalMediaFilter.audiobooks.resolved(showAudiobooks: false), .all)
        XCTAssertEqual(PersonalMediaFilter.audiobooks.resolved(showAudiobooks: true), .audiobooks)
        XCTAssertEqual(PersonalMediaSection.audiobooks.resolved(showAudiobooks: false), .movies)
        XCTAssertEqual(PersonalMediaFilter.tvShows.resolved(showAudiobooks: false), .tvShows)
    }

    func testTvShowsKeepsSeriesAndEpisodes() {
        XCTAssertTrue(PersonalMediaFilter.tvShows.includes(type: "series"))
        XCTAssertTrue(PersonalMediaFilter.tvShows.includes(type: " Episode "))
        XCTAssertTrue(PersonalMediaFilter.tvShows.includes(type: "episodes"))
        XCTAssertFalse(PersonalMediaFilter.tvShows.includes(type: "movie"))
    }
}
