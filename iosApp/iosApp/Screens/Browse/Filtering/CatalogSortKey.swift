import Foundation

/// Sort direction. Sent as the catalog `order` param. Named to avoid
/// colliding with Swift's stdlib `SortOrder`.
enum CatalogSortOrder: String, Codable, Hashable {
    case asc
    case desc

    var flipped: CatalogSortOrder { self == .asc ? .desc : .asc }
}

/// The media family of a library — selects the available sort/facet
/// vocabulary and the catalog `type` param.
enum BrowseMediaType: String, Codable, Hashable {
    case movie
    case series
    case audiobook

    static func from(libraryType: String) -> BrowseMediaType {
        if SiloMediaType.isAudiobook(libraryType) { return .audiobook }
        if SiloMediaType.isSeries(libraryType) { return .series }
        return .movie
    }

    /// The catalog `type` (media_scope) param. Audiobooks omit it — the
    /// `library_id` already scopes the query, matching the existing browse
    /// paths which never send `type` for audiobook/music libraries.
    var catalogTypeParam: String? {
        switch self {
        case .movie: return "movie"
        case .series: return "series"
        case .audiobook: return nil
        }
    }
}

/// One sortable field. The raw value is the canonical server `sort` field
/// (silo-server `query_definition.go` `querySortDefs`). `defaultOrder`
/// mirrors the server's per-field default so the first selection lands the
/// natural direction and a flip is meaningful. This enum is the single
/// source of truth that eliminates the old `sort=added` phantom (the real
/// field is `added_at`).
enum CatalogSortKey: String, CaseIterable, Codable, Hashable {
    case title
    case addedAt = "added_at"
    case year
    case ratingImdb = "rating_imdb"
    case runtime
    case resolution
    // audiobook-native
    case author
    case narrator
    case series

    /// Canonical server sort field.
    var field: String { rawValue }

    var defaultOrder: CatalogSortOrder {
        switch self {
        case .title, .author, .narrator, .series:
            return .asc
        case .addedAt, .year, .ratingImdb, .runtime, .resolution:
            return .desc
        }
    }

    var label: String {
        switch self {
        case .title: return "Title"
        case .addedAt: return "Date Added"
        case .year: return "Year"
        case .ratingImdb: return "Rating"
        case .runtime: return "Runtime"
        case .resolution: return "Resolution"
        case .author: return "Author"
        case .narrator: return "Narrator"
        case .series: return "Series"
        }
    }

    /// Short hint for the active direction, shown next to the active key.
    func directionLabel(for order: CatalogSortOrder) -> String {
        switch self {
        case .title, .author, .narrator, .series:
            return order == .asc ? "A–Z" : "Z–A"
        case .year, .addedAt:
            return order == .asc ? "Oldest" : "Newest"
        case .runtime:
            return order == .asc ? "Shortest" : "Longest"
        case .ratingImdb, .resolution:
            return order == .asc ? "Lowest" : "Highest"
        }
    }

    /// Sort keys offered for a library media type, in display order.
    static func available(for mediaType: BrowseMediaType) -> [CatalogSortKey] {
        switch mediaType {
        case .audiobook:
            return [.title, .author, .narrator, .series, .addedAt, .runtime]
        case .movie, .series:
            return [.title, .addedAt, .year, .ratingImdb, .runtime, .resolution]
        }
    }
}
