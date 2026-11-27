import XCTest
@testable import Silo

/// The player's sleep timer pickers (the iPhone settings sheet and the Apple
/// TV menu) drive the timer with one call per pick: a duration starts it
/// over, and Off, which is 0, cancels it.
@MainActor
final class SleepTimerTests: XCTestCase {
    func testPickingADurationRestartsTheTimerAndOffCancelsIt() {
        let timer = SleepTimer()
        addTeardownBlock { @MainActor in timer.cancel() }

        timer.start(minutes: 15)
        XCTAssertTrue(timer.isActive)
        XCTAssertEqual(timer.remainingSeconds, 15 * 60)
        XCTAssertEqual(timer.selectedDurationOption, 15)

        timer.start(minutes: 5)
        XCTAssertTrue(timer.isActive)
        XCTAssertEqual(timer.remainingSeconds, 5 * 60)
        XCTAssertEqual(timer.selectedDurationOption, 5)

        timer.start(minutes: 0)
        XCTAssertFalse(timer.isActive)
        XCTAssertEqual(timer.remainingSeconds, 0)
        XCTAssertEqual(timer.selectedDurationOption, 0)
    }
}

/// What the player does when the sleep timer runs out.
@MainActor
final class SleepTimerExpiryTests: XCTestCase {
    /// An episode that ends a few seconds before the timer runs out starts
    /// Up Next's countdown. The pause at zero cannot stop it, because the
    /// item has already ended, so the countdown itself has to stop or the
    /// next episode starts while the viewer sleeps.
    func testExpiryDuringTheUpNextCountdownStopsIt() throws {
        let episode = try JSONDecoder().decode(EpisodeListItem.self, from: Data(
            #"{"contentId":"synthetic-episode-b","seasonNumber":1,"episodeNumber":2,"title":"Next"}"#.utf8
        ))
        let model = PlayerViewModel()
        defer { model.cleanup() }
        // PlayerSettings.shared keeps a cached value; turning it on here
        // would queue a server write and a device override.
        try XCTSkipUnless(model.settings.autoPlayNextEpisode, "needs auto-play on, its default")
        model.nextUpEpisode = PlayerNextUpEpisode(episode: episode, seriesId: "synthetic-series", seriesTitle: "Series")
        model.duration = 2_600
        model.currentTime = 2_600
        model.handleEndOfFile()
        XCTAssertTrue(model.showNextUpScreen)
        XCTAssertNotNil(model.nextUpCountdownSeconds, "the next episode counts down")

        model.sleepTimerDidExpire()

        XCTAssertNil(model.nextUpCountdownSeconds)
    }
}
