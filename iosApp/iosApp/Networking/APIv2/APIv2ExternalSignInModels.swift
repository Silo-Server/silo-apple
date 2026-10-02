import Foundation

/// One entry of `GET /api/v2/auth/providers`.
struct APIv2AuthProvider: Decodable, Hashable, Sendable {
    let id: String
    let displayName: String
    /// `credentials` (password, sent to `login`), `oauth` (the handshake) or
    /// `network` (the provider's network says who owns the device). Other
    /// modes are ignored.
    let mode: String
    let `default`: Bool
    /// Absent when the provider ships no icon. May be site-relative.
    var iconUrl: String? = nil
    /// Absent for the built-in provider.
    var installationId: String? = nil
    /// The native start (`startNativeOAuthLogin`) as a path below the
    /// server base. The app opens it on the saved base URL; an oauth
    /// provider without it offers no browser sign-in.
    var nativeStartPath: String? = nil
    /// `signInWithNetworkIdentity` as a path below the server base, for a
    /// network provider. The app posts `{}` to it on the saved base URL.
    var networkSignInPath: String? = nil
    /// Who the network provider says owns this device, for the "Continue as"
    /// label. It authorizes nothing: the sign-in asks the provider again.
    var networkIdentity: APIv2AuthProviderNetworkIdentity? = nil

    var isOAuth: Bool { mode == "oauth" }
    var isCredentials: Bool { mode == "credentials" }
    /// Listed only to a request that came through the provider's own network
    /// (for Tailscale: the saved address is the server's tailnet name and
    /// this device is on the tailnet).
    var isNetwork: Bool { mode == "network" }
}

/// `network_identity` of a network provider: the device owner's names at
/// the provider. Either may be empty.
struct APIv2AuthProviderNetworkIdentity: Decodable, Hashable, Sendable {
    var displayName: String? = nil
    var username: String? = nil

