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
    /// Movies + series in one library. Browses merged; the user narrows via
    /// the Type facet (`CatalogFacet.itemType`), not navigation.
    case mixed

    static func from(libraryType: String) -> BrowseMediaType {
        if SiloMediaType.isMixedLibrary(libraryType) { return .mixed }
        if SiloMediaType.isAudiobook(libraryType) { return .audiobook }
        if SiloMediaType.isSeries(libraryType) { return .series }
        return .movie
    }

    /// The catalog `type` (media_scope) param. Audiobooks omit it — the
    /// `library_id` already scopes the query, matching the existing browse
    /// paths which never send `type` for audiobook/music libraries. Mixed
    /// libraries omit it too so movies and series come back merged; the
    /// Type facet supplies a grouped rule when the user narrows.
    var catalogTypeParam: String? {
        switch self {
        case .movie: return "movie"
        case .series: return "series"
        case .audiobook, .mixed: return nil
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
    case releaseDate = "release_date"
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
        case .addedAt, .releaseDate, .year, .ratingImdb, .runtime, .resolution:
            return .desc
        }
    }

    /// Shown label. The raw value is the server sort field (data, D44).
    var label: LocalizedStringResource {
        switch self {
        case .title: return .catalogSortTitle
        case .addedAt: return .catalogSortAdded
        case .releaseDate: return .catalogSortReleased
        case .year: return .catalogSortYear
        case .ratingImdb: return .catalogSortRating
        case .runtime: return .catalogSortRuntime
        case .resolution: return .catalogSortResolution
        case .author: return .catalogSortAuthor
        case .narrator: return .catalogSortNarrator
        case .series: return .catalogSortSeries
        }
    }

    /// Short hint for the active direction, shown next to the active key.
    func directionLabel(for order: CatalogSortOrder) -> LocalizedStringResource {
        switch self {
        case .title, .author, .narrator, .series:
            return order == .asc ? .libraryDirectionAz : .libraryDirectionZa
        case .releaseDate, .year, .addedAt:
            return order == .asc ? .libraryDirectionOldest : .libraryDirectionNewest
        case .runtime:
            return order == .asc ? .libraryDirectionShortest : .libraryDirectionLongest
        case .ratingImdb, .resolution:
            return order == .asc ? .libraryDirectionLowest : .libraryDirectionHighest
        }
    }

    /// Sort keys offered for a library media type, in display order.
    static func available(for mediaType: BrowseMediaType) -> [CatalogSortKey] {
        switch mediaType {
        case .audiobook:
            return [.title, .author, .narrator, .series, .addedAt, .runtime]
        case .movie, .series, .mixed:
            return [.title, .addedAt, .releaseDate, .year, .ratingImdb, .runtime, .resolution]
        }
    }
}
