#if os(tvOS)
import CoreGraphics
import SwiftUI

enum TVPlayerTimeDisplayMode: Equatable {
    case elapsedRemaining
    case currentAndFinish

    mutating func toggle() {
        self = self == .elapsedRemaining ? .currentAndFinish : .elapsedRemaining
    }
}

/// tvOS player overlay. The idle state is minimal: no hero strip, a thin
/// scrubber, and an icon-only transport row along the bottom.
/// When the user opens the options panel, the idle overlay steps aside and
/// `TVPlayerInfoHUD` takes over as a floating top-center HUD (Infuse idiom).
/// Controls auto-hide after 5 s of no focus movement while playing; Menu
/// either hides the HUD, dismisses the overlay, or exits the player
/// depending on what's on screen.
struct TVPlayerControls: View {
    fileprivate static let transportHorizontalInset: CGFloat = 80
    fileprivate static let scrubPreviewCardWidth: CGFloat = 340
    fileprivate static let scrubPreviewBottomInset: CGFloat = 300

    let viewModel: PlayerViewModel
    let showsTimelinePreview: Bool
    let timeDisplayMode: TVPlayerTimeDisplayMode
    let timelineSelectionRequest: UUID?
    let onToggleTimeDisplayMode: () -> Void
    let onDismiss: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    /// Remembered so reopening the HUD lands on the last-used tab rather
    /// than always snapping back to Info. Lives at this level because the
    /// HUD view is recreated each time HUD presentation toggles.
    @State private var activeHUDTab: TVPlayerInfoHUD.Tab = .info

    /// Flipped on immediately *before* the HUD appears so the scrubber's
    /// focus-lost path treats the resulting blur as a cancel rather than a
    /// commit. Without this, opening the HUD with an in-flight scrub preview
    /// would seek to that preview as a side-effect.
    @State private var cancelPendingScrub: Bool = false
    /// Mirrors the scrubber's explicit timeline-scrub mode (Select on the
    /// puck). Held here so the transport cluster can leave the focus graph
    /// while the scrub is modal.
    @State private var isTimelineScrubbing: Bool = false
    /// Tracks whether the current explicit timeline session interrupted
    /// active playback. Exiting a timeline opened from an already-paused
    /// HUD must leave playback paused, while Select from playing resumes.
    @State private var resumePlaybackAfterTimelineSelection = false
    /// True while the scrubber owns focus. The transport row leaves the
    /// focus graph for that duration so a Down press has no native target:
    /// the engine otherwise moves focus geometrically — to whichever button
    /// happens to sit under the playhead — *before* the scrubber's
    /// `onMoveCommand` fires, and the play/pause seed then reads as a
    /// visible hop off the wrong button. Released on the Down hand-off (so
    /// the seed has a focusable target) and whenever the scrubber blurs for
    /// any other reason (intro skip, HUD) so direction moves into the row
    /// keep working from elsewhere.
    @State private var trapsTransportFocus = false
    /// A touch-surface contact can toggle the full HUD's clock labels only
    /// if it ends as a light touch. Select and drag interactions clear this
    /// candidate so their existing transport behavior remains exclusive.
    @State private var fullHUDContactCanToggle = false

    // Focus states. SwiftUI's focus engine only holds focus on one
    // focusable at a time, so selecting one of these implicitly clears the
    // others. The HUD tab focus lives here (rather than inside
    // `TVPlayerInfoHUD`) so we can explicitly seed it at open time — without
    // a deterministic initial focus target the HUD can appear with nothing
    // focused, which leaves the Menu button with no exit handler to bubble
    // to and the user stranded inside the panel.
    @FocusState private var isScrubberFocused: Bool
    @FocusState private var focusedTransportButton: TVPlayerTransportCluster.FocusTarget?
    @FocusState private var focusedHUDTab: TVPlayerInfoHUD.Tab?
    @FocusState private var isIntroSkipFocused: Bool
    @FocusState private var isSegmentSkipFocused: Bool

    private var isHUDPresented: Bool { viewModel.isHUDPresented }

