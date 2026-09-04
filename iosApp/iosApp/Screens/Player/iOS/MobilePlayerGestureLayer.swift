#if os(iOS)
import SwiftUI

/// Full-screen touch layer that sits between the video surface and the
/// controls overlay. Owns every "invisible" player gesture so the overlay
/// stays a plain button surface:
///
/// - single tap            → toggle the controls overlay
/// - double tap left/right → skip ±10s (with a ripple flash at the tap side)
/// - double tap center     → play/pause
/// - touch & hold          → 2× playback while held (chip at top center)
/// - drag on left edge     → screen brightness (vertical gauge)
/// - drag on right edge    → player volume (vertical gauge)
/// - pinch                 → cycle video gravity (fit / fill / stretch)
///
/// Center drags never dismiss playback. Exit is an explicit close-button
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
        let id: UUID
    }

    @State private var skipFlash: SkipFlash?
    @State private var skipFlashHideTask: Task<Void, Never>?

    /// Which edge gauge the in-flight drag is adjusting, decided once from
    /// the drag's start location. Nil for center drags, which do nothing.
    @State private var activeAdjustment: EdgeAdjustment?
    /// Brightness/volume value captured when the drag began; the drag
    /// applies a delta on top so the level never jumps to the touch point.
    @State private var dragBaseline: Double?
    /// Which gauge is on screen. Outlives `activeAdjustment` by a beat so
    /// the gauge doesn't vanish the instant the finger lifts.
    @State private var visibleGauge: EdgeAdjustment?
    @State private var gaugeFraction: Double = 0
    @State private var gaugeHideTask: Task<Void, Never>?

    /// Video-gravity mode announced after a pinch; shown briefly as a toast.
    @State private var gravityToast: VideoGravity?
    @State private var gravityToastHideTask: Task<Void, Never>?

    /// Width of the brightness/volume strips along each screen edge.
    private static let edgeZoneWidth: CGFloat = 88

    /// Screen hosting the app's foreground scene. `UIScreen.main` is
    /// deprecated on iOS 26; the player always lives in the single
    /// foreground window scene, so resolving through the scene list is
    /// equivalent.
    private var activeScreen: UIScreen? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .screen
    }
    /// Fraction of the width on each side that double-taps treat as a skip
    /// zone; the middle band toggles play/pause instead.
    private static let skipZoneFraction: CGFloat = 0.35

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size

            ZStack {
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(doubleTapGesture(in: size).exclusively(before: singleTapGesture))
                    .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 24) {
                        viewModel.beginHoldFastForward()
                    } onPressingChanged: { pressing in
                        if !pressing {
                            viewModel.endHoldFastForward()
                        }
                    }
                    .simultaneousGesture(edgeAdjustmentDrag(in: size))
                    .simultaneousGesture(videoGravityPinchGesture)

                feedbackOverlays(in: size)
            }
        }
        // The controls scrim should swallow touches while the overlay is up,
        // but SwiftUI tap recognizers on an occluded sibling can still track
        // touches — rapid presses on the overlay's ±10s buttons registered
        // here as a double-tap skip. Drop out of hit testing entirely while
        // the overlay owns the screen.
        .allowsHitTesting(!viewModel.showControls)
        .ignoresSafeArea()
        .onDisappear {
            // The layer can be torn out mid-gesture (loading state flips,
            // player transitions) without a final onPressingChanged(false).
            viewModel.endHoldFastForward()
            skipFlashHideTask?.cancel()
            gaugeHideTask?.cancel()
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
            if x < size.width * Self.skipZoneFraction {
                viewModel.skipBackward(10, revealingControls: false)
                showSkipFlash(forward: false)
            } else if x > size.width * (1 - Self.skipZoneFraction) {
                viewModel.skipForward(10, revealingControls: false)
                showSkipFlash(forward: true)
            } else {
                viewModel.togglePlayPause()
            }
        }
    }

    private func edgeAdjustmentDrag(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                if dragBaseline == nil {
                    let startX = value.startLocation.x
                    if startX < Self.edgeZoneWidth {
                        activeAdjustment = .brightness
                        dragBaseline = Double(activeScreen?.brightness ?? 0.5)
                    } else if startX > size.width - Self.edgeZoneWidth {
                        activeAdjustment = .volume
                        dragBaseline = Double(viewModel.currentUserVolume)
                    } else {
                        activeAdjustment = nil
                        dragBaseline = 0
                    }
                }
                guard let adjustment = activeAdjustment, let baseline = dragBaseline else { return }

                // Full swing over ~260pt of travel; up increases.
                let fraction = min(max(baseline - Double(value.translation.height) / 260, 0), 1)
                gaugeFraction = fraction
                visibleGauge = adjustment
                gaugeHideTask?.cancel()
                switch adjustment {
                case .brightness:
                    activeScreen?.brightness = fraction
                case .volume:
                    viewModel.applyUserVolume(Float(fraction))
                }
            }
            .onEnded { _ in
                if activeAdjustment != nil {
                    scheduleGaugeHide()
                }
                activeAdjustment = nil
                dragBaseline = nil
            }
    }

    private var videoGravityPinchGesture: some Gesture {
        MagnificationGesture()
            .onEnded { scale in
                if scale > 1.08 {
                    let gravity = nextVideoGravity(after: viewModel.settings.videoGravity)
                    viewModel.setVideoGravity(gravity)
                    showGravityToast(gravity)
                } else if scale < 0.92 {
                    let gravity = previousVideoGravity(before: viewModel.settings.videoGravity)
                    viewModel.setVideoGravity(gravity)
                    showGravityToast(gravity)
                }
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

    private func showSkipFlash(forward: Bool) {
        skipFlash = SkipFlash(forward: forward, id: UUID())
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

    private func scheduleGaugeHide() {
        gaugeHideTask?.cancel()
        gaugeHideTask = Task {
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { visibleGauge = nil }
        }
    }

    @ViewBuilder
    private func feedbackOverlays(in size: CGSize) -> some View {
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

        if let gravity = gravityToast {
            gravityToastChip(for: gravity)
                .position(x: size.width / 2, y: 46)
                .transition(.opacity)
                .allowsHitTesting(false)
        }

        if viewModel.isHoldFastForwarding {
            holdFastForwardChip
                .position(x: size.width / 2, y: 46)
                .transition(.opacity)
                .allowsHitTesting(false)
        }

        if let gauge = visibleGauge {
            edgeGauge(for: gauge)
                .position(
                    x: gauge == .brightness ? 36 : size.width - 36,
                    y: size.height / 2
                )
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    private func skipFlashView(_ flash: SkipFlash) -> some View {
        VStack(spacing: 3) {
            Image(systemName: flash.forward ? "goforward.10" : "gobackward.10")
                .font(.system(size: 26, weight: .semibold))
            Text(flash.forward ? "+10s" : "−10s")
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

    private func edgeGauge(for adjustment: EdgeAdjustment) -> some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                    Capsule()
                        .fill(Color.white)
                        .frame(height: max(proxy.size.height * gaugeFraction, 6))
                }
            }
            .frame(width: 6, height: 130)

            Image(systemName: adjustment == .brightness
                ? "sun.max.fill"
                : (gaugeFraction <= 0.01 ? "speaker.slash.fill" : "speaker.wave.2.fill"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .siloPlayerGlass(in: Capsule())
    }
}
#endif
