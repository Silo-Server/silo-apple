import XCTest
@testable import Silo

@MainActor
final class SeriesPlaybackReturnTests: XCTestCase {
    private let seriesId = "series-playback-return"

    func testPartialWatchReturnsToTheSameEpisode() throws {
        let episodes = try (1...3).map { try episode(1, $0) }
        XCTAssertEqual(playback("s1e2", completed: false).episodeToSelect(in: episodes), "s1e2")
    }

    func testFinishedEpisodeAdvancesToTheNextOne() throws {
        let episodes = try (1...3).map { try episode(1, $0) }
        XCTAssertEqual(playback("s1e2", completed: true).episodeToSelect(in: episodes), "s1e3")
    }

    func testFinishedLastLoadedEpisodeNeedsAnotherPage() throws {
        let episodes = try (1...3).map { try episode(1, $0) }
        XCTAssertNil(playback("s1e3", completed: true).episodeToSelect(in: episodes))
    }

    func testEpisodeOutsideTheListKeepsTheSelection() throws {
        let episodes = try (1...3).map { try episode(1, $0) }
        XCTAssertNil(playback("s2e1", season: 2, completed: false).episodeToSelect(in: episodes))
    }

    func testFinishedRegularEpisodeDoesNotContinueIntoSpecials() throws {
        // Specials sort after the last regular season in the Apple TV window.
        let episodes = try [episode(2, 1), episode(2, 2), episode(0, 1)]
        XCTAssertNil(playback("s2e2", season: 2, completed: true).episodeToSelect(in: episodes))
    }

    func testFinishedFinaleOfTheLastSeasonStaysOnTheFinale() async throws {
        let model = try seriesModel(showing: 2, seasons: [0, 1, 2])
        model.episodesBySeason[0] = try page(0, count: 1).episodes
        defer { clearCache() }

        let selected = await model.prepareSeriesPlaybackReturn(
            playback("s2e2", season: 2, completed: true),
            fetchEpisodes: { _, season in try self.page(season, count: 2) }
        )

        XCTAssertEqual(selected, "s2e2")
        XCTAssertEqual(model.selectedSeason?.seasonNumber, 2)
    }

    func testCompetingEpisodeLoadCannotDiscardTheNextSeason() async throws {
        let model = try seriesModel(showing: 1)
        defer { clearCache() }
        let seriesId = self.seriesId

        let selected = await model.prepareSeriesPlaybackReturn(
            playback("s1e2", completed: true),
            fetchEpisodes: { _, season in
                // A post-playback refresh starts its own episode load mid-fetch.
                await model.loadEpisodes(
                    seriesId: seriesId, seasonNumber: 1, refreshFavoriteStates: false,
                    fetchEpisodes: { _, number in try self.page(number, count: 2) }
                )
                return try self.page(season, count: 2)
            }
        )

        XCTAssertEqual(selected, "s2e1")
        XCTAssertEqual(model.selectedSeason?.seasonNumber, 2)
    }

    func testSeasonChosenDuringTheFetchWins() async throws {
        let model = try seriesModel(showing: 1, seasons: [1, 2, 3])
        defer { clearCache() }
        let chosen = try XCTUnwrap(model.seasons.first { $0.seasonNumber == 3 })
        model.episodesBySeason[3] = try page(3, count: 2).episodes

        let selected = await model.prepareSeriesPlaybackReturn(
            playback("s1e2", completed: true),
            fetchEpisodes: { _, season in
                // The user picks Season 3 while the return loads Season 2.
                await model.selectSeason(chosen)
                return try self.page(season, count: 2)
            }
        )

        XCTAssertNil(selected)
        XCTAssertEqual(model.selectedSeason?.seasonNumber, 3)
    }

    func testFinishedSeasonFinaleContinuesWithTheNextSeason() async throws {
        let model = try seriesModel(showing: 1)
        defer { clearCache() }

        let selected = await model.prepareSeriesPlaybackReturn(
            playback("s1e2", completed: true),
            fetchEpisodes: { _, season in try self.page(season, count: 2) }
        )

        XCTAssertEqual(selected, "s2e1")
        XCTAssertEqual(model.selectedSeason?.seasonNumber, 2)
    }

    func testAutoplayIntoAnotherSeasonSelectsThatSeason() async throws {
        let model = try seriesModel(showing: 1)
        defer { clearCache() }

        let selected = await model.prepareSeriesPlaybackReturn(
            playback("s2e2", season: 2, completed: false),
            fetchEpisodes: { _, season in try self.page(season, count: 2) }
        )

        XCTAssertEqual(selected, "s2e2")
        XCTAssertEqual(model.selectedSeason?.seasonNumber, 2)
    }

    func testPlaybackFromAnotherSeriesIsIgnored() async throws {
        let model = try seriesModel(showing: 1)
        defer { clearCache() }
        let other = SeriesPlaybackReturn(
            episodeContentId: "s1e1", seriesContentId: "another-series", seasonNumber: 1, completed: false
        )

        let selected = await model.prepareSeriesPlaybackReturn(other)

        XCTAssertNil(selected)
        XCTAssertEqual(model.selectedSeason?.seasonNumber, 1)
    }

    func testInboxHandsTheReturnOnlyToItsSeriesOnce() {
        SeriesPlaybackReturnInbox.publish(playback("s1e1", completed: false))
        XCTAssertNil(SeriesPlaybackReturnInbox.take(seriesContentId: "another-series"))
        XCTAssertEqual(SeriesPlaybackReturnInbox.take(seriesContentId: seriesId)?.episodeContentId, "s1e1")
        XCTAssertNil(SeriesPlaybackReturnInbox.take(seriesContentId: seriesId))
    }

    // MARK: - Fixtures

    /// A Series page showing `season`. Regular seasons have two episodes each.
    private func seriesModel(showing season: Int, seasons: [Int] = [1, 2]) throws -> ItemDetailViewModel {
        let detail = try JSONDecoder().decode(ItemDetail.self, from: Data(
            "{\"contentId\":\"\(seriesId)\",\"type\":\"series\",\"title\":\"Synthetic series\"}".utf8
        ))
        ResponseCache.shared.set(detail, for: CacheKey.itemDetail(seriesId))
        let model = ItemDetailViewModel()
        model.hydrateFromCache(contentId: seriesId)
        model.seasons = try seasons.map { number in
            try JSONDecoder().decode(Season.self, from: Data(
                "{\"contentId\":\"season-\(number)\",\"seasonNumber\":\(number),\"episodeCount\":2}".utf8
            ))
        }
        let shown = try page(season, count: 2).episodes
        model.episodesBySeason[season] = shown
        model.episodes = shown
        model.selectedSeason = model.seasons.first { $0.seasonNumber == season }
        return model
    }

    private func playback(_ contentId: String, season: Int = 1, completed: Bool) -> SeriesPlaybackReturn {
        SeriesPlaybackReturn(
            episodeContentId: contentId, seriesContentId: seriesId, seasonNumber: season, completed: completed
        )
    }

    nonisolated private func page(_ season: Int, count: Int) throws -> EpisodesResponse {
        EpisodesResponse(episodes: try (1...count).map { try episode(season, $0) })
    }

    nonisolated private func episode(_ season: Int, _ number: Int) throws -> EpisodeListItem {
        try JSONDecoder().decode(EpisodeListItem.self, from: Data(
            "{\"contentId\":\"s\(season)e\(number)\",\"seasonNumber\":\(season),\"episodeNumber\":\(number)}".utf8
        ))
    }

    private func clearCache() {
        ResponseCache.shared.removeAll(withPrefix: CacheKey.itemDetail(seriesId))
    }
}
