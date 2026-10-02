import CryptoKit
import Foundation
import Security

/// The app side of the server's native OAuth handshake
/// (silo-server `docs/architecture/external-sign-in.md`, "Native apps"):
///
/// 1. Make a random `app_state` and a PKCE verifier; send the S256 challenge.
/// 2. Open the provider's native start in the system browser, always on the
///    saved server's base URL: the `/api/v2/auth/oauth/<id>/native/start`
///    suffix of `native_start_path` and its query go under the saved base's
///    own path prefix, so the app never opens another origin. An oauth
///    provider without `native_start_path` offers no browser sign-in.
/// 3. The server finishes with the provider and redirects to the fixed app
///    URI `org.siloserver.silo:/auth/callback` with `code`, `state`,
///    `server` and `iss` (the origin where the native start first arrived),
///    or `error`.
/// 4. Check `state`, `server`, and that `iss` is the saved base's origin,
///    then redeem the code with the verifier at the saved base.
///
/// The `iss` check stops a relay: a hostile saved server that sends the
/// browser on to another server's native start gets that server's own
/// origin back as `iss`, which is not the saved origin, so the code is
/// discarded. A sign-in never moves, re-keys, or duplicates a saved server.
///
/// Only the one-time code travels in the redirect. Neither it, the verifier,
/// nor any token is ever logged.
enum NativeSignIn {
    /// RFC 8252 private-use scheme: the iOS bundle prefix and the Android
    /// `applicationId`. Distinct from the `silo://` deep links.
    static let callbackScheme = "org.siloserver.silo"
    static let callbackPath = "/auth/callback"

    /// Whether `url` is the handshake's app redirect rather than a deep link.
    static func isCallback(_ url: URL) -> Bool {
        url.scheme?.lowercased() == callbackScheme
    }

    /// `scheme://host[:port]` of an http(s) URL: scheme and host lowercased,
    /// an IPv6 host bracketed in RFC 5952 form, a default port dropped. The
    /// server serializes `iss` from the `Host` a browser sent, which writes
    /// IPv6 compressed, so a saved `[fd00:0:0:0:0:0:0:5]` must compare as
    /// `[fd00::5]`. Nil for anything else.
    static func origin(of url: URL) -> String? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              var host = components.percentEncodedHost?.lowercased(), !host.isEmpty else { return nil }
        if host.contains(":") {
            let literal = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
            host = "[\(compressIPv6(literal) ?? literal)]"
        }
        var port = components.port
        if (scheme == "https" && port == 443) || (scheme == "http" && port == 80) { port = nil }
        return "\(scheme)://\(host)" + (port.map { ":\($0)" } ?? "")
    }

    /// An IPv6 literal of hex groups in RFC 5952 form: lowercase, no leading
    /// zeros, the first longest run of two or more zero groups as `::`. Nil
    /// when `literal` is not eight groups of one to four hex digits once
    /// expanded (an embedded IPv4 part or a zone is left as written), the
    /// same rule as the Android app.
    static func compressIPv6(_ literal: String) -> String? {
        let halves = literal.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ part: String) -> [String] { part.isEmpty ? [] : part.components(separatedBy: ":") }
        let left = groups(halves[0])
        let right = halves.count == 2 ? groups(halves[1]) : []
        let missing = 8 - left.count - right.count
        guard halves.count == 2 ? missing >= 1 : missing == 0 else { return nil }
        var values: [UInt16] = []
        for group in left + Array(repeating: "0", count: missing) + right {
            guard (1...4).contains(group.count), group.allSatisfy(\.isHexDigit),
                  let value = UInt16(group, radix: 16) else { return nil }
            values.append(value)
        }
        var bestStart = -1
        var bestLength = 1
        var index = 0
        while index < values.count {
            guard values[index] == 0 else {
                index += 1
                continue
            }
            let start = index
            while index < values.count, values[index] == 0 { index += 1 }
            if index - start > bestLength {
                bestStart = start
                bestLength = index - start
            }
        }
        let hex = values.map { String($0, radix: 16) }
        guard bestStart >= 0 else { return hex.joined(separator: ":") }
        return hex[..<bestStart].joined(separator: ":") + "::" + hex[(bestStart + bestLength)...].joined(separator: ":")
    }

    /// The origin of a saved server's base URL, which may carry a path.
    static func origin(ofServerURL serverURL: String) -> String? {
        URL(string: ServerRegistry.normalize(url: serverURL)).flatMap(origin(of:))
    }

    /// The server-relative part of every native start: what follows the
    /// server's base URL (which may carry a reverse proxy's path prefix).
    private static let nativeStartSuffix = try! NSRegularExpression(pattern: "/api/v2/auth/oauth/[^/?#]+/native/start/?$")

    /// The native start on the saved server: the API path (and the server's
    /// query items) of `start`, resolved against `serverURL`, the saved
    /// base. `start` comes from `native_start_path`; anything before its
    /// API path is dropped, so the URL is always under the saved base's
    /// origin and path prefix. Nil when either is malformed.
    static func startURL(_ start: SignInOptions.NativeStart, onServer serverURL: String) -> URL? {
        guard let baseURL = URL(string: ServerRegistry.normalize(url: serverURL)),
              let savedOrigin = origin(of: baseURL),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        components.percentEncodedPath = ServerRegistry.normalize(url: components.percentEncodedPath) + start.apiPath
        components.queryItems = start.queryItems.isEmpty ? nil : start.queryItems
        guard let url = components.url, origin(of: url) == savedOrigin else { return nil }
        return url
    }

    /// The API path of a native start path: the
    /// `/api/v2/auth/oauth/<id>/native/start` it ends with. Nil for a path
    /// of any other shape.
    static func nativeStartAPIPath(_ path: String) -> String? {
        let range = NSRange(path.startIndex..., in: path)
        guard let match = nativeStartSuffix.firstMatch(in: path, range: range),
              let suffix = Range(match.range, in: path) else { return nil }
        return String(path[suffix])
    }

    /// The redirect's `iss` as an origin: an absolute http(s) URL with no
    /// credentials, path, query or fragment. Nil when it is anything else.
    static func issuerOrigin(_ raw: String) -> String? {
        guard let url = URL(string: raw),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" else { return nil }
        return origin(of: url)
    }
}

