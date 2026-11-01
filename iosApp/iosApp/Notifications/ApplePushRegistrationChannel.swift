#if os(iOS)
import Foundation

/// How one registration reaches its server, and the fence its local writes
/// (the journal's allocation, the display target) run under.
struct ApplePushRegistrationChannel: Sendable {
    let owner: ApplePushIntentOwner
    let serverURL: String
    let capability: @Sendable () async throws -> APIv2ApplePushCapability
    let send: @Sendable (_ body: APIv2ApplePushRegistrationBody, _ installationKey: String,
                         _ generation: Int64) async throws -> APIv2ApplePushRegistrationReceipt
    /// `resetApplePushInstallation` with the owner's session.
    let reset: @Sendable (_ deviceID: String, _ installationKey: String) async throws -> APIv2ApplePushResetReceipt
    /// One page of the owner's account's login sessions (`listSessions`).
    let loginSessions: @Sendable (_ cursor: String?) async throws -> APIv2LoginSessionPage
    /// Runs the write only while `owner` still holds the server's
    /// credentials; throws otherwise.
    let commit: @Sendable (_ write: @Sendable () throws -> Void) async throws -> Void
}

extension ApplePushRegistrationChannel {
    /// Pages `listSessions` reads through at most when looking for a session.
    static let maximumSessionPages = 10

    /// Whether `holder`'s backend stores this channel's own login session,
    /// which proves both addresses reach one deployment. A `server_id` is
    /// self-asserted, so it only picks the addresses to ask. A session ID is
    /// a random UUID that only the backend that issued it knows, and each
    /// address is asked only about its own sessions, with its own
    /// credentials. An address that is not that backend, or a proxy for it,
    /// cannot list this session unless it signs in to `holder` with the
    /// person's own credentials, which already give it the account. Any
    /// failure counts as no proof.
    func sharesBackend(with holder: ApplePushRegistrationChannel) async -> Bool {
        guard let own = try? await loginSessions(nil).currentSession?.id, !own.isEmpty else { return false }
        var cursor: String?
        for _ in 0..<Self.maximumSessionPages {
            guard let page = try? await holder.loginSessions(cursor) else { return false }
            // The holder's own session is never this channel's.
            if page.items.contains(where: { $0.id == own && !$0.current }) { return true }
            guard let next = page.page?.nextCursor, page.page?.hasMore == true else { return false }
            cursor = next
        }
        return false
    }
}

enum ApplePushSavedServerError: Error, Equatable {
    /// No current bearer for the server's stored session (`ApproverBearer`).
    case noCredential
    /// The server refused the stored session's refresh: it needs a new
    /// sign-in, though the session stays saved.
    case credentialRejected
}

/// Registration requests for a saved server sent with that server's own
/// stored session, whichever server is active: a display token for a server
/// the person is not using still needs renewing, and signing out of a server
/// turns its registration off. Requests go straight to the server's address
/// on their own URL session, outside `HTTPClient`'s identity gate, which
/// belongs to the active server.
struct ApplePushSavedServerClient: Sendable {
    private static let defaultSession = URLSession(configuration: .ephemeral,
                                                   delegate: InsecureRedirectRefusingDelegate.shared,
                                                   delegateQueue: nil)
    private static let requestTimeout: TimeInterval = 15

    var http: HTTPClient = .shared
    var tokenStore: TokenStore = .shared
    var session: URLSession = Self.defaultSession

    /// Nil when the registry id names no server address.
    func channel(for owner: ApplePushIntentOwner) -> ApplePushRegistrationChannel? {
        guard let serverURL = ServerRegistry.url(forServerId: owner.serverID) else { return nil }
        let tokenStore = self.tokenStore
        return ApplePushRegistrationChannel(
            owner: owner,
            serverURL: serverURL,
            capability: {
                let data = try await send("GET", APIv2Client.applePushCapabilityPath, owner: owner, serverURL: serverURL)
                return try HTTPClient.makeJSONDecoder().decode(APIv2ApplePushCapability.self, from: data)
            },
            send: { body, installationKey, generation in
                let headers = try APIv2Client.applePushInstallationHeaders(installationKey: installationKey,
                                                                            generation: generation)
                let data = try await send("POST", APIv2Client.applePushRegistrationPath,
                    body: APIv2Client.applePushRegistrationBody(body), headers: headers,
                    owner: owner, serverURL: serverURL)
                return try APIv2Client.applePushReceipt(from: data, generation: generation, body: body)
            },
            reset: { deviceID, installationKey in
                let data = try await send("POST", APIv2Client.applePushResetPath,
                    body: APIv2Client.applePushResetBody(deviceID: deviceID),
                    headers: APIv2Client.applePushResetHeaders(installationKey: installationKey),
                    owner: owner, serverURL: serverURL)
                return try APIv2Client.applePushResetReceipt(from: data)
            },
            loginSessions: { cursor in
                let data = try await send("GET", APIv2Client.loginSessionsPath,
                    query: APIv2Client.loginSessionsQuery(cursor: cursor), owner: owner, serverURL: serverURL)
                return try HTTPClient.makeJSONDecoder().decode(APIv2LoginSessionPage.self, from: data)
            },
            commit: { try await tokenStore.withSavedServerAuthority(owner, operation: $0) }
        )
    }

    /// Throws `APIv2Error` for a non-200 answer, as `APIv2Client` does, so
    /// the registrar classifies refusals the same way for every server.
    private func send(_ method: String, _ path: String, query: [String: String] = [:], body: Data? = nil,
                      headers: [String: String] = [:],
                      owner: ApplePushIntentOwner, serverURL: String) async throws -> Data {
        // The stored session must still be the registering account's: a
        // later sign-in on that server would register under someone else.
        guard let account = await tokenStore.savedSessionAccount(for: owner.serverID),
              account.accountID == owner.accountID, account.epoch == owner.accountEpoch else {
            throw HTTPError.authorityChanged
        }
        let fresh = await http.freshAccessToken(serverId: owner.serverID)
        guard let bearer = fresh.token else {
            throw fresh == .rejected ? ApplePushSavedServerError.credentialRejected : ApplePushSavedServerError.noCredential
        }
        guard var components = URLComponents(string: serverURL + path) else { throw HTTPError.invalidURL(serverURL) }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw HTTPError.invalidURL(serverURL) }
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = method
        AppleDeviceIdentity.current.applyHeaders(to: &request)
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        request.setValue(owner.profileID, forHTTPHeaderField: "X-Profile-Id")
        if let proof = await tokenStore.savedProfileToken(for: owner.serverID, profileID: owner.profileID),
           !proof.isEmpty {
            request.setValue(proof, forHTTPHeaderField: "X-Profile-Token")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if let problem = try? HTTPClient.makeJSONDecoder().decode(APIv2Problem.self, from: data) {
                throw APIv2Error.problem(problem)
            }
            throw APIv2Error.httpStatus(status)
        }
        return data
    }
}
#endif
