import Observation

/// The favorite, watchlist and watched values a card shows after the viewer
/// changes one from the card's menu, and the one change it runs at a time.
///
/// A card's `userState` comes from a list its parent loaded earlier, and that
/// list does not refetch when a change lands. So a requested value stays after
/// the server applies it, until the card's `userState` changes (`reset`). Any
/// other outcome restores the value the card showed at the tap.
/// `PersonalStateOverrides` is the other shape: it drops the value when the
/// request ends, for hosts whose inputs already hold the confirmed state.
///
/// The server writes and the cache invalidation behind them stay in
/// `MediaCardWatchedSync` and `PersonalListSync`.
@Observable
@MainActor
final class MediaCardPersonalState {
    /// Where a card's watched change goes.
    enum WatchedWrite {
        /// The host page writes it and shows its own failure alert (Home).
        case host((Bool) async -> Bool)
        /// The catalog write. A `seriesId` also drops the series' cached state.
        case catalog(contentId: String, seriesId: String? = nil)
    }

    /// The server write behind each toggle.
    struct Writes {
        var watched: @MainActor (_ contentId: String, _ played: Bool, _ seriesId: String?) async -> PersonalStateOutcome
        var favorite: @MainActor (_ contentId: String, _ isFavorite: Bool, _ inWatchlist: Bool) async -> PersonalStateOutcome
        var watchlist: @MainActor (_ contentId: String, _ isFavorite: Bool, _ inWatchlist: Bool) async -> PersonalStateOutcome

        static var live: Writes {
            Writes(
                watched: { await MediaCardWatchedSync.setWatched(contentId: $0, played: $1, seriesId: $2) },
                favorite: { await PersonalListSync.setFavorite(contentId: $0, isFavorite: $1, inWatchlist: $2) },
                watchlist: { await PersonalListSync.setWatchlist(contentId: $0, isFavorite: $1, inWatchlist: $2) }
            )
        }
    }

    /// One change at a time; presents failed and held changes.
    let feedback = MediaActionFeedback()

    private var playedOverride: Bool?
    private var favoriteOverride: Bool?
    private var watchlistOverride: Bool?
    private let writes: Writes

    init(writes: Writes = .live) {
        self.writes = writes
    }

    func isPlayed(_ base: MediaItemUserState?) -> Bool {
        playedOverride ?? (base?.played == true)
    }

    func isFavorite(_ base: MediaItemUserState?) -> Bool {
        favoriteOverride ?? (base?.isFavorite == true)
    }

    func inWatchlist(_ base: MediaItemUserState?) -> Bool {
        watchlistOverride ?? (base?.inWatchlist == true)
    }

    /// The card's `userState` changed: show it instead of any earlier request.
    func reset() {
        playedOverride = nil
        favoriteOverride = nil
        watchlistOverride = nil
    }

    /// `base` is the card's `userState` at the tap. `onApplied` gets the
    /// item's state after the server applied the change.
    func toggleWatched(
        from base: MediaItemUserState?,
        via write: WatchedWrite,
        onApplied: ((MediaItemUserState) -> Void)? = nil
    ) {
        let played = !isPlayed(base)
        let reportsFailure: Bool
        switch write {
        case .host: reportsFailure = false
        case .catalog: reportsFailure = true
        }
        run(.watched, to: played, reportsFailure: reportsFailure) { [writes] in
            switch write {
            case .host(let setWatched):
                return await setWatched(played) ? .applied : .failed(nil)
            case .catalog(let contentId, let seriesId):
                return await writes.watched(contentId, played, seriesId)
            }
        } applied: {
            onApplied?(MediaItemUserState(
                played: played, isFavorite: self.isFavorite(base), inWatchlist: self.inWatchlist(base)
            ))
        }
    }

    func toggleFavorite(
        contentId: String,
        from base: MediaItemUserState?,
        onApplied: ((MediaItemUserState) -> Void)? = nil
    ) {
        let favorite = !isFavorite(base)
        let watchlist = inWatchlist(base)
        run(.favorite, to: favorite) { [writes] in
            await writes.favorite(contentId, favorite, watchlist)
        } applied: {
            onApplied?(MediaItemUserState(played: self.isPlayed(base), isFavorite: favorite, inWatchlist: watchlist))
        }
    }

    func toggleWatchlist(
        contentId: String,
        from base: MediaItemUserState?,
        onApplied: ((MediaItemUserState) -> Void)? = nil
    ) {
        let watchlist = !inWatchlist(base)
        let favorite = isFavorite(base)
        run(.watchlist, to: watchlist) { [writes] in
            await writes.watchlist(contentId, favorite, watchlist)
        } applied: {
            onApplied?(MediaItemUserState(played: self.isPlayed(base), isFavorite: favorite, inWatchlist: watchlist))
        }
    }

    /// Shows `value` while `write` runs. On `.applied` it stays and `applied`
    /// runs; any other outcome restores the override from before the tap.
    private func run(
        _ target: PersonalStateTarget,
        to value: Bool,
        reportsFailure: Bool = true,
        write: @escaping @MainActor () async -> PersonalStateOutcome,
        applied: @escaping @MainActor () -> Void
    ) {
        let previous = override(target)
        feedback.perform(reportsFailure: reportsFailure) {
            self.setOverride(target, value)
            let outcome = await write()
            if outcome == .applied {
                applied()
            } else {
                self.setOverride(target, previous)
            }
            return outcome
        }
    }

    private func override(_ target: PersonalStateTarget) -> Bool? {
        switch target {
        case .watched: playedOverride
        case .favorite: favoriteOverride
        case .watchlist: watchlistOverride
        }
    }

    private func setOverride(_ target: PersonalStateTarget, _ value: Bool?) {
        switch target {
        case .watched: playedOverride = value
        case .favorite: favoriteOverride = value
        case .watchlist: watchlistOverride = value
        }
    }
}
