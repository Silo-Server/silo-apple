import XCTest
@testable import Silo

/// Stage-0 characterization: the one input to `LoopbackSegmentPlan.build`
/// that `LoopbackSegmentPlanTests` does not exercise — `forceUniformStride`.
///
/// The trusted/untrusted keyframe-index halves of the plan are already pinned
/// there. What is unpinned is the override the *bridged* writer sets: when the
/// output bitstream comes from a VideoToolbox encoder, the source's cue points
/// describe frames that no longer exist, so the index must be ignored even
/// when it is perfectly trustworthy. Nothing else in the tree asserts that.
final class LoopbackSegmentPlanTrustTests: XCTestCase {
    // 90 kHz MPEG time base: 1 tick = 1/90000 s.
    private let num: Int32 = 1
    private let den: Int32 = 90000

    private func pts(_ seconds: Double) -> Int64 {
        Int64((seconds * 90000).rounded())
    }

    /// A dense, wide, perfectly trustworthy index — the exact input the
    /// keyframe planner is designed for.
    private var trustworthyIndex: [Int64] {
        stride(from: 0.0, through: 18.0, by: 2.0).map(pts)
    }

    func testTheIndexUnderTestIsGenuinelyTrustworthy() {
        XCTAssertTrue(LoopbackSegmentPlan.keyframeIndexIsTrustworthy(
            keyframePts: trustworthyIndex,
            timeBaseNum: num,
            timeBaseDen: den,
            sourceDurationSeconds: 20,
            targetSegmentDurationSeconds: LoopbackSegmentPlan.defaultTargetSegmentDurationSeconds
        ))
    }

    func testCopyModeHonoursATrustworthyIndex() {
        let plan = LoopbackSegmentPlan.build(
            keyframePts: trustworthyIndex,
            timeBaseNum: num,
            timeBaseDen: den,
            sourceDurationSeconds: 20
        )

        XCTAssertTrue(plan.usedKeyframeIndex)
        XCTAssertEqual(plan.boundaries, [pts(0), pts(4), pts(8), pts(12), pts(16), pts(20)])
    }

    /// The bridged case: same trustworthy index, but the writer forces the
    /// uniform stride because it will cut on its own encoder's keyframes.
    func testForcedUniformStrideDiscardsEvenATrustworthyIndex() {
        let plan = LoopbackSegmentPlan.build(
            keyframePts: trustworthyIndex,
            timeBaseNum: num,
            timeBaseDen: den,
            sourceDurationSeconds: 20,
            forceUniformStride: true
        )

        XCTAssertFalse(plan.usedKeyframeIndex)
        XCTAssertEqual(plan.startSeconds, [0, 4, 8, 12, 16, 20])
        XCTAssertEqual(plan.segmentCount, 5)
        // Every segment is exactly one target long — that is what "uniform"
        // means, and it is the promise the encoder is forced to keep.
        for index in 0..<plan.segmentCount {
            XCTAssertEqual(
                plan.duration(ofSegment: index),
                LoopbackSegmentPlan.defaultTargetSegmentDurationSeconds,
                accuracy: 0.001,
                "segment \(index)"
            )
        }
    }

    /// The forced stride still anchors at the first indexed keyframe, so a
    /// late-starting title's segment 0 remains producible.
    func testForcedUniformStrideStillAnchorsAtTheFirstKeyframe() {
        let plan = LoopbackSegmentPlan.build(
            keyframePts: [pts(11.6), pts(13.6), pts(15.6)],
            timeBaseNum: num,
            timeBaseDen: den,
            sourceDurationSeconds: 8,
            forceUniformStride: true
        )

        XCTAssertFalse(plan.usedKeyframeIndex)
        XCTAssertEqual(plan.boundaries.first, pts(11.6))
        XCTAssertEqual(plan.anchorSourceSeconds, 11.6, accuracy: 0.001)
        XCTAssertEqual(plan.startSeconds.first, 0)
    }

    /// A non-default target must be honoured in the forced path too, or a
    /// bridged session would advertise segments the encoder never fences.
    func testForcedUniformStrideHonoursTheRequestedTarget() {
        let plan = LoopbackSegmentPlan.build(
            keyframePts: trustworthyIndex,
            timeBaseNum: num,
            timeBaseDen: den,
            sourceDurationSeconds: 12,
            targetSegmentDurationSeconds: 6,
            forceUniformStride: true
        )

        XCTAssertFalse(plan.usedKeyframeIndex)
        XCTAssertEqual(plan.startSeconds, [0, 6, 12])
    }
}
