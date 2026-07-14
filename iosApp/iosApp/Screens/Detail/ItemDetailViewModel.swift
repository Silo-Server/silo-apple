import Foundation

@Observable
@MainActor
class ItemDetailViewModel {
    var detail: ItemDetail?
    /// True only on a true cold load — no cached payload and no `detail`
    /// rendered yet. Subsequent refreshes paint the cached content and
    /// flip `isRefreshing` instead.
    var isLoading = false
    var isRefreshing = false
    var error: ErrorState?

    // Series-specific state
    var seasons: [Season] = []
    var selectedSeason: Season?
    var episodes: [EpisodeListItem] = []
    var episodeFavoriteStates: [String: Bool] = [:]
    var isLoadingEpisodes = false

    /// Protects local context-menu updates from older favorite lookups that
    /// finish after the user has already changed an episode's state.
    private var episodeFavoriteMutationVersions: [String: Int] = [:]
    private var episodeFavoriteRefreshGeneration = 0

    // User actions
    var isFavorite = false
    var inWatchlist = false
    var isWatched = false

    // tvOS pre-play selector state. ItemDetailCache retains this view model
    // while the user enters playback or navigates to another item, so manual
    // Version / Audio / Subtitle picks survive those round trips instead of
    // being reset every time the detail task restarts.
    var preferredVersionFileId: Int?
    var preferredAudioTrackIndex: Int?
    var preferredSubtitleTrackIndex: Int?
    var preferredNextUpFileId: Int?
    var preferredNextUpAudioTrackIndex: Int?
    var preferredNextUpSubtitleTrackIndex: Int?

    // Track the series contentId for season/episode loading
    private var seriesContentId: String?

    func loadDetail(contentId: String) async {
        // Stage 1 — hydrate from cache synchronously so the view paints
        // the last-known detail immediately. Anything missing (e.g.
        // first-ever visit) leaves the corresponding fields nil and the
        // view falls back to its skeleton.
        hydrateFromCache(contentId: contentId)

        if detail == nil {
            isLoading = true
        } else {
            isRefreshing = true
        }
        error = nil

        do {
            let item: ItemDetail = try await ContinuumAPI.shared.get(
                "/api/v1/catalog/items/\(contentId)"
            )
            let enriched = await enrichPlaybackMetadata(for: item, contentId: contentId)
            detail = enriched
            ResponseCache.shared.set(enriched, for: CacheKey.itemDetail(contentId))

            do {
                async let favorite = ContinuumAPI.shared.isFavorite(contentId: contentId)
                async let watchlist = ContinuumAPI.shared.isInWatchlist(contentId: contentId)
                let fav = try await favorite
                let wl = try await watchlist
                isFavorite = fav
                inWatchlist = wl
                ResponseCache.shared.set(
                    UserItemState(isFavorite: fav, inWatchlist: wl),
                    for: CacheKey.itemUserState(contentId)
                )
            } catch {
                // Leave whatever we hydrated from cache; per-item user
                // state is non-fatal.
            }

            isWatched = enriched.userData?.played ?? false

            // For series, load seasons (which auto-selects the first season
            // and fetches its episodes). For a standalone season page, skip
            // the season list and fetch episodes directly for this season.
            if enriched.type == "series" {
                seriesContentId = contentId
                await loadSeasons(seriesId: contentId)
            } else if enriched.type == "season",
                      let seriesId = enriched.seriesId,
                      let seasonNumber = enriched.seasonNumber {
                seriesContentId = seriesId
                await loadEpisodes(seriesId: seriesId, seasonNumber: seasonNumber)
                await loadSeasons(seriesId: seriesId, autoSelectInitial: false)
                selectedSeason = seasons.first(where: { $0.seasonNumber == seasonNumber })
            } else if enriched.type == "episode",
                      let seriesId = enriched.seriesId,
                      let seasonNumber = enriched.seasonNumber {
                // Load the siblings for this episode's season so the
                // detail page can render the horizontal episode rail with
                // the current episode highlighted + scrolled into view.
                seriesContentId = seriesId
                await loadEpisodes(seriesId: seriesId, seasonNumber: seasonNumber)
                await loadSeasons(seriesId: seriesId, autoSelectInitial: false)
                selectedSeason = seasons.first(where: { $0.seasonNumber == seasonNumber })
            }
        } catch let err {
            if detail == nil {
                self.error = ErrorState(err)
            }
        }
        isLoading = false
        isRefreshing = false
    }

