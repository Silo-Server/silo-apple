import SwiftUI

/// Movie, Series, and audiobook details. Episode and season links resolve to
/// their Series in the same presentation, retaining the requested selection.
struct ItemDetailView: View {
    let contentId: String
    var libraryId: Int? = nil
    var tvSeed: TVItemDetailRouteSeed? = nil
    var onClose: (() -> Void)? = nil
    var resumeContext: SeriesDetailContext? = nil

    @State private var resolvedSeries: SeriesDetailContext?
    @State private var resolvedSourceID: String?

    private var seriesContext: SeriesDetailContext? {
        resolvedSourceID == contentId ? resolvedSeries : nil
    }

    var body: some View {
        let destinationID = seriesContext?.seriesContentId ?? contentId
        let context = seriesContext ?? resumeContext
        // Only the original leaf may redirect. Malformed parent metadata must
        // show a recoverable error rather than cycle between catalog entries.
        let resolve: ((SeriesDetailContext) -> Void)? = seriesContext == nil ? { context in
            resolvedSourceID = contentId
            resolvedSeries = context
        } : nil
        #if os(tvOS)
        TVItemDetailView(
            contentId: destinationID, libraryId: libraryId,
            seed: seriesContext == nil ? tvSeed : nil,
            navigationContext: context, onResolveSeries: resolve
        )
        .id(CacheKey.itemDetail(destinationID, libraryId: libraryId))
        .environment(\.browseLibraryId, libraryId)
        #else
        ItemDetailPhoneContent(
            contentId: destinationID, libraryId: libraryId, onClose: onClose,
            resumeContext: context, onResolveSeries: resolve
        )
        .id(CacheKey.itemDetail(destinationID, libraryId: libraryId))
        .environment(\.browseLibraryId, libraryId)
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

/// Scroll offsets (as folded by `phoneDetailScrollTracking`) over which the
/// floating chrome's backing strip fades in, the per-button glass fades out
/// onto that strip, and the compact title fades in. The strip keeps scrolled
/// content, such as the season chips, from sliding under the floating
/// buttons while still being tappable.
struct PhoneDetailScrollGlassTiming: Equatable {
    var strip: ClosedRange<CGFloat>
    var controlGlass: ClosedRange<CGFloat>
    var title: ClosedRange<CGFloat>

    /// Compact (phone-width) hero: tall artwork with the title on its lower
    /// edge, so the chrome waits until the artwork has mostly scrolled away.
    static let compact = PhoneDetailScrollGlassTiming(
        strip: 200...360,
        controlGlass: 150...260,
        title: 400...480
    )

    /// Expanded (regular-width iPad) hero: the title block starts near the
    /// top of a shorter editorial header and leaves sooner. 150 is the
    /// earliest offset the folded tracking reports.
    static let expanded = PhoneDetailScrollGlassTiming(
        strip: 150...250,
        controlGlass: 150...250,
        title: 250...330
    )

    static func forHero(isExpanded: Bool) -> Self {
        isExpanded ? .expanded : .compact
    }
}

/// Static top-control layout. Scroll progress is read only by the tiny opacity
/// leaves below, so changing chrome never rebuilds buttons or their actions.
/// Shared with the request detail card, which has no trailing control.
struct PhoneDetailTopChrome: View {
    let title: String
    /// False keeps the buttons on their own glass with no backing strip.
    let isScrollGlassEnabled: Bool
    let scrollState: PhoneDetailScrollState
    let leadingSystemName: String?
    let leadingAccessibilityLabel: String?
    let onLeadingTap: () -> Void
    let trailingSystemName: String?
    let onTrailingTap: (() -> Void)?

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    /// The chrome spans the detail page, so its width is the hero's width.
    @State private var pageWidth: CGFloat = 0

    /// Follows the hero's own compact/expanded choice, so the strip and the
    /// title arrive as that hero's title scrolls away.
    private var scrollGlass: PhoneDetailScrollGlassTiming? {
        guard isScrollGlassEnabled else { return nil }
        return .forHero(isExpanded: PhoneDetailHeroLayout.usesExpandedLayout(
            availableWidth: pageWidth,
            horizontalSizeClass: horizontalSizeClass,
            verticalSizeClass: verticalSizeClass
        ))
    }

    var body: some View {
        ZStack(alignment: .top) {
            PhoneDetailTopGlass(
                timing: scrollGlass,
                scrollState: scrollState
            )

            PhoneDetailScrollTitle(
                title: title,
                timing: scrollGlass,
                scrollState: scrollState
            )

            HStack {
                if let leadingSystemName {
                    Button(action: onLeadingTap) {
                        controlIcon(
                            systemName: leadingSystemName,
                            size: leadingSystemName == "chevron.left" ? 17 : 16
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(leadingAccessibilityLabel ?? "Back")
                }

                Spacer(minLength: 20)

                if let trailingSystemName, let onTrailingTap {
                    Button(action: onTrailingTap) {
                        controlIcon(systemName: trailingSystemName, size: 16)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Remote Control")
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 9)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard abs(width - pageWidth) > 1 else { return }
            pageWidth = width
        }
        .zIndex(20)
    }

    private func controlIcon(systemName: String, size: CGFloat) -> some View {
        ZStack {
            PhoneDetailControlGlass(
                timing: scrollGlass,
                scrollState: scrollState
            )

            Image(systemName: systemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(
            width: SiloTheme.topBarIconHitSize,
            height: SiloTheme.topBarIconHitSize
        )
        .contentShape(Circle())
    }
}

/// Dynamic opacity around a stable glass subtree. The expensive native glass
/// node is equatable and retained while only its compositor alpha changes.
private struct PhoneDetailTopGlass: View {
    let timing: PhoneDetailScrollGlassTiming?
    let scrollState: PhoneDetailScrollState

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    var body: some View {
        if let timing {
            PhoneDetailStaticGlassStrip(reduceTransparency: reduceTransparency)
                .equatable()
                .opacity(phoneDetailSmoothProgress(scrollState.offset, over: timing.strip))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct PhoneDetailStaticGlassStrip: View, Equatable {
    let reduceTransparency: Bool

    var body: some View {
        Group {
            if reduceTransparency {
                Color(white: 0.16).opacity(0.98)
            } else {
                Color.clear
                    .siloGlass(in: Rectangle(), tint: Color.black.opacity(0.10))
                    .overlay(Color.white.opacity(0.025))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: SiloTheme.topBarIconHitSize + 18)
    }
}

private struct PhoneDetailScrollTitle: View {
    let title: String
    let timing: PhoneDetailScrollGlassTiming?
    let scrollState: PhoneDetailScrollState

    @ViewBuilder
    var body: some View {
        if let timing {
            let progress = phoneDetailSmoothProgress(scrollState.offset, over: timing.title)
            Text(title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 96)
                .frame(
                    maxWidth: .infinity,
                    minHeight: SiloTheme.topBarIconHitSize,
                    alignment: .center
                )
                .padding(.top, 9)
                .opacity(progress)
                .allowsHitTesting(false)
                .accessibilityHidden(progress < 0.5)
        }
    }
}

private struct PhoneDetailControlGlass: View {
    let timing: PhoneDetailScrollGlassTiming?
    let scrollState: PhoneDetailScrollState

    var body: some View {
        PhoneDetailStaticControlGlass()
            .equatable()
            .opacity(
                timing.map { 1 - phoneDetailSmoothProgress(scrollState.offset, over: $0.controlGlass) }
                    ?? 1
            )
    }
}

private struct PhoneDetailStaticControlGlass: View, Equatable {
    var body: some View {
        Color.clear
            .frame(
                width: SiloTheme.topBarIconHitSize,
                height: SiloTheme.topBarIconHitSize
            )
            .siloGlass(in: Circle(), interactive: true)
    }
}

private func phoneDetailSmoothProgress(
    _ value: CGFloat,
    over range: ClosedRange<CGFloat>
) -> CGFloat {
    let progress = min(max((value - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
    return progress * progress * (3 - (2 * progress))
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
    let libraryId: Int?
    var onClose: (() -> Void)? = nil
    var resumeContext: SeriesDetailContext? = nil

    let onResolveSeries: ((SeriesDetailContext) -> Void)?

    init(contentId: String, libraryId: Int?, onClose: (() -> Void)?, resumeContext: SeriesDetailContext?, onResolveSeries: ((SeriesDetailContext) -> Void)?) {
        self.contentId = contentId
        self.libraryId = libraryId
        self.onClose = onClose
        self.resumeContext = resumeContext
        self.onResolveSeries = onResolveSeries
        // Paint cached content on the first frame, so a warm visit pushes a
        // filled page rather than an empty one that fills in from `.task`.
        let viewModel = ItemDetailViewModel(libraryId: libraryId)
        viewModel.initialResumeSeasonNumber = resumeContext?.seasonNumber
        viewModel.hydrateFromCache(contentId: contentId)
        _viewModel = State(initialValue: viewModel)
        _selectedSeriesEpisodeId = State(initialValue: resumeContext?.episodeContentId)
    }

    @State private var viewModel: ItemDetailViewModel
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
    @State private var hasStartedDetailLoad = false
    @State private var isPageVisible = false
    /// Set when this page starts playback, so it only acts on its own return.
    @State private var awaitsPlaybackReturn = false
    @State private var refreshOnPlayerDismiss = false
    @State private var offlinePlayChoice: OfflinePlayChoice?
    @State private var unreachablePlayRequest: UnreachablePlayRequest?
    @State private var detailScrollState = PhoneDetailScrollState()
    /// Whether a movie or series page lays out as a split; see `supportsScrollGlassChrome`.
    @State private var isSplitPage = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    #if os(iOS)
    @Environment(SiloControlClient.self) private var siloControl
    @State private var controlRequestBox: ControlRequestBox?
    /// The cast button's in-flight watch-state read. A second tap replaces it.
    @State private var controlResumeLookupTask: Task<Void, Never>?
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
        .siloBackground()
        #if os(iOS)
        // Detail chrome and selector checks stay monochrome over per-title
        // artwork; the app accent blue looked unrelated to this visual system.
        .tint(.white)
        #endif
        .siloNavigationTitleDisplayMode(.inline)
        .siloNavigationBarBackgroundHidden()
        .task(id: contentId) {
            // Returning from the player restarts this task. Keep the episode
            // and season the page was showing instead of the entry context.
            let isReturning = hasStartedDetailLoad
            hasStartedDetailLoad = true
            preferredVersionFileId = nil
            preferredAudioTrackIndex = nil
            preferredSubtitleTrackIndex = nil
            preferredSubtitleTrackWasManuallySelected = false
            if isReturning {
                if let playback = takePlaybackReturn() {
                    await applySeriesPlaybackReturn(playback)
                }
                viewModel.initialResumeSeasonNumber = viewModel.selectedSeason?.seasonNumber
                    ?? viewModel.initialResumeSeasonNumber
            } else {
                selectedSeriesEpisodeId = resumeContext?.episodeContentId
                viewModel.initialResumeSeasonNumber = resumeContext?.seasonNumber
            }
            refreshOnPlayerDismiss = false
            detailScrollState.reset()
            // Seed from the painted detail so the selector doesn't show
            // "Auto" while the page reloads, then again from the fresh one.
            seedSubtitleOverrideIfNeeded()
            await viewModel.loadDetail(contentId: contentId)
            reseedSubtitleOverride()
        }
        .onAppear {
            isPageVisible = true
            // Coming back from the player (or an extra) resumes a poll that
            // `onDisappear` cancelled — without re-POSTing, since the server
            // already spent the item's weekly slot.
            viewModel.resumeTrailerFetchIfNeeded()
        }
        .onDisappear {
            isPageVisible = false
            #if os(iOS)
            controlResumeLookupTask?.cancel()
            controlResumeLookupTask = nil
            #endif
            viewModel.cancelDetailLoading()
            // The trailer poll isn't owned by `.task`, so it would otherwise
            // keep running (and retaining the view model) after the route
            // pops.
            viewModel.stopTrailerFetch()
            viewModel.stopEpisodePagePrefetch()
        }
        .onChange(of: router.presentedPlayer?.id) { oldValue, newValue in
            // A full-screen player hides this page, and the `.task` above
            // reloads it when it reappears. Reload here only when the page
            // stayed on screen under the player.
            guard oldValue != nil, newValue == nil, refreshOnPlayerDismiss, isPageVisible else { return }
            refreshOnPlayerDismiss = false
            Task {
                viewModel.initialResumeSeasonNumber = viewModel.selectedSeason?.seasonNumber
                    ?? viewModel.initialResumeSeasonNumber
                await viewModel.loadDetail(contentId: contentId)
                // A track picked inside the player persisted server-side;
                // drop the pre-play selector state so the reloaded pref
                // re-seeds and the selector reflects the latest pick.
                preferredSubtitleTrackWasManuallySelected = false
                reseedSubtitleOverride()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .seriesPlaybackDidReturn)) { _ in
            // The player can finish tearing down after this page reappears.
            // While the page is hidden, its reappearing task applies the return.
            guard hasStartedDetailLoad, isPageVisible, let playback = takePlaybackReturn() else { return }
            Task { await applySeriesPlaybackReturn(playback) }
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
        .personalStateNoticeAlert($viewModel.personalStateNotice)
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
        // Hide the navigation bar so the artwork reaches the card's top edge;
        // the card draws its own floating controls.
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .top) {
            detailTopControls
        }
        .onGeometryChange(for: Bool.self) { proxy in
            PhoneDetailHeroLayout.usesSplitLayout(pageSize: proxy.size, verticalSizeClass: verticalSizeClass)
        } action: { isSplit in
            isSplitPage = isSplit
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
        }
        #endif
    }

    #if os(iOS)
    private var detailTopControls: some View {
        let showsClose = onClose != nil
        let showsBack = !showsClose && !router.itemDetailPath.isEmpty

        return PhoneDetailTopChrome(
            title: scrollTitle,
            isScrollGlassEnabled: supportsScrollGlassChrome,
            scrollState: detailScrollState,
            leadingSystemName: showsClose ? "xmark" : (showsBack ? "chevron.left" : nil),
            leadingAccessibilityLabel: showsClose ? "Close details" : (showsBack ? "Back" : nil),
            onLeadingTap: {
                if let onClose {
                    onClose()
                } else if !router.itemDetailPath.isEmpty {
                    router.itemDetailPath.removeLast()
                }
            },
            trailingSystemName: siloControl.remotePlaybackEngaged
                ? "appletvremote.gen4.fill"
                : "appletvremote.gen4",
            onTrailingTap: handleRemoteControlTap
        )
    }

    /// Audiobooks show the same cleaned title as their hero, without the
    /// series prefix and volume locator baked into catalog titles.
    private var scrollTitle: String {
        guard let detail = viewModel.detail else { return "" }
        guard detail.isAudiobook else { return detail.title }
        return AudiobookDetailFormatting.cleanTitle(detail.title, seriesName: detail.audiobook?.series?.name)
    }

    /// Phone and iPad alike: without the strip, the season chips and other
    /// controls scroll under the floating Close button on an iPad sheet. A
    /// split movie or series page needs none: its content pane starts below
    /// the buttons, and the hero pane beside it never scrolls away.
    private var supportsScrollGlassChrome: Bool {
        guard let detail = viewModel.detail else { return false }
        if SiloMediaType.isMovieLibrary(detail.type) || SiloMediaType.isSeries(detail.type) {
            return !isSplitPage
        }
        return detail.isAudiobook
    }

    /// Movie and episode leaves cast the visible item. Containers (series,
    /// seasons, audiobooks) have no single file, so the button opens the
    /// connected remote or the TV picker.
    private func handleRemoteControlTap() {
        if let detail = viewModel.detail, isDirectlyPlayable(detail) {
            // The TV resumes from the request's explicit position, so read
            // the server's current one rather than the page's snapshot.
            let fileId = playbackFileId(for: detail)
            let audioTrackIndex = preferredAudioTrackIndex
            let subtitleTrackIndex = preferredSubtitleTrackIndex
            controlResumeLookupTask?.cancel()
            controlResumeLookupTask = Task {
                let state = await refreshedResumeState(contentId: contentId)
                guard !Task.isCancelled else { return }
                controlResumeLookupTask = nil
                playOnTV(SiloControlPlaybackRequest(
                    contentId: contentId,
                    fileId: fileId,
                    audioTrackIndex: audioTrackIndex,
                    subtitleTrackIndex: subtitleTrackIndex,
                    startFromBeginning: false,
                    resumePosition: state.resumePosition(cached: detail.userData)
                ))
            }
        } else if siloControl.remotePlaybackEngaged {
            isShowingRemoteControl = true
        } else {
            isShowingControlPicker = true
        }
    }

    /// True when the loaded detail is a movie or episode leaf, whose primary
    /// item maps to a single playback request. Series, season, and audiobook
    /// containers have no single "this item" to cast.
    private func isDirectlyPlayable(_ detail: ItemDetail) -> Bool {
        !detail.isAudiobook && detail.type != "season" && detail.type != "series"
    }

    private func playOnTV(_ request: SiloControlPlaybackRequest) {
        if siloControl.remotePlaybackEngaged {
            // Already engaged (or reconnecting) ⇒ cast this item now.
            Task { await siloControl.launchOnEngagedTV(request) }
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
                libraryId: libraryId,
                isFavorite: viewModel.isFavorite,
                inWatchlist: viewModel.inWatchlist,
                isWatched: viewModel.isWatched,
                onToggleFavorite: { Task { await viewModel.toggleFavorite() } },
                onToggleWatchlist: { Task { await viewModel.toggleWatchlist() } },
                onToggleWatched: { Task { await viewModel.toggleWatched() } },
                onPersonTap: { openPerson($0) },
                onNavigateToItem: { openItem($0) },
                scrollState: detailScrollState,
                belowOverview: { translationView(for: detail) }
            )
        } else if detail.type == "season" || detail.type == "episode" {
            SeriesDetailResolutionView(detail: detail, onResolve: onResolveSeries) {
                Task { await viewModel.loadDetail(contentId: contentId) }
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
                episodeFavoriteStates: viewModel.episodeFavoriteStates,
                episodeWatchlistStates: viewModel.episodeWatchlistStates,
                isLoadingEpisodes: viewModel.isLoadingSeriesHierarchy,
                hierarchyError: viewModel.seriesLoadErrorMessage,
                onRetryHierarchy: { await viewModel.retrySeriesHierarchy() },
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
                onPlayEpisode: { id, fileId, startFromBeginning, resumePosition in
                    awaitsPlaybackReturn = true
                    SeriesPlaybackReturnInbox.discardPending()
                    let usesSelectedEpisodeControls = id == playbackEpisode(for: detail)?.contentId
                    presentPlayerFromDetail(
                        contentId: id,
                        fileId: usesSelectedEpisodeControls
                            ? nextUpPlaybackFileId(resolvedFileId: fileId) : nil,
                        audioTrackIndex: usesSelectedEpisodeControls
                            ? preferredNextUpAudioTrackIndex : nil,
                        subtitleTrackIndex: usesSelectedEpisodeControls
                            ? preferredNextUpSubtitleTrackIndex : nil,
                        startFromBeginning: startFromBeginning,
                        resumePosition: startFromBeginning ? nil : resumePosition
                    )
                },
                refreshResumeState: { id in await refreshedResumeState(contentId: id) },
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
                onSetSeasonWatched: { season, played in
                    await viewModel.setSeasonWatched(season, played: played)
                },
                onSetEpisodeWatched: { episode, played in
                    await viewModel.setEpisodeWatched(
                        contentId: episode.contentId,
                        played: played,
                        seasonNumber: episode.seasonNumber
                    )
                },
                onSetEpisodeFavorite: { id, isFavorite in
                    await viewModel.setEpisodeFavorite(contentId: id, isFavorite: isFavorite)
                },
                onSetEpisodeWatchlist: { id, inWatchlist in
                    await viewModel.setEpisodeWatchlist(contentId: id, inWatchlist: inWatchlist)
                },
                onPersonTap: { openPerson($0) },
                onNavigateToItem: { openItem($0) },
                onPlayExtra: { id in playExtra(contentId: id) },
                onFindTrailers: { viewModel.startTrailerFetch() },
                trailerStatusMessage: viewModel.trailerFetch.statusMessage,
                isFindingTrailers: viewModel.trailerFetch.isFetching,
                onTrailerStatusShown: { viewModel.trailerFetch.acknowledge() },
                scrollState: detailScrollState,
                belowOverview: { translationView(for: detail) }
            )
            .task(id: playbackEpisode(for: detail)?.contentId) {
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
                onPlay: { startFromBeginning, resumePosition in
                    // Track picks only travel with a resolved file.
                    let fileId = playbackFileId(for: detail)
                    presentPlayerFromDetail(
                        contentId: contentId,
                        fileId: fileId,
                        audioTrackIndex: fileId == nil ? nil : preferredAudioTrackIndex,
                        subtitleTrackIndex: fileId == nil ? nil : preferredSubtitleTrackIndex,
                        startFromBeginning: startFromBeginning,
                        resumePosition: startFromBeginning ? nil : resumePosition
                    )
                },
                refreshResumeState: { await refreshedResumeState(contentId: contentId) },
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
                onToggleFavorite: { Task { await viewModel.toggleFavorite() } },
                onToggleWatchlist: { Task { await viewModel.toggleWatchlist() } },
                onToggleWatched: { Task { await viewModel.toggleWatched() } },
                onPersonTap: { openPerson($0) },
                onNavigateToItem: { openItem($0) },
                onPlayExtra: { id in playExtra(contentId: id) },
                onFindTrailers: { viewModel.startTrailerFetch() },
                trailerStatusMessage: viewModel.trailerFetch.statusMessage,
                isFindingTrailers: viewModel.trailerFetch.isFetching,
                onTrailerStatusShown: { viewModel.trailerFetch.acknowledge() },
                scrollState: detailScrollState,
                belowOverview: { translationView(for: detail) }
            )
        }
    }

    /// Plays a local extra from the start (extras can't be downloaded).
    private func playExtra(contentId: String) {
        presentPlayerFromDetail(contentId: contentId, startFromBeginning: true, resumePosition: nil)
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

    /// The server's current watch state for a Play tap. Skipped when the
    /// server is known unreachable, so a downloaded copy still plays at once
    /// from the page's snapshot.
    private func refreshedResumeState(contentId: String) async -> DetailResumeState {
        guard ConnectionMonitor.shared.isServerReachable else { return .unavailable }
        let libraryId = libraryId
        return await DetailResumeState.load {
            try await SiloAPI.shared.watchDetail(contentId: contentId, libraryId: libraryId).userData
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
        let available = version.subtitleTracks?.compactMap(\.selectionIndex) ?? []
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
        let available = version.subtitleTracks?.compactMap(\.selectionIndex) ?? []
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

    /// Re-derive the seeded subtitle from the current detail unless the user
    /// picked one on this visit.
    private func reseedSubtitleOverride() {
        guard !preferredSubtitleTrackWasManuallySelected else { return }
        preferredSubtitleTrackIndex = nil
        seedSubtitleOverrideIfNeeded()
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
        guard detail.type == "series" else { return nil }
        if let inProgress = viewModel.episodes.first(where: { $0.userData?.isInProgress == true }) {
            return inProgress
        }
        if let unwatched = viewModel.episodes.first(where: { !($0.userData?.played ?? false) }) {
            return unwatched
        }
        return viewModel.episodes.first
    }

    private func takePlaybackReturn() -> SeriesPlaybackReturn? {
        guard awaitsPlaybackReturn,
              let playback = SeriesPlaybackReturnInbox.take(seriesContentId: contentId) else { return nil }
        awaitsPlaybackReturn = false
        return playback
    }

    /// Land on the episode after a finished one, or on the same episode after
    /// a partial watch.
    private func applySeriesPlaybackReturn(_ playback: SeriesPlaybackReturn) async {
        guard let episodeId = await viewModel.prepareSeriesPlaybackReturn(playback),
              !Task.isCancelled else { return }
        selectedSeriesEpisodeId = episodeId
    }

    /// The Series page's active episode: the user's card selection, else the
    /// in-progress episode, else the first unwatched one.
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
        let cacheKey = CacheKey.itemWatchDetail(requestedContentId, libraryId: libraryId)
        let cached: WatchDetail? = ResponseCache.shared.get(cacheKey)
        preferredNextUpFileId = nil
        preferredNextUpAudioTrackIndex = nil
        // A cached episode paints its selectors at once; only a miss shows
        // the skeleton while the request runs.
        nextUpWatchDetail = cached
        preferredNextUpSubtitleTrackIndex = cached.flatMap { launchSubtitleIndex(for: $0) }
        isLoadingNextUpWatchDetail = cached == nil
        let seededSubtitleIndex = preferredNextUpSubtitleTrackIndex

        defer {
            // A cancelled request may finish after the user has already
            // centered another episode. Only the request that still owns the
            // current selection is allowed to remove its skeleton.
            if playbackEpisode(for: detail)?.contentId == requestedContentId {
                isLoadingNextUpWatchDetail = false
            }
        }

        // Identity boundaries and invalidations advance the token, so a
        // response from before either is not cached.
        let writeToken = ResponseCache.shared.writeToken
        do {
            let watchDetail = try await MetadataRequestPool.shared.watchDetail(
                contentId: requestedContentId, libraryId: libraryId
            )
            guard !Task.isCancelled,
                  playbackEpisode(for: detail)?.contentId == requestedContentId else { return }
            ResponseCache.shared.set(watchDetail, for: cacheKey, fetchedAt: writeToken)
            // Keep any pick made on the cached selectors while this ran.
            let isUntouched = preferredNextUpFileId == nil
                && preferredNextUpAudioTrackIndex == nil
                && preferredNextUpSubtitleTrackIndex == seededSubtitleIndex
            nextUpWatchDetail = watchDetail
            if isUntouched {
                preferredNextUpSubtitleTrackIndex = launchSubtitleIndex(for: watchDetail)
            }
        } catch {
            guard !Task.isCancelled,
                  playbackEpisode(for: detail)?.contentId == requestedContentId,
                  cached == nil else { return }
            nextUpWatchDetail = nil
        }
    }

    private func launchSubtitleIndex(for watchDetail: WatchDetail) -> Int? {
        DetailPlaybackFormatting.launchPreferredSubtitleIndex(
            version: effectiveVersion(for: watchDetail, versionFileId: nil),
            signature: watchDetail.effectiveSubtitleTrackSignature,
            mode: watchDetail.effectiveSubtitleMode,
            usesDeviceSettings: PlayerSettings.shared.subtitleMatchesSystemAppearance
        )
    }

    private func openPerson(_ personId: String) {
        if !personId.isEmpty {
            router.navigate(to: .personDetail(personId: personId))
        }
    }

    private func openItem(_ contentId: String) {
        router.navigate(to: .itemDetail(contentId: contentId))
    }

    private func translationView(for detail: ItemDetail) -> DescriptionTranslationView {
        DescriptionTranslationView(viewModel: viewModel, contentId: detail.contentId)
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
        // An engaged TV takes the request through the router's interceptor
        // (see `AppRouter.presentPlayer`). Skipping the local-copy choice and
        // the reachability alert is deliberate: a TV can't read the phone's
        // download, and the TV reaches the server on its own link.
        if siloControl.remotePlaybackEngaged {
            presentStreamingPlayer(
                contentId: contentId,
                fileId: fileId,
                audioTrackIndex: audioTrackIndex,
                subtitleTrackIndex: subtitleTrackIndex,
                startFromBeginning: startFromBeginning,
                resumePosition: resumePosition
            )
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
            libraryId: libraryId,
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
