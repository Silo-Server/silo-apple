import Foundation
import XCTest
@testable import Silo

/// Network identity sign-in ("Continue as …" through a network provider
/// such as Tailscale): discovery of the provider, the sign-in request on the
/// saved base, the session it installs, refusal copy, and linking the
/// network identity from Settings → Sign-in.
final class NetworkSignInTests: XCTestCase {
    private typealias Support = APIv2FixtureTestSupport
    private static let apiPath = "/api/v2/auth/network/5/sign-in"

    private var stub = APIv2TestStub()

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func fixture(_ name: String, setting members: [String: Any] = [:]) -> String {
        Support.text(named: name, bundleClass: Self.self, setting: members)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try Support.decode(type, named: name, bundleClass: Self.self)
    }

    /// The network provider as discovery lists it to a request that came
    /// through the provider's network.
    private static let networkItem: [String: Any] = [
        "id": "plugin:5:tailscale",
        "display_name": "Tailscale",
        "mode": "network",
        "default": false,
        "installation_id": "5",
        "network_sign_in_path": apiPath,
        "network_identity": ["display_name": "Alice Example", "username": "alice@example.test"],
    ]

    private static func network(
        name: String = "Tailscale", path: String? = apiPath,
        identity: APIv2AuthProviderNetworkIdentity? = APIv2AuthProviderNetworkIdentity(
            displayName: "Alice Example", username: "alice@example.test")
    ) -> APIv2AuthProvider {
        APIv2AuthProvider(id: "plugin:5:tailscale", displayName: name, mode: "network", default: false,
            installationId: "5", networkSignInPath: path, networkIdentity: identity)
    }

    private static func problem(_ id: String, _ status: Int, at location: String? = nil) -> Error {
        APIv2Error.problem(APIv2Problem(type: "https://siloserver.org/docs/api/v2/problems/\(id)", title: "t",
            status: status, detail: "server detail", instance: nil,
            errors: location.map { [APIv2ProblemError(location: $0, code: "invalid", detail: "d")] }))
    }

    // MARK: Discovery

    func testDiscoveryListsTheNetworkProviderBesideTheOthers() throws {
        let body = try Support.mutatedBody(named: "list_auth_providers_ok", bundleClass: Self.self) { object in
            var items = object["items"] as? [[String: Any]] ?? []
            items.append(Self.networkItem)
            items.append(["id": "plugin:9:future", "display_name": "Future", "mode": "webauthn", "default": false])
            object["items"] = items
        }
        let providers = try Support.decoder.decode(APIv2AuthProviders.self, from: body)
        let network = try XCTUnwrap(providers.items.first { $0.isNetwork })
        XCTAssertFalse(network.isOAuth)
        XCTAssertFalse(network.isCredentials)
        XCTAssertEqual(network.installationId, "5")
        XCTAssertEqual(network.networkSignInPath, Self.apiPath)
        XCTAssertEqual(network.networkIdentity?.displayName, "Alice Example")
        XCTAssertEqual(network.networkIdentity?.username, "alice@example.test")

        let options = SignInOptions(providers: providers,
            oauth: try decode(APIv2OAuthCapabilities.self, "get_oauth_handshake_capabilities_ok"))
        XCTAssertEqual(options.networkProviders.map(\.id), ["plugin:5:tailscale"])
        XCTAssertEqual(options.browserProviders.map(\.id), ["plugin-3"], "the network provider is no browser provider")
        XCTAssertTrue(options.showsPasswordForm, "the password form stays")
        XCTAssertTrue(TVSignInPresentation.offersPassword(options), "the TV keeps its password option")
        XCTAssertNil(TVSignInPresentation.phoneHint(SignInOptions(browserProviders: [], acceptsPasswords: true,
            supportsSelectAccount: false, oauthProviders: [], networkProviders: [network])),
            "a network provider is not a single sign-on account without a password")

        // The network provider never decides whether passwords are taken,
        // and it is a way in when they are not.
        let networkOnly = SignInOptions(providers: APIv2AuthProviders(items: [network], passwordLogin: false), oauth: nil)
        XCTAssertFalse(networkOnly.showsPasswordForm)
        XCTAssertFalse(networkOnly.offersNoSignIn)
        XCTAssertEqual(networkOnly.networkProviders, [network])

        // The fixture as the server sends it off the provider's network: no
        // network provider, nothing to continue with.
        let offOverlay = SignInOptions(providers: try decode(APIv2AuthProviders.self, "list_auth_providers_ok"), oauth: nil)
        XCTAssertTrue(offOverlay.networkProviders.isEmpty)
        XCTAssertTrue(SignInOptions.passwordOnly.networkProviders.isEmpty)
    }

