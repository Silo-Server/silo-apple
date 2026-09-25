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

    /// A Series page showing `season` of two regular seasons, two episodes each.
    private func seriesModel(showing season: Int) throws -> ItemDetailViewModel {
        let detail = try JSONDecoder().decode(ItemDetail.self, from: Data(
            "{\"contentId\":\"\(seriesId)\",\"type\":\"series\",\"title\":\"Synthetic series\"}".utf8
        ))
        ResponseCache.shared.set(detail, for: CacheKey.itemDetail(seriesId))
        let model = ItemDetailViewModel()
        model.hydrateFromCache(contentId: seriesId)
        model.seasons = try [1, 2].map { number in
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
