import SwiftUI

/// Detail screen that routes to the appropriate Movie / Series /
/// Season / Episode layout for the current platform. Phones get the
/// `MovieDetailContent` / `SeriesDetailContent` / `SeasonDetailContent`
/// stack; tvOS forwards to `TVItemDetailView` for the cinematic
/// 10-foot layout.
struct ItemDetailView: View {
    let contentId: String

    var body: some View {
        #if os(tvOS)
        TVItemDetailView(contentId: contentId)
        #else
        ItemDetailPhoneContent(contentId: contentId)
        #endif
    }
}

#if os(iOS)
/// Identifiable box so a one-shot `SiloCastPlaybackRequest` can drive a
/// `.sheet(item:)`. `id` keys off `contentId` so re-presenting for the
/// same item is idempotent.
private struct CastRequestBox: Identifiable {
    let request: SiloCastPlaybackRequest
    var id: String { request.contentId }
    init(_ request: SiloCastPlaybackRequest) { self.request = request }
}
#endif

#if !os(tvOS)
private struct ItemDetailPhoneContent: View {
    let contentId: String

    @State private var viewModel = ItemDetailViewModel()
    @State private var preferredVersionFileId: Int?
    @State private var preferredAudioTrackIndex: Int?
    @State private var preferredSubtitleTrackIndex: Int?
    @State private var preferredNextUpFileId: Int?
    @State private var preferredNextUpAudioTrackIndex: Int?
    @State private var preferredNextUpSubtitleTrackIndex: Int?
    @State private var nextUpWatchDetail: WatchDetail?
    @State private var refreshOnPlayerDismiss = false
    #if os(iOS)
    @Environment(SiloCastController.self) private var castController
    @State private var castRequestBox: CastRequestBox?
    #endif
    @Environment(AppRouter.self) private var router

