//
//  PlayerLog.swift
//  Silo (iOS + tvOS)
//
//  Single emission point for `[CMP-…]` player traces: stdout for
//  `devicectl --console`, plus the diagnostics ring.
//

import Foundation

@inline(__always)
func cmpLog(_ message: String) {
    print(message)
    #if os(iOS) || os(tvOS)
    // Essential tier: the line enters the diagnostics ring whenever capture is
    // on, so crash bundles keep the player trace without the Debug Logging toggle.
    DiagTrace.log(
        .essential,
        level: .info,
        category: .playback,
        tag: "CMP",
        message: message
    )
    #endif
}
