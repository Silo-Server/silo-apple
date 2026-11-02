import XCTest
@testable import Silo

@MainActor
final class UICustomizationPreferencesTests: XCTestCase {
    func testPosterSizeAdjustsTVGridDensityAndArtworkScale() {
        XCTAssertEqual(
            AdaptiveColumns.tvPosterCount(standardCount: 6, posterSize: .compact),
            6
        )
        XCTAssertEqual(
            AdaptiveColumns.tvPosterCount(standardCount: 6, posterSize: .standard),
            6
        )
        XCTAssertEqual(
            AdaptiveColumns.tvPosterCount(standardCount: 6, posterSize: .large),
            5
        )
        XCTAssertEqual(
            AdaptiveColumns.tvPosterCount(standardCount: 3, posterSize: .large),
            3
        )
        XCTAssertEqual(CardPosterSize.compact.scale, 0.86, accuracy: 0.001)
        XCTAssertEqual(CardPosterSize.standard.scale, 1, accuracy: 0.001)
        XCTAssertEqual(CardPosterSize.large.scale, 1.2, accuracy: 0.001)
    }

    func testVisibleRootChangesOnlyRearmTheAffectedFocusOwner() {
        XCTAssertEqual(
            tvVisibleRootsFocusRearm(
                menuOwnedFocus: false,
                isShowingRoot: true,
                selectedRootWasRemoved: false
            ),
            .none,
            "reordering an unrelated root must preserve the currently focused card"
        )
        XCTAssertEqual(
            tvVisibleRootsFocusRearm(
                menuOwnedFocus: false,
                isShowingRoot: true,
                selectedRootWasRemoved: true
            ),
            .content,
            "removing content's selected root must hand focus to the Home content"
        )
        XCTAssertEqual(
            tvVisibleRootsFocusRearm(
                menuOwnedFocus: true,
                isShowingRoot: true,
                selectedRootWasRemoved: false
            ),
            .topMenu,
            "a changing focus graph must explicitly re-arm the top menu when it owns focus"
        )
        XCTAssertEqual(
            tvVisibleRootsFocusRearm(
                menuOwnedFocus: true,
                isShowingRoot: false,
                selectedRootWasRemoved: true
            ),
            .none,
            "a pushed route must not re-arm hidden root content"
        )
    }

    func testCardAccessibilityLabelsRetainHiddenIdentityAndStatus() {
        XCTAssertEqual(
            mediaCardAccessibilityLabel(
                title: "The Episode",
                episodeLabel: "S2 · E10",
                year: 2026,
                isWatched: true
            ),
            "The Episode, S2 · E10, 2026, Watched"
        )
        XCTAssertEqual(
            episodeRailAccessibilityLabel(
                seasonNumber: 2,
                episodeNumber: 10,
                title: "The Episode",
                metadata: "Aug 3 · 52m",
                isCurrent: true,
                isPlayed: true
            ),
            "Season 2, Episode 10, The Episode, Aug 3 · 52m, Now viewing, Watched"
        )
    }

    func testSpecializedCardAccessibilityLabelsIncludeOverlayMetadata() {
        let event = CalendarEvent(
            contentId: "event-1",
            type: "episode",
            title: "The Show",
            episodeTitle: "Finale",
            seriesId: "series-1",
            seasonNumber: 1,
            episodeNumber: 8,
            airDate: nil,
            airTime: nil,
            airAt: nil,
            airTimezone: nil,
            localAirDate: nil,
            posterUrl: nil,
            posterThumbhash: nil,
            watched: true,
            badges: ["series_premiere", "finale"]
        )
        XCTAssertEqual(
            calendarEventAccessibilityLabel(event),
            "The Show, S1 · E8, Finale, PREMIERE, FINALE, Watched"
        )

        let collection = LibraryCollection(
            id: "collection-1",
            name: "Favorites",
            collectionType: "movies",
            itemCount: 12
        )
        XCTAssertEqual(
            libraryCollectionAccessibilityLabel(collection),
            "Favorites, Movies, 12 items"
        )
        XCTAssertEqual(
            libraryCollectionAccessibilityLabel(
                LibraryCollection(id: "empty", name: "Empty", itemCount: 0)
            ),
            "Empty, Collection, 0 items"
        )

        let audiobook = AudiobookRelatedItem(
            contentId: "book-1",
            title: "The Next Book",
            year: 2024,
            posterUrl: nil,
            seriesIndex: 3
        )
        XCTAssertEqual(
            audiobookRelatedItemAccessibilityLabel(audiobook),
            "The Next Book, Book 3, 2024"
        )

        let movie = CalendarEvent(
            contentId: "movie-1",
            type: "movie",
            title: "The Movie",
            episodeTitle: nil,
            seriesId: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            airDate: nil,
            airTime: nil,
            airAt: nil,
            airTimezone: nil,
            localAirDate: nil,
            posterUrl: nil,
            posterThumbhash: nil,
            watched: false,
            badges: nil
        )
        XCTAssertEqual(calendarEventAccessibilityLabel(movie), "The Movie, Movie")
    }

