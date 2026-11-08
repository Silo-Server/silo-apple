import XCTest
@testable import Silo

/// A skip sets `isScrubbing` while its seek waits, but the scrub preview
/// (bubble, faded controls, taller bar) belongs to scrubs the viewer drives.
@MainActor
final class SkipScrubPreviewTests: XCTestCase {
    func testASkipMovesThePlayheadWithoutThePreview() {
        let player = makePlayer(at: 100)
        player.skipForward(10)
        XCTAssertTrue(player.isScrubbing)
        XCTAssertEqual(player.scrubPreviewTime, 110)
        XCTAssertFalse(player.showsScrubPreview)
    }

    func testADragShowsThePreview() {
        let player = makePlayer(at: 100)
        player.beginScrub(fraction: 0.5)
        XCTAssertTrue(player.showsScrubPreview)
    }

    /// A finger that lands while a skip is pending takes over the scrub: the
    /// preview shows, and the skip's delayed seek must not land under it.
    func testADragDuringAPendingSkipShowsThePreviewAndHoldsTheSeek() async throws {
        let player = makePlayer(at: 100)
        player.skipForward(10)
        player.beginScrub(fraction: 0.5)
        XCTAssertTrue(player.showsScrubPreview)
        // Past the skip's 200 ms debounce.
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(player.isScrubbing)
        XCTAssertEqual(player.scrubPreviewTime, player.duration * 0.5)
    }

    func testATrackpadSwipeAfterASkipShowsThePreview() {
        let player = makePlayer(at: 100)
        player.skipForward(10)
        player.trackpadScrubBegan()
        player.trackpadScrubMoved(by: CGSize(width: 40, height: 0))
        XCTAssertTrue(player.isTrackpadScrubbing)
        XCTAssertTrue(player.showsScrubPreview)
    }

    private func makePlayer(at time: Double) -> PlayerViewModel {
        let player = PlayerViewModel()
        player.duration = 3_600
        player.currentTime = time
        return player
    }
}
