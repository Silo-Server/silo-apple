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
/// Metadata AI, stored subtitles and provider search go through
/// ``APIv2Client``; the subtitle AI paths are still on the native `/api/v1`
/// API. The Jellyfin-compat
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

    /// Stored subtitle tracks for a media file, in server order. Used to
    /// locate the persisted track by `result_subtitle_id` after a job
    /// completes, or by ID after a provider download.
    ///
    /// Each row has an opaque `id` and metadata, **no** combined `index` and
    /// **no** stream `url`; the player synthesizes those at handoff time,
    /// mirroring Android's `SubtitleTrackMerge`. Pass the owner a download
    /// ran for so the listing is read for that owner too.
    func downloadedSubtitles(mediaFileId: Int,
                             auth: CapturedOrdinaryRequestAuth? = nil) async throws -> [DownloadedSubtitle] {
        try await v2.storedSubtitles(mediaFileID: mediaFileId, auth: auth)
    }

    // MARK: - Subtitle provider search

    /// Whether this viewer can search external subtitle providers here.
    /// ``SubtitleProvidersStore`` owns how a failed probe is treated.
    func subtitleProvidersStatus() async throws -> APIv2SubtitleProviderStatus {
        try await v2.subtitleProviderStatus()
    }

    /// Synchronous fan-out search across the server's configured external
    /// subtitle providers. Can legitimately take 20–30s (per-provider
    /// timeouts), so it opts out of the fail-fast timeout via `.extended`.
    func searchSubtitles(_ body: SubtitleSearchBody) async throws -> SubtitleSearchResponse {
        try await v2.searchSubtitles(body)
    }

    /// Synchronously download one chosen search result for `auth`. The
    /// server fetches from the upstream provider and persists before
    /// responding. Sent once: see ``APIv2Client/downloadSubtitle(_:auth:)``
    /// for the outcomes a caller must tell apart.
    func downloadSubtitle(_ body: SubtitleDownloadBody,
                          auth: CapturedOrdinaryRequestAuth) async throws -> DownloadedSubtitle {
        try await v2.downloadSubtitle(body, auth: auth)
    }
}
