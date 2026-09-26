import Foundation

/// A v2 request was refused because its owner changed before the request
/// reached the URL session. Nothing was sent.
struct APIv2OwnerChangedBeforeDispatch: LocalizedError, Sendable {
    var errorDescription: String? {
        "The active server or profile changed before the request could start."
    }
}

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
    /// A conditional resource read answered without a usable strong `ETag`.
    case missingEntityTag
    case incompleteCollection
    case invalidCatalogQuery
    case invalidCatalogContinuation
    case invalidPersonalListQuery
    case invalidPersonalListContinuation
    /// A favorites or watchlist read ran past its page budget.
    case incompletePersonalList
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
        case .incompletePersonalList:
            return "The list could not be loaded completely. Reload to try again."
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

/// One owner-bound v2 request, as `APIv2Client.send(_:auth:dispatch:)` hands
/// it to `HTTPClient.requestData`. The owner, its request identity and the
/// pre-dispatch owner guards are added by `send`, never by the caller.
/// Whether a 401 may refresh and re-send the request is decided by
/// `HTTPClient` from `method` and `path` (`APIv2MutationCatalog`), so it is
/// not part of this value.
struct APIv2Request: Sendable {
    let method: String
    let path: String
    var query: [String: String] = [:]
    var repeatedQuery: [URLQueryItem] = []
    var body: Data?
    var contentType = "application/json"
    var headers: [String: String] = [:]
    var quietStatuses: Set<Int> = []
    var acceptedStatuses: Set<Int> = []
    var timeout: HTTPTimeout = .standard
}

