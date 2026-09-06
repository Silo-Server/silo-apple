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
    @State private var hasStartedDetailLoad = false
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
    @State private var carouselLoadFailed = false
    @State private var carouselRetryGeneration = 0
    /// Serializes rapid season-tab intent before it reaches the async view
    /// model. A superseded task must never begin after its replacement and
    /// make an older season the selected one.
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

    init(contentId: String, seed: TVItemDetailRouteSeed? = nil) {
        self.contentId = contentId
        self.seed = seed
        // Resolve the cached view model eagerly so the first `body`
        // evaluation can render cached content without a blank frame.
        _viewModel = State(initialValue: ItemDetailCache.shared.viewModel(for: contentId))
    }

    var body: some View {
        Group {
            // Skip the spinner on cache hits — `detail != nil` means we
            // already have something to paint and the `.task` below is
            // refreshing it in the background.
            if !hasStartedDetailLoad, seed?.episodeContext?.seriesContentId == contentId {
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
            let navigationContext = !hasStartedDetailLoad
                && seed?.episodeContext?.seriesContentId == contentId
                ? seed?.episodeContext : nil
            didClearSubtitleOverride = false
            didClearNextUpSubtitleOverride = false
            nextUpPlaybackDetail = nil
            activeSeriesEpisodeContentId = navigationContext?.episodeContentId
            episodeSeriesDetail = nil
            failedSeriesRedirectEpisodeContentId = nil
            isLoadingNextUpPlaybackDetail = false
            didLoadNextUpPlaybackDetail = false
            if let navigationContext {
                viewModel.prepareInitialSeriesSeason(
                    navigationContext.seasonNumber, seriesId: contentId
                )
            } else {
                viewModel.initialResumeSeasonNumber = viewModel.selectedSeason?.seasonNumber
            }
            hasStartedDetailLoad = true
            await viewModel.loadDetail(contentId: contentId)
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
           let completedIndex = viewModel.seriesEpisodeWindow.episodes.firstIndex(where: {
               $0.contentId == activeSeriesEpisodeContentId
           }),
           let next = viewModel.seriesEpisodeWindow.episodes.dropFirst(completedIndex + 1).first(where: {
               !($0.userData?.played ?? false)
           }) {
            viewModel.activateLoadedSeriesEpisode(next.contentId)
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
                episodeWindow: viewModel.seriesEpisodeWindow,
                carouselLoadFailed: carouselLoadFailed,
                onLoadMoreEpisodes: { _ in
                    // Neighbors already load as focus approaches. Repeated
                    // edge presses must not cancel and restart that request.
                    if carouselLoadFailed { carouselRetryGeneration &+= 1 }
                },
                activeEpisodeContentId: activeSeriesEpisodeContentId,
                episodeFavoriteStates: viewModel.episodeFavoriteStates,
                isLoadingEpisodes: viewModel.isLoadingEpisodes,
                selectedNextUpFileId: preferredNextUpFileId,
                selectedNextUpAudioTrackIndex: preferredNextUpAudioTrackIndex,
                selectedNextUpSubtitleTrackIndex: preferredNextUpSubtitleTrackIndex,
                nextUpPlaybackDetail: nextUpPlaybackDetail,
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
                onActivateEpisode: { id in
                    if let id {
                        viewModel.activateLoadedSeriesEpisode(id)
                    }
                    activeSeriesEpisodeContentId = id
                },
                onPlayEpisode: { id, fileId, startFromBeginning in
                    let episode = viewModel.seriesEpisodeWindow.episodes.first(where: { $0.contentId == id })
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
            .task(id: activeSeriesEpisodeContentId) {
                guard let id = activeSeriesEpisodeContentId else { return }
                do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
                await viewModel.refreshSeriesEpisodeFavorite(contentId: id)
            }
            .task(id: seriesNextUpEpisodeContentId(for: detail)) {
                await loadSeriesNextUpPlaybackDetail(for: detail)
            }
            .task(
                id: "\(detail.contentId):\(viewModel.selectedSeason?.seasonNumber ?? -1):\(carouselRetryGeneration)",
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
    ) -> TVItemDetailRouteSeed.EpisodeContext? {
        guard detail.type == "episode",
              let rawSeriesId = detail.seriesId,
              let seasonNumber = detail.seasonNumber else { return nil }

        let seriesId = rawSeriesId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seriesId.isEmpty, seriesId != detail.contentId else { return nil }

        return TVItemDetailRouteSeed.EpisodeContext(
            seriesContentId: seriesId,
            seasonNumber: seasonNumber,
            episodeContentId: detail.contentId
        )
    }

    private func redirectEpisodeToSeries(
        _ destination: TVItemDetailRouteSeed.EpisodeContext
    ) async {
        let cacheKey = CacheKey.itemDetail(destination.seriesContentId)
        if let cached: ItemDetail = ResponseCache.shared.get(cacheKey),
           cached.type == "series" {
            routeToSeries(destination, series: cached)
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
            routeToSeries(destination, series: series)
        } catch {
            guard !Task.isCancelled,
                  contentId == destination.episodeContentId else { return }
            failedSeriesRedirectEpisodeContentId = destination.episodeContentId
        }
    }

    private func routeToSeries(
        _ destination: TVItemDetailRouteSeed.EpisodeContext,
        series: ItemDetail
    ) {
        guard contentId == destination.episodeContentId else { return }
        router.replaceCurrent(
            with: .itemDetail(
                contentId: destination.seriesContentId,
                tvSeed: TVItemDetailRouteSeed(series, episodeContext: destination)
            )
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
           let active = viewModel.seriesEpisodeWindow.episodes.first(where: {
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
            // Paint the episode and any cached selectors immediately. Wait
            // only on uncached network work while focus sweeps through cards.
            if activeSeriesEpisodeContentId != nil {
                try await Task.sleep(for: .milliseconds(120))
            }
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
            let key = CacheKey.itemEpisodes(seriesId: detail.contentId, seasonNumber: season.seasonNumber)
            do {
                let response: EpisodesResponse
                if let cached: EpisodesResponse = ResponseCache.shared.get(key) {
                    response = cached
                } else {
                    response = try await MetadataRequestPool.shared.episodes(
                        seriesId: detail.contentId, seasonNumber: season.seasonNumber
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
                PosterImageCache.prefetchCardArtwork(edgeEpisodes.compactMap {
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

#endif
