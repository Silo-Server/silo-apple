#if os(iOS)
import SwiftUI

/// Touch-driven overlay used on iOS/iPadOS. Breakdown:
/// - Top bar: dismiss, title, sheet buttons (tracks, chapters, settings)
/// - Center: skip back 10s, play/pause, skip forward 10s
/// - Bottom: progress bar with chapter ticks, time labels, buffering hint
///
/// The whole thing is wrapped in a tap-to-toggle gesture; auto-hide after 3 s
/// of inactivity. The view is stateful only for the sheet presentation; the
/// rest of the state lives on `PlayerViewModel`.
struct MobilePlayerControls: View {
    let viewModel: PlayerViewModel
    let orientationCoordinator: PlayerOrientationCoordinator
    let onDismiss: () -> Void

    @State private var activeSheet: PlayerSheet?

    var body: some View {
        // NOTE: the .sheet modifier MUST live outside the `showControls` gate.
        // If it's attached to a view that only exists while controls are
        // visible, the 3s auto-hide tears down the sheet's host and dismisses
        // the sheet mid-interaction — then re-presents it when controls come
        // back, because @State activeSheet survives the rebuild.
        ZStack {
            if viewModel.showControls {
                // GeometryReader pins the control stack to the player's own
                // bounds. The bars are siblings of the shared player notice in
                // `PlayerView`'s ZStack; inside the player's `.fullScreenCover`
                // a too-wide bar would otherwise stretch that shared layer past
                // the screen and drag the notice off both edges in portrait.
                // Clamping the stack to `proxy.size` keeps every overlay inside
                // the visible frame regardless of how wide a bar wants to be.
                GeometryReader { proxy in
                    ZStack {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                            .onTapGesture { viewModel.toggleControls() }

                        VStack {
                            topBar
                            Spacer()
                            centerControls
                            Spacer()
                            bottomBar
                        }
                        .padding()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                    }
                }
                .transition(.opacity)
            }
            if viewModel.showIntroSkip {
                introSkipButton
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .tracks:
                TrackSelectionSheet(viewModel: viewModel) { activeSheet = nil }
                    .presentationDetents([.medium, .large])
            case .chapters:
                ChapterSheet(viewModel: viewModel) { activeSheet = nil }
                    .presentationDetents([.medium, .large])
            case .settings:
                PlayerSettingsSheet(viewModel: viewModel, sleepTimer: viewModel.sleepTimer)
                    .presentationDetents([.large])
            }
        }
        .onChange(of: activeSheet) { _, newValue in
            // Keep controls pinned while a sheet is up, and restart the
            // auto-hide timer once it closes.
            if newValue != nil {
                viewModel.pinControlsVisible()
            } else {
                viewModel.resumeAutoHide()
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        GlassEffectContainer {
            // Tighter spacing than the other bars: in portrait this row packs
            // the close button, title and up to four trailing controls into the
            // ~370pt width, so the gaps stay small enough that the end buttons
            // never spill off-screen. The title takes the lowest layout
            // priority so it truncates before the buttons are squeezed.
            HStack(spacing: 8) {
                controlButton(systemName: "chevron.left", action: onDismiss)

                Spacer(minLength: 8)

                Text(viewModel.title)
                    .font(.subheadline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(-1)

                Spacer(minLength: 8)

                controlButton(
                    systemName: orientationCoordinator.isLandscapeLocked ? "lock.fill" : "lock.open"
                ) {
                    orientationCoordinator.togglePlayerMode()
                }
                .accessibilityLabel(
                    orientationCoordinator.isLandscapeLocked ? "Landscape Locked" : "Rotate Freely"
                )
                .accessibilityHint(
                    orientationCoordinator.isLandscapeLocked
                        ? "Allows portrait rotation during playback"
                        : "Locks playback to landscape"
                )

                // Chapters: only show if the file has them
                if !viewModel.chapters.isEmpty {
                    controlButton(systemName: "list.bullet") {
                        activeSheet = .chapters
                    }
                }

                // Tracks: disable if there's literally nothing to choose
                controlButton(systemName: "captions.bubble") {
                    activeSheet = .tracks
                }
                .disabled(viewModel.audioTracks.isEmpty && viewModel.subtitleTracks.isEmpty)
                .opacity(viewModel.audioTracks.isEmpty && viewModel.subtitleTracks.isEmpty ? 0.3 : 1)

                controlButton(systemName: "gearshape") {
                    activeSheet = .settings
                }
            }
        }
    }

    private var introSkipButton: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(alignment: .trailing, spacing: 8) {
                    if let countdown = viewModel.introAutoSkipCountdownSeconds {
                        Text("Skipping intro in \(countdown)")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(.black.opacity(0.65)))
                            .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
                    }

                    HStack(spacing: 10) {
                        if viewModel.introAutoSkipCountdownSeconds != nil {
                            Button {
                                viewModel.cancelIntroAutoSkip()
                            } label: {
                                Text("Cancel")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 11)
                            }
                            .buttonStyle(.glass)
                            .accessibilityLabel("Cancel Auto-Skip Intro")
                        }

                        Button {
                            viewModel.skipIntro()
                        } label: {
                            Label(
                                viewModel.introAutoSkipCountdownSeconds == nil ? "Skip Intro" : "Skip Now",
                                systemImage: "forward.end.fill"
                            )
                            .font(.system(size: 16, weight: .semibold))
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                        }
                        .buttonStyle(.glassProminent)
                        .accessibilityLabel(
                            viewModel.introAutoSkipCountdownSeconds == nil ? "Skip Intro" : "Skip Intro Now"
                        )
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 86)
        }
        .transition(.opacity)
    }

