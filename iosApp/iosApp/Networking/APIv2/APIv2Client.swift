import Foundation

/// Errors raised by the v2 request layer.
enum APIv2Error: LocalizedError, Sendable {
    /// The connected server is v1-only: the recorded `APIv2Probe` verdict
    /// refused the call before it left the device, or a v2 route answered with
    /// the legacy listener's plain 404. Never routed to a v1 path instead.
    case serverUpdateRequired
    case invalidSubtitleResponse
    case invalidNotificationContinuation
    case incompleteAuthResponse
    case incompleteRequestList
    case missingCollectionVersion
    /// A conditional resource read answered without a usable strong `ETag`.
    case missingEntityTag
    case incompleteCollection
    case invalidCatalogQuery
    case invalidCatalogContinuation
    case invalidPersonalListQuery
    case invalidPersonalListContinuation
    case incompleteCatalogRead
    case unsupportedCatalogReadValue
    /// A settings write answered with a row other than the one it addressed.
    /// The server did something, but not provably what was asked.
    case unexpectedSettingReceipt
    /// The server answered with an `application/problem+json` document.
    case problem(APIv2Problem)
    /// A non-2xx status whose body was not a problem document.
    case httpStatus(Int)

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
        case .unexpectedSettingReceipt:
            return "The server's reply to a settings change did not match the change."
        case .invalidCatalogQuery:
            return "The catalog query is not valid."
        case .invalidCatalogContinuation:
            return "The catalog page could not be continued. Reload to start again."
        case .incompleteCollection:
            return "The collection could not be loaded completely. Reload to try again."
        case .missingCollectionVersion:
            return "The server did not provide a collection version. Reload before editing."
        case .missingEntityTag:
            return "The server did not provide a version tag. Reload before saving."
        case .incompleteRequestList:
            return "The request list could not be loaded completely. Please reload."
        case .serverUpdateRequired:
            return UpdateRequirement.serverMessage
        case .problem(let problem):
            if UpdateRequirement.isClientUpgradeRequired(problem) { return UpdateRequirement.appMessage }
            return problem.detail.isEmpty ? problem.title : problem.detail
        case .httpStatus(let status):
            return "The server returned HTTP \(status)."
        }
    }
}

/// The v2 operations. Every path here is `/api/v2`; nothing in this file may
/// name a v1 path, and a failed v2 call is never replayed against another API
/// major.
///
/// Ownership fences (`docs/native-api-v2.md`): every method that acts for a
/// captured owner refuses to start when that owner is no longer current, and
/// discards the response when the owner changed while the request was in
/// flight. The leading check lives in the method's validation guard so the
/// refusal happens before any path is built; the awaited request itself runs
/// inside `TokenStore.withOwnerFence`, which re-checks the same owner before
/// and after the await and throws `HTTPError.authorityChanged` on a mismatch.
/// `HTTPClient` performs one more pre-dispatch check against `expectedAuth`
/// immediately before the bytes leave the device.
struct APIv2Client: Sendable {
    // Internal, not private, so the per-domain `APIv2Client+<Domain>.swift`
    // extensions build on the same transport, fences and error mapping.
    let http: HTTPClient
    let tokenStore: TokenStore
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
    /// update-required. The candidate's own contract probe, which the caller
    /// runs first and which throws on `.updateServer`, is the gate for
    /// explicit-URL operations.
    func setupStatus(serverURL: String) async throws -> APIv2SetupStatus {
        try await mapErrors {
            try await http.getUnauthenticated(serverURL: serverURL, path: "/api/v2/system/setup")
        }
    }

    // MARK: getCurrentUser (authenticated)

