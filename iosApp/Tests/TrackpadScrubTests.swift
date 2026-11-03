import XCTest
@testable import Silo

@MainActor
final class TrackpadScrubTests: XCTestCase {
    /// One point of travel is one second of a timeline this long.
    private let duration = Double(TrackpadScrub.pointsPerTimeline)

    // MARK: - Axis

    func testOnlyAHorizontalSwipeScrubs() {
        var scrub = TrackpadScrub()
        scrub.start(canSeek: true)
        XCTAssertNil(scrub.move(by: CGSize(width: 4, height: 0)))
        XCTAssertEqual(scrub.move(by: CGSize(width: 4, height: 1)), .begin(points: 8))

        // Vertical, or exactly diagonal, never scrubs, even after drifting sideways.
        for opening in [CGSize(width: 1, height: 8), CGSize(width: 6, height: 6)] {
            scrub.start(canSeek: true)
            XCTAssertNil(scrub.move(by: opening), "\(opening)")
            XCTAssertNil(scrub.move(by: CGSize(width: 300, height: 0)), "\(opening)")
        }
    }

    // MARK: - Seeks

    func testASwipeSeeksOnceWhereTheFingersLift() {
        let (player, seeks, stop) = partyPlayer(at: 100)
        defer { stop() }
        swipe(player, [40, -10])
        XCTAssertEqual(seeks(), [.seek(130)])
        XCTAssertFalse(player.isScrubbing)
    }

    /// Travel past an end is dropped, so turning back moves the playhead at once.
    func testTurningBackAfterRunningPastTheEndMovesAtOnce() {
        let (player, seeks, stop) = partyPlayer(at: 3_990)
        defer { stop() }
        swipe(player, [500, -40])
        XCTAssertEqual(seeks(), [.seek(3_960)])
    }

    /// The skip's delayed seek would otherwise fire partway through the swipe.
    func testAPendingSkipCarriesIntoTheSwipe() {
        let (player, seeks, stop) = partyPlayer(at: 100)
        defer { stop() }
        player.skipForward(10)
        swipe(player, [40])
        XCTAssertEqual(seeks(), [.seek(150)])
    }

    func testASkipDuringASwipeJoinsIt() {
        let (player, seeks, stop) = partyPlayer(at: 100)
        defer { stop() }
        player.trackpadScrubBegan()
        player.trackpadScrubMoved(by: CGSize(width: 40, height: 0))
        player.skipForward(10)
        player.trackpadScrubMoved(by: CGSize(width: 5, height: 0))
        player.trackpadScrubEnded(committing: true)
        XCTAssertEqual(seeks(), [.seek(155)])
    }

    /// Once something else commits the scrub, lifting the fingers must not seek again.
    func testAScrubCommittedElsewhereIsNotSeekedAgain() {
        let (player, seeks, stop) = partyPlayer(at: 100)
        defer { stop() }
        player.trackpadScrubBegan()
        player.trackpadScrubMoved(by: CGSize(width: 40, height: 0))
        player.endScrub()
        player.trackpadScrubMoved(by: CGSize(width: 10, height: 0))
        // The Mac timeline would otherwise keep showing a preview card.
        XCTAssertFalse(player.isTrackpadScrubbing)
        player.trackpadScrubEnded(committing: true)
        XCTAssertEqual(seeks(), [.seek(140)])
    }

    func testASwipeBackToWherePlaybackIsDoesNotSeek() {
        let (player, seeks, stop) = partyPlayer(at: 100)
        defer { stop() }
        swipe(player, [40, -40])
        XCTAssertEqual(seeks(), [])
        XCTAssertFalse(player.isScrubbing)
    }

    func testAbandoningASwipeDoesNotSeek() {
        let (player, seeks, stop) = partyPlayer(at: 100)
        defer { stop() }
        player.trackpadScrubBegan()
        player.trackpadScrubMoved(by: CGSize(width: 40, height: 0))
        player.trackpadScrubEnded(committing: false)
        XCTAssertEqual(seeks(), [])
        XCTAssertFalse(player.isScrubbing)
    }

    func testWithoutSeekRightsASwipeDoesNothing() {
        let (player, seeks, stop) = partyPlayer(at: 100, canSeek: false)
        defer { stop() }
        swipe(player, [40])
        XCTAssertEqual(seeks(), [])
        XCTAssertFalse(player.showControls)
    }

    /// `endScrub` refuses at the end of the file without clearing the scrub.
    func testReachingTheEndMidSwipeLeavesNoScrubBehind() {
        let player = PlayerViewModel()
        player.duration = duration
        player.currentTime = 3_900
        player.trackpadScrubBegan()
        player.trackpadScrubMoved(by: CGSize(width: 40, height: 0))
        XCTAssertTrue(player.isScrubbing)
        player.hasReachedEndOfFile = true
        player.trackpadScrubMoved(by: CGSize(width: 10, height: 0))
        player.trackpadScrubEnded(committing: true)
        XCTAssertFalse(player.isScrubbing)
        XCTAssertFalse(player.isTrackpadScrubbing)
    }

    // MARK: - Helpers

    /// A Watch Party member, so every seek reaches the room as a request
    /// the test can count.
    private func partyPlayer(
        at time: Double,
        canSeek: Bool = true
    ) -> (PlayerViewModel, () -> [WatchPartyPlaybackAction], () -> Void) {
        let player = PlayerViewModel()
        let adapter = WatchPartyPlaybackAdapter(player: player)
        adapter.prepare(WatchPartyPlaybackContext(
            roomId: "room", selectionRevision: 1, contentId: "movie",
            fileId: 42, libraryId: nil, startPosition: 0
        ))
        adapter.canSeek = canSeek
        var requests: [WatchPartyPlaybackAction] = []
        adapter.onUserTransport = { action, _, _ in requests.append(action); return true }
        player.duration = duration
        player.currentTime = time
        return (player, { requests }, { adapter.stop() })
    }

    /// One whole swipe: began, horizontal moves of `points`, then lifted.
    private func swipe(_ player: PlayerViewModel, _ points: [CGFloat]) {
        player.trackpadScrubBegan()
        for width in points {
            player.trackpadScrubMoved(by: CGSize(width: width, height: 0))
        }
        player.trackpadScrubEnded(committing: true)
    }
}
