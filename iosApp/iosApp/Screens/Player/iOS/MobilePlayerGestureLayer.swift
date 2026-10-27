#if os(iOS)
import SwiftUI

/// Full-screen touch layer that sits between the video surface and the
/// controls overlay. Owns every "invisible" player gesture so the overlay
/// stays a plain button surface:
///
/// - single tap            → toggle the controls overlay
/// - double tap left/right → skip by the profile's video intervals (with a
///   ripple flash at the tap side)
/// - double tap center     → play/pause
/// - touch & hold          → 2× playback while held (chip at top center)
/// - drag on left edge     → screen brightness (percentage chip at top center)
/// - drag on right edge    → device volume (percentage chip at top center)
/// - pinch                 → cycle video gravity (fit / fill / stretch)
///
/// Hold, edge drag, and pinch are exclusive: the first to start owns the
/// touch until it ends, so a slipping thumb holding 2× can't also move the
/// volume. Center drags never dismiss playback. Exit is an explicit close-button
/// action; edge brightness/volume gestures remain available.
///
/// The layer is mounted only while playback is loaded. When the controls
/// overlay is visible its scrim sits above this layer and captures touches,
/// so these gestures apply to the "clean" viewing state.
struct MobilePlayerGestureLayer: View {
    let viewModel: PlayerViewModel

    private enum EdgeAdjustment { case brightness, volume }

    private struct SkipFlash: Equatable {
        let forward: Bool
        let seconds: Int
        let id: UUID
    }

    @State private var skipFlash: SkipFlash?
    @State private var gestureOwnership = PlayerGestureOwnership()
    @State private var skipFlashHideTask: Task<Void, Never>?

    /// Which edge gauge the in-flight drag is adjusting, decided once from
    /// the drag's start location. Nil for center drags, which do nothing.
    @State private var activeAdjustment: EdgeAdjustment?
    /// Brightness/volume value captured when the drag began; the drag
    /// applies a delta on top so the level never jumps to the touch point.
    @State private var dragBaseline: Double?
    /// Which gauges are on screen. Each outlives `activeAdjustment` by a
    /// beat so it doesn't vanish the instant the finger lifts. Both can show
    /// at once, as when the volume buttons are pressed mid brightness drag.
    @State private var visibleGauges: Set<EdgeAdjustment> = []
    @State private var gaugeFractions: [EdgeAdjustment: Double] = [:]
    @State private var gaugeHideTasks: [EdgeAdjustment: Task<Void, Never>] = [:]
    /// Gauge level bucket for the in-flight drag; nil between drags. Each
    /// change ticks a haptic, so the finger feels the level move.
    @State private var gaugeHapticStep: Int?
    @State private var systemVolume = PlayerSystemVolume()

    /// Video-gravity mode announced after a pinch; shown briefly as a toast.
    @State private var gravityToast: VideoGravity?
    @State private var gravityToastHideTask: Task<Void, Never>?
    /// Bumped only when a pinch actually changes the gravity, so pinching
    /// past fit or stretch shows the toast without a haptic.
    @State private var gravityChangeCount = 0

    /// Width of the brightness/volume strips along each screen edge, past
    /// that side's safe-area inset. In landscape the inset covers the
    /// Dynamic Island, which would otherwise eat into the strip.
    private static let edgeZoneWidth: CGFloat = 88
    /// Distance from the top safe area to the first chip in the top stack.
    private static let topChipTop: CGFloat = 22
    /// Drag travel for a full 0–100% swing.
    private static let gaugeFullSwing: CGFloat = 160
    /// Haptic ticks across a full gauge swing; matches the 16 hardware
    /// volume-button steps.
    private static let gaugeHapticSteps = 16

    /// Fraction of the width on each side that double-taps treat as a skip
    /// zone; the middle band toggles play/pause instead.
    private static let skipZoneFraction: CGFloat = 0.35

