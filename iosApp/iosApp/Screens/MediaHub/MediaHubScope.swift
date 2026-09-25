import Foundation

/// A broad group of media, in tab-bar order. Read joins once the Apple
/// clients support books; music and podcasts join Listen.
enum MediaCapability: String, CaseIterable, Hashable {
    case watch
    case listen

    var title: String {
        switch self {
        case .watch: return "Watch"
        case .listen: return "Listen"
        }
    }

    /// In segment order.
    var kinds: [MediaKind] {
        switch self {
        case .watch: return [.movies, .series]
        case .listen: return [.audiobooks]
        }
    }

    /// Mixed libraries belong to Watch.
    init?(library: Library) {
        guard let capability = Self.allCases.first(where: { capability in
            capability.kinds.contains { $0.contains(library) }
        }) else { return nil }
        self = capability
    }
}

/// A tab built on `MediaHubView`: a title menu that scopes the page to one of
/// its kinds or libraries, then rows. Watch and Listen cover a capability;
/// the others cover one library type, for profiles with only that type or
/// with no second capability to group under.
enum MediaHub: String, Hashable {
    case watch
    case listen
    case movies
    case series
    case audiobooks

    var title: String {
        switch self {
        case .watch: return "Watch"
        case .listen: return "Listen"
        case .movies: return "Movies"
        case .series: return "Series"
        case .audiobooks: return "Audiobooks"
        }
    }

    /// In segment order.
    var kinds: [MediaKind] {
        switch self {
        case .watch: return MediaCapability.watch.kinds
        case .listen: return MediaCapability.listen.kinds
        case .movies: return [.movies]
        case .series: return [.series]
        case .audiobooks: return [.audiobooks]
        }
    }

    var capability: MediaCapability {
        self == .listen || self == .audiobooks ? .listen : .watch
    }
}

/// One library type. Each maps onto the existing primary-menu media-type
/// category, so library membership (including mixed libraries, which belong
/// to both Movies and Series) stays defined in one place.
enum MediaKind: String, CaseIterable, Hashable, Codable {
    case movies
    case series
    case audiobooks

    var title: String {
        switch self {
        case .movies: return "Movies"
        case .series: return "Series"
        case .audiobooks: return "Audiobooks"
        }
    }

    /// Title for the resume row the landing page borrows from Home.
    var resumeTitle: String {
        self == .audiobooks ? "Continue Listening" : "Continue Watching"
    }

    var browseAllTitle: String { "All \(title)" }

    var menuBuiltin: PrimaryMenuBuiltin {
        switch self {
        case .movies: return .movies
        case .series: return .series
        case .audiobooks: return .audiobooks
        }
    }

    func contains(_ library: Library) -> Bool {
        libraryMatchesPrimaryMenuCategory(library, category: menuBuiltin)
    }

    var browseMediaType: BrowseMediaType {
        switch self {
        case .movies: return .movie
        case .series: return .series
        case .audiobooks: return .audiobook
        }
    }

    /// The catalog `type` scope for cross-library queries.
    var catalogType: String {
        switch self {
        case .movies: return "movie"
        case .series: return "series"
        case .audiobooks: return "audiobook"
        }
    }

    /// The `type` to send with a catalog query over `library`. A single-type
    /// library already scopes the query, matching the existing browse paths;
    /// every library of the kind (`nil`) and mixed libraries need the
    /// explicit type.
    func catalogType(for library: Library?) -> String? {
        guard let library, !library.isMixedLibrary else { return catalogType }
        return nil
    }

    /// Whether a section card belongs on this side. Series accept episodes
    /// and seasons so resume and Next Up rows keep their episode cards.
    func includes(itemType: String) -> Bool {
        switch self {
        case .movies:
            return SiloMediaType.isMovieLibrary(itemType)
        case .series:
            let normalized = itemType.lowercased()
            return SiloMediaType.isSeries(itemType)
                || normalized == "episode"
                || normalized == "season"
        case .audiobooks:
            return SiloMediaType.isAudiobook(itemType)
        }
    }
}

enum MediaHubScope {
    /// A kind's libraries, in the server's order.
    static func libraries(for kind: MediaKind, in libraries: [Library]) -> [Library] {
        libraries.filter(kind.contains)
    }

