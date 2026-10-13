import XCTest
@testable import Silo

/// A stream that stops short of the end lands on the end-of-playback screen,
/// which hides the player's notice layer. The screen must still say why
/// playback stopped.
@MainActor
final class PlayerPrematureEndNoticeTests: XCTestCase {
    func testStreamThatEndsEarlyKeepsItsNoticeOnThePostroll() {
        let player = PlayerViewModel()
        defer { player.cleanup() }
        player.duration = 3_600
        player.currentTime = 1_200

        player.handleEndOfFile()

        XCTAssertTrue(player.showNextUpScreen)
        XCTAssertEqual(player.presentedNotice?.title, "Connection lost")
    }

    /// A download has no connection to lose: its early end is a file that
    /// stops short.
    func testDownloadThatEndsEarlyKeepsItsNoticeOnThePostroll() async throws {
        let player = PlayerViewModel()
        defer { player.cleanup() }
        // The test process has no download to open; the failed load still
        // records the request.
        player.loadAndPlay(contentId: "episode", startFromBeginning: false, offlineDownloadId: "download")
        try await waitUntil("the initial load to fail") { player.error != nil }
        player.error = nil
        player.duration = 3_600
        player.currentTime = 1_200

        player.handleEndOfFile()

        XCTAssertTrue(player.showNextUpScreen)
        XCTAssertEqual(player.presentedNotice?.title, "Download incomplete")
    }
}
