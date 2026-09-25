import Foundation

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
}

/// The iOS tab bar, derived only from the profile's accessible libraries:
///
/// | Libraries             | Tab bar                                        |
/// | --------------------- | ---------------------------------------------- |
/// | Watch and Listen      | Home, Watch, Listen, Libraries, For You        |
/// | Movies and Series     | Home, Movies, Series, Libraries, For You       |
/// | One library type      | Home, [type], For You                          |
///
/// Libraries also needs more than one library. Search stays in the top bar,
/// and Downloads, Favorites and Calendar are in the profile menu. The synced
/// `nav.primary_menu`, which other clients still use, is not read here.
/// Audiobook libraries count only while Show Audiobooks is on.
func appleFixedTabDestinations(
    libraries: [Library],
    showAudiobooks: Bool
) -> [MainTabDestination] {
    let visible = showAudiobooks ? libraries : libraries.filter { !$0.isAudiobookLibrary }
    let kinds = MediaKind.allCases.filter { !MediaHubScope.libraries(for: $0, in: visible).isEmpty }
    let capabilities = MediaCapability.allCases.filter { capability in
        capability.kinds.contains(where: kinds.contains)
    }

    var destinations: [MainTabDestination] = [.app(.home)]
    if capabilities.count > 1 {
        destinations += capabilities.map(\.tabDestination)
    } else {
        destinations += kinds.map { .libraryCategory($0.menuBuiltin) }
    }
    if kinds.count > 1, visible.count > 1 {
        destinations.append(.app(.libraries))
    }
    destinations.append(.app(.recommendations))
    return destinations
}

extension MediaCapability {
    var tabDestination: MainTabDestination {
        switch self {
        case .watch: return .watch
        case .listen: return .listen
        }
    }
}

extension MediaHub {
    /// The hub a tab-bar destination opens, if it is one.
    init?(destination: MainTabDestinationID) {
        switch destination {
        case .watch: self = .watch
        case .listen: self = .listen
        case .libraryCategory(.movies): self = .movies
        case .libraryCategory(.series): self = .series
        case .libraryCategory(.audiobooks): self = .audiobooks
        default: return nil
        }
    }
}