    /// A hub's kinds that have at least one library. The header only offers a
    /// switch when more than one is present.
    static func availableKinds(for hub: MediaHub, in libraries: [Library]) -> [MediaKind] {
        hub.kinds.filter { !self.libraries(for: $0, in: libraries).isEmpty }
    }

    /// The library a kind's landing page should load, or `nil` for every
    /// library of the kind. A kind with a single library always shows that
    /// library: its server-built rows are richer than the merged rows.
    static func resolvedLibraryId(
        kind: MediaKind,
        storedLibraryId: Int?,
        kindLibraries: [Library]
    ) -> Int? {
        if kindLibraries.count == 1 { return kindLibraries[0].id }
        guard let storedLibraryId,
              kindLibraries.contains(where: { $0.id == storedLibraryId })
        else { return nil }
        return storedLibraryId
    }
}

/// What the page shows: a kind, and optionally one of its libraries. `nil`
/// means every library of the kind.
struct MediaScopeSelection: Hashable {
    let kind: MediaKind
    let libraryId: Int?
}

/// The title panel's content for the current kind: a segment per kind, and
/// the rows that pick a library within it.
struct MediaScopeMenu: Equatable {
    struct Option: Identifiable, Equatable {
        let selection: MediaScopeSelection
        let title: String
        var id: MediaScopeSelection { selection }
    }

    /// Segments, in order; empty when the hub has only one kind.
    let kinds: [MediaKind]
    /// The current kind's rows: the whole kind ("All Movies") first, then
    /// each library by its exact name.
    let options: [Option]

    var isEmpty: Bool { kinds.isEmpty && options.isEmpty }
}

struct MediaScopeHeader: Equatable {
    let title: String
    let subtitle: String?
}

extension MediaHubScope {
    /// The title panel for `kind`. The segments pick a kind; the rows pick
    /// a library within it, so the list never mixes kinds. A kind with one
    /// library lists just that library, and only when there are segments to
    /// place it in context.
    static func menu(for hub: MediaHub, kind: MediaKind, in libraries: [Library]) -> MediaScopeMenu {
        let kinds = availableKinds(for: hub, in: libraries)
        let segments = kinds.count > 1 ? kinds : []
        let kindLibraries = self.libraries(for: kind, in: libraries)
        let options: [MediaScopeMenu.Option]
        if kindLibraries.count > 1 {
            options = [.init(selection: .init(kind: kind, libraryId: nil), title: kind.browseAllTitle)]
                + kindLibraries.map { .init(selection: .init(kind: kind, libraryId: $0.id), title: $0.name) }
        } else if let only = kindLibraries.first, !segments.isEmpty {
            options = [.init(selection: .init(kind: kind, libraryId: nil), title: only.name)]
        } else {
            options = []
        }
        return .init(kinds: segments, options: options)
    }

    /// The menu's checkmark for the current page. A kind with one library
    /// has a single option, so its library selection folds into the kind.
    static func currentSelection(
        kind: MediaKind,
        libraryId: Int?,
        kindLibraries: [Library]
    ) -> MediaScopeSelection {
        guard kindLibraries.count > 1 else { return .init(kind: kind, libraryId: nil) }
        return .init(kind: kind, libraryId: libraryId)
    }

    /// Large title and subtitle for the current scope. The title names what
    /// is on screen; the subtitle names what it belongs to. No title counts:
    /// an exact total is the slowest part of a catalog query.
    static func header(
        kind: MediaKind,
        library: Library?,
        kindLibraries: [Library]
    ) -> MediaScopeHeader {
        if kindLibraries.count > 1, let library {
            return .init(title: library.name, subtitle: "\(kind.title) library")
        }
        if kindLibraries.count > 1 {
            return .init(title: kind.title, subtitle: "All libraries")
        }
        return .init(title: kind.title, subtitle: kindLibraries.first?.name)
    }
}

// MARK: - Libraries page

/// One capability's cards on the Libraries page.
struct LibrariesPageSection: Equatable, Identifiable {
    let capability: MediaCapability
    let libraries: [Library]
    var id: MediaCapability { capability }
}

enum LibrariesPage {
    /// Every library as its own card, grouped by capability. Within a
    /// section, pinned libraries come first in pin order, then the rest in
    /// server order. Empty sections are left out.
    static func sections(libraries: [Library], pinnedIds: [Int]) -> [LibrariesPageSection] {
        let ordered = orderedByPins(libraries, pinnedIds: pinnedIds)
        return MediaCapability.allCases.compactMap { capability in
            let members = ordered.filter { MediaCapability(library: $0) == capability }
            return members.isEmpty ? nil : .init(capability: capability, libraries: members)
        }
    }

