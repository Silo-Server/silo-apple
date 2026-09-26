import XCTest
@testable import Silo

@MainActor
final class UICustomizationPreferencesTests: XCTestCase {
    func testNamedPresetsMatchTheCrossClientRecipes() {
        XCTAssertEqual(
            CardPresentationPreset.balanced.presentation,
            .init(posterSize: .standard, caption: .titleMetadata)
        )
        XCTAssertEqual(
            CardPresentationPreset.compact.presentation,
            .init(posterSize: .compact, caption: .title)
        )
        XCTAssertEqual(
            CardPresentationPreset.cinema.presentation,
            .init(posterSize: .large, caption: .title)
        )
        XCTAssertEqual(
            CardPresentationPreset.artworkOnly.presentation,
            .init(posterSize: .large, caption: .artwork)
        )
    }

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

    func testCaptionStylesGateTitleAndMetadataIndependently() {
        XCTAssertTrue(CardCaptionStyle.titleMetadata.showsTitle)
        XCTAssertTrue(CardCaptionStyle.titleMetadata.showsMetadata)
        XCTAssertTrue(CardCaptionStyle.title.showsTitle)
        XCTAssertFalse(CardCaptionStyle.title.showsMetadata)
        XCTAssertFalse(CardCaptionStyle.artwork.showsTitle)
        XCTAssertFalse(CardCaptionStyle.artwork.showsMetadata)
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
            "The Show, S1 · E8, Finale, SERIES PREMIERE, FINALE, Watched"
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
        let cards = CardPresentationPreference(posterSize: .large, caption: .artwork)
        XCTAssertEqual(
            String(data: try SettingsWireCoding.makeEncoder().encode(cards), encoding: .utf8),
            #"{"caption":"artwork","poster_size":"large"}"#
        )

        let menu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .library(libraryId: 7, label: "Movies"),
            .section(libraryId: 7, sectionId: "recently-added", label: "Recently Added"),
            .collection(collectionId: "favorites", label: "Favorites", libraryId: 7),
        ])
        let encoded = try SettingsWireCoding.makeEncoder().encode(menu)
        let decoded = try SettingsWireCoding.makeDecoder().decode(
            PrimaryMenuPreference.self,
            from: encoded
        )

        XCTAssertEqual(decoded, menu)
        XCTAssertTrue(decoded.isValid)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items[0]["type"] as? String, "builtin")
        XCTAssertEqual(items[0]["destination"] as? String, "home")
        XCTAssertEqual(items[1]["library_id"] as? Int, 7)
        XCTAssertEqual(items[2]["section_id"] as? String, "recently-added")
        XCTAssertEqual(items[3]["collection_id"] as? String, "favorites")
    }

    func testCollectionIdentityIsStructuredWithoutChangingTheWireFormat() throws {
        let unscoped = PrimaryMenuItem.collection(
            collectionId: "12:featured",
            label: "Featured",
            libraryId: nil
        )
        let scoped = PrimaryMenuItem.collection(
            collectionId: "featured",
            label: "Featured",
            libraryId: 12
        )
        let renamed = PrimaryMenuItem.collection(
            collectionId: "12:featured",
            label: "Renamed",
            libraryId: nil
        )

        XCTAssertEqual(unscoped.id, "collection|0|0#|11#12:featured")
        XCTAssertEqual(scoped.id, "collection|1|2#12|8#featured")
        XCTAssertNotEqual(unscoped.id, scoped.id)
        XCTAssertEqual(unscoped.id, renamed.id, "a display label is not semantic identity")

        let data = try SettingsWireCoding.makeEncoder().encode(unscoped)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "collection")
        XCTAssertEqual(object["collection_id"] as? String, "12:featured")
        XCTAssertNil(object["library_id"])
        XCTAssertNil(object["id"], "the structured client identity must not enter the wire contract")
    }

    func testMainTabProjectionKeepsLibraryIdentityAndHidesUnsupportedShortcuts() {
        let movie = Library(
            id: 7,
            name: "Renamed Movies",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let series = Library(id: 8, name: "Series", type: "series", sortOrder: 1, posterUrl: nil)
        let audiobook = Library(
            id: 9,
            name: "Audiobooks",
            type: "audiobooks",
            sortOrder: 2,
            posterUrl: nil
        )
        let menu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.movies),
            .builtin(.series),
            .builtin(.music),
            .builtin(.audiobooks),
            .section(libraryId: 7, sectionId: "recent", label: "Recently Added"),
            .library(libraryId: 7, label: "Movies"),
            .collection(collectionId: "favorites", label: "Favorites", libraryId: 7),
            .library(libraryId: 7, label: "Renamed Movies"),
            .builtin(.calendar),
        ])

        let destinations = projectedMainTabDestinations(
            primaryMenu: menu,
            availableLibraries: [movie, series, audiobook]
        )

        XCTAssertEqual(
            destinations.map(\.id),
            [
                .app(.home),
                .libraryCategory(.movies),
                .libraryCategory(.series),
                .libraryCategory(.audiobooks),
                .library(7),
                .app(.calendar),
            ]
        )
        XCTAssertEqual(
            destinations[4].title,
            "Renamed Movies",
            "pinned destinations should use current library metadata instead of their stored label"
        )
        XCTAssertFalse(
            destinations.contains { $0.id == .app(.libraries) },
            "authored categories and unsupported shortcut IDs must not collapse into an aggregate tab"
        )
    }

    func testMainTabProjectionFailsClosedAndFiltersUnavailableLibraries() {
        let menu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .library(libraryId: 7, label: "Removed"),
            .library(libraryId: 8, label: "Visible"),
        ])

        let unavailable = projectedMainTabDestinations(primaryMenu: menu)
        XCTAssertEqual(
            unavailable.map(\.id),
            [.app(.home), .app(.recommendations), .app(.calendar)]
        )

        let known = projectedMainTabDestinations(
            primaryMenu: menu,
            availableLibraries: [
                Library(id: 8, name: "Visible", type: "movies", sortOrder: 0, posterUrl: nil)
            ]
        )
        XCTAssertEqual(known.map(\.id), [.app(.home), .library(8)])
        XCTAssertEqual(
            resolvedVisibleMainTabDestination(.library(7), visibleDestinations: known),
            .app(.home)
        )
        XCTAssertEqual(
            resolvedVisibleMainTabDestination(.library(8), visibleDestinations: known),
            .library(8)
        )

        let knownEmpty = projectedMainTabDestinations(primaryMenu: menu, availableLibraries: [])
        XCTAssertEqual(
            knownEmpty.map(\.id),
            [.app(.home), .app(.recommendations), .app(.calendar)]
        )
    }

    func testHomeOnlyMainTabProjectionRestoresAppleDefaults() {
        let menu = PrimaryMenuPreference(items: [.builtin(.home)])
        let destinations = projectedMainTabDestinations(
            primaryMenu: menu,
            availableLibraries: [
                Library(id: 1, name: "Movies", type: "movies", sortOrder: 0, posterUrl: nil),
                Library(id: 2, name: "Series", type: "series", sortOrder: 1, posterUrl: nil),
            ]
        )

        XCTAssertEqual(
            destinations.map(\.id),
            [
                .app(.home),
                .libraryCategory(.movies),
                .libraryCategory(.series),
                .app(.recommendations),
                .app(.calendar),
            ]
        )
    }

    func testLibraryTabRequestUsesFirstAuthoredLibraryRoot() {
        let authoredDestinations: [MainTabDestination] = [
            .app(.home),
            .libraryCategory(.series),
            .library(id: 8, label: "Pinned"),
            .app(.downloads),
        ]
        XCTAssertEqual(
            resolvedRequestedMainTabDestination(
                .libraries,
                visibleDestinations: authoredDestinations
            ),
            .libraryCategory(.series),
            "Browse Libraries should follow authored menu order when the aggregate root is hidden"
        )

        let aggregateDestinations: [MainTabDestination] = [
            .app(.home),
            .app(.libraries),
            .libraryCategory(.series),
        ]
        XCTAssertEqual(
            resolvedRequestedMainTabDestination(
                .libraries,
                visibleDestinations: aggregateDestinations
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

    func testMainTabProjectionOnlyShowsCategoriesBackedByCurrentLibraries() {
        let menu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.movies),
            .builtin(.series),
            .builtin(.audiobooks),
        ])
        XCTAssertEqual(
            projectedMainTabDestinations(primaryMenu: menu).map(\.id),
            [.app(.home), .app(.recommendations), .app(.calendar)],
            "unavailable library categories must fall back to app roots without rendering dead library roots"
        )

        let mixed = Library(id: 4, name: "Mixed", type: "mixed", sortOrder: 0, posterUrl: nil)
        XCTAssertEqual(
            projectedMainTabDestinations(
                primaryMenu: menu,
                availableLibraries: [mixed]
            ).map(\.id),
            [.app(.home), .libraryCategory(.movies), .libraryCategory(.series)]
        )

        let audiobook = Library(
            id: 5,
            name: "Audiobooks",
            type: "audiobooks",
            sortOrder: 0,
            posterUrl: nil
        )
        XCTAssertEqual(
            projectedMainTabDestinations(
                primaryMenu: menu,
                availableLibraries: [audiobook]
            ).map(\.id),
            [.app(.home), .libraryCategory(.audiobooks)]
        )
        XCTAssertTrue(
            mainTabSupportsDestination(.builtin(.audiobooks), availableLibraries: [audiobook]),
            "the editor and runtime share this availability decision"
        )
        XCTAssertFalse(
            mainTabSupportsDestination(.builtin(.movies), availableLibraries: [audiobook])
        )
    }

    func testAudiobookOptOutHidesCustomizedMainMenuDestination() {
        let audiobook = Library(
            id: 5,
            name: "Audiobooks",
            type: "audiobooks",
            sortOrder: 0,
            posterUrl: nil
        )
        let menu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.audiobooks),
            .builtin(.calendar),
        ])

        XCTAssertEqual(
            projectedMainTabDestinations(
                primaryMenu: menu,
                availableLibraries: [audiobook],
                showAudiobooks: false
            ).map(\.id),
            [.app(.home), .app(.calendar)]
        )
        XCTAssertFalse(
            mainTabSupportsDestination(
                .builtin(.audiobooks),
                availableLibraries: [audiobook],
                showAudiobooks: false
            )
        )
        XCTAssertFalse(
            mainTabSupportsDestination(
                .library(libraryId: audiobook.id, label: audiobook.name),
                availableLibraries: [audiobook],
                showAudiobooks: false
            ),
            "the opt-out also hides a directly pinned audiobook library"
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
        let menu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .library(libraryId: library.id, label: library.name),
        ])
        let staleSnapshot = MainTabLibrarySnapshot(
            authority: firstProfile,
            libraries: [library]
        )

        let staleProjection = projectedMainTabDestinations(
            primaryMenu: menu,
            availableLibraries: staleSnapshot.availableLibraries(for: secondProfile)
        )
        XCTAssertEqual(
            staleProjection.map(\.id),
            [.app(.home), .app(.recommendations), .app(.calendar)],
            "a previous profile's library must stay hidden while the app fallback remains available"
        )
        XCTAssertEqual(
            resolvedVisibleMainTabDestination(
                .library(library.id),
                visibleDestinations: staleProjection
            ),
            .app(.home)
        )

        let currentSnapshot = MainTabLibrarySnapshot(
            authority: secondProfile,
            libraries: [library]
        )
        let currentProjection = projectedMainTabDestinations(
            primaryMenu: menu,
            availableLibraries: currentSnapshot.availableLibraries(for: secondProfile)
        )
        XCTAssertEqual(currentProjection.map(\.id), [.app(.home), .library(library.id)])

        let revokedProjection = projectedMainTabDestinations(
            primaryMenu: menu,
            availableLibraries: MainTabLibrarySnapshot(
                authority: secondProfile,
                libraries: []
            ).availableLibraries(for: secondProfile)
        )
        XCTAssertEqual(
            revokedProjection.map(\.id),
            [.app(.home), .app(.recommendations), .app(.calendar)],
            "revoking library access must restore app roots without retaining the library pin"
        )
        XCTAssertEqual(
            resolvedVisibleMainTabDestination(
                .library(library.id),
                visibleDestinations: revokedProjection
            ),
            .app(.home),
            "a same-authority access revocation must remove the pin and select Home"
        )
    }

