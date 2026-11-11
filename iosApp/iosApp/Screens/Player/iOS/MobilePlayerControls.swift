#if os(iOS)
import SwiftUI

/// Touch-driven overlay used on iOS/iPadOS. Layout:
/// - Top strip: close, title block (series eyebrow + episode title), PiP,
///   AirPlay, rotate, rotation lock
/// - Center: skip back, play/pause, skip forward (profile video intervals),
///   pinned to the middle of the player rather than between the bars
/// - Bottom stack: time row (elapsed / status chips / remaining), capsule
///   scrubber with buffered range + intro tint + chapter ticks + scrub
///   preview bubble, then a labeled action row (Quality menu, Audio &
///   Subtitles sheet, Chapters menu, More → settings sheet)
///
/// The whole thing is wrapped in a tap-to-toggle gesture and the auto-hide.
/// The view is stateful only for sheet presentation and the
/// trailing-time display mode; the rest of the state lives on
/// `PlayerViewModel`. Invisible gestures (double-tap skip, hold-2×, edge
/// swipes) live in `MobilePlayerGestureLayer` underneath this overlay.
struct MobilePlayerControls: View {
    let viewModel: PlayerViewModel
    /// The player's loading spinner is up; it takes the play/pause button's
    /// place while the controls show.
    let showsLoadingSpinner: Bool
    let onDismiss: () -> Void

