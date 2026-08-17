import SwiftUI

/// Full-screen Now Playing surface for audiobooks. PlexAmp-inspired:
/// a cover-tinted drifting mesh backdrop, oversized artwork that
/// breathes with play state, a slim chapter-ticked scrubber, and an
/// accent color pulled from the cover driving the transport controls.
struct AudioFullPlayerView: View {
    @Environment(AudioPlaybackStore.self) private var audioStore
    @Environment(\.dismiss) private var dismiss
    @State private var showChapters = false

    var body: some View {
        let player = audioStore.player
        ZStack {
            AudioPlayerBackground(palette: player.palette)
            content(player: player)
        }
        #if os(tvOS)
        .onExitCommand {
            minimize()
        }
        #endif
        .sheet(isPresented: $showChapters) {
            AudioChaptersSheet(player: player)
        }
    }

    private func minimize() {
        audioStore.dismissFullPlayer()
        dismiss()
    }

    /// "1×", "1.5×", "0.75×" — trailing-zero-free rate labels shared by
    /// the rate menus on every platform.
    static func rateLabel(_ rate: Double) -> String {
        String(format: "%.2g×", rate)
    }

    private func stop(player: AudioPlayerViewModel) {
        Task {
            await player.close()
            minimize()
        }
    }

    @ViewBuilder
    private func content(player: AudioPlayerViewModel) -> some View {
        if player.isLoading {
            VStack(spacing: 16) {
                ProgressView()
                    .controlSize(.large)
                Text("Starting audiobook")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = player.error {
            ErrorView(
                state: error,
                onRetry: { audioStore.retryLastRequest() },
                onGoBack: { audioStore.dismissFullPlayer() }
            )
        } else if player.hasActiveSession {
            #if os(tvOS)
            TVPlayerLayout(
                player: player,
                onShowChapters: { showChapters = true },
                onStop: { stop(player: player) }
            )
            #else
            PortraitPlayerLayout(
                player: player,
                onShowChapters: { showChapters = true },
                onMinimize: minimize,
                onStop: { stop(player: player) }
            )
            #endif
        } else {
            EmptyStateView(
                icon: "headphones",
                title: "No audiobook playing",
                subtitle: nil
            )
        }
    }
}

// MARK: - iPhone / iPad / Mac layout

#if !os(tvOS)
private struct PortraitPlayerLayout: View {
    let player: AudioPlayerViewModel
    let onShowChapters: () -> Void
    let onMinimize: () -> Void
    let onStop: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            topBar

            Spacer(minLength: 16)

            cover
                .frame(maxWidth: 420)
                .padding(.horizontal, 36)

            Spacer(minLength: 28)

            titleBlock

            Spacer(minLength: 24)

            AudioScrubberSection(player: player)
                .padding(.horizontal, 8)

            AudioTransportControls(player: player)
                .padding(.top, 20)

            optionsRow
                .padding(.top, 26)

            Spacer(minLength: 20)
        }
        .padding(.horizontal, 24)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }

    private var topBar: some View {
        HStack {
            Button(action: onMinimize) {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Minimize Player")

            Spacer()

            Button(action: onStop) {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Stop Listening")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .padding(.top, 8)
    }

    private var cover: some View {
        AudioCoverArtView(urlString: player.posterUrl, cornerRadius: 20)
            .shadow(color: .black.opacity(0.55), radius: 28, y: 14)
            .scaleEffect(coverScale)
            .animation(
                reduceMotion ? nil : SiloTheme.springAnimation,
                value: player.isPlaying
            )
    }

    private var coverScale: CGFloat {
        if reduceMotion { return 1 }
        return player.isPlaying ? 1 : 0.92
    }

    private var titleBlock: some View {
        VStack(spacing: 6) {
            Text(player.title)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
                .lineLimit(2)

            if let subtitle = player.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
            }

            if let chapter = player.currentChapter {
                Text(chapterLabel(chapter))
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(player.palette.accent.opacity(0.9))
                    .lineLimit(1)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 8)
    }

    private func chapterLabel(_ chapter: AudioPlaybackChapter) -> String {
        chapter.title ?? "Chapter \(chapter.index + 1)"
    }

    private var optionsRow: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(AudioPlayerViewModel.availableRates, id: \.self) { rate in
                    Button(AudioFullPlayerView.rateLabel(rate)) {
                        player.setPlaybackRate(rate)
                    }
                }
            } label: {
                AudioOptionChip(
                    text: AudioFullPlayerView.rateLabel(player.playbackRate),
                    systemImage: "speedometer",
                    isActive: player.playbackRate != 1.0,
                    accent: player.palette.accent
                )
            }
            .accessibilityLabel("Playback Speed")
            .accessibilityValue(AudioFullPlayerView.rateLabel(player.playbackRate))

            Menu {
                Button("Off") { player.sleepTimer.cancel() }
                Button("15 min") { player.sleepTimer.start(minutes: 15) }
                Button("30 min") { player.sleepTimer.start(minutes: 30) }
                Button("60 min") { player.sleepTimer.start(minutes: 60) }
            } label: {
                AudioOptionChip(
                    text: player.sleepTimer.isActive
                        ? PlayerTimeFormatter.formatCountdown(player.sleepTimer.remainingSeconds)
                        : "Sleep",
                    systemImage: player.sleepTimer.isActive ? "moon.fill" : "moon",
                    isActive: player.sleepTimer.isActive,
                    accent: player.palette.accent
                )
            }
            .accessibilityLabel("Sleep Timer")
            .accessibilityValue(
                player.sleepTimer.isActive
                    ? PlayerTimeFormatter.formatCountdown(player.sleepTimer.remainingSeconds)
                    : "Off"
            )

            if !player.chapters.isEmpty {
                Button(action: onShowChapters) {
                    AudioOptionChip(
                        text: "Chapters",
                        systemImage: "list.bullet",
                        isActive: false,
                        accent: player.palette.accent
                    )
                }
                .accessibilityLabel("Chapters")
            }
        }
        .buttonStyle(.plain)
        .menuStyle(.button)
    }
}

