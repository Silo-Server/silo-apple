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
    /// The item currently painted by this route. Episode selection changes
    /// this value without changing the navigation path, so the detail shell,
    /// season selector, and episode rail remain mounted.
    @State private var activeContentId: String
    /// Set when the user explicitly resets subtitles to "Auto" this visit:
    /// the server override is cleared with a fire-and-forget DELETE, but the
    /// already-fetched detail still carries the old `effectiveSubtitle*`, so
    /// the selector must stop feeding it to the "Auto: …" preview.
    @State private var didClearSubtitleOverride = false
    @State private var didClearNextUpSubtitleOverride = false
    @State private var nextUpPlaybackDetail: ItemDetail?
    @State private var isLoadingNextUpPlaybackDetail = false
    @State private var didLoadNextUpPlaybackDetail = false
    @State private var familyItemLoadTask: Task<Void, Never>?
    @State private var familyItemPrefetchTask: Task<Void, Never>?
    @State private var familyItemPrefetchContentId: String?
    @State private var seasonPrefetchTask: Task<Void, Never>?
    @State private var seasonPrefetchNumber: Int?
    @State private var seasonSelectionTask: Task<Void, Never>?
    @State private var skipNextActiveContentReload = false
    /// Whether the YouTube app is installed, probed once per page appearance.
    /// Remote trailer cards and the "Find Trailers" action are hidden when it
    /// isn't — tvOS has no in-app web fallback, so content that cannot open
    /// must not be offered. Always false on the simulator, which has no
    /// YouTube app.
    @State private var allowRemoteTrailers = false
    @Environment(AppRouter.self) private var router
    @Environment(\.scenePhase) private var scenePhase
    private static let focusLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "TVFocus"
    )

    init(contentId: String) {
        self.contentId = contentId
        // Resolve the cached view model eagerly so the first `body`
        // evaluation can render cached content without a blank frame.
        _viewModel = State(
            initialValue: ItemDetailCache.shared.viewModel(for: contentId)
        )
        _activeContentId = State(initialValue: contentId)
    }

    var body: some View {
        Group {
            // Skip the spinner on cache hits — `detail != nil` means we
            // already have something to paint and the `.task` below is
            // refreshing it in the background.
            if let detail = viewModel.detail {
                content(for: detail)
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: {
                    Task { await viewModel.loadDetail(contentId: activeContentId) }
                })
            } else {
                Color.clear
            }
        }
        .continuumBackground()
        .continuumNavigationTitleDisplayMode(.inline)
        .continuumNavigationBarBackgroundHidden()
        .onAppear {
            Self.focusLogger.debug("itemDetail.appear contentId=\(activeContentId, privacy: .public) pathDepth=\(router.path.count, privacy: .public)")
            allowRemoteTrailers = TVTrailerLaunch.isYouTubeAppInstalled()
            seedSubtitleOverrideIfNeeded()
            // Returning from the player (or an extra) resumes a poll that
            // `onDisappear` cancelled — without re-POSTing, since the server
            // already spent the item's weekly slot. Precedent:
            // `PersonDetailView.resumeMetadataRefreshIfNeeded`.
            viewModel.resumeTrailerFetchIfNeeded()
        }
        .onDisappear {
            Self.focusLogger.debug("itemDetail.disappear contentId=\(activeContentId, privacy: .public) pathDepth=\(router.path.count, privacy: .public)")
            familyItemLoadTask?.cancel()
            familyItemLoadTask = nil
            familyItemPrefetchTask?.cancel()
            familyItemPrefetchTask = nil
            familyItemPrefetchContentId = nil
            seasonPrefetchTask?.cancel()
            seasonPrefetchTask = nil
            seasonPrefetchNumber = nil
            seasonSelectionTask?.cancel()
            seasonSelectionTask = nil
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
        .task(id: activeContentId) {
            didClearSubtitleOverride = false
            didClearNextUpSubtitleOverride = false
            nextUpPlaybackDetail = nil
            isLoadingNextUpPlaybackDetail = false
            didLoadNextUpPlaybackDetail = false
            if skipNextActiveContentReload {
                skipNextActiveContentReload = false
            } else {
                await viewModel.loadDetail(
                    contentId: activeContentId,
                    includeRelatedStructure: activeContentId == contentId
                )
            }
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
            TVTrailerReturnStore.shared.saveHandoff(contentId: activeContentId)
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
        } else {
            let usesNextUpPlayback = isSeriesContainer(detail)
            TVMovieDetailView(
                detail: detail,
                playbackDetail: usesNextUpPlayback ? nextUpPlaybackDetail : nil,
                playTitleOverride: usesNextUpPlayback ? familyPlayTitle(for: detail) : nil,
                isLoadingPlaybackDetail: usesNextUpPlayback && isLoadingNextUpPlaybackDetail,
                didLoadPlaybackDetail: usesNextUpPlayback ? didLoadNextUpPlaybackDetail : true,
                isFavorite: viewModel.isFavorite,
                inWatchlist: viewModel.inWatchlist,
                isWatched: viewModel.isWatched,
                selectedVersionFileId: usesNextUpPlayback
                    ? preferredNextUpFileId
                    : preferredVersionFileId,
                selectedAudioTrackIndex: usesNextUpPlayback
                    ? preferredNextUpAudioTrackIndex
                    : preferredAudioTrackIndex,
                selectedSubtitleTrackIndex: usesNextUpPlayback
                    ? preferredNextUpSubtitleTrackIndex
                    : preferredSubtitleTrackIndex,
                subtitleOverrideCleared: usesNextUpPlayback
                    ? didClearNextUpSubtitleOverride
                    : didClearSubtitleOverride,
                seasons: viewModel.seasons,
                selectedSeason: viewModel.selectedSeason,
                seasonEpisodes: viewModel.episodes,
                episodeFavoriteStates: viewModel.episodeFavoriteStates,
                isLoadingEpisodes: viewModel.isLoadingEpisodes,
                trailerEntries: trailerEntries(for: detail),
                onSelectTrailer: playTrailer,
                supportsTrailerFetch: viewModel.supportsTrailerFetch && allowRemoteTrailers,
                onFindTrailers: {
                    viewModel.startTrailerFetch(
                        remoteVideosDisplayable: allowRemoteTrailers
                    )
                },
                trailerFetchStatus: viewModel.trailerFetch.statusMessage,
                isFetchingTrailers: viewModel.trailerFetch.isFetching,
                onTrailerStatusShown: { viewModel.trailerFetch.acknowledge() },
                onPlay: { startFromBeginning in
                    playPrimaryItem(detail: detail, startFromBeginning: startFromBeginning)
                },
                onSelectVersion: { fileId in
                    selectVersion(fileId, for: detail)
                },
                onSelectAudioTrack: { index in
                    selectAudioTrack(index, for: detail)
                },
                onSelectSubtitleTrack: { index in
                    selectSubtitleTrack(index, for: detail)
                },
                onSelectSeason: { season in
                    guard season.id != viewModel.selectedSeason?.id else { return }
                    selectSeason(season)
                },
                onFocusedSeasonChange: prefetchSeasonEpisodes,
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
                    switchFamilyItem(to: id)
                },
                onFocusedEpisodeChange: prefetchFamilyItem,
                onPlayFocusedEpisode: { id in
                    playEpisodeFromRail(id, activeDetail: detail)
                },
                currentEpisodeContentId: detail.type == "episode"
                    ? detail.contentId
                    : familyNextUpEpisode(for: detail)?.contentId,
                onSetEpisodeWatched: { id, played in
                    await viewModel.setEpisodeWatched(contentId: id, played: played)
                },
                onSetEpisodeFavorite: { id, isFavorite in
                    await viewModel.setEpisodeFavorite(contentId: id, isFavorite: isFavorite)
                },
                belowSynopsis: {
                    DescriptionTranslationView(
                        viewModel: viewModel,
                        contentId: detail.contentId
                    )
                    .id(detail.contentId)
                }
            )
            .task(id: familyNextUpEpisode(for: detail)?.contentId) {
                if detail.type == "season" {
                    await loadSeasonNextUpPlaybackDetail(for: detail)
                } else if detail.type == "series" {
                    await loadSeriesNextUpPlaybackDetail(for: detail)
                } else {
                    clearNextUpPlaybackState()
                }
            }
        }
    }

    private func isSeriesContainer(_ detail: ItemDetail) -> Bool {
        detail.type == "series" || detail.type == "season"
    }

    private func familyNextUpEpisode(for detail: ItemDetail) -> EpisodeListItem? {
        if detail.type == "series" {
            return seriesNextUpEpisode(for: detail)
        }
        if detail.type == "season" {
            return seasonNextUpEpisode(for: detail)
        }
        return nil
    }

    private func familyPlayTitle(for detail: ItemDetail) -> String? {
        guard let episode = familyNextUpEpisode(for: detail) else { return nil }
        let prefix = episode.userData?.isInProgress == true ? "Resume" : "Play"
        if detail.type == "series" {
            return "\(prefix) S\(episode.seasonNumber) · E\(episode.episodeNumber)"
        }
        return "\(prefix) E\(episode.episodeNumber)"
    }

    private func clearNextUpPlaybackState() {
        nextUpPlaybackDetail = nil
        isLoadingNextUpPlaybackDetail = false
        didLoadNextUpPlaybackDetail = false
        preferredNextUpFileId = nil
        preferredNextUpAudioTrackIndex = nil
        preferredNextUpSubtitleTrackIndex = nil
        didClearNextUpSubtitleOverride = false
    }

    private func prefetchSeasonEpisodes(_ season: Season?) {
        seasonPrefetchTask?.cancel()
        seasonPrefetchTask = nil
        seasonPrefetchNumber = nil

        guard let season,
              season.seasonNumber != viewModel.selectedSeason?.seasonNumber
        else { return }

        let source = viewModel
        seasonPrefetchNumber = season.seasonNumber
        seasonPrefetchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled, viewModel === source else { return }
            await source.prefetchEpisodes(for: season)
        }
    }

    private func selectSeason(_ season: Season) {
        let source = viewModel
        let matchingPrefetch = seasonPrefetchNumber == season.seasonNumber
            ? seasonPrefetchTask
            : nil

        if matchingPrefetch == nil {
            seasonPrefetchTask?.cancel()
        }
        seasonSelectionTask?.cancel()
        seasonSelectionTask = Task { @MainActor in
            if let matchingPrefetch {
                await matchingPrefetch.value
            }
            guard !Task.isCancelled, viewModel === source else { return }
            await source.selectSeason(season)
        }
    }

    private func prefetchFamilyItem(_ destinationContentId: String?) {
        familyItemPrefetchTask?.cancel()
        familyItemPrefetchTask = nil
        familyItemPrefetchContentId = nil

        guard let destinationContentId,
              destinationContentId != activeContentId
        else { return }

        let destination = ItemDetailCache.shared.viewModel(for: destinationContentId)
        if destination.detail?.contentId == destinationContentId { return }

        familyItemPrefetchContentId = destinationContentId
        familyItemPrefetchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            await destination.loadDetail(
                contentId: destinationContentId,
                includeRelatedStructure: false
            )
        }
    }

    private func switchFamilyItem(to destinationContentId: String) {
        guard destinationContentId != activeContentId else { return }

        let source = viewModel
        let matchingPrefetch = familyItemPrefetchContentId == destinationContentId
            ? familyItemPrefetchTask
            : nil
        if matchingPrefetch == nil {
            familyItemPrefetchTask?.cancel()
        }
        familyItemLoadTask?.cancel()
        familyItemLoadTask = Task { @MainActor in
            let destination = ItemDetailCache.shared.viewModel(for: destinationContentId)
            if let matchingPrefetch {
                await matchingPrefetch.value
            }
            if destination.detail?.contentId != destinationContentId {
                await destination.loadDetail(
                    contentId: destinationContentId,
                    includeRelatedStructure: false
                )
            }
            destination.adoptSeriesBrowsingContext(from: source)
            guard !Task.isCancelled,
                  let destinationDetail = destination.detail,
                  destinationDetail.contentId == destinationContentId,
                  destinationDetail.type == "series"
                    || destinationDetail.type == "season"
                    || destinationDetail.type == "episode",
                  viewModel === source else { return }

            TVDetailFocusDiagnostics.record(
                "family.destinationPrepared",
                target: "episodeCard",
                action: "swapInPlace",
                state: "episode=selected",
                essential: true
            )

            skipNextActiveContentReload = true
            viewModel = destination
            activeContentId = destinationContentId
        }
    }

    private func playPrimaryItem(detail: ItemDetail, startFromBeginning: Bool) {
        if let episode = familyNextUpEpisode(for: detail) {
            let resumePosition = startFromBeginning
                ? nil
                : playableResumePosition(
                    position: episode.userData?.positionSeconds,
                    duration: episode.userData?.durationSeconds
                )
            router.presentPlayer(
                contentId: episode.contentId,
                fileId: nextUpPlaybackFileId(resolvedFileId: preferredNextUpFileId),
                audioTrackIndex: preferredNextUpAudioTrackIndex,
                subtitleTrackIndex: preferredNextUpSubtitleTrackIndex,
                startFromBeginning: startFromBeginning,
                resumePosition: resumePosition
            )
            return
        }

        guard detail.type == "movie" || detail.type == "episode" else { return }
        let resumePosition = startFromBeginning ? nil : playableResumePosition(for: detail)
        let fileId = playbackFileId(for: detail)

        if detail.type == "episode" {
            router.presentPlayer(
                contentId: detail.contentId,
                fileId: fileId,
                audioTrackIndex: preferredAudioTrackIndex,
                subtitleTrackIndex: preferredSubtitleTrackIndex,
                startFromBeginning: startFromBeginning,
                resumePosition: resumePosition
            )
        } else if let fileId {
            router.navigate(
                to: .playerWithFile(
                    contentId: detail.contentId,
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
                    contentId: detail.contentId,
                    startFromBeginning: startFromBeginning,
                    resumePosition: resumePosition
                )
            )
        }
    }

    private func playEpisodeFromRail(_ contentId: String, activeDetail: ItemDetail) {
        let episode = viewModel.episodes.first { $0.contentId == contentId }
        let isActiveEpisode = activeDetail.type == "episode"
            && activeDetail.contentId == contentId
        router.presentPlayer(
            contentId: contentId,
            fileId: isActiveEpisode ? playbackFileId(for: activeDetail) : nil,
            audioTrackIndex: isActiveEpisode ? preferredAudioTrackIndex : nil,
            subtitleTrackIndex: isActiveEpisode ? preferredSubtitleTrackIndex : nil,
            startFromBeginning: false,
            resumePosition: playableResumePosition(
                position: episode?.userData?.positionSeconds,
                duration: episode?.userData?.durationSeconds
            )
        )
    }

    private func selectVersion(_ fileId: Int?, for detail: ItemDetail) {
        if isSeriesContainer(detail) {
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
        } else {
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
        }
    }

    private func selectAudioTrack(_ index: Int?, for detail: ItemDetail) {
        if isSeriesContainer(detail) {
            preferredNextUpAudioTrackIndex = sanitizedAudioTrackIndex(
                for: nextUpPlaybackDetail,
                versionFileId: preferredNextUpFileId,
                candidate: index
            )
            persistAudioSelection(
                prefKey: prefKey(for: nextUpPlaybackDetail),
                version: effectiveVersion(
                    for: nextUpPlaybackDetail,
                    versionFileId: preferredNextUpFileId
                ),
                requested: index,
                sanitized: preferredNextUpAudioTrackIndex
            )
        } else {
            preferredAudioTrackIndex = sanitizedAudioTrackIndex(
                for: detail,
                versionFileId: preferredVersionFileId,
                candidate: index
            )
            persistAudioSelection(
                prefKey: prefKey(for: detail),
                version: effectiveVersion(
                    for: detail,
                    versionFileId: preferredVersionFileId
                ),
                requested: index,
                sanitized: preferredAudioTrackIndex
            )
        }
    }

    private func selectSubtitleTrack(_ index: Int?, for detail: ItemDetail) {
        if isSeriesContainer(detail) {
            didClearNextUpSubtitleOverride = index == nil
            preferredNextUpSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                for: nextUpPlaybackDetail,
                versionFileId: preferredNextUpFileId,
                candidate: index
            )
            persistSubtitleSelection(
                prefKey: prefKey(for: nextUpPlaybackDetail),
                version: effectiveVersion(
                    for: nextUpPlaybackDetail,
                    versionFileId: preferredNextUpFileId
                ),
                requested: index,
                sanitized: preferredNextUpSubtitleTrackIndex,
                showForced: nil
            )
        } else {
            didClearSubtitleOverride = index == nil
            viewModel.preferredSubtitleTrackWasManuallySelected = true
            preferredSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                for: detail,
                versionFileId: preferredVersionFileId,
                candidate: index
            )
            persistSubtitleSelection(
                prefKey: prefKey(for: detail),
                version: effectiveVersion(
                    for: detail,
                    versionFileId: preferredVersionFileId
                ),
                requested: index,
                sanitized: preferredSubtitleTrackIndex,
                showForced: nil
            )
        }
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

    /// Next-up analogue of `playbackFileId(for:)`. `resolvedFileId` is the
    /// fileId the season/series view already computed from the selected
    /// version (non-nil only when the user changed Version). When that is
    /// nil but an audio/subtitle override is set, resolve the next-up
    /// effective version's fileId so the chosen tracks can still be carried
    /// through `.playerWithFile(...)` instead of being dropped by `.player`.
    private func nextUpPlaybackFileId(resolvedFileId: Int?) -> Int? {
        if let resolvedFileId {
            return resolvedFileId
        }
        if preferredNextUpAudioTrackIndex != nil || preferredNextUpSubtitleTrackIndex != nil {
            return effectiveVersion(
                for: nextUpPlaybackDetail,
                versionFileId: preferredNextUpFileId
            )?.fileId
        }
        return nil
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
        let available = version.subtitleTracks?.compactMap(\.index) ?? []
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
            let item = try await ContinuumAPI.shared.itemDetail(contentId: nextUp.contentId)
            guard !Task.isCancelled else { return }
            let enriched = await enrichPlaybackMetadata(for: item, contentId: nextUp.contentId)
            guard !Task.isCancelled else { return }
            nextUpPlaybackDetail = enriched
            preferredNextUpSubtitleTrackIndex = DetailPlaybackFormatting.launchPreferredSubtitleIndex(
                version: effectiveVersion(for: enriched, versionFileId: nil),
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

    private func seriesNextUpEpisode(for detail: ItemDetail) -> EpisodeListItem? {
        guard detail.type == "series" else { return nil }
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

        nextUpPlaybackDetail = nil
        isLoadingNextUpPlaybackDetail = true
        didLoadNextUpPlaybackDetail = false
        preferredNextUpFileId = nil
        preferredNextUpAudioTrackIndex = nil
        preferredNextUpSubtitleTrackIndex = nil
        didClearNextUpSubtitleOverride = false

        do {
            let item = try await ContinuumAPI.shared.itemDetail(contentId: nextUp.contentId)
            guard !Task.isCancelled else { return }
            let enriched = await enrichPlaybackMetadata(for: item, contentId: nextUp.contentId)
            guard !Task.isCancelled else { return }
            nextUpPlaybackDetail = enriched
            preferredNextUpSubtitleTrackIndex = DetailPlaybackFormatting.launchPreferredSubtitleIndex(
                version: effectiveVersion(for: enriched, versionFileId: nil),
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

    private func enrichPlaybackMetadata(for item: ItemDetail, contentId: String) async -> ItemDetail {
        guard item.type != "series" else { return item }

        do {
            let watchDetail = try await ContinuumAPI.shared.watchDetail(contentId: contentId)
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
}
#endif
