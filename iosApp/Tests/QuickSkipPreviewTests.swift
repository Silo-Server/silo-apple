#if os(tvOS)
import XCTest
@testable import Silo

/// Left or Right with the tvOS controls hidden skips without the controls and
/// holds where the skips land for the passive timeline's preview card. The
/// skip's seek commits 200 ms after the last tap and ends the scrub, so the
/// card's landing time has to outlive it.
@MainActor
final class QuickSkipPreviewTests: XCTestCase {
    func testRepeatedQuickSkipsHoldTheSummedLandingTimeWithoutTheControls() {
        let player = makePlayer(at: 100)
        defer { player.cleanup() }
        let forward = Double(player.skipIntervals.forward)
        let backward = Double(player.skipIntervals.backward)

        XCTAssertTrue(player.quickSkip(forward: true))
        XCTAssertTrue(player.quickSkip(forward: true))
        XCTAssertTrue(player.quickSkip(forward: false))

        XCTAssertEqual(player.quickSkipLandingTime, 100 + 2 * forward - backward)
        XCTAssertFalse(player.showControls)
    }

    func testTheLandingTimeOutlivesTheSkipsSeek() async throws {
        let player = makePlayer(at: 100)
        defer { player.cleanup() }
        player.quickSkip(forward: true)
        let landing = try XCTUnwrap(player.quickSkipLandingTime)

        // Past the skip's 200 ms debounce.
        try await Task.sleep(nanoseconds: 400_000_000)

        XCTAssertFalse(player.isScrubbing, "the skip's seek has committed")
        XCTAssertEqual(player.currentTime, landing)
        XCTAssertEqual(player.quickSkipLandingTime, landing)
    }

    func testTheCardEndsWithTheTimeline() async throws {
        let player = makePlayer(at: 100)
        defer { player.cleanup() }
        player.quickSkip(forward: true)
        try await Task.sleep(nanoseconds: 400_000_000)

        player.endQuickSkipPreview()

        XCTAssertNil(player.quickSkipLandingTime)
    }

    func testAScrubTakesOverFromTheCard() {
        let player = makePlayer(at: 100)
        defer { player.cleanup() }
        player.quickSkip(forward: true)

        player.beginScrub(fraction: 0.5)

        XCTAssertNil(player.quickSkipLandingTime)
    }

    /// A finished item refuses seeks; no card may promise one.
    func testASkipRefusedAtTheEndShowsNoCard() {
        let player = makePlayer(at: 3_595)
        defer { player.cleanup() }
        player.handleEndOfFile()

        XCTAssertFalse(player.quickSkip(forward: false))
        XCTAssertNil(player.quickSkipLandingTime)
    }

    private func makePlayer(at time: Double) -> PlayerViewModel {
        let player = PlayerViewModel()
        player.duration = 3_600
        player.currentTime = time
        return player
    }
}
#endif
