import XCTest
@testable import Silo

// MARK: - Unwatched rule

final class EpisodeWatchStateTests: XCTestCase {
    func testMissingUserDataIsUnwatched() {
        XCTAssertTrue(EpisodeWatchState(nil).isUnwatched)
    }

    func testUntouchedStateIsUnwatched() throws {
        XCTAssertTrue(EpisodeWatchState(try userData(#"{"played":false}"#)).isUnwatched)
        XCTAssertTrue(EpisodeWatchState(try userData(#"{"played":false,"isInProgress":false,"positionSeconds":0}"#)).isUnwatched)
    }

    func testPlayedEpisodeIsWatched() throws {
        XCTAssertFalse(EpisodeWatchState(try userData(#"{"played":true}"#)).isUnwatched)
    }

    func testInProgressEpisodeIsWatched() throws {
        XCTAssertFalse(EpisodeWatchState(try userData(#"{"played":false,"isInProgress":true}"#)).isUnwatched)
    }

    func testASavedPositionCountsAsStarted() throws {
        XCTAssertFalse(EpisodeWatchState(try userData(#"{"played":false,"positionSeconds":12}"#)).isUnwatched)
    }

    func testPlayedOverrideWinsOverServerState() throws {
        XCTAssertFalse(EpisodeWatchState(nil, playedOverride: true).isUnwatched)
        XCTAssertTrue(EpisodeWatchState(try userData(#"{"played":true}"#), playedOverride: false).isUnwatched)
    }

    func testSectionItemsReadPlayedStateAndResumePosition() throws {
        XCTAssertTrue(EpisodeWatchState(sectionItem: try episodeItem()).isUnwatched)
        XCTAssertFalse(EpisodeWatchState(sectionItem: try episodeItem(played: true)).isUnwatched)
        XCTAssertFalse(EpisodeWatchState(sectionItem: try episodeItem(positionSeconds: 30)).isUnwatched)
        XCTAssertFalse(EpisodeWatchState(sectionItem: try episodeItem(), playedOverride: true).isUnwatched)
        XCTAssertTrue(EpisodeWatchState(sectionItem: try episodeItem(played: true), playedOverride: false).isUnwatched)
    }
}

// MARK: - Settings helpers

extension EpisodeWatchStateTests {
    func testBrowseRowsWithAResumePositionAreStarted() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let untouched = try decoder.decode(BrowseItem.self, from: Data(#"{"content_id":"e1","type":"episode","title":"Pilot"}"#.utf8))
        let started = try decoder.decode(BrowseItem.self, from: Data(#"{"content_id":"e1","type":"episode","title":"Pilot","position_seconds":12}"#.utf8))
        XCTAssertTrue(EpisodeWatchState(browseItem: untouched).isUnwatched)
        XCTAssertFalse(EpisodeWatchState(browseItem: started).isUnwatched)
    }
}

final class EpisodeSpoilerSettingsTests: XCTestCase {
    private let unwatched = EpisodeWatchState(played: false)
    private let started = EpisodeWatchState(played: false, isInProgress: true, positionSeconds: 60)

    func testOffHidesNothing() {
        XCTAssertFalse(EpisodeSpoilerSettings.off.hidesImage(for: unwatched))
        XCTAssertFalse(EpisodeSpoilerSettings.off.hidesOverview(for: unwatched))
    }

    func testEachSwitchHidesOnlyItsOwnField() {
        let images = EpisodeSpoilerSettings(hidesImages: true, hidesOverviews: false)
        XCTAssertTrue(images.hidesImage(for: unwatched))
        XCTAssertFalse(images.hidesOverview(for: unwatched))

        let overviews = EpisodeSpoilerSettings(hidesImages: false, hidesOverviews: true)
        XCTAssertFalse(overviews.hidesImage(for: unwatched))
        XCTAssertTrue(overviews.hidesOverview(for: unwatched))
    }

    func testStartedEpisodesAreNeverHidden() {
        let all = EpisodeSpoilerSettings(hidesImages: true, hidesOverviews: true)
        XCTAssertFalse(all.hidesImage(for: started))
        XCTAssertFalse(all.hidesOverview(for: started))
        XCTAssertFalse(all.hidesImage(for: EpisodeWatchState(played: true)))
    }

    func testOnlyEpisodeSectionItemsAreHidden() throws {
        let all = EpisodeSpoilerSettings(hidesImages: true, hidesOverviews: true)
        for type in ["episode", " Episode ", "episodes", " Episodes "] {
            let item = try episodeItem(type: type)
            XCTAssertTrue(SiloMediaType.isSupportedSectionItem(type))
            XCTAssertTrue(all.hidesImage(for: item), type)
            XCTAssertTrue(all.hidesOverview(for: item), type)
        }
        for type in ["movie", "series", "season"] {
            XCTAssertFalse(all.hidesImage(for: try episodeItem(type: type)), type)
            XCTAssertFalse(all.hidesOverview(for: try episodeItem(type: type)), type)
        }
        XCTAssertFalse(all.hidesImage(for: try episodeItem(), playedOverride: true))
    }

    func testProvenancePreservesSeriesArtworkAndProtectsLegacyPayloads() throws {
        let all = EpisodeSpoilerSettings(hidesImages: true, hidesOverviews: true)
        var item = try episodeItem()
        item.backdropUrl = "https://example.invalid/series.jpg"
        item.backdropIsEpisodeStill = false
        XCTAssertFalse(all.hidesImage(for: item))
        XCTAssertTrue(all.hidesOverview(for: item))
        item.backdropIsEpisodeStill = true
        XCTAssertTrue(all.hidesImage(for: item))
        item.backdropIsEpisodeStill = nil
        XCTAssertTrue(all.hidesImage(for: item))
        item.backdropUrl = nil
        item.posterIsEpisodeStill = false
        XCTAssertFalse(all.hidesImage(for: item))
        item.posterIsEpisodeStill = true
        XCTAssertTrue(all.hidesImage(for: item))
    }

    func testSubscriptReadsAndWritesEachSwitch() {
        var settings = EpisodeSpoilerSettings.off
        settings[.overviews] = true
        XCTAssertEqual(settings, EpisodeSpoilerSettings(hidesImages: false, hidesOverviews: true))
        XCTAssertTrue(settings[.overviews])
        XCTAssertFalse(settings[.images])
    }

    func testBlurIsAtLeastSigmaTwelve() {
        XCTAssertGreaterThanOrEqual(EpisodeSpoilerBlur.radius, 12)
    }
}

// MARK: - Contract

final class EpisodeSpoilerContractTests: XCTestCase {
    func testKeysAreServedFromRevisionSixteen() {
        XCTAssertEqual(EpisodeSpoilerContract.keys, [
            .catalogHideUnwatchedEpisodeImages,
            .catalogHideUnwatchedEpisodeOverviews,
        ])
        XCTAssertTrue(EpisodeSpoilerContract.isSupported(by: spoilerCapabilities(revision: 16)))
        XCTAssertTrue(EpisodeSpoilerContract.isSupported(by: spoilerCapabilities(revision: 17)))
        XCTAssertFalse(EpisodeSpoilerContract.isSupported(by: spoilerCapabilities(revision: 15)))
        XCTAssertFalse(EpisodeSpoilerContract.isSupported(by: spoilerCapabilities(revision: 16, batchedEffective: false)))
        XCTAssertFalse(EpisodeSpoilerContract.isSupported(by: spoilerCapabilities(revision: 16, allowed: false)))
    }

    func testResolveReadsBooleansAndDefaultsTheRest() throws {
        XCTAssertEqual(
            EpisodeSpoilerContract.resolve(try spoilerResponse([
                "catalog.hide_unwatched_episode_images": true,
            ])),
            EpisodeSpoilerSettings(hidesImages: true, hidesOverviews: false)
        )
        XCTAssertEqual(EpisodeSpoilerContract.resolve(try spoilerResponse([:])), .off)
        XCTAssertEqual(
            EpisodeSpoilerContract.resolve(try spoilerResponse([
                "catalog.hide_unwatched_episode_images": "yes",
                "catalog.hide_unwatched_episode_overviews": 1,
            ])),
            .off
        )
    }
}

// MARK: - Store

@MainActor
final class EpisodeSpoilerPreferencesTests: XCTestCase {
    private var suiteName = ""
    private var suite: UserDefaults!
    private var defaults: SharedDefaults!
    private var transport: FakeEpisodeSpoilerTransport!
    private var identity: HTTPRequestIdentity? = EpisodeSpoilerPreferencesTests.profileA

    private static let profileA = HTTPRequestIdentity(
        serverId: "server-1",
        serverURL: "https://silo.example",
        profileId: "profile-a",
        clientFamily: "ios"
    )

    private static let profileB = HTTPRequestIdentity(
        serverId: "server-1",
        serverURL: "https://silo.example",
        profileId: "profile-b",
        clientFamily: "ios"
    )

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "episode-spoiler-tests-\(UUID().uuidString)"
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults = SharedDefaults(suite: suite, standard: suite)
        transport = FakeEpisodeSpoilerTransport()
        identity = Self.profileA
    }

    override func tearDown() async throws {
        suite.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    private func makeStore() -> EpisodeSpoilerPreferences {
        EpisodeSpoilerPreferences(
            defaults: defaults,
            transport: transport,
            requestIdentity: { [unowned self] in self.identity }
        )
    }

    private var cacheKey: String {
        EpisodeSpoilerPreferences.cacheKey(for: Self.profileA)
    }

    func testBeforeAnyAnswerNothingIsHiddenAndTheRowsStayHidden() {
        let store = makeStore()
        XCTAssertNil(store.values)
        XCTAssertEqual(store.settings, .off)
        XCTAssertFalse(store.showsSettings)
        XCTAssertFalse(store.allowsEditing)
    }

    func testRevisionFifteenHidesTheRowsAndNeverReadsOrWrites() async {
        transport.capabilities = .available(spoilerCapabilities(revision: 15))
        let store = makeStore()
        await store.refresh()

        XCTAssertEqual(store.syncState, .serverUpgradeRequired)
        XCTAssertFalse(store.showsSettings)
        XCTAssertFalse(store.allowsEditing)
        XCTAssertNil(store.statusMessage)
        XCTAssertEqual(store.settings, .off)
        XCTAssertEqual(transport.effectiveReads, 0)

        store.set(.images, to: true)
        await store.waitForPendingWrites()
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertEqual(store.settings, .off)
    }

    func testRevisionSixteenReadsExactlyTheTwoKeys() async {
        transport.effective = [
            "catalog.hide_unwatched_episode_images": true,
            "catalog.hide_unwatched_episode_overviews": false,
        ]
        let store = makeStore()
        await store.refresh()

        XCTAssertEqual(store.syncState, .supported)
        XCTAssertTrue(store.showsSettings)
        XCTAssertTrue(store.allowsEditing)
        XCTAssertNil(store.statusMessage)
        XCTAssertEqual(transport.requestedKeys, EpisodeSpoilerContract.keys)
        XCTAssertEqual(transport.readIdentities, [Self.profileA])
        XCTAssertEqual(store.settings, EpisodeSpoilerSettings(hidesImages: true, hidesOverviews: false))
    }

    func testUnsetValuesResolveToOff() async {
        let store = makeStore()
        await store.refresh()
        XCTAssertEqual(store.values, .off)
        XCTAssertTrue(store.showsSettings)
    }

    func testWriteGoesToProfileScopeAsABoolean() async {
        let store = makeStore()
        await store.refresh()

        store.set(.overviews, to: true)
        // Optimistic: surfaces hide the description before the write returns.
        XCTAssertTrue(store.settings.hidesOverviews)
        await store.waitForPendingWrites()

        XCTAssertEqual(transport.writes, [
            FakeEpisodeSpoilerTransport.Write(
                key: .catalogHideUnwatchedEpisodeOverviews,
                value: .bool(true),
                identity: Self.profileA
            ),
        ])
        XCTAssertFalse(store.isSaving)
        XCTAssertTrue(store.writeErrors.isEmpty)
        XCTAssertTrue(store.settings.hidesOverviews)
    }

    func testUnchangedValuesAreNotWritten() async {
        let store = makeStore()
        await store.refresh()
        store.set(.images, to: false)
        await store.waitForPendingWrites()
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testFailedWriteRollsBackOnlyThatSwitch() async {
        transport.failingKeys = [.catalogHideUnwatchedEpisodeImages]
        let store = makeStore()
        await store.refresh()

        store.set(.images, to: true)
        store.set(.overviews, to: true)
        await store.waitForPendingWrites()

        XCTAssertEqual(transport.writes.map(\.key), EpisodeSpoilerContract.keys)
        XCTAssertEqual(store.settings, EpisodeSpoilerSettings(hidesImages: false, hidesOverviews: true))
        XCTAssertNotNil(store.writeErrors[.catalogHideUnwatchedEpisodeImages])
        XCTAssertNil(store.writeErrors[.catalogHideUnwatchedEpisodeOverviews])
        XCTAssertFalse(store.isSaving)
    }

    func testTheCacheHoldsOnlyServerConfirmedValues() async {
        let store = makeStore()
        await store.refresh()

        transport.failingKeys = [.catalogHideUnwatchedEpisodeImages]
        store.set(.images, to: true)
        XCTAssertTrue(store.settings.hidesImages)
        XCTAssertFalse(makeStore().settings.hidesImages)
        await store.waitForPendingWrites()
        XCTAssertFalse(makeStore().settings.hidesImages)

        transport.failingKeys = []
        store.set(.images, to: true)
        await store.waitForPendingWrites()
        XCTAssertTrue(makeStore().settings.hidesImages)
    }

    func testProfilesKeepSeparateCaches() async {
        transport.effective = ["catalog.hide_unwatched_episode_images": true]
        let store = makeStore()
        await store.refresh()
        XCTAssertTrue(store.settings.hidesImages)

        // Switched, no refresh yet: B has no cached answer, so nothing hides.
        identity = Self.profileB
        XCTAssertEqual(store.settings, .off)

        transport.effective = ["catalog.hide_unwatched_episode_overviews": true]
        await store.refresh()
        XCTAssertEqual(store.settings, EpisodeSpoilerSettings(hidesImages: false, hidesOverviews: true))

        identity = Self.profileA
        XCTAssertEqual(store.settings, EpisodeSpoilerSettings(hidesImages: true, hidesOverviews: false))
    }

    func testAWriteThatFinishesAfterASwitchIsCachedForItsProfile() async {
        let store = makeStore()
        await store.refresh()
        let gate = WriteGate()
        transport.beforeWrite = { await gate.wait() }
        store.set(.images, to: true)

        identity = Self.profileB
        await store.refresh()
        await gate.open()
        await store.waitForPendingWrites()

        // Back on A with the server unreachable, the cache must hold A's save.
        identity = Self.profileA
        transport.capabilities = .failed(.transport(description: "offline"))
        await store.refresh()
        XCTAssertTrue(store.settings.hidesImages)
    }

    func testReturningToAProfileMidWriteShowsTheSavedValue() async {
        let store = makeStore()
        await store.refresh()
        let gate = WriteGate()
        transport.beforeWrite = { await gate.wait() }
        store.set(.images, to: true)

        identity = Self.profileB
        await store.refresh()
        identity = Self.profileA
        // Reloads A's cache, which predates the write; the read is skipped
        // while the write is in flight.
        await store.refresh()
        XCTAssertFalse(store.settings.hidesImages)

        await gate.open()
        await store.waitForPendingWrites()
        XCTAssertTrue(store.settings.hidesImages)
    }

    func testAViewReadingANewProfileBeforeItsRefreshRedrawsWithTheAnswer() async {
        let store = makeStore()
        await store.refresh()
        identity = Self.profileB
        let redraw = ObservationFlag()
        withObservationTracking { _ = store.settings } onChange: { redraw.fired = true }

        transport.effective = ["catalog.hide_unwatched_episode_images": true]
        await store.refresh()
        XCTAssertTrue(redraw.fired)
        XCTAssertTrue(store.settings.hidesImages)
    }

    func testTopShelfReadsTheImageSwitchTheStoreCached() async {
        transport.effective = ["catalog.hide_unwatched_episode_images": true]
        await makeStore().refresh()
        XCTAssertTrue(EpisodeSpoilerCache.hidesImages(serverId: "server-1", profileId: "profile-a", in: suite))
        XCTAssertFalse(EpisodeSpoilerCache.hidesImages(serverId: "server-1", profileId: "profile-b", in: suite))
        XCTAssertFalse(EpisodeSpoilerCache.hidesImages(serverId: "server-1", profileId: nil, in: suite))
    }

    func testProbeFailureKeepsTheCachedAnswer() async {
        transport.effective = ["catalog.hide_unwatched_episode_images": true]
        await makeStore().refresh()

        transport.capabilities = .failed(.transport(description: "offline"))
        let store = makeStore()
        await store.refresh()
        XCTAssertEqual(store.syncState, .unavailable)
        XCTAssertTrue(store.settings.hidesImages)
        XCTAssertTrue(store.showsSettings)
        XCTAssertFalse(store.allowsEditing)
        XCTAssertNotNil(store.statusMessage)
    }

    func testReadFailureKeepsTheCachedAnswer() async {
        transport.effective = ["catalog.hide_unwatched_episode_overviews": true]
        await makeStore().refresh()

        transport.effectiveError = SettingsAPIError.transport(description: "timed out")
        let store = makeStore()
        await store.refresh()
        XCTAssertTrue(store.settings.hidesOverviews)
        XCTAssertNotNil(store.readErrorMessage)
    }

    func testServerDowngradeClearsTheCache() async {
        transport.effective = ["catalog.hide_unwatched_episode_images": true]
        let store = makeStore()
        await store.refresh()
        XCTAssertNotNil(suite.data(forKey: cacheKey))

        transport.capabilities = .available(spoilerCapabilities(revision: 15))
        await store.refresh()
        XCTAssertNil(store.values)
        XCTAssertEqual(store.settings, .off)
        XCTAssertFalse(store.showsSettings)
        XCTAssertNil(suite.data(forKey: cacheKey))
    }

    func testUpgradeRequiredReadClearsTheCache() async {
        transport.effective = ["catalog.hide_unwatched_episode_images": true]
        await makeStore().refresh()

        transport.effectiveError = SettingsAPIError.serverUpgradeRequired
        let store = makeStore()
        await store.refresh()
        XCTAssertEqual(store.syncState, .serverUpgradeRequired)
        XCTAssertEqual(store.settings, .off)
        XCTAssertNil(suite.data(forKey: cacheKey))
    }

    func testWithoutAnActiveProfileNothingIsRead() async {
        identity = nil
        let store = makeStore()
        await store.refresh()
        XCTAssertEqual(store.syncState, .unavailable)
        XCTAssertEqual(transport.capabilityProbes, 0)
        XCTAssertEqual(store.settings, .off)
    }
}

// MARK: - tvOS marquee

#if os(tvOS)
final class TopShelfSpoilerTests: XCTestCase {
    private func item(_ json: String) throws -> TopShelfItem {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(TopShelfItem.self, from: Data(json.utf8))
    }

    func testFallbackLeavesOutAnUntouchedEpisodesStillOnlyWhenHidden() throws {
        let untouched = try item(#"{"content_id":"e1","type":"episode","title":"Pilot","poster_url":"https://example.invalid/still.jpg"}"#)
        let started = try item(#"{"content_id":"e2","type":"episode","title":"Two","position_seconds":30,"poster_url":"https://example.invalid/still2.jpg"}"#)
        let movie = try item(#"{"content_id":"m1","type":"movie","title":"Film","poster_url":"https://example.invalid/poster.jpg"}"#)
        XCTAssertNil(untouched.fallbackPosterUrl(hidingEpisodeStills: true))
        XCTAssertEqual(untouched.fallbackPosterUrl(hidingEpisodeStills: false), "https://example.invalid/still.jpg")
        XCTAssertEqual(started.fallbackPosterUrl(hidingEpisodeStills: true), "https://example.invalid/still2.jpg")
        XCTAssertEqual(movie.fallbackPosterUrl(hidingEpisodeStills: true), "https://example.invalid/poster.jpg")
    }
}

final class EpisodeSpoilerMarqueeTests: XCTestCase {
    func testProvenancePreservesSeriesArtworkInEitherSlot() throws {
        var item = try episodeItem(
            overview: "The twist.",
            backdropUrl: "https://example.invalid/series.jpg",
            posterUrl: "https://example.invalid/still.jpg"
        )
        item.backdropIsEpisodeStill = false
        item.posterIsEpisodeStill = true
        let spoilers = EpisodeSpoilerSettings(hidesImages: true, hidesOverviews: true)
        let content = TVMarqueeContent(item: item, rowTitle: "Next Up", spoilers: spoilers)
        XCTAssertNil(content.synopsis)
        XCTAssertEqual(content.backdropUrl, item.backdropUrl)
        XCTAssertNil(content.fallbackArtworkUrl)

        item.backdropIsEpisodeStill = true
        item.posterIsEpisodeStill = false
        let fallback = TVMarqueeContent(item: item, rowTitle: "Next Up", spoilers: spoilers)
        XCTAssertNil(fallback.backdropUrl)
        XCTAssertEqual(fallback.fallbackArtworkUrl, item.posterUrl)
    }

    func testHiddenEpisodeDropsItsStillSynopsisAndPosterFallback() throws {
        let item = try episodeItem(
            overview: "The twist.",
            backdropUrl: "https://img.example/still.jpg",
            posterUrl: "https://img.example/poster.jpg"
        )
        let hidden = TVMarqueeContent(
            item: item,
            rowTitle: "Next Up",
            spoilers: EpisodeSpoilerSettings(hidesImages: true, hidesOverviews: true)
        )
        XCTAssertNil(hidden.synopsis)
        XCTAssertNil(hidden.backdropUrl)
        XCTAssertNil(hidden.fallbackArtworkUrl)

        let shown = TVMarqueeContent(item: item, rowTitle: "Next Up")
        XCTAssertEqual(shown.synopsis, "The twist.")
        XCTAssertEqual(shown.backdropUrl, "https://img.example/still.jpg")
        XCTAssertEqual(shown.fallbackArtworkUrl, "https://img.example/poster.jpg")
    }

    func testSeriesRowsKeepTheirArtwork() throws {
        let item = try episodeItem(
            type: "series",
            overview: "The premise.",
            backdropUrl: "https://img.example/backdrop.jpg"
        )
        let content = TVMarqueeContent(
            item: item,
            rowTitle: "Recently Added",
            spoilers: EpisodeSpoilerSettings(hidesImages: true, hidesOverviews: true)
        )
        XCTAssertEqual(content.synopsis, "The premise.")
        XCTAssertEqual(content.backdropUrl, "https://img.example/backdrop.jpg")
    }

    /// Home can seed the marquee before the spoiler settings load; the
    /// rebuilt copy must replace the displayed content in place.
    @MainActor
    func testReplaceContentAppliesLateSpoilerSettingsToTheSameSelection() throws {
        let item = try episodeItem(overview: "The twist.", backdropUrl: "https://img.example/still.jpg")
        let model = TVFocusMarqueeModel()
        model.seed(TVMarqueeContent(item: item, rowId: "next-up", rowTitle: "Next Up"))
        XCTAssertEqual(model.content?.synopsis, "The twist.")

        let hidden = EpisodeSpoilerSettings(hidesImages: true, hidesOverviews: true)
        model.replaceContent(TVMarqueeContent(item: item, rowId: "next-up", rowTitle: "Next Up", spoilers: hidden))
        XCTAssertNil(model.content?.synopsis)
        XCTAssertNil(model.content?.backdropUrl)

        // A rebuilt card from another row is a different selection.
        model.replaceContent(TVMarqueeContent(item: item, rowId: "other", rowTitle: "Other"))
        XCTAssertNil(model.content?.synopsis)
        model.suspend()
    }

    @MainActor
    func testEnrichedBackdropUsesProvenanceAndCurrentSpoilerDecision() throws {
        for provenance: Bool? in [true, false, nil] {
            let contentId = "enriched-spoiler-\(UUID().uuidString)"
            let backdrop = "https://img.example/enriched.jpg"
            var fields: [String: Any] = ["contentId": contentId, "type": "episode", "title": "Pilot", "backdropUrl": backdrop]
            if let provenance { fields["backdropIsEpisodeStill"] = provenance }
            let detail = try JSONDecoder().decode(ItemDetail.self, from: JSONSerialization.data(withJSONObject: fields))
            let key = CacheKey.itemDetail(contentId)
            ResponseCache.shared.set(detail, for: key)
            let model = TVFocusMarqueeModel()
            defer { model.suspend(); ResponseCache.shared.remove(key) }
            let episode = try episodeItem(contentId: contentId)
            let settings = EpisodeSpoilerSettings(hidesImages: true, hidesOverviews: true)
            model.seed(TVMarqueeContent(item: episode, rowTitle: "Next Up", spoilers: settings))
            XCTAssertEqual(model.backdropURL, provenance == false ? backdrop : nil)
            model.replaceContent(TVMarqueeContent(item: episode, rowTitle: "Next Up", spoilers: .off))
            XCTAssertEqual(model.backdropURL, backdrop)
            let started = try episodeItem(contentId: contentId, played: true)
            model.replaceContent(TVMarqueeContent(item: started, rowTitle: "Next Up", spoilers: settings))
            XCTAssertEqual(model.backdropURL, backdrop)
        }
    }

    @MainActor
    func testRemovingSelectionCancelsPendingRestAndAllowsReseeding() async throws {
        let model = TVFocusMarqueeModel()
        defer { model.suspend() }
        let old = try episodeItem(type: "movie", backdropUrl: "https://img.example/old.jpg")
        model.seed(TVMarqueeContent(item: old, rowId: "next-up", rowTitle: "Next Up"))
        let pending = try episodeItem(contentId: "pending", type: "movie", backdropUrl: "https://img.example/pending.jpg")
        model.preview(TVMarqueeContent(item: pending, rowId: "next-up", rowTitle: "Next Up"))
        model.clearSelection()
        XCTAssertNil(model.content)
        XCTAssertNil(model.backdropURL)
        let replacement = try episodeItem(contentId: "replacement", type: "movie", backdropUrl: "https://img.example/replacement.jpg")
        model.seed(TVMarqueeContent(item: replacement, rowId: "next-up", rowTitle: "Next Up"))
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.content?.contentId, replacement.contentId)
        XCTAssertEqual(model.backdropURL, replacement.backdropUrl)
    }

    @MainActor
    func testLateSpoilerSettingsPreservePendingBackdropRest() async throws {
        let contentId = "spoiler-rest-\(UUID().uuidString)"
        let backdrop = "https://img.example/series.jpg"
        let detail = try JSONDecoder().decode(ItemDetail.self, from: Data("""
            {"contentId":"\(contentId)","type":"episode","title":"Pilot","backdropUrl":"\(backdrop)","backdropIsEpisodeStill":false}
            """.utf8))
        let cacheKey = CacheKey.itemDetail(contentId)
        ResponseCache.shared.set(detail, for: cacheKey)
        let model = TVFocusMarqueeModel()
        defer {
            model.suspend()
            ResponseCache.shared.remove(cacheKey)
        }

        let prior = try episodeItem(type: "movie", backdropUrl: "https://img.example/prior.jpg")
        model.seed(TVMarqueeContent(item: prior, rowId: "next-up", rowTitle: "Next Up"))
        XCTAssertEqual(model.backdropURL, prior.backdropUrl)

        let episode = try episodeItem(contentId: contentId, overview: "The twist.")
        model.preview(TVMarqueeContent(item: episode, rowId: "next-up", rowTitle: "Next Up"))
        // The settings answer changes presentation while this selection is
        // still waiting for its focus debounce; it must keep that rest pending.
        model.replaceContent(TVMarqueeContent(
            item: episode,
            rowId: "next-up",
            rowTitle: "Next Up",
            spoilers: EpisodeSpoilerSettings(hidesImages: true, hidesOverviews: true)
        ))
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertNil(model.content?.synopsis)
        XCTAssertEqual(model.enrichment?.backdropUrl, backdrop)
        XCTAssertEqual(model.backdropURL, backdrop)
    }
}
#endif

// MARK: - Fixtures

private func userData(_ json: String) throws -> LeafItemUserData {
    try JSONDecoder().decode(LeafItemUserData.self, from: Data(json.utf8))
}

private func episodeItem(
    contentId: String = "episode-1",
    type: String = "episode",
    played: Bool? = nil,
    positionSeconds: Double? = nil,
    overview: String? = nil,
    backdropUrl: String? = nil,
    posterUrl: String? = nil
) throws -> SectionItem {
    var fields: [String: Any] = [
        "contentId": contentId,
        "type": type,
        "title": "Pilot",
        "seriesId": "series-1",
        "seriesTitle": "Series",
        "seasonNumber": 1,
        "episodeNumber": 1,
    ]
    if let played {
        fields["userState"] = ["played": played, "isFavorite": false, "inWatchlist": false]
    }
    if let positionSeconds { fields["positionSeconds"] = positionSeconds }
    if let overview { fields["overview"] = overview }
    if let backdropUrl { fields["backdropUrl"] = backdropUrl }
    if let posterUrl { fields["posterUrl"] = posterUrl }
    let data = try JSONSerialization.data(withJSONObject: fields)
    return try JSONDecoder().decode(SectionItem.self, from: data)
}

private func spoilerCapabilities(
    revision: Int,
    allowed: Bool = true,
    batchedEffective: Bool = true
) -> APIv2SettingsContractCapabilities {
    APIv2SettingsContractCapabilities(
        revision: "capabilities-\(revision)",
        state: "available",
        allowed: allowed,
        manifestRevision: revision,
        clientFamilies: ["tv", "mobile", "tablet", "desktop", "web"],
        supportsBatchedEffective: batchedEffective,
        supportsAtomicShortcuts: true
    )
}

private func spoilerResponse(_ values: [String: Any], revision: Int = 16) throws -> EffectiveSettingValuesResponse {
    let rows: [[String: Any]] = values.sorted { $0.key < $1.key }.map { key, value in
        ["key": key, "value": value, "source": "profile"]
    }
    let data = try JSONSerialization.data(withJSONObject: ["items": rows, "revision": revision])
    return try SettingsWireCoding.makeDecoder().decode(EffectiveSettingValuesResponse.self, from: data)
}

/// Holds writes in flight until a test opens it.
private actor WriteGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class ObservationFlag: @unchecked Sendable {
    var fired = false
}

@MainActor
private final class FakeEpisodeSpoilerTransport: ProfileScopedSettingTransport, @unchecked Sendable {
    struct Write: Equatable {
        let key: SettingKey
        let value: SettingJSONValue
        let identity: HTTPRequestIdentity
    }

    var capabilities: SettingsCapabilitiesResult = .available(spoilerCapabilities(revision: 16))
    var effective: [String: Any] = [:]
    var effectiveError: Error?
    var failingKeys: Set<SettingKey> = []
    var beforeWrite: (@MainActor () async -> Void)?

    private(set) var capabilityProbes = 0
    private(set) var effectiveReads = 0
    private(set) var requestedKeys: [SettingKey] = []
    private(set) var readIdentities: [HTTPRequestIdentity] = []
    private(set) var writes: [Write] = []

    nonisolated func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult {
        await MainActor.run {
            capabilityProbes += 1
            return capabilities
        }
    }

    nonisolated func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        try await MainActor.run {
            effectiveReads += 1
            requestedKeys = keys
            readIdentities.append(requestIdentity)
            if let effectiveError { throw effectiveError }
            return try spoilerResponse(effective)
        }
    }

    nonisolated func putProfileValue(
        key: SettingKey,
        value: SettingJSONValue,
        requestIdentity: HTTPRequestIdentity
    ) async throws {
        if let hook = await MainActor.run(body: { beforeWrite }) {
            await hook()
        }
        try await MainActor.run {
            writes.append(Write(key: key, value: value, identity: requestIdentity))
            if failingKeys.contains(key) {
                throw SettingsAPIError.server(status: 500, code: "internal", message: "boom")
            }
        }
    }
}