    /// Paint every cached fragment the screen knows how to render so a
    /// returning visit never starts from a blank state.
    private func hydrateFromCache(contentId: String) {
        if detail == nil,
           let cached: ItemDetail = ResponseCache.shared.get(CacheKey.itemDetail(contentId)) {
            detail = cached
            isWatched = cached.userData?.played ?? false

            if cached.type == "series" {
                seriesContentId = contentId
            } else if cached.type == "season" || cached.type == "episode",
                      let seriesId = cached.seriesId {
                seriesContentId = seriesId
            }
        }
        if let state: UserItemState = ResponseCache.shared.get(CacheKey.itemUserState(contentId)) {
            isFavorite = state.isFavorite
            inWatchlist = state.inWatchlist
        }
        if let seriesId = seriesContentId,
           seasons.isEmpty,
           let cached: SeasonsResponse = ResponseCache.shared.get(CacheKey.itemSeasons(seriesId)) {
            seasons = cached.seasons.sortedForDisplay()
            if let detail, detail.type != "series", let seasonNumber = detail.seasonNumber {
                selectedSeason = seasons.first(where: { $0.seasonNumber == seasonNumber })
            }
        }
        if let seriesId = seriesContentId,
           let detail,
           detail.type != "series",
           let seasonNumber = detail.seasonNumber,
           episodes.isEmpty,
           let cached: EpisodesResponse = ResponseCache.shared.get(
               CacheKey.itemEpisodes(seriesId: seriesId, seasonNumber: seasonNumber)
           ) {
            episodes = cached.episodes.sorted(by: { $0.episodeNumber < $1.episodeNumber })
        }
    }

    private func enrichPlaybackMetadata(for item: ItemDetail, contentId: String) async -> ItemDetail {
        // Series and season containers have no single watch target — `/watch/{id}`
        // returns 404 "Watch target not found" for them. Only enrich playable
        // leaf items, rather than firing a request we know will fail.
        guard item.type != "series", item.type != "season" else { return item }

        do {
            let watchDetail = try await ContinuumAPI.shared.watchDetail(contentId: contentId)
            ResponseCache.shared.set(watchDetail, for: CacheKey.itemWatchDetail(contentId))
            return ItemDetail(
                contentId: item.contentId,
                type: item.type,
                status: item.status,
                title: item.title,
                sortTitle: item.sortTitle,
                originalTitle: item.originalTitle,
                originalLanguage: item.originalLanguage,
                showStatus: item.showStatus,
                year: item.year,
                overview: item.overview,
                tagline: item.tagline,
                runtime: item.runtime,
                contentRating: item.contentRating,
                genres: item.genres,
                ratingImdb: item.ratingImdb,
                ratingTmdb: item.ratingTmdb,
                ratingRtCritic: item.ratingRtCritic,
                ratingRtAudience: item.ratingRtAudience,
                imdbId: item.imdbId,
                tmdbId: item.tmdbId,
                tvdbId: item.tvdbId,
                cast: item.cast,
                crew: item.crew,
                studios: item.studios,
                networks: item.networks,
                countries: item.countries,
                releaseDate: item.releaseDate,
                firstAirDate: item.firstAirDate,
                lastAirDate: item.lastAirDate,
                posterUrl: item.posterUrl,
                posterThumbhash: item.posterThumbhash,
                backdropUrl: item.backdropUrl,
                backdropThumbhash: item.backdropThumbhash,
                logoUrl: item.logoUrl,
                seasonCount: item.seasonCount,
                seriesId: item.seriesId,
                seriesTitle: item.seriesTitle,
                seasonNumber: item.seasonNumber,
                episodeNumber: item.episodeNumber,
                episodeCount: item.episodeCount,
                airDate: item.airDate,
                isSpecials: item.isSpecials,
                userData: item.userData,
                versions: watchDetail.versions,
                subtitles: watchDetail.subtitles,
                intro: watchDetail.intro,
                credits: watchDetail.credits,
                effectiveSubtitleMode: watchDetail.effectiveSubtitleMode,
                effectiveShowForcedSubtitles: watchDetail.effectiveShowForcedSubtitles,
                effectiveSubtitleTrackSignature: watchDetail.effectiveSubtitleTrackSignature,
                overlaySummary: item.overlaySummary,
                audiobook: item.audiobook,
                pendingTranslationLanguage: item.pendingTranslationLanguage
            )
        } catch {
            return item
        }
    }

    // MARK: - Seasons

    func loadSeasons(seriesId: String, autoSelectInitial: Bool = true) async {
        do {
            let response: SeasonsResponse = try await ContinuumAPI.shared.get(
                "/api/v1/catalog/series/\(seriesId)/seasons"
            )
            ResponseCache.shared.set(response, for: CacheKey.itemSeasons(seriesId))
            seasons = response.seasons.sortedForDisplay()
            if autoSelectInitial, let target = preferredInitialSeason(seasons: seasons) {
                await selectSeason(target)
            }
        } catch {
            // Seasons loading failure is non-fatal — keep whatever
            // hydrated from cache.
        }
    }

