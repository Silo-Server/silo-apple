import XCTest
@testable import Silo

@MainActor
final class MacSidebarSectionsTests: XCTestCase {
    private let movies = Library(id: 1, name: "Movies", type: "movies", sortOrder: 0, posterUrl: nil)
    private let series = Library(id: 2, name: "TV Shows", type: "series", sortOrder: 1, posterUrl: nil)
    private let anime = Library(id: 3, name: "Anime", type: "series", sortOrder: 2, posterUrl: nil)
    private let audiobooks = Library(
        id: 4, name: "Audiobooks", type: "audiobooks", sortOrder: 3, posterUrl: nil
    )

    private var allLibraries: [Library] { [movies, series, anime, audiobooks] }

    private func sections(
        libraries: [Library],
        showAudiobooks: Bool = true,
        downloads: Bool = false,
        requests: Bool = false
    ) -> [MacSidebarSection] {
        macSidebarSections(
            destinations: mainTabDestinations(downloadsEnabled: downloads),
            libraries: libraries,
            showAudiobooks: showAudiobooks,
            requestsEnabled: requests
        )
    }

    private func ids(
        _ id: MacSidebarSectionID,
        in sections: [MacSidebarSection]
    ) -> [MainTabDestinationID]? {
        sections.first { $0.id == id }?.items.map(\.id)
    }

    func testLibrariesListEveryLibraryInServerOrder() {
        let built = sections(libraries: allLibraries)
        XCTAssertEqual(
            ids(.libraries, in: built),
            [.library(1), .library(2), .library(3), .library(4)]
        )
        let flattened = built.flatMap(\.items).map(\.id)
        XCTAssertEqual(Set(flattened).count, flattened.count, "no duplicate rows")
        XCTAssertFalse(flattened.contains(.app(.libraries)))
    }

    func testLibrariesFallBackToOneRowWithoutLibrariesAndRespectAudiobookOptOut() {
        // No library list yet: one Libraries row keeps a way in.
        XCTAssertEqual(ids(.libraries, in: sections(libraries: [])), [.app(.libraries)])
        XCTAssertEqual(
            ids(.libraries, in: sections(libraries: allLibraries, showAudiobooks: false)),
            [.library(1), .library(2), .library(3)]
        )
    }

    #if !os(tvOS)
    // `AppTab.visibleCases` is the iPhone/iPad/Mac list. The Apple TV shell
    // builds its own bar (`TVRootDestination.visibleRoots`) and never reads it.
    func testDiscoverHasAFixedOrderStartingWithSearch() {
        XCTAssertEqual(
            ids(.discover, in: sections(libraries: allLibraries)),
            [.app(.search), .app(.recommendations), .app(.calendar)]
        )
        XCTAssertEqual(
            ids(.discover, in: sections(libraries: allLibraries, requests: true)),
            [.app(.search), .app(.recommendations), .app(.requests), .app(.calendar)]
        )
    }
    #endif

    func testYourStuffAppearsOnlyWithDownloads() {
        XCTAssertNil(ids(.yourStuff, in: sections(libraries: allLibraries)))
        XCTAssertEqual(
            ids(.yourStuff, in: sections(libraries: allLibraries, downloads: true)),
            [.app(.downloads)]
        )
    }

    func testSectionsKeepTheirFixedOrderWithHomeFirst() {
        let built = sections(libraries: allLibraries, downloads: true)
        XCTAssertEqual(built.map(\.id), [.home, .libraries, .discover, .yourStuff])
        XCTAssertEqual(ids(.home, in: built), [.app(.home)])
        XCTAssertNil(built.first?.title)
    }

    func testRequestsFollowsForYouOnlyWhileEnabled() {
        // Compared with the list Requests is off for, since `AppTab.visibleCases`
        // differs on tvOS, whose shell does not use it.
        let off = ids(.discover, in: sections(libraries: allLibraries)) ?? []
        XCTAssertFalse(off.contains(.app(.requests)))
        var expected = off
        let afterForYou = expected.firstIndex(of: .app(.recommendations)).map { $0 + 1 } ?? 1
        expected.insert(.app(.requests), at: afterForYou)
        XCTAssertEqual(
            ids(.discover, in: sections(libraries: allLibraries, requests: true)),
            expected
        )
        XCTAssertEqual(
            ids(.discover, in: sections(libraries: allLibraries, requests: true))?.prefix(3),
            [.app(.search), .app(.recommendations), .app(.requests)]
        )
    }

    func testLibraryRowsUseMediaTypeIcons() {
        XCTAssertEqual(macSidebarIcon(for: movies).icon, LibraryMediaCategory.movies.navigationIcon)
        XCTAssertEqual(macSidebarIcon(for: series).icon, LibraryMediaCategory.series.navigationIcon)
        XCTAssertEqual(
            macSidebarIcon(for: audiobooks).icon,
            LibraryMediaCategory.audiobooks.navigationIcon
        )
    }

    func testHighlightFollowsThePageInView() {
        let library = MainTabDestinationID.library(2)
        XCTAssertEqual(macSidebarHighlight(selected: library, pushedRoutes: []), library)
        XCTAssertEqual(
            macSidebarHighlight(selected: library, pushedRoutes: [.itemDetail(contentId: "a")]),
            library
        )
        XCTAssertNil(macSidebarHighlight(selected: library, pushedRoutes: [.settings]))
        XCTAssertNil(macSidebarHighlight(selected: library, pushedRoutes: [.serverList]))
        XCTAssertEqual(
            macSidebarHighlight(selected: library, pushedRoutes: [.requestsHub]),
            .app(.requests)
        )
        XCTAssertEqual(
            macSidebarHighlight(
                selected: library,
                pushedRoutes: [.search, .requestDetail(mediaType: .movie, tmdbId: 1)]
            ),
            .app(.requests)
        )
        XCTAssertEqual(
            macSidebarHighlight(selected: library, pushedRoutes: [.search]),
            .app(.search)
        )
        XCTAssertEqual(
            macSidebarHighlight(
                selected: library,
                pushedRoutes: [.search, .itemDetail(contentId: "a")]
            ),
            .app(.search)
        )
    }

    func testFallbackLibrariesSelectionMovesToTheFirstLoadedLibrary() {
        let loaded = sections(libraries: [movies, series]).flatMap(\.items)
        XCTAssertEqual(
            resolvedRequestedMainTabDestination(.libraries, visibleDestinations: loaded),
            .library(1)
        )
        let empty = sections(libraries: []).flatMap(\.items)
        XCTAssertEqual(
            resolvedRequestedMainTabDestination(.libraries, visibleDestinations: empty),
            .app(.libraries)
        )
    }

    func testRemovingTheSelectedLibraryFallsBackToHome() {
        let remaining = sections(libraries: [movies, series]).flatMap(\.items)
        XCTAssertEqual(
            resolvedVisibleMainTabDestination(.library(3), visibleDestinations: remaining),
            .app(.home)
        )
        XCTAssertEqual(
            resolvedVisibleMainTabDestination(.app(.search), visibleDestinations: remaining),
            .app(.search)
        )
    }
}
