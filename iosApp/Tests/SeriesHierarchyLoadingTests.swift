import XCTest
@testable import Silo

@MainActor
final class SeriesHierarchyLoadingTests: XCTestCase {
    private let seriesId = "series-hierarchy-regression"

    func testSeasonsDelayDoesNotLookLikeAnEmptyResult() async throws {
        let model = ItemDetailViewModel()
        let gate = ResponseGate<SeasonsResponse>()
        let started = expectation(description: "seasons requested")
        let task = Task {
            await model.loadSeasons(seriesId: seriesId, autoSelectInitial: false, fetchSeasons: { _ in
                started.fulfill()
                return await gate.wait()
            })
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.isLoadingSeriesHierarchy)
        XCTAssertNil(model.seriesLoadErrorMessage)
        await gate.finish(try seasons([]))
        await task.value
        XCTAssertFalse(model.isLoadingSeriesHierarchy)
        XCTAssertEqual(model.seasonsLoadState, .loaded)
        XCTAssertNil(model.seriesLoadErrorMessage)
        clearCache()
    }

    func testFailedSeasonsAreRetryableAndEmptyRetryIsTerminal() async throws {
        let model = ItemDetailViewModel()
        await model.loadSeasons(seriesId: seriesId, fetchSeasons: { _ in throw URLError(.timedOut) })
        XCTAssertFalse(model.isLoadingSeriesHierarchy)
        XCTAssertNotNil(model.seriesLoadErrorMessage)
        await model.loadSeasons(seriesId: seriesId, fetchSeasons: { _ in try self.seasons([]) })
        XCTAssertFalse(model.isLoadingSeriesHierarchy)
        XCTAssertNil(model.seriesLoadErrorMessage)
        clearCache()
    }

