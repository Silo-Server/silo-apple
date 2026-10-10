import Foundation
import XCTest
#if !os(tvOS)
import AuthenticationServices
#endif
@testable import Silo

/// External sign-in in the apps: provider discovery and the password-form
/// rule, the native OAuth handshake (PKCE, state and server checks, error
/// codes), account linking, and refresh during a provider outage.
final class ExternalSignInTests: XCTestCase {
    private typealias Support = APIv2FixtureTestSupport
    private static let serverId = "dd92a78d-69a8-4b80-a6f9-b300991bfcd2"
    private static let startURL = "https://silo.example.test/api/v2/auth/oauth/3/native/start"
    private static let startPath = "/api/v2/auth/oauth/3/native/start"
    /// The origin of `startURL`, where the saved server lives unless a test
    /// says otherwise.
    private static let origin = "https://silo.example.test"

    private var stub = APIv2TestStub()

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func fixture(_ name: String) throws -> Data {
        try Support.data(named: name, bundleClass: Self.self)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try Support.decoder.decode(type, from: fixture(name))
    }

    private static func provider(
        id: String = "plugin:3:oidc", name: String = "Example SSO", mode: String = "oauth",
        installation: String? = "3", startPath: String? = ExternalSignInTests.startPath
    ) -> APIv2AuthProvider {
        APIv2AuthProvider(id: id, displayName: name, mode: mode, default: false,
            iconUrl: nil, installationId: installation, nativeStartPath: startPath)
    }

    private static let local = APIv2AuthProvider(id: "local", displayName: "Local", mode: "credentials", default: true)
    private static let native = APIv2OAuthCapabilities(state: "available", native: true, linking: true)

    // MARK: Fixtures

    func testDiscoveryAndHandshakeFixturesDecode() throws {
        let providers = try decode(APIv2AuthProviders.self, "list_auth_providers_ok")
        XCTAssertEqual(providers.passwordLogin, true)
        let sso = try XCTUnwrap(providers.items.first { $0.isOAuth })
        XCTAssertEqual(sso.installationId, "3")
        XCTAssertEqual(sso.nativeStartPath, Self.startPath)
        XCTAssertEqual(SignInOptions.nativeStart(of: sso), SignInOptions.NativeStart(apiPath: Self.startPath, queryItems: []))

        let oauth = try decode(APIv2OAuthCapabilities.self, "get_oauth_handshake_capabilities_ok")
        XCTAssertTrue(oauth.supportsNative)
        XCTAssertTrue(oauth.supportsLinking)
        XCTAssertTrue(oauth.supportsSelectAccount)
        let external = try decode(APIv2ExternalSignInCapabilities.self, "get_external_sign_in_capabilities_ok")
        XCTAssertTrue(external.supportsIdentities)
        XCTAssertTrue(external.supportsCredentialsLinking)

        let options = SignInOptions(providers: providers, oauth: oauth)
        XCTAssertEqual(options.browserProviders.map(\.id), [sso.id])
        XCTAssertTrue(options.showsPasswordForm)
        XCTAssertTrue(options.supportsSelectAccount)

        let completion = try decode(APIv2OAuthCompletion.self, "complete_oauth_login_native_ok")
        XCTAssertEqual(completion.user.id, "1")
        XCTAssertEqual(completion.accessToken, "acc")

        let identities = try decode(APIv2AccountIdentities.self, "list_account_identities_ok")
        let identity = try XCTUnwrap(identities.items.first)
        XCTAssertEqual(identity.providerName, "Company SSO")
        XCTAssertEqual(identity.accountLabel, "alice")
        XCTAssertNotNil(identity.lastSignInAt)
        XCTAssertEqual(identities.canUnlink, false)
        XCTAssertFalse(try decode(APIv2IdentityLinkTicket.self, "create_account_identity_link_ticket_ok").ticket.isEmpty)

        let outage = try decode(APIv2Problem.self, "refresh_session_provider_unavailable")
        XCTAssertEqual(outage.identifier, "provider_unavailable")
        XCTAssertEqual(outage.status, 503)
    }

    // MARK: Discovery gating

    func testPasswordFormFollowsDiscovery() {
        func options(_ items: [APIv2AuthProvider], passwordLogin: Bool?, oauth: APIv2OAuthCapabilities? = ExternalSignInTests.native) -> SignInOptions {
            SignInOptions(providers: APIv2AuthProviders(items: items, passwordLogin: passwordLogin), oauth: oauth)
        }
        let ldap = Self.provider(id: "plugin:6:ldap", name: "Directory", mode: "credentials", installation: "6", startPath: nil)

        // OIDC only, local passwords off: browser sign-in only.
        let oidcOnly = options([Self.provider()], passwordLogin: false)
        XCTAssertFalse(oidcOnly.showsPasswordForm)
        XCTAssertEqual(oidcOnly.browserProviders.count, 1)
        XCTAssertFalse(TVSignInPresentation.offersPassword(oidcOnly))

        // Local on: both.
        let both = options([Self.local, Self.provider()], passwordLogin: true)
        XCTAssertTrue(both.showsPasswordForm)
        XCTAssertEqual(both.browserProviders.count, 1)

        // LDAP with local off: the form stays, with no provider field; the
        // server routes by account. The TV keeps its password form too.
        let directory = options([ldap], passwordLogin: true)
        XCTAssertTrue(directory.showsPasswordForm)
        XCTAssertTrue(directory.browserProviders.isEmpty)
        XCTAssertFalse(directory.offersNoSignIn)
        XCTAssertTrue(TVSignInPresentation.offersPassword(directory))

        // A server that predates password_login always took a password.
        XCTAssertTrue(options([Self.local], passwordLogin: nil).showsPasswordForm)
        // No discovery at all (older server, failed read): the password form.
        XCTAssertEqual(SignInOptions(providers: nil, oauth: nil), .passwordOnly)
        XCTAssertTrue(TVSignInPresentation.offersPassword(nil))

        // Browser providers need the server's native handoff and a usable URL.
        XCTAssertTrue(options([Self.provider()], passwordLogin: true,
            oauth: APIv2OAuthCapabilities(state: "available", native: false)).browserProviders.isEmpty)
        XCTAssertTrue(options([Self.provider()], passwordLogin: true, oauth: nil).browserProviders.isEmpty)
        XCTAssertTrue(options([Self.provider(startPath: nil)], passwordLogin: true).browserProviders.isEmpty)
        XCTAssertTrue(options([Self.provider(startPath: "javascript:alert(1)")], passwordLogin: true)
            .browserProviders.isEmpty)

        // Local passwords off but no provider this app can open: no form,
        // and the screen says so (spec: apps hide the password form unless
        // a credentials provider is listed). The TV relies on device sign-in.
        let unreachable = options([Self.provider(startPath: nil)], passwordLogin: false)
        XCTAssertFalse(unreachable.acceptsPasswords)
        XCTAssertFalse(unreachable.showsPasswordForm)
        XCTAssertTrue(unreachable.offersNoSignIn)
        XCTAssertFalse(TVSignInPresentation.offersPassword(unreachable))

        // select_account needs the native handoff and the server's flag.
        let switchable = APIv2OAuthCapabilities(state: "available", native: true, selectAccount: true)
        XCTAssertTrue(options([Self.provider()], passwordLogin: false, oauth: switchable).supportsSelectAccount)
        XCTAssertFalse(oidcOnly.supportsSelectAccount, "a server that predates select_account")
        XCTAssertFalse(options([Self.provider()], passwordLogin: false, oauth:
            APIv2OAuthCapabilities(state: "disabled", native: true, selectAccount: true)).supportsSelectAccount)
    }

    /// Discovery reads that fail are not "an older server": only a 404 (the
    /// document is not served) degrades to the password form. Anything else
    /// is reported as a failure the login screen retries.
    func testDiscoveryDistinguishesAnOlderServerFromAFailedRead() async throws {
        let (_, _, tokens) = try await makeService(runner: FakeRunner { _ in throw ExternalSignInError.canceled })
        let api = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens,
            isUpdateRequired: { false })
        let server = "http://192.0.2.10:8432"
        let notFound = Support.text(named: "not_found", bundleClass: Self.self)

        stub.reply(path: APIv2Client.authProvidersPath, 200, Support.text(named: "list_auth_providers_ok", bundleClass: Self.self))
        stub.reply(path: APIv2Client.oauthCapabilitiesPath, 200,
            Support.text(named: "get_oauth_handshake_capabilities_ok", bundleClass: Self.self))
        let loaded = await api.signInOptions(serverURL: server)
        XCTAssertEqual(loaded?.browserProviders.count, 1)

        stub.reset()
        stub.reply(path: APIv2Client.authProvidersPath, 404, notFound)
        stub.reply(path: APIv2Client.oauthCapabilitiesPath, 404, notFound)
        let older = await api.signInOptions(serverURL: server)
        XCTAssertEqual(older, .passwordOnly)

        stub.reset()
        stub.reply(path: APIv2Client.authProvidersPath, 200, Support.text(named: "list_auth_providers_ok", bundleClass: Self.self))
        stub.reply(path: APIv2Client.oauthCapabilitiesPath, 404, notFound)
        let noHandshake = await api.signInOptions(serverURL: server)
        XCTAssertEqual(noHandshake?.browserProviders, [], "no handshake document, no browser providers")

