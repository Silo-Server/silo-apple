import Foundation
import Synchronization

struct RefreshAccountIdentity: Hashable, Sendable {
    let serverId: String
    let serverURL: String
    /// Process-local epoch for the exact credential owner. Persistent epochs
    /// change on login/sign-out/retarget; temporary scopes supply their stable
    /// handoff generation. Guarded refresh rotation preserves the epoch.
    let credentialGenerationID: UUID
    /// The saved account (`Account.localAccountId`) whose credentials
    /// requests send. Nil while no account is signed in on the server and
    /// for a temporary playback scope, which belongs to another device.
    let localAccountId: String?

    init(serverId: String, serverURL: String, credentialGenerationID: UUID, localAccountId: String? = nil) {
        self.serverId = serverId
        self.serverURL = serverURL
        self.credentialGenerationID = credentialGenerationID
        self.localAccountId = localAccountId
    }
}

struct CapturedRefreshCredential: Equatable, Sendable {
    let account: RefreshAccountIdentity
    let refreshToken: String
    let owner: CapturedHTTPRequestCredentialOwner
}

/// One actor-consistent snapshot of every mutable credential field an
/// ordinary request sends. The account includes temporary-owner generation;
/// profile identity is kept alongside it so a 401 can never retry under a
/// profile selected after the original request left the client.
struct CapturedOrdinaryRequestAuth: Equatable, Sendable {
    let account: RefreshAccountIdentity
    let credentialOwner: CapturedHTTPRequestCredentialOwner
    let accessToken: String?
    let profileId: String?
    let profileToken: String?
}

extension CapturedOrdinaryRequestAuth {
    /// The one ownership comparator. Two captures describe the same owner when
    /// every stored identity field matches: the account (server, URL, and
    /// process-local credential generation), the credential owner (persistent
    /// slot or temporary handoff), the selected profile, and the profile
    /// verification proof (`profileToken`). Only `accessToken` is excluded:
    /// a shared refresh rotates it without changing who owns the request, and
    /// `currentOrdinaryRequestAuth(matchingIdentityOf:)` relies on that to
    /// detect a completed rotation.
    ///
    /// Every fence in the client must go through this method or through
    /// `TokenStore.withOwnerFence`. A hand-written subset of these fields is a
    /// leak: a response could be applied under a profile or owner that
    /// replaced the one that issued the request.
    func sameCredentialIdentity(as other: CapturedOrdinaryRequestAuth) -> Bool {
        account == other.account
            && credentialOwner == other.credentialOwner
            && profileId == other.profileId
            && profileToken == other.profileToken
    }
}

/// Which credentials and profile requests would go out under, read without
/// awaiting the token store. Work that must run under the owner it was
/// started by records this when it starts and compares a later
/// `CapturedOrdinaryRequestAuth` with `matches(_:)`.
struct CredentialOwnerSnapshot: Equatable, Sendable {
    let credentialGenerationID: UUID
    let profileId: String?

    func matches(_ auth: CapturedOrdinaryRequestAuth) -> Bool {
        auth.account.credentialGenerationID == credentialGenerationID && auth.profileId == profileId
    }
}

/// Durable account owner for queued or persisted work. Unlike the request
/// owner it survives access-token rotation and profile switches: it is bound
/// to the verified account id and the account epoch installed by a login.
struct CapturedDurableAccountAuth: Sendable {
    /// The server's user ID (`Account.serverUserId`).
    let accountID: String
    let accountEpoch: UUID
    let request: CapturedOrdinaryRequestAuth

    /// The saved account on this device (`Account.localAccountId`), which
    /// the request identity carries.
    var localAccountId: String? { request.account.localAccountId }
}

/// One account signed out by `TokenStore.signOutActiveAccount()`.
struct AccountSignOutResult: Equatable, Sendable {
    let serverId: String
    /// The removed account. Callers delete the local data keyed by it. Nil
    /// when the server had no saved account.
    let localAccountId: String?
    /// False when the account record could not be removed, so the session
    /// can return after a relaunch.
    let durable: Bool
}

enum RejectedRefreshDisposition: Equatable, Sendable {
    case persistentSessionCleared
    case temporarySessionExpired
}

/// Nonsecret notification payload identifying the exact rejected credential
/// epoch. Consumers revalidate it with TokenStore immediately before routing
/// or tearing down a temporary playback identity.
struct SessionExpiryEvent: Equatable, Sendable {
    let account: RefreshAccountIdentity
    let disposition: RejectedRefreshDisposition
}

/// Nonsecret notification payload naming the account and profile whose
/// verification proof the server stopped accepting. The account session is
/// still valid; only the profile needs selecting and verifying again.
struct ProfileVerificationRequiredEvent: Equatable, Sendable {
    let account: RefreshAccountIdentity
    let profileID: String
    /// `TokenStore`'s process-local generation for the selection that sent
    /// the rejected proof. It names that installation without carrying the
    /// proof, so recovery can leave a later selection of the same profile
    /// alone.
    let profileSelection: UUID
}

struct TemporaryAuthScope: Equatable, Sendable {
    /// Stable for this installed credential overlay and replaced whenever a
    /// new remote-playback handoff is activated.
    let credentialGenerationID: UUID
    let serverId: String
    let serverURL: String
    var accessToken: String
    var refreshToken: String
    var profileId: String
    var profileToken: String
    let controllerDeviceId: String
    let expiresAt: Date

    init(
        credentialGenerationID: UUID = UUID(),
        serverId: String,
        serverURL: String,
        accessToken: String,
        refreshToken: String,
        profileId: String,
        profileToken: String,
        controllerDeviceId: String,
        expiresAt: Date
    ) {
        self.credentialGenerationID = credentialGenerationID
        self.serverId = serverId
        self.serverURL = serverURL
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.profileId = profileId
        self.profileToken = profileToken
        self.controllerDeviceId = controllerDeviceId
        self.expiresAt = expiresAt
    }
}

/// Exact temporary-owner state displaced by a handoff activation. Keeping the
/// rejection bit with the credentials lets a cancelled replacement restore
/// the prior generation without silently making a terminally rejected scope
/// refreshable again.
struct TemporaryAuthScopeSnapshot: Equatable, Sendable {
    let scope: TemporaryAuthScope?
    fileprivate let wasRefreshRejected: Bool
}

/// Atomic result of ending one temporary credential generation. Callers must
/// distinguish an already-absent scope (the requested generation is gone) from
/// a different installed generation (a replacement owns the slot).
enum TemporaryAuthScopeEndResult: Equatable, Sendable {
    case ended(TemporaryAuthScope)
    case alreadyAbsent
    case differentGeneration(activeGenerationID: UUID)
}

