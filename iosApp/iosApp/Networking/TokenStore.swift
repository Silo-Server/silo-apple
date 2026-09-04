import Foundation

struct RefreshAccountIdentity: Hashable, Sendable {
    let serverId: String
    let serverURL: String
    /// Process-local epoch for the exact credential owner. Persistent epochs
    /// change on login/sign-out/retarget; temporary scopes supply their stable
    /// handoff generation. Guarded refresh rotation preserves the epoch.
    let credentialGenerationID: UUID

    init(
        serverId: String,
        serverURL: String,
        credentialGenerationID: UUID
    ) {
        self.serverId = serverId
        self.serverURL = serverURL
        self.credentialGenerationID = credentialGenerationID
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

/// Persistent, thread-safe store for Continuum session state.
///
/// Mirrors the surface of the shared Kotlin `TokenManager`, but persists
/// tokens in the Keychain so login survives app kills. `serverUrl` and
/// `profileId` live in `SharedDefaults` (App Group suite, mirrored to
/// `.standard`) so the Top Shelf extension can read them without losing
/// compatibility with existing `.standard` readers (SettingsViewModel,
/// ProfileAvatarView, AuthService).
///
/// Multi-server note: tokens are Keychain-scoped per server. The account
/// keys (`com.continuum.<serverId>.{access,refresh,profile}Token`) are
/// computed from `activeServerId`. `switchActiveServer(serverId:)`
/// retargets the slot by flushing the cache — the next read re-populates
/// from the new server's Keychain accounts.
///
/// Top Shelf extension note: whenever the active server's access token
/// or profile token changes, we mirror the current value into two stable
/// server-independent Keychain accounts
/// (`SharedStorage.mirroredAccessTokenAccount`, `mirroredProfileTokenAccount`).
/// The extension reads those slots directly — it doesn't need to know
/// which server is active.
///
/// Auth refresh semantics follow `AuthInterceptorImpl.kt` in the shared
/// module: a single `TokenStore` is the source of truth, and `HTTPClient`
/// collapses concurrent 401s into one refresh by comparing the access
/// token it sent against the token stored after acquiring the refresh
/// mutex.
actor TokenStore {
    static let shared = TokenStore()

    static let accountCredentialAudience: KeychainAudience = .userIndependent
    static let profileCredentialAudience: KeychainAudience = .currentUser

    private let keychain: SharedKeychain
    private let defaults: SharedDefaults

    private let serverUrlDefaultsKey = SharedStorage.serverUrlKey
    private let profileIdDefaultsKey = SharedStorage.profileIdKey

    // MARK: - Keychain key derivation
    //
    // One source of truth for the per-server Keychain account keys.
    // `ServerRegistry.migrateLegacyIfNeeded` and the active-server
    // computed properties below both derive their keys here so a future
    // scheme change only touches these three funcs.
    static func accessTokenKey(for serverId: String) -> String {
        SharedStorage.accessTokenAccount(for: serverId)
    }
    static func refreshTokenKey(for serverId: String) -> String {
        SharedStorage.refreshTokenAccount(for: serverId)
    }
    static func profileTokenKey(for serverId: String) -> String {
        SharedStorage.profileTokenAccount(for: serverId)
    }
    static func accountEpochKey(for serverId: String) -> String {
        SharedStorage.accountEpochAccount(for: serverId)
    }

    /// Server whose tokens are currently cached in `cached*` and returned
    /// by `getAccessToken` etc. Empty string means "no active server" —
    /// reads return nil and saves no-op.
    private var activeServerId: String = ""

    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?
    private var cachedProfileToken: String?
    /// Process-local identity for the persistent credential slot currently
    /// selected by `activeServerId`. Refresh rotation leaves it unchanged;
    /// every session replacement or routing boundary installs a fresh epoch.
    private var persistentCredentialGenerationID = UUID()
    /// Playback-scoped credentials received by a TV through remote handoff.
    /// They are process-only and never written into normal per-server slots.
    private var temporaryScope: TemporaryAuthScope?
    /// A terminally rejected temporary generation remains installed until
    /// remote-playback teardown, but it must never submit its refresh token
    /// again or emit duplicate expiry notifications.
    private var rejectedTemporaryCredentialGenerations: Set<UUID> = []
    /// Server the current cache was loaded for. Nil means the cache is
    /// invalid and must be re-read on next access.
    private var loadedForServerId: String?

    /// Last values written to the shared-extension keychain slots. Used to
    /// skip redundant `SecItemUpdate` calls on every launch / refresh —
    /// `saveTokens` is called after every 401 refresh, so the short-
    /// circuit meaningfully reduces Keychain churn.
    private var lastMirroredAccessToken: String?
    private var lastMirroredProfileToken: String?

    init(keychain: SharedKeychain = SharedKeychain(),
         defaults: SharedDefaults = .shared) {
        self.keychain = keychain
        self.defaults = defaults
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

    // MARK: - Active server

    /// Point the Keychain reads at a different server. Flushes the
    /// in-memory cache so the next access re-reads from the new slot.
    /// Idempotent: a no-op if `serverId` is already active.
    func switchActiveServer(serverId: String) {
        if serverId == activeServerId { return }
        persistentCredentialGenerationID = UUID()
        activeServerId = serverId
        clearApplePushDisplayTokenIfIssued(forServerOtherThan: serverId)
        cachedAccessToken = nil
        cachedRefreshToken = nil
        cachedProfileToken = nil
        loadedForServerId = nil
        // Re-mirror after the cache is repopulated by the next read.
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
        clearApplePushDisplayTokenIfIssued(forServerOtherThan: serverId)
        cachedAccessToken = nil
        cachedRefreshToken = nil
        cachedProfileToken = nil
        loadedForServerId = nil
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
        return RefreshAccountIdentity(
            serverId: serverId,
            serverURL: serverURL,
            credentialGenerationID: scope?.credentialGenerationID
                ?? persistentCredentialGenerationID
        )
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
              current.account == expected.account,
              current.credentialOwner == expected.credentialOwner,
              current.profileId == expected.profileId,
              current.profileToken == expected.profileToken else {
            return nil
        }
        return current
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
              account.serverURL == expectedURL else { return false }
        return saveRefreshedTokens(
            accessValue,
            value,
            replacing: CapturedRefreshCredential(
                account: RefreshAccountIdentity(
                    serverId: expected.serverId,
                    serverURL: expectedURL,
                    credentialGenerationID: account.credentialGenerationID
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

            cachedAccessToken = accessValue
            cachedRefreshToken = value
            recordSessionEvent(
                phase: "tokenRefresh",
                outcome: "succeeded",
                reason: "persistentSession"
            )
            accountKeychain.set(accessValue, for: Self.accessTokenKey(for: serverId))
            accountKeychain.set(value, for: Self.refreshTokenKey(for: serverId))
            // Account refresh must not re-mirror a stale profile credential
            // during an in-progress profile transition.
            mirrorActiveAccessValueForExtension()
            return true
        }
    }

    /// Clear a rejected captured refresh only if it still belongs to the same
    /// active server account and no newer refresh token has replaced it. This
    /// is the failure-side counterpart to `saveRefreshedTokens`: a late scoped
    /// response must never sign out a server selected while it was in flight.
    func clearTokensAfterRejectedRefresh(
        replacing previousValue: String?,
        expected: HTTPRequestIdentity,
        credentialOwner: CapturedHTTPRequestCredentialOwner
    ) -> Bool {
        let expectedURL = ServerRegistry.normalize(url: expected.serverURL)
        guard credentialOwner == .persistentServer(serverId: expected.serverId),
              !expected.serverId.isEmpty,
              !expectedURL.isEmpty,
              let previousValue,
              !previousValue.isEmpty else {
            // Refused before reaching the shared invalidation funnel, so the
            // funnel's own line will not fire. Grouped under one token: these
            // are malformed-caller shapes, not races.
            recordSessionEvent(
                phase: "sessionInvalidation",
                outcome: "skipped",
                reason: "unsupportedCredentialShape"
            )
            return false
        }
        guard let account = refreshAccountIdentity(),
              account.serverId == expected.serverId,
              account.serverURL == expectedURL else {
            recordSessionEvent(
                phase: "sessionInvalidation",
                outcome: "skipped",
                reason: "accountChanged"
            )
            return false
        }
        let disposition = invalidateRejectedRefresh(
            CapturedRefreshCredential(
                account: RefreshAccountIdentity(
                    serverId: expected.serverId,
                    serverURL: expectedURL,
                    credentialGenerationID: account.credentialGenerationID
                ),
                refreshToken: previousValue,
                owner: credentialOwner
            )
        )
        return disposition == .persistentSessionCleared
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

            recordSessionEvent(
                phase: "sessionInvalidation",
                outcome: "cleared",
                reason: "refreshRejected"
            )
            cachedAccessToken = nil
            cachedRefreshToken = nil
            cachedProfileToken = nil
            accountKeychain.delete(Self.accessTokenKey(for: serverId))
            accountKeychain.delete(Self.refreshTokenKey(for: serverId))
            accountKeychain.delete(Self.accountEpochKey(for: serverId))
            profileKeychain.delete(Self.profileTokenKey(for: serverId))
            defaults.removeObject(forKey: profileIdDefaultsKey)
            clearMirroredTokensForExtension()
            return .persistentSessionCleared
        }
    }

    /// Verify that an expiry event still describes the active credential
    /// state after invalidation. Registry and temporary-scope switches cancel
    /// refresh tasks before installing the replacement; this final actor check
    /// prevents a late event from routing or tearing down that replacement.
    func shouldConsumeSessionExpiryEvent(_ event: SessionExpiryEvent) -> Bool {
        guard refreshAccountIdentity() == event.account else { return false }

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
            return cachedAccessToken == nil
                && cachedRefreshToken == nil
                && cachedProfileToken == nil
                && defaults.string(forKey: profileIdDefaultsKey) == nil
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
            return cachedAccessToken
        }
        return accountKeychain.get(Self.accessTokenKey(for: serverId))
    }

    /// Minimal launch-time check for whether the active server has a stored
    /// access token. This reads only the access-token slot; the full token
    /// cache is still loaded lazily by the first authenticated request.
    func hasAccessTokenForActiveServer(serverId: String) -> Bool {
        retargetActiveServer(serverId: serverId)
        if loadedForServerId == activeServerId {
            return cachedAccessToken != nil
        }
        cachedAccessToken = accountKeychain.get(Self.accessTokenKey(for: serverId))
        return cachedAccessToken != nil
    }

    func saveTokens(accessToken: String, refreshToken: String) {
        if temporaryScope != nil {
            temporaryScope?.accessToken = accessToken
            temporaryScope?.refreshToken = refreshToken
            return
        }
        guard !activeServerId.isEmpty else { return }
        ensureLoaded()
        persistentCredentialGenerationID = UUID()
        cachedAccessToken = accessToken
        cachedRefreshToken = refreshToken
        accountKeychain.set(accessToken, for: accessTokenKey)
        accountKeychain.set(refreshToken, for: refreshTokenKey)
        accountKeychain.set(UUID().uuidString, for: accountEpochKey)
        mirrorActiveTokensForExtension()
    }

    /// Clear tokens for the active server only. Leaves other servers'
    /// stored tokens intact and leaves the active-server registry entry
    /// in place (sign-out keeps the URL / name).
    func clearTokens() {
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
            return
        }
        ensureLoaded()
        persistentCredentialGenerationID = UUID()
        cachedAccessToken = nil
        cachedRefreshToken = nil
        cachedProfileToken = nil
        guard !activeServerId.isEmpty else {
            // Cache dropped, but there is no server slot to delete from. A
            // sign-out here leaves nothing persisted to clear.
            recordSessionEvent(
                phase: "clearTokens",
                outcome: "cleared",
                reason: "noActiveServer"
            )
            return
        }
        recordSessionEvent(
            phase: "clearTokens",
            outcome: "cleared",
            reason: "persistentSession"
        )
        accountKeychain.delete(accessTokenKey)
        accountKeychain.delete(refreshTokenKey)
        accountKeychain.delete(accountEpochKey)
        profileKeychain.delete(profileTokenKey)
        defaults.removeObject(forKey: profileIdDefaultsKey)
        clearMirroredTokensForExtension()
    }

    /// Delete tokens for an arbitrary server. Used by the registry when
    /// removing a server or signing out from a non-active server.
    func deleteTokens(for serverId: String) {
        guard !serverId.isEmpty else { return }
        accountKeychain.delete(Self.accessTokenKey(for: serverId))
        accountKeychain.delete(Self.refreshTokenKey(for: serverId))
        accountKeychain.delete(Self.accountEpochKey(for: serverId))
        profileKeychain.delete(Self.profileTokenKey(for: serverId))
        if serverId == activeServerId {
            persistentCredentialGenerationID = UUID()
            cachedAccessToken = nil
            cachedRefreshToken = nil
            cachedProfileToken = nil
            loadedForServerId = nil
            clearMirroredTokensForExtension()
        }
    }

    // MARK: - Profile

    func getProfileId() -> String? {
        if let temporaryScope { return temporaryScope.profileId }
        return defaults.string(forKey: profileIdDefaultsKey)
    }

    func setProfileId(_ profileId: String?) {
        if temporaryScope != nil {
            if let profileId { temporaryScope?.profileId = profileId }
            return
        }
        defaults.set(profileId, forKey: profileIdDefaultsKey)
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
        if let token {
            persisted = profileKeychain.set(token, for: profileTokenKey)
        } else {
            persisted = profileKeychain.delete(profileTokenKey)
        }
        guard persisted else { return false }
        cachedProfileToken = token
        mirrorActiveTokensForExtension()
        return true
    }

    func getOrCreateAccountEpoch() -> String? {
        guard temporaryScope == nil else { return nil }
        return getOrCreateAccountEpoch(for: activeServerId)
    }

    func getOrCreateAccountEpoch(for serverID: String) -> String? {
        guard !serverID.isEmpty else { return nil }
        let epochKey = Self.accountEpochKey(for: serverID)
        let accessKey = Self.accessTokenKey(for: serverID)
        if let existing = accountKeychain.get(epochKey), !existing.isEmpty {
            return existing
        }
        guard accountKeychain.get(accessKey) != nil else { return nil }
        let epoch = UUID().uuidString
        guard accountKeychain.set(epoch, for: epochKey) else { return nil }
        return epoch
    }

    func hasStoredProfileToken(for serverID: String) -> Bool {
        guard !serverID.isEmpty else { return false }
        if serverID == activeServerId {
            ensureLoaded()
            return cachedProfileToken != nil
        }
        return profileKeychain.get(Self.profileTokenKey(for: serverID)) != nil
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
        let persisted: Bool
        if let profileToken {
            persisted = profileKeychain.set(profileToken, for: profileTokenKey)
        } else {
            persisted = profileKeychain.delete(profileTokenKey)
        }
        guard persisted else { return false }
        cachedProfileToken = profileToken
        // The display token was minted for the previous profile. Drop it
        // before the new profile id is visible so the extension cannot pair
        // the new context with the old credential; the next registration
        // mints a replacement.
        if defaults.string(forKey: profileIdDefaultsKey) != profileID {
            clearApplePushDisplayToken()
        }
        defaults.set(profileID, forKey: profileIdDefaultsKey)
        mirrorActiveTokensForExtension()
        return true
    }

    /// Clears the complete persistent profile identity atomically. The account
    /// session remains installed so the profile picker can load household
    /// profiles without forcing another sign-in.
    func deactivateProfile(
        expectedAccount: RefreshAccountIdentity?,
        expectedProfileID: String? = nil
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
        ensureLoaded()
        if !activeServerId.isEmpty,
           !profileKeychain.delete(profileTokenKey) {
            return false
        }
        defaults.removeObject(forKey: profileIdDefaultsKey)
        cachedProfileToken = nil
        clearApplePushDisplayToken()
        mirrorActiveTokensForExtension()
        return true
    }

    // MARK: - Server URL

    func getServerUrl() -> String {
        if let temporaryScope { return temporaryScope.serverURL }
        return defaults.string(forKey: serverUrlDefaultsKey) ?? ""
    }

    func setServerUrl(_ url: String) {
        defaults.set(ServerRegistry.normalize(url: url), forKey: serverUrlDefaultsKey)
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

    private var accessTokenKey: String { Self.accessTokenKey(for: activeServerId) }
    private var refreshTokenKey: String { Self.refreshTokenKey(for: activeServerId) }
    private var profileTokenKey: String { Self.profileTokenKey(for: activeServerId) }
    private var accountEpochKey: String { Self.accountEpochKey(for: activeServerId) }
    private var accountKeychain: SharedKeychain {
        keychain.withAudience(Self.accountCredentialAudience)
    }
    private var profileKeychain: SharedKeychain {
        keychain.withAudience(Self.profileCredentialAudience)
    }

    private func ensureLoaded() {
        guard loadedForServerId != activeServerId else { return }
        if activeServerId.isEmpty {
            cachedAccessToken = nil
            cachedRefreshToken = nil
            cachedProfileToken = nil
        } else {
            cachedAccessToken = accountKeychain.get(accessTokenKey)
            cachedRefreshToken = accountKeychain.get(refreshTokenKey)
            cachedProfileToken = profileKeychain.get(profileTokenKey)
        }
        loadedForServerId = activeServerId
    }

    /// Mirror the current active access + profile tokens to fixed-name
    /// Keychain slots the Top Shelf extension reads. The extension
    /// doesn't know which server is active, so it looks for these
    /// server-independent accounts instead.
    private func mirrorActiveTokensForExtension() {
        if cachedAccessToken != lastMirroredAccessToken {
            if let accessToken = cachedAccessToken {
                accountKeychain.set(accessToken, for: SharedStorage.mirroredAccessTokenAccount)
            } else {
                accountKeychain.delete(SharedStorage.mirroredAccessTokenAccount)
            }
            lastMirroredAccessToken = cachedAccessToken
        }
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

    /// The display token is bound to one session, server, and profile, so it
    /// dies with any of them; the next registration mints a fresh one.
    private func clearApplePushDisplayToken() {
        // Metadata is removed only once the Keychain item is gone, so a
        // failed delete leaves the token paired with its real expiry and
        // issuing server rather than looking freshly issued.
        guard profileKeychain.delete(SharedStorage.applePushDisplayTokenAccount) else { return }
        defaults.removeObject(forKey: SharedStorage.applePushDisplayTokenExpiresAtKey)
        defaults.removeObject(forKey: SharedStorage.applePushDisplayTokenServerIdKey)
    }

    /// Server retargeting happens both on a real switch and when the actor
    /// hydrates the persisted server on a cold launch (`activeServerId` starts
    /// empty). Only the former invalidates the display token, so compare
    /// against the server the token was issued for rather than the actor's
    /// previous state. A token with no recorded server predates this key and
    /// is cleared to be safe.
    private func clearApplePushDisplayTokenIfIssued(forServerOtherThan serverId: String) {
        guard profileKeychain.get(SharedStorage.applePushDisplayTokenAccount) != nil else { return }
        let issuedFor = defaults.string(forKey: SharedStorage.applePushDisplayTokenServerIdKey) ?? ""
        if issuedFor.isEmpty || issuedFor != serverId {
            clearApplePushDisplayToken()
        }
    }

    private func clearMirroredTokensForExtension() {
        accountKeychain.delete(SharedStorage.mirroredAccessTokenAccount)
        profileKeychain.delete(SharedStorage.mirroredProfileTokenAccount)
        clearApplePushDisplayToken()
        lastMirroredAccessToken = nil
        lastMirroredProfileToken = nil
    }
}
