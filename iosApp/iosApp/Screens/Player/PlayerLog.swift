//
//  PlayerLog.swift
//  Continuum (iOS + tvOS)
//
//  Single emission point for `[CMP-…]` player-pipeline trace lines.
//
//  The pipeline previously fanned out each diagnostic to both
//  `Logger.info(...)` (Apple unified logging) and `print(...)` (stdout) so
//  that tvOS's `devicectl --console`, which only sees stdout, could observe
//  the trace alongside iOS's Console.app, which observes both. The side
//  effect on iPhone capture was every `[CMP-…]` line appearing twice —
//  often with subtly different formatting (e.g. `startTime=0.0` vs
//  `startTime=0.000000`) which doubled the log volume during a session.
//
//  `cmpLog` keeps stdout as the live troubleshooting surface and also feeds
//  the diagnostics ring through `DiagLog`, so crash bundles carry the same
//  curated player trace without relying only on OSLog harvesting.
//

import Foundation

@inline(__always)
func cmpLog(_ message: @autoclosure () -> String, verbose: Bool = false) {
    let rendered = message()
    print(rendered)
    #if os(iOS) || os(tvOS)
    // Verbose, high-frequency traces (e.g. the 1 Hz `[CMP-DIAG]` telemetry)
    // only enter the diagnostics ring when the user has opted into Debug
    // Logging. Errors and lifecycle lines are always kept so crash bundles
    // retain the essential player context regardless of the toggle. stdout
    // always receives the line for live `devicectl --console` troubleshooting.
    DiagTrace.log(
        verbose ? .verbose : .essential,
        level: .info,
        category: .playback,
        tag: "CMP",
        message: rendered
    )
    #endif
}

#if os(iOS) || os(tvOS)
/// Retained as the player-facing spelling of the shared tiering predicate; the
/// logic lives in `DiagTrace` so playback, focus, network, and lifecycle
/// instrumentation all make the same decision.
func shouldCaptureCMPLog(
    verbose: Bool,
    debugLoggingEnabled: Bool,
    captureEnabled: Bool
) -> Bool {
    DiagTrace.shouldCapture(
        verbose ? .verbose : .essential,
        debugLoggingEnabled: debugLoggingEnabled,
        captureEnabled: captureEnabled
    )
}
#endif
