import Foundation

/// Thin service layer for auth / profile operations backed by the native
/// Swift `HTTPClient`.
///
/// Shares the same token/profile storage as `ContinuumAPI` via
/// ``TokenStore/shared``. The sync `serverUrl`/`profileId` accessors
/// read from `ServerRegistry.shared.activeServer` and, on write, update
/// both the registry (source of truth) and the legacy `UserDefaults`
/// keys that older sync callers still read.
final class AuthService: @unchecked Sendable {
    static let shared = AuthService()
    private let defaults = SharedDefaults.shared
    private let serverIdentityResolver: ServerIdentityResolver
    private let serverRegistry: ServerRegistry

    enum SignOutAuthorization: Equatable, Sendable {
        case allowed(account: RefreshAccountIdentity?)
        case refused
    }

    init(
        serverIdentityResolver: ServerIdentityResolver = ServerIdentityResolver(),
        serverRegistry: ServerRegistry = .shared
    ) {
        self.serverIdentityResolver = serverIdentityResolver
        self.serverRegistry = serverRegistry
    }

    // MARK: - Stored State Accessors

    /// Active server URL. Read-only: changing the active server goes
    /// through `ServerRegistry.switchTo`, which mirrors the URL to the
    /// legacy `UserDefaults["serverUrl"]` slot for sync readers.
    var serverUrl: String { ServerRegistry.shared.activeServerUrl }

    /// Selected profile for the active server. Writes route through the
    /// registry (so switching servers and coming back restores the last
    /// profile for this server) and mirror to the legacy
    /// `UserDefaults["profileId"]` key that sync callers still read.
    /// Clearing also invalidates the profile token so the next request
    /// doesn't send a stale `X-Profile-Token` header.
    ///
    /// Every write re-evaluates diagnostics eligibility (see the setter): the
    /// active profile changes through many paths beyond `selectProfile` —
    /// clearing it to enter profile selection, per-tab profile switches — and a
    /// child profile can't manage diagnostics, so the synchronous
    /// breadcrumb/sentinel gate must fail closed on any change until the new
    /// profile is confirmed non-child.
    var profileId: String? {
        get { defaults.string(forKey: SharedStorage.profileIdKey) }
        set {
            if let activeId = ServerRegistry.shared.activeServerId {
                ServerRegistry.shared.setProfileId(newValue, for: activeId)
            }
            defaults.set(newValue, forKey: SharedStorage.profileIdKey)
            if newValue == nil {
                Task { await TokenStore.shared.setProfileToken(nil) }
            }
            #if os(iOS) || os(tvOS)
            // Fail the breadcrumb/session/exit-sentinel gate closed on every
            // profile change, not just the `selectProfile` path, so early
            // navigation/playback breadcrumbs (or the tvOS marker) can't be
            // captured under the previous profile's eligibility before the
            // async child-profile re-check lands.
            DiagnosticsCoordinator.activeProfileDidChange()
            #endif
        }
    }

    var hasServer: Bool { ServerRegistry.shared.hasActiveServer }

    /// Sync check used by SwiftUI bodies and view-state gates. Reads the
    /// active server's Keychain slot directly — Keychain APIs are
    /// synchronous, so no actor hop is needed.
    var isLoggedIn: Bool {
        guard let id = ServerRegistry.shared.activeServerId, !id.isEmpty else {
            return false
        }
        return SharedKeychain().get(TokenStore.accessTokenKey(for: id)) != nil
    }

    var hasProfile: Bool { profileId != nil }

    // MARK: - Server Check

    /// Probe a candidate server: set it as the active server URL,
    /// identify it via native branding (with a legacy health fallback),
    /// register the entry, and
    /// return the setup status so the caller can decide between initial
    /// setup and login.
    ///
    /// Candidate probes use their explicit URL and no active credentials.
    /// Global registry/default/token routing changes only after setup status
    /// succeeds. If both optional identity probes fail, the display name
    /// falls back to the URL.
    func checkServer(url: String) async throws -> SetupStatus {
        let normalized = ServerRegistry.normalize(url: url)
        let id = ServerRegistry.serverId(for: normalized)

        // Probe the candidate by explicit URL without touching the active
        // defaults or credential slot. This prevents candidate discovery from
        // exposing a global A/B routing mixture to unrelated requests.
        let fetchedName = await serverIdentityResolver.fetchServerName(serverURL: normalized)

        // Commit only after the candidate proves it can serve setup status.
        let status: SetupStatus = try await HTTPClient.shared.getUnauthenticated(
            serverURL: normalized,
            path: "/api/v1/auth/setup"
        )

        // Success: upsert the registry entry and make it active.
        let entry = ServerEntry(
            id: id,
            url: normalized,
            fetchedName: fetchedName,
            profileId: nil,
            lastUsedAt: Date()
        )
        ServerRegistry.shared.addOrUpdate(entry)
        if ServerRegistry.shared.activeServerId != id {
            await ServerRegistry.shared.switchTo(serverId: id)
        }

        return status
    }

