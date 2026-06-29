import Foundation

/// Cached holder for the server's AI capability probes, used to gate the
/// metadata-language setting, the on-view description-translation
/// affordance, and the in-player subtitle-AI controls.
///
/// Mirrors the `OverlayPrefsStore` precedent: a `@MainActor` observable
/// singleton, fetched once per session and reset on profile/server switch
/// so a later profile never inherits the previous one's capabilities or
/// ASR quota. Every probe is failure-tolerant — a `404`/network error on
/// any endpoint leaves that slot `nil`, which the gating booleans read as
/// "feature unavailable", so older servers degrade silently.
///
/// Reset + refresh hooks live in `AuthService` next to the existing
/// `ResponseCache` clears.
@MainActor
@Observable
final class AICapabilities {
    static let shared = AICapabilities()

    /// `GET /metadata/ai/status`. Nil until fetched or after `reset()`.
    private(set) var metadataStatus: MetadataAIStatus?
    /// `GET /subtitles/ai/status`. Nil until fetched or after `reset()`.
    private(set) var subtitleStatus: SubtitleAIStatus?
    /// `GET /subtitles/ai/quota`. Fetched on demand (when the subtitle
    /// menu opens), not as part of `refresh()`.
    private(set) var subtitleQuota: SubtitleAIQuota?

    private let api: ContinuumAI

    init(api: ContinuumAI = .shared) {
        self.api = api
    }

    // MARK: - Gating convenience

    /// Whether the metadata-language setting row + on-view affordance may
    /// appear at all.
    var metadataEnabled: Bool { metadataStatus?.enabled ?? false }

    /// How the item-detail translate affordance behaves. Defaults to
    /// `.off` when the probe hasn't landed or the feature is disabled.
    var metadataOnView: MetadataAIStatus.OnViewMode {
        guard let status = metadataStatus, status.enabled else { return .off }
        return status.onView
    }

    /// Whether the player's "Translate…" subtitle action may appear.
    var subtitleEnabled: Bool { subtitleStatus?.enabled ?? false }

    /// Whether the Whisper transcribe controls + quota gauge may appear.
    var transcribeEnabled: Bool {
        guard let status = subtitleStatus, status.enabled else { return false }
        return status.transcribeEnabled
    }

    // MARK: - Lifecycle

    /// Fetch the two status probes concurrently. Each is independently
    /// failure-tolerant: a thrown error leaves that slot `nil` rather than
    /// failing the whole refresh, so one disabled feature never hides the
    /// other.
    func refresh() async {
        async let metadata = fetchMetadataStatus()
        async let subtitle = fetchSubtitleStatus()
        let (meta, subs) = await (metadata, subtitle)
        metadataStatus = meta
        subtitleStatus = subs
    }

    /// Fetch the ASR quota on demand. Leaves the previous value in place
    /// on failure so a transient error doesn't blank the gauge.
    func refreshQuota() async {
        if let quota = try? await api.subtitleAIQuota() {
            subtitleQuota = quota
        }
    }

    /// Drop every cached probe. Called on sign-out and profile/server
    /// switch so capabilities + quota don't leak across accounts.
    func reset() {
        metadataStatus = nil
        subtitleStatus = nil
        subtitleQuota = nil
    }

    // MARK: - Internals

    private func fetchMetadataStatus() async -> MetadataAIStatus? {
        try? await api.metadataAIStatus()
    }

    private func fetchSubtitleStatus() async -> SubtitleAIStatus? {
        try? await api.subtitleAIStatus()
    }
}
