import Foundation

/// Classifies a negative `av_read_frame` result at the loopback writer's
/// ingest edge: genuine end-of-content versus a source that died early (an
/// origin outage truncating the proxied body, an `rw_timeout` expiry, a
/// half-delivered range). The writer previously treated every negative code
/// as clean EOF and finalized the remux as a complete VOD — a truncated
/// movie reported as success
/// (docs/superpowers/plans/2026-07-07-playback-continuity-client.md, B2a).
///
/// The verdict is deliberately conservative: any signal that the content is
/// substantially complete — bytes consumed to (near) the known file size, or
/// the VOD plan axis reached (near) its end fence — finalizes exactly as
/// before. Only an ending that is clearly short on every available signal is
/// declared premature. When no signal is available at all, the legacy
/// clean-EOF behavior is preserved.
enum LoopbackIngestEndPolicy {
    enum Verdict: Equatable {
        case finished
        case prematureSourceEnd(shortfallBytes: Int64?, shortfallSeconds: Double?)
    }

    /// AVERROR_EXIT ('EXIT'): the interrupt callback aborted the read. That
    /// is cancellation/teardown, never a source-health verdict.
    static let avErrorExit = -Int32(bitPattern: 0x54495845)

    /// Trailing container data the demuxer legitimately never reads (Matroska
    /// cues/tags/attachments after the last cluster). An ending within this
    /// distance of the file size counts as complete.
    static let byteShortfallToleranceFloor: Int64 = 8 * 1024 * 1024
    /// Fractional variant of the same tolerance for very large files, where
    /// trailing index data scales with content size.
    static let byteShortfallToleranceFraction = 0.02

    /// Plan-axis slack: the reached position is the *start* fence of the
    /// segment being cut, so a genuine EOF sits one segment short of the end
    /// fence. Sized to cover coalesced (keyframe-sparse) closing segments.
    static let planShortfallToleranceSeconds = 30.0

    /// - Parameters:
    ///   - readResult: the negative `av_read_frame` return code.
    ///   - bytePosition: current input IO position (`avio_seek(pb, 0,
    ///     SEEK_CUR)`), nil when unavailable.
    ///   - fileSizeBytes: known input size (`avio_size`), nil when the
    ///     transport never learned a total.
    ///   - reachedPlanSeconds: plan-axis position reached by the mux (start
    ///     fence of the segment currently being cut), nil without a VOD plan.
    ///   - plannedTotalSeconds: the plan's end fence, nil without a VOD plan.
    ///   - deadlineAborted: the interrupt token aborted this read on its span
    ///     deadline (wedged read or exhausted outage park). The resulting
    ///     AVERROR_EXIT is a source failure, not a cancellation, so it must
    ///     go through the completeness checks like any other error.
    static func classify(
        readResult: Int32,
        bytePosition: Int64?,
        fileSizeBytes: Int64?,
        reachedPlanSeconds: Double?,
        plannedTotalSeconds: Double?,
        deadlineAborted: Bool = false
    ) -> Verdict {
        if readResult == avErrorExit, !deadlineAborted {
            return .finished
        }

        var byteShortfall: Int64?
        var bytesComplete: Bool?
        if let fileSizeBytes, fileSizeBytes > 0, let bytePosition, bytePosition >= 0 {
            let tolerance = max(
                byteShortfallToleranceFloor,
                Int64(Double(fileSizeBytes) * byteShortfallToleranceFraction)
            )
            let shortfall = fileSizeBytes - bytePosition
            byteShortfall = max(0, shortfall)
            bytesComplete = shortfall <= tolerance
        }

        var planShortfall: Double?
        var planComplete: Bool?
        if let plannedTotalSeconds, plannedTotalSeconds > 0,
           let reachedPlanSeconds, reachedPlanSeconds >= 0 {
            let shortfall = plannedTotalSeconds - reachedPlanSeconds
            planShortfall = max(0, shortfall)
            planComplete = shortfall <= planShortfallToleranceSeconds
        }

        // Either signal declaring the content complete wins: bad container
        // metadata (duration overstating the media) and unread trailing data
        // must keep finalizing cleanly, exactly as before this policy.
        if planComplete == true || bytesComplete == true {
            return .finished
        }
        if bytesComplete == false || planComplete == false {
            return .prematureSourceEnd(
                shortfallBytes: byteShortfall,
                shortfallSeconds: planShortfall
            )
        }
        // No usable signal: preserve the legacy treat-as-EOF behavior.
        return .finished
    }
}
