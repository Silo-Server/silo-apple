import Foundation

/// External subtitle providers and the stored subtitles of a media file.
/// Every operation is profile scoped with an optional profile: it sends the
/// selected profile when there is one and runs under the owner captured at
/// the start (or the one the caller passes in).
///
/// `downloadSubtitle` is `non_retryable`: the server fetches from the
/// upstream provider and keeps no replay receipt. It is sent once, and an
/// owner change after dispatch could have begun is reported as an unknown
/// outcome rather than a refusal. Search is `natural_idempotent` but runs a
/// 20-30 s provider fan-out, so it is not retried either.
extension APIv2Client {
    // MARK: getSubtitleProviderStatus

    func subtitleProviderStatus() async throws -> APIv2SubtitleProviderStatus {
        let status: APIv2SubtitleProviderStatus = try await subtitlesCall(
            "GET", path: "/api/v2/subtitles/providers/status", status: 200, auth: captureSubtitleAuthority())
        guard !status.revision.isEmpty else { throw APIv2Error.incompleteCatalogRead }
        return status
    }

    // MARK: listStoredSubtitles

    /// The file's stored subtitles in server order. The server leaves out
    /// rows it cannot canonicalize, so callers address a row by its `id`, not
    /// its position. A row that names another file fails the listing.
    func storedSubtitles(mediaFileID: Int, auth: CapturedOrdinaryRequestAuth? = nil) async throws -> [DownloadedSubtitle] {
        guard mediaFileID > 0 else { throw APIv2SubtitleRequestError.invalidMediaFile }
        let owner: CapturedOrdinaryRequestAuth
        if let auth { owner = auth } else { owner = try await captureSubtitleAuthority() }
        let wire: APIv2StoredSubtitles = try await subtitlesCall(
            "GET", path: "/api/v2/subtitles/\(mediaFileID)", status: 200, auth: owner)
        return try wire.playerValues(mediaFileID: mediaFileID)
    }

    // MARK: searchSubtitles (natural_idempotent)

    func searchSubtitles(_ body: SubtitleSearchBody) async throws -> SubtitleSearchResponse {
        guard body.mediaFileId > 0 else { throw APIv2SubtitleRequestError.invalidMediaFile }
        guard body.languages.count <= 100 else { throw APIv2SubtitleRequestError.tooManyLanguages }
        let wire: APIv2SubtitleSearchResponse = try await subtitlesCall(
            "POST", path: "/api/v2/subtitles/search", body: Self.encodeSubtitleBody(APIv2SubtitleSearchBody(body)),
            timeout: .extended, status: 200, auth: captureSubtitleAuthority())
        return wire.playerValue
    }

    // MARK: downloadSubtitle (non_retryable)

    /// Downloads one search result for the owner in `auth` and returns the
    /// stored row. A refusal before dispatch throws `requestIdentityChanged`;
    /// an owner change once the request may have been sent throws
    /// `APIv2SubtitleRequestError.outcomeUnknownOwnerChanged`.
    func downloadSubtitle(_ body: SubtitleDownloadBody, auth: CapturedOrdinaryRequestAuth) async throws -> DownloadedSubtitle {
        guard body.mediaFileId > 0 else { throw APIv2SubtitleRequestError.invalidMediaFile }
        try await gate()
        guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.sameCredentialIdentity(as: auth) else {
            throw HTTPError.requestIdentityChanged
        }
        let data = try Self.encodeSubtitleBody(APIv2SubtitleDownloadBody(body))
        let wire: APIv2SubtitleDownloadResponse
        do {
            wire = try await subtitlesCall("POST", path: "/api/v2/subtitles/download", body: data,
                timeout: .extended, status: 200, auth: auth)
        } catch HTTPError.authorityChanged, HTTPError.requestIdentityChanged {
            // `requestIdentityChanged` is raised both just before the bytes
            // leave and after the response arrives, so it cannot prove the
            // download was never sent.
            throw APIv2SubtitleRequestError.outcomeUnknownOwnerChanged
        }
        return try wire.subtitle.playerValue(mediaFileID: body.mediaFileId)
    }

    // MARK: getSubtitleSyncStatus

    func subtitleSyncStatus() async throws -> APIv2SubtitleSyncStatus {
        let status: APIv2SubtitleSyncStatus = try await subtitlesCall(
            "GET", path: "/api/v2/subtitles/sync/status", status: 200, auth: captureSubtitleAuthority())
        guard !status.revision.isEmpty else { throw APIv2Error.incompleteCatalogRead }
        return status
    }

