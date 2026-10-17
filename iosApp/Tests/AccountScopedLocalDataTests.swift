import Foundation
import XCTest
@testable import Silo

/// Local data keyed by server, account, and profile (plan §2.11, spec §8.3).
/// For each store: two accounts whose profiles are both `default` on one
/// server see their own data; the account that owns the server's data from
/// before accounts takes over the old key once, and the old key is gone; any
/// other account never reads the old key; and a settings write queued under
/// one account is refused once another account with the same profile ID is
/// signed in.
@MainActor
final class AccountScopedLocalDataTests: XCTestCase {
    private typealias F = SignInStoreFixture
    private static let server = "server-1"
    private static let serverURL = "https://silo.example"
    /// Owns `server`'s data from before accounts.
    private static let alex = "12"
    private static let sam = "13"

    private var suiteName = ""
    private var suite: UserDefaults!
    private var defaults: SharedDefaults!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "account-scoped-local-data-\(UUID().uuidString)"
        suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults = SharedDefaults(suite: suite, standard: suite)
        // No owners until a test publishes them.
        LegacyLocalDataOwner.publish([:])
    }

    override func tearDown() async throws {
        LegacyLocalDataOwner.publish([:])
        UserDefaults().removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    /// Publishes alex as the owner of `server`'s old data. Every check after
    /// it runs before the next suspension, so nothing republishes meanwhile.
    private func alexOwnsLegacyData() {
        LegacyLocalDataOwner.publish([Self.server: Self.alex])
    }

    private static func identity(_ accountID: String?, family: String = "mobile") -> HTTPRequestIdentity {
        HTTPRequestIdentity(serverId: server, serverURL: serverURL, profileId: "default", clientFamily: family,
                            accountID: accountID)
    }

    // MARK: - Keys

    func testNewKeysNameTheAccountAndNeverEqualAnOldKey() {
        XCTAssertEqual(AccountScopedKeyAdoption.key("p", serverID: "s", accountID: "12", profileID: "default"),
                       "p.v2.s.12.default")
        XCTAssertEqual(AccountScopedKeyAdoption.key("p", serverID: "s", accountID: nil, profileID: "default"),
                       "p.s.default", "an unknown account keeps the key from before accounts")
        XCTAssertEqual(AccountScopedKeyAdoption.key("p", serverID: "s", accountID: "12", profileID: "d", suffix: "tv"),
                       "p.v2.s.12.d.tv")
        // A profile ID shaped like the rest of a new key still yields an old
        // key: old keys put the server right after the prefix, and no server
        // ID is the marker.
        let lookalike = AccountScopedKeyAdoption.key("p", serverID: "s", accountID: nil, profileID: "s.12.default")
        XCTAssertNotEqual(lookalike, AccountScopedKeyAdoption.key("p", serverID: "s", accountID: "12", profileID: "default"))
        XCTAssertFalse(lookalike.hasPrefix("p.\(AccountScopedKeyAdoption.versionMarker)."))
    }

    func testOnlyTheLegacyOwnerMovesAnOldValueAndOnlyOnce() {
        let old = "p.\(Self.server).default"
        defaults.set(Data("old".utf8), forKey: old)
        defaults.set(true, forKey: "\(old).flag")
        suite.set(7, forKey: "\(old).number")
        alexOwnsLegacyData()

        func key(_ account: String, _ suffix: String? = nil) -> String {
            AccountScopedKeyAdoption.adoptedKey("p", serverID: Self.server, accountID: account, profileID: "default",
                                                suffix: suffix, defaults: defaults)
        }
        XCTAssertNil(defaults.data(forKey: key(Self.sam)), "another account starts empty")
        XCTAssertNotNil(defaults.data(forKey: old), "and leaves the old value alone")

        XCTAssertEqual(defaults.data(forKey: key(Self.alex)), Data("old".utf8))
        XCTAssertNil(defaults.data(forKey: old))
        XCTAssertTrue(defaults.bool(forKey: key(Self.alex, "flag")))
        XCTAssertFalse(defaults.containsObject(forKey: "\(old).flag"))
        XCTAssertEqual(suite.integer(forKey: key(Self.alex, "number")), 7)
        XCTAssertNil(suite.object(forKey: "\(old).number"))

        defaults.set(Data("left".utf8), forKey: old)
        XCTAssertEqual(defaults.data(forKey: key(Self.alex)), Data("old".utf8), "the new key, once written, wins")
        XCTAssertEqual(defaults.data(forKey: old), Data("left".utf8))
    }

    func testAReaderThatNeverWritesFindsTheOldValueOnlyForTheOwner() {
        let old = "p.\(Self.server).default"
        defaults.set(Data("old".utf8), forKey: old)
        func readable(_ account: String?) -> String {
            AccountScopedKeyAdoption.readableKey("p", serverID: Self.server, accountID: account, profileID: "default",
                                                 contains: { self.defaults.containsObject(forKey: $0) },
                                                 legacyOwner: { $0 == Self.server ? Self.alex : nil })
        }
        XCTAssertEqual(readable(Self.alex), old)
        XCTAssertEqual(readable(Self.sam), "p.v2.\(Self.server).\(Self.sam).default")
        XCTAssertEqual(readable(nil), old)
        XCTAssertNotNil(defaults.data(forKey: old), "reading moves nothing")
    }

    // MARK: - Response snapshots

    func testResponseSnapshots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountScopedSnapshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func scope(_ account: String?) -> ResponseSnapshotStore.Scope {
            ResponseSnapshotStore.Scope(serverId: Self.server, accountId: account, profileId: "default")
        }
        ResponseSnapshotStore.store(SectionsResponse(sections: []), forKey: CacheKey.homeSections, scope: scope(nil), in: root)
        _ = ResponseSnapshotStore.load(scope: scope(nil), in: root)
        alexOwnsLegacyData()

        XCTAssertTrue(ResponseSnapshotStore.load(scope: scope(Self.sam), in: root).isEmpty)
        XCTAssertEqual(ResponseSnapshotStore.load(scope: scope(nil), in: root).map(\.key), [CacheKey.homeSections])
        XCTAssertEqual(ResponseSnapshotStore.load(scope: scope(Self.alex), in: root).map(\.key), [CacheKey.homeSections])
        XCTAssertTrue(ResponseSnapshotStore.load(scope: scope(nil), in: root).isEmpty, "the old directory moved")

        let libraries = LibrariesResponse(libraries: [Library(id: 1, name: "Movies", type: "movies", sortOrder: 0)])
        ResponseSnapshotStore.store(libraries, forKey: CacheKey.userLibraries, scope: scope(Self.sam), in: root)
        XCTAssertEqual(ResponseSnapshotStore.load(scope: scope(Self.sam), in: root).map(\.key), [CacheKey.userLibraries])
        XCTAssertEqual(ResponseSnapshotStore.load(scope: scope(Self.alex), in: root).map(\.key), [CacheKey.homeSections])
    }

    /// Snapshots the account stored before it took over the old directory
    /// (while the owners weren't published yet) win over the old copies,
    /// which go with the old directory instead of lingering.
    func testResponseSnapshotsStoredBeforeTheMoveWinAndTheOldDirectoryGoes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountScopedSnapshots-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func scope(_ account: String?) -> ResponseSnapshotStore.Scope {
            ResponseSnapshotStore.Scope(serverId: Self.server, accountId: account, profileId: "default")
        }
        func libraries(_ name: String) -> LibrariesResponse {
            LibrariesResponse(libraries: [Library(id: 1, name: name, type: "movies", sortOrder: 0)])
        }
        ResponseSnapshotStore.store(SectionsResponse(sections: []), forKey: CacheKey.homeSections, scope: scope(nil), in: root)
        ResponseSnapshotStore.store(libraries("Old"), forKey: CacheKey.userLibraries, scope: scope(nil), in: root)
        ResponseSnapshotStore.store(libraries("New"), forKey: CacheKey.userLibraries, scope: scope(Self.alex), in: root)
        _ = ResponseSnapshotStore.load(scope: scope(Self.alex), in: root)
        alexOwnsLegacyData()

        let loaded = ResponseSnapshotStore.load(scope: scope(Self.alex), in: root)
        XCTAssertEqual(Set(loaded.map(\.key)), [CacheKey.homeSections, CacheKey.userLibraries])
        let kept = try XCTUnwrap(loaded.first { $0.key == CacheKey.userLibraries }?.value as? LibrariesResponse)
        XCTAssertEqual(kept.libraries.map(\.name), ["New"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 1,
                       "the old directory is gone")
    }

    // MARK: - UI customization and its outbox

    func testUICustomizationRecordAndOutbox() async throws {
        func cacheKey(_ account: String?) -> String {
            AccountScopedKeyAdoption.key("silo.uiCustomization", serverID: Self.server, accountID: account,
                                         profileID: "default", suffix: "mobile")
        }
        // Saved before accounts: an artwork-only layout whose write never
        // reached the server.
        let layout: [String: Any] = ["poster_size": "large", "caption": "title_metadata"]
        let record: [String: Any] = [
            "shortcuts": ["items": []],
            "cardPresentation": layout,
            "pendingSyncWrites": [
                SettingKey.uiCardPresentation.rawValue: ["value": layout, "operationId": "queued-before-accounts"],
            ],
        ]
        defaults.set(try JSONSerialization.data(withJSONObject: record), forKey: cacheKey(nil))
        let transport = FakeUICustomizationTransport(effectiveResponse: FakeUICustomizationTransport.emptyResponse)
        func store(_ account: String) -> UICustomizationPreferences {
            UICustomizationPreferences(defaults: defaults, transport: transport, cacheKey: { cacheKey(account) },
                                       requestIdentity: { Self.identity(account) })
        }
        alexOwnsLegacyData()

        let samStore = store(Self.sam)
        XCTAssertEqual(samStore.cardPresentation, .standard)
        XCTAssertNotNil(defaults.data(forKey: cacheKey(nil)))

        let alexStore = store(Self.alex)
        XCTAssertEqual(alexStore.cardPresentation.posterSize, .large)
        XCTAssertNil(defaults.data(forKey: cacheKey(nil)))
        XCTAssertNotNil(defaults.data(forKey: cacheKey(Self.alex)))
        XCTAssertEqual(store(Self.alex).cardPresentation.posterSize, .large, "a second load finds it in place")

        // The outbox moved with the record and replays as alex, only.
        await samStore.refresh()
        await alexStore.refresh()
        let puts = await transport.calls(.put)
        XCTAssertEqual(puts.map(\.identity.accountID), [Self.alex])
        XCTAssertEqual(samStore.cardPresentation, .standard)
    }

    // MARK: - Title art

    func testTitleArt() async throws {
        let seeding = AccountBoundSettingsTransport(values: ["ui.title_art": false])
        await TitleArtPreferences(defaults: defaults, transport: seeding, requestIdentity: { Self.identity(nil) }).refresh()
        let old = TitleArtPreferences.cacheKey(for: Self.identity(nil))
        XCTAssertNotNil(defaults.data(forKey: old))
        alexOwnsLegacyData()

        let samStore = TitleArtPreferences(defaults: defaults, transport: seeding, requestIdentity: { Self.identity(Self.sam) })
        XCTAssertTrue(samStore.showsTitleArt, "another account sees the default")
        XCTAssertNotNil(defaults.data(forKey: old))
        let alexStore = TitleArtPreferences(defaults: defaults, transport: seeding, requestIdentity: { Self.identity(Self.alex) })
        XCTAssertFalse(alexStore.showsTitleArt)
        XCTAssertNil(defaults.data(forKey: old))
        XCTAssertNotNil(defaults.data(forKey: TitleArtPreferences.cacheKey(for: Self.identity(Self.alex))))

        seeding.values = ["ui.title_art": true]
        await samStore.refresh()
        XCTAssertTrue(samStore.showsTitleArt)
        XCTAssertFalse(TitleArtPreferences(defaults: defaults, transport: seeding,
                                           requestIdentity: { Self.identity(Self.alex) }).showsTitleArt)
    }

    // MARK: - Hidden libraries

    func testHiddenLibraries() async throws {
        let offline: (HTTPRequestIdentity?) async throws -> EffectiveSettingValuesResponse = { _ in
            throw URLError(.notConnectedToInternet)
        }
        func answer(_ ids: [Int]) -> (HTTPRequestIdentity?) async throws -> EffectiveSettingValuesResponse {
            { _ in try effectiveResponse(["ui.disabled_library_ids": ids]) }
        }
        let seeded = await HiddenLibraryPreference.hiddenLibraryIds(
            defaults: defaults, requestIdentity: { Self.identity(nil) }, read: answer([3, 4]))
        XCTAssertEqual(seeded, [3, 4])
        let old = HiddenLibraryPreference.cacheKey(for: Self.identity(nil))
        XCTAssertNotNil(defaults.data(forKey: old))

        alexOwnsLegacyData()
        let samIDs = await HiddenLibraryPreference.hiddenLibraryIds(
            defaults: defaults, requestIdentity: { Self.identity(Self.sam) }, read: offline)
        XCTAssertEqual(samIDs, [])
        XCTAssertNotNil(defaults.data(forKey: old))

        alexOwnsLegacyData()
        let alexIDs = await HiddenLibraryPreference.hiddenLibraryIds(
            defaults: defaults, requestIdentity: { Self.identity(Self.alex) }, read: offline)
        XCTAssertEqual(alexIDs, [3, 4])
        XCTAssertNil(defaults.data(forKey: old))

        _ = await HiddenLibraryPreference.hiddenLibraryIds(
            defaults: defaults, requestIdentity: { Self.identity(Self.sam) }, read: answer([9]))
        let alexAgain = await HiddenLibraryPreference.hiddenLibraryIds(
            defaults: defaults, requestIdentity: { Self.identity(Self.alex) }, read: offline)
        let samAgain = await HiddenLibraryPreference.hiddenLibraryIds(
            defaults: defaults, requestIdentity: { Self.identity(Self.sam) }, read: offline)
        XCTAssertEqual(alexAgain, [3, 4])
        XCTAssertEqual(samAgain, [9])
    }

    // MARK: - Seek intervals

    func testSeekIntervals() async throws {
        let seeding = AccountBoundSettingsTransport(values: Self.seekValues(back: 5))
        await SeekIntervalPreferences(defaults: defaults, transport: seeding, requestIdentity: { Self.identity(nil) }).refresh()
        let old = SeekIntervalPreferences.cacheKey(for: Self.identity(nil))
        XCTAssertNotNil(defaults.data(forKey: old))
        alexOwnsLegacyData()

        let samStore = SeekIntervalPreferences(defaults: defaults, transport: seeding,
                                               requestIdentity: { Self.identity(Self.sam) })
        XCTAssertNil(samStore.values)
        XCTAssertNotNil(defaults.data(forKey: old))
        let alexStore = SeekIntervalPreferences(defaults: defaults, transport: seeding,
                                                requestIdentity: { Self.identity(Self.alex) })
        XCTAssertEqual(alexStore.values?.video.backward, 5)
        XCTAssertNil(defaults.data(forKey: old))

        seeding.values = Self.seekValues(back: 15)
        await samStore.refresh()
        XCTAssertEqual(samStore.values?.video.backward, 15)
        XCTAssertEqual(SeekIntervalPreferences(defaults: defaults, transport: seeding,
                                               requestIdentity: { Self.identity(Self.alex) }).values?.video.backward, 5)
    }

    private static func seekValues(back: Int) -> [String: Any] {
        [
            "player.video_skip_back_seconds": back,
            "player.video_skip_forward_seconds": 30,
            "player.audiobook_skip_back_seconds": 30,
            "player.audiobook_skip_forward_seconds": 30,
        ]
    }

    // MARK: - Episode spoilers, which Top Shelf reads

    func testEpisodeSpoilersAndTheTopShelfRead() async throws {
        let seeding = AccountBoundSettingsTransport(values: [
            "catalog.hide_unwatched_episode_images": true,
            "catalog.hide_unwatched_episode_overviews": false,
        ])
        await EpisodeSpoilerPreferences(defaults: defaults, transport: seeding,
                                        requestIdentity: { Self.identity(nil) }).refresh()
        let old = EpisodeSpoilerCache.key(serverId: Self.server, accountId: nil, profileId: "default")
        XCTAssertNotNil(defaults.data(forKey: old))
        func topShelfHides(_ account: String?) -> Bool {
            EpisodeSpoilerCache.hidesImages(serverId: Self.server, accountId: account, profileId: "default",
                                            legacyOwner: { $0 == Self.server ? Self.alex : nil }, in: suite)
        }
        // Before the app moves it, Top Shelf reads the old answer for the
        // owner only, and moves nothing.
        XCTAssertTrue(topShelfHides(Self.alex))
        XCTAssertFalse(topShelfHides(Self.sam))
        XCTAssertNotNil(defaults.data(forKey: old))

        alexOwnsLegacyData()
        let samStore = EpisodeSpoilerPreferences(defaults: defaults, transport: seeding,
                                                 requestIdentity: { Self.identity(Self.sam) })
        XCTAssertNil(samStore.values)
        XCTAssertNotNil(defaults.data(forKey: old))
        let alexStore = EpisodeSpoilerPreferences(defaults: defaults, transport: seeding,
                                                  requestIdentity: { Self.identity(Self.alex) })
        XCTAssertEqual(alexStore.values?.hidesImages, true)
        XCTAssertNil(defaults.data(forKey: old))
        XCTAssertTrue(topShelfHides(Self.alex), "Top Shelf follows it to the new key")
        XCTAssertFalse(topShelfHides(Self.sam))

        seeding.values["catalog.hide_unwatched_episode_images"] = false
        await samStore.refresh()
        XCTAssertEqual(samStore.values?.hidesImages, false)
        XCTAssertTrue(topShelfHides(Self.alex))
    }

    // MARK: - App navigation

    func testAppNavigation() {
        func key(_ account: String?) -> String {
            AppNavPreferences.showAudiobooksKey(serverID: Self.server, accountID: account, profileID: "default",
                                                defaults: defaults)
        }
        AppNavPreferences(defaults: defaults, storageKey: { key(nil) }).setShowAudiobooks(true)
        let old = key(nil)
        alexOwnsLegacyData()

        let samPreferences = AppNavPreferences(defaults: defaults, storageKey: { key(Self.sam) })
        XCTAssertFalse(samPreferences.showAudiobooks)
        XCTAssertTrue(defaults.containsObject(forKey: old))
        XCTAssertTrue(AppNavPreferences(defaults: defaults, storageKey: { key(Self.alex) }).showAudiobooks)
        XCTAssertFalse(defaults.containsObject(forKey: old))

        samPreferences.setShowAudiobooks(false)
        XCTAssertTrue(AppNavPreferences(defaults: defaults, storageKey: { key(Self.alex) }).showAudiobooks)
        XCTAssertFalse(AppNavPreferences(defaults: defaults, storageKey: { key(Self.sam) }).showAudiobooks)
    }

    // MARK: - Browse preferences

    func testBrowsePreferences() {
        func store(_ account: String?) -> BrowsePrefsStore {
            BrowsePrefsStore(defaults: defaults, scope: {
                BrowsePrefsStore.Scope(serverID: Self.server, accountID: account, profileID: "default")
            })
        }
        var newest = CatalogFilterState()
        newest.sort = .addedAt
        newest.order = .desc
        store(nil).saveState(newest, libraryId: 7)
        store(nil).setPreserveEnabled(false, libraryId: 8)
        alexOwnsLegacyData()

        XCTAssertNil(store(Self.sam).savedState(libraryId: 7))
        XCTAssertTrue(store(Self.sam).preserveEnabled(libraryId: 8))
        XCTAssertEqual(store(nil).savedState(libraryId: 7), newest, "the old values are still there")

        XCTAssertEqual(store(Self.alex).savedState(libraryId: 7), newest)
        XCTAssertFalse(store(Self.alex).preserveEnabled(libraryId: 8))
        XCTAssertNil(store(nil).savedState(libraryId: 7))
        XCTAssertTrue(store(nil).preserveEnabled(libraryId: 8))

        var title = CatalogFilterState()
        title.order = .asc
        store(Self.sam).saveState(title, libraryId: 7)
        XCTAssertEqual(store(Self.sam).savedState(libraryId: 7), title)
        XCTAssertEqual(store(Self.alex).savedState(libraryId: 7), newest)
    }

    // MARK: - tvOS library scope

    #if os(tvOS)
    func testTVLibraryScope() {
        // The store also mirrors its numbers into the process's standard
        // defaults.
        defer {
            for account in [nil, Self.alex, Self.sam] {
                UserDefaults.standard.removeObject(forKey: AccountScopedKeyAdoption.key(
                    "skyline.libraryScope", serverID: Self.server, accountID: account, profileID: "default",
                    suffix: TVLibraryTabType.movies.rawValue))
            }
        }
        func store(_ account: String?) -> TVLibraryScopeStore {
            TVLibraryScopeStore(defaults: defaults, scope: {
                TVLibraryScopeStore.Scope(serverID: Self.server, accountID: account, profileID: "default")
            })
        }
        let libraries = [
            Library(id: 1, name: "Movies", type: "movies", sortOrder: 0),
            Library(id: 2, name: "4K Movies", type: "movies", sortOrder: 1),
        ]
        store(nil).setSelectedLibraryId(2, for: .movies)
        alexOwnsLegacyData()

        XCTAssertEqual(store(Self.sam).resolvedLibrary(for: .movies, in: libraries)?.id, 1)
        XCTAssertEqual(store(nil).resolvedLibrary(for: .movies, in: libraries)?.id, 2)
        XCTAssertEqual(store(Self.alex).resolvedLibrary(for: .movies, in: libraries)?.id, 2)
        XCTAssertEqual(store(nil).resolvedLibrary(for: .movies, in: libraries)?.id, 1, "the old choice moved")

        store(Self.sam).setSelectedLibraryId(1, for: .movies)
        XCTAssertEqual(store(Self.alex).resolvedLibrary(for: .movies, in: libraries)?.id, 2)
    }
    #endif

    // MARK: - Player settings for this device

    private static func playerScope(_ account: String?) -> String {
        PlayerSettings.makeScopeIdentifier(serverURL: serverURL, accountID: account, profileID: "default",
                                       deviceID: "device-1")
    }

    func testPlayerSettingsScopeNamesTheAccount() {
        XCTAssertEqual(Self.playerScope(nil), Data("\(Self.serverURL)|default|device-1".utf8).base64EncodedString(),
                       "an unknown account keeps the identifier from before accounts")
        XCTAssertNotEqual(Self.playerScope(Self.alex), Self.playerScope(Self.sam))
        XCTAssertNotEqual(Self.playerScope(Self.alex), Self.playerScope(nil))
    }

    /// Cached device settings, the one-time import markers, and writes not
    /// yet sent move from the identifier from before accounts to the legacy
    /// owner's, once; another account's `default` profile gets none of them.
    func testPlayerSettingsMoveToTheLegacyOwnerOnly() throws {
        let legacy = Self.playerScope(nil)
        let alexScope = Self.playerScope(Self.alex)
        let samScope = Self.playerScope(Self.sam)
        func cached(_ scope: String, _ key: String) -> String { "player.serverDeviceSettings.\(scope).\(key)" }
        func markers(_ scope: String) -> [String] {
            ["player.serverDeviceSettingsMigration.\(scope)", "player.leftoverDeviceSubtitleOffsetCleared.\(scope)"]
        }
        func journal(_ scope: String) -> UserDefaultsSettingsWriteJournal {
            UserDefaultsSettingsWriteJournal(defaults: suite, profileProvider: { "default" }, scopeProvider: { scope })
        }
        suite.set(1.5, forKey: cached(legacy, "player.playbackSpeed"))
        suite.set("1080p", forKey: cached(legacy, "preferredQuality"))
        suite.set(2.0, forKey: cached(alexScope, "player.playbackSpeed"))
        for marker in markers(legacy) { suite.set(true, forKey: marker) }
        suite.set(["player.hdr_enabled"], forKey: "player.serverDeviceSettingsMigrationRetired.\(legacy)")
        let queued = PendingSettingWrite(operation: .set(.bool(false)), scopeIdentifier: legacy, profileId: "default")
        journal(legacy).save([.playerHdrEnabled: queued])
        let owner: AccountScopedKeyAdoption.LegacyOwner = { $0 == Self.server ? Self.alex : nil }

        PlayerSettings.adoptLegacyScope(legacy, into: samScope, serverID: Self.server, accountID: Self.sam,
                                        defaults: suite, legacyOwner: owner)
        XCTAssertEqual(suite.string(forKey: cached(legacy, "preferredQuality")), "1080p")
        XCTAssertNil(suite.object(forKey: cached(samScope, "preferredQuality")))
        XCTAssertTrue(journal(samScope).load().isEmpty)
        XCTAssertEqual(journal(legacy).load().count, 1)

        PlayerSettings.adoptLegacyScope(legacy, into: alexScope, serverID: Self.server, accountID: Self.alex,
                                        defaults: suite, legacyOwner: owner)
        XCTAssertEqual(suite.string(forKey: cached(alexScope, "preferredQuality")), "1080p")
        XCTAssertNil(suite.object(forKey: cached(legacy, "preferredQuality")))
        XCTAssertEqual(suite.double(forKey: cached(alexScope, "player.playbackSpeed")), 2.0,
                       "a value the account already holds stays")
        for marker in markers(alexScope) { XCTAssertTrue(suite.bool(forKey: marker)) }
        XCTAssertEqual(suite.stringArray(forKey: "player.serverDeviceSettingsMigrationRetired.\(alexScope)"),
                       ["player.hdr_enabled"])
        for marker in markers(legacy) { XCTAssertNil(suite.object(forKey: marker)) }
        let restored = journal(alexScope).load()
        XCTAssertEqual(restored[.playerHdrEnabled]?.operation, .set(.bool(false)))
        XCTAssertEqual(restored[.playerHdrEnabled]?.scopeIdentifier, alexScope,
                       "a queued write is rebound to the scope that now sends it")
        XCTAssertTrue(journal(legacy).load().isEmpty)
        XCTAssertTrue(journal(samScope).load().isEmpty)
    }

    // MARK: - Queued settings writes

    /// Alex is signed in to Home with profile `default`; sam's sign-in on
    /// the same server, also with a `default` profile, comes next.
    private func signedInAsAlex() async throws -> F {
        let f = try F.make(self)
        try f.startUserModel()
        await f.activate(F.home, url: F.homeURL)
        try await f.install(Self.alex, access: "alex-access", refresh: "alex-refresh", placement: .newUser)
        await f.store.setProfileId("default")
        return f
    }

    private func switchToSam(_ f: F) async throws {
        await f.store.select(serverID: F.home, credential: .none, userID: nil)
        try await f.install(Self.sam, access: "sam-access", refresh: "sam-refresh", placement: .newUser)
        await f.store.setProfileId("default")
    }

    /// What `activeRequestIdentity()` builds in the app, from the fixture's
    /// mirrors.
    private func activeIdentity(_ f: F) -> @MainActor () -> HTTPRequestIdentity? {
        {
            guard let profile = f.defaults.string(forKey: SharedStorage.profileIdKey) else { return nil }
            return HTTPRequestIdentity(serverId: F.home, serverURL: F.homeURL, profileId: profile,
                                       clientFamily: AppleDeviceIdentity.current.clientFamily,
                                       accountID: AccountScopeReader.currentAccountID(defaults: f.defaults))
        }
    }

    /// Queues `write` under alex, signs sam in while it waits, then lets it
    /// go: TokenStore must refuse it.
    private func assertWriteQueuedForAlexIsRefusedForSam(
        _ f: F,
        _ transport: AccountBoundSettingsTransport,
        write: () -> Void,
        settle: () async -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        transport.holdsWrites = true
        write()
        await transport.waitForHeldWrite()
        try await switchToSam(f)
        await transport.releaseWrites()
        await settle()
        XCTAssertEqual(transport.sent, [], "nothing went out as sam", file: file, line: line)
        XCTAssertEqual(transport.refused.map(\.accountID), [Self.alex], file: file, line: line)
        XCTAssertEqual(transport.refused.map(\.profileId), ["default"], file: file, line: line)
    }

    func testQueuedSeekIntervalWrite() async throws {
        let f = try await signedInAsAlex()
        let transport = AccountBoundSettingsTransport(values: Self.seekValues(back: 10), tokens: f.store)
        let store = SeekIntervalPreferences(defaults: defaults, transport: transport, requestIdentity: activeIdentity(f))
        await store.refresh()
        XCTAssertTrue(store.allowsEditing)
        try await assertWriteQueuedForAlexIsRefusedForSam(f, transport,
            write: { store.setInterval(45, media: .video, direction: .forward) },
            settle: { await store.waitForPendingWrites() })
    }

    func testQueuedTitleArtWrite() async throws {
        let f = try await signedInAsAlex()
        let transport = AccountBoundSettingsTransport(values: ["ui.title_art": true], tokens: f.store)
        let store = TitleArtPreferences(defaults: defaults, transport: transport, requestIdentity: activeIdentity(f))
        await store.refresh()
        XCTAssertTrue(store.allowsEditing)
        try await assertWriteQueuedForAlexIsRefusedForSam(f, transport,
            write: { store.setShowTitleArt(false) },
            settle: { await store.waitForPendingWrites() })
    }

    func testQueuedEpisodeSpoilerWrite() async throws {
        let f = try await signedInAsAlex()
        let transport = AccountBoundSettingsTransport(values: [
            "catalog.hide_unwatched_episode_images": false,
            "catalog.hide_unwatched_episode_overviews": false,
        ], tokens: f.store)
        let store = EpisodeSpoilerPreferences(defaults: defaults, transport: transport, requestIdentity: activeIdentity(f))
        await store.refresh()
        XCTAssertTrue(store.allowsEditing)
        try await assertWriteQueuedForAlexIsRefusedForSam(f, transport,
            write: { store.set(.images, to: true) },
            settle: { await store.waitForPendingWrites() })
    }

    func testAdvisoryAgeWrite() async throws {
        let f = try await signedInAsAlex()
        let transport = AccountBoundSettingsTransport(values: ["catalog.show_advisory_age": false], tokens: f.store)
        let store = AdvisoryAgePreferenceStore(transport: transport, requestIdentity: activeIdentity(f))
        await store.refresh()
        XCTAssertTrue(store.isSupported)
        var pending: Task<Void, Never>?
        try await assertWriteQueuedForAlexIsRefusedForSam(f, transport,
            write: { pending = Task { await store.setShowsAdvisoryAge(true) } },
            settle: { await pending?.value })
    }

    func testQueuedUICustomizationWrite() async throws {
        let f = try await signedInAsAlex()
        let transport = FakeUICustomizationTransport(effectiveResponse: FakeUICustomizationTransport.emptyResponse)
        let identity = activeIdentity(f)
        let store = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: {
                identity().map {
                    AccountScopedKeyAdoption.key("silo.uiCustomization", serverID: $0.serverId, accountID: $0.accountID,
                                                 profileID: $0.profileId, suffix: $0.clientFamily)
                }
            },
            requestIdentity: identity,
            initialCapabilityState: .supported
        )
        await transport.hold(.puts)
        store.setCardPresentation(CardPresentationPreset.artworkOnly.presentation)
        await transport.waitForStarted(.put, count: 1)
        try await switchToSam(f)
        await transport.release(.puts)
        await store.waitForPendingSaves()

        // The outbox pins the identity it was queued under, account included,
        // and TokenStore refuses that identity while sam is signed in.
        let puts = await transport.calls(.put)
        let queued = try XCTUnwrap(puts.first?.identity)
        XCTAssertEqual(queued.accountID, Self.alex)
        do {
            _ = try await f.store.captureRequestAuth(expected: queued)
            XCTFail("a write queued for alex went out as sam")
        } catch HTTPError.requestIdentityChanged {}
    }

    /// The path every settings read and write takes: `APIv2Client` passes the
    /// caller's account on to `HTTPClient`, whose `captureRequestAuth`
    /// refuses it under another sign-in with the same profile ID.
    func testSettingsReadAndWriteCapturedForOneAccountAreRefusedForAnother() async throws {
        let f = try await signedInAsAlex()
        let stub = StubURLProtocol.Handler()
        stub.route({ $0.path.hasPrefix("/api/v2/settings/") }) { _ in .json("{}") }
        let api = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: f.store),
                              tokenStore: f.store, isUpdateRequired: { false })
        let alexIdentity = try XCTUnwrap(activeIdentity(f)())
        XCTAssertEqual(alexIdentity.accountID, Self.alex)

        _ = try await api.settingsRead("/api/v2/settings/values/effective", expectedIdentity: alexIdentity)
        _ = try await api.settingsWrite("PUT", path: "/api/v2/settings/values/ui.title_art", query: [:], body: nil,
                                        profileID: "default", expectedIdentity: alexIdentity)
        XCTAssertEqual(stub.requests.count, 2)

        try await switchToSam(f)
        do {
            _ = try await api.settingsRead("/api/v2/settings/values/effective", expectedIdentity: alexIdentity)
            XCTFail("a read captured for alex went out as sam")
        } catch HTTPError.requestIdentityChanged {}
        do {
            _ = try await api.settingsWrite("PUT", path: "/api/v2/settings/values/ui.title_art", query: [:], body: nil,
                                            profileID: "default", expectedIdentity: alexIdentity)
            XCTFail("a write captured for alex went out as sam")
        } catch HTTPError.requestIdentityChanged {}
        XCTAssertEqual(stub.requests.count, 2, "neither reached the server")

        let samIdentity = try XCTUnwrap(activeIdentity(f)())
        XCTAssertEqual(samIdentity.accountID, Self.sam)
        _ = try await api.settingsWrite("PUT", path: "/api/v2/settings/values/ui.title_art", query: [:], body: nil,
                                        profileID: "default", expectedIdentity: samIdentity)
        XCTAssertEqual(stub.requests.last?.headers["authorization"], "Bearer sam-access")
    }
}

