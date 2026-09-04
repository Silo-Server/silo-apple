#if os(tvOS)
import SwiftUI
import os

/// Cinematic item-detail screen for tvOS. Replaces the shared
/// `MovieDetailContent` / `SeriesDetailContent` layouts on tvOS only; the
/// iOS / iPadOS targets continue to use those views verbatim.
///
/// The layout mirrors VidHub / Infuse / Plex: a full-width backdrop hero
/// with the title + key metadata + primary actions overlaid on the left,
/// then a scrollable body of horizontal rails below the fold.
struct TVItemDetailView: View {
    let contentId: String
    let seed: TVItemDetailRouteSeed?

    @State private var viewModel: ItemDetailViewModel
    /// Set when the user explicitly resets subtitles to "Auto" this visit:
    /// the server override is cleared with a fire-and-forget DELETE, but the
    /// already-fetched detail still carries the old `effectiveSubtitle*`, so
    /// the selector must stop feeding it to the "Auto: …" preview.
    @State private var didClearSubtitleOverride = false
    @State private var didClearNextUpSubtitleOverride = false
    @State private var nextUpPlaybackDetail: ItemDetail?
    /// Series owns one in-place episode selection. `nil` means the Show tab
    /// and its suggested next episode are active.
    @State private var activeSeriesEpisodeContentId: String?
    @State private var episodeSeriesDetail: ItemDetail?
    /// An episode normally canonicalizes to its parent Series overview. Keep
    /// the standalone detail as a resilient fallback when that parent cannot
    /// be loaded or the hierarchy metadata is incomplete.
    @State private var failedSeriesRedirectEpisodeContentId: String?
    @State private var isLoadingNextUpPlaybackDetail = false
    @State private var didLoadNextUpPlaybackDetail = false
    /// Serializes rapid season-tab intent before it reaches the async view
    /// model. A superseded task must never begin after its replacement and
    /// make an older season the selected one.
    @State private var seriesSeasonSelectionTask: Task<Void, Never>?
    @State private var seriesSeasonSelectionGeneration = 0
    /// Whether remote YouTube trailers should be presented, probed once per
    /// page appearance. Real Apple TVs require the YouTube app because tvOS
    /// has no browser fallback. The simulator deliberately presents the
    /// cards so the full detail layout can be developed and verified even
    /// though it cannot install or launch the external YouTube app.
    @State private var allowRemoteTrailers = false
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    private static let focusLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "TVFocus"
    )

    init(contentId: String, seed: TVItemDetailRouteSeed? = nil) {
        self.contentId = contentId
        self.seed = seed
        // Resolve the cached view model eagerly so the first `body`
        // evaluation can render cached content without a blank frame.
        _viewModel = State(
            initialValue: ItemDetailCache.shared.viewModel(for: contentId)
        )
    }

    var body: some View {
        Group {
            // Skip the spinner on cache hits — `detail != nil` means we
            // already have something to paint and the `.task` below is
            // refreshing it in the background.
            if let detail = viewModel.detail {
                content(for: detail)
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.loadDetail(contentId: contentId) } })
            } else {
                TVItemDetailLoadingView(seed: seed)
            }
        }
        .continuumBackground()
        .continuumNavigationTitleDisplayMode(.inline)
        .continuumNavigationBarBackgroundHidden()
        .onAppear {
            Self.focusLogger.debug("itemDetail.appear contentId=\(contentId, privacy: .public) pathDepth=\(router.path.count, privacy: .public)")
            allowRemoteTrailers = TVTrailerLaunch.canDisplayRemoteCards()
            seedSubtitleOverrideIfNeeded()
            // Returning from the player (or an extra) resumes a poll that
            // `onDisappear` cancelled — without re-POSTing, since the server
            // already spent the item's weekly slot. Precedent:
            // `PersonDetailView.resumeMetadataRefreshIfNeeded`.
            viewModel.resumeTrailerFetchIfNeeded()
        }
        .onDisappear {
            seriesSeasonSelectionTask?.cancel()
            seriesSeasonSelectionTask = nil
            Self.focusLogger.debug("itemDetail.disappear contentId=\(contentId, privacy: .public) pathDepth=\(router.path.count, privacy: .public)")
            viewModel.cancelDeferredEpisodeFavoriteStateRefresh()
            // The coordinator's poll is not owned by `.task`, so it would
            // otherwise keep running (and retaining the view model) after
            // this route pops.
            viewModel.stopTrailerFetch()
            // A pop proves the user is navigating in-app, so any handoff
            // record is dead: if the YouTube launch had actually taken over
            // the screen, this page could not be popping. Without this, a
            // failed `open` (app deleted after the probe) leaves a live
            // record that would ghost-navigate a later cold launch. The
            // jetsam case this store exists for never pops, so it is
            // unaffected.
            TVTrailerReturnStore.shared.clear()
        }
        .onChange(of: scenePhase) { _, newPhase in
            // A warm return from the YouTube app lands here with the page
            // still alive — nothing to restore, so the handoff record must
            // not survive to be replayed on some later cold launch. Re-probe
            // YouTube as well because its installation can change while Silo
            // is suspended.
            if newPhase == .active {
                allowRemoteTrailers = TVTrailerLaunch.canDisplayRemoteCards()
                TVTrailerReturnStore.shared.clear()
            }
        }
        .task(id: contentId) {
            seriesSeasonSelectionTask?.cancel()
            seriesSeasonSelectionTask = nil
            seriesSeasonSelectionGeneration &+= 1
            let navigationContext = TVSeriesDetailNavigationContextStore.take(
                for: contentId
            )
            didClearSubtitleOverride = false
            didClearNextUpSubtitleOverride = false
            nextUpPlaybackDetail = nil
            activeSeriesEpisodeContentId = navigationContext?.episodeContentId
            episodeSeriesDetail = nil
            failedSeriesRedirectEpisodeContentId = nil
            isLoadingNextUpPlaybackDetail = false
            didLoadNextUpPlaybackDetail = false
            await viewModel.loadDetail(contentId: contentId)
            if let navigationContext, !Task.isCancelled {
                await applySeriesNavigationContext(navigationContext)
            }
            seedSubtitleOverrideIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .tvPlaybackStateDidRefresh)) { note in
            guard let event = note.object as? TVPlaybackStateRefreshEvent else { return }
            applyCompletedPlaybackRefresh(event)
        }
    }

    // Selection state lives on the cached view model so a pushed player route
    // or a temporary navigation away from this item cannot discard it. These
    // nonmutating proxies keep the existing selector callbacks concise.
    private var preferredVersionFileId: Int? {
        get { viewModel.preferredVersionFileId }
        nonmutating set { viewModel.preferredVersionFileId = newValue }
    }

    /// Continue Watching episodes open the combined Series page at their exact
    /// season and episode. The marquee has normally warmed this hierarchy, but
    /// this post-load resolution is authoritative when cached preference state
    /// points at a different in-progress season.
    private func applySeriesNavigationContext(
        _ context: TVSeriesDetailNavigationContextStore.Context
    ) async {
        guard viewModel.detail?.type == "series" else { return }
        if viewModel.selectedSeason?.seasonNumber != context.seasonNumber,
           let season = viewModel.seasons.first(where: {
               $0.seasonNumber == context.seasonNumber
           }) {
            await viewModel.selectSeason(season)
        }
        guard !Task.isCancelled else { return }
        activeSeriesEpisodeContentId = context.episodeContentId
    }

    /// The cache has already reloaded authoritative watched/progress data when
    /// this arrives. Advance only the editorial episode selection; the native
    /// episode rail keeps ownership of focus and scrolling exactly as before.
    private func applyCompletedPlaybackRefresh(_ event: TVPlaybackStateRefreshEvent) {
        guard event.refreshedContentIds.contains(contentId),
              viewModel.detail?.type == "series",
              !event.completedContentIds.isEmpty else { return }

        let activeWasCompleted = activeSeriesEpisodeContentId.map {
            event.completedContentIds.contains($0)
        } ?? false
        let completedEpisodeIsVisible = viewModel.episodes.contains {
            event.completedContentIds.contains($0.contentId)
        }
        guard activeSeriesEpisodeContentId == nil
                || activeWasCompleted
                || completedEpisodeIsVisible else { return }

        if let inProgress = viewModel.episodes.first(where: {
            $0.userData?.isInProgress == true && !($0.userData?.played ?? false)
        }) {
            activeSeriesEpisodeContentId = inProgress.contentId
            return
        }

        if let activeSeriesEpisodeContentId,
           let completedIndex = viewModel.episodes.firstIndex(where: {
               $0.contentId == activeSeriesEpisodeContentId
           }),
           let next = viewModel.episodes.dropFirst(completedIndex + 1).first(where: {
               !($0.userData?.played ?? false)
           }) {
            self.activeSeriesEpisodeContentId = next.contentId
            return
        }

        if let nextUnwatched = viewModel.episodes.first(where: {
            !($0.userData?.played ?? false)
        }) {
            activeSeriesEpisodeContentId = nextUnwatched.contentId
        }
    }

    private var preferredAudioTrackIndex: Int? {
        get { viewModel.preferredAudioTrackIndex }
        nonmutating set { viewModel.preferredAudioTrackIndex = newValue }
    }

    private var preferredSubtitleTrackIndex: Int? {
        get { viewModel.preferredSubtitleTrackIndex }
        nonmutating set { viewModel.preferredSubtitleTrackIndex = newValue }
    }

    private var preferredNextUpFileId: Int? {
        get { viewModel.preferredNextUpFileId }
        nonmutating set { viewModel.preferredNextUpFileId = newValue }
    }

    private var preferredNextUpAudioTrackIndex: Int? {
        get { viewModel.preferredNextUpAudioTrackIndex }
        nonmutating set { viewModel.preferredNextUpAudioTrackIndex = newValue }
    }

    private var preferredNextUpSubtitleTrackIndex: Int? {
        get { viewModel.preferredNextUpSubtitleTrackIndex }
        nonmutating set { viewModel.preferredNextUpSubtitleTrackIndex = newValue }
    }

    // MARK: - Trailers & extras

    /// Merged rail for the detail on screen. Remote entries are dropped
    /// when the YouTube app isn't available (see `allowRemoteTrailers`).
    private func trailerEntries(for detail: ItemDetail) -> [TrailerRailEntry] {
        TrailerRail.entries(
            videos: detail.videos,
            extras: detail.extras,
            allowRemote: allowRemoteTrailers
        )
    }

    /// Local extras go straight to the streaming path — they are ordinary
    /// watch targets with their own contentId, always from the beginning
    /// (nothing tracks resume position for an extra). Remote entries hand
    /// off to the YouTube app.
    private func playTrailer(_ entry: TrailerRailEntry) {
        switch entry {
        case .remote(let video):
            // Recorded before the deep link so a jetsam during the trailer
            // can restore this page on the next cold launch (see
            // `TVTrailerReturnStore`). tvOS cannot bring the user back from
            // YouTube; this is the fallback for when suspension doesn't
            // preserve the page either.
            TVTrailerReturnStore.shared.saveHandoff(contentId: contentId)
            TVTrailerLaunch.open(siteKey: video.siteKey) { didOpen in
                guard !didOpen else { return }
                TVTrailerReturnStore.shared.clear()
            }
        case .local(let extra):
            router.navigate(
                to: .player(
                    contentId: extra.contentId,
                    startFromBeginning: true,
                    resumePosition: nil
                )
            )
        }
    }

    @ViewBuilder
    private func content(for detail: ItemDetail) -> some View {
        if detail.isAudiobook {
            AudiobookDetailContent(
                detail: detail,
                onNavigateToItem: { id in
                    router.navigate(to: .itemDetail(contentId: id))
                }
            )
        } else if detail.type == "season" {
            TVSeasonDetailView(
                detail: detail,
                isFavorite: viewModel.isFavorite,
                inWatchlist: viewModel.inWatchlist,
                isWatched: viewModel.isWatched,
                seasons: viewModel.seasons,
                selectedSeason: viewModel.selectedSeason,
                episodes: viewModel.episodes,
                episodeFavoriteStates: viewModel.episodeFavoriteStates,
                isLoadingEpisodes: viewModel.isLoadingEpisodes,
                selectedNextUpFileId: preferredNextUpFileId,
                selectedNextUpAudioTrackIndex: preferredNextUpAudioTrackIndex,
                selectedNextUpSubtitleTrackIndex: preferredNextUpSubtitleTrackIndex,
                nextUpPlaybackDetail: nextUpPlaybackDetail,
                nextUpSubtitleOverrideCleared: didClearNextUpSubtitleOverride,
                onPlayEpisode: { id, fileId, startFromBeginning in
                    let episode = viewModel.episodes.first { $0.contentId == id }
                    let resumePosition = startFromBeginning
                        ? nil
                        : playableResumePosition(
                            position: episode?.userData?.positionSeconds,
                            duration: episode?.userData?.durationSeconds
                        )
                    if let fileId = nextUpPlaybackFileId(resolvedFileId: fileId) {
                        router.navigate(
                            to: .playerWithFile(
                                contentId: id,
                                fileId: fileId,
                                audioTrackIndex: preferredNextUpAudioTrackIndex,
                                subtitleTrackIndex: preferredNextUpSubtitleTrackIndex,
                                startFromBeginning: startFromBeginning,
                                resumePosition: resumePosition
                            )
                        )
                    } else {
                        router.navigate(
                            to: .player(
                                contentId: id,
                                startFromBeginning: startFromBeginning,
                                resumePosition: resumePosition
                            )
                        )
                    }
                },
                onEpisodeTap: { id in
                    router.navigate(to: .itemDetail(contentId: id))
                },
                onSetEpisodeWatched: { id, played in
                    await viewModel.setEpisodeWatched(contentId: id, played: played)
                },
                onSetEpisodeFavorite: { id, isFavorite in
                    await viewModel.setEpisodeFavorite(contentId: id, isFavorite: isFavorite)
                },
                onSelectSeason: { season in
                    guard season.id != detail.contentId else { return }
                    router.navigate(to: .itemDetail(contentId: season.contentId))
                },
                onSelectNextUpVersion: { fileId in
                    preferredNextUpFileId = fileId
                    preferredNextUpAudioTrackIndex = sanitizedAudioTrackIndex(
                        for: nextUpPlaybackDetail,
                        versionFileId: fileId,
                        candidate: preferredNextUpAudioTrackIndex
                    )
                    preferredNextUpSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                        for: nextUpPlaybackDetail,
                        versionFileId: fileId,
                        candidate: preferredNextUpSubtitleTrackIndex
                    )
                },
                onSelectNextUpAudioTrack: { index in
                    preferredNextUpAudioTrackIndex = sanitizedAudioTrackIndex(
                        for: nextUpPlaybackDetail,
                        versionFileId: preferredNextUpFileId,
                        candidate: index
                    )
                    persistAudioSelection(
                        prefKey: prefKey(for: nextUpPlaybackDetail),
                        version: effectiveVersion(for: nextUpPlaybackDetail, versionFileId: preferredNextUpFileId),
                        requested: index,
                        sanitized: preferredNextUpAudioTrackIndex
                    )
                },
                onSelectNextUpSubtitleTrack: { index in
                    didClearNextUpSubtitleOverride = (index == nil)
                    preferredNextUpSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                        for: nextUpPlaybackDetail,
                        versionFileId: preferredNextUpFileId,
                        candidate: index
                    )
                    persistSubtitleSelection(
                        prefKey: prefKey(for: nextUpPlaybackDetail),
                        version: effectiveVersion(for: nextUpPlaybackDetail, versionFileId: preferredNextUpFileId),
                        requested: index,
                        sanitized: preferredNextUpSubtitleTrackIndex,
                        showForced: nil
                    )
                },
                onToggleFavorite: { Task { await viewModel.toggleFavorite() } },
                onToggleWatchlist: { Task { await viewModel.toggleWatchlist() } },
                onToggleWatched: { Task { await viewModel.toggleWatched() } },
                onPersonTap: { personId in
                    if let pid = Int(personId) {
                        router.navigate(to: .personDetail(personId: pid))
                    }
                },
                onNavigateToItem: { id in
                    router.navigate(to: .itemDetail(contentId: id))
                },
                belowSynopsis: {
                    DescriptionTranslationView(viewModel: viewModel, contentId: detail.contentId)
                        .id(detail.contentId)
                }
            )
            .task(id: seasonNextUpEpisodeContentId(for: detail)) {
                await loadSeasonNextUpPlaybackDetail(for: detail)
            }
        } else if let destination = episodeSeriesDestination(for: detail),
                  failedSeriesRedirectEpisodeContentId != detail.contentId {
            // Episode pages are not a separate tvOS destination. Resolve the
            // parent first so malformed hierarchy data can still fall back to
            // the existing standalone episode detail instead of dead-ending.
            Color.clear
                .task(id: destination) {
                    await redirectEpisodeToSeries(destination)
                }
        } else if detail.type == "series" {
            TVSeriesDetailView(
                detail: detail,
                isFavorite: viewModel.isFavorite,
                inWatchlist: viewModel.inWatchlist,
                isWatched: viewModel.selectedSeason?.userData?.played ?? false,
                seasons: viewModel.seasons,
                selectedSeason: viewModel.selectedSeason,
                episodes: viewModel.episodes,
                episodesBySeason: viewModel.episodesBySeason,
                activeEpisodeContentId: activeSeriesEpisodeContentId,
                episodeFavoriteStates: viewModel.episodeFavoriteStates,
                isLoadingEpisodes: viewModel.isLoadingEpisodes,
                selectedNextUpFileId: preferredNextUpFileId,
                selectedNextUpAudioTrackIndex: preferredNextUpAudioTrackIndex,
                selectedNextUpSubtitleTrackIndex: preferredNextUpSubtitleTrackIndex,
                nextUpPlaybackDetail: nextUpPlaybackDetail,
                isLoadingNextUpPlaybackDetail: isLoadingNextUpPlaybackDetail,
                didLoadNextUpPlaybackDetail: didLoadNextUpPlaybackDetail,
                nextUpSubtitleOverrideCleared: didClearNextUpSubtitleOverride,
                trailerEntries: trailerEntries(for: detail),
                onSelectTrailer: playTrailer,
                supportsTrailerFetch: viewModel.supportsTrailerFetch && allowRemoteTrailers,
                onFindTrailers: {
                    // Without the YouTube app the rail hides remote cards, so
                    // new remote videos must not be reported as a find.
                    viewModel.startTrailerFetch(
                        remoteVideosDisplayable: allowRemoteTrailers
                    )
                },
                trailerFetchStatus: viewModel.trailerFetch.statusMessage,
                isFetchingTrailers: viewModel.trailerFetch.isFetching,
                onTrailerStatusShown: { viewModel.trailerFetch.acknowledge() },
                onSelectSeason: { season in
                    activeSeriesEpisodeContentId = nil
                    seriesSeasonSelectionTask?.cancel()
                    seriesSeasonSelectionGeneration &+= 1
                    let generation = seriesSeasonSelectionGeneration
                    seriesSeasonSelectionTask = Task { @MainActor in
                        guard !Task.isCancelled,
                              generation == seriesSeasonSelectionGeneration else { return }
                        await viewModel.selectSeason(season)
                        guard !Task.isCancelled,
                              generation == seriesSeasonSelectionGeneration else { return }
                        seriesSeasonSelectionTask = nil
                    }
                },
                onActivateEpisode: { id in
                    activeSeriesEpisodeContentId = id
                },
                onPlayEpisode: { id, fileId, startFromBeginning in
                    let episode = viewModel.episodes.first(where: { $0.contentId == id })
                    let resumePosition = startFromBeginning
                        ? nil
                        : playableResumePosition(
                            position: episode?.userData?.positionSeconds,
                            duration: episode?.userData?.durationSeconds
                        )
                    if let fileId = nextUpPlaybackFileId(
                        resolvedFileId: fileId,
                        contentId: id
                    ) {
                        router.navigate(
                            to: .playerWithFile(
                                contentId: id,
                                fileId: fileId,
                                audioTrackIndex: preferredNextUpAudioTrackIndex,
                                subtitleTrackIndex: preferredNextUpSubtitleTrackIndex,
                                startFromBeginning: startFromBeginning,
                                resumePosition: resumePosition
                            )
                        )
                    } else {
                        router.navigate(
                            to: .player(
                                contentId: id,
                                startFromBeginning: startFromBeginning,
                                resumePosition: resumePosition
                            )
                        )
                    }
                },
                onSetEpisodeWatched: { id, played in
                    await viewModel.setEpisodeWatched(contentId: id, played: played)
                },
                onSetEpisodeFavorite: { id, isFavorite in
                    await viewModel.setEpisodeFavorite(contentId: id, isFavorite: isFavorite)
                },
                onSelectNextUpVersion: { fileId in
                    preferredNextUpFileId = fileId
                    preferredNextUpAudioTrackIndex = sanitizedAudioTrackIndex(
                        for: nextUpPlaybackDetail,
                        versionFileId: fileId,
                        candidate: preferredNextUpAudioTrackIndex
                    )
                    preferredNextUpSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                        for: nextUpPlaybackDetail,
                        versionFileId: fileId,
                        candidate: preferredNextUpSubtitleTrackIndex
                    )
                },
                onSelectNextUpAudioTrack: { index in
                    preferredNextUpAudioTrackIndex = sanitizedAudioTrackIndex(
                        for: nextUpPlaybackDetail,
                        versionFileId: preferredNextUpFileId,
                        candidate: index
                    )
                    persistAudioSelection(
                        prefKey: prefKey(for: nextUpPlaybackDetail),
                        version: effectiveVersion(for: nextUpPlaybackDetail, versionFileId: preferredNextUpFileId),
                        requested: index,
                        sanitized: preferredNextUpAudioTrackIndex
                    )
                },
                onSelectNextUpSubtitleTrack: { index in
                    didClearNextUpSubtitleOverride = (index == nil)
                    preferredNextUpSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                        for: nextUpPlaybackDetail,
                        versionFileId: preferredNextUpFileId,
                        candidate: index
                    )
                    persistSubtitleSelection(
                        prefKey: prefKey(for: nextUpPlaybackDetail),
                        version: effectiveVersion(for: nextUpPlaybackDetail, versionFileId: preferredNextUpFileId),
                        requested: index,
                        sanitized: preferredNextUpSubtitleTrackIndex,
                        showForced: nil
                    )
                },
                onToggleFavorite: { Task { await viewModel.toggleFavorite() } },
                onToggleWatchlist: { Task { await viewModel.toggleWatchlist() } },
                onToggleWatched: { Task { await viewModel.toggleSelectedSeasonWatched() } },
                onPersonTap: { personId in
                    if let pid = Int(personId) {
                        router.navigate(to: .personDetail(personId: pid))
                    }
                },
                onNavigateToItem: { id in
                    router.navigate(to: .itemDetail(contentId: id))
                },
                belowSynopsis: {
                    DescriptionTranslationView(viewModel: viewModel, contentId: detail.contentId)
                        .id(detail.contentId)
                }
            )
            .task(id: seriesNextUpEpisodeContentId(for: detail)) {
                await loadSeriesNextUpPlaybackDetail(for: detail)
            }
            .task(
                id: viewModel.selectedSeason?.contentId,
                priority: .background
            ) {
                await prefetchAdjacentSeriesSeasons(for: detail)
            }
        } else {
            let supportingDetail = episodeSupportingDetail(for: detail)
            TVMovieDetailView(
                detail: detail,
                supportingDetail: supportingDetail,
                isFavorite: viewModel.isFavorite,
                inWatchlist: viewModel.inWatchlist,
                isWatched: viewModel.isWatched,
                selectedVersionFileId: preferredVersionFileId,
                selectedAudioTrackIndex: preferredAudioTrackIndex,
                selectedSubtitleTrackIndex: preferredSubtitleTrackIndex,
                subtitleOverrideCleared: didClearSubtitleOverride,
                seasons: viewModel.seasons,
                selectedSeason: viewModel.selectedSeason,
                seasonEpisodes: viewModel.episodes,
                episodeFavoriteStates: viewModel.episodeFavoriteStates,
                isLoadingEpisodes: viewModel.isLoadingEpisodes,
                trailerEntries: trailerEntries(for: supportingDetail ?? detail),
                onSelectTrailer: playTrailer,
                supportsTrailerFetch: viewModel.supportsTrailerFetch && allowRemoteTrailers,
                onFindTrailers: {
                    // Without the YouTube app the rail hides remote cards, so
                    // new remote videos must not be reported as a find.
                    viewModel.startTrailerFetch(
                        remoteVideosDisplayable: allowRemoteTrailers
                    )
                },
                trailerFetchStatus: viewModel.trailerFetch.statusMessage,
                isFetchingTrailers: viewModel.trailerFetch.isFetching,
                onTrailerStatusShown: { viewModel.trailerFetch.acknowledge() },
                onPlay: { startFromBeginning in
                    let resumePosition = startFromBeginning ? nil : playableResumePosition(for: detail)
                    if let fileId = playbackFileId(for: detail) {
                        router.navigate(
                            to: .playerWithFile(
                                contentId: contentId,
                                fileId: fileId,
                                audioTrackIndex: preferredAudioTrackIndex,
                                subtitleTrackIndex: preferredSubtitleTrackIndex,
                                startFromBeginning: startFromBeginning,
                                resumePosition: resumePosition
                            )
                        )
                    } else {
                        router.navigate(
                            to: .player(
                                contentId: contentId,
                                startFromBeginning: startFromBeginning,
                                resumePosition: resumePosition
                            )
                        )
                    }
                },
                onSelectVersion: { fileId in
                    preferredVersionFileId = fileId
                    preferredAudioTrackIndex = sanitizedAudioTrackIndex(
                        for: detail,
                        versionFileId: fileId,
                        candidate: preferredAudioTrackIndex
                    )
                    preferredSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                        for: detail,
                        versionFileId: fileId,
                        candidate: preferredSubtitleTrackIndex
                    )
                },
                onSelectAudioTrack: { index in
                    preferredAudioTrackIndex = sanitizedAudioTrackIndex(
                        for: detail,
                        versionFileId: preferredVersionFileId,
                        candidate: index
                    )
                    persistAudioSelection(
                        prefKey: prefKey(for: detail),
                        version: effectiveVersion(for: detail, versionFileId: preferredVersionFileId),
                        requested: index,
                        sanitized: preferredAudioTrackIndex
                    )
                },
                onSelectSubtitleTrack: { index in
                    didClearSubtitleOverride = (index == nil)
                    viewModel.preferredSubtitleTrackWasManuallySelected = true
                    preferredSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                        for: detail,
                        versionFileId: preferredVersionFileId,
                        candidate: index
                    )
                    persistSubtitleSelection(
                        prefKey: prefKey(for: detail),
                        version: effectiveVersion(for: detail, versionFileId: preferredVersionFileId),
                        requested: index,
                        sanitized: preferredSubtitleTrackIndex,
                        showForced: nil
                    )
                },
                onSelectSeason: { season in
                    // Swap the episode rail in place (series-page behavior)
                    // instead of pushing the season's own detail page.
                    guard season.id != viewModel.selectedSeason?.id else { return }
                    Task { await viewModel.selectSeason(season) }
                },
                onToggleFavorite: { Task { await viewModel.toggleFavorite() } },
                onToggleWatchlist: { Task { await viewModel.toggleWatchlist() } },
                onToggleWatched: { Task { await viewModel.toggleWatched() } },
                onPersonTap: { personId in
                    if let pid = Int(personId) {
                        router.navigate(to: .personDetail(personId: pid))
                    }
                },
                onNavigateToItem: { id in
                    router.navigate(to: .itemDetail(contentId: id))
                },
                onEpisodeTap: { id in
                    guard id != detail.contentId else { return }
                    // Switch only the active episode detail. Replacing the
                    // current route keeps Back returning to the series page
                    // and avoids stacking one route per episode browse.
                    router.replaceCurrent(with: .itemDetail(contentId: id))
                },
                onPlayEpisodeShortcut: { id in
                    let episode = viewModel.episodes.first { $0.contentId == id }
                    let resumePosition = playableResumePosition(
                        position: episode?.userData?.positionSeconds,
                        duration: episode?.userData?.durationSeconds
                    )
                    router.presentPlayer(
                        contentId: id,
                        fileId: nil,
                        audioTrackIndex: nil,
                        subtitleTrackIndex: nil,
                        startFromBeginning: false,
                        resumePosition: resumePosition,
                        returnToContentId: id
                    )
                },
                onSetEpisodeWatched: { id, played in
                    await viewModel.setEpisodeWatched(contentId: id, played: played)
                },
                onSetEpisodeFavorite: { id, isFavorite in
                    await viewModel.setEpisodeFavorite(contentId: id, isFavorite: isFavorite)
                },
                belowSynopsis: {
                    DescriptionTranslationView(viewModel: viewModel, contentId: detail.contentId)
                        .id(detail.contentId)
                }
            )
            .task(id: detail.type == "episode" ? detail.seriesId : nil) {
                await loadEpisodeSeriesDetail(for: detail)
            }
        }
    }

    private func episodeSeriesDestination(
        for detail: ItemDetail
    ) -> TVSeriesDetailNavigationContextStore.Context? {
        guard detail.type == "episode",
              let rawSeriesId = detail.seriesId,
              let seasonNumber = detail.seasonNumber else { return nil }

        let seriesId = rawSeriesId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seriesId.isEmpty, seriesId != detail.contentId else { return nil }

        return TVSeriesDetailNavigationContextStore.Context(
            seriesContentId: seriesId,
            seasonNumber: seasonNumber,
            episodeContentId: detail.contentId
        )
    }

    private func redirectEpisodeToSeries(
        _ destination: TVSeriesDetailNavigationContextStore.Context
    ) async {
        let cacheKey = CacheKey.itemDetail(destination.seriesContentId)
        if let cached: ItemDetail = ResponseCache.shared.get(cacheKey),
           cached.type == "series" {
            routeToSeries(destination)
            return
        }

        do {
            let series = try await MetadataRequestPool.shared.itemDetail(
                contentId: destination.seriesContentId
            )
            guard !Task.isCancelled,
                  contentId == destination.episodeContentId else { return }
            guard series.type == "series" else {
                failedSeriesRedirectEpisodeContentId = destination.episodeContentId
                return
            }
            ResponseCache.shared.set(series, for: cacheKey)
            routeToSeries(destination)
        } catch {
            guard !Task.isCancelled,
                  contentId == destination.episodeContentId else { return }
            failedSeriesRedirectEpisodeContentId = destination.episodeContentId
        }
    }

    private func routeToSeries(
        _ destination: TVSeriesDetailNavigationContextStore.Context
    ) {
        guard contentId == destination.episodeContentId else { return }
        TVSeriesDetailNavigationContextStore.stage(
            seriesContentId: destination.seriesContentId,
            seasonNumber: destination.seasonNumber,
            episodeContentId: destination.episodeContentId
        )
        router.replaceCurrent(
            with: .itemDetail(contentId: destination.seriesContentId)
        )
    }

    private func loadEpisodeSeriesDetail(for detail: ItemDetail) async {
        guard detail.type == "episode",
              let seriesId = detail.seriesId,
              !seriesId.isEmpty else {
            episodeSeriesDetail = nil
            return
        }
        if let cached: ItemDetail = ResponseCache.shared.get(CacheKey.itemDetail(seriesId)) {
            episodeSeriesDetail = cached
        }
        guard let fresh = try? await MetadataRequestPool.shared.itemDetail(contentId: seriesId),
              !Task.isCancelled else { return }
        ResponseCache.shared.set(fresh, for: CacheKey.itemDetail(seriesId))
        episodeSeriesDetail = fresh
    }

    /// The series page that launched an episode is already in the process-wide
    /// cache. Read it during the episode's very first body evaluation so its
    /// logo never waits for the supporting-detail task to make another trip.
    private func episodeSupportingDetail(for detail: ItemDetail) -> ItemDetail? {
        guard detail.type == "episode",
              let seriesId = detail.seriesId,
              !seriesId.isEmpty else { return episodeSeriesDetail }
        return episodeSeriesDetail
            ?? ResponseCache.shared.get(CacheKey.itemDetail(seriesId))
    }

    private func playbackFileId(for detail: ItemDetail) -> Int? {
        if let preferredVersionFileId {
            return preferredVersionFileId
        }
        if preferredAudioTrackIndex != nil || preferredSubtitleTrackIndex != nil {
            return effectiveVersion(for: detail, versionFileId: preferredVersionFileId)?.fileId
        }
        return nil
    }

    /// Next-up analogue of `playbackFileId(for:)`. When Series focus changes,
    /// reject any file choice still belonging to the previous episode so an
    /// immediate quick Play safely falls back to server/device defaults.
    private func nextUpPlaybackFileId(
        resolvedFileId: Int?,
        contentId: String? = nil
    ) -> Int? {
        if let contentId,
           nextUpPlaybackDetail?.contentId != contentId {
            return nil
        }
        if let resolvedFileId {
            return resolvedFileId
        }
        return effectiveVersion(
            for: nextUpPlaybackDetail,
            versionFileId: preferredNextUpFileId
        )?.fileId
    }

    private func playableResumePosition(for detail: ItemDetail) -> Double? {
        playableResumePosition(
            position: detail.userData?.positionSeconds,
            duration: detail.userData?.durationSeconds
        )
    }

    private func playableResumePosition(position: Double?, duration: Double?) -> Double? {
        guard let position, position.isFinite, position > 30 else { return nil }
        if let duration, duration.isFinite, duration > 0, position >= duration - 5 {
            return nil
        }
        return position
    }

    private func effectiveVersion(for detail: ItemDetail, versionFileId: Int?) -> FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: detail.versions ?? [],
            selectedFileId: versionFileId,
            lastFileId: detail.userData?.lastFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
    }

    private func effectiveVersion(for detail: ItemDetail?, versionFileId: Int?) -> FileVersion? {
        guard let detail else { return nil }
        return effectiveVersion(for: detail, versionFileId: versionFileId)
    }

    private func sanitizedAudioTrackIndex(
        for detail: ItemDetail,
        versionFileId: Int?,
        candidate: Int?
    ) -> Int? {
        guard let candidate else { return nil }
        guard let version = effectiveVersion(for: detail, versionFileId: versionFileId) else {
            return nil
        }
        let tracks = version.audioTracks ?? []
        return tracks.indices.contains(candidate) ? candidate : nil
    }

    private func sanitizedSubtitleTrackIndex(
        for detail: ItemDetail,
        versionFileId: Int?,
        candidate: Int?
    ) -> Int? {
        guard let candidate else { return nil }
        if candidate < 0 { return candidate }
        guard let version = effectiveVersion(for: detail, versionFileId: versionFileId) else {
            return nil
        }
        let available = version.subtitleTracks?.compactMap(\.selectionIndex) ?? []
        return available.contains(candidate) ? candidate : nil
    }

    private func sanitizedAudioTrackIndex(
        for detail: ItemDetail?,
        versionFileId: Int?,
        candidate: Int?
    ) -> Int? {
        guard let detail else { return nil }
        return sanitizedAudioTrackIndex(for: detail, versionFileId: versionFileId, candidate: candidate)
    }

    private func sanitizedSubtitleTrackIndex(
        for detail: ItemDetail?,
        versionFileId: Int?,
        candidate: Int?
    ) -> Int? {
        guard let detail else { return nil }
        return sanitizedSubtitleTrackIndex(for: detail, versionFileId: versionFileId, candidate: candidate)
    }

    // MARK: - Track-choice persistence
    //
    // Selector picks are remembered server-side (web-app parity):
    // episodes key by series id so one choice covers the series, movies
    // by their own content id. "Auto" (nil) clears the override so the
    // library/profile cascade applies again.

    /// Reflect a server-remembered subtitle override in the selector on
    /// entry. `preferredSubtitleTrackIndex` is per-visit state, so
    /// without this the selector always reopens on "Auto" even though
    /// the pick was persisted; audio doesn't need an equivalent because
    /// `resolvedAudioOrdinal` falls back to `effectiveAudioTrackIndex`.
    private func seedSubtitleOverrideIfNeeded() {
        if PlayerSettings.shared.subtitleMatchesSystemAppearance {
            if !viewModel.preferredSubtitleTrackWasManuallySelected {
                preferredSubtitleTrackIndex = nil
            }
            return
        }
        guard !viewModel.preferredSubtitleTrackWasManuallySelected,
              preferredSubtitleTrackIndex == nil,
              let detail = viewModel.detail else { return }
        preferredSubtitleTrackIndex = DetailPlaybackFormatting.launchPreferredSubtitleIndex(
            version: effectiveVersion(for: detail, versionFileId: preferredVersionFileId),
            signature: detail.effectiveSubtitleTrackSignature,
            mode: detail.effectiveSubtitleMode,
            usesDeviceSettings: PlayerSettings.shared.subtitleMatchesSystemAppearance
        )
    }

    private func prefKey(for detail: ItemDetail?) -> String? {
        TrackSelectionPersistence.prefKey(seriesId: detail?.seriesId, contentId: detail?.contentId)
    }

    private func persistAudioSelection(
        prefKey: String?,
        version: FileVersion?,
        requested: Int?,
        sanitized: Int?
    ) {
        guard let prefKey else { return }
        guard let requested else {
            TrackSelectionPersistence.clearAudio(prefKey: prefKey)
            return
        }
        guard requested == sanitized,
              let version,
              let request = TrackSelectionPersistence.audioRequest(version: version, ordinal: requested)
        else { return }
        TrackSelectionPersistence.saveAudio(prefKey: prefKey, request: request)
    }

    private func persistSubtitleSelection(
        prefKey: String?,
        version: FileVersion?,
        requested: Int?,
        sanitized: Int?,
        showForced: Bool?
    ) {
        guard let prefKey else { return }
        guard let requested else {
            TrackSelectionPersistence.clearSubtitle(prefKey: prefKey)
            return
        }
        guard requested == sanitized, let version,
              let request = TrackSelectionPersistence.subtitleRequest(
                  version: version,
                  ffIndex: requested,
                  showForced: showForced
              )
        else { return }
        TrackSelectionPersistence.saveSubtitle(prefKey: prefKey, request: request)
    }

    private func seasonNextUpEpisode(for detail: ItemDetail) -> EpisodeListItem? {
        guard detail.type == "season" else { return nil }
        if let inProgress = viewModel.episodes.first(where: { $0.userData?.isInProgress == true }) {
            return inProgress
        }
        if let unwatched = viewModel.episodes.first(where: { !($0.userData?.played ?? false) }) {
            return unwatched
        }
        return viewModel.episodes.first
    }

    private func seasonNextUpEpisodeContentId(for detail: ItemDetail) -> String? {
        seasonNextUpEpisode(for: detail)?.contentId
    }

    private func loadSeasonNextUpPlaybackDetail(for detail: ItemDetail) async {
        guard let nextUp = seasonNextUpEpisode(for: detail) else {
            nextUpPlaybackDetail = nil
            isLoadingNextUpPlaybackDetail = false
            didLoadNextUpPlaybackDetail = false
            preferredNextUpFileId = nil
            preferredNextUpAudioTrackIndex = nil
            preferredNextUpSubtitleTrackIndex = nil
            didClearNextUpSubtitleOverride = false
            return
        }

        nextUpPlaybackDetail = nil
        isLoadingNextUpPlaybackDetail = true
        didLoadNextUpPlaybackDetail = false
        preferredNextUpFileId = nil
        preferredNextUpAudioTrackIndex = nil
        preferredNextUpSubtitleTrackIndex = nil
        didClearNextUpSubtitleOverride = false

        do {
            let item = try await MetadataRequestPool.shared.itemDetail(contentId: nextUp.contentId)
            guard !Task.isCancelled else { return }
            let enriched = await enrichPlaybackMetadata(for: item, contentId: nextUp.contentId)
            guard !Task.isCancelled else { return }
            nextUpPlaybackDetail = enriched
            if let enriched {
                preferredNextUpSubtitleTrackIndex = DetailPlaybackFormatting.launchPreferredSubtitleIndex(
                    version: effectiveVersion(for: enriched, versionFileId: nil),
                    signature: enriched.effectiveSubtitleTrackSignature,
                    mode: enriched.effectiveSubtitleMode,
                    usesDeviceSettings: PlayerSettings.shared.subtitleMatchesSystemAppearance
                )
            }
            didLoadNextUpPlaybackDetail = true
        } catch {
            guard !Task.isCancelled else { return }
            nextUpPlaybackDetail = nil
            didLoadNextUpPlaybackDetail = true
        }
        isLoadingNextUpPlaybackDetail = false
    }

    private func seriesNextUpEpisode(for detail: ItemDetail) -> EpisodeListItem? {
        guard detail.type == "series" else { return nil }
        if let activeSeriesEpisodeContentId,
           let active = viewModel.episodes.first(where: {
               $0.contentId == activeSeriesEpisodeContentId
           }) {
            return active
        }
        if let inProgress = viewModel.episodes.first(where: { $0.userData?.isInProgress == true }) {
            return inProgress
        }
        if let unwatched = viewModel.episodes.first(where: { !($0.userData?.played ?? false) }) {
            return unwatched
        }
        return viewModel.episodes.first
    }

    private func seriesNextUpEpisodeContentId(for detail: ItemDetail) -> String? {
        seriesNextUpEpisode(for: detail)?.contentId
    }

    private func loadSeriesNextUpPlaybackDetail(for detail: ItemDetail) async {
        guard let nextUp = seriesNextUpEpisode(for: detail) else {
            nextUpPlaybackDetail = nil
            isLoadingNextUpPlaybackDetail = false
            didLoadNextUpPlaybackDetail = false
            preferredNextUpFileId = nil
            preferredNextUpAudioTrackIndex = nil
            preferredNextUpSubtitleTrackIndex = nil
            didClearNextUpSubtitleOverride = false
            return
        }

        let cached: ItemDetail? = ResponseCache.shared.get(
            CacheKey.itemDetail(nextUp.contentId)
        )
        let usableCached = cached?.versions?.isEmpty == false ? cached : nil
        nextUpPlaybackDetail = usableCached
        isLoadingNextUpPlaybackDetail = true
        didLoadNextUpPlaybackDetail = usableCached != nil
        preferredNextUpFileId = nil
        preferredNextUpAudioTrackIndex = nil
        preferredNextUpSubtitleTrackIndex = nil
        didClearNextUpSubtitleOverride = false
        if let usableCached {
            preferredNextUpSubtitleTrackIndex = DetailPlaybackFormatting.launchPreferredSubtitleIndex(
                version: effectiveVersion(for: usableCached, versionFileId: nil),
                signature: usableCached.effectiveSubtitleTrackSignature,
                mode: usableCached.effectiveSubtitleMode,
                usesDeviceSettings: PlayerSettings.shared.subtitleMatchesSystemAppearance
            )
        }

        do {
            let item = try await MetadataRequestPool.shared.itemDetail(contentId: nextUp.contentId)
            guard !Task.isCancelled else { return }
            let enriched = await enrichPlaybackMetadata(for: item, contentId: nextUp.contentId)
            guard !Task.isCancelled else { return }
            let resolved: ItemDetail?
            if let enriched, enriched.versions?.isEmpty == false {
                ResponseCache.shared.set(enriched, for: CacheKey.itemDetail(nextUp.contentId))
                resolved = enriched
            } else if let usableCached {
                resolved = usableCached
            } else {
                resolved = enriched
            }
            nextUpPlaybackDetail = resolved
            if let resolved {
                preferredNextUpSubtitleTrackIndex = DetailPlaybackFormatting.launchPreferredSubtitleIndex(
                    version: effectiveVersion(for: resolved, versionFileId: nil),
                    signature: resolved.effectiveSubtitleTrackSignature,
                    mode: resolved.effectiveSubtitleMode,
                    usesDeviceSettings: PlayerSettings.shared.subtitleMatchesSystemAppearance
                )
            }
            didLoadNextUpPlaybackDetail = true
        } catch {
            guard !Task.isCancelled else { return }
            if usableCached == nil {
                nextUpPlaybackDetail = nil
            }
            didLoadNextUpPlaybackDetail = true
        }
        isLoadingNextUpPlaybackDetail = false

        // Neighbor playback data is speculative. Keep it out of the selected
        // episode's critical path so its detail and artwork get first use of
        // the network and decoder queues.
        do {
            try await Task.sleep(for: .milliseconds(1_200))
        } catch {
            return
        }
        await prefetchAdjacentEpisodePlayback(around: nextUp)
    }

    /// Warm the immediate neighbors without publishing either one. Moving
    /// laterally can then swap the selector and hero from ResponseCache while
    /// the fresh request silently validates the data.
    private func prefetchAdjacentEpisodePlayback(
        around episode: EpisodeListItem
    ) async {
        guard let index = viewModel.episodes.firstIndex(where: {
            $0.contentId == episode.contentId
        }) else { return }

        let neighborIndices = [index - 1, index + 1]
            .filter { viewModel.episodes.indices.contains($0) }

        for neighborIndex in neighborIndices {
            guard !Task.isCancelled else { return }
            let neighbor = viewModel.episodes[neighborIndex]
            let cached: ItemDetail? = ResponseCache.shared.get(
                CacheKey.itemDetail(neighbor.contentId)
            )
            if cached?.versions?.isEmpty == false { continue }

            guard let item = try? await MetadataRequestPool.shared.itemDetail(
                contentId: neighbor.contentId
            ), !Task.isCancelled else { continue }
            guard let enriched = await enrichPlaybackMetadata(
                for: item,
                contentId: neighbor.contentId
            ), enriched.versions?.isEmpty == false else { continue }
            guard !Task.isCancelled else { return }
            ResponseCache.shared.set(
                enriched,
                for: CacheKey.itemDetail(neighbor.contentId)
            )
        }
    }

    /// Prefetch the episode lists and stills for the seasons beside the
    /// selected one. `ItemDetailViewModel.selectSeason` already hydrates from
    /// this same cache key, so first-time season changes avoid the empty/jumpy
    /// state without duplicating ownership of the published episode array.
    private func prefetchAdjacentSeriesSeasons(for detail: ItemDetail) async {
        guard detail.type == "series",
              let selectedSeason = viewModel.selectedSeason,
              let index = viewModel.seasons.firstIndex(where: {
                  $0.contentId == selectedSeason.contentId
              }) else { return }

        let neighborIndices = [index - 1, index + 1]
            .filter { viewModel.seasons.indices.contains($0) }

        for neighborIndex in neighborIndices {
            guard !Task.isCancelled else { return }
            let season = viewModel.seasons[neighborIndex]
            let key = CacheKey.itemEpisodes(
                seriesId: detail.contentId,
                seasonNumber: season.seasonNumber
            )

            let response: EpisodesResponse
            if let cached: EpisodesResponse = ResponseCache.shared.get(key) {
                response = cached
            } else {
                guard let fetched = try? await MetadataRequestPool.shared.episodes(
                    seriesId: detail.contentId,
                    seasonNumber: season.seasonNumber
                ), !Task.isCancelled else { continue }
                ResponseCache.shared.set(fetched, for: key)
                response = fetched
            }

            let stillURLs = response.episodes.compactMap { episode in
                episode.stillUrl.flatMap(URL.init(string:))
            }
            PosterImageCache.prefetchCardArtwork(stillURLs)

            let sorted = response.episodes.sorted {
                $0.episodeNumber < $1.episodeNumber
            }
            if viewModel.episodesBySeason[season.seasonNumber] == nil {
                // Feed the route-scoped page cache as well as ResponseCache.
                // The full season rail can then mount this neighbour before
                // the first tab movement instead of warming only after it.
                viewModel.episodesBySeason[season.seasonNumber] = sorted
            }
        }
    }

    private func enrichPlaybackMetadata(for item: ItemDetail, contentId: String) async -> ItemDetail? {
        guard item.type != "series" else { return item }

        do {
            let watchDetail = try await MetadataRequestPool.shared.watchDetail(contentId: contentId)
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
            return nil
        }
    }
}

/// One-shot route payload for opening an episode in its parent Series overview.
/// `Route.itemDetail` remains a shared iOS/tvOS destination; this tvOS-only
/// store supplies the extra browse context without widening every platform's
/// navigation enum.
@MainActor
enum TVSeriesDetailNavigationContextStore {
    struct Context: Equatable {
        let seriesContentId: String
        let seasonNumber: Int
        let episodeContentId: String
    }

    private static var pending: Context?

    static func stage(
        seriesContentId: String,
        seasonNumber: Int,
        episodeContentId: String
    ) {
        pending = Context(
            seriesContentId: seriesContentId,
            seasonNumber: seasonNumber,
            episodeContentId: episodeContentId
        )
    }

    static func take(for contentId: String) -> Context? {
        guard pending?.seriesContentId == contentId else { return nil }
        defer { pending = nil }
        return pending
    }
}
#endif
