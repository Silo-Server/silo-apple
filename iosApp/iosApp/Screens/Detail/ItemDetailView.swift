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
/// Identifiable box so a one-shot `SiloControlPlaybackRequest` can drive a
/// `.sheet(item:)`. `id` keys off `contentId` so re-presenting for the
/// same item is idempotent.
private struct ControlRequestBox: Identifiable {
    let request: SiloControlPlaybackRequest
    var id: String { request.contentId }
    init(_ request: SiloControlPlaybackRequest) { self.request = request }
}
#endif

#if !os(tvOS)
/// A play tap paused on the downloaded-vs-stream choice. Created only when
/// the target item has a playable offline copy; carries the original
/// streaming parameters so "Stream" resumes exactly the tap that was
/// interrupted.
private struct OfflinePlayChoice: Identifiable {
    let downloadId: String
    /// Leaf id (episode id / movie content id) offline progress is keyed by.
    let leafContentId: String
    /// e.g. "Play Downloaded (10 Mbps · 2.1 GB)"
    let downloadedLabel: String
    let contentId: String
    let fileId: Int?
    let audioTrackIndex: Int?
    let subtitleTrackIndex: Int?
    let startFromBeginning: Bool
    let resumePosition: Double?
    var id: String { downloadId }
}

/// A streaming play attempt intercepted because the server is unreachable and
/// no local copy exists. Held so the confirmation alert's "Try Anyway" can
/// replay the exact request.
private struct UnreachablePlayRequest: Identifiable {
    let contentId: String
    let fileId: Int?
    let audioTrackIndex: Int?
    let subtitleTrackIndex: Int?
    let startFromBeginning: Bool
    let resumePosition: Double?
    var id: String { contentId }
}

private struct ItemDetailPhoneContent: View {
    let contentId: String

