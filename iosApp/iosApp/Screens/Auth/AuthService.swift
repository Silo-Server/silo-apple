import Foundation

/// Thin service layer for auth / profile operations backed by the native
/// Swift `HTTPClient`.
///
/// Shares the same token/profile storage as `ContinuumAPI` via
/// ``TokenStore/shared``. Server metadata lives in `ServerRegistry`; active
/// profile identity is a separate current-user request scope coordinated with
/// `ProfileLaunchPreferences`.
final class AuthService: @unchecked Sendable {
    static let shared = AuthService()
    private let defaults = SharedDefaults.shared
    private let serverIdentityResolver: ServerIdentityResolver
    private let serverRegistry: ServerRegistry
    private let launchPreferences: ProfileLaunchPreferences

    enum SignOutAuthorization: Equatable, Sendable {
        case allowed(account: RefreshAccountIdentity?)
        case refused
    }

    init(
        serverIdentityResolver: ServerIdentityResolver = ServerIdentityResolver(),
        serverRegistry: ServerRegistry = .shared,
        launchPreferences: ProfileLaunchPreferences = .shared
    ) {
        self.serverIdentityResolver = serverIdentityResolver
        self.serverRegistry = serverRegistry
        self.launchPreferences = launchPreferences
    }

    // MARK: - Stored State Accessors

    /// Active server URL. Read-only: changing the active server goes
    /// through `ServerRegistry.switchTo`, which mirrors the URL to the
    /// legacy `UserDefaults["serverUrl"]` slot for sync readers.
    var serverUrl: String { ServerRegistry.shared.activeServerUrl }

    /// Active request profile. Mutations must use the transition APIs below so
    /// profile ID, verification proof, caches, diagnostics, and Top Shelf stay
    /// on one identity boundary.
    var profileId: String? { defaults.string(forKey: SharedStorage.profileIdKey) }

    var hasServer: Bool { ServerRegistry.shared.hasActiveServer }