// MARK: - Helpers

private func effectiveResponse(_ values: [String: Any]) throws -> EffectiveSettingValuesResponse {
    let rows: [[String: Any]] = values.sorted { $0.key < $1.key }.map { key, value in
        ["key": key, "value": value, "source": "profile"]
    }
    let data = try JSONSerialization.data(withJSONObject: ["items": rows, "revision": 1])
    return try SettingsWireCoding.makeDecoder().decode(EffectiveSettingValuesResponse.self, from: data)
}

/// A settings server for the profile-scoped, title art, and advisory age
/// stores. Reads answer `values` for the keys asked. With `tokens`, a write
/// goes out only once `TokenStore.captureRequestAuth` accepts its identity,
/// as `HTTPClient` sends it; `holdsWrites` parks writes until released.
@MainActor
private final class AccountBoundSettingsTransport: ProfileScopedSettingTransport, TitleArtTransport,
    AdvisoryAgePreferenceTransport, @unchecked Sendable {
    var values: [String: Any]
    var holdsWrites = false
    private let tokens: TokenStore?
    private let gate = StubURLProtocol.Gate()
    private(set) var sent: [HTTPRequestIdentity] = []
    private(set) var refused: [HTTPRequestIdentity] = []

    init(values: [String: Any], tokens: TokenStore? = nil) {
        self.values = values
        self.tokens = tokens
    }

    func waitForHeldWrite() async {
        let deadline = Date().addingTimeInterval(5)
        while await gate.waiterCount == 0, Date() < deadline {
            await Task.yield()
        }
    }

    func releaseWrites() async {
        await gate.open()
    }

    nonisolated func contractCapabilities(requestIdentity: HTTPRequestIdentity) async -> SettingsCapabilitiesResult {
        .available(APIv2SettingsContractCapabilities(
            revision: "capabilities-99",
            state: "available",
            allowed: true,
            manifestRevision: 99,
            clientFamilies: ["tv", "mobile", "tablet", "desktop", "web"],
            supportsBatchedEffective: true,
            supportsAtomicShortcuts: true
        ))
    }

    nonisolated func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        let values = await MainActor.run { self.values }
        let wanted = Set(keys.map(\.rawValue))
        return try effectiveResponse(values.filter { wanted.contains($0.key) })
    }

    nonisolated func effectiveValue(requestIdentity: HTTPRequestIdentity) async throws -> EffectiveSettingValuesResponse {
        try await effectiveValues(keys: [.catalogShowAdvisoryAge], requestIdentity: requestIdentity)
    }

    nonisolated func putProfileValue(key: SettingKey, value: SettingJSONValue,
                                     requestIdentity: HTTPRequestIdentity) async throws {
        try await send(requestIdentity)
    }

    nonisolated func putValue(key: SettingKey, scope: SettingScopeIdentity, value: SettingJSONValue,
                              requestIdentity: HTTPRequestIdentity) async throws {
        try await send(requestIdentity)
    }

    nonisolated func deleteValue(key: SettingKey, scope: SettingScopeIdentity,
                                 requestIdentity: HTTPRequestIdentity) async throws {
        try await send(requestIdentity)
    }

    nonisolated func putValue(_ enabled: Bool, requestIdentity: HTTPRequestIdentity) async throws {
        try await send(requestIdentity)
    }

    nonisolated private func send(_ identity: HTTPRequestIdentity) async throws {
        let (holds, tokens) = await MainActor.run { (self.holdsWrites, self.tokens) }
        if holds { await gate.wait() }
        do {
            if let tokens { _ = try await tokens.captureRequestAuth(expected: identity) }
            await MainActor.run { self.sent.append(identity) }
        } catch {
            await MainActor.run { self.refused.append(identity) }
            throw error
        }
    }
}
