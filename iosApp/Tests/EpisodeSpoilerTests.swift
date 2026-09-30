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
        XCTAssertTrue(all.hidesImage(for: try episodeItem()))
        XCTAssertTrue(all.hidesOverview(for: try episodeItem()))
        XCTAssertTrue(all.hidesImage(for: try episodeItem(type: " Episode ")))
        for type in ["movie", "series", "season"] {
            XCTAssertFalse(all.hidesImage(for: try episodeItem(type: type)), type)
            XCTAssertFalse(all.hidesOverview(for: try episodeItem(type: type)), type)
        }
        XCTAssertFalse(all.hidesImage(for: try episodeItem(), playedOverride: true))
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
    func testKeysAreServedFromRevisionFifteen() {
        XCTAssertEqual(EpisodeSpoilerContract.keys, [
            .catalogHideUnwatchedEpisodeImages,
            .catalogHideUnwatchedEpisodeOverviews,
        ])
        XCTAssertTrue(EpisodeSpoilerContract.isSupported(by: spoilerCapabilities(revision: 15)))
        XCTAssertTrue(EpisodeSpoilerContract.isSupported(by: spoilerCapabilities(revision: 16)))
        XCTAssertFalse(EpisodeSpoilerContract.isSupported(by: spoilerCapabilities(revision: 14)))
        XCTAssertFalse(EpisodeSpoilerContract.isSupported(by: spoilerCapabilities(revision: 15, batchedEffective: false)))
        XCTAssertFalse(EpisodeSpoilerContract.isSupported(by: spoilerCapabilities(revision: 15, allowed: false)))
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

    func testRevisionFourteenHidesTheRowsAndNeverReadsOrWrites() async {
        transport.capabilities = .available(spoilerCapabilities(revision: 14))
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

    func testRevisionFifteenReadsExactlyTheTwoKeys() async {
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

        transport.capabilities = .available(spoilerCapabilities(revision: 14))
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
final class EpisodeSpoilerMarqueeTests: XCTestCase {
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
}
#endif

// MARK: - Fixtures

private func userData(_ json: String) throws -> LeafItemUserData {
    try JSONDecoder().decode(LeafItemUserData.self, from: Data(json.utf8))
}

private func episodeItem(
    type: String = "episode",
    played: Bool? = nil,
    positionSeconds: Double? = nil,
    overview: String? = nil,
    backdropUrl: String? = nil,
    posterUrl: String? = nil
) throws -> SectionItem {
    var fields: [String: Any] = [
        "contentId": "episode-1",
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

private func spoilerResponse(_ values: [String: Any], revision: Int = 15) throws -> EffectiveSettingValuesResponse {
    let rows: [[String: Any]] = values.sorted { $0.key < $1.key }.map { key, value in
        ["key": key, "value": value, "source": "profile"]
    }
    let data = try JSONSerialization.data(withJSONObject: ["items": rows, "revision": revision])
    return try SettingsWireCoding.makeDecoder().decode(EffectiveSettingValuesResponse.self, from: data)
}

@MainActor
private final class FakeEpisodeSpoilerTransport: ProfileScopedSettingTransport, @unchecked Sendable {
    struct Write: Equatable {
        let key: SettingKey
        let value: SettingJSONValue
        let identity: HTTPRequestIdentity
    }

    var capabilities: SettingsCapabilitiesResult = .available(spoilerCapabilities(revision: 15))
    var effective: [String: Any] = [:]
    var effectiveError: Error?
    var failingKeys: Set<SettingKey> = []

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
        try await MainActor.run {
            writes.append(Write(key: key, value: value, identity: requestIdentity))
            if failingKeys.contains(key) {
                throw SettingsAPIError.server(status: 500, code: "internal", message: "boom")
            }
        }
    }
}
