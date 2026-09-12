import Foundation

/// Why a remembered server cannot safely continue into authenticated content.
enum ServerRecoveryReason: String, Equatable, Hashable, Sendable {
    /// The URL still serves Silo, but its database has not been provisioned.
    case needsSetup
    /// The URL no longer exposes the native Silo setup/session contract.
    case serverNotRecognized
}

/// Result of checking a Keychain-restored account against its remembered URL.
///
/// `indeterminate` is deliberately non-destructive. It covers temporary
/// reachability and server failures, and callers must retain their locally
/// resolved auth state so cached/offline content remains available.
enum RestoredSessionValidationResult: Equatable, Sendable {
    case valid
    case needsLogin
    case serverRecovery(ServerRecoveryReason)
    case indeterminate
    case identityChanged
}

/// A small injected boundary around the two requests needed to validate a
/// restored account. Tests supply deterministic closures; production uses the
/// existing unauthenticated setup endpoint followed by the authenticated
/// current-user endpoint.
struct RestoredSessionValidator: Sendable {
    typealias SetupProbe = @Sendable (String) async throws -> SetupStatus
    typealias AccountProbe = @Sendable () async throws -> Void
    typealias IdentityReader = @Sendable () async -> RefreshAccountIdentity?
    typealias AccessTokenReader = @Sendable (String) async -> Bool

    private enum Stage: Equatable {
        case setup
        case account
    }

    private let setupProbe: SetupProbe
    private let accountProbe: AccountProbe
    private let identityReader: IdentityReader
    private let accessTokenReader: AccessTokenReader

    init(
        setupProbe: @escaping SetupProbe,
        accountProbe: @escaping AccountProbe,
        identityReader: @escaping IdentityReader,
        accessTokenReader: @escaping AccessTokenReader
    ) {
        self.setupProbe = setupProbe
        self.accountProbe = accountProbe
        self.identityReader = identityReader
        self.accessTokenReader = accessTokenReader
    }

    static var live: RestoredSessionValidator {
        RestoredSessionValidator(
            setupProbe: { serverURL in
                try await HTTPClient.shared.getUnauthenticated(
                    serverURL: serverURL,
                    path: "/api/v1/auth/setup",
                    quietStatuses: [404]
                )
            },
            accountProbe: {
                _ = try await SiloAPI.shared.currentUser()
            },
            identityReader: {
                await TokenStore.shared.refreshAccountIdentity()
            },
            accessTokenReader: { serverID in
                await TokenStore.shared.hasAccessTokenForActiveServer(serverId: serverID)
            }
        )
    }

    func validate(expected: RefreshAccountIdentity) async -> RestoredSessionValidationResult {
        let setup: SetupStatus
        do {
            setup = try await setupProbe(expected.serverURL)
        } catch {
            return await result(for: error, stage: .setup, expected: expected)
        }

        guard await identityReader() == expected else {
            return .identityChanged
        }
        guard !setup.needsSetup else {
            return .serverRecovery(.needsSetup)
        }

        do {
            try await accountProbe()
        } catch {
            return await result(for: error, stage: .account, expected: expected)
        }

        guard await identityReader() == expected else {
            return .identityChanged
        }
        return .valid
    }

    private func result(
        for error: Error,
        stage: Stage,
        expected: RefreshAccountIdentity
    ) async -> RestoredSessionValidationResult {
        let current = await identityReader()
        guard current?.serverId == expected.serverId,
              current?.serverURL == expected.serverURL else {
            return .identityChanged
        }

        // A terminal refresh rejection advances the credential generation and
        // removes the access token. Check that before the exact-generation
        // guard so an account deletion resolves to login rather than looking
        // like an unrelated server switch.
        let stillHasAccessToken = await accessTokenReader(expected.serverId)
        if !stillHasAccessToken {
            return .needsLogin
        }
        guard current == expected else {
            return .identityChanged
        }

        if error is CancellationError {
            return .indeterminate
        }
        guard let httpError = error as? HTTPError else {
            return .indeterminate
        }

        switch httpError {
        case .requestIdentityChanged:
            return .identityChanged
        case .network, .encodingFailed:
            return .indeterminate
        case .http(let statusCode, _):
            if Self.isRetryable(statusCode) {
                return .indeterminate
            }
            if stage == .account, statusCode == 401 || statusCode == 403 {
                // HTTPClient removes the token before returning only when the
                // refresh endpoint authoritatively rejects it. If the token is
                // still present, refresh may instead have failed transiently;
                // keep the cached session rather than manufacturing a logout.
                return .indeterminate
            }
            return .serverRecovery(.serverNotRecognized)
        case .invalidResponse, .decodingFailed, .serverUrlNotConfigured, .invalidURL:
            return .serverRecovery(.serverNotRecognized)
        }
    }

    static func isRetryable(_ statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
    }
}

/// Resolves the current registry/token/profile combination into the router's
/// auth state. Cold launch can use `resolveLocal()` as an immediate fallback
/// and apply validation only while the splash is still visible; explicit
/// server switches use `resolveValidated()` and await the same policy.
enum RestoredSessionAuthResolver {
    struct LocalResolution: Equatable {
        let state: AppRouter.AuthState
        let restoredAccount: RefreshAccountIdentity?
    }

    static func localState(
        hasServer: Bool,
        hasAccessToken: Bool,
        hasProfile: Bool
    ) -> AppRouter.AuthState {
        guard hasServer else { return .needsServerSetup }
        guard hasAccessToken else { return .needsLogin }
        return hasProfile ? .authenticated : .needsProfile
    }

    static func resolveLocal() async -> LocalResolution {
        let auth = AuthService.shared
        guard auth.hasServer,
              let activeServerID = ServerRegistry.shared.activeServerId,
              !activeServerID.isEmpty else {
            return LocalResolution(state: .needsServerSetup, restoredAccount: nil)
        }

        guard await TokenStore.shared.hasAccessTokenForActiveServer(serverId: activeServerID) else {
            return LocalResolution(state: .needsLogin, restoredAccount: nil)
        }

        let hasProfile = await auth.resolveActiveProfileForSession()
        let account = await TokenStore.shared.refreshAccountIdentity()
        return LocalResolution(
            state: localState(
                hasServer: true,
                hasAccessToken: true,
                hasProfile: hasProfile
            ),
            restoredAccount: account
        )
    }

    static func state(
        after result: RestoredSessionValidationResult,
        fallingBackTo fallback: AppRouter.AuthState
    ) async -> AppRouter.AuthState {
        switch result {
        case .valid, .indeterminate:
            return fallback
        case .needsLogin:
            return .needsLogin
        case .serverRecovery(let reason):
            return .serverRecovery(reason)
        case .identityChanged:
            return await resolveLocal().state
        }
    }

    static func resolveValidated() async -> AppRouter.AuthState {
        let local = await resolveLocal()
        guard let expected = local.restoredAccount else { return local.state }
        let result = await AuthService.shared.validateRestoredSession(expected: expected)
        return await state(after: result, fallingBackTo: local.state)
    }
}
