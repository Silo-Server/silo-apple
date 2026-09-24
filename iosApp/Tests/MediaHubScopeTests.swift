import XCTest
@testable import Silo

@MainActor
final class MediaHubScopeTests: XCTestCase {
    private func library(_ id: Int, _ type: String, _ name: String? = nil) -> Library {
        Library(id: id, name: name ?? "Library \(id)", type: type, sortOrder: id, posterUrl: nil)
    }

    func testFixedTabBarShowsWatchListenAndTheChosenLastTab() {
        let libraries = [library(1, "movies"), library(2, "series"), library(3, "audiobooks", "Books")]

        let bar = appleFixedTabDestinations(
            libraries: libraries,
            showAudiobooks: true,
            downloadsEnabled: true,
            lastTab: .downloads
        )

        XCTAssertEqual(
            bar.map(\.id),
            [.app(.home), .watch, .listen, .app(.recommendations), .app(.downloads)]
        )
        XCTAssertEqual(bar[2].title, "Listen")
    }

    func testListenNeedsTheOptInAndAnAudiobookLibrary() {
        let video = [library(1, "movies")]
        let withBooks = video + [library(3, "audiobooks")]

        let optedOut = appleFixedTabDestinations(
            libraries: withBooks, showAudiobooks: false, downloadsEnabled: true, lastTab: .downloads
        )
        let noBooks = appleFixedTabDestinations(
            libraries: video, showAudiobooks: true, downloadsEnabled: true, lastTab: .downloads
        )

        XCTAssertFalse(optedOut.contains { $0.id == .listen })
        XCTAssertFalse(noBooks.contains { $0.id == .listen })
    }

    func testWatchNeedsAVideoLibrary() {
        let bar = appleFixedTabDestinations(
            libraries: [library(3, "audiobooks")], showAudiobooks: true, downloadsEnabled: true, lastTab: .favorites
        )
        XCTAssertEqual(bar.map(\.id), [.app(.home), .listen, .app(.recommendations), .favorites])
    }

    func testUnavailableLastTabFallsBackToDownloadsThenCalendar() {
        let libraries = [library(1, "movies", "Anime")]

        XCTAssertEqual(
            resolvedLastTabDestination(.library(1), libraries: libraries, downloadsEnabled: true).id,
            .library(1)
        )
        XCTAssertEqual(
            resolvedLastTabDestination(.library(99), libraries: libraries, downloadsEnabled: true).id,
            .app(.downloads)
        )
        XCTAssertEqual(
            resolvedLastTabDestination(.downloads, libraries: libraries, downloadsEnabled: false).id,
            .app(.calendar)
        )
    }

    func testAudiobookLastTabNeedsTheOptIn() {
        let libraries = [library(1, "movies"), library(4, "audiobooks")]

        let optedIn = appleFixedTabDestinations(
            libraries: libraries, showAudiobooks: true, downloadsEnabled: true, lastTab: .library(4)
        )
        XCTAssertEqual(optedIn.last?.id, .library(4))
        let optedOut = appleFixedTabDestinations(
            libraries: libraries, showAudiobooks: false, downloadsEnabled: true, lastTab: .library(4)
        )
        XCTAssertEqual(optedOut.last?.id, .app(.downloads))
    }

    func testLastTabChoiceRoundTripsThroughStorage() {
        for choice in [LastTabChoice.downloads, .favorites, .calendar, .library(42)] {
            XCTAssertEqual(LastTabChoice(storageValue: choice.storageValue), choice)
        }
        XCTAssertNil(LastTabChoice(storageValue: "library:abc"))
        XCTAssertNil(LastTabChoice(storageValue: "search"))
    }

    func testLibraryTabRequestResolvesToWatch() {
        let visible = appleFixedTabDestinations(
            libraries: [library(1, "movies")], showAudiobooks: false, downloadsEnabled: true, lastTab: .downloads
        )
        XCTAssertEqual(resolvedRequestedMainTabDestination(.libraries, visibleDestinations: visible), .watch)
    }

    func testMixedLibrariesAppearUnderBothKinds() {
        let libraries = [library(1, "movies"), library(2, "series"), library(3, "mixed"), library(4, "audiobooks")]

        XCTAssertEqual(MediaHubScope.libraries(for: .movies, in: libraries).map(\.id), [1, 3])
        XCTAssertEqual(MediaHubScope.libraries(for: .shows, in: libraries).map(\.id), [2, 3])
        XCTAssertEqual(MediaHubScope.availableKinds(for: .watch, in: libraries), [.allVideo, .movies, .shows])
        XCTAssertEqual(
            MediaHubScope.availableKinds(for: .watch, in: [library(1, "movies")]),
            [.movies],
            "All is only offered when there is something to combine"
        )
    }

