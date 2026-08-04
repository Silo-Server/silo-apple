import Foundation

struct RefreshAccountIdentity: Hashable, Sendable {
    let serverId: String
    let serverURL: String
}

struct TemporaryAuthScope: Equatable, Sendable {
    let serverId: String
    let serverURL: String
    var accessToken: String
    var refreshToken: String
    var profileId: String
    var profileToken: String
    let controllerDeviceId: String
    let expiresAt: Date
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
        "com.continuum.\(serverId).accessToken"
    }
    static func refreshTokenKey(for serverId: String) -> String {
        "com.continuum.\(serverId).refreshToken"
    }
    static func profileTokenKey(for serverId: String) -> String {
        "com.continuum.\(serverId).profileToken"
    }

    /// Server whose tokens are currently cached in `cached*` and returned
    /// by `getAccessToken` etc. Empty string means "no active server" —
    /// reads return nil and saves no-op.
    private var activeServerId: String = ""

    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?
    private var cachedProfileToken: String?
    /// Playback-scoped credentials received by a TV through remote handoff.
    /// They are process-only and never written into normal per-server slots.
    private var temporaryScope: TemporaryAuthScope?
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

    // MARK: - Active server

    /// Point the Keychain reads at a different server. Flushes the
    /// in-memory cache so the next access re-reads from the new slot.
    /// Idempotent: a no-op if `serverId` is already active.
    func switchActiveServer(serverId: String) {
        if serverId == activeServerId { return }
        activeServerId = serverId
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
        activeServerId = serverId
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
        let serverId = temporaryScope?.serverId ?? activeServerId
        let serverURL = ServerRegistry.normalize(
            url: temporaryScope?.serverURL
                ?? defaults.string(forKey: serverUrlDefaultsKey)
                ?? ""
        )
        guard !serverId.isEmpty, !serverURL.isEmpty else { return nil }
        return RefreshAccountIdentity(serverId: serverId, serverURL: serverURL)
    }

    func beginTemporaryScope(_ scope: TemporaryAuthScope) {
        temporaryScope = scope
    }

    @discardableResult
    func endTemporaryScope() -> TemporaryAuthScope? {
        defer { temporaryScope = nil }
        return temporaryScope
    }

    func getTemporaryScope() -> TemporaryAuthScope? { temporaryScope }

    func hasTemporaryScope() -> Bool { temporaryScope != nil }

    /// Atomically verify a queued request's routing identity and snapshot the
    /// matching credentials. No mutable global scope is installed: the caller
    /// carries this value for one explicit request only.
    func captureRequestAuth(expected: HTTPRequestIdentity) throws -> CapturedHTTPRequestAuth {
        let expectedURL = ServerRegistry.normalize(url: expected.serverURL)
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
              currentProfileId == expected.profileId else {
            throw HTTPError.requestIdentityChanged
        }

        if let temporaryScope {
            return CapturedHTTPRequestAuth(
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
        let currentURL = ServerRegistry.normalize(
            url: defaults.string(forKey: serverUrlDefaultsKey) ?? ""
        )
        guard temporaryScope == nil,
              credentialOwner == .persistentServer(serverId: expected.serverId),
              !expected.serverId.isEmpty,
              !expectedURL.isEmpty,
              let previousValue,
              !previousValue.isEmpty,
              activeServerId == expected.serverId,
              currentURL == expectedURL else { return false }

        ensureLoaded()
        let expectedRefreshKey = Self.refreshTokenKey(for: expected.serverId)
        guard cachedRefreshToken == previousValue else { return false }

        cachedAccessToken = accessValue
        cachedRefreshToken = value
        keychain.set(accessValue, for: Self.accessTokenKey(for: expected.serverId))
        keychain.set(value, for: expectedRefreshKey)
        // Account refresh must not re-mirror a stale profile credential
        // during an in-progress profile transition.
        mirrorActiveAccessValueForExtension()
        return true
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
        return keychain.get(Self.accessTokenKey(for: serverId))
    }

    /// Minimal launch-time check for whether the active server has a stored
    /// access token. This reads only the access-token slot; the full token
    /// cache is still loaded lazily by the first authenticated request.
    func hasAccessTokenForActiveServer(serverId: String) -> Bool {
        retargetActiveServer(serverId: serverId)
        if loadedForServerId == activeServerId {
            return cachedAccessToken != nil
        }
        cachedAccessToken = keychain.get(Self.accessTokenKey(for: serverId))
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
        cachedAccessToken = accessToken
        cachedRefreshToken = refreshToken
        keychain.set(accessToken, for: accessTokenKey)
        keychain.set(refreshToken, for: refreshTokenKey)
        mirrorActiveTokensForExtension()
    }

    /// Clear tokens for the active server only. Leaves other servers'
    /// stored tokens intact and leaves the active-server registry entry
    /// in place (sign-out keeps the URL / name).
    func clearTokens() {
        if temporaryScope != nil {
            temporaryScope = nil
            return
        }
        ensureLoaded()
        cachedAccessToken = nil
        cachedRefreshToken = nil
        cachedProfileToken = nil
        guard !activeServerId.isEmpty else { return }
        keychain.delete(accessTokenKey)
        keychain.delete(refreshTokenKey)
        keychain.delete(profileTokenKey)
        defaults.removeObject(forKey: profileIdDefaultsKey)
        clearMirroredTokensForExtension()
    }

    /// Delete tokens for an arbitrary server. Used by the registry when
    /// removing a server or signing out from a non-active server.
    func deleteTokens(for serverId: String) {
        guard !serverId.isEmpty else { return }
        keychain.delete(Self.accessTokenKey(for: serverId))
        keychain.delete(Self.refreshTokenKey(for: serverId))
        keychain.delete(Self.profileTokenKey(for: serverId))
        if serverId == activeServerId {
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

    func setProfileToken(_ token: String?) {
        if temporaryScope != nil {
            if let token { temporaryScope?.profileToken = token }
            return
        }
        guard !activeServerId.isEmpty else { return }
        ensureLoaded()
        cachedProfileToken = token
        if let token {
            keychain.set(token, for: profileTokenKey)
        } else {
            keychain.delete(profileTokenKey)
        }
        mirrorActiveTokensForExtension()
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

    private var accessTokenKey: String { Self.accessTokenKey(for: activeServerId) }
    private var refreshTokenKey: String { Self.refreshTokenKey(for: activeServerId) }
    private var profileTokenKey: String { Self.profileTokenKey(for: activeServerId) }

    private func ensureLoaded() {
        guard loadedForServerId != activeServerId else { return }
        if activeServerId.isEmpty {
            cachedAccessToken = nil
            cachedRefreshToken = nil
            cachedProfileToken = nil
        } else {
            cachedAccessToken = keychain.get(accessTokenKey)
            cachedRefreshToken = keychain.get(refreshTokenKey)
            cachedProfileToken = keychain.get(profileTokenKey)
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
                keychain.set(accessToken, for: SharedStorage.mirroredAccessTokenAccount)
            } else {
                keychain.delete(SharedStorage.mirroredAccessTokenAccount)
            }
            lastMirroredAccessToken = cachedAccessToken
        }
        if cachedProfileToken != lastMirroredProfileToken {
            if let profileToken = cachedProfileToken {
                keychain.set(profileToken, for: SharedStorage.mirroredProfileTokenAccount)
            } else {
                keychain.delete(SharedStorage.mirroredProfileTokenAccount)
            }
            lastMirroredProfileToken = cachedProfileToken
        }
    }

    private func mirrorActiveAccessValueForExtension() {
        if cachedAccessToken != lastMirroredAccessToken {
            if let value = cachedAccessToken {
                keychain.set(value, for: SharedStorage.mirroredAccessTokenAccount)
                lastMirroredAccessToken = value
            } else {
                keychain.delete(SharedStorage.mirroredAccessTokenAccount)
                lastMirroredAccessToken = nil
            }
        }
    }

    private func clearMirroredTokensForExtension() {
        keychain.delete(SharedStorage.mirroredAccessTokenAccount)
        keychain.delete(SharedStorage.mirroredProfileTokenAccount)
        lastMirroredAccessToken = nil
        lastMirroredProfileToken = nil
    }
}
