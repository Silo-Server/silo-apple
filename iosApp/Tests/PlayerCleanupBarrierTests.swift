import XCTest
@testable import Silo

@MainActor
final class PlayerCleanupBarrierTests: XCTestCase {
    func testWaitsForTheFinalWriteOfACleanupRecordedAfterPresentation() async {
        let generation = PlayerCleanupBarrier.beginPlayback()
        _ = PlayerCleanupBarrier.playerCreated()
        var finalWriteDone = false
        let waiter = Task { @MainActor in
            await PlayerCleanupBarrier.waitForCleanup(of: generation)
            return finalWriteDone
        }
        // The page reappears first; the player's teardown starts afterwards.
        await Task.yield()
        PlayerCleanupBarrier.record(Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            finalWriteDone = true
        }, generation: generation)

        let sawFinalWrite = await waiter.value
        XCTAssertTrue(sawFinalWrite)
    }

    func testAnEarlierPlayersCleanupDoesNotHoldTheReload() async {
        let earlier = Task { @MainActor in _ = try? await Task.sleep(for: .seconds(30)) }
        PlayerCleanupBarrier.record(earlier, generation: PlayerCleanupBarrier.generation)
        defer { earlier.cancel() }
        let generation = PlayerCleanupBarrier.beginPlayback()
        _ = PlayerCleanupBarrier.playerCreated()

        let start = ContinuousClock.now
        await PlayerCleanupBarrier.waitForCleanup(of: generation, grace: .milliseconds(50))

        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }

    func testAPictureInPicturePlayerEndingAfterPresentationDoesNotEndTheWait() async {
        // Player A is in Picture in Picture when the page starts playback.
        let pictureInPictureGeneration = PlayerCleanupBarrier.generation
        let generation = PlayerCleanupBarrier.beginPlayback()
        _ = PlayerCleanupBarrier.playerCreated()
        // The new player binds Picture in Picture, which tears A down.
        PlayerCleanupBarrier.record(Task {}, generation: pictureInPictureGeneration)
        var finalWriteDone = false
        let waiter = Task { @MainActor in
            await PlayerCleanupBarrier.waitForCleanup(of: generation)
            return finalWriteDone
        }
        // The page reappears before the new player's teardown starts.
        await Task.yield()
        PlayerCleanupBarrier.record(Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            finalWriteDone = true
        }, generation: generation)

        let sawFinalWrite = await waiter.value
        XCTAssertTrue(sawFinalWrite)
    }

    func testANewerPlayersCleanupDoesNotReplaceTheOneThePageWaitsFor() async {
        let generation = PlayerCleanupBarrier.beginPlayback()
        _ = PlayerCleanupBarrier.playerCreated()
        var finalWriteDone = false
        PlayerCleanupBarrier.record(Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            finalWriteDone = true
        }, generation: generation)
        // Another playback starts and its player closes at once, before the
        // page's reload runs.
        let newer = PlayerCleanupBarrier.beginPlayback()
        _ = PlayerCleanupBarrier.playerCreated()
        PlayerCleanupBarrier.record(Task {}, generation: newer)

        await PlayerCleanupBarrier.waitForCleanup(of: generation)

        XCTAssertTrue(finalWriteDone)
    }

    func testAPlaybackThatCreatedNoPlayerDoesNotHoldTheReload() async {
        // Play went to an engaged TV, so no local player was created.
        let generation = PlayerCleanupBarrier.beginPlayback()

        let start = ContinuousClock.now
        await PlayerCleanupBarrier.waitForCleanup(of: generation)

        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(500))
    }

    func testAPlaybackThatCreatedNoPlayerIgnoresALaterPagesPlayer() async {
        // Play went to an engaged TV; another page then played here.
        let generation = PlayerCleanupBarrier.beginPlayback()
        _ = PlayerCleanupBarrier.beginPlayback()
        _ = PlayerCleanupBarrier.playerCreated()

        let start = ContinuousClock.now
        await PlayerCleanupBarrier.waitForCleanup(of: generation)

        XCTAssertLessThan(ContinuousClock.now - start, .milliseconds(500))
    }

    func testPlaysThatWentToATVDoNotDropAPendingTeardown() async {
        let generation = PlayerCleanupBarrier.beginPlayback()
        _ = PlayerCleanupBarrier.playerCreated()
        var finalWriteDone = false
        PlayerCleanupBarrier.record(Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            finalWriteDone = true
        }, generation: generation)
        // Several Plays go to an engaged TV, then another page plays here.
        for _ in 0..<10 {
            _ = PlayerCleanupBarrier.beginPlayback()
        }
        _ = PlayerCleanupBarrier.playerCreated()

        await PlayerCleanupBarrier.waitForCleanup(of: generation)

        XCTAssertTrue(finalWriteDone)
    }

    func testAPlayerStillOpenWhileOthersStartKeepsItsPagesWait() async {
        let generation = PlayerCleanupBarrier.beginPlayback()
        _ = PlayerCleanupBarrier.playerCreated()
        // Other pages start and close players while this one stays open.
        for _ in 0..<10 {
            let other = PlayerCleanupBarrier.beginPlayback()
            _ = PlayerCleanupBarrier.playerCreated()
            PlayerCleanupBarrier.record(Task {}, generation: other)
        }
        var finalWriteDone = false
        PlayerCleanupBarrier.record(Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            finalWriteDone = true
        }, generation: generation)

        await PlayerCleanupBarrier.waitForCleanup(of: generation)

        XCTAssertTrue(finalWriteDone)
    }

    func testACancelledWaitReturnsBeforeTheTeardownFinishes() async {
        let generation = PlayerCleanupBarrier.beginPlayback()
        _ = PlayerCleanupBarrier.playerCreated()
        let teardown = Task { @MainActor in _ = try? await Task.sleep(for: .seconds(10)) }
        defer { teardown.cancel() }
        PlayerCleanupBarrier.record(teardown, generation: generation)
        // The page is hidden again while it waits.
        let waiter = Task { @MainActor in
            await PlayerCleanupBarrier.waitForCleanup(of: generation)
        }
        waiter.cancel()

        let start = ContinuousClock.now
        await waiter.value

        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }
}