/// Small translucent capsule used for the secondary controls row.
private struct AudioOptionChip: View {
    let text: String
    let systemImage: String
    let isActive: Bool
    let accent: Color

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.footnote.weight(.semibold))
            .monospacedDigit()
            .lineLimit(1)
            .foregroundStyle(isActive ? accent : Color.siloOnSurface)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.white.opacity(0.08), in: Capsule())
            .overlay {
                Capsule().strokeBorder(
                    isActive ? accent.opacity(0.5) : Color.siloOutline,
                    lineWidth: 1
                )
            }
            .contentShape(Capsule())
    }
}
#endif

// MARK: - tvOS layout

#if os(tvOS)
private struct TVPlayerLayout: View {
    let player: AudioPlayerViewModel
    let onShowChapters: () -> Void
    let onStop: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 90) {
            AudioCoverArtView(urlString: player.posterUrl, cornerRadius: 24)
                .frame(width: 620)
                .shadow(color: .black.opacity(0.55), radius: 40, y: 20)

            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Audiobook")
                        .font(.siloSmall.weight(.semibold))
                        .textCase(.uppercase)
                        .kerning(2)
                        .foregroundStyle(.secondary)

                    Text(player.title)
                        .font(.siloTitle)
                        .lineLimit(2)

                    if let subtitle = player.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.siloBody)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let chapter = player.currentChapter {
                        Text(chapter.title ?? "Chapter \(chapter.index + 1)")
                            .font(.siloCaption)
                            .foregroundStyle(player.palette.accent.opacity(0.9))
                            .lineLimit(1)
                            .padding(.top, 6)
                    }
                }

                AudioScrubberSection(player: player)

                HStack(spacing: 20) {
                    Button {
                        player.previousChapter()
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .accessibilityLabel("Previous Chapter")

                    Button {
                        player.skip(by: -30)
                    } label: {
                        Image(systemName: "gobackward.30")
                    }
                    .accessibilityLabel("Back 30 Seconds")

                    Button {
                        player.togglePlayPause()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .frame(minWidth: 80)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                    Button {
                        player.skip(by: 30)
                    } label: {
                        Image(systemName: "goforward.30")
                    }
                    .accessibilityLabel("Forward 30 Seconds")

                    Button {
                        player.nextChapter()
                    } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .accessibilityLabel("Next Chapter")
                }
                .buttonStyle(.bordered)

                HStack(spacing: 20) {
                    Menu {
                        ForEach(AudioPlayerViewModel.availableRates, id: \.self) { rate in
                            Button(AudioFullPlayerView.rateLabel(rate)) {
                                player.setPlaybackRate(rate)
                            }
                        }
                    } label: {
                        Label(AudioFullPlayerView.rateLabel(player.playbackRate), systemImage: "speedometer")
                    }
                    .accessibilityLabel("Playback Speed")

                    Menu {
                        Button("Off") { player.sleepTimer.cancel() }
                        Button("15 min") { player.sleepTimer.start(minutes: 15) }
                        Button("30 min") { player.sleepTimer.start(minutes: 30) }
                        Button("60 min") { player.sleepTimer.start(minutes: 60) }
                    } label: {
                        Label(
                            player.sleepTimer.isActive
                                ? PlayerTimeFormatter.formatCountdown(player.sleepTimer.remainingSeconds)
                                : "Sleep",
                            systemImage: player.sleepTimer.isActive ? "moon.fill" : "moon"
                        )
                        .monospacedDigit()
                    }
                    .accessibilityLabel("Sleep Timer")

                    if !player.chapters.isEmpty {
                        Button(action: onShowChapters) {
                            Label("Chapters", systemImage: "list.bullet")
                        }
                    }

                    Button(action: onStop) {
                        Label("Stop", systemImage: "xmark")
                    }
                    .accessibilityLabel("Stop Listening")
                }
                .buttonStyle(.bordered)
                .font(.siloCaption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, SiloTheme.safePadding)
        .padding(.vertical, 60)
    }
}
#endif

