#if os(iOS)
import SwiftUI

/// Touch-driven overlay used on iOS/iPadOS. Layout (see
/// docs/ios-player-redesign/mockups.html):
/// - Top strip: close, title block (series eyebrow + episode title), AirPlay
/// - Center: skip back 10s, play/pause, skip forward 10s
/// - Bottom stack: time row (elapsed / status chips / remaining), capsule
///   scrubber with buffered range + intro tint + chapter ticks + scrub
///   preview bubble, then a labeled action row (Speed menu, Audio &
///   Subtitles, Chapters, orientation Lock, More → settings sheet)
///
/// The whole thing is wrapped in a tap-to-toggle gesture; auto-hide after 3 s
/// of inactivity. The view is stateful only for sheet presentation and the
/// trailing-time display mode; the rest of the state lives on
/// `PlayerViewModel`. Invisible gestures (double-tap skip, hold-2×, edge
/// swipes) live in `MobilePlayerGestureLayer` underneath this overlay.
struct MobilePlayerControls: View {
    let viewModel: PlayerViewModel
    let orientationCoordinator: PlayerOrientationCoordinator
    let onDismiss: () -> Void

    @State private var activeSheet: PlayerSheet?
    /// Trailing time label mode: remaining ("−12:34") when true, total
    /// duration otherwise. Tap the label to flip — the native player idiom.
    @State private var showsRemainingTime = true

    /// Speed choices offered by the quick menu. Mirrors the ladder the old
    /// settings-sheet picker offered.
    private static let speedOptions: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

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
                        Color.black.opacity(viewModel.isScrubbing ? 0.55 : 0.4)
                            .ignoresSafeArea()
                            .onTapGesture { viewModel.toggleControls() }

