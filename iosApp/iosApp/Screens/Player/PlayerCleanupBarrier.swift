import Foundation

/// Lets a page that started playback reload only after the player's final
/// progress write. `PlayerViewModel.cleanup()` records its teardown here;
/// the page reads `generation` when it presents the player and later waits
/// for the first cleanup recorded after that.
@MainActor
enum PlayerCleanupBarrier {
    private static var latest: Task<Void, Never>?
    /// Bumped by every recorded cleanup.
    private(set) static var generation = 0

    static func record(_ cleanup: Task<Void, Never>) {
        latest = cleanup
        generation &+= 1
    }

    /// Returns once the first cleanup recorded after `generation` finishes.
    /// The page can reappear before the cover's teardown starts, so this
    /// waits up to `grace` for that cleanup to be recorded. A player that
    /// stays alive past the grace, such as one in Picture in Picture, does
    /// not hold the page.
    static func waitForCleanup(after generation: Int, grace: Duration = .seconds(1)) async {
        let deadline = ContinuousClock.now + grace
        while self.generation == generation, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard self.generation != generation else { return }
        await latest?.value
    }
}