    var body: some View {
        ZStack {
            if showsTimelinePreview && !viewModel.showControls && !isHUDPresented {
                timelinePreviewOverlay
                    .transition(.opacity)
            }
            // Idle overlay and HUD are mutually exclusive. Stacking both
            // confused the focus engine (scrubber clicks bleeding into
            // hidden transport buttons) and added visual noise from the
            // progress bar showing underneath the panel.
            if viewModel.showControls && !isHUDPresented {
                idleOverlay
                    .transition(.opacity)
            }
            introSkipLayer
                .transition(.opacity)
            if viewModel.showSegmentSkip {
                segmentSkipLayer
                    .transition(.opacity)
            }
            if isHUDPresented {
                TVPlayerInfoHUD(
                    viewModel: viewModel,
                    activeTab: $activeHUDTab,
                    focusedTab: $focusedHUDTab,
                    onDismiss: { closeHUD() }
                )
                .transition(.opacity)
            }
        }
        .background {
            TVTouchSurfaceContactGestureView(
                // Keep the raw contact observer active in both normal HUD
                // and timeline-selection states. Its simultaneous-recognition
                // delegate lets an actual pan continue to own scrubbing.
                isActive: viewModel.showControls && !isHUDPresented,
                onContactBegan: {
                    fullHUDContactCanToggle = true
                },
                onContactEnded: {
                    guard fullHUDContactCanToggle else { return }
                    fullHUDContactCanToggle = false
                    onToggleTimeDisplayMode()
                },
                onContactCancelled: {
                    fullHUDContactCanToggle = false
                },
                onDirectionalPressBegan: {
                    fullHUDContactCanToggle = false
                }
            )
            .frame(width: 1, height: 1)
        }
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: isHUDPresented)
        .animation(.easeOut(duration: 0.2), value: viewModel.showIntroSkip)
        // Menu / exit handling intentionally lives at the `PlayerView` level
        // rather than here. That higher handler reads `viewModel.isHUDPresented`
        // directly so it catches Menu presses even when focus has drifted off
        // the HUD's tab pill — adding a handler here would consume Menu while
        // the HUD is closed and break the "dismiss controls first" path.
        .onChange(of: isHUDPresented) { _, presented in
            fullHUDContactCanToggle = false
            if !presented {
                cancelPendingScrub = false
                focusedHUDTab = nil
                focusedTransportButton = nil
                isScrubberFocused = true
            }
        }
        .onChange(of: viewModel.showIntroSkip) { _, visible in
            if visible {
                // The pill takes focus as it appears, except from a viewer who
                // is mid-interaction: the HUD's focus graph, or a timeline
                // scrub, which commits its seek when it loses focus. The pill
                // still shows and its timer still runs; it stays reachable by
                // direction.
                // With the controls hidden the press capture owns focus and
                // already routes Select to the pill.
                if viewModel.showControls && !isHUDPresented &&
                    !isTimelineScrubbing && !viewModel.isScrubbing {
                    isIntroSkipFocused = true
                }
            } else {
                isIntroSkipFocused = false
                // Hand focus back to the transport when the pill disappears
                // while controls are still up, instead of leaving nothing
                // focused. A viewer who already moved onto the transport keeps
                // their place.
                if viewModel.showControls && !isHUDPresented &&
                    focusedTransportButton == nil && !isScrubberFocused {
                    isScrubberFocused = true
                }
            }
        }
        .onChange(of: viewModel.showSegmentSkip) { _, visible in
            if visible {
                // Like the intro pill, never take focus from an active scrub:
                // losing focus cancels the scrub preview.
                if !isHUDPresented && !isTimelineScrubbing && !viewModel.isScrubbing {
                    isSegmentSkipFocused = true
                }
            } else {
                isSegmentSkipFocused = false
                // A recap ends where the intro pill often appears. Keep the
                // viewer on the intro pill or a transport button they moved to.
                if viewModel.showControls && !isHUDPresented &&
                    focusedTransportButton == nil && !isIntroSkipFocused {
                    isScrubberFocused = true
                }
            }
        }
        .onChange(of: viewModel.requestedTVHUDEntryPoint) { _, entryPoint in
            guard let entryPoint else { return }
            applyHUDEntryPoint(entryPoint)
            viewModel.consumeTVHUDEntryRequest()
        }
        .onChange(of: timelineSelectionRequest) { _, request in
            guard request != nil else { return }
            fullHUDContactCanToggle = false
            // PlayerView only issues this request from its playing Select
            // path, immediately after pausing the backend.
            resumePlaybackAfterTimelineSelection = true
            enterTimelineSelection()
        }
        .onChange(of: viewModel.showControls) { _, _ in
            fullHUDContactCanToggle = false
        }
        // Re-arm the auto-hide whenever focus moves between transport controls,
        // so navigating the overlay doesn't let the fixed 5s timer hide it (and
        // the user's focus) out from under them mid-interaction.
        .onChange(of: isScrubberFocused) { _, focused in
            if focused { rearmAutoHideOnFocusMove() }
            trapsTransportFocus = focused
        }
        .onChange(of: focusedTransportButton) { _, target in
            if target != nil { rearmAutoHideOnFocusMove() }
        }
        // TV sleep discards the app's focus state, and the background-suspend
        // path keeps `showControls` true — so on wake the idle overlay is
        // already mounted, its `onAppear` seed never re-fires, and nothing is
        // focused. With no focused descendant, Menu presses never reach the
        // shell-level `onExitCommand` in PlayerView, stranding the user until
        // they d-pad onto the transport row. Re-seed a deterministic focus
        // target when the scene becomes active again.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            // Defer one turn so the write lands after the focus engine has
            // reattached to the foregrounded scene; a same-transaction claim
            // can get dropped.
            DispatchQueue.main.async {
                reseedFocusAfterWake()
            }
        }
    }

    private func reseedFocusAfterWake() {
        if isHUDPresented {
            if focusedHUDTab == nil { focusedHUDTab = activeHUDTab }
        } else if viewModel.showControls {
            // The skip pills are disabled during a timeline scrub, so a claim
            // on them would land nowhere; the scrubber owns focus then.
            if viewModel.showIntroSkip && !isTimelineScrubbing && !isIntroSkipFocused {
                isIntroSkipFocused = true
            } else if viewModel.showSegmentSkip && !isTimelineScrubbing && !isSegmentSkipFocused {
                isSegmentSkipFocused = true
            } else if focusedTransportButton == nil && !isScrubberFocused {
                isScrubberFocused = true
            }
        }
    }

    private func rearmAutoHideOnFocusMove() {
        guard viewModel.showControls, !isHUDPresented else { return }
        viewModel.revealControls()
    }

    // MARK: - Idle overlay

    private var timelinePreviewOverlay: some View {
        ZStack(alignment: .bottom) {
            bottomGradient.ignoresSafeArea()
            VStack(spacing: 10) {
                TVPassiveTimelineBar(viewModel: viewModel)
                TVPlayerTimeRow(viewModel: viewModel, mode: timeDisplayMode)
            }
            .padding(.horizontal, Self.transportHorizontalInset)
            .padding(.bottom, 48)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var idleOverlay: some View {
        ZStack(alignment: .bottom) {
            bottomGradient.ignoresSafeArea()
            statusColumn
                .padding(.top, viewModel.isBuffering ? 120 : 64)
                .padding(.horizontal, 80)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            TVScrubPreviewLayer(viewModel: viewModel)
            transportStack
                .padding(.horizontal, Self.transportHorizontalInset)
                .padding(.bottom, 48)
        }
        .onAppear {
            focusedTransportButton = nil
            // When the intro-skip pill is showing, let it own first focus
            // instead of racing this scrubber seed — otherwise revealing the
            // controls while it is up lands focus nondeterministically on the
            // scrubber or the pill. A timeline selection that revealed the
            // controls keeps the scrubber: the pills are disabled mid-scrub.
            if isTimelineScrubbing {
                isScrubberFocused = true
            } else if viewModel.showIntroSkip {
                isScrubberFocused = false
                isIntroSkipFocused = true
            } else if viewModel.showSegmentSkip {
                isScrubberFocused = false
                isSegmentSkipFocused = true
            } else {
                isScrubberFocused = true
            }
        }
    }

    /// Subtle bottom gradient so the transport has contrast against bright
    /// frames. Kept shallow because the scrubber and icon buttons carry their
    /// own outlines.
    private var bottomGradient: some View {
        VStack(spacing: 0) {
            Spacer()
            LinearGradient(
                colors: [.clear, .black.opacity(0.55)],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 240)
        }
    }

    /// The sleep-timer chip floats in the top-right when active. Buffering is
    /// owned by the player shell so it remains visible outside this overlay.
    private var statusColumn: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if viewModel.sleepTimer.isActive {
                Label(PlayerTimeFormatter.formatCountdown(viewModel.sleepTimer.remainingSeconds),
                      systemImage: "moon.zzz.fill")
                    .font(.siloSmall.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .siloPlayerGlass(in: Capsule())
            }
        }
    }

    /// Lower right, above the transport while the controls are up and closer
    /// to the corner when they hide. Fades in, and fades out when its timer
    /// runs out; Select and Menu take it down instantly (see
    /// `PlayerViewModel.selectIntroSkipPrompt`).
    ///
    /// One focus owner at a time (docs/tvos-focus.md). With the controls
    /// hidden, the shell's press capture owns the remote and routes Select to
    /// the pill, so the pill is not focusable and is drawn lit as the Select
    /// target. With the controls up it is an ordinary button in the native
    /// focus graph, and Down moves on to the transport while its timer runs.
    @ViewBuilder
    private var introSkipLayer: some View {
        if let pill = viewModel.introSkipPrompt.pill {
            TVIntroSkipPill(
                pill: pill,
                isSelectTarget: !viewModel.showControls && !isHUDPresented
            ) {
                viewModel.selectIntroSkipPrompt()
            }
            // Out of the focus graph during a timeline scrub, like the
            // transport row: a drag that drifts upward would otherwise land
            // here and cancel the scrub.
            .disabled(!viewModel.showControls || isTimelineScrubbing)
            .focused($isIntroSkipFocused)
            // Its own focus region, sized to the pill: a section spanning the
            // screen would hold Down inside it instead of handing focus to the
            // transport below.
            .focusSection()
            .padding(.horizontal, 80)
            // Clears the whole transport stack — title, scrubber, time row and
            // buttons — while it shows, so the pill never covers the end of
            // the timeline or the remaining-time label.
            .padding(.bottom, viewModel.showControls && !isHUDPresented ? 400 : 96)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .animation(.easeOut(duration: 0.22), value: viewModel.showControls)
        }
    }

    private var segmentSkipLayer: some View {
        Button {
            viewModel.skipCurrentSegment()
        } label: {
            Label(viewModel.segmentSkipLabel, systemImage: "forward.end.fill")
                .font(.system(size: 26, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 220)
        }
        .buttonStyle(TVPillButtonStyle(kind: .primary, focusTreatment: .compact))
        .disabled(isTimelineScrubbing)
        .focused($isSegmentSkipFocused)
        .accessibilityLabel(viewModel.segmentSkipLabel)
        .padding(.horizontal, 80)
        .padding(.bottom, viewModel.showControls && !isHUDPresented ? 156 : 96)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .focusSection()
    }

    // MARK: - Transport stack

    private var transportStack: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleFooter
            TVPlayerScrubber(
                viewModel: viewModel,
                isFocused: $isScrubberFocused,
                onSelectInteraction: {
                    fullHUDContactCanToggle = false
                },
                onMoveToTransport: {
                    // This fires only because the trap kept the transport row
                    // out of the focus graph (no native Down target). Restore
                    // the row first, then seed play/pause on the next turn —
                    // a claim in the same transaction as the structural
                    // re-enable gets dropped by the engine. Focus stays on
                    // the scrubber for that frame, so there is no visible
                    // intermediate stop.
                    trapsTransportFocus = false
                    DispatchQueue.main.async {
                        focusedTransportButton = .playPause
                    }
                },
                onExitWhenIdle: {
                    // The intro pill is the most transient thing on screen, so
                    // Menu takes it down first and the press ends there.
                    if viewModel.dismissIntroSkipPrompt() { return }
                    // While paused, Menu exits the player instead of hiding
                    // the controls over a frozen frame.
                    if viewModel.isPlaying {
                        viewModel.dismissControls()
                    } else {
                        onDismiss()
                    }
                },
                isTimelineScrubbing: $isTimelineScrubbing,
                resumePlaybackAfterTimelineSelection: $resumePlaybackAfterTimelineSelection,
                cancelOnBlur: cancelPendingScrub
            )
            TVPlayerTimeRow(viewModel: viewModel, mode: timeDisplayMode)
            TVPlayerTransportCluster(
                viewModel: viewModel,
                onOpenHUD: { openHUD() },
                onMoveToScrubber: {
                    // Same single-write rule as onMoveToTransport: nulling the
                    // transport focus first invites a geometric repair hop.
                    isScrubberFocused = true
                },
                onDismiss: onDismiss,
                // Timeline scrub is modal, and a focused scrubber traps Down:
                // with the transport buttons out of the focus graph, a Down
                // press/swipe has no native target below the scrubber, so the
                // hand-off goes through onMoveToTransport instead of the
                // engine's geometric pick.
                allowsFocus: !isTimelineScrubbing && !trapsTransportFocus,
                focusedButton: $focusedTransportButton
            )
        }
    }

    /// Quiet title footer above the scrubber — the VidHub idiom of surfacing
    /// the currently-playing title as bottom-left caption rather than a hero
    /// slab. Hidden while we still have no title resolved.
    @ViewBuilder
    private var titleFooter: some View {
        let title = heroTitleText
        if !title.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if let series = viewModel.metadata.seriesTitle, !series.isEmpty {
                    Text(series)
                        .font(.siloSmall.weight(.medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    Text(title)
                        .font(.siloHeadline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let episode = viewModel.metadata.episodeTag {
                        Text(episode)
                            .font(.siloSmall)
                            .foregroundStyle(.white.opacity(0.6))
                    }
                }
            }
            .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
        }
    }

    private var heroTitleText: String {
        viewModel.metadata.primaryTitle.isEmpty
            ? viewModel.title
            : viewModel.metadata.primaryTitle
    }

    // MARK: - HUD open/close

    private func enterTimelineSelection() {
        cancelPendingScrub = false
        focusedHUDTab = nil
        focusedTransportButton = nil
        isIntroSkipFocused = false
        viewModel.pinControlsVisible()

        guard viewModel.duration > 0 else {
            isTimelineScrubbing = false
            resumePlaybackAfterTimelineSelection = false
            isScrubberFocused = true
            return
        }

        let fraction = min(max(viewModel.currentTime / viewModel.duration, 0), 1)
        viewModel.beginScrub(fraction: fraction)
        isTimelineScrubbing = true
        isScrubberFocused = true
    }

    /// Open the Infuse-style HUD. Side-effects land in this order so focus
    /// transitions cleanly:
    ///   1. Flip `cancelPendingScrub` so the scrubber treats the imminent
    ///      blur as a cancel rather than a commit.
    ///   2. Drop the idle overlay's focus bindings so SwiftUI isn't trying
    ///      to hold focus on a view that's about to leave the hierarchy.
    ///   3. Seed `focusedHUDTab` so the HUD opens with a deterministic
    ///      focus target — otherwise focus can land nowhere and the Menu
    ///      button has no exit handler to bubble to.
    ///   4. Present the HUD via the view model (single source of truth).
    private func openHUD() {
        cancelPendingScrub = true
        isScrubberFocused = false
        focusedTransportButton = nil
        focusedHUDTab = activeHUDTab
        viewModel.openHUD()
    }

    private func applyHUDEntryPoint(_ entryPoint: PlayerViewModel.TVHUDEntryPoint) {
        cancelPendingScrub = true
        isScrubberFocused = false
        focusedTransportButton = nil
        switch entryPoint {
        case .settings:
            activeHUDTab = .video
        }
        focusedHUDTab = activeHUDTab
    }

    private func closeHUD() {
        viewModel.closeHUD()
    }
}

