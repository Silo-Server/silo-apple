import SwiftUI

/// The favorite / watchlist entries shared by the media-card context
/// menus (long press on iOS/macOS, long press on the touch surface on
/// tvOS). Labels reflect the caller's current membership state; the
/// caller owns the optimistic flip and the API call.
struct PersonalListMenuItems: View {
    let isFavorite: Bool
    let inWatchlist: Bool
    let onToggleFavorite: () -> Void
    let onToggleWatchlist: () -> Void

    var body: some View {
        Group {
            Button(action: onToggleFavorite) {
                Label(
                    isFavorite ? "Remove from Favorites" : "Add to Favorites",
                    systemImage: isFavorite ? "heart.slash" : "heart"
                )
            }
            Button(action: onToggleWatchlist) {
                Label(
                    inWatchlist ? "Remove from Watchlist" : "Add to Watchlist",
                    systemImage: inWatchlist ? "bookmark.slash" : "bookmark"
                )
            }
        }
    }
}

extension View {
    /// Attaches a long-press context menu with the given favorite /
    /// watchlist items, or leaves the view untouched when `nil` — so
    /// cards without a catalog identity never get an empty menu.
    @ViewBuilder
    func personalListContextMenu(_ items: PersonalListMenuItems?) -> some View {
        if let items {
            contextMenu { items }
        } else {
            self
        }
    }
}

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
            try await ContinuumAPI.shared.toggleFavorite(contentId: contentId, isFavorite: isFavorite)
            writeBack(contentId: contentId, isFavorite: isFavorite, fallbackInWatchlist: inWatchlist)
            return true
        } catch {
            return false
        }
    }

    static func setWatchlist(contentId: String, isFavorite: Bool, inWatchlist: Bool) async -> Bool {
        do {
            try await ContinuumAPI.shared.toggleWatchlist(contentId: contentId, isInWatchlist: inWatchlist)
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
    }
}