        stub.reset()
        stub.reply(path: APIv2Client.authProvidersPath, 503, #"{"type":"t","title":"t","status":503,"detail":"d"}"#)
        stub.reply(path: APIv2Client.oauthCapabilitiesPath, 200,
            Support.text(named: "get_oauth_handshake_capabilities_ok", bundleClass: Self.self))
        let failedProviders = await api.signInOptions(serverURL: server)
        XCTAssertNil(failedProviders, "a server fault is a failed read, not an older server")

        stub.reset()
        stub.reply(path: APIv2Client.authProvidersPath, 200, Support.text(named: "list_auth_providers_ok", bundleClass: Self.self))
        stub.reply(path: APIv2Client.oauthCapabilitiesPath, 500, #"{"type":"t","title":"t","status":500,"detail":"d"}"#)
        let failedHandshake = await api.signInOptions(serverURL: server)
        XCTAssertNil(failedHandshake, "a failed handshake read would otherwise hide the provider buttons")
    }

    @MainActor
    func testSelectAccountAfterSignOutAndOnRequest() throws {
        let name = "ExternalSignInTests.prompt.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let prompt = SelectAccountPrompt(defaults: defaults)

        XCTAssertFalse(prompt.isRequested(serverId: "home"))
        prompt.request(serverId: "home")
        XCTAssertTrue(prompt.isRequested(serverId: "home"))
        XCTAssertFalse(prompt.isRequested(serverId: "other"))
        XCTAssertFalse(prompt.consumeAutoStart(serverId: "home"), "an ordinary sign-out never opens the browser")
        XCTAssertTrue(SelectAccountPrompt(defaults: defaults).isRequested(serverId: "home"), "kept across launches")

        prompt.request(serverId: "home", autoStart: true)
        XCTAssertFalse(prompt.consumeAutoStart(serverId: "other"))
        XCTAssertTrue(prompt.consumeAutoStart(serverId: "home"))
        XCTAssertFalse(prompt.consumeAutoStart(serverId: "home"), "once per request")
        XCTAssertFalse(SelectAccountPrompt(defaults: defaults).consumeAutoStart(serverId: "home"),
            "a relaunch never opens a browser by itself")

        prompt.clear(serverId: "home")
        XCTAssertFalse(prompt.isRequested(serverId: "home"))

        // A login screen dropped before its sign-in finished hands the
        // auto-start back to the screen that replaces it, but never after a
        // sign-in succeeded.
        prompt.request(serverId: "home", autoStart: true)
        XCTAssertTrue(prompt.consumeAutoStart(serverId: "home"))
        prompt.restoreAutoStart(serverId: "home")
        XCTAssertTrue(prompt.consumeAutoStart(serverId: "home"), "handed back")
        prompt.clear(serverId: "home")
        prompt.restoreAutoStart(serverId: "home")
        XCTAssertFalse(prompt.consumeAutoStart(serverId: "home"), "not after a successful sign-in")

        let switchable = SignInOptions(browserProviders: [Self.provider()], acceptsPasswords: false, supportsSelectAccount: true)
        let older = SignInOptions(browserProviders: [Self.provider()], acceptsPasswords: false, supportsSelectAccount: false)
        XCTAssertTrue(LoginViewModel.asksToSelectAccount(options: switchable, choosingAccount: false, afterSignOut: true))
        XCTAssertTrue(LoginViewModel.asksToSelectAccount(options: switchable, choosingAccount: true, afterSignOut: false))
        XCTAssertFalse(LoginViewModel.asksToSelectAccount(options: switchable, choosingAccount: false, afterSignOut: false))
        XCTAssertFalse(LoginViewModel.asksToSelectAccount(options: older, choosingAccount: true, afterSignOut: true),
            "never sent to a server that does not advertise it")
        XCTAssertFalse(LoginViewModel.asksToSelectAccount(options: nil, choosingAccount: true, afterSignOut: true))
    }

    func testProviderLabelsAndIcons() {
        XCTAssertEqual(SignInOptions.buttonTitle(for: Self.provider(name: "Keycloak")), "Sign in with Keycloak")
        XCTAssertEqual(SignInOptions.buttonTitle(for: Self.provider(name: "Sign in with Keycloak")), "Sign in with Keycloak")
        XCTAssertEqual(SignInOptions.providerName(for: Self.provider(name: "Sign in with Keycloak")), "Keycloak")
        XCTAssertEqual(SignInOptions.providerName(for: Self.provider(name: "authentik")), "authentik")

        var withIcon = Self.provider()
        withIcon.iconUrl = "/api/v2/plugin-content/plugins/5/assets/sso.svg"
        XCTAssertEqual(SignInOptions.iconURL(for: withIcon, serverURL: "http://192.0.2.10:8432/")?.absoluteString,
            "http://192.0.2.10:8432/api/v2/plugin-content/plugins/5/assets/sso.svg")
        withIcon.iconUrl = "file:///etc/passwd"
        XCTAssertNil(SignInOptions.iconURL(for: withIcon, serverURL: "https://silo.example.test"))
    }

    // MARK: PKCE and the start URL

    func testPKCEVerifierAndS256Challenge() {
        // RFC 7636 appendix B.
        XCTAssertEqual(NativeSignInPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
            "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let a = NativeSignInPKCE.randomToken()
        let b = NativeSignInPKCE.randomToken()
        XCTAssertEqual(a.count, 43)
        XCTAssertTrue(a.unicodeScalars.allSatisfy(unreserved.contains))
        XCTAssertNotEqual(a, b)
    }

    func testStartURLCarriesTheChallengeStateAndTicket() throws {
        let base = try XCTUnwrap(URL(string: Self.startURL + "?keep=1&app_state=server-chosen"))
        let url = try XCTUnwrap(NativeSignInPKCE.startURL(base: base, challenge: "ch", appState: "st", linkTicket: "tk"))
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let values = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { $1 })
        XCTAssertEqual(values, ["keep": "1", "code_challenge": "ch", "code_challenge_method": "S256",
            "app_state": "st", "link_ticket": "tk"])
        XCTAssertEqual(items.filter { $0.name == "app_state" }.count, 1, "the client's state replaces any other")
        XCTAssertEqual(url.host, "silo.example.test")

        let switching = try XCTUnwrap(NativeSignInPKCE.startURL(base: base, challenge: "ch", appState: "st",
            prompt: NativeSignInPKCE.selectAccountPrompt))
        let switchingItems = try XCTUnwrap(URLComponents(url: switching, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(switchingItems.first { $0.name == "prompt" }?.value, "select_account")
        XCTAssertNil(items.first { $0.name == "prompt" }, "no prompt unless asked")
    }

    // MARK: The app redirect

    private static func callback(_ items: [String: String]) -> URL {
        var components = URLComponents()
        components.scheme = NativeSignIn.callbackScheme
        components.path = NativeSignIn.callbackPath
        components.queryItems = items.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return components.url!
    }

    func testCallbackRequiresTheFlowsStateTheSavedServerAndTheStartOrigin() throws {
        func parse(_ items: [String: String], omitIssuer: Bool = false) throws -> NativeSignInCallback {
            var items = items
            if items["iss"] == nil { items["iss"] = Self.origin }
            if omitIssuer { items["iss"] = nil }
            return try NativeSignInCallback.parse(Self.callback(items), expectedState: "st", expectedServerId: Self.serverId,
                expectedIssuer: Self.origin)
        }
        XCTAssertEqual(try parse(["code": "c", "state": "st", "server": Self.serverId]), .code("c", link: false))
        XCTAssertEqual(try parse(["code": "c", "link": "1", "state": "st", "server": Self.serverId]), .code("c", link: true))
        XCTAssertEqual(try parse(["error": "email_in_use", "state": "st", "server": Self.serverId]),
            .failure(reason: "email_in_use"))
        // The origin compares as an origin: case and a default port differ
        // only in spelling.
        XCTAssertEqual(try parse(["code": "c", "state": "st", "server": Self.serverId, "iss": "HTTPS://Silo.Example.Test:443"]),
            .code("c", link: false))

        let refusals: [([String: String], ExternalSignInError)] = [
            (["code": "c", "state": "other", "server": Self.serverId], .stateMismatch),
            (["code": "c", "server": Self.serverId], .stateMismatch),
            (["code": "c", "state": "st", "server": "another-server"], .serverMismatch),
            (["code": "c", "state": "st"], .serverMismatch),
            // A forged error is not believed without the flow's state.
            (["error": "not_permitted", "state": "forged", "server": Self.serverId], .stateMismatch),
            (["state": "st", "server": Self.serverId], .incompleteCallback),
            // Another origin finished the flow, or the server did not say.
            (["code": "c", "state": "st", "server": Self.serverId, "iss": "https://other.example.test"], .issuerMismatch),
            (["code": "c", "state": "st", "server": Self.serverId, "iss": "https://silo.example.test:8443"], .issuerMismatch),
            (["code": "c", "state": "st", "server": Self.serverId, "iss": "http://silo.example.test"], .issuerMismatch),
            (["code": "c", "state": "st", "server": Self.serverId, "iss": "https://silo.example.test/api"], .issuerMismatch),
            (["code": "c", "state": "st", "server": Self.serverId, "iss": ""], .issuerMismatch),
            (["error": "not_permitted", "state": "st", "server": Self.serverId, "iss": ""], .issuerMismatch),
        ]
        for (items, expected) in refusals {
            XCTAssertThrowsError(try parse(items), "\(items)") { XCTAssertEqual($0 as? ExternalSignInError, expected) }
        }
        for items in [["code": "c", "state": "st", "server": Self.serverId],
                      ["error": "not_permitted", "state": "st", "server": Self.serverId]] {
            XCTAssertThrowsError(try parse(items, omitIssuer: true), "no iss: \(items)") {
                XCTAssertEqual($0 as? ExternalSignInError, .issuerMismatch)
            }
        }
        XCTAssertEqual(ExternalSignInError.issuerMismatch.message,
            "This sign-in came back from a different server. Nothing was signed in.")
        let deepLink = try XCTUnwrap(URL(string: "silo://auth/callback?code=c&state=st&server=\(Self.serverId)"))
        XCTAssertFalse(NativeSignIn.isCallback(deepLink), "silo:// deep links are not the sign-in redirect")
        XCTAssertThrowsError(try NativeSignInCallback.parse(deepLink, expectedState: "st", expectedServerId: Self.serverId,
            expectedIssuer: Self.origin))
        let otherPath = try XCTUnwrap(URL(string: "org.siloserver.silo:/other?code=c&state=st&server=\(Self.serverId)"))
        XCTAssertThrowsError(try NativeSignInCallback.parse(otherPath, expectedState: "st", expectedServerId: Self.serverId,
            expectedIssuer: Self.origin)) {
            XCTAssertEqual($0 as? ExternalSignInError, .incompleteCallback)
        }
    }

    func testFailureReasonsReadAsCopyNeverCodes() {
        let reasons = ["not_permitted", "email_in_use", "identity_linked_elsewhere", "account_disabled",
                       "provider_unavailable", "state_invalid", "session_expired", "account_required"]
        let texts = reasons.map(ExternalSignInError.reasonText)
        XCTAssertEqual(Set(texts).count, reasons.count, "each reason has its own copy")
        for (reason, text) in zip(reasons, texts) {
            XCTAssertFalse(text.contains(reason), reason)
            XCTAssertNotEqual(text, ExternalSignInError.reasonText("something_new"), reason)
        }
        XCTAssertEqual(ExternalSignInError.reasonText("email_in_use"),
            "An account with this email already exists. Ask an admin to connect it to the sign-in provider.")
        XCTAssertEqual(ExternalSignInError.reasonText("account_required"),
            "You don't have an account on this server yet. Ask an admin to add you.")
        XCTAssertNil(LoginViewModel.browserSignInMessage(for: ExternalSignInError.canceled))
        XCTAssertEqual(LoginViewModel.browserSignInMessage(for: ExternalSignInError.provider(reason: "not_permitted")),
            ExternalSignInError.reasonText("not_permitted"))
    }

    func testPasswordLoginRefusalsFromExternalSignIn() {
        func problem(_ id: String, _ status: Int) -> Error {
            APIv2Error.problem(APIv2Problem(type: "https://siloserver.org/docs/api/v2/problems/\(id)", title: "t",
                status: status, detail: "server detail", instance: nil, errors: nil))
        }
        #if os(tvOS)
        XCTAssertEqual(LoginViewModel.message(for: problem("local_login_disabled", 403)),
            "Password sign-in is turned off on this server. Use your phone instead.")
        // A server without device sign-in: the screen offers no phone route,
        // so the refusal does not point there.
        XCTAssertEqual(LoginViewModel.message(for: problem("local_login_disabled", 403), offersPhoneRoute: false),
            "Password sign-in is turned off on this server.")
        #else
        XCTAssertEqual(LoginViewModel.message(for: problem("local_login_disabled", 403)),
            "Password sign-in is turned off on this server.")
        XCTAssertEqual(LoginViewModel.message(for: problem("local_login_disabled", 403),
            browserProviders: [Self.provider(name: "Sign in with Keycloak")]),
            "Password sign-in is turned off on this server. Sign in with Keycloak instead.")
        #endif
        XCTAssertEqual(LoginViewModel.message(for: problem("password_expired", 403)),
            ExternalSignInError.reasonText("password_expired"), "one copy on every path")
        XCTAssertEqual(LoginViewModel.message(for: problem("not_permitted", 403)),
            ExternalSignInError.reasonText("not_permitted"))
        XCTAssertEqual(LoginViewModel.message(for: problem("account_required", 403)),
            ExternalSignInError.reasonText("account_required"))
        XCTAssertEqual(ExternalSignInError.completionError(problem("account_required", 403)) as? ExternalSignInError,
            .provider(reason: "account_required"))
        XCTAssertEqual(LoginViewModel.message(for: problem("provider_unavailable", 503)),
            ExternalSignInError.reasonText("provider_unavailable"))
        XCTAssertEqual(LoginViewModel.message(for: problem("forbidden", 403)),
            "This account can't sign in. Contact your server administrator.")
        XCTAssertEqual(LoginViewModel.message(for: problem("invalid_token", 401)), "Incorrect username or password.")
    }

    // MARK: The handshake end to end

    private final class FakeRunner: WebAuthenticationRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var opened: [URL] = []
        private let answer: @Sendable (URL) throws -> URL
        /// Runs while the sheet is open, before the redirect comes back:
        /// what the app might do meanwhile (switch server, sign in elsewhere).
        private let whileOpen: (@Sendable () async throws -> Void)?

        init(whileOpen: (@Sendable () async throws -> Void)? = nil, _ answer: @escaping @Sendable (URL) throws -> URL) {
            self.whileOpen = whileOpen
            self.answer = answer
        }

        var startURLs: [URL] { lock.withLock { opened } }

        @MainActor func authenticate(url: URL, callbackScheme: String) async throws -> URL {
            XCTAssertEqual(callbackScheme, "org.siloserver.silo")
            lock.withLock { opened.append(url) }
            try await whileOpen?()
            return try answer(url)
        }

        /// The redirect a server would send for `start`: the start's own
        /// `app_state` echoed as `state`, the origin where the start arrived
        /// as `iss` (unless `items` names one, or `omitIssuer`), plus `items`.
        static func echo(_ start: URL, _ items: [String: String], state: String? = nil,
                         omitIssuer: Bool = false) -> URL {
            let query = URLComponents(url: start, resolvingAgainstBaseURL: false)?.queryItems ?? []
            var merged = items
            merged["state"] = state ?? query.first { $0.name == "app_state" }?.value
            merged["iss"] = omitIssuer ? nil : items["iss"] ?? NativeSignIn.origin(of: start)
            return ExternalSignInTests.callback(merged)
        }
    }

    private final class Installed: @unchecked Sendable {
        private let lock = NSLock()
        private var value: [APIv2OAuthCompletion] = []
        var sessions: [APIv2OAuthCompletion] { lock.withLock { value } }
        func add(_ tokens: APIv2OAuthCompletion) { lock.withLock { value.append(tokens) } }
    }

    /// A service over an isolated token store whose saved server is at
    /// `savedURL`. Installs are recorded, not made.
    private func makeService(
        runner: FakeRunner, serverId: String? = serverId, signedIn: Bool = false, savedURL: String = origin
    ) async throws -> (ExternalSignInService, Installed, TokenStore) {
        let name = "ExternalSignInTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        addTeardownBlock {
            _ = await tokens.clearTokens()
            UserDefaults().removePersistentDomain(forName: name)
        }
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl(savedURL)
        if signedIn {
            try await tokens.installAccountSession(accessToken: "acc", refreshToken: "ref", accountID: "1")
        }
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        let api = APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false })
        let installed = Installed()
        let service = ExternalSignInService(api: api, tokenStore: tokens, runner: runner,
            verifiedServerId: { serverId },
            installSession: { completion, _ in installed.add(completion) })
        return (service, installed, tokens)
    }

    private func body(_ request: StubURLProtocol.Request?) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request?.body)) as? [String: String])
    }

    func testSignInRedeemsTheCodeWithTheVerifierOfItsChallenge() async throws {
        let runner = FakeRunner { FakeRunner.echo($0, ["code": "one-time", "server": Self.serverId]) }
        let (service, installed, _) = try await makeService(runner: runner)
        stub.reply(path: APIv2Client.oauthCompletePath, 200,
            Support.text(named: "complete_oauth_login_native_ok", bundleClass: Self.self))

        try await service.signIn(with: Self.provider())

        let start = try XCTUnwrap(runner.startURLs.first)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: start, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        XCTAssertTrue(start.absoluteString.hasPrefix(Self.startURL + "?"))
        XCTAssertEqual(query["code_challenge_method"], "S256")
        XCTAssertEqual(query["app_state"]?.count, 43)
        XCTAssertNil(query["link_ticket"])

        XCTAssertEqual(stub.requestedPaths, [APIv2Client.oauthCompletePath])
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.url?.host, "silo.example.test")
        XCTAssertNil(request.header("authorization"), "completeOAuthLogin is public")
        let sent = try body(request)
        XCTAssertEqual(sent["code"], "one-time")
        let verifier = try XCTUnwrap(sent["code_verifier"])
        XCTAssertEqual(NativeSignInPKCE.challenge(for: verifier), query["code_challenge"])
        XCTAssertNotEqual(verifier, query["app_state"], "state and verifier are independent")
        XCTAssertEqual(installed.sessions.map(\.user.id), ["1"])
        XCTAssertNil(query["prompt"])
    }

    func testSwitchAccountSignInAsksTheProviderToChoose() async throws {
        let runner = FakeRunner { FakeRunner.echo($0, ["code": "one-time", "server": Self.serverId]) }
        let (service, installed, _) = try await makeService(runner: runner)
        stub.reply(path: APIv2Client.oauthCompletePath, 200,
            Support.text(named: "complete_oauth_login_native_ok", bundleClass: Self.self))

        try await service.signIn(with: Self.provider(), selectAccount: true)

        let start = try XCTUnwrap(runner.startURLs.first)
        let prompt = URLComponents(url: start, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "prompt" }
        XCTAssertEqual(prompt?.value, "select_account")
        XCTAssertEqual(installed.sessions.count, 1)
    }

    func testMismatchedRedirectsAndProviderErrorsRedeemNothing() async throws {
        let cases: [(String, @Sendable (URL) -> URL, ExternalSignInError)] = [
            ("state", { FakeRunner.echo($0, ["code": "c", "server": ExternalSignInTests.serverId], state: "stolen") }, .stateMismatch),
            ("server", { FakeRunner.echo($0, ["code": "c", "server": "other-server"]) }, .serverMismatch),
            ("error", { FakeRunner.echo($0, ["error": "not_permitted", "server": ExternalSignInTests.serverId]) },
                .provider(reason: "not_permitted")),
            ("link code on sign-in", { FakeRunner.echo($0, ["code": "c", "link": "1", "server": ExternalSignInTests.serverId]) },
                .incompleteCallback),
            ("no iss", { FakeRunner.echo($0, ["code": "c", "server": ExternalSignInTests.serverId], omitIssuer: true) },
                .issuerMismatch),
            ("no iss on an error", { FakeRunner.echo($0, ["error": "not_permitted", "server": ExternalSignInTests.serverId],
                omitIssuer: true) }, .issuerMismatch),
            ("empty iss", { FakeRunner.echo($0, ["code": "c", "server": ExternalSignInTests.serverId, "iss": ""]) },
                .issuerMismatch),
        ]
        for (name, answer, expected) in cases {
            stub.reset()
            let (service, installed, _) = try await makeService(runner: FakeRunner(answer))
            do {
                try await service.signIn(with: Self.provider())
                XCTFail("\(name): accepted")
            } catch {
                XCTAssertEqual(error as? ExternalSignInError, expected, name)
            }
            XCTAssertTrue(stub.requests.isEmpty, "\(name): nothing redeemed")
            XCTAssertTrue(installed.sessions.isEmpty, name)
        }
    }

    /// What can change on the app's token store while the sign-in sheet is
    /// open: another saved server becomes active, the active server's
    /// address changes, or another account signs in.
    private static let identityChanges: [(String, @Sendable (TokenStore) async throws -> Void)] = [
        ("another server", { await $0.switchActiveServer(serverId: "other-server") }),
        ("another address", { await $0.setServerUrl("https://elsewhere.example.test") }),
        ("another account", {
            try await $0.installAccountSession(accessToken: "other-acc", refreshToken: "other-ref", accountID: "2")
        }),
    ]

    /// Hands the token store `makeService` creates to a runner built before it.
    private final class StoreBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: TokenStore?
        var store: TokenStore? {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// The code from a browser flow belongs to the server and account that
    /// started it. When the active server, its address, or the signed-in
    /// account changes while the sheet is open, a valid redirect still
    /// redeems nothing and installs nothing.
    func testSignInRedeemsNothingWhenTheActiveIdentityChangesWhileTheBrowserIsOpen() async throws {
        for (name, change) in Self.identityChanges {
            stub.reset()
            let box = StoreBox()
            let runner = FakeRunner(whileOpen: { try await change(XCTUnwrap(box.store)) }) {
                FakeRunner.echo($0, ["code": "one-time", "server": ExternalSignInTests.serverId])
            }
            let (service, installed, tokens) = try await makeService(runner: runner)
            box.store = tokens
            stub.reply(path: APIv2Client.oauthCompletePath, 200,
                Support.text(named: "complete_oauth_login_native_ok", bundleClass: Self.self))
            do {
                try await service.signIn(with: Self.provider())
                XCTFail("\(name): signed in")
            } catch HTTPError.requestIdentityChanged {
            } catch {
                XCTFail("\(name): \(error)")
            }
            XCTAssertEqual(runner.startURLs.count, 1, name)
            XCTAssertTrue(stub.requests.isEmpty, "\(name): the code went nowhere")
            XCTAssertTrue(installed.sessions.isEmpty, name)
        }
    }

    func testMissingServerIdentityStopsBeforeTheBrowser() async throws {
        let runner = FakeRunner { _ in XCTFail("browser opened"); throw ExternalSignInError.canceled }
        let (service, _, _) = try await makeService(runner: runner, serverId: nil)
        do {
            try await service.signIn(with: Self.provider())
            XCTFail("signed in without a server identity")
        } catch {
            XCTAssertEqual(error as? ExternalSignInError, .serverIdentityUnavailable)
        }
        XCTAssertTrue(runner.startURLs.isEmpty)
    }

    func testCompletionRefusalsMapToCopyAndInstallNothing() async throws {
        let cases: [(String, Int, ExternalSignInError)] = [
            ("complete_oauth_login_invalid_grant", 400, .provider(reason: "state_invalid")),
            ("authentication_required", 401, .provider(reason: "session_expired")),
        ]
        for (fixtureName, status, expected) in cases {
            stub.reset()
            let runner = FakeRunner { FakeRunner.echo($0, ["code": "c", "server": Self.serverId]) }
            let (service, installed, _) = try await makeService(runner: runner)
            var problem = Support.text(named: fixtureName, bundleClass: Self.self)
            if status == 401 {
                problem = #"{"type":"https://siloserver.org/docs/api/v2/problems/invalid_token","title":"t","status":401,"detail":"d"}"#
            }
            stub.reply(path: APIv2Client.oauthCompletePath, status, problem)
            do {
                try await service.signIn(with: Self.provider())
                XCTFail("\(fixtureName): accepted")
            } catch {
                XCTAssertEqual(error as? ExternalSignInError, expected, fixtureName)
            }
            XCTAssertEqual(stub.requestedPaths, [APIv2Client.oauthCompletePath], "\(fixtureName): one dispatch, no replay")
            XCTAssertTrue(installed.sessions.isEmpty, fixtureName)
        }
    }

    // MARK: Everything happens on the saved base

    private static let hostile = "https://hostile.example.test"

    /// A hostile saved server answers the native start on its own origin by
    /// sending the browser on to the real server's native start with the
    /// app's challenge and state. The real server records where the start
    /// reached it, its own origin, and sends that as `iss` with its own id
    /// (which the hostile server also claims), so the app keeps the code: it
    /// is sent nowhere. The app opened the start on the hostile (saved)
    /// origin.
    func testRelayedStartIsRefusedAndTheCodeIsSentNowhere() async throws {
        let relayed = FakeRunner { FakeRunner.echo($0, ["code": "real-code", "server": Self.serverId, "iss": Self.origin]) }
        var (service, installed, _) = try await makeService(runner: relayed, savedURL: Self.hostile)
        do {
            try await service.signIn(with: Self.provider())
            XCTFail("a relayed sign-in was accepted")
        } catch {
            XCTAssertEqual(error as? ExternalSignInError, .issuerMismatch)
            XCTAssertEqual(LoginViewModel.browserSignInMessage(for: error),
                "This sign-in came back from a different server. Nothing was signed in.")
        }
        XCTAssertEqual(relayed.startURLs.compactMap { NativeSignIn.origin(of: $0) }, [Self.hostile])
        XCTAssertTrue(stub.requests.isEmpty, "the code and verifier went nowhere")
        XCTAssertTrue(installed.sessions.isEmpty)

        // The same for a linking flow: only the ticket request was made.
        stub.reset()
        let relayedLink = FakeRunner { FakeRunner.echo($0, ["code": "real-code", "link": "1", "server": Self.serverId,
            "iss": Self.origin]) }
        (service, _, _) = try await makeService(runner: relayedLink, signedIn: true, savedURL: Self.hostile)
        stub.reply(path: APIv2Client.identityLinkTicketPath, 200,
            Support.text(named: "create_account_identity_link_ticket_ok", bundleClass: Self.self))
        do {
            try await service.link(provider: Self.provider(), password: "p")
            XCTFail("a relayed link was accepted")
        } catch {
            XCTAssertEqual(error as? ExternalSignInError, .issuerMismatch)
        }
        XCTAssertEqual(stub.requestedPaths, [APIv2Client.identityLinkTicketPath])
    }

    /// A server saved by its LAN address signs in on that address even when
    /// it also has a public URL: the start opens on the saved base, the code
    /// comes back with the saved origin as `iss`, and it is redeemed at the
    /// saved base.
    func testSignInStaysOnTheSavedBase() async throws {
        let lan = "http://192.168.1.5:8096"
        let runner = FakeRunner { FakeRunner.echo($0, ["code": "one-time", "server": Self.serverId]) }
        let (service, installed, _) = try await makeService(runner: runner, savedURL: lan)
        stub.reply(path: APIv2Client.oauthCompletePath, 200,
            Support.text(named: "complete_oauth_login_native_ok", bundleClass: Self.self))

        try await service.signIn(with: Self.provider())

        let start = try XCTUnwrap(runner.startURLs.first)
        XCTAssertEqual(NativeSignIn.origin(of: start), lan, "the browser opened the saved base")
        XCTAssertEqual(start.path, Self.startPath)
        XCTAssertEqual(stub.requestedPaths, [APIv2Client.oauthCompletePath])
        XCTAssertEqual(stub.requests.map { $0.url?.host }, ["192.168.1.5"], "redeemed at the saved base")
        XCTAssertEqual(installed.sessions.map(\.user.id), ["1"])

        // A redirect whose `iss` names the server's public origin rather than
        // the saved one is refused, even though that is the same server.
        stub.reset()
        let publicIss = FakeRunner { FakeRunner.echo($0, ["code": "one-time", "server": Self.serverId, "iss": Self.origin]) }
        let (refusing, refused, _) = try await makeService(runner: publicIss, savedURL: lan)
        do {
            try await refusing.signIn(with: Self.provider())
            XCTFail("accepted an iss that is not the saved origin")
        } catch {
            XCTAssertEqual(error as? ExternalSignInError, .issuerMismatch)
        }
        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertTrue(refused.sessions.isEmpty)
    }

    /// `native_start_path` becomes a start on the saved base: only its
    /// `/api/v2/auth/oauth/<id>/native/start` suffix and its query survive,
    /// under the saved base's own path prefix. A provider without it, or with
    /// one of another shape, offers no browser sign-in.
    func testNativeStartResolvesAgainstTheSavedBase() throws {
        func resolved(_ provider: APIv2AuthProvider, on saved: String) -> String? {
            SignInOptions.nativeStart(of: provider).flatMap { NativeSignIn.startURL($0, onServer: saved) }?.absoluteString
        }
        let prefixed = Self.provider(startPath: "/silo/api/v2/auth/oauth/5/native/start?keep=1")
        XCTAssertEqual(resolved(prefixed, on: "http://192.168.1.5:8096"),
            "http://192.168.1.5:8096/api/v2/auth/oauth/5/native/start?keep=1", "the public prefix is not the LAN's")
        XCTAssertEqual(resolved(prefixed, on: "https://lan.example.test/media/"),
            "https://lan.example.test/media/api/v2/auth/oauth/5/native/start?keep=1", "the saved prefix is kept")
        XCTAssertEqual(resolved(Self.provider(), on: "HTTPS://Silo.Example.Test"),
            "HTTPS://Silo.Example.Test" + Self.startPath)
        XCTAssertEqual(resolved(Self.provider(), on: Self.hostile), Self.hostile + Self.startPath)

        let unusable: [APIv2AuthProvider] = [
            Self.provider(startPath: nil),
            Self.provider(startPath: "/somewhere/else"),
            Self.provider(startPath: "//evil.example.test" + Self.startPath),
            Self.provider(startPath: "https://evil.example.test" + Self.startPath),
            Self.provider(startPath: "/not/a/start"),
            Self.provider(startPath: Self.startPath + "#x"),
        ]
        for provider in unusable {
            XCTAssertNil(SignInOptions.nativeStart(of: provider), "\(provider)")
        }
        let options = SignInOptions(providers: APIv2AuthProviders(items: [Self.local] + unusable, passwordLogin: true),
            oauth: Self.native)
        XCTAssertTrue(options.browserProviders.isEmpty)

        let start = try XCTUnwrap(SignInOptions.nativeStart(of: Self.provider()))
        let ipv6 = try XCTUnwrap(NativeSignIn.startURL(start, onServer: "http://[FD00::5]:8096"))
        XCTAssertEqual(NativeSignIn.origin(of: ipv6), "http://[fd00::5]:8096")
        XCTAssertEqual(NativeSignIn.issuerOrigin("http://[fd00::5]:8096"), NativeSignIn.origin(ofServerURL: "http://[FD00::5]:8096/"))
        XCTAssertNil(NativeSignIn.startURL(start, onServer: "not a url"))
        XCTAssertNil(NativeSignIn.startURL(start, onServer: "https://silo.example.test/?x=1"))
    }

    /// A server saved behind a reverse proxy's path prefix: the browser opens
    /// the native start under that prefix, and the redirect's `iss` is the
    /// bare origin (an origin has no path), which is what the app expects.
    func testPathPrefixedSavedBaseSignsInAndExpectsTheBareOrigin() async throws {
        let saved = "https://lan.example.test/media"
        let completePath = "/media" + APIv2Client.oauthCompletePath
        let runner = FakeRunner { FakeRunner.echo($0, ["code": "one-time", "server": Self.serverId,
            "iss": "https://lan.example.test"]) }
        let (service, installed, _) = try await makeService(runner: runner, savedURL: saved)
        stub.reply(path: completePath, 200, Support.text(named: "complete_oauth_login_native_ok", bundleClass: Self.self))

        try await service.signIn(with: Self.provider())

        let start = try XCTUnwrap(runner.startURLs.first)
        XCTAssertTrue(start.absoluteString.hasPrefix("https://lan.example.test/media/api/v2/auth/oauth/3/native/start?"),
            start.absoluteString)
        XCTAssertEqual(stub.requestedPaths, [completePath])
        XCTAssertEqual(stub.requests.map { $0.url?.host }, ["lan.example.test"])
        XCTAssertEqual(installed.sessions.map(\.user.id), ["1"])

        // An `iss` that carries the prefix is not an origin.
        stub.reset()
        let withPath = FakeRunner { FakeRunner.echo($0, ["code": "one-time", "server": Self.serverId,
            "iss": "https://lan.example.test/media"]) }
        let (refusing, refused, _) = try await makeService(runner: withPath, savedURL: saved)
        do {
            try await refusing.signIn(with: Self.provider())
            XCTFail("accepted an iss with a path")
        } catch {
            XCTAssertEqual(error as? ExternalSignInError, .issuerMismatch)
        }
        XCTAssertTrue(stub.requests.isEmpty)
        XCTAssertTrue(refused.sessions.isEmpty)
    }

    /// The server builds `iss` from the `Host` the browser sent, and browsers
    /// write IPv6 compressed. A server saved with an uncompressed or
    /// zero-padded IPv6 literal still signs in.
    func testIPv6SavedBaseComparesInCompressedForm() async throws {
        XCTAssertEqual(NativeSignIn.origin(ofServerURL: "http://[fd00:0:0:0:0:0:0:5]:8096"), "http://[fd00::5]:8096")
        XCTAssertEqual(NativeSignIn.origin(ofServerURL: "http://[fd00::0005]:8096/"), "http://[fd00::5]:8096")
        XCTAssertEqual(NativeSignIn.origin(ofServerURL: "http://[0:0:0:0:0:0:0:1]"), "http://[::1]")
        XCTAssertEqual(NativeSignIn.issuerOrigin("HTTP://[FD00::5]:8096"), "http://[fd00::5]:8096")
        let compressed: [(String, String?)] = [
            ("2001:db8:0:0:1:0:0:1", "2001:db8::1:0:0:1"),
            ("1:0:0:2:0:0:0:3", "1:0:0:2::3"),
            ("1:2:3:4:5:6:7:0", "1:2:3:4:5:6:7:0"),
            ("0:0:0:0:0:0:0:0", "::"),
            ("fd00::", "fd00::"),
            ("::ffff:1.2.3.4", nil),
            ("1::2::3", nil),
            ("12345::1", nil),
            ("1:2:3:4:5:6:7", nil),
        ]
        for (literal, expected) in compressed {
            XCTAssertEqual(NativeSignIn.compressIPv6(literal), expected, literal)
        }

        for saved in ["http://[fd00:0:0:0:0:0:0:5]:8096", "http://[fd00::0005]:8096"] {
            stub.reset()
            let runner = FakeRunner { FakeRunner.echo($0, ["code": "one-time", "server": Self.serverId,
                "iss": "http://[fd00::5]:8096"]) }
            let (service, installed, _) = try await makeService(runner: runner, savedURL: saved)
            stub.reply(path: APIv2Client.oauthCompletePath, 200,
                Support.text(named: "complete_oauth_login_native_ok", bundleClass: Self.self))
            try await service.signIn(with: Self.provider())
            XCTAssertEqual(stub.requestedPaths, [APIv2Client.oauthCompletePath], saved)
            XCTAssertEqual(installed.sessions.map(\.user.id), ["1"], saved)
        }
    }

    /// The app's real registry, token store and `AuthService` over the stub,
    /// with the saved server at `lan` (keyed by that URL, as `checkServer`
    /// keys it) and active.
    @MainActor
    private func makeApp(lan: String) async throws -> AppHarness {
        let name = "ExternalSignInTests.app.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        let tokens = TokenStore(keychain: keychain, defaults: defaults)
        addTeardownBlock {
            _ = await tokens.clearTokens()
            UserDefaults().removePersistentDomain(forName: name)
        }
        defaults.set(true, forKey: ServerRegistry.migratedKey)
        let preferences = ProfileLaunchPreferences(defaults: defaults)
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        let registry = ServerRegistry(defaults: defaults, keychain: keychain, launchPreferences: preferences,
            tokenStore: tokens, httpClient: http)
        let lanId = ServerRegistry.serverId(for: lan)
        XCTAssertNotNil(registry.addOrUpdate(ServerEntry(id: lanId, url: lan, fetchedName: "Home",
            lastUsedAt: Date(), verifiedServerId: Self.serverId)))
        let switched = await registry.switchTo(serverId: lanId)
        XCTAssertTrue(switched)
        let api = APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false })
        let auth = AuthService(serverIdentityResolver: ServerIdentityResolver(httpClient: http), serverRegistry: registry,
            launchPreferences: preferences, contractProbe: APIv2Probe(httpClient: http), apiV2Client: api,
            httpClient: http, tokenStore: tokens, sessionPersistence: AccountSessionPersistence(keychain: keychain),
            purgeDiagnostics: { _ in true })
        return AppHarness(tokens: tokens, registry: registry, auth: auth, api: api)
    }

    private struct AppHarness {
        let tokens: TokenStore
        let registry: ServerRegistry
        let auth: AuthService
        let api: APIv2Client

        func service(_ runner: FakeRunner) -> ExternalSignInService {
            let auth = auth
            return ExternalSignInService(api: api, tokenStore: tokens, runner: runner,
                verifiedServerId: { ExternalSignInTests.serverId },
                installSession: { completion, account in
                    try await auth.installSession(accessToken: completion.accessToken, refreshToken: completion.refreshToken,
                        accountID: completion.user.id, expectedAccount: account)
                })
        }
    }

    /// The whole app path for a server saved by its LAN address whose
    /// discovery lists its public URL: sign-in and linking both run on the
    /// LAN address, and the saved server stays exactly where it was (same
    /// id, address, name and identity; no other entry appears).
    @MainActor
    func testLANSavedServerSignsInAndStaysOnItsLANAddress() async throws {
        let lan = "http://192.168.1.5:8096"
        let app = try await makeApp(lan: lan)
        let lanId = ServerRegistry.serverId(for: lan)
        let before = try XCTUnwrap(app.registry.activeServer)
        stub.reply(path: APIv2Client.oauthCompletePath, 200,
            Support.text(named: "complete_oauth_login_native_ok", bundleClass: Self.self))

        let signIn = FakeRunner { FakeRunner.echo($0, ["code": "one-time", "server": Self.serverId]) }
        try await app.service(signIn).signIn(with: Self.provider())

        XCTAssertEqual(signIn.startURLs.map { $0.host }, ["192.168.1.5"])
        XCTAssertEqual(stub.requests.map { $0.url?.host }, ["192.168.1.5"])
        XCTAssertEqual(app.registry.entries, [before], "the saved server did not move or duplicate")
        XCTAssertEqual(app.registry.activeServerId, lanId)
        XCTAssertTrue(app.auth.isLoggedIn)
        let account = await app.tokens.refreshAccountIdentity()
        XCTAssertEqual(account?.serverId, lanId)
        XCTAssertEqual(account?.serverURL, lan)
        let access = await app.tokens.getAccessToken()
        XCTAssertEqual(access, "acc")

        // Linking on the same saved server: ticket, browser start and the
        // bearer's confirmation all stay on the LAN address.
        stub.reset()
        stub.reply(path: APIv2Client.identityLinkTicketPath, 200,
            Support.text(named: "create_account_identity_link_ticket_ok", bundleClass: Self.self))
        stub.reply(path: APIv2Client.identityLinkCompletePath, 204, "")
        let link = FakeRunner { FakeRunner.echo($0, ["code": "link-code", "link": "1", "server": Self.serverId]) }
        try await app.service(link).link(provider: Self.provider(), password: "local-pass")

        XCTAssertEqual(link.startURLs.map { $0.host }, ["192.168.1.5"])
        XCTAssertEqual(stub.requests.map(\.path), [APIv2Client.identityLinkTicketPath, APIv2Client.identityLinkCompletePath])
        XCTAssertEqual(stub.requests.map { $0.url?.host }, ["192.168.1.5", "192.168.1.5"])
        XCTAssertEqual(stub.requests.last?.header("authorization"), "Bearer acc")
        XCTAssertEqual(app.registry.entries, [before])
        XCTAssertTrue(app.auth.isLoggedIn)
    }

    // MARK: Linking

    func testLinkSpendsAPasswordTicketAndConfirmsTheCodeWithTheVerifier() async throws {
        let runner = FakeRunner { FakeRunner.echo($0, ["code": "link-code", "link": "1", "server": Self.serverId]) }
        let (service, installed, _) = try await makeService(runner: runner, signedIn: true)
        stub.reply(path: APIv2Client.identityLinkTicketPath, 200,
            Support.text(named: "create_account_identity_link_ticket_ok", bundleClass: Self.self))
        stub.reply(path: APIv2Client.identityLinkCompletePath, 204, "")

        try await service.link(provider: Self.provider(), password: "local-pass")

        XCTAssertEqual(stub.requestedPaths, [APIv2Client.identityLinkTicketPath, APIv2Client.identityLinkCompletePath])
        let ticketRequest = stub.requests[0]
        XCTAssertEqual(ticketRequest.header("authorization"), "Bearer acc")
        XCTAssertNil(ticketRequest.header("x-profile-id"), "account-scoped")
        XCTAssertEqual(try body(ticketRequest), ["installation_id": "3", "password": "local-pass"])

        let start = try XCTUnwrap(runner.startURLs.first)
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: start, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .map { ($0.name, $0.value ?? "") })
        let ticket = try decode(APIv2IdentityLinkTicket.self, "create_account_identity_link_ticket_ok").ticket
        XCTAssertEqual(query["link_ticket"], ticket)

        let confirm = stub.requests[1]
        XCTAssertEqual(confirm.header("authorization"), "Bearer acc")
        let sent = try body(confirm)
        XCTAssertEqual(sent["code"], "link-code")
        XCTAssertEqual(NativeSignInPKCE.challenge(for: try XCTUnwrap(sent["code_verifier"])), query["code_challenge"])
        XCTAssertTrue(installed.sessions.isEmpty, "linking opens no session")
    }

    /// A link code confirms a link for the account that bought the ticket.
    /// When the active server, its address, or the signed-in account changes
    /// while the sheet is open, nothing is confirmed and no session opens.
    func testLinkConfirmsNothingWhenTheActiveIdentityChangesWhileTheBrowserIsOpen() async throws {
        for (name, change) in Self.identityChanges {
            stub.reset()
            let box = StoreBox()
            let runner = FakeRunner(whileOpen: { try await change(XCTUnwrap(box.store)) }) {
                FakeRunner.echo($0, ["code": "link-code", "link": "1", "server": ExternalSignInTests.serverId])
            }
            let (service, installed, tokens) = try await makeService(runner: runner, signedIn: true)
            box.store = tokens
            stub.reply(path: APIv2Client.identityLinkTicketPath, 200,
                Support.text(named: "create_account_identity_link_ticket_ok", bundleClass: Self.self))
            stub.reply(path: APIv2Client.identityLinkCompletePath, 204, "")
            do {
                try await service.link(provider: Self.provider(), password: "p")
                XCTFail("\(name): linked")
            } catch HTTPError.requestIdentityChanged {
            } catch {
                XCTFail("\(name): \(error)")
            }
            XCTAssertEqual(runner.startURLs.count, 1, name)
            XCTAssertEqual(stub.requestedPaths, [APIv2Client.identityLinkTicketPath], "\(name): no link-complete")
            XCTAssertTrue(installed.sessions.isEmpty, name)
        }
    }

    func testLinkRefusesASignInCodeAndMapsLinkRefusals() async throws {
        let signInCode = FakeRunner { FakeRunner.echo($0, ["code": "c", "server": Self.serverId]) }
        var (service, _, _) = try await makeService(runner: signInCode, signedIn: true)
        stub.reply(path: APIv2Client.identityLinkTicketPath, 200,
            Support.text(named: "create_account_identity_link_ticket_ok", bundleClass: Self.self))
        do {
            try await service.link(provider: Self.provider(), password: "p")
            XCTFail("a sign-in code was taken as a link")
        } catch {
            XCTAssertEqual(error as? ExternalSignInError, .incompleteCallback)
        }
        XCTAssertEqual(stub.requestedPaths, [APIv2Client.identityLinkTicketPath])

        stub.reset()
        let elsewhere = FakeRunner { FakeRunner.echo($0, ["error": "identity_linked_elsewhere", "server": Self.serverId]) }
        (service, _, _) = try await makeService(runner: elsewhere, signedIn: true)
        stub.reply(path: APIv2Client.identityLinkTicketPath, 200,
            Support.text(named: "create_account_identity_link_ticket_ok", bundleClass: Self.self))
        do {
            try await service.link(provider: Self.provider(), password: "p")
            XCTFail("linked")
        } catch {
            XCTAssertEqual(error as? ExternalSignInError, .provider(reason: "identity_linked_elsewhere"))
            XCTAssertEqual(AccountSignInModel.message(for: error, action: .connect),
                "That provider account is already connected to another account.")
        }

        stub.reset()
        let wrongVerifier = FakeRunner { FakeRunner.echo($0, ["code": "c", "link": "1", "server": Self.serverId]) }
        (service, _, _) = try await makeService(runner: wrongVerifier, signedIn: true)
        stub.reply(path: APIv2Client.identityLinkTicketPath, 200,
            Support.text(named: "create_account_identity_link_ticket_ok", bundleClass: Self.self))
        stub.reply(path: APIv2Client.identityLinkCompletePath, 400,
            Support.text(named: "complete_account_identity_link_invalid_grant", bundleClass: Self.self))
        do {
            try await service.link(provider: Self.provider(), password: "p")
            XCTFail("linked")
        } catch {
            XCTAssertEqual(error as? ExternalSignInError, .provider(reason: "state_invalid"))
        }
    }

    /// Linking checks the saved server's identity before the password check
    /// buys a ticket: without one the flow could not finish, and the person
    /// would type the password again for nothing.
    func testLinkWithoutServerIdentitySpendsNoPasswordCheck() async throws {
        let runner = FakeRunner { _ in XCTFail("browser opened"); throw ExternalSignInError.canceled }
        let (service, _, _) = try await makeService(runner: runner, serverId: nil, signedIn: true)
        stub.reply(path: APIv2Client.identityLinkTicketPath, 200,
            Support.text(named: "create_account_identity_link_ticket_ok", bundleClass: Self.self))
        do {
            try await service.link(provider: Self.provider(), password: "p")
            XCTFail("linked without a server identity")
        } catch {
            XCTAssertEqual(error as? ExternalSignInError, .serverIdentityUnavailable)
        }
        XCTAssertTrue(stub.requests.isEmpty, "no ticket was requested")
        XCTAssertTrue(runner.startURLs.isEmpty)
    }

    func testLinkTicketIsNeverReplayedAfterA401() async throws {
        let runner = FakeRunner { _ in XCTFail("browser opened"); throw ExternalSignInError.canceled }
        let (service, _, _) = try await makeService(runner: runner, signedIn: true)
        stub.reply(path: HTTPClient.refreshPath, 200, #"{"access_token":"new","refresh_token":"new-ref","expires_in":3600}"#)
        stub.reply(path: APIv2Client.identityLinkTicketPath, 401,
            #"{"type":"https://siloserver.org/docs/api/v2/problems/invalid_token","title":"t","status":401,"detail":"d"}"#)
        do {
            try await service.link(provider: Self.provider(), password: "p")
            XCTFail("linked")
        } catch {}
        XCTAssertEqual(stub.requestedPaths.filter { $0 == APIv2Client.identityLinkTicketPath }.count, 1,
            "a spent password re-check is not re-sent")
    }

    func testWrongPasswordAndLastSignInMethodCopy() throws {
        let wrong = APIv2Error.problem(try decode(APIv2Problem.self, "create_account_identity_link_ticket_wrong_password"))
        XCTAssertEqual(AccountSignInModel.message(for: wrong, action: .connect), "That Silo password is incorrect.")
        let last = APIv2Error.problem(try decode(APIv2Problem.self, "delete_account_identity_last_sign_in_method"))
        XCTAssertEqual(AccountSignInModel.message(for: last, action: .disconnect),
            "This is your only way to sign in, so it can't be disconnected. Ask an administrator to set a password for your account first.")
    }

    func testConnectableProvidersFollowLinkingSupport() {
        let oidc = Self.provider()
        let ldap = Self.provider(id: "plugin:6:ldap", name: "Directory", mode: "credentials", installation: "6", startPath: nil)
        let all = AccountSignInModel.connectable(providers: [Self.local, oidc, ldap], oauth: Self.native,
            credentialsLinking: true, linked: [])
        XCTAssertEqual(all.map(\.id), [oidc.id, ldap.id])
        XCTAssertEqual(all.map(\.method), [.browser, .directory])

        // A server without credentials linking hides LDAP Connect; one
        // without app linking hides OIDC Connect.
        XCTAssertEqual(AccountSignInModel.connectable(providers: [oidc, ldap], oauth: Self.native,
            credentialsLinking: false, linked: []).map(\.id), [oidc.id])
        XCTAssertEqual(AccountSignInModel.connectable(providers: [oidc, ldap], oauth:
            APIv2OAuthCapabilities(state: "available", native: true, linking: false), credentialsLinking: true, linked: [])
            .map(\.id), [ldap.id])
        XCTAssertTrue(AccountSignInModel.connectable(providers: [oidc, ldap], oauth: nil, credentialsLinking: false,
            linked: []).isEmpty)

        let linked = APIv2AccountIdentity(id: "4", installationId: "3", providerId: oidc.id, providerName: "Example SSO",
            username: "alice", email: "", displayName: "", linkedAt: Date())
        XCTAssertEqual(AccountSignInModel.connectable(providers: [oidc, ldap], oauth: Self.native,
            credentialsLinking: true, linked: [linked]).map(\.id),
            [ldap.id], "a linked installation is not offered again")
    }

    func testCredentialsLinkingCapabilityDecodes() throws {
        // credentials_linking is an external sign-in capability, not an
        // OAuth handshake one: directory linking needs no browser.
        let current = try decode(APIv2ExternalSignInCapabilities.self, "get_external_sign_in_capabilities_ok")
        XCTAssertTrue(current.supportsCredentialsLinking)
        let older = try Support.decoder.decode(APIv2ExternalSignInCapabilities.self, from: Support.mutatedBody(
            named: "get_external_sign_in_capabilities_ok", bundleClass: Self.self) {
                $0.removeValue(forKey: "credentials_linking")
            })
        XCTAssertFalse(older.supportsCredentialsLinking, "absent from servers that predate it")
        let unavailable = try Support.decoder.decode(APIv2ExternalSignInCapabilities.self, from: Support.mutatedBody(
            named: "get_external_sign_in_capabilities_ok", bundleClass: Self.self) {
                $0["credentials_linking"] = true
                $0["state"] = "disabled"
            })
        XCTAssertFalse(unavailable.supportsCredentialsLinking)

        let handshake = try decode(APIv2OAuthCapabilities.self, "get_oauth_handshake_capabilities_ok")
        XCTAssertTrue(handshake.supportsSelectAccount)
        let olderHandshake = try Support.decoder.decode(APIv2OAuthCapabilities.self, from: Support.mutatedBody(
            named: "get_oauth_handshake_capabilities_ok", bundleClass: Self.self) {
                $0.removeValue(forKey: "select_account")
            })
        XCTAssertFalse(olderHandshake.supportsSelectAccount, "absent from servers that predate it")
    }

    func testDirectoryLinkSendsBothPasswordsOnceUnderTheAccount() async throws {
        let runner = FakeRunner { _ in XCTFail("browser opened"); throw ExternalSignInError.canceled }
        let (_, _, tokens) = try await makeService(runner: runner, signedIn: true)
        let api = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens,
            isUpdateRequired: { false })
        let identity = await tokens.refreshAccountIdentity()
        let account = try XCTUnwrap(identity)

        stub.reply(path: APIv2Client.identityLinkCredentialsPath, 201,
            Support.text(named: "link_account_identity_with_credentials_ok", bundleClass: Self.self))
        let linked = try await api.linkIdentityWithCredentials(installationId: "4", password: "local", username: "alice",
            directoryPassword: "dir", expectedAccount: account)
        XCTAssertEqual(linked.installationId, "4")
        XCTAssertEqual(linked.accountLabel, "alice")
        XCTAssertNil(linked.lastSignInAt)
        let request = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.header("authorization"), "Bearer acc")
        XCTAssertNil(request.header("x-profile-id"), "account-scoped")
        XCTAssertEqual(try body(request), ["installation_id": "4", "password": "local", "username": "alice",
            "directory_password": "dir"])

        // A 401 is not answered with a refresh and a second password check.
        stub.reset()
        stub.reply(path: HTTPClient.refreshPath, 200, #"{"access_token":"new","refresh_token":"new-ref","expires_in":3600}"#)
        stub.reply(path: APIv2Client.identityLinkCredentialsPath, 401,
            #"{"type":"https://siloserver.org/docs/api/v2/problems/invalid_token","title":"t","status":401,"detail":"d"}"#)
        do {
            _ = try await api.linkIdentityWithCredentials(installationId: "4", password: "local", username: "alice",
                directoryPassword: "dir", expectedAccount: account)
            XCTFail("linked")
        } catch {}
        XCTAssertEqual(stub.requestedPaths, [APIv2Client.identityLinkCredentialsPath])
    }

    func testDirectoryLinkRefusalsReadAsCopy() {
        func problem(_ id: String, _ status: Int, at location: String? = nil) -> Error {
            APIv2Error.problem(APIv2Problem(type: "https://siloserver.org/docs/api/v2/problems/\(id)", title: "t",
                status: status, detail: "server detail", instance: nil,
                errors: location.map { [APIv2ProblemError(location: $0, code: "invalid", detail: "d")] }))
        }
        let cases: [(Error, String)] = [
            (problem("validation_failed", 422, at: "body.password"), "That Silo password is incorrect."),
            (problem("validation_failed", 422, at: "body.directory_password"),
                "The directory didn't accept that username and password."),
            (problem("local_password_required", 409),
                "Your account has no Silo password to confirm with. Ask an administrator to connect the provider."),
            (problem("not_permitted", 403), ExternalSignInError.reasonText("not_permitted")),
            (problem("account_disabled", 403), ExternalSignInError.reasonText("account_disabled")),
            (problem("identity_linked_elsewhere", 409), ExternalSignInError.reasonText("identity_linked_elsewhere")),
            (problem("already_linked", 409), ExternalSignInError.reasonText("already_linked")),
            (problem("password_expired", 403), ExternalSignInError.reasonText("password_expired")),
            (problem("not_found", 404), "The sign-in provider is no longer available on this server."),
            (problem("provider_unavailable", 503), ExternalSignInError.reasonText("provider_unavailable")),
            (problem("permission_denied", 403),
                "This session can't change how the account signs in. Sign in with your own account and try again."),
            (problem("rate_limited", 429), "Too many attempts. Wait a moment, then try again."),
        ]
        for (error, expected) in cases {
            XCTAssertEqual(AccountSignInModel.message(for: error, action: .connect), expected, "\(error)")
        }
    }

    /// The account page reads credentials linking from the external sign-in
    /// document (where the server reports it) and the identity list's
    /// `can_unlink`.
    @MainActor
    func testAccountPageLoadsDirectoryConnectAndUnlinkRule() async throws {
        let runner = FakeRunner { _ in XCTFail("browser opened"); throw ExternalSignInError.canceled }
        let (_, _, tokens) = try await makeService(runner: runner, signedIn: true)
        let api = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens,
            isUpdateRequired: { false })
        let model = AccountSignInModel(api: api, tokenStore: tokens,
            link: { _, _ in XCTFail("browser link used") })
        let providers = #"{"items":[{"id":"local","display_name":"Local","mode":"credentials","default":true},"#
            + #"{"id":"plugin:6:ldap","display_name":"Directory","mode":"credentials","default":false,"#
            + #""installation_id":"6"}],"password_login":true}"#
        stub.reply(path: APIv2Client.authProvidersPath, 200, providers)
        stub.reply(path: APIv2Client.oauthCapabilitiesPath, 200,
            Support.text(named: "get_oauth_handshake_capabilities_ok", bundleClass: Self.self))
        stub.reply(path: APIv2Client.externalSignInCapabilitiesPath, 200,
            Support.text(named: "get_external_sign_in_capabilities_ok", bundleClass: Self.self))
        stub.reply(path: APIv2Client.accountIdentitiesPath, 200,
            Support.text(named: "list_account_identities_ok", bundleClass: Self.self))

        await model.load()
        XCTAssertTrue(model.isSupported)
        XCTAssertEqual(model.connectable.map(\.id), ["plugin:6:ldap"])
        XCTAssertEqual(model.connectable.map(\.method), [.directory])
        XCTAssertEqual(model.canUnlink, false)
        XCTAssertEqual(model.identities.map(\.id), ["4"])
    }

    @MainActor
    func testDirectoryConnectAsksForBothCredentialsBeforeSending() async throws {
        let runner = FakeRunner { _ in XCTFail("browser opened"); throw ExternalSignInError.canceled }
        let (_, _, tokens) = try await makeService(runner: runner, signedIn: true)
        let api = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens,
            isUpdateRequired: { false })
        let model = AccountSignInModel(api: api, tokenStore: tokens,
            link: { _, _ in XCTFail("browser link used for a directory") })
        let ldap = Self.provider(id: "plugin:6:ldap", name: "Directory", mode: "credentials", installation: "6", startPath: nil)

        let missing = await model.connect(ldap, password: "local",
            directory: AccountSignInModel.DirectoryCredentials(username: " ", password: "dir"))
        XCTAssertFalse(missing)
        XCTAssertEqual(model.errorMessage, "Enter your Directory username and password.")
        XCTAssertTrue(stub.requests.isEmpty)

        stub.reply(path: APIv2Client.identityLinkCredentialsPath, 422,
            Support.text(named: "link_account_identity_with_credentials_directory_refused", bundleClass: Self.self))
        let refused = await model.connect(ldap, password: "local",
            directory: AccountSignInModel.DirectoryCredentials(username: " alice ", password: "dir"))
        XCTAssertFalse(refused)
        XCTAssertEqual(model.errorMessage, "The directory didn't accept that username and password.")
        XCTAssertEqual(try body(stub.requests.last)["username"], "alice", "surrounding spaces are trimmed")
        XCTAssertNil(model.busyID)
    }

    func testIdentityDisconnectIsAnAccountScopedDelete() async throws {
        let runner = FakeRunner { _ in throw ExternalSignInError.canceled }
        let (_, _, tokens) = try await makeService(runner: runner, signedIn: true)
        let api = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens,
            isUpdateRequired: { false })
        let identity = await tokens.refreshAccountIdentity()
        let account = try XCTUnwrap(identity)
        stub.reply(path: "/api/v2/account/identities/4", 204, "")
        try await api.deleteAccountIdentity(id: "4", expectedAccount: account)
        stub.reply(path: APIv2Client.accountIdentitiesPath, 200,
            Support.text(named: "list_account_identities_ok", bundleClass: Self.self))
        let listed = try await api.accountIdentities(expectedAccount: account)
        XCTAssertEqual(listed.items.map(\.id), ["4"])
        XCTAssertEqual(listed.canUnlink, false)
        XCTAssertEqual(stub.methods, ["DELETE", "GET"])
        for request in stub.requests {
            XCTAssertEqual(request.header("authorization"), "Bearer acc")
            XCTAssertNil(request.header("x-profile-id"))
        }
    }

    // MARK: Refresh during a provider outage

    /// The server refuses a refresh with 503 `provider_unavailable` when the
    /// provider re-check fails closed. The session stays and the next
    /// request refreshes again.
    func testProviderOutageOnRefreshKeepsTheSessionAndRetriesLater() async throws {
        let name = "ExternalSignInTests.refresh.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        addTeardownBlock {
            _ = await tokens.clearTokens()
            UserDefaults().removePersistentDomain(forName: name)
        }
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://refresh.example")
        let saved = await tokens.saveTokens(accessToken: "access", refreshToken: "refresh")
        XCTAssertTrue(saved)

        let outage = Support.text(named: "refresh_session_provider_unavailable", bundleClass: Self.self)
        let refreshes = Counter()
        let handler = StubURLProtocol.Handler()
        handler.route(StubURLProtocol.method("POST", path: HTTPClient.refreshPath)) { _ in
            refreshes.increment() == 1
                ? .json(outage, status: 503, headers: ["Content-Type": "application/problem+json"])
                : .json(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#)
        }
        handler.route(StubURLProtocol.path("/api/v2/account/me")) { request in
            request.header("Authorization") == "Bearer new-access" ? .json("{}") : .status(401)
        }
        let http = HTTPClient(session: handler.makeSession(), tokenStore: tokens)
        let expired = Counter()
        let observer = NotificationCenter.default.addObserver(forName: .siloSessionExpired, object: nil, queue: nil) { _ in
            _ = expired.increment()
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let api = APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false })
        do {
            _ = try await api.mapErrors { try await http.requestData(method: "GET", path: "/api/v2/account/me") }
            XCTFail("the request cannot succeed while the provider is unreachable")
        } catch {
            // The outage itself, not the 401 that sent the request to refresh:
            // it reads as transient, never as an ended session.
            guard case APIv2Error.problem(let problem) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(problem.identifier, "provider_unavailable")
            XCTAssertEqual(problem.status, 503)
            let state = ErrorState(error)
            XCTAssertFalse(state.isAuthFailure)
            XCTAssertTrue(state.isTransient)
            XCTAssertEqual(state.message, ExternalSignInError.reasonText("provider_unavailable"))
        }
        let keptAccess = await tokens.getAccessToken()
        let keptRefresh = await tokens.getRefreshToken()
        XCTAssertEqual(keptAccess, "access")
        XCTAssertEqual(keptRefresh, "refresh")
        XCTAssertEqual(expired.value, 0, "an outage never signs out")
        XCTAssertFalse(HTTPClient.shouldInvalidateSessionAfterRefreshFailure(503))

        let response = try await http.requestData(method: "GET", path: "/api/v2/account/me")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(refreshes.value, 2, "the next request refreshed again")
        let rotated = await tokens.getAccessToken()
        XCTAssertEqual(rotated, "new-access")
    }
}

