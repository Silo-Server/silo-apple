//
//  PlaybackEndPolicy.swift
//  Continuum (iOS + tvOS)
//
//  Pure decision for "playback has actually finished" after the demuxer
//  reports end of input. The previous rule was clock-based only —
//  complete when the clock came within 0.5 s of the container duration —
//  which truncated the final half-second of audio while it was still
//  queued, fired early on containers whose duration overstates nothing
//  but whose tail is long, and completed immediately on unknown-duration
//  sources even with a full pipeline still draining.
//
//  The primary signal is now the pipeline itself: input EOF plus every
//  stage drained (packet queues, decoded-frame queue, audio chunks). The
//  clock-past-duration check remains only as a fallback for a drain
//  signal that wedges (e.g. a stuck tail frame), so completion can never
//  regress behind the old behavior's worst case.
//
//  No I/O, no locking — testable in isolation. PlayerCore feeds it from
//  the throttled time observer, the input-EOF notification, and the
//  100 ms buffering monitor (the last render produces no further time
//  callbacks, so a timer must drive the final check).
//

import Foundation

enum PlaybackEndPolicy {

    struct Inputs {
        /// The demux loop delivered its EOF sentinel for this generation.
        let reachedInputEOF: Bool
        /// Current playback clock, seconds.
        let observedSeconds: Double
        /// Container-reported duration; `<= 0` or non-finite = unknown.
        let durationSeconds: Double
        let audioPacketsQueued: Int
        let videoPacketsQueued: Int
        let decodedVideoFramesQueued: Int
        let audioChunksQueued: Int
    }

    static func shouldComplete(_ inputs: Inputs) -> Bool {
        guard inputs.reachedInputEOF else { return false }

        let drained = inputs.audioPacketsQueued == 0
            && inputs.videoPacketsQueued == 0
            && inputs.decodedVideoFramesQueued == 0
            && inputs.audioChunksQueued == 0
        if drained { return true }

        // Fallback: the pipeline still holds data but the clock has played
        // through the advertised duration — trust the clock over a drain
        // signal that may be wedged on a stuck tail sample.
        guard inputs.observedSeconds.isFinite,
              inputs.durationSeconds.isFinite,
              inputs.durationSeconds > 0 else { return false }
        return inputs.observedSeconds >= inputs.durationSeconds
    }
}
