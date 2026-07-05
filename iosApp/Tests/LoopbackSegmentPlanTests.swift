import XCTest
@testable import Silo

final class LoopbackSegmentPlanTests: XCTestCase {
    // 90 kHz MPEG time base used throughout: 1 tick = 1/90000 s.
    private let num: Int32 = 1
    private let den: Int32 = 90000

    private func pts(_ seconds: Double) -> Int64 {
        Int64((seconds * 90000).rounded())
    }

    // MARK: - Trust gates

    func testClusteredTSIndexFailsGapWitness() {
        // A clustered MPEG-TS index: keyframes at the head, then one
        // thousands of seconds later. Largest gap far exceeds max(16, 30) s.
        let keyframes = [pts(0), pts(2), pts(4), pts(5000)]
        XCTAssertFalse(LoopbackSegmentPlan.keyframeIndexIsTrustworthy(
            keyframePts: keyframes,
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 6000
        ))
    }

    func testBunchedHeadKeyframesFailCoverageWitness() {
        // The failed-Cues shape: only open-time keyframes survive, bunched in
        // the first two seconds of a two-hour title. Gaps are tiny (gap
        // witness passes) but coverage is under one target duration.
        let keyframes = [pts(0), pts(0.5), pts(1.0), pts(2.0)]
        XCTAssertFalse(LoopbackSegmentPlan.keyframeIndexIsTrustworthy(
            keyframePts: keyframes,
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 7200
        ))
    }

    func testCoverageBoundaryIsInclusive() {
        // Exactly one target duration of coverage is trustworthy; a hair
        // under is not.
        let exactly = [pts(0), pts(1), pts(2), pts(3), pts(4.0)]
        XCTAssertTrue(LoopbackSegmentPlan.keyframeIndexIsTrustworthy(
            keyframePts: exactly,
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 100
        ))

        let justUnder = [pts(0), pts(1), pts(2), pts(3), pts(3.999)]
        XCTAssertFalse(LoopbackSegmentPlan.keyframeIndexIsTrustworthy(
            keyframePts: justUnder,
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 100
        ))
    }

    func testGapBoundaryIsInclusive() {
        // With target 4.0 the trusted-gap cap is max(16, 30) = 30 s.
        let exactly = [pts(0), pts(30), pts(60)]
        XCTAssertTrue(LoopbackSegmentPlan.keyframeIndexIsTrustworthy(
            keyframePts: exactly,
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 100
        ))

        let justOver = [pts(0), pts(30.001), pts(60)]
        XCTAssertFalse(LoopbackSegmentPlan.keyframeIndexIsTrustworthy(
            keyframePts: justOver,
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 100
        ))
    }

    func testTailGapToEOFIsNotCounted() {
        // Coverage and gaps are measured between keyframes only. A dense
        // index that stops well before the end of the title stays trusted —
        // the tail is the producer's problem, not the planner's.
        let keyframes = (0...10).map { pts(Double($0)) }
        XCTAssertTrue(LoopbackSegmentPlan.keyframeIndexIsTrustworthy(
            keyframePts: keyframes,
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 7200
        ))
    }

    func testDegenerateInputsAreUntrusted() {
        XCTAssertFalse(LoopbackSegmentPlan.keyframeIndexIsTrustworthy(
            keyframePts: [pts(0)],
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 100
        ))
        XCTAssertFalse(LoopbackSegmentPlan.keyframeIndexIsTrustworthy(
            keyframePts: [pts(0), pts(10)],
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 0
        ))
        XCTAssertFalse(LoopbackSegmentPlan.keyframeIndexIsTrustworthy(
            keyframePts: [pts(0), pts(10)],
            timeBaseNum: 0, timeBaseDen: den,
            sourceDurationSeconds: 100
        ))
    }

    // MARK: - Keyframe plan

    func testKeyframePlanCutsAtAbsoluteThresholds() {
        // Keyframes every 2 s over 20 s, target 4 s: boundaries land on the
        // keyframes at 4, 8, 12, 16; the final entry is the 20 s end fence.
        let keyframes = stride(from: 0.0, through: 18.0, by: 2.0).map(pts)
        let plan = LoopbackSegmentPlan.build(
            keyframePts: keyframes,
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 20
        )
        XCTAssertTrue(plan.usedKeyframeIndex)
        XCTAssertEqual(plan.segmentCount, 5)
        XCTAssertEqual(plan.boundaries, [
            pts(0), pts(4), pts(8), pts(12), pts(16), pts(20),
        ])
        XCTAssertEqual(plan.duration(ofSegment: 0), 4.0, accuracy: 0.001)
        XCTAssertEqual(plan.totalDurationSeconds, 20.0, accuracy: 0.001)
    }

    func testIrregularGOPUsesAbsoluteNotRelativeThresholds() {
        // A 3.9 s GOP then regular 4 s GOPs. Relative thresholds would drift
        // (next cut at 3.9 + 4 = 7.9 measured from the previous cut);
        // absolute thresholds cut at the first keyframe ≥ 8.0 from anchor.
        let keyframes = [pts(0), pts(3.9), pts(7.9), pts(8.2), pts(12.2)]
        let plan = LoopbackSegmentPlan.build(
            keyframePts: keyframes,
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 16
        )
        XCTAssertTrue(plan.usedKeyframeIndex)
        // 3.9 < 4.0 stays in segment 0; 7.9 ≥ 4.0 opens a segment; 8.2 ≥ 8.0
        // opens the next; 12.2 ≥ 12.0 opens the next.
        XCTAssertEqual(plan.boundaries, [
            pts(0), pts(7.9), pts(8.2), pts(12.2), pts(16),
        ])
    }

