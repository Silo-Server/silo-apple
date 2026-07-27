import XCTest
@testable import Silo

final class LoopbackBufferPolicyTests: XCTestCase {
    func testEventGeneratedMediaBitrateDrivesSteadyStateBufferTarget() {
        let target = AVPlayerBackend.loopbackSteadyStateForwardBufferTarget(
            forBitsPerSecond: 69_000_000,
            targetDuration: 4,
            longestSegmentDuration: 4,
            servingMode: .event,
            constrainedMemoryDevice: true
        )

        XCTAssertGreaterThan(target, 18)
        XCTAssertLessThan(target, 21)
    }

    func testLiveEdgeFloorAppliesWhenBitrateIsUnknown() {
        let target = AVPlayerBackend.loopbackSteadyStateForwardBufferTarget(
            forBitsPerSecond: nil,
            targetDuration: 6,
            longestSegmentDuration: 10,
            servingMode: .event,
            constrainedMemoryDevice: true
        )

        XCTAssertEqual(target, 28)
    }

    func testStaticVODKeepsOneSegmentExplicitTarget() {
        let target = AVPlayerBackend.loopbackSteadyStateForwardBufferTarget(
            forBitsPerSecond: 69_000_000,
            targetDuration: 4,
            longestSegmentDuration: 4,
            servingMode: .vodPlan,
            constrainedMemoryDevice: true
        )

        XCTAssertEqual(target, 4)
        XCTAssertLessThan(target, 15.5)
    }

    func testStaticVODIgnoresEventLiveEdgeFloor() {
        let target = AVPlayerBackend.loopbackSteadyStateForwardBufferTarget(
            forBitsPerSecond: nil,
            targetDuration: 6,
            longestSegmentDuration: 10,
            servingMode: .vodPlan,
            constrainedMemoryDevice: true
        )

        XCTAssertEqual(target, 4)
    }

    func testStaticVODIgnoresUnexpectedlyLongTargetDuration() {
        let target = AVPlayerBackend.loopbackSteadyStateForwardBufferTarget(
            forBitsPerSecond: nil,
            targetDuration: 30,
            longestSegmentDuration: 30,
            servingMode: .vodPlan,
            constrainedMemoryDevice: true
        )

        XCTAssertEqual(target, 4)
    }
}