    @State private var activeSheet: PlayerSheet?
    @State private var tracksDetent: PresentationDetent = .medium
    @State private var tracksNestedSheetCovers = false
    @State private var chaptersDetent: PresentationDetent = .medium
    @State private var qualityDetent: PresentationDetent = .medium
    /// Trailing time label mode: remaining ("−12:34") when true, total
    /// duration otherwise. Tap the label to flip — the native player idiom.
    @State private var showsRemainingTime = true
    @State private var pictureInPicture = PictureInPictureCoordinator.shared
    @State private var orientationCoordinator = PlayerOrientationCoordinator.shared
    /// Floating stats card. Kept here rather than on the view model because
    /// it is purely presentation. It shows while the controls are away and
    /// steps aside while they show: it is too tall to fit between them.
    @State private var showsStats = false
    /// Set when switching the stats on closes the sheet: the controls then
    /// hide instead of restarting their auto-hide, so the stats show at once.
    @State private var hidesControlsWhenSheetCloses = false
    /// Global top edge of the timeline while the controls show. Skip pills
    /// float just above it so they never cover the time labels.
    @State private var timelineMinY: CGFloat?
    @Environment(\.playerTabletopLayout) private var tabletopLayout
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.locale) private var locale

    var body: some View {
        // NOTE: the .sheet modifier MUST live outside the `showControls` gate.
        // If it's attached to a view that only exists while controls are
        // visible, the auto-hide tears down the sheet's host and dismisses
        // the sheet mid-interaction — then re-presents it when controls come
        // back, because @State activeSheet survives the rebuild.
        ZStack {
            // Fills the player whatever else shows, so the side panel
            // overlay below has the player's size to lay out in.
            Color.clear.allowsHitTesting(false)
            // A side panel takes the controls' place; the picture stays.
            if viewModel.showControls && panelSheet == nil {
                // GeometryReader pins the control stack to the player's own
                // bounds. The bars are siblings of the shared player notice in
                // `PlayerView`'s ZStack; inside the player's `.fullScreenCover`
                // a too-wide bar would otherwise stretch that shared layer past
                // the screen and drag the notice off both edges in portrait.
                // Clamping the stack to `proxy.size` keeps every overlay inside
                // the visible frame regardless of how wide a bar wants to be.
                GeometryReader { proxy in
                    // In the tabletop posture the controls take the pane
                    // below the fold, clear of the video above it.
                    let paneTop = tabletopControlsTop(in: proxy)
                    let pane = CGSize(width: proxy.size.width, height: proxy.size.height - paneTop)
                    ZStack {
                        Color.black.opacity(viewModel.isScrubbing ? 0.55 : 0.4)
                            .ignoresSafeArea()
                            .onTapGesture { viewModel.toggleControls() }

                        // Centred on the whole pane (the screen, where the
                        // video is, unless the tabletop posture moved the
                        // controls below the fold) rather than between the top
                        // strip and the taller bottom stack, which would pull
                        // it off-centre. Kept beneath the bars so the scrub
                        // preview draws over it.
                        if let dock = portraitDock(in: proxy) {
                            dockedControls(dock, pane: pane)
                        } else {
                            centerCluster(playSize: Self.playButtonSize, skipSize: Self.skipButtonSize, spacing: 48)
                                .opacity(recedingOpacity)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .ignoresSafeArea()

                            VStack(spacing: 0) {
                                topStrip(compact: pane.width < pane.height)
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
                            .frame(width: pane.width, height: pane.height)
                        }
                    }
                    .padding(.top, paneTop)
                    .animation(.easeOut(duration: 0.18), value: viewModel.isScrubbing)
                }
                .transition(.opacity)
            }
            introSkipPill
            if viewModel.showSegmentSkip {
                segmentSkipPill
            }
            if showsStats && !viewModel.showControls {
                MobilePlaybackStatsOverlay(stats: viewModel.playbackStats) { showsStats = false }
                    .transition(.opacity)
            }
        }
        // Tap-to-toggle and auto-hide flip `showControls` without an
        // animation of their own; fade every control in and out together.
        .animation(.easeOut(duration: 0.18), value: viewModel.showControls)
        .animation(.easeOut(duration: 0.18), value: showsStats)
        // Fades in, and out when its timer runs out. Tap takes it down at once
        // (see `PlayerViewModel.selectIntroSkipPrompt`).
        .animation(.easeOut(duration: 0.2), value: viewModel.showIntroSkip)
        // A phone on its side gets the menus as a panel at the trailing
        // edge, sized to its content and with the picture still in view; a
        // full-screen sheet would stretch short lists across the whole
        // screen. Upright phones and iPads keep the native sheets.
        .overlay { sidePanel }
        .animation(.easeOut(duration: 0.22), value: panelSheet)
        .sheet(item: Binding(
            get: { usesSidePanel ? nil : activeSheet },
            set: { activeSheet = $0 }
        )) { sheet in
            if let detent = detentBinding(for: sheet) {
                sheetContent(sheet)
                    .presentationDetents([.medium, .large], selection: detent)
                    .presentationDragIndicator(.visible)
            } else {
                sheetContent(sheet)
                    .presentationDetents([.large])
            }
        }
        .onChange(of: activeSheet) { _, newValue in
            // Keep controls pinned while a sheet is up, and restart the
            // auto-hide timer once it closes.
            if newValue != nil {
                viewModel.pinControlsVisible()
                return
            }
            if hidesControlsWhenSheetCloses {
                hidesControlsWhenSheetCloses = false
                viewModel.dismissControls()
            } else {
                viewModel.resumeAutoHide()
            }
            tracksDetent = .medium
            chaptersDetent = .medium
            qualityDetent = .medium
            tracksNestedSheetCovers = false
        }
        // Initial too: controls that mount again say whether their sheet
        // came back with them.
        .onChange(of: sheetCoversPlayer, initial: true) { _, covers in
            viewModel.playerSheetCoversPlayer(covers)
        }
    }

    @ViewBuilder
    private func sheetContent(_ sheet: PlayerSheet) -> some View {
        switch sheet {
        case .tracks:
            TrackSelectionSheet(viewModel: viewModel, nestedSheetCoversPlayer: $tracksNestedSheetCovers) {
                activeSheet = nil
            }
        case .quality:
            QualitySheet(viewModel: viewModel) { activeSheet = nil }
        case .chapters:
            ChapterListSheet(viewModel: viewModel) { activeSheet = nil }
        case .settings:
            PlayerSettingsSheet(
                viewModel: viewModel,
                sleepTimer: viewModel.sleepTimer,
                statsOverlayVisible: Binding(
                    get: { showsStats },
                    set: { newValue in
                        showsStats = newValue
                        // Switching it on closes the sheet and the
                        // controls: the stats are only useful over the
                        // picture they describe, and show while the
                        // controls are away.
                        if newValue {
                            hidesControlsWhenSheetCloses = true
                            activeSheet = nil
                        }
                    }
                ),
                onDismiss: { activeSheet = nil }
            )
        }
    }

    /// The half/full-height selection of a sheet that offers both; nil for
    /// the settings, which always open full height.
    private func detentBinding(for sheet: PlayerSheet) -> Binding<PresentationDetent>? {
        switch sheet {
        case .tracks: $tracksDetent
        case .quality: $qualityDetent
        case .chapters: $chaptersDetent
        case .settings: nil
        }
    }

    /// Landscape phone: the menus open as a trailing panel instead of a sheet.
    private var usesSidePanel: Bool {
        UIDevice.current.userInterfaceIdiom == .phone && verticalSizeClass == .compact
    }

    private var panelSheet: PlayerSheet? {
        usesSidePanel ? activeSheet : nil
    }

    @ViewBuilder
    private var sidePanel: some View {
        if let sheet = panelSheet {
            ZStack(alignment: .trailing) {
                // The picture stays in view, dimmed; a tap on it closes.
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { activeSheet = nil }
                    .accessibilityHidden(true)
                // The rows keep to the safe area; the plate behind them runs
                // out to the screen edges.
                sheetContent(sheet)
                    .frame(width: sheet == .tracks ? 620 : 380)
                    .frame(maxHeight: .infinity)
                    .background {
                        UnevenRoundedRectangle(topLeadingRadius: 22, bottomLeadingRadius: 22, style: .continuous)
                            .fill(Color(white: 0.06))
                            .shadow(color: .black.opacity(0.5), radius: 24, x: -6)
                            .ignoresSafeArea()
                    }
                    .transition(.move(edge: .trailing))
            }
        }
    }

    /// Top strip, center cluster and action row fade out of the way while
    /// the user is scrubbing so the preview bubble owns the screen.
    private var recedingOpacity: Double {
        viewModel.isScrubbing ? 0.12 : 1
    }

    // MARK: - Top strip

    private func topStrip(compact: Bool, showsTitle: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                closeButton
                if !compact { titleBlock }
                Spacer(minLength: 0)
                if !compact || !showsTitle { externalPlaybackControls }
                if showsRotationControls { rotationControls }
            }
            if compact && showsTitle {
                HStack(spacing: 12) {
                    titleBlock
                    Spacer(minLength: 12)
                    externalPlaybackControls
                }
            }
        }
    }

    private var closeButton: some View {
        Button(action: onDismiss) {
            Image(systemName: "xmark")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: SiloTheme.topBarIconHitSize, height: SiloTheme.topBarIconHitSize)
        }
        .buttonStyle(MobilePlayerGlassButtonStyle())
        .accessibilityLabel(Text(.playerControlsClosePlayer))
        .accessibilityIdentifier("player.close")
    }

    @ViewBuilder
    private var externalPlaybackControls: some View {
        if !viewModel.isWatchPartyPlayback, pictureInPicture.isSupported, pictureInPicture.hasSource {
            controlButton(
                systemName: pictureInPicture.isActive ? "pip.exit" : "pip.enter"
            ) {
                pictureInPicture.toggle()
            }
            // AVKit can report `possible == false` during the final active
            // transition; the user must still be able to stop PiP.
            .disabled(!pictureInPicture.isPossible && !pictureInPicture.isActive)
            .accessibilityLabel(Text(
                pictureInPicture.isActive
                    ? LocalizedStringResource.playerControlsStopPictureInPicture
                    : .playerControlsStartPictureInPicture
            ))
        }

        if !viewModel.isWatchPartyPlayback, viewModel.supportsExternalPlayback {
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
            .frame(width: SiloTheme.topBarIconHitSize, height: SiloTheme.topBarIconHitSize)
            .siloPlayerGlass(in: Circle(), interactive: true)
        }
    }

    /// The iPhone Duo's open display turns with the device and ignores the
    /// app's rotation requests, so it gets no rotate or lock buttons. It is
    /// the only phone window that is regular in both dimensions.
    private var showsRotationControls: Bool {
        !(UIDevice.current.userInterfaceIdiom == .phone
            && horizontalSizeClass == .regular && verticalSizeClass == .regular)
    }

    /// Where the controls start: the top of the player, or just below the
    /// fold in the iPhone Duo's tabletop posture.
    private func tabletopControlsTop(in proxy: GeometryProxy) -> CGFloat {
        guard let tabletopLayout else { return 0 }
        let top = tabletopLayout.controlsMinY - proxy.frame(in: .global).minY
        return min(max(top, 0), proxy.size.height)
    }

    /// Where the letterboxed picture sits, in the controls' own coordinates,
    /// when an upright phone leaves room under it for the controls.
    private struct PortraitDock {
        let pictureTop: CGFloat
        let pictureBottom: CGFloat
    }

    /// The picture is centred on the whole screen, so a phone held upright
    /// shows a film as a band across the middle. The controls then gather
    /// around that band (title above it, timeline, transport and actions
    /// below it) instead of spreading to the screen edges. Nil when the
    /// picture fills the height, its size is not known yet, or the room
    /// under it is too small.
    private func portraitDock(in proxy: GeometryProxy) -> PortraitDock? {
        guard tabletopLayout == nil, proxy.size.width < proxy.size.height else { return nil }
        let engine = viewModel.aetherEngine
        let pixelAspect = engine.sourceVideoPixelAspectRatio > 0 ? engine.sourceVideoPixelAspectRatio : 1
        let videoWidth = CGFloat(engine.sourceVideoWidth) * CGFloat(pixelAspect)
        let videoHeight = CGFloat(engine.sourceVideoHeight)
        guard videoWidth > 0, videoHeight > 0 else { return nil }
        let insets = proxy.safeAreaInsets
        let screenWidth = proxy.size.width + insets.leading + insets.trailing
        let screenHeight = proxy.size.height + insets.top + insets.bottom
        let pictureHeight = min(screenHeight, screenWidth * videoHeight / videoWidth)
        let top = (screenHeight - pictureHeight) / 2 - insets.top
        let bottom = top + pictureHeight
        guard proxy.size.height - bottom >= Self.dockMinHeight, top >= Self.dockTopMinHeight else { return nil }
        return PortraitDock(pictureTop: top, pictureBottom: bottom)
    }

    /// Room the docked timeline, transport and action row need under the picture.
    private static let dockMinHeight: CGFloat = 210
    /// Room the top strip and title need above the picture.
    private static let dockTopMinHeight: CGFloat = 140

    @ViewBuilder
    private func dockedControls(_ dock: PortraitDock, pane: CGSize) -> some View {
        // The top strip and title sit together just above the picture, so
        // the whole HUD reads as one group around it.
        VStack(alignment: .leading, spacing: 14) {
            topStrip(compact: true, showsTitle: false)
            dockTitleBlock
                .padding(.horizontal, 4)
        }
        .opacity(recedingOpacity)
        .padding(.horizontal)
        .frame(width: pane.width, height: max(0, dock.pictureTop - 12), alignment: .bottom)
        .frame(width: pane.width, height: pane.height, alignment: .top)

        VStack(spacing: 14) {
            timeline
            centerCluster(playSize: 60, skipSize: 46, spacing: 40)
                .opacity(recedingOpacity)
            actionRow
                .opacity(recedingOpacity)
        }
        .padding(.horizontal)
        .padding(.top, dock.pictureBottom + 14)
        .frame(width: pane.width, height: pane.height, alignment: .top)
    }

    /// The title over the picture in the docked layout: series line, then
    /// the title at a size that holds its own above a film.
    private var dockTitleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let eyebrow = titleEyebrow {
                Text(eyebrow)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Text(heroTitle)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
            // What is on screen now: runtime and the chapter playing, so the
            // band over the picture carries information, not just a name.
            if let line = dockDetailLine {
                Text(line)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var dockDetailLine: String? {
        var parts: [String] = []
        if viewModel.duration > 0 {
            parts.append(PlayerTimeFormatter.formatRuntime(viewModel.duration, locale: locale))
        }
        if let chapter = viewModel.chapters.last(where: { $0.time <= viewModel.currentTime }) {
            parts.append(chapter.title.map { AppLanguage.isolated($0) }
                ?? AppLanguage.string(
                    .optionsChapterNumbered(LocaleFormat.integer(chapter.index + 1, locale: locale)),
                    locale: locale
                ))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var rotationControls: some View {
        HStack(spacing: 12) {
            controlButton(systemName: "rectangle.landscape.rotate") {
                orientationCoordinator.togglePlayerOrientation()
                viewModel.resumeAutoHide()
            }
            .accessibilityLabel(Text(orientationCoordinator.nextPlayerOrientation.rotateToLabel))
            .accessibilityHint(Text(.playerOrientationRotateHint))
            .accessibilityIdentifier("player.rotate")

            // The open and closed glyphs differ only in the padlock's shackle,
            // so the lock also takes the active tint the quality pill uses.
            controlButton(
                systemName: orientationCoordinator.isRotationLocked ? "lock.rotation" : "lock.rotation.open",
                tint: orientationCoordinator.isRotationLocked ? Color.white.opacity(0.22) : nil
            ) {
                orientationCoordinator.toggleRotationLock()
                viewModel.resumeAutoHide()
            }
            .accessibilityLabel(Text(orientationCoordinator.isRotationLocked
                ? LocalizedStringResource.playerOrientationUnlock
                : .playerOrientationLock))
            .accessibilityValue(Text(orientationCoordinator.isRotationLocked
                ? LocalizedStringResource.playerOrientationLocked
                : .playerOrientationUnlocked))
            .accessibilityHint(Text(orientationCoordinator.isRotationLocked
                ? LocalizedStringResource.playerOrientationUnlockHint
                : .playerOrientationLockHint))
            .accessibilityIdentifier("player.rotation-lock")
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
            parts.append(LocaleFormat.integer(year, locale: locale))
        }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " · ").uppercased()
    }

    private var heroTitle: String {
        let primary = viewModel.metadata.primaryTitle
        return primary.isEmpty ? viewModel.title : primary
    }

    // MARK: - Center

    /// Play/pause is the largest control, flanked by smaller skips — the
    /// same 64/52pt hierarchy and 48pt spacing as the Android phone player.
    private func centerCluster(playSize: CGFloat, skipSize: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Button {
                viewModel.skipBackward()
            } label: {
                Image(systemName: SeekIntervalLabel.symbolName(.backward, seconds: viewModel.skipIntervals.backward))
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: skipSize, height: skipSize)
            }
            .buttonStyle(MobilePlayerGlassButtonStyle(size: skipSize))
            .accessibilityLabel(SeekIntervalLabel.accessibilityLabel(.backward, seconds: viewModel.skipIntervals.backward))
            .disabled(!viewModel.canRequestSeek)

            // Still play/pause while it shows the spinner.
            Button {
                viewModel.togglePlayPause()
            } label: {
                Group {
                    if showsLoadingSpinner {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.black.opacity(0.85))
                            .scaleEffect(1.4)
                    } else {
                        Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.black.opacity(0.85))
                            // play.fill reads left-heavy inside a circle;
                            // nudge it toward the optical center.
                            .offset(x: viewModel.isPlaying ? 0 : 2)
                    }
                }
                .frame(width: playSize, height: playSize)
            }
            .buttonStyle(MobilePlayerGlassButtonStyle(tint: .white.opacity(0.9), size: playSize))
            .accessibilityLabel(Text(viewModel.isPlaying
                ? LocalizedStringResource.playerControlsPause
                : .playerControlsPlay))
            .accessibilityValue(showsLoadingSpinner ? Text(.commonLoading) : Text(verbatim: ""))
            .disabled(!viewModel.canRequestPlayPause)

            Button {
                viewModel.skipForward()
            } label: {
                Image(systemName: SeekIntervalLabel.symbolName(.forward, seconds: viewModel.skipIntervals.forward))
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: skipSize, height: skipSize)
            }
            .buttonStyle(MobilePlayerGlassButtonStyle(size: skipSize))
            .accessibilityLabel(SeekIntervalLabel.accessibilityLabel(.forward, seconds: viewModel.skipIntervals.forward))
            .disabled(!viewModel.canRequestSeek)
        }
        .mediaLayoutDirection()
    }

    static let playButtonSize: CGFloat = 64
    static let skipButtonSize: CGFloat = 52

    // MARK: - Bottom stack

    private var bottomStack: some View {
        VStack(spacing: 10) {
            timeline
            actionRow
                .opacity(recedingOpacity)
        }
    }

    private var timeline: some View {
        MobilePlayerTimeline(viewModel: viewModel, showsRemainingTime: $showsRemainingTime)
            .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: { timelineMinY = $0 }
            .onDisappear { timelineMinY = nil }
    }

    /// Bottom padding for a skip pill: clear of the timeline while the
    /// controls show, near the bottom edge when it floats alone.
    private func pillBottomPadding(in proxy: GeometryProxy) -> CGFloat {
        guard viewModel.showControls, let timelineMinY else { return 24 }
        // 20pt: the time labels' touch targets reach 16pt above the row.
        return max(24, proxy.frame(in: .global).maxY - timelineMinY + 20)
    }

    // MARK: - Action row

    private enum ActionRowStyle {
        case full      // labeled pills, value on the Quality pill
        case compact   // shorter labels
        case icons     // icon controls; Quality remains a pill
    }

    /// Labeled pill row. `ViewThatFits` tries the full labels first, then
    /// compact ones, then icon controls, so the row never truncates or wraps
    /// — an iPhone in portrait with chapters present lands on `.icons`.
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            actionRowContent(style: .full)
            actionRowContent(style: .compact)
            actionRowContent(style: .icons)
        }
        .frame(maxWidth: .infinity)
        // A track-less file on a server last seen without a provider leaves
        // the pill inert, so the sheet's own provider refresh cannot run.
        // Ask again each time the controls show, so a provider added
        // meanwhile makes search reachable.
        .onAppear {
            if trackPickerIsEmpty, viewModel.subtitleSearchVisible, !viewModel.subtitleSearchEnabled {
                viewModel.refreshSubtitleProviders()
            }
        }
    }

    /// The Audio & Subtitles picker would have nothing in it apart from
    /// subtitle search.
    private var trackPickerIsEmpty: Bool {
        viewModel.audioTracks.isEmpty
            && viewModel.subtitleTracks.isEmpty
            && !aiSubtitlesAvailable
    }

    private func actionRowContent(style: ActionRowStyle) -> some View {
        // The Audio & Subtitles pill is only inert when the picker would have
        // nothing at all in it. A track-less file can still offer subtitle
        // search when the server has a provider, so that entry point keeps
        // the sheet reachable.
        let noTracks = trackPickerIsEmpty && !viewModel.subtitleSearchEnabled
        return HStack(spacing: 8) {
            if viewModel.hasQualityChoice {
                qualityMenu(compact: style != .full)
            }

            trackSelectionButton(style: style)
                .disabled(noTracks)
                .opacity(noTracks ? 0.4 : 1)
                .accessibilityLabel(Text(.playerTracksTitle))

            if !viewModel.chapters.isEmpty {
                chaptersMenu(style: style)
                    .accessibilityLabel(Text(.optionsChapters))
            }

            controlButton(systemName: "ellipsis") {
                activeSheet = .settings
            }
            .accessibilityLabel(Text(.playerSettingsSheetTitle))
        }
    }

    /// Opens the quality sheet: every tier with its bitrate, scrolling, and
    /// clear of the transport.
    private func qualityMenu(compact: Bool) -> some View {
        Button {
            activeSheet = .quality
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
                    Text(.optionsQuality)
                        .font(.system(size: 12, weight: .semibold))
                    Text(qualityValueText)
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.8)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: SiloTheme.topBarIconHitSize)
        }
        .buttonStyle(MobilePlayerGlassButtonStyle(
            tint: viewModel.activeQualityId == ApplePlaybackQuality.autoId ? nil : Color.white.opacity(0.22)
        ))
        .accessibilityLabel(Text(.playerControlsPlaybackQuality))
        .accessibilityValue(qualityValueText)
    }

    /// Short value for the pill — the tier's resolution ("1080p") rather
    /// than the full "Up to 1080p HD (High)" menu label. A fixed saved
    /// resolution the menu has no row for still reads as that resolution.
    private var qualityValueText: String {
        if let active = viewModel.activeQualityOption {
            return active.isAuto || active.resolution.isEmpty
                ? AppLanguage.string(.optionsAuto, locale: locale)
                : active.resolution
        }
        return SiloQualityPresets.resolutionLabel(AppleQualityAxes.split(viewModel.activeQualityId).resolution)
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
                    title: style == .compact ? .playerTracksTitleShort : .playerTracksTitle
                ) {
                    activeSheet = .tracks
                }
            }
        }
    }

    // MARK: - Chapters menu

    /// Opens the chapter sheet, which starts scrolled to the chapter playing.
    private func chaptersMenu(style: ActionRowStyle) -> some View {
        Button {
            activeSheet = .chapters
        } label: {
            menuPillLabel(
                systemImage: "list.bullet",
                title: style == .icons ? nil : LocalizedStringResource.optionsChapters
            )
        }
        .buttonStyle(MobilePlayerGlassButtonStyle())
    }

    /// Menu label matching the `actionPill` (titled) / `controlButton`
    /// (icon circle) appearance so menus and buttons read as one family.
    @ViewBuilder
    private func menuPillLabel(systemImage: String, title: LocalizedStringResource?) -> some View {
        if let title {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: SiloTheme.topBarIconHitSize)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: SiloTheme.topBarIconHitSize, height: SiloTheme.topBarIconHitSize)
        }
    }

    private func actionPill(
        systemImage: String,
        title: LocalizedStringResource,
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
            .frame(height: SiloTheme.topBarIconHitSize)
        }
        .buttonStyle(MobilePlayerGlassButtonStyle())
    }

    // MARK: - Intro skip

    /// The intro-skip pill: "Skip Intro" for `ask`, and a small "Intro
    /// skipped" caption over "Watch Intro" for `always`'s undo. The same state
    /// machine and copy as the TV, web and Android pills, with pointer rules: a
    /// tap is Select, and a tap elsewhere is not a dismissal.
    @ViewBuilder
    private var introSkipPill: some View {
        if let pill = viewModel.introSkipPrompt.pill {
            GeometryReader { proxy in
                VStack(alignment: .trailing, spacing: 4) {
                    Spacer()
                    if let caption = pill.kind.caption {
                        Text(caption)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white.opacity(0.75))
                            .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                            .padding(.trailing, 12)
                            .accessibilityHidden(true)
                    }
                    Button {
                        viewModel.selectIntroSkipPrompt()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: pill.kind == .skip ? "forward.end.fill" : "arrow.counterclockwise")
                            Text(pill.kind.actionTitle)
                        }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .frame(height: SiloTheme.topBarIconHitSize)
                    }
                    .buttonStyle(MobilePlayerPillButtonStyle(pill: pill))
                    .accessibilityLabel(pill.kind.accessibilityLabel)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 24)
                // Clear the timeline while the controls are up; hug the bottom
                // edge when the pill is floating alone.
                .padding(.bottom, pillBottomPadding(in: proxy))
                .animation(.easeOut(duration: 0.2), value: viewModel.showControls)
            }
            .transition(.opacity)
        }
    }

    private var segmentSkipPill: some View {
        GeometryReader { proxy in
            VStack(alignment: .trailing, spacing: 10) {
                Spacer()
                // With the next episode named, the card carries the actions
                // (Play next episode, Not now), as on the TVs and Android;
                // otherwise the recap or credits skip stays a pill.
                Group {
                    if let upNext = viewModel.creditsNextEpisode {
                        MobileCreditsUpNextCard(viewModel: viewModel, episode: upNext)
                    } else {
                        HStack {
                            Spacer()
                            Button {
                                viewModel.skipCurrentSegment()
                            } label: {
                                Label(viewModel.segmentSkipLabel, systemImage: "forward.end.fill")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(.black.opacity(0.85))
                                    .padding(.horizontal, 16)
                                    .frame(height: SiloTheme.topBarIconHitSize)
                            }
                            .buttonStyle(MobilePlayerGlassButtonStyle(tint: .white.opacity(0.9)))
                            .accessibilityLabel(viewModel.segmentSkipLabel)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, pillBottomPadding(in: proxy))
            }
            .animation(.easeOut(duration: 0.2), value: viewModel.showControls)
        }
        .transition(.opacity)
    }

    // MARK: - Helpers

    private func controlButton(
        systemName: String, tint: Color? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: SiloTheme.topBarIconHitSize, height: SiloTheme.topBarIconHitSize)
        }
        .buttonStyle(MobilePlayerGlassButtonStyle(tint: tint))
    }

    // MARK: - Sheet identifier

    /// A full-height sheet covers the top of the player, where the buffering
    /// pill and notices show; the tracks sheet at half height does not. In
    /// a compact height every sheet is full height, and a sheet the tracks
    /// sheet opens can cover the player on its own.
    private var sheetCoversPlayer: Bool {
        guard let activeSheet else { return false }
        guard let detent = detentBinding(for: activeSheet) else { return true }
        return detent.wrappedValue == .large || verticalSizeClass == .compact
            || (activeSheet == .tracks && tracksNestedSheetCovers)
    }

    private enum PlayerSheet: Identifiable {
        case tracks, quality, chapters, settings
        var id: Self { self }
    }
}

