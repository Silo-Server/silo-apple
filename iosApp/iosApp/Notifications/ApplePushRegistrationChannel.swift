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
    /// Runs the write only while `owner` still holds the server's
    /// credentials; throws otherwise.
    let commit: @Sendable (_ write: @Sendable () throws -> Void) async throws -> Void
}

enum ApplePushSavedServerError: Error, Equatable {
    /// No current bearer for the server's stored session (`ApproverBearer`).
    case noCredential
}

/// Registration requests for a saved server sent with that server's own
/// stored session, whichever server is active: a display token for a server
/// the person is not using still needs renewing, and signing out of a server
/// turns its registration off. Requests go straight to the server's address
/// on their own URL session, outside `HTTPClient`'s identity gate, which
/// belongs to the active server.
struct ApplePushSavedServerClient: Sendable {
    private static let defaultSession = URLSession(configuration: .ephemeral)
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
            commit: { try await tokenStore.withSavedServerAuthority(owner, operation: $0) }
        )
    }

    /// Throws `APIv2Error` for a non-200 answer, as `APIv2Client` does, so
    /// the registrar classifies refusals the same way for every server.
    private func send(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:],
                      owner: ApplePushIntentOwner, serverURL: String) async throws -> Data {
        // The stored session must still be the registering account's: a
        // later sign-in on that server would register under someone else.
        guard let account = await tokenStore.savedSessionAccount(for: owner.serverID),
              account.accountID == owner.accountID, account.epoch == owner.accountEpoch else {
            throw HTTPError.authorityChanged
        }
        guard let bearer = await http.freshAccessToken(serverId: owner.serverID).token else {
            throw ApplePushSavedServerError.noCredential
        }
        guard let url = URL(string: serverURL + path) else { throw HTTPError.invalidURL(serverURL) }
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
