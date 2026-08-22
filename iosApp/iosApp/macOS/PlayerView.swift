#if os(macOS)
import AetherEngine
import SwiftUI

struct PlayerView: View {
    let contentId: String
    let preferredFileId: Int?
    let preferredAudioTrackIndex: Int?
    let preferredSubtitleTrackIndex: Int?
    let startFromBeginning: Bool
    let resumePositionOverride: Double?
    /// Set when the caller wants offline playback of a completed download.
    /// Routes the prepare through `OfflinePlaybackBuilder` (stored manifest
    /// + local media file, no server session) so playback works with no
    /// network.
    let offlineDownloadId: String?

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel = PlayerViewModel()
    @State private var isOptionsPresented = false
    @State private var selectedOptionsTab: MacPlayerOptionsPanel.Tab = .audio

    init(
        contentId: String,
        preferredFileId: Int? = nil,
        preferredAudioTrackIndex: Int? = nil,
        preferredSubtitleTrackIndex: Int? = nil,
        startFromBeginning: Bool = false,
        resumePositionOverride: Double? = nil,
        offlineDownloadId: String? = nil
    ) {
        self.contentId = contentId
        self.preferredFileId = preferredFileId
        self.preferredAudioTrackIndex = preferredAudioTrackIndex
        self.preferredSubtitleTrackIndex = preferredSubtitleTrackIndex
        self.startFromBeginning = startFromBeginning
        self.resumePositionOverride = resumePositionOverride
        self.offlineDownloadId = offlineDownloadId
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let error = viewModel.error {
                errorView(error)
            } else {
                playerSurface

                if viewModel.isLoading {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.5)
                }

                if shouldShowControls {
                    MacPlayerControls(
                        viewModel: viewModel,
                        isOptionsPresented: $isOptionsPresented,
                        selectedOptionsTab: $selectedOptionsTab,
                        onDismiss: { dismiss() }
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

                if let notice = viewModel.activeNotice {
                    PlayerNoticeOverlay(notice: notice)
                        .padding(.top, 72)
                }

                MacPlayerCommandCapture { command in
                    handleCommand(command)
                }
                .frame(width: 0, height: 0)
            }
        }
        .onHover { hovering in
            if hovering {
                viewModel.revealControls()
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
                contentId: contentId,
                preferredFileId: preferredFileId,
                preferredAudioTrackIndex: preferredAudioTrackIndex,
                preferredSubtitleTrackIndex: preferredSubtitleTrackIndex,
                startFromBeginning: startFromBeginning,
                resumePositionOverride: resumePositionOverride,
                offlineDownloadId: offlineDownloadId
            )
        }
        .onDisappear {
            viewModel.cleanup()
        }
        .preferredColorScheme(.dark)
        .animation(.easeOut(duration: 0.16), value: shouldShowControls)
        .animation(.easeOut(duration: 0.16), value: isOptionsPresented)
    }

    private var shouldShowControls: Bool {
        viewModel.showControls
            || !viewModel.isPlaying
            || viewModel.isLoading
            || viewModel.isBuffering
            || isOptionsPresented
    }

    @ViewBuilder
    private var playerSurface: some View {
        ZStack {
            AetherPlayerSurface(engine: viewModel.aetherEngine)
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
        .ignoresSafeArea()
    }

    private func handleCommand(_ command: MacPlayerCommand) {
        switch command {
        case .playPause:
            viewModel.togglePlayPause()
        case .skipBackward:
            viewModel.skipBackward(15)
        case .skipForward:
            viewModel.skipForward(15)
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
            } else {
                dismiss()
            }
        case .speedDown:
            viewModel.setPlaybackSpeed(nextSpeed(offset: -1))
        case .speedUp:
            viewModel.setPlaybackSpeed(nextSpeed(offset: 1))
        case .normalSpeed:
            viewModel.setPlaybackSpeed(1.0)
        }
    }

    private func nextSpeed(offset: Int) -> Double {
        let speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]
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
                .foregroundStyle(Color.continuumError)

            Text(error)
                .font(.continuumBody)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)

            HStack(spacing: 12) {
                Button("Retry") {
                    viewModel.retry()
                }
                .buttonStyle(.borderedProminent)

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
#endif
