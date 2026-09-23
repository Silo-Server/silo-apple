import Foundation

/// Metadata AI: the viewer-facing capability and the on-view description
/// translation. Both are profile scoped and send `X-Profile-Id`.
extension APIv2Client {
    // MARK: getMetadataAICapability

    /// Enabled only when the profile is `allowed` and the state is `available`.
    func metadataAIStatus() async throws -> MetadataAIStatus {
        let data = try await settingsRead("/api/v2/capabilities/metadata-ai", profileRequired: true)
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2MetadataAICapability.self, from: data)
        guard !wire.revision.isEmpty else { throw APIv2Error.incompleteCatalogRead }
        return wire.playerValue
    }

    // MARK: translateCatalogItemDescription

    /// Queues the translation for the owner in `auth` and returns the 202 job.
    /// The contract marks this `coalescing`: the server reuses an active job,
    /// and may return a recently failed one without starting new work.
    func translateDescription(contentID: String, language: String,
                              auth: CapturedOrdinaryRequestAuth) async throws -> APIv2MetadataTranslationJob {
        try await gate()
        guard let profile = auth.profileId, await matchesAIAuthority(auth), !contentID.isEmpty,
              !language.isEmpty else {
            throw HTTPError.requestIdentityChanged
        }
        let segment = try catalogPathSegment(contentID)
        let identity = Self.requestIdentity(auth, profile: profile)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(APIv2TranslateDescriptionBody(targetLanguage: language))
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "POST", path: "/api/v2/catalog/items/\(segment)/translate-description",
                    body: body, requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        guard raw.statusCode == 202 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let job = try HTTPClient.makeJSONDecoder().decode(APIv2MetadataTranslationJob.self, from: raw.data)
        guard !job.id.isEmpty, job.contentId == contentID, ["item", "season", "episode"].contains(job.targetKind) else {
            throw APIv2Error.incompleteCatalogRead
        }
        return job
    }
}
