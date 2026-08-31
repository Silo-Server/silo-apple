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
    /// Parent-series portrait artwork used only when an episode's season has
    /// no poster of its own. Episode artwork is normally a landscape still,
    /// so it must not be stretched into the iPad hero's portrait slot.
    var episodeSeriesPosterUrl: String?
    var episodeSeriesPosterThumbhash: String?
    /// Route-scoped pages already loaded while browsing seasons. This keeps
    /// chip taps and iPad page swipes instant when the user comes back to a
    /// season, while `ResponseCache` remains the longer-lived cold-start tier.
    var episodesBySeason: [Int: [EpisodeListItem]] = [:]
    var episodeFavoriteStates: [String: Bool] = [:]
    var isLoadingEpisodes = false

    /// Protects local context-menu updates from older favorite lookups that
    /// finish after the user has already changed an episode's state.
    private var episodeFavoriteMutationVersions: [String: Int] = [:]
    private var episodeFavoriteRefreshGeneration = 0
    /// Cancels publication from an older season request after the user has
    /// already moved to another page.
    private var episodeLoadGeneration = 0
    /// Season whose episodes are actually painted. Used to roll back an
    /// optimistic chip/page selection if its request fails.
    private var loadedSeasonNumber: Int?

    /// Bumped by every writer of `detail` + `CacheKey.itemDetail`, so a load
    /// that started earlier but finishes later cannot publish over a newer
    /// payload. Same idiom as `BrowseViewModel` / `TVLibraryGridViewModel`.
    ///
    /// The race this closes: an entry `loadDetail` on a cache hit fetches the
    /// pre-refresh catalog payload and then suspends inside
    /// ``enrichPlaybackMetadata(for:contentId:)`` (a whole `/watch` round
    /// trip); the trailer poll publishes its newer, trailers-bearing payload
    /// meanwhile; the older load resumes and overwrites `detail` and the
    /// cache with the trailer-less item — the run reports `.found` and no
    /// rail appears.
    private var detailGeneration = 0

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
    /// Distinguishes a selector choice from a server-derived launch seed so
    /// enabling device caption settings can discard only the latter.
    var preferredSubtitleTrackWasManuallySelected = false
    var preferredNextUpFileId: Int?
    var preferredNextUpAudioTrackIndex: Int?
    var preferredNextUpSubtitleTrackIndex: Int?

    // Track the series contentId for season/episode loading
    private var seriesContentId: String?

    /// - Parameter preserveSeasonSelection: keep the season the user is
    ///   currently browsing instead of re-running the auto-select. Set by
    ///   background reloads that happen *while* the page is on screen (the
    ///   trailer fetch's found-path), where snapping the episode rail back to
    ///   the preferred initial season would yank the ground out from under
    ///   the user — under focus, on tvOS. Entry loads and the player-dismiss
    ///   reload leave it false: there, re-picking the season is the point.
    func loadDetail(contentId: String, preserveSeasonSelection: Bool = false) async {
        if detail?.contentId != contentId {
            episodeSeriesPosterUrl = nil
            episodeSeriesPosterThumbhash = nil
        }

        // Stage 1 — hydrate from cache synchronously so the view paints
        // the last-known detail immediately. Anything missing (e.g.
        // first-ever visit) leaves the corresponding fields nil and the
        // view falls back to its skeleton.
        hydrateFromCache(contentId: contentId)

        // Claimed before the fetch, so "newer" means "started later" — a
        // trailer-found adopt that begins while this request is in flight
        // supersedes it even though it publishes first.
        let generation = beginDetailWrite()

        if detail == nil {
            isLoading = true
        } else {
            isRefreshing = true
        }
        error = nil
        defer {
            isLoading = false
            isRefreshing = false
        }

        do {
            let item: ItemDetail = try await ContinuumAPI.shared.get(
                "/api/v1/catalog/items/\(contentId)"
            )
            let enriched = await adoptDetail(item, contentId: contentId, generation: generation)

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
                // state is non-fatal. Independent of the detail payload, so
                // it still applies to a superseded load.
            }

            // Superseded: a newer payload is already on screen. Deriving
            // watched state or the season/episode structure from this older
            // copy would undo parts of it (and re-run the season auto-select
            // under the user).
            guard let enriched else { return }

            isWatched = enriched.userData?.played ?? false

            await loadRelatedStructure(
                for: enriched,
                contentId: contentId,
                preserveSeasonSelection: preserveSeasonSelection
            )
        } catch let err {
            if detail == nil {
                self.error = ErrorState(err)
            }
        }
    }

    /// Claim the right to publish into `detail`, invalidating any write that
    /// claimed earlier and hasn't landed yet.
    private func beginDetailWrite() -> Int {
        detailGeneration += 1
        return detailGeneration
    }

    /// Publish a payload the caller re-fetched itself, taking the generation
    /// with it so an in-flight load can't land its older copy afterwards.
    /// Used by the description translator, which polls the catalog directly
    /// and (deliberately) skips playback enrichment.
    func publishRefetchedDetail(_ item: ItemDetail, contentId: String) {
        _ = beginDetailWrite()
        detail = item
        ResponseCache.shared.set(item, for: CacheKey.itemDetail(contentId))
    }

    /// Enrich, publish, and cache a freshly fetched detail payload. The one
    /// place `detail` and `CacheKey.itemDetail` are written together, so any
    /// caller that obtains an `ItemDetail` lands it identically.
    ///
    /// Returns `nil` — publishing nothing — when a newer write claimed the
    /// slot while this one was suspended in enrichment (a full `/watch`
    /// round trip, which is where the window is widest).
    private func adoptDetail(
        _ item: ItemDetail,
        contentId: String,
        generation: Int
    ) async -> ItemDetail? {
        let enriched = await enrichPlaybackMetadata(for: item, contentId: contentId)
        guard generation == detailGeneration else { return nil }
        detail = enriched
        ResponseCache.shared.set(enriched, for: CacheKey.itemDetail(contentId))
        return enriched
    }

    /// Load the season / episode structure a detail payload implies.
    ///
    /// For series, load seasons (which auto-selects the first season and
    /// fetches its episodes). For a standalone season page, skip the season
    /// list and fetch episodes directly for this season.
    private func loadRelatedStructure(
        for enriched: ItemDetail,
        contentId: String,
        preserveSeasonSelection: Bool
    ) async {
        if enriched.type == "series" {
            seriesContentId = contentId
            let keepSeason = preserveSeasonSelection ? selectedSeason?.seasonNumber : nil
            await loadSeasons(seriesId: contentId, autoSelectInitial: keepSeason == nil)
            if let keepSeason {
                // Re-point at the freshly-loaded instance of the same
                // season so its progress counters are current, without
                // re-fetching the episode rail the user is looking at.
                selectedSeason = seasons.first(where: { $0.seasonNumber == keepSeason })
                    ?? selectedSeason
            }
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
            async let episodeLoad: Void = loadEpisodes(
                seriesId: seriesId,
                seasonNumber: seasonNumber
            )
            await loadSeasons(seriesId: seriesId, autoSelectInitial: false)
            selectedSeason = seasons.first(where: { $0.seasonNumber == seasonNumber })
            // Resolve the season first so its more-specific poster paints
            // immediately. The series detail is an optional fallback only.
            await loadEpisodeSeriesArtwork(seriesId: seriesId)
            await episodeLoad
        }
    }

    private func loadEpisodeSeriesArtwork(seriesId: String) async {
        let seriesDetail: ItemDetail
        if let cached: ItemDetail = ResponseCache.shared.get(CacheKey.itemDetail(seriesId)) {
            seriesDetail = cached
        } else {
            do {
                seriesDetail = try await ContinuumAPI.shared.itemDetail(contentId: seriesId)
                ResponseCache.shared.set(seriesDetail, for: CacheKey.itemDetail(seriesId))
            } catch {
                return
            }
        }

        guard detail?.type == "episode", detail?.seriesId == seriesId else { return }
        episodeSeriesPosterUrl = seriesDetail.posterUrl
        episodeSeriesPosterThumbhash = seriesDetail.posterThumbhash
    }

    /// Adopt a detail payload the caller already has in hand, taking the
    /// same path a `loadDetail` response would — enrichment, cache write,
    /// watched flag, season/episode structure — minus the catalog fetch that
    /// produced it and the favorite/watchlist round trips, which nothing
    /// about a background refresh invalidates.
    ///
    /// Enrichment failing is not fatal here: it returns the payload
    /// untouched, so the new trailers still render.
    ///
    /// Claiming a generation is what stops an entry `loadDetail` that is
    /// still suspended in enrichment from landing its older, trailer-less
    /// payload on top of this one afterwards.
    private func apply(
        item: ItemDetail,
        contentId: String,
        preserveSeasonSelection: Bool
    ) async {
        let generation = beginDetailWrite()
        guard let enriched = await adoptDetail(
            item,
            contentId: contentId,
            generation: generation
        ) else { return }
        isWatched = enriched.userData?.played ?? false
        await loadRelatedStructure(
            for: enriched,
            contentId: contentId,
            preserveSeasonSelection: preserveSeasonSelection
        )
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
            let sorted = cached.episodes.sorted(by: { $0.episodeNumber < $1.episodeNumber })
            episodes = sorted
            episodesBySeason[seasonNumber] = sorted
            loadedSeasonNumber = seasonNumber
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
                pendingTranslationLanguage: item.pendingTranslationLanguage,
                // Catalog-only fields: the watch detail knows nothing about
                // them, so they must be carried across or the trailers rail
                // would disappear the moment enrichment succeeds.
                videos: item.videos,
                extras: item.extras
            )
        } catch {
            return item
        }
    }

    // MARK: - Trailer fetch

    /// Manual "Find Trailers" driver, created on first use and wired to the
    /// live API plus this view model's own reload. Lazy because most detail
    /// visits never invoke the action.
    ///
    /// `@ObservationIgnored` because the UI binds to the coordinator's own
    /// `@Observable` phase, not through this view model — and because the
    /// accessor below writes the slot on first read, which must not count as
    /// a state mutation during a view update.
    @ObservationIgnored
    private var trailerFetchStorage: TrailerFetchCoordinator?

    /// The item the in-flight run started on. Pins the whole run to one id:
    /// the closures below resolve `detail?.contentId` when they run, so
    /// without this a view model reused for another item mid-poll (tvOS
    /// keeps them cached) would poll the *new* item against the *old*
    /// item's baseline counts and could report a false "found".
    @ObservationIgnored
    private var trailerFetchContentId: String?

    var trailerFetch: TrailerFetchCoordinator {
        if let trailerFetchStorage { return trailerFetchStorage }
        // The closures resolve `contentId` when they run rather than
        // capturing it here, so a view model that gets reused for another
        // item can never address the old one — and the pin makes them fail
        // outright rather than quietly switch items mid-run.
        let coordinator = TrailerFetchCoordinator(
            request: { [weak self] in
                let contentId = try self?.pinnedTrailerFetchContentId()
                guard let contentId else { throw ItemDetailViewModelError.noItemLoaded }
                return try await ContinuumAPI.shared.requestTrailersRefresh(contentId: contentId)
            },
            fetchDetail: { [weak self] in
                let contentId = try self?.pinnedTrailerFetchContentId()
                guard let contentId else { throw ItemDetailViewModelError.noItemLoaded }
                return try await ContinuumAPI.shared.itemDetail(contentId: contentId)
            }
        )
        trailerFetchStorage = coordinator
        return coordinator
    }

    /// The loaded item's id, but only while it is still the item the trailer
    /// run started on. Throws otherwise, which the coordinator treats as a
    /// transient failure (the poll keeps its baseline and settles out).
    private func pinnedTrailerFetchContentId() throws -> String {
        guard let contentId = detail?.contentId,
              contentId == trailerFetchContentId else {
            throw ItemDetailViewModelError.noItemLoaded
        }
        return contentId
    }

    /// Whether the "Find Trailers" action applies to what's on screen. The
    /// server only ever populates videos for movies and series.
    var supportsTrailerFetch: Bool {
        detail?.type == "movie" || detail?.type == "series"
    }

    /// - Parameter remoteVideosDisplayable: false when the caller's rail
    ///   cannot render remote (YouTube) cards — tvOS with no YouTube app
    ///   installed. iOS and macOS always can, so they leave it at true.
    func startTrailerFetch(remoteVideosDisplayable: Bool = true) {
        guard let contentId = detail?.contentId, supportsTrailerFetch else { return }
        trailerFetchContentId = contentId
        trailerFetch.start(
            baseline: detail,
            remoteVideosDisplayable: remoteVideosDisplayable
        ) { [weak self] found in
            guard let self else { return }
            // Apply the payload the coordinator already observed the trailers
            // in, rather than fetching the same item a second time: a
            // transient failure there would leave the page on the old detail
            // even though the run has reported success. This lands while the
            // page is on screen, so the season the user is browsing must
            // survive it.
            guard found.contentId == contentId else {
                // Shouldn't happen (the run is pinned to one id), but a
                // mismatched payload must never be written under this id.
                await self.loadDetail(contentId: contentId, preserveSeasonSelection: true)
                return
            }
            await self.apply(
                item: found,
                contentId: contentId,
                preserveSeasonSelection: true
            )
        }
    }

    /// Stop the poll when the page leaves the nav stack: the coordinator's
    /// task is not owned by SwiftUI's `.task` lifetime and would otherwise
    /// keep this view model alive and mutating.
    func stopTrailerFetch() {
        trailerFetchStorage?.stop()
    }

    /// Pick the poll back up when the page returns — e.g. the user played
    /// the movie mid-fetch, which cancelled it. No-op unless a poll was
    /// actually interrupted, and never re-POSTs (the slot is already spent).
    /// Lazily-created on purpose: a page that never ran a fetch has no
    /// coordinator and needs none.
    func resumeTrailerFetchIfNeeded() {
        trailerFetchStorage?.resumeIfInterrupted()
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
                await selectSeason(target, forceRefresh: true)
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

    func selectSeason(_ season: Season, forceRefresh: Bool = false) async {
        let fallbackSeasonNumber = loadedSeasonNumber ?? selectedSeason?.seasonNumber
        selectedSeason = season
        guard let seriesId = seriesContentId else { return }

        if !forceRefresh, let cached = episodesBySeason[season.seasonNumber] {
            // Invalidate any older in-flight request before publishing the
            // cached page. Otherwise it could finish later and replace this
            // selection with stale content.
            episodeLoadGeneration += 1
            episodes = cached
            loadedSeasonNumber = season.seasonNumber
            isLoadingEpisodes = false
            return
        }

        await loadEpisodes(
            seriesId: seriesId,
            seasonNumber: season.seasonNumber,
            fallbackSeasonNumber: fallbackSeasonNumber
        )
    }

    func loadEpisodes(
        seriesId: String,
        seasonNumber: Int,
        refreshFavoriteStates: Bool = true,
        fallbackSeasonNumber: Int? = nil
    ) async {
        episodeLoadGeneration += 1
        let generation = episodeLoadGeneration
        let key = CacheKey.itemEpisodes(seriesId: seriesId, seasonNumber: seasonNumber)

        // Hydrate this page from either route memory or ResponseCache, then
        // refresh silently. Never leave the previous season's rows under a
        // newly-selected chip.
        var cachedEpisodes = episodesBySeason[seasonNumber]
        if cachedEpisodes == nil,
           let cached: EpisodesResponse = ResponseCache.shared.get(key) {
            let sorted = cached.episodes.sorted(by: { $0.episodeNumber < $1.episodeNumber })
            episodesBySeason[seasonNumber] = sorted
            cachedEpisodes = sorted
        }

        let shouldPublish = selectedSeason == nil || selectedSeason?.seasonNumber == seasonNumber
        if shouldPublish, let cachedEpisodes {
            episodes = cachedEpisodes
            loadedSeasonNumber = seasonNumber
        } else if shouldPublish {
            episodes = []
            isLoadingEpisodes = true
        }

        do {
            let response: EpisodesResponse = try await ContinuumAPI.shared.get(
                "/api/v1/catalog/series/\(seriesId)/seasons/\(seasonNumber)/episodes"
            )
            ResponseCache.shared.set(response, for: key)
            let sorted = response.episodes.sorted(by: { $0.episodeNumber < $1.episodeNumber })
            guard generation == episodeLoadGeneration else { return }
            episodesBySeason[seasonNumber] = sorted
            if selectedSeason == nil || selectedSeason?.seasonNumber == seasonNumber {
                episodes = sorted
                loadedSeasonNumber = seasonNumber
                isLoadingEpisodes = false
            }
        } catch {
            guard generation == episodeLoadGeneration else { return }
            if selectedSeason == nil || selectedSeason?.seasonNumber == seasonNumber {
                if cachedEpisodes == nil,
                   let fallbackSeasonNumber,
                   let fallbackEpisodes = episodesBySeason[fallbackSeasonNumber],
                   let fallbackSeason = seasons.first(where: {
                       $0.seasonNumber == fallbackSeasonNumber
                   }) {
                    selectedSeason = fallbackSeason
                    episodes = fallbackEpisodes
                    loadedSeasonNumber = fallbackSeasonNumber
                }
                isLoadingEpisodes = false
            }
        }

        if refreshFavoriteStates,
           generation == episodeLoadGeneration,
           (selectedSeason?.seasonNumber == seasonNumber || selectedSeason == nil) {
            await refreshEpisodeFavoriteStates(for: episodesBySeason[seasonNumber] ?? episodes)
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

    /// Series overview action: mutate the season currently selected in the
    /// pill row, not the whole series. The server already fans a season
    /// mutation out to its episodes; refreshing the season + episode payloads
    /// keeps every checkmark and next-up calculation consistent afterward.
    func toggleSelectedSeasonWatched() async {
        guard let selectedSeason,
              let seriesId = seriesContentId else { return }

        let played = !(selectedSeason.userData?.played ?? false)
        do {
            try await ContinuumAPI.shared.setWatched(
                contentId: selectedSeason.contentId,
                played: played
            )
            invalidateRelatedCaches(
                contentId: selectedSeason.contentId,
                seriesId: seriesId,
                seasonNumber: selectedSeason.seasonNumber
            )

            await loadSeasons(seriesId: seriesId, autoSelectInitial: false)
            if let refreshed = seasons.first(where: {
                $0.contentId == selectedSeason.contentId
                    || $0.seasonNumber == selectedSeason.seasonNumber
            }) {
                await selectSeason(refreshed, forceRefresh: true)
            }
        } catch {
            // Leave the server-provided state untouched on failure.
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
            } else {
                // The sibling's cached watchlist value is not loaded here, so
                // discard its combined user-state entry rather than pairing
                // the new favorite value with unrelated detail-item state.
                ResponseCache.shared.remove(CacheKey.itemUserState(contentId))
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

/// Failures raised by the view model's own coordinator wiring rather than by
/// the API layer.
enum ItemDetailViewModelError: LocalizedError {
    case noItemLoaded

    var errorDescription: String? {
        switch self {
        case .noItemLoaded:
            return "No item is loaded."
        }
    }
}

/// User-state pair cached alongside an item detail so a returning view
/// renders the correct favorite / watchlist buttons without waiting for
/// the two `isFavorite` / `isInWatchlist` round-trips.
struct UserItemState {
    let isFavorite: Bool
    let inWatchlist: Bool
}