    func testCancelledSeasonResponseCannotPublishOrCache() async throws {
        let model = ItemDetailViewModel()
        let gate = ResponseGate<SeasonsResponse>()
        let started = expectation(description: "seasons requested")
        let task = Task {
            await model.loadSeasons(seriesId: seriesId, autoSelectInitial: false, fetchSeasons: { _ in
                started.fulfill()
                return await gate.wait()
            })
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await gate.finish(try seasons([1]))
        await task.value
        XCTAssertTrue(model.seasons.isEmpty)
        XCTAssertEqual(model.seasonsLoadState, .idle)
        let cached: SeasonsResponse? = ResponseCache.shared.get(CacheKey.itemSeasons(seriesId))
        XCTAssertNil(cached)
        // Returning to the page starts a fresh request, including after cancellation.
        await model.loadSeasons(seriesId: seriesId, autoSelectInitial: false, fetchSeasons: { _ in try self.seasons([2]) })
        XCTAssertEqual(model.seasons.map(\.seasonNumber), [2])
        clearCache()
    }

    func testOlderSeasonsCannotReplaceNewerHierarchy() async throws {
        let model = ItemDetailViewModel()
        let gate = ResponseGate<SeasonsResponse>()
        let started = expectation(description: "old request started")
        let task = Task {
            await model.loadSeasons(seriesId: seriesId, autoSelectInitial: false, fetchSeasons: { _ in
                started.fulfill()
                return await gate.wait()
            })
        }
        await fulfillment(of: [started], timeout: 2)
        await model.loadSeasons(seriesId: seriesId, autoSelectInitial: false, fetchSeasons: { _ in try self.seasons([2]) })
        await gate.finish(try seasons([1]))
        await task.value
        XCTAssertEqual(model.seasons.map(\.seasonNumber), [2])
        let cached: SeasonsResponse? = ResponseCache.shared.get(CacheKey.itemSeasons(seriesId))
        XCTAssertEqual(cached?.seasons.map(\.seasonNumber), [2])
        clearCache()
    }

    func testEpisodeDelayFailureAndRetryHaveDistinctStates() async throws {
        let model = ItemDetailViewModel()
        let season = try seasons([1]).seasons[0]
        model.seasons = [season]
        model.selectedSeason = season
        let gate = ResponseGate<EpisodesResponse>()
        let started = expectation(description: "episode request started")
        let task = Task {
            await model.loadEpisodes(seriesId: seriesId, seasonNumber: 1, refreshFavoriteStates: false, fetchEpisodes: { _, _ in
                started.fulfill()
                return await gate.wait()
            })
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.isLoadingSeriesHierarchy)
        await gate.finish(try episodes([]))
        await task.value
        XCTAssertFalse(model.isLoadingSeriesHierarchy)
        XCTAssertNil(model.seriesLoadErrorMessage)
        await model.loadEpisodes(seriesId: seriesId, seasonNumber: 1, refreshFavoriteStates: false, fetchEpisodes: { _, _ in
            throw URLError(.timedOut)
        })
        XCTAssertFalse(model.isLoadingEpisodes)
        XCTAssertNotNil(model.seriesLoadErrorMessage)
        await model.loadEpisodes(seriesId: seriesId, seasonNumber: 1, refreshFavoriteStates: false, fetchEpisodes: { _, _ in try self.episodes([1]) })
        XCTAssertEqual(model.episodes.map(\.episodeNumber), [1])
        XCTAssertNil(model.seriesLoadErrorMessage)
        clearCache()
    }

    func testCachedPageRemainsVisibleWhileRefreshingAndAfterFailure() async throws {
        let model = ItemDetailViewModel()
        model.seasons = try seasons([1]).seasons
        model.selectedSeason = model.seasons[0]
        model.episodesBySeason[1] = try episodes([1]).episodes
        await model.loadEpisodes(seriesId: seriesId, seasonNumber: 1, refreshFavoriteStates: false, fetchEpisodes: { _, _ in
            await MainActor.run {
                XCTAssertFalse(model.isLoadingSeriesHierarchy)
                XCTAssertEqual(model.episodes.map(\.episodeNumber), [1])
            }
            throw URLError(.timedOut)
        })
        XCTAssertEqual(model.episodes.map(\.episodeNumber), [1])
        XCTAssertNotNil(model.seriesLoadErrorMessage)
        clearCache()
    }

    func testCancelledEpisodeResponseCannotPublishOrCache() async throws {
        let model = ItemDetailViewModel()
        let gate = ResponseGate<EpisodesResponse>()
        let started = expectation(description: "episodes requested")
        let task = Task {
            await model.loadEpisodes(seriesId: seriesId, seasonNumber: 1, refreshFavoriteStates: false, fetchEpisodes: { _, _ in
                started.fulfill()
                return await gate.wait()
            })
        }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await gate.finish(try episodes([1]))
        await task.value
        XCTAssertTrue(model.episodes.isEmpty)
        XCTAssertFalse(model.isLoadingEpisodes)
        XCTAssertFalse(model.episodesLoadFailed)
        let cached: EpisodesResponse? = ResponseCache.shared.get(CacheKey.itemEpisodes(seriesId: seriesId, seasonNumber: 1))
        XCTAssertNil(cached)
    }

    func testCachedOrdinaryEntryHydratesItsEpisodePageImmediately() throws {
        let detail = try JSONDecoder().decode(ItemDetail.self, from: Data(
            "{\"contentId\":\"\(seriesId)\",\"type\":\"series\",\"title\":\"Synthetic series\"}".utf8
        ))
        ResponseCache.shared.set(detail, for: CacheKey.itemDetail(seriesId))
        ResponseCache.shared.set(try seasons([1]), for: CacheKey.itemSeasons(seriesId))
        ResponseCache.shared.set(try episodes([1]), for: CacheKey.itemEpisodes(seriesId: seriesId, seasonNumber: 1))
        defer {
            clearCache()
            ResponseCache.shared.remove(CacheKey.itemDetail(seriesId))
        }
        let model = ItemDetailViewModel()
        model.hydrateFromCache(contentId: seriesId)
        XCTAssertEqual(model.selectedSeason?.seasonNumber, 1)
        XCTAssertEqual(model.episodes.map(\.episodeNumber), [1])
        XCTAssertFalse(model.isLoadingSeriesHierarchy)
    }

    func testNavigationAwayInvalidatesAnUnstructuredRetry() async throws {
        let model = ItemDetailViewModel()
        let gate = ResponseGate<EpisodesResponse>()
        let started = expectation(description: "retry started")
        let task = Task {
            await model.loadEpisodes(seriesId: seriesId, seasonNumber: 1, refreshFavoriteStates: false, fetchEpisodes: { _, _ in
                started.fulfill()
                return await gate.wait()
            })
        }
        await fulfillment(of: [started], timeout: 2)
        model.cancelDetailLoading()
        // The task itself is deliberately not cancelled: route invalidation
        // must also cover a button's unstructured Task.
        await gate.finish(try episodes([1]))
        await task.value
        XCTAssertTrue(model.episodes.isEmpty)
        XCTAssertFalse(model.isLoadingEpisodes)
        let cached: EpisodesResponse? = ResponseCache.shared.get(CacheKey.itemEpisodes(seriesId: seriesId, seasonNumber: 1))
        XCTAssertNil(cached)
    }

    func testOlderEpisodeResponseCannotReplaceNewerPageOrCache() async throws {
        let model = ItemDetailViewModel()
        let gate = ResponseGate<EpisodesResponse>()
        let started = expectation(description: "old page started")
        let task = Task {
            await model.loadEpisodes(seriesId: seriesId, seasonNumber: 1, refreshFavoriteStates: false, fetchEpisodes: { _, _ in
                started.fulfill()
                return await gate.wait()
            })
        }
        await fulfillment(of: [started], timeout: 2)
        await model.loadEpisodes(seriesId: seriesId, seasonNumber: 1, refreshFavoriteStates: false, fetchEpisodes: { _, _ in try self.episodes([2]) })
        await gate.finish(try episodes([1]))
        await task.value
        XCTAssertEqual(model.episodes.map(\.episodeNumber), [2])
        let cached: EpisodesResponse? = ResponseCache.shared.get(CacheKey.itemEpisodes(seriesId: seriesId, seasonNumber: 1))
        XCTAssertEqual(cached?.episodes.map(\.episodeNumber), [2])
        clearCache()
    }

    func testEmptyHierarchyReplacesPreviouslyLoadedEpisodes() async throws {
        let model = ItemDetailViewModel()
        model.seasons = try seasons([1]).seasons
        model.selectedSeason = model.seasons.first
        model.episodes = try episodes([1]).episodes
        model.episodesBySeason[1] = model.episodes
        await model.loadSeasons(seriesId: seriesId, fetchSeasons: { _ in try self.seasons([]) })
        XCTAssertNil(model.selectedSeason)
        XCTAssertTrue(model.episodes.isEmpty)
        XCTAssertTrue(model.episodesBySeason.isEmpty)
        XCTAssertFalse(model.isLoadingSeriesHierarchy)
        clearCache()
    }

    func testSerializedHierarchyKeepsLoadingUntilTheSelectedPageFinishes() async throws {
        let model = ItemDetailViewModel()
        let gate = ResponseGate<EpisodesResponse>()
        let started = expectation(description: "selected page requested")
        let task = Task {
            await model.loadSeasons(seriesId: seriesId,
                fetchSeasons: { _ in try self.seasons([1]) },
                fetchEpisodes: { _, number in
                    XCTAssertEqual(number, 1)
                    started.fulfill()
                    return await gate.wait()
                })
        }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.seasonsLoadState, .loaded)
        XCTAssertEqual(model.selectedSeason?.seasonNumber, 1)
        XCTAssertTrue(model.isLoadingSeriesHierarchy)
        await gate.finish(try episodes([]))
        await task.value
        XCTAssertFalse(model.isLoadingSeriesHierarchy)
        XCTAssertNil(model.seriesLoadErrorMessage)
        clearCache()
    }

