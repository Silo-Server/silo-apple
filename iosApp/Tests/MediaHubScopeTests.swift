import XCTest
@testable import Silo

@MainActor
final class MediaHubScopeTests: XCTestCase {
    private func library(_ id: Int, _ type: String, _ name: String? = nil) -> Library {
        Library(id: id, name: name ?? "Library \(id)", type: type, sortOrder: id, posterUrl: nil)
    }

    private func bar(_ libraries: [Library], showAudiobooks: Bool = true) -> [MainTabDestinationID] {
        appleFixedTabDestinations(libraries: libraries, showAudiobooks: showAudiobooks).map(\.id)
    }

    func testWatchAndListenProfile() {
        let libraries = [library(1, "movies"), library(2, "series"), library(3, "audiobooks", "Books")]
        XCTAssertEqual(
            bar(libraries),
            [.app(.home), .watch, .listen, .app(.libraries), .app(.recommendations)]
        )
        XCTAssertEqual(appleFixedTabDestinations(libraries: libraries, showAudiobooks: true)[2].title, "Listen")
    }

    func testWatchOnlyProfileSplitsIntoMoviesAndSeries() {
        XCTAssertEqual(
            bar([library(1, "movies"), library(2, "series")]),
            [.app(.home), .libraryCategory(.movies), .libraryCategory(.series), .app(.libraries), .app(.recommendations)]
        )
        let titles = appleFixedTabDestinations(
            libraries: [library(1, "movies"), library(2, "series")], showAudiobooks: true
        ).map(\.title)
        XCTAssertEqual(titles, ["Home", "Movies", "Series", "Libraries", "For You"])
    }

    func testOneLibraryTypeGetsOneDestinationAndNoLibraries() {
        XCTAssertEqual(
            bar([library(1, "movies"), library(2, "movies")]),
            [.app(.home), .libraryCategory(.movies), .app(.recommendations)]
        )
        XCTAssertEqual(
            bar([library(3, "audiobooks"), library(4, "audiobooks")]),
            [.app(.home), .libraryCategory(.audiobooks), .app(.recommendations)]
        )
    }

    func testASingleMixedLibraryNeedsNoLibrariesDestination() {
        XCTAssertEqual(
            bar([library(5, "mixed")]),
            [.app(.home), .libraryCategory(.movies), .libraryCategory(.series), .app(.recommendations)]
        )
    }

    func testAudiobooksCountOnlyWithTheOptIn() {
        let libraries = [library(1, "movies"), library(3, "audiobooks")]
        XCTAssertEqual(
            bar(libraries, showAudiobooks: false),
            [.app(.home), .libraryCategory(.movies), .app(.recommendations)]
        )
    }

    func testNoLibrariesKeepsHomeAndForYou() {
        XCTAssertEqual(bar([]), [.app(.home), .app(.recommendations)])
    }

    func testTabDestinationsMapToHubs() {
        XCTAssertEqual(MediaHub(destination: .watch), .watch)
        XCTAssertEqual(MediaHub(destination: .listen), .listen)
        XCTAssertEqual(MediaHub(destination: .libraryCategory(.series)), .series)
        XCTAssertEqual(MediaHub(destination: .libraryCategory(.audiobooks)), .audiobooks)
        XCTAssertNil(MediaHub(destination: .app(.libraries)))
    }

    func testLibraryTabRequestResolvesToTheFirstLibraryRootWithoutLibraries() {
        let visible = appleFixedTabDestinations(libraries: [library(1, "movies")], showAudiobooks: false)
        XCTAssertEqual(
            resolvedRequestedMainTabDestination(.libraries, visibleDestinations: visible),
            .libraryCategory(.movies)
        )
    }

