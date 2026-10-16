import Foundation

/// Bare-bones authenticated GET helper for the Top Shelf extension.
///
/// The main app's `HTTPClient` owns a lot we don't need here: in-flight
/// request cancellation, cookie storage, logging, persisted token rotation.
/// The extension runs for a few seconds with no UI to refresh into, so each
/// call is a single `URLSession.data(for:)` with pre-attached headers and a
/// 5 s timeout.
///
/// Access tokens expire after the server's `auth.access_token_expiry` (8 h by
/// default), so a Top Shelf run long after the app last ran sees a 401. The
/// client then refreshes once from the stored refresh token, in memory only,
/// and retries. The new pair is never written to the shared Keychain: the app
/// owns it. Refresh tokens are not single-use; the server checks the signature
/// and the session and consumes nothing, so the app's token stays valid. A
/// 401 that survives the refresh means the session is gone; the caller
/// returns no content and the system shows the static top-shelf image.
///
/// Lives in Shared so the test bundles can reach it.
struct TopShelfHTTPClient {
    enum Error: Swift.Error {
        case notAuthenticated
        case invalidURL
        case unexpectedStatus(Int)
    }

    let defaults: SharedDefaults
    let accountKeychain: SharedKeychain
    let profileKeychain: SharedKeychain
    let session: URLSession
    private let sessions: AccountSessionPersistence
    /// Captured by `authenticated()`; canonical identity is rechecked before
    /// sending credentials and before publishing each response.
    private var credentials: Credentials?

    /// The account and profile a set of credentials was read for.
    private struct Scope: Equatable {
        let serverID: String
        let origin: String
        let accountID: String?
        let profileID: String?
        let accountEpoch: String?
        let isLegacy: Bool
    }

    private struct ResolvedSession {
        let scope: Scope
        let accessToken: String
        let refreshToken: String?
        let profileToken: String?
    }

    private struct Credentials {
        let scope: Scope
        let serverURL: String
        let tokens: AccessTokenSlot
        let profileID: String?
        let profileToken: String?
    }

    /// The access token every copy of one authenticated client sends, so
    /// requests that hit the same expired token share a single refresh.
    private actor AccessTokenSlot {
        private(set) var accessToken: String
        private let refreshToken: String?
        private var refresh: Task<String?, Never>?

        init(accessToken: String, refreshToken: String?) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
        }

