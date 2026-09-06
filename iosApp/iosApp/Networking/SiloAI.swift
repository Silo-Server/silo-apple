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
/// Subtitle capability, stored-track, and search reads use API v2. Other operations retain their
/// existing native routes until their server contracts migrate.
actor SiloAI {
    static let shared = SiloAI()

    private let http: HTTPClient
    private let v2: APIv2Client
    private struct CreationAttempt {
        let id: UUID
        let auth: CapturedOrdinaryRequestAuth
        let body: APIv2SubtitleCreateBody
    }
    private var unresolvedCreations: [CreationAttempt] = []

    init(http: HTTPClient = .shared, v2: APIv2Client? = nil) {
        self.http = http
        self.v2 = v2 ?? APIv2Client(http: http)
    }

    // MARK: - Metadata

    /// Server-wide metadata-translation capability + the on-view mode.
    func metadataAIStatus() async throws -> MetadataAIStatus {
        try await v2.metadataAIStatus()
    }

    /// Kick off an on-demand description translation for `contentId`.
    /// Returns the bare v2 job; a recent failed job may be reused. Observe
    /// completion through bounded item-detail reads, never by replaying the POST.
    func translateDescription(contentId: String, targetLanguage: String, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2MetadataTranslationJob {
        try await v2.translateDescription(contentID: contentId, language: targetLanguage, auth: auth)
    }

    func matchesAuthority(_ auth: CapturedOrdinaryRequestAuth) async -> Bool {
        await v2.matchesAIAuthority(auth)
    }

    // MARK: - Subtitles

    /// Server-wide subtitle-AI capability (translate + transcribe).
    func subtitleAIStatus() async throws -> SubtitleAIStatus {
        try await v2.requestGet("/api/v2/subtitles/ai/status")
    }

    /// The current user's ASR quota.
    func subtitleAIQuota() async throws -> SubtitleAIQuota {
        try await v2.requestGet("/api/v2/subtitles/ai/quota")
    }

    /// Start a subtitle translate / transcribe / transcribe-translate job.
    func captureCreationAuthority() async throws -> CapturedOrdinaryRequestAuth {
        try await v2.subtitleCreateAuthority()
    }

    func translateSubtitle(_ body: TranslateSubtitleBody, auth: CapturedOrdinaryRequestAuth) async throws -> SubtitleCreationResult {
        let wire = try APIv2SubtitleCreateBody(body)
        guard !unresolvedCreations.contains(where: {
            $0.auth.account == auth.account && $0.auth.profileId == auth.profileId
                && $0.body.mediaFileId == wire.mediaFileId && $0.body.kind == wire.kind
                && $0.body.sourceIndex == wire.sourceIndex && $0.body.sourceLanguage == wire.sourceLanguage
                && $0.body.targetLanguage == wire.targetLanguage
        }) else { throw SubtitleCreationError.unresolved }
        let attempt = CreationAttempt(id: UUID(), auth: auth, body: wire)
        unresolvedCreations.append(attempt)
        // Retain after any failed/uncertain dispatch. No retry, rebase or fallback.
        let result = try await v2.createSubtitle(wire, auth: auth)
        unresolvedCreations.removeAll { $0.id == attempt.id }
        return result
    }

    /// Poll a single job by id.
    func subtitleJob(id: String) async throws -> SubtitleJob {
        guard let value = Int64(id), value > 0, String(value) == id else {
            throw APIv2Error.invalidSubtitleResponse
        }
        let envelope: APIv2SubtitleJobEnvelope = try await v2.requestGet("/api/v2/subtitles/ai/jobs/\(id)")
        return try SubtitleJob(v2: envelope.job, expectedJobID: id)
    }

    /// Request cancellation of a running job (204, no body).
    func cancelSubtitleJob(id: String) async throws {
        try await v2.cancelSubtitleJob(id: id)
    }

    /// Downloaded subtitle tracks for a media file. Used to locate the
    /// persisted track by `result_subtitle_id` after a job completes.
    ///
    /// Returns the server's `DownloadedSubtitle` shape (`id` + metadata, **no**
    /// combined `index`, **no** stream `url`); the player synthesizes those at
    /// handoff time, mirroring Android's `SubtitleTrackMerge`.
    func downloadedSubtitles(mediaFileId: Int) async throws -> [DownloadedSubtitle] {
        let response: APIv2StoredSubtitles = try await v2.requestGet("/api/v2/subtitles/\(mediaFileId)")
        return try response.subtitles.map { try $0.playerValue(mediaFileID: mediaFileId) }
    }

    // MARK: - Subtitle provider search

    /// Whether the server has any external subtitle providers configured.
    ///
    /// The v2 route returns explicit disabled state when no providers are
    /// configured. Errors retain the store's last known availability.
    func subtitleProvidersStatus() async throws -> SubtitleProvidersStatus {
        try await v2.requestGet("/api/v2/subtitles/providers/status")
    }

    /// Synchronous fan-out search across the server's configured external
    /// subtitle providers. Can legitimately take 20–30s (per-provider
    /// timeouts), so it opts out of the fail-fast timeout via `.extended`.
    /// No providers configured yields an empty result set, not an error.
    func searchSubtitles(_ body: SubtitleSearchBody) async throws -> SubtitleSearchResponse {
        let response: APIv2SubtitleSearchResponse = try await v2.requestPost("/api/v2/subtitles/search",
            body: APIv2SubtitleSearchBody(body), timeout: .extended)
        return response.playerValue
    }

    /// Synchronously download one chosen search result. The server fetches
    /// from the upstream provider and persists before responding — another
    /// legitimately slow call, so `.extended`. The returned
    /// ``DownloadedSubtitle`` then appears in
    /// ``downloadedSubtitles(mediaFileId:)``.
    func downloadSubtitle(_ body: SubtitleDownloadBody, expectedAuth: CapturedOrdinaryRequestAuth? = nil) async throws -> DownloadedSubtitle {
        try await v2.downloadSubtitle(body, expectedAuth: expectedAuth)
    }
}