    /// Refreshes the active registry entry from the server's native branding.
    /// The identity check prevents a slow response from one server renaming a
    /// different server after the user switches destinations.
    func refreshActiveServerName() async {
        guard let server = serverRegistry.activeServer else { return }
        let serverId = server.id
        guard let name = await serverIdentityResolver.fetchServerName(serverURL: server.url),
              serverRegistry.activeServerId == serverId else {
            return
        }
        serverRegistry.updateFetchedName(for: serverId, fetchedName: name)
    }

    // MARK: - Authentication

    func login(username: String, password: String) async throws {
        guard let expectedAccount = await TokenStore.shared.refreshAccountIdentity() else {
            throw HTTPError.serverUrlNotConfigured
        }
        let response: LoginResponse = try await HTTPClient.shared.post(
            "/api/v1/auth/login",
            body: LoginRequest(username: username, password: password)
        )
        try await installSession(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expectedAccount: expectedAccount
        )
    }

    func setupAdmin(username: String, email: String, password: String) async throws {
        guard let expectedAccount = await TokenStore.shared.refreshAccountIdentity() else {
            throw HTTPError.serverUrlNotConfigured
        }
        let response: LoginResponse = try await HTTPClient.shared.post(
            "/api/v1/auth/setup",
            body: SetupRequest(username: username, email: email, password: password)
        )
        try await installSession(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expectedAccount: expectedAccount
        )
    }

    func signup(username: String, email: String, password: String, inviteCode: String) async throws {
        guard let expectedAccount = await TokenStore.shared.refreshAccountIdentity() else {
            throw HTTPError.serverUrlNotConfigured
        }
        let response: LoginResponse = try await HTTPClient.shared.post(
            "/api/v1/auth/signup",
            body: SignupRequest(
                username: username,
                email: email,
                password: password,
                inviteCode: inviteCode
            )
        )
        try await installSession(
            accessToken: response.accessToken,
            refreshToken: response.refreshToken,
            expectedAccount: expectedAccount
        )
    }

    /// A login response establishes a brand-new session. Wipe every piece of
    /// prior auth state before persisting the new tokens — no need to carry
    /// `profileId` or `profileToken` across the boundary, and keeping them
    /// just strands stale values that the server rejects.
    func installSession(
        accessToken: String,
        refreshToken: String,
        expectedAccount: RefreshAccountIdentity
    ) async throws {
        guard let transitionLease = await HTTPClient.shared.beginIdentityTransition() else {
            throw CancellationError()
        }
        guard !Task.isCancelled else {
            await HTTPClient.shared.endIdentityTransition(transitionLease)
            throw CancellationError()
        }
        await HTTPClient.shared.cancelInFlightRequests()
        guard !Task.isCancelled,
              await TokenStore.shared.refreshAccountIdentity() == expectedAccount else {
            await HTTPClient.shared.endIdentityTransition(transitionLease)
            if Task.isCancelled { throw CancellationError() }
            throw HTTPError.requestIdentityChanged
        }
        await TokenStore.shared.clearTokens()
        await TokenStore.shared.saveTokens(
            accessToken: accessToken,
            refreshToken: refreshToken
        )
        await clearAllCaches()
        await HTTPClient.shared.endIdentityTransition(transitionLease)
    }

    // MARK: - Profiles

    func getProfiles() async throws -> [UserProfile] {
        try await ContinuumAPI.shared.listProfiles()
    }

