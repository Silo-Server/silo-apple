import Foundation

// MARK: Download registry (profile_scoped)
//
// Every call names the calling device: `HTTPClient` attaches this
// installation's `X-Silo-Device-Id` to each request, and the server scopes
// the registry to (account, profile, device). Adding the header here as well
// would send it twice.

extension APIv2Client {
    /// Entries per registry page, and pages per read. One read covers at most
    /// 10,000 entries; a longer registry fails instead of being truncated.
    static let downloadRegistryPageLimit = 100
    static let downloadRegistryMaxPages = 100

    // MARK: getDownloadCapability

    func downloadCapability(auth: CapturedOrdinaryRequestAuth) async throws -> DownloadCapability {
        let response = try await downloadRegistryRequest(method: "GET", path: "/api/v2/capabilities/downloads", auth: auth)
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2DownloadCapability.self, from: response.data)
        return DownloadCapability(wire)
    }

    // MARK: listDownloads

    /// Reads this device's whole registry. A read that ends early, repeats a
    /// cursor or an entry, or holds an unusable entry throws: reconcile treats
    /// a missing entry as removed on the server, so it must never see a
    /// prefix.
    func listDownloads(auth: CapturedOrdinaryRequestAuth) async throws -> [APIv2DownloadEntry] {
        let deviceID = AppleDeviceIdentity.current.id
        var entries: [APIv2DownloadEntry] = []
        var ids: Set<String> = []
        var cursors: Set<String> = []
        var cursor: String?
        for _ in 0..<Self.downloadRegistryMaxPages {
            var query = ["limit": String(Self.downloadRegistryPageLimit)]
            if let cursor { query["cursor"] = cursor }
            let response = try await downloadRegistryRequest(method: "GET", path: "/api/v2/downloads", query: query, auth: auth)
            guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
            let page = try HTTPClient.makeJSONDecoder().decode(APIv2DownloadEntryPage.self, from: response.data)
            guard page.items.count <= Self.downloadRegistryPageLimit else { throw DownloadRegistryError.incompleteRegistry }
            for entry in page.items {
                guard entry.isUsable, entry.deviceId == deviceID, ids.insert(entry.id).inserted else {
                    throw DownloadRegistryError.incompleteRegistry
                }
                entries.append(entry)
            }
            guard let info = page.page, info.hasMore else {
                guard page.page?.nextCursor?.isEmpty ?? true else { throw DownloadRegistryError.incompleteRegistry }
                return entries
            }
            guard let next = info.nextCursor, !next.isEmpty, !page.items.isEmpty, cursors.insert(next).inserted else {
                throw DownloadRegistryError.incompleteRegistry
            }
            cursor = next
        }
        throw DownloadRegistryError.incompleteRegistry
    }

    // MARK: createDownloads (non_retryable)

    /// Sends one `createDownloads` request, exactly once. The operation is
    /// `non_retryable`: after an uncertain outcome the caller reads the
    /// registry instead of sending again. A series request passes the
    /// previous page's `nextCursor` with the same request to get its next
    /// page.
    ///
    /// The answer must describe the request (the item, file, quality and
    /// device, or the batch); anything else throws `unexpectedReceipt`, which
    /// counts as uncertain because the server has already acted.
    func createDownloads(
        _ request: APIv2DownloadCreateRequest,
        cursor: String? = nil,
        auth: CapturedOrdinaryRequestAuth
    ) async throws -> APIv2DownloadCreated {
        guard request.isValid, cursor == nil || request.batchId != nil else {
            throw DownloadRegistryError.invalidRequest
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(request)
        var query: [String: String] = [:]
        if request.batchId != nil { query["limit"] = String(Self.downloadRegistryPageLimit) }
        if let cursor { query["cursor"] = cursor }
        let response = try await downloadRegistryRequest(method: "POST", path: "/api/v2/downloads",
            query: query, body: body, auth: auth)
        guard response.statusCode == 202 else { throw APIv2Error.httpStatus(response.statusCode) }
        let created: APIv2DownloadCreated
        do {
            created = try HTTPClient.makeJSONDecoder().decode(APIv2DownloadCreated.self, from: response.data)
        } catch {
            throw DownloadRegistryError.unexpectedReceipt
        }
        guard Self.receipt(created, describes: request, deviceID: AppleDeviceIdentity.current.id) else {
            throw DownloadRegistryError.unexpectedReceipt
        }
        return created
    }

    /// Whether a create answer is the one the request asked for.
    static func receipt(_ created: APIv2DownloadCreated, describes request: APIv2DownloadCreateRequest,
                        deviceID: String) -> Bool {
        guard created.items.allSatisfy({ $0.isUsable && $0.deviceId == deviceID }),
              Set(created.items.map(\.id)).count == created.items.count else { return false }
        switch request {
        case let .single(contentId, episodeId, mediaFileId, quality, _, expected):
            guard created.items.count == 1, created.skipped.isEmpty, !created.page.hasMore,
                  let entry = created.items.first,
                  entry.contentId == contentId, entry.episodeId == episodeId, entry.quality == quality,
                  mediaFileId.map({ $0 == entry.mediaFileId }) ?? true else { return false }
            if case let .entry(id, revision) = expected {
                return entry.id == id && entry.revision >= revision
            }
            return true
        case let .seriesPage(seriesId, _, batchId, _):
            guard created.batchId == batchId,
                  created.items.count + created.skipped.count <= downloadRegistryPageLimit,
                  created.items.allSatisfy({ $0.contentId == seriesId && $0.episodeId?.isEmpty == false }) else {
                return false
            }
            let next = created.page.nextCursor ?? ""
            return created.page.hasMore ? !next.isEmpty : next.isEmpty
        }
    }

    // MARK: reportDownloadStatus (domain_identity)

    /// Reports one local status event. A retry must send the same event:
    /// the server acknowledges an event it already holds and answers 409
    /// when the entry's revision moved on.
    func reportDownloadStatus(id: String, event: DownloadStatusEvent,
                              auth: CapturedOrdinaryRequestAuth) async throws -> APIv2DownloadEntry {
        guard event.revision >= 1, let segment = CatalogPathSegment.encode(id), !id.isEmpty else {
            throw DownloadRegistryError.invalidRequest
        }
        // Sorted keys keep a retry's body byte-identical to the first send.
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let body = try encoder.encode(APIv2DownloadStatusBody(event: event))
        let response = try await downloadRegistryRequest(method: "PATCH", path: "/api/v2/downloads/\(segment)",
            body: body, auth: auth)
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        guard let entry = try? HTTPClient.makeJSONDecoder().decode(APIv2DownloadEntry.self, from: response.data),
              entry.id == id, entry.isUsable else {
            throw DownloadRegistryError.unexpectedReceipt
        }
        return entry
    }

    // MARK: deleteDownload (natural_idempotent)

    func deleteDownload(id: String, auth: CapturedOrdinaryRequestAuth) async throws {
        guard let segment = CatalogPathSegment.encode(id), !id.isEmpty else {
            throw DownloadRegistryError.invalidRequest
        }
        let response = try await downloadRegistryRequest(method: "DELETE", path: "/api/v2/downloads/\(segment)", auth: auth)
        guard response.statusCode == 204 else { throw APIv2Error.httpStatus(response.statusCode) }
    }

    // MARK: Failure classification

    /// Sorts a thrown registry error into the outcome the caller acts on.
    static func downloadRegistryFailure(_ error: Error) -> DownloadRegistryFailure {
        switch error {
        case APIv2Error.serverUpdateRequired:
            return .notApplied
        case APIv2Error.problem(let problem):
            return downloadRegistryFailure(status: problem.status)
        case APIv2Error.httpStatus(let status):
            return downloadRegistryFailure(status: status)
        case DownloadRegistryError.invalidRequest:
            return .rejected
        case HTTPError.requestIdentityChanged, HTTPError.serverUrlNotConfigured,
             HTTPError.invalidURL, HTTPError.encodingFailed, is EncodingError:
            return .notApplied
        case HTTPError.network(let underlying as URLError) where neverConnected.contains(underlying.code):
            return .notApplied
        default:
            // Includes an owner change noticed on the way back and an answer
            // that could not be used: the server may have acted.
            return .uncertain
        }
    }

    private static func downloadRegistryFailure(status: Int) -> DownloadRegistryFailure {
        switch status {
        case 409:
            return .conflict
        // Refused before any write: no session, timeout, app or server too
        // old, rate limit, unavailable.
        case 401, 408, 410, 429, 503:
            return .notApplied
        // An unexpected success status, or a server error that can follow
        // the write.
        case 200..<300, 500...:
            return .uncertain
        default:
            return .rejected
        }
    }

    // MARK: Transport

    /// One registry request under the captured owner: refused before
    /// dispatch when that owner is no longer current, and its answer
    /// discarded when the owner changed while it was in flight.
    private func downloadRegistryRequest(
        method: String,
        path: String,
        query: [String: String] = [:],
        body: Data? = nil,
        auth: CapturedOrdinaryRequestAuth
    ) async throws -> HTTPRawResponse {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              !AppleDeviceIdentity.current.id.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = Self.requestIdentity(auth, profile: profile)
        return try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: method, path: path, query: query, body: body,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
    }
}
