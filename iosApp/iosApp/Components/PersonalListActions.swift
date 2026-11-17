import Foundation

/// Server sync behind the card context-menu toggles, dispatched through
/// `PersonalStateSync` under the owner current at the tap. Mirrors
/// `ItemDetailViewModel.toggleFavorite/toggleWatchlist`: on success it
/// writes back the cached per-item user-state pair (so a subsequent
/// detail visit renders the right buttons immediately) and drops the
/// derived list caches so Favorites / Watchlist / Home refetch fresh.
@MainActor
enum PersonalListSync {
    /// Anything but `.applied` means nothing was written locally and the
    /// caller reverts its optimistic UI state. The sibling flag is only a
    /// write-back fallback; a fresher cached value for it wins (see `writeBack`).
    static func setFavorite(contentId: String, isFavorite: Bool, inWatchlist: Bool) async -> PersonalStateOutcome {
        let outcome = await PersonalStateSync.outcome {
            try await PersonalStateSync.set(.favorite, contentId: contentId, to: isFavorite)
        }
        if outcome == .applied {
            writeBack(contentId: contentId, isFavorite: isFavorite, fallbackInWatchlist: inWatchlist)
        }
        return outcome
    }

    static func setWatchlist(contentId: String, isFavorite: Bool, inWatchlist: Bool) async -> PersonalStateOutcome {
        let outcome = await PersonalStateSync.outcome {
            try await PersonalStateSync.set(.watchlist, contentId: contentId, to: inWatchlist)
        }
        if outcome == .applied {
            writeBack(contentId: contentId, inWatchlist: inWatchlist, fallbackIsFavorite: isFavorite)
        }
        return outcome
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
        PersonalStateSync.invalidateDerivedLists()
    }
}

/// Server sync behind Not interested, from a card menu or a detail page.
@MainActor
enum NotInterestedSync {
    /// Only movies and series take the mark; a series mark covers its episodes.
    static func canMark(_ type: String?) -> Bool {
        guard let type else { return false }
        return SiloMediaType.isMovieLibrary(type) || SiloMediaType.isSeries(type)
    }

    /// Anything but `.applied` means nothing changed locally. A new mark tells
    /// a mounted Home to drop the card from its recommendation rows at once;
    /// the refetch that follows already leaves it out.
    static func set(contentId: String, to marked: Bool) async -> PersonalStateOutcome {
        let outcome = await PersonalStateSync.outcome {
            try await PersonalStateSync.set(.notInterested, contentId: contentId, to: marked)
        }
        if outcome == .applied {
            applied(contentId: contentId, marked: marked)
        }
        return outcome
    }

    /// Local follow-up to a mark or clear the server applied.
    static func applied(contentId: String, marked: Bool) {
        if marked {
            NotificationCenter.default.post(
                name: .titleMarkedNotInterested, object: nil, userInfo: [contentIdKey: contentId]
            )
        }
        PersonalStateSync.invalidateItemState(contentId: contentId)
    }

    static let contentIdKey = "contentId"
}

extension Notification.Name {
    /// Posted on the main actor after the server applied a Not interested
    /// mark; `userInfo[NotInterestedSync.contentIdKey]` holds the title.
    static let titleMarkedNotInterested = Notification.Name("titleMarkedNotInterested")
}