    func selectProfile(profileId: String, pin: String? = nil) async throws {
        // `ContinuumAPI.selectProfile` already calls `TokenStore.setProfileId`,
        // which writes UserDefaults. Duplicating the write here is what created
        // the dual-writer pattern that stranded a stale `profileId` in the
        // simulator's device-level plist across reinstalls.
        try await ContinuumAPI.shared.selectProfile(profileId: profileId, pin: pin)
        // Persist through the profileId setter so the registry entry
        // for the active server also records the selection, enabling
        // automatic restoration when the user switches back. The setter also
        // re-evaluates diagnostics eligibility (an adult→child switch must
        // disarm breadcrumb/session/exit-sentinel capture even though the
        // server/account binding is unchanged).
        self.profileId = profileId
        await clearPerProfileCaches()
        // Re-probe AI capabilities for the newly-selected profile. Fire and
        // forget — gating defaults to "unavailable" until the probes land,
        // so nothing blocks on this.
        Task { @MainActor in
            await AICapabilities.shared.refresh()
            await RequestsFeatureStore.shared.refresh()
        }
    }

    /// Drop every cached response that's profile-scoped. Called on
    /// profile switch and sign-out so userData (watched, favorites,
    /// watchlist, home recommendations) doesn't leak between accounts.
    @MainActor
    private func clearPerProfileCaches() {
        StartupContentPrefetcher.resetProfileScopedPrefetches()
        for prefix in CacheKey.perProfilePrefixes {
            ResponseCache.shared.removeAll(withPrefix: prefix)
        }
        ResponseCache.shared.remove(CacheKey.profiles)
        // Overlay prefs are user-scoped on the server (not profile-scoped),
        // so a profile switch within one account doesn't strictly require
        // a re-fetch. We still clear: (a) freshness — a remote web edit
        // between switches would otherwise serve stale prefs until app
        // restart; (b) defensive — if the server ever moves overlays to
        // a per-profile scope, this path keeps working.
        OverlayPrefsStore.shared.clear()
        // Profile's preferred subtitle language drives detail-page track
        // ordering; drop it so the next profile re-hydrates its own.
        ProfilePrefsStore.shared.clear()
        // Server-wide AI capability + per-user ASR quota are reset on every
        // profile switch; `selectProfile` re-fetches after the switch lands.
        AICapabilities.shared.reset()
        RequestsFeatureStore.shared.reset()
        RequestsEventBus.shared.reset()
        #if os(tvOS)
        ItemDetailCache.shared.clearAll()
        #endif
    }

    func createProfile(name: String, avatarEmoji: String?, pin: String?, isChild: Bool) async throws -> UserProfile {
        try await ContinuumAPI.shared.createProfile(
            name: name,
            avatarEmoji: avatarEmoji,
            pin: pin,
            isChild: isChild
        )
    }

    // MARK: - Device Login (QR sign-in)

    func startDeviceLogin(deviceName: String, devicePlatform: String) async throws -> DeviceLoginStartResponse {
        try await HTTPClient.shared.post(
            "/api/v1/auth/device/start",
            body: DeviceLoginStartRequest(
                deviceName: deviceName,
                devicePlatform: devicePlatform
            )
        )
    }

    /// Poll the pairing row for status. Terminal statuses (approved /
    /// denied / expired / consumed) return HTTP 200 with a status field;
    /// a 404 means the row no longer exists (cleaned up post-expiry).
    func pollDeviceLogin(deviceCode: String) async throws -> DeviceLoginPollResponse {
        try await HTTPClient.shared.post(
            "/api/v1/auth/device/poll",
            body: DeviceLoginPollRequest(deviceCode: deviceCode)
        )
    }

    // MARK: - Sign Out