extension ExternalSignInTests {
    /// A JWT-shaped token whose `exp` is `expiresIn` seconds from now.
    fileprivate static func jwt(_ label: String, expiresIn: TimeInterval) -> String {
        let exp = Date().timeIntervalSince1970 + expiresIn
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": exp, "iat": exp - 3600, "sub": label])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "h.\(encoded).s"
    }

    /// A bearer about to expire is renewed before the request goes out. When
    /// that renewal meets a provider outage, the still-valid bearer is sent
    /// anyway: the outage must not fail a request that would succeed.
    func testProviderOutageBeforeDispatchStillSendsAValidBearer() async throws {
        let name = "ExternalSignInTests.predispatch.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        addTeardownBlock {
            _ = await tokens.clearTokens()
            UserDefaults().removePersistentDomain(forName: name)
        }
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://refresh.example")
        let closing = Self.jwt("closing", expiresIn: 20)
        let saved = await tokens.saveTokens(accessToken: closing, refreshToken: "refresh")
        XCTAssertTrue(saved)

        let outage = Support.text(named: "refresh_session_provider_unavailable", bundleClass: Self.self)
        let handler = StubURLProtocol.Handler()
        handler.route(StubURLProtocol.method("POST", path: HTTPClient.refreshPath)) { _ in
            .json(outage, status: 503, headers: ["Content-Type": "application/problem+json"])
        }
        handler.route(StubURLProtocol.path("/api/v2/account/me")) { request in
            request.header("Authorization") == "Bearer \(closing)" ? .json("{}") : .status(401)
        }
        let http = HTTPClient(session: handler.makeSession(), tokenStore: tokens)
        let response = try await http.requestData(method: "GET", path: "/api/v2/account/me")
        XCTAssertEqual(response.statusCode, 200)
        let kept = await tokens.getAccessToken()
        XCTAssertEqual(kept, closing)
    }
}

