import Foundation

/// External sign-in (OIDC, LDAP and network identity providers) on the v2
/// wire: provider discovery, the native OAuth completion, network identity
/// sign-in, and the account's linked identities. See silo-server
/// `docs/architecture/external-sign-in.md`.
///
/// Nothing here logs a completion code, a verifier, a ticket or a token:
/// they travel only in request bodies, which the transport never logs.
extension APIv2Client {
    static let authProvidersPath = "/api/v2/auth/providers"
    static let oauthCapabilitiesPath = "/api/v2/auth/oauth/capabilities"
    static let externalSignInCapabilitiesPath = "/api/v2/auth/external-sign-in/capabilities"
    static let oauthCompletePath = "/api/v2/auth/oauth/complete"
    static let accountIdentitiesPath = "/api/v2/account/identities"
    static let identityLinkTicketPath = "/api/v2/account/identities/link-ticket"
    static let identityLinkCompletePath = "/api/v2/account/identities/link-complete"
    static let identityLinkCredentialsPath = "/api/v2/account/identities/link-credentials"
    static let identityLinkNetworkPath = "/api/v2/account/identities/link-network"

    // MARK: Discovery (public, explicit URL)

    /// `listAuthProviders` for `serverURL`, without credentials. Explicit-URL
    /// reads skip the active server's contract gate, like `setupStatus`.
    func authProviders(serverURL: String) async throws -> APIv2AuthProviders {
        try await mapErrors {
            try await http.getUnauthenticated(serverURL: serverURL, path: Self.authProvidersPath,
                quietStatuses: [404])
        }
    }

    /// `getOAuthHandshakeCapabilities` for `serverURL`, without credentials.
    func oauthCapabilities(serverURL: String) async throws -> APIv2OAuthCapabilities {
        try await mapErrors {
            try await http.getUnauthenticated(serverURL: serverURL, path: Self.oauthCapabilitiesPath,
                quietStatuses: [404])
        }
    }

    /// Discovery and the handshake document read together. A document the
    /// server does not serve (a 404 from a server that predates it) degrades
    /// to what older servers offer: password only, no browser providers.
    /// Nil when either read failed for any other reason (network, server
    /// fault), so the screen can say so and retry instead of guessing.
    func signInOptions(serverURL: String) async -> SignInOptions? {
        async let providers = Self.discoveryRead { try await authProviders(serverURL: serverURL) }
        async let oauth = Self.discoveryRead { try await oauthCapabilities(serverURL: serverURL) }
        guard case .success(let providersValue) = await providers,
              case .success(let oauthValue) = await oauth else { return nil }
        return SignInOptions(providers: providersValue, oauth: oauthValue)
    }

    /// A discovery document, nil when the server does not serve it, or the
    /// failure.
    private static func discoveryRead<T: Sendable>(_ read: () async throws -> T) async -> Result<T?, Error> {
        do {
            return .success(try await read())
        } catch APIv2Error.serverUpdateRequired {
            return .success(nil)
        } catch APIv2Error.httpStatus(404) {
            return .success(nil)
        } catch APIv2Error.problem(let problem) where problem.status == 404 {
            return .success(nil)
        } catch {
            return .failure(error)
        }
    }

    // MARK: Native completion (public, single dispatch)

    /// `completeOAuthLogin` with the PKCE verifier of the native start.
    /// `non_retryable` and public: one dispatch with no bearer, never a
    /// refresh or a replay, like `login`.
    func completeOAuthLogin(code: String, codeVerifier: String,
                            expectedAccount: RefreshAccountIdentity) async throws -> APIv2OAuthCompletion {
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": codeVerifier])
        return try await postForLoginTokens(path: Self.oauthCompletePath, body: body, expectedAccount: expectedAccount)
    }

    // MARK: Network identity sign-in (public, single dispatch)

    /// `signInWithNetworkIdentity` at `apiPath` (the
    /// `/api/v2/auth/network/<id>/sign-in` of a network provider's
    /// `network_sign_in_path`, see `NetworkSignIn.apiPath(of:)`), on the saved
    /// base URL. The body is an empty JSON object, which the server requires;
    /// the provider's network says who owns this device. `non_retryable` and
    /// public like `login`: one dispatch with no bearer, never a refresh or a
    /// replay.
    func signInWithNetworkIdentity(apiPath: String,
                                   expectedAccount: RefreshAccountIdentity) async throws -> APIv2LoginTokens {
        try await postForLoginTokens(path: apiPath, body: Data("{}".utf8), expectedAccount: expectedAccount)
    }

    // MARK: Account identities (authenticated, account-scoped)

    /// `getExternalSignInCapabilities` under the active account.
    func externalSignInCapabilities(expectedAccount: RefreshAccountIdentity) async throws -> APIv2ExternalSignInCapabilities {
        try await accountJSON(method: "GET", path: Self.externalSignInCapabilitiesPath, status: 200,
            expectedAccount: expectedAccount)
    }

