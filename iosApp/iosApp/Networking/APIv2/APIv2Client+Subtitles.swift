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
        guard await isCurrentOwner(auth) else {
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

    // MARK: Transport

    /// Shared with `APIv2Client+SubtitleAI.swift`.
    func captureSubtitleAuthority() async throws -> CapturedOrdinaryRequestAuth {
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else { throw HTTPError.requestIdentityChanged }
        return auth
    }

    func subtitlesCall<T: Decodable>(_ method: String, path: String, body: Data? = nil,
                                     timeout: HTTPTimeout = .standard, status: Int,
                                     auth: CapturedOrdinaryRequestAuth) async throws -> T {
        let raw = try await subtitlesRequest(method, path: path, body: body, timeout: timeout, auth: auth)
        guard raw.statusCode == status else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try HTTPClient.makeJSONDecoder().decode(T.self, from: raw.data)
    }

    /// Sends one request for the owner in `auth`, with the selected profile
    /// or an explicit empty `X-Profile-Id` when there is none.
    func subtitlesRequest(_ method: String, path: String, body: Data? = nil,
                          timeout: HTTPTimeout = .standard,
                          auth: CapturedOrdinaryRequestAuth) async throws -> HTTPRawResponse {
        try await gate()
        guard await isCurrentOwner(auth) else { throw HTTPError.requestIdentityChanged }
        return try await send(APIv2Request(method: method, path: path, body: body, timeout: timeout), auth: auth)
    }

    static func encodeSubtitleBody<Body: Encodable>(_ body: Body) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }
}