    /// Pick the season we should auto-land on when a user opens a series:
    /// prefer one with an episode in progress (Continue Watching state),
    /// then the first partially-watched season, then the first season that
    /// isn't fully played, then fall back to the first season.
    private func preferredInitialSeason(seasons: [Season]) -> Season? {
        if let inProgress = seasons.first(where: { ($0.userData?.inProgressCount ?? 0) > 0 }) {
            return inProgress
        }
        if let partial = seasons.first(where: {
            guard let ud = $0.userData else { return false }
            let watched = ud.watchedCount ?? 0
            return watched > 0 && watched < $0.episodeCount
        }) {
            return partial
        }
        if let firstUnplayed = seasons.first(where: { !($0.userData?.played ?? false) }) {
            return firstUnplayed
        }
        return seasons.first
    }

    func selectSeason(_ season: Season) async {
        selectedSeason = season
        guard let seriesId = seriesContentId else { return }
        await loadEpisodes(seriesId: seriesId, seasonNumber: season.seasonNumber)
    }

    func loadEpisodes(
        seriesId: String,
        seasonNumber: Int,
        refreshFavoriteStates: Bool = true
    ) async {
        let key = CacheKey.itemEpisodes(seriesId: seriesId, seasonNumber: seasonNumber)
        // Hydrate from cache so the rail paints immediately, then
        // refresh silently in the background.
        if episodes.isEmpty,
           let cached: EpisodesResponse = ResponseCache.shared.get(key) {
            episodes = cached.episodes.sorted(by: { $0.episodeNumber < $1.episodeNumber })
        }
        if episodes.isEmpty {
            isLoadingEpisodes = true
        }
        do {
            let response: EpisodesResponse = try await ContinuumAPI.shared.get(
                "/api/v1/catalog/series/\(seriesId)/seasons/\(seasonNumber)/episodes"
            )
            ResponseCache.shared.set(response, for: key)
            episodes = response.episodes.sorted(by: { $0.episodeNumber < $1.episodeNumber })
        } catch {
            // Episode loading failure is non-fatal — keep whatever
            // we hydrated from cache.
        }
        isLoadingEpisodes = false
        if refreshFavoriteStates {
            await refreshEpisodeFavoriteStates(for: episodes)
        }
    }

    private func refreshEpisodeFavoriteStates(
        for episodes: [EpisodeListItem],
        maxConcurrent: Int = 6
    ) async {
        episodeFavoriteRefreshGeneration += 1
        let generation = episodeFavoriteRefreshGeneration
        let mutationVersionsAtStart = episodeFavoriteMutationVersions
        var states: [String: Bool] = [:]

        // Query in small batches so a long season cannot fan out an
        // unbounded number of requests against the server.
        for batchStart in stride(from: 0, to: episodes.count, by: maxConcurrent) {
            let batchEnd = min(batchStart + maxConcurrent, episodes.count)
            let batch = Array(episodes[batchStart..<batchEnd])
            let batchStates = await withTaskGroup(of: (String, Bool?).self) { group in
                for episode in batch {
                    group.addTask {
                        let isFavorite = try? await ContinuumAPI.shared.isFavorite(
                            contentId: episode.contentId
                        )
                        return (episode.contentId, isFavorite)
                    }
                }

                var results: [String: Bool] = [:]
                for await (contentId, isFavorite) in group {
                    if let isFavorite {
                        results[contentId] = isFavorite
                    }
                }
                return results
            }
            states.merge(batchStates) { _, refreshed in refreshed }
        }

        let currentIds = Set(self.episodes.map(\.contentId))
        guard generation == episodeFavoriteRefreshGeneration,
              currentIds == Set(episodes.map(\.contentId)) else { return }

        var mergedStates = episodeFavoriteStates.filter { currentIds.contains($0.key) }
        for (contentId, isFavorite) in states {
            guard episodeFavoriteMutationVersions[contentId]
                    == mutationVersionsAtStart[contentId] else { continue }
            mergedStates[contentId] = isFavorite
        }
        episodeFavoriteStates = mergedStates
    }

    // MARK: - User Actions

    func toggleFavorite() async {
        guard let contentId = detail?.contentId else { return }
        isFavorite.toggle()
        writeBackUserState(contentId: contentId)
        do {
            if isFavorite {
                try await ContinuumAPI.shared.putVoid("/api/v1/favorites/\(contentId)")
            } else {
                try await ContinuumAPI.shared.delete("/api/v1/favorites/\(contentId)")
            }
            invalidateRelatedCaches(contentId: contentId)
        } catch {
            isFavorite.toggle() // Revert on failure
            writeBackUserState(contentId: contentId)
        }
    }

