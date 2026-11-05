import Foundation

/// Media requests (`/api/v2/requests`). Every operation is profile scoped:
/// it needs a selected profile, sends `X-Profile-Id` (and the profile proof
/// when one is held), and runs under the owner captured at the start.
///
/// Follow and unfollow are naturally idempotent: repeating one leaves the
/// same state, so a lost answer is safe to send again.
///
/// Create and cancel are `non_retryable` in the contract. Neither is replayed
/// after an uncertain outcome; the callers re-read server state instead. An
/// owner change once a mutation has captured its owner is uncertain too: the
/// response is discarded, but the server may already have acted.
extension APIv2Client {
    // MARK: getRequestStatus

    func requestsStatus() async throws -> RequestsFeatureStatus {
        try await requestsCall("GET", path: "/api/v2/requests/status", status: 200)
    }

    // MARK: searchRequestMedia

    func searchRequestMedia(query: String, mediaType: RequestMediaType, page: Int) async throws -> RequestMediaPage {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw APIv2RequestsError.emptySearchQuery
        }
        let type: String
        switch mediaType {
        case .movie, .series, .all: type = mediaType.rawValue
        case .unknown: throw APIv2RequestsError.unsupportedMediaType
        }
        return try await requestsCall("GET", path: "/api/v2/requests/search",
            query: ["q": query, "media_type": type, "page": String(max(page, 1))], status: 200)
    }

    // MARK: listDiscoverSections

    func requestDiscoverLayout() async throws -> RequestDiscoverLayout {
        let collection: APIv2DiscoverSectionCollection = try await requestsCall(
            "GET", path: "/api/v2/requests/discover", status: 200)
        return RequestDiscoverLayout(sections: collection.items, rowOrder: collection.rowOrder ?? [])
    }

    // MARK: getDiscoverRow

    /// One page of a row of the server's Discover layout, for its See all page.
    func requestDiscoverRow(key: String, page: Int) async throws -> RequestDiscoverySection {
        let escaped = try catalogPathSegment(key)
        return try await requestsCall("GET", path: "/api/v2/requests/discover/rows/\(escaped)",
            query: ["page": String(max(page, 1))], status: 200)
    }

    // MARK: getRequestMediaDetail

    func requestMediaDetail(mediaType: RequestMediaType, tmdbId: Int) async throws -> RequestMediaDetail {
        let type = try Self.requestableMediaType(mediaType)
        return try await requestsCall("GET", path: "/api/v2/requests/detail/\(type)/\(tmdbId)", status: 200)
    }

    // MARK: createRequest (non_retryable)

    func createRequest(_ input: CreateRequestInput) async throws -> MediaRequest {
        _ = try Self.requestableMediaType(input.mediaType)
        return try await requestsCall("POST", path: "/api/v2/requests", body: try Self.encode(input), status: 201)
    }

    // MARK: listMyRequests

    /// The acting profile's own requests, up to 100 pages (see `requestList`).
    func myRequests() async throws -> [MediaRequest] {
        try await requestList(path: "/api/v2/requests/mine", maxPages: 100)
    }

    // MARK: cancelRequest (non_retryable)

    func cancelRequest(id: String, reason: String?) async throws -> MediaRequest {
        let path = "/api/v2/requests/\(try catalogPathSegment(id))/cancel"
        return try await requestsCall("POST", path: path, body: try Self.encode(CancelRequestBody(reason: reason)), status: 200)
    }

    // MARK: followRequestMedia / unfollowRequestMedia (naturally idempotent)

    /// `PUT /api/v2/requests/follows/{media_type}/{tmdb_id}`: hear when a
    /// title someone else requested becomes available. Answers the title's
    /// request state for the viewer.
    func followRequestMedia(mediaType: RequestMediaType, tmdbId: Int) async throws -> RequestState {
        let type = try Self.requestableMediaType(mediaType)
        return try await requestsCall("PUT", path: "/api/v2/requests/follows/\(type)/\(tmdbId)", status: 200)
    }

    /// `DELETE /api/v2/requests/follows/{media_type}/{tmdb_id}`. Answers 204
    /// with no body.
    func unfollowRequestMedia(mediaType: RequestMediaType, tmdbId: Int) async throws {
        let type = try Self.requestableMediaType(mediaType)
        _ = try await requestsSend("DELETE", path: "/api/v2/requests/follows/\(type)/\(tmdbId)", status: 204)
    }

    /// Follows `page.next_cursor` under one owner captured at the start. A
    /// failed page, a missing or repeated cursor, or the page bound fails the
    /// whole load instead of returning a partial list.
    private func requestList(path: String, maxPages: Int) async throws -> [MediaRequest] {
        guard let auth = await tokenStore.captureOrdinaryRequestAuth(),
              let profile = auth.profileId else { throw HTTPError.requestIdentityChanged }
        let identity = Self.requestIdentity(auth, profile: profile)
        var records: [MediaRequest] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0..<maxPages {
            try await gate()
            var query = ["limit": "50"]
            if let cursor { query["cursor"] = cursor }
            let requestQuery = query
            let raw = try await tokenStore.withOwnerFence(auth) {
                try await mapErrors {
                    try await http.requestData(method: "GET", path: path,
                        query: requestQuery, requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
                }
            }
            guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
            let response = try HTTPClient.makeJSONDecoder().decode(APIv2RequestsPage.self, from: raw.data)
            records.append(contentsOf: response.items)
            guard let page = response.page, page.hasMore else { return records }
            guard let next = page.nextCursor, !next.isEmpty, seen.insert(next).inserted else {
                throw APIv2Error.incompleteRequestList
            }
            cursor = next
        }
        throw APIv2Error.incompleteRequestList
    }

    // MARK: Transport

    private func requestsCall<T: Decodable>(_ method: String, path: String, query: [String: String] = [:],
                                            body: Data? = nil, status: Int) async throws -> T {
        let response = try await requestsSend(method, path: path, query: query, body: body, status: status)
        return try HTTPClient.makeJSONDecoder(artworkServerURL: response.url).decode(T.self, from: response.data)
    }

    /// Sends one profile-scoped call and requires `status`; the caller reads
    /// the body, if there is one.
    private func requestsSend(_ method: String, path: String, query: [String: String] = [:],
                              body: Data? = nil, status: Int) async throws -> HTTPRawResponse {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth(), let profile = auth.profileId else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = Self.requestIdentity(auth, profile: profile)
        let response: HTTPRawResponse
        do {
            response = try await tokenStore.withOwnerFence(auth) {
                try await mapErrors {
                    try await http.requestData(method: method, path: path, query: query, body: body,
                        requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
                }
            }
        } catch HTTPError.authorityChanged where method != "GET" {
            throw APIv2RequestsError.outcomeUnknownOwnerChanged
        } catch HTTPError.requestIdentityChanged where method != "GET" {
            // Raised both just before the bytes leave and after the response
            // arrives, so it cannot prove the mutation was never sent.
            throw APIv2RequestsError.outcomeUnknownOwnerChanged
        }
        guard response.statusCode == status else { throw APIv2Error.httpStatus(response.statusCode) }
        return response
    }

    private static func requestableMediaType(_ type: RequestMediaType) throws -> String {
        switch type {
        case .movie, .series: return type.rawValue
        case .all, .unknown: throw APIv2RequestsError.unsupportedMediaType
        }
    }

    private static func encode<Body: Encodable>(_ body: Body) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }
}
