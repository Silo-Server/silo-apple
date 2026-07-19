import Foundation

/// Personalized watch-status facet. Each maps to a boolean server rule and
/// requires an active profile.
enum WatchStatusFilter: String, Codable, CaseIterable, Hashable {
    case unwatched
    case inProgress
    case watched
    case favorited
    case watchlist

    var label: String {
        switch self {
        case .unwatched: return "Unwatched"
        case .inProgress: return "In Progress"
        case .watched: return "Watched"
        case .favorited: return "Favorited"
        case .watchlist: return "Watchlist"
        }
    }
}

/// A facet dimension the user can filter on. The raw value matches the
/// server rule `field` where one applies (`query_definition.go`
/// `queryFieldDefs`); `decade`, `dynamicRange`, and `watchStatus` are
/// client-side groupings that lower to one or more server rules.
enum CatalogFacet: String, CaseIterable, Codable, Hashable {
    /// Movie-vs-series scope, offered only in mixed libraries. Lowers to the
    /// catalog `type` (media_scope) param rather than a rule group.
    case itemType = "item_type"
    case genre
    case decade
    case watchStatus
    case contentRating = "content_rating"
    case resolution
    case dynamicRange
    case studio
    case network
    case country
    case audioLanguage = "audio_language"
    case subtitleLanguage = "subtitle_language"
    case originalLanguage = "original_language"
    // audiobook-native
    case author
    case narrator
    case seriesName

    var title: String {
        switch self {
        case .itemType: return "Type"
        case .genre: return "Genre"
        case .decade: return "Decade"
        case .watchStatus: return "Watch Status"
        case .contentRating: return "Content Rating"
        case .resolution: return "Resolution"
        case .dynamicRange: return "Dynamic Range"
        case .studio: return "Studio"
        case .network: return "Network"
        case .country: return "Country"
        case .audioLanguage: return "Audio Language"
        case .subtitleLanguage: return "Subtitle Language"
        case .originalLanguage: return "Original Language"
        case .author: return "Author"
        case .narrator: return "Narrator"
        case .seriesName: return "Series"
        }
    }

    /// Whether this facet's options come from the technical block of
    /// `/catalog/filters` (requires `include_technical=true`).
    var isTechnical: Bool {
        switch self {
        case .resolution, .audioLanguage, .subtitleLanguage: return true
        default: return false
        }
    }

    /// Whether the facet is a fixed/derived vocabulary rather than a
    /// server-provided value list (decade, dynamic range, watch status).
    var hasFixedVocabulary: Bool {
        switch self {
        case .itemType, .decade, .dynamicRange, .watchStatus: return true
        default: return false
        }
    }

    /// Facets offered for a library media type, in display order. Sections
    /// whose option list resolves empty are hidden by the UI.
    static func available(for mediaType: BrowseMediaType) -> [CatalogFacet] {
        switch mediaType {
        case .movie, .series:
            return [.genre, .decade, .watchStatus, .contentRating, .resolution,
                    .dynamicRange, .studio, .network, .country,
                    .audioLanguage, .subtitleLanguage, .originalLanguage]
        case .mixed:
            return [.itemType, .genre, .decade, .watchStatus, .contentRating, .resolution,
                    .dynamicRange, .studio, .network, .country,
                    .audioLanguage, .subtitleLanguage, .originalLanguage]
        case .audiobook:
            return [.genre, .author, .narrator, .seriesName, .decade, .watchStatus]
        }
    }
}

/// A single active selection, surfaced as a removable chip.
struct CatalogFilterChip: Identifiable, Hashable {
    let facet: CatalogFacet
    /// The underlying value (genre name, decade start year as string,
    /// watch-status raw value, "hdr"/"dolby_vision"). `nil` is never used —
    /// every chip removes exactly one value.
    let value: String
    let label: String
    var id: String { "\(facet.rawValue):\(value)" }
}

/// The full applied browse filter + sort state. Shared across iOS and tvOS.
/// `Equatable` drives generation comparison; `Codable` drives per-library
/// persistence (`BrowsePrefsStore`).
struct CatalogFilterState: Equatable, Codable, Hashable {
    var sort: CatalogSortKey = .title
    /// `nil` = use `sort.defaultOrder`.
    var order: CatalogSortOrder? = nil
    /// Across-facet combination: `true` → `match=all` (AND), `false` →
    /// `match=any` (OR). Within a single multi-value facet values are always
    /// OR'd.
    var matchAll: Bool = true