/// Actor that signs requests with the active account's credentials and
/// owns their refresh. Accounts, their tokens and the selection persist in
/// `AccountStore`; this actor caches the active server's selected account,
/// routes every credential change through the store, and keeps the active
/// server URL and profile id in `SharedDefaults`. The active access and
/// profile tokens are mirrored to fixed Keychain accounts for the extensions.
/// `HTTPClient` collapses concurrent 401s into one refresh per
/// `RefreshAccountIdentity`.
actor TokenStore {
    static let shared = TokenStore()

    static let accountCredentialAudience: KeychainAudience = .userIndependent
    static let profileCredentialAudience: KeychainAudience = .currentUser

    private let accountKeychain: SharedKeychain
    private let profileKeychain: SharedKeychain
    private let defaults: SharedDefaults
    private let accounts: AccountStore
    #if os(iOS)
    private let displayTargets: ApplePushDisplayTargetStore
    #endif
    /// The active server's selected account while it is signed in and saved
    /// for the registry URL. Its tokens are what requests send.
    private var activeAccount: Account?
    /// Servers whose saved accounts could not be read or written. Requests on
    /// them carry no credentials until the next install.
    private var runtimeBlockedServers: Set<String> = []

    private let serverUrlDefaultsKey = SharedStorage.serverUrlKey
    private let profileIdDefaultsKey = SharedStorage.profileIdKey

    /// Server whose tokens are currently cached in `cached*` and returned
    /// by `getAccessToken` etc. Empty string means "no active server" —
    /// reads return nil and saves no-op.
    private var activeServerId: String = ""

    private var cachedAccessToken: String? { activeAccount?.accessToken }
    private var cachedRefreshToken: String? { activeAccount?.refreshToken }
    private var cachedProfileToken: String?
    /// Process-local identity for the persistent credential slot currently
    /// selected by `activeServerId`. Refresh rotation leaves it unchanged;
    /// every session replacement or routing boundary installs a fresh epoch.
    private var persistentCredentialGenerationID = UUID() {
        didSet { publishOwnerMirror() }
    }
    /// Process-local identity for one installation of the persistent profile
    /// ID and proof. Every activation, deactivation, or direct profile write
    /// replaces it, so selecting the same profile again with the same proof
    /// (or with none) is still a new selection.
    private var profileSelectionGeneration = UUID()
    /// Playback-scoped credentials received by a TV through remote handoff.
    /// They are process-only and never written into normal per-server slots.
    private var temporaryScope: TemporaryAuthScope? {
        didSet { publishOwnerMirror() }
    }
    /// Lock-protected copy of the owner fields `ownerSnapshot` needs beyond
    /// the persisted profile selection, kept in step by the `didSet`s above.
    private let ownerMirror: Mutex<(persistentGeneration: UUID, temporary: (generation: UUID, profileId: String)?)>
    /// A terminally rejected temporary generation remains installed until
    /// remote-playback teardown, but it must never submit its refresh token
    /// again or emit duplicate expiry notifications.
    private var rejectedTemporaryCredentialGenerations: Set<UUID> = []
    /// Server the current cache was loaded for. Nil means the cache is
    /// invalid and must be re-read on next access.
    private var loadedForServerId: String?

    /// Last values written to the shared-extension keychain slots. Skips
    /// redundant Keychain writes; the access value is re-mirrored after every
    /// refresh.
    private var lastMirroredAccessToken: String?
    private var lastMirroredProfileToken: String?

    init(keychain: SharedKeychain = SharedKeychain(),
         defaults: SharedDefaults = .shared,
         accounts: AccountStore? = nil) {
        self.accountKeychain = keychain.withAudience(Self.accountCredentialAudience)
        self.profileKeychain = keychain.withAudience(Self.profileCredentialAudience)
        self.defaults = defaults
        self.accounts = accounts ?? AccountStore(keychain: keychain, defaults: defaults)
        let generation = UUID()
        self.persistentCredentialGenerationID = generation
        self.ownerMirror = Mutex((persistentGeneration: generation, temporary: nil))
        #if os(iOS)
        self.displayTargets = ApplePushDisplayTargetStore(keychain: keychain.withAudience(Self.profileCredentialAudience))
        #endif
    }

    // MARK: - Diagnostics
    //
    // Session lines are deliberately outcome-only. Everything this actor holds
    // — access/refresh/profile tokens, profile ids, server ids (base64 of the
    // server URL, so an id *is* the hostname), server URLs — is credential or
    // identifying material and must never reach a log line, not truncated and
    // not hashed. What a report needs to explain "I got logged out" is the
    // sequence of outcomes and a stable classification of each refusal, so
    // that is all these emit: a fixed `phase`, a fixed `outcome`, and a fixed
    // `reason`, every one of them a compile-time literal.

    /// Durable session-event line. Breadcrumbs are the right destination
    /// because a rejected refresh is frequently followed by the user killing
    /// the app, and the in-memory ring would not survive that.
    private func recordSessionEvent(phase: String, outcome: String, reason: String) {
        #if os(iOS) || os(tvOS)
        DiagTrace.breadcrumb(
            .essential,
            category: .lifecycle,
            tag: "Auth",
            message: "session credential event",
            attrs: [
                "phase": .string(phase),
                "outcome": .string(outcome),
                "reason": .string(reason),
            ]
        )
        #endif
    }

    /// Fixed classification of a session-persistence failure for
    /// `recordSessionEvent`. The error itself never reaches the breadcrumb;
    /// only one of these literals does.
    private static func persistenceFailureReason(_ error: Error) -> String {
        switch error {
        case AccountStoreError.writeFailed: return "persistenceUnavailable"
        case AccountStoreError.corrupt, AccountStoreError.unsupportedVersion, AccountStoreError.keyMismatch:
            return "invalidSessionRecord"
        case AccountStoreError.invalidIdentity: return "invalidSessionIdentity"
        case AccountStoreError.credentialsChanged, AccountStoreError.notFound: return "canonicalSessionMismatch"
        case is SharedKeychain.ReadError: return "keychainReadFailed"
        default: return "persistenceUnavailable"
        }
    }

    // MARK: - Active server

    /// Point the Keychain reads at a different server. Flushes the
    /// in-memory cache so the next access re-reads from the new slot.
    /// Idempotent: a no-op if `serverId` is already active.
    func switchActiveServer(serverId: String) {
        guard serverId != activeServerId else { return }
        retargetActiveServer(serverId: serverId)
        ensureLoaded()
        mirrorActiveTokensForExtension()
    }

    /// Retarget the actor to the active registry server without touching
    /// Keychain. Used during cold launch so route selection can avoid doing
    /// the full token load + Top Shelf mirror before SwiftUI leaves `.loading`.
    func retargetActiveServer(serverId: String) {
        if serverId == activeServerId { return }
        persistentCredentialGenerationID = UUID()
        activeServerId = serverId
        activeAccount = nil
        cachedProfileToken = nil
        loadedForServerId = nil
    }

    /// Reads the active server's account again after a server merge
    /// (`ServerRegistry.mergeDuplicateServers`) moved accounts onto it or
    /// removed the one in use. A no-op while temporary credentials are in use.
    func reloadAfterServerMerge() {
        guard temporaryScope == nil, !activeServerId.isEmpty else { return }
        let previous = activeAccount?.credentials
        loadedForServerId = nil
        ensureLoaded()
        guard activeAccount?.credentials != previous else { return }
        persistentCredentialGenerationID = UUID()
        mirrorActiveTokensForExtension()
    }

    /// Make another saved account on the active server the one requests use,
    /// for the current device user. The profile is cleared; the caller then
    /// selects one of the account's profiles. False when the account isn't
    /// saved and signed in on the active server, or the selection didn't save.
    func switchActiveAccount(localAccountId: String) -> Bool {
        guard temporaryScope == nil, !activeServerId.isEmpty else { return false }
        ensureLoaded()
        if activeAccount?.localAccountId == localAccountId { return true }
        guard let account = try? accounts.account(localAccountId, onServer: activeServerId),
              account.isSignedIn, accounts.select(account) else { return false }
        try? accounts.markUsed(localAccountId, onServer: activeServerId)
        defaults.removeObject(forKey: profileIdDefaultsKey)
        profileSelectionGeneration = UUID()
        persistentCredentialGenerationID = UUID()
        // An explicit switch to a readable, signed-in account lifts a block
        // left by signing out of another account here, as an install does;
        // a read error while loading it blocks the server again.
        runtimeBlockedServers.remove(activeServerId)
        loadedForServerId = nil
        ensureLoaded()
        mirrorActiveTokensForExtension()
        let switched = activeAccount?.localAccountId == localAccountId
        #if os(iOS)
        // The server's push installation moves to this account at the next
        // generation, with the same key.
        if switched {
            Task { @MainActor in await ApplePushRegistrationCoordinator.shared.activeAccountDidChange() }
        }
        #endif
        return switched
    }

    /// The current active server ID. Empty string if none.
    func getActiveServerId() -> String { temporaryScope?.serverId ?? activeServerId }

    /// Atomically capture the account-level identity that owns refresh-token
    /// rotation. Both ordinary and captured-identity HTTP requests use this
    /// key to join one refresh flight.
    func refreshAccountIdentity() -> RefreshAccountIdentity? {
        let scope = temporaryScope
        let serverId = scope?.serverId ?? activeServerId
        let serverURL = ServerRegistry.normalize(
            url: scope?.serverURL
                ?? defaults.string(forKey: serverUrlDefaultsKey)
                ?? ""
        )
        guard !serverId.isEmpty, !serverURL.isEmpty else { return nil }
        if scope == nil { ensureLoaded() }
        return RefreshAccountIdentity(
            serverId: serverId,
            serverURL: serverURL,
            credentialGenerationID: scope?.credentialGenerationID
                ?? persistentCredentialGenerationID,
            localAccountId: scope == nil ? activeAccount?.localAccountId : nil
        )
    }

    /// One shared binding for future queued authenticated operations. Unverified
    /// legacy sessions and temporary playback credentials cannot acquire it.
    func captureDurableAccountAuth() -> CapturedDurableAccountAuth? {
        guard temporaryScope == nil, let request = captureOrdinaryRequestAuth(),
              !runtimeBlockedServers.contains(activeServerId), let account = activeAccount,
              let accountID = account.serverUserId, let epoch = account.epoch,
              account.origin == request.account.serverURL, account.accessToken == request.accessToken else { return nil }
        return CapturedDurableAccountAuth(accountID: accountID, accountEpoch: epoch, request: request)
    }

    /// Execute a synchronous effect in the same actor turn as its durable
    /// authority check. No credential/profile mutation can interleave before
    /// the effect. Throws `HTTPError.authorityChanged` when the verified
    /// account, its epoch, or the request owner moved since `expected` was
    /// captured.
    ///
    /// The request owner is compared with `sameCredentialIdentity(as:)`, not
    /// `==`: a durable authority is meant to outlive access-token rotation, so
    /// the rotated token must not make queued work look foreign. Profile and
    /// credential-owner changes still break it, because the queued work was
    /// prepared for that profile's view of the account.
    func withCurrentDurableAuthority(_ expected: CapturedDurableAccountAuth,
                                     operation: @Sendable () throws -> Void) throws {
        try Task.checkCancellation()
        guard let current = captureDurableAccountAuth(), current.accountID == expected.accountID,
              current.accountEpoch == expected.accountEpoch,
              current.request.sameCredentialIdentity(as: expected.request) else {
            throw HTTPError.authorityChanged
        }
        try operation()
    }

    /// Capture the account, credential owner, and complete request auth header
    /// set in one actor turn. The request carries this immutable identity
    /// through its 401 path so a later server, temporary-owner, or profile
    /// switch cannot redirect its refresh or produce mixed headers.
    func captureOrdinaryRequestAuth() -> CapturedOrdinaryRequestAuth? {
        guard let account = refreshAccountIdentity() else { return nil }
        if let temporaryScope {
            return CapturedOrdinaryRequestAuth(
                account: account,
                credentialOwner: .temporary,
                accessToken: temporaryScope.accessToken,
                profileId: temporaryScope.profileId,
                profileToken: temporaryScope.profileToken
            )
        }

        ensureLoaded()
        return CapturedOrdinaryRequestAuth(
            account: account,
            credentialOwner: .persistentServer(serverId: account.serverId),
            accessToken: cachedAccessToken,
            profileId: defaults.string(forKey: profileIdDefaultsKey),
            profileToken: cachedProfileToken
        )
    }

    /// Capture the refresh credential and its owner in the same actor turn as
    /// the account identity check. A refresh response must carry this snapshot
    /// back to its save/invalidation operation so it cannot affect credentials
    /// installed by a later server switch, sign-out, or token rotation.
    func captureRefreshCredential(expected: RefreshAccountIdentity) -> CapturedRefreshCredential? {
        guard refreshAccountIdentity() == expected else { return nil }
        if let temporaryScope {
            guard expected.credentialGenerationID == temporaryScope.credentialGenerationID,
                  !rejectedTemporaryCredentialGenerations.contains(temporaryScope.credentialGenerationID),
                  !temporaryScope.refreshToken.isEmpty else { return nil }
            return CapturedRefreshCredential(
                account: expected,
                refreshToken: temporaryScope.refreshToken,
                owner: .temporary
            )
        }

        ensureLoaded()
        guard let cachedRefreshToken, !cachedRefreshToken.isEmpty else { return nil }
        return CapturedRefreshCredential(
            account: expected,
            refreshToken: cachedRefreshToken,
            owner: .persistentServer(serverId: expected.serverId)
        )
    }

    /// Atomically re-capture the current ordinary-request auth only if its
    /// account owner/generation and profile identity still match `expected`.
    /// Access-token rotation is intentionally excluded from the identity
    /// comparison so callers can detect a completed shared refresh.
    func currentOrdinaryRequestAuth(
        matchingIdentityOf expected: CapturedOrdinaryRequestAuth
    ) -> CapturedOrdinaryRequestAuth? {
        guard let current = captureOrdinaryRequestAuth(),
              current.sameCredentialIdentity(as: expected) else {
            return nil
        }
        return current
    }

    /// The current profile selection generation, only while the persistent
    /// account still sends exactly the identity in `expected`. Nil while a
    /// temporary scope owns requests or the identity has changed.
    func profileSelectionGeneration(
        matchingIdentityOf expected: CapturedOrdinaryRequestAuth
    ) -> UUID? {
        guard temporaryScope == nil,
              currentOrdinaryRequestAuth(matchingIdentityOf: expected) != nil else {
            return nil
        }
        return profileSelectionGeneration
    }

    /// Whether `generation` is still the installed persistent profile
    /// selection.
    func isCurrentProfileSelection(_ generation: UUID) -> Bool {
        temporaryScope == nil && profileSelectionGeneration == generation
    }

    /// Ownership fence for one awaited operation.
    ///
    /// `auth` is the owner captured with `captureOrdinaryRequestAuth()` before
    /// the caller left the actor. The fence checks that owner is still current
    /// immediately before `body` runs and again after it returns, and throws
    /// `HTTPError.authorityChanged` on either mismatch so a response can never
    /// be applied to a profile, server, or temporary scope that replaced the one
    /// that issued the request. The comparison is `sameCredentialIdentity(as:)`:
    /// a shared refresh that only rotated the access token passes.
    ///
    /// The actor is not held while `body` is suspended, so `body` may call back
    /// into the store or into other actors freely.
    func withOwnerFence<T: Sendable>(
        _ auth: CapturedOrdinaryRequestAuth,
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        guard currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.authorityChanged
        }
        let value = try await body()
        guard currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.authorityChanged
        }
        return value
    }

    /// An approved handoff must still belong to the owner captured before polling.
    func beginTemporaryScope(_ scope: TemporaryAuthScope, expected: AccountInstallationExpectation) -> TemporaryAuthScopeSnapshot? {
        guard captureAccountInstallationExpectation() == expected else { return nil }
        return beginTemporaryScope(scope)
    }

    @discardableResult
    func beginTemporaryScope(_ scope: TemporaryAuthScope) -> TemporaryAuthScopeSnapshot {
        let previous = TemporaryAuthScopeSnapshot(
            scope: temporaryScope,
            wasRefreshRejected: temporaryScope.map {
                rejectedTemporaryCredentialGenerations.contains($0.credentialGenerationID)
            } ?? false
        )
        if let previous = temporaryScope,
           previous.credentialGenerationID != scope.credentialGenerationID {
            rejectedTemporaryCredentialGenerations.remove(previous.credentialGenerationID)
        }
        temporaryScope = scope
        return previous
    }

    /// Roll back a just-installed scope only while it is still the active
    /// generation. A newer activation wins and is never overwritten by a
    /// delayed cancellation cleanup.
    @discardableResult
    func restoreTemporaryScope(
        _ snapshot: TemporaryAuthScopeSnapshot,
        replacingGenerationID: UUID
    ) -> Bool {
        guard temporaryScope?.credentialGenerationID == replacingGenerationID else {
            return false
        }
        rejectedTemporaryCredentialGenerations.remove(replacingGenerationID)
        temporaryScope = snapshot.scope
        if snapshot.wasRefreshRejected, let restored = snapshot.scope {
            rejectedTemporaryCredentialGenerations.insert(restored.credentialGenerationID)
        }
        return true
    }

    @discardableResult
    func endTemporaryScope(
        expectedGenerationID: UUID? = nil
    ) -> TemporaryAuthScopeEndResult {
        guard let scope = temporaryScope else { return .alreadyAbsent }
        if let expectedGenerationID,
           scope.credentialGenerationID != expectedGenerationID {
            return .differentGeneration(
                activeGenerationID: scope.credentialGenerationID
            )
        }
        rejectedTemporaryCredentialGenerations.remove(scope.credentialGenerationID)
        temporaryScope = nil
        return .ended(scope)
    }

    func getTemporaryScope() -> TemporaryAuthScope? { temporaryScope }

    func hasTemporaryScope() -> Bool { temporaryScope != nil }

    /// Atomically verify a queued request's routing identity and snapshot the
    /// matching credentials. No mutable global scope is installed: the caller
    /// carries this value for one explicit request only.
    func captureRequestAuth(expected: HTTPRequestIdentity) throws -> CapturedHTTPRequestAuth {
        let expectedURL = ServerRegistry.normalize(url: expected.serverURL)
        guard let account = refreshAccountIdentity() else {
            // No resolvable account at all: the registry has no active server,
            // or its URL mirror is missing. Distinct from a mismatch below,
            // because it means requests are being issued with nothing to
            // authenticate against rather than against the wrong thing.
            recordSessionEvent(
                phase: "captureRequestAuth",
                outcome: "failed",
                reason: "noAccountIdentity"
            )
            throw HTTPError.requestIdentityChanged
        }
        let currentServerId = temporaryScope?.serverId ?? activeServerId
        let currentURL = ServerRegistry.normalize(
            url: temporaryScope?.serverURL
                ?? defaults.string(forKey: serverUrlDefaultsKey)
                ?? ""
        )
        let currentProfileId = temporaryScope?.profileId
            ?? defaults.string(forKey: profileIdDefaultsKey)

        guard !expected.serverId.isEmpty,
              !expectedURL.isEmpty,
              !expected.profileId.isEmpty,
              currentServerId == expected.serverId,
              currentURL == expectedURL,
              account.serverId == expected.serverId,
              account.serverURL == expectedURL,
              currentProfileId == expected.profileId else {
            // Which identity field moved is the whole diagnostic value here:
            // "server switched mid-flight" and "profile switched mid-flight"
            // produce identical user-visible failures but have different
            // causes. The classifier takes only the already-evaluated
            // booleans, so no identifier can reach the log line.
            recordSessionEvent(
                phase: "captureRequestAuth",
                outcome: "failed",
                reason: Self.requestIdentityMismatchReason(
                    hasExpectedServerId: !expected.serverId.isEmpty,
                    hasExpectedServerURL: !expectedURL.isEmpty,
                    hasExpectedProfileId: !expected.profileId.isEmpty,
                    serverIdMatches: currentServerId == expected.serverId,
                    serverURLMatches: currentURL == expectedURL,
                    accountServerIdMatches: account.serverId == expected.serverId,
                    accountServerURLMatches: account.serverURL == expectedURL,
                    profileMatches: currentProfileId == expected.profileId
                )
            )
            throw HTTPError.requestIdentityChanged
        }
        // Work bound to an account never runs as another account's profile
        // with the same ID. A temporary playback scope has no local account.
        if temporaryScope == nil, let expectedAccount = expected.localAccountId,
           account.localAccountId != expectedAccount {
            recordSessionEvent(phase: "captureRequestAuth", outcome: "failed", reason: "accountChanged")
            throw HTTPError.requestIdentityChanged
        }

        if let temporaryScope {
            return CapturedHTTPRequestAuth(
                account: account,
                serverURL: expectedURL,
                accessValue: temporaryScope.accessToken,
                refreshValue: temporaryScope.refreshToken,
                profileId: expected.profileId,
                profileValue: temporaryScope.profileToken,
                credentialOwner: .temporary
            )
        }

        ensureLoaded()
        return CapturedHTTPRequestAuth(
            account: account,
            serverURL: expectedURL,
            accessValue: cachedAccessToken,
            refreshValue: cachedRefreshToken,
            profileId: expected.profileId,
            profileValue: cachedProfileToken,
            credentialOwner: .persistentServer(serverId: expected.serverId)
        )
    }

    /// Store a scoped refresh only if the same server account and refresh
    /// value are still active. Access/refresh credentials belong to the
    /// server account, not one selected profile, so a profile switch must not
    /// discard a successful rotation and strand that server's slot.
    func saveRefreshedTokens(
        _ accessValue: String,
        _ value: String,
        replacing previousValue: String?,
        expected: HTTPRequestIdentity,
        credentialOwner: CapturedHTTPRequestCredentialOwner
    ) -> Bool {
        let expectedURL = ServerRegistry.normalize(url: expected.serverURL)
        guard credentialOwner == .persistentServer(serverId: expected.serverId),
              !expected.serverId.isEmpty,
              !expectedURL.isEmpty,
              let previousValue,
              !previousValue.isEmpty else { return false }
        guard let account = refreshAccountIdentity(),
              account.serverId == expected.serverId,
              account.serverURL == expectedURL,
              // A rotation captured for one account never lands on another.
              expected.localAccountId == nil || expected.localAccountId == account.localAccountId else { return false }
        return saveRefreshedTokens(
            accessValue,
            value,
            replacing: CapturedRefreshCredential(
                account: RefreshAccountIdentity(
                    serverId: expected.serverId,
                    serverURL: expectedURL,
                    credentialGenerationID: account.credentialGenerationID,
                    localAccountId: account.localAccountId
                ),
                refreshToken: previousValue,
                owner: credentialOwner
            )
        )
    }

    /// Store rotated credentials only if the exact account, credential owner,
    /// and refresh token captured before the network call are still current.
    func saveRefreshedTokens(
        _ accessValue: String,
        _ value: String,
        replacing captured: CapturedRefreshCredential
    ) -> Bool {
        // Both `saveRefreshedTokens` overloads land here, so this is the one
        // place a successful rotation is committed — and the only place the
        // success/discard split needs to be recorded. A discarded rotation is
        // benign on its own (a server switch raced the response) but shows up
        // in reports as an unexplained re-login, so it is worth a line.
        guard refreshAccountIdentity() == captured.account else {
            recordSessionEvent(
                phase: "tokenRefresh",
                outcome: "discarded",
                reason: "accountChanged"
            )
            return false
        }

        switch captured.owner {
        case .temporary:
            let generationID = captured.account.credentialGenerationID
            guard temporaryScope?.credentialGenerationID == generationID,
                  !rejectedTemporaryCredentialGenerations.contains(generationID),
                  temporaryScope?.refreshToken == captured.refreshToken else {
                recordSessionEvent(
                    phase: "tokenRefresh",
                    outcome: "discarded",
                    reason: "temporaryScopeChanged"
                )
                return false
            }
            temporaryScope?.accessToken = accessValue
            temporaryScope?.refreshToken = value
            recordSessionEvent(
                phase: "tokenRefresh",
                outcome: "succeeded",
                reason: "temporaryScope"
            )
            return true

        case .persistentServer(let serverId):
            guard temporaryScope == nil,
                  serverId == captured.account.serverId,
                  activeServerId == serverId else {
                recordSessionEvent(
                    phase: "tokenRefresh",
                    outcome: "discarded",
                    reason: "credentialOwnerChanged"
                )
                return false
            }
            ensureLoaded()
            guard cachedRefreshToken == captured.refreshToken else {
                // A concurrent refresh already rotated this slot. Expected
                // under collapsed 401s; recorded because a burst of these
                // means the collapse in HTTPClient is not collapsing.
                recordSessionEvent(
                    phase: "tokenRefresh",
                    outcome: "discarded",
                    reason: "refreshTokenRotated"
                )
                return false
            }

            guard let original = activeAccount,
                  captured.account.localAccountId == original.localAccountId else {
                recordSessionEvent(
                    phase: "tokenRefresh",
                    outcome: "discarded",
                    reason: "canonicalSessionMismatch"
                )
                return false
            }
            let rotated: Account
            do {
                rotated = try accounts.rotateTokens(expected: original.credentials, onServer: serverId,
                                                    accessToken: accessValue, refreshToken: value)
            } catch AccountStoreError.credentialsChanged {
                // Another process (or a sign-out) changed the stored record
                // since this cache was loaded; it wins.
                recordSessionEvent(
                    phase: "tokenRefresh",
                    outcome: "discarded",
                    reason: "canonicalSessionMismatch"
                )
                return false
            } catch {
                recordSessionEvent(
                    phase: "tokenRefresh",
                    outcome: "failed",
                    reason: Self.persistenceFailureReason(error)
                )
                blockRuntimeSession()
                return false
            }
            activeAccount = rotated
            recordSessionEvent(
                phase: "tokenRefresh",
                outcome: "succeeded",
                reason: "persistentSession"
            )
            // Account refresh must not re-mirror a stale profile credential
            // during an in-progress profile transition.
            mirrorActiveAccessValueForExtension()
            return true
        }
    }

    /// Invalidate only the credential snapshot the server rejected. Temporary
    /// playback credentials stay installed until their teardown path removes
    /// them, preventing a fall-through to the owner's persistent account.
    func invalidateRejectedRefresh(
        _ captured: CapturedRefreshCredential
    ) -> RejectedRefreshDisposition? {
        // This is *the* "I got logged out" event: the only path that drops a
        // persistent session because the server rejected its refresh token.
        // Both the clear and every refusal to clear are recorded, because a
        // refusal means the app keeps credentials the server has already
        // repudiated and will 401 until something else resolves it.
        guard refreshAccountIdentity() == captured.account else {
            recordSessionEvent(
                phase: "sessionInvalidation",
                outcome: "skipped",
                reason: "accountChanged"
            )
            return nil
        }

        switch captured.owner {
        case .temporary:
            let generationID = captured.account.credentialGenerationID
            guard temporaryScope?.credentialGenerationID == generationID,
                  temporaryScope?.refreshToken == captured.refreshToken,
                  rejectedTemporaryCredentialGenerations.insert(generationID).inserted else {
                recordSessionEvent(
                    phase: "sessionInvalidation",
                    outcome: "skipped",
                    reason: "temporaryScopeChanged"
                )
                return nil
            }
            recordSessionEvent(
                phase: "sessionInvalidation",
                outcome: "expired",
                reason: "temporaryScope"
            )
            return .temporarySessionExpired

        case .persistentServer(let serverId):
            guard temporaryScope == nil,
                  serverId == captured.account.serverId,
                  activeServerId == serverId else {
                recordSessionEvent(
                    phase: "sessionInvalidation",
                    outcome: "skipped",
                    reason: "credentialOwnerChanged"
                )
                return nil
            }
            ensureLoaded()
            guard cachedRefreshToken == captured.refreshToken else {
                recordSessionEvent(
                    phase: "sessionInvalidation",
                    outcome: "skipped",
                    reason: "refreshTokenRotated"
                )
                return nil
            }

            // The account is marked as needing sign-in first: it keeps its
            // local data, but its tokens go. If that cannot be persisted, the
            // record still holds the rejected tokens and `ensureLoaded()`
            // would restore them on the next launch, so nothing local is
            // cleared and no expiry is reported: the caller sees the same
            // outcome as any other skipped invalidation and the next 401
            // retries the whole sequence.
            guard let rejected = activeAccount,
                  (try? accounts.markNeedsSignIn(expected: rejected.credentials, onServer: serverId)) != nil else {
                recordSessionEvent(
                    phase: "sessionInvalidation",
                    outcome: "failed",
                    reason: "persistenceUnavailable"
                )
                return nil
            }
            recordSessionEvent(
                phase: "sessionInvalidation",
                outcome: "cleared",
                reason: "refreshRejected"
            )
            activeAccount = nil
            cachedProfileToken = nil
            accounts.setProfileToken(nil, for: rejected.localAccountId, onServer: serverId)
            // The selected profile stays: an account waiting to sign in again
            // keeps its local data, and its downloads stay in scope
            // (`AccountScope.current`). Requests carry no credentials until
            // the next sign-in, which selects a profile again.
            clearMirroredTokensForExtension()
            removeDisplayTargets(registeredBy: serverId)
            return .persistentSessionCleared
        }
    }

    /// Verify that an expiry event still describes the active credential
    /// state after invalidation. Registry and temporary-scope switches cancel
    /// refresh tasks before installing the replacement; this final actor check
    /// prevents a late event from routing or tearing down that replacement.
    func shouldConsumeSessionExpiryEvent(_ event: SessionExpiryEvent) -> Bool {
        // Clearing a refused session drops its account from the identity, so
        // the cleared state names no account; the epoch still names the
        // credentials the server refused.
        let expected = event.disposition == .persistentSessionCleared
            ? RefreshAccountIdentity(serverId: event.account.serverId, serverURL: event.account.serverURL,
                                     credentialGenerationID: event.account.credentialGenerationID)
            : event.account
        guard refreshAccountIdentity() == expected else { return false }

        switch event.disposition {
        case .temporarySessionExpired:
            let generationID = event.account.credentialGenerationID
            return temporaryScope?.credentialGenerationID == generationID
                && rejectedTemporaryCredentialGenerations.contains(generationID)

        case .persistentSessionCleared:
            guard temporaryScope == nil,
                  activeServerId == event.account.serverId,
                  persistentCredentialGenerationID == event.account.credentialGenerationID else {
                return false
            }
            ensureLoaded()
            return activeAccount == nil && cachedProfileToken == nil
        }
    }

    // MARK: - Tokens

    func getAccessToken() -> String? {
        if let temporaryScope { return temporaryScope.accessToken }
        ensureLoaded()
        return cachedAccessToken
    }

    func getRefreshToken() -> String? {
        if let temporaryScope { return temporaryScope.refreshToken }
        ensureLoaded()
        return cachedRefreshToken
    }

    /// Read a specific server's stored access token WITHOUT changing the
    /// active server. Used by companion pairing to approve a device on a
    /// server other than the one currently active.
    func getAccessToken(for serverId: String) -> String? {
        guard !serverId.isEmpty else { return nil }
        if serverId == activeServerId {
            ensureLoaded()
            if let activeAccount, !Self.account(activeAccount, belongsTo: serverId) { return nil }
            return cachedAccessToken
        }
        guard let account = savedAccount(onServer: serverId), Self.account(account, belongsTo: serverId) else { return nil }
        return account.accessToken
    }

    /// A saved server's stored account when that server is NOT the active
    /// one: what an approving phone needs to renew the bearer of a server it
    /// is not currently using. Nil for the active server (its credentials
    /// rotate through `HTTPClient`'s single refresh flight), a blocked
    /// server, or a server with no refreshable account.
    func inactiveServerSession(for serverId: String) -> Account? {
        guard !serverId.isEmpty, serverId != activeServerId, temporaryScope?.serverId != serverId,
              let value = savedAccount(onServer: serverId), Self.account(value, belongsTo: serverId),
              value.accessToken?.isEmpty == false, value.refreshToken?.isEmpty == false else { return nil }
        return value
    }

    /// A saved account's stored session when requests do not use it: another
    /// account on the active server, or any account on another server. What
    /// an approving phone needs to approve a TV as that account. Nil for the
    /// account in use (its credentials rotate through `HTTPClient`'s single
    /// refresh flight), a blocked or temporary server, or an account with no
    /// refreshable session.
    func inactiveAccountSession(_ localAccountId: String, onServer serverId: String) -> Account? {
        guard !serverId.isEmpty, temporaryScope?.serverId != serverId,
              !runtimeBlockedServers.contains(serverId),
              !(serverId == activeServerId && requestAccountId(onServer: serverId) == localAccountId),
              let value = try? accounts.account(localAccountId, onServer: serverId), value.isSignedIn,
              Self.account(value, belongsTo: serverId),
              value.accessToken?.isEmpty == false, value.refreshToken?.isEmpty == false else { return nil }
        return value
    }

    #if os(iOS)
    /// The verified account and sign-in epoch of the account that requests
    /// on a saved server use, active or not. Nil for a signed-out, blocked,
    /// unverified, or temporary slot, which cannot keep a push registration
    /// current. On an inactive server this is the account last used there.
    func savedSessionAccount(for serverId: String) -> ApplePushSessionAccount? {
        guard !serverId.isEmpty, temporaryScope?.serverId != serverId else { return nil }
        let account: Account?
        if serverId == activeServerId {
            ensureLoaded()
            account = activeAccount
        } else {
            account = savedAccount(onServer: serverId)
        }
        guard let account, Self.account(account, belongsTo: serverId),
              let accountID = account.serverUserId, let epoch = account.epoch else { return nil }
        return (accountID, epoch, account.localAccountId)
    }

    /// The profile verification proof stored for a saved server's account.
    /// The active server's counts only while `profileID` is its selected
    /// profile; an inactive server keeps the proof of the profile it last used.
    func savedProfileToken(for serverId: String, profileID: String) -> String? {
        guard temporaryScope == nil else { return nil }
        if serverId == activeServerId {
            guard defaults.string(forKey: profileIdDefaultsKey) == profileID else { return nil }
            ensureLoaded()
            return cachedProfileToken
        }
        guard let account = savedAccount(onServer: serverId) else { return nil }
        return accounts.profileToken(for: account.localAccountId, onServer: serverId)
    }

    /// Runs a local push-registration write only while `owner`'s account
    /// still holds the stored session of `owner.serverID`, whether or not
    /// that server is active. Throws `HTTPError.authorityChanged` after a
    /// sign-out, a sign-in to another account, or a new sign-in epoch.
    func withSavedServerAuthority(_ owner: ApplePushIntentOwner,
                                  operation: @Sendable () throws -> Void) throws {
        try Task.checkCancellation()
        guard let current = savedSessionAccount(for: owner.serverID), owner.holds(current) else {
            throw HTTPError.authorityChanged
        }
        try operation()
    }
    #endif

    /// Whether a saved account is bound to the address its server is keyed
    /// by. A registry id is derived from the saved server's URL
    /// (`ServerRegistry.serverId(for:)`), so the id itself names the one
    /// origin a bearer read for another device may send the account's
    /// tokens to. An account bound elsewhere, or an id that names no URL,
    /// releases nothing.
    static func account(_ value: Account, belongsTo serverId: String) -> Bool {
        guard let address = ServerRegistry.url(forServerId: serverId) else { return false }
        return ServerRegistry.normalize(url: value.origin) == address
    }

    /// Store a rotated token pair for an account requests do not use (on an
    /// inactive server, or another account on the active one), but only when
    /// it still holds exactly the credentials the refresh was sent with. An
    /// account that came into use, was signed out, or rotated meanwhile
    /// keeps what it has; the caller then reports the approval as needing a
    /// fresh sign-in rather than writing over newer credentials.
    func saveInactiveServerRefresh(
        accessToken: String,
        refreshToken: String,
        replacing captured: Account,
        for serverId: String
    ) -> Bool {
        guard !accessToken.isEmpty, !refreshToken.isEmpty,
              inactiveAccountSession(captured.localAccountId, onServer: serverId)?.credentials == captured.credentials else {
            recordSessionEvent(phase: "tokenRefresh", outcome: "discarded", reason: "inactiveSlotChanged")
            return false
        }
        do {
            _ = try accounts.rotateTokens(expected: captured.credentials, onServer: serverId,
                                          accessToken: accessToken, refreshToken: refreshToken)
        } catch {
            recordSessionEvent(phase: "tokenRefresh", outcome: "failed", reason: Self.persistenceFailureReason(error))
            return false
        }
        recordSessionEvent(phase: "tokenRefresh", outcome: "succeeded", reason: "inactiveServer")
        return true
    }

    /// Launch-time check for whether `serverId` has a signed-in account.
    /// Retargets to it and loads that account.
    func hasAccessTokenForActiveServer(serverId: String) -> Bool {
        retargetActiveServer(serverId: serverId)
        ensureLoaded()
        return cachedAccessToken != nil
    }

    /// Compatibility entry point for unverified sessions; it creates no verified
    /// durable account binding. Actual login/pairing installers supply accountID.
    @discardableResult
    func saveTokens(accessToken: String, refreshToken: String) -> Bool {
        if temporaryScope != nil {
            temporaryScope?.accessToken = accessToken
            temporaryScope?.refreshToken = refreshToken
            return true
        }
        do {
            try installAccountSession(accessToken: accessToken, refreshToken: refreshToken, accountID: nil, clearProfile: false)
            return true
        } catch {
            return false
        }
    }

    struct AccountInstallationExpectation: Equatable, Sendable {
        let account: RefreshAccountIdentity?
        let generation: UUID
    }

    func captureAccountInstallationExpectation() -> AccountInstallationExpectation {
        AccountInstallationExpectation(account: refreshAccountIdentity(), generation: persistentCredentialGenerationID)
    }

    /// Explicit receiver targets are persisted without changing the active owner.
    /// Comparison and checked keychain publication occur in one actor turn.
    @discardableResult
    func installAccountSessionForServer(serverID: String, origin: String, accessToken: String,
        refreshToken: String, accountID: String, username: String? = nil,
        expected: AccountInstallationExpectation) throws -> AccountSignInResult {
        guard captureAccountInstallationExpectation() == expected, temporaryScope == nil else {
            throw HTTPError.requestIdentityChanged
        }
        let origin = ServerRegistry.normalize(url: origin)
        guard !serverID.isEmpty, !origin.isEmpty, !accountID.isEmpty,
              !accessToken.isEmpty, !refreshToken.isEmpty else { throw AccountStoreError.invalidIdentity }
        let result: AccountSignInResult
        do {
            result = try accounts.saveSignIn(serverId: serverID, origin: origin, serverUserId: accountID,
                                             username: username, accessToken: accessToken,
                                             refreshToken: refreshToken, replacingOtherAccounts: true)
        } catch {
            runtimeBlockedServers.insert(serverID)
            if serverID == activeServerId { blockRuntimeSession() }
            throw error
        }
        runtimeBlockedServers.remove(serverID)
        accounts.setProfileToken(nil, for: result.account.localAccountId, onServer: serverID)
        if serverID == activeServerId {
            accounts.select(result.account)
            defaults.removeObject(forKey: profileIdDefaultsKey)
        }
        // A successful install consumes this expectation even for an inactive target.
        persistentCredentialGenerationID = UUID()
        if serverID == activeServerId {
            activeAccount = nil
            cachedProfileToken = nil
            loadedForServerId = nil
        }
        return result
    }

    /// Saves a sign-in on the active server and makes its account the one
    /// requests use. Signing in as a saved server user refreshes that account.
    /// With `replacingOtherAccounts`, any other account on the server is
    /// replaced, so the server keeps one visible account; without it the
    /// sign-in is added beside them. The result names the replaced accounts
    /// so callers can forget what was stored for them.
    @discardableResult
    func installAccountSession(accessToken: String, refreshToken: String, accountID: String?,
                               username: String? = nil, clearProfile: Bool = true,
                               replacingOtherAccounts: Bool = true,
                               expectedAccount: RefreshAccountIdentity? = nil) throws -> AccountSignInResult {
        if let expectedAccount, refreshAccountIdentity() != expectedAccount { throw HTTPError.requestIdentityChanged }
        let result: AccountSignInResult
        do {
            guard temporaryScope == nil, !activeServerId.isEmpty, !accessToken.isEmpty, !refreshToken.isEmpty,
                  accountID == nil || accountID?.isEmpty == false else { throw AccountStoreError.invalidIdentity }
            let origin = ServerRegistry.normalize(url: defaults.string(forKey: serverUrlDefaultsKey) ?? "")
            guard !origin.isEmpty else { throw AccountStoreError.invalidIdentity }
            do {
                result = try accounts.saveSignIn(serverId: activeServerId, origin: origin, serverUserId: accountID,
                                                 username: username, accessToken: accessToken,
                                                 refreshToken: refreshToken,
                                                 replacingOtherAccounts: replacingOtherAccounts)
            } catch { blockRuntimeSession(); throw error }
        } catch {
            // Recorded here rather than by each caller so login, pairing and
            // `saveTokens` all leave the same durable breadcrumb when the
            // session cannot be written.
            recordSessionEvent(
                phase: "sessionInstall",
                outcome: "failed",
                reason: Self.persistenceFailureReason(error)
            )
            throw error
        }
        runtimeBlockedServers.remove(activeServerId)
        accounts.select(result.account)
        if clearProfile {
            defaults.removeObject(forKey: profileIdDefaultsKey)
            accounts.setProfileToken(nil, for: result.account.localAccountId, onServer: activeServerId)
            cachedProfileToken = nil
        } else {
            // The install marks the cache loaded below, so the profile proof
            // must reflect the Keychain now: a blocked or never-loaded slot
            // would otherwise hide a stored proof until the next switch.
            cachedProfileToken = accounts.profileToken(for: result.account.localAccountId, onServer: activeServerId)
        }
        // A display target belongs to the session that registered it; a new
        // sign-in registers its own.
        removeDisplayTargets(registeredBy: activeServerId)
        persistentCredentialGenerationID = UUID()
        activeAccount = result.account
        loadedForServerId = activeServerId
        mirrorActiveTokensForExtension()
        return result
    }

    /// Everything a server's accounts held at one moment, with this device
    /// user's profile proofs for them, so a sign-in or pairing can put it back
    /// exactly when a later commit fails.
    enum AccountSessionSnapshot: Equatable, Sendable {
        case saved(AccountServerSnapshot, profileTokens: [String: String])
        /// The accounts could not be read. Restoring fails closed.
        case unreadable
    }

    func accountSessionSnapshot(for serverID: String) -> AccountSessionSnapshot {
        guard !serverID.isEmpty else { return .unreadable }
        do {
            let snapshot = try accounts.snapshot(ofServer: serverID)
            var proofs: [String: String] = [:]
            for account in snapshot.accounts {
                proofs[account.localAccountId] = try accounts.checkedProfileToken(
                    for: account.localAccountId, onServer: serverID)
            }
            return .saved(snapshot, profileTokens: proofs)
        } catch {
            return .unreadable
        }
    }

    /// Reinstates `snapshot` for `serverID`. When the restore cannot be made
    /// durable, returns false and blocks runtime use. An account whose
    /// profile proof can't be restored is marked as needing sign-in, so a
    /// partial session cannot return after relaunch.
    @discardableResult
    func restoreAccountSession(_ snapshot: AccountSessionSnapshot, for serverID: String) -> Bool {
        guard !serverID.isEmpty else { return false }
        var durable = false
        var failureReason = "persistenceUnavailable"
        if case .saved(let saved, let proofs) = snapshot, saved.serverId == serverID {
            durable = (try? accounts.restore(saved)) != nil
            if durable {
                for account in saved.accounts
                where !accounts.setProfileToken(proofs[account.localAccountId], for: account.localAccountId, onServer: serverID) {
                    // Account and profile proofs use different Keychain
                    // audiences. Drop the account's tokens if its profile
                    // proof cannot be restored.
                    durable = false
                    failureReason = (try? accounts.markNeedsSignIn(expected: account.credentials, onServer: serverID)) != nil
                        ? "profileRestoreFailedSessionInvalidated"
                        : "profileRestoreFailedInvalidationFailed"
                }
            }
        }
        if durable {
            runtimeBlockedServers.remove(serverID)
        } else {
            recordSessionEvent(phase: "sessionRestore", outcome: "failed", reason: failureReason)
            runtimeBlockedServers.insert(serverID)
        }
        if serverID == activeServerId {
            persistentCredentialGenerationID = UUID()
            activeAccount = nil
            cachedProfileToken = nil
            loadedForServerId = nil
            ensureLoaded()
            mirrorActiveTokensForExtension()
        }
        return durable
    }

    /// Bind an unverified (migrated) account to the server user an
    /// authenticated account response named under this exact token and
    /// process identity, and record its username. Existing queues are not
    /// relabelled.
    func bindVerifiedAccount(_ accountID: String, username: String? = nil,
                             expected: CapturedOrdinaryRequestAuth) throws {
        guard temporaryScope == nil else { return }
        ensureLoaded()
        guard !accountID.isEmpty, refreshAccountIdentity() == expected.account,
              cachedAccessToken == expected.accessToken else { throw HTTPError.requestIdentityChanged }
        // Access-only legacy credentials can still read account metadata, but cannot
        // establish a refreshable durable login envelope or queue authority.
        guard let account = activeAccount, account.refreshToken != nil else { return }
        guard account.serverUserId == nil || account.serverUserId == accountID else {
            throw AccountStoreError.invalidIdentity
        }
        if account.serverUserId == accountID, username == nil || account.username == username { return }
        do {
            activeAccount = try accounts.bindServerUser(accountID, username: username,
                                                        expected: account.credentials, onServer: activeServerId)
        } catch AccountStoreError.credentialsChanged {
            throw HTTPError.requestIdentityChanged
        } catch AccountStoreError.invalidIdentity {
            // Another saved account on this server already is this user.
            // Merging the two waits for the account picker; until then this
            // one stays unverified.
            throw AccountStoreError.invalidIdentity
        } catch {
            blockRuntimeSession()
            throw error
        }
    }

    /// Caches the profiles a fresh list returned for the active account, so
    /// the picker can draw them offline. Ignored when the account changed
    /// since `expected` was captured.
    func updateCachedProfiles(_ profiles: [AccountProfile], expected: RefreshAccountIdentity) {
        guard temporaryScope == nil, refreshAccountIdentity() == expected,
              let account = activeAccount, account.cachedProfiles != profiles else { return }
        do {
            try accounts.updateCachedProfiles(profiles, for: account.localAccountId, onServer: activeServerId)
            activeAccount?.cachedProfiles = profiles
        } catch {
            recordSessionEvent(phase: "profileCache", outcome: "failed", reason: Self.persistenceFailureReason(error))
        }
    }

    private func blockRuntimeSession() {
        runtimeBlockedServers.insert(activeServerId)
        persistentCredentialGenerationID = UUID()
        activeAccount = nil; cachedProfileToken = nil
        loadedForServerId = activeServerId
        clearMirroredTokensForExtension()
        removeDisplayTargets(registeredBy: activeServerId)
    }

    /// Signs out of the active server's account: its record and this device
    /// user's profile proof go, and the server stays saved. Leaves other
    /// servers' and other accounts' credentials intact.
    @discardableResult
    func clearTokens() -> Bool {
        signOutActiveAccount().durable
    }

    /// Signs out of the account requests on the active server use and
    /// returns its `localAccountId`, so callers can delete the data keyed by
    /// it. A temporary playback scope is ended instead, and reports no
    /// account.
    @discardableResult
    func signOutActiveAccount() -> AccountSignOutResult {
        // The deliberate counterpart to `invalidateRejectedRefresh`: reaching
        // login through this path means the app dropped the session on
        // purpose (sign-out), not because the server rejected it. Reports that
        // conflate the two are the reason "I got logged out" is unanswerable,
        // so the two paths carry distinct phases.
        if let temporaryScope {
            rejectedTemporaryCredentialGenerations.remove(temporaryScope.credentialGenerationID)
            self.temporaryScope = nil
            recordSessionEvent(
                phase: "clearTokens",
                outcome: "cleared",
                reason: "temporaryScope"
            )
            return AccountSignOutResult(serverId: temporaryScope.serverId, localAccountId: nil, durable: true)
        }
        let serverId = activeServerId
        var signedOut: String?
        var durable = true
        if !serverId.isEmpty {
            ensureLoaded()
            do {
                // A server whose account needs sign-in has no loaded account,
                // but signing out still removes it.
                if let target = try activeAccount ?? accounts.activeAccount(onServer: serverId) {
                    signedOut = try accounts.signOut(target.localAccountId, onServer: serverId)
                }
            } catch {
                durable = false
            }
            runtimeBlockedServers.insert(serverId)
        }
        persistentCredentialGenerationID = UUID()
        activeAccount = nil
        cachedProfileToken = nil
        guard !serverId.isEmpty else {
            // Cache dropped, but there is no server slot to delete from. A
            // sign-out here leaves nothing persisted to clear.
            recordSessionEvent(
                phase: "clearTokens",
                outcome: "cleared",
                reason: "noActiveServer"
            )
            return AccountSignOutResult(serverId: serverId, localAccountId: nil, durable: true)
        }
        recordSessionEvent(
            phase: "clearTokens",
            outcome: durable ? "cleared" : "failed",
            reason: durable ? "persistentSession" : "persistenceUnavailable"
        )
        if let current = accounts.selection(), current.serverId == serverId {
            accounts.select(nil)
        }
        defaults.removeObject(forKey: profileIdDefaultsKey)
        clearMirroredTokensForExtension()
        removeDisplayTargets(registeredBy: serverId, account: signedOut)
        return AccountSignOutResult(serverId: serverId, localAccountId: signedOut, durable: durable)
    }

    /// The account whose credentials requests send on `serverId` now. Nil
    /// when none is loaded, such as a selected account that needs to sign in
    /// again; `requestAccountId(onServer:)` falls back to the selection.
    func loadedAccountId(onServer serverId: String) -> String? {
        guard !serverId.isEmpty, serverId == activeServerId else { return nil }
        ensureLoaded()
        return activeAccount?.localAccountId
    }

    /// The saved account requests on `serverId` use now: the selected one on
    /// the active server, otherwise the server's most recently used account.
    /// Nil when the server has none, or its accounts can't be read.
    func requestAccountId(onServer serverId: String) -> String? {
        guard !serverId.isEmpty else { return nil }
        if serverId == activeServerId {
            ensureLoaded()
            if let activeAccount { return activeAccount.localAccountId }
        }
        return (try? accounts.activeAccount(onServer: serverId))?.localAccountId
    }

    /// Signs out of a saved account that requests do not use: another
    /// account on the active server, or any account on another server. Its
    /// record and this device user's profile proof go; the account in use
    /// is untouched. The loaded account (`loadedAccountId(onServer:)`) signs
    /// out through `signOutActiveAccount()`, which this refuses.
    func signOutInactiveAccount(_ localAccountId: String, onServer serverId: String) -> AccountSignOutResult {
        let refused = AccountSignOutResult(serverId: serverId, localAccountId: nil, durable: false)
        guard !serverId.isEmpty, temporaryScope?.serverId != serverId else { return refused }
        if loadedAccountId(onServer: serverId) == localAccountId { return refused }
        do {
            try accounts.signOut(localAccountId, onServer: serverId)
            // A selected account that needs to sign in again has no session
            // loaded; it signs out here, and nothing stays selected.
            if accounts.selection()?.localAccountId == localAccountId { _ = accounts.select(nil) }
        } catch {
            recordSessionEvent(phase: "clearTokens", outcome: "failed", reason: Self.persistenceFailureReason(error))
            return refused
        }
        recordSessionEvent(phase: "clearTokens", outcome: "cleared", reason: "inactiveAccount")
        removeDisplayTargets(registeredBy: serverId, account: localAccountId)
        return AccountSignOutResult(serverId: serverId, localAccountId: localAccountId, durable: true)
    }

    /// Delete every account on an arbitrary server. Used by the registry
    /// when removing a server.
    @discardableResult
    func deleteTokens(for serverId: String) -> Bool {
        removeAccounts(onServer: serverId) != nil
    }

    /// Signs out of every account on `serverId` and returns their
    /// `localAccountId`s, or nil when the removal could not be saved.
    func removeAccounts(onServer serverId: String) -> [String]? {
        guard !serverId.isEmpty else { return [] }
        let removed: [String]?
        do { removed = try accounts.removeServer(serverId) } catch {
            recordSessionEvent(phase: "deleteTokens", outcome: "failed", reason: "persistenceUnavailable")
            removed = nil
        }
        runtimeBlockedServers.insert(serverId)
        removeDisplayTargets(registeredBy: serverId)
        if let current = accounts.selection(), current.serverId == serverId {
            accounts.select(nil)
        }
        if serverId == activeServerId {
            activeAccount = nil
            persistentCredentialGenerationID = UUID()
            cachedProfileToken = nil
            loadedForServerId = nil
            clearMirroredTokensForExtension()
        }
        return removed
    }

    // MARK: - Profile

    func getProfileId() -> String? {
        if let temporaryScope { return temporaryScope.profileId }
        return defaults.string(forKey: profileIdDefaultsKey)
    }

    /// The owner `captureOrdinaryRequestAuth` would report now, readable
    /// without awaiting the actor: a remote-playback scope's credentials and
    /// profile while one is installed, otherwise the persistent slot's
    /// credential generation and the selected profile.
    nonisolated var ownerSnapshot: CredentialOwnerSnapshot {
        let mirror = ownerMirror.withLock { $0 }
        if let temporary = mirror.temporary {
            return CredentialOwnerSnapshot(credentialGenerationID: temporary.generation, profileId: temporary.profileId)
        }
        return CredentialOwnerSnapshot(
            credentialGenerationID: mirror.persistentGeneration,
            profileId: defaults.string(forKey: profileIdDefaultsKey)
        )
    }

    private func publishOwnerMirror() {
        let persistent = persistentCredentialGenerationID
        let temporary = temporaryScope.map { (generation: $0.credentialGenerationID, profileId: $0.profileId) }
        ownerMirror.withLock { $0 = (persistentGeneration: persistent, temporary: temporary) }
    }

    func setProfileId(_ profileId: String?) {
        if temporaryScope != nil {
            if let profileId { temporaryScope?.profileId = profileId }
            return
        }
        defaults.set(profileId, forKey: profileIdDefaultsKey)
        profileSelectionGeneration = UUID()
    }

    func getProfileToken() -> String? {
        if let temporaryScope { return temporaryScope.profileToken }
        ensureLoaded()
        return cachedProfileToken
    }

    @discardableResult
    func setProfileToken(_ token: String?) -> Bool {
        if temporaryScope != nil {
            if let token { temporaryScope?.profileToken = token }
            return token != nil
        }
        guard !activeServerId.isEmpty else { return false }
        ensureLoaded()
        let persisted: Bool
        if let account = activeAccount {
            persisted = accounts.setProfileToken(token, for: account.localAccountId, onServer: activeServerId)
        } else {
            // Without an account there is no proof to keep: clearing succeeds,
            // storing one fails.
            persisted = token == nil
        }
        guard persisted else { return false }
        cachedProfileToken = token
        profileSelectionGeneration = UUID()
        mirrorActiveTokensForExtension()
        return true
    }

    /// The active account's sign-in epoch, which remembered profiles are
    /// bound to. Every saved account has one; the name predates accounts,
    /// when a session could lack it.
    func getOrCreateAccountEpoch() -> String? {
        guard temporaryScope == nil else { return nil }
        return getOrCreateAccountEpoch(for: activeServerId)
    }

    func getOrCreateAccountEpoch(for serverID: String) -> String? {
        guard !serverID.isEmpty else { return nil }
        if serverID == activeServerId {
            ensureLoaded()
            return activeAccount?.epoch?.uuidString
        }
        return savedAccount(onServer: serverID)?.epoch?.uuidString
    }

    /// Commits profile ID and verification proof in one actor turn after the
    /// caller has closed HTTP dispatch. Persistent mutations fail closed while
    /// a temporary remote-playback identity owns request authentication.
    func activateProfile(
        profileID: String,
        profileToken: String?,
        expectedAccount: RefreshAccountIdentity
    ) -> Bool {
        guard temporaryScope == nil,
              refreshAccountIdentity() == expectedAccount,
              !profileID.isEmpty else {
            return false
        }
        ensureLoaded()
        guard let account = activeAccount,
              accounts.setProfileToken(profileToken, for: account.localAccountId, onServer: activeServerId) else {
            return false
        }
        cachedProfileToken = profileToken
        // A display target names its own profile, so the previous profile's
        // stays until this profile's registration replaces it, as the
        // server's registration does.
        defaults.set(profileID, forKey: profileIdDefaultsKey)
        profileSelectionGeneration = UUID()
        mirrorActiveTokensForExtension()
        return true
    }

    /// Clears the complete persistent profile identity atomically. The account
    /// session remains installed so the profile picker can load household
    /// profiles without forcing another sign-in. The profile's push display
    /// target stays: the server's registration still belongs to it.
    func deactivateProfile(
        expectedAccount: RefreshAccountIdentity?,
        expectedProfileID: String? = nil,
        expectedProfileSelection: UUID? = nil
    ) -> Bool {
        guard temporaryScope == nil else { return false }
        if let expectedAccount,
           refreshAccountIdentity() != expectedAccount {
            return false
        }
        if let expectedProfileID,
           defaults.string(forKey: profileIdDefaultsKey) != expectedProfileID {
            return false
        }
        if let expectedProfileSelection,
           profileSelectionGeneration != expectedProfileSelection {
            return false
        }
        ensureLoaded()
        if let account = activeAccount,
           !accounts.setProfileToken(nil, for: account.localAccountId, onServer: activeServerId) {
            return false
        }
        defaults.removeObject(forKey: profileIdDefaultsKey)
        cachedProfileToken = nil
        profileSelectionGeneration = UUID()
        mirrorActiveTokensForExtension()
        return true
    }

    // MARK: - Server URL

    func getServerUrl() -> String {
        if let temporaryScope { return temporaryScope.serverURL }
        return defaults.string(forKey: serverUrlDefaultsKey) ?? ""
    }

    func setServerUrl(_ url: String) {
        let normalized = ServerRegistry.normalize(url: url)
        if normalized != defaults.string(forKey: serverUrlDefaultsKey) {
            loadedForServerId = nil
            persistentCredentialGenerationID = UUID()
        }
        defaults.set(normalized, forKey: serverUrlDefaultsKey)
    }

    // MARK: - Private

    /// Classify a `captureRequestAuth` refusal into one stable token.
    ///
    /// Every parameter is a boolean the caller already computed, so this
    /// function is structurally incapable of emitting an identifier: there is
    /// nothing but `Bool` in scope. Order matches the guard's evaluation
    /// order, and the "missing" cases come first because an empty expected
    /// field is a caller bug rather than a mid-flight identity change.
    ///
    /// Internal rather than private so `TokenStoreDiagnosticsTests` can pin
    /// the mapping; the tokens are read by hand from field reports and must
    /// not silently change meaning.
    static func requestIdentityMismatchReason(
        hasExpectedServerId: Bool,
        hasExpectedServerURL: Bool,
        hasExpectedProfileId: Bool,
        serverIdMatches: Bool,
        serverURLMatches: Bool,
        accountServerIdMatches: Bool,
        accountServerURLMatches: Bool,
        profileMatches: Bool
    ) -> String {
        if !hasExpectedServerId { return "missingServerId" }
        if !hasExpectedServerURL { return "missingServerURL" }
        if !hasExpectedProfileId { return "missingProfileId" }
        if !serverIdMatches { return "serverIdChanged" }
        if !serverURLMatches { return "serverURLChanged" }
        if !accountServerIdMatches || !accountServerURLMatches {
            // The active-server mirror and the refresh account disagree: the
            // registry and TokenStore are mid-retarget or one of them failed
            // to commit. Rare, and worth its own token when it happens.
            return "accountIdentityChanged"
        }
        if !profileMatches { return "profileChanged" }
        return "unknown"
    }

    private func ensureLoaded() {
        guard loadedForServerId != activeServerId else { return }
        activeAccount = nil
        cachedProfileToken = nil
        if !activeServerId.isEmpty, !runtimeBlockedServers.contains(activeServerId) {
            do {
                let origin = ServerRegistry.normalize(url: defaults.string(forKey: serverUrlDefaultsKey) ?? "")
                if let account = try accounts.activeAccount(onServer: activeServerId),
                   account.isSignedIn, account.origin == origin {
                    activeAccount = account
                    cachedProfileToken = accounts.profileToken(for: account.localAccountId, onServer: activeServerId)
                    // Keep the selection mirror that `AccountScope.current`
                    // reads in step with the account requests use.
                    accounts.select(account)
                }
            } catch {
                // Fail closed: a record that cannot be read or decoded
                // blocks the runtime session until the next install.
                recordSessionEvent(
                    phase: "sessionLoad",
                    outcome: "blocked",
                    reason: Self.persistenceFailureReason(error)
                )
                runtimeBlockedServers.insert(activeServerId)
            }
        }
        loadedForServerId = activeServerId
    }

    /// A non-active server's signed-in account, as requests on it would use.
    /// Nil for a blocked server, one with no signed-in account, and on a read
    /// error, which is recorded.
    private func savedAccount(onServer serverId: String) -> Account? {
        guard !runtimeBlockedServers.contains(serverId) else { return nil }
        do {
            guard let account = try accounts.activeAccount(onServer: serverId), account.isSignedIn else { return nil }
            return account
        } catch {
            recordSessionEvent(
                phase: "sessionLoad",
                outcome: "failed",
                reason: Self.persistenceFailureReason(error)
            )
            return nil
        }
    }

    /// Mirror the current active access + profile tokens to fixed-name
    /// Keychain slots the Top Shelf extension reads. The extension
    /// doesn't know which server is active, so it looks for these
    /// server-independent accounts instead.
    private func mirrorActiveTokensForExtension() {
        mirrorActiveAccessValueForExtension()
        if cachedProfileToken != lastMirroredProfileToken {
            if let profileToken = cachedProfileToken {
                profileKeychain.set(profileToken, for: SharedStorage.mirroredProfileTokenAccount)
            } else {
                profileKeychain.delete(SharedStorage.mirroredProfileTokenAccount)
            }
            lastMirroredProfileToken = cachedProfileToken
        }
    }

    private func mirrorActiveAccessValueForExtension() {
        if cachedAccessToken != lastMirroredAccessToken {
            if let value = cachedAccessToken {
                accountKeychain.set(value, for: SharedStorage.mirroredAccessTokenAccount)
                lastMirroredAccessToken = value
            } else {
                accountKeychain.delete(SharedStorage.mirroredAccessTokenAccount)
                lastMirroredAccessToken = nil
            }
        }
    }

    /// A display token belongs to its server's session, so it goes when that
    /// session's credentials do. Turning the registration off first is the
    /// caller's job (`ApplePushRegistrationCoordinator.unregister`). With
    /// `account`, only that account's target goes: another account on the
    /// server may hold its installation.
    private func removeDisplayTargets(registeredBy serverId: String, account: String? = nil) {
        #if os(iOS)
        guard !serverId.isEmpty else { return }
        if let account {
            displayTargets.removeTargets(registeredBy: serverId, account: account)
        } else {
            displayTargets.removeTargets(registeredBy: serverId)
        }
        #endif
    }

    private func clearMirroredTokensForExtension() {
        accountKeychain.delete(SharedStorage.mirroredAccessTokenAccount)
        profileKeychain.delete(SharedStorage.mirroredProfileTokenAccount)
        lastMirroredAccessToken = nil
        lastMirroredProfileToken = nil
    }
}