    func testSingleLibraryAlwaysSelectedAndStaleSelectionFallsBackToAll() {
        let one = [library(1, "movies")]
        XCTAssertEqual(MediaHubScope.resolvedLibraryId(kind: .movies, storedLibraryId: nil, kindLibraries: one), 1)

        let many = [library(1, "movies"), library(2, "movies")]
        XCTAssertEqual(MediaHubScope.resolvedLibraryId(kind: .movies, storedLibraryId: 2, kindLibraries: many), 2)
        XCTAssertNil(MediaHubScope.resolvedLibraryId(kind: .movies, storedLibraryId: 99, kindLibraries: many))
        XCTAssertNil(MediaHubScope.resolvedLibraryId(kind: .movies, storedLibraryId: nil, kindLibraries: many))
    }

    func testTitleMenuListsOnlyTheCurrentKindsLibrariesUnderItsSegments() {
        let libraries = [
            library(1, "movies", "Movies"),
            library(2, "movies", "Movies - Anime"),
            library(3, "series", "TV Shows"),
            library(4, "audiobooks", "Books"),
        ]

        let movies = MediaHubScope.menu(for: .watch, kind: .movies, in: libraries)
        XCTAssertEqual(movies.kinds, [.allVideo, .movies, .shows])
        XCTAssertEqual(movies.kinds.map(\.segmentTitle), ["All", "Movies", "Shows"])
        XCTAssertEqual(movies.options.map(\.title), ["All Movies", "Movies", "Movies - Anime"])
        XCTAssertEqual(movies.options[0].selection, .init(kind: .movies, libraryId: nil))
        XCTAssertEqual(movies.options[2].selection, .init(kind: .movies, libraryId: 2))

        let shows = MediaHubScope.menu(for: .watch, kind: .shows, in: libraries)
        XCTAssertEqual(shows.options.map(\.title), ["TV Shows"], "a one-library kind names its library")
        XCTAssertEqual(shows.options[0].selection, .init(kind: .shows, libraryId: nil))

        XCTAssertTrue(MediaHubScope.menu(for: .watch, kind: .allVideo, in: libraries).options.isEmpty)
    }

    func testTitleMenuIsEmptyWhenThereIsNothingToPick() {
        XCTAssertTrue(MediaHubScope.menu(for: .listen, kind: .audiobooks, in: [library(4, "audiobooks")]).isEmpty)

        let twoBookLibraries = [library(4, "audiobooks", "Books"), library(5, "audiobooks", "Kids")]
        let listen = MediaHubScope.menu(for: .listen, kind: .audiobooks, in: twoBookLibraries)
        XCTAssertTrue(listen.kinds.isEmpty, "one kind needs no switch")
        XCTAssertEqual(listen.options.map(\.title), ["All Audiobooks", "Books", "Kids"])
    }

    func testHeaderNamesTheScopeAndWhatItBelongsToWithoutCounts() {
        let movies = [library(1, "movies", "Movies"), library(2, "movies", "Movies - Anime")]
        let books = [library(4, "audiobooks", "Audiobooks English")]

        XCTAssertEqual(
            MediaHubScope.header(hub: .watch, kind: .allVideo, library: nil, kindLibraries: movies),
            .init(title: "Watch", subtitle: "Movies & Shows")
        )
        XCTAssertEqual(
            MediaHubScope.header(hub: .watch, kind: .movies, library: nil, kindLibraries: movies),
            .init(title: "Movies", subtitle: "All libraries")
        )
        XCTAssertEqual(
            MediaHubScope.header(hub: .watch, kind: .movies, library: movies[1], kindLibraries: movies),
            .init(title: "Movies - Anime", subtitle: "Movies library"),
            "library names are shown exactly as the server has them"
        )
        XCTAssertEqual(
            MediaHubScope.header(hub: .listen, kind: .audiobooks, library: books[0], kindLibraries: books),
            .init(title: "Audiobooks", subtitle: "Audiobooks English")
        )
    }

    func testMenuCheckmarkFoldsASingleLibraryIntoItsKind() {
        let one = [library(3, "series")]
        let two = [library(1, "movies"), library(2, "movies")]
        XCTAssertEqual(
            MediaHubScope.currentSelection(kind: .shows, libraryId: 3, kindLibraries: one),
            .init(kind: .shows, libraryId: nil)
        )
        XCTAssertEqual(
            MediaHubScope.currentSelection(kind: .movies, libraryId: 2, kindLibraries: two),
            .init(kind: .movies, libraryId: 2)
        )
    }

