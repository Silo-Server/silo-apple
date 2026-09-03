#if os(tvOS)
import Foundation
import QuartzCore
import os

/// Opt-in main-thread frame hitch logger for on-device performance work.
///
/// Enabled only when the process is launched with the `-perfHitchLog`
/// argument (for example through `devicectl device process launch`), so a
/// normal launch pays nothing. A `CADisplayLink` on the main run loop
/// records every callback that arrives more than half a frame late — the
/// signature of the main thread being busy through a vsync — and prints a
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

    private let logger = Logger(subsystem: "com.continuum.app", category: "perf.hitch")
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

        let frameDuration = link.duration > 0 ? link.duration : 1.0 / 60.0
        let interval = now - lastTimestamp
        frameCount += 1

        // Late by more than half a frame: the callback missed at least one
        // vsync. Small jitter under that threshold is display-link noise.
        let late = interval - frameDuration
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
        logger.notice("\(message, privacy: .public)")
        FileHandle.standardError.write(Data("[perf.hitch] \(message)\n".utf8))
    }
}
#endif