/// PKCE (RFC 7636) and the opaque `app_state`.
enum NativeSignInPKCE {
    /// 32 random bytes as unpadded base64url: 43 unreserved characters, the
    /// shortest verifier RFC 7636 allows and within `app_state`'s 1-512.
    static func randomToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "system random source unavailable")
        return base64URL(Data(bytes))
    }

    /// `code_challenge` for `verifier`: unpadded base64url of SHA-256.
    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `prompt` value that asks the provider to let the person choose which
    /// provider account to sign in with.
    static let selectAccountPrompt = "select_account"

    /// The start URL: the provider's native start on the saved base with the
    /// challenge, the state and, for a linking flow, the ticket, or for a
    /// Switch account sign-in, `prompt`. Existing query items on the server's URL are kept;
    /// the client's own members replace any of the same name.
    static func startURL(base: URL, challenge: String, appState: String, linkTicket: String? = nil,
                         prompt: String? = nil) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { return nil }
        var own = [
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "app_state", value: appState),
        ]
        if let linkTicket { own.append(URLQueryItem(name: "link_ticket", value: linkTicket)) }
        if let prompt { own.append(URLQueryItem(name: "prompt", value: prompt)) }
        let names = Set(own.map(\.name))
        components.queryItems = (components.queryItems ?? []).filter { !names.contains($0.name) } + own
        return components.url
    }
}

/// A validated app redirect.
enum NativeSignInCallback: Equatable {
    /// A one-time code to redeem with the verifier. `link` marks a linking
    /// flow's code, which `completeAccountIdentityLink` confirms.
    case code(String, link: Bool)
    /// The server's failure reason (`not_permitted`, `email_in_use`, …).
    case failure(reason: String)

