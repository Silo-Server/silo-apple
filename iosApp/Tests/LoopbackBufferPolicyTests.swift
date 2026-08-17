import XCTest
@testable import Silo

final class LoopbackBufferPolicyTests: XCTestCase {
    /// The static VOD playlist is the only loopback serving mode, and it keeps
    /// AVPlayer's explicit forward-buffer target at one nominal segment
    /// regardless of source bitrate or segment durations — resilience comes
    /// from the disk-backed producer/cache window instead.
    func testStaticVODKeepsOneSegmentExplicitTarget() {
        XCTAssertEqual(AVPlayerBackend.loopbackSteadyStateForwardBufferTarget, 4)
    }
}
