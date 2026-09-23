import Foundation

/// Typed facade over the native Silo **AI** endpoints — metadata
/// translation and subtitle translation/transcription.
///
/// Sibling to ``SiloAPI``: a separate actor keeps the AI surface
/// cohesive and independently testable rather than swelling the much
/// larger `SiloAPI`. Methods are thin pass-throughs over
/// ``HTTPClient/shared``; snake_case auto-converts both ways, so the wire
/// shapes in ``AIModels`` stay camelCase.
///
/// Metadata AI goes through ``APIv2Client``; the subtitle paths are still on
/// the native `/api/v1` API. The Jellyfin-compat
/// API does not mirror the AI trigger/status/job endpoints; the Apple
/// clients use the native API exclusively.
actor SiloAI {
    static let shared = SiloAI()

    private let http: HTTPClient
    private let v2: APIv2Client

    init(http: HTTPClient = .shared, v2: APIv2Client = SiloAPI.shared.apiV2Client) {
        self.http = http
        self.v2 = v2
    }

    // MARK: - Metadata

    /// The profile's metadata-translation capability + the on-view mode.
    func metadataAIStatus() async throws -> MetadataAIStatus {
        try await v2.metadataAIStatus()
    }

    /// The owner a description translation runs for. Capture it before the
    /// first await and pass it to ``translateDescription(contentId:targetLanguage:auth:)``.
    func captureAuthority() async throws -> CapturedOrdinaryRequestAuth {
        try await v2.captureAIAuthority()
    }

    func matchesAuthority(_ auth: CapturedOrdinaryRequestAuth) async -> Bool {
        await v2.matchesAIAuthority(auth)
    }

    /// Queue an on-demand description translation for `contentId`. The 202
    /// job may be a recently failed one the server reused; observe
    /// completion by re-fetching the item detail until
    /// `pendingTranslationLanguage` clears.
    func translateDescription(contentId: String, targetLanguage: String,
                              auth: CapturedOrdinaryRequestAuth) async throws -> APIv2MetadataTranslationJob {
        try await v2.translateDescription(contentID: contentId, language: targetLanguage, auth: auth)
    }

    // MARK: - Subtitles

    /// Server-wide subtitle-AI capability (translate + transcribe).
    func subtitleAIStatus() async throws -> SubtitleAIStatus {
        try await http.get("/api/v1/subtitles/ai/status")
    }

    /// The current user's ASR quota.
    func subtitleAIQuota() async throws -> SubtitleAIQuota {
        try await http.get("/api/v1/subtitles/ai/quota")
    }

    /// Start a subtitle translate / transcribe / transcribe-translate job.
    func translateSubtitle(_ body: TranslateSubtitleBody) async throws -> SubtitleJob {
        let envelope: SubtitleJobEnvelope = try await http.post(
            "/api/v1/subtitles/ai/translate",
            body: body
        )
        return envelope.job
    }

    /// Poll a single job by id.
    func subtitleJob(id: String) async throws -> SubtitleJob {
        let envelope: SubtitleJobEnvelope = try await http.get("/api/v1/subtitles/ai/jobs/\(id)")
        return envelope.job
    }

    /// Request cancellation of a running job (204, no body).
    func cancelSubtitleJob(id: String) async throws {
        try await http.postVoid("/api/v1/subtitles/ai/jobs/\(id)/cancel")
    }

    /// Downloaded subtitle tracks for a media file. Used to locate the
    /// persisted track by `result_subtitle_id` after a job completes.
    ///
    /// Returns the server's `DownloadedSubtitle` shape (`id` + metadata, **no**
    /// combined `index`, **no** stream `url`); the player synthesizes those at
    /// handoff time, mirroring Android's `SubtitleTrackMerge`.
    func downloadedSubtitles(mediaFileId: Int) async throws -> [DownloadedSubtitle] {
        let response: DownloadedSubtitlesResponse = try await http.get(
            "/api/v1/subtitles/\(mediaFileId)"
        )
        return response.subtitles
    }

    // MARK: - Subtitle provider search

    /// Whether the server has any external subtitle providers configured.
    ///
    /// Available to any authenticated user, and answered `200` by every
    /// server that implements it (there is a fallback registration so it
    /// never 404s on an instance where the feature is unwired). Servers
    /// that predate the endpoint DO 404 — and those have working search, so
    /// the caller must treat a thrown error as "assume enabled". See
    /// ``SubtitleProvidersStore`` for that fail-open contract.
    func subtitleProvidersStatus() async throws -> SubtitleProvidersStatus {
        try await http.get("/api/v1/subtitles/providers/status")
    }

    /// Synchronous fan-out search across the server's configured external
    /// subtitle providers. Can legitimately take 20–30s (per-provider
    /// timeouts), so it opts out of the fail-fast timeout via `.extended`.
    /// No providers configured yields an empty result set, not an error.
    func searchSubtitles(_ body: SubtitleSearchBody) async throws -> SubtitleSearchResponse {
        try await http.post("/api/v1/subtitles/search", body: body, timeout: .extended)
    }

    /// Synchronously download one chosen search result. The server fetches
    /// from the upstream provider and persists before responding — another
    /// legitimately slow call, so `.extended`. The returned
    /// ``DownloadedSubtitle`` then appears in
    /// ``downloadedSubtitles(mediaFileId:)``.
    func downloadSubtitle(_ body: SubtitleDownloadBody) async throws -> DownloadedSubtitle {
        let response: SubtitleDownloadResponse = try await http.post(
            "/api/v1/subtitles/download",
            body: body,
            timeout: .extended
        )
        return response.subtitle
    }
}
