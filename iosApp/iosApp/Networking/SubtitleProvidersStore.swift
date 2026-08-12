import Foundation

/// Cached holder for whether the server has any external subtitle providers
/// configured (`GET /api/v1/subtitles/providers/status`), used to render the
/// in-player "Search Subtitles…" entry point as *disabled with a reason*
/// rather than letting it run a search that can only ever come back empty.
///
/// Without this probe, a server with no providers wired up answers
/// `POST /api/v1/subtitles/search` with `200 {"results": null}` — so the user
/// picks a language, waits out the 20–30s provider fan-out timeout, and gets
/// "No subtitles found for English.", which is indistinguishable from a real
/// empty result. That has already been reported as a broken feature when it
/// was only ever an unconfigured one.
///
/// Structurally this follows the ``AICapabilities`` / ``RequestsFeatureStore``
/// precedent: a `@MainActor` `@Observable` singleton, probed once per session,
/// reset on sign-out and profile/server switch, with a `generation` counter so
/// a probe that lands after a switch discards its result instead of
/// repopulating the next account's flag.
///
/// ## It FAILS OPEN — deliberately inverting the sibling stores' convention
///
/// `AICapabilities` and `RequestsFeatureStore` both treat a probe failure as
/// "feature off": a 404 there means an older server that genuinely lacks the
/// feature, so hiding the entry point is correct.
///
/// **This store must do the opposite.** Subtitle provider search shipped long
/// before its status endpoint did, so every server that predates the endpoint
/// 404s here while having a perfectly working search. Defaulting to disabled
/// would regress all of them at once. Therefore:
///
///   - ``isAvailable`` starts `true`, before any probe has run.
///   - A 404, a network error, a decode failure — anything short of an
///     affirmative answer — leaves it `true`.
///   - Only an explicit `{"enabled": false}` from a server that *does*
///     implement the endpoint may turn the entry point off.
///
/// The wire model (``SubtitleProvidersStatus``) carries the same bias: a
/// missing `enabled` key decodes to `true`, not `false`.
///
/// Reset + refresh hooks live in `AuthService`/`ServerRegistry`/`ContentView`
/// next to the existing `AICapabilities` calls.
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

    private let api: ContinuumAI

    init(api: ContinuumAI = .shared) {
        self.api = api
    }

    func refresh() async {
        let gen = generation
        let status = try? await api.subtitleProvidersStatus()
        guard gen == generation else { return }
        guard let status else {
            // Fail open. A thrown error here is overwhelmingly likely to be a
            // 404 from a server that predates the endpoint (where search
            // works fine), or a transient network blip. Neither is evidence
            // that providers are unconfigured, so leave the previous value —
            // which, absent an affirmative answer, is `true`.
            return
        }
        isAvailable = status.enabled
    }

    /// Drop the cached probe on sign-out and profile/server switch.
    ///
    /// Note the restore value is `true`, **not** `false` as in the sibling
    /// stores: the next server is presumed capable until it says otherwise,
    /// for the same reason the initial value is `true`. Resetting to `false`
    /// would leave the row disabled on every older server between the switch
    /// and the (never-succeeding) probe.
    func reset() {
        generation &+= 1
        isAvailable = true
    }
}
