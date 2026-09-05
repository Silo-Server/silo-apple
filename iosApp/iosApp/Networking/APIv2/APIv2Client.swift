import Foundation

/// Errors raised by the v2 request layer.
enum APIv2Error: LocalizedError, Sendable {
    /// The connected server is v1-only (see `APIv2Probe`). Pilot operations
    /// are refused rather than routed to a v1 path.
    case serverUpdateRequired
    case incompleteRequestList
    case missingCollectionVersion
    case incompleteCollection
    case invalidCatalogQuery
    case invalidCatalogContinuation
    case incompleteCatalogRead
    /// The server answered with an `application/problem+json` document.
    case problem(APIv2Problem)
    /// A non-2xx status whose body was not a problem document.
    case httpStatus(Int)

    static let serverUpdateRequiredMessage =
        "This server needs to be updated before this version of Silo can use it."

    var errorDescription: String? {
        switch self {
        case .incompleteCatalogRead:
            return "The server returned an incomplete catalog list. Reload to try again."
        case .invalidCatalogQuery:
            return "The catalog query is not valid."
        case .invalidCatalogContinuation:
            return "The catalog page could not be continued. Reload to start again."
        case .incompleteCollection:
            return "The collection could not be loaded completely. Reload to try again."
        case .missingCollectionVersion:
            return "The server did not provide a collection version. Reload before editing."
        case .incompleteRequestList:
            return "The request list could not be loaded completely. Please reload."
        case .serverUpdateRequired:
            return Self.serverUpdateRequiredMessage
        case .problem(let problem):
            return problem.detail.isEmpty ? problem.title : problem.detail
        case .httpStatus(let status):
            return "The server returned HTTP \(status)."
        }
    }
}

/// The pilot's v2 operations. Every path here is `/api/v2`; nothing in this
/// file may name a v1 path, and a failed v2 call is never replayed against
/// another API major (a source-level test enforces both).
struct APIv2Client: Sendable {
    private let http: HTTPClient
    private let tokenStore: TokenStore
    /// Whether the connected server was found to be v1-only. Read once per
    /// call so the update-server state set by the probe blocks pilot traffic.
    private let isUpdateRequired: @Sendable () async -> Bool

    init(
        http: HTTPClient = .shared,
        tokenStore: TokenStore = .shared,
        isUpdateRequired: @escaping @Sendable () async -> Bool = {
            await MainActor.run { ConnectionMonitor.shared.isServerUpdateRequired }
        }
    ) {
        self.http = http
        self.tokenStore = tokenStore
        self.isUpdateRequired = isUpdateRequired
    }

    // MARK: getSetupStatus (public)

    /// Probes a candidate server by explicit URL without credentials.
    ///
    /// Deliberately not gated on the active session's verdict: that verdict
    /// describes the active server, not this candidate. Gating here would make
    /// it impossible to add an updated server while the active one is
    /// update-required. The candidate's own contract probe, which
    /// `AuthService.checkServer` runs first and which throws on
    /// `.updateServer`, is the gate for explicit-URL operations.
    func setupStatus(serverURL: String) async throws -> APIv2SetupStatus {
        try await mapErrors {
            try await http.getUnauthenticated(serverURL: serverURL, path: "/api/v2/system/setup")
        }
    }

    // MARK: getCurrentUser (authenticated)

    func currentUser() async throws -> APIv2Account {
        try await gate()
        return try await mapErrors { try await http.get("/api/v2/account/me") }
    }

    // MARK: listProgress (profile_scoped)

    func listProgress(
        status: APIv2ProgressStatus? = nil,
        libraryId: String? = nil,
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> APIv2ProgressPage {
        try await gate()
        var query: [String: String] = [:]
        if let status { query["status"] = status.wireValue }
        if let libraryId { query["library_id"] = libraryId }
        if let limit { query["limit"] = String(limit) }
        if let cursor { query["cursor"] = cursor }
        return try await mapErrors { try await http.get("/api/v2/progress", query: query) }
    }

    // MARK: updateProfile (profile_scoped, no profile header required)

    func updateProfile(id: String, patch: APIv2ProfilePatch) async throws -> APIv2Profile {
        try await gate()
        return try await mapErrors { try await http.patch("/api/v2/profiles/\(id)", body: patch) }
    }

    // MARK: Requests

    func requestGet<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await gate()
        return try await mapErrors { try await http.get(path, query: query) }
    }

