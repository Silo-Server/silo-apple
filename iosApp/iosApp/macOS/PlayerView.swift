#if os(macOS)
import AetherEngine
import SwiftUI

struct PlayerView: View {
    private let request: MacPlayerRequest
    private let libraryId: Int?

    /// Created once on appear. A `State` initial value would build, and then
    /// discard, a full playback engine (with its audio-session claim) on
    /// every init of this view.
    @State private var viewModel: PlayerViewModel?

    init(
        contentId: String,
        libraryId: Int? = nil,
        preferredFileId: Int? = nil,
        pinsVersion: Bool = false,
        preferredAudioTrackIndex: Int? = nil,
        preferredSubtitleTrackIndex: Int? = nil,
        startFromBeginning: Bool = false,
        resumePositionOverride: Double? = nil,
        prefersLastUsedVersion: Bool = false,
        offlineDownloadId: String? = nil
    ) {
        self.libraryId = libraryId
        request = MacPlayerRequest(
            contentId: contentId,
            preferredFileId: preferredFileId,
            pinsVersion: pinsVersion,
            preferredAudioTrackIndex: preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: preferredSubtitleTrackIndex,
            startFromBeginning: startFromBeginning,
            resumePositionOverride: resumePositionOverride,
            prefersLastUsedVersion: prefersLastUsedVersion,
            offlineDownloadId: offlineDownloadId
        )
    }

    var body: some View {
        if let viewModel {
            MacPlayerScreen(request: request, viewModel: viewModel)
        } else {
            Color.black
                .ignoresSafeArea()
                .onAppear { viewModel = PlayerViewModel(libraryId: libraryId) }
        }
    }
}

private struct MacPlayerRequest {
    let contentId: String
    let preferredFileId: Int?
    /// The viewer picked `preferredFileId` in a version picker.
    let pinsVersion: Bool
    let preferredAudioTrackIndex: Int?
    let preferredSubtitleTrackIndex: Int?
    let startFromBeginning: Bool
    let resumePositionOverride: Double?
    /// Continue Watching resume intent: select the server's last-used file
    /// before the profile-wide quality preference.
    let prefersLastUsedVersion: Bool
    /// Set when the caller wants offline playback of a completed download.
    /// Routes the prepare through `OfflinePlaybackBuilder` (stored manifest
    /// + local media file, no server session) so playback works with no
    /// network.
    let offlineDownloadId: String?
}

