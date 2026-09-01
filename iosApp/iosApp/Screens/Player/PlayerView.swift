import AetherEngine
import SwiftUI

/// Full-screen video player. Thin shell around `PlayerViewModel` that picks
/// the platform-appropriate controls overlay. iOS gets touch-driven controls
/// with bottom sheets; tvOS gets a focus-driven transport bar plus the
/// floating HUD for route, track, chapter, and playback controls.
struct PlayerView: View {
    let contentId: String
    let preferredFileId: Int?
    let preferredAudioTrackIndex: Int?
    let preferredSubtitleTrackIndex: Int?
    /// `true` when the caller explicitly asked to restart from zero rather
    /// than honoring the server-side resume position. Forwarded to the
    /// session bridge so both direct-play and transcode paths align.
    let startFromBeginning: Bool
    let resumePositionOverride: Double?
    let prefersLastUsedVersion: Bool
    /// Set when the caller wants offline playback of a completed download.
    /// Routes the prepare through `OfflinePlaybackBuilder` (stored manifest
    /// + local media file, no server session) so playback works with no
    /// network and progress queues for the next `/sync/progress` flush.
    let offlineDownloadId: String?
    /// Optional poster/backdrop URLs the presenter already has on hand.
    /// When set, the now-playing widget skips its own catalog-item fetch
    /// for artwork. Nil falls back to the prior fetch-on-prepare path.
    let posterURLHint: String?
    let backdropURLHint: String?
    let onPlaybackStarted: (() -> Void)?

    @State private var viewModel = PlayerViewModel()
    @State private var didNotifyPlaybackStarted = false
    @Environment(\.dismiss) var dismiss
    #if os(iOS)
    @State private var orientationCoordinator = PlayerOrientationCoordinator.shared
    #endif
    #if os(tvOS)
    @State private var remoteIdentityNotice: RemotePlaybackIdentityManager.ActiveIdentity?
    @State private var isTimelinePreviewVisible = false
    @State private var timelineTimeDisplayMode: TVPlayerTimeDisplayMode = .elapsedRemaining
    @State private var timelineSelectionRequest: UUID?
    @State private var timelinePreviewHideTask: Task<Void, Never>?
    @State private var timelinePreviewContactCanToggle = false
    #endif

