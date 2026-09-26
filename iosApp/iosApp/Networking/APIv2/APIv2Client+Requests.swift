import Foundation

/// Media requests (`/api/v2/requests`). Every operation is profile scoped:
/// it needs a selected profile, sends `X-Profile-Id` (and the profile proof
/// when one is held), and runs under the owner captured at the start.
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

    func requestDiscoverSections() async throws -> [RequestDiscoverySection] {
        let collection: APIv2DiscoverSectionCollection = try await requestsCall(
            "GET", path: "/api/v2/requests/discover", status: 200)
        return collection.items
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

    /// Follows `page.next_cursor` under one captured owner. A failed page, a
    /// missing or repeated cursor, or the 100-page bound fails the whole load
    /// instead of returning a partial list.
    func myRequests() async throws -> [MediaRequest] {
        // Captured before the per-page gate, unlike `captureRequestOwner()`.
        guard let auth = await tokenStore.captureOrdinaryRequestAuth(),
              auth.profileId != nil else { throw HTTPError.requestIdentityChanged }
        var records: [MediaRequest] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0..<100 {
            try await gate()
            var query = ["limit": "50"]
            if let cursor { query["cursor"] = cursor }
            let raw = try await send(APIv2Request(method: "GET", path: "/api/v2/requests/mine", query: query), auth: auth)
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

    // MARK: cancelRequest (non_retryable)

    func cancelRequest(id: String, reason: String?) async throws -> MediaRequest {
        let path = "/api/v2/requests/\(try catalogPathSegment(id))/cancel"
        return try await requestsCall("POST", path: path, body: try Self.encode(CancelRequestBody(reason: reason)), status: 200)
    }

    // MARK: Transport

    private func requestsCall<T: Decodable>(_ method: String, path: String, query: [String: String] = [:],
                                            body: Data? = nil, status: Int) async throws -> T {
        let auth = try await captureRequestOwner()
        guard auth.profileId != nil else { throw HTTPError.requestIdentityChanged }
        let response: HTTPRawResponse
        do {
            response = try await send(APIv2Request(method: method, path: path, query: query, body: body), auth: auth)
        } catch HTTPError.authorityChanged where method != "GET" {
            throw APIv2RequestsError.outcomeUnknownOwnerChanged
        } catch HTTPError.requestIdentityChanged where method != "GET" {
            // Raised both just before the bytes leave and after the response
            // arrives, so it cannot prove the mutation was never sent.
            throw APIv2RequestsError.outcomeUnknownOwnerChanged
        }
        guard response.statusCode == status else { throw APIv2Error.httpStatus(response.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: response.url).decode(T.self, from: response.data)
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