    /// Checks the redirect against the flow that started it. The state must
    /// be the flow's own, `server` the saved server's verified identity, and
    /// `iss` the saved base's origin (`expectedIssuer`), where the app opened
    /// the native start; only then is an `error` or a `code` believed.
    static func parse(_ url: URL, expectedState: String, expectedServerId: String,
                      expectedIssuer: String) throws -> NativeSignInCallback {
        guard NativeSignIn.isCallback(url),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.path == NativeSignIn.callbackPath else {
            throw ExternalSignInError.incompleteCallback
        }
        var values: [String: String] = [:]
        for item in components.queryItems ?? [] where values[item.name] == nil {
            values[item.name] = item.value ?? ""
        }
        guard let state = values["state"], !state.isEmpty, state == expectedState else {
            throw ExternalSignInError.stateMismatch
        }
        guard let server = values["server"], !server.isEmpty, server == expectedServerId else {
            throw ExternalSignInError.serverMismatch
        }
        // The server sends the origin where the native start first arrived.
        // A saved server that relayed the start to another server gets that
        // server's own origin back here. A redirect without `iss` is refused.
        guard let issuer = values["iss"].flatMap(NativeSignIn.issuerOrigin), issuer == expectedIssuer else {
            throw ExternalSignInError.issuerMismatch
        }
        if let reason = values["error"] {
            return .failure(reason: reason)
        }
        guard let code = values["code"], !code.isEmpty else { throw ExternalSignInError.incompleteCallback }
        return .code(code, link: values["link"] == "1")
    }
}

/// Why a browser sign-in or link did not finish. `message` is the copy the
/// app shows; `canceled` shows nothing.
enum ExternalSignInError: LocalizedError, Equatable {
    /// The person closed the sign-in sheet.
    case canceled
    /// The system browser could not be opened.
    case browserUnavailable
    /// The server lists no native start of the expected shape, or the saved
    /// base URL cannot carry one.
    case invalidStartURL
    /// The saved server has no verified identity to check the redirect with.
    case serverIdentityUnavailable
    /// The redirect's state is not this flow's.
    case stateMismatch
    /// The redirect names another server than the saved one.
    case serverMismatch
    /// The redirect's `iss` is missing or is not the saved base's origin:
    /// the native start reached another server first.
    case issuerMismatch
    /// The redirect carried neither a code nor an error, or the wrong kind.
    case incompleteCallback
    /// The server or provider refused, with the server's reason code.
    case provider(reason: String)

    var errorDescription: String? { message }

    var message: String {
        switch self {
        case .canceled: return ""
        case .browserUnavailable: return "Couldn't open the sign-in page. Try again."
        case .invalidStartURL: return "This server's sign-in page can't be opened from the app."
        case .serverIdentityUnavailable:
            return "Couldn't confirm which server this is. Check the connection and try again."
        case .stateMismatch: return Self.reasonText("state_invalid")
        case .serverMismatch, .issuerMismatch: return Self.differentServerText
        case .incompleteCallback: return Self.reasonText("login_failed")
        case .provider(let reason): return Self.reasonText(reason)
        }
    }

    static let differentServerText = "This sign-in came back from a different server. Nothing was signed in."

    /// Copy for the server's failure reasons, the same codes the web login
    /// page maps. Unknown codes fall back to a generic line; the code itself
    /// is never shown.
    static func reasonText(_ reason: String) -> String {
        switch reason {
        case "not_permitted":
            return "Your account at the sign-in provider isn't allowed to use this server."
        case "email_in_use":
            return "An account with this email already exists. Ask an admin to connect it to the sign-in provider."
        case "identity_linked_elsewhere":
            return "That provider account is already connected to another account."
        case "account_disabled":
            return "This account is disabled."
        case "provider_unavailable":
            return "The sign-in provider can't be reached right now. Try again later."
        case "state_invalid":
            return "Sign-in didn't finish. Start again."
        case "session_expired":
            return "Sign-in took too long. Start again."
        case "already_linked":
            return "This account is already connected to the sign-in provider."
        case "password_expired":
            return "Your directory password has expired. Change it with your organization, then try again."
        case "account_required":
            return "You don't have an account on this server yet. Ask an admin to add you."
        default:
            return "Sign-in with the provider failed. Try again."
        }
    }

    /// Maps a v2 problem from completing the handshake or linking to the same
    /// copy. A code that expired, was used, or does not fit the verifier all
    /// mean the flow has to start again.
    static func completionError(_ error: Error) -> Error {
        guard case APIv2Error.problem(let problem) = error else { return error }
        switch problem.identifier {
        case "invalid_grant": return ExternalSignInError.provider(reason: "state_invalid")
        case "invalid_token", "session_expired": return ExternalSignInError.provider(reason: "session_expired")
        case "not_permitted", "identity_linked_elsewhere", "email_in_use", "provider_unavailable", "account_disabled",
             "already_linked", "password_expired", "account_required":
            return ExternalSignInError.provider(reason: problem.identifier)
        case "conflict" where problem.status == 409:
            return ExternalSignInError.provider(reason: "already_linked")
        default: return error
        }
    }
}

