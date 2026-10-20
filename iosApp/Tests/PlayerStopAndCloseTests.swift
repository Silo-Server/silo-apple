import XCTest
@testable import Silo

/// The TV's remote receiver stops a title with `stopAndClose()` when a phone
/// takes over. A title started from a tvOS detail page is a pushed route that
/// the receiver can't dismiss itself, so the stop must not wait for the view
/// to disappear, and the view must be told to close.
@MainActor
final class PlayerStopAndCloseTests: XCTestCase {
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
