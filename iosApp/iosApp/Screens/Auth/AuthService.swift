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

    private init() {}

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
    /// identify it via `GET /api/v1/health`, register the entry, and
    /// return the setup status so the caller can decide between initial
    /// setup and login.
    ///
    /// The sequence matters: we set the URL first because `HTTPClient`
    /// needs it to build requests, then upsert the registry entry with
    /// the advertised server identity. If the health probe fails
    /// (older server, 404) we still register the entry so the user can
    /// proceed — the display name falls back to the URL.
    func checkServer(url: String) async throws -> SetupStatus {
        let normalized = ServerRegistry.normalize(url: url)
        let id = ServerRegistry.serverId(for: normalized)
        let previousActiveId = ServerRegistry.shared.activeServerId

        // Point HTTPClient + TokenStore at this server before any probe.
        await TokenStore.shared.setServerUrl(normalized)
        await TokenStore.shared.switchActiveServer(serverId: id)

        // Fetch identity. Tolerate failure: older servers omit these
        // fields and we still want the URL to work.
        var fetchedName: String?
        if let health: HealthStatus = try? await HTTPClient.shared.get("/api/v1/health") {
            fetchedName = health.serverName
        }

        // Probe /auth/setup BEFORE committing. If it fails we must
        // restore the previous active server so the user isn't silently
        // switched into a half-configured one.
        let status: SetupStatus
        do {
            status = try await HTTPClient.shared.get("/api/v1/auth/setup")
        } catch {
            if let previousActiveId, previousActiveId != id {
                await ServerRegistry.shared.switchTo(serverId: previousActiveId)
            }
            throw error
        }

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

    // MARK: - Authentication

    func login(username: String, password: String) async throws {
        let response: LoginResponse = try await HTTPClient.shared.post(
            "/api/v1/auth/login",
            body: LoginRequest(username: username, password: password)
        )
        await startSession(accessToken: response.accessToken, refreshToken: response.refreshToken)
    }

    func setupAdmin(username: String, email: String, password: String) async throws {
        let response: LoginResponse = try await HTTPClient.shared.post(
            "/api/v1/auth/setup",
            body: SetupRequest(username: username, email: email, password: password)
        )
        await startSession(accessToken: response.accessToken, refreshToken: response.refreshToken)
    }

    func signup(username: String, email: String, password: String, inviteCode: String) async throws {
        let response: LoginResponse = try await HTTPClient.shared.post(
            "/api/v1/auth/signup",
            body: SignupRequest(
                username: username,
                email: email,
                password: password,
                inviteCode: inviteCode
            )
        )
        await startSession(accessToken: response.accessToken, refreshToken: response.refreshToken)
    }

    // MARK: - Emailed invitations

    /// Resolves an invitation claim token against the server named in the
    /// deep link. Points HTTPClient at that server first (same sequencing as
    /// `checkServer`): the claim flow starts before any session exists.
    func lookupInvitation(serverUrl: String, token: String) async throws -> InvitationLookupResponse {
        let normalized = ServerRegistry.normalize(url: serverUrl)
        let id = ServerRegistry.serverId(for: normalized)
        await TokenStore.shared.setServerUrl(normalized)
        await TokenStore.shared.switchActiveServer(serverId: id)
        return try await HTTPClient.shared.get("/api/v1/invitations/\(token)")
    }

    /// Accepts an invitation: the account is created server-side with the
    /// invitation's email as username, and a normal session begins. The
    /// server entry is registered so the session survives restarts.
    func acceptInvitation(serverUrl: String, token: String, password: String) async throws {
        let normalized = ServerRegistry.normalize(url: serverUrl)
        let id = ServerRegistry.serverId(for: normalized)
        var fetchedName: String?
        if let health: HealthStatus = try? await HTTPClient.shared.get("/api/v1/health") {
            fetchedName = health.serverName
        }
        let response: LoginResponse = try await HTTPClient.shared.post(
            "/api/v1/invitations/\(token)/accept",
            body: AcceptInvitationRequest(password: password)
        )
        ServerRegistry.shared.addOrUpdate(ServerEntry(
            id: id,
            url: normalized,
            fetchedName: fetchedName,
            profileId: nil,
            lastUsedAt: Date()
        ))
        if ServerRegistry.shared.activeServerId != id {
            await ServerRegistry.shared.switchTo(serverId: id)
        }
        await startSession(accessToken: response.accessToken, refreshToken: response.refreshToken)
    }

    /// A login response establishes a brand-new session. Wipe every piece of
    /// prior auth state before persisting the new tokens — no need to carry
    /// `profileId` or `profileToken` across the boundary, and keeping them
    /// just strands stale values that the server rejects.
    private func startSession(accessToken: String, refreshToken: String) async {
        await TokenStore.shared.clearTokens()
        await TokenStore.shared.saveTokens(
            accessToken: accessToken,
            refreshToken: refreshToken
        )
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
    func signOut() async {
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
        do {
            try await HTTPClient.shared.postVoid("/api/v1/auth/logout")
        } catch {
            // Swallow; state will still be cleared locally.
        }
        if let activeId = ServerRegistry.shared.activeServerId {
            // Only skip the redundant current-binding purge if it already
            // succeeded above; the registry-wide purge runs either way.
            await ServerRegistry.shared.signOut(
                serverId: activeId,
                purgeCurrentBinding: !purgedCurrentBinding
            )
        } else {
            await TokenStore.shared.clearTokens()
        }
        await clearAllCaches()
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
