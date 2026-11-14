import XCTest
@testable import Silo

/// Cards that stay on screen prewarm the detail page their tap opens, within
/// fixed bounds, and the page then opens from what they cached.
@MainActor
final class DetailPrewarmerTests: XCTestCase {
    private var ids: Set<String> = []
    private let owner = PrewarmOwnerBox(PrewarmFixtures.auth(profileId: "profile-a"))
    private let calls = PrewarmCallLog()
    private let gates = PrewarmGates()
    private var metered = false
    private var lowPower = false
    private var busy = false
    /// Times the prewarmer asked whether anything holds it back.
    private var heldBackChecks = 0
    private var clock = ContinuousClock.now

    override func tearDown() async throws {
        await gates.openAll()
        for id in ids { ResponseCache.shared.removeItemMetadata(contentId: id) }
        ResponseCache.shared.remove(CacheKey.itemDetailSeed)
        try await super.tearDown()
    }

    // MARK: - Target resolution

    func testTargetsResolveTheWayTheTapOpensThePage() throws {
        let movie = try PrewarmFixtures.section(#"{"contentId":"m1","type":"movie","title":"Heat"}"#)
        XCTAssertEqual(
            DetailPrewarmTarget.homeCard(movie, opensResumeContext: true, libraryId: 7),
            DetailPrewarmTarget(contentId: "m1", libraryId: 7)
        )

        let episode = try PrewarmFixtures.section(
            #"{"contentId":"e1","type":"episode","title":"Pilot","seriesId":"s1","seasonNumber":2,"episodeNumber":1}"#
        )
        // Continue Watching opens the series on the episode's season.
        XCTAssertEqual(
            DetailPrewarmTarget.homeCard(episode, opensResumeContext: true, libraryId: 7),
            DetailPrewarmTarget(contentId: "s1", libraryId: 7, resumeSeasonNumber: 2)
        )
        // Elsewhere the card opens its own page, in the row's library.
        XCTAssertEqual(
            DetailPrewarmTarget.homeCard(episode, opensResumeContext: false, libraryId: nil),
            DetailPrewarmTarget(contentId: "e1", libraryId: nil)
        )
        XCTAssertEqual(
            DetailPrewarmTarget.rowCard(episode, libraryId: 3),
            DetailPrewarmTarget(contentId: "e1", libraryId: 3)
        )
    }

    // MARK: - Bounds

    func testAtMostTwoRunAndTheNewestOfferStartsNext() async throws {
        let prewarmer = makePrewarmer()
        let targets = (1...5).map { target("bounds-\($0)") }
        await gates.close(targets.map(\.contentId))

        offer(targets[0], to: prewarmer)
        offer(targets[1], to: prewarmer)
        try await waitUntil { prewarmer.runningTargets.count == 2 }
        for target in targets[2...] {
            offer(target, to: prewarmer)
            try await waitUntil { prewarmer.pending.last == target }
        }
        XCTAssertEqual(prewarmer.runningTargets, [targets[0], targets[1]])

        await gates.open(targets[0].contentId)
        try await waitUntil { prewarmer.runningTargets.contains(targets[4]) }
        XCTAssertEqual(prewarmer.runningTargets.count, 2)
        XCTAssertEqual(prewarmer.pending, [targets[2], targets[3]])
    }

    func testPendingQueueDropsItsOldestOffers() async throws {
        let prewarmer = makePrewarmer(limits: .init(settle: .milliseconds(20), maxPending: 3))
        let running = [target("queue-a"), target("queue-b")]
        let queued = (1...5).map { target("queue-\($0)") }
        await gates.close((running + queued).map(\.contentId))
        for target in running { offer(target, to: prewarmer) }
        try await waitUntil { prewarmer.runningTargets.count == 2 }

        for target in queued {
            offer(target, to: prewarmer)
            try await waitUntil { prewarmer.pending.last == target }
        }
        XCTAssertEqual(prewarmer.pending, Array(queued.suffix(3)))
    }

    func testACardScrolledAwayBeforeTheSettleIsNeverFetched() async throws {
        let prewarmer = makePrewarmer(limits: .init(settle: .milliseconds(80)))
        let passing = target("settle-gone")
        let resting = target("settle-kept")
        offer(passing, to: prewarmer)
        offer(resting, to: prewarmer)
        prewarmer.withdraw(passing)

        try await waitUntil { self.cachedDetail(resting) != nil }
        let fetched = await calls.details
        XCTAssertEqual(fetched, [resting.contentId])
    }

    // MARK: - Skip rules

    func testAnItemAlreadyCachedIsNotFetchedAgain() async throws {
        let prewarmer = makePrewarmer()
        let cached = target("skip-cached")
        ResponseCache.shared.set(try PrewarmFixtures.movie(cached.contentId), for: detailKey(cached))
        let fresh = target("skip-fresh")
        offer(cached, to: prewarmer)
        offer(fresh, to: prewarmer)

        try await waitUntil { self.cachedDetail(fresh) != nil }
        let fetched = await calls.details
        XCTAssertEqual(fetched, [fresh.contentId])

        // Offered again later, the prewarmed item is not even scheduled.
        prewarmer.withdraw(fresh)
        offer(fresh, to: prewarmer)
        XCTAssertFalse(isScheduled(fresh, in: prewarmer))
        let again = await calls.details
        XCTAssertEqual(again, [fresh.contentId])
    }

    func testNothingLoadsOnAMeteredConnectionOrBehindAnOpenPage() async throws {
        let prewarmer = makePrewarmer()
        metered = true
        offer(target("skip-metered"), to: prewarmer)
        // Settled, then held back.
        try await waitUntil { self.heldBackChecks == 1 }
        metered = false
        busy = true
        offer(target("skip-busy"), to: prewarmer)
        try await waitUntil { self.heldBackChecks == 2 }

        let fetched = await calls.details
        XCTAssertEqual(fetched, [])
        XCTAssertTrue(prewarmer.pending.isEmpty)
        XCTAssertTrue(prewarmer.runningTargets.isEmpty)

        // Closing the page offers the cards still on screen again.
        busy = false
        prewarmer.reofferVisible()
        try await waitUntil { self.cachedDetail(self.target("skip-busy")) != nil }
    }

    func testNothingLoadsInLowPowerModeOrSignedOut() async throws {
        let prewarmer = makePrewarmer()
        lowPower = true
        offer(target("skip-low-power"), to: prewarmer)
        try await waitUntil { self.heldBackChecks == 1 }
        XCTAssertTrue(prewarmer.pending.isEmpty)
        XCTAssertTrue(prewarmer.runningTargets.isEmpty)

        lowPower = false
        owner.set(nil)
        let signedOut = target("skip-signed-out")
        offer(signedOut, to: prewarmer)
        // It starts, finds nobody to request as, and stops.
        try await waitUntil { self.heldBackChecks == 2 }
        try await waitUntil { prewarmer.runningTargets.isEmpty }

        let fetched = await calls.details
        XCTAssertEqual(fetched, [])
        XCTAssertNil(cachedDetail(signedOut))
        XCTAssertTrue(prewarmer.trackedTargets.isEmpty)
    }

    // MARK: - Cool-down

    func testAFailedItemWaitsOutTheCoolDown() async throws {
        let prewarmer = makePrewarmer()
        let failing = target("cool-fail")
        offer(failing, to: prewarmer)
        try await waitUntil { prewarmer.attemptedTargets.contains(failing) }
        XCTAssertTrue(prewarmer.runningTargets.isEmpty)

        // Settling again inside the cool-down sends nothing.
        prewarmer.withdraw(failing)
        offer(failing, to: prewarmer)
        XCTAssertFalse(isScheduled(failing, in: prewarmer))
        clock += .seconds(4 * 60)
        prewarmer.reofferVisible()
        XCTAssertFalse(isScheduled(failing, in: prewarmer))
        var fetched = await calls.details
        XCTAssertEqual(fetched, [failing.contentId])

        // After it, the card is fetched again.
        clock += .seconds(61)
        prewarmer.reofferVisible()
        try await waitUntil { await self.calls.details.count == 2 }
        fetched = await calls.details
        XCTAssertEqual(fetched, [failing.contentId, failing.contentId])
    }

    func testAnEvictedItemWaitsOutTheCoolDownUnlessItIsInvalidated() async throws {
        let prewarmer = makePrewarmer(limits: .init(settle: .milliseconds(20), maxTracked: 1))
        let old = target("cool-evicted")
        let newer = target("cool-newer")
        offer(old, to: prewarmer)
        try await waitUntil { prewarmer.trackedTargets == [old] }
        offer(newer, to: prewarmer)
        try await waitUntil { prewarmer.trackedTargets == [newer] }
        XCTAssertNil(cachedDetail(old))
        XCTAssertEqual(prewarmer.attemptedTargets, [old])

        // Its card is still on screen and settles again: nothing goes out.
        prewarmer.reofferVisible()
        XCTAssertFalse(isScheduled(old, in: prewarmer))

        // The user acts on it (a watched toggle invalidates its metadata),
        // so it may be warmed again at once.
        ResponseCache.shared.removeItemMetadata(contentId: old.contentId)
        XCTAssertEqual(prewarmer.attemptedTargets, [])
        prewarmer.reofferVisible()
        try await waitUntil { self.cachedDetail(old) != nil }
        let fetched = await calls.details
        // The read after the invalidation never joins a request that may
        // have been sent before it.
        XCTAssertEqual(fetched, [old.contentId, newer.contentId, "fresh:\(old.contentId)"])
    }

    func testOnlyTheFirstPrewarmAfterAnInvalidationReadsFresh() async throws {
        let prewarmer = makePrewarmer(limits: .init(settle: .milliseconds(20), maxTracked: 1))
        let item = target("fresh-once")
        let other = target("fresh-once-other")
        ResponseCache.shared.removeItemMetadata(contentId: item.contentId)
        offer(item, to: prewarmer)
        try await waitUntil { prewarmer.trackedTargets == [item] }
        // Evicted by a newer item, then warmed again after its cool-down.
        offer(other, to: prewarmer)
        try await waitUntil { prewarmer.trackedTargets == [other] }
        clock = clock.advanced(by: .seconds(600))
        prewarmer.reofferVisible()
        try await waitUntil { self.cachedDetail(item) != nil }
        let fetched = await calls.details
        XCTAssertEqual(fetched, ["fresh:\(item.contentId)", other.contentId, item.contentId])
    }

    // MARK: - Eviction

    func testEvictionKeepsAFavoriteTheUserSetAfterThePrewarm() async throws {
        let prewarmer = makePrewarmer(limits: .init(settle: .milliseconds(20), maxTracked: 1))
        let item = target("evict-user-state")
        offer(item, to: prewarmer)
        try await waitUntil { prewarmer.trackedTargets == [item] }
        // The prewarm cached the fetched flags (favorite).
        let userStateKey = CacheKey.itemUserState(item.contentId)
        let prewarmed: UserItemState? = ResponseCache.shared.get(userStateKey)
        XCTAssertEqual(prewarmed?.isFavorite, true)

        // The user unfavorites it from its card, as `PersonalListActions`
        // writes it back.
        ResponseCache.shared.set(UserItemState(isFavorite: false, inWatchlist: true), for: userStateKey)
        let newer = target("evict-user-state-newer")
        offer(newer, to: prewarmer)
        try await waitUntil { prewarmer.trackedTargets == [newer] }

        XCTAssertNil(cachedDetail(item))
        let kept: UserItemState? = ResponseCache.shared.get(userStateKey)
        XCTAssertEqual(kept?.isFavorite, false)
        XCTAssertEqual(kept?.inWatchlist, true)
    }

    func testTheOldestNeverOpenedPrewarmsAreEvicted() async throws {
        let prewarmer = makePrewarmer(limits: .init(settle: .milliseconds(20), maxTracked: 2))
        let opened = target("evict-opened")
        let old = target("evict-old")
        let newer = [target("evict-new-1"), target("evict-new-2")]

        for item in [opened, old] {
            offer(item, to: prewarmer)
            try await waitUntil { prewarmer.trackedTargets.contains(item) }
        }
        prewarmer.noteOpened(contentId: opened.contentId)
        for item in newer {
            offer(item, to: prewarmer)
            try await waitUntil { prewarmer.trackedTargets.contains(item) }
        }

        XCTAssertEqual(prewarmer.trackedTargets, newer)
        XCTAssertNil(cachedDetail(old))
        let oldWatch: WatchDetail? = ResponseCache.shared.get(CacheKey.itemWatchDetail(old.contentId))
        XCTAssertNil(oldWatch)
        // A page that was opened keeps its entries.
        XCTAssertNotNil(cachedDetail(opened))
    }

    // MARK: - Identity and invalidation

    func testAResponseThatCrossesAProfileSwitchIsDropped() async throws {
        let prewarmer = makePrewarmer()
        let item = target("fence-profile")
        await gates.close([item.contentId])
        offer(item, to: prewarmer)
        try await waitUntil { await self.calls.details.contains(item.contentId) }

        owner.set(PrewarmFixtures.auth(profileId: "profile-b"))
        await gates.open(item.contentId)
        try await waitUntil { prewarmer.runningTargets.isEmpty }

        XCTAssertNil(cachedDetail(item))
        XCTAssertTrue(prewarmer.trackedTargets.isEmpty)
    }

    func testAResponseThatCrossesAnInvalidationIsDropped() async throws {
        let prewarmer = makePrewarmer()
        let item = target("fence-token")
        await gates.close([item.contentId])
        offer(item, to: prewarmer)
        try await waitUntil { await self.calls.details.contains(item.contentId) }

        // A watched toggle on the card invalidates the item meanwhile.
        ResponseCache.shared.removeItemMetadata(contentId: item.contentId)
        await gates.open(item.contentId)
        try await waitUntil { prewarmer.runningTargets.isEmpty }

        XCTAssertNil(cachedDetail(item))
    }

    func testAPageOpenedMidPrewarmOwnsTheItem() async throws {
        let prewarmer = makePrewarmer()
        let item = target("opened-mid")
        await gates.close([item.contentId])
        offer(item, to: prewarmer)
        try await waitUntil { await self.calls.details.contains(item.contentId) }

        prewarmer.noteOpened(contentId: item.contentId)
        await gates.open(item.contentId)
        try await waitUntil { prewarmer.runningTargets.isEmpty }

        // The page adopts the joined response itself; the prewarm writes
        // nothing over it.
        XCTAssertNil(cachedDetail(item))
        let watch = await calls.watchDetails
        XCTAssertEqual(watch, [])
    }

    func testDroppingTheItemFamilyResetsEverythingAndStopsRunningWork() async throws {
        let prewarmer = makePrewarmer(limits: .init(settle: .milliseconds(20), maxTracked: 1))
        let done = target("reset-done")
        let evicted = target("reset-evicted")
        offer(evicted, to: prewarmer)
        try await waitUntil { prewarmer.trackedTargets == [evicted] }
        offer(done, to: prewarmer)
        try await waitUntil { prewarmer.trackedTargets == [done] }
        prewarmer.noteOpened(contentId: "reset-opened")
        let inFlight = target("reset-in-flight")
        await gates.close([inFlight.contentId])
        offer(inFlight, to: prewarmer)
        try await waitUntil { await self.calls.details.contains(inFlight.contentId) }
        XCTAssertEqual(prewarmer.attemptedTargets, [evicted])
        XCTAssertEqual(prewarmer.openedCount, 1)

        // A profile switch drops the family.
        ResponseCache.shared.clearMemory(withPrefix: "item:")

        XCTAssertTrue(prewarmer.runningTargets.isEmpty)
        XCTAssertTrue(prewarmer.pending.isEmpty)
        XCTAssertTrue(prewarmer.trackedTargets.isEmpty)
        XCTAssertTrue(prewarmer.attemptedTargets.isEmpty)
        XCTAssertEqual(prewarmer.openedCount, 0)
        // The stopped prewarm writes nothing when its response arrives. It
        // counts its one request as it returns.
        let requestsBefore = prewarmer.stats.jsonRequests
        await gates.open(inFlight.contentId)
        try await waitUntil { prewarmer.stats.jsonRequests == requestsBefore + 1 }
        XCTAssertNil(cachedDetail(inFlight))
        XCTAssertTrue(prewarmer.trackedTargets.isEmpty)

        // Sign-out and account changes clear everything, which resets too.
        prewarmer.noteOpened(contentId: "reset-opened")
        ResponseCache.shared.clearMemory()
        XCTAssertEqual(prewarmer.openedCount, 0)
    }

    func testOpenedItemsAreBounded() {
        let prewarmer = makePrewarmer(limits: .init(maxOpened: 3))
        for index in 1...5 { prewarmer.noteOpened(contentId: "opened-\(index)") }
        XCTAssertEqual(prewarmer.openedCount, 3)
        // Opening one again does not count it twice.
        prewarmer.noteOpened(contentId: "opened-5")
        XCTAssertEqual(prewarmer.openedCount, 3)
    }

    // MARK: - The page after a prewarm

    func testASeriesOpenedAfterAPrewarmPaintsItsResumeSeasonWithNoSeed() async throws {
        let prewarmer = makePrewarmer()
        let series = DetailPrewarmTarget(contentId: "page-series", libraryId: 4, resumeSeasonNumber: 2)
        ids.insert(series.contentId)
        offer(series, to: prewarmer)
        try await waitUntil { prewarmer.trackedTargets.contains(series) }
        let episodesRequested = await calls.episodes
        XCTAssertEqual(episodesRequested, ["page-series/2"])

        // The card's seed is on offer too; the prewarmed detail wins.
        let card = try PrewarmFixtures.section(#"{"contentId":"page-series","type":"series","title":"Card title"}"#)
        DetailSeedStore.offer(.section(card), opening: series.contentId)
        let model = ItemDetailViewModel(libraryId: 4)
        model.initialResumeSeasonNumber = 2
        model.hydrateFromCache(contentId: series.contentId)

        XCTAssertEqual(model.detail?.title, "Fetched page-series")
        XCTAssertFalse(model.isDetailProvisional)
        XCTAssertNil(model.seedArtwork)
        XCTAssertEqual(model.seasons.map(\.seasonNumber), [1, 2])
        XCTAssertEqual(model.selectedSeason?.seasonNumber, 2)
        XCTAssertEqual(model.episodes.map(\.contentId), ["page-series-s2e1"])
    }

    func testAMovieOpenedAfterAPrewarmHasItsWatchDetail() async throws {
        let prewarmer = makePrewarmer()
        let movie = target("page-movie")
        offer(movie, to: prewarmer)
        try await waitUntil { prewarmer.trackedTargets.contains(movie) }

        let model = ItemDetailViewModel()
        model.hydrateFromCache(contentId: movie.contentId)

        XCTAssertFalse(model.isDetailProvisional)
        XCTAssertEqual(model.detail?.hasWatchDetailSubtitlePolicy, true)
        XCTAssertEqual(model.detail?.versions?.count, 0)
        XCTAssertTrue(model.isFavorite)
        let watch: WatchDetail? = ResponseCache.shared.get(CacheKey.itemWatchDetail(movie.contentId))
        XCTAssertNotNil(watch)
        let stats = prewarmer.stats
        XCTAssertEqual(stats.items, 1)
        XCTAssertEqual(stats.jsonRequests, 2)
    }

    // MARK: - Fixtures

    private func makePrewarmer(
        limits: DetailPrewarmer.Limits = .init(settle: .milliseconds(20))
    ) -> DetailPrewarmer {
        let calls = calls
        let gates = gates
        let owner = owner
        let environment = DetailPrewarmEnvironment(
            fetchDetail: { id, _ in
                await calls.detail(id)
                await gates.wait(id)
                if id.contains("fail") { throw URLError(.timedOut) }
                return id.contains("series")
                    ? try PrewarmFixtures.series(id)
                    : try PrewarmFixtures.movie(id)
            },
            fetchSeasons: { _, _ in try PrewarmFixtures.seasons([1, 2]) },
            fetchEpisodes: { id, season, _ in
                await calls.episode("\(id)/\(season)")
                return try PrewarmFixtures.episodes(seriesId: id, season: season)
            },
            fetchWatchDetail: { id, _ in
                await calls.watchDetail(id)
                return PrewarmFixtures.watchDetail(id)
            },
            captureOwner: { owner.value },
            warmArtwork: { _ in DetailPrewarmArtwork.Result() },
            releaseArtwork: { _ in },
            isMetered: { [unowned self] in
                self.heldBackChecks += 1
                return self.metered
            },
            isLowPower: { [unowned self] in self.lowPower },
            isDisabled: { false },
            now: { [unowned self] in self.clock },
            fresh: .init(
                fetchDetail: { id, _ in
                    await calls.detail("fresh:\(id)")
                    return try PrewarmFixtures.movie(id)
                },
                fetchSeasons: { _, _ in try PrewarmFixtures.seasons([1, 2]) },
                fetchEpisodes: { id, season, _ in try PrewarmFixtures.episodes(seriesId: id, season: season) },
                fetchWatchDetail: { id, _ in
                    await calls.watchDetail("fresh:\(id)")
                    return PrewarmFixtures.watchDetail(id)
                }
            )
        )
        return DetailPrewarmer(environment: environment, limits: limits)
    }

    private func target(_ id: String) -> DetailPrewarmTarget {
        ids.insert(id)
        return DetailPrewarmTarget(contentId: id, libraryId: nil)
    }

    private func offer(_ target: DetailPrewarmTarget, to prewarmer: DetailPrewarmer) {
        ids.insert(target.contentId)
        prewarmer.offer(target) { [unowned self] in self.busy }
    }

    /// Whether `target` is settling, queued or running.
    private func isScheduled(_ target: DetailPrewarmTarget, in prewarmer: DetailPrewarmer) -> Bool {
        prewarmer.settlingTargets.contains(target) || prewarmer.pending.contains(target)
            || prewarmer.runningTargets.contains(target)
    }

    private func detailKey(_ target: DetailPrewarmTarget) -> String {
        CacheKey.itemDetail(target.contentId, libraryId: target.libraryId)
    }

    private func cachedDetail(_ target: DetailPrewarmTarget) -> ItemDetail? {
        ResponseCache.shared.get(detailKey(target))
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                XCTFail("condition not met in time")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum PrewarmFixtures {
    static func auth(profileId: String) -> CapturedOrdinaryRequestAuth {
        CapturedOrdinaryRequestAuth(
            account: RefreshAccountIdentity(
                serverId: "server",
                serverURL: "https://silo.example",
                credentialGenerationID: generation
            ),
            credentialOwner: .persistentServer(serverId: "server"),
            accessToken: "access",
            profileId: profileId,
            profileToken: "proof"
        )
    }

    private static let generation = UUID()

    static func section(_ json: String) throws -> SectionItem {
        try JSONDecoder().decode(SectionItem.self, from: Data(json.utf8))
    }

    static func movie(_ id: String) throws -> ItemDetail {
        let json = #"{"contentId":"\#(id)","type":"movie","title":"Fetched \#(id)","#
            + #""userState":{"played":false,"isFavorite":true,"inWatchlist":false}}"#
        return try JSONDecoder().decode(ItemDetail.self, from: Data(json.utf8))
    }

    static func series(_ id: String) throws -> ItemDetail {
        try JSONDecoder().decode(ItemDetail.self, from: Data(
            #"{"contentId":"\#(id)","type":"series","title":"Fetched \#(id)"}"#.utf8
        ))
    }

    static func seasons(_ numbers: [Int]) throws -> SeasonsResponse {
        let rows = numbers.map { #"{"contentId":"prewarm-season-\#($0)","seasonNumber":\#($0)}"# }
        return SeasonsResponse(seasons: try JSONDecoder().decode(
            [Season].self, from: Data("[\(rows.joined(separator: ","))]".utf8)
        ))
    }

    static func episodes(seriesId: String, season: Int) throws -> EpisodesResponse {
        let episode = try JSONDecoder().decode(EpisodeListItem.self, from: Data(
            #"{"contentId":"\#(seriesId)-s\#(season)e1","seasonNumber":\#(season),"episodeNumber":1}"#.utf8
        ))
        return EpisodesResponse(episodes: [episode])
    }

    static func watchDetail(_ id: String) -> WatchDetail {
        WatchDetail(
            contentId: id, type: "movie", title: "Fetched", year: nil, overview: nil,
            versions: [], subtitles: nil, intro: nil, credits: nil, userData: nil,
            seriesId: nil, seriesTitle: nil, seasonNumber: nil, episodeNumber: nil,
            effectiveSubtitleLanguage: nil, effectiveSubtitleMode: nil,
            effectiveShowForcedSubtitles: nil, effectiveSubtitleTrackSignature: nil
        )
    }
}

private final class PrewarmOwnerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: CapturedOrdinaryRequestAuth?

    init(_ value: CapturedOrdinaryRequestAuth?) { current = value }

    var value: CapturedOrdinaryRequestAuth? { lock.withLock { current } }
    func set(_ value: CapturedOrdinaryRequestAuth?) { lock.withLock { current = value } }
}

private actor PrewarmCallLog {
    private(set) var details: [String] = []
    private(set) var episodes: [String] = []
    private(set) var watchDetails: [String] = []

    func detail(_ id: String) { details.append(id) }
    func episode(_ key: String) { episodes.append(key) }
    func watchDetail(_ id: String) { watchDetails.append(id) }
}

/// Holds a detail request open until the test releases it.
private actor PrewarmGates {
    private var closed: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func close(_ ids: [String]) { closed.formUnion(ids) }

    func wait(_ id: String) async {
        guard closed.contains(id) else { return }
        await withCheckedContinuation { waiters[id, default: []].append($0) }
    }

    func open(_ id: String) {
        closed.remove(id)
        for waiter in waiters.removeValue(forKey: id) ?? [] { waiter.resume() }
    }

    func openAll() {
        for id in Array(closed) { open(id) }
    }
}