#if !os(tvOS)
    // availablePrimaryMenuShortcuts / primaryMenuShortcutTypeTitle live in
    // InterfaceCustomizationView, which the tvOS build compiles out.
    func testAvailableShortcutsExcludeItemsAlreadyInPrimaryMenu() {
        let availableLibrary = Library(
            id: 8,
            name: "Available",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let visibleLibrary = Library(
            id: 9,
            name: "Visible",
            type: "series",
            sortOrder: 1,
            posterUrl: nil
        )
        let visibleItem = PrimaryMenuItem.library(libraryId: 9, label: "Old Name")

        XCTAssertEqual(
            availablePrimaryMenuShortcuts(
                candidates: [.builtin(.home), .builtin(.forYou)],
                libraries: [availableLibrary, visibleLibrary],
                visibleIds: [PrimaryMenuItem.builtin(.home).id, visibleItem.id]
            ),
            [
                .builtin(.forYou),
                .library(libraryId: 8, label: "Available"),
            ]
        )
    }

    func testShortcutTypeTitlesUseCustomizationCategories() {
        XCTAssertEqual(primaryMenuShortcutTypeTitle(.builtin(.movies)), "Media Type")
        XCTAssertEqual(
            primaryMenuShortcutTypeTitle(.library(libraryId: 1, label: "Movies")),
            "Library"
        )
        XCTAssertEqual(primaryMenuShortcutTypeTitle(.builtin(.forYou)), "Discover")
        XCTAssertEqual(primaryMenuShortcutTypeTitle(.builtin(.home)), "Your Stuff")

        let mixed = Library(
            id: 2,
            name: "Mixed",
            type: "mixed",
            sortOrder: 0,
            posterUrl: nil
        )
        XCTAssertEqual(
            primaryMenuShortcutTypeTitle(
                .library(libraryId: 2, label: "Mixed"),
                libraries: [mixed]
            ),
            "Mixed Library"
        )

        let movies = Library(
            id: 3,
            name: "Movies",
            type: "movies",
            sortOrder: 1,
            posterUrl: nil
        )
        let series = Library(
            id: 4,
            name: "Series",
            type: "series",
            sortOrder: 2,
            posterUrl: nil
        )
        XCTAssertEqual(
            primaryMenuShortcutTypeTitle(
                .library(libraryId: 3, label: "Movies"),
                libraries: [movies, series]
            ),
            "Movies Library"
        )
        XCTAssertEqual(
            primaryMenuShortcutTypeTitle(
                .library(libraryId: 4, label: "Series"),
                libraries: [movies, series]
            ),
            "Series Library"
        )
        XCTAssertEqual(
            primaryMenuShortcutTypeTitle(
                .library(libraryId: 3, label: "Movies"),
                libraries: [movies, series],
                isNestedLibrary: true
            ),
            "Library"
        )
    }
#endif

    func testPrimaryMenuItemsUseMainMenuNavigationIcons() {
        XCTAssertEqual(PrimaryMenuItem.builtin(.home).navigationIcon, AppTab.home.icon)
        XCTAssertEqual(PrimaryMenuItem.builtin(.movies).navigationIcon, "film.stack")
        XCTAssertEqual(PrimaryMenuItem.builtin(.series).navigationIcon, "tv")
        XCTAssertEqual(PrimaryMenuItem.builtin(.music).navigationIcon, "rectangle.stack")
        XCTAssertEqual(PrimaryMenuItem.builtin(.audiobooks).navigationIcon, "book.closed")
        XCTAssertEqual(
            PrimaryMenuItem.builtin(.forYou).navigationIcon,
            AppTab.recommendations.icon
        )
        XCTAssertEqual(PrimaryMenuItem.builtin(.calendar).navigationIcon, AppTab.calendar.icon)
        XCTAssertEqual(
            PrimaryMenuItem.library(libraryId: 1, label: "Movies").navigationIcon,
            "rectangle.stack"
        )
    }

#if !os(tvOS)
    // PrimaryMenuEditorRow and its helpers live in InterfaceCustomizationView,
    // which the tvOS build compiles out.
    func testPrimaryMenuEditorGroupsLibrariesUnderTheirVisibleMediaType() {
        let movies = Library(
            id: 1,
            name: "Movies A",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let series = Library(
            id: 2,
            name: "Series A",
            type: "series",
            sortOrder: 1,
            posterUrl: nil
        )
        let mixed = Library(
            id: 3,
            name: "Mixed",
            type: "mixed",
            sortOrder: 2,
            posterUrl: nil
        )
        let items: [PrimaryMenuItem] = [
            .builtin(.home),
            .library(libraryId: 2, label: "Series A"),
            .builtin(.movies),
            .builtin(.series),
            .library(libraryId: 1, label: "Movies A"),
            .library(libraryId: 3, label: "Mixed"),
            .builtin(.forYou),
        ]

        let rows = groupedPrimaryMenuEditorRows(
            items,
            libraries: [movies, series, mixed]
        )

        XCTAssertEqual(
            rows.map(\.item),
            [
                .builtin(.home),
                .builtin(.movies),
                .library(libraryId: 1, label: "Movies A"),
                .builtin(.series),
                .library(libraryId: 2, label: "Series A"),
                .library(libraryId: 3, label: "Mixed"),
                .builtin(.forYou),
            ]
        )
        XCTAssertEqual(
            rows.map(\.parentMediaType),
            [nil, nil, .movies, nil, .series, nil, nil]
        )
    }
#endif

    func testMixedLibraryStaysOutsidePrimaryMenuMediaTypes() {
        let mixed = Library(
            id: 3,
            name: "Mixed",
            type: "mixed",
            sortOrder: 0,
            posterUrl: nil
        )

        XCTAssertNil(
            primaryMenuParentCategory(for: mixed, among: [.movies, .series])
        )
        XCTAssertEqual(mixed.navigationIcon, "square.stack.3d.up")
        XCTAssertEqual(mixed.selectedNavigationIcon, "square.stack.3d.up.fill")
    }

    func testPinnedMixedLibraryOnlySwitchesAmongMixedLibraries() {
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
                category: nil,
                fixedLibraryId: mixed.id,
                showAudiobooks: true
            ).map(\.id),
            [mixed.id, otherMixed.id]
        )
    }

#if !os(tvOS)
    // PrimaryMenuEditorRow and its helpers live in InterfaceCustomizationView,
    // which the tvOS build compiles out.
    func testPrimaryMenuEditorOnlyOffsetsLibrariesWithinTheirMediaType() {
        let rows = [
            PrimaryMenuEditorRow(item: .builtin(.movies), parentMediaType: nil),
            PrimaryMenuEditorRow(
                item: .library(libraryId: 1, label: "Movies A"),
                parentMediaType: .movies
            ),
            PrimaryMenuEditorRow(
                item: .library(libraryId: 2, label: "Movies B"),
                parentMediaType: .movies
            ),
            PrimaryMenuEditorRow(item: .builtin(.series), parentMediaType: nil),
            PrimaryMenuEditorRow(
                item: .library(libraryId: 3, label: "Series A"),
                parentMediaType: .series
            ),
        ]

        XCTAssertNil(
            offsetPrimaryMenuEditorItem(
                rows,
                itemId: "library:1",
                by: 2
            )
        )
        XCTAssertEqual(
            offsetPrimaryMenuEditorItem(
                rows,
                itemId: "library:1",
                by: 1
            ),
            [
                .builtin(.movies),
                .library(libraryId: 2, label: "Movies B"),
                .library(libraryId: 1, label: "Movies A"),
                .builtin(.series),
                .library(libraryId: 3, label: "Series A"),
            ]
        )
    }

    func testPrimaryMenuEditorMovesMediaTypeWithAssociatedLibraries() {
        let rows = [
            PrimaryMenuEditorRow(item: .builtin(.home), parentMediaType: nil),
            PrimaryMenuEditorRow(item: .builtin(.movies), parentMediaType: nil),
            PrimaryMenuEditorRow(
                item: .library(libraryId: 1, label: "Movies A"),
                parentMediaType: .movies
            ),
            PrimaryMenuEditorRow(
                item: .library(libraryId: 2, label: "Movies B"),
                parentMediaType: .movies
            ),
            PrimaryMenuEditorRow(item: .builtin(.series), parentMediaType: nil),
            PrimaryMenuEditorRow(
                item: .library(libraryId: 3, label: "Series A"),
                parentMediaType: .series
            ),
        ]

        XCTAssertEqual(
            offsetPrimaryMenuEditorItem(
                rows,
                itemId: "builtin:series",
                by: -1
            ),
            [
                .builtin(.home),
                .builtin(.series),
                .library(libraryId: 3, label: "Series A"),
                .builtin(.movies),
                .library(libraryId: 1, label: "Movies A"),
                .library(libraryId: 2, label: "Movies B"),
            ]
        )
    }