    /// A TV with no device sign-in on a server that takes no password shows
    /// "Continue as …" alone, never a password form the server refuses.
    func testTVShowsOnlyTheNetworkSignInWhenItIsTheOnlyWayIn() {
        let network = Self.network()
        let networkOnly = SignInOptions(providers: APIv2AuthProviders(items: [network], passwordLogin: false), oauth: nil)
        XCTAssertTrue(TVSignInPresentation.offersOnlyNetworkSignIn(networkOnly, deviceSignIn: false))
        XCTAssertFalse(TVSignInPresentation.offersOnlyNetworkSignIn(networkOnly, deviceSignIn: true),
            "the code screen leads instead")

        let withPasswords = SignInOptions(providers: APIv2AuthProviders(items: [network], passwordLogin: true), oauth: nil)
        XCTAssertFalse(TVSignInPresentation.offersOnlyNetworkSignIn(withPasswords, deviceSignIn: false),
            "the password form stays under the button")
        let noNetwork = SignInOptions(providers: APIv2AuthProviders(items: [], passwordLogin: false), oauth: nil)
        XCTAssertFalse(TVSignInPresentation.offersOnlyNetworkSignIn(noNetwork, deviceSignIn: false))
        XCTAssertFalse(TVSignInPresentation.offersOnlyNetworkSignIn(nil, deviceSignIn: false),
            "unknown discovery keeps the form")
    }

    /// `network_sign_in_path` becomes a path on the saved base: only its
    /// `/api/v2/auth/network/<id>/sign-in` suffix survives. Anything of
    /// another shape offers no network sign-in.
    func testSignInPathIsTheAPISuffixOnTheSavedBase() {
        XCTAssertEqual(NetworkSignIn.apiPath(of: Self.network()), Self.apiPath)
        XCTAssertEqual(NetworkSignIn.apiPath(of: Self.network(path: "/silo/api/v2/auth/network/5/sign-in")), Self.apiPath,
            "another address's path prefix is dropped; the saved base supplies its own")
        XCTAssertEqual(NetworkSignIn.apiPath(of: Self.network(path: " /api/v2/auth/network/12/sign-in ")),
            "/api/v2/auth/network/12/sign-in")
        for unusable in [nil, "", "api/v2/auth/network/5/sign-in", "//evil.example/api/v2/auth/network/5/sign-in",
                         "https://evil.example/api/v2/auth/network/5/sign-in", "/api/v2/auth/network/5/sign-in?x=1",
                         "/api/v2/auth/network/5/sign-in#x", "/api/v2/auth/network/abc/sign-in",
                         "/api/v2/auth/network/0/sign-in", "/api/v2/auth/network/../sign-in",
                         "/api/v2/auth/oauth/5/native/start", "/api/v2/auth/login"] {
            XCTAssertNil(NetworkSignIn.apiPath(of: Self.network(path: unusable)), unusable ?? "nil")
        }
        let oauth = APIv2AuthProvider(id: "plugin:5:tailscale", displayName: "Tailscale", mode: "oauth", default: false,
            installationId: "5", networkSignInPath: Self.apiPath)
        XCTAssertNil(NetworkSignIn.apiPath(of: oauth), "only a network provider signs in this way")

        XCTAssertTrue(ServerAuthPath.isNetworkSignIn(Self.apiPath))
        XCTAssertTrue(ServerAuthPath.isNetworkSignIn("/media" + Self.apiPath), "under the saved base's path prefix")
        XCTAssertFalse(ServerAuthPath.isNetworkSignIn("/api/v2/auth/network/5/sign-in/extra"))
        XCTAssertFalse(ServerAuthPath.isNetworkSignIn("/api/v2/auth/network/0/sign-in"), "ends in /sign-in, wrong id")
        XCTAssertFalse(ServerAuthPath.isNetworkSignIn("/api/v2/catalog/items"))
        XCTAssertFalse(ServerAuthPath.isNetworkSignIn(APIv2Client.identityLinkNetworkPath))
    }