    var body: some View {
        Group {
            if let detail = viewModel.detail {
                content(for: detail)
            } else if let error = viewModel.error {
                ErrorView(state: error, onRetry: { Task { await viewModel.loadDetail(contentId: contentId) } })
            } else {
                Color.clear
            }
        }
        .continuumBackground()
        .continuumNavigationTitleDisplayMode(.inline)
        .continuumNavigationBarBackgroundHidden()
        .task(id: contentId) {
            preferredVersionFileId = nil
            preferredAudioTrackIndex = nil
            preferredSubtitleTrackIndex = nil
            preferredNextUpFileId = nil
            preferredNextUpAudioTrackIndex = nil
            preferredNextUpSubtitleTrackIndex = nil
            nextUpWatchDetail = nil
            refreshOnPlayerDismiss = false
            await viewModel.loadDetail(contentId: contentId)
        }
        .onChange(of: router.presentedPlayer?.id) { oldValue, newValue in
            guard oldValue != nil, newValue == nil, refreshOnPlayerDismiss else { return }
            refreshOnPlayerDismiss = false
            Task { await viewModel.loadDetail(contentId: contentId) }
        }
        #if os(iOS)
        .toolbar {
            if let detail = viewModel.detail, isDirectlyPlayable(detail) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        castFromDetail(currentCastRequest(for: detail))
                    } label: {
                        Image(systemName: castController.hasActiveSession
                            ? "appletvremote.gen4.fill"
                            : "appletvremote.gen4")
                    }
                    .tint(.continuumOnSurface)
                    .accessibilityLabel("Remote Control")
                }
            }
        }
        .sheet(item: $castRequestBox) { box in
            SiloCastTargetPickerView(request: box.request, controller: castController)
        }
        #endif
    }

    #if os(iOS)
    /// True when the loaded detail routes to `MovieDetailContent` — the only
    /// branch whose primary item maps to a single playback request. Series,
    /// season, and audiobook containers have no single "this item" to cast.
    private func isDirectlyPlayable(_ detail: ItemDetail) -> Bool {
        !detail.isAudiobook && detail.type != "season" && detail.type != "series"
    }

    /// Builds the cast request for the visible movie/episode using the
    /// IDENTICAL expressions as the `MovieDetailContent.onPlay` callback
    /// (resume-aware: play from the saved position when available).
    private func currentCastRequest(for detail: ItemDetail) -> SiloCastPlaybackRequest {
        currentCastRequest(
            contentId: contentId,
            fileId: playbackFileId(for: detail),
            audioTrackIndex: preferredAudioTrackIndex,
            subtitleTrackIndex: preferredSubtitleTrackIndex,
            startFromBeginning: false,
            resumePosition: playableResumePosition(for: detail)
        )
    }

    private func currentCastRequest(
        contentId: String,
        fileId: Int?,
        audioTrackIndex: Int?,
        subtitleTrackIndex: Int?,
        startFromBeginning: Bool,
        resumePosition: Double?
    ) -> SiloCastPlaybackRequest {
        SiloCastPlaybackRequest(
            contentId: contentId,
            fileId: fileId,
            audioTrackIndex: audioTrackIndex,
            subtitleTrackIndex: subtitleTrackIndex,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition
        )
    }

    private func castFromDetail(_ request: SiloCastPlaybackRequest) {
        if castController.hasActiveSession {
            // Already connected ⇒ cast this item now.
            Task { await castController.launch(request) }
        } else {
            // No session ⇒ pick a TV, then cast-and-play in one step.
            castRequestBox = CastRequestBox(request)
        }
    }
    #endif

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
            SeasonDetailContent(
                detail: detail,
                viewModel: viewModel,
                isFavorite: viewModel.isFavorite,
                inWatchlist: viewModel.inWatchlist,
                isWatched: viewModel.isWatched,
                seasons: viewModel.seasons,
                selectedSeason: viewModel.selectedSeason,
                episodes: viewModel.episodes,
                isLoadingEpisodes: viewModel.isLoadingEpisodes,
                selectedNextUpFileId: preferredNextUpFileId,
                selectedNextUpAudioTrackIndex: preferredNextUpAudioTrackIndex,
                selectedNextUpSubtitleTrackIndex: preferredNextUpSubtitleTrackIndex,
                nextUpWatchDetail: nextUpWatchDetail,
                onPlayEpisode: { id, fileId, startFromBeginning in
                    let episode = viewModel.episodes.first { $0.contentId == id }
                    let resumePosition = startFromBeginning
                        ? nil
                        : playableResumePosition(
                            position: episode?.userData?.positionSeconds,
                            duration: episode?.userData?.durationSeconds
                        )
                    if let fileId = nextUpPlaybackFileId(resolvedFileId: fileId) {
                        presentPlayerFromDetail(
                            contentId: id,
                            fileId: fileId,
                            audioTrackIndex: preferredNextUpAudioTrackIndex,
                            subtitleTrackIndex: preferredNextUpSubtitleTrackIndex,
                            startFromBeginning: startFromBeginning,
                            resumePosition: resumePosition
                        )
                    } else {
                        presentPlayerFromDetail(
                            contentId: id,
                            startFromBeginning: startFromBeginning,
                            resumePosition: resumePosition
                        )
                    }
                },
                onEpisodeTap: { id in
                    router.navigate(to: .itemDetail(contentId: id))
                },
                onSelectSeason: { season in
                    guard season.id != detail.contentId else { return }
                    router.navigate(to: .itemDetail(contentId: season.contentId))
                },
                onSelectNextUpVersion: { fileId in
                    preferredNextUpFileId = fileId
                    preferredNextUpAudioTrackIndex = sanitizedAudioTrackIndex(
                        for: nextUpWatchDetail,
                        versionFileId: fileId,
                        candidate: preferredNextUpAudioTrackIndex
                    )
                    preferredNextUpSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                        for: nextUpWatchDetail,
                        versionFileId: fileId,
                        candidate: preferredNextUpSubtitleTrackIndex
                    )
                },
                onSelectNextUpAudioTrack: { index in
                    preferredNextUpAudioTrackIndex = sanitizedAudioTrackIndex(
                        for: nextUpWatchDetail,
                        versionFileId: preferredNextUpFileId,
                        candidate: index
                    )
                },
                onSelectNextUpSubtitleTrack: { index in
                    preferredNextUpSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                        for: nextUpWatchDetail,
                        versionFileId: preferredNextUpFileId,
                        candidate: index
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
                }
            )
            .task(id: nextUpEpisodeContentId(for: detail)) {
                await loadNextUpWatchDetail(for: detail)
            }
        } else if detail.type == "series" {
            SeriesDetailContent(
                detail: detail,
                viewModel: viewModel,
                isFavorite: viewModel.isFavorite,
                inWatchlist: viewModel.inWatchlist,
                isWatched: viewModel.isWatched,
                seasons: viewModel.seasons,
                selectedSeason: viewModel.selectedSeason,
                episodes: viewModel.episodes,
                isLoadingEpisodes: viewModel.isLoadingEpisodes,
                selectedNextUpFileId: preferredNextUpFileId,
                selectedNextUpAudioTrackIndex: preferredNextUpAudioTrackIndex,
                selectedNextUpSubtitleTrackIndex: preferredNextUpSubtitleTrackIndex,
                nextUpWatchDetail: nextUpWatchDetail,
                onSelectSeason: { season in
                    Task { await viewModel.selectSeason(season) }
                },
                onPlayEpisode: { id, fileId, startFromBeginning in
                    let resumePosition = startFromBeginning
                        ? nil
                        : viewModel.episodes.first(where: { $0.contentId == id })?.userData?.positionSeconds
                    if let fileId = nextUpPlaybackFileId(resolvedFileId: fileId) {
                        presentPlayerFromDetail(
                            contentId: id,
                            fileId: fileId,
                            audioTrackIndex: preferredNextUpAudioTrackIndex,
                            subtitleTrackIndex: preferredNextUpSubtitleTrackIndex,
                            startFromBeginning: startFromBeginning,
                            resumePosition: resumePosition
                        )
                    } else {
                        presentPlayerFromDetail(
                            contentId: id,
                            startFromBeginning: startFromBeginning,
                            resumePosition: resumePosition
                        )
                    }
                },
                onEpisodeTap: { id in
                    router.navigate(to: .itemDetail(contentId: id))
                },
                onSelectNextUpVersion: { fileId in
                    preferredNextUpFileId = fileId
                    preferredNextUpAudioTrackIndex = sanitizedAudioTrackIndex(
                        for: nextUpWatchDetail,
                        versionFileId: fileId,
                        candidate: preferredNextUpAudioTrackIndex
                    )
                    preferredNextUpSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                        for: nextUpWatchDetail,
                        versionFileId: fileId,
                        candidate: preferredNextUpSubtitleTrackIndex
                    )
                },
                onSelectNextUpAudioTrack: { index in
                    preferredNextUpAudioTrackIndex = sanitizedAudioTrackIndex(
                        for: nextUpWatchDetail,
                        versionFileId: preferredNextUpFileId,
                        candidate: index
                    )
                },
                onSelectNextUpSubtitleTrack: { index in
                    preferredNextUpSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                        for: nextUpWatchDetail,
                        versionFileId: preferredNextUpFileId,
                        candidate: index
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
                }
            )
            .task(id: nextUpEpisodeContentId(for: detail)) {
                await loadNextUpWatchDetail(for: detail)
            }
        } else {
            MovieDetailContent(
                detail: detail,
                viewModel: viewModel,
                isFavorite: viewModel.isFavorite,
                inWatchlist: viewModel.inWatchlist,
                isWatched: viewModel.isWatched,
                selectedVersionFileId: preferredVersionFileId,
                selectedAudioTrackIndex: preferredAudioTrackIndex,
                selectedSubtitleTrackIndex: preferredSubtitleTrackIndex,
                seasons: viewModel.seasons,
                selectedSeason: viewModel.selectedSeason,
                seasonEpisodes: viewModel.episodes,
                isLoadingEpisodes: viewModel.isLoadingEpisodes,
                onPlay: { startFromBeginning in
                    let resumePosition = startFromBeginning ? nil : playableResumePosition(for: detail)
                    if let fileId = playbackFileId(for: detail) {
                        presentPlayerFromDetail(
                            contentId: contentId,
                            fileId: fileId,
                            audioTrackIndex: preferredAudioTrackIndex,
                            subtitleTrackIndex: preferredSubtitleTrackIndex,
                            startFromBeginning: startFromBeginning,
                            resumePosition: resumePosition
                        )
                    } else {
                        presentPlayerFromDetail(
                            contentId: contentId,
                            startFromBeginning: startFromBeginning,
                            resumePosition: resumePosition
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
                },
                onSelectSubtitleTrack: { index in
                    preferredSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                        for: detail,
                        versionFileId: preferredVersionFileId,
                        candidate: index
                    )
                },
                onSelectSeason: { season in
                    guard season.id != detail.contentId else { return }
                    router.navigate(to: .itemDetail(contentId: season.contentId))
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
                    router.navigate(to: .itemDetail(contentId: id))
                }
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

    private func nextUpPlaybackFileId(resolvedFileId: Int?) -> Int? {
        if let resolvedFileId {
            return resolvedFileId
        }
        if preferredNextUpAudioTrackIndex != nil || preferredNextUpSubtitleTrackIndex != nil {
            return effectiveVersion(
                for: nextUpWatchDetail,
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

    private func effectiveVersion(for detail: WatchDetail?, versionFileId: Int?) -> FileVersion? {
        guard let detail else { return nil }
        return DetailVersionSelection.displayVersion(
            versions: detail.versions,
            selectedFileId: versionFileId,
            lastFileId: detail.userData?.lastFileId,
            preferredQualityId: PlayerSettings.shared.preferredQuality
        )
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

    private func sanitizedAudioTrackIndex(
        for detail: WatchDetail?,
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

    private func sanitizedSubtitleTrackIndex(
        for detail: WatchDetail?,
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

    private func nextUpEpisode(for detail: ItemDetail) -> EpisodeListItem? {
        guard detail.type == "series" || detail.type == "season" else { return nil }
        if let inProgress = viewModel.episodes.first(where: { $0.userData?.isInProgress == true }) {
            return inProgress
        }
        if let unwatched = viewModel.episodes.first(where: { !($0.userData?.played ?? false) }) {
            return unwatched
        }
        return viewModel.episodes.first
    }

    private func nextUpEpisodeContentId(for detail: ItemDetail) -> String? {
        nextUpEpisode(for: detail)?.contentId
    }

    private func loadNextUpWatchDetail(for detail: ItemDetail) async {
        guard let nextUp = nextUpEpisode(for: detail) else {
            nextUpWatchDetail = nil
            preferredNextUpFileId = nil
            preferredNextUpAudioTrackIndex = nil
            preferredNextUpSubtitleTrackIndex = nil
            return
        }

        nextUpWatchDetail = nil
        preferredNextUpFileId = nil
        preferredNextUpAudioTrackIndex = nil
        preferredNextUpSubtitleTrackIndex = nil

        do {
            let watchDetail = try await ContinuumAPI.shared.watchDetail(contentId: nextUp.contentId)
            guard !Task.isCancelled else { return }
            nextUpWatchDetail = watchDetail
        } catch {
            guard !Task.isCancelled else { return }
            nextUpWatchDetail = nil
        }
    }

    private func presentPlayerFromDetail(
        contentId: String,
        fileId: Int? = nil,
        audioTrackIndex: Int? = nil,
        subtitleTrackIndex: Int? = nil,
        startFromBeginning: Bool,
        resumePosition: Double?
    ) {
        #if os(iOS)
        if castController.hasActiveSession {
            let request = SiloCastPlaybackRequest(
                contentId: contentId,
                fileId: fileId,
                audioTrackIndex: audioTrackIndex,
                subtitleTrackIndex: subtitleTrackIndex,
                startFromBeginning: startFromBeginning,
                resumePosition: resumePosition
            )
            Task {
                await castController.launch(request)
            }
            return
        }
        #endif

        refreshOnPlayerDismiss = true
        // Pass the artwork URLs we already loaded into the detail view so
        // PlayerViewModel.pushNowPlayingArtwork can publish lock-screen art
        // without re-fetching the catalog item. The hints are best-effort —
        // when the play target differs from the visible detail (e.g. a
        // related episode tap), the player falls back to its own fetch.
        let isOwnDetail = viewModel.detail?.contentId == contentId
        router.presentPlayer(
            contentId: contentId,
            fileId: fileId,
            audioTrackIndex: audioTrackIndex,
            subtitleTrackIndex: subtitleTrackIndex,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition,
            posterURL: isOwnDetail ? viewModel.detail?.posterUrl : nil,
            backdropURL: isOwnDetail ? viewModel.detail?.backdropUrl : nil
        )
    }
}
#endif