private extension PlayerViewModel {
    /// The scrub preview while scrubbing, otherwise the playhead.
    var timelineDisplayTime: Double {
        isScrubbing ? scrubPreviewTime : currentTime
    }

    var timelineProgressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(max(timelineDisplayTime / duration, 0), 1)
    }
}

/// Elapsed/remaining or clock/finish-time row. It reads the playback clock,
/// so clock ticks re-render this view rather than the whole overlay.
private struct TVPlayerTimeRow: View {
    let viewModel: PlayerViewModel
    let mode: TVPlayerTimeDisplayMode

    var body: some View {
        if mode == .currentAndFinish {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack {
                    clockText(formatClockTime(context.date))
                    Spacer()
                    if viewModel.duration > 0 {
                        clockText(formatClockTime(estimatedFinishDate(from: context.date)))
                    }
                }
            }
        } else {
            HStack {
                clockText(PlayerTimeFormatter.formatHMS(viewModel.timelineDisplayTime))
                Spacer()
                if viewModel.duration > 0 {
                    clockText("−\(PlayerTimeFormatter.formatHMS(remainingTime))")
                }
            }
        }
    }

    private func clockText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 28, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .monospacedDigit()
    }

    private var remainingTime: Double {
        max(0, viewModel.duration - viewModel.timelineDisplayTime)
    }

    private func estimatedFinishDate(from now: Date) -> Date {
        let speed = max(viewModel.effectivePlaybackSpeed, 0.1)
        return now.addingTimeInterval(remainingTime / speed)
    }

    private func formatClockTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// Non-interactive progress bar shown while the controls are hidden.
