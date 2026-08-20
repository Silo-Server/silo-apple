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

/// The card context menu shared by `MediaCard` (iOS/macOS long press and the
/// tvOS `FocusableMediaCard` wrapper), `EpisodeThumbCard` and Home's card
/// menu: watched toggle, then the personal-list entries, then the destructive
/// removal. Each caller supplies an `onSetWatched` that already wraps its own
/// optimistic watched flip, and `nil` for whatever it doesn't offer.
struct CardContextMenuItems: View {
    let isWatched: Bool
    let onSetWatched: ((Bool) async -> Bool)?
    let personalItems: PersonalListMenuItems?
    let onRemoveFromContinueWatching: (() -> Void)?

    /// False when the card has nothing to show — those cards get no menu at
    /// all rather than an empty one.
    var hasAny: Bool {
        onSetWatched != nil || personalItems != nil || onRemoveFromContinueWatching != nil
    }

    @ViewBuilder
    var body: some View {
        if let onSetWatched {
            Button {
                Task { @MainActor in
                    _ = await onSetWatched(!isWatched)
                }
            } label: {
                Label(
                    isWatched ? "Mark as Unwatched" : "Mark as Watched",
                    systemImage: isWatched ? "circle" : "checkmark.circle"
                )
            }
        }

        if let personalItems {
            personalItems
        }

        if let onRemoveFromContinueWatching {
            Button(role: .destructive) {
                onRemoveFromContinueWatching()
            } label: {
                Label("Remove from Continue Watching", systemImage: "xmark.circle")
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

    /// Same, for the full card menu: no menu at all when the card has no
    /// entries to offer, rather than an empty one.
    @ViewBuilder
    func cardContextMenu(_ items: CardContextMenuItems) -> some View {
        if items.hasAny {
            contextMenu { items }
        } else {
            self
        }
    }
}

/// The optimistic write / call / revert around `PersonalListSync` that every
/// card menu performs: flip the caller's override, snapshot the sibling flag,
/// and put the override back when the server call fails. The anti-clobber
/// merge itself lives once, in `PersonalListSync.writeBack`.
@MainActor
enum PersonalListToggles {
    /// - Parameters:
    ///   - write: applies the optimistic value to the caller's override.
    ///   - onCommit: called with the committed pair once the server agrees,
    ///     for callers that publish the new state upward.
    static func toggleFavorite(
        contentId: String,
        isFavorite: Bool,
        inWatchlist: Bool,
        write: @escaping @MainActor (Bool) -> Void,
        onCommit: (@MainActor (_ isFavorite: Bool, _ inWatchlist: Bool) -> Void)? = nil
    ) {
        let newValue = !isFavorite
        write(newValue)
        Task {
            if await PersonalListSync.setFavorite(
                contentId: contentId, isFavorite: newValue, inWatchlist: inWatchlist
            ) {
                onCommit?(newValue, inWatchlist)
            } else {
                write(isFavorite)
            }
        }
    }

    static func toggleWatchlist(
        contentId: String,
        isFavorite: Bool,
        inWatchlist: Bool,
        write: @escaping @MainActor (Bool) -> Void,
        onCommit: (@MainActor (_ isFavorite: Bool, _ inWatchlist: Bool) -> Void)? = nil
    ) {
        let newValue = !inWatchlist
        write(newValue)
        Task {
            if await PersonalListSync.setWatchlist(
                contentId: contentId, isFavorite: isFavorite, inWatchlist: newValue
            ) {
                onCommit?(isFavorite, newValue)
            } else {
                write(inWatchlist)
            }
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
    }
}
