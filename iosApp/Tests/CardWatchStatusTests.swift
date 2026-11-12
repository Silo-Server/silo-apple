import XCTest
@testable import Silo

/// The poster's watch-status corner, matched against the web client's
/// `remainingEpisodes` in `CardWatchStatus.tsx`.
@MainActor
final class CardWatchStatusTests: XCTestCase {
    func testEpisodesLeftShowsOnlyOnAStartedUnfinishedTitle() {
        XCTAssertEqual(MediaItemUserState(watchedCount: 4, unplayedCount: 6).episodesLeft, 6)
        // Untouched: its count would be on every new show.
        XCTAssertNil(MediaItemUserState(watchedCount: 0, unplayedCount: 10).episodesLeft)
        XCTAssertNil(MediaItemUserState(unplayedCount: 10).episodesLeft)
        // Finished, or watched: the check stands for it.
        XCTAssertNil(MediaItemUserState(watchedCount: 10, unplayedCount: 0).episodesLeft)
        XCTAssertNil(MediaItemUserState(played: true, watchedCount: 4, unplayedCount: 6).episodesLeft)
        // A movie carries no counts.
        XCTAssertNil(MediaItemUserState().episodesLeft)
    }

    func testCardUserStateDecodesTheCatalogCounts() throws {
        let json = #"{"played":false,"is_favorite":false,"in_watchlist":true,"not_interested":false,"watched_count":2,"unplayed_count":73}"#
        let state = try HTTPClient.makeJSONDecoder().decode(MediaItemUserState.self, from: Data(json.utf8))
        XCTAssertEqual(state.episodesLeft, 73)
        XCTAssertTrue(state.inWatchlist)

        let finished = #"{"played":true,"is_favorite":false,"in_watchlist":false,"not_interested":false}"#
        let decoded = try HTTPClient.makeJSONDecoder().decode(MediaItemUserState.self, from: Data(finished.utf8))
        XCTAssertNil(decoded.watchedCount)
        XCTAssertNil(decoded.episodesLeft)
    }

    func testAWatchedChangeFromTheCardHidesTheStaleCount() async {
        let base = MediaItemUserState(watchedCount: 4, unplayedCount: 6)
        let state = MediaCardPersonalState(writes: .init(
            watched: { _, _, _ in .applied },
            favorite: { _, _, _ in .applied },
            watchlist: { _, _, _ in .applied }
        ))
        XCTAssertEqual(state.episodesLeft(base), 6)

        state.toggleWatched(from: base, via: .catalog(contentId: "series-1"))
        // The change runs in a task of its own.
        for _ in 0..<1_000 where !state.isPlayed(base) { await Task.yield() }
        XCTAssertTrue(state.isPlayed(base))
        XCTAssertNil(state.episodesLeft(base), "the loaded counts predate the change")

        // The card's `userState` changed: the fresh counts show again.
        state.reset()
        XCTAssertEqual(state.episodesLeft(base), 6)
    }
}