    func testContinueAsNamesTheDeviceOwnerAndTheProvider() {
        let alice = Self.network()
        XCTAssertEqual(NetworkSignIn.buttonTitle(for: alice), "Continue as Alice Example")
        XCTAssertEqual(NetworkSignIn.viaLine(for: alice), "via Tailscale")
        XCTAssertEqual(NetworkSignIn.accessibilityLabel(for: alice), "Continue as Alice Example, via Tailscale")

        let usernameOnly = Self.network(identity: APIv2AuthProviderNetworkIdentity(displayName: "  ", username: "alice@example.test"))
        XCTAssertEqual(NetworkSignIn.buttonTitle(for: usernameOnly), "Continue as alice@example.test")

        let nameless = Self.network(name: "Sign in with Tailscale",
            identity: APIv2AuthProviderNetworkIdentity(displayName: "", username: ""))
        XCTAssertEqual(NetworkSignIn.buttonTitle(for: nameless), "Continue with Tailscale")
        XCTAssertNil(NetworkSignIn.viaLine(for: nameless), "the button already names the provider")
        XCTAssertEqual(NetworkSignIn.accessibilityLabel(for: nameless), "Continue with Tailscale")
        XCTAssertEqual(NetworkSignIn.buttonTitle(for: Self.network(name: "Headscale", identity: nil)),
            "Continue with Headscale", "the provider's own name, never a hard-coded one")
    }

    // MARK: Signing in

