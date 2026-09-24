import Foundation

/// A tab built on `MediaHubView`: a title menu that scopes the page to one of
/// its kinds or libraries, then rows.
enum MediaHub: String, Hashable {
    case watch
    case listen

    var title: String {
        switch self {
        case .watch: return "Watch"
        case .listen: return "Listen"
        }
    }

    /// In menu order. Music joins Listen once the Apple clients support it.
    var kinds: [MediaKind] {
        switch self {
        case .watch: return [.allVideo, .movies, .shows]
        case .listen: return [.audiobooks]
        }
    }
}

/// One scope in a hub's title menu. Each maps onto the existing
/// primary-menu media-type category, so library membership (including mixed
/// libraries, which belong to both Movies and Shows) stays defined in one
/// place.
enum MediaKind: String, CaseIterable, Hashable, Codable {
    /// Movies and shows together: Watch's default, Home's rows without the
    /// non-video content. Offered only when both halves exist.
    case allVideo = "all_video"
    case movies
    case shows
    case audiobooks

    var title: String {
        switch self {
        case .allVideo: return "Movies & Shows"
        case .movies: return "Movies"
        case .shows: return "Shows"
        case .audiobooks: return "Audiobooks"
        }
    }

    /// Title for the resume row the landing page borrows from Home.
    var resumeTitle: String {
        self == .audiobooks ? "Continue Listening" : "Continue Watching"
    }

    /// Segment label in the title panel.
    var segmentTitle: String {
        self == .allVideo ? "All" : title
    }

    var browseAllTitle: String {
        switch self {
        case .allVideo: return "All Titles"
        case .movies: return "All Movies"
        case .shows: return "All Shows"
        case .audiobooks: return "All Audiobooks"
        }
    }

    var categories: [PrimaryMenuBuiltin] {
        switch self {
        case .allVideo: return [.movies, .series]
        case .movies: return [.movies]
        case .shows: return [.series]
        case .audiobooks: return [.audiobooks]
        }
    }

    var browseMediaType: BrowseMediaType {
        switch self {
        case .allVideo: return .mixed
        case .movies: return .movie
        case .shows: return .series
        case .audiobooks: return .audiobook
        }
    }

    /// The catalog `type` scope for cross-library queries; `nil` for the
    /// two-type "All", which the landing page builds from Home instead.
    var catalogType: String? {
        switch self {
        case .allVideo: return nil
        case .movies: return "movie"
        case .shows: return "series"
        case .audiobooks: return "audiobook"
        }
    }

    /// The `type` to send with a catalog query over `library`. A single-type
    /// library already scopes the query, matching the existing browse paths;
    /// "All" (`nil`) and mixed libraries need the explicit type.
    func catalogType(for library: Library?) -> String? {
        guard let library, !library.isMixedLibrary else { return catalogType }
        return nil
    }

    /// Whether a section card belongs on this side. Shows accept episodes and
    /// seasons so resume and Next Up rows keep their episode cards.
    func includes(itemType: String) -> Bool {
        switch self {
        case .allVideo:
            return MediaKind.movies.includes(itemType: itemType)
                || MediaKind.shows.includes(itemType: itemType)
        case .movies:
            return SiloMediaType.isMovieLibrary(itemType)
        case .shows:
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
        libraries.filter { library in
            kind.categories.contains { libraryMatchesPrimaryMenuCategory(library, category: $0) }
        }
    }

    /// A hub's kinds that have at least one library. The header only offers a
    /// switch when more than one is present; the combined "All" appears only
    /// when both movies and shows do.
    static func availableKinds(for hub: MediaHub, in libraries: [Library]) -> [MediaKind] {
        let present = hub.kinds.filter { kind in
            kind != .allVideo && !self.libraries(for: kind, in: libraries).isEmpty
        }
        guard hub.kinds.contains(.allVideo), present.contains(.movies), present.contains(.shows) else {
            return present
        }
        return [.allVideo] + present
    }

    /// The library a kind's landing page should load, or `nil` for the
    /// merged "All" view. A kind with a single library always shows that
    /// library: its server-built rows are richer than the merged rows.
    static func resolvedLibraryId(
        kind: MediaKind,
        storedLibraryId: Int?,
        kindLibraries: [Library]
    ) -> Int? {
        guard kind != .allVideo else { return nil }
        if kindLibraries.count == 1 { return kindLibraries[0].id }
        guard let storedLibraryId,
              kindLibraries.contains(where: { $0.id == storedLibraryId })
        else { return nil }
        return storedLibraryId
    }
}

/// What the page shows: a kind, and optionally one of its libraries. `nil`
/// means every library of the kind (or, for `.allVideo`, Home's rows).
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
    /// place it in context. Movies & Shows has no rows.
    static func menu(for hub: MediaHub, kind: MediaKind, in libraries: [Library]) -> MediaScopeMenu {
        let kinds = availableKinds(for: hub, in: libraries)
        let segments = kinds.count > 1 ? kinds : []
        guard kind != .allVideo else { return .init(kinds: segments, options: []) }
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
        guard kind != .allVideo, kindLibraries.count > 1 else {
            return .init(kind: kind, libraryId: nil)
        }
        return .init(kind: kind, libraryId: libraryId)
    }

    /// Large title and subtitle for the current scope. The title names what
    /// is on screen; the subtitle names what it belongs to. No title counts:
    /// an exact total is the slowest part of a catalog query.
    static func header(
        hub: MediaHub,
        kind: MediaKind,
        library: Library?,
        kindLibraries: [Library]
    ) -> MediaScopeHeader {
        if kind == .allVideo {
            return .init(title: hub.title, subtitle: kind.title)
        }
        if kindLibraries.count > 1, let library {
            return .init(title: library.name, subtitle: "\(kind.title) library")
        }
        if kindLibraries.count > 1 {
            return .init(title: kind.title, subtitle: "All libraries")
        }
        return .init(title: kind.title, subtitle: kindLibraries.first?.name)
    }
}

/// Device-local hub memory, scoped by server and profile the same way the
/// existing library selector is.
struct MediaHubSelectionStore {
    let hub: MediaHub
    let authority: MainTabLibraryAuthority?
    var defaults: UserDefaults = .standard

    private var scope: String? {
        authority.map { "\($0.serverId).\($0.profileId)" }
    }

    func storedKind() -> MediaKind? {
        guard let scope,
              let raw = defaults.string(forKey: "\(hub.rawValue).kind.\(scope)"),
              let kind = MediaKind(rawValue: raw),
              hub.kinds.contains(kind)
        else { return nil }
        return kind
    }

    func setKind(_ kind: MediaKind) {
        guard let scope else { return }
        defaults.set(kind.rawValue, forKey: "\(hub.rawValue).kind.\(scope)")
    }

    /// `nil` means the merged "All" view.
    func storedLibraryId(for kind: MediaKind) -> Int? {
        guard let scope else { return nil }
        let value = defaults.integer(forKey: "watch.library.\(kind.rawValue).\(scope)")
        return value == 0 ? nil : value
    }

    func setLibraryId(_ libraryId: Int?, for kind: MediaKind) {
        guard let scope else { return }
        let key = "watch.library.\(kind.rawValue).\(scope)"
        if let libraryId {
            defaults.set(libraryId, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
