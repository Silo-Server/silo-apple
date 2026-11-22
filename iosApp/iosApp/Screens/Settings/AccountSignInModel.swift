import Foundation

/// The account's external sign-in: which provider identities are linked,
/// which providers can be connected from this app, and the connect and
/// disconnect actions. Backs the Settings "Sign-in" page on iOS, iPadOS and
/// macOS.
@MainActor
@Observable
final class AccountSignInModel {
    /// A provider this app can connect, and how.
    struct Connectable: Identifiable, Equatable {
        enum Method: Equatable {
            /// OIDC: local password for a link ticket, then the browser.
            case browser
            /// LDAP: local password plus the directory username and password.
            case directory
            /// A network identity provider (Tailscale): local password only;
            /// the provider's network says who owns this device.
            case network
        }

        let provider: APIv2AuthProvider
        let method: Method
        var id: String { provider.id }
        var name: String { SignInOptions.providerName(for: provider) }
    }

    /// What the directory connect form sends besides the local password.
    struct DirectoryCredentials: Equatable, Sendable {
        let username: String
        let password: String
    }

    private(set) var identities: [APIv2AccountIdentity] = []
    /// Whether the server says an identity can be disconnected now. Nil when
    /// it does not say (an older server); its guard still applies.
    private(set) var canUnlink: Bool?
    private(set) var connectable: [Connectable] = []
    /// Whether connecting a network provider keeps the Silo password. False
    /// on servers that predate `network_link_keeps_password`.
    private(set) var networkLinkKeepsPassword = false
    /// Whether the server serves the account's identities at all.
    private(set) var isSupported = false
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    /// The identity or provider an action is running for.
    private(set) var busyID: String?
    var errorMessage: String?
    var resultMessage: LocalizedStringResource?

    private let api: APIv2Client
    private let tokenStore: TokenStore
    private let link: @Sendable (APIv2AuthProvider, String) async throws -> Void

    init(
        api: APIv2Client,
        tokenStore: TokenStore,
        link: @escaping @Sendable (APIv2AuthProvider, String) async throws -> Void
    ) {
        self.api = api
        self.tokenStore = tokenStore
        self.link = link
    }

    /// Whether Settings shows the Sign-in entry: the server serves identities
    /// and has a provider this app can connect, or the account already has an
    /// identity.
    var showsEntry: Bool { isSupported && (!connectable.isEmpty || !identities.isEmpty) }

    var isBusy: Bool { busyID != nil }

