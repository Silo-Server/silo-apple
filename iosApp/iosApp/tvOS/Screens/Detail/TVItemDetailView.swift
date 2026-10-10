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
    let libraryId: Int?
    let seed: TVItemDetailRouteSeed?
    let navigationContext: SeriesDetailContext?
    let onResolveSeries: ((SeriesDetailContext) -> Void)?

    @State private var viewModel: ItemDetailViewModel
    @State private var hasStartedDetailLoad = false
    /// Set when the user explicitly resets subtitles to "Auto" this visit:
    /// the server override is cleared with a fire-and-forget DELETE, but the
    /// already-fetched detail still carries the old `effectiveSubtitle*`, so
    /// the selector must stop feeding it to the "Auto: …" preview.
    @State private var didClearSubtitleOverride = false
    @State private var didClearNextUpSubtitleOverride = false
    @State private var nextUpPlaybackDetail: ItemDetail?
    /// The next-up episode's catalog item. The hero reads its ratings when
    /// the playback details for that episode could not be loaded.
    @State private var nextUpCatalogDetail: ItemDetail?
    /// Series owns one in-place episode selection. `nil` means the series
    /// overview and its suggested next episode are active.
    @State private var activeSeriesEpisodeContentId: String?
    /// Bumped to move the episode row to `activeSeriesEpisodeContentId`
    /// after the player closes, including when the row holds focus.
    @State private var seriesEpisodeSelectionRequest = 0
    @State private var isPageVisible = false
    /// Set when this page starts playback, so it only acts on its own return.
    @State private var awaitsPlaybackReturn = false
    /// A Resume/Play press's in-flight watch-state read. A second press
    /// replaces it; leaving the page cancels it.
    @State private var resumeLookupTask: Task<Void, Never>?
    @State private var carouselLoadFailed = false
    @State private var carouselRetryGeneration = 0
    /// Whether remote YouTube trailers should be presented, probed once per
    /// page appearance. Real Apple TVs require the YouTube app because tvOS
    /// has no browser fallback. The simulator deliberately presents the
    /// cards so the full detail layout can be developed and verified even
    /// though it cannot install or launch the external YouTube app.
    @State private var allowRemoteTrailers = false
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    private static let focusLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "TVFocus"
    )

    init(contentId: String, libraryId: Int? = nil, seed: TVItemDetailRouteSeed? = nil, navigationContext: SeriesDetailContext? = nil, onResolveSeries: ((SeriesDetailContext) -> Void)? = nil) {
        self.contentId = contentId
        self.libraryId = libraryId
        self.seed = seed
        self.navigationContext = navigationContext
        self.onResolveSeries = onResolveSeries
        // Resolve the cached view model eagerly so the first `body`
        // evaluation can render cached content without a blank frame.
        _viewModel = State(initialValue: ItemDetailCache.shared.viewModel(for: contentId, libraryId: libraryId))
    }

    var body: some View {
        Group {
            // A resolved series entry shows the loading view until its task
            // seeds the season. Otherwise cached detail paints at once while
            // `.task` refreshes it.
            if !hasStartedDetailLoad, navigationContext?.seriesContentId == contentId {
                TVItemDetailLoadingView(seed: seed)
            } else if let detail = viewModel.detail {
                content(for: detail)
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.loadDetail(contentId: contentId) } })
            } else {
                TVItemDetailLoadingView(seed: seed)
            }
        }
        .siloBackground()
        .siloNavigationTitleDisplayMode(.inline)
        .siloNavigationBarBackgroundHidden()
        .descriptionTranslation(viewModel)
        .personalStateNoticeAlert($viewModel.personalStateNotice)
        .onAppear {
            isPageVisible = true
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
            isPageVisible = false
            resumeLookupTask?.cancel()
            resumeLookupTask = nil
            viewModel.cancelDetailLoading()
            Self.focusLogger.debug("itemDetail.disappear contentId=\(contentId, privacy: .public) pathDepth=\(router.path.count, privacy: .public)")
            viewModel.cancelDeferredEpisodePersonalListStateRefresh()
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
            // Returning from the player restarts this task. Keep the episode
            // the page was showing instead of falling back to a stale guess.
            let isReturning = hasStartedDetailLoad
            let entryContext = !hasStartedDetailLoad
                && navigationContext?.seriesContentId == contentId
                ? navigationContext : nil
            didClearSubtitleOverride = false
            didClearNextUpSubtitleOverride = false
            nextUpPlaybackDetail = nil
            nextUpCatalogDetail = nil
            if !isReturning {
                activeSeriesEpisodeContentId = entryContext?.episodeContentId
            }
            if let seasonNumber = entryContext?.seasonNumber {
                viewModel.prepareInitialSeriesSeason(
                    seasonNumber, seriesId: contentId
                )
            } else {
                if isReturning, let playback = takePlaybackReturn() {
                    await applySeriesPlaybackReturn(playback)
                }
                viewModel.initialResumeSeasonNumber = viewModel.selectedSeason?.seasonNumber
                    ?? viewModel.initialResumeSeasonNumber
            }
            hasStartedDetailLoad = true
            await viewModel.loadDetail(contentId: contentId)
            seedSubtitleOverrideIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .seriesPlaybackDidReturn)) { _ in
            // The player can finish tearing down after this page reappears.
            // While the page is hidden, its reappearing task applies the return.
            guard hasStartedDetailLoad, isPageVisible, let playback = takePlaybackReturn() else { return }
            Task { await applySeriesPlaybackReturn(playback) }
        }
    }

    // Selection state lives on the cached view model so a pushed player route
    // or a temporary navigation away from this item cannot discard it. These
    // nonmutating proxies keep the existing selector callbacks concise.
    private var preferredVersionFileId: Int? {
        get { viewModel.preferredVersionFileId }
        nonmutating set { viewModel.preferredVersionFileId = newValue }
    }

    private func takePlaybackReturn() -> SeriesPlaybackReturn? {
        guard awaitsPlaybackReturn,
              let playback = SeriesPlaybackReturnInbox.take(seriesContentId: contentId) else { return nil }
        awaitsPlaybackReturn = false
        return playback
    }

    /// Land on the episode after a finished one, or on the same episode after
    /// a partial watch, and move the episode row there with it.
    private func applySeriesPlaybackReturn(_ playback: SeriesPlaybackReturn) async {
        guard let episodeId = await viewModel.prepareSeriesPlaybackReturn(playback),
              !Task.isCancelled else { return }
        viewModel.activateLoadedSeriesEpisode(episodeId)
        activeSeriesEpisodeContentId = episodeId
        seriesEpisodeSelectionRequest &+= 1
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
            TVTrailerReturnStore.shared.saveHandoff(contentId: contentId, libraryId: libraryId)
            TVTrailerLaunch.open(siteKey: video.siteKey) { didOpen in
                guard !didOpen else { return }
                TVTrailerReturnStore.shared.clear()
            }
        case .local(let extra):
            router.navigate(
                to: .player(
                    contentId: extra.contentId,
                    startFromBeginning: true,
                    resumePosition: nil,
                    libraryId: libraryId
                )
            )
        }
    }

    @ViewBuilder
    private func content(for detail: ItemDetail) -> some View {
        if detail.isAudiobook {
            TVAudiobookDetailView(
                detail: detail,
                libraryId: libraryId,
                onNavigateToItem: { id in
                    router.navigate(to: .itemDetail(contentId: id))
                }
            )
        } else if detail.type == "season" || detail.type == "episode" {
            SeriesDetailResolutionView(detail: detail, onResolve: onResolveSeries) {
                Task { await viewModel.loadDetail(contentId: contentId) }
            }
        } else if detail.type == "series" {
            TVSeriesDetailView(
                detail: detail,
                isFavorite: viewModel.isFavorite,
                inWatchlist: viewModel.inWatchlist,
                isSeriesWatched: viewModel.isWatched,
                isSeasonWatched: viewModel.selectedSeason?.userData?.played ?? false,
                seasons: viewModel.seasons,
                selectedSeason: viewModel.selectedSeason,
                episodes: viewModel.episodes,
                episodeWindow: viewModel.seriesEpisodeWindow,
                carouselLoadFailed: carouselLoadFailed,
                onLoadMoreEpisodes: {
                    // Retry only after a failure; focus reaching the boundary
                    // card already requests neighbours.
                    if carouselLoadFailed { carouselRetryGeneration &+= 1 }
                },
                activeEpisodeContentId: activeSeriesEpisodeContentId,
                episodeSelectionRequest: seriesEpisodeSelectionRequest,
                episodeFavoriteStates: viewModel.episodeFavoriteStates,
                episodeWatchlistStates: viewModel.episodeWatchlistStates,
                isLoadingEpisodes: viewModel.isLoadingSeriesHierarchy,
                hierarchyError: viewModel.seriesLoadErrorMessage,
                onRetryHierarchy: { await viewModel.retrySeriesHierarchy() },
                selectedNextUpFileId: preferredNextUpFileId,
                selectedNextUpAudioTrackIndex: preferredNextUpAudioTrackIndex,
                selectedNextUpSubtitleTrackIndex: preferredNextUpSubtitleTrackIndex,
                nextUpPlaybackDetail: nextUpPlaybackDetail,
                nextUpCatalogDetail: nextUpCatalogDetail,
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
                    await viewModel.selectSeason(season)
                    guard !Task.isCancelled,
                          viewModel.selectedSeason?.id == season.id,
                          let first = viewModel.episodes.first,
                          first.seasonNumber == season.seasonNumber else { return nil }
                    return first.contentId
                },
                onSetSeasonWatched: { season, played in
                    await viewModel.setSeasonWatched(season, played: played)
                },
                onActivateEpisode: { id in
                    if let id {
                        viewModel.activateLoadedSeriesEpisode(id)
                    }
                    activeSeriesEpisodeContentId = id
                },
                onPlayEpisode: { id, fileId, startFromBeginning in
                    let episode = viewModel.seriesEpisodeWindow.episodes.first(where: { $0.contentId == id })
                    // Version and track picks are read at the press, not
                    // after the watch-state read.
                    let playbackFileId = nextUpPlaybackFileId(
                        resolvedFileId: fileId,
                        contentId: id
                    )
                    let audioTrackIndex = preferredNextUpAudioTrackIndex
                    let subtitleTrackIndex = preferredNextUpSubtitleTrackIndex
                    playWithFreshResumePosition(
                        contentId: id,
                        startFromBeginning: startFromBeginning,
                        cached: episode?.userData
                    ) { resumePosition in
                        awaitsPlaybackReturn = true
                        SeriesPlaybackReturnInbox.discardPending()
                        if let playbackFileId {
                            router.navigate(
                                to: .playerWithFile(
                                    contentId: id,
                                    fileId: playbackFileId,
                                    audioTrackIndex: audioTrackIndex,
                                    subtitleTrackIndex: subtitleTrackIndex,
                                    startFromBeginning: startFromBeginning,
                                    resumePosition: resumePosition,
                                    libraryId: libraryId
                                )
                            )
                        } else {
                            router.navigate(
                                to: .player(
                                    contentId: id,
                                    startFromBeginning: startFromBeginning,
                                    resumePosition: resumePosition,
                                    libraryId: libraryId
                                )
                            )
                        }
                    }
                },
                onSetEpisodeWatched: { id, played in
                    await viewModel.setEpisodeWatched(contentId: id, played: played)
                },
                onSetEpisodeFavorite: { id, isFavorite in
                    await viewModel.setEpisodeFavorite(contentId: id, isFavorite: isFavorite)
                },
                onSetEpisodeWatchlist: { id, inWatchlist in
                    await viewModel.setEpisodeWatchlist(contentId: id, inWatchlist: inWatchlist)
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
                onToggleSeriesWatched: { Task { await viewModel.toggleWatched() } },
                onToggleSeasonWatched: { Task { await viewModel.toggleSelectedSeasonWatched() } },
                onPersonTap: { personId in
                    if !personId.isEmpty {
                        router.navigate(to: .personDetail(personId: personId))
                    }
                },
                onNavigateToItem: { id in
                    router.navigate(to: .itemDetail(contentId: id))
                },
                synopsisStatus: viewModel.descriptionTranslationStatus,
                isTranslatingEpisodes: viewModel.isTranslatingSeasonEpisodes,
                onTranslateDescription: translateDescriptionAction
            )
            .task(id: activeSeriesEpisodeContentId) {
                guard let id = activeSeriesEpisodeContentId else { return }
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                await viewModel.refreshSeriesEpisodePersonalLists(contentId: id)
            }
            .task(id: seriesNextUpEpisodeContentId(for: detail)) {
                await loadSeriesNextUpPlaybackDetail(for: detail)
            }
            .task(
                id: "\(detail.contentId):\(viewModel.selectedSeason?.seasonNumber ?? -1):\(carouselRetryGeneration):\(viewModel.episodePagesRevision)",
                priority: .background
            ) {
                await prefetchAdjacentSeriesSeasons(for: detail)
            }
        } else {
            TVMovieDetailView(
                detail: detail,
                isFavorite: viewModel.isFavorite,
                inWatchlist: viewModel.inWatchlist,
                isWatched: viewModel.isWatched,
                selectedVersionFileId: preferredVersionFileId,
                selectedAudioTrackIndex: preferredAudioTrackIndex,
                selectedSubtitleTrackIndex: preferredSubtitleTrackIndex,
                subtitleOverrideCleared: didClearSubtitleOverride,
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
                onPlay: { startFromBeginning in
                    // Version and track picks are read at the press, not
                    // after the watch-state read.
                    let fileId = playbackFileId(for: detail)
                    let audioTrackIndex = preferredAudioTrackIndex
                    let subtitleTrackIndex = preferredSubtitleTrackIndex
                    playWithFreshResumePosition(
                        contentId: contentId,
                        startFromBeginning: startFromBeginning,
                        cached: detail.userData
                    ) { resumePosition in
                        if let fileId {
                            router.navigate(
                                to: .playerWithFile(
                                    contentId: contentId,
                                    fileId: fileId,
                                    audioTrackIndex: audioTrackIndex,
                                    subtitleTrackIndex: subtitleTrackIndex,
                                    startFromBeginning: startFromBeginning,
                                    resumePosition: resumePosition,
                                    libraryId: libraryId
                                )
                            )
                        } else {
                            router.navigate(
                                to: .player(
                                    contentId: contentId,
                                    startFromBeginning: startFromBeginning,
                                    resumePosition: resumePosition,
                                    libraryId: libraryId
                                )
                            )
                        }
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
                onToggleFavorite: { Task { await viewModel.toggleFavorite() } },
                onToggleWatchlist: { Task { await viewModel.toggleWatchlist() } },
                onToggleWatched: { Task { await viewModel.toggleWatched() } },
                onPersonTap: { personId in
                    if !personId.isEmpty {
                        router.navigate(to: .personDetail(personId: personId))
                    }
                },
                onNavigateToItem: { id in
                    router.navigate(to: .itemDetail(contentId: id))
                },
                synopsisStatus: viewModel.descriptionTranslationStatus,
                onTranslateDescription: translateDescriptionAction
            )
        }
    }

    /// The More menu's Translate Description, while the page offers it.
    private var translateDescriptionAction: (() -> Void)? {
        guard viewModel.offersDescriptionTranslation else { return nil }
        return { viewModel.translateDescriptions() }
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
        contentId: String
    ) -> Int? {
        if nextUpPlaybackDetail?.contentId != contentId {
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

    /// Starts playback from the server's current position. The page's
    /// snapshot can be minutes old when another device kept playing, and an
    /// explicit resume position overrides the one the player would read, so
    /// a Resume/Play press re-reads the item's watch state first. The
    /// snapshot (`cached`) is used only when the server is known unreachable,
    /// errors, or takes longer than `DetailResumeState.defaultTimeout`.
    /// Start Over skips the read.
    private func playWithFreshResumePosition(
        contentId id: String,
        startFromBeginning: Bool,
        cached: LeafItemUserData?,
        play: @escaping (_ resumePosition: Double?) -> Void
    ) {
        resumeLookupTask?.cancel()
        resumeLookupTask = nil
        guard !startFromBeginning else {
            play(nil)
            return
        }
        resumeLookupTask = Task {
            let state = await refreshedResumeState(contentId: id)
            guard !Task.isCancelled, isPageVisible else { return }
            resumeLookupTask = nil
            play(state.resumePosition(cached: cached))
        }
    }

    private func refreshedResumeState(contentId id: String) async -> DetailResumeState {
        guard ConnectionMonitor.shared.isServerReachable else { return .unavailable }
        let libraryId = libraryId
        return await DetailResumeState.load {
            try await SiloAPI.shared.watchDetail(contentId: id, libraryId: libraryId).userData
        }
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

    private func seriesNextUpEpisode(for detail: ItemDetail) -> EpisodeListItem? {
        guard detail.type == "series" else { return nil }
        if let activeSeriesEpisodeContentId,
           let active = viewModel.seriesEpisodeWindow.episodes.first(where: {
               $0.contentId == activeSeriesEpisodeContentId
           }) {
            return active
        }
        return viewModel.episodes.preferredResumeEpisode()
    }

    private func seriesNextUpEpisodeContentId(for detail: ItemDetail) -> String? {
        seriesNextUpEpisode(for: detail)?.contentId
    }

    private func loadSeriesNextUpPlaybackDetail(for detail: ItemDetail) async {
        guard let nextUp = seriesNextUpEpisode(for: detail) else {
            nextUpPlaybackDetail = nil
            nextUpCatalogDetail = nil
            preferredNextUpFileId = nil
            preferredNextUpAudioTrackIndex = nil
            preferredNextUpSubtitleTrackIndex = nil
            didClearNextUpSubtitleOverride = false
            return
        }

        let cached: ItemDetail? = ResponseCache.shared.get(
            CacheKey.itemDetail(nextUp.contentId, libraryId: libraryId)
        )
        let usableCached = cached?.versions?.isEmpty == false ? cached : nil
        nextUpPlaybackDetail = usableCached
        nextUpCatalogDetail = nil
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
            // Paint the episode and any cached selectors immediately. Wait
            // only on uncached network work while focus sweeps through cards.
            if activeSeriesEpisodeContentId != nil {
                try await Task.sleep(for: .milliseconds(120))
            }
            // The watch request doesn't depend on the catalog item; run both at once.
            async let watchDetail = try? MetadataRequestPool.shared.watchDetail(
                contentId: nextUp.contentId,
                libraryId: libraryId
            )
            let item = try await MetadataRequestPool.shared.itemDetail(contentId: nextUp.contentId, libraryId: libraryId)
            guard !Task.isCancelled else { return }
            nextUpCatalogDetail = item
            let watch = await watchDetail
            let enriched = applyingPlaybackMetadata(watch, to: item, contentId: nextUp.contentId)
            guard !Task.isCancelled else { return }
            let resolved: ItemDetail?
            if let enriched, enriched.versions?.isEmpty == false {
                ResponseCache.shared.set(enriched, for: CacheKey.itemDetail(nextUp.contentId, libraryId: libraryId))
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
        } catch {
            guard !Task.isCancelled else { return }
            if usableCached == nil {
                nextUpPlaybackDetail = nil
            }
        }

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
        let episodes = viewModel.seriesEpisodeWindow.episodes
        guard let index = episodes.firstIndex(where: {
            $0.contentId == episode.contentId
        }) else { return }

        let neighborIndices = [index - 1, index + 1]
            .filter { episodes.indices.contains($0) }

        for neighborIndex in neighborIndices {
            guard !Task.isCancelled else { return }
            let neighbor = episodes[neighborIndex]
            let cached: ItemDetail? = ResponseCache.shared.get(
                CacheKey.itemDetail(neighbor.contentId, libraryId: libraryId)
            )
            if cached?.versions?.isEmpty == false { continue }

            guard let item = try? await MetadataRequestPool.shared.itemDetail(
                contentId: neighbor.contentId,
                libraryId: libraryId
            ), !Task.isCancelled else { continue }
            guard let enriched = await enrichPlaybackMetadata(
                for: item,
                contentId: neighbor.contentId
            ), enriched.versions?.isEmpty == false else { continue }
            guard !Task.isCancelled else { return }
            ResponseCache.shared.set(
                enriched,
                for: CacheKey.itemDetail(neighbor.contentId, libraryId: libraryId)
            )
        }
    }

    /// Load only the neighboring pages, walking through known empty seasons.
    /// Keep artwork warming to the cards beside each boundary, not every still
    /// in two potentially enormous seasons. The rail loads visible art lazily.
    private func prefetchAdjacentSeriesSeasons(for detail: ItemDetail) async {
        guard detail.type == "series", let selected = viewModel.selectedSeason?.seasonNumber else { return }
        let order = SeriesEpisodeWindow.orderedSeasons(viewModel.seasons)
        guard let selectedIndex = order.firstIndex(where: { $0.seasonNumber == selected }) else { return }
        carouselLoadFailed = false
        viewModel.episodesBySeason = SeriesEpisodeWindow.retainedPages(
            seasons: viewModel.seasons, selected: selected, pages: viewModel.episodesBySeason
        )
        async let previous: Void = prefetchSeriesSeasonNeighbor(
            direction: -1, order: order, selectedIndex: selectedIndex, detail: detail
        )
        async let next: Void = prefetchSeriesSeasonNeighbor(
            direction: 1, order: order, selectedIndex: selectedIndex, detail: detail
        )
        _ = await (previous, next)
    }

    private func prefetchSeriesSeasonNeighbor(
        direction: Int, order: [Season], selectedIndex: Int, detail: ItemDetail
    ) async {
        let selected = order[selectedIndex].seasonNumber
        var index = selectedIndex + direction
        while order.indices.contains(index) {
            guard !Task.isCancelled, viewModel.selectedSeason?.seasonNumber == selected else { return }
            let season = order[index]
            if let page = viewModel.episodesBySeason[season.seasonNumber] {
                if !page.isEmpty { break }
                index += direction
                continue
            }
            let key = CacheKey.itemEpisodes(seriesId: detail.contentId, seasonNumber: season.seasonNumber, libraryId: libraryId)
            do {
                let response: EpisodesResponse
                if let cached: EpisodesResponse = ResponseCache.shared.get(key) {
                    response = cached
                } else if viewModel.episodePagesRevision != 0 {
                    // A watched change dropped these pages. A shared request
                    // sent before the write could still be in flight and would
                    // hand back the old state, so read the server directly.
                    response = try await SiloAPI.shared.episodes(
                        seriesId: detail.contentId, seasonNumber: season.seasonNumber,
                        libraryId: libraryId
                    )
                } else {
                    response = try await MetadataRequestPool.shared.episodes(
                        seriesId: detail.contentId, seasonNumber: season.seasonNumber,
                        libraryId: libraryId
                    )
                }
                guard !Task.isCancelled, viewModel.selectedSeason?.seasonNumber == selected,
                      viewModel.detail?.contentId == detail.contentId else { return }
                ResponseCache.shared.set(response, for: key)
                let sorted = response.episodes.sorted { $0.episodeNumber < $1.episodeNumber }
                // A foreground selection may already have published newer progress.
                if viewModel.episodesBySeason[season.seasonNumber] == nil {
                    viewModel.episodesBySeason[season.seasonNumber] = sorted
                }
                viewModel.episodesBySeason = SeriesEpisodeWindow.retainedPages(
                    seasons: viewModel.seasons, selected: selected, pages: viewModel.episodesBySeason
                )
                let edgeEpisodes = direction < 0 ? Array(sorted.suffix(3)) : Array(sorted.prefix(3))
                PosterImageCache.prefetchArtworkData(edgeEpisodes.compactMap {
                    $0.stillUrl.flatMap(URL.init(string:))
                })
                if !sorted.isEmpty { break }
                index += direction
            } catch {
                guard !Task.isCancelled else { return }
                carouselLoadFailed = true
                break
            }
        }
    }

    private func enrichPlaybackMetadata(for item: ItemDetail, contentId: String) async -> ItemDetail? {
        guard item.type != "series" else { return item }
        let watchDetail = try? await MetadataRequestPool.shared.watchDetail(contentId: contentId, libraryId: libraryId)
        return applyingPlaybackMetadata(watchDetail, to: item, contentId: contentId)
    }

    /// The catalog item with the watch detail's playback fields; nil when the
    /// watch request failed. Series items need no playback fields.
    private func applyingPlaybackMetadata(
        _ watchDetail: WatchDetail?,
        to item: ItemDetail,
        contentId: String
    ) -> ItemDetail? {
        guard item.type != "series" else { return item }
        guard let watchDetail else { return nil }
        ResponseCache.shared.set(watchDetail, for: CacheKey.itemWatchDetail(contentId, libraryId: libraryId))
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
            advisoryAge: item.advisoryAge,
            advisorySource: item.advisorySource,
            genres: item.genres,
            ratingImdb: item.ratingImdb,
            ratingTmdb: item.ratingTmdb,
            ratingRtCritic: item.ratingRtCritic,
            ratingRtAudience: item.ratingRtAudience,
            ratings: item.ratings,
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
            playbackVariants: item.playbackVariants,
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
            extras: item.extras,
            machineTranslatedFields: item.machineTranslatedFields
        )
    }
}

#endif