    init(
        contentId: String,
        preferredFileId: Int? = nil,
        preferredAudioTrackIndex: Int? = nil,
        preferredSubtitleTrackIndex: Int? = nil,
        startFromBeginning: Bool = false,
        resumePositionOverride: Double? = nil,
        prefersLastUsedVersion: Bool = false,
        offlineDownloadId: String? = nil,
        posterURLHint: String? = nil,
        backdropURLHint: String? = nil,
        onPlaybackStarted: (() -> Void)? = nil
    ) {
        self.contentId = contentId
        self.preferredFileId = preferredFileId
        self.preferredAudioTrackIndex = preferredAudioTrackIndex
        self.preferredSubtitleTrackIndex = preferredSubtitleTrackIndex
        self.startFromBeginning = startFromBeginning
        self.resumePositionOverride = resumePositionOverride
        self.prefersLastUsedVersion = prefersLastUsedVersion
        self.offlineDownloadId = offlineDownloadId
        self.posterURLHint = posterURLHint
        self.backdropURLHint = backdropURLHint
        self.onPlaybackStarted = onPlaybackStarted
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.ignoresSafeArea()

            if let error = viewModel.error {
                errorView(error)
            } else {
                if viewModel.showNextUpScreen {
                    PlayerNextUpScreen(
                        viewModel: viewModel,
                        onBack: {
                            if !viewModel.keepWatchingCurrentEpisode() {
                                dismissPlayer()
                            }
                        },
                        miniPlayer: { playerSurface(ignoresSafeArea: false) }
                    )
                    .transition(.opacity)
                } else {
                    playerSurface()

                    #if os(tvOS)
                    // Focus sink with UIKit-backed press capture. Mounted
                    // whenever the transport overlay is hidden OR a seek
                    // session is active — in both cases it's the sole target
                    // for the Siri Remote.
                    //
                    // Two modes:
                    //   • Not in seek mode: Tap Left/Right = quick skip,
                    //     Tap Down = open the player menu, Tap Up = reveal the
                    //     full transport HUD, Tap Select = pause and
                    //     enter the focused timeline,
                    //     Hold Left/Right = enter seek mode.
                    //   • In seek mode: Tap Left/Right = adjust rate along
                    //     the signed ladder, Tap Select = commit + exit,
                    //     Menu = cancel + exit (handled in onExitCommand).
                    //     Taps against Up/Down are ignored; holds are no-ops.
                    // Never while the HUD is presented: the sink and the HUD's
                    // focus graph would be two owners for the same presses
                    // (docs/tvos-focus.md), and the sink's Down handler
                    // force-switches the HUD tab underneath the user.
                    if !viewModel.isLoading && !viewModel.isHUDPresented &&
                        (!(viewModel.showIntroSkip || viewModel.showCreditsSkip) || viewModel.isHoldSeeking) &&
                        (!viewModel.showControls || viewModel.isHoldSeeking) {
                        TVPressCaptureView(
                            onArrowTap: { direction in
                                if viewModel.isHoldSeeking {
                                    switch direction {
                                    case .left:  viewModel.adjustHoldSeekRate(delta: -1)
                                    case .right: viewModel.adjustHoldSeekRate(delta: +1)
                                    case .up, .down: break
                                    }
                                } else {
                                    switch direction {
                                    case .left:  viewModel.skipBackward()
                                    case .right: viewModel.skipForward()
                                    case .down:  viewModel.openSettingsHUD()
                                    case .up:    viewModel.revealControls()
                                    }
                                }
                            },
                            onArrowHoldBegin: { direction in
                                // Only Left / Right enter seek mode. Hold on
                                // Up / Down is ignored so it can't be
                                // accidentally triggered while skipping.
                                switch direction {
                                case .left:  viewModel.beginHoldSeek(forward: false)
                                case .right: viewModel.beginHoldSeek(forward: true)
                                case .up, .down: break
                                }
                            },
                            onDirectionalPressBegan: {
                                timelinePreviewContactCanToggle = false
                            },
                            onTouchSurfaceContactBegan: {
                                handleTimelinePreviewContactBegan()
                            },
                            onTouchSurfaceContactEnded: {
                                handleTimelinePreviewContactEnded()
                            },
                            onTouchSurfaceContactCancelled: {
                                handleTimelinePreviewContactCancelled()
                            },
                            onSelect: {
                                if viewModel.isHoldSeeking {
                                    viewModel.commitHoldSeek()
                                } else if viewModel.isPlaying {
                                    timelinePreviewContactCanToggle = false
                                    hideTimelinePreview(immediately: true)
                                    viewModel.pauseForTimelineSelection()
                                    timelineSelectionRequest = UUID()
                                } else {
                                    viewModel.revealControls()
                                }
                            }
                        )
                        .ignoresSafeArea()
                    }

                    // `isLoading` also covers Protocol V3 replans (track or
                    // quality changes made *from inside the HUD*). Unmounting
                    // here for those would destroy the HUD's @State/@FocusState
                    // mid-press and reseed focus on a reset tab, so the HUD
                    // keeps its host mounted through a replan. A replacement
                    // load closes the HUD in `resetPublishedLoadState`, so
                    // cold starts and item changes still unmount as before.
                    if (!viewModel.isLoading || viewModel.isHUDPresented) && !viewModel.isHoldSeeking {
                        TVPlayerControls(
                            viewModel: viewModel,
                            showsTimelinePreview: isTimelinePreviewVisible,
                            timeDisplayMode: timelineTimeDisplayMode,
                            timelineSelectionRequest: timelineSelectionRequest,
                            onToggleTimeDisplayMode: {
                                withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
                                    timelineTimeDisplayMode.toggle()
                                }
                            },
                            onDismiss: { dismissPlayer() }
                        )
                    }

                    // Speed-indicator chip shown only while a seek session is
                    // active. The overlay/scrubber is suppressed during the
                    // session (so the capture view keeps focus), so this chip
                    // is the sole source of visual feedback until Select
                    // commits or Menu cancels.
                    if viewModel.isHoldSeeking {
                        HoldSeekIndicator(
                            rate: viewModel.holdSeekRate,
                            previewTime: viewModel.scrubPreviewTime,
                            duration: viewModel.duration,
                            previewImage: viewModel.scrubPreviewImage
                        )
                        .transition(.opacity)
                        .allowsHitTesting(false)
                    }
                    #else
                    // The full controls overlay (and its close button) only
                    // mounts once the decoder opens the file, so a standalone
                    // close control has to cover the load/buffer phase —
                    // otherwise the only way out of a stalled start is
                    // force-quitting the app. tvOS gets this via Menu in
                    // `onExitCommand`; macOS keeps its controls (and Escape)
                    // during loading.
                    if viewModel.isLoading {
                        loadingCloseButton
                    }

                    if !viewModel.isLoading {
                        // Invisible gestures (tap-to-toggle, double-tap skip,
                        // hold-2×, edge swipes, pinch) live in a dedicated
                        // layer under the button overlay.
                        MobilePlayerGestureLayer(
                            viewModel: viewModel,
                            onDismiss: { dismissPlayer() }
                        )
                        MobilePlayerControls(
                            viewModel: viewModel,
                            orientationCoordinator: orientationCoordinator,
                            onDismiss: { dismissPlayer() }
                        )
                    }
                    #endif

                    #if os(tvOS)
                    if let identity = remoteIdentityNotice {
                        RemotePlaybackIdentityNotice(identity: identity)
                            .transition(.opacity)
                    } else if let notice = viewModel.activeNotice {
                        PlayerNoticeOverlay(notice: notice)
                    }
                    #else
                    if let notice = viewModel.activeNotice {
                        PlayerNoticeOverlay(notice: notice)
                    }
                    #endif
                }

                if viewModel.isLoading || viewModel.isBuffering {
                    PlayerBufferingCapsule()
                }
            }
        }
        #if os(tvOS)
        // Physical Play/Pause on the Siri remote always toggles playback
        // and brings the transport bar back.
        .onPlayPauseCommand {
            if viewModel.showNextUpScreen {
                viewModel.playNextEpisodeNow()
            } else {
                viewModel.togglePlayPause()
            }
        }
        // Menu button: step seek-session → HUD → overlay → dismiss.
        // Matches the Infuse / Apple TV pattern. Runs at the shell level
        // so it fires even if focus has drifted — the HUD's own
        // `onExitCommand` handles the common case where focus is inside
        // it; this fallback keeps the user from getting stuck.
        .onExitCommand {
            if viewModel.showNextUpScreen {
                if !viewModel.keepWatchingCurrentEpisode() {
                    dismissPlayer()
                }
            } else if viewModel.isHoldSeeking {
                viewModel.cancelHoldSeek()
            } else if viewModel.isHUDPresented {
                // Before the `isLoading` escape: a replan issued from the HUD
                // keeps the HUD mounted while `isLoading` is true, and Menu
                // during that window must close the HUD, not exit the player.
                // A genuinely stalled load is still escapable — the first
                // Menu closes the HUD, the next one lands below.
                viewModel.closeHUD()
            } else if viewModel.isLoading {
                dismissPlayer()
            } else if !viewModel.isPlaying {
                // While paused, Menu exits the player instead of hiding the
                // controls over a frozen frame.
                dismissPlayer()
            } else if viewModel.showControls {
                viewModel.dismissControls()
            } else {
                dismissPlayer()
            }
        }
        #endif
        .onChange(of: viewModel.isPlaying) { _, isPlaying in
            guard isPlaying, !didNotifyPlaybackStarted else { return }
            didNotifyPlaybackStarted = true
            onPlaybackStarted?()
        }
        #if os(tvOS)
        .onChange(of: viewModel.showControls) { _, visible in
            if visible {
                hideTimelinePreview()
            } else {
                timelineTimeDisplayMode = .elapsedRemaining
            }
        }
        #endif
        .onChange(of: viewModel.remoteDismissToken) { _, newValue in
            guard newValue != nil else { return }
            dismissPlayer()
        }
        .onAppear {
            #if os(iOS)
            // A Picture in Picture restore re-presents this cover for a session
            // that is still playing. Adopt that view model instead of minting a
            // new one, and skip the load — the session never stopped.
            if let restored = PlayerPresentationRestoration.consumeAdoption(matching: contentId) {
                viewModel = restored
                orientationCoordinator.activatePlayer()
                restored.playerPresentationDidAppear()
                bindPictureInPicture(to: restored)
                return
            }
            #endif
            let activeViewModel: PlayerViewModel
            if viewModel.needsReplacementForPresentation {
                let replacement = PlayerViewModel()
                viewModel = replacement
                activeViewModel = replacement
            } else {
                activeViewModel = viewModel
            }
            #if os(iOS)
            orientationCoordinator.activatePlayer()
            activeViewModel.playerPresentationDidAppear()
            bindPictureInPicture(to: activeViewModel)
            #endif
            activeViewModel.applyArtworkURLHints(posterURL: posterURLHint, backdropURL: backdropURLHint)
            activeViewModel.loadAndPlay(
                contentId: contentId,
                preferredFileId: preferredFileId,
                preferredAudioTrackIndex: preferredAudioTrackIndex,
                preferredSubtitleTrackIndex: preferredSubtitleTrackIndex,
                startFromBeginning: startFromBeginning,
                resumePositionOverride: resumePositionOverride,
                prefersLastUsedVersion: prefersLastUsedVersion,
                offlineDownloadId: offlineDownloadId
            )
            #if os(tvOS)
            TVControlReceiver.shared.registerPlayer(activeViewModel, contentId: contentId)
            withAnimation(.easeInOut(duration: 0.2)) {
                remoteIdentityNotice = RemotePlaybackIdentityManager.shared.activeIdentity
            }
            #endif
        }
        #if os(tvOS)
        .task(id: remoteIdentityNotice?.generationID) {
            guard remoteIdentityNotice != nil else { return }
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) {
                remoteIdentityNotice = nil
            }
        }
        #endif
        .onDisappear {
            #if os(tvOS)
            timelinePreviewHideTask?.cancel()
            timelinePreviewHideTask = nil
            #endif
            #if os(iOS)
            viewModel.playerPresentationDidDisappear()
            #else
            viewModel.cleanup()
            #endif
            #if os(tvOS)
            TVControlReceiver.shared.unregisterPlayer(viewModel)
            #endif
            #if os(iOS)
            orientationCoordinator.deactivatePlayer()
            #endif
            #if os(tvOS)
            // Progress/watched state for this item (and its parent
            // season/series) was mutated server-side during playback.
            // Flag the detail cache so the next visit to any of those
            // pages shows corrected userData instead of pre-play values.
            let touchedContentIds = viewModel.contentIdsNeedingDetailRefresh
            if touchedContentIds.isEmpty {
                ItemDetailCache.shared.markStaleFamily(contentId: contentId)
            } else {
                for id in touchedContentIds {
                    ItemDetailCache.shared.markStaleFamily(contentId: id)
                }
            }
            #endif
        }
        .continuumStatusBarHidden()
        #if !os(tvOS)
        .navigationBarHidden(true)
        #endif
        .preferredColorScheme(.dark)
    }

    private func dismissPlayer() {
        viewModel.cleanup()
        dismiss()
    }

    #if os(iOS)
    /// One binding site so the restore and start-failure hooks can never be
    /// installed on one path and forgotten on the other.
    private func bindPictureInPicture(to model: PlayerViewModel) {
        PictureInPictureCoordinator.shared.bind(
            engine: model.aetherEngine,
            owner: model,
            onEngagementEnded: { [weak model] in
                model?.pictureInPictureEngagementDidEnd()
            },
            onRestoreUserInterface: { [weak model] completion in
                guard let model else {
                    // The engaged player is gone; AVKit must not be told the
                    // interface came back.
                    completion(false)
                    return
                }
                model.restorePictureInPictureUserInterface(completion)
            },
            onStartFailure: { [weak model] failure in
                model?.reportPictureInPictureStartFailure(failure)
            }
        )
    }
    #endif

    #if os(tvOS)
    private func handleTimelinePreviewContactBegan() {
        guard viewModel.isPlaying,
              !viewModel.showControls,
              !viewModel.isHUDPresented,
              !viewModel.isHoldSeeking else { return }

        timelinePreviewHideTask?.cancel()
        timelinePreviewHideTask = nil
        timelinePreviewContactCanToggle = isTimelinePreviewVisible
        withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
            if !isTimelinePreviewVisible {
                isTimelinePreviewVisible = true
            }
        }
    }

    private func handleTimelinePreviewContactEnded() {
        guard isTimelinePreviewVisible else { return }
        if timelinePreviewContactCanToggle {
            withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
                timelineTimeDisplayMode.toggle()
            }
        }
        timelinePreviewContactCanToggle = false
        scheduleTimelinePreviewHide()
    }

    private func handleTimelinePreviewContactCancelled() {
        timelinePreviewContactCanToggle = false
        scheduleTimelinePreviewHide()
    }

    private func scheduleTimelinePreviewHide() {
        guard isTimelinePreviewVisible else { return }
        timelinePreviewHideTask?.cancel()
        timelinePreviewHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            hideTimelinePreview()
        }
    }

    private func hideTimelinePreview(immediately: Bool = false) {
        timelinePreviewHideTask?.cancel()
        timelinePreviewHideTask = nil
        timelinePreviewContactCanToggle = false
        guard isTimelinePreviewVisible else { return }
        if immediately {
            isTimelinePreviewVisible = false
        } else {
            withAnimation(.easeOut(duration: ContinuumTheme.fastDuration)) {
                isTimelinePreviewVisible = false
            }
            // A dismissed quick preview always starts fresh in duration mode
            // on the next light touch. The immediate Select-to-HUD handoff
            // intentionally preserves the current display mode instead.
            timelineTimeDisplayMode = .elapsedRemaining
        }
    }
    #endif

    /// Video surface. tvOS uses focus-driven transport; on iOS the touch
    /// gestures (tap-to-toggle, pinch, double-tap skip, …) live in
    /// `MobilePlayerGestureLayer`, mounted above this surface.
    ///
    /// Aether owns native/software route selection behind this one surface.
    @ViewBuilder
    private func playerSurface(ignoresSafeArea: Bool = true) -> some View {
        let surface = AetherPlayerSurface(engine: viewModel.aetherEngine)
            .background(Color.black)
            .overlay {
                AetherSubtitleOverlay(
                    engine: viewModel.aetherEngine,
                    sourceTime: viewModel.currentTime,
                    livePrimaryCues: viewModel.selectedSubtitleId.map(SubtitleTrackIdSpace.isAILive) == true
                        ? viewModel.livePrimarySubtitleCues
                        : [],
                    liveSecondaryCues: viewModel.selectedSecondarySubtitleId.map(SubtitleTrackIdSpace.isAILive) == true
                        ? viewModel.liveSecondarySubtitleCues
                        : [],
                    appearance: viewModel.settings.effectiveSubtitleAppearance,
                    subtitleSyncMs: viewModel.settings.subtitleSyncMs
                )
            }
        if ignoresSafeArea {
            surface.ignoresSafeArea()
        } else {
            surface
        }
    }

    #if !os(tvOS)
    /// Close control shown while the player is still loading/buffering, in
    /// the same spot (and glass style) as the close button in
    /// `MobilePlayerControls`' top strip so the two read as one control.
    private var loadingCloseButton: some View {
        HStack {
            Button(action: { dismissPlayer() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Close Player")

            Spacer()
        }
        .padding(.horizontal)
        .padding(.top)
        .transition(.opacity)
    }
    #endif

    @ViewBuilder
    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.continuumError)

            Text(error)
                .font(.continuumBody)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            HStack(spacing: 16) {
                Button("Retry") {
                    viewModel.retry()
                }
                .siloPrimaryButton()
                .frame(minWidth: 140)

                Button("Go Back") { dismissPlayer() }
                    .siloPrimaryButton()
                    .frame(minWidth: 140)
            }
        }
    }
}