    func testMixedLibrariesAppearUnderBothKinds() {
        let libraries = [library(1, "movies"), library(2, "series"), library(3, "mixed"), library(4, "audiobooks")]

        XCTAssertEqual(MediaHubScope.libraries(for: .movies, in: libraries).map(\.id), [1, 3])
        XCTAssertEqual(MediaHubScope.libraries(for: .series, in: libraries).map(\.id), [2, 3])
        XCTAssertEqual(MediaHubScope.availableKinds(for: .watch, in: libraries), [.movies, .series])
        XCTAssertEqual(MediaHubScope.availableKinds(for: .watch, in: [library(1, "movies")]), [.movies])
        XCTAssertEqual(MediaHubScope.availableKinds(for: .series, in: libraries), [.series])
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
        XCTAssertEqual(movies.kinds, [.movies, .series])
        XCTAssertEqual(movies.kinds.map(\.title), ["Movies", "Series"])
        XCTAssertEqual(movies.options.map(\.title), ["All Movies", "Movies", "Movies - Anime"])
        XCTAssertEqual(movies.options[0].selection, .init(kind: .movies, libraryId: nil))
        XCTAssertEqual(movies.options[2].selection, .init(kind: .movies, libraryId: 2))

        let series = MediaHubScope.menu(for: .watch, kind: .series, in: libraries)
        XCTAssertEqual(series.options.map(\.title), ["TV Shows"], "a one-library kind names its library")
        XCTAssertEqual(series.options[0].selection, .init(kind: .series, libraryId: nil))

        let moviesTab = MediaHubScope.menu(for: .movies, kind: .movies, in: libraries)
        XCTAssertTrue(moviesTab.kinds.isEmpty, "a single-type tab has no segments")
        XCTAssertEqual(moviesTab.options.map(\.title), ["All Movies", "Movies", "Movies - Anime"])
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
            MediaHubScope.header(kind: .movies, library: nil, kindLibraries: movies),
            .init(title: "Movies", subtitle: "All libraries")
        )
        XCTAssertEqual(
            MediaHubScope.header(kind: .movies, library: movies[1], kindLibraries: movies),
            .init(title: "Movies - Anime", subtitle: "Movies library"),
            "library names are shown exactly as the server has them"
        )
        XCTAssertEqual(
            MediaHubScope.header(kind: .audiobooks, library: books[0], kindLibraries: books),
            .init(title: "Audiobooks", subtitle: "Audiobooks English")
        )
    }

    func testMenuCheckmarkFoldsASingleLibraryIntoItsKind() {
        let one = [library(3, "series")]
        let two = [library(1, "movies"), library(2, "movies")]
        XCTAssertEqual(
            MediaHubScope.currentSelection(kind: .series, libraryId: 3, kindLibraries: one),
            .init(kind: .series, libraryId: nil)
        )
        XCTAssertEqual(
            MediaHubScope.currentSelection(kind: .movies, libraryId: 2, kindLibraries: two),
            .init(kind: .movies, libraryId: 2)
        )
    }

    private func makeDefaults() throws -> (UserDefaults, () -> Void) {
        let suite = "MediaHubScopeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (defaults, { defaults.removePersistentDomain(forName: suite) })
    }

    func testSelectionMemoryIsScopedPerProfileAndKind() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }

        let alice = MediaHubMemory(authority: MainTabLibraryAuthority(serverId: "s", profileId: "alice"), defaults: defaults)
        let bob = MediaHubMemory(authority: MainTabLibraryAuthority(serverId: "s", profileId: "bob"), defaults: defaults)

        alice.setKind(.series, for: .watch)
        alice.setLibraryId(3, for: .movies)
        XCTAssertEqual(alice.kind(for: .watch), .series)
        XCTAssertNil(alice.kind(for: .listen), "each hub remembers its own kind")
        XCTAssertEqual(alice.libraryId(for: .movies), 3)
        XCTAssertNil(alice.libraryId(for: .series))
        XCTAssertNil(bob.kind(for: .watch))
        XCTAssertNil(bob.libraryId(for: .movies))

        alice.setLibraryId(nil, for: .movies)
        XCTAssertNil(alice.libraryId(for: .movies), "clearing returns to every library of the kind")
    }

    func testOpeningALibraryFromLibrariesBecomesItsCapabilitysSelection() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let memory = MediaHubMemory(authority: MainTabLibraryAuthority(serverId: "s", profileId: "p"), defaults: defaults)

        memory.remember(library(2, "series", "Anime"))
        XCTAssertEqual(memory.kind(for: .watch), .series)
        XCTAssertEqual(memory.libraryId(for: .series), 2)
        XCTAssertEqual(memory.lastUsedLibraryId(for: .watch), 2)
        XCTAssertNil(memory.lastUsedLibraryId(for: .listen))

        memory.remember(library(5, "mixed", "Kids"))
        XCTAssertEqual(memory.kind(for: .watch), .series, "a mixed library keeps Watch on its kind")
        XCTAssertEqual(memory.libraryId(for: .movies), 5)
        XCTAssertEqual(memory.libraryId(for: .series), 5)

        memory.remember(library(7, "audiobooks"))
        XCTAssertEqual(memory.kind(for: .listen), .audiobooks)
        XCTAssertEqual(memory.lastUsedLibraryId(for: .listen), 7)
        XCTAssertEqual(memory.lastUsedLibraryId(for: .watch), 5)
    }

    func testPinsAreScopedPerProfile() throws {
        let (defaults, cleanup) = try makeDefaults()
        defer { cleanup() }
        let alice = MediaHubMemory(authority: MainTabLibraryAuthority(serverId: "s", profileId: "alice"), defaults: defaults)
        let bob = MediaHubMemory(authority: MainTabLibraryAuthority(serverId: "s", profileId: "bob"), defaults: defaults)

        alice.setPinnedLibraryIds([4, 1])
        XCTAssertEqual(alice.pinnedLibraryIds(), [4, 1])
        XCTAssertEqual(bob.pinnedLibraryIds(), [])
    }

    func testLibrariesPageGroupsByCapabilityWithPinsFirst() {
        let libraries = [
            library(1, "movies", "Movies"),
            library(2, "movies", "Movies - Anime"),
            library(3, "series", "TV"),
            library(4, "audiobooks", "Books"),
            library(5, "mixed", "Kids"),
            library(6, "audiobooks", "Podcasts"),
        ]

        let unpinned = LibrariesPage.sections(libraries: libraries, pinnedIds: [])
        XCTAssertEqual(unpinned.map(\.capability), [.watch, .listen])
        XCTAssertEqual(unpinned[0].libraries.map(\.id), [1, 2, 3, 5], "server order, every library its own card")
        XCTAssertEqual(unpinned[1].libraries.map(\.id), [4, 6])

        let pinned = LibrariesPage.sections(libraries: libraries, pinnedIds: [6, 5, 2])
        XCTAssertEqual(pinned[0].libraries.map(\.id), [5, 2, 1, 3], "pins lead their section in pin order")
        XCTAssertEqual(pinned[1].libraries.map(\.id), [6, 4])

        XCTAssertEqual(
            LibrariesPage.sections(libraries: [library(1, "movies")], pinnedIds: []).map(\.capability),
            [.watch],
            "empty capabilities are left out"
        )
    }

    func testPinsForLostLibrariesAreDropped() {
        let libraries = [library(1, "movies"), library(2, "series")]
        XCTAssertEqual(LibrariesPage.prunedPins([2, 9, 1], libraries: libraries), [2, 1])
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

    func testKindFiltersResumeCardsByItemType() {
        XCTAssertTrue(MediaKind.movies.includes(itemType: "movie"))
        XCTAssertFalse(MediaKind.movies.includes(itemType: "episode"))
        XCTAssertTrue(MediaKind.series.includes(itemType: "episode"))
        XCTAssertTrue(MediaKind.series.includes(itemType: "series"))
        XCTAssertFalse(MediaKind.series.includes(itemType: "audiobook"))
        XCTAssertTrue(MediaKind.audiobooks.includes(itemType: "audiobook"))
        XCTAssertFalse(MediaKind.audiobooks.includes(itemType: "movie"))
    }

    func testCrossLibraryBrowseCacheKeysDoNotCollide() {
        let movies = CacheKey.browse(libraryId: nil, filterKey: "f", scope: "movie")
        let series = CacheKey.browse(libraryId: nil, filterKey: "f", scope: "series")
        let unscoped = CacheKey.browse(libraryId: nil, filterKey: "f")
        XCTAssertEqual(Set([movies, series, unscoped]).count, 3)
        XCTAssertEqual(unscoped, "browse:v2:all:f", "existing unscoped keys keep their format")
    }
}
