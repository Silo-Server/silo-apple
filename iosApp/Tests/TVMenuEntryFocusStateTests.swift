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

#if os(tvOS)
final class TVTopMenuRootsTests: XCTestCase {
    private let movies = Library(id: 1, name: "Films", type: "movies", sortOrder: 0, posterUrl: nil)
    private let series = Library(id: 2, name: "Shows", type: "series", sortOrder: 1, posterUrl: nil)
    private let music = Library(id: 3, name: "Music", type: "music", sortOrder: 2, posterUrl: nil)
    private let audiobooks = Library(id: 4, name: "Books", type: "audiobooks", sortOrder: 3, posterUrl: nil)

    func testBarHasAFixedOrderWithATabPerAvailableLibraryType() {
        // Libraries arrive in server order; the bar order never follows it.
        XCTAssertEqual(
            TVRootDestination.visibleRoots(
                libraries: [audiobooks, music, series, movies],
                showAudiobooks: true
            ),
            [
                .home, .libraryType(.movies), .libraryType(.series), .libraryType(.music),
                .libraryType(.audiobooks), .recommendations, .calendar,
            ]
        )
    }

    func testAudiobooksTabIsOptIn() {
        XCTAssertEqual(
            TVRootDestination.visibleRoots(
                libraries: [movies, series, audiobooks],
                showAudiobooks: false
            ),
            [.home, .libraryType(.movies), .libraryType(.series), .recommendations, .calendar]
        )
    }

    func testTypeTabsNeedAMatchingLibrary() {
        XCTAssertEqual(
            TVRootDestination.visibleRoots(libraries: [], showAudiobooks: true),
            [.home, .recommendations, .calendar]
        )
        let mixed = Library(id: 5, name: "Everything", type: "mixed", sortOrder: 0, posterUrl: nil)
        XCTAssertEqual(
            TVRootDestination.visibleRoots(libraries: [mixed], showAudiobooks: false),
            [.home, .libraryType(.movies), .libraryType(.series), .recommendations, .calendar],
            "a mixed library belongs under both video tabs"
        )
    }
}
#endif
