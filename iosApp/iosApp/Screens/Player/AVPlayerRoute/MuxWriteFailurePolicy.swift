//
//  MuxWriteFailurePolicy.swift
//  Continuum
//
//  Pure accounting for `av_interleaved_write_frame` failures in
//  DVSegmentWriter. Two abort conditions:
//
//    1. A consecutive burst (`maxConsecutive`) — the mux stopped
//       producing valid output outright.
//    2. Persistent flapping (`maxOutstanding`) — failures that keep
//       arriving with only short clean runs between them. A plain
//       consecutive counter reset on every success let a
//       fail-4/succeed-1 pattern drop packets forever while the output
//       silently corrupted; here each failure stays "outstanding" until
//       a sustained clean run (`successesToForgiveOne` writes, roughly
//       one second of A/V packets) retires it.
//
//  Sparse one-off failures (the fmp4 muxer's brief reorder bursts during
//  keyframe boundary realignment) are forgiven by the clean run that
//  follows them and never abort. No I/O, no locking — testable in
//  isolation; DVSegmentWriter owns one instance per session.
//

struct MuxWriteFailurePolicy {
    private(set) var consecutiveFailures = 0
    private(set) var outstandingFailures = 0
    private var successesSinceLastForgiveness = 0

    /// Consecutive-burst abort threshold. Tuned to tolerate the brief
    /// reorder bursts the fmp4 muxer occasionally emits during keyframe
    /// boundary realignment without missing a genuinely broken stream.
    let maxConsecutive: Int
    /// Flapping abort threshold: total not-yet-forgiven failures.
    let maxOutstanding: Int
    /// Clean writes required to retire one outstanding failure.
    let successesToForgiveOne: Int

    init(
        maxConsecutive: Int = 5,
        maxOutstanding: Int = 12,
        successesToForgiveOne: Int = 48
    ) {
        self.maxConsecutive = maxConsecutive
        self.maxOutstanding = maxOutstanding
        self.successesToForgiveOne = successesToForgiveOne
    }

    /// Record a failed write. Returns true when the mux should abort.
    mutating func recordFailure() -> Bool {
        consecutiveFailures += 1
        outstandingFailures += 1
        successesSinceLastForgiveness = 0
        return consecutiveFailures >= maxConsecutive
            || outstandingFailures >= maxOutstanding
    }

    /// Record a successful write.
    mutating func recordSuccess() {
        consecutiveFailures = 0
        guard outstandingFailures > 0 else { return }
        successesSinceLastForgiveness += 1
        if successesSinceLastForgiveness >= successesToForgiveOne {
            outstandingFailures -= 1
            successesSinceLastForgiveness = 0
        }
    }
}