/// The v2 operations. Every path here is `/api/v2`; nothing in this file may
/// name a v1 path, and a failed v2 call is never replayed against another API
/// major.
///
/// Ownership fences (`docs/native-api-v2.md`): every method that acts for a
/// captured owner refuses to start when that owner is no longer current, and
/// discards the response when the owner changed while the request was in
/// flight. `send(_:auth:dispatch:)` is the one place such a request reaches
/// `HTTPClient`: it runs inside `TokenStore.withOwnerFence`, which re-checks
/// the owner before and after the await and throws `HTTPError.authorityChanged`
/// on a mismatch, and `HTTPClient` checks `expectedAuth` once more
/// immediately before the bytes leave the device. Most methods reach `send`
/// through `profileRequest`, which runs the gate and the leading owner check
/// first, so the refusal happens before any path is built.
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
        let captured = try await captureRequestOwner()
        // Reads through `http.get`, not `send`: the account read stays on the
        // unscoped request path.
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
        let collection: APIv2CatalogReadCollection<APIv2UserLibrary> = try await requestGet("/api/v2/user/libraries")
        return try collection.completeItems()
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
        // Unlike `profileRequest`, the selected profile only has to be the
        // one addressed.
        guard id == auth.profileId, await isCurrentOwner(auth) else {
            throw HTTPError.requestIdentityChanged
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(patch)
        let path = "/api/v2/profiles/\(try catalogPathSegment(id))"
        let response = try await send(APIv2Request(method: "PATCH", path: path, body: body), auth: auth)
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        let profile = try HTTPClient.makeJSONDecoder(artworkServerURL: response.url).decode(APIv2Profile.self, from: response.data)
        guard profile.id == id else { throw APIv2Error.incompleteCatalogRead }
        return profile
    }

    // MARK: Owner-bound calls

    /// A read bound to the owner current at capture: the response is
    /// discarded if the account, credential owner, or profile changed while
    /// the request was in flight.
    func requestGet<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let auth = try await captureRequestOwner()
        let response = try await send(APIv2Request(method: "GET", path: path, query: query), auth: auth)
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: response.url).decode(T.self, from: response.data)
    }

    func settingsRead(_ path: String, query: [URLQueryItem] = [], profileID: String? = nil,
                      expectedIdentity: HTTPRequestIdentity? = nil, profileRequired: Bool = false) async throws -> Data {
        let auth = try await captureRequestOwner()
        if profileRequired && auth.profileId == nil { throw SettingsAPIError.profileRequired }
        if let profileID, profileID != auth.profileId { throw HTTPError.requestIdentityChanged }
        try Self.requireSettingsIdentity(expectedIdentity,
                                         matches: auth.profileId.map { Self.requestIdentity(auth, profile: $0) })
        let response = try await send(APIv2Request(method: "GET", path: path, repeatedQuery: query), auth: auth)
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
        let auth = try await captureRequestOwner()
        guard let profile = auth.profileId else { throw SettingsAPIError.profileRequired }
        guard profile == profileID else { throw HTTPError.requestIdentityChanged }
        try Self.requireSettingsIdentity(expectedIdentity, matches: Self.requestIdentity(auth, profile: profile))
        return try await send(APIv2Request(method: method, path: path, query: query, body: body,
                                           quietStatuses: quietStatuses), auth: auth)
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
        _ = try await profileRequest(auth: auth, valid: !seriesId.isEmpty, cancellation: .never, status: 204) {
            APIv2Request(method: method, path: "/api/v2/\(kind.rawValue)-prefs/\(try catalogPathSegment(seriesId))",
                         body: body)
        }
    }

    private func householdRequest<T: Decodable>(_ method: String, path: String, body: Data? = nil, status: Int) async throws -> T {
        let auth = try await captureRequestOwner()
        let response = try await send(APIv2Request(method: method, path: path, body: body), auth: auth)
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
        let auth = try await captureRequestOwner()
        guard auth.profileId != nil else { throw HTTPError.requestIdentityChanged }
        let raw = try await send(APIv2Request(method: "GET", path: "/api/v2/onboarding/state"), auth: auth)
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let state = try HTTPClient.makeJSONDecoder().decode(OnboardingState.self, from: raw.data)
        let tag = try Self.entityTag(raw.header("ETag"))
        var flow: OnboardingFlow?
        if let surface {
            let response = try await send(APIv2Request(method: "GET", path: "/api/v2/onboarding/flow",
                                                       query: ["surface": surface]), auth: auth)
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
        let auth = session.auth
        let raw = try await profileRequest(auth: auth, valid: body.tourId == session.state.tourId,
                                           cancellation: .never, status: 200) {
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
            return APIv2Request(method: "PUT", path: "/api/v2/onboarding/progress", body: try encoder.encode(body),
                                headers: ["If-Match": session.tag])
        }
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

    // MARK: Personal collections

    /// One personal-collection request for `auth`'s profile, used by
    /// `APIv2Client+Collections.swift`. `ifMatch` is the strong tag of the
    /// editor read the write is based on. The answer must carry exactly
    /// `status`; anything else throws.
    ///
    /// An owner change is reported by when it was caught (see
    /// `reportingOwnerChangeBeforeDispatch`).
    func collectionRequest(_ method: String, path: String, body: Data? = nil, ifMatch: String? = nil,
                           status: Int, auth: CapturedOrdinaryRequestAuth) async throws -> HTTPRawResponse {
        try await reportingOwnerChangeBeforeDispatch { dispatch in
            try await profileRequest(auth: auth, cancellation: .never, status: status, dispatch: dispatch) {
                APIv2Request(method: method, path: path, body: body, headers: ifMatch.map { ["If-Match": $0] } ?? [:])
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
        guard await isCurrentOwner(auth) else {
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
        // `identity` was minted from `auth` by `catalogPage`; `send` derives
        // the same one.
        let response = try await send(APIv2Request(method: operation == .get ? "GET" : "POST",
            path: operation == .get ? "/api/v2/catalog" : "/api/v2/catalog/query",
            query: parameters, body: body), auth: auth)
        // The continuation below is handed back to the caller; check the owner
        // once more immediately before minting it.
        guard await isCurrentOwner(auth) else {
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
        let raw = try await profileRequest(auth: auth, status: 200) {
            var query: [String: String] = [:]
            if let libraryId { query["library_id"] = libraryId }
            if !includeTechnical { query["skip_technical"] = "true" }
            return APIv2Request(method: "GET", path: "/api/v2/catalog/filters", query: query)
        }
        return try HTTPClient.makeJSONDecoder().decode(APIv2CatalogFilters.self, from: raw.data)
    }

    /// No owner check of its own: the fence's entry check is the first.
    func catalogSearchCapabilities(auth suppliedAuth: CapturedOrdinaryRequestAuth? = nil) async throws -> APIv2CatalogSearchCapabilities {
        try await gate()
        let captured = await tokenStore.captureOrdinaryRequestAuth()
        guard let auth = suppliedAuth ?? captured, auth.profileId != nil else {
            throw HTTPError.requestIdentityChanged
        }
        let raw = try await send(APIv2Request(method: "GET", path: "/api/v2/catalog/search/capabilities"), auth: auth)
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try HTTPClient.makeJSONDecoder().decode(APIv2CatalogSearchCapabilities.self, from: raw.data)
    }

    /// The Collections tab as the captured profile sees it: curated
    /// collections, their groups, and the profile's opted-in personal ones.
    func libraryCollectionTab(libraryId: String, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2LibraryCollectionTab {
        let raw = try await profileRequest(auth: auth, status: 200) {
            APIv2Request(method: "GET", path: "/api/v2/library/\(try catalogPathSegment(libraryId))/collections")
        }
        let tab = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(APIv2LibraryCollectionTab.self, from: raw.data)
        guard tab.libraryId == libraryId else { throw APIv2Error.incompleteCatalogRead }
        return tab
    }

    // MARK: Membership and personal reads

    /// Membership and watched-state mutations dispatch once, are never
    /// replayed after a refresh, and apply only under the captured owner.
    func setWatchedState(id: String, included: Bool, auth: CapturedOrdinaryRequestAuth) async throws {
        try await setMembership("watched", id: id, method: included ? "POST" : "DELETE", auth: auth)
    }

    func setFavoriteMembership(id: String, included: Bool, auth: CapturedOrdinaryRequestAuth) async throws {
        try await setMembership("favorites", id: id, method: included ? "PUT" : "DELETE", auth: auth)
    }

    func setWatchlistMembership(id: String, included: Bool, auth: CapturedOrdinaryRequestAuth) async throws {
        try await setMembership("watchlist", id: id, method: included ? "PUT" : "DELETE", auth: auth)
    }

    private func setMembership(_ list: String, id: String, method: String,
                               auth: CapturedOrdinaryRequestAuth) async throws {
        _ = try await profileRequest(auth: auth, status: 204) {
            APIv2Request(method: method, path: "/api/v2/\(list)/\(try catalogPathSegment(id))")
        }
    }

    /// Membership reads return an entry on 200 and absence on 404, never legacy 204.
    func personalMembership(id: String, watchlist: Bool, auth: CapturedOrdinaryRequestAuth?) async throws -> Bool {
        let raw = try await profileRequest(auth: auth, status: nil) {
            APIv2Request(method: "GET", path: "/api/v2/\(watchlist ? "watchlist" : "favorites")/\(try catalogPathSegment(id))",
                         quietStatuses: [404], acceptedStatuses: [404])
        }
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
        let raw = try await profileRequest(auth: auth, status: 200) {
            APIv2Request(method: "GET", path: "/api/v2/recommendations/discover")
        }
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
        // Refused before the gate, unlike `profileRequest`'s own check.
        guard let auth, auth.profileId?.isEmpty == false else { throw HTTPError.requestIdentityChanged }
        struct Body: Encodable { let progressUpdatedAt: String?; let seriesId: String? }
        _ = try await profileRequest(auth: auth, status: 204) {
            let surface: String
            if let progressUpdatedAt, !progressUpdatedAt.isEmpty { surface = "continue_watching" }
            else if let seriesId, !seriesId.isEmpty { surface = "next_up" }
            else { throw APIv2Error.incompleteCatalogRead }
            // Preserve the observed anchor verbatim. Do not manufacture a timestamp or rebase it.
            let body = Body(progressUpdatedAt: surface == "continue_watching" ? progressUpdatedAt : nil,
                            seriesId: surface == "next_up" ? seriesId : nil)
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
            let data = try encoder.encode(body)
            return APIv2Request(method: "PUT", path: "/api/v2/home/dismissals/\(surface)/\(try catalogPathSegment(id))",
                                body: data)
        }
    }

    func librarySections(id: Int, imageSize: String?, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2LibrarySectionsRead {
        let raw = try await profileRequest(auth: auth, valid: id > 0, status: 200) {
            APIv2Request(method: "GET", path: "/api/v2/library/\(id)/sections",
                         query: imageSize.map { ["image_size": $0] } ?? [:])
        }
        struct Wire: Decodable { let sections: [ResolvedSection] }
        let value = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(Wire.self, from: raw.data)
        guard Set(value.sections.map(\.id)).count == value.sections.count,
              value.sections.allSatisfy({ !$0.id.isEmpty }) else { throw APIv2Error.incompleteCatalogRead }
        return APIv2LibrarySectionsRead(libraryId: id, auth: auth,
            response: SectionsResponse(sections: value.sections))
    }

    func homeSections(imageSize: String?, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2HomeSectionsRead {
        let raw = try await profileRequest(auth: auth, status: 200) {
            APIv2Request(method: "GET", path: "/api/v2/home/sections", query: imageSize.map { ["image_size": $0] } ?? [:])
        }
        struct Wire: Decodable { let sections: [ResolvedSection] }
        let value = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(Wire.self, from: raw.data)
        guard Set(value.sections.map(\.id)).count == value.sections.count,
              value.sections.allSatisfy({ !$0.id.isEmpty }) else { throw APIv2Error.incompleteCatalogRead }
        return APIv2HomeSectionsRead(auth: auth, response: SectionsResponse(sections: value.sections))
    }

    func calendar(start: String, end: String, filter: String, timezone: String,
                  auth: CapturedOrdinaryRequestAuth) async throws -> CalendarResponse {
        let raw = try await profileRequest(auth: auth, status: 200) {
            APIv2Request(method: "GET", path: "/api/v2/calendar",
                         query: ["start": start, "end": end, "filter": filter, "timezone": timezone])
        }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(CalendarResponse.self, from: raw.data)
    }

    func similarCards(id: String, limit: Int, auth: CapturedOrdinaryRequestAuth) async throws -> [BrowseItem] {
        let raw = try await profileRequest(auth: auth, valid: (1...50).contains(limit), status: 200) {
            APIv2Request(method: "GET", path: "/api/v2/recommendations/similar/\(try catalogPathSegment(id))",
                         query: ["limit": String(limit)])
        }
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
        try await profileRequest(auth: auth, status: nil) {
            APIv2Request(method: refresh ? "POST" : "GET",
                         path: "/api/v2/catalog/items/\(try catalogPathSegment(id))" + (refresh ? "/trailers/refresh" : ""),
                         query: refresh ? [:] : catalogReadScope(libraryId: libraryId, imageSize: imageSize))
        }
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
        guard seasonNumber >= 0 else { throw APIv2Error.invalidCatalogQuery }
        let raw = try await profileRequest(auth: auth, status: 200) {
            APIv2Request(method: "GET",
                         path: "/api/v2/catalog/series/\(try catalogPathSegment(seriesId))/seasons/\(seasonNumber)/episodes",
                         query: catalogReadScope(libraryId: libraryId, imageSize: imageSize))
        }
        let response = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(APIv2CatalogReadCollection<APIv2CatalogRead.Episode>.self, from: raw.data)
        return try response.completeItems()
    }

    func catalogSeasons(seriesId: String, libraryId: String? = nil, imageSize: String?, includeArtwork: Bool? = nil,
                         auth: CapturedOrdinaryRequestAuth) async throws -> [APIv2CatalogRead.Season] {
        let raw = try await profileRequest(auth: auth, status: 200) {
            var query = catalogReadScope(libraryId: libraryId, imageSize: imageSize)
            if let includeArtwork { query["include_artwork"] = String(includeArtwork) }
            return APIv2Request(method: "GET", path: "/api/v2/catalog/series/\(try catalogPathSegment(seriesId))/seasons",
                                query: query)
        }
        let response = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(APIv2CatalogReadCollection<APIv2CatalogRead.Season>.self, from: raw.data)
        return try response.completeItems()
    }

    /// `refreshPerson` is `non_retryable`: it is dispatched once and never
    /// replayed after a token refresh. A 202 only means the refresh was queued;
    /// callers observe the result by re-reading the person.
    func refreshPerson(id: String, auth: CapturedOrdinaryRequestAuth) async throws {
        let response = try await personRequest(id: id, method: "POST", auth: auth)
        guard response.statusCode == 202 else { throw APIv2Error.httpStatus(response.statusCode) }
        struct Queued: Decodable { let status: String; let personId: String }
        let wire = try HTTPClient.makeJSONDecoder().decode(Queued.self, from: response.data)
        guard wire.status == "queued", wire.personId == id else { throw APIv2Error.incompleteCatalogRead }
    }

    func catalogPerson(id: String, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2CatalogRead.Person {
        let response = try await personRequest(id: id, method: "GET", auth: auth)
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        let person = try HTTPClient.makeJSONDecoder(artworkServerURL: response.url).decode(APIv2CatalogRead.Person.self, from: response.data)
        guard person.id == id else { throw APIv2Error.incompleteCatalogRead }
        return person
    }

    private func personRequest(id: String, method: String, auth: CapturedOrdinaryRequestAuth) async throws -> HTTPRawResponse {
        let path = "/api/v2/catalog/people/\(try catalogPathSegment(id))" + (method == "POST" ? "/refresh" : "")
        return try await profileRequest(auth: auth, status: nil) { APIv2Request(method: method, path: path) }
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
    func catalogPathSegment(_ value: String) throws -> String {
        guard let escaped = CatalogPathSegment.encode(value) else {
            throw APIv2Error.invalidCatalogQuery
        }
        return escaped
    }

    private func catalogRead<Value: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> Value {
        let auth = try await captureRequestOwner()
        guard auth.profileId != nil else { throw HTTPError.requestIdentityChanged }
        let response = try await send(APIv2Request(method: "GET", path: path, query: query), auth: auth)
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
              await isCurrentOwner(auth) else { throw HTTPError.requestIdentityChanged }
        try Task.checkCancellation()
        var query = ["limit": String(limit)]
        if let imageSize { query["image_size"] = imageSize }
        if let cursor { query["cursor"] = cursor }
        // `identity` was minted from `auth` by `personalList`, and the guard
        // ties `account` to it; `send` derives the same identity.
        let response = try await send(APIv2Request(method: "GET", path: "/api/v2/\(kind.rawValue)", query: query),
                                      auth: auth)
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
    /// the await (no owner check of its own: the fence's entry check is the
    /// first); callers check the status they expect.
    func playbackRequest(method: String, suffix: String, body: Data? = nil,
                         auth: CapturedOrdinaryRequestAuth, query: [String: String] = [:],
                         timeout: HTTPTimeout = .standard) async throws -> HTTPRawResponse {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty else { throw HTTPError.requestIdentityChanged }
        return try await send(APIv2Request(method: method, path: "/api/v2/playback" + suffix, query: query, body: body,
                                           timeout: timeout), auth: auth)
    }

    func watchDetail(id: String, libraryId: String? = nil, imageSize: String?, auth: CapturedOrdinaryRequestAuth) async throws -> WatchDetail {
        let raw = try await profileRequest(auth: auth, status: 200) {
            APIv2Request(method: "GET", path: "/api/v2/watch/\(try catalogPathSegment(id))",
                         query: catalogReadScope(libraryId: libraryId, imageSize: imageSize))
        }
        return try WatchDetail(v2: HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(APIv2CatalogRead.WatchDetail.self, from: raw.data))
    }

    func playbackCapabilities(auth: CapturedOrdinaryRequestAuth) async throws -> APIv2PlaybackCapabilities {
        let raw = try await playbackRequest(method: "GET", suffix: "/capabilities", auth: auth)
        guard raw.statusCode == 200 else { throw PlaybackSequencedError.invalidResponse }
        return try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackCapabilities.self, from: raw.data)
    }

    #if os(iOS)
    func notificationSync(cursor: String?, auth: CapturedOrdinaryRequestAuth) async throws -> APIv2NotificationSyncPage {
        let raw = try await profileRequest(auth: auth, status: 200) {
            var query = ["limit": String(APIv2NotificationSyncPage.defaultLimit)]
            if let cursor, !cursor.isEmpty { query["cursor"] = cursor }
            return APIv2Request(method: "GET", path: "/api/v2/notifications/sync", query: query)
        }
        let page = try HTTPClient.makeJSONDecoder().decode(APIv2NotificationSyncPage.self, from: raw.data)
        guard !page.syncCursor.isEmpty, page.unreadCount >= 0,
              page.items.count <= APIv2NotificationSyncPage.defaultLimit,
              page.items.allSatisfy({ !$0.id.isEmpty && $0.profileId == auth.profileId }),
              Set(page.items.map(\.id)).count == page.items.count,
              page.initialSnapshot == (cursor == nil),
              page.page.hasMore ? (page.page.nextCursor == page.syncCursor && page.syncCursor != cursor && !page.items.isEmpty) : page.page.nextCursor == nil else {
            throw APIv2Error.invalidNotificationContinuation
        }
        return page
    }

    func applePushRegistrationCapability(auth: CapturedOrdinaryRequestAuth) async throws -> APIv2ApplePushCapability {
        let data = try await applePushRequest(method: "GET", path: "/api/v2/devices/push/apple/capabilities", auth: auth)
        return try HTTPClient.makeJSONDecoder().decode(APIv2ApplePushCapability.self, from: data)
    }

    /// Sends one ordered installation intent. `installationKey` and
    /// `generation` come from `ApplePushInstallationJournal`, which owns their
    /// sequence; an exact replay passes the same three values again. The body
    /// is encoded with sorted keys so a replay sends the same bytes.
    ///
    /// Throws `ApplePushRegistrationError.invalidReceipt` when the server's
    /// receipt does not describe this generation and payload.
    func registerApplePush(_ body: APIv2ApplePushRegistrationBody, installationKey: String, generation: Int64,
                           auth: CapturedOrdinaryRequestAuth) async throws -> APIv2ApplePushRegistrationReceipt {
        guard ApplePushInstallationJournal.isInstallationKey(installationKey), generation > 0 else {
            throw ApplePushRegistrationError.invalidInstallation
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = .sortedKeys
        let data = try await applePushRequest(method: "POST", path: "/api/v2/devices/push/apple",
            body: encoder.encode(body),
            headers: ["X-Push-Installation-Key": installationKey, "X-Push-Generation": String(generation)],
            auth: auth)
        let receipt = try HTTPClient.makeJSONDecoder().decode(APIv2ApplePushRegistrationReceipt.self, from: data)
        guard receipt.generation == String(generation), !receipt.id.isEmpty, !receipt.serverDeviceId.isEmpty,
              receipt.pushMode == body.pushMode else {
            throw ApplePushRegistrationError.invalidReceipt
        }
        return receipt
    }

    private func applePushRequest(method: String, path: String, body: Data? = nil, headers: [String: String] = [:],
                                  auth: CapturedOrdinaryRequestAuth) async throws -> Data {
        try await gate()
        // No owner check of its own: the fence's entry check is the first.
        guard case .persistentServer = auth.credentialOwner, let profile = auth.profileId, !profile.isEmpty else {
            throw HTTPError.requestIdentityChanged
        }
        let raw = try await send(APIv2Request(method: method, path: path, body: body, headers: headers), auth: auth)
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return raw.data
    }
    #endif

    // MARK: Owner-fenced requests

    /// Captures the owner a call, or a sequence of calls, is bound to, after
    /// the v1 gate. Each request in the sequence names it, so a server,
    /// account or profile switch refuses the remaining requests instead of
    /// sending them to the replacement.
    func captureRequestOwner() async throws -> CapturedOrdinaryRequestAuth {
        try await gate()
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else { throw HTTPError.requestIdentityChanged }
        return auth
    }

    /// Whether `auth` still describes the current owner. The one comparator
    /// (`TokenStore.currentOrdinaryRequestAuth(matchingIdentityOf:)`) every
    /// owner check in the client goes through.
    func isCurrentOwner(_ auth: CapturedOrdinaryRequestAuth) async -> Bool {
        await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
    }

    /// Sends `request` for `auth`. This is the only place an owner-bound v2
    /// request reaches `HTTPClient`:
    ///
    /// - `TokenStore.withOwnerFence` checks that `auth` is current just
    ///   before the request and again after the answer, and throws
    ///   `HTTPError.authorityChanged` when it is not;
    /// - `HTTPClient` compares the credentials it captures for the request
    ///   with `auth` and its account just before dispatch, and throws
    ///   `HTTPError.requestIdentityChanged` on a mismatch;
    /// - a non-2xx answer becomes an `APIv2Error` (`mapErrors`).
    ///
    /// The request identity is derived from `auth`, so it always names the
    /// owner the guards check. Without a selected profile the request carries
    /// an explicit empty `X-Profile-Id`. `dispatch` is marked when the request
    /// reaches the URL session. Callers run `gate()` first and check the
    /// status. A caller handed an owner usually checks it with
    /// `isCurrentOwner(_:)` first (`profileRequest` does); otherwise the
    /// fence's entry check is the first owner check.
    func send(_ request: APIv2Request, auth: CapturedOrdinaryRequestAuth,
              dispatch: HTTPDispatchRecord? = nil) async throws -> HTTPRawResponse {
        let identity = auth.profileId.map { Self.requestIdentity(auth, profile: $0) }
        let headers = identity == nil
            ? request.headers.merging(["X-Profile-Id": ""]) { _, empty in empty }
            : request.headers
        return try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: request.method, path: request.path, query: request.query,
                    repeatedQuery: request.repeatedQuery, body: request.body, contentType: request.contentType,
                    headers: headers, quietStatuses: request.quietStatuses, timeout: request.timeout,
                    requestIdentity: identity, acceptedStatuses: request.acceptedStatuses,
                    expectedAccount: auth.account, expectedAuth: auth, dispatchRecord: dispatch)
            }
        }
    }

    /// When `profileRequest` checks for task cancellation.
    enum CancellationCheck {
        case never
        case afterResponse
        case beforeAndAfter
    }

    /// A profile-scoped call under a caller-supplied owner, in this order:
    ///
    /// 1. `gate()`;
    /// 2. `HTTPError.requestIdentityChanged` unless `valid`, `auth` has a
    ///    non-empty profile, and `auth` is still the current owner;
    /// 3. with `.beforeAndAfter`, a cancellation check;
    /// 4. `build`, which makes the request, so a bad path segment or body is
    ///    reported only for a current owner;
    /// 5. `send`;
    /// 6. unless `.never`, a cancellation check;
    /// 7. with a `status`, `APIv2Error.httpStatus` for any other status.
    ///
    /// `valid` is the caller's argument check. It shares the owner guard, so a
    /// bad argument is refused with the same error the owner check uses.
    func profileRequest(auth: CapturedOrdinaryRequestAuth?, valid: Bool = true,
                        cancellation: CancellationCheck = .beforeAndAfter, status: Int?,
                        dispatch: HTTPDispatchRecord? = nil,
                        _ build: () throws -> APIv2Request) async throws -> HTTPRawResponse {
        try await gate()
        guard valid, let auth, let profile = auth.profileId, !profile.isEmpty, await isCurrentOwner(auth) else {
            throw HTTPError.requestIdentityChanged
        }
        if cancellation == .beforeAndAfter { try Task.checkCancellation() }
        let raw = try await send(build(), auth: auth, dispatch: dispatch)
        if cancellation != .never { try Task.checkCancellation() }
        if let status, raw.statusCode != status { throw APIv2Error.httpStatus(raw.statusCode) }
        return raw
    }

    /// Runs `operation` with a fresh dispatch record and reports an owner
    /// change by when it was caught: `APIv2OwnerChangedBeforeDispatch` when
    /// the request never reached the URL session (an owner check, the fence's
    /// entry check, or `HTTPClient`'s dispatch gate and owner checks), and
    /// `HTTPError.requestIdentityChanged` or `.authorityChanged` when it was
    /// sent and its answer discarded.
    private func reportingOwnerChangeBeforeDispatch<T>(
        _ operation: (HTTPDispatchRecord) async throws -> T
    ) async throws -> T {
        let dispatch = HTTPDispatchRecord()
        do {
            return try await operation(dispatch)
        } catch HTTPError.requestIdentityChanged where !dispatch.didDispatch {
            throw APIv2OwnerChangedBeforeDispatch()
        } catch HTTPError.authorityChanged where !dispatch.didDispatch {
            throw APIv2OwnerChangedBeforeDispatch()
        }
    }

    /// Sends one request with a caller-built body under `auth` and returns the
    /// undecoded 2xx response; the caller asserts the exact status. A non-2xx
    /// answer throws `APIv2Error`. Never retried here. An owner change is
    /// reported by when it was caught (see
    /// `reportingOwnerChangeBeforeDispatch`).
    func ownedRequest(method: String, path: String, body: Data? = nil, contentType: String = "application/json",
                      timeout: HTTPTimeout = .standard,
                      auth: CapturedOrdinaryRequestAuth) async throws -> HTTPRawResponse {
        try await gate()
        return try await reportingOwnerChangeBeforeDispatch { dispatch in
            guard await isCurrentOwner(auth) else { throw HTTPError.requestIdentityChanged }
            return try await send(APIv2Request(method: method, path: path, body: body, contentType: contentType,
                                               timeout: timeout), auth: auth, dispatch: dispatch)
        }
    }

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
    static func entityTag(_ tag: String?) throws -> String {
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