/// Opens a URL in the system's web authentication sheet and returns the
/// redirect to `callbackScheme`. Throws `ExternalSignInError.canceled` when
/// the person closes it.
protocol WebAuthenticationRunning: AnyObject, Sendable {
    @MainActor func authenticate(url: URL, callbackScheme: String) async throws -> URL
}

/// Runs browser sign-in and account linking against the active server.
///
/// Everything happens on the saved base URL: the native start opens there,
/// the redirect's `iss` must be its origin, and the code is redeemed there.
/// A server saved by its LAN address signs in on that address and stays on
/// it; nothing about the saved server changes because of a sign-in.
final class ExternalSignInService: Sendable {
    /// Installs the session a code opened for the saved server.
    typealias InstallSession = @Sendable (APIv2OAuthCompletion, RefreshAccountIdentity) async throws -> Void

    private let api: APIv2Client
    private let tokenStore: TokenStore
    private let runner: WebAuthenticationRunning
    private let verifiedServerId: @Sendable () async -> String?
    private let installSession: InstallSession
    private let randomToken: @Sendable () -> String

    init(
        api: APIv2Client,
        tokenStore: TokenStore,
        runner: WebAuthenticationRunning,
        verifiedServerId: @escaping @Sendable () async -> String?,
        installSession: @escaping InstallSession,
        randomToken: @escaping @Sendable () -> String = { NativeSignInPKCE.randomToken() }
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.runner = runner
        self.verifiedServerId = verifiedServerId
        self.installSession = installSession
        self.randomToken = randomToken
    }

    /// Signs in with `provider` and installs the session it opens.
    /// `selectAccount` asks the provider to let the person choose another
    /// provider account (`prompt=select_account`); send it only to a server
    /// that advertises `select_account`.
    func signIn(with provider: APIv2AuthProvider, selectAccount: Bool = false) async throws {
        guard let expectedAccount = await tokenStore.refreshAccountIdentity() else {
            throw HTTPError.serverUrlNotConfigured
        }
        let (target, serverId) = try await flowPrerequisites(provider: provider, serverURL: expectedAccount.serverURL)
        let flow = try await runFlow(target: target, serverId: serverId, linkTicket: nil,
            prompt: selectAccount ? NativeSignInPKCE.selectAccountPrompt : nil)
        let tokens: APIv2OAuthCompletion
        do {
            tokens = try await api.completeOAuthLogin(code: flow.code, codeVerifier: flow.verifier,
                expectedAccount: expectedAccount)
        } catch {
            throw ExternalSignInError.completionError(error)
        }
        try await installSession(tokens, expectedAccount)
    }

    /// Links `provider` to the signed-in account: the local password buys a
    /// link ticket, the browser flow runs with it, and the app confirms the
    /// resulting code with its verifier under its own bearer.
    func link(provider: APIv2AuthProvider, password: String) async throws {
        guard let installationId = provider.installationId else { throw ExternalSignInError.invalidStartURL }
        guard let expectedAccount = await tokenStore.refreshAccountIdentity() else {
            throw HTTPError.serverUrlNotConfigured
        }
        // Check what the flow needs before the password check and the
        // ticket are spent.
        let (target, serverId) = try await flowPrerequisites(provider: provider, serverURL: expectedAccount.serverURL)
        let ticket = try await api.createIdentityLinkTicket(installationId: installationId, password: password,
            expectedAccount: expectedAccount)
        let flow = try await runFlow(target: target, serverId: serverId, linkTicket: ticket.ticket, prompt: nil)
        do {
            try await api.completeIdentityLink(code: flow.code, codeVerifier: flow.verifier,
                expectedAccount: expectedAccount)
        } catch {
            throw ExternalSignInError.completionError(error)
        }
    }

    /// A browser flow that came back with a code.
    private struct Flow {
        let code: String
        let verifier: String
    }

