import XCTest
@testable import Silo

/// A detail page opened from a card draws the card until its own detail
/// loads, and a series starts its seasons alongside that request.
@MainActor
final class DetailSeedTests: XCTestCase {
    private let movieId = "detail-seed-movie"
    private let seriesId = "detail-seed-series"
    private let episodeId = "detail-seed-episode"

    override func tearDown() async throws {
        ResponseCache.shared.remove(CacheKey.itemDetailSeed)
        for id in [movieId, seriesId, episodeId] {
            ResponseCache.shared.removeItemMetadata(contentId: id)
        }
        try await super.tearDown()
    }

    // MARK: - Seed construction

    func testMovieCardSeedsItsOwnPage() throws {
        let card = try section(
            #"{"contentId":"detail-seed-movie","type":"movie","title":"Heat","year":1995,"runtime":170,"#
                + #""overview":"A heist.","genres":["Crime"],"backdropUrl":"https://example.test/b.jpg","#
                + #""backdropThumbhash":"bh","userState":{"played":true,"isFavorite":true,"inWatchlist":false}}"#
        )
        let seed = try XCTUnwrap(ItemDetail.seed(from: card, opening: movieId))
        XCTAssertEqual(seed.type, "movie")
        XCTAssertEqual(seed.title, "Heat")
        XCTAssertEqual(seed.year, 1995)
        XCTAssertEqual(seed.runtime, 170)
        XCTAssertEqual(seed.overview, "A heist.")
        XCTAssertEqual(seed.backdropUrl, "https://example.test/b.jpg")
        XCTAssertEqual(seed.userState?.isFavorite, true)
        // Nothing the card does not carry is invented.
        XCTAssertNil(seed.versions)
        XCTAssertNil(seed.userData)
        XCTAssertNil(seed.cast)
        XCTAssertNil(seed.crew)
        XCTAssertNil(seed.pendingTranslationLanguage)
    }

