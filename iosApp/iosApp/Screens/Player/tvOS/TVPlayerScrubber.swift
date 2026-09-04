#if os(tvOS)
import SwiftUI

/// Glass-capsule scrubber inspired by Infuse / the Apple TV app. Left/right
/// presses route through `PlayerViewModel.skipBackward` / `skipForward`,
/// which own a trailing-edge debounce — rapid presses coalesce into one
/// seek fired after the user stops pressing. Select commits the in-flight
/// preview immediately. In explicit timeline-scrub mode, Select starts and
/// commits the preview; opening a player menu abandons the preview.
/// Chapter ticks sit on the bar while the footer below the timeline owns the
/// current-time readout.
struct TVPlayerScrubber: View {
    let viewModel: PlayerViewModel
    @FocusState.Binding var isFocused: Bool
    let onSelectInteraction: () -> Void
    let onMoveToTransport: () -> Void
    let onExitWhenIdle: () -> Void

    /// Explicit timeline-scrub mode (Select on the puck). Owned by the shell
    /// so it can drop the transport row out of the focus graph while the
    /// scrub is modal — otherwise a Down press/swipe moves focus there
    /// natively, before `onMoveCommand` ever fires.
    @Binding var isTimelineScrubbing: Bool

    /// Whether this explicit timeline session paused active playback and
    /// should therefore resume it when committed. Kept by the shell so an
    /// externally-requested session can carry its pre-pause state in.
    @Binding var resumePlaybackAfterTimelineSelection: Bool

    /// When true, blurring the scrubber cancels the in-progress scrub rather
    /// than committing it. The shell flips this on before opening a sheet so
    /// the focus-lost path doesn't turn into an accidental seek.
    var cancelOnBlur: Bool = false

    private static let scrubBackwardStep: Double = 10
    private static let scrubForwardStep: Double = 30
    private static let timelineHoldBackwardStep: Double = 2
    private static let timelineHoldForwardStep: Double = 2
    private static let timelineAutoSeekTickNanos: UInt64 = 100_000_000
    private static let timelineAutoSeekBaseStep: Double = 2
    private static let timelineAutoSeekRates = [-32, -16, -8, -4, -2, -1, 1, 2, 4, 8, 16, 32]
    @State private var timelineAutoSeekRate = 0
    @State private var timelineAutoSeekTask: Task<Void, Never>?

    /// Trackpad-drag scrubbing. Translation from one full edge-to-edge swipe
    /// on the Siri Remote surface is ~1000pt, so this maps a full swipe to
    /// roughly 8% of the timeline — a light drag lands within seconds of
    /// where it started instead of jumping minutes.
    private static let panPointsForFullTimeline: CGFloat = 12000
    /// Accumulated translation required before a drag starts moving the
    /// playhead; the finger contact from a d-pad click always jitters a few
    /// points and must not nudge the preview.
    private static let panDeadzone: CGFloat = 12
    @State private var isPanScrubbing = false
    @State private var panEngaged = false
    @State private var panAccumulated: CGFloat = 0
    /// Distinguishes entering/exiting timeline mode from a real seek. A
    /// Select-only round trip should resume the paused pipeline in place.
    @State private var hasTimelineSelectionMoved = false

    // Visual metrics pulled out as compile-time constants so layout doesn't
    // re-evaluate them each pass. Chapter ticks rely on `trackHeight` so the
    // track and ticks stay visually aligned.
    private static let barHeight: CGFloat = 7
    private static let activeBarHeight: CGFloat = 12
    private static let puckSize: CGFloat = 30
    private static let activePuckSize: CGFloat = 42
    /// Reserved vertical footprint for the largest focused puck/ticks so
    /// focus state cannot resize the transport stack.
    private static let trackStackHeight: CGFloat = 56

    /// Playhead fraction as rendered on the bar — reflects the scrub preview
    /// while scrubbing so the white fill tracks the user's nudges instead of
    /// the underlying playback position.
    private var progressFraction: Double {
        guard viewModel.duration > 0 else { return 0 }
        let t = viewModel.isScrubbing ? viewModel.scrubPreviewTime : viewModel.currentTime
        return min(max(t / viewModel.duration, 0), 1)
    }

    private var bufferedFraction: Double {
        guard viewModel.duration > 0 else { return 0 }
        let end = viewModel.currentTime + viewModel.bufferedAheadSeconds
        return min(max(end / viewModel.duration, 0), 1)
    }

    private var displayTime: Double {
        viewModel.isScrubbing ? viewModel.scrubPreviewTime : viewModel.currentTime
    }

