import Foundation
#if canImport(UIKit)
import UIKit
#endif

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

    private init() {
        #if canImport(UIKit)
        // Item pages are the bulk of the cache and the cheapest to refetch.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                ResponseCache.shared.clearMemory(withPrefix: "item:")
            }
        }
        #endif
    }

    /// Returns the cached value typed as `T` if one exists. Mismatched
    /// types return nil rather than crashing — the caller falls back to
    /// the network like any other miss.
    func get<T>(_ key: String, as: T.Type = T.self) -> T? {
        entries[key] as? T
    }

    func set<T>(_ value: T, for key: String) {
        entries[key] = value
        storeSnapshot(value, for: key)
    }

    func remove(_ key: String) {
        entries.removeValue(forKey: key)
        if ResponseSnapshotStore.snapshotType(forKey: key) != nil, let scope = snapshotScope {
            ResponseSnapshotStore.remove(scope: scope) { $0 == key }
        }
    }

    /// Personal mutations affect every library presentation of the same item.
    func removeItemMetadata(contentId: String) {
        let key = CacheKey.itemDetail(contentId)
        remove(key)
        removeAll(withPrefix: key + ":")
    }

    /// Mutate a cached value in place. Used by optimistic mutations
    /// (favorite, watched, etc.) so a returning screen sees the same
    /// toggle state without a network round-trip.
    func update<T>(_ key: String, as: T.Type = T.self, transform: (inout T) -> Void) {
        guard var value = entries[key] as? T else { return }
        transform(&value)
        entries[key] = value
        storeSnapshot(value, for: key)
    }

    /// Drop every entry whose key starts with `prefix`. Useful for
    /// invalidating a family (e.g. "item:" after a profile switch).
    func removeAll(withPrefix prefix: String) {
        for key in entries.keys where key.hasPrefix(prefix) {
            entries.removeValue(forKey: key)
        }
        // Snapshots of the family too, including keys this process never
        // loaded, so a later seed cannot bring the invalidated data back.
        if let scope = snapshotScope {
            ResponseSnapshotStore.remove(scope: scope) { $0.hasPrefix(prefix) }
        }
    }

    /// Drop every cached response whose contents carry a translatable
    /// overview/tagline, so the next fetch picks up the server-side
    /// translation for a newly-changed preferred metadata language.
    ///
    /// The language is profile-global and changes rarely, so rather than
    /// adding a language dimension to every cache key we flush the whole
    /// `item:` family (detail / seasons / episodes / watch detail) plus
    /// the home-sections and recommendations rows that embed item
    /// summaries. Every snapshot carries summaries too, so the profile's
    /// snapshots all go. Call this ONLY when the metadata language actually
    /// changed. tvOS additionally holds an `ItemDetailCache` — clear that
    /// at the same call site.
    func invalidateAllItemMetadata() {
        removeAll(withPrefix: "item:")
        remove(CacheKey.homeSections)
        remove(CacheKey.recommendations)
        if let scope = snapshotScope {
            ResponseSnapshotStore.remove(scope: scope) { _ in true }
        }
    }

    /// Sign-out boundary: memory and the on-disk snapshots of every scope.
    func clearAll() {
        clearMemory()
        ResponseSnapshotStore.removeAll()
    }

    /// Identity boundary that keeps the saved snapshots: a remote-playback
    /// handoff and its end. The owner's snapshots stay for their next launch.
    func clearMemory() {
        entries.removeAll()
        seededScope = nil
    }

    /// Profile boundary (restore, switch, deselect): drops what this process
    /// loaded for the family but keeps the profile's snapshots, which a
    /// launch restoring that profile seeds from right after. Invalidations
    /// use `removeAll(withPrefix:)` instead.
    func clearMemory(withPrefix prefix: String) {
        for key in entries.keys where key.hasPrefix(prefix) {
            entries.removeValue(forKey: key)
        }
        seededScope = nil
    }

    /// True while a remote-playback handoff runs under another account or
    /// profile. The persisted server and profile still name the owner then,
    /// so snapshots are neither written nor read.
    var snapshotsSuspended = false
    /// The scope already seeded in this process. Seeding again (a new
    /// iPad window, a profile reselect) would bring back responses that
    /// were since replaced or invalidated in memory.
    private var seededScope: ResponseSnapshotStore.Scope?

    // MARK: - Snapshots

    /// Fill keys this process has not loaded yet from the active profile's
    /// last-known responses, so the first screens can paint before the
    /// network answers.
    func seedFromSnapshots() {
        guard let scope = snapshotScope, scope != seededScope else { return }
        seededScope = scope
        for (key, value) in ResponseSnapshotStore.load(scope: scope) where entries[key] == nil {
            entries[key] = value
        }
    }

    private func storeSnapshot<T>(_ value: T, for key: String) {
        guard ResponseSnapshotStore.snapshotType(forKey: key) != nil,
              let encodable = value as? any Encodable,
              let scope = snapshotScope else { return }
        ResponseSnapshotStore.store(encodable, forKey: key, scope: scope)
    }

    /// The server and profile that own responses cached right now.
    private var snapshotScope: ResponseSnapshotStore.Scope? {
        guard !snapshotsSuspended,
              let serverId = ServerRegistry.activeServerIDSnapshot,
              let profileId = AuthService.shared.profileId else { return nil }
        return ResponseSnapshotStore.Scope(serverId: serverId, profileId: profileId)
    }
}