    /// `listAccountIdentities`: the provider identities linked to the
    /// account, and whether one can be disconnected now.
    func accountIdentities(expectedAccount: RefreshAccountIdentity) async throws -> APIv2AccountIdentities {
        try await accountJSON(method: "GET", path: Self.accountIdentitiesPath,
            status: 200, expectedAccount: expectedAccount)
    }

    /// `createAccountIdentityLinkTicket`: re-enters the local password for a
    /// single-use ticket that starts one linking flow. `non_retryable`.
    func createIdentityLinkTicket(installationId: String, password: String,
                                  expectedAccount: RefreshAccountIdentity) async throws -> APIv2IdentityLinkTicket {
        let body = try JSONSerialization.data(withJSONObject: ["installation_id": installationId, "password": password])
        let ticket: APIv2IdentityLinkTicket = try await accountJSON(method: "POST", path: Self.identityLinkTicketPath,
            body: body, status: 200, expectedAccount: expectedAccount)
        guard !ticket.ticket.isEmpty else { throw APIv2Error.incompleteAuthResponse }
        return ticket
    }

    /// `completeAccountIdentityLink`: confirms an app linking flow's code with
    /// its verifier. `non_retryable`; 204 on success.
    func completeIdentityLink(code: String, codeVerifier: String,
                              expectedAccount: RefreshAccountIdentity) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["code": code, "code_verifier": codeVerifier])
        let response = try await accountRequest(method: "POST", path: Self.identityLinkCompletePath, body: body,
            expectedAccount: expectedAccount)
        guard response.statusCode == 204 else { throw APIv2Error.incompleteAuthResponse }
    }

    /// `linkAccountIdentityWithCredentials`: links a directory (LDAP) account
    /// after the local password is re-entered, from the directory username
    /// and password. Single dispatch: both passwords are checked, and a
    /// replay would spend another attempt against each. 201 with the new
    /// identity.
    func linkIdentityWithCredentials(installationId: String, password: String, username: String,
                                     directoryPassword: String,
                                     expectedAccount: RefreshAccountIdentity) async throws -> APIv2AccountIdentity {
        let body = try JSONSerialization.data(withJSONObject: [
            "installation_id": installationId, "password": password,
            "username": username, "directory_password": directoryPassword,
        ])
        return try await accountJSON(method: "POST", path: Self.identityLinkCredentialsPath, body: body, status: 201,
            expectedAccount: expectedAccount)
    }

    /// `linkAccountIdentityWithNetwork`: links the network identity of this
    /// device (who owns it on the provider's network) after the local
    /// password is re-entered. Only a request through that provider's network
    /// can link. Single dispatch: a replay would spend another password check.
    /// 201 with the new identity.
    func linkIdentityWithNetwork(installationId: String, password: String,
                                 expectedAccount: RefreshAccountIdentity) async throws -> APIv2AccountIdentity {
        let body = try JSONSerialization.data(withJSONObject: ["installation_id": installationId, "password": password])
        return try await accountJSON(method: "POST", path: Self.identityLinkNetworkPath, body: body, status: 201,
            expectedAccount: expectedAccount)
    }

    /// `deleteAccountIdentity`. The server refuses the account's last way to
    /// sign in with 409 `last_sign_in_method`.
    func deleteAccountIdentity(id: String, expectedAccount: RefreshAccountIdentity) async throws {
        let segment = try catalogPathSegment(id)
        let response = try await accountRequest(method: "DELETE", path: "\(Self.accountIdentitiesPath)/\(segment)",
            expectedAccount: expectedAccount)
        guard response.statusCode == 204 else { throw APIv2Error.incompleteAuthResponse }
    }

    // MARK: Internals

    /// An account-scoped request: the bearer only, never `X-Profile-Id`, and
    /// refused when the active account changed while it ran.
    private func accountRequest(method: String, path: String, body: Data? = nil,
                                expectedAccount: RefreshAccountIdentity) async throws -> HTTPRawResponse {
        try await gate()
        let response = try await mapErrors {
            try await http.requestData(method: method, path: path, body: body,
                expectedAccount: expectedAccount, sendsProfile: false)
        }
        guard await tokenStore.refreshAccountIdentity() == expectedAccount else { throw HTTPError.requestIdentityChanged }
        return response
    }

    private func accountJSON<T: Decodable>(method: String, path: String, body: Data? = nil, status: Int,
                                           expectedAccount: RefreshAccountIdentity) async throws -> T {
        let response = try await accountRequest(method: method, path: path, body: body, expectedAccount: expectedAccount)
        guard response.statusCode == status else { throw APIv2Error.incompleteAuthResponse }
        return try HTTPClient.makeJSONDecoder().decode(T.self, from: response.data)
    }
}
