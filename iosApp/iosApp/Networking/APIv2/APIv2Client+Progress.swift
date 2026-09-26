import Foundation

// MARK: listProgress (profile_scoped)

extension APIv2Client {
    /// Entries per progress page (the server maximum), and pages per read.
    /// One read covers at most 20,000 entries; a longer history fails instead
    /// of being truncated.
    static let progressPageLimit = 200
    static let progressMaxPages = 100

    /// Reads every progress entry of the owner in `auth`, page by page under
    /// that owner. v2 has no delta read, so this is the whole set. A read
    /// that ends early, repeats a cursor or an item, or overruns the page
    /// bound throws: the caller treats an item missing from a finished read
    /// as having no progress on the server, so it must never see a prefix.
    func listAllProgress(auth: CapturedOrdinaryRequestAuth) async throws -> [APIv2ProgressEntry] {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty, await isCurrentOwner(auth) else {
            throw HTTPError.requestIdentityChanged
        }
        var entries: [APIv2ProgressEntry] = []
        var ids: Set<String> = []
        var cursors: Set<String> = []
        var cursor: String?
        for _ in 0..<Self.progressMaxPages {
            var query = ["limit": String(Self.progressPageLimit)]
            if let cursor { query["cursor"] = cursor }
            let response = try await send(APIv2Request(method: "GET", path: "/api/v2/progress", query: query), auth: auth)
            guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
            let page = try HTTPClient.makeJSONDecoder().decode(APIv2ProgressPage.self, from: response.data)
            guard page.items.count <= Self.progressPageLimit else { throw ProgressReadError.incompleteRead }
            for entry in page.items {
                guard !entry.mediaItemId.isEmpty, ids.insert(entry.mediaItemId).inserted else {
                    throw ProgressReadError.incompleteRead
                }
                entries.append(entry)
            }
            guard page.page.hasMore else {
                guard page.page.nextCursor?.isEmpty ?? true else { throw ProgressReadError.incompleteRead }
                return entries
            }
            guard let next = page.page.nextCursor, !next.isEmpty, !page.items.isEmpty,
                  cursors.insert(next).inserted else {
                throw ProgressReadError.incompleteRead
            }
            cursor = next
        }
        throw ProgressReadError.incompleteRead
    }
}

// MARK: syncProgress (profile_scoped, non_retryable)

extension APIv2Client {
    /// Uploads a batch of progress writes for the current owner.
    func syncProgress(_ items: [SyncProgressItem]) async -> ProgressSyncOutcome {
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else {
            return .notSent(HTTPError.requestIdentityChanged)
        }
        return await syncProgress(items, auth: auth)
    }

    /// Uploads a batch of progress writes for the owner in `auth`, exactly
    /// once. `syncProgress` is `non_retryable`: this method never re-sends,
    /// and it reports which of the three outcomes happened so the caller can
    /// keep an unanswered batch from being replayed.
    ///
    /// The batch must hold 1-100 items with distinct `media_item_id`s; the
    /// server rejects anything else as a whole, so such a batch is refused
    /// here without being sent.
    func syncProgress(_ items: [SyncProgressItem], auth: CapturedOrdinaryRequestAuth) async -> ProgressSyncOutcome {
        let request = SyncProgressRequest(items: items)
        let body: Data
        do {
            try await gate()
            guard request.isValidBatch else { throw ProgressSyncError.invalidBatch }
            guard let profile = auth.profileId, !profile.isEmpty, await isCurrentOwner(auth) else {
                throw HTTPError.requestIdentityChanged
            }
            try Task.checkCancellation()
            body = try JSONEncoder().encode(request)
        } catch {
            return .notSent(error)
        }

        let response: HTTPRawResponse
        let dispatch = HTTPDispatchRecord()
        do {
            response = try await send(APIv2Request(method: "POST", path: "/api/v2/sync/progress", body: body),
                                      auth: auth, dispatch: dispatch)
        } catch {
            return Self.progressSyncFailure(error, dispatched: dispatch.didDispatch)
        }
        guard response.statusCode == 200 else {
            // The contract has no other success status. A 2xx the client does
            // not understand still means the server took the request.
            return .uncertain(APIv2Error.httpStatus(response.statusCode))
        }
        do {
            let result = try HTTPClient.makeJSONDecoder().decode(APIv2ProgressSyncBatchResult.self, from: response.data)
            return .answered(try Self.matchedResults(result, to: items))
        } catch {
            return .uncertain(error)
        }
    }

    /// One result per request item, keyed back to the item by index and id.
    /// Anything else leaves the per-item outcome unknown.
    private static func matchedResults(
        _ result: APIv2ProgressSyncBatchResult,
        to items: [SyncProgressItem]
    ) throws -> [APIv2ProgressSyncItemResult] {
        guard result.items.count == items.count else { throw ProgressSyncError.incompleteResult }
        let ordered = result.items.sorted { $0.index < $1.index }
        for (index, entry) in ordered.enumerated() {
            guard entry.index == index,
                  entry.mediaItemId == items[index].mediaItemId,
                  entry.succeeded == (entry.failure == nil) else {
                throw ProgressSyncError.incompleteResult
            }
        }
        return ordered
    }

    /// Classifies a thrown dispatch error. A problem document or HTTP status
    /// is a definite answer: `deferred` when the server applied nothing and
    /// the batch may be sent later, `rejected` otherwise. An owner change is
    /// `notSent` when it refused the request before it reached the URL
    /// session (the fence's entry check or HTTPClient's dispatch gate;
    /// `dispatched` is false). A transport error is `notSent` only when the
    /// connection was never established; every other failure after dispatch,
    /// including an owner change noticed on the way back, is uncertain.
    static func progressSyncFailure(_ error: Error, dispatched: Bool = true) -> ProgressSyncOutcome {
        switch error {
        case HTTPError.requestIdentityChanged where !dispatched, HTTPError.authorityChanged where !dispatched:
            return .notSent(error)
        case APIv2Error.serverUpdateRequired:
            return .deferred(error)
        case APIv2Error.problem(let problem):
            if UpdateRequirement.isClientUpgradeRequired(problem) || deferredStatuses.contains(problem.status) {
                return .deferred(error)
            }
            return .rejected(error)
        case APIv2Error.httpStatus(let status):
            return deferredStatuses.contains(status) ? .deferred(error) : .rejected(error)
        case HTTPError.network(let underlying as URLError) where Self.neverConnected.contains(underlying.code):
            return .notSent(error)
        case HTTPError.serverUrlNotConfigured, HTTPError.invalidURL:
            return .notSent(error)
        default:
            return .uncertain(error)
        }
    }

    /// Whole-batch statuses the server returns before writing anything, for
    /// a condition that passes: an auth refusal (an expired session, or a
    /// profile whose proof is missing or stale) that
    /// clears after re-authentication, timeout, rate limit, unavailable. A
    /// 500 is not one: the server can raise it after the writes.
    private static let deferredStatuses: Set<Int> = [401, 403, 408, 429, 503]

    /// URL loading errors raised before any request bytes could reach the
    /// server: no usable URL, no route, no name, no connection, or no trusted
    /// TLS session. The one list every v2 lane uses (see
    /// `APIv2MutationOutcome`).
    static let neverConnected: Set<URLError.Code> = [
        .badURL, .unsupportedURL,
        .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .internationalRoamingOff, .dataNotAllowed, .callIsActive,
        .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
        .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
        .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired,
    ]
}