/// Canonical key strings. Centralizing them keeps cache reads and
/// writes from drifting apart and makes prefix-invalidation safe.
enum CacheKey {
    static let homeSections = "home:sections:v2"
    static let recommendations = "recommendations:discover"
    static let collections = "collections:list"
    static let profiles = "profiles:list"
    static let favorites = "personal:favorites"
    static let history = "personal:history:v2"
    static let watchlist = "personal:watchlist"
    /// Libraries visible to the active profile — drives the Skyline
    /// type-derived tabs on tvOS.
    static let userLibraries = "user:libraries"

    static func itemDetail(_ contentId: String, libraryId: Int? = nil) -> String {
        // Opaque IDs may contain our delimiter or literal escape sequences.
        let encodedId = contentId.replacingOccurrences(of: "%", with: "%25")
            .replacingOccurrences(of: ":", with: "%3A")
        return "item:\(encodedId)" + (libraryId.map { ":library:\($0)" } ?? "")
    }
    static func itemSeasons(_ seriesId: String, libraryId: Int? = nil) -> String { "\(itemDetail(seriesId, libraryId: libraryId)):seasons" }
    static func itemEpisodes(seriesId: String, seasonNumber: Int, libraryId: Int? = nil) -> String {
        "\(itemDetail(seriesId, libraryId: libraryId)):season:\(seasonNumber):episodes"
    }
    static func itemUserState(_ contentId: String) -> String { "\(itemDetail(contentId)):userState" }
    static func itemWatchDetail(_ contentId: String, libraryId: Int? = nil) -> String { "\(itemDetail(contentId, libraryId: libraryId)):watchDetail" }
    /// Browse grid page-1 cache, keyed by the full filter/sort state
    /// (`CatalogFilterState.cacheKeyFragment`).
    static func browse(libraryId: Int?, filterKey: String) -> String {
        "browse:v2:\(libraryId.map(String.init) ?? "all"):\(filterKey)"
    }
    /// Per-library facet vocabulary from `/catalog/filters`.
    static func catalogFilters(libraryId: Int?, includeTechnical: Bool = true) -> String {
        "catalogFilters:\(libraryId.map(String.init) ?? "all"):\(includeTechnical ? "technical" : "basic")"
    }
    static func librarySections(_ libraryId: Int) -> String {
        "library:\(libraryId):sections"
    }
    static func tvLibrary(libraryId: Int, filterKey: String) -> String {
        "tvlibrary:v2:\(libraryId):\(filterKey)"
    }
    static func collectionItems(_ collectionId: String) -> String { "collection:\(collectionId):items" }
    /// First page of a collection's items from the v2 catalog, kept apart
    /// from the raw collection-items list.
    static func catalogCollectionItems(_ collectionId: String) -> String {
        "collection:\(collectionId):catalog:v2"
    }
    static func similar(_ contentId: String) -> String { "\(itemDetail(contentId)):similar" }
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
