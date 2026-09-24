import Foundation

/// What the last slot of the iOS tab bar opens.
enum LastTabChoice: Hashable, Sendable {
    case downloads
    case favorites
    case calendar
    case library(Int)

    init?(storageValue: String) {
        switch storageValue {
        case "downloads": self = .downloads
        case "favorites": self = .favorites
        case "calendar": self = .calendar
        default:
            guard storageValue.hasPrefix("library:"),
                  let id = Int(storageValue.dropFirst("library:".count))
            else { return nil }
            self = .library(id)
        }
    }

    var storageValue: String {
        switch self {
        case .downloads: return "downloads"
        case .favorites: return "favorites"
        case .calendar: return "calendar"
        case .library(let id): return "library:\(id)"
        }
    }
}

extension MainTabDestination {
    /// Every movie and series library (`MediaHubView`).
    static let watch = MainTabDestination(
        id: .watch,
        title: "Watch",
        icon: "play.tv",
        selectedIcon: "play.tv.fill"
    )

    /// Every audiobook library (`MediaHubView`); music joins it later.
    static let listen = MainTabDestination(
        id: .listen,
        title: "Listen",
        icon: "headphones",
        selectedIcon: "headphones"
    )

    static let favorites = MainTabDestination(
        id: .favorites,
        title: "Favorites",
        icon: "heart",
        selectedIcon: "heart.fill"
    )
}

/// The iOS tab bar: Home | Watch | Listen | For You | one chosen slot.
///
/// The bar is fixed rather than projected from the synced
/// `nav.primary_menu`, which other clients still use unchanged. Watch needs
/// a movie, series or mixed library; Listen needs the audiobook opt-in and an
/// audiobook library. An unavailable last-slot choice, including an
/// audiobook library while the opt-in is off, falls back to Downloads, then
/// Calendar.
func appleFixedTabDestinations(
    libraries: [Library],
    showAudiobooks: Bool,
    downloadsEnabled: Bool,
    lastTab: LastTabChoice
) -> [MainTabDestination] {
    var destinations: [MainTabDestination] = [.app(.home)]
    if !MediaHubScope.availableKinds(for: .watch, in: libraries).isEmpty {
        destinations.append(.watch)
    }
    if showAudiobooks, libraries.contains(where: \.isAudiobookLibrary) {
        destinations.append(.listen)
    }
    destinations.append(.app(.recommendations))
    destinations.append(
        resolvedLastTabDestination(
            lastTab,
            libraries: showAudiobooks ? libraries : libraries.filter { !$0.isAudiobookLibrary },
            downloadsEnabled: downloadsEnabled
        )
    )
    return destinations
}

func resolvedLastTabDestination(
    _ choice: LastTabChoice,
    libraries: [Library],
    downloadsEnabled: Bool
) -> MainTabDestination {
    let fallback: MainTabDestination = downloadsEnabled ? .app(.downloads) : .app(.calendar)
    switch choice {
    case .downloads:
        return fallback
    case .favorites:
        return .favorites
    case .calendar:
        return .app(.calendar)
    case .library(let libraryId):
        guard let library = libraries.first(where: { $0.id == libraryId }) else { return fallback }
        return .library(
            id: library.id,
            label: library.name,
            icon: library.navigationIcon,
            selectedIcon: library.selectedNavigationIcon
        )
    }
}