    var body: some View {
        // Plain `.focusable(true)` rather than a `Button`: tvOS's built-in
        // button styles (.plain/.card/.borderless) all render a full-bounds
        // "focused surface" that inflated the scrubber into a full-width
        // white slab whenever focus arrived. `.focusEffectDisabled()`
        // doesn't suppress that surface because it belongs to the
        // ButtonStyle, not a separate focus effect. Using a bare focusable
        // view gives us the focus state without any system chrome. Select
        // press commits via `onTapGesture` — on tvOS the remote's Select
        // button delivers a tap to the focused view.
        barLayer
            .contentShape(Rectangle())
            .overlay(alignment: .topTrailing) {
                if isTimelineAutoSeeking {
                    timelineAutoSeekChip
                        .offset(y: -34)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
            .focusable(true)
            .focused($isFocused)
            .onTapGesture { commitScrub() }
            .background {
                ZStack {
                    TVDirectionalPressGestureView(
                        isActive: isFocused && !viewModel.isHoldSeeking && timelineAutoSeekRate == 0,
                        onArrowTap: handleArrowTap,
                        onArrowHoldBegin: handleArrowHoldBegin
                    )
                    // Continuous trackpad drag while the puck is selected —
                    // Select enters timeline-scrub mode, then swipes stream
                    // through here instead of stepping ±10s/30s per move
                    // command.
                    TVPanCaptureView(
                        isActive: isFocused && isTimelineScrubbing && !isTimelineAutoSeeking,
                        onPanBegan: {
                            isPanScrubbing = true
                            panEngaged = false
                            panAccumulated = 0
                        },
                        onPanChanged: handlePanChanged,
                        onPanEnded: { isPanScrubbing = false }
                    )
                }
                .frame(width: 1, height: 1)
            }
            .onChange(of: isFocused) { _, focused in
                // Gaining focus is not itself a scrub: the scrub series
                // starts on the first Left/Right press (via `skipBackward`
                // / `skipForward` which own the debounce). Blur only
                // matters when a series is in flight — commit or cancel
                // based on whether the shell asked us to abandon.
                if !focused, viewModel.isScrubbing {
                    if isTimelineScrubbing {
                        stopTimelineAutoSeek()
                        isTimelineScrubbing = false
                        resumePlaybackAfterTimelineSelection = false
                        viewModel.cancelScrub()
                    } else if cancelOnBlur {
                        viewModel.cancelScrub()
                    } else {
                        viewModel.endScrub()
                    }
                }
            }
            .onChange(of: isTimelineScrubbing) { _, scrubbing in
                if scrubbing {
                    hasTimelineSelectionMoved = false
                }
            }
            .onMoveCommand(perform: handleMove)
            .onExitCommand {
                if isTimelineScrubbing || viewModel.isScrubbing {
                    cancelTimelineScrub()
                } else {
                    onExitWhenIdle()
                }
            }
            .accessibilityLabel("Scrubber")
            .accessibilityValue(Text(formatTime(displayTime)))
    }

    // MARK: - Bar

    private var barLayer: some View {
        GeometryReader { geo in
            let width = geo.size.width
            ZStack(alignment: .leading) {
                // Thin-line track: at 3pt the capsule glass adds nothing but
                // cost, so the track is now a plain translucent white fill.
                // The played region is pure white on top; the unplayed region
                // reads at ~22% opacity — enough contrast against video
                // without pulling attention from the frame.
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(isTimelineScrubbing ? 0.48 : isFocused ? 0.35 : 0.24))
                    .frame(height: trackHeight)

                introRegion(barWidth: width)

                // Played / scrub-preview fill.
                Capsule(style: .continuous)
                    .fill(Color.white)
                    .frame(width: width * progressFraction, height: trackHeight)

                // Buffered-ahead sliver: only the region *between* the
                // playhead and the end of the loaded range. Rendering from
                // x=0 would put it entirely under the played fill (invisible)
                // and mis-represent the semantic — buffer is inherently a
                // forward-looking indicator. Aether routes without comparable
                // buffer telemetry leave `bufferedAheadSeconds` at zero.
                let bufferedAhead = max(0, bufferedFraction - progressFraction)
                if bufferedAhead > 0 {
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.28))
                        .frame(width: width * bufferedAhead, height: trackHeight)
                        .offset(x: width * progressFraction)
                }

                // Chapter ticks float on top of the fill — white at full
                // opacity so they read through the played region too.
                chapterTicks(barWidth: width)

                // Playhead puck — only while focused so the bar reads as a
                // passive progress indicator when the user is elsewhere.
                if isFocused {
                    puck(barWidth: width)
                }
            }
            .frame(height: Self.trackStackHeight, alignment: .center)
        }
        .frame(height: Self.trackStackHeight)
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
        // Deliberately no animation on `progressFraction` — it animated every
        // tick of the playhead AND every transition between scrub preview and
        // live position, which turned any state drift (keyframe snapping,
        // filter-release handoff) into a visible 100 ms slide. With it
        // removed, normal playback ticks step forward discretely (at the
        // periodic observer's cadence) and seek commits snap cleanly.
    }

    @ViewBuilder
    private func introRegion(barWidth: CGFloat) -> some View {
        if let introRange = viewModel.introRange, viewModel.duration > 0 {
            let start = min(max(introRange.start / viewModel.duration, 0), 1)
            let end = min(max(introRange.end / viewModel.duration, 0), 1)
            if end > start {
                Capsule(style: .continuous)
                    .fill(Color.cyan.opacity(isTimelineScrubbing || isFocused ? 0.45 : 0.34))
                    .frame(width: barWidth * (end - start), height: trackHeight)
                    .offset(x: barWidth * start)
            }
        }
    }

    @ViewBuilder
    private func chapterTicks(barWidth: CGFloat) -> some View {
        if viewModel.duration > 0 && !viewModel.chapters.isEmpty {
            ForEach(viewModel.chapters) { chapter in
                let fraction = min(max(chapter.time / viewModel.duration, 0), 1)
                // Skip the chapter-0 tick at x=0 — it sits under the capsule
                // endcap and reads as an artifact.
                if fraction > 0.001 {
                    Rectangle()
                        .fill(Color.white.opacity(0.85))
                        .frame(width: isTimelineScrubbing ? 4 : 3, height: trackHeight + 14)
                        .offset(x: barWidth * fraction - 1)
                }
            }
        }
    }

    private func puck(barWidth: CGFloat) -> some View {
        let size = isTimelineScrubbing ? Self.activePuckSize : Self.puckSize
        return Circle()
            .fill(Color.white)
            .frame(width: size, height: size)
            .overlay(
                Circle().stroke(Color.white.opacity(isTimelineScrubbing ? 0.55 : 0), lineWidth: 8)
            )
            .shadow(color: .black.opacity(0.48), radius: 8, y: 3)
            .offset(x: barWidth * progressFraction - size / 2)
    }

    private var trackHeight: CGFloat {
        isTimelineScrubbing ? Self.activeBarHeight : Self.barHeight
    }

    private var isTimelineAutoSeeking: Bool {
        timelineAutoSeekRate != 0
    }

    private var timelineAutoSeekChip: some View {
        HStack(spacing: 7) {
            Image(systemName: timelineAutoSeekRate < 0 ? "backward.fill" : "forward.fill")
                .font(.system(size: 13, weight: .bold))
            Text("\(abs(timelineAutoSeekRate))x")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.black)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule(style: .continuous).fill(.white))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: timelineAutoSeekRate)
    }

    // MARK: - Input

    private func handleArrowTap(_ direction: TVPressCaptureView.ArrowDirection) {
        if isTimelineAutoSeeking {
            switch direction {
            case .left:
                adjustTimelineAutoSeekRate(delta: -1)
            case .right:
                adjustTimelineAutoSeekRate(delta: 1)
            case .up, .down:
                break
            }
            return
        }

        switch direction {
        case .left:
            if isTimelineScrubbing {
                stepTimeline(by: -Self.scrubBackwardStep)
            } else {
                viewModel.skipBackward(Self.scrubBackwardStep)
            }
        case .right:
            if isTimelineScrubbing {
                stepTimeline(by: Self.scrubForwardStep)
            } else {
                viewModel.skipForward(Self.scrubForwardStep)
            }
        case .up, .down:
            break
        }
    }

    private func handleArrowHoldBegin(_ direction: TVPressCaptureView.ArrowDirection) {
        switch direction {
        case .left:
            beginTimelineAutoSeek(direction: -1)
        case .right:
            beginTimelineAutoSeek(direction: 1)
        case .up, .down:
            break
        }
    }

    private func beginTimelineHoldIfNeeded() {
        guard !isTimelineScrubbing else { return }
        guard viewModel.duration > 0 else { return }
        resumePlaybackAfterTimelineSelection = viewModel.isPlaying
        let base = viewModel.isScrubbing ? viewModel.scrubPreviewTime : viewModel.currentTime
        viewModel.beginScrub(fraction: min(max(base / viewModel.duration, 0), 1))
        isTimelineScrubbing = true
    }

    private func beginTimelineAutoSeek(direction: Int) {
        beginTimelineHoldIfNeeded()
        timelineAutoSeekRate = direction < 0 ? -1 : 1
        startTimelineAutoSeekTask()
    }

    private func startTimelineAutoSeekTask() {
        timelineAutoSeekTask?.cancel()
        timelineAutoSeekTask = Task { @MainActor in
            while !Task.isCancelled {
                let rate = timelineAutoSeekRate
                if rate == 0 { break }
                stepTimeline(by: Self.timelineAutoSeekBaseStep * Double(rate))
                try? await Task.sleep(nanoseconds: Self.timelineAutoSeekTickNanos)
            }
        }
    }

    private func adjustTimelineAutoSeekRate(delta: Int) {
        guard isTimelineAutoSeeking else { return }
        guard let currentIdx = Self.timelineAutoSeekRates.firstIndex(of: timelineAutoSeekRate) else { return }
        let newIdx = max(0, min(Self.timelineAutoSeekRates.count - 1, currentIdx + delta))
        timelineAutoSeekRate = Self.timelineAutoSeekRates[newIdx]
    }

    private func stopTimelineAutoSeek() {
        timelineAutoSeekTask?.cancel()
        timelineAutoSeekTask = nil
        timelineAutoSeekRate = 0
    }

    private func cancelTimelineScrub() {
        guard isTimelineScrubbing || viewModel.isScrubbing else { return }
        stopTimelineAutoSeek()
        isTimelineScrubbing = false
        resumePlaybackAfterTimelineSelection = false
        viewModel.cancelScrub()
    }

    /// Select on an in-flight scrub commits the preview immediately instead
    /// of waiting for the debounce to fire.
    private func commitScrub() {
        onSelectInteraction()
        if isTimelineScrubbing || viewModel.isScrubbing {
            let resumesPlayback = isTimelineScrubbing && resumePlaybackAfterTimelineSelection
            let shouldSeek = !isTimelineScrubbing || hasTimelineSelectionMoved
            stopTimelineAutoSeek()
            isTimelineScrubbing = false
            resumePlaybackAfterTimelineSelection = false
            viewModel.endScrub(resumePlayback: resumesPlayback, shouldSeek: shouldSeek)
        } else {
            guard viewModel.duration > 0 else { return }
            resumePlaybackAfterTimelineSelection = viewModel.isPlaying
            viewModel.pauseForTimelineSelection()
            let fraction = viewModel.currentTime / viewModel.duration
            viewModel.beginScrub(fraction: fraction)
            isTimelineScrubbing = true
        }
    }

    /// Continuous trackpad drag: translation maps linearly onto the
    /// timeline. A deadzone filters out the contact jitter from clicks; once
    /// crossed, every subsequent delta moves the preview directly.
    private func handlePanChanged(_ deltaX: CGFloat) {
        guard isTimelineScrubbing, viewModel.duration > 0 else { return }
        if !panEngaged {
            panAccumulated += deltaX
            guard abs(panAccumulated) >= Self.panDeadzone else { return }
            panEngaged = true
        }
        let base = viewModel.isScrubbing ? viewModel.scrubPreviewTime : viewModel.currentTime
        let deltaSeconds = Double(deltaX / Self.panPointsForFullTimeline) * viewModel.duration
        let target = min(max(base + deltaSeconds, 0), viewModel.duration)
        if target != base {
            hasTimelineSelectionMoved = true
        }
        viewModel.updateScrub(fraction: target / viewModel.duration)
    }

    private func handleMove(_ direction: MoveCommandDirection) {
        // While a trackpad drag is in flight the same swipe also surfaces
        // here as discrete left/right move commands — the pan owns the
        // playhead, so the fixed-step path must stay quiet.
        let panOwnsTimeline = isPanScrubbing && isTimelineScrubbing && !isTimelineAutoSeeking
        switch direction {
        case .left:
            guard viewModel.duration > 0 else { return }
            if isTimelineAutoSeeking {
                adjustTimelineAutoSeekRate(delta: -1)
            } else if isTimelineScrubbing, !panOwnsTimeline {
                stepTimeline(by: -Self.scrubBackwardStep)
            }
        case .right:
            guard viewModel.duration > 0 else { return }
            if isTimelineAutoSeeking {
                adjustTimelineAutoSeekRate(delta: 1)
            } else if isTimelineScrubbing, !panOwnsTimeline {
                stepTimeline(by: Self.scrubForwardStep)
            }
        case .up:
            break
        case .down:
            // While a scrub is in flight, a downward swipe is almost always
            // drag spillover, not an intent to leave — trapping it keeps the
            // preview alive until the user commits (Select) or cancels (Menu).
            guard !isTimelineScrubbing, !viewModel.isScrubbing else { return }
            onMoveToTransport()
        @unknown default:
            break
        }
    }

    private func stepTimeline(by delta: Double) {
        let base = viewModel.isScrubbing ? viewModel.scrubPreviewTime : viewModel.currentTime
        let target = min(max(base + delta, 0), viewModel.duration)
        if target != base {
            hasTimelineSelectionMoved = true
        }
        viewModel.updateScrub(fraction: target / viewModel.duration)
    }

    private func stepTimelineHold(direction: Int) {
        let step = direction < 0 ? -Self.timelineHoldBackwardStep : Self.timelineHoldForwardStep
        stepTimeline(by: step)
    }

    private func formatTime(_ seconds: Double) -> String {
        PlayerTimeFormatter.formatHMS(seconds)
    }
}
#endif