    /// Loads the providers and the account's identities. A server without
    /// external sign-in leaves the page unsupported rather than failing.
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        guard let account = await tokenStore.refreshAccountIdentity() else {
            isSupported = false
            return
        }
        // The account's own server, so providers and identities never come
        // from two different servers.
        let url = account.serverURL
        async let providersRead = try? api.authProviders(serverURL: url)
        async let oauthRead = try? api.oauthCapabilities(serverURL: url)
        async let capabilitiesRead = try? api.externalSignInCapabilities(expectedAccount: account)
        let (providers, oauth, capabilities) = await (providersRead, oauthRead, capabilitiesRead)
        guard let capabilities, capabilities.supportsIdentities else {
            isSupported = false
            identities = []
            canUnlink = nil
            connectable = []
            networkLinkKeepsPassword = false
            return
        }
        do {
            let page = try await api.accountIdentities(expectedAccount: account)
            identities = page.items
            canUnlink = page.canUnlink
            errorMessage = nil
        } catch {
            errorMessage = Self.message(for: error, action: .load)
        }
        connectable = Self.connectable(providers: providers?.items ?? [], oauth: oauth,
            credentialsLinking: capabilities.supportsCredentialsLinking,
            networkLinking: capabilities.supportsNetworkSignIn, linked: identities)
        networkLinkKeepsPassword = capabilities.keepsPasswordOnNetworkLink
        // Last, so the entry never shows before the state it leads to.
        isSupported = true
    }

    /// The external providers the account has no identity at, with how each
    /// connects. A browser provider needs the handshake document's app
    /// linking (`linking`); a directory needs the external sign-in
    /// document's `credentials_linking`, and a network provider its
    /// `network_sign_in`. Servers without them list nothing to connect.
    /// Discovery lists a network provider only over its own network, so it
    /// is offered only while this device reaches the server that way.
    nonisolated static func connectable(providers: [APIv2AuthProvider], oauth: APIv2OAuthCapabilities?,
                                        credentialsLinking: Bool, networkLinking: Bool = false,
                                        linked: [APIv2AccountIdentity]) -> [Connectable] {
        let linkedInstallations = Set(linked.map(\.installationId))
        return providers.compactMap { provider in
            guard let installation = provider.installationId, !linkedInstallations.contains(installation) else {
                return nil
            }
            if provider.isOAuth, oauth?.supportsLinking == true, SignInOptions.nativeStart(of: provider) != nil {
                return Connectable(provider: provider, method: .browser)
            }
            if provider.isCredentials, credentialsLinking {
                return Connectable(provider: provider, method: .directory)
            }
            // Only a provider the login screen can sign in with, so the
            // connection is usable from this app.
            if networkLinking, NetworkSignIn.apiPath(of: provider) != nil {
                return Connectable(provider: provider, method: .network)
            }
            return nil
        }
    }

    /// The Connect sheet's note under the Silo password: what connecting
    /// `item` changes about signing in. OIDC and LDAP links replace the
    /// password; a network link keeps it when the server says so.
    nonisolated static func connectFooter(for item: Connectable, networkLinkKeepsPassword: Bool) -> LocalizedStringResource {
        switch item.method {
        case .directory:
            return .settingsSignInConnectFooterDirectory(item.name)
        case .network:
            // Whole sentences for each case, so a translation can place the
            // owner's name and the provider freely.
            switch (item.provider.networkIdentity?.name, networkLinkKeepsPassword) {
            case (let owner?, true):
                return .settingsSignInConnectFooterNetworkOwnerKeepsPassword(owner, item.name)
            case (let owner?, false):
                return .settingsSignInConnectFooterNetworkOwner(owner, item.name)
            case (nil, true):
                return .settingsSignInConnectFooterNetworkKeepsPassword(item.name)
            case (nil, false):
                return .settingsSignInConnectFooterNetwork(item.name)
            }
        case .browser:
            return .settingsSignInConnectFooterBrowser(item.name)
        }
    }

    /// Connects `provider` after the local password is re-entered: through
    /// the browser for OIDC, with `directory` credentials for LDAP, and with
    /// the password alone for a network provider. Closing the browser sheet
    /// is not an error.
    @discardableResult
    func connect(_ provider: APIv2AuthProvider, password: String,
                 directory: DirectoryCredentials? = nil) async -> Bool {
        guard !isBusy else { return false }
        guard !password.isEmpty else {
            errorMessage = AppLanguage.string(.settingsSignInEnterSiloPassword)
            return false
        }
        if provider.isCredentials {
            guard let directory, !directory.username.trimmingCharacters(in: .whitespaces).isEmpty,
                  !directory.password.isEmpty else {
                errorMessage = AppLanguage.string(.settingsSignInEnterDirectoryCredentials(AppLanguage.isolated(SignInOptions.providerName(for: provider))))
                return false
            }
        }
        busyID = provider.id
        errorMessage = nil
        resultMessage = nil
        defer { busyID = nil }
        do {
            if provider.isCredentials, let directory {
                try await linkDirectory(provider, password: password, directory: directory)
            } else if provider.isNetwork {
                try await linkNetwork(provider, password: password)
            } else {
                try await link(provider, password)
            }
            resultMessage = .settingsSignInConnectedTo(SignInOptions.providerName(for: provider))
            await load()
            return true
        } catch ExternalSignInError.canceled {
            return false
        } catch is CancellationError {
            return false
        } catch {
            errorMessage = provider.isNetwork
                ? NetworkSignIn.linkMessage(for: error, provider: provider)
                : Self.message(for: error, action: .connect)
            return false
        }
    }

    private func linkDirectory(_ provider: APIv2AuthProvider, password: String,
                               directory: DirectoryCredentials) async throws {
        guard let installationId = provider.installationId,
              let account = await tokenStore.refreshAccountIdentity() else {
            throw HTTPError.serverUrlNotConfigured
        }
        _ = try await api.linkIdentityWithCredentials(
            installationId: installationId, password: password,
            username: directory.username.trimmingCharacters(in: .whitespaces),
            directoryPassword: directory.password, expectedAccount: account)
    }

    /// Links the network identity of this device. The server asks the
    /// provider who owns the device that sent the request.
    private func linkNetwork(_ provider: APIv2AuthProvider, password: String) async throws {
        guard let installationId = provider.installationId,
              let account = await tokenStore.refreshAccountIdentity() else {
            throw HTTPError.serverUrlNotConfigured
        }
        _ = try await api.linkIdentityWithNetwork(installationId: installationId, password: password,
            expectedAccount: account)
    }

    /// Disconnects `identity`; the server refuses the account's last way to
    /// sign in.
    @discardableResult
    func disconnect(_ identity: APIv2AccountIdentity) async -> Bool {
        guard !isBusy, let account = await tokenStore.refreshAccountIdentity() else { return false }
        busyID = identity.id
        errorMessage = nil
        resultMessage = nil
        defer { busyID = nil }
        do {
            try await api.deleteAccountIdentity(id: identity.id, expectedAccount: account)
            resultMessage = identity.providerName.isEmpty
                ? .settingsSignInDisconnectedFromUnnamed
                : .settingsSignInDisconnectedFrom(identity.providerName)
            await load()
            return true
        } catch {
            errorMessage = Self.message(for: error, action: .disconnect)
            return false
        }
    }

    enum Action { case load, connect, disconnect }

    /// Why an identity can't be disconnected: the server's refusal, and the
    /// account screen's note when the server says so up front (`can_unlink`).
    nonisolated static var onlySignInMethodMessage: String { AppLanguage.string(.settingsSignInOnlySignInMethodAdministrator) }

    /// The provider is not (or no longer) an enabled provider of its kind.
    nonisolated static var providerGoneMessage: String { AppLanguage.string(.settingsSignInProviderGone) }

    /// Copy for a failed action. Problem identifiers name the server's
    /// refusals; the problem's own text is never shown for these. A
    /// `String`, because the auth layer's messages it passes on are, and
    /// `NetworkSignIn` shows it; resolved in the app language when made.
    nonisolated static func message(for error: Error, action: Action) -> String {
        if let external = error as? ExternalSignInError { return external.message }
        if let requirement = UpdateRequirement(error) { return requirement.message }
        if case APIv2Error.problem(let problem) = error {
            let location = problem.errors?.first?.location
            switch (action, problem.identifier, problem.status) {
            case (.disconnect, "last_sign_in_method", _):
                return onlySignInMethodMessage
            case (.connect, "validation_failed", 422) where location == "body.directory_password":
                return AppLanguage.string(.settingsSignInDirectoryRefusedGeneric)
            case (.connect, "validation_failed", 422) where location == "body.password":
                return AppLanguage.string(.settingsSignInWrongSiloPassword)
            case (.connect, "validation_failed", 422):
                return AppLanguage.string(.settingsSignInCheckEntries)
            case (.connect, "not_permitted", _), (.connect, "identity_linked_elsewhere", _),
                 (.connect, "account_disabled", _), (.connect, "already_linked", _),
                 (.connect, "password_expired", _):
                return ExternalSignInError.reasonText(problem.identifier)
            case (.connect, "local_password_required", _), (.connect, "conflict", 409):
                // The link ticket answers a plain conflict for the same case.
                return AppLanguage.string(.settingsSignInNoLocalPasswordAdministrator)
            case (.connect, _, 404):
                return providerGoneMessage
            case (.disconnect, _, 404):
                return AppLanguage.string(.settingsSignInConnectionGone)
            case (_, "provider_unavailable", _), (_, _, 503):
                return ExternalSignInError.reasonText("provider_unavailable")
            case (_, _, 429):
                return AppLanguage.string(.tvSignInErrorRateLimited)
            case (_, _, 403):
                return AppLanguage.string(.settingsSignInSessionCannotChange)
            default:
                break
            }
        }
        switch action {
        case .load: return AppLanguage.string(.settingsSignInLoadFailed)
        case .connect: return AppLanguage.string(.settingsSignInConnectFailedGeneric)
        case .disconnect: return AppLanguage.string(.settingsSignInDisconnectFailedGeneric)
        }
    }
}

#if !os(tvOS)
extension AccountSignInModel {
    static func live() -> AccountSignInModel {
        AccountSignInModel(
            api: SiloAPI.shared.apiV2Client,
            tokenStore: .shared,
            link: { provider, password in
                try await ExternalSignInService.live.link(provider: provider, password: password)
            }
        )
    }
}
#endif
