import Foundation

/// Lets a page that started playback reload only after the player's final
/// progress write. The page calls `beginPlayback()` before presenting the
/// player, each `PlayerViewModel` notes `generation` when it is created, and
/// `PlayerViewModel.cleanup()` records its teardown under that generation.
/// The page then waits for a cleanup from a player created for its playback.
@MainActor
enum PlayerCleanupBarrier {
    /// The most recent teardowns, each under the generation its player was
    /// created in. A newer player's teardown never replaces an older one a
    /// page may still be waiting for.
    private static var cleanups: [(generation: Int, cleanup: Task<Void, Never>)] = []
    private static let retainedCleanups = 8
    /// Bumped each time a page starts playback.
    private(set) static var generation = 0
    /// Generations a player was created in. A page whose playback went to a TV
    /// instead never gets a local player, so it has nothing to wait for, even
    /// after another page's player is created. It grows by one entry per
    /// playback and is never pruned, so a player that stays open while others
    /// start, as in a second Mac window, keeps its page's wait.
    private static var playerGenerations: Set<Int> = []

    /// Starts a new generation for the player a page is about to present and
    /// returns it for `waitForCleanup(of:)`.
    static func beginPlayback() -> Int {
        generation &+= 1
        return generation
    }

    /// Called as a player is created; returns the generation it belongs to.
    static func playerCreated() -> Int {
        playerGenerations.insert(generation)
        return generation
    }

    /// Records a player's teardown under the generation it was created in.
    static func record(_ cleanup: Task<Void, Never>, generation: Int) {
        cleanups.append((generation, cleanup))
        if cleanups.count > retainedCleanups {
            cleanups.removeFirst(cleanups.count - retainedCleanups)
        }
    }

    /// Returns once the cleanups of players created in `generation` or later
    /// finish. An older player's teardown, such as one in Picture in Picture
    /// ended by a newer player, never answers for this one. The page can
    /// reappear before its player's teardown starts, so this waits up to
    /// `grace` for a cleanup from `generation` itself. A player that stays
    /// alive past the grace, such as one in Picture in Picture, does not hold
    /// the page, and a playback that created no player returns at once. A
    /// caller cancelled before the teardowns are awaited returns without them.
    static func waitForCleanup(of generation: Int, grace: Duration = .seconds(1)) async {
        guard playerGenerations.contains(generation) else { return }
        let deadline = ContinuousClock.now + grace
        while !cleanups.contains(where: { $0.generation == generation }),
              ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
        guard !Task.isCancelled else { return }
        for entry in cleanups where entry.generation >= generation {
            await entry.cleanup.value
        }
    }
}