    // MARK: getStoredSubtitleSync

    /// One stored subtitle's timing and latest sync job, for polling a job
    /// while it is pending or running. Needs file access only.
    func storedSubtitleSync(id: String, mediaFileID: Int) async throws -> DownloadedSubtitle {
        let segment = try Self.storedSubtitleSegment(id)
        let wire: APIv2StoredSubtitleEnvelope = try await subtitlesCall(
            "GET", path: "/api/v2/subtitles/stored/\(segment)/sync", status: 200, auth: captureSubtitleAuthority())
        return try wire.subtitle.playerValue(mediaFileID: mediaFileID)
    }

    // MARK: syncStoredSubtitle (coalescing)

    /// Starts a sync, or returns the subtitle's active job. A server that
    /// predates sync keys lets only the account that added the subtitle or an
    /// administrator sync it; others get 403. A format that cannot be retimed
    /// gets 422.
    func requestStoredSubtitleSync(id: String) async throws -> SubtitleSyncJob {
        let segment = try Self.storedSubtitleSegment(id)
        let wire: APIv2SubtitleSyncRequestResponse = try await subtitlesCall(
            "POST", path: "/api/v2/subtitles/stored/\(segment)/sync", status: 202, auth: captureSubtitleAuthority())
        return wire.job
    }

    // MARK: setStoredSubtitleTiming

    /// Replaces the timing correction, guarded by the validator of the
    /// subtitle's viewer metadata so a change made meanwhile wins (412).
    func setStoredSubtitleTiming(id: String, mediaFileID: Int,
                                 timing: SubtitleTiming) async throws -> DownloadedSubtitle {
        let segment = try Self.storedSubtitleSegment(id)
        let auth = try await captureSubtitleAuthority()
        let metadata = try await subtitlesRequest(
            "GET", path: "/api/v2/subtitles/stored/\(segment)/metadata", auth: auth)
        guard metadata.statusCode == 200 else { throw APIv2Error.httpStatus(metadata.statusCode) }
        let validator = try Self.entityTag(metadata.header("ETag"))
        let body = try Self.encodeSubtitleBody(APIv2SubtitleTimingBody(offsetMs: timing.offsetMs, scale: timing.scale))
        let wire: APIv2StoredSubtitleEnvelope = try await subtitlesCall(
            "PUT", path: "/api/v2/subtitles/stored/\(segment)/timing", body: body,
            headers: ["If-Match": validator], status: 200, auth: auth)
        return try wire.subtitle.playerValue(mediaFileID: mediaFileID)
    }

    static func storedSubtitleSegment(_ id: String) throws -> String {
        guard let segment = CatalogPathSegment.encode(id) else { throw APIv2Error.invalidSubtitleResponse }
        return segment
    }

    // MARK: listSubtitleSync

    /// Every syncable subtitle of the file under its sync key: stored ones,
    /// then the subtitle files next to the media. Needs file access only.
    func subtitleSyncStates(mediaFileID: Int) async throws -> [SubtitleSyncState] {
        guard mediaFileID > 0 else { throw APIv2SubtitleRequestError.invalidMediaFile }
        let wire: APIv2SubtitleSyncList = try await subtitlesCall(
            "GET", path: "/api/v2/subtitles/\(mediaFileID)/sync", status: 200, auth: captureSubtitleAuthority())
        return try wire.subtitles.map { try Self.checkedSyncState($0, mediaFileID: mediaFileID) }
    }

    // MARK: getSubtitleSync

    /// One subtitle's timing and latest job, for polling a job while it is
    /// pending or running.
    func subtitleSyncState(mediaFileID: Int, key: String) async throws -> SubtitleSyncState {
        try await readSubtitleSync(mediaFileID: mediaFileID, key: key, auth: captureSubtitleAuthority()).state
    }

    // MARK: startSubtitleSync (coalescing)

    /// Starts a sync, or returns the subtitle with its active job. Anyone who
    /// can play the file may; demo mode refuses (403), and a format that
    /// cannot be retimed gets 422.
    func startSubtitleSync(mediaFileID: Int, key: String) async throws -> SubtitleSyncState {
        let path = try Self.subtitleSyncPath(mediaFileID: mediaFileID, key: key)
        let wire: APIv2SubtitleSyncStateEnvelope = try await subtitlesCall(
            "POST", path: path, status: 202, auth: captureSubtitleAuthority())
        return try Self.checkedSyncState(wire.subtitle, mediaFileID: mediaFileID, key: key)
    }

