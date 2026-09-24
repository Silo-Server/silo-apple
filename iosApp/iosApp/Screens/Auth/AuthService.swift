import Foundation

/// Thin service layer for auth / profile operations backed by the native
/// Swift `HTTPClient`.
///
/// Shares the same token/profile storage as `SiloAPI` via
/// ``TokenStore/shared``. Server metadata lives in `ServerRegistry`; active
/// profile identity is a separate current-user request scope coordinated with
/// `ProfileLaunchPreferences`.
final class AuthService: @unchecked Sendable {
    static let shared = AuthService()
    private let defaults = SharedDefaults.shared
    private let serverIdentityResolver: ServerIdentityResolver
    private let serverRegistry: ServerRegistry
    private let launchPreferences: ProfileLaunchPreferences
    private let restoredSessionValidator: RestoredSessionValidator
    private let contractProbe: APIv2Probe
    private let apiV2Client: APIv2Client
    private let httpClient: HTTPClient
    private let tokenStore: TokenStore
    private let sessionPersistence: AccountSessionPersistence
    private let purgeDiagnostics: @Sendable (String) async -> Bool

    enum SignOutAuthorization: Equatable, Sendable {
        case allowed(account: RefreshAccountIdentity?)
        case refused
    }

    enum SignOutOutcome: Equatable, Sendable {
        /// Credentials were cleared and the canonical record was invalidated.
        case completed
        /// Credentials were invalidated, but local diagnostics could not be erased.
        case diagnosticsCleanupFailed
        /// Nothing was changed: the sign-out was not authorised or the
        /// active identity changed while it ran.
        case refused
        /// Process-local credentials were cleared but the canonical record
        /// could not be invalidated, so the session can return after a
        /// relaunch. The caller should leave the signed-in UI but must not
        /// report a durable sign-out.
        case localOnly
    }

    init(
        serverIdentityResolver: ServerIdentityResolver = ServerIdentityResolver(),
        serverRegistry: ServerRegistry = .shared,
        launchPreferences: ProfileLaunchPreferences = .shared,
        restoredSessionValidator: RestoredSessionValidator = .live,
        contractProbe: APIv2Probe = APIv2Probe(),
        apiV2Client: APIv2Client = SiloAPI.shared.apiV2Client,
        httpClient: HTTPClient = .shared,
        tokenStore: TokenStore = .shared,
        sessionPersistence: AccountSessionPersistence = AccountSessionPersistence(keychain: SharedKeychain()),
        purgeDiagnostics: @escaping @Sendable (String) async -> Bool = { serverID in
            #if os(iOS) || os(tvOS)
            return await DiagnosticsCoordinator.shared.purgeDiagnosticsForServerRegistryID(serverID)
            #else
            return true
            #endif
        }
    ) {
        self.serverIdentityResolver = serverIdentityResolver
        self.serverRegistry = serverRegistry
        self.launchPreferences = launchPreferences
        self.restoredSessionValidator = restoredSessionValidator
        self.contractProbe = contractProbe
        self.apiV2Client = apiV2Client
        self.httpClient = httpClient
        self.tokenStore = tokenStore
        self.sessionPersistence = sessionPersistence
        self.purgeDiagnostics = purgeDiagnostics
    }

