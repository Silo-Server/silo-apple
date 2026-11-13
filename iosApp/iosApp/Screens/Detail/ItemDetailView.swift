import SwiftUI

/// Movie, Series, and audiobook details. Episode and season links resolve to
/// their Series in the same presentation, retaining the requested selection.
struct ItemDetailView: View {
    let contentId: String
    var libraryId: Int? = nil
    var tvSeed: TVItemDetailRouteSeed? = nil
    var onClose: (() -> Void)? = nil
    var resumeContext: SeriesDetailContext? = nil
    /// Reports the season and episode chosen on a series page.
    var onSeriesSelection: ((SeriesDetailContext) -> Void)? = nil

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
            resumeContext: context, onResolveSeries: resolve, onSeriesSelection: onSeriesSelection
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
    /// Replaces the buttons' usual inset (18pt from the sides, 9pt from the
    /// top) with one distance from both, to sit them in a split page's sidebar.
    var cornerInset: CGFloat? = nil

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.locale) private var locale
    /// The chrome spans the detail page, so its width is the hero's width.
    @State private var pageWidth: CGFloat = 0
    #if os(iOS)
    @State private var statusColumn: StatusColumnLayout?
    #endif

    /// Follows the hero's own compact/expanded choice, so the strip and the
    /// title arrive as that hero's title scrolls away.
    private var scrollGlass: PhoneDetailScrollGlassTiming? {
        guard isScrollGlassEnabled, !isBesideStatusColumn else { return nil }
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
                if let leadingSystemName, !usesStatusColumnNavigation {
                    Button(action: onLeadingTap) {
                        controlIcon(
                            systemName: leadingSystemName,
                            size: leadingSystemName == "chevron.backward" ? 17 : 16
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(leadingAccessibilityLabel ?? AppLanguage.string(.commonBack, locale: locale))
                }

                Spacer(minLength: 20)

                if !isBesideStatusColumn {
                    trailingButton
                }
            }
            .padding(.horizontal, cornerInset ?? 18)
            .padding(.top, cornerInset ?? 9)
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            guard abs(width - pageWidth) > 1 else { return }
            pageWidth = width
        }
        #if os(iOS)
        .onGeometryChange(for: StatusColumnLayout?.self) { proxy in
            StatusColumnLayout(safeArea: proxy.safeAreaInsets)
        } action: { column in
            statusColumn = column
        }
        // The page hides the navigation bar so its artwork reaches the top.
        // On the folded iPhone Duo the bar runs down the status column
        // beside the artwork and carries Close or Back.
        .toolbar(usesStatusColumnNavigation ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            if usesStatusColumnNavigation, leadingSystemName == "xmark" {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: onLeadingTap) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel(leadingAccessibilityLabel ?? AppLanguage.string(.rowPageClose, locale: locale))
                }
            }
        }
        #endif
        .zIndex(20)
    }

    /// On the folded iPhone Duo, Close and Back go at the top of the status
    /// column as system bar buttons, where Apple places a page's primary
    /// navigation and where row pages and pushed pages already show theirs.
    /// The system keeps them clear of the time and any Live Activity. The
    /// open Duo's split page keeps its own button in the sidebar.
    private var usesStatusColumnNavigation: Bool {
        isBesideStatusColumn && horizontalSizeClass == .compact
    }

    /// Beside the iPhone Duo's status column the buttons keep their own
    /// glass and no strip runs across the top: a strip there ends at the
    /// column in a hard edge.
    private var isBesideStatusColumn: Bool {
        #if os(iOS)
        statusColumn != nil
        #else
        false
        #endif
    }

    @ViewBuilder
    private var trailingButton: some View {
        if let trailingSystemName, let onTrailingTap {
            Button(action: onTrailingTap) {
                controlIcon(systemName: trailingSystemName, size: 16)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(.detailRemoteControl))
        }
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
    let pinsVersion: Bool
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
    let pinsVersion: Bool
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
    let onSeriesSelection: ((SeriesDetailContext) -> Void)?

    init(
        contentId: String, libraryId: Int?, onClose: (() -> Void)?, resumeContext: SeriesDetailContext?,
        onResolveSeries: ((SeriesDetailContext) -> Void)?, onSeriesSelection: ((SeriesDetailContext) -> Void)?
    ) {
        self.contentId = contentId
        self.libraryId = libraryId
        self.onClose = onClose
        self.resumeContext = resumeContext
        self.onResolveSeries = onResolveSeries
        self.onSeriesSelection = onSeriesSelection
        // Paint cached content on the first frame, so a warm visit pushes a
        // filled page rather than an empty one that fills in from `.task`.
        let viewModel = ItemDetailViewModel(libraryId: libraryId)
        viewModel.initialResumeSeasonNumber = resumeContext?.seasonNumber
        viewModel.hydrateFromCache(contentId: contentId)
        _viewModel = State(initialValue: viewModel)
        _selectedSeriesEpisodeId = State(initialValue: resumeContext?.episodeContentId)
    }

    @State private var viewModel: ItemDetailViewModel
    /// Season and episode routes resolve to their series, so this is the
    /// page theme music looks up the selected season's own set on.
    private var isSeriesPage: Bool { viewModel.detail.map { SiloMediaType.isSeries($0.type) } ?? false }
    @State private var preferredVersionFileId: Int?
    /// The edition picked on this visit. Nil opens on the last-played one.
    @State private var preferredEditionId: String?
    @State private var preferredAudioTrackIndex: Int?
    @State private var preferredSubtitleTrackIndex: Int?
    @State private var preferredSubtitleTrackWasManuallySelected = false
    /// Set when the viewer picks Auto on this visit; the next load reads the
    /// cleared preference from the server.
    @State private var didClearSubtitleOverride = false
    /// The file a manual subtitle track pick was made on; its index means
    /// nothing on another version.
    @State private var preferredSubtitleTrackFileId: Int?
    @State private var preferredNextUpFileId: Int?
    @State private var preferredNextUpEditionId: String?
    @State private var preferredNextUpAudioTrackIndex: Int?
    @State private var preferredNextUpSubtitleTrackIndex: Int?
    @State private var nextUpWatchDetail: WatchDetail?
    /// Set when the viewer picks Auto for the selected episode, until the
    /// next episode load.
    @State private var didClearNextUpSubtitleOverride = false
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
    /// `PlayerCleanupBarrier` generation of the player this page presented,
    /// so the reload after it closes waits for that player's final write.
    @State private var playerCleanupGeneration: Int?
    @State private var offlinePlayChoice: OfflinePlayChoice?
    @State private var unreachablePlayRequest: UnreachablePlayRequest?
    @State private var detailScrollState = PhoneDetailScrollState()
    /// Whether a movie or series page lays out as a split; see `supportsScrollGlassChrome`.
    @State private var isSplitPage = false
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.locale) private var locale
    #if os(iOS)
    /// The iPhone Duo's status column beside the page, where the TV remote
    /// covers the window and the Remote button moves into the column.
    @State private var statusColumn: StatusColumnLayout?
    private var isBesideStatusColumn: Bool { statusColumn != nil }
    @Environment(SiloControlClient.self) private var siloControl
    @State private var controlRequestBox: ControlRequestBox?
    /// The cast button's in-flight watch-state read. A second tap replaces it.
    @State private var controlResumeLookupTask: Task<Void, Never>?
    @State private var isShowingControlPicker = false
    @State private var isShowingRemoteControl = false

    private var seriesSelection: SeriesDetailContext? {
        guard viewModel.detail?.type == "series" else { return nil }
        return SeriesDetailContext(
            seriesContentId: contentId,
            episodeContentId: selectedSeriesEpisodeId,
            seasonNumber: viewModel.selectedSeason?.seasonNumber
        )
    }

    private var isShowingControl: Bool {
        controlRequestBox != nil || isShowingControlPicker || isShowingRemoteControl
    }
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
        #if os(macOS)
        // The Mac's pages share one charcoal canvas, so a loading detail
        // page must not flash black. The page shows its own title, and the
        // toolbar would otherwise fall back to the window's name.
        .siloPageBackground()
        .toolbar(removing: .title)
        #else
        .siloBackground()
        #endif
        #if os(iOS)
        // Detail chrome and selector checks stay monochrome over per-title
        // artwork; the app accent blue looked unrelated to this visual system.
        .tint(.white)
        #endif
        .siloNavigationTitleDisplayMode(.inline)
        .siloNavigationBarBackgroundHidden()
        .descriptionTranslation(viewModel)
        .themeMusic(
            viewModel.detail?.themes,
            seasonContentId: isSeriesPage ? viewModel.selectedSeason?.contentId : nil,
            // A series page waits for its seasons, so a season that owns a
            // theme never opens on a burst of the series' one.
            isLoading: viewModel.detail == nil
                || (isSeriesPage && viewModel.seasons.isEmpty
                    && viewModel.isLoadingSeriesHierarchy)
        )
        .onChange(of: PlaybackConnection.shared.isMetered) { wasMetered, _ in
            reconcileTracksAfterConnectionChange(wasMetered: wasMetered)
        }
        .task(id: contentId) {
            // Returning from the player restarts this task. Keep the episode
            // and season the page was showing instead of the entry context.
            let isReturning = hasStartedDetailLoad
            hasStartedDetailLoad = true
            didClearSubtitleOverride = false
            preferredVersionFileId = nil
            preferredEditionId = nil
            preferredAudioTrackIndex = nil
            // A subtitle picked in the selector on this visit, Off included,
            // stays when the viewer returns from the player, as on tvOS.
            // `reseedSubtitleOverride` drops it only if the reloaded version
            // no longer has that track.
            if !isReturning || !preferredSubtitleTrackWasManuallySelected {
                preferredSubtitleTrackIndex = nil
                preferredSubtitleTrackWasManuallySelected = false
                preferredSubtitleTrackFileId = nil
            }
            if isReturning {
                if let playback = takePlaybackReturn() {
                    await applySeriesPlaybackReturn(playback)
                }
            } else {
                selectedSeriesEpisodeId = resumeContext?.episodeContentId
                viewModel.initialResumeSeasonNumber = resumeContext?.seasonNumber
            }
            detailScrollState.reset()
            // Seed from the painted detail so the selector doesn't show
            // "Auto" while the page reloads, then again from the fresh one.
            seedSubtitleOverrideIfNeeded()
            if let cleanupGeneration = playerCleanupGeneration {
                // Reloading before the closed player's last progress write
                // lands would show the progress and watched state from before it.
                await PlayerCleanupBarrier.waitForCleanup(of: cleanupGeneration)
                // Hidden again before the write landed; the next return waits.
                guard !Task.isCancelled else { return }
                if playerCleanupGeneration == cleanupGeneration {
                    playerCleanupGeneration = nil
                }
            }
            if isReturning {
                // Read after the wait, so a Series return that arrived during
                // it keeps the season it chose.
                viewModel.initialResumeSeasonNumber = viewModel.selectedSeason?.seasonNumber
                    ?? viewModel.initialResumeSeasonNumber
            }
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
            guard oldValue != nil, newValue == nil, let cleanupGeneration = playerCleanupGeneration,
                  isPageVisible else { return }
            playerCleanupGeneration = nil
            Task {
                await PlayerCleanupBarrier.waitForCleanup(of: cleanupGeneration)
                viewModel.initialResumeSeasonNumber = viewModel.selectedSeason?.seasonNumber
                    ?? viewModel.initialResumeSeasonNumber
                await viewModel.loadDetail(contentId: contentId)
                // A track picked inside the player persisted server-side and
                // re-seeds the selector, unless the viewer picked one in the
                // selector on this visit; that pick stays, as on tvOS.
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
            Text(.detailOfflineChoiceTitle),
            isPresented: Binding(
                get: { offlinePlayChoice != nil },
                set: { if !$0 { offlinePlayChoice = nil } }
            ),
            presenting: offlinePlayChoice
        ) { choice in
            Button(choice.downloadedLabel) {
                playerCleanupGeneration = PlayerCleanupBarrier.beginPlayback()
                router.presentOfflinePlayer(
                    downloadId: choice.downloadId,
                    contentId: choice.leafContentId,
                    startFromBeginning: choice.startFromBeginning,
                    resumePosition: choice.resumePosition
                )
            }
            Button(.detailOfflineChoiceStream) {
                presentStreamingPlayer(
                    contentId: choice.contentId,
                    fileId: choice.fileId,
                    pinsVersion: choice.pinsVersion,
                    audioTrackIndex: choice.audioTrackIndex,
                    subtitleTrackIndex: choice.subtitleTrackIndex,
                    startFromBeginning: choice.startFromBeginning,
                    resumePosition: choice.resumePosition
                )
            }
            Button(.commonCancel, role: .cancel) {}
        } message: { _ in
            Text(.detailOfflineChoiceBody)
        }
        .personalStateNoticeAlert($viewModel.personalStateNotice)
        .alert(
            Text(.detailUnreachableTitle),
            isPresented: Binding(
                get: { unreachablePlayRequest != nil },
                set: { if !$0 { unreachablePlayRequest = nil } }
            ),
            presenting: unreachablePlayRequest
        ) { request in
            // Reachability state can be stale (e.g. the server just came
            // back), so always leave an escape hatch to attempt the stream.
            Button(.detailUnreachableTryAnyway) {
                Task { await ConnectionMonitor.shared.probeServer() }
                presentStreamingPlayer(
                    contentId: request.contentId,
                    fileId: request.fileId,
                    pinsVersion: request.pinsVersion,
                    audioTrackIndex: request.audioTrackIndex,
                    subtitleTrackIndex: request.subtitleTrackIndex,
                    startFromBeginning: request.startFromBeginning,
                    resumePosition: request.resumePosition
                )
            }
            Button(.commonCancel, role: .cancel) {}
        } message: { _ in
            Text(ConnectionMonitor.shared.isDeviceOnline
                ? LocalizedStringResource.detailUnreachableServerDown
                : .detailUnreachableOffline)
        }
        #if os(iOS)
        // The card draws its own floating controls, which also decide when
        // the navigation bar shows (see `PhoneDetailTopChrome`).
        .overlay(alignment: .top) {
            detailTopControls
        }
        .onGeometryChange(for: Bool.self) { proxy in
            PhoneDetailHeroLayout.usesSplitLayout(pageSize: proxy.size, verticalSizeClass: verticalSizeClass)
        } action: { isSplit in
            isSplitPage = isSplit
        }
        .onGeometryChange(for: StatusColumnLayout?.self) { proxy in
            StatusColumnLayout(safeArea: proxy.safeAreaInsets)
        } action: { column in
            statusColumn = column
        }
        .overlay {
            if let statusColumn {
                statusColumnRemoteButton(statusColumn)
            }
        }
        .sheet(item: $controlRequestBox, onDismiss: { router.refitItemDetail() }) { box in
            SiloControlTargetPickerView(request: box.request, controller: siloControl)
        }
        .sheet(isPresented: $isShowingControlPicker, onDismiss: { router.refitItemDetail() }) {
            SiloControlTargetPickerView(request: nil, controller: siloControl)
        }
        .siloRemoteControl(
            isPresented: $isShowingRemoteControl,
            coversWindow: router.presentsItemDetailFullWindow || isBesideStatusColumn,
            controller: siloControl,
            onDismiss: { router.refitItemDetail() }
        )
        // Refitting the detail would discard these, so it waits for them.
        .onChange(of: isShowingControl) { _, showing in
            router.itemDetailShowsControl = showing
        }
        .onChange(of: seriesSelection) { _, selection in
            if let selection { onSeriesSelection?(selection) }
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
            leadingSystemName: showsClose ? "xmark" : (showsBack ? "chevron.backward" : nil),
            leadingAccessibilityLabel: showsClose
                ? AppLanguage.string(.detailCloseDetails, locale: locale)
                : (showsBack ? AppLanguage.string(.commonBack, locale: locale) : nil),
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
            onTrailingTap: handleRemoteControlTap,
            cornerInset: isSplitPage ? PhoneDetailHeroLayout.splitCloseButtonInset : nil
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
    /// The Remote button in the status column, at the bottom where the tab
    /// pages keep their actions. The top of the column belongs to the system
    /// and grows when the Dynamic Island shows an activity.
    private func statusColumnRemoteButton(_ layout: StatusColumnLayout) -> some View {
        Button(action: handleRemoteControlTap) {
            Image(systemName: siloControl.remotePlaybackEngaged ? "appletvremote.gen4.fill" : "appletvremote.gen4")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: SiloTheme.topBarIconHitSize, height: SiloTheme.topBarIconHitSize)
                .siloGlass(in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(.detailRemoteControl))
        .statusColumnCentered(layout)
        .padding(.bottom, StatusColumnBar.bottomMargin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: layout.edge == .leading ? .bottomLeading : .bottomTrailing)
        .ignoresSafeArea(edges: [layout.edgeSet, .bottom])
    }

    private func handleRemoteControlTap() {
        if let detail = viewModel.detail, isDirectlyPlayable(detail) {
            // The TV resumes from the request's explicit position, so read
            // the server's current one rather than the page's snapshot, and
            // resolve the file from the same state.
            controlResumeLookupTask?.cancel()
            controlResumeLookupTask = Task {
                let state = await refreshedResumeState(contentId: contentId)
                guard !Task.isCancelled else { return }
                controlResumeLookupTask = nil
                let start = playbackStart(
                    for: detail,
                    startFromBeginning: false,
                    resumePosition: state.resumePosition(cached: detail.userData),
                    watchState: state.userData(cached: detail.userData)
                )
                playOnTV(SiloControlPlaybackRequest(
                    contentId: contentId,
                    fileId: start.fileId,
                    audioTrackIndex: start.audioTrackIndex,
                    subtitleTrackIndex: start.subtitleTrackIndex,
                    startFromBeginning: false,
                    resumePosition: start.resumePosition,
                    pinsVersion: preferredVersionFileId != nil
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
                selectedNextUpEditionId: preferredNextUpEditionId,
                selectedNextUpAudioTrackIndex: preferredNextUpAudioTrackIndex,
                selectedNextUpSubtitleTrackIndex: preferredNextUpSubtitleTrackIndex,
                nextUpWatchDetail: nextUpWatchDetail,
                nextUpSubtitleOverrideCleared: didClearNextUpSubtitleOverride,
                isLoadingSelectedEpisodePlayback: isLoadingNextUpWatchDetail,
                selectedEpisodeContentId: playbackEpisode(for: detail)?.contentId,
                onSelectSeason: { season in
                    selectedSeriesEpisodeId = nil
                    Task { await viewModel.selectSeason(season) }
                },
                onPlayEpisode: { id, fileId, startFromBeginning, resumePosition, watchState in
                    awaitsPlaybackReturn = true
                    SeriesPlaybackReturnInbox.discardPending()
                    let usesSelectedEpisodeControls = id == playbackEpisode(for: detail)?.contentId
                    let resumePosition = startFromBeginning ? nil : resumePosition
                    let start = usesSelectedEpisodeControls
                        ? nextUpPlaybackStart(
                            pinnedFileId: fileId,
                            contentId: id,
                            startFromBeginning: startFromBeginning,
                            resumePosition: resumePosition,
                            watchState: watchState
                        ) : nil
                    presentPlayerFromDetail(
                        contentId: id,
                        fileId: start?.fileId,
                        // `fileId` is set only by a version picked for this episode.
                        pinsVersion: usesSelectedEpisodeControls && fileId != nil,
                        audioTrackIndex: start?.audioTrackIndex,
                        subtitleTrackIndex: start?.subtitleTrackIndex,
                        startFromBeginning: startFromBeginning,
                        resumePosition: start.map(\.resumePosition) ?? resumePosition
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
                onSelectNextUpVersion: { selectNextUpVersion($0) },
                onSelectNextUpEdition: { selectNextUpEdition($0) },
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
                    didClearNextUpSubtitleOverride = (index == nil)
                    preferredNextUpSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                        for: nextUpWatchDetail,
                        versionFileId: preferredNextUpFileId,
                        candidate: index
                    )
                    persistSubtitleSelection(
                        prefKey: prefKey(for: nextUpWatchDetail),
                        version: effectiveVersion(for: nextUpWatchDetail, versionFileId: preferredNextUpFileId),
                        requested: index,
                        sanitized: preferredNextUpSubtitleTrackIndex
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
                onNavigateToItem: { router.openRelatedTitle(contentId: $0) },
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
                boxSet: viewModel.boxSet,
                selectedVersionFileId: preferredVersionFileId,
                selectedEditionId: preferredEditionId,
                selectedAudioTrackIndex: preferredAudioTrackIndex,
                selectedSubtitleTrackIndex: preferredSubtitleTrackIndex,
                subtitleOverrideCleared: didClearSubtitleOverride,
                onPlay: { startFromBeginning, resumePosition, watchState in
                    // Track picks only travel with the file they were made on.
                    let start = playbackStart(
                        for: detail,
                        startFromBeginning: startFromBeginning,
                        resumePosition: startFromBeginning ? nil : resumePosition,
                        watchState: watchState
                    )
                    presentPlayerFromDetail(
                        contentId: contentId,
                        fileId: start.fileId,
                        pinsVersion: preferredVersionFileId != nil,
                        audioTrackIndex: start.audioTrackIndex,
                        subtitleTrackIndex: start.subtitleTrackIndex,
                        startFromBeginning: startFromBeginning,
                        resumePosition: start.resumePosition
                    )
                },
                refreshResumeState: { await refreshedResumeState(contentId: contentId) },
                onSelectVersion: { selectVersion($0, in: detail) },
                onSelectEdition: { selectEdition($0, in: detail) },
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
                    preferredSubtitleTrackWasManuallySelected = true
                    preferredSubtitleTrackIndex = sanitizedSubtitleTrackIndex(
                        for: detail,
                        versionFileId: preferredVersionFileId,
                        candidate: index
                    )
                    preferredSubtitleTrackFileId = effectiveVersion(
                        for: detail,
                        versionFileId: preferredVersionFileId
                    )?.fileId
                    persistSubtitleSelection(
                        prefKey: prefKey(for: detail),
                        version: effectiveVersion(for: detail, versionFileId: preferredVersionFileId),
                        requested: index,
                        sanitized: preferredSubtitleTrackIndex
                    )
                },
                onToggleFavorite: { Task { await viewModel.toggleFavorite() } },
                onToggleWatchlist: { Task { await viewModel.toggleWatchlist() } },
                onToggleWatched: { Task { await viewModel.toggleWatched() } },
                onPersonTap: { openPerson($0) },
                onNavigateToItem: { router.openRelatedTitle(contentId: $0) },
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

    /// The file and track picks Play sends: the file the page shows, for
    /// the watch state the resume position came from (`watchState`). Only a
    /// Version pick pins it (`pinsVersion`); otherwise the server may fall
    /// back to another file of the same edition.
    private func playbackStart(
        for detail: ItemDetail,
        startFromBeginning: Bool,
        resumePosition: Double?,
        watchState: LeafItemUserData?
    ) -> DetailVersionSelection.PageStart {
        DetailVersionSelection.pageStart(
            versions: detail.versions ?? [],
            pinnedFileId: preferredVersionFileId,
            editionId: preferredEditionId,
            shownWith: detail.userData,
            startsWith: watchState,
            resumePosition: resumePosition,
            preferredQualityId: detailQuality(onMeteredNetwork: nil),
            startFromBeginning: startFromBeginning,
            audioTrackIndex: preferredAudioTrackIndex,
            subtitleTrackIndex: preferredSubtitleTrackIndex,
            variants: detail.playbackVariants
        )
    }

    /// The selected episode's start. No file while its files are still
    /// loading, so a quick Play never sends the previous episode's file.
    /// `pinnedFileId` is a version picked for this episode.
    private func nextUpPlaybackStart(
        pinnedFileId: Int?,
        contentId: String,
        startFromBeginning: Bool,
        resumePosition: Double?,
        watchState: LeafItemUserData?
    ) -> DetailVersionSelection.PageStart {
        guard let nextUpWatchDetail, nextUpWatchDetail.contentId == contentId else {
            return .unresolved(resumePosition: resumePosition)
        }
        return DetailVersionSelection.pageStart(
            versions: nextUpWatchDetail.versions,
            pinnedFileId: pinnedFileId ?? preferredNextUpFileId,
            editionId: preferredNextUpEditionId,
            shownWith: nextUpWatchDetail.userData,
            startsWith: watchState,
            resumePosition: resumePosition,
            preferredQualityId: detailQuality(onMeteredNetwork: nil),
            startFromBeginning: startFromBeginning,
            audioTrackIndex: preferredNextUpAudioTrackIndex,
            subtitleTrackIndex: preferredNextUpSubtitleTrackIndex
        )
    }

    private func selectVersion(_ fileId: Int?, in detail: ItemDetail) {
        // A pin records its cut, so Auto stays there once the pin is cleared.
        if let fileId {
            preferredEditionId = PlaybackEditions.edition(forFileId: fileId, in: detail.versions ?? [])?.id
        }
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
        preferredSubtitleTrackFileId = effectiveVersion(for: detail, versionFileId: fileId)?.fileId
    }

    /// An Edition pick: Version returns to Auto in that edition. When that
    /// changes the file, the audio pick and a subtitle track pick named
    /// streams of the old file, so they go, as on a connection change:
    /// subtitle Auto and Off stay, and the subtitle reseeds for the new
    /// file. The subtitle pick's file is not rewritten to the new one.
    private func selectEdition(_ id: String, in detail: ItemDetail) {
        let before = effectiveVersion(for: detail, versionFileId: preferredVersionFileId)?.fileId
        preferredEditionId = id
        preferredVersionFileId = nil
        guard effectiveVersion(for: detail, versionFileId: nil)?.fileId != before else { return }
        preferredAudioTrackIndex = nil
        reseedSubtitleOverride()
    }

    /// `selectEdition` for the selected episode.
    private func selectNextUpEdition(_ id: String) {
        let before = effectiveVersion(for: nextUpWatchDetail, versionFileId: preferredNextUpFileId)?.fileId
        preferredNextUpEditionId = id
        preferredNextUpFileId = nil
        guard let nextUpWatchDetail,
              effectiveVersion(for: nextUpWatchDetail, versionFileId: nil)?.fileId != before else { return }
        preferredNextUpAudioTrackIndex = nil
        preferredNextUpSubtitleTrackIndex = DetailPlaybackFormatting.subtitleIndexAfterFileChange(
            preferredNextUpSubtitleTrackIndex
        ) { launchSubtitleIndex(for: nextUpWatchDetail) }
    }

    private func selectNextUpVersion(_ fileId: Int?) {
        if let fileId {
            preferredNextUpEditionId = PlaybackEditions.edition(forFileId: fileId, in: nextUpWatchDetail?.versions ?? [])?.id
        }
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

    /// The connection moved between Wi-Fi and mobile data, which can change
    /// Auto's file under the open page. Track picks made on the old file name
    /// streams of that file, so they're dropped and reseeded as on a reload.
    private func reconcileTracksAfterConnectionChange(wasMetered: Bool) {
        if preferredVersionFileId == nil, let detail = viewModel.detail,
           let before = effectiveVersion(for: detail, versionFileId: nil, onMeteredNetwork: wasMetered) {
            // The connection never changes the cut: keep the one shown.
            if preferredEditionId == nil {
                preferredEditionId = PlaybackEditions.edition(forFileId: before.fileId, in: detail.versions ?? [])?.id
            }
            if before.fileId != effectiveVersion(for: detail, versionFileId: nil)?.fileId {
                preferredAudioTrackIndex = nil
                reseedSubtitleOverride()
            }
        }
        if preferredNextUpFileId == nil, let nextUpWatchDetail,
           let before = effectiveVersion(for: nextUpWatchDetail, versionFileId: nil, onMeteredNetwork: wasMetered) {
            if preferredNextUpEditionId == nil {
                preferredNextUpEditionId = PlaybackEditions.edition(forFileId: before.fileId, in: nextUpWatchDetail.versions)?.id
            }
            if before.fileId != effectiveVersion(for: nextUpWatchDetail, versionFileId: nil)?.fileId {
                preferredNextUpAudioTrackIndex = nil
                preferredNextUpSubtitleTrackIndex = DetailPlaybackFormatting.subtitleIndexAfterFileChange(
                    preferredNextUpSubtitleTrackIndex
                ) { launchSubtitleIndex(for: nextUpWatchDetail) }
            }
        }
    }

    /// The quality Auto ranks with: the current connection's, or the one
    /// for `onMeteredNetwork` when asking what it was before a change.
    private func detailQuality(onMeteredNetwork: Bool?) -> String {
        onMeteredNetwork.map { PlayerSettings.shared.preferredQuality(onMeteredNetwork: $0) }
            ?? PlayerSettings.shared.connectionPreferredQuality
    }

    /// The movie's file, in the edition picked on this visit.
    private func effectiveVersion(
        for detail: ItemDetail,
        versionFileId: Int?,
        onMeteredNetwork: Bool? = nil
    ) -> FileVersion? {
        DetailVersionSelection.displayVersion(
            versions: detail.versions ?? [],
            selectedFileId: versionFileId,
            lastFileId: detail.userData?.lastFileId,
            lastFileInProgress: detail.userData?.hasResumePoint ?? false,
            preferredQualityId: detailQuality(onMeteredNetwork: onMeteredNetwork),
            editionId: preferredEditionId,
            lastEditionKey: detail.userData?.lastEditionKey,
            variants: detail.playbackVariants
        )
    }

    /// The selected episode's file, in the edition picked for it.
    private func effectiveVersion(
        for detail: WatchDetail?,
        versionFileId: Int?,
        onMeteredNetwork: Bool? = nil
    ) -> FileVersion? {
        guard let detail else { return nil }
        return DetailVersionSelection.displayVersion(
            versions: detail.versions,
            selectedFileId: versionFileId,
            lastFileId: detail.userData?.lastFileId,
            lastFileInProgress: detail.userData?.hasResumePoint ?? false,
            preferredQualityId: detailQuality(onMeteredNetwork: onMeteredNetwork),
            editionId: preferredNextUpEditionId,
            lastEditionKey: detail.userData?.lastEditionKey
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
        // A remembered pick of a track the server can't deliver falls back
        // to Auto: starting on it would be refused.
        let available = version.subtitleTracks?.filter { !$0.hasUnsupportedFormat }.compactMap(\.selectionIndex) ?? []
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
        // A remembered pick of a track the server can't deliver falls back
        // to Auto: starting on it would be refused.
        let available = version.subtitleTracks?.filter { !$0.hasUnsupportedFormat }.compactMap(\.selectionIndex) ?? []
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
            showForced: detail.showsForcedSubtitles,
            usesDeviceSettings: PlayerSettings.shared.subtitleMatchesSystemAppearance
        )
    }

    /// Re-derive the seeded subtitle from the current detail unless the user
    /// picked one on this visit and the reloaded page still shows it: the
    /// same file, which still offers that track.
    private func reseedSubtitleOverride() {
        if preferredSubtitleTrackWasManuallySelected {
            guard let detail = viewModel.detail else { return }
            let keepsPick = DetailPlaybackFormatting.keepsManualSubtitlePick(
                preferredSubtitleTrackIndex,
                pickedFileId: preferredSubtitleTrackFileId,
                reloadedFileId: effectiveVersion(for: detail, versionFileId: preferredVersionFileId)?.fileId
            ) { index in
                sanitizedSubtitleTrackIndex(
                    for: detail,
                    versionFileId: preferredVersionFileId,
                    candidate: index
                ) != nil
            }
            if keepsPick { return }
            preferredSubtitleTrackWasManuallySelected = false
            preferredSubtitleTrackFileId = nil
        }
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
        sanitized: Int?
    ) {
        guard let prefKey else { return }
        guard let requested else {
            TrackSelectionPersistence.clearSubtitle(prefKey: prefKey)
            return
        }
        guard requested == sanitized, let version,
              let request = TrackSelectionPersistence.subtitleRequest(version: version, ffIndex: requested)
        else { return }
        TrackSelectionPersistence.saveSubtitle(prefKey: prefKey, request: request)
    }

    private func nextUpEpisode(for detail: ItemDetail) -> EpisodeListItem? {
        guard detail.type == "series" else { return nil }
        return viewModel.episodes.preferredResumeEpisode()
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
        didClearNextUpSubtitleOverride = false
        guard let nextUp = playbackEpisode(for: detail) else {
            nextUpWatchDetail = nil
            isLoadingNextUpWatchDetail = false
            preferredNextUpFileId = nil
            preferredNextUpEditionId = nil
            preferredNextUpAudioTrackIndex = nil
            preferredNextUpSubtitleTrackIndex = nil
            return
        }

        let requestedContentId = nextUp.contentId
        let cacheKey = CacheKey.itemWatchDetail(requestedContentId, libraryId: libraryId)
        let cached: WatchDetail? = ResponseCache.shared.get(cacheKey)
        preferredNextUpFileId = nil
        preferredNextUpEditionId = nil
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
                && preferredNextUpEditionId == nil
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
            showForced: watchDetail.showsForcedSubtitles,
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
        DescriptionTranslationView(viewModel: viewModel)
    }

    private func presentPlayerFromDetail(
        contentId: String,
        fileId: Int? = nil,
        pinsVersion: Bool = false,
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
                pinsVersion: pinsVersion,
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
                playerCleanupGeneration = PlayerCleanupBarrier.beginPlayback()
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
                downloadedLabel: Self.downloadedOptionLabel(for: record, locale: locale),
                contentId: contentId,
                fileId: fileId,
                pinsVersion: pinsVersion,
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
                pinsVersion: pinsVersion,
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
            pinsVersion: pinsVersion,
            audioTrackIndex: audioTrackIndex,
            subtitleTrackIndex: subtitleTrackIndex,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition
        )
    }

    private func presentStreamingPlayer(
        contentId: String,
        fileId: Int?,
        pinsVersion: Bool,
        audioTrackIndex: Int?,
        subtitleTrackIndex: Int?,
        startFromBeginning: Bool,
        resumePosition: Double?
    ) {
        playerCleanupGeneration = PlayerCleanupBarrier.beginPlayback()
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
            pinsVersion: pinsVersion,
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
    private static func downloadedOptionLabel(for record: DownloadRecord, locale: Locale) -> String {
        var parts: [String] = []
        let quality = record.effectiveQuality ?? record.format
        if !quality.isEmpty {
            parts.append(DownloadFormat(rawValue: quality)?.displayName ?? quality.capitalized)
        }
        if record.fileSize > 0 {
            parts.append(LocaleFormat.bytes(record.fileSize, locale: locale))
        }
        return AppLanguage.string(
            parts.isEmpty
                ? .detailPlayDownloaded
                : .detailPlayDownloadedDetails(parts.joined(separator: " · ")),
            locale: locale
        )
    }
}
#endif