#if !os(tvOS)
extension ExternalSignInTests {
    @MainActor
    private final class FakeSession: WebAuthenticationSessionHandle {
        private(set) var canceled = false
        func start() -> Bool { true }
        func cancel() { canceled = true }
    }

    @MainActor
    private final class Sessions {
        var made: [FakeSession] = []
        var completions: [@Sendable (URL?, Error?) -> Void] = []
    }

    /// On macOS the redirect can reach the app through URL routing instead
    /// of the session. Any URL with the app's scheme can arrive that way;
    /// only one carrying the open flow's `app_state` as `state` ends it.
    @MainActor
    func testRoutedRedirectEndsTheSignInOnlyWithTheFlowsState() async throws {
        let sessions = Sessions()
        let opened = expectation(description: "session started")
        let runner = SystemWebAuthenticationRunner { _, _, _, _ in
            let session = FakeSession()
            sessions.made.append(session)
            opened.fulfill()
            return session
        }
        let start = try XCTUnwrap(URL(string: Self.startURL + "?code_challenge=c&app_state=flow-state"))
        let flow = Task { try await runner.authenticate(url: start, callbackScheme: NativeSignIn.callbackScheme) }
        await fulfillment(of: [opened], timeout: 5)
        let session = try XCTUnwrap(sessions.made.first)

        let strays = [
            Self.callback(["code": "c", "state": "someone-else", "server": Self.serverId]),
            Self.callback(["code": "c", "server": Self.serverId]),
            try XCTUnwrap(URL(string: "org.siloserver.silo:/auth/callback")),
        ]
        for stray in strays {
            XCTAssertFalse(runner.receiveExternalCallback(stray), stray.absoluteString)
        }
        XCTAssertFalse(session.canceled, "the sign-in stays open")

        let own = Self.callback(["code": "c", "state": "flow-state", "server": Self.serverId])
        XCTAssertTrue(runner.receiveExternalCallback(own))
        let returned = try await flow.value
        XCTAssertEqual(returned, own, "no stray URL resumed the flow")
        XCTAssertTrue(session.canceled)
        XCTAssertFalse(runner.receiveExternalCallback(own), "nothing is pending once the flow ended")
    }

