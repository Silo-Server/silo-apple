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

    /// Whether the server lets a viewer follow a title someone else already
    /// requested ("Notify Me"). False whenever `isEnabled` is.
    private(set) var followSupported = false

    /// True once a probe for the current session has answered. `isEnabled`
    /// reads false before that answer as well as after it, so only this pair
    /// can tell "requests are off" from "not known yet".
    private(set) var isResolved = false

    /// The server answered that requests are unavailable. Open Requests
    /// screens close on this, never on the unknown state before the first
    /// answer or after a reset, and never on a failed probe.
    var isKnownUnavailable: Bool { isResolved && !isEnabled }

    /// Bumped on every `reset()` so a probe that finishes after a sign-out
    /// or profile switch discards its result instead of repopulating the
    /// next account's flag.
    private var generation = 0

    /// Probes are numbered as they start, and an answer counts only if no
    /// newer probe has answered yet: an older "available" can't undo a newer
    /// "disabled", and a newer probe that fails doesn't discard an older
    /// probe's answer.
    private var probesStarted = 0
    private var newestAnswer = 0

    private let probe: @MainActor () async throws -> RequestsFeatureStatus

    convenience init(api: SiloAPI = .shared) {
        self.init(probe: { try await api.requestsStatus() })
    }

    init(probe: @escaping @MainActor () async throws -> RequestsFeatureStatus) {
        self.probe = probe
    }

    func refresh() async {
        probesStarted &+= 1
        let ordinal = probesStarted
        let gen = generation
        let status = try? await probe()
        // On error, keep the previous value: a transient failure shouldn't
        // yank an already-visible entry point, and foreground/auth-state
        // transitions retry naturally.
        guard gen == generation, ordinal > newestAnswer, let status else { return }
        newestAnswer = ordinal
        // Follow support first, so nothing that watches `isEnabled` reads a
        // stale value of it.
        followSupported = status.isAvailable && status.followSupported == true
        isEnabled = status.isAvailable
        isResolved = true
    }

    func reset() {
        generation &+= 1
        isEnabled = false
        followSupported = false
        isResolved = false
    }

    /// A requests call failed because the server reports the requests
    /// capability off (turned off, not configured, or unsupported). Callers
    /// re-probe on this so entry points hide and open Requests screens close;
    /// the probe's answer, not the failed call, decides.
    nonisolated static func isCapabilityOff(_ error: Error) -> Bool {
        guard case APIv2Error.problem(let problem) = error else { return false }
        switch problem.identifier {
        case "capability_disabled", "capability_not_configured", "capability_unsupported":
            return true
        default:
            return false
        }
    }
}
