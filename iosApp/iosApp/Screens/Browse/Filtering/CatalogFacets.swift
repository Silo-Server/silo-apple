import Foundation

/// Client-facing superset of the server's `/catalog/filters` response,
/// normalized to non-optional arrays so the UI can read options without
/// unwrapping. Technical facets (resolution / audio / subtitle language)
/// are empty unless the request was made with `include_technical=true`.
struct CatalogFacets {
    var genres: [String] = []
    var studios: [String] = []
    var networks: [String] = []
    var countries: [String] = []
    var contentRatings: [String] = []
    var originalLanguages: [String] = []
    var authors: [String] = []
    var narrators: [String] = []
    var series: [String] = []
    var resolutions: [String] = []
    var audioLanguages: [String] = []
    var subtitleLanguages: [String] = []

    init() {}

    init(_ f: CatalogFilters) {
        genres = f.genres
        studios = f.studios
        networks = f.networks
        countries = f.countries
        contentRatings = f.contentRatings
        originalLanguages = f.originalLanguages ?? []
        authors = f.authors ?? []
        narrators = f.narrators ?? []
        series = f.series ?? []
        resolutions = f.resolutions ?? []
        audioLanguages = f.audioLanguages ?? []
        subtitleLanguages = f.subtitleLanguages ?? []
    }

    /// The server-provided option list for a facet. Fixed-vocabulary facets
    /// (decade / dynamic range / watch status) return `[]` — the UI supplies
    /// their values directly.
    func options(for facet: CatalogFacet) -> [String] {
        switch facet {
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
        case .seriesName: return series
        case .itemType, .decade, .dynamicRange, .watchStatus: return []
        }
    }

    /// The decade chips offered in the UI (newest first).
    static let decadeLadder: [Int] = [2020, 2010, 2000, 1990, 1980, 1970, 1960]

    /// (value, label) options for a facet — fixed vocab for derived facets,
    /// server vocab otherwise. `watchStatus` is hidden without a profile.
    func optionPairs(for facet: CatalogFacet, hasProfile: Bool) -> [(value: String, label: String)] {
        switch facet {
        case .itemType:
            return [("movie", "Movies"), ("series", "Series")]
        case .decade:
            return Self.decadeLadder.map { (String($0), "\($0)s") }
        case .dynamicRange:
            return [("hdr", "HDR"), ("dolby_vision", "Dolby Vision")]
        case .watchStatus:
            guard hasProfile else { return [] }
            return WatchStatusFilter.allCases.map { ($0.rawValue, $0.label) }
        default:
            return options(for: facet).map { ($0, $0) }
        }
    }
}

/// Loads and caches the per-library facet vocabulary, coalescing concurrent
/// requests like `StartupContentPrefetcher`. Filters change rarely, so a
/// cached value is returned without revalidation for the session.
@MainActor
final class FacetLoader {
    static let shared = FacetLoader()

    private var inFlight: [String: Task<CatalogFilters, Error>] = [:]

    func facets(libraryId: Int?, includeTechnical: Bool = true) async throws -> CatalogFacets {
        let key = CacheKey.catalogFilters(libraryId: libraryId, includeTechnical: includeTechnical)
        if let cached: CatalogFilters = ResponseCache.shared.get(key) {
            return CatalogFacets(cached)
        }
        return CatalogFacets(try await fetch(libraryId: libraryId, includeTechnical: includeTechnical, key: key))
    }

    /// Returns a cached facet set synchronously if present (for instant
    /// sheet/panel open), else `nil`.
    func cachedFacets(libraryId: Int?, includeTechnical: Bool = true) -> CatalogFacets? {
        let key = CacheKey.catalogFilters(libraryId: libraryId, includeTechnical: includeTechnical)
        guard let cached: CatalogFilters = ResponseCache.shared.get(key) else { return nil }
        return CatalogFacets(cached)
    }

    /// Warm the cache without awaiting (e.g. on library selection).
    func prefetch(libraryId: Int?) {
        let key = CacheKey.catalogFilters(libraryId: libraryId, includeTechnical: true)
        guard ResponseCache.shared.get(key) as CatalogFilters? == nil else { return }
        Task { _ = try? await fetch(libraryId: libraryId, includeTechnical: true, key: key) }
    }

    private func fetch(libraryId: Int?, includeTechnical: Bool, key: String) async throws -> CatalogFilters {
        if let existing = inFlight[key] { return try await existing.value }
        let task = Task {
            try await SiloAPI.shared.catalogFilters(libraryId: libraryId, includeTechnical: includeTechnical)
        }
        inFlight[key] = task
        do {
            let result = try await task.value
            inFlight[key] = nil
            ResponseCache.shared.set(result, for: key)
            return result
        } catch {
            inFlight[key] = nil
            throw error
        }
    }
}
