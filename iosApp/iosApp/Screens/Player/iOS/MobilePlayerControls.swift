#if os(iOS)
import SwiftUI

/// Touch-driven overlay used on iOS/iPadOS. Layout (see
/// docs/ios-player-redesign/mockups.html):
/// - Top strip: close, title block (series eyebrow + episode title)
/// - Center: skip back 10s, play/pause, skip forward 10s
/// - Bottom stack: time row (elapsed / status chips / remaining), capsule
///   scrubber with buffered range + intro tint + chapter ticks + scrub
///   preview bubble, then a labeled action row (Quality menu, Audio &
///   Subtitles sheet, Chapters menu, orientation Lock, More → settings sheet)
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
    @State private var pictureInPicture = PictureInPictureCoordinator.shared
    /// Floating stats card. Kept here rather than on the view model because
    /// it is purely presentation, and kept outside the `showControls` gate
    /// below so the auto-hide takes the transport away without it.
    @State private var showsStats = false


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
                        .padding(.horizontal)
                        .padding(.top)
                        // Hug the bottom: the safe-area inset already keeps
                        // the action row clear of the home indicator, so only
                        // a hairline of extra breathing room is needed.
                        .padding(.bottom, 2)
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .animation(.easeOut(duration: 0.18), value: viewModel.isScrubbing)
                    }
                }
                .transition(.opacity)
            }
            if viewModel.showIntroSkip {
                introSkipPill
            }
            if showsStats {
                MobilePlaybackStatsOverlay(stats: viewModel.playbackStats)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.18), value: showsStats)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .tracks:
                TrackSelectionSheet(viewModel: viewModel) { activeSheet = nil }
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            case .aiSubtitles:
                SubtitleTranslateMenu(
                    viewModel: viewModel,
                    onDismiss: { activeSheet = nil },
                    // Job accepted: close the sheet so the live overlay is
                    // visible on the player.
                    onJobStarted: { activeSheet = nil }
                )
                .presentationDetents([.medium, .large])
            case .subtitleSearch:
                SubtitleSearchMenu(
                    viewModel: viewModel,
                    onDismiss: { activeSheet = nil },
                    // Download succeeded (track already selected): close the
                    // sheet so the player is visible.
                    onDownloaded: { activeSheet = nil }
                )
                .presentationDetents([.large])
            case .settings:
                PlayerSettingsSheet(
                    viewModel: viewModel,
                    sleepTimer: viewModel.sleepTimer,
                    statsOverlayVisible: Binding(
                        get: { showsStats },
                        set: { newValue in
                            showsStats = newValue
                            // Switching it on closes the sheet: the stats are
                            // only useful over the picture they describe.
                            if newValue { activeSheet = nil }
                        }
                    )
                )
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

            if pictureInPicture.isSupported, pictureInPicture.hasSource {
                controlButton(
                    systemName: pictureInPicture.isActive ? "pip.exit" : "pip.enter"
                ) {
                    pictureInPicture.toggle()
                }
                // AVKit can report `possible == false` during the final active
                // transition; the user must still be able to stop PiP.
                .disabled(!pictureInPicture.isPossible && !pictureInPicture.isActive)
                .accessibilityLabel(
                    pictureInPicture.isActive
                        ? "Stop Picture in Picture"
                        : "Start Picture in Picture"
                )
            }

            if viewModel.supportsExternalPlayback {
                AirPlayRoutePicker { isPresentingRoutes in
                    // The route sheet is a UIKit presentation the auto-hide
                    // timer knows nothing about; pin the controls so it can't
                    // dismantle the picker mid-selection.
                    if isPresentingRoutes {
                        viewModel.pinControlsVisible()
                    } else {
                        viewModel.resumeAutoHide()
                    }
                }
                .frame(width: 44, height: 44)
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let eyebrow = titleEyebrow {
                Text(eyebrow)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }
            Text(heroTitle)
                .font(.system(size: 13, weight: .semibold))
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

    /// Fixed circle sizes keep the three buttons proportioned as a family
    /// (content-driven glass sizing made the play disc balloon relative to
    /// the skips). The play/pause disc is white prominent glass with a dark
    /// glyph rather than accent-tinted.
    private var centerCluster: some View {
        HStack(spacing: 36) {
            Button {
                viewModel.skipBackward(10)
            } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Skip Back 10 Seconds")

            Button {
                viewModel.togglePlayPause()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.black.opacity(0.85))
                    // play.fill reads left-heavy inside a circle;
                    // nudge it toward the optical center.
                    .offset(x: viewModel.isPlaying ? 0 : 1.5)
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .tint(.white.opacity(0.9))
            .accessibilityLabel(viewModel.isPlaying ? "Pause" : "Play")

            Button {
                viewModel.skipForward(10)
            } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 50, height: 50)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Skip Forward 10 Seconds")
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
                .font(.caption2)
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
                    .font(.caption2)
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
            let barHeight: CGFloat = viewModel.isScrubbing ? 12 : 6

            ZStack(alignment: .leading) {
                // Base track
                Capsule()
                    .fill(Color.white.opacity(0.2))
                    .frame(height: barHeight)

                // Buffered range from Aether telemetry. Routes that cannot
                // report a comparable value leave the layer empty.
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
                            .frame(width: 2, height: barHeight + 5)
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
                    let previewInset: CGFloat = viewModel.scrubPreviewImage == nil ? 80 : 102
                    scrubPreviewBubble
                        .position(
                            x: min(
                                max(width * progress, previewInset),
                                max(width - previewInset, previewInset)
                            ),
                            y: viewModel.scrubPreviewImage == nil ? -36 : -92
                        )
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            // The custom scrubber is drag-only; expose it to VoiceOver as an
            // adjustable element that seeks through the same skip path.
            .accessibilityElement()
            .accessibilityLabel("Playback Position")
            .accessibilityValue(
                "\(PlayerTimeFormatter.formatHMS(displayTime)) of \(PlayerTimeFormatter.formatHMS(viewModel.duration))"
            )
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: viewModel.skipForward(10)
                case .decrement: viewModel.skipBackward(10)
                @unknown default: break
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
        VStack(spacing: 6) {
            if let image = viewModel.scrubPreviewImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 176, height: 99)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
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
        .padding(7)
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
        case full      // labeled pills, value on the Quality pill
        case compact   // shorter labels, lock folds to a circle
        case icons     // circles everywhere except the Quality value pill
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
        // The Audio & Subtitles pill is only inert when the picker would have
        // nothing at all in it. A track-less file can still offer subtitle
        // search (and the explanation when search isn't configured), so those
        // entry points keep the sheet reachable. This also closes a pre-existing
        // reachability gap: before, a file with no audio and no subtitle
        // tracks disabled the pill outright, making subtitle search — the one
        // feature that could fix exactly that file — impossible to reach.
        let noTracks = viewModel.audioTracks.isEmpty
            && viewModel.subtitleTracks.isEmpty
            && !viewModel.subtitleSearchVisible
            && !aiSubtitlesAvailable
        return HStack(spacing: 8) {
            qualityMenu(compact: style != .full)

            trackSelectionButton(style: style)
                .disabled(noTracks)
                .opacity(noTracks ? 0.4 : 1)
                .accessibilityLabel("Audio & Subtitles")

            if !viewModel.chapters.isEmpty {
                chaptersMenu(style: style)
                    .accessibilityLabel("Chapters")
            }

            lockControl(compact: style != .full)

            controlButton(systemName: "ellipsis") {
                activeSheet = .settings
            }
            .accessibilityLabel("Playback Settings")
        }
    }

    private func qualityMenu(compact: Bool) -> some View {
        let menu = Menu {
            ForEach(viewModel.qualityOptions) { option in
                Button {
                    viewModel.switchQuality(option.id)
                } label: {
                    if option.id == viewModel.activeQualityId {
                        Label(option.labelWithBitrate, systemImage: "checkmark")
                    } else {
                        Text(option.labelWithBitrate)
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                if viewModel.isQualitySwitching {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.white)
                } else {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                }
                if compact {
                    Text(qualityValueText)
                        .font(.system(size: 12, weight: .semibold))
                } else {
                    Text("Quality")
                        .font(.system(size: 12, weight: .semibold))
                    Text(qualityValueText)
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 34)
        }
        .menuStyle(.button)
        // Keep Auto at the top, reading down.
        .menuOrder(.fixed)

        return Group {
            // The prominent style flags a non-Auto quality cap at a glance.
            if viewModel.activeQualityId == ApplePlaybackQuality.autoId {
                menu.buttonStyle(.glass)
            } else {
                menu.buttonStyle(.glassProminent)
            }
        }
        .buttonBorderShape(.capsule)
        .accessibilityLabel("Playback Quality")
        .accessibilityValue(qualityValueText)
    }

    /// Short value for the pill — the tier's resolution ("1080p") rather
    /// than the full "Up to 1080p HD (High)" menu label.
    private var qualityValueText: String {
        guard let active = viewModel.qualityOptions.first(where: { $0.id == viewModel.activeQualityId }),
              !active.isAuto, !active.isOriginal, !active.resolution.isEmpty else {
            return "Auto"
        }
        return active.resolution
    }

    // MARK: - Audio & Subtitles sheet

    /// Whether any AI subtitle action is available (translate or transcribe),
    /// per the server's capability probes **and** the current track list.
    /// Gates the "AI Subtitles…" row so it never opens an empty menu.
    private var aiSubtitlesAvailable: Bool {
        SubtitleTranslateMenu.hasActionableSource(viewModel)
    }

    /// Track inventories are unbounded, so they use a scrollable sheet rather
    /// than a native `Menu`, whose landscape popover can clip later rows.
    private func trackSelectionButton(style: ActionRowStyle) -> some View {
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
    }

    // MARK: - Chapters menu

    private var currentChapterIndex: Int? {
        viewModel.chapters.lastIndex(where: { $0.time <= viewModel.currentTime })
    }

    /// Native chapter picker: one row per chapter with the timestamp as the
    /// menu subtitle and a checkmark on the chapter currently playing.
    private func chaptersMenu(style: ActionRowStyle) -> some View {
        Menu {
            ForEach(viewModel.chapters) { chapter in
                Button {
                    viewModel.seekTo(seconds: chapter.time)
                } label: {
                    if currentChapterIndex == chapter.index {
                        Label {
                            Text(chapterMenuTitle(chapter))
                            Text(PlayerTimeFormatter.formatHMS(chapter.time))
                        } icon: {
                            Image(systemName: "checkmark")
                        }
                    } else {
                        Text(chapterMenuTitle(chapter))
                        Text(PlayerTimeFormatter.formatHMS(chapter.time))
                    }
                }
            }
        } label: {
            menuPillLabel(
                systemImage: "list.bullet",
                title: style == .icons ? nil : "Chapters"
            )
        }
        .menuStyle(.button)
        // Keep Chapter 1 at the top, reading down.
        .menuOrder(.fixed)
        .buttonStyle(.glass)
        .buttonBorderShape(style == .icons ? .circle : .capsule)
    }

    private func chapterMenuTitle(_ chapter: PlayerChapterInfo) -> String {
        "\(chapter.index + 1).  \(chapter.title ?? "Chapter \(chapter.index + 1)")"
    }

    /// Menu label matching the `actionPill` (titled) / `controlButton`
    /// (icon circle) appearance so menus and buttons read as one family.
    @ViewBuilder
    private func menuPillLabel(systemImage: String, title: String?) -> some View {
        if let title {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 34)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
        }
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
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 34)
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
                        HStack(spacing: 6) {
                            Image(systemName: "forward.end.fill")
                            Text("Skip Intro")
                            if let countdown = viewModel.introAutoSkipCountdownSeconds {
                                Text("· \(countdown)")
                                    .opacity(0.55)
                                    .monospacedDigit()
                            }
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black.opacity(0.85))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                    }
                    // White prominent glass with a dark glyph, matching the
                    // play/pause disc — accent-tinted prominent reads as an
                    // app-colored web button over video.
                    .buttonStyle(.glassProminent)
                    .tint(.white.opacity(0.9))
                    .accessibilityLabel(
                        viewModel.introAutoSkipCountdownSeconds == nil ? "Skip Intro" : "Skip Intro Now"
                    )
                }
            }
            .padding(.horizontal, 24)
            // Clear the bottom stack while the controls are up; hug the
            // bottom edge when the pill is floating alone.
            .padding(.bottom, viewModel.showControls ? 88 : 24)
        }
        .animation(.easeOut(duration: 0.2), value: viewModel.showControls)
        .transition(.opacity)
    }

    // MARK: - Helpers

    private func controlButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
        }
        // `.circle` keeps each glass control a compact circle instead of the
        // default wider capsule so rows of controls stay dense.
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    // MARK: - Sheet identifier

    private enum PlayerSheet: Identifiable {
        case tracks, aiSubtitles, subtitleSearch, settings
        var id: Self { self }
    }
}
#endif
