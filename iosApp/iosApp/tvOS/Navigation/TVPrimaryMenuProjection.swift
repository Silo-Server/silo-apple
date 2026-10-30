#if os(tvOS)
import Foundation

/// The single Apple TV rule for which primary-menu items are renderable
/// roots. The top bar and the Customize Top Menu editor both use it so the
/// editor never lists a destination the bar hides.
enum TVPrimaryMenuProjection {
    /// Items the editor lists and counts: built-ins with a matching library
    /// type, library shortcuts whose library is available, Home/For You/
    /// Calendar always; sections and collections stay stored but hidden.
    static func visibleItems(
        in items: [PrimaryMenuItem],
        libraries: [Library]
    ) -> [PrimaryMenuItem] {
        let availableIds = Set(libraries.map(\.id))
        func hasLibrary(_ type: TVLibraryTabType) -> Bool {
            libraries.contains(where: { type.matches($0) })
        }
        return items.filter { item in
            switch item {
            case .builtin(.movies): return hasLibrary(.movies)
            case .builtin(.series): return hasLibrary(.series)
            case .builtin(.music): return hasLibrary(.music)
            case .builtin(.audiobooks): return hasLibrary(.audiobooks)
            case .library(let id, _): return availableIds.contains(id)
            case .section, .collection: return false
            case .builtin(.home), .builtin(.forYou), .builtin(.calendar): return true
            }
        }
    }

    /// Whether search includes audiobooks: the bar shows an audiobook
    /// destination (the Audiobooks tab or a pinned audiobook library), or the
    /// legacy per-device "Show Audiobooks" opt-in is on. The opt-in still
    /// counts when a synced menu leaves audiobooks out, so turning on the menu
    /// sync never hides audiobooks from search for someone who opted in.
    /// Either way an audiobook library must exist.
    static func searchIncludesAudiobooks(
        menuItems: [PrimaryMenuItem],
        libraries: [Library],
        legacyOptIn: Bool
    ) -> Bool {
        if legacyOptIn, libraries.contains(where: { $0.isAudiobookLibrary }) {
            return true
        }
        return roots(for: menuItems, libraries: libraries).contains { root in
            switch root {
            case .libraryType(.audiobooks):
                return true
            case .libraryShortcut(let libraryId, _):
                return libraries.contains { $0.id == libraryId && $0.isAudiobookLibrary }
            default:
                return false
            }
        }
    }

    /// Bar roots in menu order, deduplicated, with Home forced first when absent.
    static func roots(
        for items: [PrimaryMenuItem],
        libraries: [Library]
    ) -> [TVRootDestination] {
        var roots: [TVRootDestination] = []
        for item in visibleItems(in: items, libraries: libraries) {
            let root: TVRootDestination?
            switch item {
            case .builtin(.home): root = .home
            case .builtin(.movies): root = .libraryType(.movies)
            case .builtin(.series): root = .libraryType(.series)
            case .builtin(.music): root = .libraryType(.music)
            case .builtin(.audiobooks): root = .libraryType(.audiobooks)
            case .builtin(.forYou): root = .recommendations
            case .builtin(.calendar): root = .calendar
            case .library(let libraryId, let label):
                root = .libraryShortcut(libraryId: libraryId, label: label)
            case .section, .collection:
                // `visibleItems` already drops these: the contract can carry
                // them for web and future clients, but Apple TV has a stable
                // root route only for whole libraries.
                root = nil
            }
            if let root, !roots.contains(root) { roots.append(root) }
        }
        if !roots.contains(.home) { roots.insert(.home, at: 0) }
        return roots
    }
}
#endif