    /// Runs the v2 contract probe for `serverId` and records the verdict.
    /// The generation is issued before the await so an older probe that
    /// finishes after a newer one cannot overwrite its verdict; the monitor
    /// also drops the result unless `serverId` is still the active server.
    /// Only `.v2` and `.updateServer` change the verdict; a transport or HTTP
    /// failure leaves the previous one in place (a timeout is not an old
    /// server). Nothing here throws: the verdict closes the v2 gate, and
    /// gated calls then report that the server needs an update.
    private func recordContractVerdict(serverId: String, serverURL: String) async {
        let generation = await MainActor.run {
            ConnectionMonitor.shared.beginContractProbe(serverId: serverId)
        }
        let result = await contractProbe.probe(serverURL: serverURL)
        await MainActor.run {
            ConnectionMonitor.shared.noteContractProbe(result, serverId: serverId, generation: generation)
        }
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

    var hasServer: Bool { serverRegistry.hasActiveServer }

    /// Use the same canonical record as TokenStore. Legacy mirrors cannot
    /// revive a session after its sign-out tombstone has been written.
    var isLoggedIn: Bool {
        guard let server = serverRegistry.activeServer else { return false }
        return sessionPersistence.hasSession(serverID: server.id, origin: ServerRegistry.normalize(url: server.url))
    }

    var hasProfile: Bool { profileId != nil }

    // MARK: - Server Check

    /// Probe a candidate server: set it as the active server URL,
    /// identify it via native branding, register the entry, and
    /// return the setup status so the caller can decide between initial
    /// setup and login.
    ///
    /// Candidate probes use their explicit URL and no active credentials.
    /// Global registry/default/token routing changes only after setup status
    /// succeeds. If both optional identity probes fail, the display name
    /// falls back to the URL. A v1-only server fails the setup read with
    /// `APIv2Error.serverUpdateRequired`, so it is never committed.
    func checkServer(url: String) async throws -> APIv2SetupStatus {
        let normalized = ServerRegistry.normalize(url: url)
        let id = ServerRegistry.serverId(for: normalized)

        // Probe the candidate by explicit URL without touching the active
        // defaults or credential slot. This prevents candidate discovery from
        // exposing a global A/B routing mixture to unrelated requests.
        let fetchedName = await serverIdentityResolver.fetchServerName(serverURL: normalized)
        try Task.checkCancellation()
        // Best effort: an older server has no identity and the entry simply
        // stays unmatched across addresses until it is upgraded.
        let verifiedServerId = await serverIdentityResolver.fetchServerIdentity(serverURL: normalized)
        try Task.checkCancellation()

        // Commit only after the candidate proves it can serve setup status.
        let status = try await apiV2Client.setupStatus(serverURL: normalized)
        try Task.checkCancellation()

        // Success: upsert the registry entry and make it active.
        let entry = ServerEntry(
            id: id,
            url: normalized,
            fetchedName: fetchedName,
            profileId: nil,
            lastUsedAt: Date(),
            verifiedServerId: verifiedServerId
        )
        guard serverRegistry.addOrUpdate(entry) != nil else {
            throw ServerRegistryError.persistenceFailed
        }
        if serverRegistry.activeServerId != id {
            guard await serverRegistry.switchTo(serverId: id) else {
                throw ServerRegistryError.persistenceFailed
            }
        }
        // Now that the candidate is the active server, establish the v2
        // contract verdict the pilot gate reads. Recorded after the switch so
        // a candidate that is not committed never touches the active verdict.
        await recordContractVerdict(serverId: id, serverURL: normalized)
        try Task.checkCancellation()

        return status
    }

    /// Refreshes the active registry entry from the server's native branding.
    /// The identity check prevents a slow response from one server renaming a
    /// different server after the user switches destinations.
    func refreshActiveServerName() async {
        guard let server = serverRegistry.activeServer else { return }
        let serverId = server.id
        // Refreshing the cached identity is the other moment the contract
        // verdict is (re)established: server switch, foreground return, and
        // unreachable->reachable recovery all come through here.
        await recordContractVerdict(serverId: serverId, serverURL: server.url)
        guard serverRegistry.activeServerId == serverId else { return }
        await refreshVerifiedServerId(for: server)
        guard serverRegistry.activeServerId == serverId else { return }
        guard let name = await serverIdentityResolver.fetchServerName(serverURL: server.url),
              serverRegistry.activeServerId == serverId else {
            return
        }
        serverRegistry.updateFetchedName(for: serverId, fetchedName: name)
    }

    /// Re-runs the contract probe for the active server and records the
    /// verdict under the usual generation and active-server rules. The
    /// restored-session validator calls this when a v2 read succeeds while
    /// the verdict still says v1-only, so an in-place upgrade clears it.
    func recheckActiveServerContract() async {
        guard let server = serverRegistry.activeServer else { return }
        await recordContractVerdict(serverId: server.id, serverURL: server.url)
    }

    /// Learns (or re-learns) the deployment identity behind a saved server so
    /// SiloRemote and companion pairing can recognise it at other addresses.
    /// Servers added before the identity contract pick it up here on their
    /// next activation or foreground refresh.
    func refreshVerifiedServerId(for server: ServerEntry) async {
        guard let identity = await serverIdentityResolver.fetchServerIdentity(serverURL: server.url) else {
            return
        }
        serverRegistry.updateVerifiedServerId(for: server.id, verifiedServerId: identity)
    }

    /// Validate a Keychain-restored account without changing the remembered
    /// server entry. Temporary failures return `indeterminate`; only the
    /// existing HTTP refresh policy may invalidate a terminally rejected
    /// credential while the account probe is in flight.
    func validateRestoredSession(
        expected: RefreshAccountIdentity
    ) async -> RestoredSessionValidationResult {
        await restoredSessionValidator.validate(expected: expected)
    }

    // MARK: - Authentication

    /// Password sign-in through `POST /api/v2/auth/login`. The token pair
    /// names the account it authenticates, so the session is installed with
    /// that verified account id. A v1-only server is refused before the
    /// request leaves the device (`APIv2Error.serverUpdateRequired`).
    func login(username: String, password: String) async throws {
        guard let expectedAccount = await tokenStore.refreshAccountIdentity() else {
            throw HTTPError.serverUrlNotConfigured
        }
        let tokens = try await apiV2Client.login(
            username: username,
            password: password,
            expectedAccount: expectedAccount
        )
        try await installSession(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            accountID: tokens.user.id,
            expectedAccount: expectedAccount
        )
    }

    /// A new login clears the prior profile. Failed installation restores the
    /// previous session before releasing the identity transition.
    ///
    /// `accountID` is the account the server said the tokens authenticate
    /// (v2 `TokenPair.user.id`); it binds the session so durable account work
    /// can capture it.
    func installSession(
        accessToken: String,
        refreshToken: String,
        accountID: String,
        expectedAccount: RefreshAccountIdentity
    ) async throws {
        guard let transitionLease = await httpClient.beginIdentityTransition() else {
            throw CancellationError()
        }
        do {
            try Task.checkCancellation()
            await httpClient.cancelInFlightRequests()
            try Task.checkCancellation()
            guard await tokenStore.refreshAccountIdentity() == expectedAccount else {
                try Task.checkCancellation()
                throw HTTPError.requestIdentityChanged
            }
            let previousSession = await tokenStore.accountSessionSnapshot(for: expectedAccount.serverId)
            guard previousSession != .unreadable else {
                throw AccountSessionPersistenceError.unavailable
            }
            let previousProfileID = await tokenStore.getProfileId()
            await tokenStore.clearTokens()
            do {
                try await tokenStore.installAccountSession(
                    accessToken: accessToken,
                    refreshToken: refreshToken,
                    accountID: accountID
                )
            } catch {
                // TokenStore blocks the session if restoration also fails.
                _ = await tokenStore.restoreAccountSession(previousSession, for: expectedAccount.serverId)
                await tokenStore.setProfileId(previousProfileID)
                throw error
            }
            launchPreferences.clearRememberedProfile(for: expectedAccount.serverId)
            await clearAllCaches()
        } catch {
            await httpClient.endIdentityTransition(transitionLease)
            throw error
        }
        await httpClient.endIdentityTransition(transitionLease)
    }

    // MARK: - Profiles

    func getProfiles() async throws -> [UserProfile] {
        try await SiloAPI.shared.listProfiles()
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

        let profileToken = try await SiloAPI.shared.verifyProfileSelection(
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
            await CurrentProfileStore.shared.refresh(force: true)
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
                // Cold return records may require the profile picker. Keep
                // them until the selected identity can validate ownership;
                // explicit in-app profile changes clear them before this path.
                await clearPerProfileCaches(preservingTrailerReturn: true, preservingWatchPartyRecent: true)
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
                // Restore the same remembered identity without discarding its
                // pending trailer handoff or its authority-scoped recent party.
                await clearPerProfileCaches(preservingTrailerReturn: true, preservingWatchPartyRecent: true)
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
        // Preserve cold return records through the picker. After authentication,
        // their owner checks accept only the same account and profile.
        // Explicit profile switches already clear them during deactivation.
        await clearPerProfileCaches(preservingTrailerReturn: true, preservingWatchPartyRecent: true)
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
                name: .siloProfileSelectionRequired,
                object: expectedProfileID
            )
        }
    }

