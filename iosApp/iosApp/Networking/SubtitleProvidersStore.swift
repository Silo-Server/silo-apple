import Foundation

/// Cached holder for whether this viewer can search external subtitle
/// providers (`GET /api/v2/subtitles/providers/status`), used to render the
/// in-player "Search Subtitles…" entry point as *disabled with a reason*
/// rather than letting it run a search that can only ever come back empty.
///
/// Without this probe, a server with no providers wired up answers a search
/// with an empty result set — so the user picks a language, waits out the
/// 20–30s provider fan-out timeout, and gets "No subtitles found for
/// English.", which is indistinguishable from a real empty result. That has
/// already been reported as a broken feature when it was only ever an
/// unconfigured one.
///
/// Structurally this follows the ``AICapabilities`` / ``RequestsFeatureStore``
/// precedent: a `@MainActor` `@Observable` singleton, probed once per session,
/// reset on sign-out and profile/server switch, with a `generation` counter so
/// a probe that lands after a switch discards its result instead of
/// repopulating the next account's flag.
///
/// ## Only an answer turns it off
///
///   - ``isAvailable`` starts `true`, before any probe has run.
///   - An answer sets it to ``APIv2SubtitleProviderStatus/isAvailable``:
///     `allowed`, state `available`, and a provider enabled.
///   - A failed probe (network error, server error, unreadable body) is not
///     an answer: it leaves the previous value, and the next refresh trigger
///     asks again. The search itself still reports its own errors.
///
/// Reset + refresh hooks live in `AuthService`/`ServerRegistry`/`ContentView`
/// next to the existing `AICapabilities` calls.
@MainActor
@Observable
final class SubtitleProvidersStore {
    static let shared = SubtitleProvidersStore()

    /// Whether the "Search Subtitles…" entry point should be *enabled*.
    ///
    /// Starts `true` and only goes `false` on an answer that says search is
    /// unavailable — see the type doc.
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
            // Not an answer: keep the previous value until the next refresh.
            return
        }
        isAvailable = status.isAvailable
    }

    /// Drop the cached probe on sign-out and profile/server switch.
    ///
    /// Note the restore value is `true`, **not** `false` as in the sibling
    /// stores: the next server is presumed capable until it says otherwise,
    /// for the same reason the initial value is `true`.
    func reset() {
        generation &+= 1
        isAvailable = true
    }
}
