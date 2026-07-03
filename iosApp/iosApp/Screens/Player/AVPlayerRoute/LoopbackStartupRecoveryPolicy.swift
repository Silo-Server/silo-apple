//
//  LoopbackStartupRecoveryPolicy.swift
//
//  Pure decision core for the local-loopback startup watchdog in
//  `AVPlayerBackend`. Replaces the old fixed 12 s readiness timeout with a
//  stall detector: elapsed wall time is not evidence of a wedge — only
//  frozen forward progress is. A slow-but-healthy AVPlayer keeps issuing
//  loopback HTTP requests every segment; a dead loader pipeline stops
//  requesting within seconds. The watchdog tick feeds both signals here and
//  acts on the verdict.
//
//  The escalation ladder itself (nudge seek → in-place item reload → route
//  fallback) lives in the backend; this policy only decides *when* to take
//  the next step.

import Foundation

enum LoopbackStartupRecoveryPolicy {
    enum Verdict: Equatable {
        /// Startup is progressing (or externally held up) — do nothing.
        case wait
        /// Forward progress has been frozen for the full stall window —
        /// take the next recovery step on the ladder.
        case escalate
        /// The absolute backstop elapsed without the item ever becoming
        /// ready — give up regardless of progress so a pathological
        /// "fetches forever, never ready" consumer cannot spin unbounded.
        case failBackstop
    }

    static func verdict(
        secondsSinceProgress: Double,
        secondsSinceStart: Double,
        displayModeSwitchInProgress: Bool,
        stallWindow: Double,
        absoluteBackstop: Double
    ) -> Verdict {
        if secondsSinceStart >= absoluteBackstop {
            return .failBackstop
        }
        // An HDMI display-mode switch (e.g. HDR → Dolby Vision) stalls
        // AVFoundation readiness for several seconds through no fault of
        // the loopback pipeline. Hold the ladder while the switch runs.
        if displayModeSwitchInProgress {
            return .wait
        }
        if secondsSinceProgress < stallWindow {
            return .wait
        }
        return .escalate
    }
}
