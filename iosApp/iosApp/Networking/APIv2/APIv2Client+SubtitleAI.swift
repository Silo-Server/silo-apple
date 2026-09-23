import Foundation

/// Subtitle AI: the capability, the viewer's ASR quota, and the translate /
/// transcribe job lifecycle. Every operation is profile scoped with an
/// optional profile and shares the transport in `APIv2Client+Subtitles.swift`.
///
/// `createSubtitle` is `non_retryable`: the server deduplicates active jobs
/// but keeps no replay receipt. It is sent once (no refresh-and-resend, see
/// `HTTPClient.shouldAttemptRefresh`), and an owner change once dispatch may
/// have begun is reported as an unknown outcome rather than a refusal. Cancel
/// is `natural_idempotent` for one job ID; polling decides the final state.
extension APIv2Client {
    // MARK: getSubtitleAIStatus

    func subtitleAIStatus() async throws -> SubtitleAIStatus {
        let status: APIv2SubtitleAIStatus = try await subtitlesCall(
            "GET", path: "/api/v2/subtitles/ai/status", status: 200, auth: captureSubtitleAuthority())
        guard !status.revision.isEmpty else { throw APIv2Error.incompleteCatalogRead }
        return status.playerValue
    }

    // MARK: getSubtitleAIQuota

    func subtitleAIQuota() async throws -> SubtitleAIQuota {
        let quota: APIv2SubtitleAIQuota = try await subtitlesCall(
            "GET", path: "/api/v2/subtitles/ai/quota", status: 200, auth: captureSubtitleAuthority())
        return quota.playerValue
    }

    // MARK: createSubtitleAIJob (non_retryable)

    /// Starts one job for the owner in `auth` and returns the 202 receipt.
    ///
    /// A refusal before dispatch throws `HTTPError.requestIdentityChanged` or
    /// `APIv2Error.serverUpdateRequired`; a server answer throws its problem.
    /// Once the request may have been sent, an owner change or a receipt for
    /// a different job throws `SubtitleCreationError.outcomeUnknown`.
    func createSubtitle(_ body: APIv2SubtitleCreateBody, auth: CapturedOrdinaryRequestAuth) async throws -> SubtitleCreationResult {
        try await gate()
        guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.sameCredentialIdentity(as: auth) else {
            throw HTTPError.requestIdentityChanged
        }
        let data = try Self.encodeSubtitleBody(body)
        let identity = auth.profileId.map { Self.requestIdentity(auth, profile: $0) }
        let raw: HTTPRawResponse
        do {
            raw = try await tokenStore.withOwnerFence(auth) {
                try await mapErrors {
                    try await http.requestData(method: "POST", path: "/api/v2/subtitles/ai/translate", body: data,
                        headers: auth.profileId == nil ? ["X-Profile-Id": ""] : [:],
                        requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
                }
            }
        } catch HTTPError.authorityChanged, HTTPError.requestIdentityChanged {
            // `requestIdentityChanged` is raised both just before the bytes
            // leave and after the response arrives, so it cannot prove the
            // job was never started.
            throw SubtitleCreationError.outcomeUnknown
        }
        guard raw.statusCode == 202 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let response = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleCreateResponse.self, from: raw.data)
        guard response.job.mediaFileId == body.mediaFileId, response.job.kind == body.kind.rawValue,
              response.job.sourceIndex == body.sourceIndex,
              !response.liveDeliveryAttached || body.sessionId != nil,
              !response.job.id.isEmpty,
              let job = try? SubtitleJob(v2: response.job, expectedJobID: response.job.id) else {
            throw SubtitleCreationError.outcomeUnknown
        }
        return SubtitleCreationResult(job: job, liveDeliveryAttached: response.liveDeliveryAttached)
    }

    // MARK: getSubtitleAIJob

    /// One snapshot of `id`, read for the owner in `auth` (the current owner
    /// when nil). The job ID is opaque and path-segment encoded.
    func subtitleJob(id: String, auth: CapturedOrdinaryRequestAuth? = nil) async throws -> SubtitleJob {
        guard !id.isEmpty, let segment = try? catalogPathSegment(id) else { throw APIv2Error.invalidSubtitleResponse }
        let owner = try await subtitleJobOwner(auth)
        let wire: APIv2SubtitleJobEnvelope = try await subtitlesCall(
            "GET", path: "/api/v2/subtitles/ai/jobs/\(segment)", status: 200, auth: owner)
        return try SubtitleJob(v2: wire.job, expectedJobID: id)
    }

    // MARK: cancelSubtitleJob (natural_idempotent)

    /// Acknowledges a cancellation request; completion may already have won.
    func cancelSubtitleJob(id: String, auth: CapturedOrdinaryRequestAuth? = nil) async throws {
        guard !id.isEmpty, let segment = try? catalogPathSegment(id) else { throw APIv2Error.invalidSubtitleResponse }
        let owner = try await subtitleJobOwner(auth)
        let response = try await subtitlesRequest("POST", path: "/api/v2/subtitles/ai/jobs/\(segment)/cancel", auth: owner)
        guard response.statusCode == 204 else { throw APIv2Error.httpStatus(response.statusCode) }
    }

    /// The owner that started the job when known, otherwise the current owner.
    private func subtitleJobOwner(_ auth: CapturedOrdinaryRequestAuth?) async throws -> CapturedOrdinaryRequestAuth {
        if let auth { return auth }
        return try await captureSubtitleAuthority()
    }
}