    var body: some View {
        // A reader that ignores the safe area reports zero insets, so the
        // outer reader, which respects it, supplies them to the full-screen
        // inner one.
        GeometryReader { safeArea in
            let insets = safeArea.safeAreaInsets
            GeometryReader { proxy in
                let size = proxy.size
                let leadingZone = insets.leading + Self.edgeZoneWidth
                let trailingZone = insets.trailing + Self.edgeZoneWidth

                ZStack {
                    // Must stay in the window for writes to move the device
                    // volume; its presence also hides the system volume HUD,
                    // which the volume chip replaces.
                    PlayerSystemVolumeHost(volume: systemVolume)
                        .frame(width: 1, height: 1)
                        .opacity(0.0001)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)

                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(doubleTapGesture(in: size).exclusively(before: singleTapGesture))
                        .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 24) {
                            guard gestureOwnership.claim(.hold) else { return }
                            viewModel.beginHoldFastForward()
                            // A paused player refuses 2×; leave the touch
                            // free for an edge drag.
                            if !viewModel.isHoldFastForwarding { gestureOwnership.release(.hold) }
                        } onPressingChanged: { pressing in
                            if !pressing {
                                gestureOwnership.release(.hold)
                                viewModel.endHoldFastForward()
                            }
                        }
                        .simultaneousGesture(edgeAdjustmentDrag(in: size, leadingZone: leadingZone, trailingZone: trailingZone))
                        .simultaneousGesture(videoGravityPinchGesture)

                    feedbackOverlays(in: size, insets: insets)
                }
            }
            .ignoresSafeArea()
        }
        // These gestures have no button under the finger, so a light haptic
        // confirms each one landed.
        .sensoryFeedback(trigger: skipFlash?.id) { _, id in
            id == nil ? nil : .impact(weight: .light)
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: viewModel.isHoldFastForwarding) { _, holding in
            holding
        }
        .sensoryFeedback(.impact(weight: .light), trigger: gravityChangeCount)
        // A tick per gauge step, and a firmer one at empty or full.
        .sensoryFeedback(trigger: gaugeHapticStep) { old, new in
            guard let old, let new, old != new else { return nil }
            return new == 0 || new == Self.gaugeHapticSteps + 1
                ? .impact(weight: .medium)
                : .selection
        }
        // The controls scrim should swallow touches while the overlay is up,
        // but SwiftUI tap recognizers on an occluded sibling can still track
        // touches — rapid presses on the overlay's skip buttons registered
        // here as a double-tap skip. Drop out of hit testing entirely while
        // the overlay owns the screen.
        .allowsHitTesting(!viewModel.showControls)
        // Dropping out of hit testing cancels in-flight gestures without
        // their end callbacks; release the touch so the next one starts clean.
        .onChange(of: viewModel.showControls) { _, showing in
            guard showing else { return }
            gestureOwnership.reset()
            activeAdjustment = nil
            dragBaseline = nil
            gaugeHapticStep = nil
        }
        .onAppear {
            systemVolume.onExternalChange = { level in
                // The drag's own writes echo back here late; the drag
                // already drives the gauge.
                guard activeAdjustment != .volume else { return }
                showGauge(.volume, fraction: Double(level))
                scheduleGaugeHide(.volume)
            }
            systemVolume.startObserving()
        }
        .onDisappear {
            systemVolume.stopObserving()
            // The callback captures this view, whose state holds
            // `systemVolume`; clearing it breaks that cycle.
            systemVolume.onExternalChange = nil
            // The layer can be torn out mid-gesture (loading state flips,
            // player transitions) without a final onPressingChanged(false).
            viewModel.endHoldFastForward()
            gestureOwnership.reset()
            skipFlashHideTask?.cancel()
            gaugeHideTasks.values.forEach { $0.cancel() }
            gravityToastHideTask?.cancel()
        }
    }

    // MARK: - Gestures

    private var singleTapGesture: some Gesture {
        TapGesture().onEnded { viewModel.toggleControls() }
    }

    private func doubleTapGesture(in size: CGSize) -> some Gesture {
        SpatialTapGesture(count: 2).onEnded { value in
            // Belt-and-braces for a recognizer that started tracking just
            // before the overlay appeared: never double-tap-skip while the
            // controls own the screen.
            guard !viewModel.showControls else { return }
            let x = value.location.x
            // revealingControls: false — the flash below is the feedback;
            // summoning the overlay would drop its scrim on top of this
            // layer and swallow the next double-tap.
            // A refused skip (parked at end of file) shows no flash, so its
            // haptic doesn't confirm a skip that never happened.
            if x < size.width * Self.skipZoneFraction {
                let seconds = viewModel.skipIntervals.backward
                if viewModel.skipBackward(Double(seconds), revealingControls: false) {
                    showSkipFlash(forward: false, seconds: seconds)
                }
            } else if x > size.width * (1 - Self.skipZoneFraction) {
                let seconds = viewModel.skipIntervals.forward
                if viewModel.skipForward(Double(seconds), revealingControls: false) {
                    showSkipFlash(forward: true, seconds: seconds)
                }
            } else {
                viewModel.togglePlayPause()
            }
        }
    }

    private func edgeAdjustmentDrag(in size: CGSize, leadingZone: CGFloat, trailingZone: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                if dragBaseline == nil {
                    // Decided once per drag, so a drag that starts during a
                    // hold or pinch stays inert after that gesture ends.
                    let startX = value.startLocation.x
                    if startX < leadingZone, gestureOwnership.claim(.edgeAdjustment) {
                        activeAdjustment = .brightness
                        dragBaseline = PlayerScreenBrightness.shared.currentLevel()
                    } else if startX > size.width - trailingZone, gestureOwnership.claim(.edgeAdjustment) {
                        activeAdjustment = .volume
                        dragBaseline = Double(systemVolume.currentLevel)
                    } else {
                        activeAdjustment = nil
                        dragBaseline = 0
                    }
                }
                guard let adjustment = activeAdjustment, let baseline = dragBaseline else { return }

                // Up increases.
                let fraction = min(max(baseline - Double(value.translation.height / Self.gaugeFullSwing), 0), 1)
                switch adjustment {
                case .brightness:
                    PlayerScreenBrightness.shared.apply(fraction)
                case .volume:
                    // No feedback for a level the route won't take.
                    guard systemVolume.apply(Float(fraction)) else { return }
                    viewModel.unmutePlayerGainForLocalVolume()
                }
                showGauge(adjustment, fraction: fraction)
                gaugeHapticStep = Self.gaugeHapticStep(for: fraction)
            }
            .onEnded { _ in
                if let adjustment = activeAdjustment {
                    scheduleGaugeHide(adjustment)
                }
                gestureOwnership.release(.edgeAdjustment)
                activeAdjustment = nil
                dragBaseline = nil
                gaugeHapticStep = nil
            }
    }

    /// 0 only at exactly empty and `gaugeHapticSteps + 1` only at exactly
    /// full, so the firmer edge haptic fires when the level hits a rail.
    private static func gaugeHapticStep(for fraction: Double) -> Int {
        if fraction <= 0 { return 0 }
        if fraction >= 1 { return gaugeHapticSteps + 1 }
        return 1 + min(Int(fraction * Double(gaugeHapticSteps)), gaugeHapticSteps - 1)
    }

    private var videoGravityPinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { _ in
                _ = gestureOwnership.claim(.pinch)
            }
            .onEnded { value in
                guard gestureOwnership.owner == .pinch else { return }
                gestureOwnership.release(.pinch)
                let scale = value.magnification
                let current = viewModel.settings.videoGravity
                let gravity: VideoGravity
                if scale > 1.08 {
                    gravity = nextVideoGravity(after: current)
                } else if scale < 0.92 {
                    gravity = previousVideoGravity(before: current)
                } else {
                    return
                }
                if gravity != current { gravityChangeCount += 1 }
                viewModel.setVideoGravity(gravity)
                showGravityToast(gravity)
            }
    }

    private func nextVideoGravity(after gravity: VideoGravity) -> VideoGravity {
        switch gravity {
        case .fit: return .fill
        case .fill: return .stretch
        case .stretch: return .stretch
        }
    }

    private func previousVideoGravity(before gravity: VideoGravity) -> VideoGravity {
        switch gravity {
        case .fit: return .fit
        case .fill: return .fit
        case .stretch: return .fill
        }
    }

    // MARK: - Transient feedback

    private func showSkipFlash(forward: Bool, seconds: Int) {
        skipFlash = SkipFlash(forward: forward, seconds: seconds, id: UUID())
        skipFlashHideTask?.cancel()
        skipFlashHideTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { skipFlash = nil }
        }
    }

    private func showGravityToast(_ gravity: VideoGravity) {
        withAnimation(.easeOut(duration: 0.15)) { gravityToast = gravity }
        gravityToastHideTask?.cancel()
        gravityToastHideTask = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { gravityToast = nil }
        }
    }

    private func showGauge(_ adjustment: EdgeAdjustment, fraction: Double) {
        gaugeFractions[adjustment] = fraction
        if !visibleGauges.contains(adjustment) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { _ = visibleGauges.insert(adjustment) }
        }
        gaugeHideTasks[adjustment]?.cancel()
    }

    private func scheduleGaugeHide(_ adjustment: EdgeAdjustment) {
        gaugeHideTasks[adjustment]?.cancel()
        gaugeHideTasks[adjustment] = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { _ = visibleGauges.remove(adjustment) }
        }
    }

    @ViewBuilder
    private func feedbackOverlays(in size: CGSize, insets: EdgeInsets) -> some View {
        if let flash = skipFlash {
            skipFlashView(flash)
                .position(
                    x: flash.forward ? size.width * 0.82 : size.width * 0.18,
                    y: size.height / 2
                )
                .transition(.opacity)
                .id(flash.id)
                .allowsHitTesting(false)
        }

        // One stack at top center, clear of the thumb dragging along either
        // edge: chips that show together sit one under the other. The
        // volume buttons can raise a gauge while the controls show; the
        // stack drops below the top bar then, clear of its buttons.
        let topBarBottom = PlayerView.topBarBottom(portrait: size.width < size.height)
        VStack(spacing: 8) {
            if visibleGauges.contains(.brightness) {
                gaugeChip(for: .brightness)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if visibleGauges.contains(.volume) {
                gaugeChip(for: .volume)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if viewModel.isHoldFastForwarding {
                holdFastForwardChip
                    .transition(.opacity)
            }
            if let gravity = gravityToast {
                gravityToastChip(for: gravity)
                    .transition(.opacity)
            }
        }
        .padding(.top, insets.top + (viewModel.showControls ? topBarBottom : Self.topChipTop))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.easeOut(duration: 0.18), value: viewModel.showControls)
        .animation(.easeOut(duration: 0.2), value: viewModel.isHoldFastForwarding)
        .allowsHitTesting(false)
    }

    private func skipFlashView(_ flash: SkipFlash) -> some View {
        VStack(spacing: 3) {
            Image(systemName: SeekIntervalLabel.symbolName(
                flash.forward ? .forward : .backward,
                seconds: flash.seconds
            ))
                .font(.system(size: 26, weight: .semibold))
            Text(flash.forward ? "+\(flash.seconds)s" : "−\(flash.seconds)s")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(.white)
        .frame(width: 74, height: 74)
        .siloPlayerGlass(in: Circle())
    }

    private func gravityToastChip(for gravity: VideoGravity) -> some View {
        HStack(spacing: 6) {
            Image(systemName: gravityToastIcon(for: gravity))
                .font(.system(size: 12, weight: .semibold))
            Text(gravity.label)
                .font(.system(size: 14, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .siloPlayerGlass(in: Capsule())
    }

    private func gravityToastIcon(for gravity: VideoGravity) -> String {
        switch gravity {
        case .fit:     return "rectangle.arrowtriangle.2.inward"
        case .fill:    return "rectangle.arrowtriangle.2.outward"
        case .stretch: return "arrow.left.and.right.square"
        }
    }

    private var holdFastForwardChip: some View {
        HStack(spacing: 6) {
            Text("2×")
                .font(.system(size: 14, weight: .bold))
            Image(systemName: "forward.fill")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .siloPlayerGlass(in: Capsule())
    }

    private func gaugeChip(for adjustment: EdgeAdjustment) -> some View {
        let fraction = gaugeFractions[adjustment] ?? 0
        return HStack(spacing: 14) {
            gaugeIcon(for: adjustment, fraction: fraction)
                .font(.system(size: 20, weight: .semibold))
                // The speaker's waves make it wider than the sun.
                .frame(width: adjustment == .volume ? 30 : 24, height: 24)
                .contentTransition(.symbolEffect(.replace))
            Text("\(Int((fraction * 100).rounded()))%")
                .font(.system(size: 17, weight: .medium))
                .monospacedDigit()
                .frame(minWidth: 44, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .siloPlayerGlass(in: Capsule())
    }

    private func gaugeIcon(for adjustment: EdgeAdjustment, fraction: Double) -> Image {
        switch adjustment {
        case .brightness:
            return Image(systemName: fraction < 0.5 ? "sun.min" : "sun.max")
        case .volume:
            if fraction <= 0.01 {
                return Image(systemName: "speaker.slash.fill")
            }
            // The waves fill in with the level.
            return Image(systemName: "speaker.wave.3.fill", variableValue: fraction)
        }
    }
}
#endif
