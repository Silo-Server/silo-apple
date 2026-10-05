import Foundation

/// Groups of the Mac sidebar, in display order.
enum MacSidebarSectionID: String, CaseIterable {
    case home
    case libraries
    case discover
    case yourStuff
}

/// One labelled group of Mac sidebar rows. A section with no rows is never
/// built, so the view can render every section it is handed.
struct MacSidebarSection: Identifiable, Equatable {
    let id: MacSidebarSectionID
    let items: [MainTabDestination]

    /// Home sits above the groups without a heading.
    var title: String? {
        switch id {
        case .home: return nil
        case .libraries: return "Libraries"
        case .discover: return "Discover"
        case .yourStuff: return "Your Stuff"
        }
    }
}

/// Builds the Mac sidebar from the shell's projected destinations and the
/// profile's libraries.
///
/// The Libraries group lists every library the profile can open, in server
/// order, whatever the synced Primary Menu pins. The Primary Menu still decides
/// whether For You and Calendar show and in which order. Media-type roots and
/// pinned libraries from the menu are dropped: the Libraries group covers them.
func macSidebarSections(
    destinations: [MainTabDestination],
    libraries: [Library],
    showAudiobooks: Bool
) -> [MacSidebarSection] {
    let libraryItems = libraries
        .filter { showAudiobooks || !$0.isAudiobookLibrary }
        .map { library in
            let icon = macSidebarIcon(for: library)
            return MainTabDestination.library(
                id: library.id,
                label: library.name,
                icon: icon.icon,
                selectedIcon: icon.selectedIcon
            )
        }
    let discoverItems = [.app(.search)] + destinations.filter {
        $0.id == .app(.recommendations) || $0.id == .app(.calendar)
    }
    let yourStuffItems = destinations.filter { $0.id == .app(.downloads) }

    return [
        MacSidebarSection(id: .home, items: [.app(.home)]),
        MacSidebarSection(id: .libraries, items: libraryItems),
        MacSidebarSection(id: .discover, items: discoverItems),
        MacSidebarSection(id: .yourStuff, items: yourStuffItems),
    ].filter { !$0.items.isEmpty }
}

/// Media-type icon for a library row. Mixed libraries match both the movie
/// and series categories, so they are checked first.
func macSidebarIcon(for library: Library) -> (icon: String, selectedIcon: String) {
    if library.isMixedLibrary {
        return (library.navigationIcon, library.selectedNavigationIcon)
    }
    let categories: [PrimaryMenuBuiltin] = [.movies, .series, .audiobooks]
    if let category = categories.first(where: {
        libraryMatchesPrimaryMenuCategory(library, category: $0)
    }) {
        return (category.navigationIcon, category.navigationIcon)
    }
    return (library.navigationIcon, library.selectedNavigationIcon)
}

/// The sidebar row to highlight for the page in view.
///
/// Pages opened from the profile menu belong to no row. A pushed Search page
/// lights the Search row. Anything else pushed (a detail page, a person)
/// keeps the row it was opened from.
func macSidebarHighlight(
    selected: MainTabDestinationID,
    pushedRoutes: [Route]
) -> MainTabDestinationID? {
    for route in pushedRoutes.reversed() {
        switch route {
        case .settings, .serverList, .requestsHub, .myRequests, .requestApprovals,
             .requestDetail:
            return nil
        case .search:
            return .app(.search)
        default:
            continue
        }
    }
    return selected
}
