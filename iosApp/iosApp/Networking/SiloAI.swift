import Foundation

/// Typed facade over the native Silo **AI** endpoints — metadata
/// translation and subtitle translation/transcription.
///
/// Sibling to ``SiloAPI``: a separate actor keeps the AI surface
/// cohesive and independently testable rather than swelling the much
/// larger `SiloAPI`. Every call goes through ``APIv2Client``. The
/// Jellyfin-compat API does not mirror the AI trigger/status/job endpoints;
/// the Apple clients use the native API exclusively.
actor SiloAI {
    static let shared = SiloAI()

    private let v2: APIv2Client

    /// Subtitle job requests whose outcome is unknown: they may have started
    /// a job, so an identical request is not sent again until the user
    /// discards the hold. Process-local, like Android's
    /// `SubtitleAiCreateV2Api.unresolved`; it is not an offline queue.
    private var unresolvedCreations: Set<SubtitleCreationIntent> = []

    init(v2: APIv2Client = SiloAPI.shared.apiV2Client) {
        self.v2 = v2
    }

    // MARK: - Metadata

    /// The profile's metadata-translation capability + the on-view mode.
    func metadataAIStatus() async throws -> MetadataAIStatus {
        try await v2.metadataAIStatus()
    }

    /// The owner an AI action runs for. Capture it before the first await and
    /// pass it to ``translateDescription(contentId:targetLanguage:auth:)`` or
    /// ``translateSubtitle(_:auth:)``.
    func captureAuthority() async throws -> CapturedOrdinaryRequestAuth {
        try await v2.captureRequestOwner()
    }

    func matchesAuthority(_ auth: CapturedOrdinaryRequestAuth) async -> Bool {
        await v2.isCurrentOwner(auth)
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

    /// The subtitle-AI capability (translate + transcribe) for this viewer.
    func subtitleAIStatus() async throws -> SubtitleAIStatus {
        try await v2.subtitleAIStatus()
    }

    /// The current viewer's ASR quota.
    func subtitleAIQuota() async throws -> SubtitleAIQuota {
        try await v2.subtitleAIQuota()
    }

    /// Start a subtitle translate / transcribe / transcribe-translate job for
    /// the owner in `auth`. Sent once.
    ///
    /// A request whose outcome is unknown (see
    /// ``SubtitleCreationError/isUncertain(_:)``) is held: an identical
    /// request for the same owner throws ``SubtitleCreationError/unresolved``
    /// without being sent, until ``discardUnresolvedSubtitle(_:auth:)``. A
    /// success or a definite failure releases it.
    func translateSubtitle(_ body: TranslateSubtitleBody,
                           auth: CapturedOrdinaryRequestAuth) async throws -> SubtitleCreationResult {
        let wire = try APIv2SubtitleCreateBody(body)
        let intent = SubtitleCreationIntent(wire, auth: auth)
        guard unresolvedCreations.insert(intent).inserted else { throw SubtitleCreationError.unresolved }
        do {
            let result = try await v2.createSubtitle(wire, auth: auth)
            unresolvedCreations.remove(intent)
            return result
        } catch {
            if !SubtitleCreationError.isUncertain(error) { unresolvedCreations.remove(intent) }
            throw error
        }
    }

    /// Drop the hold on a request whose outcome stayed unknown, so the user
    /// can send it again. The earlier request may still have started a job.
    func discardUnresolvedSubtitle(_ body: TranslateSubtitleBody, auth: CapturedOrdinaryRequestAuth) {
        guard let wire = try? APIv2SubtitleCreateBody(body) else { return }
        unresolvedCreations.remove(SubtitleCreationIntent(wire, auth: auth))
    }

    /// One snapshot of a job, read for the owner that started it.
    func subtitleJob(id: String, auth: CapturedOrdinaryRequestAuth? = nil) async throws -> SubtitleJob {
        try await v2.subtitleJob(id: id, auth: auth)
    }

    /// Request cancellation of a running job (204, no body).
    func cancelSubtitleJob(id: String, auth: CapturedOrdinaryRequestAuth? = nil) async throws {
        try await v2.cancelSubtitleJob(id: id, auth: auth)
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

/// What makes two subtitle job requests the same request: the owner, the
/// file, and the job asked for. The playhead and the live session are left
/// out, so a moved playhead or a new session cannot turn a lost receipt into
/// a second job for the same source.
private struct SubtitleCreationIntent: Hashable {
    let account: RefreshAccountIdentity
    let profileId: String?
    let mediaFileId: String
    let kind: SubtitleAIKind
    let sourceIndex: Int
    let sourceLanguage: String
    let targetLanguage: String

    init(_ body: APIv2SubtitleCreateBody, auth: CapturedOrdinaryRequestAuth) {
        account = auth.account
        profileId = auth.profileId
        mediaFileId = body.mediaFileId
        kind = body.kind
        sourceIndex = body.sourceIndex
        sourceLanguage = body.sourceLanguage
        targetLanguage = body.targetLanguage
    }
}
