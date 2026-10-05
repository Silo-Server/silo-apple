import AetherEngine
import XCTest
@testable import Silo

/// A dropped source connection is not a stall while the player still plays
/// from its read-ahead buffer.
final class PlayerStallPresentationTests: XCTestCase {
    private let now = ContinuousClock.now

    private func isLoading(_ phase: PlaybackPhase, isPlaying: Bool = true,
                           movedSecondsAgo: Double?, bufferEmptySecondsAgo: Double? = nil) -> Bool {
        PlayerStallPresentation.isLoading(
            phase: phase,
            isPlaying: isPlaying,
            playheadMovedAt: movedSecondsAgo.map { now - .milliseconds(Int($0 * 1_000)) },
            bufferEmptySince: bufferEmptySecondsAgo.map { now - .milliseconds(Int($0 * 1_000)) },
            now: now
        )
    }

    func testReconnectingSourceWithAMovingPlayheadIsNotLoading() {
        XCTAssertFalse(isLoading(.stalled(reconnecting: true), movedSecondsAgo: 0.1))
        XCTAssertFalse(isLoading(.stalled(reconnecting: false), movedSecondsAgo: 0.1))
    }

    func testStalledSourceWithAStoppedPlayheadIsLoading() {
        XCTAssertTrue(isLoading(.stalled(reconnecting: true), movedSecondsAgo: 1.5))
        XCTAssertTrue(isLoading(.stalled(reconnecting: false), movedSecondsAgo: 1.5))
    }

    func testStalledSourceBeforeAnyPlayheadMovementIsLoading() {
        XCTAssertTrue(isLoading(.stalled(reconnecting: true), movedSecondsAgo: nil))
    }

    /// A paused player over a dead source is paused, not loading, and keeps
    /// its controls.
    func testPausedPlayerOverStalledSourceIsNotLoading() {
        XCTAssertFalse(isLoading(.stalled(reconnecting: true), isPlaying: false, movedSecondsAgo: 30))
    }

    /// After a seek past the buffer over a dead source, Aether's clock runs
    /// on without a frame. The moving playhead must not hide the stall.
    func testRunningClockWithNothingBufferedAheadIsLoading() {
        XCTAssertTrue(isLoading(.stalled(reconnecting: true), movedSecondsAgo: 0.1, bufferEmptySecondsAgo: 1.5))
    }

    func testBrieflyEmptyBufferIsNotYetLoading() {
        XCTAssertFalse(isLoading(.stalled(reconnecting: true), movedSecondsAgo: 0.1, bufferEmptySecondsAgo: 0.3))
    }

    func testPausedPlayerWithAnEmptyBufferIsNotLoading() {
        XCTAssertFalse(isLoading(.stalled(reconnecting: true), isPlaying: false,
                                 movedSecondsAgo: 30, bufferEmptySecondsAgo: 30))
    }

    func testMediaAheadOfTheClock() {
        // Playing from the read-ahead buffer.
        XCTAssertTrue(PlayerStallPresentation.hasMediaAhead(bufferedPosition: 640, clockTime: 400))
        // A starved reader: the buffered position is clamped to the clock.
        XCTAssertFalse(PlayerStallPresentation.hasMediaAhead(bufferedPosition: 1_800, clockTime: 1_800))
        XCTAssertFalse(PlayerStallPresentation.hasMediaAhead(bufferedPosition: 1_800.05, clockTime: 1_800))
        // No usable reading leaves the judgment to the playhead.
        XCTAssertTrue(PlayerStallPresentation.hasMediaAhead(bufferedPosition: .nan, clockTime: 1_800))
    }

    func testOtherPhasesKeepTheirMeaning() {
        XCTAssertTrue(isLoading(.loading, movedSecondsAgo: 0.1))
        XCTAssertTrue(isLoading(.rebuffering, movedSecondsAgo: 0.1))
        for phase: PlaybackPhase in [.idle, .playing, .paused, .seeking, .ended, .error("failed")] {
            XCTAssertFalse(isLoading(phase, movedSecondsAgo: 30), "\(phase)")
        }
    }
}
