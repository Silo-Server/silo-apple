import XCTest
@testable import Silo

final class TVMenuEntryFocusStateTests: XCTestCase {
    func testBackCancelsCallbackAlreadyQueuedAfterScrolling() {
        var state = TVMenuEntryFocusState()
        XCTAssertTrue(state.receive(1, menuOwnsFocus: false))
        let queued = state.pendingRequest!
        state.cancel()
        XCTAssertFalse(state.consume(queued))
        XCTAssertFalse(state.receive(1, menuOwnsFocus: false))
    }

    func testFreshSelectionSurvivesAnOlderQueuedCallback() {
        var state = TVMenuEntryFocusState()
        XCTAssertTrue(state.receive(1, menuOwnsFocus: false))
        state.cancel()
        XCTAssertTrue(state.receive(2, menuOwnsFocus: false))
        XCTAssertFalse(state.consume(1))
        XCTAssertTrue(state.consume(2))
        XCTAssertFalse(state.consume(2))
    }

    func testEntryArrivingWhileMenuOwnsFocusDoesNotReplayLater() {
        var state = TVMenuEntryFocusState()
        XCTAssertFalse(state.receive(1, menuOwnsFocus: true))
        XCTAssertFalse(state.receive(1, menuOwnsFocus: false))
        XCTAssertFalse(state.consume(1))
        XCTAssertTrue(state.receive(2, menuOwnsFocus: false))
    }

    func testNewRequestSupersedesUnfinishedScroll() {
        var state = TVMenuEntryFocusState()
        XCTAssertTrue(state.receive(1, menuOwnsFocus: false))
        XCTAssertTrue(state.receive(2, menuOwnsFocus: false))
        XCTAssertFalse(state.consume(1))
        XCTAssertTrue(state.consume(2))
    }

    func testInactiveRequestDoesNotClaimFocus() {
        var state = TVMenuEntryFocusState()
        XCTAssertFalse(state.receive(0, menuOwnsFocus: false))
        XCTAssertFalse(state.consume(0))
    }
}
