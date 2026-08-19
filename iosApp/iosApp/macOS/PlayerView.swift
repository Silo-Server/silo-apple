#if os(macOS)
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
    @Environment(\.scenePhase) private var scenePhase
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

                // The player's single loading/buffering surface, for the start
                // (`isLoading`) and every rebuffer after it (`isBuffering`)
                // alike. Inside the non-error branch, so it can never float
                // over the error view.
                if viewModel.isLoading || viewModel.isBuffering {
                    PlayerBufferingCapsule()
                }

                if let notice = viewModel.activeNotice ?? viewModel.suspendedNotice {
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
        .onChange(of: scenePhase) { _, newPhase in
            viewModel.handleScenePhase(newPhase)
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
        if let backend = viewModel.avPlayerBackend {
            AVPlayerSurface(backend: backend)
                .ignoresSafeArea()
        } else {
            Color.black.ignoresSafeArea()
        }
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
