import Foundation

/// Lets a page that started playback reload only after the player's final
/// progress write. The page calls `beginPlayback()` before presenting the
/// player, each `PlayerViewModel` notes `generation` when it is created, and
/// `PlayerViewModel.cleanup()` records its teardown under that generation.
/// The page then waits for a cleanup from a player created for its playback.
@MainActor
enum PlayerCleanupBarrier {
    private static var latest: (generation: Int, cleanup: Task<Void, Never>)?
    /// Bumped each time a page starts playback.
    private(set) static var generation = 0

    /// Starts a new generation for the player a page is about to present and
    /// returns it for `waitForCleanup(of:)`.
    static func beginPlayback() -> Int {
        generation &+= 1
        return generation
    }

    /// Records a player's teardown under the generation it was created in, so
    /// an older player's teardown, such as one in Picture in Picture ended by
    /// a newer player, never answers for the newer player or replaces its
    /// cleanup.
    static func record(_ cleanup: Task<Void, Never>, generation: Int) {
        if let latest, latest.generation > generation { return }
        latest = (generation, cleanup)
    }

    /// Returns once a cleanup from a player created in `generation` or later
    /// finishes. The page can reappear before the cover's teardown starts, so
    /// this waits up to `grace` for that cleanup to be recorded. A player that
    /// stays alive past the grace, such as one in Picture in Picture, does
    /// not hold the page.
    static func waitForCleanup(of generation: Int, grace: Duration = .seconds(1)) async {
        let deadline = ContinuousClock.now + grace
        while cleanup(of: generation) == nil, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        await cleanup(of: generation)?.value
    }

    private static func cleanup(of generation: Int) -> Task<Void, Never>? {
        guard let latest, latest.generation >= generation else { return nil }
        return latest.cleanup
    }
}
