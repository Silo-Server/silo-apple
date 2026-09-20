import Foundation

/// Server sync behind the card context-menu toggles. Mirrors
/// `ItemDetailViewModel.toggleFavorite/toggleWatchlist`: on success it
/// writes back the cached per-item user-state pair (so a subsequent
/// detail visit renders the right buttons immediately) and drops the
/// derived list caches so Favorites / Watchlist / Home refetch fresh.
@MainActor
enum PersonalListSync {
    /// Returns false when the server call failed — the caller reverts
    /// its optimistic UI state. The sibling flag is only a write-back
    /// fallback; a fresher cached value for it wins (see `writeBack`).
    static func setFavorite(contentId: String, isFavorite: Bool, inWatchlist: Bool) async -> Bool {
        do {
            try await SiloAPI.shared.toggleFavorite(contentId: contentId, isFavorite: isFavorite)
            writeBack(contentId: contentId, isFavorite: isFavorite, fallbackInWatchlist: inWatchlist)
            return true
        } catch {
            return false
        }
    }

    static func setWatchlist(contentId: String, isFavorite: Bool, inWatchlist: Bool) async -> Bool {
        do {
            try await SiloAPI.shared.toggleWatchlist(contentId: contentId, isInWatchlist: inWatchlist)
            writeBack(contentId: contentId, inWatchlist: inWatchlist, fallbackIsFavorite: isFavorite)
            return true
        } catch {
            return false
        }
    }

    /// Merges the toggled flag over the cached pair rather than writing the
    /// caller's full snapshot: two quick toggles race their server round
    /// trips, and the slower write must not revert the sibling flag the
    /// faster one already committed to the cache. The caller's snapshot is
    /// only used when nothing is cached yet.
    private static func writeBack(
        contentId: String,
        isFavorite: Bool? = nil,
        inWatchlist: Bool? = nil,
        fallbackIsFavorite: Bool = false,
        fallbackInWatchlist: Bool = false
    ) {
        let key = CacheKey.itemUserState(contentId)
        let cached: UserItemState? = ResponseCache.shared.get(key)
        ResponseCache.shared.set(
            UserItemState(
                isFavorite: isFavorite ?? cached?.isFavorite ?? fallbackIsFavorite,
                inWatchlist: inWatchlist ?? cached?.inWatchlist ?? fallbackInWatchlist
            ),
            for: key
        )
        ResponseCache.shared.remove(CacheKey.favorites)
        ResponseCache.shared.remove(CacheKey.watchlist)
        ResponseCache.shared.remove(CacheKey.homeSections)
        ResponseCache.shared.remove(CacheKey.recommendations)
        for prefix in ["browse:", "tvlibrary:", "library:", "collection:"] {
            ResponseCache.shared.removeAll(withPrefix: prefix)
        }
    }
}
