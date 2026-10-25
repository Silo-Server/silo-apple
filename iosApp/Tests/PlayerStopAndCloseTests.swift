import XCTest
@testable import Silo

/// The TV's remote receiver stops a title with `stopAndClose()` when a phone
/// takes over. A title started from a tvOS detail page is a pushed route that
/// the receiver can't dismiss itself, so the stop must not wait for the view
/// to disappear, and the view must be told to close.
@MainActor
final class PlayerStopAndCloseTests: XCTestCase {
    func testRemoteReplacementKeepsPlayerAliveAndPublishesTheNewSelection() {
        let player = PlayerViewModel()
        defer { player.cleanup() }
        player.loadAndPlay(contentId: "outgoing", startFromBeginning: false)
        player.error = "old failure"

        player.replaceSiloControlPlayback(SiloControlPlaybackRequest(
            contentId: "incoming", fileId: nil, audioTrackIndex: nil, subtitleTrackIndex: nil,
            startFromBeginning: true, resumePosition: 42
        ))

        let state = player.makeSiloControlPlaybackState(contentId: "outgoing")
        XCTAssertEqual(state.contentId, "incoming")
        XCTAssertNil(state.error)
        XCTAssertTrue(state.isLoading)
        XCTAssertFalse(player.needsReplacementForPresentation)
        XCTAssertNil(player.remoteDismissToken)
    }

    func testRemoteReplacementCannotReviveADisposedPlayer() {
        let player = PlayerViewModel()
        player.loadAndPlay(contentId: "outgoing", startFromBeginning: false)
        player.cleanup()

        player.replaceSiloControlPlayback(SiloControlPlaybackRequest(
            contentId: "incoming", fileId: nil, audioTrackIndex: nil, subtitleTrackIndex: nil,
            startFromBeginning: false, resumePosition: nil
        ))

        XCTAssertEqual(player.makeSiloControlPlaybackState(contentId: nil).contentId, "outgoing")
        XCTAssertTrue(player.needsReplacementForPresentation)
    }

    func testStopsAtOnceWithoutWaitingForTheViewToDisappear() {
        let player = PlayerViewModel()
        player.stopAndClose()

        XCTAssertTrue(player.needsReplacementForPresentation, "the player must be torn down now")
    }

    func testAsksTheViewToClose() async {
        let player = PlayerViewModel()
        XCTAssertNil(player.remoteDismissToken)

        player.stopAndClose()

        await expectEventually("the view is asked to close") { player.remoteDismissToken != nil }
    }
}
