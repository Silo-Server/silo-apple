import Foundation

/// Errors raised by the v2 request layer.
enum APIv2Error: LocalizedError, Sendable {
    /// The connected server is v1-only (see `APIv2Probe`). Pilot operations
    /// are refused rather than routed to a v1 path.
    case serverUpdateRequired
    case invalidSubtitleResponse
    case invalidNotificationContinuation
    case incompleteAuthResponse
    case incompleteRequestList
    case missingCollectionVersion
    case incompleteCollection
    case invalidCatalogQuery
    case invalidCatalogContinuation
    case invalidPersonalListQuery
    case invalidPersonalListContinuation
    case incompleteCatalogRead
    case unsupportedCatalogReadValue
    /// The server answered with an `application/problem+json` document.
    case problem(APIv2Problem)
    /// A non-2xx status whose body was not a problem document.
    case httpStatus(Int)

    static let serverUpdateRequiredMessage =
        "This server needs to be updated before this version of Silo can use it."

    var errorDescription: String? {
        switch self {
        case .invalidSubtitleResponse: return "The subtitle response cannot be used by this player."
        case .invalidNotificationContinuation: return "The notification sync could not be continued. Try again."
        case .incompleteAuthResponse: return "The server returned an incomplete sign-in response. Start sign-in again."
        case .invalidPersonalListQuery:
            return "The personal list request is not valid."
        case .invalidPersonalListContinuation:
            return "The personal list could not be continued. Reload to start again."
        case .unsupportedCatalogReadValue:
            return "This item uses a value this client cannot support. Please update the client."
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
        guard let captured = await tokenStore.captureOrdinaryRequestAuth() else { throw HTTPError.requestIdentityChanged }
        let value: APIv2Account = try await mapErrors { try await http.get("/api/v2/account/me") }
        guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.account == captured.account else {
            throw HTTPError.requestIdentityChanged
        }
        try await tokenStore.bindVerifiedAccount(value.id, expected: current)
        return value
    }

    /// Account discovery is valid before selecting a household profile.
    func userLibraries() async throws -> [APIv2UserLibrary] {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = auth.profileId.map {
            HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
                profileId: $0, clientFamily: AppleDeviceIdentity.current.clientFamily)
        }
        let response = try await mapErrors {
            try await http.requestData(method: "GET", path: "/api/v2/user/libraries",
                headers: auth.profileId == nil ? ["X-Profile-Id": ""] : [:],
                requestIdentity: identity, expectedAccount: auth.account)
        }
        guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.account == auth.account,
              current.profileId == auth.profileId else { throw HTTPError.requestIdentityChanged }
        return try HTTPClient.makeJSONDecoder()
            .decode(APIv2CatalogReadCollection<APIv2UserLibrary>.self, from: response.data).completeItems()
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
    func requestPost<T: Decodable, B: Encodable>(_ path: String, body: B, timeout: HTTPTimeout = .standard) async throws -> T {
        try await gate()
        return try await mapErrors { try await http.post(path, body: body, timeout: timeout) }
    }

    func settingsRead(_ path: String, query: [URLQueryItem] = [], profileID: String? = nil,
                      expectedIdentity: HTTPRequestIdentity? = nil, profileRequired: Bool = false) async throws -> Data {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else { throw HTTPError.requestIdentityChanged }
        if profileRequired && auth.profileId == nil { throw SettingsAPIError.profileRequired }
        if let profileID, profileID != auth.profileId { throw HTTPError.requestIdentityChanged }
        let identity = auth.profileId.map {
            HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
                profileId: $0, clientFamily: AppleDeviceIdentity.current.clientFamily)
        }
        if let expectedIdentity, expectedIdentity != identity { throw HTTPError.requestIdentityChanged }
        let response = try await mapErrors {
            try await http.requestData(method: "GET", path: path, repeatedQuery: query,
                headers: auth.profileId == nil ? ["X-Profile-Id": ""] : [:],
                requestIdentity: identity, expectedAccount: auth.account)
        }
        guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.account == auth.account,
              current.profileId == auth.profileId, current.profileToken == auth.profileToken else {
            throw HTTPError.requestIdentityChanged
        }
        guard response.statusCode == 200 else { throw APIv2Error.incompleteCatalogRead }
        return response.data
    }