    /// A new sign-in replaces the open one. The replaced flow's late answers
    /// (its session reporting the cancel, its task's cancellation) end only
    /// that flow, never the one that replaced it.
    @MainActor
    func testAReplacedSignInNeverEndsTheOneThatReplacedIt() async throws {
        let sessions = Sessions()
        let runner = SystemWebAuthenticationRunner { _, _, _, completion in
            sessions.completions.append(completion)
            return FakeSession()
        }
        let firstStart = try XCTUnwrap(URL(string: Self.startURL + "?code_challenge=c&app_state=first"))
        let secondStart = try XCTUnwrap(URL(string: Self.startURL + "?code_challenge=c&app_state=second"))
        let first = Task { try await runner.authenticate(url: firstStart, callbackScheme: NativeSignIn.callbackScheme) }
        while sessions.completions.isEmpty { await Task.yield() }
        let second = Task { try await runner.authenticate(url: secondStart, callbackScheme: NativeSignIn.callbackScheme) }
        while sessions.completions.count < 2 { await Task.yield() }

        do {
            _ = try await first.value
            XCTFail("the replaced flow ends canceled")
        } catch {
            XCTAssertEqual(error as? ExternalSignInError, .canceled)
        }
        sessions.completions[0](nil, ASWebAuthenticationSessionError(.canceledLogin))
        first.cancel()
        for _ in 0..<20 { await Task.yield() }

        let own = Self.callback(["code": "c", "state": "second", "server": Self.serverId])
        XCTAssertTrue(runner.receiveExternalCallback(own), "the newer flow is still open")
        let returned = try await second.value
        XCTAssertEqual(returned, own)
    }
}
#endif

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    @discardableResult func increment() -> Int { lock.withLock { count += 1; return count } }
}
