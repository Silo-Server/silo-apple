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
        menu: PrimaryMenuPreference?,
        libraries: [Library],
        showAudiobooks: Bool = true,
        downloads: Bool = false
    ) -> [MacSidebarSection] {
        var destinations = projectedMainTabDestinations(
            primaryMenu: menu,
            availableLibraries: libraries,
            showAudiobooks: showAudiobooks
        )
        if downloads { destinations.append(.app(.downloads)) }
        return macSidebarSections(
            destinations: destinations,
            libraries: libraries,
            showAudiobooks: showAudiobooks
        )
    }

    private func ids(
        _ id: MacSidebarSectionID,
        in sections: [MacSidebarSection]
    ) -> [MainTabDestinationID]? {
        sections.first { $0.id == id }?.items.map(\.id)
    }

    func testLibrariesListEveryLibraryInServerOrderWhateverTheMenuPins() {
        let expected: [MainTabDestinationID] = [.library(1), .library(2), .library(3), .library(4)]
        let menus: [PrimaryMenuPreference?] = [
            nil,
            PrimaryMenuPreference(items: [.builtin(.home)]),
            PrimaryMenuPreference(items: [.builtin(.home), .library(libraryId: 3, label: "Anime")]),
            PrimaryMenuPreference(items: [.builtin(.home), .builtin(.series), .builtin(.movies)]),
        ]
        for menu in menus {
            let built = sections(menu: menu, libraries: allLibraries)
            XCTAssertEqual(ids(.libraries, in: built), expected)
            let flattened = built.flatMap(\.items).map(\.id)
            XCTAssertEqual(Set(flattened).count, flattened.count, "no duplicate rows")
            XCTAssertFalse(flattened.contains(.app(.libraries)))
            XCTAssertFalse(flattened.contains(.libraryCategory(.movies)))
            XCTAssertFalse(flattened.contains(.libraryCategory(.series)))
        }
    }

    func testLibrariesGroupIsOmittedWithoutLibrariesAndRespectsAudiobookOptOut() {
        XCTAssertNil(ids(.libraries, in: sections(menu: nil, libraries: [])))
        XCTAssertEqual(
            ids(.libraries, in: sections(menu: nil, libraries: allLibraries, showAudiobooks: false)),
            [.library(1), .library(2), .library(3)]
        )
    }

    func testDiscoverStartsWithSearchThenFollowsThePrimaryMenu() {
        let reordered = PrimaryMenuPreference(items: [
            .builtin(.home), .builtin(.calendar), .builtin(.forYou),
        ])
        XCTAssertEqual(
            ids(.discover, in: sections(menu: reordered, libraries: allLibraries)),
            [.app(.search), .app(.calendar), .app(.recommendations)]
        )
        let calendarOnly = PrimaryMenuPreference(items: [.builtin(.home), .builtin(.calendar)])
        XCTAssertEqual(
            ids(.discover, in: sections(menu: calendarOnly, libraries: allLibraries)),
            [.app(.search), .app(.calendar)]
        )
    }

    func testYourStuffAppearsOnlyWithDownloads() {
        XCTAssertNil(ids(.yourStuff, in: sections(menu: nil, libraries: allLibraries)))
        XCTAssertEqual(
            ids(.yourStuff, in: sections(menu: nil, libraries: allLibraries, downloads: true)),
            [.app(.downloads)]
        )
    }

    func testSectionsKeepTheirFixedOrderWithHomeFirst() {
        let built = sections(menu: nil, libraries: allLibraries, downloads: true)
        XCTAssertEqual(built.map(\.id), [.home, .libraries, .discover, .yourStuff])
        XCTAssertEqual(ids(.home, in: built), [.app(.home)])
        XCTAssertNil(built.first?.title)
    }

    func testLibraryRowsUseMediaTypeIcons() {
        XCTAssertEqual(macSidebarIcon(for: movies).icon, PrimaryMenuBuiltin.movies.navigationIcon)
        XCTAssertEqual(macSidebarIcon(for: series).icon, PrimaryMenuBuiltin.series.navigationIcon)
        XCTAssertEqual(
            macSidebarIcon(for: audiobooks).icon,
            PrimaryMenuBuiltin.audiobooks.navigationIcon
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
        XCTAssertNil(macSidebarHighlight(selected: library, pushedRoutes: [.requestsHub]))
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

    func testRemovingTheSelectedLibraryFallsBackToHome() {
        let remaining = sections(menu: nil, libraries: [movies, series]).flatMap(\.items)
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
