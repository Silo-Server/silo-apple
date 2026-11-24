import Foundation

/// The rating sources the server shows, from `GET /api/v2/capabilities/ratings`.
///
/// Sort lists offer a rating sort (RT Critic, RT Audience) only while its
/// source is shown, as the web client does. Follows `ShuffleFeatureStore`:
/// probed once per session, reset on profile and server switch, and a failed
/// probe keeps the previous answer. Empty until the first answer, so a rating
/// the server may hide is never offered early.
@MainActor
@Observable
final class RatingSourcesStore {
    static let shared = RatingSourcesStore()

    private(set) var shown: Set<String> = []

    /// Bumped on every `reset()` so a probe that finishes after a sign-out or
    /// profile switch discards its result.
    private var generation = 0

    private let api: SiloAPI

    init(api: SiloAPI = .shared) {
        self.api = api
    }

    func refresh() async {
        let gen = generation
        let probed = try? await api.shownRatingSources()
        guard gen == generation else { return }
        if let probed { shown = probed }
    }

    func reset() {
        generation &+= 1
        shown = []
    }
}
