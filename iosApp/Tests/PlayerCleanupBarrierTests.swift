import XCTest
@testable import Silo

@MainActor
final class PlayerCleanupBarrierTests: XCTestCase {
    func testWaitsForTheFinalWriteOfACleanupRecordedAfterPresentation() async {
        let generation = PlayerCleanupBarrier.beginPlayback()
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

        let start = ContinuousClock.now
        await PlayerCleanupBarrier.waitForCleanup(of: generation, grace: .milliseconds(50))

        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }

    func testAPictureInPicturePlayerEndingAfterPresentationDoesNotEndTheWait() async {
        // Player A is in Picture in Picture when the page starts playback.
        let pictureInPictureGeneration = PlayerCleanupBarrier.generation
        let generation = PlayerCleanupBarrier.beginPlayback()
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
}