    /// Movie-vs-series scope for mixed libraries ("movie" / "series");
    /// `nil` = both. Single-select; lowers to the catalog `type` param.
    var mediaScope: String? = nil
    var genres: Set<String> = []
    var contentRatings: Set<String> = []
    var studios: Set<String> = []
    var networks: Set<String> = []
    var countries: Set<String> = []
    var resolutions: Set<String> = []
    var audioLanguages: Set<String> = []
    var subtitleLanguages: Set<String> = []
    var originalLanguages: Set<String> = []
    var authors: Set<String> = []
    var narrators: Set<String> = []
    var seriesNames: Set<String> = []
    /// Decade start years (e.g. 2010 for "2010s"). Each lowers to a
    /// `year between [start, start+9]` rule.
    var decades: Set<Int> = []
    var hdr: Bool = false
    var dolbyVision: Bool = false
    var watchStatus: WatchStatusFilter? = nil

    /// Alphabet-rail prefix (tvOS). Orthogonal to facets, included in the
    /// cache key but never persisted (a transient jump).
    var namePrefix: String? = nil

    static let none = CatalogFilterState()

    var effectiveOrder: CatalogSortOrder { order ?? sort.defaultOrder }

    /// Whether any facet (not sort, not namePrefix) is active.
    var hasActiveFilters: Bool { activeFacetCount > 0 }

    /// Number of active facet dimensions (for the count badge).
    var activeFacetCount: Int {
        var n = 0
        for set in [genres, contentRatings, studios, networks, countries,
                    resolutions, audioLanguages, subtitleLanguages,
                    originalLanguages, authors, narrators, seriesNames]
        where !set.isEmpty { n += 1 }
        if mediaScope != nil { n += 1 }
        if !decades.isEmpty { n += 1 }
        if hdr || dolbyVision { n += 1 }
        if watchStatus != nil { n += 1 }
        return n
    }

    var canResetFilters: Bool {
        hasActiveFilters || !matchAll
    }

    /// True when this is the untouched default view (Title, natural order,
    /// no facets) — used to decide whether to show a "clear" affordance.
    var isDefault: Bool {
        sort == .title && order == nil && matchAll && !hasActiveFilters && namePrefix == nil
    }

    // MARK: - Generic facet access (keeps the UI loops simple)

    func selectedValues(_ facet: CatalogFacet) -> Set<String> {
        switch facet {
        case .itemType: return mediaScope.map { [$0] } ?? []
        case .genre: return genres
        case .contentRating: return contentRatings
        case .studio: return studios
        case .network: return networks
        case .country: return countries
        case .resolution: return resolutions
        case .audioLanguage: return audioLanguages
        case .subtitleLanguage: return subtitleLanguages
        case .originalLanguage: return originalLanguages
        case .author: return authors
        case .narrator: return narrators
        case .seriesName: return seriesNames
        case .decade: return Set(decades.map(String.init))
        case .dynamicRange:
            var s = Set<String>()
            if hdr { s.insert("hdr") }
            if dolbyVision { s.insert("dolby_vision") }
            return s
        case .watchStatus:
            return watchStatus.map { [$0.rawValue] } ?? []
        }
    }

    func isSelected(_ facet: CatalogFacet, value: String) -> Bool {
        selectedValues(facet).contains(value)
    }

    /// Toggle a value within a facet. Watch status is single-select
    /// (toggling the active value clears it); everything else is multi-select.
    mutating func toggle(_ facet: CatalogFacet, value: String) {
        switch facet {
        case .itemType:
            mediaScope = (mediaScope == value) ? nil : value
        case .genre: Self.toggle(&genres, value)
        case .contentRating: Self.toggle(&contentRatings, value)
        case .studio: Self.toggle(&studios, value)
        case .network: Self.toggle(&networks, value)
        case .country: Self.toggle(&countries, value)
        case .resolution: Self.toggle(&resolutions, value)
        case .audioLanguage: Self.toggle(&audioLanguages, value)
        case .subtitleLanguage: Self.toggle(&subtitleLanguages, value)
        case .originalLanguage: Self.toggle(&originalLanguages, value)
        case .author: Self.toggle(&authors, value)
        case .narrator: Self.toggle(&narrators, value)
        case .seriesName: Self.toggle(&seriesNames, value)
        case .decade:
            if let y = Int(value) {
                if decades.contains(y) { decades.remove(y) } else { decades.insert(y) }
            }
        case .dynamicRange:
            if value == "hdr" { hdr.toggle() }
            else if value == "dolby_vision" { dolbyVision.toggle() }
        case .watchStatus:
            let next = WatchStatusFilter(rawValue: value)
            watchStatus = (watchStatus == next) ? nil : next
        }
    }