                        VStack(spacing: 0) {
                            topStrip
                                .opacity(recedingOpacity)
                            Spacer()
                            centerCluster
                                .opacity(recedingOpacity)
                            Spacer()
                            bottomStack
                        }
                        .padding()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .animation(.easeOut(duration: 0.18), value: viewModel.isScrubbing)
                    }
                }
                .transition(.opacity)
            }
            if viewModel.showIntroSkip {
                introSkipPill
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .tracks:
                TrackSelectionSheet(viewModel: viewModel) { activeSheet = nil }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            case .chapters:
                ChapterSheet(viewModel: viewModel) { activeSheet = nil }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
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

    /// Top strip, center cluster and action row fade out of the way while
    /// the user is scrubbing so the preview bubble owns the screen.
    private var recedingOpacity: Double {
        viewModel.isScrubbing ? 0.12 : 1
    }

    // MARK: - Top strip

    private var topStrip: some View {
        HStack(alignment: .center, spacing: 12) {
            controlButton(systemName: "xmark", action: onDismiss)
                .accessibilityLabel("Close Player")

            titleBlock

            Spacer(minLength: 12)

            AirPlayRoutePicker()
                .frame(width: 44, height: 44)
                .siloGlass(in: Circle())
                .accessibilityLabel("AirPlay")
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let eyebrow = titleEyebrow {
                Text(eyebrow)
                    .font(.caption2.weight(.semibold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Text(heroTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .shadow(color: .black.opacity(0.5), radius: 6, y: 1)
        .layoutPriority(-1)
    }

    /// "SEVERANCE · S2:E4"-style context line. Series title + episode tag
    /// for episodes, release year for movies, nothing when metadata hasn't
    /// resolved yet.
    private var titleEyebrow: String? {
        let metadata = viewModel.metadata
        var parts: [String] = []
        if let series = metadata.seriesTitle, !series.isEmpty {
            parts.append(series)
        }
        if let tag = metadata.episodeTag, !tag.isEmpty {
            parts.append(tag)
        }
        if parts.isEmpty, let year = metadata.year {
            parts.append(String(year))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ").uppercased()
    }

    private var heroTitle: String {
        let primary = viewModel.metadata.primaryTitle
        return primary.isEmpty ? viewModel.title : primary
    }

    // MARK: - Center

    private var centerCluster: some View {
        HStack(spacing: 48) {
            Button {
                viewModel.skipBackward(10)
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
                viewModel.skipForward(10)
            } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.glass)
        }
    }

    // MARK: - Bottom stack

    private var bottomStack: some View {
        VStack(spacing: 10) {
            timeRow
            progressSlider
            actionRow
                .opacity(recedingOpacity)
        }
    }

    private var timeRow: some View {
        HStack {
            Text(PlayerTimeFormatter.formatHMS(displayTime))
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .monospacedDigit()

            Spacer()

            if viewModel.sleepTimer.isActive {
                statusChip(
                    systemImage: "moon.zzz.fill",
                    text: PlayerTimeFormatter.formatCountdown(viewModel.sleepTimer.remainingSeconds)
                )
            }

            Spacer()

            Button {
                showsRemainingTime.toggle()
            } label: {
                Text(trailingTimeText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
                    .monospacedDigit()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(showsRemainingTime ? "Time Remaining" : "Duration")
            .accessibilityHint("Switches between time remaining and total duration")
        }
    }

    private var trailingTimeText: String {
        if showsRemainingTime {
            return "−" + PlayerTimeFormatter.formatHMS(max(viewModel.duration - displayTime, 0))
        }
        return PlayerTimeFormatter.formatHMS(viewModel.duration)
    }

    private func statusChip(systemImage: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
            Text(text)
                .font(.system(size: 11, weight: .bold))
                .monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.45)))
        .overlay(Capsule().stroke(.white.opacity(0.16), lineWidth: 0.5))
    }

    private var displayTime: Double {
        viewModel.isScrubbing ? viewModel.scrubPreviewTime : viewModel.currentTime
    }

    // MARK: - Scrubber

    private var progressSlider: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = viewModel.duration > 0
                ? min(max(displayTime / viewModel.duration, 0), 1)
                : 0
            let barHeight: CGFloat = viewModel.isScrubbing ? 14 : 8

            ZStack(alignment: .leading) {
                // Base track
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: barHeight)

                // Buffered range (AVPlayer routes only; CoreMedia reports 0
                // so the layer simply never draws).
                if let buffered = bufferedFraction, buffered > progress {
                    Capsule()
                        .fill(Color.white.opacity(0.22))
                        .frame(width: max(width * buffered, barHeight), height: barHeight)
                }

                introMarker(width: width, height: barHeight)

                // Chapter ticks. Rendered behind the fill so they're visible
                // in unplayed territory; the fill covers them over played
                // time, which matches Apple's native transport-bar behavior.
                if viewModel.duration > 0 && !viewModel.chapters.isEmpty {
                    ForEach(viewModel.chapters) { chapter in
                        let fraction = chapter.time / viewModel.duration
                        Capsule()
                            .fill(Color.white.opacity(0.6))
                            .frame(width: 2, height: barHeight + 6)
                            .offset(x: width * min(max(fraction, 0), 1) - 1)
                    }
                }

                // Played portion. Thumbless — the whole bar is the handle.
                Capsule()
                    .fill(Color.white)
                    .frame(width: max(width * progress, barHeight), height: barHeight)
                    .shadow(color: .white.opacity(viewModel.isScrubbing ? 0.35 : 0), radius: 8)
            }
            .frame(height: 20, alignment: .center)
            .animation(.snappy(duration: 0.22), value: viewModel.isScrubbing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = min(max(value.location.x / width, 0), 1)
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
            .overlay(alignment: .topLeading) {
                if viewModel.isScrubbing {
                    scrubPreviewBubble
                        .position(
                            x: min(max(width * progress, 80), max(width - 80, 80)),
                            y: -36
                        )
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .frame(height: 20)
    }

    private var bufferedFraction: Double? {
        guard viewModel.duration > 0, viewModel.bufferedAheadSeconds > 0 else { return nil }
        let end = (viewModel.currentTime + viewModel.bufferedAheadSeconds) / viewModel.duration
        return min(max(end, 0), 1)
    }

    /// Floating time + chapter readout pinned above the touch point while
    /// scrubbing. Presentation-only: reads the same `scrubPreviewTime` the
    /// seek machinery already maintains.
    private var scrubPreviewBubble: some View {
        VStack(spacing: 2) {
            Text(PlayerTimeFormatter.formatHMS(viewModel.scrubPreviewTime))
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(.white)
                .monospacedDigit()
            if let chapter = chapterTitle(at: viewModel.scrubPreviewTime) {
                Text(chapter)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .siloGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .fixedSize()
    }

    private func chapterTitle(at time: Double) -> String? {
        guard let chapter = viewModel.chapters.last(where: { $0.time <= time }) else { return nil }
        return chapter.title ?? "Chapter \(chapter.index + 1)"
    }

    @ViewBuilder
    private func introMarker(width: CGFloat, height: CGFloat) -> some View {
        if let introRange = viewModel.introRange, viewModel.duration > 0 {
            let start = min(max(introRange.start / viewModel.duration, 0), 1)
            let end = min(max(introRange.end / viewModel.duration, 0), 1)
            if end > start {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.cyan.opacity(0.4))
                    .frame(width: width * (end - start), height: height)
                    .offset(x: width * start)
            }
        }
    }

    // MARK: - Action row

    private enum ActionRowStyle {
        case full      // labeled pills, value on the Speed pill
        case compact   // shorter labels, lock folds to a circle
        case icons     // circles everywhere except the Speed value pill
    }

    /// Labeled pill row. `ViewThatFits` tries the full labels first, then
    /// compact ones, then icon circles, so the row never truncates or wraps
    /// — an iPhone in portrait with chapters present lands on `.icons`.
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            actionRowContent(style: .full)
            actionRowContent(style: .compact)
            actionRowContent(style: .icons)
        }
        .frame(maxWidth: .infinity)
    }

    private func actionRowContent(style: ActionRowStyle) -> some View {
        let noTracks = viewModel.audioTracks.isEmpty && viewModel.subtitleTracks.isEmpty
        return HStack(spacing: 8) {
            speedMenu(compact: style != .full)

            Group {
                if style == .icons {
                    controlButton(systemName: "captions.bubble") {
                        activeSheet = .tracks
                    }
                } else {
                    actionPill(
                        systemImage: "captions.bubble",
                        title: style == .compact ? "Audio & Subs" : "Audio & Subtitles"
                    ) {
                        activeSheet = .tracks
                    }
                }
            }
            .disabled(noTracks)
            .opacity(noTracks ? 0.4 : 1)
            .accessibilityLabel("Audio & Subtitles")

            if !viewModel.chapters.isEmpty {
                Group {
                    if style == .icons {
                        controlButton(systemName: "list.bullet") {
                            activeSheet = .chapters
                        }
                    } else {
                        actionPill(systemImage: "list.bullet", title: "Chapters") {
                            activeSheet = .chapters
                        }
                    }
                }
                .accessibilityLabel("Chapters")
            }

            lockControl(compact: style != .full)

            controlButton(systemName: "ellipsis") {
                activeSheet = .settings
            }
            .accessibilityLabel("Playback Settings")
        }
    }

    private func speedMenu(compact: Bool) -> some View {
        let menu = Menu {
            ForEach(Self.speedOptions, id: \.self) { speed in
                Button {
                    viewModel.setPlaybackSpeed(speed)
                } label: {
                    if speed == viewModel.settings.playbackSpeed {
                        Label(speedLabel(speed), systemImage: "checkmark")
                    } else {
                        Text(speedLabel(speed))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.67percent")
                    .font(.system(size: 13, weight: .semibold))
                if compact {
                    Text(speedValueText)
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    Text("Speed")
                        .font(.system(size: 13, weight: .semibold))
                    Text(speedValueText)
                        .font(.system(size: 12, weight: .medium))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 38)
        }
        .menuStyle(.button)

        return Group {
            // The prominent style flags a non-default speed at a glance.
            if viewModel.settings.playbackSpeed == 1.0 {
                menu.buttonStyle(.glass)
            } else {
                menu.buttonStyle(.glassProminent)
            }
        }
        .buttonBorderShape(.capsule)
        // A native Menu offers no isPresented hook, so pin the controls the
        // moment the label is tapped; `setPlaybackSpeed` re-arms auto-hide
        // when a choice lands, and any later overlay tap does too.
        .simultaneousGesture(TapGesture().onEnded { viewModel.pinControlsVisible() })
        .accessibilityLabel("Playback Speed")
        .accessibilityValue(speedValueText)
    }

    private var speedValueText: String {
        speedLabel(viewModel.settings.playbackSpeed)
    }

    private func speedLabel(_ speed: Double) -> String {
        speed == 1.0 ? "1×" : String(format: "%g×", speed)
    }

    private func lockControl(compact: Bool) -> some View {
        let isLocked = orientationCoordinator.isLandscapeLocked
        return Group {
            if compact {
                controlButton(systemName: isLocked ? "lock.fill" : "lock.open") {
                    orientationCoordinator.togglePlayerMode()
                }
            } else {
                actionPill(systemImage: isLocked ? "lock.fill" : "lock.open", title: "Lock") {
                    orientationCoordinator.togglePlayerMode()
                }
            }
        }
        .accessibilityLabel(isLocked ? "Landscape Locked" : "Rotate Freely")
        .accessibilityHint(
            isLocked
                ? "Allows portrait rotation during playback"
                : "Locks playback to landscape"
        )
    }

    private func actionPill(
        systemImage: String,
        title: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 38)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.capsule)
    }

    // MARK: - Intro skip

    /// One prominent pill that covers both intro states: "Skip Intro" while
    /// the range is active, "Skip Intro · N" with a cancel circle beside it
    /// once the auto-skip countdown is armed.
    private var introSkipPill: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                HStack(spacing: 10) {
                    if viewModel.introAutoSkipCountdownSeconds != nil {
                        Button {
                            viewModel.cancelIntroAutoSkip()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 38, height: 38)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .accessibilityLabel("Cancel Auto-Skip Intro")
                    }

                    Button {
                        viewModel.skipIntro()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "forward.end.fill")
                            Text("Skip Intro")
                            if let countdown = viewModel.introAutoSkipCountdownSeconds {
                                Text("· \(countdown)")
                                    .opacity(0.65)
                                    .monospacedDigit()
                            }
                        }
                        .font(.system(size: 15, weight: .semibold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 11)
                    }
                    .buttonStyle(.glassProminent)
                    .accessibilityLabel(
                        viewModel.introAutoSkipCountdownSeconds == nil ? "Skip Intro" : "Skip Intro Now"
                    )
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 96)
        }
        .transition(.opacity)
    }

    // MARK: - Helpers

    private func controlButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
        }
        // `.circle` keeps each glass control a compact circle instead of the
        // default wider capsule so rows of controls stay dense.
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