    func testSeriesCardSeedsASeriesPage() throws {
        let card = try section(#"{"contentId":"detail-seed-series","type":"series","title":"Severance","showStatus":"Continuing"}"#)
        let seed = try XCTUnwrap(ItemDetail.seed(from: card, opening: seriesId))
        XCTAssertEqual(seed.type, "series")
        XCTAssertEqual(seed.showStatus, "Continuing")
    }

    func testEpisodeCardSeedsItsSeriesFromParentFieldsOnly() throws {
        let card = try section(
            #"{"contentId":"detail-seed-episode","type":"episode","title":"Pilot","seriesId":"detail-seed-series","#
                + #""seriesTitle":"Severance","seasonNumber":1,"episodeNumber":1,"overview":"Episode overview","#
                + #""runtime":55,"ratingImdb":8.1,"backdropUrl":"https://example.test/still.jpg","#
                + #""seriesBackdropUrl":"https://example.test/series-b.jpg","seriesBackdropThumbhash":"sbh","#
                + #""userState":{"played":false,"isFavorite":true,"inWatchlist":true}}"#
        )
        let seed = try XCTUnwrap(ItemDetail.seed(from: card, opening: seriesId))
        XCTAssertEqual(seed.contentId, seriesId)
        XCTAssertEqual(seed.type, "series")
        XCTAssertEqual(seed.title, "Severance")
        XCTAssertEqual(seed.backdropUrl, "https://example.test/series-b.jpg")
        XCTAssertEqual(seed.backdropThumbhash, "sbh")
        // The episode's own description, still, runtime, ratings and flags
        // are not the series'.
        XCTAssertNil(seed.overview)
        XCTAssertNil(seed.runtime)
        XCTAssertNil(seed.ratingImdb)
        XCTAssertNil(seed.posterUrl)
        XCTAssertNil(seed.userState)
    }

    func testCardsThatCannotDescribeThePageSeedNothing() throws {
        // An episode opening its own page, a series link without a title, an
        // unsupported type, an empty title, and a card for another item.
        let episode = try section(#"{"contentId":"detail-seed-episode","type":"episode","title":"Pilot","seriesId":"detail-seed-series"}"#)
        XCTAssertNil(ItemDetail.seed(from: episode, opening: episodeId))
        XCTAssertNil(ItemDetail.seed(from: episode, opening: seriesId))
        let audiobook = try section(#"{"contentId":"detail-seed-movie","type":"audiobook","title":"Dune"}"#)
        XCTAssertNil(ItemDetail.seed(from: audiobook, opening: movieId))
        let untitled = try section(#"{"contentId":"detail-seed-movie","type":"movie","title":"  "}"#)
        XCTAssertNil(ItemDetail.seed(from: untitled, opening: movieId))
        let other = try section(#"{"contentId":"detail-seed-movie","type":"movie","title":"Heat"}"#)
        XCTAssertNil(ItemDetail.seed(from: other, opening: seriesId))
    }

    func testStoreOnlyServesTheOfferedItemAndALaterTapReplacesIt() throws {
        let movie = try section(#"{"contentId":"detail-seed-movie","type":"movie","title":"Heat"}"#)
        DetailSeedStore.offer(.section(movie), opening: movieId)
        XCTAssertEqual(DetailSeedStore.seed(for: movieId)?.title, "Heat")
        XCTAssertNil(DetailSeedStore.seed(for: seriesId))
        // A tap that cannot seed clears the slot instead of leaving it.
        DetailSeedStore.offer(nil, opening: seriesId)
        XCTAssertNil(DetailSeedStore.seed(for: movieId))
    }

    func testSeedIsDroppedWithItemMetadata() throws {
        let movie = try section(#"{"contentId":"detail-seed-movie","type":"movie","title":"Heat"}"#)
        DetailSeedStore.offer(.section(movie), opening: movieId)
        // Profile switch, sign-out and language changes all drop the family.
        ResponseCache.shared.clearMemory(withPrefix: "item:")
        XCTAssertNil(DetailSeedStore.seed(for: movieId))
    }

    // MARK: - Page behavior

    func testSeedPaintsProvisionallyAndIsNeverCachedAsTheDetail() throws {
        let card = try section(
            #"{"contentId":"detail-seed-series","type":"series","title":"Severance","#
                + #""userState":{"played":false,"isFavorite":true,"inWatchlist":true}}"#
        )
        DetailSeedStore.offer(.section(card), opening: seriesId)

        let model = ItemDetailViewModel()
        model.hydrateFromCache(contentId: seriesId)

        XCTAssertEqual(model.detail?.title, "Severance")
        XCTAssertTrue(model.isDetailProvisional)
        XCTAssertTrue(model.isFavorite)
        XCTAssertTrue(model.inWatchlist)
        let cached: ItemDetail? = ResponseCache.shared.get(CacheKey.itemDetail(seriesId))
        XCTAssertNil(cached)
    }

    func testFetchedDetailReplacesSeedAndClearsProvisional() async throws {
        try offerSeriesSeed()
        let model = ItemDetailViewModel()
        model.hydrateFromCache(contentId: seriesId)
        let fetched = try detail(#"{"contentId":"detail-seed-series","type":"series","title":"Severance (2022)"}"#)

        await model.loadDetail(
            contentId: seriesId,
            fetchDetail: { _ in fetched },
            fetchSeasons: { _ in try Self.seasons([1]) },
            fetchEpisodes: { _, _ in EpisodesResponse(episodes: []) }
        )

        XCTAssertEqual(model.detail?.title, "Severance (2022)")
        XCTAssertFalse(model.isDetailProvisional)
        XCTAssertNil(model.error)
        let cached: ItemDetail? = ResponseCache.shared.get(CacheKey.itemDetail(seriesId))
        XCTAssertEqual(cached?.title, "Severance (2022)")
        // The seed is spent once the fetched detail is on screen.
        XCTAssertNil(DetailSeedStore.seed(for: seriesId))
    }

    func testFailedFetchWhileSeededSurfacesTheError() async throws {
        try offerSeriesSeed()
        let model = ItemDetailViewModel()
        model.hydrateFromCache(contentId: seriesId)

        await model.loadDetail(
            contentId: seriesId,
            fetchDetail: { _ in throw URLError(.timedOut) },
            fetchSeasons: { _ in try Self.seasons([1]) },
            fetchEpisodes: { _, _ in EpisodesResponse(episodes: []) }
        )

        XCTAssertNotNil(model.error)
        XCTAssertTrue(model.isDetailProvisional)
        let cached: ItemDetail? = ResponseCache.shared.get(CacheKey.itemDetail(seriesId))
        XCTAssertNil(cached)
    }

    func testSeededSeriesStartsSeasonsBeforeTheDetailAnswers() async throws {
        try offerSeriesSeed()
        let model = ItemDetailViewModel()
        model.hydrateFromCache(contentId: seriesId)
        let fetched = try detail(#"{"contentId":"detail-seed-series","type":"series","title":"Severance"}"#)
        let detailGate = SeedResponseGate<ItemDetail>()
        let seasonsRequested = expectation(description: "seasons requested")

        let load = Task {
            await model.loadDetail(
                contentId: seriesId,
                fetchDetail: { _ in await detailGate.wait() },
                fetchSeasons: { _ in
                    seasonsRequested.fulfill()
                    return try Self.seasons([1, 2])
                },
                fetchEpisodes: { _, _ in EpisodesResponse(episodes: []) }
            )
        }

        // The detail request is still open here.
        await fulfillment(of: [seasonsRequested], timeout: 2)
        XCTAssertTrue(model.isDetailProvisional)
        await detailGate.finish(fetched)
        await load.value

        XCTAssertEqual(model.seasons.map(\.seasonNumber), [1, 2])
        XCTAssertEqual(model.seasonsLoadState, .loaded)
        XCTAssertFalse(model.isDetailProvisional)
    }

    func testSeedThatWronglySaysSeriesLeavesNoSeriesState() async throws {
        try offerSeriesSeed()
        let model = ItemDetailViewModel()
        model.hydrateFromCache(contentId: seriesId)
        let fetched = try detail(#"{"contentId":"detail-seed-series","type":"episode","title":"Pilot"}"#)
        let detailGate = SeedResponseGate<ItemDetail>()
        let episodeId = episodeId

        let load = Task {
            await model.loadDetail(
                contentId: seriesId,
                fetchDetail: { _ in await detailGate.wait() },
                fetchSeasons: { _ in try Self.seasons([1]) },
                fetchEpisodes: { _, season in try Self.episodes(id: episodeId, season: season) }
            )
        }

        // The seed's seasons and episodes are on the page while the detail
        // request is still open.
        try await waitUntil { !model.episodes.isEmpty }
        XCTAssertEqual(model.seasons.map(\.seasonNumber), [1])
        XCTAssertNotNil(model.selectedSeason)
        XCTAssertTrue(model.isDetailProvisional)

        // Then the server says it is not a series.
        await detailGate.finish(fetched)
        await load.value

        XCTAssertEqual(model.detail?.type, "episode")
        XCTAssertFalse(model.isDetailProvisional)
        XCTAssertTrue(model.seasons.isEmpty)
        XCTAssertNil(model.selectedSeason)
        XCTAssertTrue(model.episodes.isEmpty)
        XCTAssertEqual(model.seasonsLoadState, .idle)
    }

    // MARK: - Store scope and flags

    func testStoreRefusesASeedOfferedUnderAnotherProfileOrServer() throws {
        let original = DetailSeedStore.currentScope
        defer { DetailSeedStore.currentScope = original }
        DetailSeedStore.currentScope = { .init(serverId: "server-a", profileId: "profile-a") }
        let movie = try section(#"{"contentId":"detail-seed-movie","type":"movie","title":"Heat"}"#)
        DetailSeedStore.offer(.section(movie), opening: movieId)
        XCTAssertEqual(DetailSeedStore.seed(for: movieId)?.title, "Heat")

        // Nothing cleared the cache, but requests now go out as someone else.
        DetailSeedStore.currentScope = { .init(serverId: "server-a", profileId: "profile-b") }
        XCTAssertNil(DetailSeedStore.seed(for: movieId))
        DetailSeedStore.currentScope = { .init(serverId: "server-b", profileId: "profile-a") }
        XCTAssertNil(DetailSeedStore.seed(for: movieId))
        let model = ItemDetailViewModel()
        model.hydrateFromCache(contentId: movieId)
        XCTAssertNil(model.detail)

        // Back under the profile that offered it.
        DetailSeedStore.currentScope = { .init(serverId: "server-a", profileId: "profile-a") }
        XCTAssertEqual(DetailSeedStore.seed(for: movieId)?.title, "Heat")
    }

    func testCachedUserStateWinsOverTheSeedsFlags() throws {
        // The card says favorite and on the watchlist; a later toggle cached
        // the opposite.
        let card = try section(
            #"{"contentId":"detail-seed-movie","type":"movie","title":"Heat","#
                + #""userState":{"played":false,"isFavorite":true,"inWatchlist":true}}"#
        )
        DetailSeedStore.offer(.section(card), opening: movieId)
        ResponseCache.shared.set(
            UserItemState(isFavorite: false, inWatchlist: false), for: CacheKey.itemUserState(movieId)
        )

        let model = ItemDetailViewModel()
        model.hydrateFromCache(contentId: movieId)

        XCTAssertTrue(model.isDetailProvisional)
        XCTAssertFalse(model.isFavorite)
        XCTAssertFalse(model.inWatchlist)
    }

    // MARK: - Remote button

    func testRemoteButtonTreatsASeedAsNothingToCast() throws {
        let movie = try detail(#"{"contentId":"detail-seed-movie","type":"movie","title":"Heat"}"#)
        let series = try detail(#"{"contentId":"detail-seed-series","type":"series","title":"Severance"}"#)

        // A fetched movie casts itself.
        XCTAssertEqual(
            DetailRemoteControlAction.forTap(detail: movie, isProvisional: false, remotePlaybackEngaged: false),
            .playOnTV
        )
        // A seed of the same movie acts as a page with no detail yet.
        XCTAssertEqual(
            DetailRemoteControlAction.forTap(detail: movie, isProvisional: true, remotePlaybackEngaged: false),
            .pickTV
        )
        XCTAssertEqual(
            DetailRemoteControlAction.forTap(detail: movie, isProvisional: true, remotePlaybackEngaged: true),
            .showRemote
        )
        XCTAssertEqual(
            DetailRemoteControlAction.forTap(detail: nil, isProvisional: false, remotePlaybackEngaged: false),
            .pickTV
        )
        // Containers never cast.
        XCTAssertEqual(
            DetailRemoteControlAction.forTap(detail: series, isProvisional: false, remotePlaybackEngaged: true),
            .showRemote
        )
    }

    // MARK: - Fixtures

    private func offerSeriesSeed() throws {
        let card = try section(#"{"contentId":"detail-seed-series","type":"series","title":"Severance"}"#)
        DetailSeedStore.offer(.section(card), opening: seriesId)
    }

    private func section(_ json: String) throws -> SectionItem {
        try JSONDecoder().decode(SectionItem.self, from: Data(json.utf8))
    }

    private func detail(_ json: String) throws -> ItemDetail {
        try JSONDecoder().decode(ItemDetail.self, from: Data(json.utf8))
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition not met in time")
                return
            }
            await Task.yield()
        }
    }

    nonisolated private static func episodes(id: String, season: Int) throws -> EpisodesResponse {
        let episode = try JSONDecoder().decode(EpisodeListItem.self, from: Data(
            #"{"contentId":"\#(id)","seasonNumber":\#(season),"episodeNumber":1}"#.utf8
        ))
        return EpisodesResponse(episodes: [episode])
    }

    nonisolated private static func seasons(_ numbers: [Int]) throws -> SeasonsResponse {
        let rows = numbers.map { #"{"contentId":"detail-seed-season-\#($0)","seasonNumber":\#($0)}"# }
        return SeasonsResponse(seasons: try JSONDecoder().decode(
            [Season].self, from: Data("[\(rows.joined(separator: ","))]".utf8)
        ))
    }
}

private actor SeedResponseGate<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var pending: Value?

    func wait() async -> Value {
        if let pending { return pending }
        return await withCheckedContinuation { continuation = $0 }
    }

    func finish(_ value: Value) {
        if let continuation {
            continuation.resume(returning: value)
            self.continuation = nil
        } else {
            pending = value
        }
    }
}