    func currentUser() async throws -> APIv2Account {
        try await gate()
        guard let captured = await tokenStore.captureOrdinaryRequestAuth() else { throw HTTPError.requestIdentityChanged }
        let value: APIv2Account = try await tokenStore.withOwnerFence(captured) {
            try await mapErrors { try await http.get("/api/v2/account/me") }
        }
        // The binding needs the credentials that are current now (a shared
        // refresh may have rotated the access token during the read), so it
        // re-captures through the comparator instead of reusing `captured`.
        guard let current = await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: captured) else {
            throw HTTPError.authorityChanged
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
        let identity = auth.profileId.map { Self.requestIdentity(auth, profile: $0) }
        let response = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: "/api/v2/user/libraries",
                    headers: auth.profileId == nil ? ["X-Profile-Id": ""] : [:],
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: response.url)
            .decode(APIv2CatalogReadCollection<APIv2UserLibrary>.self, from: response.data).completeItems()
    }

    // MARK: listProgress (profile_scoped)

    func listProgress(
        status: APIv2ProgressStatus? = nil,
        libraryId: String? = nil,
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> APIv2ProgressPage {
        var query: [String: String] = [:]
        if let status { query["status"] = status.wireValue }
        if let libraryId { query["library_id"] = libraryId }
        if let limit { query["limit"] = String(limit) }
        if let cursor { query["cursor"] = cursor }
        return try await requestGet("/api/v2/progress", query: query)
    }

    // MARK: updateProfile (profile_scoped, no profile header required)

    /// Updates the profile the captured owner currently has selected. The
    /// owner is captured here and the request is bound to it, so a profile or
    /// account switch during the call refuses the patch instead of applying
    /// it under the replacement.
    func updateProfile(id: String, patch: APIv2ProfilePatch) async throws -> APIv2Profile {
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else { throw HTTPError.requestIdentityChanged }
        return try await updateProfile(id: id, patch: patch, auth: auth)
    }

    /// Onboarding may update only the profile that owned the displayed flow.
    func updateProfile(id: String, patch: APIv2ProfilePatch,
                       auth: CapturedOrdinaryRequestAuth) async throws -> APIv2Profile {
        try await gate()
        guard id == auth.profileId,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(patch)
        let path = "/api/v2/profiles/\(try catalogPathSegment(id))"
        let identity = Self.requestIdentity(auth, profile: id)
        let response = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "PATCH", path: path, body: body,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        let profile = try HTTPClient.makeJSONDecoder(artworkServerURL: response.url).decode(APIv2Profile.self, from: response.data)
        guard profile.id == id else { throw APIv2Error.incompleteCatalogRead }
        return profile
    }

    // MARK: Requests

    /// A read bound to the owner current at capture: the response is
    /// discarded if the account, credential owner, or profile changed while
    /// the request was in flight.
    func requestGet<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else { throw HTTPError.requestIdentityChanged }
        let identity = auth.profileId.map { Self.requestIdentity(auth, profile: $0) }
        let response = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: path, query: query,
                    headers: auth.profileId == nil ? ["X-Profile-Id": ""] : [:],
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: response.url).decode(T.self, from: response.data)
    }

    /// Create and cancel are never replayed after an ambiguous transport
    /// failure, and, like every other v2 mutation, dispatch only under the
    /// owner captured here.
    func requestPost<T: Decodable, B: Encodable>(_ path: String, body: B, timeout: HTTPTimeout = .standard) async throws -> T {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else { throw HTTPError.requestIdentityChanged }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(body)
        let identity = auth.profileId.map { Self.requestIdentity(auth, profile: $0) }
        let response = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "POST", path: path, body: data,
                    headers: auth.profileId == nil ? ["X-Profile-Id": ""] : [:], timeout: timeout,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        guard (200..<300).contains(response.statusCode) else { throw APIv2Error.httpStatus(response.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: response.url).decode(T.self, from: response.data)
    }

    func settingsRead(_ path: String, query: [URLQueryItem] = [], profileID: String? = nil,
                      expectedIdentity: HTTPRequestIdentity? = nil, profileRequired: Bool = false) async throws -> Data {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else { throw HTTPError.requestIdentityChanged }
        if profileRequired && auth.profileId == nil { throw SettingsAPIError.profileRequired }
        if let profileID, profileID != auth.profileId { throw HTTPError.requestIdentityChanged }
        let identity = auth.profileId.map { Self.requestIdentity(auth, profile: $0) }
        try Self.requireSettingsIdentity(expectedIdentity, matches: identity)
        let response = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: path, repeatedQuery: query,
                    headers: auth.profileId == nil ? ["X-Profile-Id": ""] : [:],
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        guard response.statusCode == 200 else { throw APIv2Error.incompleteCatalogRead }
        return response.data
    }

    /// The settings value writes (`APIv2Client+Settings.swift`), under the same
    /// owner rules as `settingsRead`. `profileID` must be the profile the
    /// captured session has selected: the household-parent `profile_id` query
    /// override is never sent, so a write captured for one profile cannot land
    /// on another. The status and receipt checks belong to each operation.
    func settingsWrite(_ method: String, path: String, query: [String: String], body: Data?,
                       profileID: String, expectedIdentity: HTTPRequestIdentity? = nil,
                       quietStatuses: Set<Int> = []) async throws -> HTTPRawResponse {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else { throw HTTPError.requestIdentityChanged }
        guard let profile = auth.profileId else { throw SettingsAPIError.profileRequired }
        guard profile == profileID else { throw HTTPError.requestIdentityChanged }
        let identity = Self.requestIdentity(auth, profile: profile)
        try Self.requireSettingsIdentity(expectedIdentity, matches: identity)
        return try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: method, path: path, query: query, body: body,
                    quietStatuses: quietStatuses, requestIdentity: identity,
                    expectedAccount: auth.account, expectedAuth: auth)
            }
        }
    }

    /// Refuses a settings request whose caller pinned an identity that is no
    /// longer the captured one. The captured account URL is normalized; a
    /// caller's identity may carry the registry spelling, which HTTPClient
    /// normalizes the same way.
    private static func requireSettingsIdentity(_ expected: HTTPRequestIdentity?,
                                                matches identity: HTTPRequestIdentity?) throws {
        guard let expected else { return }
        let normalizedExpected = HTTPRequestIdentity(
            serverId: expected.serverId,
            serverURL: ServerRegistry.normalize(url: expected.serverURL),
            profileId: expected.profileId,
            clientFamily: expected.clientFamily
        )
        if normalizedExpected != identity { throw HTTPError.requestIdentityChanged }
    }

    func metadataAIStatus() async throws -> MetadataAIStatus {
        let data = try await settingsRead("/api/v2/capabilities/metadata-ai", profileRequired: true)
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2MetadataAICapability.self, from: data)
        guard !wire.revision.isEmpty else { throw APIv2Error.incompleteCatalogRead }
        return wire.playerValue
    }

    /// `updateAudioPreference` / `updateSubtitlePreference`: replaces the
    /// acting profile's remembered track for one series (or movie) id. The
    /// operation is `natural_idempotent` and answers 204; the body schema is
    /// closed, so `body` encodes snake_case with nil members omitted.
    func writeTrackPreference<Body: Encodable>(kind: TrackPreferenceKind, seriesId: String, body: Body,
                                              auth: CapturedOrdinaryRequestAuth) async throws {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try await mutateTrackPreference(kind: kind, seriesId: seriesId, method: "PUT",
                                        body: encoder.encode(body), auth: auth)
    }

    /// `deleteAudioPreference` / `deleteSubtitlePreference`. The server
    /// answers 204 whether or not a preference existed.
    func deleteTrackPreference(kind: TrackPreferenceKind, seriesId: String,
                               auth: CapturedOrdinaryRequestAuth) async throws {
        try await mutateTrackPreference(kind: kind, seriesId: seriesId, method: "DELETE", body: nil, auth: auth)
    }

    private func mutateTrackPreference(kind: TrackPreferenceKind, seriesId: String, method: String, body: Data?,
                                       auth: CapturedOrdinaryRequestAuth) async throws {
        try await gate()
        guard !seriesId.isEmpty,
              let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        let segment = try catalogPathSegment(seriesId)
        let identity = Self.requestIdentity(auth, profile: profile)
        let response = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: method, path: "/api/v2/\(kind.rawValue)-prefs/\(segment)",
                    body: body, requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        guard response.statusCode == 204 else { throw APIv2Error.httpStatus(response.statusCode) }
    }

    /// Whether `auth` still describes the current owner. Goes through the one
    /// comparator; callers scheduling AI work check this before dispatch.
    func matchesAIAuthority(_ auth: CapturedOrdinaryRequestAuth) async -> Bool {
        await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
    }

    func translateDescription(contentID: String, language: String, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2MetadataTranslationJob {
        try await gate()
        guard let profile = auth.profileId, await matchesAIAuthority(auth), !contentID.isEmpty,
              !language.isEmpty else {
            throw HTTPError.requestIdentityChanged
        }
        let segment = try catalogPathSegment(contentID)
        let identity = Self.requestIdentity(auth, profile: profile)
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(TranslateDescriptionBody(targetLanguage: language))
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "POST", path: "/api/v2/catalog/items/\(segment)/translate-description",
                    body: body, requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
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
        try await gate()
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = auth.profileId.map { Self.requestIdentity(auth, profile: $0) }
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(body)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "POST", path: "/api/v2/subtitles/ai/translate", body: data,
                    headers: auth.profileId == nil ? ["X-Profile-Id": ""] : [:],
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        guard raw.statusCode == 202 else { throw APIv2Error.invalidSubtitleResponse }
        let response = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleCreateResponse.self, from: raw.data)
        guard !response.job.id.isEmpty,
              response.job.mediaFileId == body.mediaFileId, response.job.kind == body.kind.rawValue,
              response.job.sourceIndex == body.sourceIndex,
              !response.liveDeliveryAttached || body.sessionId != nil else { throw APIv2Error.invalidSubtitleResponse }
        return try SubtitleCreationResult(job: SubtitleJob(v2: response.job, expectedJobID: response.job.id),
            liveDeliveryAttached: response.liveDeliveryAttached)
    }

    /// Acknowledges a cancellation request; completion may already have won.
    func cancelSubtitleJob(id: String) async throws {
        guard let segment = try? catalogPathSegment(id) else {
            throw APIv2Error.invalidSubtitleResponse
        }
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = auth.profileId.map { Self.requestIdentity(auth, profile: $0) }
        let response = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "POST", path: "/api/v2/subtitles/ai/jobs/\(segment)/cancel",
                    headers: auth.profileId == nil ? ["X-Profile-Id": ""] : [:],
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        guard response.statusCode == 204, response.data.isEmpty else { throw APIv2Error.invalidSubtitleResponse }
    }

    /// Provider download has no durable replay receipt, including after a 401.
    func downloadSubtitle(_ body: SubtitleDownloadBody, expectedAuth: CapturedOrdinaryRequestAuth? = nil) async throws -> DownloadedSubtitle {
        try await gate()
        guard body.mediaFileId > 0, let auth = await tokenStore.captureOrdinaryRequestAuth(),
              let profile = auth.profileId else { throw HTTPError.requestIdentityChanged }
        if let expectedAuth, !auth.sameCredentialIdentity(as: expectedAuth) {
            throw HTTPError.requestIdentityChanged
        }
        let identity = Self.requestIdentity(auth, profile: profile)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(APIv2SubtitleDownloadBody(body))
        let response = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "POST", path: "/api/v2/subtitles/download", body: data,
                    timeout: .extended, requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        guard response.statusCode == 200 else { throw APIv2Error.invalidSubtitleResponse }
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2SubtitleDownloadResponse.self, from: response.data)
        return try wire.subtitle.playerValue(mediaFileID: body.mediaFileId)
    }

    private func householdRequest<T: Decodable>(_ method: String, path: String, body: Data? = nil, status: Int) async throws -> T {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else { throw HTTPError.requestIdentityChanged }
        let identity = auth.profileId.map { Self.requestIdentity(auth, profile: $0) }
        let response = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: method, path: path, body: body,
                    headers: auth.profileId == nil ? ["X-Profile-Id": ""] : [:],
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        guard response.statusCode == status else { throw APIv2Error.httpStatus(response.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: response.url).decode(T.self, from: response.data)
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
        let segment = try catalogPathSegment(id)
        let data = try JSONEncoder().encode(VerifyPinRequest(pin: pin))
        return try await householdRequest("POST", path: "/api/v2/profiles/\(segment)/verify-pin", body: data, status: 200)
    }

    /// `getOnboardingState`, then `getOnboardingFlow` when `surface` is set,
    /// both under one captured owner. The state's strong `ETag` is the only
    /// validator a later `onboardingWrite` may send.
    func onboardingRead(surface: String? = nil) async throws -> APIv2OnboardingSession {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth(), let profile = auth.profileId else { throw HTTPError.requestIdentityChanged }
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: "/api/v2/onboarding/state",
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let state = try HTTPClient.makeJSONDecoder().decode(OnboardingState.self, from: raw.data)
        let tag = try Self.entityTag(raw.header("ETag"))
        var flow: OnboardingFlow?
        if let surface {
            let response = try await tokenStore.withOwnerFence(auth) {
                try await mapErrors {
                    try await http.requestData(method: "GET", path: "/api/v2/onboarding/flow", query: ["surface": surface],
                        requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
                }
            }
            guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
            flow = try HTTPClient.makeJSONDecoder().decode(OnboardingFlow.self, from: response.data)
            guard flow?.tourId == state.tourId else { throw OnboardingProgressError.tourChanged }
        }
        return APIv2OnboardingSession(auth: auth, tag: tag, state: state, flow: flow)
    }

    /// `updateOnboardingProgress` under the session's owner and tag. The
    /// operation is `non_retryable`: it is dispatched once, and a 412 (stale
    /// tag), 428, 409 (tour no longer current) or lost response is never
    /// re-sent here. The caller must read the state again before its next
    /// write, and must replace its session with the one returned.
    func onboardingWrite(_ body: OnboardingProgressRequest,
                         session: APIv2OnboardingSession) async throws -> APIv2OnboardingSession {
        try await gate()
        let auth = session.auth
        guard body.tourId == session.state.tourId,
              let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = Self.requestIdentity(auth, profile: profile)
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(body)
        let tag = session.tag
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "PUT", path: "/api/v2/onboarding/progress", body: data,
                    headers: ["If-Match": tag], requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let state = try HTTPClient.makeJSONDecoder().decode(OnboardingState.self, from: raw.data)
        // A receipt for another tour, or a finished write that did not finish
        // the tour, is not proof the requested change was applied.
        guard state.tourId == body.tourId,
              !(body.completed || body.skipped) || state.done else {
            throw OnboardingProgressError.unexpectedReceipt
        }
        return APIv2OnboardingSession(auth: auth,
            tag: try Self.entityTag(raw.header("ETag")), state: state, flow: session.flow)
    }

    func myRequests() async throws -> [MediaRequest] {
        guard let auth = await tokenStore.captureOrdinaryRequestAuth(),
              let profile = auth.profileId else { throw HTTPError.requestIdentityChanged }
        let identity = Self.requestIdentity(auth, profile: profile)
        var records: [MediaRequest] = []
        var cursor: String?
        var seen: Set<String> = []
        for _ in 0..<100 {
            try await gate()
            var query = ["limit": "50"]
            if let cursor { query["cursor"] = cursor }
            let requestQuery = query
            let raw = try await tokenStore.withOwnerFence(auth) {
                try await mapErrors {
                    try await http.requestData(method: "GET", path: "/api/v2/requests/mine",
                        query: requestQuery, requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
                }
            }
            guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
            let response = try HTTPClient.makeJSONDecoder().decode(APIv2RequestsPage.self, from: raw.data)
            records.append(contentsOf: response.items)
            if !response.page.hasMore { return records }
            guard let next = response.page.nextCursor, !next.isEmpty, seen.insert(next).inserted else {
                throw APIv2Error.incompleteRequestList
            }
            cursor = next
        }
        throw APIv2Error.incompleteRequestList
    }

    // MARK: Collection editors

    func collectionEditor<T: Decodable>(_ path: String) async throws -> CollectionEditor<T> {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth(), let profile = auth.profileId else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: path, requestIdentity: identity,
                    expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        guard let tag = raw.headers["etag"], !tag.isEmpty else { throw APIv2Error.missingCollectionVersion }
        return CollectionEditor(value: try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(T.self, from: raw.data),
            version: CollectionEditVersion(path: path, etag: tag, identity: identity, account: auth.account, auth: auth))
    }

    func mutateCollection<T: Decodable, B: Encodable>(method: String, version: CollectionEditVersion,
                                                     body: B) async throws -> T {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let raw = try await collectionMutation(method: method, version: version, body: encoder.encode(body))
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(T.self, from: raw.data)
    }

    func deleteCollection(version: CollectionEditVersion) async throws {
        let raw = try await collectionMutation(method: "DELETE", version: version, body: nil)
        guard raw.statusCode == 204 else { throw APIv2Error.httpStatus(raw.statusCode) }
    }

    private func collectionMutation(method: String, version: CollectionEditVersion, body: Data?) async throws -> HTTPRawResponse {
        try await gate()
        let auth = version.auth
        guard auth.account == version.account, auth.profileId == version.identity.profileId,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        return try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: method, path: version.path, body: body,
                    headers: ["If-Match": version.etag], requestIdentity: version.identity,
                    expectedAccount: version.account, expectedAuth: auth)
            }
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
        let identity = Self.requestIdentity(auth, profile: profile)
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
        let method = operation == .get ? "GET" : "POST"
        let path = operation == .get ? "/api/v2/catalog" : "/api/v2/catalog/query"
        let requestQuery = parameters
        let requestBody = body
        let response = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: method, path: path, query: requestQuery, body: requestBody,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        // The continuation below is handed back to the caller; check the owner
        // once more immediately before minting it.
        guard await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.authorityChanged
        }
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        let page = try HTTPClient.makeJSONDecoder(artworkServerURL: response.url).decode(APIv2CatalogPage.self, from: response.data)
        var continuation: APIv2CatalogContinuation?
        if page.page.hasMore {
            guard let next = page.page.nextCursor, !next.isEmpty, !seen.contains(next) else {
                throw APIv2Error.invalidCatalogContinuation
            }
            continuation = APIv2CatalogContinuation(query: query, operation: operation, cursor: next,
                seen: seen.union([next]), identity: identity, auth: auth)
        } else if let next = page.page.nextCursor, !next.isEmpty {
            throw APIv2Error.invalidCatalogContinuation
        }
        return APIv2CatalogResult(auth: auth, value: page, continuation: continuation)
    }

    /// Facets depend on the viewer's library access, so the read is bound to
    /// the caller's captured owner like the other catalog reads.
    func catalogFilters(libraryId: String?, includeTechnical: Bool = true,
                        auth: CapturedOrdinaryRequestAuth) async throws -> APIv2CatalogFilters {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        var query: [String: String] = [:]
        if let libraryId { query["library_id"] = libraryId }
        if !includeTechnical { query["skip_technical"] = "true" }
        let requestQuery = query
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: "/api/v2/catalog/filters", query: requestQuery,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try HTTPClient.makeJSONDecoder().decode(APIv2CatalogFilters.self, from: raw.data)
    }

    func catalogSearchCapabilities(auth suppliedAuth: CapturedOrdinaryRequestAuth? = nil) async throws -> APIv2CatalogSearchCapabilities {
        try await gate()
        let captured = await tokenStore.captureOrdinaryRequestAuth()
        guard let auth = suppliedAuth ?? captured, let profile = auth.profileId else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: "/api/v2/catalog/search/capabilities",
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try HTTPClient.makeJSONDecoder().decode(APIv2CatalogSearchCapabilities.self, from: raw.data)
    }

    func libraryCollectionTab(libraryId: String) async throws -> APIv2LibraryCollectionTab {
        try await requestGet("/api/v2/library/\(try catalogPathSegment(libraryId))/collections")
    }

    // MARK: Membership and personal reads

    /// Membership and watched-state mutations dispatch once, are never
    /// replayed after a refresh, and apply only under the captured owner.
    func setWatchedState(id: String, included: Bool, auth: CapturedOrdinaryRequestAuth) async throws {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: included ? "POST" : "DELETE", path: "/api/v2/watched/\(try catalogPathSegment(id))",
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
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
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: included ? "PUT" : "DELETE", path: "/api/v2/favorites/\(try catalogPathSegment(id))",
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
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
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: included ? "PUT" : "DELETE", path: "/api/v2/watchlist/\(try catalogPathSegment(id))",
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
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
        let identity = Self.requestIdentity(auth, profile: profile)
        let path = "/api/v2/\(watchlist ? "watchlist" : "favorites")/\(try catalogPathSegment(id))"
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: path, quietStatuses: [404],
                    requestIdentity: identity, acceptedStatuses: [404], expectedAccount: auth.account, expectedAuth: auth)
            }
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
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: "/api/v2/recommendations/discover", query: [:],
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let collection = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(APIv2CatalogReadCollection<APIv2DiscoverRow>.self, from: raw.data)
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
        let identity = Self.requestIdentity(auth, profile: profile)
        let path = "/api/v2/home/dismissals/\(surface)/\(try catalogPathSegment(id))"
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "PUT", path: path, body: data,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
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
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: "/api/v2/library/\(id)/sections", query: imageSize.map { ["image_size": $0] } ?? [:],
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        struct Wire: Decodable { let sections: [ResolvedSection] }
        let value = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(Wire.self, from: raw.data)
        guard Set(value.sections.map(\.id)).count == value.sections.count,
              value.sections.allSatisfy({ !$0.id.isEmpty }) else { throw APIv2Error.incompleteCatalogRead }
        return APIv2LibrarySectionsRead(libraryId: id, auth: auth,
            response: SectionsResponse(sections: value.sections))
    }

    func homeSections(imageSize: String?, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2HomeSectionsRead {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: "/api/v2/home/sections", query: imageSize.map { ["image_size": $0] } ?? [:],
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        struct Wire: Decodable { let sections: [ResolvedSection] }
        let value = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(Wire.self, from: raw.data)
        guard Set(value.sections.map(\.id)).count == value.sections.count,
              value.sections.allSatisfy({ !$0.id.isEmpty }) else { throw APIv2Error.incompleteCatalogRead }
        return APIv2HomeSectionsRead(auth: auth, response: SectionsResponse(sections: value.sections))
    }

    func calendar(start: String, end: String, filter: String, timezone: String,
                  auth: CapturedOrdinaryRequestAuth) async throws -> CalendarResponse {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: "/api/v2/calendar", query: ["start": start, "end": end, "filter": filter, "timezone": timezone],
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(CalendarResponse.self, from: raw.data)
    }

    func similarCards(id: String, limit: Int, auth: CapturedOrdinaryRequestAuth) async throws -> [BrowseItem] {
        try await gate()
        guard (1...50).contains(limit), let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = Self.requestIdentity(auth, profile: profile)
        let path = "/api/v2/recommendations/similar/\(try catalogPathSegment(id))"
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: path, query: ["limit": String(limit)],
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let collection = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(APIv2CatalogReadCollection<BrowseItem>.self, from: raw.data)
        let cards = try collection.completeItems()
        guard cards.count <= limit, Set(cards.map(\.contentId)).count == cards.count,
              cards.allSatisfy({ !$0.contentId.isEmpty }) else { throw APIv2Error.incompleteCatalogRead }
        return cards
    }

    // MARK: Catalog detail and hierarchy reads

    func refreshTrailers(id: String, auth: CapturedOrdinaryRequestAuth) async throws -> TrailerRefreshResponse {
        let raw = try await trailerRequest(id: id, refresh: true, auth: auth)
        let response = try HTTPClient.makeJSONDecoder().decode(TrailerRefreshResponse.self, from: raw.data)
        guard (raw.statusCode == 202 && response.status == "queued") ||
              (raw.statusCode == 200 && ["cooldown", "disabled"].contains(response.status)) else {
            throw APIv2Error.incompleteCatalogRead
        }
        return response
    }

    func trailerItem(id: String, libraryId: String? = nil, imageSize: String?, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2CatalogRead.CatalogItemDetail {
        let raw = try await trailerRequest(id: id, refresh: false, libraryId: libraryId, imageSize: imageSize, auth: auth)
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let item = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(APIv2CatalogRead.CatalogItemDetail.self, from: raw.data)
        guard item.contentId == id else { throw APIv2Error.incompleteCatalogRead }
        return item
    }

    private func trailerRequest(id: String, refresh: Bool, libraryId: String? = nil, imageSize: String? = nil,
                                auth: CapturedOrdinaryRequestAuth) async throws -> HTTPRawResponse {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = Self.requestIdentity(auth, profile: profile)
        let path = "/api/v2/catalog/items/\(try catalogPathSegment(id))" + (refresh ? "/trailers/refresh" : "")
        let query = refresh ? [:] : catalogReadScope(libraryId: libraryId, imageSize: imageSize)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: refresh ? "POST" : "GET", path: path, query: query,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        return raw
    }

    func catalogItem(id: String, libraryId: String? = nil, imageSize: String?, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2CatalogRead.CatalogItemDetail {
        // Same exact viewer detail read and authority fence used by bounded trailer observation.
        try await trailerItem(id: id, libraryId: libraryId, imageSize: imageSize, auth: auth)
    }

    func catalogItem(id: String, libraryId: String? = nil, fileId: String? = nil,
                     imageSize: String? = nil) async throws -> APIv2CatalogRead.CatalogItemDetail {
        var query = catalogReadScope(libraryId: libraryId, imageSize: imageSize)
        if let fileId { query["file_id"] = fileId }
        return try await catalogRead("/api/v2/catalog/items/\(try catalogPathSegment(id))", query: query)
    }

    func catalogSeasons(seriesId: String, libraryId: String? = nil,
                        imageSize: String? = nil, includeArtwork: Bool? = nil) async throws -> [APIv2CatalogRead.Season] {
        var query = catalogReadScope(libraryId: libraryId, imageSize: imageSize)
        if let includeArtwork { query["include_artwork"] = String(includeArtwork) }
        let response: APIv2CatalogReadCollection<APIv2CatalogRead.Season> = try await catalogRead(
            "/api/v2/catalog/series/\(try catalogPathSegment(seriesId))/seasons",
            query: query)
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

    func catalogEpisodes(seriesId: String, seasonNumber: Int, libraryId: String? = nil, imageSize: String?,
                         auth: CapturedOrdinaryRequestAuth) async throws -> [APIv2CatalogRead.Episode] {
        try await gate()
        guard seasonNumber >= 0 else { throw APIv2Error.invalidCatalogQuery }
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = Self.requestIdentity(auth, profile: profile)
        let path = "/api/v2/catalog/series/\(try catalogPathSegment(seriesId))/seasons/\(seasonNumber)/episodes"
        let query = catalogReadScope(libraryId: libraryId, imageSize: imageSize)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: path, query: query,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let response = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(APIv2CatalogReadCollection<APIv2CatalogRead.Episode>.self, from: raw.data)
        return try response.completeItems()
    }

    func catalogSeasons(seriesId: String, libraryId: String? = nil, imageSize: String?, includeArtwork: Bool? = nil,
                         auth: CapturedOrdinaryRequestAuth) async throws -> [APIv2CatalogRead.Season] {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = Self.requestIdentity(auth, profile: profile)
        let path = "/api/v2/catalog/series/\(try catalogPathSegment(seriesId))/seasons"
        var query = catalogReadScope(libraryId: libraryId, imageSize: imageSize)
        if let includeArtwork { query["include_artwork"] = String(includeArtwork) }
        let requestQuery = query
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: path, query: requestQuery,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let response = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(APIv2CatalogReadCollection<APIv2CatalogRead.Season>.self, from: raw.data)
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
        let person = try HTTPClient.makeJSONDecoder(artworkServerURL: response.url).decode(APIv2CatalogRead.Person.self, from: response.data)
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
        let identity = Self.requestIdentity(auth, profile: profile)
        let suffix = method == "POST" ? "/refresh" : ""
        let response = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: method, path: "/api/v2/catalog/people/\(id)\(suffix)",
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        return response
    }

    func catalogPerson(id: String) async throws -> APIv2CatalogRead.Person {
        try await catalogRead("/api/v2/catalog/people/\(try catalogPathSegment(id))")
    }

    private func catalogReadScope(libraryId: String?, imageSize: String?) -> [String: String] {
        var query: [String: String] = [:]
        if let libraryId { query["library_id"] = libraryId }
        if let imageSize { query["image_size"] = imageSize }
        return query
    }

    /// Every path-building site percent-encodes through here. `/`, `?`, `#`
    /// and `%` are never allowed through unencoded, and `.`/`..` never become
    /// a segment.
    private func catalogPathSegment(_ value: String) throws -> String {
        guard let escaped = CatalogPathSegment.encode(value) else {
            throw APIv2Error.invalidCatalogQuery
        }
        return escaped
    }

    private func catalogRead<Value: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> Value {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth(), let profile = auth.profileId else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = Self.requestIdentity(auth, profile: profile)
        let response = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: path, query: query, requestIdentity: identity,
                    expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: response.url).decode(Value.self, from: response.data)
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
        let identity = Self.requestIdentity(auth, profile: profile)
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
        let path = "/api/v2/\(kind.rawValue)"
        let requestQuery = query
        let response = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: path, query: requestQuery, requestIdentity: identity,
                    expectedAccount: account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        let page = try HTTPClient.makeJSONDecoder(artworkServerURL: response.url).decode(APIv2PersonalListPage.self, from: response.data)
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

    // MARK: Active account/device authentication

    /// `login` is `non_retryable` and public: one dispatch with no bearer, and
    /// a 401 is the wrong-credentials answer, never a refresh trigger.
    func login(username: String, password: String, expectedAccount: RefreshAccountIdentity) async throws -> APIv2LoginTokens {
        try await gate()
        let body = try JSONEncoder().encode(LoginRequest(username: username, password: password))
        let response = try await mapErrors {
            try await http.requestData(method: "POST", path: "/api/v2/auth/login", body: body, expectedAccount: expectedAccount)
        }
        guard await tokenStore.refreshAccountIdentity() == expectedAccount else { throw HTTPError.requestIdentityChanged }
        guard response.statusCode == 200 else { throw APIv2Error.incompleteAuthResponse }
        let value = try HTTPClient.makeJSONDecoder().decode(APIv2LoginTokens.self, from: response.data)
        guard !value.accessToken.isEmpty, !value.refreshToken.isEmpty,
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

    /// The validated wire poll. Tokens are present only on the first
    /// `approved` answer; the caller installs them from this value.
    func pollDeviceLogin(deviceCode: String, expectedAccount: RefreshAccountIdentity) async throws -> APIv2DevicePoll {
        try await gate()
        let body = try JSONSerialization.data(withJSONObject: ["device_code": deviceCode])
        let response = try await mapErrors {
            try await http.requestData(method: "POST", path: "/api/v2/auth/device/poll", body: body, expectedAccount: expectedAccount)
        }
        guard await tokenStore.refreshAccountIdentity() == expectedAccount else { throw HTTPError.requestIdentityChanged }
        guard response.statusCode == 200 else { throw APIv2Error.incompleteAuthResponse }
        return try HTTPClient.makeJSONDecoder().decode(APIv2DevicePoll.self, from: response.data).validated()
    }

    /// The approving side of a SiloRemote handoff reads and decides under
    /// the caller's captured owner: `expectedAuth`, when given, refuses the
    /// dispatch once the credential or profile behind it has changed.
    func deviceLookup(code: String, identity: HTTPRequestIdentity, expectedAccount: RefreshAccountIdentity,
                      expectedAuth: CapturedOrdinaryRequestAuth? = nil) async throws -> DeviceLookupResponse {
        try await gate()
        let response = try await mapErrors {
            try await http.requestData(method: "GET", path: "/api/v2/auth/device", query: ["code": code], requestIdentity: identity,
                expectedAccount: expectedAccount, expectedAuth: expectedAuth)
        }
        guard await tokenStore.refreshAccountIdentity() == expectedAccount else { throw HTTPError.requestIdentityChanged }
        guard response.statusCode == 200 else { throw APIv2Error.incompleteAuthResponse }
        return try HTTPClient.makeJSONDecoder().decode(APIv2DeviceLookup.self, from: response.data).presentation
    }

    /// `approve-handoff` and `deny` are `domain_identity`: the code names the
    /// request, so the usual refresh and resend is safe.
    func decideDeviceLogin(code: String, approveHandoff: Bool, identity: HTTPRequestIdentity, expectedAccount: RefreshAccountIdentity,
                           expectedAuth: CapturedOrdinaryRequestAuth? = nil) async throws {
        try await gate()
        let body = try JSONSerialization.data(withJSONObject: ["code": code])
        let path = approveHandoff ? "/api/v2/auth/device/approve-handoff" : "/api/v2/auth/device/deny"
        let response = try await mapErrors {
            try await http.requestData(method: "POST", path: path, body: body, requestIdentity: identity,
                expectedAccount: expectedAccount, expectedAuth: expectedAuth)
        }
        guard await tokenStore.refreshAccountIdentity() == expectedAccount else { throw HTTPError.requestIdentityChanged }
        guard response.statusCode == 200 else { throw APIv2Error.incompleteAuthResponse }
        let value = try HTTPClient.makeJSONDecoder().decode(APIv2DeviceDecision.self, from: response.data)
        guard value.status == (approveHandoff ? "approved" : "denied") else { throw APIv2Error.incompleteAuthResponse }
    }

    /// Ends the login session that `expectedAccount` currently holds. The
    /// request carries the bearer only: v2 logout does not accept
    /// `X-Profile-Id`, so a temporary scope's profile proof is left off too.
    /// `natural_idempotent`, so the usual 401 refresh and resend is safe.
    func logout(expectedAccount: RefreshAccountIdentity) async throws {
        try await gate()
        let response = try await mapErrors {
            try await http.requestData(method: "POST", path: "/api/v2/auth/logout",
                expectedAccount: expectedAccount, sendsProfile: false)
        }
        guard response.statusCode == 204 else { throw APIv2Error.incompleteAuthResponse }
    }

    // MARK: Initial playback

    /// One playback request under a captured owner. Fenced before and after
    /// the await; callers check the status they expect.
    func playbackRequest(method: String, suffix: String, body: Data? = nil,
                         auth: CapturedOrdinaryRequestAuth, query: [String: String] = [:],
                         timeout: HTTPTimeout = .standard) async throws -> HTTPRawResponse {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty else { throw HTTPError.requestIdentityChanged }
        let identity = Self.requestIdentity(auth, profile: profile)
        return try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: method, path: "/api/v2/playback" + suffix, query: query, body: body,
                    timeout: timeout, requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
    }

    func playbackControlRequest(sessionID: String, installationID: String,
                                auth: CapturedOrdinaryRequestAuth) async throws -> URLRequest {
        guard UUID(uuidString: sessionID) != nil else { throw PlaybackSequencedError.invalidSession }
        let capabilityRaw = try await playbackRequest(method: "GET", suffix: "/sessions/control/capabilities", auth: auth)
        guard capabilityRaw.statusCode == 200 else { throw PlaybackSequencedError.invalidResponse }
        let capability = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackControlCapabilities.self, from: capabilityRaw.data)
        guard capability.servesControlHandshake else { throw PlaybackSequencedError.invalidResponse }
        struct Body: Encodable { let installationId: String }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let raw = try await playbackRequest(method: "POST", suffix: "/sessions/\(sessionID)/control/ws-ticket",
            body: encoder.encode(Body(installationId: installationID)), auth: auth)
        // The ticket is a delegated credential; it is handed out only to the
        // owner that is still current after both requests.
        guard raw.statusCode == 200,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw PlaybackSequencedError.authorityChanged
        }
        let ticket = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackControlTicket.self, from: raw.data)
        return try ticket.request(serverURL: auth.account.serverURL, sessionID: sessionID)
    }

    func watchDetail(id: String, libraryId: String? = nil, imageSize: String?, auth: CapturedOrdinaryRequestAuth) async throws -> WatchDetail {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = Self.requestIdentity(auth, profile: profile)
        let path = "/api/v2/watch/\(try catalogPathSegment(id))"
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: path, query: catalogReadScope(libraryId: libraryId, imageSize: imageSize),
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try WatchDetail(v2: HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(APIv2CatalogRead.WatchDetail.self, from: raw.data))
    }

    func playbackCapabilities(auth: CapturedOrdinaryRequestAuth) async throws -> APIv2PlaybackCapabilities {
        let raw = try await playbackRequest(method: "GET", suffix: "/capabilities", auth: auth)
        guard raw.statusCode == 200 else { throw PlaybackSequencedError.invalidResponse }
        return try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackCapabilities.self, from: raw.data)
    }

    #if os(iOS)
    func notificationSync(cursor: String?, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2NotificationSyncPage {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = Self.requestIdentity(auth, profile: profile)
        var query = ["limit": String(APIv2NotificationSyncPage.defaultLimit)]
        if let cursor, !cursor.isEmpty { query["cursor"] = cursor }
        let requestQuery = query
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: "/api/v2/notifications/sync", query: requestQuery,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let page = try HTTPClient.makeJSONDecoder().decode(APIv2NotificationSyncPage.self, from: raw.data)
        guard !page.syncCursor.isEmpty, page.unreadCount >= 0,
              page.items.count <= APIv2NotificationSyncPage.defaultLimit,
              page.items.allSatisfy({ !$0.id.isEmpty && $0.profileId == profile }),
              Set(page.items.map(\.id)).count == page.items.count,
              page.initialSnapshot == (cursor == nil),
              page.page.hasMore ? (page.page.nextCursor == page.syncCursor && page.syncCursor != cursor && !page.items.isEmpty) : page.page.nextCursor == nil else {
            throw APIv2Error.invalidNotificationContinuation
        }
        return page
    }

    struct ApplePushCapability: Decodable {
        let revision: String
        let registrationAvailable: Bool
    }

    func applePushRegistrationCapability(auth: CapturedOrdinaryRequestAuth) async throws -> ApplePushCapability {
        let data = try await applePushRequest(method: "GET", path: "/api/v2/devices/push/apple/capabilities", auth: auth)
        return try HTTPClient.makeJSONDecoder().decode(ApplePushCapability.self, from: data)
    }

    /// `installationKey` and `generation` are the ordered-intent headers the
    /// server uses to discard a stale registration; the caller's journal owns
    /// their sequence.
    func registerApplePush(_ body: ApplePushRegistrationRequest, installationKey: String, generation: Int64,
                           auth: CapturedOrdinaryRequestAuth) async throws -> APIv2ApplePushRegistration {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        let data = try await applePushRequest(method: "POST", path: "/api/v2/devices/push/apple",
            body: encoder.encode(body),
            headers: ["X-Push-Installation-Key": installationKey, "X-Push-Generation": String(generation)],
            auth: auth)
        return try HTTPClient.makeJSONDecoder().decode(APIv2ApplePushRegistration.self, from: data)
    }

    private func applePushRequest(method: String, path: String, body: Data? = nil, headers: [String: String] = [:],
                                  auth: CapturedOrdinaryRequestAuth) async throws -> Data {
        try await gate()
        guard case .persistentServer = auth.credentialOwner, let profile = auth.profileId, !profile.isEmpty else {
            throw HTTPError.requestIdentityChanged
        }
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: method, path: path, body: body, headers: headers,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return raw.data
    }
    #endif

    // MARK: Internals

    /// Refuses relative-URL (active-session) operations while the active
    /// server is known to be v1-only. Explicit-URL candidate probes skip this.
    func gate() async throws {
        if await isUpdateRequired() { throw APIv2Error.serverUpdateRequired }
    }

    static func requestIdentity(_ auth: CapturedOrdinaryRequestAuth, profile: String) -> HTTPRequestIdentity {
        HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
    }

    /// A strong entity tag: quoted, non-empty, single line. Anything else is
    /// refused rather than echoed back as an `If-Match` precondition.
    private static func entityTag(_ tag: String?) throws -> String {
        guard let tag, tag.count > 2, tag.first == "\"", tag.last == "\"",
              !tag.contains("\r"), !tag.contains("\n") else { throw APIv2Error.missingEntityTag }
        return tag
    }

    func mapErrors<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch HTTPError.http(let statusCode, let body) {
            if let body, let data = body.data(using: .utf8),
               let problem = try? HTTPClient.makeJSONDecoder().decode(APIv2Problem.self, from: data) {
                throw APIv2Error.problem(problem)
            }
            // Every path here is `/api/v2`, so Go's plain 404 can only come
            // from a v1-only server's legacy listener.
            if statusCode == 404, APIv2Probe.isLegacyNotFound(body: body) {
                throw APIv2Error.serverUpdateRequired
            }
            throw APIv2Error.httpStatus(statusCode)
        }
    }
}
