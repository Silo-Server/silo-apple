import XCTest
@testable import Silo

/// Solo playback refuses seeks once the item has ended, so a scrub still open
/// at that moment can never be committed. Playback ending has to close it.
@MainActor
final class PlayerScrubEndOfFileTests: XCTestCase {
    private func soloPlayer() -> PlayerViewModel {
        let player = PlayerViewModel()
        player.duration = 1_200
        player.currentTime = 1_195
        return player
    }

    /// A finger or pointer holding the timeline as the item ends.
    func testTimelineScrubOpenAtTheEndIsClosed() {
        let player = soloPlayer()
        defer { player.cleanup() }
        player.beginScrub(fraction: 0.5)
        XCTAssertTrue(player.isScrubbing)

        player.handleEndOfFile()

        XCTAssertFalse(player.isScrubbing)
    }

    /// Apple TV's hold-to-seek session, which only Select or Menu ends.
    func testSeekSessionOpenAtTheEndIsClosed() {
        let player = soloPlayer()
        defer { player.cleanup() }
        player.beginHoldSeek(forward: true)
        XCTAssertTrue(player.isHoldSeeking)

        player.handleEndOfFile()

        XCTAssertFalse(player.isHoldSeeking)
    }

    /// A skip seeks after a short debounce. One pressed just before the end
    /// must not seek the ended item afterwards.
    func testSkipPendingAtTheEndDoesNotSeekAfterwards() async throws {
        let player = soloPlayer()
        defer { player.cleanup() }
        player.skipBackward(10)

        player.handleEndOfFile()
        // Past the skip's 200 ms debounce.
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertTrue(player.hasReachedEndOfFile)
        XCTAssertEqual(player.currentTime, 1_200)
    }
}