    func testRequestedSeasonSurvivesEpisodeFailureAndSucceedsOnRetry() async throws {
        let model = ItemDetailViewModel()
        model.initialResumeSeasonNumber = 1
        await model.loadSeasons(seriesId: seriesId,
            fetchSeasons: { _ in try self.seasons([1]) },
            fetchEpisodes: { _, _ in throw URLError(.timedOut) })
        XCTAssertEqual(model.initialResumeSeasonNumber, 1)
        XCTAssertTrue(model.episodesLoadFailed)
        await model.loadSeasons(seriesId: seriesId,
            fetchSeasons: { _ in
                await MainActor.run { XCTAssertNil(model.seriesLoadErrorMessage) }
                return try self.seasons([1])
            },
            fetchEpisodes: { _, _ in try self.episodes([]) })
        XCTAssertNil(model.initialResumeSeasonNumber)
        XCTAssertFalse(model.episodesLoadFailed)
        XCTAssertEqual(model.selectedSeason?.seasonNumber, 1)
        clearCache()
    }

    func testCancelledSelectionCannotChangeTheVisibleSeason() async throws {
        let model = ItemDetailViewModel()
        let target = try seasons([1]).seasons[0]
        let task = Task { await model.selectSeason(target) }
        task.cancel()
        await task.value
        XCTAssertNil(model.selectedSeason)
        XCTAssertFalse(model.isLoadingEpisodes)
    }

    private func clearCache() {
        ResponseCache.shared.remove(CacheKey.itemSeasons(seriesId))
        ResponseCache.shared.remove(CacheKey.itemEpisodes(seriesId: seriesId, seasonNumber: 1))
    }

    nonisolated private func seasons(_ numbers: [Int]) throws -> SeasonsResponse {
        let rows = numbers.map { "{\"contentId\":\"regression-season-\($0)\",\"seasonNumber\":\($0)}" }.joined(separator: ",")
        return try JSONDecoder().decode(SeasonsResponse.self, from: Data("{\"seasons\":[\(rows)]}".utf8))
    }

    nonisolated private func episodes(_ numbers: [Int]) throws -> EpisodesResponse {
        let rows = numbers.map { "{\"contentId\":\"regression-episode-\($0)\",\"seasonNumber\":1,\"episodeNumber\":\($0)}" }.joined(separator: ",")
        return try JSONDecoder().decode(EpisodesResponse.self, from: Data("{\"episodes\":[\(rows)]}".utf8))
    }
}

/// Intentionally ignores cancellation to model a coalesced response already in flight.
private actor ResponseGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    func wait() async -> Value {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish(_ value: Value) { continuation?.resume(returning: value) }
}
