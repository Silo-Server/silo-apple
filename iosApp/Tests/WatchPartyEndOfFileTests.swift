import AetherEngine
import XCTest
@testable import Silo

/// A Watch Party member whose stream reaches end of file must stay movable by
/// the room, and must not drag the room back to where its stream stopped.
@MainActor
final class WatchPartyEndOfFileTests: XCTestCase {
    private func partyPlayer() -> (PlayerViewModel, WatchPartyPlaybackAdapter) {
        let player = PlayerViewModel()
        let adapter = WatchPartyPlaybackAdapter(player: player)
        adapter.prepare(WatchPartyPlaybackContext(
            roomId: "room", selectionRevision: 1, contentId: "movie",
            fileId: 42, libraryId: nil, startPosition: 0
        ))
        return (player, adapter)
    }

    func testEndedStreamStillReportsAndTakesRoomCommands() {
        XCTAssertTrue(PlayerViewModel.isWatchPartyReadyPhase(.ended))
        XCTAssertTrue(PlayerViewModel.isWatchPartyReadyPhase(.paused))
        XCTAssertTrue(PlayerViewModel.isWatchPartyReadyPhase(.playing))
        for phase: PlaybackPhase in [
            .idle, .loading, .seeking, .rebuffering,
            .stalled(reconnecting: true), .stalled(reconnecting: false), .error("failed"),
        ] {
            XCTAssertFalse(PlayerViewModel.isWatchPartyReadyPhase(phase), "\(phase)")
        }
    }

    func testSeekAfterEndOfFileIsRequestedFromTheRoom() {
        let (player, adapter) = partyPlayer()
        defer { adapter.stop() }
        adapter.canSeek = true
        var requests: [WatchPartyPlaybackAction] = []
        adapter.onUserTransport = { action, _, _ in requests.append(action) }
        player.duration = 1_200
        player.currentTime = 1_200
        player.hasReachedEndOfFile = true

        player.seekTo(seconds: 300)
        player.beginScrub(fraction: 0.5)
        player.endScrub()

        XCTAssertEqual(requests, [.seek(300), .seek(600)])
        // The room's command moves the playhead, not the request.
        XCTAssertEqual(player.currentTime, 1_200)
    }

    func testPlayFromTheEndIsNotSentToTheRoom() {
        let (player, adapter) = partyPlayer()
        defer { adapter.stop() }
        adapter.canPlayPause = true
        adapter.canSeek = true
        var requests: [WatchPartyPlaybackAction] = []
        adapter.onUserTransport = { action, _, _ in requests.append(action) }
        player.hasReachedEndOfFile = true
        adapter.update(player.watchPartyPlaybackSnapshot)

        player.togglePlayPause()
        XCTAssertEqual(requests, [])

        adapter.request(.seek(10))
        XCTAssertEqual(requests, [.seek(10)])

        adapter.update(WatchPartyPlaybackSnapshot(sourceTime: 10, isReady: true))
        adapter.request(.play)
        XCTAssertEqual(requests, [.seek(10), .play])
    }

    func testSoloPlaybackStillStopsSeeksAtEndOfFile() {
        let player = PlayerViewModel()
        player.duration = 1_200
        player.currentTime = 1_200
        player.hasReachedEndOfFile = true

        player.seekTo(seconds: 300)
        player.beginScrub(fraction: 0.5)

        XCTAssertEqual(player.currentTime, 1_200)
        XCTAssertFalse(player.isScrubbing)
    }
}
