import Foundation

/// Cached holder for the server's `requests_enabled` feature flag, gating
/// every media-request entry point (profile-menu row, tvOS dropdown row,
/// the "Available to request" search section).
///
/// Follows the `AICapabilities` precedent: a `@MainActor` `@Observable`
/// singleton, probed once per session and reset on profile/server switch.
/// The probe is failure-tolerant — a 404 (older server without the requests
/// API) or any transient error reads as "disabled", so entry points simply
/// never render and no error surfaces.
///
/// Reset + refresh hooks live in `AuthService`/`ServerRegistry`/`ContentView`
/// next to the existing `AICapabilities` calls.
@MainActor
@Observable
final class RequestsFeatureStore {
    static let shared = RequestsFeatureStore()

    /// False until the first successful probe reports the feature on.
    /// Hiding entry points during the brief startup probe is the correct
    /// default, so no separate loading state exists.
    private(set) var isEnabled = false

    /// Bumped on every `reset()` so a probe that finishes after a sign-out
    /// or profile switch discards its result instead of repopulating the
    /// next account's flag.
    private var generation = 0

    private let api: SiloAPI

    init(api: SiloAPI = .shared) {
        self.api = api
    }

    func refresh() async {
        let gen = generation
        let status = try? await api.requestsStatus()
        guard gen == generation else { return }
        if let status {
            isEnabled = status.requestsEnabled
        }
        // On error, keep the previous value: a transient failure shouldn't
        // yank an already-visible entry point, and foreground/auth-state
        // transitions retry naturally.
    }

    func reset() {
        generation &+= 1
        isEnabled = false
    }
}