    func metadataAIStatus() async throws -> MetadataAIStatus {
        let data = try await settingsRead("/api/v2/capabilities/metadata-ai", profileRequired: true)
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2MetadataAICapability.self, from: data)
        guard !wire.revision.isEmpty else { throw APIv2Error.incompleteCatalogRead }
        return wire.playerValue
    }

    // The selection owner supplies authority captured before scheduling the write.
    func writeTrackPreference<Body: Encodable>(kind: String, seriesId: String, body: Body,
                                              auth: CapturedOrdinaryRequestAuth) async throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try await mutateTrackPreference(kind: kind, seriesId: seriesId, method: "PUT",
                                        body: encoder.encode(body), auth: auth)
    }

    func deleteTrackPreference(kind: String, seriesId: String, auth: CapturedOrdinaryRequestAuth) async throws {
        try await mutateTrackPreference(kind: kind, seriesId: seriesId, method: "DELETE", body: nil, auth: auth)
    }

    private func mutateTrackPreference(kind: String, seriesId: String, method: String, body: Data?,
                                       auth: CapturedOrdinaryRequestAuth) async throws {
        try await gate()
        guard ["audio", "subtitle"].contains(kind), !seriesId.isEmpty,
              let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil,
              let segment = seriesId.addingPercentEncoding(withAllowedCharacters:
                CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let response = try await mapErrors {
            try await http.requestData(method: method, path: "/api/v2/\(kind)-prefs/\(segment)", body: body,
                requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        guard response.statusCode == 204 else { throw APIv2Error.httpStatus(response.statusCode) }
    }

    func matchesAIAuthority(_ auth: CapturedOrdinaryRequestAuth) async -> Bool {
        guard let current = await tokenStore.captureOrdinaryRequestAuth() else { return false }
        return current.account == auth.account && current.profileId == auth.profileId && current.profileToken == auth.profileToken
    }

    func translateDescription(contentID: String, language: String, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2MetadataTranslationJob {
        try await gate()
        guard auth.profileId != nil, await matchesAIAuthority(auth), !contentID.isEmpty,
              !language.isEmpty, language.count <= 16,
              let segment = contentID.addingPercentEncoding(withAllowedCharacters:
                CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: auth.profileId!, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let raw = try await mapErrors {
            try await http.requestData(method: "POST", path: "/api/v2/catalog/items/\(segment)/translate-description",
                body: encoder.encode(TranslateDescriptionBody(targetLanguage: language)),
                requestIdentity: identity, expectedAccount: auth.account)
        }
        guard await matchesAIAuthority(auth) else { throw HTTPError.requestIdentityChanged }
        guard raw.statusCode == 202 else { throw APIv2Error.incompleteCatalogRead }
        let job = try HTTPClient.makeJSONDecoder().decode(APIv2MetadataTranslationJob.self, from: raw.data)
        guard !job.id.isEmpty, job.contentId == contentID, ["item", "season", "episode"].contains(job.targetKind) else {
            throw APIv2Error.incompleteCatalogRead
        }
        return job
    }

    func subtitleCreateAuthority() async throws -> CapturedOrdinaryRequestAuth {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else { throw HTTPError.requestIdentityChanged }
        return auth
    }

    func createSubtitle(_ body: APIv2SubtitleCreateBody, auth: CapturedOrdinaryRequestAuth) async throws -> SubtitleCreationResult {
        let current = try await subtitleCreateAuthority()
        guard current.account == auth.account, current.profileId == auth.profileId,
              current.profileToken == auth.profileToken else { throw HTTPError.requestIdentityChanged }
        let identity = auth.profileId.map {
            HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
                profileId: $0, clientFamily: AppleDeviceIdentity.current.clientFamily)
        }
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let raw = try await mapErrors {
            try await http.requestData(method: "POST", path: "/api/v2/subtitles/ai/translate", body: encoder.encode(body),
                headers: auth.profileId == nil ? ["X-Profile-Id": ""] : [:],
                requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
        }
        let after = try await subtitleCreateAuthority()
        guard after.account == auth.account, after.profileId == auth.profileId,
              after.profileToken == auth.profileToken else { throw HTTPError.requestIdentityChanged }
        guard raw.statusCode == 202 else { throw APIv2Error.invalidSubtitleResponse }
        let response = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleCreateResponse.self, from: raw.data)
        guard let id = Int64(response.job.id), id > 0, String(id) == response.job.id,
              response.job.mediaFileId == body.mediaFileId, response.job.kind == body.kind.rawValue,
              response.job.sourceIndex == body.sourceIndex,
              !response.liveDeliveryAttached || body.sessionId != nil else { throw APIv2Error.invalidSubtitleResponse }
        return try SubtitleCreationResult(job: SubtitleJob(v2: response.job, expectedJobID: response.job.id),
            liveDeliveryAttached: response.liveDeliveryAttached)
    }

    /// Acknowledges a cancellation request; completion may already have won.
    func cancelSubtitleJob(id: String) async throws {
        guard let value = Int64(id), value > 0, String(value) == id else {
            throw APIv2Error.invalidSubtitleResponse
        }
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = auth.profileId.map {
            HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
                profileId: $0, clientFamily: AppleDeviceIdentity.current.clientFamily)
        }
        let response = try await mapErrors {
            try await http.requestData(method: "POST", path: "/api/v2/subtitles/ai/jobs/\(id)/cancel",
                headers: auth.profileId == nil ? ["X-Profile-Id": ""] : [:],
                requestIdentity: identity, expectedAccount: auth.account)
        }
        guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.account == auth.account,
              current.profileId == auth.profileId, current.profileToken == auth.profileToken else {
            throw HTTPError.requestIdentityChanged
        }
        guard response.statusCode == 204, response.data.isEmpty else { throw APIv2Error.invalidSubtitleResponse }
    }

    /// Provider download has no durable replay receipt, including after401.
    func downloadSubtitle(_ body: SubtitleDownloadBody, expectedAuth: CapturedOrdinaryRequestAuth? = nil) async throws -> DownloadedSubtitle {
        try await gate()
        guard body.mediaFileId > 0, let auth = await tokenStore.captureOrdinaryRequestAuth(),
              let profile = auth.profileId else { throw HTTPError.requestIdentityChanged }
        if let expectedAuth {
            guard auth.account == expectedAuth.account, auth.profileId == expectedAuth.profileId,
                  auth.profileToken == expectedAuth.profileToken else { throw HTTPError.requestIdentityChanged }
        }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(APIv2SubtitleDownloadBody(body))
        let response = try await mapErrors {
            try await http.requestData(method: "POST", path: "/api/v2/subtitles/download", body: data,
                timeout: .extended, requestIdentity: identity, expectedAccount: auth.account)
        }
        guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.account == auth.account,
              current.profileId == auth.profileId, current.profileToken == auth.profileToken else {
            throw HTTPError.requestIdentityChanged
        }
        guard response.statusCode == 200 else { throw APIv2Error.invalidSubtitleResponse }
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleDownloadResponse.self, from: response.data)
        return try wire.subtitle.playerValue(mediaFileID: body.mediaFileId)
    }

    private func householdRequest<T: Decodable>(_ method: String, path: String, body: Data? = nil, status: Int) async throws -> T {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else { throw HTTPError.requestIdentityChanged }
        let identity = auth.profileId.map {
            HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
                profileId: $0, clientFamily: AppleDeviceIdentity.current.clientFamily)
        }
        let response = try await mapErrors {
            try await http.requestData(method: method, path: path, body: body,
                headers: auth.profileId == nil ? ["X-Profile-Id": ""] : [:],
                requestIdentity: identity, expectedAccount: auth.account)
        }
        guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.account == auth.account,
              current.profileId == auth.profileId, current.profileToken == auth.profileToken else {
            throw HTTPError.requestIdentityChanged
        }
        guard response.statusCode == status else { throw APIv2Error.httpStatus(response.statusCode) }
        return try HTTPClient.makeJSONDecoder().decode(T.self, from: response.data)
    }

    func householdProfiles() async throws -> [UserProfile] {
        let collection: APIv2CatalogReadCollection<APIv2Profile> = try await householdRequest("GET", path: "/api/v2/profiles", status: 200)
        let rows = try collection.completeItems()
        guard Set(rows.map(\.id)).count == rows.count else { throw APIv2Error.incompleteCollection }
        return rows.map(\.asUserProfile)
    }

    func createHouseholdProfile(_ body: CreateProfileRequestBody) async throws -> UserProfile {
        guard body.allowedLibraryIds.allSatisfy({ $0 > 0 }) else { throw APIv2Error.invalidCatalogQuery }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let wire = APIv2ProfileCreate(name: body.name, avatar: body.avatar, pin: body.pin,
            isChild: body.isChild, maxContentRating: body.maxContentRating,
            libraryRestrictionsEnabled: body.libraryRestrictionsEnabled, allowedLibraryIds: body.allowedLibraryIds.map(String.init))
        let row: APIv2Profile = try await householdRequest("POST", path: "/api/v2/profiles", body: encoder.encode(wire), status: 201)
        return row.asUserProfile
    }

    func verifyHouseholdPIN(id: String, pin: String) async throws -> VerifyPinResponse {
        guard !id.isEmpty, id != ".", id != "..", let segment = id.addingPercentEncoding(withAllowedCharacters:
            CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) else { throw APIv2Error.invalidCatalogQuery }
        let data = try JSONEncoder().encode(VerifyPinRequest(pin: pin))
        return try await householdRequest("POST", path: "/api/v2/profiles/\(segment)/verify-pin", body: data, status: 200)
    }

    func onboardingRead(surface: String? = nil) async throws -> APIv2OnboardingSession {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth(), let profile = auth.profileId else { throw HTTPError.requestIdentityChanged }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let raw = try await http.requestData(method: "GET", path: "/api/v2/onboarding/state",
            requestIdentity: identity, expectedAccount: auth.account)
        let state = try HTTPClient.makeJSONDecoder().decode(OnboardingState.self, from: raw.data)
        let tag = try DownloadSubscriptionV2.validator(raw.header("ETag"))
        var flow: OnboardingFlow?
        if let surface {
            let response = try await http.requestData(method: "GET", path: "/api/v2/onboarding/flow", query: ["surface": surface],
                requestIdentity: identity, expectedAccount: auth.account)
            flow = try HTTPClient.makeJSONDecoder().decode(OnboardingFlow.self, from: response.data)
            guard flow?.tourId == state.tourId else { throw APIv2Error.incompleteCollection }
        }
        guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.account == auth.account,
              current.profileId == auth.profileId, current.profileToken == auth.profileToken else { throw HTTPError.requestIdentityChanged }
        return APIv2OnboardingSession(id: UUID(), auth: auth, tag: tag, state: state, flow: flow)
    }

    func onboardingWrite(_ body: OnboardingProgressRequest, session: APIv2OnboardingSession) async throws -> APIv2OnboardingSession {
        try await gate()
        guard body.writerID == session.id, body.tourId == session.state.tourId,
              let current = await tokenStore.captureOrdinaryRequestAuth(), current.account == session.auth.account,
              current.profileId == session.auth.profileId, current.profileToken == session.auth.profileToken,
              let profile = current.profileId else { throw HTTPError.requestIdentityChanged }
        let identity = HTTPRequestIdentity(serverId: current.account.serverId, serverURL: current.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let raw = try await http.requestData(method: "PUT", path: "/api/v2/onboarding/progress", body: encoder.encode(body),
            headers: ["If-Match": session.tag], requestIdentity: identity, expectedAccount: session.auth.account)
        guard let after = await tokenStore.captureOrdinaryRequestAuth(), after.account == session.auth.account,
              after.profileId == session.auth.profileId, after.profileToken == session.auth.profileToken else { throw HTTPError.requestIdentityChanged }
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let state = try HTTPClient.makeJSONDecoder().decode(OnboardingState.self, from: raw.data)
        guard state.tourId == body.tourId else { throw APIv2Error.incompleteCollection }
        return APIv2OnboardingSession(id: session.id, auth: session.auth,
            tag: try DownloadSubscriptionV2.validator(raw.header("ETag")), state: state, flow: session.flow)
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

    func catalogPage(query: APIv2CatalogQuery, operation: APIv2CatalogOperation = .get,
                     auth suppliedAuth: CapturedOrdinaryRequestAuth? = nil) async throws -> APIv2CatalogResult {
        try await gate()
        let captured = await tokenStore.captureOrdinaryRequestAuth()
        guard let auth = suppliedAuth ?? captured, let profile = auth.profileId else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        return try await fetchCatalogPage(query: query, operation: operation, cursor: nil, seen: [],
            identity: identity, auth: auth)
    }

    func nextCatalogPage(_ continuation: APIv2CatalogContinuation) async throws -> APIv2CatalogResult {
        try await fetchCatalogPage(query: continuation.query, operation: continuation.operation,
            cursor: continuation.cursor, seen: continuation.seen,
            identity: continuation.identity, auth: continuation.auth)
    }

    private func fetchCatalogPage(query: APIv2CatalogQuery, operation: APIv2CatalogOperation,
        cursor: String?, seen: Set<String>, identity: HTTPRequestIdentity,
        auth: CapturedOrdinaryRequestAuth) async throws -> APIv2CatalogResult {
        try await gate()
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
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
                query: parameters, body: body, requestIdentity: identity,
                expectedAccount: auth.account, expectedAuth: auth)
            guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
                throw HTTPError.requestIdentityChanged
            }
            try Task.checkCancellation()
            guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
            return try HTTPClient.makeJSONDecoder().decode(APIv2CatalogPage.self, from: response.data)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        var continuation: APIv2CatalogContinuation?
        if page.page.hasMore {
            guard let next = page.page.nextCursor, !next.isEmpty, !seen.contains(next) else {
                throw APIv2Error.invalidCatalogContinuation
            }
            continuation = APIv2CatalogContinuation(query: query, operation: operation, cursor: next,
                seen: seen.union([next]), identity: identity, account: auth.account, auth: auth)
        }
        return APIv2CatalogResult(auth: auth, value: page, continuation: continuation)
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

    func setWatchedState(id: String, included: Bool, auth: CapturedOrdinaryRequestAuth) async throws {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let path = "/api/v2/watched/\(try catalogPathSegment(id))"
        let raw = try await mapErrors {
            try await http.requestData(method: included ? "POST" : "DELETE", path: path,
                requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        guard raw.statusCode == 204 else { throw APIv2Error.httpStatus(raw.statusCode) }
    }

    func setFavoriteMembership(id: String, included: Bool, auth: CapturedOrdinaryRequestAuth) async throws {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let path = "/api/v2/favorites/\(try catalogPathSegment(id))"
        let raw = try await mapErrors {
            try await http.requestData(method: included ? "PUT" : "DELETE", path: path,
                requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        guard raw.statusCode == 204 else { throw APIv2Error.httpStatus(raw.statusCode) }
    }

    func setWatchlistMembership(id: String, included: Bool, auth: CapturedOrdinaryRequestAuth) async throws {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let path = "/api/v2/watchlist/\(try catalogPathSegment(id))"
        let raw = try await mapErrors {
            try await http.requestData(method: included ? "PUT" : "DELETE", path: path,
                requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        guard raw.statusCode == 204 else { throw APIv2Error.httpStatus(raw.statusCode) }
    }

    /// Membership reads return an entry on 200 and absence on 404, never legacy 204.
    func personalMembership(id: String, watchlist: Bool, auth: CapturedOrdinaryRequestAuth?) async throws -> Bool {
        try await gate()
        guard let auth, let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let path = "/api/v2/\(watchlist ? "watchlist" : "favorites")/\(try catalogPathSegment(id))"
        let raw = try await mapErrors {
            try await http.requestData(method: "GET", path: path, quietStatuses: [404],
                requestIdentity: identity, acceptedStatuses: [404], expectedAccount: auth.account, expectedAuth: auth)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        if raw.statusCode == 404 {
            let problem = try HTTPClient.makeJSONDecoder().decode(APIv2Problem.self, from: raw.data)
            guard problem.status == 404, problem.identifier == "not_found" else {
                throw APIv2Error.problem(problem)
            }
            return false
        }
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        struct Entry: Decodable { let itemId: String; let addedAt: String }
        let entry = try HTTPClient.makeJSONDecoder().decode(Entry.self, from: raw.data)
        guard entry.itemId == id, !entry.addedAt.isEmpty else { throw APIv2Error.incompleteCatalogRead }
        return true
    }

    func discover(auth: CapturedOrdinaryRequestAuth) async throws -> [APIv2DiscoverRow] {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let raw = try await mapErrors {
            try await http.requestData(method: "GET", path: "/api/v2/recommendations/discover",
                requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let collection = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogReadCollection<APIv2DiscoverRow>.self, from: raw.data)
        let rows = try collection.completeItems()
        guard rows.allSatisfy({ row in
            Set(row.items.map(\.contentId)).count == row.items.count &&
                row.items.allSatisfy { !$0.contentId.isEmpty }
        }) else { throw APIv2Error.incompleteCatalogRead }
        return rows
    }

    func dismissHomeItem(id: String, progressUpdatedAt: String?, seriesId: String?,
                         auth: CapturedOrdinaryRequestAuth?) async throws {
        guard let auth, let profile = auth.profileId, !profile.isEmpty else { throw HTTPError.requestIdentityChanged }
        try await gate()
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let surface: String
        if let progressUpdatedAt, !progressUpdatedAt.isEmpty { surface = "continue_watching" }
        else if let seriesId, !seriesId.isEmpty { surface = "next_up" }
        else { throw APIv2Error.incompleteCatalogRead }
        struct Body: Encodable { let progressUpdatedAt: String?; let seriesId: String? }
        // Preserve the observed anchor verbatim. Do not manufacture a timestamp or rebase it.
        let body = Body(progressUpdatedAt: surface == "continue_watching" ? progressUpdatedAt : nil,
                        seriesId: surface == "next_up" ? seriesId : nil)
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(body)
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let path = "/api/v2/home/dismissals/\(surface)/\(try catalogPathSegment(id))"
        let raw = try await mapErrors {
            try await http.requestData(method: "PUT", path: path, body: data,
                requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        guard raw.statusCode == 204 else { throw APIv2Error.httpStatus(raw.statusCode) }
    }

    func librarySections(id: Int, imageSize: String?, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2LibrarySectionsRead {
        try await gate()
        guard id > 0, let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let raw = try await mapErrors {
            try await http.requestData(method: "GET", path: "/api/v2/library/\(id)/sections",
                query: imageSize.map { ["image_size": $0] } ?? [:],
                requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        struct Wire: Decodable { let sections: [ResolvedSection] }
        let value = try HTTPClient.makeJSONDecoder().decode(Wire.self, from: raw.data)
        guard Set(value.sections.map(\.id)).count == value.sections.count,
              value.sections.allSatisfy({ !$0.id.isEmpty }) else { throw APIv2Error.incompleteCatalogRead }
        return APIv2LibrarySectionsRead(libraryId: id, auth: auth,
            response: SectionsResponse(sections: value.sections))
    }

    func homeSections(imageSize: String?, auth: CapturedOrdinaryRequestAuth) async throws -> SectionsResponse {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let raw = try await mapErrors {
            try await http.requestData(method: "GET", path: "/api/v2/home/sections",
                query: imageSize.map { ["image_size": $0] } ?? [:],
                requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        struct Wire: Decodable { let sections: [ResolvedSection] }
        let value = try HTTPClient.makeJSONDecoder().decode(Wire.self, from: raw.data)
        guard Set(value.sections.map(\.id)).count == value.sections.count,
              value.sections.allSatisfy({ !$0.id.isEmpty }) else { throw APIv2Error.incompleteCatalogRead }
        var response = SectionsResponse(sections: value.sections)
        response.homeReadAuth = auth
        return response
    }

    func calendar(start: String, end: String, filter: String, timezone: String,
                  auth: CapturedOrdinaryRequestAuth) async throws -> CalendarResponse {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let raw = try await mapErrors {
            try await http.requestData(method: "GET", path: "/api/v2/calendar",
                query: ["start": start, "end": end, "filter": filter, "timezone": timezone],
                requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try HTTPClient.makeJSONDecoder().decode(CalendarResponse.self, from: raw.data)
    }

    func similarCards(id: String, limit: Int, auth: CapturedOrdinaryRequestAuth) async throws -> [BrowseItem] {
        try await gate()
        guard (1...50).contains(limit), let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let path = "/api/v2/recommendations/similar/\(try catalogPathSegment(id))"
        let raw = try await mapErrors {
            try await http.requestData(method: "GET", path: path, query: ["limit": String(limit)],
                requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let collection = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogReadCollection<BrowseItem>.self, from: raw.data)
        let cards = try collection.completeItems()
        guard cards.count <= limit, Set(cards.map(\.contentId)).count == cards.count,
              cards.allSatisfy({ !$0.contentId.isEmpty }) else { throw APIv2Error.incompleteCatalogRead }
        return cards
    }

    func refreshTrailers(id: String, auth: CapturedOrdinaryRequestAuth) async throws -> TrailerRefreshResponse {
        let raw = try await trailerRequest(id: id, refresh: true, auth: auth)
        let response = try HTTPClient.makeJSONDecoder().decode(TrailerRefreshResponse.self, from: raw.data)
        guard (raw.statusCode == 202 && response.status == "queued") ||
              (raw.statusCode == 200 && ["cooldown", "disabled"].contains(response.status)) else {
            throw APIv2Error.incompleteCatalogRead
        }
        return response
    }

    func trailerItem(id: String, imageSize: String?, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2CatalogRead.CatalogItemDetail {
        let raw = try await trailerRequest(id: id, refresh: false, imageSize: imageSize, auth: auth)
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let item = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.CatalogItemDetail.self, from: raw.data)
        guard item.contentId == id else { throw APIv2Error.incompleteCatalogRead }
        return item
    }

    private func trailerRequest(id: String, refresh: Bool, imageSize: String? = nil,
                                auth: CapturedOrdinaryRequestAuth) async throws -> HTTPRawResponse {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let path = "/api/v2/catalog/items/\(try catalogPathSegment(id))" + (refresh ? "/trailers/refresh" : "")
        let raw = try await mapErrors {
            try await http.requestData(method: refresh ? "POST" : "GET", path: path,
                query: refresh ? [:] : catalogReadScope(libraryId: nil, imageSize: imageSize),
                requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        return raw
    }

    func catalogItem(id: String, imageSize: String?, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2CatalogRead.CatalogItemDetail {
        // Same exact viewer detail read and authority fence used by bounded trailer observation.
        try await trailerItem(id: id, imageSize: imageSize, auth: auth)
    }

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

    func catalogEpisodes(seriesId: String, seasonNumber: Int, imageSize: String?,
                         auth: CapturedOrdinaryRequestAuth) async throws -> [APIv2CatalogRead.Episode] {
        try await gate()
        guard seasonNumber >= 0 else { throw APIv2Error.invalidCatalogQuery }
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let path = "/api/v2/catalog/series/\(try catalogPathSegment(seriesId))/seasons/\(seasonNumber)/episodes"
        let raw = try await mapErrors {
            try await http.requestData(method: "GET", path: path,
                query: catalogReadScope(libraryId: nil, imageSize: imageSize),
                requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let response = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogReadCollection<APIv2CatalogRead.Episode>.self, from: raw.data)
        return try response.completeItems()
    }

    func catalogSeasons(seriesId: String, imageSize: String?,
                         auth: CapturedOrdinaryRequestAuth) async throws -> [APIv2CatalogRead.Season] {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let path = "/api/v2/catalog/series/\(try catalogPathSegment(seriesId))/seasons"
        let raw = try await mapErrors {
            try await http.requestData(method: "GET", path: path,
                query: catalogReadScope(libraryId: nil, imageSize: imageSize),
                requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let response = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogReadCollection<APIv2CatalogRead.Season>.self, from: raw.data)
        return try response.completeItems()
    }

    func refreshPerson(id: Int, auth: CapturedOrdinaryRequestAuth) async throws -> PersonRefreshQueuedResponse {
        let response = try await personRequest(id: id, method: "POST", auth: auth)
        guard response.statusCode == 202 else { throw APIv2Error.httpStatus(response.statusCode) }
        struct Queued: Decodable { let status: String; let personId: String }
        let wire = try HTTPClient.makeJSONDecoder().decode(Queued.self, from: response.data)
        guard wire.status == "queued", wire.personId == String(id) else { throw APIv2Error.incompleteCatalogRead }
        return PersonRefreshQueuedResponse(status: wire.status, personId: id)
    }

    func catalogPerson(id: Int, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2CatalogRead.Person {
        let response = try await personRequest(id: id, method: "GET", auth: auth)
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        let person = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.Person.self, from: response.data)
        guard person.id == String(id) else { throw APIv2Error.incompleteCatalogRead }
        return person
    }

    private func personRequest(id: Int, method: String, auth: CapturedOrdinaryRequestAuth) async throws -> HTTPRawResponse {
        try await gate()
        guard id > 0, let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let suffix = method == "POST" ? "/refresh" : ""
        let response = try await mapErrors {
            try await http.requestData(method: method, path: "/api/v2/catalog/people/\(id)\(suffix)",
                requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        return response
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

    // MARK: Standalone personal list reads

    func personalList(kind: APIv2PersonalListKind, limit: Int = 50,
                      imageSize: String? = nil, auth original: CapturedOrdinaryRequestAuth? = nil) async throws -> APIv2PersonalListResult {
        try await gate()
        guard (1...200).contains(limit) else { throw APIv2Error.invalidPersonalListQuery }
        let captured: CapturedOrdinaryRequestAuth?
        if let original { captured = original } else { captured = await tokenStore.captureOrdinaryRequestAuth() }
        guard let auth = captured, let profile = auth.profileId, !profile.isEmpty else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        return try await personalListPage(kind: kind, limit: limit, imageSize: imageSize, cursor: nil,
                                          seen: [], identity: identity, account: auth.account, auth: auth)
    }

    func nextPersonalListPage(_ continuation: APIv2PersonalListContinuation) async throws -> APIv2PersonalListResult {
        try await personalListPage(kind: continuation.kind, limit: continuation.limit, imageSize: continuation.imageSize,
            cursor: continuation.cursor, seen: continuation.seen, identity: continuation.identity, account: continuation.account, auth: continuation.auth)
    }

    private func personalListPage(kind: APIv2PersonalListKind, limit: Int, imageSize: String?, cursor: String?,
                                  seen: Set<String>, identity: HTTPRequestIdentity,
                                  account: RefreshAccountIdentity, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2PersonalListResult {
        try await gate()
        guard auth.account == account, auth.profileId == identity.profileId,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else { throw HTTPError.requestIdentityChanged }
        try Task.checkCancellation()
        var query = ["limit": String(limit)]
        if let imageSize { query["image_size"] = imageSize }
        if let cursor { query["cursor"] = cursor }
        let response = try await mapErrors {
            try await http.requestData(method: "GET", path: "/api/v2/\(kind.rawValue)", query: query, requestIdentity: identity, expectedAccount: account, expectedAuth: auth)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else { throw HTTPError.requestIdentityChanged }
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        let page = try HTTPClient.makeJSONDecoder().decode(APIv2PersonalListPage.self, from: response.data)
        var continuation: APIv2PersonalListContinuation?
        if page.page.hasMore {
            guard let next = page.page.nextCursor, !next.isEmpty, !seen.contains(next) else {
                throw APIv2Error.invalidPersonalListContinuation
            }
            continuation = APIv2PersonalListContinuation(kind: kind, limit: limit, imageSize: imageSize,
                cursor: next, seen: seen.union([next]), identity: identity, account: account, auth: auth)
        } else if page.page.nextCursor?.isEmpty == false {
            throw APIv2Error.invalidPersonalListContinuation
        }
        // Empty/duplicate-only visible pages still advance through raw list entries.
        return APIv2PersonalListResult(auth: auth, value: page, continuation: continuation)
    }

    // MARK: Progress bootstrap (wire only)

    func progressBootstrapCapabilities() async throws -> APIv2ProgressBootstrapCapabilities {
        let intent = try await makeProgressSnapshotIntent(requestId: UUID(), limit: 200)
        let response = try await progressBootstrapRequest(method: "GET",
            path: "/api/v2/sync/progress/capabilities", intent: intent)
        return try HTTPClient.makeJSONDecoder().decode(APIv2ProgressBootstrapCapabilities.self, from: response.data)
    }

    /// A future durable coordinator supplies and persists this UUID before dispatch.
    func makeProgressSnapshotIntent(requestId: UUID, limit: Int = 200) async throws -> APIv2ProgressSnapshotIntent {
        try await gate()
        guard (1...200).contains(limit) else { throw APIv2ProgressBootstrapError.invalidIntent }
        guard let auth = await tokenStore.captureOrdinaryRequestAuth(), let profile = auth.profileId else {
            throw HTTPError.requestIdentityChanged
        }
        return APIv2ProgressSnapshotIntent(requestId: requestId, limit: limit,
            identity: HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
                profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily), account: auth.account)
    }

    func createProgressSnapshot(_ intent: APIv2ProgressSnapshotIntent) async throws -> APIv2ProgressSnapshotResult {
        struct Admission: Encodable { let request_id: String; let limit: Int }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(Admission(request_id: intent.requestId.uuidString.lowercased(), limit: intent.limit))
        let response = try await progressBootstrapRequest(method: "POST", path: "/api/v2/sync/progress/snapshots",
            body: body, intent: intent)
        guard response.statusCode == 201 else { throw APIv2ProgressBootstrapError.invalidSnapshot }
        return try decodeProgressSnapshot(response, intent: intent, previous: nil)
    }

    func progressSnapshotPage(_ cursor: APIv2ProgressSnapshotCursor) async throws -> APIv2ProgressSnapshotResult {
        let response = try await progressBootstrapRequest(method: "GET",
            path: "/api/v2/sync/progress/snapshots/\(cursor.snapshot.snapshotId)",
            query: ["cursor": cursor.token], intent: cursor.intent)
        guard response.statusCode == 200 else { throw APIv2ProgressBootstrapError.invalidSnapshot }
        return try decodeProgressSnapshot(response, intent: cursor.intent, previous: cursor)
    }

    private func progressBootstrapRequest(method: String, path: String, query: [String: String] = [:],
        body: Data? = nil, intent: APIv2ProgressSnapshotIntent) async throws -> HTTPRawResponse {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth(), auth.account == intent.account,
              auth.profileId == intent.identity.profileId else { throw HTTPError.requestIdentityChanged }
        // The transport only retries a rejected 401 after scoped refresh. Lost POST replies
        // propagate; explicit replay reuses the exact domain-identity intent and body.
        let response = try await mapErrors {
            try await http.requestData(method: method, path: path, query: query, body: body,
                requestIdentity: intent.identity, acceptedStatuses: [400, 401, 403, 404, 409, 413, 422, 429, 501, 503])
        }
        guard let current = await tokenStore.captureOrdinaryRequestAuth(), current.account == intent.account,
              current.profileId == intent.identity.profileId else { throw HTTPError.requestIdentityChanged }
        guard (200..<300).contains(response.statusCode) else {
            let problem = try? HTTPClient.makeJSONDecoder().decode(APIv2Problem.self, from: response.data)
            throw APIv2ProgressBootstrapError.response(status: response.statusCode, problem: problem,
                retryAfter: response.header("Retry-After"))
        }
        return response
    }

    private func decodeProgressSnapshot(_ response: HTTPRawResponse, intent: APIv2ProgressSnapshotIntent,
        previous: APIv2ProgressSnapshotCursor?) throws -> APIv2ProgressSnapshotResult {
        let value = try HTTPClient.makeJSONDecoder().decode(APIv2ProgressSnapshot.self, from: response.data)
        let location = "/api/v2/sync/progress/snapshots/\(value.snapshotId)"
        guard UUID(uuidString: value.snapshotId) != nil, !value.installationId.isEmpty,
              !value.accountId.isEmpty, value.profileId == intent.identity.profileId,
              !value.generation.isEmpty, value.mode == "full_replace", value.itemCount >= 0,
              value.expiresAt > value.capturedAt, response.header("Location") == location,
              value.items.count <= intent.limit else { throw APIv2ProgressBootstrapError.invalidSnapshot }
        if let old = previous?.snapshot {
            guard value.snapshotId == old.snapshotId, value.installationId == old.installationId,
                  value.accountId == old.accountId, value.profileId == old.profileId,
                  value.generation == old.generation, value.capturedAt == old.capturedAt,
                  value.expiresAt == old.expiresAt, value.itemCount == old.itemCount else {
                throw APIv2ProgressBootstrapError.invalidSnapshot
            }
        }
        var items = previous?.seenItems ?? []
        for item in value.items {
            guard !item.mediaItemId.isEmpty, item.positionSeconds.isFinite, item.durationSeconds.isFinite,
                  item.positionSeconds >= 0, item.durationSeconds >= 0,
                  items.insert(item.mediaItemId).inserted else { throw APIv2ProgressBootstrapError.invalidSnapshot }
        }
        guard items.count <= value.itemCount else { throw APIv2ProgressBootstrapError.invalidSnapshot }
        let seen = previous?.seenCursors ?? []
        if value.complete {
            guard !value.page.hasMore, value.page.nextCursor == nil,
                  let receipt = value.completionToken, !receipt.isEmpty,
                  items.count == value.itemCount else { throw APIv2ProgressBootstrapError.invalidSnapshot }
            return APIv2ProgressSnapshotResult(value: value, location: location, continuation: nil,
                receipt: APIv2ProgressCompletionReceipt(token: receipt))
        }
        guard value.page.hasMore, let next = value.page.nextCursor, !next.isEmpty,
              next.count <= 8192, !seen.contains(next), value.completionToken == nil,
              !value.items.isEmpty, items.count < value.itemCount else { throw APIv2ProgressBootstrapError.invalidSnapshot }
        return APIv2ProgressSnapshotResult(value: value, location: location,
            continuation: APIv2ProgressSnapshotCursor(token: next, snapshot: value, intent: intent,
                seenCursors: seen.union([next]), seenItems: items), receipt: nil)
    }

    // MARK: Active account/device authentication

    func login(username: String, password: String, expectedAccount: RefreshAccountIdentity) async throws -> APIv2LoginTokens {
        try await gate()
        let body = try JSONEncoder().encode(LoginRequest(username: username, password: password))
        let response = try await mapErrors {
            try await http.requestData(method: "POST", path: "/api/v2/auth/login", body: body, expectedAccount: expectedAccount)
        }
        guard await tokenStore.refreshAccountIdentity() == expectedAccount else { throw HTTPError.requestIdentityChanged }
        let value = try HTTPClient.makeJSONDecoder().decode(APIv2LoginTokens.self, from: response.data)
        guard response.statusCode == 200, !value.accessToken.isEmpty, !value.refreshToken.isEmpty,
              !value.user.id.isEmpty else { throw APIv2Error.incompleteAuthResponse }
        return value
    }

    func startDeviceLogin(_ input: DeviceLoginStartRequest, expectedAccount: RefreshAccountIdentity) async throws -> DeviceLoginStartResponse {
        try await gate()
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let response = try await mapErrors {
            try await http.requestData(method: "POST", path: "/api/v2/auth/device/start", body: encoder.encode(input), expectedAccount: expectedAccount)
        }
        guard await tokenStore.refreshAccountIdentity() == expectedAccount else { throw HTTPError.requestIdentityChanged }
        guard response.statusCode == 201 else { throw APIv2Error.incompleteAuthResponse }
        return try HTTPClient.makeJSONDecoder().decode(APIv2DeviceStart.self, from: response.data).presentation
    }

    func pollDeviceLogin(deviceCode: String, expectedAccount: RefreshAccountIdentity) async throws -> DeviceLoginPollResponse {
        try await gate()
        let body = try JSONSerialization.data(withJSONObject: ["device_code": deviceCode])
        let response = try await mapErrors {
            try await http.requestData(method: "POST", path: "/api/v2/auth/device/poll", body: body, expectedAccount: expectedAccount)
        }
        guard await tokenStore.refreshAccountIdentity() == expectedAccount else { throw HTTPError.requestIdentityChanged }
        guard response.statusCode == 200 else { throw APIv2Error.incompleteAuthResponse }
        return try HTTPClient.makeJSONDecoder().decode(APIv2DevicePoll.self, from: response.data).presentation()
    }

    func deviceLookup(code: String, identity: HTTPRequestIdentity, expectedAccount: RefreshAccountIdentity) async throws -> DeviceLookupResponse {
        try await gate()
        let response = try await mapErrors {
            try await http.requestData(method: "GET", path: "/api/v2/auth/device", query: ["code": code], requestIdentity: identity, expectedAccount: expectedAccount)
        }
        guard await tokenStore.refreshAccountIdentity() == expectedAccount else { throw HTTPError.requestIdentityChanged }
        guard response.statusCode == 200 else { throw APIv2Error.incompleteAuthResponse }
        return try HTTPClient.makeJSONDecoder().decode(APIv2DeviceLookup.self, from: response.data).presentation
    }

    func decideDeviceLogin(code: String, approveHandoff: Bool, identity: HTTPRequestIdentity, expectedAccount: RefreshAccountIdentity) async throws {
        try await gate()
        let body = try JSONSerialization.data(withJSONObject: ["code": code])
        let path = approveHandoff ? "/api/v2/auth/device/approve-handoff" : "/api/v2/auth/device/deny"
        let response = try await mapErrors {
            try await http.requestData(method: "POST", path: path, body: body, requestIdentity: identity, expectedAccount: expectedAccount)
        }
        guard await tokenStore.refreshAccountIdentity() == expectedAccount else { throw HTTPError.requestIdentityChanged }
        let value = try HTTPClient.makeJSONDecoder().decode(APIv2DeviceDecision.self, from: response.data)
        guard response.statusCode == 200, value.status == (approveHandoff ? "approved" : "denied") else { throw APIv2Error.incompleteAuthResponse }
    }

    func logout(expectedAccount: RefreshAccountIdentity) async throws {
        try await gate()
        let response = try await mapErrors {
            try await http.requestData(method: "POST", path: "/api/v2/auth/logout", expectedAccount: expectedAccount)
        }
        guard response.statusCode == 204 else { throw APIv2Error.incompleteAuthResponse }
    }

    // MARK: Initial playback

    func playbackRequest(method: String, suffix: String, body: Data? = nil,
                         auth: CapturedOrdinaryRequestAuth) async throws -> HTTPRawResponse {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty else { throw HTTPError.requestIdentityChanged }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        return try await mapErrors {
            try await http.requestData(method: method, path: "/api/v2/playback" + suffix, body: body,
                requestIdentity: identity, expectedAccount: auth.account)
        }
    }

    func playbackCapabilities(auth: CapturedOrdinaryRequestAuth) async throws -> APIv2PlaybackCapabilities {
        let raw = try await playbackRequest(method: "GET", suffix: "/capabilities", auth: auth)
        guard raw.statusCode == 200 else { throw PlaybackSequencedError.invalidResponse }
        return try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackCapabilities.self, from: raw.data)
    }

    #if os(iOS)
    func notificationSync(cursor: String?, auth: CapturedOrdinaryRequestAuth) async throws -> ApplePushNotificationSyncResponse {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let raw = try await mapErrors {
            try await http.requestData(method: "GET", path: ApplePushNotificationSyncWire.endpoint,
                query: ApplePushNotificationSyncWire.query(cursor: cursor),
                requestIdentity: identity, expectedAccount: auth.account)
        }
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        let page = try HTTPClient.makeJSONDecoder().decode(ApplePushNotificationSyncResponse.self, from: raw.data)
        guard raw.statusCode == 200, !page.syncCursor.isEmpty, page.unreadCount >= 0,
              page.items.count <= ApplePushNotificationSyncWire.defaultLimit,
              page.items.allSatisfy({ !$0.id.isEmpty && $0.profileId == profile }),
              Set(page.items.map(\.id)).count == page.items.count,
              page.initialSnapshot == (cursor == nil),
              page.page.hasMore ? (page.page.nextCursor == page.syncCursor && page.syncCursor != cursor && !page.items.isEmpty) : page.page.nextCursor == nil else {
            throw APIv2Error.invalidNotificationContinuation
        }
        return page
    }
    #endif

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