    /// Create and cancel are never replayed after an ambiguous transport failure.
    func requestPost<T: Decodable, B: Encodable>(_ path: String, body: B) async throws -> T {
        try await gate()
        return try await mapErrors { try await http.post(path, body: body) }
    }

    func myRequests() async throws -> [MediaRequest] {
        guard let auth = await tokenStore.captureOrdinaryRequestAuth(),
              let profile = auth.profileId else { throw HTTPError.requestIdentityChanged }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId,
            serverURL: auth.account.serverURL, profileId: profile,
            clientFamily: AppleDeviceIdentity.current.clientFamily)
        var records: [MediaRequest] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0..<100 {
            try await gate()
            guard let current = await tokenStore.captureOrdinaryRequestAuth(),
                  current.account == auth.account, current.profileId == profile else {
                throw HTTPError.requestIdentityChanged
            }
            var query = ["limit": "50"]
            if let cursor { query["cursor"] = cursor }
            let response: MediaRequestsResponse = try await mapErrors {
                let raw = try await http.requestData(method: "GET", path: "/api/v2/requests/mine",
                    query: query, requestIdentity: identity)
                return try HTTPClient.makeJSONDecoder().decode(MediaRequestsResponse.self, from: raw.data)
            }
            guard let current = await tokenStore.captureOrdinaryRequestAuth(),
                  current.account == auth.account, current.profileId == profile else {
                throw HTTPError.requestIdentityChanged
            }
            records.append(contentsOf: response.items)
            if !response.page.hasMore { return records }
            guard let next = response.page.nextCursor, !next.isEmpty, seen.insert(next).inserted else {
                throw APIv2Error.incompleteRequestList
            }
            cursor = next
        }
        throw APIv2Error.incompleteRequestList
    }

    /// Hydrated personal collection cards. Membership endpoints return join records instead.
    func personalCollectionCards(id: String) async throws -> CatalogResponse {
        guard let auth = await tokenStore.captureOrdinaryRequestAuth(), let profile = auth.profileId else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        var items: [BrowseItem] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0..<100 {
            try await gate()
            guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.account == auth.account,
                  current.profileId == profile else { throw HTTPError.requestIdentityChanged }
            var query = ["source": "user_collection", "collection_id": id, "limit": "50"]
            if let cursor { query["cursor"] = cursor }
            let page: CollectionCardsV2 = try await mapErrors {
                let raw = try await http.requestData(method: "GET", path: "/api/v2/catalog",
                    query: query, requestIdentity: identity)
                return try HTTPClient.makeJSONDecoder().decode(CollectionCardsV2.self, from: raw.data)
            }
            guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.account == auth.account,
                  current.profileId == profile else { throw HTTPError.requestIdentityChanged }
            items.append(contentsOf: page.items)
            if !page.page.hasMore { return CatalogResponse(collectionCards: items) }
            guard let next = page.page.nextCursor, !next.isEmpty, seen.insert(next).inserted else {
                throw APIv2Error.incompleteCollection
            }
            cursor = next
        }
        throw APIv2Error.incompleteCollection
    }

    // MARK: Collection editors

    func collectionEditor<T: Decodable>(_ path: String) async throws -> CollectionEditor<T> {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth(), let profile = auth.profileId else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let raw = try await mapErrors {
            try await http.requestData(method: "GET", path: path, requestIdentity: identity)
        }
        guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.account == auth.account,
              current.profileId == profile else { throw HTTPError.requestIdentityChanged }
        guard let tag = raw.headers["etag"], !tag.isEmpty else { throw APIv2Error.missingCollectionVersion }
        return CollectionEditor(value: try HTTPClient.makeJSONDecoder().decode(T.self, from: raw.data),
            version: CollectionEditVersion(path: path, etag: tag, identity: identity, account: auth.account))
    }

    func mutateCollection<T: Decodable, B: Encodable>(method: String, version: CollectionEditVersion,
                                                     body: B) async throws -> T {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let raw = try await collectionMutation(method: method, version: version, body: encoder.encode(body))
        return try HTTPClient.makeJSONDecoder().decode(T.self, from: raw.data)
    }

    func deleteCollection(version: CollectionEditVersion) async throws {
        _ = try await collectionMutation(method: "DELETE", version: version, body: nil)
    }

    private func collectionMutation(method: String, version: CollectionEditVersion, body: Data?) async throws -> HTTPRawResponse {
        try await gate()
        guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.account == version.account,
              current.profileId == version.identity.profileId else { throw HTTPError.requestIdentityChanged }
        return try await mapErrors {
            try await http.requestData(method: method, path: version.path, body: body,
                headers: ["If-Match": version.etag], requestIdentity: version.identity)
        }
    }

    // MARK: Catalog contract

    func catalogPage(query: APIv2CatalogQuery, operation: APIv2CatalogOperation = .get) async throws -> APIv2CatalogResult {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth(), let profile = auth.profileId else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        return try await fetchCatalogPage(query: query, operation: operation, cursor: nil, seen: [],
            identity: identity, account: auth.account)
    }

    func nextCatalogPage(_ continuation: APIv2CatalogContinuation) async throws -> APIv2CatalogResult {
        try await fetchCatalogPage(query: continuation.query, operation: continuation.operation,
            cursor: continuation.cursor, seen: continuation.seen,
            identity: continuation.identity, account: continuation.account)
    }

    private func fetchCatalogPage(query: APIv2CatalogQuery, operation: APIv2CatalogOperation,
        cursor: String?, seen: Set<String>, identity: HTTPRequestIdentity,
        account: RefreshAccountIdentity) async throws -> APIv2CatalogResult {
        try await gate()
        guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.account == account,
              current.profileId == identity.profileId else { throw HTTPError.requestIdentityChanged }
        var parameters = try query.getParameters()
        var body: Data?
        if operation == .query {
            let encoder = JSONEncoder()
            encoder.keyEncodingStrategy = .convertToSnakeCase
            body = try encoder.encode(APIv2CatalogQueryBody(query: query, cursor: cursor))
            parameters = [:]
            if let size = query.imageSize { parameters["image_size"] = size }
        } else {
            guard (parameters["groups"]?.utf8.count ?? 0) <= 32768 else { throw APIv2Error.invalidCatalogQuery }
            if let cursor { parameters["cursor"] = cursor }
        }
        let page: APIv2CatalogPage = try await mapErrors {
            let response = try await http.requestData(method: operation == .get ? "GET" : "POST",
                path: operation == .get ? "/api/v2/catalog" : "/api/v2/catalog/query",
                query: parameters, body: body, requestIdentity: identity)
            return try HTTPClient.makeJSONDecoder().decode(APIv2CatalogPage.self, from: response.data)
        }
        guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.account == account,
              current.profileId == identity.profileId else { throw HTTPError.requestIdentityChanged }
        var continuation: APIv2CatalogContinuation?
        if page.page.hasMore {
            guard let next = page.page.nextCursor, !next.isEmpty, !seen.contains(next) else {
                throw APIv2Error.invalidCatalogContinuation
            }
            continuation = APIv2CatalogContinuation(query: query, operation: operation, cursor: next,
                seen: seen.union([next]), identity: identity, account: account)
        }
        return APIv2CatalogResult(value: page, continuation: continuation)
    }

    func catalogFilters(libraryId: String?, includeTechnical: Bool = true) async throws -> APIv2CatalogFilters {
        var query: [String: String] = [:]
        if let libraryId { query["library_id"] = libraryId }
        if !includeTechnical { query["skip_technical"] = "true" }
        return try await requestGet("/api/v2/catalog/filters", query: query)
    }

    func catalogSearchCapabilities() async throws -> APIv2CatalogSearchCapabilities {
        try await requestGet("/api/v2/catalog/search/capabilities")
    }

    func libraryCollectionTab(libraryId: String) async throws -> APIv2LibraryCollectionTab {
        try await requestGet("/api/v2/library/\(libraryId)/collections")
    }

    // MARK: Catalog detail and hierarchy reads

    func catalogItem(id: String, libraryId: String? = nil, fileId: String? = nil,
                     imageSize: String? = nil) async throws -> APIv2CatalogRead.CatalogItemDetail {
        var query = catalogReadScope(libraryId: libraryId, imageSize: imageSize)
        if let fileId { query["file_id"] = fileId }
        return try await catalogRead("/api/v2/catalog/items/\(try catalogPathSegment(id))", query: query)
    }

    func catalogSeasons(seriesId: String, libraryId: String? = nil,
                        imageSize: String? = nil) async throws -> [APIv2CatalogRead.Season] {
        let response: APIv2CatalogReadCollection<APIv2CatalogRead.Season> = try await catalogRead(
            "/api/v2/catalog/series/\(try catalogPathSegment(seriesId))/seasons",
            query: catalogReadScope(libraryId: libraryId, imageSize: imageSize))
        return try response.completeItems()
    }

    func catalogEpisodes(seriesId: String, seasonNumber: Int, libraryId: String? = nil,
                         imageSize: String? = nil) async throws -> [APIv2CatalogRead.Episode] {
        guard seasonNumber >= 0 else { throw APIv2Error.invalidCatalogQuery }
        let response: APIv2CatalogReadCollection<APIv2CatalogRead.Episode> = try await catalogRead(
            "/api/v2/catalog/series/\(try catalogPathSegment(seriesId))/seasons/\(seasonNumber)/episodes",
            query: catalogReadScope(libraryId: libraryId, imageSize: imageSize))
        return try response.completeItems()
    }

    func catalogPerson(id: String) async throws -> APIv2CatalogRead.Person {
        try await catalogRead("/api/v2/catalog/people/\(try catalogPathSegment(id))")
    }

    func catalogPeople(query: String, limit: Int = 20) async throws -> [APIv2CatalogRead.Person] {
        guard (1...100).contains(limit), query.count <= 200 else { throw APIv2Error.invalidCatalogQuery }
        let response: APIv2CatalogReadCollection<APIv2CatalogRead.Person> = try await catalogRead(
            "/api/v2/catalog/people", query: ["q": query, "limit": String(limit)])
        return try response.completeItems()
    }

    private func catalogReadScope(libraryId: String?, imageSize: String?) -> [String: String] {
        var query: [String: String] = [:]
        if let libraryId { query["library_id"] = libraryId }
        if let imageSize { query["image_size"] = imageSize }
        return query
    }

    private func catalogPathSegment(_ value: String) throws -> String {
        guard !value.isEmpty, value != ".", value != "..",
              let escaped = value.addingPercentEncoding(withAllowedCharacters:
                CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) else {
            throw APIv2Error.invalidCatalogQuery
        }
        return escaped
    }

    private func catalogRead<Value: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> Value {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth(), let profile = auth.profileId else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let response = try await mapErrors {
            try await http.requestData(method: "GET", path: path, query: query, requestIdentity: identity)
        }
        guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.account == auth.account,
              current.profileId == profile else { throw HTTPError.requestIdentityChanged }
        return try HTTPClient.makeJSONDecoder().decode(Value.self, from: response.data)
    }

    // MARK: Internals

    /// Refuses relative-URL (active-session) operations while the active
    /// server is known to be v1-only. Explicit-URL candidate probes skip this.
    private func gate() async throws {
        if await isUpdateRequired() { throw APIv2Error.serverUpdateRequired }
    }

    private func mapErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch HTTPError.http(let statusCode, let body) {
            if let body, let data = body.data(using: .utf8),
               let problem = try? HTTPClient.makeJSONDecoder().decode(APIv2Problem.self, from: data) {
                throw APIv2Error.problem(problem)
            }
            throw APIv2Error.httpStatus(statusCode)
        }
    }
}