    /// The name to show: the display name, else the username. Nil when both
    /// are empty.
    var name: String? {
        for value in [displayName, username] {
            if let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

/// `GET /api/v2/auth/providers`.
struct APIv2AuthProviders: Decodable, Sendable {
    let items: [APIv2AuthProvider]
    /// Whether any listed provider takes a username and password. Absent
    /// from servers that predate external sign-in, which always took one.
    var passwordLogin: Bool? = nil
}

/// `GET /api/v2/auth/oauth/capabilities`. Only the app-relevant members are
/// read; `native`, `linking` and `select_account` are absent from servers
/// that predate them.
struct APIv2OAuthCapabilities: Decodable, Equatable, Sendable {
    let state: String
    var native: Bool? = nil
    var linking: Bool? = nil
    /// Whether the native start accepts `prompt=select_account`, which asks
    /// the provider to let the person choose another provider account.
    var selectAccount: Bool? = nil

    var supportsNative: Bool { state == "available" && native == true }
    var supportsLinking: Bool { supportsNative && linking == true }
    var supportsSelectAccount: Bool { state == "available" && selectAccount == true }
}

/// `GET /api/v2/auth/external-sign-in/capabilities`, the members the account
/// screen reads. `credentials_linking` and `network_sign_in` are absent from
/// servers that predate them.
struct APIv2ExternalSignInCapabilities: Decodable, Equatable, Sendable {
    let state: String
    var identities: Bool? = nil
    /// Whether `linkAccountIdentityWithCredentials` links a directory (LDAP)
    /// account from the directory username and password.
    var credentialsLinking: Bool? = nil
    /// Whether `signInWithNetworkIdentity` and `linkAccountIdentityWithNetwork`
    /// are served. Whether this device may use them is discovery's answer: it
    /// lists a network provider only over that provider's network.
    var networkSignIn: Bool? = nil

    var supportsIdentities: Bool { state == "available" && identities == true }
    var supportsCredentialsLinking: Bool { state == "available" && credentialsLinking == true }
    var supportsNetworkSignIn: Bool { state == "available" && networkSignIn == true }
}

/// One entry of `GET /api/v2/account/identities`.
struct APIv2AccountIdentity: Decodable, Hashable, Sendable, Identifiable {
    let id: String
    let installationId: String
    /// Empty while that provider is not enabled.
    let providerId: String
    /// Empty while that provider is not enabled.
    let providerName: String
    let username: String
    let email: String
    let displayName: String
    let linkedAt: Date
    var lastSignInAt: Date? = nil

    /// What the account screen shows for who this identity is at the
    /// provider: the username, else the email, else the display name.
    var accountLabel: String {
        for value in [username, email, displayName] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return ""
    }
}

struct APIv2AccountIdentities: Decodable, Sendable {
    let items: [APIv2AccountIdentity]
    /// Whether `deleteAccountIdentity` would disconnect an identity now: the
    /// account has another identity, or its local password still signs in.
    /// Absent from servers that predate it; the server still refuses the
    /// last way to sign in either way.
    var canUnlink: Bool? = nil
}

/// `POST /api/v2/account/identities/link-ticket`.
struct APIv2IdentityLinkTicket: Decodable, Sendable {
    let ticket: String
    let expiresAt: Date
}

/// `POST /api/v2/auth/oauth/complete` answers the login token pair plus the
/// flow's return path, which apps ignore.
typealias APIv2OAuthCompletion = APIv2LoginTokens

/// What the sign-in screens offer for one server, from provider discovery
/// and the OAuth handshake document.
struct SignInOptions: Equatable, Sendable {
    /// Providers an app can sign in with through the system browser.
    let browserProviders: [APIv2AuthProvider]
    /// Whether discovery says a password sign-in can succeed for ordinary
    /// accounts: a provider takes a password (local or directory).
    let acceptsPasswords: Bool
    /// Whether a browser sign-in can ask the provider to choose another
    /// provider account (`prompt=select_account`).
    let supportsSelectAccount: Bool
    /// Every OAuth provider discovery lists, whether or not this app can run
    /// it. The TV names it beside its password form: people who sign in
    /// with it have no password and use their phone instead.
    let oauthProviders: [APIv2AuthProvider]
    /// Network providers (`mode: network`) with a usable
    /// `network_sign_in_path`: "Continue as …" signs this device's owner in
    /// with no password and no browser. Discovery lists one only to a request
    /// that came through that provider's network.
    let networkProviders: [APIv2AuthProvider]

    /// Whether the phone, tablet and Mac login screen shows the username and
    /// password form. Discovery omits the local provider while password
    /// sign-in is off, and a directory (LDAP) provider keeps the form: the
    /// server routes a password sign-in by account.
    var showsPasswordForm: Bool { acceptsPasswords }

    /// Password sign-in is off and no listed provider can run in this app.
    var offersNoSignIn: Bool { !acceptsPasswords && browserProviders.isEmpty && networkProviders.isEmpty }

    /// What a server that predates discovery offers: the password form only,
    /// which every server before external sign-in accepted.
    static let passwordOnly = SignInOptions(browserProviders: [], acceptsPasswords: true, supportsSelectAccount: false,
        oauthProviders: [])

    /// The rule the login screens follow.
    ///
    /// - Passwords are accepted unless discovery says no listed provider
    ///   takes one (`password_login`). A server that predates the member
    ///   always took one.
    /// - A browser provider needs a `native_start_path` of the expected shape
    ///   and a server whose handshake document says it serves apps
    ///   (`native`).
    /// - Missing discovery (a server that predates it) keeps the password
    ///   form. A read that failed is not this: see `SignInDiscovery.failed`.
    /// - A network provider needs a `network_sign_in_path` of the expected
    ///   shape. It never changes whether the password form shows.
    init(providers: APIv2AuthProviders?, oauth: APIv2OAuthCapabilities?) {
        guard let providers else {
            self = .passwordOnly
            return
        }
        let native = oauth?.supportsNative == true
        browserProviders = native
            ? providers.items.filter { $0.isOAuth && Self.nativeStart(of: $0) != nil }
            : []
        acceptsPasswords = providers.passwordLogin ?? true
        supportsSelectAccount = native && oauth?.supportsSelectAccount == true
        oauthProviders = providers.items.filter(\.isOAuth)
        networkProviders = providers.items.filter { $0.isNetwork && NetworkSignIn.apiPath(of: $0) != nil }
    }

    init(browserProviders: [APIv2AuthProvider], acceptsPasswords: Bool, supportsSelectAccount: Bool,
         oauthProviders: [APIv2AuthProvider]? = nil, networkProviders: [APIv2AuthProvider] = []) {
        self.browserProviders = browserProviders
        self.acceptsPasswords = acceptsPasswords
        self.supportsSelectAccount = supportsSelectAccount
        self.oauthProviders = oauthProviders ?? browserProviders
        self.networkProviders = networkProviders
    }

    /// A provider's native start relative to a server's base URL: the
    /// `/api/v2/auth/oauth/<id>/native/start` path and the server's query
    /// items. The app resolves it against the saved base URL
    /// (`NativeSignIn.startURL(_:onServer:)`).
    struct NativeStart: Equatable, Sendable {
        let apiPath: String
        let queryItems: [URLQueryItem]
    }

    /// The provider's native start, read from `native_start_path`. Nil when
    /// the server does not list it or it has another shape.
    static func nativeStart(of provider: APIv2AuthProvider) -> NativeStart? {
        guard let path = provider.nativeStartPath?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/"), !path.hasPrefix("//"), let components = URLComponents(string: path),
              components.scheme == nil, components.host == nil else { return nil }
        guard let apiPath = NativeSignIn.nativeStartAPIPath(components.percentEncodedPath) else { return nil }
        return NativeStart(apiPath: apiPath, queryItems: components.queryItems ?? [])
    }

    /// The button text for a provider. Plugins often configure the whole
    /// label ("Sign in with authentik"); a bare name gets the prefix.
    static func buttonTitle(for provider: APIv2AuthProvider) -> String {
        let name = provider.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "Sign in with single sign-on" }
        let lowered = name.lowercased()
        if ["sign in", "log in", "login", "continue with"].contains(where: { lowered.hasPrefix($0) }) {
            return name
        }
        return "Sign in with \(name)"
    }

    /// The provider's name for sentences ("Connect Keycloak"), without a
    /// "Sign in with" the plugin may have put on its button label.
    static func providerName(for provider: APIv2AuthProvider) -> String {
        let name = provider.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["sign in with ", "log in with ", "login with ", "continue with "]
        where name.lowercased().hasPrefix(prefix) {
            let rest = String(name.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty { return rest }
        }
        return name.isEmpty ? "single sign-on" : name
    }

    /// The provider's icon, resolved against the server URL when the server
    /// sent a site-relative path. Only http(s) URLs are returned.
    static func iconURL(for provider: APIv2AuthProvider, serverURL: String) -> URL? {
        guard let raw = provider.iconUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let resolved: URL?
        if raw.hasPrefix("/") && !raw.hasPrefix("//") {
            resolved = URL(string: ServerRegistry.normalize(url: serverURL) + raw)
        } else {
            resolved = URL(string: raw)
        }
        guard let resolved, let scheme = resolved.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        return resolved
    }
}

/// The login screen's state of discovery for the active server.
enum SignInDiscovery: Equatable, Sendable {
    /// Not answered yet: neither the form nor provider buttons show, so an
    /// OIDC-only server never flashes a password form.
    case loading
    /// A read failed (network, server fault). The password form shows with
    /// a retry, so a transient error never hides the only way in.
    case failed
    case loaded(SignInOptions)

    var options: SignInOptions? {
        if case .loaded(let options) = self { return options }
        return nil
    }
}