private let playerNextUpMainScrollTarget = "player-next-up-main"
private let playerNextUpOnDeckScrollTarget = "player-next-up-on-deck"

private enum PlayerNextUpFocusTarget: Hashable {
    case playNow
    case keepWatching
    case back
    case autoPlay
}

private struct PlayerNextUpScreen<MiniPlayer: View>: View {
    let viewModel: PlayerViewModel
    let onBack: () -> Void
    @ViewBuilder let miniPlayer: () -> MiniPlayer
    @FocusState private var focusedTarget: PlayerNextUpFocusTarget?
    @State private var onDeckFocusRequest = 0
    @State private var didRequestInitialActionFocus = false

    #if os(tvOS)
    @Namespace private var defaultFocusNamespace
    #endif

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                backgroundImage

                #if os(tvOS)
                ScrollView(.vertical, showsIndicators: false) {
                    screenContent(maxMainWidth: mainContentWidth(for: proxy))
                    .padding(.horizontal, horizontalPadding)
                    .padding(.top, verticalTopPadding)
                    .padding(.bottom, verticalBottomPadding)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .defaultScrollAnchor(.top)
                .scrollClipDisabled()
                #else
                screenContent(maxMainWidth: mainContentWidth(for: proxy))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.horizontal, horizontalPadding)
                    .padding(.vertical, verticalPadding)
                #endif
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.2), value: viewModel.nextUpCountdownSeconds)
        .animation(.easeInOut(duration: 0.2), value: viewModel.nextUpEpisode)
        .animation(.easeInOut(duration: 0.2), value: viewModel.nextUpCarouselItems)
        #if os(tvOS)
        .onAppear(perform: requestInitialActionFocusIfNeeded)
        .onChange(of: viewModel.nextUpEpisode?.contentId) { _, _ in
            requestInitialActionFocusIfNeeded()
        }
        #endif
    }

    private func screenContent(maxMainWidth: CGFloat) -> some View {
        let content = VStack(spacing: sectionSpacing) {
            mainContent
                .frame(maxWidth: maxMainWidth)
                .id(playerNextUpMainScrollTarget)

            if !viewModel.nextUpCarouselItems.isEmpty {
                onDeckSection
                    .frame(maxWidth: carouselMaxWidth)
                    .id(playerNextUpOnDeckScrollTarget)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)

        #if os(tvOS)
        return content.focusScope(defaultFocusNamespace)
        #else
        return content
        #endif
    }

    @ViewBuilder
    private var backgroundImage: some View {
        if let artwork = backgroundArtwork {
            AsyncImageView(url: artwork.url, thumbhash: artwork.thumbhash)
                .scaledToFill()
                .blur(radius: 44)
                .scaleEffect(1.12)
                .opacity(0.18)
                .overlay(Color.black.opacity(0.78))
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var mainContent: some View {
        #if os(tvOS)
        HStack(alignment: .center, spacing: 48) {
            miniPlayerPane
                .frame(width: 680)
            nextUpPanel
                .frame(maxWidth: 650, alignment: .leading)
        }
        #else
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: sectionSpacing) {
                miniPlayerPane
                    .frame(maxWidth: 620)
                nextUpPanel
                    .frame(maxWidth: 620)
            }
            .frame(maxWidth: .infinity)
        }
        #endif
    }

    private var miniPlayerPane: some View {
        ZStack {
            miniPlayer()
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 34, y: 18)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var nextUpPanel: some View {
        VStack(alignment: isTV ? .leading : .center, spacing: panelSpacing) {
            eyebrow

            if let episode = viewModel.nextUpEpisode {
                nextEpisodeContent(episode)
            } else if viewModel.isLoadingNextUpEpisode {
                loadingContent
            } else {
                finishedContent
            }
        }
        .multilineTextAlignment(isTV ? .leading : .center)
    }

    private var eyebrow: some View {
        Text(statusLabel)
            .font(.system(size: eyebrowSize, weight: .semibold))
            .textCase(.uppercase)
            .foregroundStyle(.white.opacity(0.52))
    }

    private func nextEpisodeContent(_ episode: PlayerNextUpEpisode) -> some View {
        VStack(alignment: isTV ? .leading : .center, spacing: panelSpacing) {
            metadata(for: episode)
            actionRow(hasNextEpisode: true)
            autoPlayToggle
        }
    }

    private var loadingContent: some View {
        VStack(alignment: isTV ? .leading : .center, spacing: panelSpacing) {
            HStack(spacing: 14) {
                ProgressView()
                    .tint(.white)
                    .scaleEffect(isTV ? 1.35 : 1.0)
                Text("Finding the next episode")
                    .font(.system(size: titleSize, weight: .semibold))
                    .foregroundStyle(.white)
            }
            actionRow(hasNextEpisode: false)
        }
    }

    private var finishedContent: some View {
        VStack(alignment: isTV ? .leading : .center, spacing: panelSpacing) {
            Text(viewModel.nextUpScreenVideoEnded ? "End of playback" : "Almost finished")
                .font(.system(size: titleSize, weight: .bold))
                .foregroundStyle(.white)
            Text(finishedMessage)
                .font(.system(size: bodySize, weight: .medium))
                .foregroundStyle(.white.opacity(0.62))
                .frame(maxWidth: 560, alignment: isTV ? .leading : .center)
            actionRow(hasNextEpisode: false)
        }
    }

    private func metadata(for episode: PlayerNextUpEpisode) -> some View {
        VStack(alignment: isTV ? .leading : .center, spacing: isTV ? 12 : 7) {
            if let seriesTitle = episode.seriesTitle, !seriesTitle.isEmpty {
                Text(seriesTitle)
                    .font(.system(size: seriesTitleSize, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

            HStack(spacing: 10) {
                Text(episode.episodeLabel)
                    .foregroundStyle(.white.opacity(0.62))
                Text(episode.title)
                    .foregroundStyle(.white)
            }
            .font(.system(size: subtitleSize, weight: .semibold))
            .lineLimit(2)
            .multilineTextAlignment(isTV ? .leading : .center)

            let metadataLine = episodeMetadataLine(for: episode)
            if !metadataLine.isEmpty {
                Text(metadataLine)
                    .font(.system(size: captionSize, weight: .medium))
                    .foregroundStyle(.white.opacity(0.46))
            }

            if let overview = episode.overview, !overview.isEmpty {
                Text(overview)
                    .font(.system(size: bodySize))
                    .lineLimit(isTV ? 3 : 2)
                    .multilineTextAlignment(isTV ? .leading : .center)
                    .foregroundStyle(.white.opacity(0.58))
                    .frame(maxWidth: 620, alignment: isTV ? .leading : .center)
            }
        }
    }

    @ViewBuilder
    private func actionRow(hasNextEpisode: Bool) -> some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 18) {
            // Reserve enough room for the primary pill's focused scale and
            // outer focus outline so the countdown never overlaps it.
            HStack(spacing: 56) {
                if hasNextEpisode {
                    Button(action: { viewModel.playNextEpisodeNow() }) {
                        HStack(spacing: 18) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 32, weight: .bold))
                            Text("Play Now")
                                .font(.system(size: 30, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(width: 220)
                    }
                    .buttonStyle(TVPillButtonStyle(kind: .primary))
                    .focused($focusedTarget, equals: .playNow)
                    .prefersDefaultFocus(true, in: defaultFocusNamespace)
                }

                if let seconds = viewModel.nextUpCountdownSeconds {
                    CountdownRing(seconds: seconds, totalSeconds: viewModel.nextUpCountdownTotalSeconds)
                }
            }

            HStack(spacing: 20) {
                if !viewModel.nextUpScreenVideoEnded {
                    Button(action: { viewModel.keepWatchingCurrentEpisode() }) {
                        HStack(spacing: 16) {
                            Image(systemName: "rectangle.inset.filled")
                                .font(.system(size: 25, weight: .semibold))
                            Text("Keep Watching")
                                .font(.system(size: 26, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .frame(width: 250)
                    }
                    .buttonStyle(TVPillButtonStyle(kind: .secondary))
                    .focused($focusedTarget, equals: .keepWatching)
                    .prefersDefaultFocus(!hasNextEpisode, in: defaultFocusNamespace)
                }

                Button(action: onBack) {
                    HStack(spacing: 16) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 26, weight: .semibold))
                        Text("Back")
                            .font(.system(size: 26, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .frame(width: 120)
                }
                .buttonStyle(TVPillButtonStyle(kind: .secondary))
                .focused($focusedTarget, equals: .back)
                .prefersDefaultFocus(!hasNextEpisode && viewModel.nextUpScreenVideoEnded, in: defaultFocusNamespace)
            }
            .onMoveCommand { direction in
                if direction == .down {
                    focusBelowActions()
                }
            }
        }
        #else
        VStack(spacing: 10) {
            if hasNextEpisode {
                Button(action: { viewModel.playNextEpisodeNow() }) {
                    Label("Play Now", systemImage: "play.fill")
                }
                .siloPrimaryButton()
                .frame(maxWidth: .infinity)
            }

            if !viewModel.nextUpScreenVideoEnded {
                Button(action: { viewModel.keepWatchingCurrentEpisode() }) {
                    Label("Keep Watching", systemImage: "rectangle.inset.filled")
                }
                .siloSecondaryButton()
                .frame(maxWidth: .infinity)
            }

            Button(action: onBack) {
                Label("Back", systemImage: "chevron.left")
            }
            .siloSecondaryButton()
            .frame(maxWidth: .infinity)

            if let seconds = viewModel.nextUpCountdownSeconds {
                CountdownRing(seconds: seconds, totalSeconds: viewModel.nextUpCountdownTotalSeconds)
            }
        }
        .frame(maxWidth: 280)
        #endif
    }

    private var autoPlayToggle: some View {
        Button {
            viewModel.setNextUpAutoPlayEnabled(!viewModel.settings.autoPlayNextEpisode)
        } label: {
            Text("Auto-play is \(viewModel.settings.autoPlayNextEpisode ? "On" : "Off")")
                .font(.system(size: captionSize, weight: .semibold))
        }
        .buttonStyle(AutoPlayToggleButtonStyle())
        #if os(tvOS)
        .focused($focusedTarget, equals: .autoPlay)
        .onMoveCommand { direction in
            if direction == .up {
                focusPreferredAction()
            } else if direction == .down {
                focusFirstOnDeckItem()
            }
        }
        #endif
    }

    private var onDeckSection: some View {
        MediaRow(
            title: "On Deck",
            items: viewModel.nextUpCarouselItems.map(\.sectionItem),
            onItemTap: playOnDeckItem(contentId:),
            showProgress: true,
            icon: "play.circle.fill",
            layout: .thumbnail,
            usesProvidedThumbnailTapAction: onDeckUsesProvidedThumbnailTapAction,
            focusRequest: onDeckFocusRequest,
            onMoveUp: focusAboveOnDeck
        )
    }

    private var onDeckUsesProvidedThumbnailTapAction: Bool {
        #if os(iOS)
        return true
        #else
        return false
        #endif
    }

    private var statusLabel: String {
        if viewModel.nextUpEpisode == nil && !viewModel.isLoadingNextUpEpisode {
            return viewModel.nextUpScreenVideoEnded ? "Finished" : "More To Watch"
        }
        return viewModel.nextUpScreenVideoEnded ? "Playing Next" : "Up Next"
    }

    private var finishedMessage: String {
        if let startError = viewModel.nextUpStartError {
            let suffix = viewModel.nextUpCarouselItems.isEmpty
                ? "Try again or go back."
                : "Try again, pick something from On Deck, or go back."
            return "Couldn't start the next episode: \(startError) \(suffix)"
        }
        if viewModel.nextUpLookupError != nil {
            return "Couldn't load the next episode. Pick something from On Deck, or go back."
        }
        if viewModel.nextUpCarouselItems.isEmpty {
            return "No next episode is available."
        }
        return "No next episode is available. Pick something from On Deck instead."
    }

    private func focusPreferredAction() {
        focusedTarget = preferredActionFocusTarget
    }

    private func focusBelowActions() {
        if viewModel.nextUpEpisode != nil {
            focusedTarget = .autoPlay
            return
        }
        focusFirstOnDeckItem()
    }

    private func focusAboveOnDeck() {
        if viewModel.nextUpEpisode != nil {
            focusedTarget = .autoPlay
            return
        }
        focusPreferredAction()
    }

    private func focusFirstOnDeckItem() {
        guard !viewModel.nextUpCarouselItems.isEmpty else { return }
        onDeckFocusRequest &+= 1
    }

    private func requestInitialActionFocusIfNeeded() {
        guard !didRequestInitialActionFocus else { return }
        guard viewModel.nextUpEpisode != nil || !viewModel.isLoadingNextUpEpisode else { return }
        didRequestInitialActionFocus = true

        Task { @MainActor in
            await Task.yield()
            focusedTarget = preferredActionFocusTarget
        }
    }

    private var preferredActionFocusTarget: PlayerNextUpFocusTarget {
        if viewModel.nextUpEpisode != nil {
            return .playNow
        }
        if !viewModel.nextUpScreenVideoEnded {
            return .keepWatching
        }
        return .back
    }

    private func playOnDeckItem(contentId: String) {
        guard let item = viewModel.nextUpCarouselItems.first(where: { $0.contentId == contentId }) else {
            return
        }
        viewModel.playOnDeckItemNow(item)
    }

    private var backgroundArtwork: (url: String, thumbhash: String?)? {
        if let url = viewModel.nextUpEpisode?.stillUrl {
            return (url, viewModel.nextUpEpisode?.stillThumbhash)
        }
        if let item = viewModel.nextUpCarouselItems.first,
           let url = item.artworkUrl {
            return (url, item.artworkThumbhash)
        }
        return nil
    }

    private func episodeMetadataLine(for episode: PlayerNextUpEpisode) -> String {
        var parts: [String] = []
        if let airDate = episode.airDate, !airDate.isEmpty {
            parts.append(formatAirDate(airDate))
        }
        if let runtime = episode.runtime, runtime > 0 {
            parts.append(formatRuntime(runtime))
        }
        return parts.joined(separator: " · ")
    }

    private func formatAirDate(_ airDate: String) -> String {
        guard let date = try? Date(airDate, strategy: .iso8601) else { return airDate }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private func formatRuntime(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }

    private func mainContentWidth(for proxy: GeometryProxy) -> CGFloat {
        min(proxy.size.width - horizontalPadding * 2, isTV ? 1420 : 680)
    }

    private var isTV: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    private var carouselMaxWidth: CGFloat { isTV ? 1580 : 680 }
    private var horizontalPadding: CGFloat { isTV ? 80 : 24 }
    private var verticalTopPadding: CGFloat { isTV ? 112 : 24 }
    private var verticalBottomPadding: CGFloat { isTV ? 260 : 24 }
    private var verticalPadding: CGFloat { isTV ? 58 : 24 }
    private var sectionSpacing: CGFloat { isTV ? 34 : 22 }
    private var panelSpacing: CGFloat { isTV ? 22 : 14 }
    private var eyebrowSize: CGFloat { isTV ? 18 : 12 }
    private var titleSize: CGFloat { isTV ? 42 : 26 }
    private var seriesTitleSize: CGFloat { isTV ? 34 : 22 }
    private var subtitleSize: CGFloat { isTV ? 25 : 17 }
    private var bodySize: CGFloat { isTV ? 22 : 15 }
    private var captionSize: CGFloat { isTV ? 19 : 13 }
}

private struct AutoPlayToggleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AutoPlayToggleButtonBody(configuration: configuration)
    }
}

private struct AutoPlayToggleButtonBody: View {
    let configuration: ButtonStyle.Configuration
    @Environment(\.isFocused) private var isFocused

    var body: some View {
        configuration.label
            .foregroundStyle(.white.opacity(isFocused ? 0.92 : 0.54))
            .padding(.horizontal, 22)
            .padding(.vertical, 10)
            .overlay(
                Capsule()
                    .stroke(.white.opacity(isFocused ? 0.55 : 0), lineWidth: 1.5)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : (isFocused ? 1.04 : 1.0))
            #if os(tvOS)
            .focusEffectDisabled()
            #endif
            .animation(ContinuumTheme.springAnimation, value: isFocused)
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: configuration.isPressed)
    }
}

private struct CountdownRing: View {
    let seconds: Int
    let totalSeconds: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.12), lineWidth: 3)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(seconds)")
                .font(.system(size: textSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: ringSize, height: ringSize)
        .accessibilityLabel("Playing next in \(seconds) seconds")
    }

    private var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return max(0, min(1, Double(seconds) / Double(totalSeconds)))
    }

    private var ringSize: CGFloat {
        #if os(tvOS)
        58
        #else
        44
        #endif
    }

    private var textSize: CGFloat {
        #if os(tvOS)
        24
        #else
        17
        #endif
    }
}