        /// The token to retry with after `rejected` drew a 401, or nil when
        /// the one refresh this client may make failed or already produced
        /// `rejected`.
        func replacement(
            for rejected: String,
            refreshing perform: @escaping @Sendable (String) async -> String?
        ) async -> String? {
            if refresh == nil, let refreshToken {
                refresh = Task { await perform(refreshToken) }
            }
            guard let fresh = await refresh?.value, fresh != rejected else { return nil }
            accessToken = fresh
            return fresh
        }
    }

    init(defaults: SharedDefaults = .shared,
         keychain: SharedKeychain = SharedKeychain(),
         session: URLSession = .shared,
         sessions: AccountSessionPersistence? = nil) {
        self.defaults = defaults
        // A matching legacy service disables SharedKeychain's rename-on-read
        // path. Only the app may migrate credentials or canonical storage.
        let readOnlyKeychain = SharedKeychain(service: keychain.service, accessGroup: keychain.accessGroup,
            audience: keychain.audience, usesUserIndependentKeychain: keychain.usesUserIndependentKeychain,
            allowsAppLocalFallback: keychain.allowsAppLocalFallback, legacyService: keychain.service)
        self.accountKeychain = readOnlyKeychain.withAudience(.userIndependent)
        self.profileKeychain = readOnlyKeychain.withAudience(.currentUser)
        self.session = session
        self.sessions = sessions ?? AccountSessionPersistence(keychain: readOnlyKeychain)
    }

    var isPersonalizedContentAllowed: Bool {
        guard let resolved = resolveSession() else { return false }
        return allowsPersonalizedContent(resolved)
    }

    private func allowsPersonalizedContent(_ resolved: ResolvedSession) -> Bool {
        let state = ProfileLaunchState.load(from: defaults)
        return TopShelfProfilePolicy.allowsPersonalizedContent(
            state: state,
            serverID: resolved.scope.serverID,
            activeProfileID: resolved.scope.profileID,
            accountEpoch: resolved.scope.accountEpoch,
            hasStoredProfileToken: resolved.profileToken != nil
        )
    }

    /// True while personalized content is allowed and the active account and
    /// profile are still the ones this copy's credentials were read for, so
    /// a profile switch mid-request cannot publish the previous profile's shelf.
    var isCurrentScope: Bool {
        guard let credentials, let resolved = resolveSession(),
              allowsPersonalizedContent(resolved) else { return false }
        return resolved.scope == credentials.scope && resolved.profileToken == credentials.profileToken
    }

    /// Reading an adopted envelope never migrates it or consults raw mirrors.
    /// The app owns adoption, account selection, and token persistence.
    private func resolveSession() -> ResolvedSession? {
        guard let serverID = defaults.string(forKey: SharedStorage.activeServerIdKey),
              !serverID.isEmpty,
              let savedURL = defaults.string(forKey: SharedStorage.serverUrlKey),
              let origin = Self.normalizedOrigin(savedURL) else { return nil }
        do {
            let accountID: String?
            let epoch: String?
            let accessToken: String
            let refreshToken: String?
            let isLegacy: Bool
            switch try sessions.load(serverID) {
            case .signedOut:
                return nil
            case .session(let value):
                guard let storedOrigin = value.origin,
                      Self.normalizedOrigin(storedOrigin) == origin,
                      let access = value.accessToken, !access.isEmpty,
                      let accountEpoch = value.epoch else { return nil }
                accountID = value.accountID
                epoch = accountEpoch.uuidString
                accessToken = access
                refreshToken = value.refreshToken
                isLegacy = false
            case .legacy:
                guard let access = try accountKeychain.getChecked(
                    SharedStorage.accessTokenAccount(for: serverID)), !access.isEmpty else { return nil }
                accountID = nil
                epoch = try accountKeychain.getChecked(SharedStorage.accountEpochAccount(for: serverID))
                accessToken = access
                refreshToken = try accountKeychain.getChecked(SharedStorage.refreshTokenAccount(for: serverID))
                // Adoption or a local selector appearing during the raw reads
                // must close this legacy credential path immediately.
                guard try sessions.load(serverID) == .legacy else { return nil }
                isLegacy = true
            }
            #if os(tvOS)
            let profileKey = SharedStorage.profileTokenAccount(for: serverID, accountID: accountID)
            #else
            let profileKey = SharedStorage.profileTokenAccount(for: serverID)
            #endif
            let proof = try profileKeychain.getChecked(profileKey)
            return ResolvedSession(
                scope: Scope(serverID: serverID, origin: origin, accountID: accountID,
                    profileID: defaults.string(forKey: SharedStorage.profileIdKey),
                    accountEpoch: epoch, isLegacy: isLegacy),
                accessToken: accessToken, refreshToken: refreshToken,
                profileToken: proof?.isEmpty == false ? proof : nil
            )
        } catch {
            return nil
        }
    }

    /// Matches the app's saved URL normalization while refusing a non-HTTP
    /// destination or credentials embedded in the server address.
    private static func normalizedOrigin(_ value: String) -> String? {
        var origin = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while origin.hasSuffix("/") { origin.removeLast() }
        guard let components = URLComponents(string: origin),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        return origin
    }

    /// A copy carrying the active server's credentials, or nil without an
    /// access token. Check `isPersonalizedContentAllowed` first.
    func authenticated() -> TopShelfHTTPClient? {
        guard let resolved = resolveSession() else { return nil }
        var client = self
        client.credentials = Credentials(
            scope: resolved.scope,
            serverURL: resolved.scope.origin,
            tokens: AccessTokenSlot(
                accessToken: resolved.accessToken,
                refreshToken: resolved.refreshToken
            ),
            profileID: resolved.scope.profileID,
            profileToken: resolved.profileToken
        )
        return client
    }

    /// Negotiate the same large-image contract as the main tvOS app. Older
    /// servers and transient failures return an empty query, preserving the
    /// extension's existing fallback behavior.
    func fetchImageSizeQuery() async -> [String: String] {
        let capability: ImageSizeCapabilityResponse? = try? await get(
            "/api/v2/images/capabilities"
        )
        return ImageSizeSelection.queryEntries(
            capability: capability,
            prefersLargeImages: true
        )
    }

    func fetchHomeSections(imageSizeQuery: [String: String]) async throws -> TopShelfSectionsResponse {
        try await get("/api/v2/home/sections", query: imageSizeQuery)
    }

    func fetchSeasons(
        seriesId: String,
        imageSizeQuery: [String: String]
    ) async throws -> TopShelfSeasonsResponse {
        guard let segment = CatalogPathSegment.encode(seriesId) else { throw Error.invalidURL }
        return try await get(
            "/api/v2/catalog/series/\(segment)/seasons",
            query: imageSizeQuery
        )
    }

    func fetchItemDetail(
        contentId: String,
        imageSizeQuery: [String: String]
    ) async throws -> TopShelfItemDetail {
        guard let segment = CatalogPathSegment.encode(contentId) else { throw Error.invalidURL }
        return try await get(
            "/api/v2/catalog/items/\(segment)",
            query: imageSizeQuery
        )
    }

    // MARK: - Private

    private func get<T: Decodable>(
        _ path: String,
        query: [String: String] = [:]
    ) async throws -> T {
        // Rechecked per request and after every await: a timed profile policy
        // can expire, or the account or profile change, while a request or
        // the token refresh is in flight.
        guard isCurrentScope, let credentials else { throw Error.notAuthenticated }
        guard let url = Self.url(credentials.serverURL, path: path, query: query) else {
            throw Error.invalidURL
        }

        let token = await credentials.tokens.accessToken
        guard isCurrentScope else { throw Error.notAuthenticated }
        var (data, http) = try await send(url, credentials: credentials, bearer: token)
        let serverURL = credentials.serverURL
        if http.statusCode == 401 {
            // Never spend a refresh token the app may have signed out of.
            guard isCurrentScope else { throw Error.notAuthenticated }
            if let fresh = await credentials.tokens.replacement(for: token, refreshing: { [session] refreshToken in
                await Self.refreshedAccessToken(serverURL: serverURL, refreshToken: refreshToken, session: session)
            }) {
                guard isCurrentScope else { throw Error.notAuthenticated }
                (data, http) = try await send(url, credentials: credentials, bearer: fresh)
            }
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.unexpectedStatus(http.statusCode)
        }
        guard isCurrentScope else { throw Error.notAuthenticated }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.userInfo[ArtworkURLResolver.serverURLKey] = http.url ?? url
        return try decoder.decode(T.self, from: data)
    }

    private func send(
        _ url: URL,
        credentials: Credentials,
        bearer: String
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        if let profileID = credentials.profileID {
            request.setValue(profileID, forHTTPHeaderField: "X-Profile-Id")
        }
        if let profileToken = credentials.profileToken {
            request.setValue(profileToken, forHTTPHeaderField: "X-Profile-Token")
        }
        return try await Self.send(request, session: session)
    }

    private static func send(
        _ request: URLRequest,
        session: URLSession
    ) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Error.unexpectedStatus(0)
        }
        return (data, http)
    }

    private static func url(_ serverURL: String, path: String, query: [String: String] = [:]) -> URL? {
        guard var components = URLComponents(string: serverURL) else { return nil }
        let base = components.percentEncodedPath
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        components.percentEncodedPath = trimmed + path
        if !query.isEmpty {
            components.queryItems = query
                .sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }

    private struct RefreshBody: Encodable { let refreshToken: String }
    private struct RefreshedTokens: Decodable { let accessToken: String }

    /// `POST /api/v2/auth/refresh` without a bearer. Only the access token is
    /// kept; nil on any failure, which leaves the original 401 standing.
    private static func refreshedAccessToken(
        serverURL: String,
        refreshToken: String,
        session: URLSession
    ) async -> String? {
        guard let url = url(serverURL, path: "/api/v2/auth/refresh") else { return nil }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? encoder.encode(RefreshBody(refreshToken: refreshToken))
        guard let (data, http) = try? await send(request, session: session),
              (200..<300).contains(http.statusCode) else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return (try? decoder.decode(RefreshedTokens.self, from: data))?.accessToken
    }
}
