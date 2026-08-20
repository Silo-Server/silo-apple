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

    @State private var viewModel: ItemDetailViewModel
    /// Set when the user explicitly resets subtitles to "Auto" this visit:
    /// the server override is cleared with a fire-and-forget DELETE, but the
    /// already-fetched detail still carries the old `effectiveSubtitle*`, so
    /// the selector must stop feeding it to the "Auto: …" preview.
    @State private var didClearSubtitleOverride = false
    @State private var didClearNextUpSubtitleOverride = false
    @State private var nextUpPlaybackDetail: ItemDetail?
    @State private var isLoadingNextUpPlaybackDetail = false
    @State private var didLoadNextUpPlaybackDetail = false
    /// Whether the YouTube app is installed, probed once per page appearance.
    /// Remote trailer cards and the "Find Trailers" action are hidden when it
    /// isn't — tvOS has no in-app web fallback, so content that cannot open
    /// must not be offered. Always false on the simulator, which has no
    /// YouTube app.
    @State private var allowRemoteTrailers = false
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    private static let focusLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "TVFocus"
    )

    init(contentId: String) {
        self.contentId = contentId
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
                Color.clear
            }
        }
        .siloBackground()
        .siloNavigationTitleDisplayMode(.inline)
        .siloNavigationBarBackgroundHidden()
        .onAppear {
            Self.focusLogger.debug("itemDetail.appear contentId=\(contentId, privacy: .public) pathDepth=\(router.path.count, privacy: .public)")
            allowRemoteTrailers = TVTrailerLaunch.isYouTubeAppInstalled()
            seedSubtitleOverrideIfNeeded()
            // Returning from the player (or an extra) resumes a poll that
            // `onDisappear` cancelled — without re-POSTing, since the server
            // already spent the item's weekly slot. Precedent:
            // `PersonDetailView.resumeMetadataRefreshIfNeeded`.
            viewModel.resumeTrailerFetchIfNeeded()
        }
        .onDisappear {
            Self.focusLogger.debug("itemDetail.disappear contentId=\(contentId, privacy: .public) pathDepth=\(router.path.count, privacy: .public)")
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
                allowRemoteTrailers = TVTrailerLaunch.isYouTubeAppInstalled()
                TVTrailerReturnStore.shared.clear()
            }
        }
        .task(id: contentId) {
            didClearSubtitleOverride = false
            didClearNextUpSubtitleOverride = false
            nextUpPlaybackDetail = nil
            isLoadingNextUpPlaybackDetail = false
            didLoadNextUpPlaybackDetail = false
            await viewModel.loadDetail(contentId: contentId)
            seedSubtitleOverrideIfNeeded()
        }
    }

    // Selection state lives on the cached view model so a pushed player route
    // or a temporary navigation away from this item cannot discard it. These
    // nonmutating proxies keep the existing selector callbacks concise.
    private var preferredVersionFileId: Int? {
        get { viewModel.preferredVersionFileId }
        nonmutating set { viewModel.preferredVersionFileId = newValue }
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
                        : DetailPlaybackFormatting.playableResumePosition(
                            position: episode?.userData?.positionSeconds,
                            duration: episode?.userData?.durationSeconds
                        )
                    if let fileId = nextUpSelection(versionFileId: preferredNextUpFileId)
                        .playbackFileId(resolvedFileId: fileId) {
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
                onSetEpisodeWatched: setEpisodeWatched,
                onSetEpisodeFavorite: setEpisodeFavorite,
                onSelectSeason: { season in
                    guard season.id != detail.contentId else { return }
                    router.navigate(to: .itemDetail(contentId: season.contentId))
                },
                onSelectNextUpVersion: selectNextUpVersion,
                onSelectNextUpAudioTrack: selectNextUpAudioTrack,
                onSelectNextUpSubtitleTrack: selectNextUpSubtitleTrack,
                onToggleFavorite: { Task { await viewModel.toggleFavorite() } },
                onToggleWatchlist: { Task { await viewModel.toggleWatchlist() } },
                onToggleWatched: { Task { await viewModel.toggleWatched() } },
                onPersonTap: personTap,
                onNavigateToItem: navigateToItem,
                belowSynopsis: { descriptionTranslation(for: detail.contentId) }
            )
            .task(id: nextUpEpisode(for: detail)?.contentId) {
                await loadNextUpPlaybackDetail(for: detail)
            }
        } else if detail.type == "series" {
            TVSeriesDetailView(
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
                    Task { await viewModel.selectSeason(season) }
                },
                onPlayEpisode: { id, fileId, startFromBeginning in
                    let resumePosition = startFromBeginning
                        ? nil
                        : viewModel.episodes.first(where: { $0.contentId == id })?.userData?.positionSeconds
                    if let fileId = nextUpSelection(versionFileId: preferredNextUpFileId)
                        .playbackFileId(resolvedFileId: fileId) {
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
                onSetEpisodeWatched: setEpisodeWatched,
                onSetEpisodeFavorite: setEpisodeFavorite,
                onSelectNextUpVersion: selectNextUpVersion,
                onSelectNextUpAudioTrack: selectNextUpAudioTrack,
                onSelectNextUpSubtitleTrack: selectNextUpSubtitleTrack,
                onToggleFavorite: { Task { await viewModel.toggleFavorite() } },
                onToggleWatchlist: { Task { await viewModel.toggleWatchlist() } },
                onToggleWatched: { Task { await viewModel.toggleWatched() } },
                onPersonTap: personTap,
                onNavigateToItem: navigateToItem,
                belowSynopsis: { descriptionTranslation(for: detail.contentId) }
            )
            .task(id: nextUpEpisode(for: detail)?.contentId) {
                await loadNextUpPlaybackDetail(for: detail)
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
                seasons: viewModel.seasons,
                selectedSeason: viewModel.selectedSeason,
                seasonEpisodes: viewModel.episodes,
                episodeFavoriteStates: viewModel.episodeFavoriteStates,
                isLoadingEpisodes: viewModel.isLoadingEpisodes,
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
                    let resumePosition = startFromBeginning
                        ? nil
                        : DetailPlaybackFormatting.playableResumePosition(for: detail)
                    if let fileId = selection(for: detail, versionFileId: preferredVersionFileId).playbackFileId {
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
                    let updated = selection(for: detail, versionFileId: fileId)
                    preferredAudioTrackIndex = updated.sanitizedAudioIndex(preferredAudioTrackIndex)
                    preferredSubtitleTrackIndex = updated.sanitizedSubtitleIndex(preferredSubtitleTrackIndex)
                },
                onSelectAudioTrack: { index in
                    let current = selection(for: detail, versionFileId: preferredVersionFileId)
                    preferredAudioTrackIndex = current.sanitizedAudioIndex(index)
                    TrackSelectionPersistence.persistAudio(
                        prefKey: prefKey(for: detail),
                        version: current.effectiveVersion,
                        requested: index,
                        sanitized: preferredAudioTrackIndex
                    )
                },
                onSelectSubtitleTrack: { index in
                    didClearSubtitleOverride = (index == nil)
                    viewModel.preferredSubtitleTrackWasManuallySelected = true
                    let current = selection(for: detail, versionFileId: preferredVersionFileId)
                    preferredSubtitleTrackIndex = current.sanitizedSubtitleIndex(index)
                    TrackSelectionPersistence.persistSubtitle(
                        prefKey: prefKey(for: detail),
                        version: current.effectiveVersion,
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
                onPersonTap: personTap,
                onNavigateToItem: navigateToItem,
                onEpisodeTap: { id in
                    let episode = viewModel.episodes.first { $0.contentId == id }
                    let isCurrentEpisode = id == detail.contentId
                    let resumePosition = DetailPlaybackFormatting.playableResumePosition(
                        position: episode?.userData?.positionSeconds,
                        duration: episode?.userData?.durationSeconds
                    )

                    // Present independently of the navigation stack. Once
                    // playback reports that it is actually running, the
                    // hidden detail route is replaced with this episode so
                    // dismissing the player returns to what was just played.
                    router.presentPlayer(
                        contentId: id,
                        fileId: isCurrentEpisode
                            ? selection(for: detail, versionFileId: preferredVersionFileId).playbackFileId
                            : nil,
                        audioTrackIndex: isCurrentEpisode ? preferredAudioTrackIndex : nil,
                        subtitleTrackIndex: isCurrentEpisode ? preferredSubtitleTrackIndex : nil,
                        startFromBeginning: false,
                        resumePosition: resumePosition,
                        returnToContentId: isCurrentEpisode ? nil : id
                    )
                },
                onSetEpisodeWatched: setEpisodeWatched,
                onSetEpisodeFavorite: setEpisodeFavorite,
                belowSynopsis: { descriptionTranslation(for: detail.contentId) }
            )
        }
    }

    // MARK: - Shared detail-arm callbacks
    //
    // The season / series / movie arms above hand these to their layout
    // views verbatim; they live here as methods so each arm passes a
    // reference instead of repeating the body.

    private func selectNextUpVersion(_ fileId: Int?) {
        preferredNextUpFileId = fileId
        let updated = nextUpSelection(versionFileId: fileId)
        preferredNextUpAudioTrackIndex = updated.sanitizedAudioIndex(preferredNextUpAudioTrackIndex)
        preferredNextUpSubtitleTrackIndex = updated.sanitizedSubtitleIndex(preferredNextUpSubtitleTrackIndex)
    }

    private func selectNextUpAudioTrack(_ index: Int?) {
        let current = nextUpSelection(versionFileId: preferredNextUpFileId)
        preferredNextUpAudioTrackIndex = current.sanitizedAudioIndex(index)
        TrackSelectionPersistence.persistAudio(
            prefKey: prefKey(for: nextUpPlaybackDetail),
            version: current.effectiveVersion,
            requested: index,
            sanitized: preferredNextUpAudioTrackIndex
        )
    }

    private func selectNextUpSubtitleTrack(_ index: Int?) {
        didClearNextUpSubtitleOverride = (index == nil)
        let current = nextUpSelection(versionFileId: preferredNextUpFileId)
        preferredNextUpSubtitleTrackIndex = current.sanitizedSubtitleIndex(index)
        TrackSelectionPersistence.persistSubtitle(
            prefKey: prefKey(for: nextUpPlaybackDetail),
            version: current.effectiveVersion,
            requested: index,
            sanitized: preferredNextUpSubtitleTrackIndex,
            showForced: nil
        )
    }

    private func personTap(_ personId: String) {
        if let pid = Int(personId) {
            router.navigate(to: .personDetail(personId: pid))
        }
    }

    private func navigateToItem(_ id: String) {
        router.navigate(to: .itemDetail(contentId: id))
    }

    private func setEpisodeWatched(_ id: String, _ played: Bool) async -> Bool {
        await viewModel.setEpisodeWatched(contentId: id, played: played)
    }

    private func setEpisodeFavorite(_ id: String, _ isFavorite: Bool) async -> Bool {
        await viewModel.setEpisodeFavorite(contentId: id, isFavorite: isFavorite)
    }

    @ViewBuilder
    private func descriptionTranslation(for detailContentId: String) -> some View {
        DescriptionTranslationView(viewModel: viewModel, contentId: detailContentId)
            .id(detailContentId)
    }

    /// This visit's picks for the item on screen. The policy lives in
    /// `DetailPlaybackSelection`; the screen owns only the storage (here the
    /// cached view model, so a pushed player route cannot discard it).
    private func selection(for detail: ItemDetail?, versionFileId: Int?) -> DetailPlaybackSelection {
        DetailPlaybackSelection(
            detail: detail,
            versionFileId: versionFileId,
            audioTrackIndex: preferredAudioTrackIndex,
            subtitleTrackIndex: preferredSubtitleTrackIndex
        )
    }

    /// Same, for the series/season next-up episode's own picks.
    private func nextUpSelection(versionFileId: Int?) -> DetailPlaybackSelection {
        DetailPlaybackSelection(
            detail: nextUpPlaybackDetail,
            versionFileId: versionFileId,
            audioTrackIndex: preferredNextUpAudioTrackIndex,
            subtitleTrackIndex: preferredNextUpSubtitleTrackIndex
        )
    }

    // MARK: - Track-choice persistence
    //
    // Selector picks are remembered server-side (web-app parity):
    // episodes key by series id so one choice covers the series, movies
    // by their own content id. "Auto" (nil) clears the override so the
    // library/profile cascade applies again.

    /// Applies `DetailPlaybackFormatting.seededSubtitleIndex` to this
    /// screen's selector state.
    private func seedSubtitleOverrideIfNeeded() {
        let seeded = DetailPlaybackFormatting.seededSubtitleIndex(
            current: preferredSubtitleTrackIndex,
            wasManuallySelected: viewModel.preferredSubtitleTrackWasManuallySelected,
            detail: viewModel.detail,
            version: selection(
                for: viewModel.detail,
                versionFileId: preferredVersionFileId
            ).effectiveVersion
        )
        if seeded != preferredSubtitleTrackIndex {
            preferredSubtitleTrackIndex = seeded
        }
    }

    private func prefKey(for detail: ItemDetail?) -> String? {
        TrackSelectionPersistence.prefKey(seriesId: detail?.seriesId, contentId: detail?.contentId)
    }

    private func nextUpEpisode(for detail: ItemDetail) -> EpisodeListItem? {
        guard detail.type == "season" || detail.type == "series" else { return nil }
        return EpisodeRailFormatting.nextUp(in: viewModel.episodes)
    }

    private func loadNextUpPlaybackDetail(for detail: ItemDetail) async {
        guard let nextUp = nextUpEpisode(for: detail) else {
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
            let item = try await SiloAPI.shared.itemDetail(contentId: nextUp.contentId)
            guard !Task.isCancelled else { return }
            let enriched = await viewModel.enrichPlaybackMetadata(for: item, contentId: nextUp.contentId)
            guard !Task.isCancelled else { return }
            nextUpPlaybackDetail = enriched
            preferredNextUpSubtitleTrackIndex = DetailPlaybackFormatting.launchPreferredSubtitleIndex(
                version: DetailPlaybackSelection(detail: enriched, versionFileId: nil).effectiveVersion,
                signature: enriched.effectiveSubtitleTrackSignature,
                mode: enriched.effectiveSubtitleMode,
                usesDeviceSettings: PlayerSettings.shared.subtitleMatchesSystemAppearance
            )
            didLoadNextUpPlaybackDetail = true
        } catch {
            guard !Task.isCancelled else { return }
            nextUpPlaybackDetail = nil
            didLoadNextUpPlaybackDetail = true
        }
        isLoadingNextUpPlaybackDetail = false
    }
}
#endif