    /// Drop every cached response that's profile-scoped. Called while
    /// restoring or changing profile identity so userData (watched, favorites,
    /// watchlist, home recommendations) doesn't leak between accounts.
    @MainActor
    private func clearPerProfileCaches(preservingTrailerReturn: Bool = false, preservingWatchPartyRecent: Bool = false) {
        StartupContentPrefetcher.resetProfileScopedPrefetches()
        for prefix in CacheKey.perProfilePrefixes {
            ResponseCache.shared.removeAll(withPrefix: prefix)
        }
        PersonalStateHolds.shared.reset()
        // Profiles are account-scoped and are the offline source for Who's
        // Watching. Keep that list across profile transitions; server/account
        // boundaries still clear it through `clearAllCaches()`.
        // Overlay prefs are stored at profile scope (`ui.card_overlays`),
        // so the next profile must re-read them.
        OverlayPrefsStore.shared.clear()
        // Profile's preferred subtitle language drives detail-page track
        // ordering; drop it so the next profile re-hydrates its own.
        ProfilePrefsStore.shared.clear()
        // Server-wide AI capability + per-user ASR quota are reset on every
        // profile switch; `selectProfile` re-fetches after the switch lands.
        AICapabilities.shared.reset()
        ImageSizeCapability.shared.reset()
        WatchPartySession.shared.leave(forgetRecent: !preservingWatchPartyRecent)
        RequestsFeatureStore.shared.reset()
        CurrentProfileStore.shared.reset()
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
        try await SiloAPI.shared.createProfile(
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

    /// Opens a pairing request through `POST /api/v2/auth/device/start`
    /// (`non_retryable`: one dispatch, no bearer). A v1-only server is refused
    /// with `APIv2Error.serverUpdateRequired`.
    func startDeviceLogin(
        deviceName: String,
        devicePlatform: String,
        expectedAccount: RefreshAccountIdentity
    ) async throws -> DeviceLoginStartResponse {
        try await apiV2Client.startDeviceLogin(
            DeviceLoginStartRequest(deviceName: deviceName, devicePlatform: devicePlatform),
            expectedAccount: expectedAccount
        )
    }

    /// Polls the pairing request through `POST /api/v2/auth/device/poll`.
    /// Terminal statuses answer 200 with a status field; a 404 problem means
    /// the request no longer exists. Tokens arrive once, on the first
    /// `approved` answer, so the caller must install them from this value.
    func pollDeviceLogin(
        deviceCode: String,
        expectedAccount: RefreshAccountIdentity
    ) async throws -> APIv2DevicePoll {
        try await apiV2Client.pollDeviceLogin(deviceCode: deviceCode, expectedAccount: expectedAccount)
    }

    // MARK: - Sign Out

    /// Clear local credentials under the identity gate. Remote revocation uses
    /// only the outgoing credential and cannot delay logout or alter a new login.
    func signOutWithOutcome() async -> SignOutOutcome {
        let serverID = serverRegistry.activeServerId
        let capturedAuth = await tokenStore.captureOrdinaryRequestAuth()
        guard case .allowed(let account) = Self.signOutAuthorization(
            activeServerId: serverID, capturedAuth: capturedAuth
        ) else { return .refused }
        guard let lease = await httpClient.beginIdentityTransition() else { return .refused }
        await httpClient.cancelInFlightRequests()
        guard !Task.isCancelled,
              serverRegistry.activeServerId == serverID,
              await tokenStore.refreshAccountIdentity() == account else {
            await httpClient.endIdentityTransition(lease)
            return .refused
        }
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileWillChange()
        #endif
        let durable = await tokenStore.clearTokens()
        var diagnosticsRemoved = true
        if let serverID {
            launchPreferences.clearRememberedProfile(for: serverID)
            diagnosticsRemoved = await purgeDiagnostics(serverID)
        }
        await clearAllCaches()
        await httpClient.endIdentityTransition(lease)
        if let capturedAuth {
            Task { await httpClient.revokeSession(capturedAuth) }
        }
        guard durable else { return .localOnly }
        return diagnosticsRemoved ? .completed : .diagnosticsCleanupFailed
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
        PersonalStateHolds.shared.reset()
        OverlayPrefsStore.shared.clear()
        ProfilePrefsStore.shared.clear()
        AICapabilities.shared.reset()
        ImageSizeCapability.shared.reset()
        WatchPartySession.shared.leave(forgetRecent: true)
        RequestsFeatureStore.shared.reset()
        CurrentProfileStore.shared.reset()
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
