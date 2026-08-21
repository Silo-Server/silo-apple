import Foundation

/// A load-time segment plan for the SiloPlayer VOD loopback: every segment
/// boundary is decided once, before the first byte is muxed, so the local
/// playlist can advertise the whole title up front and AVPlayer sees a
/// complete VOD asset instead of a growing EVENT playlist
/// (see `docs/tvos-player/03-dolby-vision-and-avplayer-route.md`).
///
/// `boundaries` are source-PTS values in the video stream's time base and
/// carry `segmentCount + 1` entries — the final entry is the end of the last
/// segment, not the start of another. `startSeconds` is the same fence on the
/// 0-based playlist axis. Segment 0 anchors at the first indexed keyframe,
/// never at PTS 0: a title whose content starts late would otherwise
/// advertise leading segments the producer can never emit, leaving AVPlayer's
/// first fetch permanently out of range.
struct LoopbackSegmentPlan: Equatable {
    let boundaries: [Int64]
    let startSeconds: [Double]
    /// The plan anchor (first boundary) on the source clock, in seconds.
    /// `sourceStartSeconds(ofSegment:)` maps a plan segment back onto the
    /// source axis for restarted-producer demuxer seeks.
    let anchorSourceSeconds: Double
    let usedKeyframeIndex: Bool

    static let defaultTargetSegmentDurationSeconds = 4.0

    var segmentCount: Int { max(0, boundaries.count - 1) }
    var totalDurationSeconds: Double { startSeconds.last ?? 0 }

    func duration(ofSegment index: Int) -> Double {
        guard index >= 0, index < segmentCount else { return 0 }
        return startSeconds[index + 1] - startSeconds[index]
    }

    /// Where a plan segment starts on the source clock (for a restarted
    /// producer's demuxer seek). Clamped into the plan's real segments.
    func sourceStartSeconds(ofSegment index: Int) -> Double {
        guard segmentCount > 0 else { return anchorSourceSeconds }
        let clamped = max(0, min(index, segmentCount - 1))
        return anchorSourceSeconds + startSeconds[clamped]
    }

    /// Maps a 0-based playlist time onto a segment index. Out-of-range times
    /// clamp (negative → 0, past-the-end → last segment) because the plan's
    /// final boundary is an end fence, not a fetchable segment.
    func segmentIndex(forPlaylistSeconds seconds: Double) -> Int {
        guard segmentCount > 0 else { return 0 }
        if seconds <= 0 { return 0 }
        var index = 0
        while index + 1 < segmentCount, startSeconds[index + 1] <= seconds {
            index += 1
        }
        return index
    }

    /// A copy of the plan with segments `keep+1 ... through` merged into
    /// segment `keep`: their start fences are removed, so segment `keep`
    /// spans from its own boundary to segment `through`'s end fence. Used by
    /// the resume-anchor bitstream validation — when a plan boundary's frame
    /// turns out not to be a true random-access point, the segment AVPlayer
    /// cold-decodes on resume must instead open at the nearest earlier
    /// boundary that is one (the playlist advertises
    /// EXT-X-INDEPENDENT-SEGMENTS, so every advertised segment start is a
    /// decode-start promise).
    func coalescingSegments(after keep: Int, through last: Int) -> LoopbackSegmentPlan {
        guard keep >= 0, last > keep, last < segmentCount else { return self }
        var mergedBoundaries = boundaries
        var mergedStartSeconds = startSeconds
        mergedBoundaries.removeSubrange((keep + 1)...last)
        mergedStartSeconds.removeSubrange((keep + 1)...last)
        return LoopbackSegmentPlan(
            boundaries: mergedBoundaries,
            startSeconds: mergedStartSeconds,
            anchorSourceSeconds: anchorSourceSeconds,
            usedKeyframeIndex: usedKeyframeIndex
        )
    }

    /// Whether a scanned keyframe index is dense and wide enough to plan
    /// keyframe-aligned segments from, or whether the plan must fall back to
    /// a uniform stride. Two witnesses, both required:
    ///
    /// - gap: the largest gap stays under `max(4 × target, 30 s)`. A
    ///   clustered MPEG-TS index can gap by thousands of seconds; trusting it
    ///   plans one enormous segment the muxer buffers whole in RAM before its
    ///   first cut. The span from the LAST indexed keyframe to the end of the
    ///   title counts as a gap too: `buildKeyframePlan` closes the final
    ///   segment at the source's end fence, so an index that covers 0–10 s of
    ///   a 7200 s title plans [0, 4, 8, 7200] — the same title-sized segment
    ///   an interior gap would produce, arrived at from the other end.
    /// - coverage: the first→last keyframe span reaches at least one target
    ///   duration. A remote MKV whose Cues tail read failed leaves only the
    ///   open-time keyframes bunched at the head — gaps are tiny (the gap
    ///   witness passes) yet the keyframe plan would degenerate to a single
    ///   whole-file segment. Coverage is measured between keyframes, so a
    ///   dense index that simply stops early is unaffected.
    static func keyframeIndexIsTrustworthy(
        keyframePts: [Int64],
        timeBaseNum: Int32,
        timeBaseDen: Int32,
        sourceDurationSeconds: Double,
        targetSegmentDurationSeconds: Double = defaultTargetSegmentDurationSeconds
    ) -> Bool {
        guard keyframePts.count >= 2,
              sourceDurationSeconds > 0,
              timeBaseNum > 0, timeBaseDen > 0 else {
            return false
        }
        let secondsPerTick = Double(timeBaseNum) / Double(timeBaseDen)
        let sorted = keyframePts.sorted()

        let coverage = Double(sorted[sorted.count - 1] - sorted[0]) * secondsPerTick
        guard coverage >= targetSegmentDurationSeconds else { return false }

        let maxTrustedGapSeconds = max(targetSegmentDurationSeconds * 4, 30)
        var previous = sorted[0]
        for pts in sorted.dropFirst() {
            if Double(pts - previous) * secondsPerTick > maxTrustedGapSeconds {
                return false
            }
            previous = pts
        }
        // The tail: last indexed keyframe → the end fence the keyframe plan
        // would close on. Measured on the same axis the plan uses (the anchor
        // is the first keyframe, the fence is anchor + source duration), so
        // this is exactly `sourceDurationSeconds - coverage`.
        if sourceDurationSeconds - coverage > maxTrustedGapSeconds {
            return false
        }
        return true
    }

