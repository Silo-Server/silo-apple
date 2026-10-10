import XCTest
@testable import Silo

final class WatchPartySpoilerTests: XCTestCase {
    private let enabled = EpisodeSpoilerSettings(hidesImages: true, hidesOverviews: true)

    func testCatalogRefreshRetainsEpisodeProtection() throws {
        let item = WatchPartySelectedItem(try catalog())
        XCTAssertTrue(item.hidesPoster(with: enabled))
        XCTAssertTrue(item.hidesBackdrop(with: enabled))
        XCTAssertNil(item.visibleOverview(with: enabled))
        XCTAssertEqual(item.visibleOverview(with: .off), "Episode description")
    }

    func testStartedCatalogEpisodesRemainVisible() throws {
        for state: [String: Any] in [
            ["played": true], ["played": false, "is_in_progress": true],
            ["played": false, "position_seconds": 30],
        ] {
            let item = WatchPartySelectedItem(try catalog(userData: state))
            XCTAssertFalse(item.hidesPoster(with: enabled))
            XCTAssertFalse(item.hidesBackdrop(with: enabled))
            XCTAssertEqual(item.visibleOverview(with: enabled), "Episode description")
        }
    }

    func testCatalogFallbackWatchState() throws {
        let watched = WatchPartySelectedItem(try catalog(extra: ["user_state": ["played": true, "is_favorite": false, "in_watchlist": false]]))
        XCTAssertFalse(watched.hidesBackdrop(with: enabled))
    }

    func testArtworkSlotsUseTheirOwnProvenance() throws {
        let item = WatchPartySelectedItem(try catalog(extra: ["poster_is_episode_still": false]))
        XCTAssertFalse(item.hidesPoster(with: enabled))
        XCTAssertTrue(item.hidesBackdrop(with: enabled))
        XCTAssertNil(item.visibleOverview(with: enabled))
    }

    func testPosterFallbackAndLegacyPreviewAreProtected() {
        let item = WatchPartySelectedItem(previewContentId: "episode:1", type: " Episodes ", title: "Pilot",
            posterUrl: "https://example.invalid/still.jpg", backdropUrl: nil, overview: "Episode description")
        XCTAssertTrue(item.hidesPoster(with: enabled))
        XCTAssertTrue(item.hidesBackdrop(with: enabled))
        XCTAssertNil(item.visibleOverview(with: enabled))
    }

    func testPreviewKeepsStartedStateAndSeriesArtwork() {
        let item = WatchPartySelectedItem(previewContentId: "episode:1", type: "episode", title: "Pilot",
            posterUrl: "https://example.invalid/series.jpg", backdropUrl: "https://example.invalid/still.jpg",
            overview: "Episode description", posterIsEpisodeStill: false, backdropIsEpisodeStill: true,
            episodeWatchState: EpisodeWatchState(played: false, positionSeconds: 10))
        XCTAssertFalse(item.hidesPoster(with: enabled))
        XCTAssertFalse(item.hidesBackdrop(with: enabled))
        XCTAssertEqual(item.visibleOverview(with: enabled), "Episode description")
    }

    func testEpisodeSuggestionPostersFollowTheImageSwitch() {
        func suggestion(_ type: String) -> WatchPartySuggestion {
            WatchPartySuggestion(id: type, roomId: "room", suggesterUserId: "1", suggesterProfileId: "p",
                                 contentId: type, contentType: type, title: "Pick", createdAt: Date())
        }
        XCTAssertTrue(suggestion("episode").hidesPoster(with: enabled))
        XCTAssertFalse(suggestion("episode").hidesPoster(with: .off))
        XCTAssertFalse(suggestion("movie").hidesPoster(with: enabled))
    }

    func testNonEpisodeCatalogItemStaysVisible() throws {
        let item = WatchPartySelectedItem(try catalog(extra: ["type": "movie"]))
        XCTAssertFalse(item.hidesPoster(with: enabled))
        XCTAssertFalse(item.hidesBackdrop(with: enabled))
        XCTAssertEqual(item.visibleOverview(with: enabled), "Episode description")
    }

    func testPositivePlaybackUnhidesTheRetainedLobbyItem() throws {
        var item = WatchPartySelectedItem(try catalog())
        item.recordPlaybackProgress(0)
        item.recordPlaybackProgress(.nan)
        XCTAssertNil(item.visibleOverview(with: enabled))
        item.recordPlaybackProgress(2)
        XCTAssertFalse(item.hidesPoster(with: enabled))
        XCTAssertFalse(item.hidesBackdrop(with: enabled))
        XCTAssertEqual(item.visibleOverview(with: enabled), "Episode description")
        item.recordPlaybackProgress(0)
        XCTAssertFalse(item.hidesBackdrop(with: enabled))
    }

    private func catalog(userData: [String: Any]? = nil, extra: [String: Any] = [:]) throws -> APIv2CatalogRead.CatalogItemDetail {
        var body: [String: Any] = [
            "content_id": "episode:1", "type": "episode", "title": "Pilot", "status": "",
            "genres": [], "keywords": [], "cast": [], "crew": [], "versions": [], "subtitles": [],
            "overview": "Episode description", "poster_url": "https://example.invalid/poster.jpg",
            "backdrop_url": "https://example.invalid/backdrop.jpg",
            "poster_is_episode_still": true, "backdrop_is_episode_still": true,
        ]
        if var userData {
            userData["watched_count"] = 0
            userData["unplayed_count"] = 1
            userData["in_progress_count"] = 0
            body["user_data"] = userData
        }
        body.merge(extra) { _, new in new }
        return try HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.CatalogItemDetail.self,
            from: JSONSerialization.data(withJSONObject: body))
    }
}