    func testSparseKeyframesSkipCrossedThresholds() {
        // A keyframe that jumps past several thresholds only opens one
        // segment; the skipped thresholds must not produce empty segments.
        let keyframes = [pts(0), pts(2), pts(13), pts(15), pts(17), pts(19)]
        let plan = LoopbackSegmentPlan.build(
            keyframePts: keyframes,
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 21
        )
        XCTAssertTrue(plan.usedKeyframeIndex)
        XCTAssertEqual(plan.boundaries, [
            pts(0), pts(13), pts(17), pts(21),
        ])
    }

    func testLateStartTitleAnchorsAtFirstKeyframe() {
        // Blu-ray-style late start: content begins at 11.6 s. Segment 0 must
        // anchor there, not at PTS 0, or the playlist advertises leading
        // segments the producer can never emit.
        let keyframes = stride(from: 11.6, through: 31.6, by: 2.0).map(pts)
        let plan = LoopbackSegmentPlan.build(
            keyframePts: keyframes,
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 20
        )
        XCTAssertEqual(plan.boundaries[0], pts(11.6))
        XCTAssertEqual(plan.startSeconds[0], 0.0)
    }

    // MARK: - Uniform fallback

    func testUntrustedIndexFallsBackToUniformStride() {
        let keyframes = [pts(0), pts(5000)]
        let plan = LoopbackSegmentPlan.build(
            keyframePts: keyframes,
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 10
        )
        XCTAssertFalse(plan.usedKeyframeIndex)
        XCTAssertEqual(plan.segmentCount, 3)
        XCTAssertEqual(plan.startSeconds, [0, 4, 8, 10])
    }

    func testUniformFallbackAnchorsAtFirstKeyframe() {
        // Even the fallback anchors at the first indexed keyframe so a
        // late-starting title's segment 0 is producible.
        let keyframes = [pts(11.6)]
        let plan = LoopbackSegmentPlan.build(
            keyframePts: keyframes,
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 8
        )
        XCTAssertFalse(plan.usedKeyframeIndex)
        XCTAssertEqual(plan.boundaries[0], pts(11.6))
        XCTAssertEqual(plan.boundaries.last, pts(19.6))
    }

    func testEmptyIndexUniformPlanAnchorsAtZero() {
        let plan = LoopbackSegmentPlan.build(
            keyframePts: [],
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 9
        )
        XCTAssertFalse(plan.usedKeyframeIndex)
        XCTAssertEqual(plan.boundaries[0], 0)
        XCTAssertEqual(plan.segmentCount, 3)
    }

    // MARK: - Index lookup

    func testSegmentIndexLookupClamps() {
        let keyframes = stride(from: 0.0, through: 18.0, by: 2.0).map(pts)
        let plan = LoopbackSegmentPlan.build(
            keyframePts: keyframes,
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 20
        )
        XCTAssertEqual(plan.segmentIndex(forPlaylistSeconds: -5), 0)
        XCTAssertEqual(plan.segmentIndex(forPlaylistSeconds: 0), 0)
        XCTAssertEqual(plan.segmentIndex(forPlaylistSeconds: 5), 1)
        XCTAssertEqual(plan.segmentIndex(forPlaylistSeconds: 19.9), 4)
        // Past the end fence clamps into the last real segment.
        XCTAssertEqual(plan.segmentIndex(forPlaylistSeconds: 400), 4)
    }

    // MARK: - Resume-anchor coalescing

    func testCoalescingSegmentsMergesBoundariesAndRemapsResume() {
        // Segments every 4 s over 20 s: boundaries at 0/4/8/12/16, fence 20.
        let keyframes = stride(from: 0.0, through: 18.0, by: 2.0).map(pts)
        let plan = LoopbackSegmentPlan.build(
            keyframePts: keyframes,
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 20
        )
        // Resume segment 3 failed bitstream validation; anchor at 1.
        let merged = plan.coalescingSegments(after: 1, through: 3)
        XCTAssertEqual(merged.segmentCount, plan.segmentCount - 2)
        XCTAssertEqual(merged.boundaries, [pts(0), pts(4), pts(16), plan.boundaries.last!])
        XCTAssertEqual(merged.startSeconds, [0, 4, 16, plan.startSeconds.last!])
        // Segment 1 now spans the merged range; total duration unchanged.
        XCTAssertEqual(merged.duration(ofSegment: 1), 12, accuracy: 0.001)
        XCTAssertEqual(merged.totalDurationSeconds, plan.totalDurationSeconds)
        // A resume time inside the old segment 3 lands in the kept segment.
        XCTAssertEqual(merged.segmentIndex(forPlaylistSeconds: 13), 1)
    }

    func testCoalescingSegmentsRejectsInvalidRanges() {
        let keyframes = stride(from: 0.0, through: 18.0, by: 2.0).map(pts)
        let plan = LoopbackSegmentPlan.build(
            keyframePts: keyframes,
            timeBaseNum: num, timeBaseDen: den,
            sourceDurationSeconds: 20
        )
        XCTAssertEqual(plan.coalescingSegments(after: 2, through: 2), plan)
        XCTAssertEqual(plan.coalescingSegments(after: 3, through: 1), plan)
        XCTAssertEqual(plan.coalescingSegments(after: -1, through: 2), plan)
        // `through` must be a real segment, not the end fence.
        XCTAssertEqual(plan.coalescingSegments(after: 1, through: plan.segmentCount), plan)
    }
}
