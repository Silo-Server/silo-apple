import Foundation

/// Process-wide stale-while-revalidate cache for decoded API responses.
///
/// Callers compose a string key for the request they're about to make,
/// pull the last-known value out synchronously (rendering it instantly
/// while a fresh fetch runs in the background), then write the fresh
/// result back. The cache is intentionally dumb — no TTLs, no LRU. Any
/// per-screen size limits should live with the screen.
///
/// Profile / server-switch / sign-out paths must clear the cache (or
/// targeted prefixes) so per-profile state doesn't leak across accounts.
/// Hooks live in `AuthService`.
@MainActor
final class ResponseCache {
    static let shared = ResponseCache()

    private var entries: [String: Any] = [:]

    private init() {}

    /// Returns the cached value typed as `T` if one exists. Mismatched
    /// types return nil rather than crashing — the caller falls back to
    /// the network like any other miss.
    func get<T>(_ key: String, as: T.Type = T.self) -> T? {
        entries[key] as? T
    }

    func set<T>(_ value: T, for key: String) {
        entries[key] = value
    }

    func remove(_ key: String) {
        entries.removeValue(forKey: key)
    }

    /// Mutate a cached value in place. Used by optimistic mutations
    /// (favorite, watched, etc.) so a returning screen sees the same
    /// toggle state without a network round-trip.
    func update<T>(_ key: String, as: T.Type = T.self, transform: (inout T) -> Void) {
        guard var value = entries[key] as? T else { return }
        transform(&value)
        entries[key] = value
    }

    /// Drop every entry whose key starts with `prefix`. Useful for
    /// invalidating a family (e.g. "item:" after a profile switch).
    func removeAll(withPrefix prefix: String) {
        entries = entries.filter { !$0.key.hasPrefix(prefix) }
    }

    /// Drop every cached response whose contents carry a translatable
    /// overview/tagline, so the next fetch picks up the server-side
    /// translation for a newly-changed preferred metadata language.
    ///
    /// The language is profile-global and changes rarely, so rather than
    /// adding a language dimension to every cache key we flush the whole
    /// `item:` family (detail / seasons / episodes / watch detail) plus
    /// the home-sections and recommendations rows that embed item
    /// summaries. Call this ONLY when the metadata language actually
    /// changed. tvOS additionally holds an `ItemDetailCache` — clear that
    /// at the same call site.
    func invalidateAllItemMetadata() {
        removeAll(withPrefix: "item:")
        remove(CacheKey.homeSections)
        remove(CacheKey.recommendations)
    }

    func clearAll() {
        entries.removeAll()
    }
}

/// Canonical key strings. Centralizing them keeps cache reads and
/// writes from drifting apart and makes prefix-invalidation safe.
enum CacheKey {
    static let homeSections = "home:sections"
    static let recommendations = "recommendations:discover"
    static let collections = "collections:list"
    static let profiles = "profiles:list"
    static let favorites = "personal:favorites"
    static let history = "personal:history"
    static let watchlist = "personal:watchlist"
    /// Libraries visible to the active profile — drives the Skyline
    /// type-derived tabs on tvOS.
    static let userLibraries = "user:libraries"

    static func itemDetail(_ contentId: String) -> String { "item:\(contentId)" }
    static func itemSeasons(_ seriesId: String) -> String { "item:\(seriesId):seasons" }
    static func itemEpisodes(seriesId: String, seasonNumber: Int) -> String {
        "item:\(seriesId):season:\(seasonNumber):episodes"
    }
    static func itemUserState(_ contentId: String) -> String { "item:\(contentId):userState" }
    static func itemWatchDetail(_ contentId: String) -> String { "item:\(contentId):watchDetail" }
    /// Browse grid page-1 cache, keyed by the full filter/sort state so
    /// distinct filter combinations never collide (the old genre+sort-only
    /// key did). `filterKey` is `CatalogFilterState.cacheKeyFragment`.
    static func browse(libraryId: Int?, filterKey: String) -> String {
        "browse:\(libraryId.map(String.init) ?? "all"):\(filterKey)"
    }
    /// Per-library facet vocabulary from `/catalog/filters`.
    static func catalogFilters(libraryId: Int?, includeTechnical: Bool = true) -> String {
        "catalogFilters:\(libraryId.map(String.init) ?? "all"):\(includeTechnical ? "technical" : "basic")"
    }
    static func librarySections(_ libraryId: Int) -> String {
        "library:\(libraryId):sections"
    }
    static func tvLibrary(libraryId: Int, filterKey: String) -> String {
        "tvlibrary:\(libraryId):\(filterKey)"
    }
    static func collectionItems(_ collectionId: String) -> String { "collection:\(collectionId):items" }
    static func similar(_ contentId: String) -> String { "item:\(contentId):similar" }
    static func calendarWeek(_ weekStart: String, filter: String) -> String {
        "calendar:\(weekStart):\(filter)"
    }

    /// Per-profile data that must be dropped on profile switch.
    static let perProfilePrefixes: [String] = [
        "home:",
        "recommendations:",
        "browse:",
        "library:",
        "personal:",
        "item:",
        "collection:",
        "collections:",
        "calendar:",
        "user:",
        // Browse pages and facet lists are access-filtered per profile, and
        // watch-status filters make a page profile-specific.
        "tvlibrary:",
        "catalogFilters:",
    ]
}