    /// The provider's native start resolved onto the saved base, with the
    /// saved base's origin it must come back with as `iss`.
    private typealias StartTarget = (url: URL, issuer: String)

    private static func startURL(of provider: APIv2AuthProvider, serverURL: String) -> StartTarget? {
        guard let start = SignInOptions.nativeStart(of: provider),
              let url = NativeSignIn.startURL(start, onServer: serverURL),
              let issuer = NativeSignIn.origin(ofServerURL: serverURL) else { return nil }
        return (url, issuer)
    }

    /// What a browser flow needs before anything is spent on it: the start
    /// on the saved base and the saved server's verified identity.
    private func flowPrerequisites(provider: APIv2AuthProvider,
                                   serverURL: String) async throws -> (target: StartTarget, serverId: String) {
        guard let target = Self.startURL(of: provider, serverURL: serverURL) else {
            throw ExternalSignInError.invalidStartURL
        }
        guard let serverId = await verifiedServerId() else { throw ExternalSignInError.serverIdentityUnavailable }
        return (target, serverId)
    }

    /// Runs the browser flow on the saved base and returns the one-time code
    /// with its verifier. A linking flow (a `linkTicket`) must come back
    /// with a link code and a sign-in flow with a sign-in code; the server's
    /// refusal becomes `.provider(reason:)`.
    private func runFlow(target: StartTarget, serverId: String, linkTicket: String?,
                         prompt: String?) async throws -> Flow {
        let appState = randomToken()
        let verifier = randomToken()
        guard let start = NativeSignInPKCE.startURL(base: target.url, challenge: NativeSignInPKCE.challenge(for: verifier),
                                                    appState: appState, linkTicket: linkTicket, prompt: prompt) else {
            throw ExternalSignInError.invalidStartURL
        }
        try Task.checkCancellation()
        let redirect = try await runner.authenticate(url: start, callbackScheme: NativeSignIn.callbackScheme)
        switch try NativeSignInCallback.parse(redirect, expectedState: appState, expectedServerId: serverId,
                                              expectedIssuer: target.issuer) {
        case .code(let code, let link) where link == (linkTicket != nil):
            return Flow(code: code, verifier: verifier)
        case .code:
            throw ExternalSignInError.incompleteCallback
        case .failure(let reason):
            throw ExternalSignInError.provider(reason: reason)
        }
    }
}

/// Which saved servers ask the provider to let the person choose an account
/// on their next browser sign-in (`prompt=select_account`). An explicit Silo
/// sign-out sets it: the sign-in sheet shares the system browser's cookies,
/// so without it the provider signs the same person straight back in. The
/// first browser sign-in that succeeds clears it.
///
/// "Not you? Switch account" on a TV approval also asks to start that
/// sign-in as soon as the login screen has its providers (`autoStart`). That
/// request lives in memory only: a relaunch never opens a browser by itself.
@MainActor
final class SelectAccountPrompt {
    static let shared = SelectAccountPrompt()

    private let defaults: UserDefaults
    private static let key = "externalSignIn.selectAccountServerIds"
    private var autoStartServerId: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private var serverIds: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.key) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.key) }
    }

    /// Ask for an account choice on `serverId`'s next browser sign-in.
    func request(serverId: String, autoStart: Bool = false) {
        guard !serverId.isEmpty else { return }
        serverIds.insert(serverId)
        if autoStart { autoStartServerId = serverId }
    }

    func isRequested(serverId: String) -> Bool { serverIds.contains(serverId) }

    /// A browser sign-in on `serverId` succeeded.
    func clear(serverId: String) {
        serverIds.remove(serverId)
        if autoStartServerId == serverId { autoStartServerId = nil }
    }

    /// Whether the login screen for `serverId` should start the browser
    /// sign-in by itself. True once per request.
    func consumeAutoStart(serverId: String) -> Bool {
        guard autoStartServerId == serverId else { return false }
        autoStartServerId = nil
        return true
    }

    /// Gives back an auto-start that `consumeAutoStart` took for a sign-in
    /// that never finished because its login screen went away. Does nothing
    /// once a browser sign-in succeeded (`clear`).
    func restoreAutoStart(serverId: String) {
        guard isRequested(serverId: serverId) else { return }
        autoStartServerId = serverId
    }
}
