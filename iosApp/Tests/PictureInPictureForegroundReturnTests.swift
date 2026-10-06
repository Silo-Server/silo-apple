#if os(iOS)
import XCTest
@testable import Silo

/// Returning to the app with the full-screen player still presented must end
/// automatic Picture in Picture; otherwise AVKit leaves an empty window over
/// the inline video until the player closes.
@MainActor
final class PictureInPictureForegroundReturnTests: XCTestCase {
    private typealias Coordinator = PictureInPictureCoordinator

    func testActivePictureInPictureStopsWhenTheOwningPlayerIsPresented() {
        XCTAssertEqual(
            Coordinator.foregroundReturnAction(ownsSession: true, isActive: true, isTransitioning: false),
            .stop
        )
    }

    func testStartStillInFlightStopsOnceItLands() {
        XCTAssertEqual(
            Coordinator.foregroundReturnAction(ownsSession: true, isActive: false, isTransitioning: true),
            .stopOnceStarted
        )
    }

    func testIdlePictureInPictureIsLeftAlone() {
        XCTAssertEqual(
            Coordinator.foregroundReturnAction(ownsSession: true, isActive: false, isTransitioning: false),
            .none
        )
    }

    /// An outgoing player can still be mounted while a newer session owns the
    /// window; its return must not close the newer session's PiP.
    func testAnotherSessionsPictureInPictureIsLeftAlone() {
        XCTAssertEqual(
            Coordinator.foregroundReturnAction(ownsSession: false, isActive: true, isTransitioning: false),
            .none
        )
        XCTAssertEqual(
            Coordinator.foregroundReturnAction(ownsSession: false, isActive: false, isTransitioning: true),
            .none
        )
    }
}
#endif
