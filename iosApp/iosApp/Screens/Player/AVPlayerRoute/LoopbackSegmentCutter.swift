import Foundation

/// Decode-order, keyframe-gated segment routing for the SiloPlayer VOD
/// loopback: a new segment opens only at the keyframe whose *presentation*
/// timestamp has reached the next plan boundary
/// (docs/tvos-player/2026-07-03-siloplayer-loopback-primary-plan.md, M2).
///
/// Routing by the IRAP's PTS rather than by packet DTS matters under B-frame
/// reorder: a keyframe's DTS trails its PTS, so DTS-keyed routing drops the
/// IRAP into the previous segment and the next segment starts mid-GOP,
/// decode-dependent on its predecessor — a fresh decode at that boundary
/// (rebuffer recovery) surfaces as transient blocky corruption. Open-GOP RASL
/// leading pictures arrive after their CRA in decode order with PTS before
/// it; because only keyframes advance the cursor, they stay in the CRA's
/// segment, so every segment opens on a clean random-access point.
struct LoopbackSegmentCutter {
    /// Segment-start fences in source PTS: `boundaries[i]` starts segment
    /// `baseIndex + i`. The count is `segmentCount + 1` — the final entry is
    /// the end fence, not a startable segment, so a late keyframe clamps
    /// into the last real segment instead of advancing past the plan.
    let boundaries: [Int64]
    /// Plan index of the first segment this producer session emits; a
    /// restarted producer passes the restart segment here.
    let baseIndex: Int
    private(set) var current: Int

    init(boundaries: [Int64], baseIndex: Int = 0) {
        self.boundaries = boundaries
        self.baseIndex = baseIndex
        self.current = baseIndex
    }

    /// Routes one video packet (in decode order) to the segment it belongs
    /// to. Non-keyframes and NOPTS packets never advance the cursor; a
    /// keyframe that jumped past several boundaries advances past all of
    /// them in one step (sparse-GOP sources must not leave empty segments
    /// between cuts).
    mutating func index(pts: Int64, isKeyframe: Bool) -> Int {
        guard isKeyframe, pts != Int64.min else { return current }
        var nextLocal = (current - baseIndex) + 1
        while nextLocal < boundaries.count - 1, pts >= boundaries[nextLocal] {
            current += 1
            nextLocal += 1
        }
        return current
    }
}
