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
func cmpLog(_ message: @autoclosure () -> String) {
    let rendered = message()
    print(rendered)
    #if os(iOS) || os(tvOS)
    DiagLog.i(.playback, "CMP", rendered)
    #endif
}
