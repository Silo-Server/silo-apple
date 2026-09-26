import AVFoundation
import Foundation

/// Keeps one AVPlayer's external-playback flags at the value a policy owner decides.
///
/// Other hosts bound to the same player (AVKit, the system) can write these flags
/// at any time. The guard observes them by KVO and turns a forbidden route back
/// off on every change, so enforcement does not depend on who runs last.
///
/// KVO enforcement is one-directional: it only corrects `true` to `false`. The
/// security concern runs one way (a credentialed stream must not reach an AirPlay
/// receiver), and fighting a writer that disables AirPlay could ping-pong with the
/// system. `apply()` still writes either value when the owner re-evaluates.
@MainActor
final class ExternalPlaybackPolicyGuard {
    /// The value the player's flags must hold, or nil to leave this player alone
    /// (for example, a player the engine no longer publishes).
    typealias Policy = @MainActor (AVPlayer) -> Bool?

    private let policy: Policy
    private var observations: [NSKeyValueObservation] = []
    private(set) weak var player: AVPlayer?

    init(policy: @escaping Policy) {
        self.policy = policy
    }

    /// Invalidates the previous player's observations, observes the new player, then calls `apply()`.
    func bind(to player: AVPlayer?) {
        observations.forEach { $0.invalidate() }
        observations = []
        self.player = player
        if let player {
            observations.append(observeFlag(\.allowsExternalPlayback, of: player))
            #if os(iOS)
            observations.append(observeFlag(\.usesExternalPlaybackWhileExternalScreenIsActive, of: player))
            #endif
        }
        apply()
    }

    /// Explicit re-evaluation: writes the policy value in either direction, but only when it differs.
    func apply() {
        guard let player, let allowed = policy(player) else { return }
        write(allowed, to: player)
    }

    private func observeFlag(_ keyPath: KeyPath<AVPlayer, Bool>, of player: AVPlayer) -> NSKeyValueObservation {
        player.observe(keyPath, options: [.new]) { [weak self] player, _ in
            // KVO runs on the writer's thread. Correct a main-thread writer
            // before its setter returns; hop for any other thread.
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self?.correctReopenedPlayback(of: player)
                }
            } else {
                Task { @MainActor [weak self, weak player] in
                    guard let player else { return }
                    self?.correctReopenedPlayback(of: player)
                }
            }
        }
    }

    private func correctReopenedPlayback(of player: AVPlayer) {
        guard self.player === player, policy(player) == false else { return }
        write(false, to: player)
    }

    /// Each write is skipped when the flag already holds the value, so the KVO
    /// notification a write triggers comes back as a no-op.
    private func write(_ allowed: Bool, to player: AVPlayer) {
        if player.allowsExternalPlayback != allowed {
            player.allowsExternalPlayback = allowed
        }
        #if os(iOS)
        if player.usesExternalPlaybackWhileExternalScreenIsActive != allowed {
            player.usesExternalPlaybackWhileExternalScreenIsActive = allowed
        }
        #endif
    }
}
