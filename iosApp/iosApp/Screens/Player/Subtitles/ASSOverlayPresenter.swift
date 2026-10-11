import AVFoundation
import AetherEngine
import CoreMedia
import Foundation

/// Where the presenter queues canvases, and the clock it queues them against.
protocol ASSOverlayOutput: AnyObject, Sendable {
    /// Seconds on the clock queued canvases are stamped against.
    var now: Double { get }
    var rate: Double { get }
    /// Shows `buffer` from `time` until the next queued canvas, when
    /// `generation` is the selection the output accepts.
    func enqueue(_ buffer: CVPixelBuffer, at time: CMTime, generation: UInt64)
    /// Drops everything queued. Removing the displayed image clears the
    /// overlay at once; keeping it holds the last canvas until a new one is due.
    func flush(removingImage: Bool)
}

/// A sample-buffer layer that shows rendered subtitle canvases at the times
/// they are stamped with, on the video's own clock. Core Animation pairs each
/// canvas with the frame it was rendered for, so a slow render or a busy main
/// thread does not shift it.
final class ASSOverlaySink: ASSOverlayOutput, @unchecked Sendable {
    let layer: AVSampleBufferDisplayLayer
    let timebase: CMTimebase
    private let renderer: AVSampleBufferVideoRenderer
    private let lock = NSLock()
    private var formats: [CGSize: CMVideoFormatDescription] = [:]
    private var acceptedGeneration: UInt64

    @MainActor
    init(timebase: CMTimebase, generation: UInt64) {
        self.timebase = timebase
        acceptedGeneration = generation
        layer = AVSampleBufferDisplayLayer()
        layer.controlTimebase = timebase
        layer.videoGravity = .resize
        layer.isOpaque = false
        layer.backgroundColor = nil
        renderer = layer.sampleBufferRenderer
    }

    var now: Double { CMTimebaseGetTime(timebase).seconds }
    var rate: Double { CMTimebaseGetRate(timebase) }

    /// The selection whose canvases may be shown. Only the session sets it,
    /// on the main actor and before it awaits the presenter, so a step still
    /// rendering for an outgoing selection cannot put its canvases back after
    /// that selection's flush.
    @MainActor
    func accept(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        acceptedGeneration = generation
    }

    func enqueue(_ buffer: CVPixelBuffer, at time: CMTime, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == acceptedGeneration else { return }
        if renderer.status == .failed { renderer.flush() }
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        if formats[size] == nil {
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
                                                         formatDescriptionOut: &format)
            formats[size] = format
        }
        guard let format = formats[size] else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample { renderer.enqueue(sample) }
    }

    func flush(removingImage: Bool) {
        lock.lock()
        defer { lock.unlock() }
        renderer.flush(removingDisplayedImage: removingImage, completionHandler: nil)
    }
}