    func testSelectionMemoryIsScopedPerProfileAndKind() throws {
        let suite = "MediaHubScopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let alice = MediaHubSelectionStore(
            hub: .watch,
            authority: MainTabLibraryAuthority(serverId: "s", profileId: "alice"),
            defaults: defaults
        )
        let bob = MediaHubSelectionStore(
            hub: .watch,
            authority: MainTabLibraryAuthority(serverId: "s", profileId: "bob"),
            defaults: defaults
        )

        alice.setKind(.shows)
        alice.setLibraryId(3, for: .movies)
        XCTAssertEqual(alice.storedKind(), .shows)
        XCTAssertEqual(alice.storedLibraryId(for: .movies), 3)
        XCTAssertNil(alice.storedLibraryId(for: .shows))
        XCTAssertNil(bob.storedKind())
        XCTAssertNil(bob.storedLibraryId(for: .movies))

        alice.setLibraryId(nil, for: .movies)
        XCTAssertNil(alice.storedLibraryId(for: .movies), "clearing returns to All")
    }

    func testListenHubCoversAudiobookLibrariesAndKeepsItsOwnMemory() throws {
        let libraries = [library(1, "movies"), library(3, "audiobooks"), library(4, "audiobooks")]
        XCTAssertEqual(MediaHubScope.availableKinds(for: .listen, in: libraries), [.audiobooks])
        XCTAssertEqual(MediaHubScope.libraries(for: .audiobooks, in: libraries).map(\.id), [3, 4])

        let suite = "MediaHubScopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let authority = MainTabLibraryAuthority(serverId: "s", profileId: "p")
        let watch = MediaHubSelectionStore(hub: .watch, authority: authority, defaults: defaults)
        let listen = MediaHubSelectionStore(hub: .listen, authority: authority, defaults: defaults)
        watch.setKind(.shows)
        XCTAssertNil(listen.storedKind(), "each hub remembers its own kind")
    }

    func testAudiobookQueriesOnlySendTypeWhenNoLibraryScopesThem() {
        XCTAssertEqual(MediaKind.audiobooks.catalogType(for: nil), "audiobook")
        XCTAssertNil(MediaKind.audiobooks.catalogType(for: library(3, "audiobooks")))
        XCTAssertEqual(MediaKind.movies.catalogType(for: library(5, "mixed")), "movie")

        let allAudiobooks = CatalogQueryBuilder.build(.none, libraryId: nil, mediaType: .audiobook, limit: 10)
        XCTAssertEqual(allAudiobooks.type, "audiobook", "an unscoped grid must not browse the whole catalog")
        let oneLibrary = CatalogQueryBuilder.build(.none, libraryId: 3, mediaType: .audiobook, limit: 10)
        XCTAssertNil(oneLibrary.type)
    }

    func testCombinedAllMirrorsHomeAcrossEveryVideoLibrary() {
        let libraries = [library(1, "movies"), library(2, "movies"), library(3, "series")]
        let allVideoLibraries = MediaHubScope.libraries(for: .allVideo, in: libraries)

        XCTAssertEqual(allVideoLibraries.map(\.id), [1, 2, 3])
        XCTAssertNil(MediaHubScope.resolvedLibraryId(kind: .allVideo, storedLibraryId: 1, kindLibraries: allVideoLibraries))
        XCTAssertTrue(MediaKind.allVideo.includes(itemType: "episode"))
        XCTAssertTrue(MediaKind.allVideo.includes(itemType: "movie"))
        XCTAssertFalse(MediaKind.allVideo.includes(itemType: "audiobook"))
    }

    func testKindFiltersResumeCardsByItemType() {
        XCTAssertTrue(MediaKind.movies.includes(itemType: "movie"))
        XCTAssertFalse(MediaKind.movies.includes(itemType: "episode"))
        XCTAssertTrue(MediaKind.shows.includes(itemType: "episode"))
        XCTAssertTrue(MediaKind.shows.includes(itemType: "series"))
        XCTAssertFalse(MediaKind.shows.includes(itemType: "audiobook"))
        XCTAssertTrue(MediaKind.audiobooks.includes(itemType: "audiobook"))
        XCTAssertFalse(MediaKind.audiobooks.includes(itemType: "movie"))
    }

    func testCrossLibraryBrowseCacheKeysDoNotCollide() {
        let movies = CacheKey.browse(libraryId: nil, filterKey: "f", scope: "movie")
        let shows = CacheKey.browse(libraryId: nil, filterKey: "f", scope: "series")
        let unscoped = CacheKey.browse(libraryId: nil, filterKey: "f")
        XCTAssertEqual(Set([movies, shows, unscoped]).count, 3)
        XCTAssertEqual(unscoped, "browse:v2:all:f", "existing unscoped keys keep their format")
    }
}
