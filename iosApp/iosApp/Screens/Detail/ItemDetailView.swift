import SwiftUI

/// Detail screen that routes to the appropriate Movie / Series /
/// Season / Episode layout for the current platform. Phones get the
/// `MovieDetailContent` / `SeriesDetailContent` / `SeasonDetailContent`
/// stack; tvOS forwards to `TVItemDetailView` for the cinematic
/// 10-foot layout.
struct ItemDetailView: View {
    let contentId: String
    var tvSeed: TVItemDetailRouteSeed? = nil
    var onClose: (() -> Void)? = nil

    var body: some View {
        #if os(tvOS)
        TVItemDetailView(contentId: contentId, seed: tvSeed)
        #else
        ItemDetailPhoneContent(contentId: contentId, onClose: onClose)
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
    var onClose: (() -> Void)? = nil

    @State private var viewModel = ItemDetailViewModel()
    @State private var preferredVersionFileId: Int?
    @State private var preferredAudioTrackIndex: Int?
    @State private var preferredSubtitleTrackIndex: Int?
    @State private var preferredSubtitleTrackWasManuallySelected = false
    @State private var preferredNextUpFileId: Int?
    @State private var preferredNextUpAudioTrackIndex: Int?
    @State private var preferredNextUpSubtitleTrackIndex: Int?
    @State private var nextUpWatchDetail: WatchDetail?
    /// Keeps the playback selector's footprint occupied while a newly focused
    /// episode is resolving its files and tracks. The series page renders a
    /// same-size skeleton from this state instead of collapsing the stack.
    @State private var isLoadingNextUpWatchDetail = false
    /// Series pages select episodes in place. Nil means the normal next-up
    /// episode is active; tapping a card pins that episode without pushing a
    /// second detail route.
    @State private var selectedSeriesEpisodeId: String?
    @State private var refreshOnPlayerDismiss = false
    @State private var offlinePlayChoice: OfflinePlayChoice?
    @State private var unreachablePlayRequest: UnreachablePlayRequest?
    #if os(iOS)
    @Environment(SiloControlClient.self) private var siloControl
    @State private var controlRequestBox: ControlRequestBox?
    @State private var isShowingControlPicker = false
    @State private var isShowingRemoteControl = false
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
        #if os(iOS)
        // Detail chrome and selector checks stay monochrome over per-title
        // artwork; the app accent blue looked unrelated to this visual system.
        .tint(.white)
        #endif
        .continuumNavigationTitleDisplayMode(.inline)
        .continuumNavigationBarBackgroundHidden()
        .task(id: contentId) {
            preferredVersionFileId = nil
            preferredAudioTrackIndex = nil
            preferredSubtitleTrackIndex = nil
            preferredSubtitleTrackWasManuallySelected = false
            preferredNextUpFileId = nil
            preferredNextUpAudioTrackIndex = nil
            preferredNextUpSubtitleTrackIndex = nil
            nextUpWatchDetail = nil
            isLoadingNextUpWatchDetail = false
            selectedSeriesEpisodeId = nil
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
            viewModel.stopEpisodePagePrefetch()
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
        // The native navigation bar reserved a solid black strip above the
        // artwork. The card owns its controls instead: the image now reaches
        // the rounded top edge and both controls float directly over it.
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            detailTopControls
        }
        .sheet(item: $controlRequestBox) { box in
            SiloControlTargetPickerView(request: box.request, controller: siloControl)
        }
        .sheet(isPresented: $isShowingControlPicker) {
            SiloControlTargetPickerView(request: nil, controller: siloControl)
        }
        .sheet(isPresented: $isShowingRemoteControl) {
            SiloControlRemoteView(controller: siloControl)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        #endif
    }

    #if os(iOS)
    private var detailTopControls: some View {
        HStack {
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(
                            width: ContinuumTheme.topBarIconHitSize,
                            height: ContinuumTheme.topBarIconHitSize
                        )
                        .siloGlass(in: Circle(), interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close details")
            } else if !router.itemDetailPath.isEmpty {
                Button {
                    router.itemDetailPath.removeLast()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(
                            width: ContinuumTheme.topBarIconHitSize,
                            height: ContinuumTheme.topBarIconHitSize
                        )
                        .siloGlass(in: Circle(), interactive: true)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
            }

            Spacer(minLength: 20)

            Button(action: handleRemoteControlTap) {
                Image(systemName: siloControl.hasActiveSession
                    ? "appletvremote.gen4.fill"
                    : "appletvremote.gen4")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(
                        width: ContinuumTheme.topBarIconHitSize,
                        height: ContinuumTheme.topBarIconHitSize
                    )
                    .siloGlass(in: Circle(), interactive: true)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remote Control")
        }
        .padding(.horizontal, 28)
        .padding(.top, 18)
        .zIndex(20)
    }

    /// Movies and episodes retain the existing cast-and-play behavior. Series
    /// overview cards still show the same remote pill; there it opens the
    /// connected remote or the TV picker because the container has no single
    /// playable file of its own.
    private func handleRemoteControlTap() {
        if let detail = viewModel.detail, isDirectlyPlayable(detail) {
            playOnTV(currentControlRequest(for: detail))
        } else if siloControl.hasActiveSession || siloControl.isReconnecting {
            isShowingRemoteControl = true
        } else {
            isShowingControlPicker = true
        }
    }

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
            fileId: playbackFileId(for: detail),
            audioTrackIndex: preferredAudioTrackIndex,
            subtitleTrackIndex: preferredSubtitleTrackIndex,
            startFromBeginning: false,
            resumePosition: playableResumePosition(for: detail)
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
                onNavigateToItem: { id in
                    router.navigate(to: .itemDetail(contentId: id))
                }
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
                    persistAudioSelection(
                        prefKey: prefKey(for: nextUpWatchDetail),
                        version: effectiveVersion(for: nextUpWatchDetail, versionFileId: preferredNextUpFileId),
                        requested: index,
                        sanitized: preferredNextUpAudioTrackIndex
                    )
                },
                onSelectNextUpSubtitleTrack: { index in
                    preferredNextUpSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                        for: nextUpWatchDetail,
                        versionFileId: preferredNextUpFileId,
                        candidate: index
                    )
                    persistSubtitleSelection(
                        prefKey: prefKey(for: nextUpWatchDetail),
                        version: effectiveVersion(for: nextUpWatchDetail, versionFileId: preferredNextUpFileId),
                        requested: index,
                        sanitized: preferredNextUpSubtitleTrackIndex,
                        showForced: nextUpWatchDetail?.effectiveShowForcedSubtitles
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
                belowOverview: {
                    DescriptionTranslationView(viewModel: viewModel, contentId: detail.contentId)
                        .id(detail.contentId)
                }
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
                isLoadingSelectedEpisodePlayback: isLoadingNextUpWatchDetail,
                selectedEpisodeContentId: playbackEpisode(for: detail)?.contentId,
                onSelectSeason: { season in
                    selectedSeriesEpisodeId = nil
                    Task { await viewModel.selectSeason(season) }
                },
                onPlayEpisode: { id, fileId, startFromBeginning in
                    let usesSelectedEpisodeControls = id == playbackEpisode(for: detail)?.contentId
                    let episode = viewModel.episodes.first(where: { $0.contentId == id })
                    let resumePosition = startFromBeginning
                        ? nil
                        : playableResumePosition(
                            position: episode?.userData?.positionSeconds,
                            duration: episode?.userData?.durationSeconds
                        )
                    if usesSelectedEpisodeControls,
                       let fileId = nextUpPlaybackFileId(resolvedFileId: fileId) {
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
                            fileId: usesSelectedEpisodeControls ? fileId : nil,
                            audioTrackIndex: usesSelectedEpisodeControls
                                ? preferredNextUpAudioTrackIndex : nil,
                            subtitleTrackIndex: usesSelectedEpisodeControls
                                ? preferredNextUpSubtitleTrackIndex : nil,
                            startFromBeginning: startFromBeginning,
                            resumePosition: resumePosition
                        )
                    }
                },
                onEpisodeTap: { id in
                    // The rail has already completed its native deceleration by
                    // the time it reports a centered card. Publishing this
                    // without a second animation prevents the whole vertical
                    // detail stack from participating in the selection change.
                    selectedSeriesEpisodeId = id
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
                    persistAudioSelection(
                        prefKey: prefKey(for: nextUpWatchDetail),
                        version: effectiveVersion(for: nextUpWatchDetail, versionFileId: preferredNextUpFileId),
                        requested: index,
                        sanitized: preferredNextUpAudioTrackIndex
                    )
                },
                onSelectNextUpSubtitleTrack: { index in
                    preferredNextUpSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                        for: nextUpWatchDetail,
                        versionFileId: preferredNextUpFileId,
                        candidate: index
                    )
                    persistSubtitleSelection(
                        prefKey: prefKey(for: nextUpWatchDetail),
                        version: effectiveVersion(for: nextUpWatchDetail, versionFileId: preferredNextUpFileId),
                        requested: index,
                        sanitized: preferredNextUpSubtitleTrackIndex,
                        showForced: nextUpWatchDetail?.effectiveShowForcedSubtitles
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
                onPlayExtra: { id in playExtra(contentId: id) },
                onFindTrailers: { viewModel.startTrailerFetch() },
                trailerStatusMessage: viewModel.trailerFetch.statusMessage,
                isFindingTrailers: viewModel.trailerFetch.isFetching,
                onTrailerStatusShown: { viewModel.trailerFetch.acknowledge() },
                belowOverview: {
                    DescriptionTranslationView(viewModel: viewModel, contentId: detail.contentId)
                        .id(detail.contentId)
                }
            )
            .task(id: playbackEpisodeContentId(for: detail)) {
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
                episodeSeriesLogoUrl: viewModel.episodeSeriesLogoUrl,
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
                    persistAudioSelection(
                        prefKey: prefKey(for: detail),
                        version: effectiveVersion(for: detail, versionFileId: preferredVersionFileId),
                        requested: index,
                        sanitized: preferredAudioTrackIndex
                    )
                },
                onSelectSubtitleTrack: { index in
                    preferredSubtitleTrackWasManuallySelected = true
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
                    router.navigate(to: .itemDetail(contentId: id))
                },
                onPlayExtra: { id in playExtra(contentId: id) },
                onFindTrailers: { viewModel.startTrailerFetch() },
                trailerStatusMessage: viewModel.trailerFetch.statusMessage,
                isFindingTrailers: viewModel.trailerFetch.isFetching,
                onTrailerStatusShown: { viewModel.trailerFetch.acknowledge() },
                belowOverview: {
                    DescriptionTranslationView(viewModel: viewModel, contentId: detail.contentId)
                        .id(detail.contentId)
                }
            )
        }
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
            if !preferredSubtitleTrackWasManuallySelected {
                preferredSubtitleTrackIndex = nil
            }
            return
        }
        guard !preferredSubtitleTrackWasManuallySelected,
              preferredSubtitleTrackIndex == nil,
              let detail = viewModel.detail else { return }
        preferredSubtitleTrackIndex = DetailPlaybackFormatting.launchPreferredSubtitleIndex(
            version: effectiveVersion(for: detail, versionFileId: preferredVersionFileId),
            signature: detail.effectiveSubtitleTrackSignature,
            mode: detail.effectiveSubtitleMode,
            usesDeviceSettings: PlayerSettings.shared.subtitleMatchesSystemAppearance
        )
    }

    private func prefKey(for detail: ItemDetail) -> String? {
        TrackSelectionPersistence.prefKey(seriesId: detail.seriesId, contentId: detail.contentId)
    }

    private func prefKey(for detail: WatchDetail?) -> String? {
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

    /// Series detail keeps one active episode on the main page. The user's
    /// explicit card selection wins; otherwise retain the existing in-progress
    /// then first-unwatched next-up policy. Season detail continues to use the
    /// unmodified next-up path.
    private func playbackEpisode(for detail: ItemDetail) -> EpisodeListItem? {
        if detail.type == "series",
           let selectedSeriesEpisodeId,
           let selected = viewModel.episodes.first(where: {
               $0.contentId == selectedSeriesEpisodeId
           }) {
            return selected
        }
        return nextUpEpisode(for: detail)
    }

    private func playbackEpisodeContentId(for detail: ItemDetail) -> String? {
        playbackEpisode(for: detail)?.contentId
    }

    private func loadNextUpWatchDetail(for detail: ItemDetail) async {
        guard let nextUp = playbackEpisode(for: detail) else {
            nextUpWatchDetail = nil
            isLoadingNextUpWatchDetail = false
            preferredNextUpFileId = nil
            preferredNextUpAudioTrackIndex = nil
            preferredNextUpSubtitleTrackIndex = nil
            return
        }

        let requestedContentId = nextUp.contentId
        isLoadingNextUpWatchDetail = true
        nextUpWatchDetail = nil
        preferredNextUpFileId = nil
        preferredNextUpAudioTrackIndex = nil
        preferredNextUpSubtitleTrackIndex = nil

        defer {
            // A cancelled request may finish after the user has already
            // centered another episode. Only the request that still owns the
            // current selection is allowed to remove its skeleton.
            if playbackEpisode(for: detail)?.contentId == requestedContentId {
                isLoadingNextUpWatchDetail = false
            }
        }

        do {
            let watchDetail = try await ContinuumAPI.shared.watchDetail(contentId: requestedContentId)
            guard !Task.isCancelled,
                  playbackEpisode(for: detail)?.contentId == requestedContentId else { return }
            nextUpWatchDetail = watchDetail
            preferredNextUpSubtitleTrackIndex = DetailPlaybackFormatting.launchPreferredSubtitleIndex(
                version: effectiveVersion(for: watchDetail, versionFileId: nil),
                signature: watchDetail.effectiveSubtitleTrackSignature,
                mode: watchDetail.effectiveSubtitleMode,
                usesDeviceSettings: PlayerSettings.shared.subtitleMatchesSystemAppearance
            )
        } catch {
            guard !Task.isCancelled,
                  playbackEpisode(for: detail)?.contentId == requestedContentId else { return }
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