/// Renders ASS subtitles ahead of the video and queues them on the video's
/// clock.
///
/// Each step renders the frames due in the next fraction of a second at their
/// exact timestamps, and queues only frames whose pixels libass reports
/// changed. A seek, a selection or setting change, or a cue update that
/// touches the queued span flushes the layer and refills it from the frame on
/// screen.
actor ASSOverlayPresenter {
    /// How the overlay layer's clock relates to the subtitle cue clock.
    enum ClockAxis: Equatable, Sendable {
        /// Aether's software path: the layer runs on the source clock.
        case source
        /// Aether's native path: Aether's axis map converts item time to source time.
        case nativeItem
        /// An AVPlayer path Aether does not mux (remote HLS): item time leads
        /// source time by a measured amount.
        case item(leadSeconds: Double)
    }

    /// Per-step settings, cheap to compare.
    struct Timing: Equatable, Sendable {
        let canvas: ASSSubtitleRenderer.Canvas
        /// Added to a frame's source time to get its cue time: the sidecar
        /// timeline offset minus the user's subtitle delay.
        let cueOffset: Double
        let axis: ClockAxis
        /// Spacing for frames Aether does not report, from the source's
        /// nominal frame rate.
        let frameInterval: Double

        /// Which of Aether's frame reports describe this clock.
        var frameSource: ASSFrameSchedule.Source { axis == .source ? .software : .native }
    }

    struct Step: Sendable {
        var renderedFrames = 0
        /// Rendered frames whose timestamps Aether reported; the rest were
        /// spaced by the nominal frame rate.
        var reportedFrames = 0
        var queuedCanvases = 0
        var renderSeconds: Double = 0
        var slowestRenderSeconds: Double = 0
        var drewSomething = false
    }

    static let lookaheadSeconds: Double = 0.3
    /// A clock that moves this far outside where its rates predict has jumped.
    static let jumpToleranceSeconds: Double = 0.02
    private static let maximumFramesPerStep = 12

    private let schedule: ASSFrameSchedule
    private let axisMap: @Sendable () -> PresentationAxisMap
    private let renderer = ASSSubtitleRenderer()
    private var sink: (any ASSOverlayOutput)?

    private var generation: UInt64?
    /// The newest generation loaded. Loads only move forward, so a step for
    /// an outgoing selection that reaches the actor late cannot undo a newer
    /// one.
    private var newestGeneration: UInt64?
    private var header = ""
    private var fonts: [FontAttachment] = []
    private var cues: [ASSSubtitleRenderer.Cue] = []
    private var cueRevision: UInt64 = 0
    private var appliedCueRevision: UInt64?
    /// The next cue update replaces every event libass has.
    private var replacesEvents = false
    private var timing: Timing?

    /// Presentation time of the last frame rendered for the layer. nil when
    /// the layer is empty and must be refilled from the frame on screen.
    private var renderedThrough: Double?
    /// Whether the newest queued canvas has pixels, so an empty frame after it
    /// must queue a clear canvas.
    private var queuedPixels = false
    /// A snapshot moved libass's idea of the previous frame, so the next
    /// render cannot trust its change report.
    private var forceNextRender = false
    private var lastClock: (host: Double, time: Double, rate: Double)?

    init(schedule: ASSFrameSchedule, axisMap: @escaping @Sendable () -> PresentationAxisMap) {
        self.schedule = schedule
        self.axisMap = axisMap
    }

    /// Shows the overlay on `sink`, or detaches it. A new sink starts empty.
    func attach(_ sink: (any ASSOverlayOutput)?) {
        guard sink !== self.sink else { return }
        self.sink?.flush(removingImage: true)
        self.sink = sink
        restart(keepingImage: false)
    }

    /// Starts a selection: a track, its header, and its fonts. A new
    /// generation clears the overlay; the outgoing frames never show again.
    func load(generation: UInt64, header: String, fonts: [FontAttachment]) {
        if let newestGeneration, generation <= newestGeneration { return }
        newestGeneration = generation
        self.generation = generation
        self.header = header
        self.fonts = fonts
        renderer.removeAllEvents()
        appliedCueRevision = nil
        replacesEvents = false
        sink?.flush(removingImage: true)
        restart(keepingImage: false)
    }

    /// Clears the overlay and forgets the selection.
    func reset() {
        generation = nil
        cues = []
        renderer.removeAllEvents()
        appliedCueRevision = nil
        replacesEvents = false
        sink?.flush(removingImage: true)
        restart(keepingImage: false)
    }

    /// Takes the selection's cues. Revisions only move forward. A replacement
    /// comes from a reload of the track, which may have deleted cues libass
    /// would otherwise keep for a backward seek, so it re-ingests them all.
    func updateCues(_ cues: [ASSSubtitleRenderer.Cue], revision: UInt64, replacing: Bool = false) {
        guard revision >= cueRevision else { return }
        self.cues = cues
        cueRevision = revision
        if replacing {
            replacesEvents = true
            appliedCueRevision = nil
        }
    }

    /// Renders and queues the frames due within the lookahead window, when
    /// `expected` is still the loaded generation. A step for an outgoing
    /// selection that reaches the actor late carries that selection's timing.
    func step(_ timing: Timing, generation expected: UInt64) throws -> Step {
        var report = Step()
        guard let sink, let generation, generation == expected else { return report }
        if timing != self.timing {
            // A new size, delay, or clock redraws the frame on screen; the
            // old canvas stays up until the new one is due.
            let keepsImage = self.timing != nil
            self.timing = timing
            sink.flush(removingImage: !keepsImage)
            restart(keepingImage: keepsImage)
        }
        let hostBefore = Self.hostSeconds()
        let now = sink.now
        let hostAfter = Self.hostSeconds()
        guard now.isFinite else { return report }
        // A read interrupted between the two clocks cannot judge a jump.
        let host = hostAfter - hostBefore < 0.002 ? (hostBefore + hostAfter) / 2 : nil
        if clockJumped(now: now, rate: sink.rate, host: host) {
            sink.flush(removingImage: true)
            restart(keepingImage: false)
        }
        let interval = timing.frameInterval

        let start = cueTime(forPresentation: now, timing) ?? 0
        let end = cueTime(forPresentation: now + Self.lookaheadSeconds, timing) ?? start
        // The frame on screen began up to a frame before `now`.
        if try applyCues(window: (start - interval)...max(start, end) + interval), renderedThrough != nil {
            // Late cues replace the queued frames. Clearing the screen in
            // between would flash the picture without its signs.
            sink.flush(removingImage: false)
            restart(keepingImage: true)
        }

        var frames: [(frame: ASSFrameSchedule.Frame, reported: Bool)] = []
        let horizon = now + Self.lookaheadSeconds
        if let renderedThrough, renderedThrough >= now - 2 * interval {
            frames = upcomingFrames(after: renderedThrough, through: horizon, timing)
        } else {
            // Empty, just started, or fallen more than a frame behind: begin
            // with the frame on screen, which is newer than anything queued.
            // A frame entry from before a seek is not that frame.
            let reported = schedule.frame(atOrBefore: now, in: timing.frameSource)
                .flatMap { now - $0.presentation <= 2 * interval ? $0 : nil }
            let current = reported ?? synthesizedFrame(at: now, timing)
            if let current { frames = [(current, reported != nil)] }
            frames += upcomingFrames(after: current?.presentation ?? now, through: horizon, timing)
        }

        for (frame, reported) in frames.prefix(Self.maximumFramesPerStep) {
            let started = ContinuousClock.now
            let output = renderer.render(time: frame.source + timing.cueOffset, canvas: timing.canvas,
                                         force: renderedThrough == nil || forceNextRender)
            forceNextRender = false
            let seconds = Self.seconds(ContinuousClock.now - started)
            report.renderSeconds += seconds
            report.slowestRenderSeconds = max(report.slowestRenderSeconds, seconds)
            report.renderedFrames += 1
            if reported { report.reportedFrames += 1 }
            switch output {
            case .unavailable:
                // Every canvas is still queued; this frame renders again next step.
                schedule.prune(before: now - 2, in: timing.frameSource)
                return report
            case .unchanged:
                break
            case .empty:
                if queuedPixels {
                    guard let clear = renderer.transparentCanvas() else {
                        // Nothing to clear with yet; this frame renders again next step.
                        forceNextRender = true
                        schedule.prune(before: now - 2, in: timing.frameSource)
                        return report
                    }
                    sink.enqueue(clear, at: frame.stamp, generation: generation)
                    report.queuedCanvases += 1
                }
                queuedPixels = false
            case .frame(let buffer):
                sink.enqueue(buffer, at: frame.stamp, generation: generation)
                report.queuedCanvases += 1
                report.drewSomething = true
                queuedPixels = true
            }
            renderedThrough = frame.presentation
        }
        schedule.prune(before: now - 2, in: timing.frameSource)
        return report
    }

    /// Renders one cue time for tests and diagnostics, queuing nothing.
    func snapshot(cueTime: Double, canvas: ASSSubtitleRenderer.Canvas,
                  generation expected: UInt64) throws -> CVPixelBuffer? {
        guard let generation, generation == expected else { return nil }
        if appliedCueRevision != cueRevision, renderedThrough != nil {
            // Applying cues here hides from the next step whether its queued
            // frames went stale, so refill them as a late cue update would.
            sink?.flush(removingImage: false)
            restart(keepingImage: true)
        }
        _ = try applyCues(window: cueTime...cueTime)
        forceNextRender = true
        if case .frame(let buffer) = renderer.render(time: cueTime, canvas: canvas, force: true) { return buffer }
        return nil
    }

    /// Hands libass any cues it has not seen. Returns whether frames in
    /// `window` (cue clock) may now render differently.
    private func applyCues(window: ClosedRange<Double>) throws -> Bool {
        guard appliedCueRevision != cueRevision else { return false }
        let stale = try renderer.update(header: header, fonts: fonts, cues: cues, window: window,
                                        replacing: replacesEvents)
        appliedCueRevision = cueRevision
        replacesEvents = false
        return stale
    }

    /// Refills from the frame on screen. A kept image may have pixels, so an
    /// empty first frame must still queue a clear canvas.
    private func restart(keepingImage: Bool) {
        renderedThrough = nil
        queuedPixels = keepingImage
        lastClock = nil
    }

    /// Compares the clock with where its rates say it should be. A seek, a
    /// scrub or frame step while paused, or a player item swap moves it
    /// elsewhere. Play and pause change the rate between two steps, so the
    /// clock may be anywhere between what the old and new rates predict, but
    /// it never runs backwards.
    private func clockJumped(now: Double, rate: Double, host: Double?) -> Bool {
        let previous = lastClock
        lastClock = host.map { ($0, now, rate) }
        guard let previous, let host else { return false }
        if min(previous.rate, rate) >= 0, now < previous.time - 0.001 { return true }
        let elapsed = host - previous.host
        let low = previous.time + min(previous.rate, rate) * elapsed
        let high = previous.time + max(previous.rate, rate) * elapsed
        return now < low - Self.jumpToleranceSeconds || now > high + Self.jumpToleranceSeconds
    }

    private static func hostSeconds() -> Double {
        CMClockGetTime(CMClockGetHostTimeClock()).seconds
    }

    private func upcomingFrames(after start: Double, through end: Double,
                                _ timing: Timing) -> [(frame: ASSFrameSchedule.Frame, reported: Bool)] {
        let source = timing.frameSource
        if source == .software || schedule.hasFrames(after: start, in: source) {
            return schedule.frames(after: start, through: end, in: source).map { ($0, true) }
        }
        // Aether reports no frames on this path, or has not reached them yet.
        var frames: [(frame: ASSFrameSchedule.Frame, reported: Bool)] = []
        let interval = timing.frameInterval
        var time = ((start / interval).rounded(.down) + 1) * interval
        // The division can round down a whole step when `start` is on the grid,
        // and a frame's stamp holds its time to the nanosecond.
        if time - start < 1e-6 { time += interval }
        while time <= end {
            if let frame = synthesizedFrame(at: time, timing) { frames.append((frame, false)) }
            time += interval
        }
        return frames
    }

    private func synthesizedFrame(at presentation: Double, _ timing: Timing) -> ASSFrameSchedule.Frame? {
        sourceTime(forPresentation: presentation, timing).map {
            ASSFrameSchedule.Frame(presentation: presentation, source: $0)
        }
    }

    private func cueTime(forPresentation time: Double, _ timing: Timing) -> Double? {
        sourceTime(forPresentation: time, timing).map { $0 + timing.cueOffset }
    }

    private func sourceTime(forPresentation time: Double, _ timing: Timing) -> Double? {
        switch timing.axis {
        case .source: time
        case .nativeItem: axisMap().sourceSeconds(forItemSeconds: time)
        case .item(let lead): time - lead
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
