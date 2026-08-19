import XCTest
@testable import Silo

/// The runway is `max(playable, generated-visible)`; the generated figure is
/// non-nil only on the loopback route, so its nilness encodes the route.
/// Pinned because pointing a watchdog at the wrong figure silently disables
/// loopback stall recovery.
final class PlaybackRunwayPolicyTests: XCTestCase {
    func testPrefersLargerGeneratedFigure() {
        XCTAssertEqual(
            PlaybackRunwayPolicy.runwaySeconds(
                playableAheadSeconds: 4,
                generatedVisibleAheadSeconds: 45
            ),
            45,
            accuracy: 0.0001
        )
    }

    func testTakesMaxNeverMin() {
        XCTAssertEqual(
            PlaybackRunwayPolicy.runwaySeconds(
                playableAheadSeconds: 6,
                generatedVisibleAheadSeconds: 1
            ),
            6,
            accuracy: 0.0001
        )
    }

    func testWithoutGeneratedFigureFallsBackToPlayable() {
        XCTAssertEqual(
            PlaybackRunwayPolicy.runwaySeconds(
                playableAheadSeconds: 7.5,
                generatedVisibleAheadSeconds: nil
            ),
            7.5,
            accuracy: 0.0001
        )
    }

    func testNegativeAndZeroInputsFloorAtZero() {
        XCTAssertEqual(
            PlaybackRunwayPolicy.runwaySeconds(
                playableAheadSeconds: -3,
                generatedVisibleAheadSeconds: nil
            ),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PlaybackRunwayPolicy.runwaySeconds(
                playableAheadSeconds: -3,
                generatedVisibleAheadSeconds: -9
            ),
            0,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            PlaybackRunwayPolicy.runwaySeconds(
                playableAheadSeconds: 0,
                generatedVisibleAheadSeconds: 0
            ),
            0,
            accuracy: 0.0001
        )
    }
}