/// Time row and scrubber. The only part of the controls that reads the
/// playback clock, so clock ticks re-render this view alone.
private struct MobilePlayerTimeline: View {
    let viewModel: PlayerViewModel
    @Binding var showsRemainingTime: Bool
    /// Set only while a finger drags the scrub bar. Skip buttons and
    /// hold-seek also set `isScrubbing`, but they shouldn't play chapter ticks
    /// or change scrub speed.
    @GestureState private var scrubDrag: MobileScrubDrag?
    @Environment(\.locale) private var locale

    /// Space between the scrub bubble's bottom edge and the top of the bar's
    /// 20pt touch strip, 4pt above the visible bar while scrubbing. The
    /// bubble grows upward from here when it adds a line.
    private static let scrubBubbleGap: CGFloat = 16
    /// Taller than the bubble ever gets; the bubble sits at its bottom.
    private static let scrubBubbleBoxHeight: CGFloat = 240

    var body: some View {
        VStack(spacing: 10) {
            timeRow
            progressSlider
        }
        .mediaLayoutDirection()
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
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
                    // A 44pt touch target around the small label; the
                    // negative padding below keeps the row's layout.
                    .frame(minWidth: 44, alignment: .trailing)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.vertical, -16)
            .accessibilityLabel(Text(showsRemainingTime
                ? LocalizedStringResource.playerProgressTimeRemaining
                : .playerProgressDuration))
            .accessibilityHint(Text(.playerProgressToggleTimeHint))
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
                    .updating($scrubDrag) { value, drag, _ in
                        guard width > 0 else { return }
                        var next = drag ?? MobileScrubDrag(startX: value.startLocation.x, width: width)
                        next.move(toX: value.location.x, heightAboveBar: -value.translation.height, width: width)
                        drag = next
                        if viewModel.isScrubbing {
                            viewModel.updateScrub(fraction: next.fraction)
                        } else {
                            viewModel.beginScrub(fraction: next.fraction)
                        }
                    }
                    .onEnded { _ in
                        viewModel.endScrub()
                    }
            )
            .scrubTickFeedback(
                tickTimes: viewModel.chapters.map(\.time),
                scrubTime: scrubDrag != nil ? viewModel.scrubPreviewTime : nil
            )
            .sensoryFeedback(trigger: scrubDrag?.speed) { old, new in
                old != nil && new != nil ? .impact(weight: .light) : nil
            }
            .overlay(alignment: .topLeading) {
                if viewModel.isScrubbing {
                    let previewInset: CGFloat = viewModel.scrubPreviewImage == nil ? 80 : 102
                    // Pin the bubble's bottom above the bar so a speed label
                    // grows it upward instead of over the bar.
                    scrubPreviewBubble
                        .frame(height: Self.scrubBubbleBoxHeight, alignment: .bottom)
                        .position(
                            x: min(
                                max(width * progress, previewInset),
                                max(width - previewInset, previewInset)
                            ),
                            y: -Self.scrubBubbleGap - Self.scrubBubbleBoxHeight / 2
                        )
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            // The custom scrubber is drag-only; expose it to VoiceOver as an
            // adjustable element that seeks through the same skip path.
            .accessibilityElement()
            .accessibilityLabel(Text(.playerProgressPlaybackPosition))
            .accessibilityValue(Text(.playerProgressPositionState(
                PlayerTimeFormatter.formatHMS(displayTime),
                PlayerTimeFormatter.formatHMS(viewModel.duration)
            )))
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: viewModel.skipForward()
                case .decrement: viewModel.skipBackward()
                @unknown default: break
                }
            }
        }
        .frame(height: 20)
    }

    private var bufferedFraction: Double? {
        guard viewModel.duration > 0, viewModel.bufferedAheadSeconds > 0 else { return nil }
        return viewModel.bufferedEndFraction
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
            if let speedLabel = scrubDrag?.speed.label {
                Text(speedLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(7)
        .siloPlayerGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .fixedSize()
    }

    private func chapterTitle(at time: Double) -> String? {
        guard let chapter = viewModel.chapters.last(where: { $0.time <= time }) else { return nil }
        return chapter.title
            ?? AppLanguage.string(.optionsChapterNumbered(LocaleFormat.integer(chapter.index + 1, locale: locale)), locale: locale)
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
}

/// The player pills' capsule, shared by the intro-skip and buffering-quality
/// pills: a dark scrim with the timer's fill creeping behind the label,
/// brighter while pressed. A button without a timer, such as **Keep quality**,
/// gets the same capsule with no fill.
struct MobilePlayerPillButtonStyle: ButtonStyle {
    let pill: (any PlayerTimedPill)?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: SiloTheme.topBarIconHitSize)
            .background {
                ZStack {
                    Capsule().fill(Color.black.opacity(0.65))
                    if let pill {
                        PlayerPillProgress(
                            pill: pill,
                            color: .white.opacity(configuration.isPressed ? 0.4 : 0.22)
                        )
                    } else if configuration.isPressed {
                        Capsule().fill(Color.white.opacity(0.22))
                    }
                }
                .clipShape(Capsule())
            }
            .overlay {
                Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
            }
            .contentShape(Capsule())
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

/// Match detail chrome without the extra padding added by native glass
/// button styles. A square label is circular; longer labels form a pill.
/// Chrome uses the 44pt default; the transport cluster passes larger sizes.
struct MobilePlayerGlassButtonStyle: ButtonStyle {
    var tint: Color? = nil
    var size: CGFloat = SiloTheme.topBarIconHitSize

    /// Untinted glass over a bright frame leaves white labels under 4.5:1;
    /// a little black in the glass keeps them legible on any picture.
    static let legibilityTint = Color.black.opacity(0.22)

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: size)
            .frame(height: size)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .contentShape(Capsule())
            .siloPlayerGlass(in: Capsule(), tint: tint ?? Self.legibilityTint, interactive: true)
    }
}

