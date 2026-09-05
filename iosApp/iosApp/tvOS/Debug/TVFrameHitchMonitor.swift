#if os(tvOS)
import Foundation
import QuartzCore
import os

/// Opt-in main-thread frame hitch logger for on-device performance work.
///
/// Enabled only when the process is launched with the `-perfHitchLog`
/// argument (for example through `devicectl device process launch`), so a
/// normal launch pays nothing. A `CADisplayLink` on the main run loop flags a
/// frame as a hitch when either the callback cadence skipped a vsync (the
/// main thread was blocked, so intermediate callbacks were dropped) or the
/// callback itself ran past the frame's display deadline. It prints a
/// ten-second summary with the hitch count, total late time, and the worst
/// single hitch. Lines go to stderr so a console-attached launch shows them
/// without unified-log filtering, and to the `perf.hitch` os_log category.
///
/// This measures main-thread hitches only. Render-server commit hitches need
/// Instruments' Animation Hitches template, which requires a wired or
/// Xcode-paired connection this monitor is meant to stand in for.
@MainActor
final class TVFrameHitchMonitor {
    static let shared = TVFrameHitchMonitor()

    private static let launchArgument = "-perfHitchLog"
    private static let summaryInterval: CFTimeInterval = 10

    private let logger = Logger(subsystem: "org.siloserver.silo", category: "perf.hitch")
    private let startTime = CACurrentMediaTime()
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    private var summaryStart: CFTimeInterval = 0
    private var frameCount = 0
    private var hitchCount = 0
    private var lateTotal: CFTimeInterval = 0
    private var lateMax: CFTimeInterval = 0

    static func installIfRequested() {
        guard CommandLine.arguments.contains(launchArgument) else { return }
        shared.start()
    }

    private func start() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        emit("monitor started")
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { lastTimestamp = now }
        guard lastTimestamp > 0 else {
            summaryStart = now
            return
        }

        // Derive the frame period from the link's own schedule so adaptive
        // refresh rates are handled; `duration` is undefined before the
        // first callback.
        let scheduled = link.targetTimestamp - now
        let frameDuration = scheduled > 0 ? scheduled : 1.0 / 60.0
        let interval = now - lastTimestamp
        frameCount += 1

        // Two ways to miss a frame. A blocked main thread drops callbacks,
        // so consecutive timestamps land more than one period apart. A
        // callback that starts after its target display time has already
        // lost that frame even when the cadence looks regular. Report the
        // larger of the two; jitter under half a frame is display-link noise.
        let skipped = interval - frameDuration
        let overDeadline = CACurrentMediaTime() - link.targetTimestamp
        let late = max(skipped, overDeadline)
        if late > frameDuration * 0.5 {
            hitchCount += 1
            lateTotal += late
            lateMax = max(lateMax, late)
            emit(String(format: "hitch %.1f ms late (interval %.1f ms)", late * 1000, interval * 1000))
        }

        if now - summaryStart >= Self.summaryInterval {
            emit(String(
                format: "summary %ds: %d frames, %d hitches, %.1f ms late total, worst %.1f ms",
                Int(now - summaryStart), frameCount, hitchCount, lateTotal * 1000, lateMax * 1000
            ))
            summaryStart = now
            frameCount = 0
            hitchCount = 0
            lateTotal = 0
            lateMax = 0
        }
    }

    private func emit(_ message: String) {
        // Seconds since the monitor started, so hitches can be lined up with
        // launch-phase work in the same console capture.
        let stamped = String(format: "t+%.1fs %@", CACurrentMediaTime() - startTime, message)
        logger.notice("\(stamped, privacy: .public)")
        FileHandle.standardError.write(Data("[perf.hitch] \(stamped)\n".utf8))
    }
}
#endif