// MARK: - Scrubber

/// Slim PlexAmp-style progress bar with chapter tick marks, an
/// accent-gradient fill, and drag-to-scrub on touch platforms. Time
/// labels show elapsed and remaining; while scrubbing they preview the
/// drag target.
private struct AudioScrubberSection: View {
    let player: AudioPlayerViewModel

    @State private var scrubTime: Double?

    private var displayedTime: Double {
        scrubTime ?? player.currentTime
    }

    private var fraction: Double {
        guard player.duration > 0 else { return 0 }
        return min(max(displayedTime / player.duration, 0), 1)
    }

    private var trackHeight: CGFloat {
        #if os(tvOS)
        10
        #else
        scrubTime == nil ? 6 : 10
        #endif
    }

    var body: some View {
        VStack(spacing: 10) {
            track

            HStack {
                Text(PlayerTimeFormatter.formatHMS(displayedTime))
                Spacer()
                Text("-" + PlayerTimeFormatter.formatHMS(max(0, player.duration - displayedTime)))
            }
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Playback Position")
        .accessibilityValue(
            "\(PlayerTimeFormatter.formatHMS(displayedTime)) of \(PlayerTimeFormatter.formatHMS(player.duration))"
        )
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: player.skip(by: 30)
            case .decrement: player.skip(by: -30)
            @unknown default: break
            }
        }
    }

    private var track: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.16))
                    .frame(height: trackHeight)

                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                player.palette.accent.opacity(0.75),
                                player.palette.accent,
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(
                        width: max(trackHeight, geo.size.width * fraction),
                        height: trackHeight
                    )

                chapterTicks(width: geo.size.width)
            }
            .frame(maxHeight: .infinity, alignment: .center)
            #if !os(tvOS)
            .contentShape(Rectangle())
            .gesture(scrubGesture(trackWidth: geo.size.width))
            #endif
        }
        .frame(height: 30)
        .animation(.easeOut(duration: 0.15), value: trackHeight)
    }

    @ViewBuilder
    private func chapterTicks(width: CGFloat) -> some View {
        if player.duration > 0, player.chapters.count > 1 {
            ForEach(player.chapters.dropFirst()) { chapter in
                Rectangle()
                    .fill(.black.opacity(0.45))
                    .frame(width: 1.5, height: trackHeight)
                    .offset(x: width * (chapter.startSeconds / player.duration))
            }
        }
    }

    #if !os(tvOS)
    private func scrubGesture(trackWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                guard player.duration > 0, trackWidth > 0 else { return }
                let fraction = min(max(value.location.x / trackWidth, 0), 1)
                scrubTime = fraction * player.duration
            }
            .onEnded { _ in
                if let scrubTime {
                    player.seek(to: scrubTime)
                }
                scrubTime = nil
            }
    }
    #endif
}

// MARK: - Transport

#if !os(tvOS)
/// Five-button transport row with the oversized accent play button.
private struct AudioTransportControls: View {
    let player: AudioPlayerViewModel

    var body: some View {
        HStack(spacing: 28) {
            Button {
                player.previousChapter()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Previous Chapter")

            Button {
                player.skip(by: -30)
            } label: {
                Image(systemName: "gobackward.30")
                    .font(.title)
                    .frame(width: 50, height: 50)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Back 30 Seconds")

            Button {
                player.togglePlayPause()
            } label: {
                ZStack {
                    Circle()
                        .fill(player.palette.accent)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 32, weight: .heavy))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                }
                .frame(width: 82, height: 82)
                .shadow(color: player.palette.accent.opacity(0.35), radius: 16, y: 6)
            }
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            Button {
                player.skip(by: 30)
            } label: {
                Image(systemName: "goforward.30")
                    .font(.title)
                    .frame(width: 50, height: 50)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Forward 30 Seconds")

            Button {
                player.nextChapter()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Next Chapter")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.siloOnSurface)
    }
}
#endif