    /// Sign out of the active server. Keeps the registry entry (URL +
    /// display name) so the user can log back in without re-adding the
    /// server. Call `ServerRegistry.shared.remove(serverId:)` to fully
    /// forget a server instead.
    @discardableResult
    func signOut() async -> Bool {
        let signingOutServerId = ServerRegistry.shared.activeServerId
        let signingOutAuth = await TokenStore.shared.captureOrdinaryRequestAuth()
        let authorization = Self.signOutAuthorization(
            activeServerId: signingOutServerId,
            capturedAuth: signingOutAuth
        )
        guard case .allowed(let signingOutAccount) = authorization else {
            return false
        }
        #if os(iOS) || os(tvOS)
        // Purge the active binding now, while still authenticated: the /logout
        // below invalidates the session, after which the binding could only be
        // resolved from the last-known snapshot. The registry-wide purge always
        // runs in ServerRegistry.signOut regardless, catching diagnostics under
        // older server_instance_ids for this URL.
        let purgedCurrentBinding = await DiagnosticsCoordinator.shared.purgeDiagnosticsForCurrentBinding()
        #else
        let purgedCurrentBinding = false
        #endif
        // Best-effort server-side logout; never block sign-out on a
        // server-side error, since the client wants to end the session
        // regardless.
        if let signingOutAccount {
            do {
                try await HTTPClient.shared.postVoid(
                    "/api/v1/auth/logout",
                    expectedAccount: signingOutAccount
                )
            } catch {
                // Swallow; the captured account check below still prevents
                // clearing a server selected while logout was in flight.
            }
        }
        #if os(iOS) || os(tvOS)
        if !purgedCurrentBinding,
           ServerRegistry.shared.activeServerId == signingOutServerId {
            _ = await DiagnosticsCoordinator.shared.purgeDiagnosticsForCurrentBinding()
        }
        if let signingOutServerId {
            await DiagnosticsCoordinator.shared.purgeDiagnosticsForServerRegistryID(signingOutServerId)
        }
        #endif
        guard let transitionLease = await HTTPClient.shared.beginIdentityTransition() else {
            return false
        }
        guard !Task.isCancelled else {
            await HTTPClient.shared.endIdentityTransition(transitionLease)
            return false
        }
        await HTTPClient.shared.cancelInFlightRequests()
        guard !Task.isCancelled,
              ServerRegistry.shared.activeServerId == signingOutServerId,
              await TokenStore.shared.refreshAccountIdentity() == signingOutAccount else {
            await HTTPClient.shared.endIdentityTransition(transitionLease)
            return false
        }
        if let signingOutServerId {
            await ServerRegistry.shared.signOut(
                serverId: signingOutServerId,
                purgeCurrentBinding: false,
                purgeRegistryBindings: false
            )
        } else {
            await TokenStore.shared.clearTokens()
        }
        await clearAllCaches()
        await HTTPClient.shared.endIdentityTransition(transitionLease)
        return true
    }

    /// Decide whether a captured credential can authorize local sign-out.
    /// Missing capture data is allowed so a damaged URL/defaults mirror cannot
    /// strand Keychain credentials. A temporary playback overlay is refused:
    /// its owner must end that generation before persistent state is touched.
    static func signOutAuthorization(
        activeServerId: String?,
        capturedAuth: CapturedOrdinaryRequestAuth?
    ) -> SignOutAuthorization {
        if capturedAuth?.credentialOwner == .temporary {
            return .refused
        }
        guard let activeServerId, !activeServerId.isEmpty else {
            return .allowed(account: capturedAuth?.account)
        }
        guard let capturedAuth else {
            return .allowed(account: nil)
        }
        guard capturedAuth.credentialOwner == .persistentServer(
            serverId: activeServerId
        ), capturedAuth.account.serverId == activeServerId else {
            return .refused
        }
        return .allowed(account: capturedAuth.account)
    }

    /// Wipe every cached response. Sign-out boundary: tokens are gone,
    /// the next session must start clean.
    @MainActor
    private func clearAllCaches() {
        StartupContentPrefetcher.resetAllPrefetches()
        ResponseCache.shared.clearAll()
        OverlayPrefsStore.shared.clear()
        ProfilePrefsStore.shared.clear()
        AICapabilities.shared.reset()
        RequestsFeatureStore.shared.reset()
        RequestsEventBus.shared.reset()
        #if os(tvOS)
        ItemDetailCache.shared.clearAll()
        #endif
    }

    /// A remote-playback handoff changes server/account/profile without
    /// touching the persistent registry. Treat both entry and restoration as
    /// full auth boundaries so cached user data cannot cross identities.
    @MainActor
    func clearCachesForTemporaryIdentityChange() {
        clearAllCaches()
    }

    /// A server switch is the same hard identity boundary as sign-out for
    /// process-wide response and prefetch caches, even when both servers are
    /// already authenticated and the router's auth state does not change.
    @MainActor
    func clearCachesForServerChange() {
        clearAllCaches()
    }
}
