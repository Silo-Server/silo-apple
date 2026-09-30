import Foundation

/// Cached holder for the server's requests capability, gating
/// every media-request entry point (profile-menu row, tvOS dropdown row,
/// the "Available to request" search section).
///
/// Follows the `AICapabilities` precedent: a `@MainActor` `@Observable`
/// singleton, probed once per session and reset on profile/server switch.
/// The capability counts only when `allowed` and `state == available`
/// (`RequestsFeatureStatus.isAvailable`). A failed probe keeps the previous
/// value, which starts as "disabled", so entry points simply never render
/// and no error surfaces.
///
/// Reset + refresh hooks live in `AuthService`/`ServerRegistry`/`ContentView`
/// next to the existing `AICapabilities` calls.
@MainActor
@Observable
final class RequestsFeatureStore {
    static let shared = RequestsFeatureStore()

    /// False until the first successful probe reports the feature available.
    /// Hiding entry points during the brief startup probe is the correct
    /// default, so no separate loading state exists.
    private(set) var isEnabled = false

    /// Whether the signed-in user can moderate everyone's requests: an admin
    /// acting as the primary profile on a server with the integration
    /// configured. Probed only after `isEnabled`, and false on any failure.
    private(set) var canModerate = false

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
        // On error, keep the previous value: a transient failure shouldn't
        // yank an already-visible entry point, and foreground/auth-state
        // transitions retry naturally.
        let enabled = status?.isAvailable ?? isEnabled
        var moderates = canModerate
        if !enabled {
            moderates = false
        } else {
            do {
                moderates = try await api.adminRequestCapabilities().available
            } catch APIv2Error.problem {
                // The server answered: not an admin, not the primary
                // profile, or no integration configured.
                moderates = false
            } catch {
                // Transport trouble: keep the previous value.
            }
            guard gen == generation else { return }
        }
        // Published together, moderation first: a screen that appears when
        // Requests does already knows whether to load the approval queue.
        canModerate = moderates
        isEnabled = enabled
    }

    func reset() {
        generation &+= 1
        isEnabled = false
        canModerate = false
    }
}