    // MARK: - Center

    private var centerControls: some View {
        GlassEffectContainer {
            HStack(spacing: 48) {
                Button {
                    viewModel.skipBackward()
                } label: {
                    Image(systemName: "gobackward.10")
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.glass)

                Button {
                    viewModel.togglePlayPause()
                } label: {
                    if viewModel.isBuffering {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(1.5)
                            .frame(width: 60, height: 60)
                    } else {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.glassProminent)

                Button {
                    viewModel.skipForward()
                } label: {
                    Image(systemName: "goforward.10")
                        .font(.system(size: 32))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.glass)
            }
        }
    }

    // MARK: - Bottom

    private var bottomBar: some View {
        VStack(spacing: 8) {
            progressSlider

            HStack {
                Text(PlayerTimeFormatter.formatHMS(displayTime))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .monospacedDigit()

                Spacer()

                if viewModel.sleepTimer.isActive {
                    Label(PlayerTimeFormatter.formatCountdown(viewModel.sleepTimer.remainingSeconds), systemImage: "moon.zzz.fill")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .monospacedDigit()
                }

                Spacer()

                Text(PlayerTimeFormatter.formatHMS(viewModel.duration))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .monospacedDigit()
            }
        }
    }

    private var displayTime: Double {
        viewModel.isScrubbing ? viewModel.scrubPreviewTime : viewModel.currentTime
    }

    private var progressSlider: some View {
        GeometryReader { geo in
            let progress = viewModel.duration > 0
                ? displayTime / viewModel.duration
                : 0

            ZStack(alignment: .leading) {
                // Base
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.3))
                    .frame(height: 4)

                introMarker(width: geo.size.width)

                // Chapter ticks. Rendered behind the fill so they're visible
                // in unplayed territory; the fill covers them over played
                // time, which matches Apple's native transport-bar behavior.
                if viewModel.duration > 0 && !viewModel.chapters.isEmpty {
                    ForEach(viewModel.chapters) { chapter in
                        let fraction = chapter.time / viewModel.duration
                        Rectangle()
                            .fill(Color.white.opacity(0.7))
                            .frame(width: 2, height: 8)
                            .offset(x: geo.size.width * min(max(fraction, 0), 1) - 1)
                    }
                }

                // Filled portion
                RoundedRectangle(cornerRadius: 2)
                    .fill(.tint)
                    .frame(width: geo.size.width * min(max(progress, 0), 1), height: 4)

                // Thumb
                Circle()
                    .fill(.tint)
                    .frame(width: 14, height: 14)
                    .offset(x: geo.size.width * min(max(progress, 0), 1) - 7)
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / geo.size.width, 0), 1)
                        if viewModel.isScrubbing {
                            viewModel.updateScrub(fraction: fraction)
                        } else {
                            viewModel.beginScrub(fraction: fraction)
                        }
                    }
                    .onEnded { _ in
                        viewModel.endScrub()
                    }
            )
        }
        .frame(height: 14)
    }

    @ViewBuilder
    private func introMarker(width: CGFloat) -> some View {
        if let introRange = viewModel.introRange, viewModel.duration > 0 {
            let start = min(max(introRange.start / viewModel.duration, 0), 1)
            let end = min(max(introRange.end / viewModel.duration, 0), 1)
            if end > start {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.cyan.opacity(0.4))
                    .frame(width: width * (end - start), height: 4)
                    .offset(x: width * start)
            }
        }
    }

    // MARK: - Helpers

    private func controlButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
        }
        // `.circle` keeps each glass control a compact 44pt circle instead of
        // the default wider capsule, so the full top-bar row (close, title and
        // up to four trailing controls) fits within an iPhone's portrait width.
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    // MARK: - Sheet identifier

    private enum PlayerSheet: Identifiable {
        case tracks, chapters, settings
        var id: Self { self }
    }
}
#endif