/// The standalone close button shown while loading, on Next Up and on
/// errors — when the full controls aren't mounted — follows the same
/// tap/auto-hide state as the controls.
struct MobilePlayerChromeVisibility: ViewModifier {
    /// Room the Next Up layout leaves above itself for the close button.
    static let topClearance: CGFloat = SiloTheme.topBarIconHitSize + 32

    let isVisible: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
            .animation(.easeOut(duration: 0.18), value: isVisible)
    }
}
/// "Up next" during the credits: the episode that follows, when it starts,
/// "Play next episode" to start it now and "Not now" to stop it starting by
/// itself this time. Its own view, so the countdown's clock ticks re-render the card
/// alone.
private struct MobileCreditsUpNextCard: View {
    let viewModel: PlayerViewModel
    let episode: PlayerNextUpEpisode
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(.upNextHeading)
                    .textCase(.uppercase)
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.72))
                Text(verbatim: episodeLine)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                if let timingText {
                    timingText
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            // The card's actions: play the named episode now (lit), or not
            // now (quiet).
            HStack(spacing: 8) {
                Button {
                    viewModel.selectSegmentAction()
                } label: {
                    Text(viewModel.segmentActionLabel)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(Color.white))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                // Stops this episode starting the next by itself and puts the
                // card away; the auto-play setting is untouched.
                Button {
                    viewModel.declineCreditsAutoPlay()
                } label: {
                    Text(.markerCreditsCardNotNow)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(Color.white.opacity(0.1)))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.3), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 360, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.86))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
    }

    /// "S2 · E5 · Title": the code from the catalog, the title as the
    /// server wrote it.
    private var episodeLine: String {
        let code = AppLanguage.string(
            .catalogEpisodeCaption(LocaleFormat.codeNumber(episode.seasonNumber), LocaleFormat.codeNumber(episode.episodeNumber)),
            locale: locale
        )
        return "\(code) · \(AppLanguage.isolated(episode.title))"
    }

    /// When the credits end, the time in bold, and what follows. One catalog
    /// message with the time restyled in place, so translations can reorder it.
    /// Nil when auto-play is on but stood down for this episode (Keep
    /// Watching): neither line would be true then.
    private var timingText: Text? {
        let remaining = PlayerTimeFormatter.formatHMS(viewModel.creditsRemainingSeconds, locale: locale)
        let message: LocalizedStringResource
        if viewModel.nextUpAutoPlayArmed {
            message = .upNextCreditsEndThenPlays(remaining)
        } else if !viewModel.settings.autoPlayNextEpisode {
            message = .upNextCreditsEndAutoPlayOff(remaining)
        } else {
            return nil
        }
        var line = AttributedString(AppLanguage.string(message, locale: locale))
        if let range = line.range(of: remaining) {
            line[range].inlinePresentationIntent = .stronglyEmphasized
            line[range].foregroundColor = .white
        }
        return Text(line)
    }
}
#endif