private struct MacPlayerScreen: View {
    let request: MacPlayerRequest
    let viewModel: PlayerViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var isOptionsPresented = false
    @State private var selectedOptionsTab: MacPlayerOptionsPanel.Tab = .audio
    /// The loading spinner is up, on its show delay and minimum time.
    @State private var showsLoadingSpinner = false
    /// The window is in, or entering, full screen.
    @State private var isFullScreen = false
    /// The pointer is over the player.
    @State private var isPointerOver = false
    /// Last pointer position on screen. Hiding the title bar shifts the
    /// player, which re-reports the pointer at a new local point; comparing
    /// screen positions keeps that from counting as a move and bringing the
    /// controls straight back.
    @State private var lastPointerLocation: CGPoint?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let error = viewModel.error {
                errorView(error)
            } else {
                playerSurface

                // Clicks on the picture land here; the controls above it take
                // their own. A click brings the controls up, a double click
                // toggles full screen.
                Color.clear
                    .contentShape(Rectangle())
                    .ignoresSafeArea()
                    .onTapGesture(count: 2) { toggleFullScreen() }
                    .simultaneousGesture(TapGesture().onEnded { viewModel.revealControls() })

                if shouldShowControls {
                    MacPlayerControls(
                        viewModel: viewModel,
                        isFullScreen: isFullScreen,
                        isOptionsPresented: $isOptionsPresented,
                        selectedOptionsTab: $selectedOptionsTab
                    )
                    .transition(.opacity)
                }

                if isOptionsPresented {
                    MacPlayerOptionsPanel(
                        viewModel: viewModel,
                        selectedTab: $selectedOptionsTab,
                        onDismiss: { isOptionsPresented = false }
                    )
                    .padding(.trailing, 24)
                    .padding(.bottom, 116)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                }

                if let pill = viewModel.introSkipPrompt.pill {
                    MacIntroSkipPill(pill: pill) {
                        viewModel.selectIntroSkipPrompt()
                    }
                    .padding(.trailing, 24)
                    // Above the control bar while it shows; toward the corner
                    // once it hides.
                    .padding(.bottom, shouldShowControls ? 136 : 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .transition(.opacity)
                }

                if showsLoadingSpinner {
                    PlayerLoadingSpinner()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }

                // The notice position, below the window's title bar. The
                // buffering pill shares it, below any notice.
                PlayerNoticeStack {
                    if let notice = viewModel.presentedNotice {
                        PlayerNoticeOverlay(notice: notice)
                    }
                    if let pill = viewModel.bufferingPill {
                        MacBufferingQualityPill(
                            pill: pill,
                            onPrimary: { viewModel.selectBufferingPrimary() },
                            onSecondary: { viewModel.selectBufferingKeep() }
                        )
                        .padding(.horizontal, SiloTheme.safePadding)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .playerNoticeStackPill()
                    }
                }
                .padding(.top, 72)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                if let notice = viewModel.subtitleSync.notice {
                    SubtitleSyncIndicator(notice: notice) {
                        viewModel.subtitleSync.dismissNotice()
                    }
                    .padding(.top, 24)
                    .padding(.trailing, 24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.opacity)
                }

                MacPlayerCommandCapture { command in
                    handleCommand(command)
                }
                .frame(width: 0, height: 0)
            }
        }
        .background {
            // The picture runs under the title bar, so swipes there count too.
            MacPlayerTrackpadScrubCapture(
                viewModel: viewModel,
                isEnabled: viewModel.error == nil && !viewModel.isStartingPlayback && !isOptionsPresented
            )
            .ignoresSafeArea()
        }
        .playerLoadingSpinnerVisibility(isActive: viewModel.isWaitingToPlay, isVisible: $showsLoadingSpinner)
        // Every mouse move brings the controls up; `onHover` only reports
        // the pointer entering the window.
        .onContinuousHover { phase in
            switch phase {
            case .active:
                let location = NSEvent.mouseLocation
                isPointerOver = true
                guard location != lastPointerLocation else { return }
                lastPointerLocation = location
                viewModel.revealControls()
            case .ended:
                // Keep the last position: hiding the title bar ends and
                // restarts the hover without the pointer moving.
                isPointerOver = false
            }
        }
        .onChange(of: shouldShowControls) { _, showing in
            // The pointer goes with the controls and comes back on the next move.
            if !showing, isPointerOver {
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        .onChange(of: viewModel.hasTrackSelectionOptions) { _, hasOptions in
            if !hasOptions {
                isOptionsPresented = false
            }
        }
        .onChange(of: viewModel.remoteDismissToken) { _, newValue in
            guard newValue != nil else { return }
            dismiss()
        }
        .onAppear {
            viewModel.loadAndPlay(
                contentId: request.contentId,
                preferredFileId: request.preferredFileId,
                pinsVersion: request.pinsVersion,
                preferredAudioTrackIndex: request.preferredAudioTrackIndex,
                preferredSubtitleTrackIndex: request.preferredSubtitleTrackIndex,
                startFromBeginning: request.startFromBeginning,
                resumePositionOverride: request.resumePositionOverride,
                prefersLastUsedVersion: request.prefersLastUsedVersion,
                offlineDownloadId: request.offlineDownloadId
            )
        }
        .onDisappear {
            viewModel.cleanup()
        }
        // Pills and notices wait while this window can't be seen.
        .background(MacWindowVisibilityReader { viewModel.playerWindowVisibilityChanged($0) })
        // In full screen the title bar comes and goes with the controls, so
        // the picture has the screen to itself while they're hidden.
        .background(MacPlayerFullScreenBridge(hidesToolbar: !shouldShowControls) { isFullScreen = $0 })
        .preferredColorScheme(.dark)
        // One header: the window's title bar carries what is playing and its
        // format beside the back button.
        .navigationTitle(viewModel.title.isEmpty ? "Silo" : viewModel.title)
        .navigationSubtitle(viewModel.metadata.badges.joined(separator: " · "))
        .animation(.easeOut(duration: 0.16), value: shouldShowControls)
        .animation(.easeOut(duration: 0.16), value: isOptionsPresented)
        .animation(.easeOut(duration: 0.2), value: viewModel.showIntroSkip)
        .animation(.easeOut(duration: 0.2), value: viewModel.showBufferingPill)
    }

    /// The controls come in at the first frame; a later stall leaves them as
    /// they are.
    private var shouldShowControls: Bool {
        guard !viewModel.isStartingPlayback else { return false }
        return viewModel.showControls || !viewModel.isPlaying || isOptionsPresented
    }

    private var playerSurface: some View {
        ZStack {
            AetherPlayerSurface(engine: viewModel.aetherEngine)
            MacSubtitleLayer(viewModel: viewModel)
        }
        // Keep the leading inset: ignoring it centred the picture on the
        // whole window, so part of it sat behind the sidebar and the
        // letterboxing landed on one side only.
        .ignoresSafeArea(edges: .vertical)
    }

    private func handleCommand(_ command: MacPlayerCommand) {
        switch command {
        case .playPause:
            viewModel.togglePlayPause()
        case .skipBackward:
            viewModel.skipBackward()
        case .skipForward:
            viewModel.skipForward()
        case .previousChapter:
            viewModel.seekToAdjacentChapter(forward: false)
        case .nextChapter:
            viewModel.seekToAdjacentChapter(forward: true)
        case .cycleAudio:
            viewModel.cycleAudioTrack()
        case .cycleSubtitle:
            viewModel.cycleSubtitleTrack()
        case .toggleSubtitle:
            viewModel.toggleSubtitles()
        case .options:
            selectedOptionsTab = .audio
            isOptionsPresented.toggle()
            viewModel.revealControls()
        case .escape:
            if isOptionsPresented {
                isOptionsPresented = false
            } else if viewModel.dismissBufferingPill() {
                // Back on the buffering pill, before the window takes Escape;
                // the next Escape closes the player as usual.
            } else if viewModel.dismissIntroSkipPrompt() {
                // The intro pill takes Escape before the window does; the next
                // Escape closes the player as usual.
            } else if isFullScreen {
                // Leave full screen first, as other Mac players do; the next
                // Escape closes the player.
                toggleFullScreen()
            } else {
                dismiss()
            }
        case .confirm:
            // Return acts on the pill that is up; with none showing it does
            // nothing. The controller never shows the two pills together.
            if viewModel.showBufferingPill {
                viewModel.selectBufferingPrimary()
            } else {
                viewModel.selectIntroSkipPrompt()
            }
        case .speedDown:
            viewModel.setPlaybackSpeed(nextSpeed(offset: -1))
        case .speedUp:
            viewModel.setPlaybackSpeed(nextSpeed(offset: 1))
        case .normalSpeed:
            viewModel.setPlaybackSpeed(1.0)
        }
    }

    private func toggleFullScreen() {
        NSApp.keyWindow?.toggleFullScreen(nil)
    }

    private func nextSpeed(offset: Int) -> Double {
        let speeds = MacPlayerOptionsPanel.playbackSpeeds
        let current = viewModel.settings.playbackSpeed
        let index = speeds.enumerated().min { lhs, rhs in
            abs(lhs.element - current) < abs(rhs.element - current)
        }?.offset ?? 2
        return speeds[max(0, min(speeds.count - 1, index + offset))]
    }

    @ViewBuilder
    private func errorView(_ error: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(Color.siloError)

            Text(error)
                .font(.siloBody)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            HStack(spacing: 12) {
                if viewModel.errorIsRetryable {
                    Button(viewModel.retryButtonTitle) {
                        viewModel.retry()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.siloOnSurface)
                    .foregroundStyle(Color.siloBackground)
                }

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Subtitles read `currentTime`, so they live in their own view: playback
/// ticks then re-render only this layer, not the whole player.
private struct MacSubtitleLayer: View {
    let viewModel: PlayerViewModel

    var body: some View {
        AetherSubtitleOverlay(
            engine: viewModel.aetherEngine,
            assSubtitles: viewModel.assSubtitles,
            cueHold: viewModel.subtitleCueHold,
            sourceTime: viewModel.currentTime,
            primaryUsesMovieTimeline: viewModel.subtitleUsesMovieTimeline(viewModel.selectedSubtitleId),
            secondaryUsesMovieTimeline: viewModel.subtitleUsesMovieTimeline(viewModel.selectedSecondarySubtitleId, slot: .secondary),
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
}
#endif
