import Foundation

/// Why a remembered server cannot safely continue into authenticated content.
enum ServerRecoveryReason: String, Equatable, Hashable, Sendable {
    /// The URL still serves Silo, but its database has not been provisioned.
    case needsSetup
    /// The URL no longer exposes the native Silo setup/session contract.
    case serverNotRecognized
    /// The server is v1-only and must be updated for this app version.
    case serverUpdateRequired
    /// The server no longer accepts this app version.
    case appUpdateRequired

    init(_ requirement: UpdateRequirement) {
        switch requirement {
        case .server: self = .serverUpdateRequired
        case .app: self = .appUpdateRequired
        }
    }
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
/// public v2 setup read followed by the authenticated v2 account read.
struct RestoredSessionValidator: Sendable {
    typealias SetupProbe = @Sendable (String) async throws -> APIv2SetupStatus
    typealias AccountProbe = @Sendable () async throws -> Void
    typealias IdentityReader = @Sendable () async -> RefreshAccountIdentity?
    typealias AccessTokenReader = @Sendable (String) async -> Bool
    typealias UpdateRequiredReader = @Sendable () async -> Bool
    typealias ContractRecheck = @Sendable () async -> Void

    private enum Stage: Equatable {
        case setup
        case account
    }

    private let setupProbe: SetupProbe
    private let accountProbe: AccountProbe
    private let identityReader: IdentityReader
    private let accessTokenReader: AccessTokenReader
    private let isServerUpdateRequired: UpdateRequiredReader
    private let contractRecheck: ContractRecheck

    init(
        setupProbe: @escaping SetupProbe,
        accountProbe: @escaping AccountProbe,
        identityReader: @escaping IdentityReader,
        accessTokenReader: @escaping AccessTokenReader,
        isServerUpdateRequired: @escaping UpdateRequiredReader = { false },
        contractRecheck: @escaping ContractRecheck = {}
    ) {
        self.setupProbe = setupProbe
        self.accountProbe = accountProbe
        self.identityReader = identityReader
        self.accessTokenReader = accessTokenReader
        self.isServerUpdateRequired = isServerUpdateRequired
        self.contractRecheck = contractRecheck
    }

    static var live: RestoredSessionValidator {
        live(client: SiloAPI.shared.apiV2Client, tokenStore: .shared)
    }

    /// `GET /api/v2/system/setup` by the remembered URL, then
    /// `GET /api/v2/account/me` for the restored credentials. The account
    /// read also binds the verified account ID to a session installed
    /// without one. When the active server's recorded verdict is v1-only,
    /// the contract probe runs again before the gated account read.
    static func live(
        client: APIv2Client,
        tokenStore: TokenStore,
        isServerUpdateRequired: @escaping UpdateRequiredReader = {
            await MainActor.run { ConnectionMonitor.shared.isServerUpdateRequired }
        },
        contractRecheck: @escaping ContractRecheck = {
            await AuthService.shared.recheckActiveServerContract()
        }
    ) -> RestoredSessionValidator {
        RestoredSessionValidator(
            setupProbe: { serverURL in
                try await client.setupStatus(serverURL: serverURL)
            },
            accountProbe: {
                _ = try await client.currentUser()
            },
            identityReader: {
                await tokenStore.refreshAccountIdentity()
            },
            accessTokenReader: { serverID in
                await tokenStore.hasAccessTokenForActiveServer(serverId: serverID)
            },
            isServerUpdateRequired: isServerUpdateRequired,
            contractRecheck: contractRecheck
        )
    }

    func validate(expected: RefreshAccountIdentity) async -> RestoredSessionValidationResult {
        let setup: APIv2SetupStatus
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

        // The account read is gated on the v1-only verdict, which stays put
        // until a new probe. A v2 setup read that just succeeded means the
        // server may have been updated in place (nothing else probes while
        // the recovery screen is up), so probe again before trusting it.
        // A failed probe leaves the verdict, and the gate would refuse the
        // read anyway, so answer update-required without sending it.
        if await isServerUpdateRequired() {
            await contractRecheck()
            if await isServerUpdateRequired() {
                return await result(for: APIv2Error.serverUpdateRequired, stage: .account, expected: expected)
            }
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
        // A version mismatch is authoritative but never a credential problem:
        // show the update copy and keep the saved session.
        if let requirement = UpdateRequirement(error) {
            return .serverRecovery(ServerRecoveryReason(requirement))
        }
        // `APIv2Client` turns every non-2xx answer into `APIv2Error`;
        // transport, decoding and identity failures stay `HTTPError`.
        switch error {
        case APIv2Error.problem(let problem):
            return Self.result(forStatus: problem.status, stage: stage)
        case APIv2Error.httpStatus(let statusCode):
            return Self.result(forStatus: statusCode, stage: stage)
        case let httpError as HTTPError:
            switch httpError {
            case .requestIdentityChanged, .authorityChanged:
                return .identityChanged
            case .network:
                return .indeterminate
            case .http(let statusCode, _):
                return Self.result(forStatus: statusCode, stage: stage)
            case .invalidResponse, .decodingFailed, .serverUrlNotConfigured, .invalidURL:
                return .serverRecovery(.serverNotRecognized)
            }
        default:
            return .indeterminate
        }
    }

    private static func result(forStatus statusCode: Int, stage: Stage) -> RestoredSessionValidationResult {
        if isRetryable(statusCode) {
            return .indeterminate
        }
        if stage == .account, (statusCode == 401 || statusCode == 403) {
            // HTTPClient removes the token before returning only when the
            // refresh endpoint authoritatively rejects it. If the token is
            // still present, refresh may instead have failed transiently;
            // keep the cached session rather than manufacturing a logout.
            return .indeterminate
        }
        return .serverRecovery(.serverNotRecognized)
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