    // MARK: setSubtitleTiming

    /// Replaces the timing correction, guarded by the validator of a fresh
    /// read so a change made meanwhile wins (412).
    func setSubtitleTiming(mediaFileID: Int, key: String, timing: SubtitleTiming) async throws -> SubtitleSyncState {
        let path = try Self.subtitleSyncPath(mediaFileID: mediaFileID, key: key)
        let auth = try await captureSubtitleAuthority()
        let current = try await readSubtitleSync(mediaFileID: mediaFileID, key: key, auth: auth)
        let validator = try Self.entityTag(current.entityTag)
        let body = try Self.encodeSubtitleBody(APIv2SubtitleTimingBody(offsetMs: timing.offsetMs, scale: timing.scale))
        let wire: APIv2SubtitleSyncStateEnvelope = try await subtitlesCall(
            "PUT", path: path + "/timing", body: body, headers: ["If-Match": validator], status: 200, auth: auth)
        return try Self.checkedSyncState(wire.subtitle, mediaFileID: mediaFileID, key: key)
    }

    private func readSubtitleSync(mediaFileID: Int, key: String,
                                  auth: CapturedOrdinaryRequestAuth) async throws -> (state: SubtitleSyncState, entityTag: String?) {
        let raw = try await subtitlesRequest(
            "GET", path: Self.subtitleSyncPath(mediaFileID: mediaFileID, key: key), auth: auth)
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleSyncStateEnvelope.self, from: raw.data)
        return (try Self.checkedSyncState(wire.subtitle, mediaFileID: mediaFileID, key: key), raw.header("ETag"))
    }

    static func subtitleSyncPath(mediaFileID: Int, key: String) throws -> String {
        guard mediaFileID > 0 else { throw APIv2SubtitleRequestError.invalidMediaFile }
        guard let segment = CatalogPathSegment.encode(key) else { throw APIv2Error.invalidSubtitleResponse }
        return "/api/v2/subtitles/\(mediaFileID)/sync/\(segment)"
    }

    /// The key stays opaque; only the file, and the key when one was asked
    /// for, must be the ones requested.
    static func checkedSyncState(_ state: SubtitleSyncState, mediaFileID: Int,
                                 key: String? = nil) throws -> SubtitleSyncState {
        guard !state.key.isEmpty, state.mediaFileId == String(mediaFileID),
              key == nil || state.key == key else { throw APIv2Error.invalidSubtitleResponse }
        return state
    }

    // MARK: Transport

    /// Shared with `APIv2Client+SubtitleAI.swift`.
    func captureSubtitleAuthority() async throws -> CapturedOrdinaryRequestAuth {
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else { throw HTTPError.requestIdentityChanged }
        return auth
    }

    func subtitlesCall<T: Decodable>(_ method: String, path: String, body: Data? = nil,
                                     headers: [String: String] = [:],
                                     timeout: HTTPTimeout = .standard, status: Int,
                                     auth: CapturedOrdinaryRequestAuth) async throws -> T {
        let raw = try await subtitlesRequest(method, path: path, body: body, headers: headers,
                                             timeout: timeout, auth: auth)
        guard raw.statusCode == status else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try HTTPClient.makeJSONDecoder().decode(T.self, from: raw.data)
    }

    /// Sends one request for the owner in `auth`, with the selected profile
    /// or an explicit empty `X-Profile-Id` when there is none.
    func subtitlesRequest(_ method: String, path: String, body: Data? = nil,
                          headers: [String: String] = [:],
                          timeout: HTTPTimeout = .standard,
                          auth: CapturedOrdinaryRequestAuth) async throws -> HTTPRawResponse {
        try await gate()
        guard await matchesAIAuthority(auth) else { throw HTTPError.requestIdentityChanged }
        let identity = auth.profileId.map { Self.requestIdentity(auth, profile: $0) }
        return try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: method, path: path, body: body,
                    headers: headers.merging(auth.profileId == nil ? ["X-Profile-Id": ""] : [:]) { $1 },
                    timeout: timeout,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
    }

    static func encodeSubtitleBody<Body: Encodable>(_ body: Body) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }
}