    /// Pinned libraries in pin order, then the rest in server order. This is
    /// also the order a capability falls back through.
    static func orderedByPins(_ libraries: [Library], pinnedIds: [Int]) -> [Library] {
        let pinned = pinnedIds.compactMap { id in libraries.first { $0.id == id } }
        return pinned + libraries.filter { !pinnedIds.contains($0.id) }
    }

    /// Pins for libraries the profile can no longer open are dropped, so a
    /// library that comes back returns unpinned.
    static func prunedPins(_ pinnedIds: [Int], libraries: [Library]) -> [Int] {
        pinnedIds.filter { id in libraries.contains { $0.id == id } }
    }
}

// MARK: - Memory

extension Notification.Name {
    /// Posted when a remembered hub selection changes outside the hub (the
    /// Libraries page), so a live hub can follow it.
    static let mediaHubSelectionDidChange = Notification.Name("mediaHubSelectionDidChange")
}

/// Device-local navigation memory, scoped by server and profile the same way
/// the existing library selector is: each hub's kind, each kind's library,
/// the last library used in each capability, and Libraries page pins.
struct MediaHubMemory {
    let authority: MainTabLibraryAuthority?
    var defaults: UserDefaults = .standard

    private var scope: String? {
        authority.map { "\($0.serverId).\($0.profileId)" }
    }

    private func key(_ name: String) -> String? {
        scope.map { "mediaHub.\(name).\($0)" }
    }

    func kind(for hub: MediaHub) -> MediaKind? {
        guard let key = key("\(hub.rawValue).kind"),
              let raw = defaults.string(forKey: key),
              let kind = MediaKind(rawValue: raw),
              hub.kinds.contains(kind)
        else { return nil }
        return kind
    }

    func setKind(_ kind: MediaKind, for hub: MediaHub) {
        guard let key = key("\(hub.rawValue).kind") else { return }
        defaults.set(kind.rawValue, forKey: key)
    }

    /// Shared by every hub that shows the kind, so Watch and a Movies tab
    /// agree. `nil` means every library of the kind.
    func libraryId(for kind: MediaKind) -> Int? {
        guard let key = key("library.\(kind.rawValue)") else { return nil }
        let value = defaults.integer(forKey: key)
        return value == 0 ? nil : value
    }

    func setLibraryId(_ libraryId: Int?, for kind: MediaKind) {
        guard let key = key("library.\(kind.rawValue)") else { return }
        if let libraryId {
            defaults.set(libraryId, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// The Libraries page's "last used" mark.
    func lastUsedLibraryId(for capability: MediaCapability) -> Int? {
        guard let key = key("lastUsed.\(capability.rawValue)") else { return nil }
        let value = defaults.integer(forKey: key)
        return value == 0 ? nil : value
    }

    func setLastUsedLibraryId(_ libraryId: Int, for capability: MediaCapability) {
        guard let key = key("lastUsed.\(capability.rawValue)") else { return }
        defaults.set(libraryId, forKey: key)
    }

    func pinnedLibraryIds() -> [Int] {
        guard let key = key("pins") else { return [] }
        return defaults.array(forKey: key) as? [Int] ?? []
    }

    func setPinnedLibraryIds(_ ids: [Int]) {
        guard let key = key("pins") else { return }
        defaults.set(ids, forKey: key)
    }

    /// Opening a library from the Libraries page makes it the capability's
    /// selection: its hub opens on the library's kind and the library, and
    /// the page marks it as last used. A mixed library becomes the selection
    /// for both Movies and Series and leaves Watch on its current kind.
    func remember(_ library: Library) {
        guard let capability = MediaCapability(library: library) else { return }
        let kinds = capability.kinds.filter { $0.contains(library) }
        guard let firstKind = kinds.first else { return }
        for kind in kinds {
            setLibraryId(library.id, for: kind)
        }
        let hub: MediaHub = capability == .listen ? .listen : .watch
        if kind(for: hub).map(kinds.contains) != true {
            setKind(firstKind, for: hub)
        }
        setLastUsedLibraryId(library.id, for: capability)
        NotificationCenter.default.post(name: .mediaHubSelectionDidChange, object: nil)
    }
}