    func testCustomizationModelsUseTheExactSettingsContractShape() throws {
        // caption is retired but still required: always written as
        // title_metadata, and a stored value from an older client is ignored.
        let cards = CardPresentationPreference(posterSize: .large)
        XCTAssertEqual(
            String(data: try SettingsWireCoding.makeEncoder().encode(cards), encoding: .utf8),
            #"{"caption":"title_metadata","poster_size":"large"}"#
        )
        XCTAssertEqual(
            try SettingsWireCoding.makeDecoder().decode(
                CardPresentationPreference.self,
                from: Data(#"{"poster_size":"large","caption":"artwork"}"#.utf8)
            ),
            cards
        )
    }

    func testLibraryTabRequestUsesTheFirstLibraryRowWhenTheAggregateRootIsHidden() {
        // The Mac sidebar lists each library instead of one Libraries row.
        let macDestinations: [MainTabDestination] = [
            .app(.home),
            .library(id: 8, label: "Films"),
            .library(id: 9, label: "Shows"),
            .app(.downloads),
        ]
        XCTAssertEqual(
            resolvedRequestedMainTabDestination(
                .libraries,
                visibleDestinations: macDestinations
            ),
            .library(8)
        )
        XCTAssertEqual(
            resolvedRequestedMainTabDestination(
                .libraries,
                visibleDestinations: mainTabDestinations(downloadsEnabled: false)
            ),
            .app(.libraries)
        )
        XCTAssertEqual(
            resolvedRequestedMainTabDestination(
                .libraries,
                visibleDestinations: [.app(.home), .app(.downloads)]
            ),
            .app(.home)
        )
    }

    func testMainTabLibrarySnapshotRejectsPreviousProfileWithOverlappingId() throws {
        let serverId = "server"
        let firstProfile = try XCTUnwrap(
            MainTabLibraryAuthority(serverId: serverId, profileId: "profile-a")
        )
        let secondProfile = try XCTUnwrap(
            MainTabLibraryAuthority(serverId: serverId, profileId: "profile-b")
        )
        let library = Library(
            id: 7,
            name: "Same Numeric ID",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )

        let staleSnapshot = MainTabLibrarySnapshot(
            authority: firstProfile,
            libraries: [library]
        )
        XCTAssertTrue(
            staleSnapshot.availableLibraries(for: secondProfile).isEmpty,
            "a previous profile's library must stay hidden"
        )

        let currentSnapshot = MainTabLibrarySnapshot(
            authority: secondProfile,
            libraries: [library]
        )
        XCTAssertEqual(currentSnapshot.availableLibraries(for: secondProfile), [library])
    }

    func testMixedLibraryMatchesBothVideoCategories() {
        let mixed = Library(
            id: 3,
            name: "Mixed",
            type: "mixed",
            sortOrder: 0,
            posterUrl: nil
        )

        XCTAssertTrue(LibraryMediaCategory.movies.matches(mixed))
        XCTAssertTrue(LibraryMediaCategory.series.matches(mixed))
        XCTAssertFalse(LibraryMediaCategory.audiobooks.matches(mixed))
        XCTAssertEqual(mixed.navigationIcon, "square.stack.3d.up")
        XCTAssertEqual(mixed.selectedNavigationIcon, "square.stack.3d.up.fill")
    }

    func testMixedLibraryRootOnlySwitchesAmongMixedLibraries() {
        let mixed = Library(
            id: 1, name: "Mixed A", type: "mixed", sortOrder: 0, posterUrl: nil
        )
        let otherMixed = Library(
            id: 2, name: "Mixed B", type: "mixed", sortOrder: 1, posterUrl: nil
        )
        let movies = Library(
            id: 3, name: "Movies", type: "movies", sortOrder: 2, posterUrl: nil
        )
        let series = Library(
            id: 4, name: "Series", type: "series", sortOrder: 3, posterUrl: nil
        )

        XCTAssertEqual(
            visibleLibrariesForRoot(
                [mixed, otherMixed, movies, series],
                fixedLibraryId: mixed.id,
                showAudiobooks: true
            ).map(\.id),
            [mixed.id, otherMixed.id]
        )
    }

    func testDirectLibraryRootUsesExactAccessibleLibraryAndFixedChrome() {
        let first = Library(id: 7, name: "First", type: "movies", sortOrder: 0, posterUrl: nil)
        let second = Library(id: 8, name: "Second", type: "series", sortOrder: 1, posterUrl: nil)

        XCTAssertEqual(
            visibleLibrariesForRoot(
                [first, second],
                fixedLibraryId: second.id,
                showAudiobooks: true
            ),
            [second]
        )
        XCTAssertTrue(
            visibleLibrariesForRoot(
                [first, second],
                fixedLibraryId: 99,
                showAudiobooks: true
            ).isEmpty,
            "an inaccessible library ID must not fall through to another library"
        )

        XCTAssertEqual(
            resolvedLibraryIdForRoot(
                [first, second],
                fixedLibraryId: first.id,
                showAudiobooks: true,
                storedLibraryId: second.id
            ),
            first.id
        )
        XCTAssertEqual(
            resolvedLibraryIdForRoot(
                [first, second],
                fixedLibraryId: second.id,
                showAudiobooks: true,
                storedLibraryId: first.id
            ),
            second.id,
            "changing a reused fixed-root scope must immediately select the new exact library"
        )

        let sibling = Library(
            id: 9, name: "Sibling", type: "series", sortOrder: 2, posterUrl: nil
        )
        XCTAssertEqual(
            resolvedLibraryIdForRoot(
                [first, second, sibling],
                fixedLibraryId: second.id,
                showAudiobooks: true,
                storedLibraryId: 0,
                currentSelectionId: sibling.id
            ),
            sibling.id,
            "an in-session switch to a same-type sibling must survive re-resolution"
        )
        XCTAssertEqual(
            resolvedLibraryIdForRoot(
                [first, second, sibling],
                fixedLibraryId: second.id,
                showAudiobooks: true,
                storedLibraryId: 0,
                currentSelectionId: first.id
            ),
            second.id,
            "a selection outside the root scope must fall back to the root's library"
        )
    }

    func testOnlyTheLibrariesTabPersistsItsSelection() throws {
        XCTAssertEqual(
            librarySelectionStorageKey(fixedLibraryId: nil),
            "librariesTabSelectedLibraryId"
        )
        XCTAssertNil(
            librarySelectionStorageKey(fixedLibraryId: 7),
            "a fixed root derives its selection from the destination and must not persist it"
        )

        let suiteName = "library-selection-suite-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        XCTAssertEqual(storedLibrarySelectionId(for: nil, defaults: defaults), 0)
        defaults.set(8, forKey: "librariesTabSelectedLibraryId")
        XCTAssertEqual(
            storedLibrarySelectionId(for: "librariesTabSelectedLibraryId", defaults: defaults),
            8
        )
    }

    func testHiddenRequestedTabFallsBackToHomeAfterMenuReordering() {
        let visible = [
            MainTabDestination.app(.calendar),
            MainTabDestination.library(id: 7, label: "Movies"),
            MainTabDestination.app(.home),
        ]

        XCTAssertEqual(
            resolvedRequestedMainTabDestination(
                .recommendations,
                visibleDestinations: visible
            ),
            .app(.home)
        )
        XCTAssertEqual(
            resolvedRequestedMainTabDestination(.calendar, visibleDestinations: visible),
            .app(.calendar)
        )
    }

    func testCacheFromBeforeMenuRemovalKeepsCardsAndDropsMenuChanges() async throws {
        let suiteName = "ui-customization-legacy-menu-cache-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-legacy-menu-cache-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        // A cache written while Apple clients still synced the top menu: menu
        // and shortcut members plus queued, held menu changes.
        let cacheKey = "silo.uiCustomization.server.profile.mobile"
        let item: [String: Any] = ["type": "library", "library_id": 7, "label": "Films"]
        let held: [String: Any] = ["failedAttempts": 6, "isHeld": true]
        let cache: [String: Any] = [
            "primaryMenu": ["items": [["type": "builtin", "destination": "home"], item]],
            "primaryMenuSource": "profile_device",
            "shortcuts": ["items": [item]],
            "cardPresentation": [
                "poster_size": "large",
                "caption": "title_metadata",
            ],
            "cardPresentationSource": "profile_client",
            "supportProjection": "supported",
            "pendingSyncWrites": [
                SettingKey.navPrimaryMenu.rawValue: [
                    "value": ["items": [["type": "builtin", "destination": "home"]]],
                    "operationId": "menu-write",
                    "retry": held,
                ],
            ],
            "pendingShortcutOperations": [
                "library|7": [
                    "item": item,
                    "present": true,
                    "operationId": "pin",
                    "sequence": 1,
                    "retry": held,
                ],
            ],
            "pendingShortcutPlacementBlockedIds": ["library|7"],
            "pendingDeletes": [
                "\(SettingKey.navPrimaryMenu.rawValue)|profile_device": [
                    "scope": "profile_device",
                    "operationId": "menu-delete",
                    "retry": held,
                ],
            ],
        ]
        let defaults = SharedDefaults(suite: suite, standard: standard)
        defaults.set(
            try JSONSerialization.data(withJSONObject: cache, options: [.sortedKeys]),
            forKey: cacheKey
        )

        let transport = FakeUICustomizationTransport(rows: [
            try .init(.uiCardPresentation, .profileClient, encoding: CardPresentationPreference(posterSize: .large)),
        ])
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) }
        )
        XCTAssertEqual(preferences.cardPresentation, CardPresentationPreference(posterSize: .large))
        XCTAssertTrue(preferences.cardPresentationUsesFamilyOverride)
        XCTAssertFalse(preferences.hasHeldChanges, "held top-menu changes are dropped, not shown")

        await preferences.refresh()

        let writes = await transport.calls(.write)
        XCTAssertTrue(writes.isEmpty, "nothing queued for the top menu is sent")
        XCTAssertEqual(preferences.cardPresentation, CardPresentationPreference(posterSize: .large))
        XCTAssertNil(preferences.syncErrorMessage)
    }

    func testRapidEditsAreWrittenInOrderAndSavingCoversTheWholeQueue() async throws {
        let suiteName = "ui-customization-writes-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-writes-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let transport = FakeUICustomizationTransport(
            effectiveResponse: FakeUICustomizationTransport.emptyResponse
        )
        await transport.hold(.puts)
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { "silo.uiCustomization.server.profile.mobile" },
            requestIdentity: { testRequestIdentity(family: "mobile") },
            initialCapabilityState: .supported
        )

        preferences.setCardPresentation(CardPresentationPreference(posterSize: .compact))
        preferences.setCardPresentation(CardPresentationPreference(posterSize: .large))
        XCTAssertTrue(preferences.isSaving)

        let release = Task {
            await transport.waitForStarted(.put, count: 1)
            try? await Task.sleep(nanoseconds: 50_000_000)
            await transport.release(.puts)
        }
        await transport.waitForCompleted(.put, count: 2)
        await release.value
        await preferences.waitForPendingSaves()

        let values = await transport.calls(.put).compactMap(\.value)
        let maxConcurrentWrites = await transport.maxConcurrentWrites
        let presentations = try values.map {
            try $0.decoded(as: CardPresentationPreference.self)
        }
        XCTAssertEqual(maxConcurrentWrites, 1, "writes must never overtake one another")
        XCTAssertEqual(
            presentations,
            [
                CardPresentationPreference(posterSize: .compact),
                CardPresentationPreference(posterSize: .large),
            ]
        )
        XCTAssertFalse(preferences.isSaving, "saving ends only after the queue drains")
    }

    func testCardPresentationAndOutboxShareOneDurableCacheSnapshot() async throws {
        let suiteName = "ui-customization-card-cache-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-card-cache-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let cacheKey = "silo.uiCustomization.server.profile.mobile"
        let transport = FakeUICustomizationTransport(
            effectiveResponse: FakeUICustomizationTransport.emptyResponse
        )
        await transport.hold(.puts)
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        let desired = CardPresentationPreference(posterSize: .large)

        preferences.setCardPresentation(desired)
        await transport.waitForStarted(.put, count: 1)

        let cachedData = try XCTUnwrap(defaults.data(forKey: cacheKey))
        let cache = try XCTUnwrap(
            JSONSerialization.jsonObject(with: cachedData) as? [String: Any]
        )
        let card = try XCTUnwrap(cache["cardPresentation"] as? [String: Any])
        let pending = try XCTUnwrap(cache["pendingSyncWrites"] as? [String: Any])
        XCTAssertEqual(card["poster_size"] as? String, "large")
        XCTAssertNotNil(pending[SettingKey.uiCardPresentation.rawValue])

        await transport.release(.puts)
        await transport.waitForCompleted(.put, count: 1)
    }

    func testOfflineWriteIsDurablyReplayedBeforeEffectiveRefresh() async throws {
        let suiteName = "ui-customization-outbox-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-outbox-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let transport = FakeUICustomizationTransport(rows: [
            try .init(.uiCardPresentation, .profileClient, encoding: CardPresentationPreference.standard),
        ])
        await transport.fail(.puts)
        let cacheKey = "silo.uiCustomization.server.profile.mobile"
        let offline = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        let desired = CardPresentationPreference(posterSize: .large)

        offline.setCardPresentation(desired)
        await transport.waitForStarted(.put, count: 1)
        await transport.stopFailing(.puts)

        // A fresh store proves the failed write was journaled in the cache,
        // not merely retained by the first in-memory instance.
        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        XCTAssertEqual(restarted.cardPresentation, desired)

        await restarted.refresh()

        let steps = await transport.steps()
        let writtenValues = await transport.calls(.put).compactMap(\.value)
        let storedPresentation = await transport.stored(
            .uiCardPresentation,
            at: .profileClient,
            as: CardPresentationPreference.self
        )
        XCTAssertEqual(steps, [
            .put(.uiCardPresentation, .failed),
            .put(.uiCardPresentation, .succeeded),
            .read(.succeeded),
        ])
        XCTAssertEqual(
            writtenValues,
            Array(repeating: try SettingJSONValue.encoding(desired), count: 2),
            "a connectivity retry sends the same desired value again"
        )
        XCTAssertEqual(storedPresentation, desired)
        XCTAssertEqual(restarted.cardPresentation, desired)
        XCTAssertNil(restarted.syncErrorMessage)
    }

    /// Owner decision D4: a value write is retried on a bounded backoff, then
    /// held. A held change stays on screen, is not replayed by a refresh, and
    /// goes away only through "Discard Held Change" or "Try Again".
    func testWriteIsHeldAfterItsRetryBoundAndCanBeDiscarded() async throws {
        let suiteName = "ui-customization-held-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-held-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let transport = FakeUICustomizationTransport(rows: [
            try .init(.uiCardPresentation, .profileClient, encoding: CardPresentationPreference.standard),
        ])
        await transport.fail(.puts)
        let cacheKey = "silo.uiCustomization.server.profile.mobile"
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported,
            writeRetryPolicy: .init(maximumAutomaticRetries: 2, base: .milliseconds(5), maximum: .milliseconds(5))
        )
        let desired = CardPresentationPreference(posterSize: .large)

        preferences.setCardPresentation(desired)
        await transport.waitForStarted(.put, count: 3)
        for _ in 0..<200 where !preferences.hasHeldChanges {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(preferences.hasHeldChanges, "the change is held once the bound runs out")
        XCTAssertEqual(preferences.syncErrorMessage, HeldSettingChange.message)
        XCTAssertFalse(preferences.hasArmedOutboxRetry, "no retry after the bound")
        let heldSteps = await transport.steps()
        XCTAssertEqual(
            heldSteps,
            [
                .put(.uiCardPresentation, .failed),
                .put(.uiCardPresentation, .failed),
                .put(.uiCardPresentation, .failed),
            ],
            "no retry after the bound"
        )

        // Online again: a refresh reads the other keys but neither replays
        // the held change nor paints the server's older value over it.
        await transport.stopFailing(.puts)
        await preferences.refresh()
        let refreshedSteps = await transport.steps()
        XCTAssertEqual(refreshedSteps, [
            .put(.uiCardPresentation, .failed),
            .put(.uiCardPresentation, .failed),
            .put(.uiCardPresentation, .failed),
            .read(.succeeded),
        ])
        XCTAssertEqual(preferences.cardPresentation, desired)
        XCTAssertTrue(preferences.hasHeldChanges)

        // The hold survives a restart.
        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        XCTAssertTrue(restarted.hasHeldChanges)

        await restarted.discardHeldChanges()
        let storedPresentation = await transport.stored(
            .uiCardPresentation,
            at: .profileClient,
            as: CardPresentationPreference.self
        )
        XCTAssertFalse(restarted.hasHeldChanges)
        XCTAssertEqual(restarted.cardPresentation, .standard, "discarding repaints what the server holds")
        XCTAssertEqual(storedPresentation, .standard, "discarding sends nothing")
        XCTAssertNil(restarted.syncErrorMessage)
    }

    func testTryAgainSendsAHeldChangeWithAFreshBudget() async throws {
        let suiteName = "ui-customization-held-retry-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-held-retry-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let transport = FakeUICustomizationTransport(rows: [
            try .init(.uiCardPresentation, .profileClient, encoding: CardPresentationPreference.standard),
        ])
        await transport.fail(.puts)
        let cacheKey = "silo.uiCustomization.server.profile.mobile"
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported,
            writeRetryPolicy: .init(maximumAutomaticRetries: 0)
        )
        let desired = CardPresentationPreference(posterSize: .large)

        preferences.setCardPresentation(desired)
        await transport.waitForStarted(.put, count: 1)
        for _ in 0..<200 where !preferences.hasHeldChanges {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(preferences.hasHeldChanges)

        await transport.stopFailing(.puts)
        preferences.retryHeldChanges()
        await transport.waitForStarted(.put, count: 2)
        for _ in 0..<200 where preferences.hasHeldChanges {
            try await Task.sleep(for: .milliseconds(5))
        }

        let steps = await transport.steps()
        let storedPresentation = await transport.stored(
            .uiCardPresentation,
            at: .profileClient,
            as: CardPresentationPreference.self
        )
        XCTAssertEqual(steps, [
            .put(.uiCardPresentation, .failed),
            .put(.uiCardPresentation, .succeeded),
        ])
        XCTAssertEqual(storedPresentation, desired)
        XCTAssertFalse(preferences.hasHeldChanges)
        XCTAssertNil(preferences.syncErrorMessage)
    }

    func testUnavailableOrOldCapabilitiesDoNotDrainRevisionFiveOutbox() async throws {
        let suiteName = "ui-customization-capability-gate-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-capability-gate-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let cacheKey = "silo.uiCustomization.server.profile.mobile"
        let transport = FakeUICustomizationTransport(
            capabilities: .failed(.transport(description: "offline")),
            effectiveResponse: FakeUICustomizationTransport.emptyResponse
        )
        await transport.fail(.puts)
        let desired = CardPresentationPreference(posterSize: .large)
        let authored = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )

        authored.setCardPresentation(desired)
        await transport.waitForStarted(.put, count: 1)

        let unavailable = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) }
        )
        await unavailable.refresh()

        var putAttempts = await transport.calls(.put).count
        var effectiveReads = await transport.calls(.read).count
        XCTAssertEqual(unavailable.capabilityState, .unavailable)
        XCTAssertEqual(unavailable.supportProjection, .unknown)
        XCTAssertFalse(unavailable.allowsEditing)
        XCTAssertEqual(unavailable.cardPresentation, desired)
        XCTAssertEqual(putAttempts, 1)
        XCTAssertEqual(effectiveReads, 0)

        // A server that answers "settings are not available here" (disabled,
        // not configured, or not allowed) says nothing about its version: the
        // cache keeps painting and nothing is sent.
        await transport.setCapabilities(.unavailable)
        await unavailable.refresh()

        putAttempts = await transport.calls(.put).count
        effectiveReads = await transport.calls(.read).count
        XCTAssertEqual(unavailable.capabilityState, .unavailable)
        XCTAssertEqual(unavailable.supportProjection, .unknown)
        XCTAssertFalse(unavailable.allowsEditing)
        XCTAssertEqual(unavailable.cardPresentation, desired)
        XCTAssertEqual(putAttempts, 1)
        XCTAssertEqual(effectiveReads, 0)

        await transport.setCapabilities(.serverUpgradeRequired)
        await unavailable.refresh()

        putAttempts = await transport.calls(.put).count
        effectiveReads = await transport.calls(.read).count
        XCTAssertEqual(unavailable.capabilityState, .serverUpgradeRequired)
        XCTAssertEqual(unavailable.supportProjection, .knownUnsupported)
        XCTAssertEqual(unavailable.cardPresentation, .standard)
        XCTAssertEqual(putAttempts, 1, "a known old server must not receive the outbox")
        XCTAssertEqual(effectiveReads, 0)

        await transport.setCapabilities(.available(FakeUICustomizationTransport.capabilities(batchedEffective: false)))
        await unavailable.refresh()

        putAttempts = await transport.calls(.put).count
        effectiveReads = await transport.calls(.read).count
        XCTAssertEqual(unavailable.capabilityState, .serverUpgradeRequired)
        XCTAssertEqual(unavailable.supportProjection, .knownUnsupported)
        XCTAssertFalse(unavailable.allowsEditing)
        XCTAssertEqual(unavailable.cardPresentation, .standard)
        XCTAssertEqual(
            putAttempts,
            1,
            "the client must not use a multi-key read when the server does not advertise it"
        )
        XCTAssertEqual(effectiveReads, 0)

        await transport.setCapabilities(.failed(.transport(description: "offline again")))
        await unavailable.refresh()

        putAttempts = await transport.calls(.put).count
        effectiveReads = await transport.calls(.read).count
        XCTAssertEqual(unavailable.capabilityState, .unavailable)
        XCTAssertEqual(
            unavailable.supportProjection,
            .knownUnsupported,
            "a later transient probe failure must not forget an explicit incompatibility"
        )
        XCTAssertEqual(unavailable.cardPresentation, .standard)
        XCTAssertEqual(putAttempts, 1)
        XCTAssertEqual(effectiveReads, 0)

        let restartedKnownUnsupported = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) }
        )
        await restartedKnownUnsupported.refresh()
        XCTAssertEqual(restartedKnownUnsupported.capabilityState, .unavailable)
        XCTAssertEqual(restartedKnownUnsupported.supportProjection, .knownUnsupported)
        XCTAssertEqual(restartedKnownUnsupported.cardPresentation, .standard)

        await transport.setCapabilities(.available(FakeUICustomizationTransport.capabilities(clientFamilies: ["tv", "web"])))
        await unavailable.refresh()

        putAttempts = await transport.calls(.put).count
        effectiveReads = await transport.calls(.read).count
        XCTAssertEqual(unavailable.capabilityState, .serverUpgradeRequired)
        XCTAssertFalse(unavailable.allowsEditing)
        XCTAssertEqual(unavailable.cardPresentation, .standard)
        XCTAssertEqual(
            putAttempts,
            1,
            "a server that cannot store this client family's card presentation must not receive the outbox"
        )
        XCTAssertEqual(effectiveReads, 0)
    }

    func testProfileClientCardResetIsDurableAndResolvesInheritedValueAfterRestart() async throws {
        let suiteName = "ui-customization-card-reset-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-card-reset-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let cacheKey = "silo.uiCustomization.server.profile.mobile"
        let transport = FakeUICustomizationTransport(
            rows: [
                try .init(
                    .uiCardPresentation,
                    .profileClient,
                    encoding: CardPresentationPreference(posterSize: .compact)
                ),
            ],
            persistsPuts: false
        )
        await transport.fail(.deletes)
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) }
        )

        await preferences.refresh()
        XCTAssertTrue(preferences.cardPresentationUsesFamilyOverride)
        XCTAssertEqual(preferences.cardPresentation, CardPresentationPreference(posterSize: .compact))

        let mark = await transport.steps().count
        preferences.resetCardPresentationToInherited()
        await transport.waitForStarted(.delete, count: 1)
        await transport.stopFailing(.deletes)

        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) }
        )
        await restarted.refresh()

        let steps = Array(await transport.steps().dropFirst(mark))
        let deleteScopes = await transport.calls(.delete).compactMap(\.scope)
        XCTAssertEqual(steps, [
            .delete(.uiCardPresentation, .profileClient, .failed),
            .delete(.uiCardPresentation, .profileClient, .succeeded),
            .read(.succeeded),
        ])
        XCTAssertEqual(deleteScopes, [.profileClient, .profileClient])
        XCTAssertEqual(restarted.cardPresentation, .standard)
        XCTAssertFalse(restarted.cardPresentationUsesFamilyOverride)
        XCTAssertNil(restarted.syncErrorMessage)
    }

    func testQueuedWriteNeverFollowsAChangedServerProfileIdentity() async throws {
        let suiteName = "ui-customization-identity-race-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-identity-race-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let identity = MutableRequestIdentity(testRequestIdentity(family: "mobile"))
        let transport = FakeUICustomizationTransport(
            effectiveResponse: FakeUICustomizationTransport.emptyResponse
        )
        await transport.hold(.puts)
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { testCacheKey(for: identity.value) },
            requestIdentity: { identity.value },
            initialCapabilityState: .supported
        )

        preferences.setCardPresentation(CardPresentationPreference(posterSize: .compact))
        preferences.setCardPresentation(CardPresentationPreference(posterSize: .large))
        await transport.waitForStarted(.put, count: 1)

        identity.value = HTTPRequestIdentity(
            serverId: "server-b",
            serverURL: "http://server-b.invalid",
            profileId: "profile-b",
            clientFamily: "mobile"
        )
        await transport.release(.puts)
        await preferences.waitForPendingSaves()

        let puts = await transport.calls(.put)
        XCTAssertEqual(puts.map(\.identity), [testRequestIdentity(family: "mobile")])
        XCTAssertEqual(
            puts.compactMap(\.value).count,
            1,
            "queued work for the old cache must be retained, not sent through the new identity"
        )
        XCTAssertFalse(preferences.isSaving)
    }

    func testRefreshPreservesHigherPrecedenceDeviceOverrideSource() async throws {
        let suiteName = "ui-customization-source-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-source-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let response = EffectiveSettingValuesResponse(
            settings: [
                EffectiveSettingValue(
                    key: SettingKey.uiCardPresentation.rawValue,
                    value: try SettingJSONValue.encoding(CardPresentationPreference(posterSize: .compact)),
                    source: .scope(.profileDevice),
                    scope: .profileDevice,
                    profileId: "profile",
                    deviceId: "device"
                ),
            ],
            revision: SettingKey.revision
        )
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: FakeUICustomizationTransport(effectiveResponse: response),
            cacheKey: { "silo.uiCustomization.server.profile.tv" },
            requestIdentity: { testRequestIdentity(family: "tv") },
            initialCapabilityState: .supported
        )

        await preferences.refresh()

        XCTAssertTrue(preferences.cardPresentationUsesDeviceOverride)
        XCTAssertTrue(preferences.hasDeviceOverrides)
    }

    func testFailedDeviceDeleteKeepsTheOverrideAndReplaysAfterRestart() async throws {
        let suiteName = "ui-customization-device-delete-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-device-delete-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let cacheKey = "silo.uiCustomization.server.profile.tv"
        let defaults = SharedDefaults(suite: suite, standard: standard)
        let transport = FakeUICustomizationTransport(
            rows: try deviceOverrideRows(),
            persistsPuts: false
        )
        await transport.fail(.delete(.uiCardPresentation))
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await preferences.refresh()
        XCTAssertTrue(preferences.cardPresentationUsesDeviceOverride)

        preferences.useFamilySettings()
        while preferences.isSaving { await Task.yield() }

        XCTAssertTrue(
            preferences.cardPresentationUsesDeviceOverride,
            "the failed device delete must keep its effective value and source"
        )
        XCTAssertEqual(preferences.cardPresentation, CardPresentationPreference(posterSize: .compact))
        XCTAssertNotNil(preferences.syncErrorMessage)

        await transport.stopFailing()
        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await restarted.refresh()

        let deleteKeys = await transport.calls(.delete).compactMap(\.key)
        XCTAssertEqual(
            deleteKeys,
            [.uiCardPresentation, .uiCardPresentation],
            "restart must replay the failed device delete"
        )
        XCTAssertFalse(restarted.cardPresentationUsesDeviceOverride)
        XCTAssertEqual(restarted.cardPresentation, .standard)
    }

    func testDeviceDeleteReadFailureRemainsDurableUntilRestartReconcilesIt() async throws {
        let suiteName = "ui-customization-device-delete-read-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-device-delete-read-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let cacheKey = "silo.uiCustomization.server.profile.tv"
        let defaults = SharedDefaults(suite: suite, standard: standard)
        let transport = FakeUICustomizationTransport(
            rows: try deviceOverrideRows(),
            persistsPuts: false
        )
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await preferences.refresh()
        // The delete lands, but the read of the value underneath it fails.
        await transport.fail(.reads, times: 1)
        preferences.useFamilySettings()
        while preferences.isSaving { await Task.yield() }

        XCTAssertTrue(
            preferences.cardPresentationUsesDeviceOverride,
            "a successful delete without its inherited value must retain the safe cached pair"
        )
        XCTAssertNotNil(preferences.syncErrorMessage)

        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await restarted.refresh()

        let deleteKeys = await transport.calls(.delete).compactMap(\.key)
        XCTAssertEqual(
            deleteKeys,
            [.uiCardPresentation, .uiCardPresentation],
            "the delete whose effective read failed stays in the durable outbox"
        )
        XCTAssertFalse(restarted.cardPresentationUsesDeviceOverride)
        XCTAssertEqual(restarted.cardPresentation, .standard)
        XCTAssertNil(restarted.syncErrorMessage)
    }

    func testRefreshPreservesAnInvalidValueWithItsPriorSource() async throws {
        let suiteName = "ui-customization-independent-decode-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-independent-decode-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let initialResponse = EffectiveSettingValuesResponse(
            settings: [
                EffectiveSettingValue(
                    key: SettingKey.uiCardPresentation.rawValue,
                    value: try SettingJSONValue.encoding(
                        CardPresentationPreference(posterSize: .compact)
                    ),
                    source: .scope(.profileDevice),
                    scope: .profileDevice,
                    profileId: "profile",
                    deviceId: "device"
                ),
            ],
            revision: SettingKey.revision
        )
        let transport = FakeUICustomizationTransport(effectiveResponse: initialResponse)
        let cacheKey = "silo.uiCustomization.server.profile.mobile"
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await preferences.refresh()

        await transport.setEffectiveResponse(EffectiveSettingValuesResponse(
            settings: [
                EffectiveSettingValue(
                    key: SettingKey.uiCardPresentation.rawValue,
                    value: .object([
                        "poster_size": .string("future-size"),
                        "caption": .string("title"),
                    ]),
                    source: .scope(.profileClient),
                    scope: .profileClient,
                    profileId: "profile",
                    clientFamily: "mobile"
                ),
            ],
            revision: SettingKey.revision
        ))
        await preferences.refresh()

        XCTAssertEqual(preferences.cardPresentation, CardPresentationPreference(posterSize: .compact))
        XCTAssertTrue(
            preferences.cardPresentationUsesDeviceOverride,
            "a failed decode must retain the matching prior source with its prior value"
        )
        XCTAssertNotNil(preferences.syncErrorMessage)

        await transport.setEffectiveResponse(EffectiveSettingValuesResponse(
            settings: [
                EffectiveSettingValue(
                    key: SettingKey.uiCardPresentation.rawValue,
                    value: try SettingJSONValue.encoding(
                        CardPresentationPreference(posterSize: .large)
                    ),
                    source: .scope(.profileClient),
                    scope: .profileClient,
                    profileId: "profile",
                    clientFamily: "mobile"
                ),
            ],
            revision: SettingKey.revision
        ))
        await preferences.refresh()

        XCTAssertEqual(
            preferences.cardPresentation,
            CardPresentationPreference(posterSize: .large)
        )
        XCTAssertFalse(preferences.cardPresentationUsesDeviceOverride)
        XCTAssertNil(preferences.syncErrorMessage)

        let cached = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        XCTAssertEqual(cached.cardPresentation, CardPresentationPreference(posterSize: .large))
        XCTAssertFalse(cached.cardPresentationUsesDeviceOverride)
    }

    func testRefreshReconcilesTheFamilyScopedCacheAndOfflineRestoreKeepsIt() async throws {
        let suiteName = "ui-customization-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let cards = CardPresentationPreference(posterSize: .large)
        let response = EffectiveSettingValuesResponse(
            settings: [
                try effective(.uiCardPresentation, cards, scope: .profileClient),
            ],
            revision: SettingKey.revision
        )
        let defaults = SharedDefaults(suite: suite, standard: standard)
        let cacheKey = "silo.uiCustomization.server.profile.mobile"
        let online = UICustomizationPreferences(
            defaults: defaults,
            transport: FakeUICustomizationTransport(effectiveResponse: response),
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )

        await online.refresh()

        XCTAssertEqual(online.cardPresentation, cards)
        XCTAssertNil(online.syncErrorMessage)

        let offlineTransport = FakeUICustomizationTransport()
        await offlineTransport.fail(.reads)
        let offline = UICustomizationPreferences(
            defaults: defaults,
            transport: offlineTransport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        XCTAssertEqual(offline.cardPresentation, cards)

        await offline.refresh()

        XCTAssertEqual(offline.cardPresentation, cards, "a failed refresh must not erase the cached cards")
        XCTAssertNotNil(offline.syncErrorMessage)
    }

    private func effective<T: Encodable>(
        _ key: SettingKey,
        _ value: T,
        scope: SettingScope
    ) throws -> EffectiveSettingValue {
        EffectiveSettingValue(
            key: key.rawValue,
            value: try SettingJSONValue.encoding(value),
            source: .scope(scope),
            scope: scope,
            profileId: "profile",
            clientFamily: scope == .profileClient ? "mobile" : nil
        )
    }

    /// Server rows where this device overrides the family card presentation.
    private func deviceOverrideRows() throws -> [FakeUICustomizationTransport.Row] {
        [
            try .init(
                .uiCardPresentation,
                .profileDevice,
                encoding: CardPresentationPreference(posterSize: .compact)
            ),
        ]
    }
}

private func testRequestIdentity(family: String) -> HTTPRequestIdentity {
    HTTPRequestIdentity(
        serverId: "server",
        serverURL: "http://settings-test.invalid",
        profileId: "profile",
        clientFamily: family
    )
}

private func testRequestIdentity(for cacheKey: String) -> HTTPRequestIdentity {
    testRequestIdentity(family: cacheKey.split(separator: ".").last.map(String.init) ?? "mobile")
}

private func testCacheKey(for identity: HTTPRequestIdentity) -> String {
    "silo.uiCustomization.\(identity.serverId).\(identity.profileId).\(identity.clientFamily)"
}

private final class MutableRequestIdentity: @unchecked Sendable {
    var value: HTTPRequestIdentity

    init(_ value: HTTPRequestIdentity) {
        self.value = value
    }
}