#endif

    func testPrimaryMenuLibraryCategoriesKeepTheirAuthoredMediaScope() {
        let movie = Library(id: 1, name: "Movies", type: "movies", sortOrder: 0, posterUrl: nil)
        let series = Library(id: 2, name: "Shows", type: "series", sortOrder: 1, posterUrl: nil)
        let mixed = Library(id: 3, name: "Mixed", type: "mixed", sortOrder: 2, posterUrl: nil)
        let audiobook = Library(
            id: 4,
            name: "Audiobooks",
            type: "audiobooks",
            sortOrder: 3,
            posterUrl: nil
        )

        XCTAssertTrue(libraryMatchesPrimaryMenuCategory(movie, category: .movies))
        XCTAssertTrue(libraryMatchesPrimaryMenuCategory(mixed, category: .movies))
        XCTAssertFalse(libraryMatchesPrimaryMenuCategory(series, category: .movies))
        XCTAssertTrue(libraryMatchesPrimaryMenuCategory(series, category: .series))
        XCTAssertTrue(libraryMatchesPrimaryMenuCategory(mixed, category: .series))
        XCTAssertFalse(libraryMatchesPrimaryMenuCategory(movie, category: .series))
        XCTAssertTrue(libraryMatchesPrimaryMenuCategory(audiobook, category: .audiobooks))
        XCTAssertFalse(libraryMatchesPrimaryMenuCategory(movie, category: .audiobooks))
        XCTAssertFalse(libraryMatchesPrimaryMenuCategory(movie, category: .music))
    }

    func testDirectLibraryRootUsesExactAccessibleLibraryAndFixedChrome() {
        let first = Library(id: 7, name: "First", type: "movies", sortOrder: 0, posterUrl: nil)
        let second = Library(id: 8, name: "Second", type: "series", sortOrder: 1, posterUrl: nil)

        XCTAssertEqual(
            visibleLibrariesForRoot(
                [first, second],
                category: nil,
                fixedLibraryId: second.id,
                showAudiobooks: true
            ),
            [second]
        )
        XCTAssertTrue(
            visibleLibrariesForRoot(
                [first, second],
                category: nil,
                fixedLibraryId: 99,
                showAudiobooks: true
            ).isEmpty,
            "an inaccessible pinned ID must not fall through to another library"
        )
        XCTAssertFalse(
            libraryRootCanSwitch(visibleLibraryCount: 1),
            "a direct root with no same-type siblings disables the library picker"
        )
        XCTAssertTrue(
            libraryRootCanSwitch(visibleLibraryCount: 2),
            "a direct root with same-type siblings allows switching via the top selector"
        )

        XCTAssertEqual(
            resolvedLibraryIdForRoot(
                [first, second],
                category: nil,
                fixedLibraryId: first.id,
                showAudiobooks: true,
                storedLibraryId: second.id
            ),
            first.id
        )
        XCTAssertEqual(
            resolvedLibraryIdForRoot(
                [first, second],
                category: nil,
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
                category: nil,
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
                category: nil,
                fixedLibraryId: second.id,
                showAudiobooks: true,
                storedLibraryId: 0,
                currentSelectionId: first.id
            ),
            second.id,
            "a selection outside the root scope must fall back to the pinned library"
        )
    }

    func testLibrarySelectionPersistenceIsScopedByAuthorityAndRoot() throws {
        let firstAuthority = try XCTUnwrap(
            MainTabLibraryAuthority(serverId: "server", profileId: "profile-a")
        )
        let secondAuthority = try XCTUnwrap(
            MainTabLibraryAuthority(serverId: "server", profileId: "profile-b")
        )
        let aggregateKey = try XCTUnwrap(
            librarySelectionStorageKey(
                category: nil,
                fixedLibraryId: nil,
                authority: firstAuthority
            )
        )
        let moviesKey = try XCTUnwrap(
            librarySelectionStorageKey(
                category: .movies,
                fixedLibraryId: nil,
                authority: firstAuthority
            )
        )
        let seriesKey = try XCTUnwrap(
            librarySelectionStorageKey(
                category: .series,
                fixedLibraryId: nil,
                authority: firstAuthority
            )
        )
        let otherProfileMoviesKey = try XCTUnwrap(
            librarySelectionStorageKey(
                category: .movies,
                fixedLibraryId: nil,
                authority: secondAuthority
            )
        )

        XCTAssertEqual(aggregateKey, "librariesTabSelectedLibraryId")
        XCTAssertNotEqual(moviesKey, seriesKey)
        XCTAssertNotEqual(moviesKey, otherProfileMoviesKey)
        XCTAssertNil(
            librarySelectionStorageKey(
                category: nil,
                fixedLibraryId: 7,
                authority: firstAuthority
            ),
            "a fixed root derives its selection from the destination and must not persist it"
        )
        XCTAssertNil(
            librarySelectionStorageKey(
                category: .movies,
                fixedLibraryId: nil,
                authority: nil
            ),
            "an unauthenticated category root must not persist under a shared none:none key"
        )

        let suiteName = "library-selection-scope-suite-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { UserDefaults().removePersistentDomain(forName: suiteName) }
        defaults.set(8, forKey: aggregateKey)
        XCTAssertEqual(
            storedLibrarySelectionId(for: moviesKey, defaults: defaults),
            8,
            "a missing scoped value seeds from the legacy aggregate selection"
        )
        defaults.set(9, forKey: moviesKey)
        defaults.set(10, forKey: seriesKey)
        XCTAssertEqual(storedLibrarySelectionId(for: moviesKey, defaults: defaults), 9)
        XCTAssertEqual(storedLibrarySelectionId(for: seriesKey, defaults: defaults), 10)
    }

    func testDirectTVLibraryShortcutDoesNotInheritCategoryPillState() {
        XCTAssertEqual(
            resolvedLibraryRootPill(
                categorySelection: .browse,
                directSelection: nil,
                isDirectLibraryShortcut: true
            ),
            .recommended
        )
        XCTAssertEqual(
            resolvedLibraryRootPill(
                categorySelection: .collections,
                directSelection: nil,
                isDirectLibraryShortcut: true
            ),
            .recommended
        )
        XCTAssertEqual(
            resolvedLibraryRootPill(
                categorySelection: .browse,
                directSelection: nil,
                isDirectLibraryShortcut: false
            ),
            .browse
        )
        XCTAssertEqual(
            resolvedLibraryRootPill(
                categorySelection: .collections,
                directSelection: .browse,
                isDirectLibraryShortcut: true
            ),
            .browse,
            "the direct pin's cascade owns a writable section independent of its category"
        )
        XCTAssertTrue(TVLibraryMenuRootKind.category.hasSectionCascade)
        XCTAssertTrue(
            TVLibraryMenuRootKind.directShortcut.hasSectionCascade,
            "D-pad Down on a direct pin must enter its one-library section cascade"
        )
        XCTAssertFalse(TVLibraryMenuRootKind.staticRoot.hasSectionCascade)
    }

    func testTVCustomizationControlsDisableAcrossCapabilityChanges() {
        XCTAssertTrue(
            tvCustomizationMutationIsEnabled(
                allowsEditing: true,
                usesDeviceMenuOverride: false,
                changesFamilyMenu: true
            )
        )
        XCTAssertFalse(
            tvCustomizationMutationIsEnabled(
                allowsEditing: false,
                usesDeviceMenuOverride: false,
                changesFamilyMenu: true
            ),
            "an already-presented menu or picker must stop accepting mutations"
        )
        XCTAssertFalse(
            tvCustomizationMutationIsEnabled(
                allowsEditing: true,
                usesDeviceMenuOverride: true,
                changesFamilyMenu: true
            )
        )
        XCTAssertTrue(
            tvCustomizationMutationIsEnabled(
                allowsEditing: true,
                usesDeviceMenuOverride: true,
                changesFamilyMenu: false
            ),
            "profile shortcut membership remains editable under a device menu override"
        )
        XCTAssertFalse(
            tvCustomizationMutationIsEnabled(
                allowsEditing: false,
                usesDeviceMenuOverride: true,
                changesFamilyMenu: false
            )
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

    func testLegacyCollectionOutboxIdentityMigratesToStructuredIdentity() async throws {
        let suiteName = "ui-customization-legacy-collection-id-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-legacy-collection-id-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let cacheKey = "silo.uiCustomization.server.profile.mobile"
        let item: [String: Any] = [
            "type": "collection",
            "collection_id": "featured:2026",
            "label": "Featured",
        ]
        let legacyIdentity = "collection:all:featured:2026"
        let cache: [String: Any] = [
            "shortcuts": ["items": [item]],
            "cardPresentation": [
                "poster_size": "standard",
                "caption": "title_metadata",
            ],
            "pendingShortcutOperations": [
                legacyIdentity: [
                    "item": item,
                    "present": true,
                    "mutationId": "legacy-collection-mutation",
                    "sequence": 7,
                ],
            ],
        ]
        let defaults = SharedDefaults(suite: suite, standard: standard)
        defaults.set(
            try JSONSerialization.data(withJSONObject: cache, options: [.sortedKeys]),
            forKey: cacheKey
        )

        let transport = FakeUICustomizationTransport(rows: [
            try .init(.navShortcuts, .profile, encoding: NavigationShortcutsPreference.empty),
        ])
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) }
        )
        await preferences.refresh()

        let shortcutOperations = await transport.calls(.shortcut)
        let operation = try XCTUnwrap(shortcutOperations.first)
        let replayedItem = try XCTUnwrap(operation.item)
        XCTAssertEqual(shortcutOperations.count, 1)
        XCTAssertEqual(replayedItem.id, "collection|0|0#|13#featured:2026")
        XCTAssertEqual(operation.present, true, "the cache written with a mutation id still replays")
        XCTAssertEqual(preferences.shortcuts.items.map(\.id), [replayedItem.id])
    }

    func testPrimaryMenuRejectsMissingOrDuplicateHomeAndDuplicateShortcuts() {
        XCTAssertFalse(PrimaryMenuPreference(items: [.builtin(.movies)]).isValid)
        XCTAssertFalse(
            PrimaryMenuPreference(items: [.builtin(.home), .builtin(.home)]).isValid
        )
        XCTAssertFalse(
            PrimaryMenuPreference(items: [
                .builtin(.home),
                .library(libraryId: 7, label: "Movies"),
                .library(libraryId: 7, label: "Renamed Movies"),
            ]).isValid
        )
        XCTAssertFalse(
            PrimaryMenuPreference(items: [
                .builtin(.home),
                .library(libraryId: 7, label: "  \n"),
            ]).isValid
        )
        XCTAssertFalse(
            PrimaryMenuPreference(items: [
                .builtin(.home),
                .section(libraryId: 7, sectionId: " \n ", label: "Recent"),
            ]).isValid
        )
        XCTAssertFalse(
            PrimaryMenuPreference(items: [
                .builtin(.home),
                .collection(collectionId: "\t", label: "Favorites", libraryId: nil),
            ]).isValid
        )
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

        preferences.setCardPresentation(CardPresentationPreset.compact.presentation)
        preferences.setCardPresentation(CardPresentationPreset.artworkOnly.presentation)
        XCTAssertTrue(preferences.isSaving)

        let release = Task {
            await transport.waitForStarted(.put, count: 1)
            try? await Task.sleep(nanoseconds: 50_000_000)
            await transport.release(.puts)
        }
        await transport.waitForCompleted(.put, count: 2)
        await release.value
        try await Task.sleep(nanoseconds: 20_000_000)

        let values = await transport.calls(.put).compactMap(\.value)
        let maxConcurrentWrites = await transport.maxConcurrentWrites
        let presentations = try values.map {
            try $0.decoded(as: CardPresentationPreference.self)
        }
        XCTAssertEqual(maxConcurrentWrites, 1, "writes must never overtake one another")
        XCTAssertEqual(
            presentations,
            [
                CardPresentationPreset.compact.presentation,
                CardPresentationPreset.artworkOnly.presentation,
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
        let desired = CardPresentationPreset.artworkOnly.presentation

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

    func testAcceptedPinDurablyTransitionsToMenuOutboxBeforeTransportCompletion() async throws {
        let suiteName = "ui-customization-pin-crash-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-pin-crash-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let cacheKey = "silo.uiCustomization.server.profile.tv"
        let transport = FakeUICustomizationTransport(
            effectiveResponse: FakeUICustomizationTransport.emptyResponse
        )
        await transport.hold(.put(.navPrimaryMenu))
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        let library = Library(
            id: 7,
            name: "Accepted",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let item = PrimaryMenuItem.library(libraryId: 7, label: "Accepted")

        preferences.setLibraryPinned(library, isPinned: true)
        await transport.waitForStarted(.put, count: 1)

        let cachedData = try XCTUnwrap(defaults.data(forKey: cacheKey))
        let cache = try XCTUnwrap(
            JSONSerialization.jsonObject(with: cachedData) as? [String: Any]
        )
        let pendingWrites = try XCTUnwrap(cache["pendingSyncWrites"] as? [String: Any])
        XCTAssertNil(cache["pendingShortcutOperations"])
        XCTAssertNotNil(pendingWrites[SettingKey.navPrimaryMenu.rawValue])

        let replayTransport = FakeUICustomizationTransport(
            rows: try menuAndShortcutRows(shortcuts: [item])
        )
        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: replayTransport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await restarted.refresh()

        let menuWrites = await replayTransport.decodedPuts(
            .navPrimaryMenu,
            as: PrimaryMenuPreference.self
        )
        XCTAssertEqual(menuWrites.count, 1)
        XCTAssertTrue(menuWrites[0].items.contains { $0.id == item.id })
        XCTAssertTrue(restarted.isLibraryPinned(7))

        await transport.release(.put(.navPrimaryMenu))
        await transport.waitForCompleted(.put, count: 1)
    }

    func testSuccessfulMenuWriteDoesNotClearShortcutWriteFailure() async throws {
        let suiteName = "ui-customization-partial-failure-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-partial-failure-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let transport = FakeUICustomizationTransport(
            effectiveResponse: FakeUICustomizationTransport.emptyResponse
        )
        await transport.fail(.put(.navShortcuts))
        await transport.fail(.shortcuts)
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { "silo.uiCustomization.server.profile.tv" },
            requestIdentity: { testRequestIdentity(family: "tv") },
            initialCapabilityState: .supported
        )
        let library = Library(
            id: 7,
            name: "Movies",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )

        preferences.setLibraryPinned(library, isPinned: true)
        preferences.setPrimaryMenuItems([
            .builtin(.home),
            .builtin(.forYou),
        ])
        await transport.waitForCompleted(.write, count: 2)
        try await Task.sleep(nanoseconds: 20_000_000)
        let writtenKeys = await transport.calls(.write).compactMap(\.key)
        let wholeShortcutPutCount = await transport.calls(.put)
            .filter { $0.key == .navShortcuts }
            .count

        XCTAssertEqual(writtenKeys, [.navShortcuts, .navPrimaryMenu])
        XCTAssertEqual(
            wholeShortcutPutCount,
            0,
            "shortcut edits must use the atomic item endpoint, never a whole-value PUT"
        )
        XCTAssertNotNil(
            preferences.syncErrorMessage,
            "a later menu success must not hide the failed profile shortcut write"
        )
        XCTAssertFalse(preferences.isSaving)
    }

    func testSuccessfulShortcutDoesNotClearDifferentPendingShortcutFailure() async throws {
        let suiteName = "ui-customization-per-shortcut-error-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-per-shortcut-error-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let cacheKey = "silo.uiCustomization.server.profile.tv"
        let failedLibrary = Library(
            id: 7,
            name: "Failed Library",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let successfulLibrary = Library(
            id: 8,
            name: "Successful Library",
            type: "movies",
            sortOrder: 1,
            posterUrl: nil
        )
        let transport = FakeUICustomizationTransport(
            effectiveResponse: FakeUICustomizationTransport.emptyResponse
        )
        await transport.fail(.shortcut(id: "library:7"))
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )

        preferences.setLibraryPinned(failedLibrary, isPinned: true)
        preferences.setLibraryPinned(successfulLibrary, isPinned: true)
        await transport.waitForCompleted(.write, count: 3)

        XCTAssertNotNil(
            preferences.syncErrorMessage,
            "shortcut B succeeding must not hide shortcut A's pending failure"
        )

        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await restarted.refresh()
        let attemptedShortcutIds = await transport.calls(.shortcut).compactMap(\.item?.id)

        XCTAssertEqual(
            attemptedShortcutIds,
            ["library:7", "library:8", "library:7"],
            "only the still-failed shortcut must survive and replay from the outbox"
        )
        XCTAssertNotNil(restarted.syncErrorMessage)
    }

    func testOverlappingAcceptedPinsPersistOnlyAcceptedMenuSnapshots() async throws {
        let suiteName = "ui-customization-overlap-success-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-overlap-success-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let transport = FakeUICustomizationTransport(rows: try menuAndShortcutRows())
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { "silo.uiCustomization.server.profile.tv" },
            requestIdentity: { testRequestIdentity(family: "tv") },
            initialCapabilityState: .supported
        )
        let first = Library(
            id: 7,
            name: "First",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let second = Library(
            id: 8,
            name: "Second",
            type: "movies",
            sortOrder: 1,
            posterUrl: nil
        )

        preferences.setLibraryPinned(first, isPinned: true)
        preferences.setLibraryPinned(second, isPinned: true)
        await transport.waitForCompleted(.write, count: 4)

        let shortcutAttempts = await transport.calls(.shortcut)
        let menuWrites = await transport.decodedPuts(
            .navPrimaryMenu,
            as: PrimaryMenuPreference.self
        )
        XCTAssertEqual(shortcutAttempts.compactMap(\.item?.id), ["library:7", "library:8"])
        XCTAssertEqual(menuWrites.count, 2)
        XCTAssertTrue(menuWrites[0].items.contains { $0.id == "library:7" })
        XCTAssertFalse(menuWrites[0].items.contains { $0.id == "library:8" })
        XCTAssertTrue(menuWrites[1].items.contains { $0.id == "library:7" })
        XCTAssertTrue(menuWrites[1].items.contains { $0.id == "library:8" })
    }

    func testLaterRejectedPinNeverEntersEarlierAcceptedPinMenuWrite() async throws {
        let suiteName = "ui-customization-overlap-rejection-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-overlap-rejection-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let transport = FakeUICustomizationTransport(rows: try menuAndShortcutRows())
        await transport.fail(.shortcut(id: "library:8"), with: .api(.invalidValue(message: "shortcut rejected")), times: 1)
        let cacheKey = "silo.uiCustomization.server.profile.tv"
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        let first = Library(
            id: 7,
            name: "Accepted",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let second = Library(
            id: 8,
            name: "Rejected",
            type: "movies",
            sortOrder: 1,
            posterUrl: nil
        )

        preferences.setLibraryPinned(first, isPinned: true)
        preferences.setLibraryPinned(second, isPinned: true)
        await transport.waitForCompleted(.write, count: 3)
        await preferences.refresh()

        let menuWrites = await transport.decodedPuts(
            .navPrimaryMenu,
            as: PrimaryMenuPreference.self
        )
        XCTAssertEqual(menuWrites.count, 1)
        XCTAssertTrue(menuWrites[0].items.contains { $0.id == "library:7" })
        XCTAssertFalse(menuWrites[0].items.contains { $0.id == "library:8" })
        XCTAssertTrue(preferences.isLibraryPinned(7))
        XCTAssertFalse(preferences.isLibraryPinned(8))
        XCTAssertFalse(
            preferences.resolvedPrimaryMenuItems().contains { $0.id == "library:8" }
        )
    }

    func testDefinitiveRejectionRollsBackOnlyRejectedShortcutWhenRefreshFails() async throws {
        let suiteName = "ui-customization-rejection-rollback-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-rejection-rollback-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let transport = FakeUICustomizationTransport(rows: try menuAndShortcutRows())
        await transport.fail(.shortcut(id: "library:8"), with: .api(.invalidValue(message: "shortcut rejected")), times: 1)
        await transport.fail(.reads)
        let cacheKey = "silo.uiCustomization.server.profile.tv"
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        let first = Library(
            id: 7,
            name: "Accepted",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let second = Library(
            id: 8,
            name: "Rejected",
            type: "movies",
            sortOrder: 1,
            posterUrl: nil
        )

        preferences.setLibraryPinned(first, isPinned: true)
        preferences.setLibraryPinned(second, isPinned: true)
        await transport.waitForCompleted(.write, count: 3)
        try await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertTrue(preferences.isLibraryPinned(7))
        XCTAssertFalse(
            preferences.isLibraryPinned(8),
            "a failed reconciliation must not leave a quarantined pin projected forever"
        )
        XCTAssertNotNil(preferences.syncErrorMessage)

        let cachedData = try XCTUnwrap(
            SharedDefaults(suite: suite, standard: standard).data(forKey: cacheKey)
        )
        let cache = try XCTUnwrap(
            JSONSerialization.jsonObject(with: cachedData) as? [String: Any]
        )
        XCTAssertNil(cache["pendingShortcutOperations"])
    }

    func testEarlierTransientPinReplaysIntoItsAuthoredOrderAfterLaterSuccess() async throws {
        let suiteName = "ui-customization-overlap-retry-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-overlap-retry-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let transport = FakeUICustomizationTransport(rows: try menuAndShortcutRows())
        await transport.fail(.shortcut(id: "library:7"), times: 1)
        let cacheKey = "silo.uiCustomization.server.profile.tv"
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        let first = Library(
            id: 7,
            name: "First",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let second = Library(
            id: 8,
            name: "Second",
            type: "movies",
            sortOrder: 1,
            posterUrl: nil
        )

        preferences.setLibraryPinned(first, isPinned: true)
        preferences.setLibraryPinned(second, isPinned: true)
        await transport.waitForCompleted(.write, count: 3)

        var menuWrites = await transport.decodedPuts(
            .navPrimaryMenu,
            as: PrimaryMenuPreference.self
        )
        XCTAssertEqual(menuWrites.count, 1)
        XCTAssertFalse(menuWrites[0].items.contains { $0.id == "library:7" })
        XCTAssertTrue(menuWrites[0].items.contains { $0.id == "library:8" })

        await preferences.refresh()

        let shortcutAttempts = await transport.calls(.shortcut)
        menuWrites = await transport.decodedPuts(
            .navPrimaryMenu,
            as: PrimaryMenuPreference.self
        )
        XCTAssertEqual(
            shortcutAttempts.compactMap(\.item?.id),
            ["library:7", "library:8", "library:7"]
        )
        let finalIds = menuWrites.last?.items.map(\.id) ?? []
        let firstIndex = try XCTUnwrap(finalIds.firstIndex(of: "library:7"))
        let secondIndex = try XCTUnwrap(finalIds.firstIndex(of: "library:8"))
        XCTAssertLessThan(firstIndex, secondIndex)
        XCTAssertNil(preferences.syncErrorMessage)
    }

    func testNewerExplicitMenuSupersedesInFlightPinPlacement() async throws {
        let suiteName = "ui-customization-explicit-inflight-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-explicit-inflight-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let transport = FakeUICustomizationTransport(
            rows: [try .init(.navShortcuts, .profile, encoding: NavigationShortcutsPreference.empty)],
            persistsPuts: false
        )
        await transport.hold(.shortcuts)
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { "silo.uiCustomization.server.profile.tv" },
            requestIdentity: { testRequestIdentity(family: "tv") },
            initialCapabilityState: .supported
        )
        let library = Library(
            id: 7,
            name: "Pending",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let explicitMenu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.calendar),
        ])

        preferences.setLibraryPinned(library, isPinned: true)
        await transport.waitForStarted(.shortcut, count: 1)
        preferences.setPrimaryMenuItems(explicitMenu.items)
        await transport.release(.shortcuts)
        await transport.waitForCompleted(.shortcut, count: 1)
        await transport.waitForCompleted(.put, count: 1)
        try await Task.sleep(nanoseconds: 30_000_000)

        let genericPutCount = await transport.calls(.put).count
        let menuWrites = await transport.decodedPuts(
            .navPrimaryMenu,
            as: PrimaryMenuPreference.self
        )
        XCTAssertEqual(genericPutCount, 1)
        XCTAssertEqual(menuWrites, [explicitMenu])
        XCTAssertEqual(preferences.primaryMenu, explicitMenu)
        XCTAssertTrue(preferences.isLibraryPinned(7))
        XCTAssertFalse(preferences.isSaving)
    }

    func testPendingPinCannotBeExplicitlyPlacedBeforeAcceptance() async throws {
        let suiteName = "ui-customization-pending-placement-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-pending-placement-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let transport = FakeUICustomizationTransport(
            rows: [try .init(.navShortcuts, .profile, encoding: NavigationShortcutsPreference.empty)],
            persistsPuts: false
        )
        await transport.hold(.shortcuts)
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { "silo.uiCustomization.server.profile.tv" },
            requestIdentity: { testRequestIdentity(family: "tv") },
            initialCapabilityState: .supported
        )
        let library = Library(
            id: 7,
            name: "Pending",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let pendingItem = PrimaryMenuItem.library(libraryId: 7, label: "Pending")

        preferences.setLibraryPinned(library, isPinned: true)
        await transport.waitForStarted(.shortcut, count: 1)
        preferences.setPrimaryMenuItems([.builtin(.home), pendingItem])

        XCTAssertNil(preferences.primaryMenu)
        XCTAssertTrue(preferences.syncErrorMessage?.contains("finish syncing") == true)

        await transport.release(.shortcuts)
        await transport.waitForCompleted(.shortcut, count: 1)
        await transport.waitForCompleted(.put, count: 1)
        let genericPutCount = await transport.calls(.put).count
        let menuWrites = await transport.decodedPuts(
            .navPrimaryMenu,
            as: PrimaryMenuPreference.self
        )
        XCTAssertEqual(genericPutCount, 1)
        XCTAssertTrue(menuWrites[0].items.contains { $0.id == pendingItem.id })
        XCTAssertNil(preferences.syncErrorMessage)
    }

    func testPendingPinCannotBePlacedAfterAnEarlierExplicitSupersession() async throws {
        let suiteName = "ui-customization-pending-resupersession-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-pending-resupersession-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let transport = FakeUICustomizationTransport(
            rows: [try .init(.navShortcuts, .profile, encoding: NavigationShortcutsPreference.empty)],
            persistsPuts: false
        )
        await transport.hold(.shortcuts)
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { "silo.uiCustomization.server.profile.tv" },
            requestIdentity: { testRequestIdentity(family: "tv") },
            initialCapabilityState: .supported
        )
        let library = Library(
            id: 7,
            name: "Pending",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let item = PrimaryMenuItem.library(libraryId: 7, label: "Pending")
        let firstExplicitMenu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.calendar),
        ])

        preferences.setLibraryPinned(library, isPinned: true)
        await transport.waitForStarted(.shortcut, count: 1)
        preferences.setPrimaryMenuItems(firstExplicitMenu.items)
        preferences.setPrimaryMenuItems(firstExplicitMenu.items + [item])

        XCTAssertEqual(preferences.primaryMenu, firstExplicitMenu)
        XCTAssertTrue(preferences.syncErrorMessage?.contains("finish syncing") == true)

        await transport.release(.shortcuts)
        await transport.waitForCompleted(.shortcut, count: 1)
        await transport.waitForCompleted(.put, count: 1)
        try await Task.sleep(nanoseconds: 30_000_000)

        let genericPutCount = await transport.calls(.put).count
        let menuWrites = await transport.decodedPuts(
            .navPrimaryMenu,
            as: PrimaryMenuPreference.self
        )
        XCTAssertEqual(genericPutCount, 1)
        XCTAssertEqual(menuWrites, [firstExplicitMenu])
        XCTAssertNil(preferences.syncErrorMessage)
    }

    func testPendingPlacementErrorTracksOnlyBlockedPinAcrossRestart() async throws {
        let suiteName = "ui-customization-pending-blocked-id-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-pending-blocked-id-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let cacheKey = "silo.uiCustomization.server.profile.tv"
        let first = PrimaryMenuItem.library(libraryId: 7, label: "First")
        let second = PrimaryMenuItem.library(libraryId: 8, label: "Second")
        let offlineTransport = FakeUICustomizationTransport(rows: try menuAndShortcutRows())
        await offlineTransport.fail(.shortcut(id: first.id), times: 1)
        await offlineTransport.fail(.shortcut(id: second.id), times: 1)
        let authored = UICustomizationPreferences(
            defaults: defaults,
            transport: offlineTransport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )

        authored.setLibraryPinned(
            Library(id: 7, name: "First", type: "movies", sortOrder: 0, posterUrl: nil),
            isPinned: true
        )
        authored.setLibraryPinned(
            Library(id: 8, name: "Second", type: "movies", sortOrder: 1, posterUrl: nil),
            isPinned: true
        )
        authored.setPrimaryMenuItems([.builtin(.home), first])
        await offlineTransport.waitForCompleted(.write, count: 2)

        XCTAssertTrue(authored.syncErrorMessage?.contains("finish syncing") == true)
        let blockedCacheData = try XCTUnwrap(defaults.data(forKey: cacheKey))
        let blockedCache = try XCTUnwrap(
            JSONSerialization.jsonObject(with: blockedCacheData) as? [String: Any]
        )
        XCTAssertEqual(
            blockedCache["pendingShortcutPlacementBlockedIds"] as? [String],
            [first.id]
        )

        let replayTransport = FakeUICustomizationTransport(rows: try menuAndShortcutRows())
        await replayTransport.fail(.shortcut(id: second.id), times: 1)
        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: replayTransport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        XCTAssertTrue(restarted.syncErrorMessage?.contains("finish syncing") == true)

        await restarted.refresh()

        let replayShortcutIds = await replayTransport.calls(.shortcut).compactMap(\.item?.id)
        XCTAssertEqual(replayShortcutIds, [first.id, second.id])
        XCTAssertFalse(restarted.syncErrorMessage?.contains("finish syncing") == true)
        let reconciledCacheData = try XCTUnwrap(defaults.data(forKey: cacheKey))
        let reconciledCache = try XCTUnwrap(
            JSONSerialization.jsonObject(with: reconciledCacheData) as? [String: Any]
        )
        XCTAssertNil(reconciledCache["pendingShortcutPlacementBlockedIds"])
    }

    func testExplicitMenuSupersessionSurvivesPendingPinRestart() async throws {
        let suiteName = "ui-customization-explicit-restart-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-explicit-restart-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let transport = FakeUICustomizationTransport(rows: [
            try .init(.navShortcuts, .profile, encoding: NavigationShortcutsPreference.empty),
        ])
        await transport.fail(.shortcuts)
        let cacheKey = "silo.uiCustomization.server.profile.tv"
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        let library = Library(
            id: 7,
            name: "Pending",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let explicitMenu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.calendar),
        ])

        preferences.setLibraryPinned(library, isPinned: true)
        await transport.waitForStarted(.shortcut, count: 1)
        preferences.setPrimaryMenuItems(explicitMenu.items)
        await transport.waitForCompleted(.put, count: 1)

        let cachedData = try XCTUnwrap(defaults.data(forKey: cacheKey))
        let cache = try XCTUnwrap(
            JSONSerialization.jsonObject(with: cachedData) as? [String: Any]
        )
        let pending = try XCTUnwrap(
            cache["pendingShortcutOperations"] as? [String: [String: Any]]
        )
        XCTAssertEqual(pending["library:7"]?["updatesPrimaryMenu"] as? Bool, false)

        await transport.stopFailing(.shortcuts)
        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await restarted.refresh()

        let shortcutOperationCount = await transport.calls(.shortcut).count
        let genericPutCount = await transport.calls(.put).count
        XCTAssertEqual(shortcutOperationCount, 2)
        XCTAssertEqual(genericPutCount, 1)
        XCTAssertEqual(restarted.primaryMenu, explicitMenu)
        XCTAssertTrue(restarted.isLibraryPinned(7))
    }

    func testNewerExplicitMenuKeepsItemAfterPendingUnpinSucceeds() async throws {
        let suiteName = "ui-customization-explicit-unpin-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-explicit-unpin-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let item = PrimaryMenuItem.library(libraryId: 7, label: "Pinned")
        let initialMenu = PrimaryMenuPreference(items: [
            .builtin(.home),
            item,
            .builtin(.forYou),
        ])
        let explicitMenu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.forYou),
            item,
        ])
        let transport = FakeUICustomizationTransport(
            rows: try menuAndShortcutRows(menu: initialMenu, shortcuts: [item])
        )
        await transport.fail(.shortcut(id: "library:7"), times: 1)
        let cacheKey = "silo.uiCustomization.server.profile.tv"
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await preferences.refresh()

        preferences.setLibraryPinned(
            Library(id: 7, name: "Pinned", type: "movies", sortOrder: 0, posterUrl: nil),
            isPinned: false
        )
        await transport.waitForCompleted(.write, count: 1)
        preferences.setPrimaryMenuItems(explicitMenu.items)
        await transport.waitForCompleted(.write, count: 2)
        await preferences.refresh()

        let menuWrites = await transport.decodedPuts(
            .navPrimaryMenu,
            as: PrimaryMenuPreference.self
        )
        XCTAssertEqual(menuWrites, [explicitMenu])
        XCTAssertFalse(preferences.isLibraryPinned(7))
        XCTAssertEqual(preferences.primaryMenu, explicitMenu)
    }

    func testPendingRemovalKeepsLaterAcceptedPinAfterItsProjectedPredecessor() async throws {
        let suiteName = "ui-customization-mixed-retry-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-mixed-retry-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let firstItem = PrimaryMenuItem.library(libraryId: 7, label: "First")
        let initialMenu = PrimaryMenuPreference(items: [
            .builtin(.home),
            firstItem,
            .builtin(.forYou),
        ])
        let transport = FakeUICustomizationTransport(
            rows: try menuAndShortcutRows(menu: initialMenu, shortcuts: [firstItem])
        )
        await transport.fail(.shortcut(id: "library:7"), times: 1)
        let cacheKey = "silo.uiCustomization.server.profile.tv"
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await preferences.refresh()
        let first = Library(
            id: 7,
            name: "First",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let second = Library(
            id: 8,
            name: "Second",
            type: "movies",
            sortOrder: 1,
            posterUrl: nil
        )

        preferences.setLibraryPinned(first, isPinned: false)
        preferences.setLibraryPinned(second, isPinned: true)
        await transport.waitForCompleted(.write, count: 3)

        var menuWrites = await transport.decodedPuts(
            .navPrimaryMenu,
            as: PrimaryMenuPreference.self
        )
        XCTAssertEqual(
            menuWrites.first?.items.map(\.id),
            ["builtin:home", "library:7", "builtin:for_you", "library:8"]
        )

        await preferences.refresh()

        menuWrites = await transport.decodedPuts(
            .navPrimaryMenu,
            as: PrimaryMenuPreference.self
        )
        XCTAssertEqual(
            menuWrites.last?.items.map(\.id),
            ["builtin:home", "builtin:for_you", "library:8"]
        )
    }

    func testRejectedRemovalPreservesSiblingAndLaterAcceptedPinOrdering() async throws {
        let suiteName = "ui-customization-mixed-rejection-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-mixed-rejection-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let firstItem = PrimaryMenuItem.library(libraryId: 7, label: "First")
        let initialMenu = PrimaryMenuPreference(items: [
            .builtin(.home),
            firstItem,
            .builtin(.forYou),
        ])
        let transport = FakeUICustomizationTransport(
            rows: try menuAndShortcutRows(menu: initialMenu, shortcuts: [firstItem])
        )
        await transport.fail(.shortcut(id: "library:7"), with: .api(.invalidValue(message: "shortcut rejected")), times: 1)
        let cacheKey = "silo.uiCustomization.server.profile.tv"
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await preferences.refresh()
        let first = Library(
            id: 7,
            name: "First",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let second = Library(
            id: 8,
            name: "Second",
            type: "movies",
            sortOrder: 1,
            posterUrl: nil
        )

        preferences.setLibraryPinned(first, isPinned: false)
        preferences.setLibraryPinned(second, isPinned: true)
        await transport.waitForCompleted(.write, count: 3)
        await preferences.refresh()

        let menuWrites = await transport.decodedPuts(
            .navPrimaryMenu,
            as: PrimaryMenuPreference.self
        )
        XCTAssertEqual(
            menuWrites.last?.items.map(\.id),
            ["builtin:home", "library:7", "builtin:for_you", "library:8"]
        )
        XCTAssertTrue(preferences.isLibraryPinned(7))
        XCTAssertTrue(preferences.isLibraryPinned(8))
    }

    func testPinningBeyondShortcutLimitPreservesStateAndOutbox() throws {
        let suiteName = "ui-customization-shortcut-limit-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-shortcut-limit-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let cacheKey = "silo.uiCustomization.server.profile.mobile"
        let shortcutItems: [[String: Any]] = (1...256).map { libraryId in
            [
                "type": "library",
                "library_id": libraryId,
                "label": "Library \(libraryId)",
            ]
        }
        let cache: [String: Any] = [
            "shortcuts": ["items": shortcutItems],
            "cardPresentation": [
                "poster_size": "standard",
                "caption": "title_metadata",
            ],
            "supportProjection": "supported",
        ]
        let cachedData = try JSONSerialization.data(withJSONObject: cache, options: [.sortedKeys])
        let defaults = SharedDefaults(suite: suite, standard: standard)
        defaults.set(cachedData, forKey: cacheKey)
        let transport = FakeUICustomizationTransport(
            effectiveResponse: FakeUICustomizationTransport.emptyResponse
        )
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        let overflowLibrary = Library(
            id: 257,
            name: "Overflow Library",
            type: "movies",
            sortOrder: 256,
            posterUrl: nil
        )

        preferences.setLibraryPinned(overflowLibrary, isPinned: true)

        XCTAssertEqual(preferences.shortcuts.items.count, 256)
        XCTAssertFalse(preferences.isLibraryPinned(overflowLibrary.id))
        XCTAssertFalse(preferences.isSaving, "a rejected add must not enqueue any writes")
        XCTAssertEqual(
            defaults.data(forKey: cacheKey),
            cachedData,
            "the rejected add must leave the durable shortcut list and outbox untouched"
        )
        XCTAssertTrue(preferences.syncErrorMessage?.contains("256") == true)
    }

    func testRedundantPinRequestsAreNoOpsAndPreserveCatalogState() async throws {
        let suiteName = "ui-customization-redundant-pin-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-redundant-pin-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let pinned = PrimaryMenuItem.library(libraryId: 7, label: "Pinned")
        let response = EffectiveSettingValuesResponse(
            settings: [
                try effective(
                    .navShortcuts,
                    NavigationShortcutsPreference(items: [pinned]),
                    scope: .profile
                ),
            ],
            revision: SettingKey.revision
        )
        let transport = FakeUICustomizationTransport(effectiveResponse: response)
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { "silo.uiCustomization.server.profile.tv" },
            requestIdentity: { testRequestIdentity(family: "tv") },
            initialCapabilityState: .supported
        )
        await preferences.refresh()

        preferences.setLibraryPinned(
            Library(id: 7, name: "Pinned", type: "movies", sortOrder: 0, posterUrl: nil),
            isPinned: true
        )
        preferences.setLibraryPinned(
            Library(id: 8, name: "Absent", type: "movies", sortOrder: 1, posterUrl: nil),
            isPinned: false
        )

        XCTAssertTrue(preferences.isLibraryPinned(7))
        XCTAssertFalse(preferences.isLibraryPinned(8))
        XCTAssertFalse(preferences.isSaving)
        let writtenKeys = await transport.calls(.write).compactMap(\.key)
        XCTAssertTrue(writtenKeys.isEmpty)
    }

    func testPinningIntoFullPrimaryMenuRejectsTheCompoundMutation() throws {
        let suiteName = "ui-customization-menu-limit-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-menu-limit-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let cacheKey = "silo.uiCustomization.server.profile.mobile"
        let menuItems: [[String: Any]] = [
            ["type": "builtin", "destination": "home"],
        ] + (1...63).map { libraryId in
            [
                "type": "library",
                "library_id": libraryId,
                "label": "Library \(libraryId)",
            ]
        }
        let cache: [String: Any] = [
            "primaryMenu": ["items": menuItems],
            "shortcuts": ["items": []],
            "cardPresentation": [
                "poster_size": "standard",
                "caption": "title_metadata",
            ],
            "supportProjection": "supported",
        ]
        let cachedData = try JSONSerialization.data(withJSONObject: cache, options: [.sortedKeys])
        let defaults = SharedDefaults(suite: suite, standard: standard)
        defaults.set(cachedData, forKey: cacheKey)
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: FakeUICustomizationTransport(
                effectiveResponse: FakeUICustomizationTransport.emptyResponse
            ),
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        let overflowLibrary = Library(
            id: 64,
            name: "Overflow Library",
            type: "movies",
            sortOrder: 63,
            posterUrl: nil
        )

        preferences.setLibraryPinned(overflowLibrary, isPinned: true)

        XCTAssertEqual(preferences.primaryMenu?.items.count, 64)
        XCTAssertTrue(preferences.shortcuts.items.isEmpty)
        XCTAssertFalse(preferences.isSaving, "a rejected compound add must not enqueue either write")
        XCTAssertEqual(defaults.data(forKey: cacheKey), cachedData)
        XCTAssertTrue(preferences.syncErrorMessage?.contains("64") == true)
    }

    func testDefinitiveShortcutRejectionReconcilesWithoutReplayingTheOutbox() async throws {
        let suiteName = "ui-customization-definitive-rejection-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-definitive-rejection-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let cacheKey = "silo.uiCustomization.server.profile.tv"
        let defaults = SharedDefaults(suite: suite, standard: standard)
        // Fixed responses rather than rows: neither carries the card key.
        func response(shortcutCount: Int) throws -> EffectiveSettingValuesResponse {
            let items = (1...shortcutCount).map {
                PrimaryMenuItem.library(libraryId: $0, label: "Library \($0)")
            }
            return EffectiveSettingValuesResponse(
                settings: [
                    EffectiveSettingValue(
                        key: SettingKey.navPrimaryMenu.rawValue,
                        value: try SettingJSONValue.encoding(
                            PrimaryMenuPreference(items: [.builtin(.home)])
                        ),
                        source: .scope(.profileClient),
                        scope: .profileClient,
                        profileId: "profile",
                        clientFamily: "tv"
                    ),
                    EffectiveSettingValue(
                        key: SettingKey.navShortcuts.rawValue,
                        value: try SettingJSONValue.encoding(
                            NavigationShortcutsPreference(items: items)
                        ),
                        source: .scope(.profile),
                        scope: .profile,
                        profileId: "profile"
                    ),
                ],
                revision: SettingKey.revision
            )
        }
        let before = try response(shortcutCount: 255)
        let after = try response(shortcutCount: 256)
        let transport = FakeUICustomizationTransport(effectiveResponse: before)
        await transport.hold(.shortcuts)
        await transport.fail(
            .shortcuts,
            with: .api(.invalidValue(message: "items must contain at most 256 entries"))
        )
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        let racedLibrary = Library(
            id: 257,
            name: "Raced Pin",
            type: "movies",
            sortOrder: 256,
            posterUrl: nil
        )

        await preferences.refresh()
        XCTAssertEqual(preferences.shortcuts.items.count, 255)
        XCTAssertFalse(preferences.primaryMenuUsesDeviceOverride)

        preferences.setLibraryPinned(racedLibrary, isPinned: true)
        await transport.waitForStarted(.shortcut, count: 1)
        await transport.setEffectiveResponse(after)
        await transport.release(.shortcuts)
        await transport.waitForCompleted(.shortcut, count: 1)
        await preferences.refresh()
        await preferences.refresh()

        let shortcutWriteAttempts = await transport.calls(.shortcut).count
        let effectiveReads = await transport.calls(.read).count
        let primaryMenuWriteAttempts = await transport.calls(.put)
            .filter { $0.key == .navPrimaryMenu }
            .count
        XCTAssertEqual(shortcutWriteAttempts, 1)
        XCTAssertEqual(
            primaryMenuWriteAttempts,
            0,
            "a rejected profile shortcut must not commit only its family-menu placement"
        )
        XCTAssertGreaterThanOrEqual(
            effectiveReads,
            2,
            "overlapping refreshes may coalesce, but one authoritative read must follow the rejection"
        )
        XCTAssertEqual(preferences.shortcuts.items.count, 256)
        XCTAssertFalse(preferences.isLibraryPinned(racedLibrary.id))
        XCTAssertEqual(preferences.primaryMenu?.items, [.builtin(.home)])
        XCTAssertTrue(preferences.syncErrorMessage?.contains("256") == true)

        let cachedData = try XCTUnwrap(defaults.data(forKey: cacheKey))
        let cache = try XCTUnwrap(
            JSONSerialization.jsonObject(with: cachedData) as? [String: Any]
        )
        XCTAssertNil(
            cache["pendingShortcutOperations"],
            "a definitive rejection must be quarantined from the durable retry outbox"
        )
    }

    func testOfflineShortcutOperationIsDurablyReplayedWithTheSameMutationId() async throws {
        let suiteName = "ui-customization-shortcut-outbox-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-shortcut-outbox-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let transport = FakeUICustomizationTransport(rows: [
            try .init(.navShortcuts, .profile, encoding: NavigationShortcutsPreference.empty),
        ])
        await transport.fail(.shortcuts)
        let cacheKey = "silo.uiCustomization.server.profile.mobile"
        let library = Library(
            id: 7,
            name: "Movies",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let offline = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )

        offline.setLibraryPinned(library, isPinned: true)
        await transport.waitForStarted(.shortcut, count: 1)
        await transport.stopFailing(.shortcuts)

        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        XCTAssertEqual(restarted.shortcuts.items.map(\.id), ["library:7"])

        await restarted.refresh()

        let steps = await transport.steps()
        let shortcutOperations = await transport.calls(.shortcut)
        XCTAssertEqual(steps, [
            .shortcut(id: "library:7", present: true, .failed),
            .shortcut(id: "library:7", present: true, .succeeded),
            .put(.navPrimaryMenu, .succeeded),
            .read(.succeeded),
        ])
        XCTAssertEqual(shortcutOperations.compactMap(\.present), [true, true])
        XCTAssertEqual(shortcutOperations.count, 2)
        XCTAssertEqual(
            Set(shortcutOperations.compactMap(\.item?.id)),
            ["library:7"],
            "an ambiguous atomic operation is retried as the same desired state after restart"
        )
        XCTAssertEqual(restarted.shortcuts.items.map(\.id), ["library:7"])
        XCTAssertNil(restarted.syncErrorMessage)
    }

    func testAuthenticationFailureKeepsShortcutIntentForReplay() async throws {
        let suiteName = "ui-customization-shortcut-auth-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-shortcut-auth-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let transport = FakeUICustomizationTransport(rows: [
            try .init(.navShortcuts, .profile, encoding: NavigationShortcutsPreference.empty),
        ])
        await transport.fail(.shortcuts, with: .api(.server(
            status: 401,
            code: "unauthorized",
            message: "profile authentication expired"
        )))
        let cacheKey = "silo.uiCustomization.server.profile.mobile"
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        let library = Library(
            id: 7,
            name: "Movies",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )

        preferences.setLibraryPinned(library, isPinned: true)
        await transport.waitForStarted(.shortcut, count: 1)
        let failedCacheData = try XCTUnwrap(defaults.data(forKey: cacheKey))
        let failedCache = try XCTUnwrap(
            JSONSerialization.jsonObject(with: failedCacheData) as? [String: Any]
        )
        XCTAssertNotNil(
            failedCache["pendingShortcutOperations"],
            "authentication failures must retain replayable user intent"
        )

        await transport.stopFailing(.shortcuts)
        await preferences.refresh()

        let shortcutOperations = await transport.calls(.shortcut)
        XCTAssertEqual(shortcutOperations.count, 2)
        XCTAssertEqual(Set(shortcutOperations.compactMap(\.item?.id)), ["library:7"])
        XCTAssertTrue(preferences.isLibraryPinned(library.id))
        XCTAssertNil(preferences.syncErrorMessage)
    }

    func testOfflineShortcutOperationsPreserveCrossIdentityOrderAfterRestart() async throws {
        let suiteName = "ui-customization-shortcut-sequence-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-shortcut-sequence-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let transport = FakeUICustomizationTransport(rows: [
            try .init(.navShortcuts, .profile, encoding: NavigationShortcutsPreference.empty),
        ])
        await transport.fail(.shortcuts)
        let cacheKey = "silo.uiCustomization.server.profile.tv"
        let libraryB = Library(
            id: 20,
            name: "Library B",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let libraryA = Library(
            id: 10,
            name: "Library A",
            type: "movies",
            sortOrder: 1,
            posterUrl: nil
        )
        let offline = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )

        offline.setLibraryPinned(libraryB, isPinned: true)
        await transport.waitForStarted(.shortcut, count: 1)
        offline.setLibraryPinned(libraryA, isPinned: true)
        await transport.waitForStarted(.shortcut, count: 2)
        await transport.stopFailing(.shortcuts)

        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        XCTAssertEqual(restarted.shortcuts.items.map(\.id), ["library:20", "library:10"])

        await restarted.refresh()

        let shortcutOperations = await transport.calls(.shortcut)
        let storedShortcuts = await transport.stored(
            .navShortcuts,
            at: .profile,
            as: NavigationShortcutsPreference.self
        )?.items
        XCTAssertEqual(
            shortcutOperations.compactMap(\.item?.id),
            ["library:20", "library:10", "library:20", "library:10"],
            "restart replay must follow the user's cross-library edit order, not semantic ID order"
        )
        XCTAssertEqual(storedShortcuts?.map(\.id), ["library:20", "library:10"])
        XCTAssertEqual(restarted.shortcuts.items.map(\.id), ["library:20", "library:10"])
        XCTAssertNil(restarted.syncErrorMessage)
    }

    func testNewerOppositeShortcutIntentSurvivesOlderInFlightSuccess() async throws {
        let suiteName = "ui-customization-shortcut-order-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-shortcut-order-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let transport = FakeUICustomizationTransport(
            rows: [try .init(.navShortcuts, .profile, encoding: NavigationShortcutsPreference.empty)],
            persistsPuts: false
        )
        await transport.hold(.shortcuts)
        let cacheKey = "silo.uiCustomization.server.profile.tv"
        let library = Library(
            id: 9,
            name: "Documentaries",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )

        preferences.setLibraryPinned(library, isPinned: true)
        await transport.waitForStarted(.shortcut, count: 1)
        preferences.setLibraryPinned(library, isPinned: false)
        XCTAssertFalse(preferences.shortcuts.items.contains { $0.id == "library:9" })

        await transport.release(.shortcuts)
        await transport.waitForCompleted(.shortcut, count: 2)

        let firstShortcutOperations = await transport.calls(.shortcut)
        let firstStored = await transport.stored(
            .navShortcuts,
            at: .profile,
            as: NavigationShortcutsPreference.self
        )
        let firstStoredShortcuts = try XCTUnwrap(firstStored).items
        let firstGenericPutCount = await transport.calls(.put).count
        XCTAssertEqual(firstShortcutOperations.compactMap(\.present), [true, false])
        XCTAssertTrue(firstStoredShortcuts.isEmpty)
        XCTAssertEqual(
            firstGenericPutCount,
            0,
            "a superseded add followed by an accepted remove leaves the family menu unchanged"
        )

        // If the first success had cleared the newer cached operation, this
        // restart would replay the add or leave a pending add behind.
        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await restarted.refresh()

        let finalShortcutOperationCount = await transport.calls(.shortcut).count
        XCTAssertEqual(finalShortcutOperationCount, 2)
        XCTAssertTrue(restarted.shortcuts.items.isEmpty)
        XCTAssertNil(restarted.syncErrorMessage)
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
        let desired = CardPresentationPreset.artworkOnly.presentation

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
        let desired = CardPresentationPreset.artworkOnly.presentation

        preferences.setCardPresentation(desired)
        await transport.waitForStarted(.put, count: 3)
        for _ in 0..<200 where !preferences.hasHeldChanges {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(preferences.hasHeldChanges, "the change is held once the bound runs out")
        XCTAssertEqual(preferences.syncErrorMessage, HeldSettingChange.message)
        try await Task.sleep(for: .milliseconds(50))
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
        let desired = CardPresentationPreset.artworkOnly.presentation

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
        let desired = CardPresentationPreset.artworkOnly.presentation
        let authored = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )

        authored.setCardPresentation(desired)
        let customMenu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.calendar),
        ])
        authored.setPrimaryMenuItems(customMenu.items)
        await transport.waitForStarted(.put, count: 2)

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
        XCTAssertEqual(unavailable.primaryMenu, customMenu)
        XCTAssertEqual(putAttempts, 2)
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
        XCTAssertEqual(unavailable.primaryMenu, customMenu)
        XCTAssertEqual(putAttempts, 2)
        XCTAssertEqual(effectiveReads, 0)

        await transport.setCapabilities(.serverUpgradeRequired)
        await unavailable.refresh()

        putAttempts = await transport.calls(.put).count
        effectiveReads = await transport.calls(.read).count
        XCTAssertEqual(unavailable.capabilityState, .serverUpgradeRequired)
        XCTAssertEqual(unavailable.supportProjection, .knownUnsupported)
        XCTAssertEqual(unavailable.cardPresentation, .standard)
        XCTAssertNil(unavailable.primaryMenu)
        XCTAssertEqual(putAttempts, 2, "a known old server must not receive the outbox")
        XCTAssertEqual(effectiveReads, 0)

        await transport.setCapabilities(.available(FakeUICustomizationTransport.capabilities(batchedEffective: false)))
        await unavailable.refresh()

        putAttempts = await transport.calls(.put).count
        effectiveReads = await transport.calls(.read).count
        XCTAssertEqual(unavailable.capabilityState, .serverUpgradeRequired)
        XCTAssertEqual(unavailable.supportProjection, .knownUnsupported)
        XCTAssertFalse(unavailable.allowsEditing)
        XCTAssertEqual(unavailable.cardPresentation, .standard)
        XCTAssertNil(unavailable.primaryMenu)
        XCTAssertFalse(unavailable.hasExplicitPrimaryMenu)
        XCTAssertEqual(
            putAttempts,
            2,
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
        XCTAssertNil(unavailable.primaryMenu)
        XCTAssertEqual(putAttempts, 2)
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
        XCTAssertNil(restartedKnownUnsupported.primaryMenu)

        await transport.setCapabilities(.available(FakeUICustomizationTransport.capabilities(atomicShortcuts: false)))
        await unavailable.refresh()

        putAttempts = await transport.calls(.put).count
        effectiveReads = await transport.calls(.read).count
        XCTAssertEqual(unavailable.capabilityState, .serverUpgradeRequired)
        XCTAssertFalse(unavailable.allowsEditing)
        XCTAssertEqual(unavailable.cardPresentation, .standard)
        XCTAssertNil(unavailable.primaryMenu)
        XCTAssertEqual(putAttempts, 2, "an old server must not receive revision-5 writes")
        XCTAssertEqual(effectiveReads, 0)

        await transport.setCapabilities(.available(FakeUICustomizationTransport.capabilities(clientFamilies: ["tv", "web"])))
        await unavailable.refresh()

        putAttempts = await transport.calls(.put).count
        effectiveReads = await transport.calls(.read).count
        XCTAssertEqual(unavailable.capabilityState, .serverUpgradeRequired)
        XCTAssertFalse(unavailable.allowsEditing)
        XCTAssertEqual(unavailable.cardPresentation, .standard)
        XCTAssertNil(unavailable.primaryMenu)
        XCTAssertEqual(
            putAttempts,
            2,
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
                    encoding: CardPresentationPreset.compact.presentation
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
        XCTAssertEqual(preferences.cardPresentation, CardPresentationPreset.compact.presentation)

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

        preferences.setCardPresentation(CardPresentationPreset.compact.presentation)
        preferences.setCardPresentation(CardPresentationPreset.artworkOnly.presentation)
        await transport.waitForStarted(.put, count: 1)

        identity.value = HTTPRequestIdentity(
            serverId: "server-b",
            serverURL: "http://server-b.invalid",
            profileId: "profile-b",
            clientFamily: "mobile"
        )
        await transport.release(.puts)
        try await Task.sleep(nanoseconds: 50_000_000)

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

        let menu = PrimaryMenuPreference(items: [.builtin(.home), .builtin(.movies)])
        let response = EffectiveSettingValuesResponse(
            settings: [
                EffectiveSettingValue(
                    key: SettingKey.navPrimaryMenu.rawValue,
                    value: try SettingJSONValue.encoding(menu),
                    source: .scope(.profileDevice),
                    scope: .profileDevice,
                    profileId: "profile",
                    deviceId: "device"
                ),
                EffectiveSettingValue(
                    key: SettingKey.uiCardPresentation.rawValue,
                    value: try SettingJSONValue.encoding(CardPresentationPreset.compact.presentation),
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

        XCTAssertTrue(preferences.primaryMenuUsesDeviceOverride)
        XCTAssertTrue(preferences.cardPresentationUsesDeviceOverride)
        XCTAssertTrue(preferences.hasDeviceOverrides)
    }

    func testSuccessfulDeviceDeleteReconcilesWhenSiblingFailsAndOnlyFailureReplays() async throws {
        let suiteName = "ui-customization-partial-device-delete-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-partial-device-delete-standard-\(UUID().uuidString)"
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
        await transport.fail(.delete(.navPrimaryMenu))
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await preferences.refresh()
        XCTAssertTrue(preferences.primaryMenuUsesDeviceOverride)
        XCTAssertTrue(preferences.cardPresentationUsesDeviceOverride)

        preferences.useFamilySettings()
        while preferences.isSaving { await Task.yield() }

        XCTAssertTrue(
            preferences.primaryMenuUsesDeviceOverride,
            "the failed device delete must keep its effective value and source"
        )
        XCTAssertFalse(
            preferences.cardPresentationUsesDeviceOverride,
            "the successful sibling must reconcile even while another delete remains pending"
        )
        XCTAssertEqual(preferences.cardPresentation, .standard)
        XCTAssertNotNil(preferences.syncErrorMessage)

        var deleteKeys = await transport.calls(.delete).compactMap(\.key)
        let targetedReadKeys = await transport.calls(.read).compactMap(\.keys)
            .filter { $0.count == 1 }
            .flatMap { $0 }
        XCTAssertEqual(deleteKeys, [.navPrimaryMenu, .uiCardPresentation])
        XCTAssertEqual(targetedReadKeys, [.uiCardPresentation])

        let restarted = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await restarted.refresh()

        deleteKeys = await transport.calls(.delete).compactMap(\.key)
        XCTAssertEqual(
            deleteKeys,
            [.navPrimaryMenu, .uiCardPresentation, .navPrimaryMenu],
            "restart must replay only the failed device delete"
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
        await transport.fail(.read(keys: [.navPrimaryMenu]), times: 1)
        let preferences = UICustomizationPreferences(
            defaults: defaults,
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        await preferences.refresh()
        preferences.useFamilySettings()
        while preferences.isSaving { await Task.yield() }

        XCTAssertTrue(
            preferences.primaryMenuUsesDeviceOverride,
            "a successful delete without its inherited value must retain the safe cached pair"
        )
        XCTAssertFalse(preferences.cardPresentationUsesDeviceOverride)
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
        let targetedReadKeys = await transport.calls(.read).compactMap(\.keys)
            .filter { $0.count == 1 }
            .flatMap { $0 }
        XCTAssertEqual(
            deleteKeys,
            [.navPrimaryMenu, .uiCardPresentation, .navPrimaryMenu],
            "only the delete whose effective read failed remains in the durable outbox"
        )
        XCTAssertEqual(
            targetedReadKeys,
            [.navPrimaryMenu, .uiCardPresentation, .navPrimaryMenu]
        )
        XCTAssertFalse(restarted.primaryMenuUsesDeviceOverride)
        XCTAssertFalse(restarted.cardPresentationUsesDeviceOverride)
        XCTAssertEqual(
            restarted.primaryMenu,
            PrimaryMenuPreference(items: [.builtin(.home), .builtin(.series)])
        )
        XCTAssertEqual(restarted.cardPresentation, .standard)
        XCTAssertNil(restarted.syncErrorMessage)
    }

    func testRefreshReconcilesValidKeysAndPreservesEachInvalidValueAndSource() async throws {
        let suiteName = "ui-customization-independent-decode-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-independent-decode-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let originalMenu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.movies),
        ])
        let updatedMenu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.series),
        ])
        let updatedShortcuts = NavigationShortcutsPreference(items: [
            .library(libraryId: 8, label: "Pinned"),
        ])
        let initialResponse = EffectiveSettingValuesResponse(
            settings: [
                EffectiveSettingValue(
                    key: SettingKey.navPrimaryMenu.rawValue,
                    value: try SettingJSONValue.encoding(originalMenu),
                    source: .scope(.profileDevice),
                    scope: .profileDevice,
                    profileId: "profile",
                    deviceId: "device"
                ),
                EffectiveSettingValue(
                    key: SettingKey.navShortcuts.rawValue,
                    value: try SettingJSONValue.encoding(NavigationShortcutsPreference.empty),
                    source: .scope(.profile),
                    scope: .profile,
                    profileId: "profile"
                ),
                EffectiveSettingValue(
                    key: SettingKey.uiCardPresentation.rawValue,
                    value: try SettingJSONValue.encoding(
                        CardPresentationPreset.compact.presentation
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
                    key: SettingKey.navPrimaryMenu.rawValue,
                    value: try SettingJSONValue.encoding(updatedMenu),
                    source: .scope(.profileClient),
                    scope: .profileClient,
                    profileId: "profile",
                    clientFamily: "mobile"
                ),
                EffectiveSettingValue(
                    key: SettingKey.navShortcuts.rawValue,
                    value: try SettingJSONValue.encoding(updatedShortcuts),
                    source: .scope(.profile),
                    scope: .profile,
                    profileId: "profile"
                ),
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

        XCTAssertEqual(preferences.primaryMenu, updatedMenu)
        XCTAssertFalse(preferences.primaryMenuUsesDeviceOverride)
        XCTAssertEqual(preferences.shortcuts, updatedShortcuts)
        XCTAssertEqual(preferences.cardPresentation, CardPresentationPreset.compact.presentation)
        XCTAssertTrue(
            preferences.cardPresentationUsesDeviceOverride,
            "a failed decode must retain the matching prior source with its prior value"
        )
        XCTAssertNotNil(preferences.syncErrorMessage)

        let invalidMenu = PrimaryMenuPreference(items: [.builtin(.movies)])
        await transport.setEffectiveResponse(EffectiveSettingValuesResponse(
            settings: [
                EffectiveSettingValue(
                    key: SettingKey.navPrimaryMenu.rawValue,
                    value: try SettingJSONValue.encoding(invalidMenu),
                    source: .scope(.profileDevice),
                    scope: .profileDevice,
                    profileId: "profile",
                    deviceId: "device"
                ),
                EffectiveSettingValue(
                    key: SettingKey.navShortcuts.rawValue,
                    value: try SettingJSONValue.encoding(updatedShortcuts),
                    source: .scope(.profile),
                    scope: .profile,
                    profileId: "profile"
                ),
                EffectiveSettingValue(
                    key: SettingKey.uiCardPresentation.rawValue,
                    value: try SettingJSONValue.encoding(
                        CardPresentationPreset.artworkOnly.presentation
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

        XCTAssertEqual(preferences.primaryMenu, updatedMenu)
        XCTAssertFalse(
            preferences.primaryMenuUsesDeviceOverride,
            "an invalid menu must not pair its source with the previous valid menu"
        )
        XCTAssertEqual(
            preferences.cardPresentation,
            CardPresentationPreset.artworkOnly.presentation
        )
        XCTAssertFalse(preferences.cardPresentationUsesDeviceOverride)
        XCTAssertNotNil(preferences.syncErrorMessage)

        let cached = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        XCTAssertEqual(cached.primaryMenu, updatedMenu)
        XCTAssertEqual(cached.shortcuts, updatedShortcuts)
        XCTAssertEqual(cached.cardPresentation, CardPresentationPreset.artworkOnly.presentation)
        XCTAssertFalse(cached.primaryMenuUsesDeviceOverride)
        XCTAssertFalse(cached.cardPresentationUsesDeviceOverride)
    }

    func testDeviceMenuOverrideDoesNotBlockProfileLibraryPin() async throws {
        let suiteName = "ui-customization-device-menu-pin-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-device-menu-pin-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let deviceMenu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .builtin(.movies),
        ])
        let response = EffectiveSettingValuesResponse(
            settings: [
                EffectiveSettingValue(
                    key: SettingKey.navPrimaryMenu.rawValue,
                    value: try SettingJSONValue.encoding(deviceMenu),
                    source: .scope(.profileDevice),
                    scope: .profileDevice,
                    profileId: "profile",
                    deviceId: "device"
                ),
            ],
            revision: SettingKey.revision
        )
        let transport = FakeUICustomizationTransport(effectiveResponse: response)
        let cacheKey = "silo.uiCustomization.server.profile.tv"
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: transport,
            cacheKey: { cacheKey },
            requestIdentity: { testRequestIdentity(for: cacheKey) },
            initialCapabilityState: .supported
        )
        let library = Library(
            id: 7,
            name: "Movies",
            type: "movies",
            sortOrder: 0,
            posterUrl: nil
        )

        await preferences.refresh()
        preferences.setLibraryPinned(library, isPinned: true)
        await transport.waitForCompleted(.write, count: 1)
        let writtenKeys = await transport.calls(.write).compactMap(\.key)

        XCTAssertTrue(preferences.primaryMenuUsesDeviceOverride)
        XCTAssertEqual(preferences.primaryMenu, deviceMenu)
        XCTAssertTrue(preferences.isLibraryPinned(library.id))
        XCTAssertEqual(
            writtenKeys,
            [.navShortcuts],
            "the independent profile shortcut should sync without rewriting the device menu"
        )
    }

    func testPinnedLibraryStateTracksShortcutCatalogInsteadOfMenuPlacement() async throws {
        let suiteName = "ui-customization-pinned-state-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-pinned-state-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let shortcutOnly = PrimaryMenuItem.library(libraryId: 7, label: "Hidden Pin")
        let menuOnly = PrimaryMenuItem.library(libraryId: 9, label: "Menu Only")
        let response = EffectiveSettingValuesResponse(
            settings: [
                try effective(
                    .navPrimaryMenu,
                    PrimaryMenuPreference(items: [.builtin(.home), menuOnly]),
                    scope: .profileClient
                ),
                try effective(
                    .navShortcuts,
                    NavigationShortcutsPreference(items: [shortcutOnly]),
                    scope: .profile
                ),
            ],
            revision: SettingKey.revision
        )
        let preferences = UICustomizationPreferences(
            defaults: SharedDefaults(suite: suite, standard: standard),
            transport: FakeUICustomizationTransport(effectiveResponse: response),
            cacheKey: { "silo.uiCustomization.server.profile.mobile" },
            requestIdentity: { testRequestIdentity(family: "mobile") },
            initialCapabilityState: .supported
        )

        await preferences.refresh()

        XCTAssertTrue(
            preferences.isLibraryPinned(7),
            "hiding a library from this family's menu must not turn off its profile shortcut toggle"
        )
        XCTAssertFalse(
            preferences.isLibraryPinned(9),
            "menu placement alone is not membership in the profile shortcut catalog"
        )
    }

    func testProfileShortcutDoesNotPopulateFamilyDefaultMenu() async throws {
        let suiteName = "ui-customization-family-default-suite-\(UUID().uuidString)"
        let standardName = "ui-customization-family-default-standard-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            UserDefaults().removePersistentDomain(forName: suiteName)
            UserDefaults().removePersistentDomain(forName: standardName)
        }

        let shortcut = PrimaryMenuItem.library(libraryId: 7, label: "Movies")
        let response = EffectiveSettingValuesResponse(
            settings: [
                try effective(
                    .navShortcuts,
                    NavigationShortcutsPreference(items: [shortcut]),
                    scope: .profile
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

        XCTAssertTrue(preferences.isLibraryPinned(7))
        XCTAssertNil(preferences.primaryMenu)
        XCTAssertFalse(
            preferences.resolvedPrimaryMenuItems().contains { $0.id == shortcut.id },
            "a profile shortcut must remain hidden until this family authors its placement"
        )
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

        let menu = PrimaryMenuPreference(items: [
            .builtin(.home),
            .library(libraryId: 7, label: "Movies"),
            .builtin(.forYou),
        ])
        let shortcuts = NavigationShortcutsPreference(items: [
            .builtin(.calendar), // Invalid for nav.shortcuts and must be discarded.
            .section(libraryId: 7, sectionId: "recently-added", label: "Recently Added"),
        ])
        let cards = CardPresentationPreference(posterSize: .large, caption: .artwork)
        let response = EffectiveSettingValuesResponse(
            settings: [
                try effective(.navPrimaryMenu, menu, scope: .profileClient),
                try effective(.navShortcuts, shortcuts, scope: .profile),
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

        XCTAssertEqual(online.primaryMenu, menu)
        XCTAssertEqual(online.shortcuts.items, Array(shortcuts.items.dropFirst()))
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
        XCTAssertEqual(offline.primaryMenu, menu)
        XCTAssertEqual(offline.cardPresentation, cards)

        await offline.refresh()

        XCTAssertEqual(offline.primaryMenu, menu, "a failed refresh must not erase the cached menu")
        XCTAssertEqual(offline.cardPresentation, cards)
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

    /// Server rows where this device overrides the family menu and the card
    /// presentation.
    private func deviceOverrideRows() throws -> [FakeUICustomizationTransport.Row] {
        [
            try .init(
                .navPrimaryMenu,
                .profileDevice,
                encoding: PrimaryMenuPreference(items: [.builtin(.home), .builtin(.movies)])
            ),
            try .init(
                .navPrimaryMenu,
                .profileClient,
                encoding: PrimaryMenuPreference(items: [.builtin(.home), .builtin(.series)])
            ),
            try .init(.navShortcuts, .profile, encoding: NavigationShortcutsPreference.empty),
            try .init(
                .uiCardPresentation,
                .profileDevice,
                encoding: CardPresentationPreset.compact.presentation
            ),
        ]
    }

    /// Server rows holding a family menu and the profile shortcut catalog.
    private func menuAndShortcutRows(
        menu: PrimaryMenuPreference = .init(items: [.builtin(.home)]),
        shortcuts: [PrimaryMenuItem] = []
    ) throws -> [FakeUICustomizationTransport.Row] {
        [
            try .init(.navPrimaryMenu, .profileClient, encoding: menu),
            try .init(.navShortcuts, .profile, encoding: NavigationShortcutsPreference(items: shortcuts)),
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