    func toggleWatchlist() async {
        guard let contentId = detail?.contentId else { return }
        inWatchlist.toggle()
        writeBackUserState(contentId: contentId)
        do {
            if inWatchlist {
                try await ContinuumAPI.shared.putVoid("/api/v1/watchlist/\(contentId)")
            } else {
                try await ContinuumAPI.shared.delete("/api/v1/watchlist/\(contentId)")
            }
            invalidateRelatedCaches(contentId: contentId)
        } catch {
            inWatchlist.toggle() // Revert on failure
            writeBackUserState(contentId: contentId)
        }
    }

    /// Mark the detail item (and, for series/seasons, its leaf episodes)
    /// as watched or unwatched. Backed by POST / DELETE
    /// `/api/v1/watched/{contentId}` — the server resolves the targets.
    func toggleWatched() async {
        guard let contentId = detail?.contentId else { return }
        isWatched.toggle()
        do {
            if isWatched {
                try await ContinuumAPI.shared.postVoid("/api/v1/watched/\(contentId)")
            } else {
                try await ContinuumAPI.shared.delete("/api/v1/watched/\(contentId)")
            }
            invalidateRelatedCaches(contentId: contentId)
        } catch {
            isWatched.toggle() // Revert on failure
        }
    }

    func setEpisodeWatched(contentId: String, played: Bool) async -> Bool {
        do {
            try await ContinuumAPI.shared.setWatched(contentId: contentId, played: played)
            if contentId == detail?.contentId {
                isWatched = played
            }
            invalidateRelatedCaches(
                contentId: contentId,
                seriesId: seriesContentId,
                seasonNumber: selectedSeason?.seasonNumber
            )
            if let seriesId = seriesContentId, let seasonNumber = selectedSeason?.seasonNumber {
                await loadEpisodes(
                    seriesId: seriesId,
                    seasonNumber: seasonNumber,
                    refreshFavoriteStates: false
                )
            }
            return true
        } catch {
            return false
        }
    }

    func setEpisodeFavorite(contentId: String, isFavorite: Bool) async -> Bool {
        do {
            try await ContinuumAPI.shared.toggleFavorite(contentId: contentId, isFavorite: isFavorite)
            if contentId == detail?.contentId {
                self.isFavorite = isFavorite
                writeBackUserState(contentId: contentId)
            }
            episodeFavoriteMutationVersions[contentId, default: 0] += 1
            episodeFavoriteStates[contentId] = isFavorite
            invalidateRelatedCaches(contentId: contentId)
            return true
        } catch {
            return false
        }
    }

    private func writeBackUserState(contentId: String) {
        ResponseCache.shared.set(
            UserItemState(isFavorite: isFavorite, inWatchlist: inWatchlist),
            for: CacheKey.itemUserState(contentId)
        )
    }

    /// Tell adjacent caches that a mutation invalidated derived state
    /// (e.g. parent series progress when a child episode is marked
    /// watched). Drops the cached payloads so the next visit fetches
    /// fresh — painted content keeps showing in the meantime via the
    /// existing `detail` binding.
    private func invalidateRelatedCaches(
        contentId: String,
        seriesId: String? = nil,
        seasonNumber: Int? = nil
    ) {
        ResponseCache.shared.remove(CacheKey.itemDetail(contentId))
        if let seriesId = seriesId ?? detail?.seriesId {
            ResponseCache.shared.remove(CacheKey.itemDetail(seriesId))
            ResponseCache.shared.remove(CacheKey.itemSeasons(seriesId))
            if let seasonNumber = seasonNumber ?? detail?.seasonNumber {
                ResponseCache.shared.remove(
                    CacheKey.itemEpisodes(seriesId: seriesId, seasonNumber: seasonNumber)
                )
            }
        }
        // Home + recommendations watch-progress rows are now stale too.
        ResponseCache.shared.remove(CacheKey.homeSections)
        ResponseCache.shared.remove(CacheKey.recommendations)
        ResponseCache.shared.remove(CacheKey.favorites)
        ResponseCache.shared.remove(CacheKey.watchlist)
        ResponseCache.shared.remove(CacheKey.history)

        #if os(tvOS)
        ItemDetailCache.shared.markStaleFamily(contentId: contentId)
        #endif
    }
}

/// User-state pair cached alongside an item detail so a returning view
/// renders the correct favorite / watchlist buttons without waiting for
/// the two `isFavorite` / `isInWatchlist` round-trips.
struct UserItemState {
    let isFavorite: Bool
    let inWatchlist: Bool
}
