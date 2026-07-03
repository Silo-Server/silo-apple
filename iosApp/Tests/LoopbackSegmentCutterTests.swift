import XCTest
@testable import Silo

final class LoopbackSegmentCutterTests: XCTestCase {
    // Boundaries in 90 kHz ticks: segments start at 0 s, 4 s, 8 s, 12 s;
    // the 16 s entry is the end fence.
    private let boundaries: [Int64] = [0, 360_000, 720_000, 1_080_000, 1_440_000]

    func testFirstKeyframeOpensSegmentZero() {
        var cutter = LoopbackSegmentCutter(boundaries: boundaries)
        XCTAssertEqual(cutter.index(pts: 0, isKeyframe: true), 0)
    }

    func testNonKeyframeNeverAdvances() {
        var cutter = LoopbackSegmentCutter(boundaries: boundaries)
        _ = cutter.index(pts: 0, isKeyframe: true)
        // A delta frame past the next boundary still belongs to the open
        // segment — only an IRAP may start a new one.
        XCTAssertEqual(cutter.index(pts: 400_000, isKeyframe: false), 0)
    }

    func testBoundaryKeyframeOpensNextSegment() {
        var cutter = LoopbackSegmentCutter(boundaries: boundaries)
        _ = cutter.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(cutter.index(pts: 360_000, isKeyframe: true), 1)
    }

    func testRaslLeadingPicturesStayWithTheirKeyframe() {
        var cutter = LoopbackSegmentCutter(boundaries: boundaries)
        _ = cutter.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(cutter.index(pts: 360_000, isKeyframe: true), 1)
        // Open-GOP RASL pictures follow the CRA in decode order but present
        // before it; they must ride in the CRA's segment.
        XCTAssertEqual(cutter.index(pts: 355_000, isKeyframe: false), 1)
        XCTAssertEqual(cutter.index(pts: 358_000, isKeyframe: false), 1)
    }

    func testIntraSegmentKeyframeDoesNotCut() {
        var cutter = LoopbackSegmentCutter(boundaries: boundaries)
        _ = cutter.index(pts: 0, isKeyframe: true)
        // GOP shorter than the segment: a keyframe below the next boundary
        // stays put.
        XCTAssertEqual(cutter.index(pts: 180_000, isKeyframe: true), 0)
    }

    func testSparseKeyframeAdvancesPastMultipleBoundaries() {
        var cutter = LoopbackSegmentCutter(boundaries: boundaries)
        _ = cutter.index(pts: 0, isKeyframe: true)
        // One keyframe jumping past the 4 s and 8 s boundaries lands in the
        // 8 s segment directly; no empty segment is left behind.
        XCTAssertEqual(cutter.index(pts: 900_000, isKeyframe: true), 2)
    }

    func testNeverAdvancesPastLastRealSegment() {
        var cutter = LoopbackSegmentCutter(boundaries: boundaries)
        _ = cutter.index(pts: 0, isKeyframe: true)
        // The final boundary entry is an end fence, not a segment start: a
        // keyframe at or past it clamps into the last real segment.
        XCTAssertEqual(cutter.index(pts: 2_000_000, isKeyframe: true), 3)
        XCTAssertEqual(cutter.index(pts: 3_000_000, isKeyframe: true), 3)
    }

    func testNoptsKeyframeStaysPut() {
        var cutter = LoopbackSegmentCutter(boundaries: boundaries)
        _ = cutter.index(pts: 0, isKeyframe: true)
        XCTAssertEqual(cutter.index(pts: Int64.min, isKeyframe: true), 0)
    }

    func testBaseIndexAnchorsRestartedProducer() {
        // A producer restarted at plan segment 40 receives the plan tail's
        // boundaries and reports plan-absolute indices.
        var cutter = LoopbackSegmentCutter(boundaries: boundaries, baseIndex: 40)
        XCTAssertEqual(cutter.index(pts: 0, isKeyframe: true), 40)
        XCTAssertEqual(cutter.index(pts: 360_000, isKeyframe: true), 41)
        XCTAssertEqual(cutter.index(pts: 1_080_000, isKeyframe: true), 43)
        XCTAssertEqual(cutter.index(pts: 2_000_000, isKeyframe: true), 43)
    }
}
