import Foundation

/// Caches the v2 provider capability for the player's subtitle search control.
/// A disabled response turns search off. A failed read retains the last known
/// value; the initial value permits search while capability is unknown.
/// Reset invalidates any request still running for a previous account/profile.
@MainActor
@Observable
final class SubtitleProvidersStore {
    static let shared = SubtitleProvidersStore()

    /// Whether the "Search Subtitles…" entry point should be *enabled*.
    ///
    /// Starts `true` and only ever goes `false` on an affirmative
    /// `{"enabled": false}` — see the fail-open rationale in the type doc.
    /// The optimistic default also means there is no visible flicker during
    /// the startup probe: the row is enabled, and at worst it dims a moment
    /// later on a server that really has no providers.
    private(set) var isAvailable = true

    /// Bumped on every `reset()` so a probe that finishes after a sign-out
    /// or profile switch discards its result instead of repopulating the
    /// next account's flag.
    private var generation = 0

    private let api: SiloAI

    init(api: SiloAI = .shared) {
        self.api = api
    }

    func refresh() async {
        let gen = generation
        let status = try? await api.subtitleProvidersStatus()
        guard gen == generation else { return }
        guard let status else {
            // A failed capability read does not establish disabled state.
            return
        }
        isAvailable = status.enabled
    }

    /// Invalidate the previous scope's probe and restore unknown availability.
    func reset() {
        generation &+= 1
        isAvailable = true
    }
}
