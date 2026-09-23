import Foundation

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
        let identity: HTTPRequestIdentity
        do {
            try await gate()
            guard request.isValidBatch else { throw ProgressSyncError.invalidBatch }
            guard let profile = auth.profileId, !profile.isEmpty,
                  await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
                throw HTTPError.requestIdentityChanged
            }
            try Task.checkCancellation()
            body = try JSONEncoder().encode(request)
            identity = Self.requestIdentity(auth, profile: profile)
        } catch {
            return .notSent(error)
        }

        let response: HTTPRawResponse
        do {
            response = try await tokenStore.withOwnerFence(auth) {
                try await mapErrors {
                    try await http.requestData(method: "POST", path: "/api/v2/sync/progress", body: body,
                        requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
                }
            }
        } catch {
            return Self.progressSyncFailure(error)
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
    /// is a definite answer. A transport error is `notSent` only when the
    /// connection was never established; every other failure after dispatch,
    /// including an owner change noticed on the way back, is uncertain.
    static func progressSyncFailure(_ error: Error) -> ProgressSyncOutcome {
        switch error {
        case APIv2Error.problem, APIv2Error.httpStatus, APIv2Error.serverUpdateRequired:
            return .rejected(error)
        case HTTPError.network(let underlying as URLError) where Self.neverConnected.contains(underlying.code):
            return .notSent(error)
        case HTTPError.serverUrlNotConfigured, HTTPError.invalidURL, HTTPError.encodingFailed:
            return .notSent(error)
        default:
            return .uncertain(error)
        }
    }

    /// URL loading errors raised before any request bytes could reach the
    /// server: no route, no name, no connection, or no trusted TLS session.
    private static let neverConnected: Set<URLError.Code> = [
        .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .internationalRoamingOff, .dataNotAllowed, .callIsActive,
        .appTransportSecurityRequiresSecureConnection, .secureConnectionFailed,
        .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
        .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired,
    ]
}