    static func build(
        keyframePts: [Int64],
        timeBaseNum: Int32,
        timeBaseDen: Int32,
        sourceDurationSeconds: Double,
        targetSegmentDurationSeconds: Double = defaultTargetSegmentDurationSeconds
    ) -> LoopbackSegmentPlan {
        let target = max(0.5, targetSegmentDurationSeconds)
        if keyframeIndexIsTrustworthy(
            keyframePts: keyframePts,
            timeBaseNum: timeBaseNum,
            timeBaseDen: timeBaseDen,
            sourceDurationSeconds: sourceDurationSeconds,
            targetSegmentDurationSeconds: target
        ) {
            return buildKeyframePlan(
                keyframePts: keyframePts,
                timeBaseNum: timeBaseNum,
                timeBaseDen: timeBaseDen,
                sourceDurationSeconds: sourceDurationSeconds,
                targetSegmentDurationSeconds: target
            )
        }
        return buildUniformPlan(
            keyframePts: keyframePts,
            timeBaseNum: timeBaseNum,
            timeBaseDen: timeBaseDen,
            sourceDurationSeconds: sourceDurationSeconds,
            targetSegmentDurationSeconds: target
        )
    }

    /// Mirrors the ffmpeg `hls` muxer's cut rule: segment N ends at the first
    /// keyframe whose offset from the plan anchor reaches `(N+1) × target`.
    /// Thresholds are absolute from the anchor, not relative to the previous
    /// cut, so irregular GOPs cannot accumulate drift.
    private static func buildKeyframePlan(
        keyframePts: [Int64],
        timeBaseNum: Int32,
        timeBaseDen: Int32,
        sourceDurationSeconds: Double,
        targetSegmentDurationSeconds: Double
    ) -> LoopbackSegmentPlan {
        let secondsPerTick = Double(timeBaseNum) / Double(timeBaseDen)
        let sorted = keyframePts.sorted()
        let anchor = sorted[0]
        let endPts = anchor + ticks(
            forSeconds: sourceDurationSeconds,
            timeBaseNum: timeBaseNum,
            timeBaseDen: timeBaseDen
        )

        var boundaries: [Int64] = [anchor]
        var nextThreshold = targetSegmentDurationSeconds
        for pts in sorted.dropFirst() {
            let offsetSeconds = Double(pts - anchor) * secondsPerTick
            if offsetSeconds >= nextThreshold, pts < endPts {
                boundaries.append(pts)
                // Absolute threshold: skip forward past any thresholds this
                // keyframe already crossed (sparse-GOP sources).
                while offsetSeconds >= nextThreshold {
                    nextThreshold += targetSegmentDurationSeconds
                }
            }
        }
        boundaries.append(max(endPts, boundaries[boundaries.count - 1] + 1))

        let startSeconds = boundaries.map {
            Double($0 - anchor) * secondsPerTick
        }
        return LoopbackSegmentPlan(
            boundaries: boundaries,
            startSeconds: startSeconds,
            anchorSourceSeconds: Double(anchor) * secondsPerTick,
            usedKeyframeIndex: true
        )
    }

    /// Fallback for untrustworthy indices: a fixed stride anchored at the
    /// first indexed keyframe (or PTS 0 when nothing was indexed at all).
    private static func buildUniformPlan(
        keyframePts: [Int64],
        timeBaseNum: Int32,
        timeBaseDen: Int32,
        sourceDurationSeconds: Double,
        targetSegmentDurationSeconds: Double
    ) -> LoopbackSegmentPlan {
        let duration = max(targetSegmentDurationSeconds, sourceDurationSeconds)
        let anchor = keyframePts.min() ?? 0
        let count = max(1, Int((duration / targetSegmentDurationSeconds).rounded(.up)))

        var boundaries: [Int64] = []
        var startSeconds: [Double] = []
        boundaries.reserveCapacity(count + 1)
        startSeconds.reserveCapacity(count + 1)
        for index in 0..<count {
            let offset = Double(index) * targetSegmentDurationSeconds
            boundaries.append(anchor + ticks(
                forSeconds: offset,
                timeBaseNum: timeBaseNum,
                timeBaseDen: timeBaseDen
            ))
            startSeconds.append(offset)
        }
        boundaries.append(anchor + ticks(
            forSeconds: duration,
            timeBaseNum: timeBaseNum,
            timeBaseDen: timeBaseDen
        ))
        startSeconds.append(duration)

        return LoopbackSegmentPlan(
            boundaries: boundaries,
            startSeconds: startSeconds,
            anchorSourceSeconds: Double(anchor) * Double(timeBaseNum) / Double(max(1, timeBaseDen)),
            usedKeyframeIndex: false
        )
    }

    private static func ticks(
        forSeconds seconds: Double,
        timeBaseNum: Int32,
        timeBaseDen: Int32
    ) -> Int64 {
        guard timeBaseNum > 0, timeBaseDen > 0 else { return 0 }
        return Int64((seconds * Double(timeBaseDen) / Double(timeBaseNum)).rounded())
    }
}
