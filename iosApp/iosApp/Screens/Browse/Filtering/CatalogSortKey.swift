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
/// (silo-server `query_definition.go` `querySortDefs`). Cases, names, order,
/// default directions, and which libraries list them mirror the web client's
/// `web/src/lib/querySortOptions.ts`, so every client offers the same sorts.
/// `defaultOrder` is the direction a newly picked sort starts in.
enum CatalogSortKey: String, CaseIterable, Codable, Hashable {
    case title
    case addedAt = "added_at"
    case releaseDate = "release_date"
    case lastAirDate = "last_air_date"
    case latestEpisodeAdded = "latest_episode_added"
    case year
    case contentRating = "content_rating"
    case runtime
    case ratingImdb = "rating_imdb"
    case ratingTmdb = "rating_tmdb"
    case ratingRtCritic = "rating_rt_critic"
    case ratingRtAudience = "rating_rt_audience"
    case resolution
    case bitrate
    // per-profile: ordered by this profile's own watching
    case progress
    case dateViewed = "date_viewed"
    case plays
    // audiobook-native
    case author
    case narrator
    case series

    /// Canonical server sort field.
    var field: String { rawValue }

    var defaultOrder: CatalogSortOrder {
        switch self {
        case .title, .contentRating, .author, .narrator, .series:
            return .asc
        case .addedAt, .releaseDate, .lastAirDate, .latestEpisodeAdded, .year, .runtime,
             .ratingImdb, .ratingTmdb, .ratingRtCritic, .ratingRtAudience, .resolution, .bitrate,
             .progress, .dateViewed, .plays:
            return .desc
        }
    }

    /// Shown label. The raw value is the server sort field (data, D44).
    var label: LocalizedStringResource {
        switch self {
        case .title: return .catalogSortTitle
        case .addedAt: return .catalogSortAdded
        case .releaseDate: return .catalogSortReleased
        case .lastAirDate: return .catalogSortLatestEpisodeAirDate
        case .latestEpisodeAdded: return .catalogSortLatestEpisodeAdded
        case .year: return .catalogSortYear
        case .contentRating: return .catalogSortContentRating
        case .runtime: return .catalogSortDuration
        case .ratingImdb: return .catalogSortImdbRating
        case .ratingTmdb: return .catalogSortTmdbRating
        case .ratingRtCritic: return .catalogSortRtCriticRating
        case .ratingRtAudience: return .catalogSortRtAudienceRating
        case .resolution: return .catalogSortResolution
        case .bitrate: return .catalogSortBitrate
        case .progress: return .catalogSortProgress
        case .dateViewed: return .catalogSortDateViewed
        case .plays: return .catalogSortPlays
        case .author: return .catalogSortAuthor
        case .narrator: return .catalogSortNarrator
        case .series: return .catalogSortSeries
        }
    }

    /// Short hint for the active direction, shown next to the active key.
    func directionLabel(for order: CatalogSortOrder) -> LocalizedStringResource {
        switch self {
        case .title, .contentRating, .author, .narrator, .series:
            return order == .asc ? .libraryDirectionAz : .libraryDirectionZa
        case .addedAt, .releaseDate, .lastAirDate, .latestEpisodeAdded, .year, .dateViewed:
            return order == .asc ? .libraryDirectionOldest : .libraryDirectionNewest
        case .runtime:
            return order == .asc ? .libraryDirectionShortest : .libraryDirectionLongest
        case .ratingImdb, .ratingTmdb, .ratingRtCritic, .ratingRtAudience, .resolution, .bitrate, .progress:
            return order == .asc ? .libraryDirectionLowest : .libraryDirectionHighest
        case .plays:
            return order == .asc ? .libraryDirectionFewest : .libraryDirectionMost
        }
    }

    /// The rating source a rating sort needs the server to show
    /// (`GET /api/v2/capabilities/ratings`); nil for every other sort.
    var ratingSource: String? {
        switch self {
        case .ratingRtCritic: return "rt_critic"
        case .ratingRtAudience: return "rt_audience"
        default: return nil
        }
    }

    /// Whether the key orders a library of `mediaType`, as the web client
    /// decides. A mixed library lists only keys that order movies and series
    /// alike, so the episode sorts appear once it is narrowed to Series.
    func applies(to mediaType: BrowseMediaType) -> Bool {
        switch self {
        case .title, .addedAt, .releaseDate, .year, .runtime, .bitrate, .progress, .dateViewed, .plays:
            return true
        case .lastAirDate, .latestEpisodeAdded:
            return mediaType == .series
        case .contentRating, .ratingImdb, .ratingTmdb, .ratingRtCritic, .ratingRtAudience, .resolution:
            return mediaType != .audiobook
        case .author, .narrator, .series:
            return mediaType == .audiobook
        }
    }

    /// The media a sort list is for: a mixed library narrowed to Movies or
    /// Series by its Type filter sorts as that type, as the web client does.
    /// The Type filter only narrows the results when every filter must match
    /// or it is the only filter; under Match Any another filter can let the
    /// other type back in, so the list stays the mixed one.
    static func sortMediaType(_ mediaType: BrowseMediaType, filter: CatalogFilterState) -> BrowseMediaType {
        guard mediaType == .mixed, filter.matchAll || filter.activeFacetCount <= 1 else { return mediaType }
        switch filter.mediaScope {
        case "series": return .series
        case "movie": return .movie
        default: return .mixed
        }
    }

    /// Sort keys offered for a library of `mediaType`, in the web client's
    /// order. A rating sort is listed only while the server shows its source
    /// (`shownRatingSources`). `current`, the sort in use, is always listed,
    /// so a sort restored from saved preferences stays visible and can be
    /// changed even where the list would not otherwise offer it.
    static func available(
        for mediaType: BrowseMediaType,
        shownRatingSources: Set<String> = [],
        current: CatalogSortKey? = nil
    ) -> [CatalogSortKey] {
        allCases.filter { key in
            key == current || (
                key.applies(to: mediaType) &&
                    (key.ratingSource.map(shownRatingSources.contains) ?? true)
            )
        }
    }
}