    @State private var viewModel = ItemDetailViewModel()
    @State private var preferredVersionFileId: Int?
    @State private var preferredAudioTrackIndex: Int?
    @State private var preferredSubtitleTrackIndex: Int?
    @State private var preferredSubtitleTrackWasManuallySelected = false
    @State private var preferredNextUpFileId: Int?
    @State private var preferredNextUpAudioTrackIndex: Int?
    @State private var preferredNextUpSubtitleTrackIndex: Int?
    @State private var nextUpWatchDetail: WatchDetail?
    @State private var refreshOnPlayerDismiss = false
    @State private var offlinePlayChoice: OfflinePlayChoice?
    @State private var unreachablePlayRequest: UnreachablePlayRequest?
    #if os(iOS)
    @Environment(SiloControlClient.self) private var siloControl
    @State private var controlRequestBox: ControlRequestBox?
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
        .siloBackground()
        .siloNavigationTitleDisplayMode(.inline)
        .siloNavigationBarBackgroundHidden()
        .task(id: contentId) {
            preferredVersionFileId = nil
            preferredAudioTrackIndex = nil
            preferredSubtitleTrackIndex = nil
            preferredSubtitleTrackWasManuallySelected = false
            preferredNextUpFileId = nil
            preferredNextUpAudioTrackIndex = nil
            preferredNextUpSubtitleTrackIndex = nil
            nextUpWatchDetail = nil
            refreshOnPlayerDismiss = false
            await viewModel.loadDetail(contentId: contentId)
            seedSubtitleOverrideIfNeeded()
        }
        .onAppear {
            // Coming back from the player (or an extra) resumes a poll that
            // `onDisappear` cancelled — without re-POSTing, since the server
            // already spent the item's weekly slot. Precedent:
            // `PersonDetailView.resumeMetadataRefreshIfNeeded`.
            viewModel.resumeTrailerFetchIfNeeded()
            seedSubtitleOverrideIfNeeded()
        }
        .onDisappear {
            // The trailer poll isn't owned by `.task`, so it would otherwise
            // keep running (and retaining the view model) after the route
            // pops. Same reasoning as `PersonDetailView.stopMetadataRefresh`.
            viewModel.stopTrailerFetch()
        }
        .onChange(of: router.presentedPlayer?.id) { oldValue, newValue in
            guard oldValue != nil, newValue == nil, refreshOnPlayerDismiss else { return }
            refreshOnPlayerDismiss = false
            Task {
                await viewModel.loadDetail(contentId: contentId)
                // A track picked inside the player persisted server-side;
                // drop the pre-play selector state so the reloaded pref
                // re-seeds and the selector reflects the latest pick.
                preferredSubtitleTrackIndex = nil
                preferredSubtitleTrackWasManuallySelected = false
                seedSubtitleOverrideIfNeeded()
            }
        }
        .alert(
            "Downloaded on This Device",
            isPresented: Binding(
                get: { offlinePlayChoice != nil },
                set: { if !$0 { offlinePlayChoice = nil } }
            ),
            presenting: offlinePlayChoice
        ) { choice in
            Button(choice.downloadedLabel) {
                refreshOnPlayerDismiss = true
                router.presentOfflinePlayer(
                    downloadId: choice.downloadId,
                    contentId: choice.leafContentId,
                    startFromBeginning: choice.startFromBeginning,
                    resumePosition: choice.resumePosition
                )
            }
            Button("Stream from Server") {
                presentStreamingPlayer(
                    contentId: choice.contentId,
                    fileId: choice.fileId,
                    audioTrackIndex: choice.audioTrackIndex,
                    subtitleTrackIndex: choice.subtitleTrackIndex,
                    startFromBeginning: choice.startFromBeginning,
                    resumePosition: choice.resumePosition
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Play the copy saved on this device, or stream from the server.")
        }
        .alert(
            "Can't Reach Server",
            isPresented: Binding(
                get: { unreachablePlayRequest != nil },
                set: { if !$0 { unreachablePlayRequest = nil } }
            ),
            presenting: unreachablePlayRequest
        ) { request in
            // Reachability state can be stale (e.g. the server just came
            // back), so always leave an escape hatch to attempt the stream.
            Button("Try Anyway") {
                Task { await ConnectionMonitor.shared.probeServer() }
                presentStreamingPlayer(
                    contentId: request.contentId,
                    fileId: request.fileId,
                    audioTrackIndex: request.audioTrackIndex,
                    subtitleTrackIndex: request.subtitleTrackIndex,
                    startFromBeginning: request.startFromBeginning,
                    resumePosition: request.resumePosition
                )
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(ConnectionMonitor.shared.isDeviceOnline
                ? "Streaming needs a connection to your server, which isn't responding right now. Downloaded titles can still be played."
                : "You're offline. Connect to a network to stream, or play a downloaded title.")
        }
        #if os(iOS)
        .toolbar {
            if let detail = viewModel.detail, isDirectlyPlayable(detail) {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        playOnTV(currentControlRequest(for: detail))
                    } label: {
                        Image(systemName: siloControl.hasActiveSession
                            ? "appletvremote.gen4.fill"
                            : "appletvremote.gen4")
                    }
                    .tint(.siloOnSurface)
                    .accessibilityLabel("Remote Control")
                }
            }
        }
        .sheet(item: $controlRequestBox) { box in
            SiloControlTargetPickerView(request: box.request, controller: siloControl)
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
    private func currentControlRequest(for detail: ItemDetail) -> SiloControlPlaybackRequest {
        currentControlRequest(
            contentId: contentId,
            fileId: selection(for: detail, versionFileId: preferredVersionFileId).playbackFileId,
            audioTrackIndex: preferredAudioTrackIndex,
            subtitleTrackIndex: preferredSubtitleTrackIndex,
            startFromBeginning: false,
            resumePosition: DetailPlaybackFormatting.playableResumePosition(for: detail)
        )
    }

    private func currentControlRequest(
        contentId: String,
        fileId: Int?,
        audioTrackIndex: Int?,
        subtitleTrackIndex: Int?,
        startFromBeginning: Bool,
        resumePosition: Double?
    ) -> SiloControlPlaybackRequest {
        SiloControlPlaybackRequest(
            contentId: contentId,
            fileId: fileId,
            audioTrackIndex: audioTrackIndex,
            subtitleTrackIndex: subtitleTrackIndex,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition
        )
    }

    private func playOnTV(_ request: SiloControlPlaybackRequest) {
        if siloControl.hasActiveSession {
            // Already connected ⇒ cast this item now.
            Task { await siloControl.launch(request) }
        } else {
            // No session ⇒ pick a TV, then cast-and-play in one step.
            controlRequestBox = ControlRequestBox(request)
        }
    }
    #endif

    @ViewBuilder
    private func content(for detail: ItemDetail) -> some View {
        if detail.isAudiobook {
            AudiobookDetailContent(
                detail: detail,
                onNavigateToItem: navigateToItem
            )
        } else if detail.type == "season" {
            SeasonDetailContent(
                detail: detail,
                isFavorite: viewModel.isFavorite,
                inWatchlist: viewModel.inWatchlist,
                isWatched: viewModel.isWatched,
                seasons: viewModel.seasons,
                selectedSeason: viewModel.selectedSeason,
                episodes: viewModel.episodes,
                episodesBySeason: viewModel.episodesBySeason,
                isLoadingEpisodes: viewModel.isLoadingEpisodes,
                selectedNextUpFileId: preferredNextUpFileId,
                selectedNextUpAudioTrackIndex: preferredNextUpAudioTrackIndex,
                selectedNextUpSubtitleTrackIndex: preferredNextUpSubtitleTrackIndex,
                nextUpWatchDetail: nextUpWatchDetail,
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
                onEpisodeTap: navigateToItem,
                onSelectSeason: { season in
                    guard season.id != detail.contentId else { return }
                    router.navigate(to: .itemDetail(contentId: season.contentId))
                },
                onSelectNextUpVersion: selectNextUpVersion,
                onSelectNextUpAudioTrack: selectNextUpAudioTrack,
                onSelectNextUpSubtitleTrack: selectNextUpSubtitleTrack,
                onToggleFavorite: toggleFavorite,
                onToggleWatchlist: toggleWatchlist,
                onToggleWatched: toggleWatched,
                onPersonTap: navigateToPerson,
                onNavigateToItem: navigateToItem,
                belowOverview: { descriptionTranslation(for: detail) }
            )
            .task(id: nextUpEpisodeContentId(for: detail)) {
                await loadNextUpWatchDetail(for: detail)
            }
        } else if detail.type == "series" {
            SeriesDetailContent(
                detail: detail,
                isFavorite: viewModel.isFavorite,
                inWatchlist: viewModel.inWatchlist,
                isWatched: viewModel.isWatched,
                seasons: viewModel.seasons,
                selectedSeason: viewModel.selectedSeason,
                episodes: viewModel.episodes,
                episodesBySeason: viewModel.episodesBySeason,
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
                    if let fileId = nextUpSelection(versionFileId: preferredNextUpFileId)
                        .playbackFileId(resolvedFileId: fileId) {
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
                onEpisodeTap: navigateToItem,
                onSelectNextUpVersion: selectNextUpVersion,
                onSelectNextUpAudioTrack: selectNextUpAudioTrack,
                onSelectNextUpSubtitleTrack: selectNextUpSubtitleTrack,
                onToggleFavorite: toggleFavorite,
                onToggleWatchlist: toggleWatchlist,
                onToggleWatched: toggleWatched,
                onPersonTap: navigateToPerson,
                onNavigateToItem: navigateToItem,
                onPlayExtra: { id in playExtra(contentId: id) },
                onFindTrailers: { viewModel.startTrailerFetch() },
                trailerStatusMessage: viewModel.trailerFetch.statusMessage,
                isFindingTrailers: viewModel.trailerFetch.isFetching,
                onTrailerStatusShown: { viewModel.trailerFetch.acknowledge() },
                belowOverview: { descriptionTranslation(for: detail) }
            )
            .task(id: nextUpEpisodeContentId(for: detail)) {
                await loadNextUpWatchDetail(for: detail)
            }
        } else {
            MovieDetailContent(
                detail: detail,
                isFavorite: viewModel.isFavorite,
                inWatchlist: viewModel.inWatchlist,
                isWatched: viewModel.isWatched,
                selectedVersionFileId: preferredVersionFileId,
                selectedAudioTrackIndex: preferredAudioTrackIndex,
                selectedSubtitleTrackIndex: preferredSubtitleTrackIndex,
                seasons: viewModel.seasons,
                selectedSeason: viewModel.selectedSeason,
                seasonEpisodes: viewModel.episodes,
                seasonEpisodesBySeason: viewModel.episodesBySeason,
                isLoadingEpisodes: viewModel.isLoadingEpisodes,
                episodeSeriesPosterUrl: viewModel.episodeSeriesPosterUrl,
                episodeSeriesPosterThumbhash: viewModel.episodeSeriesPosterThumbhash,
                onPlay: { startFromBeginning in
                    let resumePosition = startFromBeginning
                        ? nil
                        : DetailPlaybackFormatting.playableResumePosition(for: detail)
                    if let fileId = selection(for: detail, versionFileId: preferredVersionFileId).playbackFileId {
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
                    preferredSubtitleTrackWasManuallySelected = true
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
                    Task { await viewModel.selectSeason(season) }
                },
                onToggleFavorite: toggleFavorite,
                onToggleWatchlist: toggleWatchlist,
                onToggleWatched: toggleWatched,
                onPersonTap: navigateToPerson,
                onNavigateToItem: navigateToItem,
                onEpisodeTap: navigateToItem,
                onPlayExtra: { id in playExtra(contentId: id) },
                onFindTrailers: { viewModel.startTrailerFetch() },
                trailerStatusMessage: viewModel.trailerFetch.statusMessage,
                isFindingTrailers: viewModel.trailerFetch.isFetching,
                onTrailerStatusShown: { viewModel.trailerFetch.acknowledge() },
                belowOverview: { descriptionTranslation(for: detail) }
            )
        }
    }

    @ViewBuilder
    private func descriptionTranslation(for detail: ItemDetail) -> some View {
        DescriptionTranslationView(viewModel: viewModel, contentId: detail.contentId)
            .id(detail.contentId)
    }

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
            prefKey: prefKey(for: nextUpWatchDetail),
            version: current.effectiveVersion,
            requested: index,
            sanitized: preferredNextUpAudioTrackIndex
        )
    }

    private func selectNextUpSubtitleTrack(_ index: Int?) {
        let current = nextUpSelection(versionFileId: preferredNextUpFileId)
        preferredNextUpSubtitleTrackIndex = current.sanitizedSubtitleIndex(index)
        TrackSelectionPersistence.persistSubtitle(
            prefKey: prefKey(for: nextUpWatchDetail),
            version: current.effectiveVersion,
            requested: index,
            sanitized: preferredNextUpSubtitleTrackIndex,
            showForced: nextUpWatchDetail?.effectiveShowForcedSubtitles
        )
    }

    private func toggleFavorite() {
        Task { await viewModel.toggleFavorite() }
    }

    private func toggleWatchlist() {
        Task { await viewModel.toggleWatchlist() }
    }

    private func toggleWatched() {
        Task { await viewModel.toggleWatched() }
    }

    private func navigateToPerson(_ personId: String) {
        if let pid = Int(personId) {
            router.navigate(to: .personDetail(personId: pid))
        }
    }

    private func navigateToItem(_ id: String) {
        router.navigate(to: .itemDetail(contentId: id))
    }

    /// Play a local extra from the trailers rail. Always from the beginning
    /// — an extra has no stored resume point.
    ///
    /// An extra is an ordinary watch target with its own `contentId`, so a
    /// live Silo Control session casts it to the TV exactly like every other
    /// play affordance on the page; anything else would make extras the one
    /// odd affordance that plays locally while the rest beam.
    ///
    /// Without a session it skips only the downloaded-vs-stream choice of
    /// `presentPlayerFromDetail`: extras can't be downloaded, so that dialog
    /// has nothing to offer. The unreachable-server alert still applies —
    /// it warns up front rather than dropping the user into a player that
    /// will spin and fail, and extras must fail the same way as every other
    /// play affordance on the page.
    private func playExtra(contentId: String) {
        #if os(iOS)
        if siloControl.hasActiveSession {
            let request = SiloControlPlaybackRequest(
                contentId: contentId,
                fileId: nil,
                audioTrackIndex: nil,
                subtitleTrackIndex: nil,
                startFromBeginning: true,
                resumePosition: nil
            )
            Task { await siloControl.launch(request) }
            return
        }
        #endif

        guard ConnectionMonitor.shared.isServerReachable else {
            unreachablePlayRequest = UnreachablePlayRequest(
                contentId: contentId,
                fileId: nil,
                audioTrackIndex: nil,
                subtitleTrackIndex: nil,
                startFromBeginning: true,
                resumePosition: nil
            )
            return
        }

        presentStreamingPlayer(
            contentId: contentId,
            fileId: nil,
            audioTrackIndex: nil,
            subtitleTrackIndex: nil,
            startFromBeginning: true,
            resumePosition: nil
        )
    }

    /// This visit's picks for the item on screen. The policy lives in
    /// `DetailPlaybackSelection`; the screen owns only the storage.
    private func selection(for detail: ItemDetail, versionFileId: Int?) -> DetailPlaybackSelection {
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
            detail: nextUpWatchDetail,
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
    /// screen's per-visit selector state.
    private func seedSubtitleOverrideIfNeeded() {
        let seeded = DetailPlaybackFormatting.seededSubtitleIndex(
            current: preferredSubtitleTrackIndex,
            wasManuallySelected: preferredSubtitleTrackWasManuallySelected,
            detail: viewModel.detail,
            version: DetailPlaybackSelection(
                detail: viewModel.detail,
                versionFileId: preferredVersionFileId
            ).effectiveVersion
        )
        if seeded != preferredSubtitleTrackIndex {
            preferredSubtitleTrackIndex = seeded
        }
    }

    private func prefKey(for detail: ItemDetail) -> String? {
        TrackSelectionPersistence.prefKey(seriesId: detail.seriesId, contentId: detail.contentId)
    }

    private func prefKey(for detail: WatchDetail?) -> String? {
        TrackSelectionPersistence.prefKey(seriesId: detail?.seriesId, contentId: detail?.contentId)
    }

    private func nextUpEpisode(for detail: ItemDetail) -> EpisodeListItem? {
        guard detail.type == "series" || detail.type == "season" else { return nil }
        return EpisodeRailFormatting.nextUp(in: viewModel.episodes)
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
            let watchDetail = try await SiloAPI.shared.watchDetail(contentId: nextUp.contentId)
            guard !Task.isCancelled else { return }
            nextUpWatchDetail = watchDetail
            preferredNextUpSubtitleTrackIndex = DetailPlaybackFormatting.launchPreferredSubtitleIndex(
                version: DetailPlaybackSelection(detail: watchDetail, versionFileId: nil)
                    .effectiveVersion,
                signature: watchDetail.effectiveSubtitleTrackSignature,
                mode: watchDetail.effectiveSubtitleMode,
                usesDeviceSettings: PlayerSettings.shared.subtitleMatchesSystemAppearance
            )
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
        if siloControl.hasActiveSession {
            let request = SiloControlPlaybackRequest(
                contentId: contentId,
                fileId: fileId,
                audioTrackIndex: audioTrackIndex,
                subtitleTrackIndex: subtitleTrackIndex,
                startFromBeginning: startFromBeginning,
                resumePosition: resumePosition
            )
            Task {
                await siloControl.launch(request)
            }
            return
        }
        #endif

        // A playable local copy exists: pause the tap on a source choice so
        // the user can pick the downloaded file (e.g. a saved 1080p) or the
        // server stream (e.g. the full 4K). The cast branch above never
        // offers this — a cast target can't read the local file.
        if let record = DownloadManager.shared.record(forContentId: contentId),
           record.isPlayableOffline {
            // Server unreachable: streaming can't start, so skip the source
            // choice and play the local copy directly.
            guard ConnectionMonitor.shared.isServerReachable else {
                refreshOnPlayerDismiss = true
                router.presentOfflinePlayer(
                    downloadId: record.id,
                    contentId: record.leafMediaItemId,
                    startFromBeginning: startFromBeginning,
                    resumePosition: resumePosition
                )
                return
            }
            offlinePlayChoice = OfflinePlayChoice(
                downloadId: record.id,
                leafContentId: record.leafMediaItemId,
                downloadedLabel: Self.downloadedOptionLabel(for: record),
                contentId: contentId,
                fileId: fileId,
                audioTrackIndex: audioTrackIndex,
                subtitleTrackIndex: subtitleTrackIndex,
                startFromBeginning: startFromBeginning,
                resumePosition: resumePosition
            )
            return
        }

        // No local copy and the server is known unreachable: surface that
        // here instead of presenting a player that will spin and fail.
        guard ConnectionMonitor.shared.isServerReachable else {
            unreachablePlayRequest = UnreachablePlayRequest(
                contentId: contentId,
                fileId: fileId,
                audioTrackIndex: audioTrackIndex,
                subtitleTrackIndex: subtitleTrackIndex,
                startFromBeginning: startFromBeginning,
                resumePosition: resumePosition
            )
            return
        }

        presentStreamingPlayer(
            contentId: contentId,
            fileId: fileId,
            audioTrackIndex: audioTrackIndex,
            subtitleTrackIndex: subtitleTrackIndex,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition
        )
    }

    private func presentStreamingPlayer(
        contentId: String,
        fileId: Int?,
        audioTrackIndex: Int?,
        subtitleTrackIndex: Int?,
        startFromBeginning: Bool,
        resumePosition: Double?
    ) {
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

    /// Dialog label for the local copy, annotated with its stored quality
    /// and size so the choice against the stream is an informed one.
    private static func downloadedOptionLabel(for record: DownloadRecord) -> String {
        var parts: [String] = []
        let quality = record.effectiveQuality ?? record.format
        if !quality.isEmpty {
            parts.append(DownloadFormat(rawValue: quality)?.displayName ?? quality.capitalized)
        }
        if record.fileSize > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: record.fileSize, countStyle: .file))
        }
        return parts.isEmpty
            ? "Play Downloaded"
            : "Play Downloaded (\(parts.joined(separator: " · ")))"
    }
}
#endif