    /// An app on a fresh install with a stale session in its store, saved
    /// behind a path prefix on the provider's address.
    @MainActor
    private func makeAuth(savedURL: String = "https://silo.tailnet.ts.net/media") async throws -> (AuthService, TokenStore) {
        let name = "NetworkSignInTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil), defaults: defaults)
        addTeardownBlock {
            _ = await tokens.clearTokens()
            UserDefaults().removePersistentDomain(forName: name)
        }
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl(savedURL)
        try await tokens.installAccountSession(accessToken: "old", refreshToken: "old-refresh", accountID: "12")
        await tokens.setProfileId("old-profile")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        let auth = AuthService(launchPreferences: ProfileLaunchPreferences(defaults: defaults),
            apiV2Client: APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }),
            httpClient: http, tokenStore: tokens)
        return (auth, tokens)
    }

    /// The sign-in posts `{}` as JSON to the provider's path under the saved
    /// base, with no bearer and no profile, and installs the token pair the
    /// way a password sign-in does.
    @MainActor
    func testSignInPostsAnEmptyJSONObjectAndInstallsTheTokenPair() async throws {
        let (auth, tokens) = try await makeAuth()
        let entry = try Support.entry(named: "sign_in_with_network_identity_ok", bundleClass: Self.self)
        XCTAssertEqual(entry.operationId, "signInWithNetworkIdentity")
        XCTAssertEqual(entry.request.body, "{}")
        let sent = "/media" + Self.apiPath
        stub.reply(path: sent, 200, fixture("sign_in_with_network_identity_ok"))

        try await auth.signInWithNetworkIdentity(Self.network(path: "/elsewhere/api/v2/auth/network/5/sign-in"))

        XCTAssertEqual(stub.requestedPaths, [sent], "one dispatch, on the saved base")
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url?.host, "silo.tailnet.ts.net")
        XCTAssertEqual(request.body, Data("{}".utf8))
        XCTAssertEqual(request.header("content-type"), "application/json")
        XCTAssertNil(request.header("authorization"), "a prior bearer cannot authorize a fresh sign-in")
        XCTAssertNil(request.header("x-profile-id"))

        let access = await tokens.getAccessToken()
        let profile = await tokens.getProfileId()
        let durable = await tokens.captureDurableAccountAuth()
        XCTAssertEqual(access, "acc")
        XCTAssertNil(profile, "a new sign-in clears the prior profile")
        XCTAssertEqual(durable?.accountID, "1", "bound to the account the token pair names")
    }

    /// A refusal installs nothing and keeps the previous session. The sign-in
    /// is single dispatch: a 401 never starts a refresh or a replay.
    @MainActor
    func testRefusalsInstallNothingAndAreNeverReplayed() async throws {
        let (auth, tokens) = try await makeAuth(savedURL: "http://192.168.1.5:8096")
        let refusal = try decode(APIv2Problem.self, "sign_in_with_network_identity_off_overlay")
        XCTAssertEqual(refusal.identifier, "network_identity_required")
        XCTAssertEqual(refusal.status, 403)

        for (status, body) in [(403, fixture("sign_in_with_network_identity_off_overlay")),
                               (401, #"{"type":"https://siloserver.org/docs/api/v2/problems/invalid_token","title":"t","status":401,"detail":"d"}"#)] {
            stub.reset()
            stub.reply(path: HTTPClient.refreshPath, 200, #"{"access_token":"new","refresh_token":"new-ref","expires_in":3600}"#)
            stub.reply(path: Self.apiPath, status, body)
            do {
                try await auth.signInWithNetworkIdentity(Self.network())
                XCTFail("\(status): signed in")
            } catch APIv2Error.problem(let problem) {
                XCTAssertEqual(problem.status, status)
            }
            XCTAssertEqual(stub.requestedPaths, [Self.apiPath], "\(status): one dispatch, no refresh")
            let access = await tokens.getAccessToken()
            let profile = await tokens.getProfileId()
            XCTAssertEqual(access, "old", "\(status)")
            XCTAssertEqual(profile, "old-profile", "\(status)")
        }

        // A provider whose path has another shape sends nothing.
        stub.reset()
        do {
            try await auth.signInWithNetworkIdentity(Self.network(path: "https://evil.example" + Self.apiPath))
            XCTFail("signed in through another origin")
        } catch HTTPError.invalidURL {}
        XCTAssertTrue(stub.requests.isEmpty)
    }

    /// "Change server" while "Continue as …" runs leaves the sign-in screen.
    /// The session still lands, but the sign-in must not pull the app back
    /// to the profiles.
    @MainActor
    func testSignInDoesNotRouteOnceTheAppLeftTheSignInScreen() async throws {
        let (auth, tokens) = try await makeAuth()
        let sent = "/media" + Self.apiPath
        stub.reply(path: sent, 200, fixture("sign_in_with_network_identity_ok"))
        stub.hold(path: sent)
        let router = AppRouter()
        router.resetToLogin()
        let model = LoginViewModel(auth: auth)

        let signIn = Task { await model.signInWithNetworkIdentity(Self.network(), router: router) }
        await stub.waitUntilHeld()
        router.resetToServerSetup()
        stub.release()
        let succeeded = await signIn.value

        XCTAssertTrue(succeeded)
        XCTAssertEqual(router.authState, .needsServerSetup)
        let access = await tokens.getAccessToken()
        XCTAssertEqual(access, "acc")
    }

    func testRefusalsReadAsSentencesNamingTheProvider() {
        let provider = Self.network()
        let cases: [(Error, String?)] = [
            (Self.problem("network_identity_required", 403),
                "Open this server at its Tailscale address to sign in this way."),
            (Self.problem("not_permitted", 403), "Tailscale doesn't allow this device to sign in to this server."),
            (Self.problem("email_in_use", 409),
                "An account with your email already exists. Sign in with your password, then connect Tailscale in Settings → Sign-in."),
            (Self.problem("account_required", 403), ExternalSignInError.reasonText("account_required")),
            (Self.problem("permission_denied", 403), ExternalSignInError.reasonText("account_disabled")),
            (Self.problem("identity_linked_elsewhere", 409), ExternalSignInError.reasonText("identity_linked_elsewhere")),
            (Self.problem("provider_unavailable", 503), ExternalSignInError.reasonText("provider_unavailable")),
            (Self.problem("not_found", 404), AccountSignInModel.providerGoneMessage),
            (Self.problem("rate_limited", 429), LoginViewModel.rateLimitedMessage),
            (APIv2Error.httpStatus(429), LoginViewModel.rateLimitedMessage),
            (Self.problem("invalid_token", 401), ExternalSignInError.reasonText("login_failed")),
            (Self.problem("unsupported_media_type", 415), ExternalSignInError.reasonText("login_failed")),
            (CancellationError(), nil),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(NetworkSignIn.signInMessage(for: error, provider: provider), expected, "\(error)")
        }
        XCTAssertEqual(NetworkSignIn.signInMessage(for: Self.problem("not_permitted", 403),
            provider: Self.network(name: "Headscale")), "Headscale doesn't allow this device to sign in to this server.")
    }

    // MARK: Linking from Settings → Sign-in

    func testCapabilityAndConnectableFollowTheServer() throws {
        let current = try decode(APIv2ExternalSignInCapabilities.self, "get_external_sign_in_capabilities_ok")
        XCTAssertTrue(current.supportsNetworkSignIn)
        let older = try Support.decoder.decode(APIv2ExternalSignInCapabilities.self, from: Support.mutatedBody(
            named: "get_external_sign_in_capabilities_ok", bundleClass: Self.self) { $0.removeValue(forKey: "network_sign_in") })
        XCTAssertFalse(older.supportsNetworkSignIn, "absent from servers that predate it")

        let network = Self.network()
        let local = APIv2AuthProvider(id: "local", displayName: "Local", mode: "credentials", default: true)
        let offered = AccountSignInModel.connectable(providers: [local, network], oauth: nil, credentialsLinking: false,
            networkLinking: true, linked: [])
        XCTAssertEqual(offered.map(\.id), [network.id])
        XCTAssertEqual(offered.map(\.method), [.network])
        XCTAssertEqual(offered.first?.name, "Tailscale")
        XCTAssertTrue(AccountSignInModel.connectable(providers: [network], oauth: nil, credentialsLinking: true,
            linked: []).isEmpty, "a server without network_sign_in offers no network link")
        let linked = APIv2AccountIdentity(id: "8", installationId: "5", providerId: network.id, providerName: "Tailscale",
            username: "alice@example.test", email: "", displayName: "", linkedAt: Date())
        XCTAssertTrue(AccountSignInModel.connectable(providers: [network], oauth: nil, credentialsLinking: false,
            networkLinking: true, linked: [linked]).isEmpty, "a linked installation is not offered again")

        // A provider the login screen would drop for its path is never
        // offered: the connection would give no way to sign in on this app.
        for unusable in [nil, "/api/v2/auth/network/abc/sign-in", "https://evil.example/api/v2/auth/network/5/sign-in"] {
            XCTAssertTrue(SignInOptions(providers: APIv2AuthProviders(items: [Self.network(path: unusable)],
                passwordLogin: true), oauth: nil).networkProviders.isEmpty, unusable ?? "nil")
            XCTAssertTrue(AccountSignInModel.connectable(providers: [Self.network(path: unusable)], oauth: nil,
                credentialsLinking: false, networkLinking: true, linked: []).isEmpty, unusable ?? "nil")
        }
    }

    /// Like directory linking, the local password goes once, under the
    /// account's own bearer; this device's owner is what the server links.
    func testLinkSendsOnlyTheSiloPasswordOnceUnderTheAccount() async throws {
        let (api, account) = try await makeSignedInAPI()
        let entry = try Support.entry(named: "link_account_identity_with_network_ok", bundleClass: Self.self)
        XCTAssertEqual(entry.operationId, "linkAccountIdentityWithNetwork")
        XCTAssertEqual(entry.request.path, APIv2Client.identityLinkNetworkPath)
        stub.reply(path: APIv2Client.identityLinkNetworkPath, 201, fixture("link_account_identity_with_network_ok"))

        let linked = try await api.linkIdentityWithNetwork(installationId: "5", password: "local", expectedAccount: account)

        XCTAssertEqual(linked.installationId, "5")
        XCTAssertEqual(linked.providerName, "Tailscale")
        XCTAssertEqual(linked.accountLabel, "alice@example.test")
        let request = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.header("authorization"), "Bearer acc")
        XCTAssertNil(request.header("x-profile-id"), "account-scoped")
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String]),
            ["installation_id": "5", "password": "local"])

        // A 401 is not answered with a refresh and a second password check.
        stub.reset()
        stub.reply(path: HTTPClient.refreshPath, 200, #"{"access_token":"new","refresh_token":"new-ref","expires_in":3600}"#)
        stub.reply(path: APIv2Client.identityLinkNetworkPath, 401,
            #"{"type":"https://siloserver.org/docs/api/v2/problems/invalid_token","title":"t","status":401,"detail":"d"}"#)
        do {
            _ = try await api.linkIdentityWithNetwork(installationId: "5", password: "local", expectedAccount: account)
            XCTFail("linked")
        } catch {}
        XCTAssertEqual(stub.requestedPaths, [APIv2Client.identityLinkNetworkPath])
    }

    /// The Settings page offers "Connect Tailscale" only when discovery lists
    /// the provider (over its network) and the server serves network links;
    /// connecting sends the password alone and reads refusals as copy.
    @MainActor
    func testAccountPageConnectsTheNetworkProviderWithThePasswordAlone() async throws {
        let (api, _, tokens) = try await makeSignedInStack()
        let model = AccountSignInModel(api: api, tokenStore: tokens, link: { _, _ in XCTFail("browser link used") })
        let providers = try Support.mutatedBody(named: "list_auth_providers_ok", bundleClass: Self.self) { object in
            object["items"] = [["id": "local", "display_name": "Silo account", "mode": "credentials", "default": true],
                               Self.networkItem]
        }
        stub.reply(path: APIv2Client.authProvidersPath, 200, String(decoding: providers, as: UTF8.self))
        stub.reply(path: APIv2Client.oauthCapabilitiesPath, 200, fixture("get_oauth_handshake_capabilities_ok"))
        stub.reply(path: APIv2Client.externalSignInCapabilitiesPath, 200, fixture("get_external_sign_in_capabilities_ok"))
        stub.reply(path: APIv2Client.accountIdentitiesPath, 200, #"{"items":[],"can_unlink":true}"#)

        await model.load()
        XCTAssertTrue(model.showsEntry)
        let item = try XCTUnwrap(model.connectable.first)
        XCTAssertEqual(item.method, .network)

        let cases: [(Int, String, String)] = [
            (403, Self.problemBody("network_identity_required", 403), "Open this server at its Tailscale address to connect it."),
            (422, #"{"type":"https://siloserver.org/docs/api/v2/problems/validation_failed","title":"t","status":422,"detail":"d","errors":[{"location":"body.password","code":"invalid","detail":"d"}]}"#,
                "That Silo password is incorrect."),
            (403, Self.problemBody("not_permitted", 403), "Tailscale doesn't allow this device to sign in to this server."),
            (409, Self.problemBody("local_password_required", 409),
                "Your account has no Silo password to confirm with. Ask an administrator to connect the provider."),
            (409, Self.problemBody("already_linked", 409), ExternalSignInError.reasonText("already_linked")),
        ]
        for (status, body, expected) in cases {
            stub.reply(path: APIv2Client.identityLinkNetworkPath, status, body)
            let connected = await model.connect(item.provider, password: "local")
            XCTAssertFalse(connected, expected)
            XCTAssertEqual(model.errorMessage, expected)
            XCTAssertNil(model.busyID)
        }
        let before = stub.requestedPaths.filter { $0 == APIv2Client.identityLinkNetworkPath }.count
        let empty = await model.connect(item.provider, password: "")
        XCTAssertFalse(empty)
        XCTAssertEqual(model.errorMessage, "Enter your Silo password.")
        XCTAssertEqual(stub.requestedPaths.filter { $0 == APIv2Client.identityLinkNetworkPath }.count, before,
            "nothing is sent without the password")

        stub.reply(path: APIv2Client.identityLinkNetworkPath, 201, fixture("link_account_identity_with_network_ok"))
        let connected = await model.connect(item.provider, password: "local")
        XCTAssertTrue(connected)
        XCTAssertEqual(model.resultMessage, "Connected to Tailscale.")
        XCTAssertNil(model.errorMessage)
    }

    private static func problemBody(_ id: String, _ status: Int) -> String {
        #"{"type":"https://siloserver.org/docs/api/v2/problems/\#(id)","title":"t","status":\#(status),"detail":"d"}"#
    }

    private func makeSignedInStack() async throws -> (APIv2Client, RefreshAccountIdentity, TokenStore) {
        let name = "NetworkSignInTests.account.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        addTeardownBlock {
            _ = await tokens.clearTokens()
            UserDefaults().removePersistentDomain(forName: name)
        }
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://silo.tailnet.ts.net")
        try await tokens.installAccountSession(accessToken: "acc", refreshToken: "ref", accountID: "1")
        let api = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens,
            isUpdateRequired: { false })
        let identity = await tokens.refreshAccountIdentity()
        return (api, try XCTUnwrap(identity), tokens)
    }

    private func makeSignedInAPI() async throws -> (APIv2Client, RefreshAccountIdentity) {
        let (api, account, _) = try await makeSignedInStack()
        return (api, account)
    }
}
