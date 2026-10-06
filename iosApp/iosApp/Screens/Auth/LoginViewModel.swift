import Foundation

@MainActor
@Observable
final class LoginViewModel {
    var username: String = ""
    var password: String = ""
    var isLoading: Bool = false
    /// Settable so tests can stage the error the form shows.
    var error: FormError?
    /// What this server offers, once discovery answered.
    var discovery: SignInDiscovery = .loading
    /// Numbers `loadSignInOptions` reads; only the newest one publishes.
    @ObservationIgnored private var discoveryReads = 0
    /// The provider whose browser or network sign-in is running.
    var providerInFlight: String?
    /// Why the last network sign-in ("Continue as …") failed, shown under its
    /// button rather than in the password form.
    var networkSignInError: FormError?

    private let auth: AuthService

    init(auth: AuthService = .shared) {
        self.auth = auth
    }

    var signInOptions: SignInOptions? { discovery.options }

    /// Whether the username and password form is offered: not while
    /// discovery is loading (an OIDC-only server must not flash it), and
    /// always when discovery failed, with a retry beside it.
    var showsPasswordForm: Bool {
        switch discovery {
        case .loading: return false
        case .failed: return true
        case .loaded(let options): return options.showsPasswordForm
        }
    }

    var browserProviders: [APIv2AuthProvider] { signInOptions?.browserProviders ?? [] }

    /// Network providers ("Continue as …"); discovery lists one only when this
    /// device reached the server through that provider's network.
    var networkProviders: [APIv2AuthProvider] { signInOptions?.networkProviders ?? [] }

    /// Whether the screen offers a phone route (device sign-in) beside the
    /// password form. The TV turns it off on a server without device
    /// sign-in, where pointing at the phone would lead nowhere.
    var offersPhoneRoute = true

    /// The TV password form's hint for single sign-on accounts, also added
    /// to its wrong-password message. Nil elsewhere, on servers without an
    /// OAuth provider, and where the screen offers no phone route.
    var phoneHint: String? {
        #if os(tvOS)
        return offersPhoneRoute ? TVSignInPresentation.phoneHint(signInOptions) : nil
        #else
        return nil
        #endif
    }

    /// The hint as its own line under the form: hidden while the error shown
    /// already says it (a wrong password), so it never appears twice.
    var phoneHintLine: String? {
        guard let hint = phoneHint, error?.message.contains(hint) != true else { return nil }
        return hint
    }

    /// Password sign-in is off and no provider can run in this app.
    var offersNoSignIn: Bool { signInOptions?.offersNoSignIn == true }

    /// Whether "Use a different account" is offered under the providers.
    var offersAccountChoice: Bool { signInOptions?.supportsSelectAccount == true && !browserProviders.isEmpty }

    var isBusy: Bool { isLoading || providerInFlight != nil }

    /// Reads provider discovery for the active server. `showsLoading: false`
    /// refreshes behind the current screen (returning to the app) and keeps
    /// loaded options when that read fails.
    func loadSignInOptions(showsLoading: Bool = true) async {
        discoveryReads += 1
        let read = discoveryReads
        if showsLoading { discovery = .loading }
        let options = await auth.signInOptions()
        // A slower, older read never replaces a newer one.
        guard !Task.isCancelled, read == discoveryReads else { return }
        if let options {
            discovery = .loaded(options)
        } else if showsLoading || discovery.options == nil {
            discovery = .failed
        }
    }

    /// Authenticate with username and password. Returns whether the
    /// sign-in succeeded (and routed on).
    @discardableResult
    @MainActor
    func login(router: AppRouter) async -> Bool {
        guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
            error = FormError("Please enter your username.")
            return false
        }
        guard !password.isEmpty else {
            error = FormError("Please enter your password.")
            return false
        }

        isLoading = true
        error = nil
        networkSignInError = nil
        defer { isLoading = false }