    /// Clear a whole facet dimension.
    mutating func clear(_ facet: CatalogFacet) {
        switch facet {
        case .itemType: mediaScope = nil
        case .genre: genres.removeAll()
        case .contentRating: contentRatings.removeAll()
        case .studio: studios.removeAll()
        case .network: networks.removeAll()
        case .country: countries.removeAll()
        case .resolution: resolutions.removeAll()
        case .audioLanguage: audioLanguages.removeAll()
        case .subtitleLanguage: subtitleLanguages.removeAll()
        case .originalLanguage: originalLanguages.removeAll()
        case .author: authors.removeAll()
        case .narrator: narrators.removeAll()
        case .seriesName: seriesNames.removeAll()
        case .decade: decades.removeAll()
        case .dynamicRange: hdr = false; dolbyVision = false
        case .watchStatus: watchStatus = nil
        }
    }

    /// Reset filter facets and matching mode to defaults (keeps sort/order
    /// and namePrefix).
    mutating func resetFilters() {
        let currentSort = sort
        let currentOrder = order
        let prefix = namePrefix
        self = .none
        sort = currentSort
        order = currentOrder
        namePrefix = prefix
    }

    private static func toggle(_ set: inout Set<String>, _ value: String) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    // MARK: - Chips

    /// Active selections as removable chips, in facet display order.
    func activeChips() -> [CatalogFilterChip] {
        var chips: [CatalogFilterChip] = []
        let ordered: [CatalogFacet] = [.itemType, .genre, .decade, .watchStatus, .contentRating,
                                       .resolution, .dynamicRange, .studio, .network,
                                       .country, .audioLanguage, .subtitleLanguage,
                                       .originalLanguage, .author, .narrator, .seriesName]
        for facet in ordered {
            for value in selectedValues(facet).sorted() {
                chips.append(CatalogFilterChip(facet: facet, value: value,
                                               label: Self.chipLabel(facet: facet, value: value)))
            }
        }
        return chips
    }

    static func chipLabel(facet: CatalogFacet, value: String) -> String {
        switch facet {
        case .itemType:
            return value == "series" ? "Series" : "Movies"
        case .decade:
            return Int(value).map { "\($0)s" } ?? value
        case .dynamicRange:
            return value == "dolby_vision" ? "Dolby Vision" : "HDR"
        case .watchStatus:
            return WatchStatusFilter(rawValue: value)?.label ?? value
        default:
            return value
        }
    }

    // MARK: - Cache discriminator

    /// Stable serialization used as the response-cache discriminator. Unlike
    /// persistence, this DOES include `namePrefix` — the fetched page content
    /// depends on it.
    var cacheKeyFragment: String {
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? value
        }
        func join(_ s: Set<String>) -> String { s.sorted().map(encode).joined(separator: ",") }
        var parts: [String] = [
            "s=\(sort.field)",
            "o=\(effectiveOrder.rawValue)",
            "m=\(matchAll ? "all" : "any")",
        ]
        if let p = namePrefix { parts.append("p=\(encode(p))") }
        if let sc = mediaScope { parts.append("sc=\(encode(sc))") }
        if !genres.isEmpty { parts.append("g=\(join(genres))") }
        if !contentRatings.isEmpty { parts.append("cr=\(join(contentRatings))") }
        if !studios.isEmpty { parts.append("st=\(join(studios))") }
        if !networks.isEmpty { parts.append("nw=\(join(networks))") }
        if !countries.isEmpty { parts.append("co=\(join(countries))") }
        if !resolutions.isEmpty { parts.append("res=\(join(resolutions))") }
        if !audioLanguages.isEmpty { parts.append("al=\(join(audioLanguages))") }
        if !subtitleLanguages.isEmpty { parts.append("sl=\(join(subtitleLanguages))") }
        if !originalLanguages.isEmpty { parts.append("ol=\(join(originalLanguages))") }
        if !authors.isEmpty { parts.append("au=\(join(authors))") }
        if !narrators.isEmpty { parts.append("na=\(join(narrators))") }
        if !seriesNames.isEmpty { parts.append("se=\(join(seriesNames))") }
        if !decades.isEmpty { parts.append("dec=\(decades.sorted().map(String.init).joined(separator: ","))") }
        if hdr { parts.append("hdr") }
        if dolbyVision { parts.append("dv") }
        if let w = watchStatus { parts.append("ws=\(encode(w.rawValue))") }
        return parts.joined(separator: "|")
    }
}