    /// Sync check used by SwiftUI bodies and view-state gates. Reads the
    /// active server's Keychain slot directly — Keychain APIs are
    /// synchronous, so no actor hop is needed.
    var isLoggedIn: Bool {
        guard let id = ServerRegistry.shared.activeServerId, !id.isEmpty else {
            return false
        }
        return SharedKeychain(audience: .userIndependent)
            .get(TokenStore.accessTokenKey(for: id)) != nil
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
        try Task.checkCancellation()

        // Commit only after the candidate proves it can serve setup status.
        let status: SetupStatus = try await HTTPClient.shared.getUnauthenticated(
            serverURL: normalized,
            path: "/api/v1/auth/setup"
        )
        try Task.checkCancellation()

        // Success: upsert the registry entry and make it active.
        let entry = ServerEntry(
            id: id,
            url: normalized,
            fetchedName: fetchedName,
            profileId: nil,
            lastUsedAt: Date()
        )
        guard ServerRegistry.shared.addOrUpdate(entry) != nil else {
            throw ServerRegistryError.persistenceFailed
        }
        if ServerRegistry.shared.activeServerId != id {
            guard await ServerRegistry.shared.switchTo(serverId: id) else {
                throw ServerRegistryError.persistenceFailed
            }
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
        if let serverID = serverRegistry.activeServerId {
            launchPreferences.clearRememberedProfile(for: serverID)
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

    func selectProfile(
        profileId: String,
        pin: String? = nil,
        requiresPIN: Bool = false,
        rememberSelection: Bool = true
    ) async throws {
        guard let expectedAccount = await TokenStore.shared.refreshAccountIdentity() else {
            throw ProfileTransitionError.noActiveAccount
        }
        guard !(await TokenStore.shared.hasTemporaryScope()) else {
            throw ProfileTransitionError.temporaryIdentityActive
        }

        let profileToken = try await ContinuumAPI.shared.verifyProfileSelection(
            profileId: profileId,
            pin: pin
        )
        if requiresPIN, profileToken == nil {
            throw ProfileTransitionError.missingPINProof
        }
        try await activateProfile(
            profileID: profileId,
            profileToken: profileToken,
            requiresPIN: requiresPIN,
            rememberSelection: rememberSelection,
            expectedAccount: expectedAccount
        )
        // Re-probe capabilities for the newly-selected profile. Fire and
        // forget so profile navigation is never held behind an optional
        // feature probe. Artwork-bearing API methods await the coalesced image
        // probe at their own request boundary before dispatching.
        Task { @MainActor in
            await AICapabilities.shared.refresh()
            await ImageSizeCapability.shared.refresh()
            await RequestsFeatureStore.shared.refresh()
            // Unlike the two above, this one gates *enablement* of an entry
            // point that stays visible either way, and it defaults to
            // available — so a slow or failing probe never hides anything.
            await SubtitleProvidersStore.shared.refresh()
        }
    }

    /// Resolve the active server's launch policy. Returns `true` only when a
    /// complete remembered identity was restored; callers otherwise present
    /// Who's Watching while retaining the account session.
    func resolveActiveProfileForSession() async -> Bool {
        guard let transitionLease = await HTTPClient.shared.beginIdentityTransition() else {
            return false
        }
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileWillChange()
        #endif
        await HTTPClient.shared.cancelInFlightRequests()
        let resolved = await resolveActiveProfileForSession(holding: transitionLease)
        await HTTPClient.shared.endIdentityTransition(transitionLease)
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileDidChange()
        #endif
        return resolved
    }

    /// Resolve launch policy while a server transition already owns the HTTP
    /// identity gate. The gate stays closed until the destination's profile
    /// ID and proof have been committed (or deliberately cleared).
    func resolveActiveProfileForSession(
        holding transitionLease: HTTPIdentityTransitionLease
    ) async -> Bool {
        guard await HTTPClient.shared.isIdentityTransitionActive(transitionLease) else {
            return false
        }
        guard let serverID = serverRegistry.activeServerId,
              let expectedAccount = await TokenStore.shared.refreshAccountIdentity(),
              let accountEpoch = await TokenStore.shared.getOrCreateAccountEpoch() else {
            return false
        }
        let profileToken = await TokenStore.shared.getProfileToken()
        let knownProfileIDs: Set<String>? = await MainActor.run {
            ResponseCache.shared
                .get(CacheKey.profiles, as: [UserProfile].self)
                .map { Set($0.map(\.id)) }
        }
        let resolution = launchPreferences.resolution(
            for: serverID,
            accountEpoch: accountEpoch,
            hasStoredProfileToken: profileToken != nil,
            knownProfileIDs: knownProfileIDs
        )

        if case .needsSelection = resolution,
           let remembered = launchPreferences.rememberedProfile(for: serverID),
           knownProfileIDs?.contains(remembered.profileID) == false {
            launchPreferences.clearRememberedProfile(for: serverID)
        }

        switch resolution {
        case .needsSelection:
            let committed = await TokenStore.shared.deactivateProfile(
                expectedAccount: expectedAccount
            )
            if committed {
                // A cold trailer return may require the profile picker. Keep
                // the record until the selected identity can validate it;
                // explicit in-app profile changes clear it before this path.
                await clearPerProfileCaches(preservingTrailerReturn: true)
            }
            return false

        case .restore(let remembered):
            let committed = await TokenStore.shared.activateProfile(
                profileID: remembered.profileID,
                profileToken: remembered.requiredPINAtSelection ? profileToken : nil,
                expectedAccount: expectedAccount
            )
            if committed {
                guard launchPreferences.clearBackgroundedAt() else {
                    _ = await TokenStore.shared.deactivateProfile(
                        expectedAccount: expectedAccount,
                        expectedProfileID: remembered.profileID
                    )
                    await clearPerProfileCaches()
                    return false
                }
                // This is launch restoration of the same remembered identity,
                // not a profile boundary. Keep a matching trailer handoff
                // alive until ContentView can consume it after authentication.
                await clearPerProfileCaches(preservingTrailerReturn: true)
                return true
            } else {
                _ = await TokenStore.shared.deactivateProfile(
                    expectedAccount: expectedAccount
                )
                return false
            }
        }
    }

    /// Persist an explicit switch request before clearing request identity so
    /// killing the app on the picker cannot make Automatic silently restore
    /// the previous profile.
    func beginExplicitProfileSelection() async -> Bool {
        await PlayerSettings.shared.flushPendingDeviceSettings()
        return await deactivateProfile(
            preserveRememberedProfile: true,
            markSelectionRequired: true
        )
    }

    /// Clear active profile identity while retaining the account session.
    /// This path owns the HTTP transition barrier for launch, explicit switch,
    /// and temporary profile-management cleanup.
    func deactivateProfile(
        preserveRememberedProfile: Bool,
        markSelectionRequired: Bool = false,
        expectedProfileID: String? = nil
    ) async -> Bool {
        guard !(await TokenStore.shared.hasTemporaryScope()) else { return false }
        if let expectedProfileID, profileId != expectedProfileID { return false }
        let serverID = serverRegistry.activeServerId
        let expectedAccount = await TokenStore.shared.refreshAccountIdentity()
        let removedRememberedProfile = preserveRememberedProfile
            ? nil
            : launchPreferences.rememberedProfile(for: serverID)

        if markSelectionRequired, let serverID {
            guard launchPreferences.markSelectionRequired(for: serverID) else {
                return false
            }
        }
        if !preserveRememberedProfile, let serverID {
            launchPreferences.clearRememberedProfile(for: serverID)
        }

        guard let transitionLease = await HTTPClient.shared.beginIdentityTransition() else {
            if markSelectionRequired, let serverID {
                launchPreferences.clearSelectionRequired(for: serverID)
            }
            restoreRememberedProfile(removedRememberedProfile, for: serverID)
            return false
        }
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileWillChange()
        #endif
        await HTTPClient.shared.cancelInFlightRequests()
        let committed = await TokenStore.shared.deactivateProfile(
            expectedAccount: expectedAccount,
            expectedProfileID: expectedProfileID
        )
        if committed {
            await clearPerProfileCaches()
        } else if markSelectionRequired, let serverID {
            launchPreferences.clearSelectionRequired(for: serverID)
        }
        if !committed {
            restoreRememberedProfile(removedRememberedProfile, for: serverID)
        }
        await HTTPClient.shared.endIdentityTransition(transitionLease)
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileDidChange()
        #endif
        return committed
    }

    private func activateProfile(
        profileID: String,
        profileToken: String?,
        requiresPIN: Bool,
        rememberSelection: Bool,
        expectedAccount: RefreshAccountIdentity
    ) async throws {
        guard let serverID = serverRegistry.activeServerId else {
            throw ProfileTransitionError.noActiveServer
        }
        guard let accountEpoch = await TokenStore.shared.getOrCreateAccountEpoch() else {
            throw ProfileTransitionError.accountEpochUnavailable
        }
        guard let transitionLease = await HTTPClient.shared.beginIdentityTransition() else {
            throw CancellationError()
        }
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileWillChange()
        #endif
        await HTTPClient.shared.cancelInFlightRequests()
        guard !Task.isCancelled,
              await TokenStore.shared.activateProfile(
                profileID: profileID,
                profileToken: profileToken,
                expectedAccount: expectedAccount
              ) else {
            await HTTPClient.shared.endIdentityTransition(transitionLease)
            #if os(iOS) || os(tvOS)
            DiagnosticsCoordinator.activeProfileDidChange()
            #endif
            if Task.isCancelled { throw CancellationError() }
            throw ProfileTransitionError.identityChanged
        }
        if rememberSelection {
            guard launchPreferences.remember(
                profileID: profileID,
                requiresPIN: requiresPIN,
                accountEpoch: accountEpoch,
                for: serverID
            ) else {
                _ = await TokenStore.shared.deactivateProfile(
                    expectedAccount: expectedAccount,
                    expectedProfileID: profileID
                )
                await HTTPClient.shared.endIdentityTransition(transitionLease)
                #if os(iOS) || os(tvOS)
                DiagnosticsCoordinator.activeProfileDidChange()
                #endif
                throw ProfileTransitionError.accountEpochUnavailable
            }
        }
        // Preserve a cold trailer return through the picker. Once the router
        // becomes authenticated, ContentView consumes it and the identity
        // policy either restores the matching page or rejects the record.
        // Explicit profile switches already clear it during deactivation.
        await clearPerProfileCaches(preservingTrailerReturn: true)
        await HTTPClient.shared.endIdentityTransition(transitionLease)
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileDidChange()
        #endif
    }

    private func restoreRememberedProfile(
        _ remembered: RememberedProfile?,
        for serverID: String?
    ) {
        guard let remembered, let serverID else { return }
        launchPreferences.remember(
            profileID: remembered.profileID,
            requiresPIN: remembered.requiredPINAtSelection,
            accountEpoch: remembered.accountEpoch,
            for: serverID
        )
    }

    /// Reconcile a fresh account-level profile list with the current request
    /// identity. A removed profile returns to Who's Watching without touching
    /// the still-valid account tokens.
    func reconcileAvailableProfiles(_ profiles: [UserProfile]) async {
        guard let activeProfileID = profileId,
              !profiles.contains(where: { $0.id == activeProfileID }) else {
            return
        }
        await recoverFromInvalidProfile(expectedProfileID: activeProfileID)
    }

    /// Recover from the server's profile-specific 403/404 responses. The
    /// expected ID prevents a late failed request from clearing a profile the
    /// user selected after that request started.
    func recoverFromInvalidProfile(expectedProfileID: String) async {
        guard profileId == expectedProfileID else { return }
        let serverID = serverRegistry.activeServerId
        let expectedAccount = await TokenStore.shared.refreshAccountIdentity()
        guard let transitionLease = await HTTPClient.shared.beginIdentityTransition() else {
            return
        }
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileWillChange()
        #endif
        await HTTPClient.shared.cancelInFlightRequests()
        let committed = await TokenStore.shared.deactivateProfile(
            expectedAccount: expectedAccount,
            expectedProfileID: expectedProfileID
        )
        if committed {
            if let serverID {
                launchPreferences.clearRememberedProfile(for: serverID)
            }
            await clearPerProfileCaches()
        }
        await HTTPClient.shared.endIdentityTransition(transitionLease)
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileDidChange()
        #endif
        guard committed else { return }
        await MainActor.run {
            NotificationCenter.default.post(
                name: .continuumProfileSelectionRequired,
                object: expectedProfileID
            )
        }
    }

    /// Drop every cached response that's profile-scoped. Called while
    /// restoring or changing profile identity so userData (watched, favorites,
    /// watchlist, home recommendations) doesn't leak between accounts.
    @MainActor
    private func clearPerProfileCaches(preservingTrailerReturn: Bool = false) {
        StartupContentPrefetcher.resetProfileScopedPrefetches()
        for prefix in CacheKey.perProfilePrefixes {
            ResponseCache.shared.removeAll(withPrefix: prefix)
        }
        // Profiles are account-scoped and are the offline source for Who's
        // Watching. Keep that list across profile transitions; server/account
        // boundaries still clear it through `clearAllCaches()`.
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
        ImageSizeCapability.shared.reset()
        RequestsFeatureStore.shared.reset()
        SubtitleProvidersStore.shared.reset()
        RequestsEventBus.shared.reset()
        #if os(tvOS)
        ItemDetailCache.shared.clearAll()
        if !preservingTrailerReturn {
            // The identity check in TrailerReturnPolicy already refuses a record
            // across identities; deleting here keeps the outgoing identity's
            // browsing out of plaintext defaults on a shared device.
            TVTrailerReturnStore.shared.clear()
        }
        #endif
    }

    func createProfile(
        name: String,
        avatarEmoji: String?,
        pin: String?,
        isChild: Bool,
        maxContentRating: String? = nil,
        libraryRestrictionsEnabled: Bool = false,
        allowedLibraryIds: [Int] = []
    ) async throws -> UserProfile {
        try await ContinuumAPI.shared.createProfile(
            name: name,
            avatarEmoji: avatarEmoji,
            pin: pin,
            isChild: isChild,
            maxContentRating: maxContentRating,
            libraryRestrictionsEnabled: libraryRestrictionsEnabled,
            allowedLibraryIds: allowedLibraryIds
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
        ImageSizeCapability.shared.reset()
        RequestsFeatureStore.shared.reset()
        SubtitleProvidersStore.shared.reset()
        RequestsEventBus.shared.reset()
        #if os(tvOS)
        ItemDetailCache.shared.clearAll()
        // The identity check in TrailerReturnPolicy already refuses a record
        // across identities; deleting here keeps the outgoing identity's
        // browsing out of plaintext defaults on a shared device.
        TVTrailerReturnStore.shared.clear()
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