private struct TVPassiveTimelineBar: View {
    let viewModel: PlayerViewModel

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let progress = viewModel.timelineProgressFraction
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(0.24))
                    .frame(height: 7)

                let bufferedAhead = max(0, viewModel.bufferedEndFraction - progress)
                if bufferedAhead > 0 {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.28))
                        .frame(width: width * bufferedAhead, height: 7)
                        .offset(x: width * progress)
                }

                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: width * progress, height: 7)
            }
            .frame(height: 20, alignment: .center)
        }
        .frame(height: 20)
    }
}

/// Still preview card that follows the scrubber puck while scrubbing.
private struct TVScrubPreviewLayer: View {
    private typealias Layout = TVPlayerControls

    let viewModel: PlayerViewModel

    var body: some View {
        if viewModel.isScrubbing, let image = viewModel.scrubPreviewImage {
            GeometryReader { proxy in
                scrubPreviewCard(image)
                    .frame(width: Layout.scrubPreviewCardWidth)
                    .padding(.leading, scrubPreviewLeadingInset(in: proxy.size.width))
                    .padding(.bottom, Layout.scrubPreviewBottomInset)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottomLeading
                    )
            }
            .transition(.opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    private func scrubPreviewCard(_ image: CGImage) -> some View {
        VStack(spacing: 8) {
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 320, height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            Text(PlayerTimeFormatter.formatHMS(viewModel.scrubPreviewTime))
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
        }
        .padding(10)
        .siloPlayerGlass(
            in: RoundedRectangle(cornerRadius: 20, style: .continuous),
            tint: Color.black.opacity(0.28)
        )
        .shadow(color: .black.opacity(0.5), radius: 18, y: 7)
    }

    /// Aligns the preview with the scrubber puck while keeping the complete
    /// card inside the same horizontal bounds as the transport timeline.
    private func scrubPreviewLeadingInset(in containerWidth: CGFloat) -> CGFloat {
        let trackWidth = max(containerWidth - (Layout.transportHorizontalInset * 2), 0)
        let playheadCenter = Layout.transportHorizontalInset
            + (trackWidth * CGFloat(viewModel.timelineProgressFraction))
        let minimumLeading = Layout.transportHorizontalInset
        let maximumLeading = containerWidth
            - Layout.transportHorizontalInset
            - Layout.scrubPreviewCardWidth
        return min(
            max(playheadCenter - (Layout.scrubPreviewCardWidth / 2), minimumLeading),
            maximumLeading
        )
    }
}
#endif
