import XCTest
@testable import Silo

@MainActor
final class PlayerCleanupBarrierTests: XCTestCase {
    func testWaitsForTheFinalWriteOfACleanupRecordedAfterPresentation() async {
        let generation = PlayerCleanupBarrier.generation
        var finalWriteDone = false
        let waiter = Task { @MainActor in
            await PlayerCleanupBarrier.waitForCleanup(after: generation)
            return finalWriteDone
        }
        // The page reappears first; the player's teardown starts afterwards.
        await Task.yield()
        PlayerCleanupBarrier.record(Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            finalWriteDone = true
        })

        let sawFinalWrite = await waiter.value
        XCTAssertTrue(sawFinalWrite)
    }

    func testAnEarlierPlayersCleanupDoesNotHoldTheReload() async {
        let earlier = Task { @MainActor in _ = try? await Task.sleep(for: .seconds(30)) }
        PlayerCleanupBarrier.record(earlier)
        defer { earlier.cancel() }
        let generation = PlayerCleanupBarrier.generation

        let start = ContinuousClock.now
        await PlayerCleanupBarrier.waitForCleanup(after: generation, grace: .milliseconds(50))

        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }
}
