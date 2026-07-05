#if os(tvOS)
import SwiftUI

/// tvOS player overlay. Post-redesign the idle state is VidHub-minimal:
/// no hero strip, thin scrubber, icon-only transport row along the bottom.
/// When the user opens the options panel, the idle overlay steps aside and
/// `TVPlayerInfoHUD` takes over as a floating top-center HUD (Infuse idiom).
/// Controls auto-hide after 5 s of no focus movement while playing; Menu
/// either hides the HUD, dismisses the overlay, or exits the player
/// depending on what's on screen.
struct TVPlayerControls: View {
    let viewModel: PlayerViewModel
    let onDismiss: () -> Void

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
    @FocusState private var focusedIntroAction: IntroAction?

    private var isHUDPresented: Bool { viewModel.isHUDPresented }

    var body: some View {
        ZStack {
            // Idle overlay and HUD are mutually exclusive. Stacking both
            // confused the focus engine (scrubber clicks bleeding into
            // hidden transport buttons) and added visual noise from the
            // progress bar showing underneath the panel.
            if viewModel.showControls && !isHUDPresented {
                idleOverlay
                    .transition(.opacity)
            }
            if viewModel.showIntroSkip {
                introSkipLayer
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
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isHUDPresented)
        // Menu / exit handling intentionally lives at the `PlayerView` level
        // rather than here. That higher handler reads `viewModel.isHUDPresented`
        // directly so it catches Menu presses even when focus has drifted off
        // the HUD's tab pill — adding a handler here would consume Menu while
        // the HUD is closed and break the "dismiss controls first" path.
        .onChange(of: isHUDPresented) { _, presented in
            if !presented {
                cancelPendingScrub = false
                focusedHUDTab = nil
                focusedTransportButton = nil
                isScrubberFocused = true
            }
        }
        .onChange(of: viewModel.showIntroSkip) { _, visible in
            if visible {
                // The skip layer renders beneath the HUD, so claiming focus
                // here while the HUD is up would yank the user out of it
                // mid-navigation. The HUD-dismiss handler above re-seeds
                // transport focus, and Skip stays reachable by direction.
                if !isHUDPresented {
                    focusedIntroAction = .skip
                }
            } else {
                focusedIntroAction = nil
                // Hand focus back to the transport when the Skip button
                // disappears while controls are still up, instead of leaving
                // nothing focused.
                if viewModel.showControls && !isHUDPresented {
                    isScrubberFocused = true
                }
            }
        }
        .onChange(of: viewModel.requestedTVHUDEntryPoint) { _, entryPoint in
            guard let entryPoint else { return }
            applyHUDEntryPoint(entryPoint)
            viewModel.consumeTVHUDEntryRequest()
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
    }

    private func rearmAutoHideOnFocusMove() {
        guard viewModel.showControls, !isHUDPresented else { return }
        viewModel.revealControls()
    }

    // MARK: - Idle overlay

    @ViewBuilder
    private var idleOverlay: some View {
        ZStack(alignment: .bottom) {
            bottomGradient.ignoresSafeArea()
            statusColumn
                .padding(.top, 64)
                .padding(.horizontal, 80)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            transportStack
                .padding(.horizontal, 80)
                .padding(.bottom, 48)
        }
        .onAppear {
            focusedTransportButton = nil
            // When the intro-skip button is showing, let it own first focus
            // instead of racing this scrubber seed — otherwise revealing the
            // controls during the intro window lands focus nondeterministically
            // on the scrubber or the Skip button.
            if viewModel.showIntroSkip {
                isScrubberFocused = false
                focusedIntroAction = .skip
            } else {
                isScrubberFocused = true
            }
        }
    }

    /// Subtle bottom gradient so the transport has contrast against bright
    /// frames. Shallower than pre-redesign (340pt → 240pt) since the scrubber
    /// and icon buttons now carry their own outlines and need less backdrop.
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

    /// Buffering + sleep-timer chips float in the top-right when active.
    /// Everything else that used to live in the hero strip (title, series,
    /// badges, year, runtime, chapter) is now in the HUD's Info tab.
    private var statusColumn: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if viewModel.isBuffering {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(.white)
                        .progressViewStyle(.circular)
                        .scaleEffect(0.9)
                    Text("Buffering")
                        .font(.continuumSmall.weight(.medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .siloPlayerGlass(in: Capsule())
            }

            if viewModel.sleepTimer.isActive {
                Label(formatCountdown(viewModel.sleepTimer.remainingSeconds),
                      systemImage: "moon.zzz.fill")
                    .font(.continuumSmall.weight(.medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .siloPlayerGlass(in: Capsule())
            }
        }
    }

    private var introSkipLayer: some View {
        introSkipButton
            .padding(.horizontal, 80)
            .padding(.bottom, viewModel.showControls && !isHUDPresented ? 156 : 96)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            // Group Skip + Cancel as their own focus region so the engine can
            // move between them and the transport row below by direction.
            .focusSection()
    }

    private var introSkipButton: some View {
        VStack(alignment: .trailing, spacing: 16) {
            if let countdown = viewModel.introAutoSkipCountdownSeconds {
                markerCountdownBadge(countdown)
            }

            HStack(spacing: 18) {
                if viewModel.introAutoSkipCountdownSeconds != nil {
                    Button {
                        viewModel.cancelIntroAutoSkip()
                    } label: {
                        Label("Cancel", systemImage: "xmark")
                            .font(.system(size: 24, weight: .semibold))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 136)
                    }
                    .buttonStyle(TVPillButtonStyle(kind: .secondary, focusTreatment: .compact))
                    .focused($focusedIntroAction, equals: .cancel)
                    .accessibilityLabel("Cancel Auto-Skip Intro")
                }

                skipIntroNowButton
            }
        }
    }

    private var skipIntroNowButton: some View {
        Button {
            viewModel.skipIntro()
        } label: {
            Label(
                viewModel.introAutoSkipCountdownSeconds == nil ? "Skip Intro" : "Skip Now",
                systemImage: "forward.end.fill"
            )
                .font(.system(size: 26, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: 196)
        }
        .buttonStyle(TVPillButtonStyle(kind: .primary, focusTreatment: .compact))
        .focused($focusedIntroAction, equals: .skip)
        .accessibilityLabel(
            viewModel.introAutoSkipCountdownSeconds == nil ? "Skip Intro" : "Skip Intro Now"
        )
    }

    private func markerCountdownBadge(_ countdown: Int) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles.tv")
                .font(.system(size: 19, weight: .semibold))
            Text("Intro")
                .font(.system(size: 17, weight: .bold))
                .textCase(.uppercase)
                .tracking(1.0)
                .foregroundStyle(.white.opacity(0.62))
            Text("Skipping in \(countdown)")
                .font(.system(size: 22, weight: .semibold))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: ContinuumTheme.smallCornerRadius, style: .continuous)
                .fill(Color.black.opacity(0.46))
        )
        .overlay(
            RoundedRectangle(cornerRadius: ContinuumTheme.smallCornerRadius, style: .continuous)
                .stroke(Color.white.opacity(0.24), lineWidth: 1.2)
        )
        .shadow(color: .black.opacity(0.32), radius: 10, y: 4)
    }

    private enum IntroAction: Hashable {
        case cancel
        case skip
    }

    // MARK: - Transport stack

    private var transportStack: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleFooter
            TVPlayerScrubber(
                viewModel: viewModel,
                isFocused: $isScrubberFocused,
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
                    viewModel.dismissControls()
                },
                isTimelineScrubbing: $isTimelineScrubbing,
                cancelOnBlur: cancelPendingScrub
            )
            timeRow
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
                        .font(.continuumSmall.weight(.medium))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                HStack(spacing: 10) {
                    Text(title)
                        .font(.continuumHeadline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if let episode = viewModel.metadata.episodeTag {
                        Text(episode)
                            .font(.continuumSmall)
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

    private var timeRow: some View {
        HStack {
            Text(formatTime(scrubberDisplayTime))
                .font(.system(size: 28, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
            Spacer()
            if viewModel.duration > 0 {
                Text("−\(formatTime(remainingTime))")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .monospacedDigit()
            }
        }
    }

    private var scrubberDisplayTime: Double {
        viewModel.isScrubbing ? viewModel.scrubPreviewTime : viewModel.currentTime
    }

    private var remainingTime: Double {
        max(0, viewModel.duration - scrubberDisplayTime)
    }

    // MARK: - HUD open/close

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

    private func openSettingsHUD() {
        applyHUDEntryPoint(.settings)
        viewModel.openSettingsHUD()
    }

    private func openPlaybackHUD() {
        applyHUDEntryPoint(.playback)
        viewModel.openPlaybackHUD()
    }

    private func applyHUDEntryPoint(_ entryPoint: PlayerViewModel.TVHUDEntryPoint) {
        cancelPendingScrub = true
        isScrubberFocused = false
        focusedTransportButton = nil
        switch entryPoint {
        case .settings:
            activeHUDTab = .video
        case .playback:
            activeHUDTab = preferredPlaybackHUDTab
        }
        focusedHUDTab = activeHUDTab
    }

    private var preferredPlaybackHUDTab: TVPlayerInfoHUD.Tab {
        if !viewModel.audioTracks.isEmpty { return .audio }
        if !viewModel.subtitleTracks.isEmpty { return .subtitles }
        return .video
    }

    private func closeHUD() {
        viewModel.closeHUD()
    }

    // MARK: - Helpers

    private func formatTime(_ seconds: Double) -> String {
        PlayerTimeFormatter.formatHMS(seconds)
    }

    private func formatCountdown(_ seconds: Int) -> String {
        PlayerTimeFormatter.formatCountdown(seconds)
    }
}
#endif