        do {
            try await auth.login(username: username, password: password)
            StartupContentPrefetcher.prefetchProfiles()
            router.skipsSingleProfilePicker = true
            router.showProfileSelection()
            return true
        } catch let loginError {
            self.error = FormError(Self.message(for: loginError, browserProviders: browserProviders,
                phoneHint: phoneHint, offersPhoneRoute: offersPhoneRoute))
            return false
        }
    }

    /// Signs this device's owner in through a network provider ("Continue
    /// as …"), then routes on like a password sign-in, unless the app left
    /// the sign-in screen meanwhile ("Change server"). Returns whether it
    /// succeeded. A refusal shows under the button (`networkSignInError`).
    @discardableResult
    func signInWithNetworkIdentity(_ provider: APIv2AuthProvider, router: AppRouter) async -> Bool {
        guard !isBusy else { return false }
        let route = router.authState
        providerInFlight = provider.id
        error = nil
        networkSignInError = nil
        defer { providerInFlight = nil }
        do {
            try await auth.signInWithNetworkIdentity(provider)
            guard router.authState == route else { return true }
            StartupContentPrefetcher.prefetchProfiles()
            router.skipsSingleProfilePicker = true
            router.showProfileSelection()
            return true
        } catch {
            networkSignInError = NetworkSignIn.signInMessage(for: error, provider: provider).map(FormError.init)
            return false
        }
    }

    #if !os(tvOS)
    /// Signs in through `provider` in the system browser, then routes on like
    /// a password sign-in. Closing the sheet is not an error. `choosingAccount`
    /// is "Use a different account"; the first browser sign-in after an
    /// explicit sign-out asks for an account choice too.
    func signIn(with provider: APIv2AuthProvider, router: AppRouter, choosingAccount: Bool = false) async {
        guard !isBusy else { return }
        let serverId = ServerRegistry.shared.activeServerId ?? ""
        let prompt = SelectAccountPrompt.shared
        let selectAccount = Self.asksToSelectAccount(options: signInOptions, choosingAccount: choosingAccount,
            afterSignOut: prompt.isRequested(serverId: serverId))
        providerInFlight = provider.id
        error = nil
        networkSignInError = nil
        defer { providerInFlight = nil }
        do {
            try await ExternalSignInService.live.signIn(with: provider, selectAccount: selectAccount)
            prompt.clear(serverId: serverId)
            StartupContentPrefetcher.prefetchProfiles()
            router.skipsSingleProfilePicker = true
            router.showProfileSelection()
        } catch {
            self.error = Self.browserSignInMessage(for: error).map(FormError.init)
        }
    }

    /// Starts the browser sign-in by itself when "Not you? Switch account"
    /// sent the person here and the server lists exactly one provider.
    ///
    /// SwiftUI can build a login screen and drop it while the app routes
    /// here after the sign-out; that screen's task is already cancelled, so
    /// it leaves the request to the screen that stays, and hands it back if
    /// it goes away before the sign-in finished.
    func startRequestedSignIn(router: AppRouter) async {
        guard !Task.isCancelled, signInOptions != nil, let serverId = ServerRegistry.shared.activeServerId,
              SelectAccountPrompt.shared.consumeAutoStart(serverId: serverId),
              browserProviders.count == 1, let provider = browserProviders.first else { return }
        await signIn(with: provider, router: router)
        if Task.isCancelled {
            SelectAccountPrompt.shared.restoreAutoStart(serverId: serverId)
        }
    }
    #endif

    /// Whether a browser sign-in sends `prompt=select_account`: asked for
    /// ("Use a different account") or owed after an explicit sign-out, and
    /// only to a server that advertises it.
    nonisolated static func asksToSelectAccount(options: SignInOptions?, choosingAccount: Bool,
                                                afterSignOut: Bool) -> Bool {
        options?.supportsSelectAccount == true && (choosingAccount || afterSignOut)
    }

    /// Copy for a failed browser sign-in; nil when the person canceled it.
    nonisolated static func browserSignInMessage(for error: Error) -> String? {
        if let external = error as? ExternalSignInError {
            return external == .canceled ? nil : external.message
        }
        if error is CancellationError { return nil }
        return message(for: error)
    }

    /// The sign-in failure as the login form shows it. Silo's v2 login
    /// rejects with problem documents, so only a problem's status says what
    /// went wrong; a bare 401 or 403 comes from something in front of the
    /// server (an authenticating proxy or WAF) and must not blame the
    /// credentials. A bare 429 still reads as rate limiting, since limiters
    /// may answer without a problem body. An update requirement (v1-only
    /// server, or 410 `client_upgrade_required`) keeps its own copy.
    /// External sign-in refusals (password sign-in turned off, a directory
    /// that refuses the account) are named by the problem's identifier;
    /// `browserProviders` are the providers the screen offers instead.
    /// `phoneHint` (the TV's) follows a wrong password: the account may
    /// sign in with a provider and have no password at all.
    /// `offersPhoneRoute` is false where the screen offers no phone route
    /// (see `LoginViewModel.offersPhoneRoute`); no message points there.
    /// Anything else falls back to the error's description.
    nonisolated static func message(for error: Error, browserProviders: [APIv2AuthProvider] = [],
                                    phoneHint: String? = nil, offersPhoneRoute: Bool = true) -> String {
        if let requirement = UpdateRequirement(error) { return requirement.message }
        let status: Int
        switch error {
        case APIv2Error.problem(let problem):
            if let text = externalSignInText(problem.identifier, browserProviders: browserProviders,
                                              offersPhoneRoute: offersPhoneRoute) { return text }
            status = problem.status
        case APIv2Error.httpStatus(429): return rateLimitedMessage
        default: return error.localizedDescription
        }
        switch status {
        case 401:
            let wrong = "Incorrect username or password."
            return phoneHint.map { "\(wrong) \($0)" } ?? wrong
        case 403:
            return "This account can't sign in. Contact your server administrator."
        case 400, 422:
            return "Check your username and password, then try again."
        case 429:
            return rateLimitedMessage
        default:
            return error.localizedDescription
        }
    }

    nonisolated private static func externalSignInText(_ identifier: String, browserProviders: [APIv2AuthProvider],
                                                       offersPhoneRoute: Bool) -> String? {
        switch identifier {
        case "local_login_disabled":
            return localLoginDisabledText(browserProviders: browserProviders, offersPhoneRoute: offersPhoneRoute)
        case "password_expired", "not_permitted", "email_in_use", "identity_linked_elsewhere", "provider_unavailable",
             "account_required":
            return ExternalSignInError.reasonText(identifier)
        default:
            return nil
        }
    }

    /// The server-wide switch refused a correct password. The TV cannot run
    /// a provider sign-in, so it points at the phone when the screen offers
    /// that route; elsewhere the screen's own provider is named when it
    /// offers exactly one.
    nonisolated static func localLoginDisabledText(browserProviders: [APIv2AuthProvider],
                                                   offersPhoneRoute: Bool = true) -> String {
        let off = "Password sign-in is turned off on this server."
        #if os(tvOS)
        return offersPhoneRoute ? "\(off) Use your phone instead." : off
        #else
        switch browserProviders.count {
        case 0: return off
        case 1: return "\(off) Sign in with \(SignInOptions.providerName(for: browserProviders[0])) instead."
        default: return "\(off) Use a sign-in provider above instead."
        }
        #endif
    }

    nonisolated static let rateLimitedMessage = "Too many sign-in attempts. Wait a moment, then try again."
}
