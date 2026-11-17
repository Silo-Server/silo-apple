import Observation

/// The favorite, watchlist, watched and Not interested values a card shows after the viewer
/// changes one from the card's menu, and the one change it runs at a time.
///
/// A card's `userState` comes from a list its parent loaded earlier, and that
/// list does not refetch when a change lands. So a requested value stays after
/// the server applies it, until the card's `userState` changes (`reset`). Any
/// other outcome restores the value the card showed at the tap.
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
        var notInterested: @MainActor (_ contentId: String, _ marked: Bool) async -> PersonalStateOutcome = {
            await NotInterestedSync.set(contentId: $0, to: $1)
        }

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
    private var notInterestedOverride: Bool?
    private let writes: Writes

    init(writes: Writes = .live) {
        self.writes = writes
    }

    func isPlayed(_ base: MediaItemUserState?) -> Bool {
        playedOverride ?? (base?.played == true)
    }

    /// The episodes a started series or season has left, for the card's
    /// watch-status corner. A watched change made from this card leaves the
    /// loaded counts stale, so none shows until the card's `userState` changes.
    func episodesLeft(_ base: MediaItemUserState?) -> Int? {
        playedOverride == nil ? base?.episodesLeft : nil
    }

    func isFavorite(_ base: MediaItemUserState?) -> Bool {
        favoriteOverride ?? (base?.isFavorite == true)
    }

    func inWatchlist(_ base: MediaItemUserState?) -> Bool {
        watchlistOverride ?? (base?.inWatchlist == true)
    }

    func isNotInterested(_ base: MediaItemUserState?) -> Bool {
        notInterestedOverride ?? (base?.notInterested == true)
    }

    /// Whether the card can offer Not interested: a movie or series from a
    /// server that sends the mark.
    static func offersNotInterested(type: String?, _ base: MediaItemUserState?) -> Bool {
        base?.notInterested != nil && NotInterestedSync.canMark(type)
    }

    /// The card's `userState` changed: show it instead of any earlier request.
    func reset() {
        playedOverride = nil
        favoriteOverride = nil
        watchlistOverride = nil
        notInterestedOverride = nil
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
            onApplied?(self.state(from: base, played: played))
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
            onApplied?(self.state(from: base, isFavorite: favorite))
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
            onApplied?(self.state(from: base, inWatchlist: watchlist))
        }
    }

    func toggleNotInterested(
        contentId: String,
        from base: MediaItemUserState?,
        onApplied: ((MediaItemUserState) -> Void)? = nil
    ) {
        let marked = !isNotInterested(base)
        run(.notInterested, to: marked) { [writes] in
            await writes.notInterested(contentId, marked)
        } applied: {
            onApplied?(self.state(from: base, notInterested: marked))
        }
    }

    /// The item's state after a change: the card's effective flags with the
    /// changed one replaced. Episode counts are dropped; a watched change
    /// leaves them stale, and `episodesLeft` hides them meanwhile anyway.
    private func state(
        from base: MediaItemUserState?,
        played: Bool? = nil,
        isFavorite: Bool? = nil,
        inWatchlist: Bool? = nil,
        notInterested: Bool? = nil
    ) -> MediaItemUserState {
        MediaItemUserState(
            played: played ?? isPlayed(base),
            isFavorite: isFavorite ?? self.isFavorite(base),
            inWatchlist: inWatchlist ?? self.inWatchlist(base),
            notInterested: notInterested ?? base?.notInterested.map { _ in isNotInterested(base) }
        )
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
        case .notInterested: notInterestedOverride
        }
    }

    private func setOverride(_ target: PersonalStateTarget, _ value: Bool?) {
        switch target {
        case .watched: playedOverride = value
        case .favorite: favoriteOverride = value
        case .watchlist: watchlistOverride = value
        case .notInterested: notInterestedOverride = value
        }
    }
}
