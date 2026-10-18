import Foundation

/// A finished sign-in that nothing has saved yet (plan §2.9): every sign-in
/// path produces one, and `SiloUserCoordinator.completeSignIn` decides where
/// it goes, or asks first. It holds secrets and is never logged.
struct PendingSignIn: Equatable, Sendable {
    let serverID: String
    /// The normalized server URL the tokens were issued at.
    let origin: String
    let accessToken: String
    let refreshToken: String
    /// The account the server said the tokens authenticate. Pairing and
    /// device-code sign-ins carry no username until `/api/v2/account/me`.
    let account: SignInAccount
    /// The identity captured before the request was sent. The sign-in is
    /// saved only while it is still the active one.
    let expected: RefreshAccountIdentity

    init(accessToken: String, refreshToken: String, account: SignInAccount, expected: RefreshAccountIdentity) {
        self.serverID = expected.serverId
        self.origin = expected.serverURL
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.account = account
        self.expected = expected
    }

    init(tokens: APIv2LoginTokens, expected: RefreshAccountIdentity) {
        self.init(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            account: SignInAccount(id: tokens.user.id, username: ServerIdentity.usable(tokens.user.username)),
            expected: expected
        )
    }

    /// The saved sign-in this would be. Nil for an account ID that can't
    /// name one.
    var key: SignInKey? { SignInKey(serverID: serverID, accountID: account.id) }

    /// The session, for ending it when nobody keeps the sign-in.
    var revocable: RevocableCredential {
        RevocableCredential(serverURL: origin, accessToken: accessToken, refreshToken: refreshToken)
    }
}

extension SignInPlacement {
    /// The placement policy's answer, case for case.
    init(_ placement: SignInPlacementPolicy.Placement) {
        switch placement {
        case .refresh(let key): self = .refresh(key)
        case .join(let userID): self = .join(userID: userID)
        case .newUser: self = .newUser
        }
    }
}

/// Thin service layer for auth / profile operations backed by the native
/// Swift `HTTPClient`.
///
/// Shares the same token/profile storage as `SiloAPI` via
/// ``TokenStore/shared``. Server metadata lives in `ServerRegistry`; active
/// profile identity is a separate current-user request scope coordinated with
/// `ProfileLaunchPreferences`.
final class AuthService: @unchecked Sendable {
    static let shared = AuthService()
    private let defaults: SharedDefaults
    private let serverIdentityResolver: ServerIdentityResolver
    let serverRegistry: ServerRegistry
    let launchPreferences: ProfileLaunchPreferences
    private let restoredSessionValidator: RestoredSessionValidator
    private let contractProbe: APIv2Probe
    private let apiV2Client: APIv2Client
    let httpClient: HTTPClient
    let tokenStore: TokenStore
    private let sessionPersistence: AccountSessionPersistence
    private let purgeDiagnostics: @Sendable (String) async -> Bool
    /// Turns the server's push registration off (`ApplePushRegistrationCoordinator.unregister`).
    private let unregisterPush: @Sendable (String) async -> Void
    /// Turns it back on after a sign-out that did not happen (`ApplePushRegistrationCoordinator.restore`).
    private let restorePush: @Sendable (String) async -> Void

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
        defaults: SharedDefaults = .shared,
        sessionPersistence: AccountSessionPersistence = AccountSessionPersistence(keychain: SharedKeychain()),
        purgeDiagnostics: @escaping @Sendable (String) async -> Bool = { serverID in
            #if os(iOS) || os(tvOS)
            return DiagnosticsCoordinator.shared.purgeDiagnosticsForServerRegistryID(serverID)
            #else
            return true
            #endif
        },
        unregisterPush: @escaping @Sendable (String) async -> Void = { serverID in
            #if os(iOS)
            await ApplePushRegistrationCoordinator.shared.unregister(serverID: serverID)
            #endif
        },
        restorePush: @escaping @Sendable (String) async -> Void = { serverID in
            #if os(iOS)
            await ApplePushRegistrationCoordinator.shared.restore(serverID: serverID)
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
        self.defaults = defaults
        self.sessionPersistence = sessionPersistence
        self.purgeDiagnostics = purgeDiagnostics
        self.unregisterPush = unregisterPush
        self.restorePush = restorePush
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

    /// The verified account of the credential selected on the active
    /// server: the selected saved sign-in's (the `activeAccountId` mirror),
    /// else the account recorded in the server's own session. Nil when
    /// signed out or for a legacy session that never recorded its account.
    var accountID: String? {
        guard let server = serverRegistry.activeServer else { return nil }
        if let accountID = tokenStore.mirroredAccountID { return accountID }
        guard legacySessionCounts(for: server.id),
              case .session(let session)? = try? sessionPersistence.load(server.id),
              session.origin == ServerRegistry.normalize(url: server.url) else { return nil }
        return session.accountID
    }

    /// Whether the active server's selected credential is signed in, read
    /// from the same records TokenStore loads. Legacy mirrors cannot revive a
    /// session after its sign-out tombstone has been written. Nothing
    /// selected (a chooser, the server step, or a sign-in screen) is signed
    /// out, even on a server whose own session is still saved.
    var isLoggedIn: Bool {
        guard let server = serverRegistry.activeServer else { return false }
        let origin = ServerRegistry.normalize(url: server.url)
        switch tokenStore.mirroredSelection {
        case .signIn(let key):
            guard key.serverID == server.id,
                  let signIn = try? tokenStore.savedSignIns.loadSignIn(key) else { return false }
            return signIn.isSignedIn && ServerRegistry.normalize(url: signIn.origin) == origin
        case .legacy(let serverID):
            guard serverID == server.id, legacySessionCounts(for: server.id) else { return false }
            return sessionPersistence.hasSession(serverID: server.id, origin: origin)
        case .none:
            return false
        }
    }

    /// A server's own session is read before sign-in migration, and after it
    /// only while the server is a pending legacy server.
    private func legacySessionCounts(for serverID: String) -> Bool {
        guard let index = try? tokenStore.savedSignIns.loadIndex() else { return true }
        return index.users.contains { $0.pendingLegacyServerIDs?.contains(serverID) == true }
    }

    var hasProfile: Bool { profileId != nil }

    // MARK: - Server Check

    /// Probe a candidate server: set it as the active server URL,
    /// identify it via native branding, register the entry, and
    /// return the setup status so the caller can decide between initial
    /// setup and login. The candidate becomes active with no credential
    /// selected: every server added continues to sign-in
    /// (`SiloUserCoordinator.beginSignIn`).
    ///
    /// Candidate probes use their explicit URL and no active credentials.
    /// Global registry/default/token routing changes only after setup status
    /// succeeds. If both optional identity probes fail, the display name
    /// falls back to the URL. A v1-only server fails the setup read with
    /// `APIv2Error.serverUpdateRequired`, so it is never committed.
    ///
    /// A plain-HTTP candidate that redirects to HTTPS on its own host, or on
    /// its name completed with a domain (an overlay provider's bare name), is
    /// committed as that HTTPS origin: the redirect answers reads only, so
    /// saving the typed URL would fail sign-in.
    func checkServer(url: String) async throws -> APIv2SetupStatus {
        var normalized = ServerRegistry.normalize(url: url)
        if normalized.lowercased().hasPrefix("http://"),
           let secure = await OverlayNameResolver(timeout: ServerIdentity.probeTimeout).secureOrigin(redirectedFrom: normalized) {
            normalized = secure
        }
        try Task.checkCancellation()
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
        // A saved entry for the same origin keeps its own id.
        guard let saved = serverRegistry.addOrUpdate(entry) else {
            throw ServerRegistryError.persistenceFailed
        }
        if serverRegistry.activeServerId != saved.id {
            guard await serverRegistry.switchTo(serverId: saved.id, credential: .none, userID: nil) else {
                throw ServerRegistryError.persistenceFailed
            }
        }
        // Now that the candidate is the active server, establish the v2
        // contract verdict the pilot gate reads. Recorded after the switch so
        // a candidate that is not committed never touches the active verdict.
        await recordContractVerdict(serverId: saved.id, serverURL: saved.url)
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

    /// The active server's verified deployment identity, learned now when the
    /// entry has none yet. Browser sign-in checks the app redirect's `server`
    /// against it, so a flow finished by another server is refused. Nil when
    /// the server cannot say, and when the active server changed meanwhile.
    func verifiedIdentityOfActiveServer() async -> String? {
        guard let server = serverRegistry.activeServer else { return nil }
        if let known = ServerIdentity.usable(server.verifiedServerId) { return known }
        await refreshVerifiedServerId(for: server)
        guard serverRegistry.activeServerId == server.id else { return nil }
        return ServerIdentity.usable(serverRegistry.activeServer?.verifiedServerId)
    }

    /// What the login screen offers on the active server: browser providers
    /// and whether the password form shows. Never throws; nil when discovery
    /// could not be read (see `APIv2Client.signInOptions(serverURL:)`).
    func signInOptions() async -> SignInOptions? {
        let url = serverUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return .passwordOnly }
        return await apiV2Client.signInOptions(serverURL: url)
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
    /// names the account it authenticates. Nothing is saved: the caller
    /// places the result (`SiloUserCoordinator.completeSignIn`). A v1-only
    /// server is refused before the request leaves the device
    /// (`APIv2Error.serverUpdateRequired`).
    func login(username: String, password: String) async throws -> PendingSignIn {
        try await requestSignIn { [apiV2Client] expectedAccount in
            try await apiV2Client.login(username: username, password: password, expectedAccount: expectedAccount)
        }
    }

    /// Network identity sign-in (`signInWithNetworkIdentity`) through
    /// `provider`, a network provider discovery listed for the active server:
    /// `{}` posted to its sign-in path on the saved base URL, with no password
    /// and no bearer. The provider's network says who owns this device. The
    /// token pair is placed exactly as a password sign-in's.
    func signInWithNetworkIdentity(_ provider: APIv2AuthProvider) async throws -> PendingSignIn {
        guard let apiPath = NetworkSignIn.apiPath(of: provider) else {
            throw HTTPError.invalidURL(provider.networkSignInPath ?? "")
        }
        return try await requestSignIn { [apiV2Client] expectedAccount in
            try await apiV2Client.signInWithNetworkIdentity(apiPath: apiPath, expectedAccount: expectedAccount)
        }
    }

    /// A sign-in that answers a token pair for the active server, under the
    /// account identity captured before the request was sent.
    private func requestSignIn(
        _ request: (RefreshAccountIdentity) async throws -> APIv2LoginTokens
    ) async throws -> PendingSignIn {
        guard let expectedAccount = await tokenStore.refreshAccountIdentity() else {
            throw HTTPError.serverUrlNotConfigured
        }
        let tokens = try await request(expectedAccount)
        return PendingSignIn(tokens: tokens, expected: expectedAccount)
    }

    /// Saves a sign-in outside any user flow, as a first sign-in would be
    /// placed: the same account refreshes its saved sign-in, a new one
    /// founds a user, and before migration the server's own session is
    /// replaced. Tests and debug sign-in use this; the app's screens go
    /// through `SiloUserCoordinator.completeSignIn`.
    ///
    /// `accountID` is the account the server said the tokens authenticate
    /// (v2 `TokenPair.user.id`).
    func installSession(
        accessToken: String,
        refreshToken: String,
        accountID: String,
        expectedAccount: RefreshAccountIdentity
    ) async throws {
        try await commitOutsideUserFlow(PendingSignIn(
            accessToken: accessToken,
            refreshToken: refreshToken,
            account: SignInAccount(id: accountID, username: nil),
            expected: expectedAccount
        ))
    }

    /// `installSession` for a sign-in already in hand.
    func commitOutsideUserFlow(_ pending: PendingSignIn) async throws {
        let directory: SiloUserDirectorySnapshot
        do {
            directory = try await tokenStore.directory()
        } catch SavedSignInAccessError.notMigrated {
            try await commitLegacySignIn(pending)
            return
        } catch {
            throw AccountSessionPersistenceError.unavailable
        }
        switch SignInPlacementPolicy.decide(context: .firstRun, serverID: pending.serverID,
                                            accountID: pending.account.id, username: pending.account.username,
                                            directory: directory) {
        case .place(let placement)?:
            _ = try await commitSignIn(pending, placement: SignInPlacement(placement))
        case .switchToExisting(let key, _)?:
            _ = try await commitSignIn(pending, placement: .refresh(key))
        case .ask?, nil:
            discardSignIn(pending)
            throw AccountSessionPersistenceError.invalidIdentity
        }
    }

    /// Saves `pending` where `placement` says (plan §2.5): the identity
    /// captured before the request must still be active, the sign-in becomes
    /// the selected credential, and this Apple TV user's remembered profile
    /// and pending Switch Profile for it go, because the session is new. A
    /// refreshed sign-in's previous session is revoked afterwards.
    ///
    /// Pass `lease` when the caller already holds the identity transition
    /// (phone pairing); otherwise this takes it and cancels requests first.
    func commitSignIn(
        _ pending: PendingSignIn,
        placement: SignInPlacement,
        holding lease: HTTPIdentityTransitionLease? = nil
    ) async throws -> SignInInstallResult {
        let result = try await withSignInTransition(holding: lease) { [tokenStore] in
            try await tokenStore.installSignIn(
                accessToken: pending.accessToken,
                refreshToken: pending.refreshToken,
                account: pending.account,
                origin: pending.origin,
                placement: placement,
                expected: pending.expected
            )
        }
        launchPreferences.forgetSignIn(
            result.key,
            legacyOwnerAccountID: await tokenStore.legacyDataOwner(forServer: result.key.serverID)
        )
        revoke(result.superseded.map { [$0] } ?? [])
        return result
    }

    /// Before sign-in migration: replace the server's own session, as
    /// signing in always has, restoring it if the install fails.
    func commitLegacySignIn(_ pending: PendingSignIn, holding lease: HTTPIdentityTransitionLease? = nil) async throws {
        try await withSignInTransition(holding: lease) { [self] in
            try await replaceServerSession(
                accessToken: pending.accessToken,
                refreshToken: pending.refreshToken,
                accountID: pending.account.id,
                serverID: pending.serverID
            )
        }
        launchPreferences.forgetLegacyProfile(forServer: pending.serverID)
    }

    /// A sign-in nobody kept (a prompt answered Cancel): end its session on
    /// the server.
    func discardSignIn(_ pending: PendingSignIn) {
        revoke([pending.revocable])
    }

    /// Runs `install` under the identity transition, after checking the
    /// session's captured identity is still active, then clears every cache.
    private func withSignInTransition<T>(
        holding held: HTTPIdentityTransitionLease?,
        _ install: () async throws -> T
    ) async throws -> T {
        let lease: HTTPIdentityTransitionLease
        if let held {
            guard await httpClient.isIdentityTransitionActive(held) else { throw CancellationError() }
            lease = held
        } else {
            guard let acquired = await httpClient.beginIdentityTransition() else { throw CancellationError() }
            lease = acquired
        }
        func release() async {
            if held == nil { await httpClient.endIdentityTransition(lease) }
        }
        let value: T
        do {
            if held == nil {
                try Task.checkCancellation()
                await httpClient.cancelInFlightRequests()
                try Task.checkCancellation()
            }
            value = try await install()
            await clearAllCaches()
        } catch {
            await release()
            throw error
        }
        await release()
        return value
    }

    /// Before sign-in migration: replace the server's own session, restoring
    /// it if the install fails.
    private func replaceServerSession(
        accessToken: String,
        refreshToken: String,
        accountID: String,
        serverID: String
    ) async throws {
        let previousSession = await tokenStore.accountSessionSnapshot(for: serverID)
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
            _ = await tokenStore.restoreAccountSession(previousSession, for: serverID)
            await tokenStore.setProfileId(previousProfileID)
            throw error
        }
    }

    /// Ends sessions this device no longer keeps, after local state is
    /// already gone, without waiting.
    func revoke(_ credentials: [RevocableCredential]) {
        for credential in credentials {
            Task { [httpClient] in await httpClient.revoke(credential) }
        }
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
        guard let expectedAccount = await tokenStore.refreshAccountIdentity() else {
            throw ProfileTransitionError.noActiveAccount
        }
        guard !(await tokenStore.hasTemporaryScope()) else {
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
            await ShuffleFeatureStore.shared.refresh()
            await CurrentProfileStore.shared.refresh(force: true)
            // Unlike the two above, this one gates *enablement* of an entry
            // point that stays visible either way, and it defaults to
            // available — so a slow or failing probe never hides anything.
            await SubtitleProvidersStore.shared.refresh()
        }
    }

    /// Which launch-state entries the selected credential reads and writes:
    /// a saved sign-in's, or a server's own session's (before migration, or
    /// a pending legacy server).
    enum LaunchStateScope: Equatable, Sendable {
        /// `legacyOwnerAccountID` is the account that took over the server's
        /// state recorded before sign-ins existed.
        case signIn(SignInKey, legacyOwnerAccountID: String?)
        case legacy(serverID: String)
    }

    /// The selected credential's launch-state scope; nil with nothing
    /// selected.
    func currentLaunchStateScope() async -> LaunchStateScope? {
        switch await tokenStore.currentSelection() {
        case .none:
            return nil
        case .legacy(let serverID):
            return .legacy(serverID: serverID)
        case .signIn(let key):
            return .signIn(key, legacyOwnerAccountID: await tokenStore.legacyDataOwner(forServer: key.serverID))
        }
    }

    /// The profile remembered for the selected credential (Who's Watching's
    /// "Last used"), whatever Profile Selection says.
    func rememberedProfileForCurrentSelection() async -> RememberedProfile? {
        rememberedProfile(in: await currentLaunchStateScope(), accountEpoch: await tokenStore.getOrCreateAccountEpoch())
    }

    /// The same read without waiting, from the selection mirror, for a
    /// screen's first frame: tvOS puts initial focus on the "Last used"
    /// profile, and a value that arrives a moment later no longer moves it.
    /// Only an entry recorded before sign-ins existed needs the saved
    /// sign-in's epoch, so only that one reads the keychain.
    var rememberedProfileIDForCurrentSelection: String? {
        switch tokenStore.mirroredSelection {
        case .signIn(let key):
            if let remembered = launchPreferences.rememberedProfile(for: key, accountEpoch: nil) {
                return remembered.profileID
            }
            guard launchPreferences.legacyRememberedProfile(forServer: key.serverID) != nil else { return nil }
            let epoch = (try? tokenStore.savedSignIns.loadSignIn(key))?.epoch?.uuidString
            return launchPreferences.rememberedProfile(for: key, accountEpoch: epoch)?.profileID
        case .legacy(let serverID):
            return launchPreferences.legacyRememberedProfile(forServer: serverID)?.profileID
        case .none:
            return nil
        }
    }

    /// Resolve the selected sign-in's launch policy. Returns `true` only when
    /// a complete remembered identity was restored; callers otherwise
    /// present Who's Watching while retaining the account session.
    func resolveActiveProfileForSession() async -> Bool {
        guard let transitionLease = await httpClient.beginIdentityTransition() else {
            return false
        }
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileWillChange()
        #endif
        await httpClient.cancelInFlightRequests()
        let resolved = await resolveActiveProfileForSession(holding: transitionLease)
        await httpClient.endIdentityTransition(transitionLease)
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
        guard await httpClient.isIdentityTransitionActive(transitionLease) else {
            return false
        }
        guard let scope = await currentLaunchStateScope(),
              let expectedAccount = await tokenStore.refreshAccountIdentity(),
              let accountEpoch = await tokenStore.getOrCreateAccountEpoch() else {
            return false
        }
        let profileToken = await tokenStore.getProfileToken()
        let knownProfileIDs: Set<String>? = await MainActor.run {
            ResponseCache.shared
                .get(CacheKey.profiles, as: [UserProfile].self)
                .map { Set($0.map(\.id)) }
        }
        let resolution: ProfileLaunchResolution
        let remembered: RememberedProfile?
        switch scope {
        case .signIn(let key, let legacyOwner):
            // The server-keyed state from before sign-ins existed moves onto
            // its owner the first time that sign-in resolves here.
            launchPreferences.adoptLegacyEntries(for: key, accountEpoch: accountEpoch,
                                                 legacyOwnerAccountID: legacyOwner)
            resolution = launchPreferences.resolution(
                for: key,
                accountEpoch: accountEpoch,
                hasStoredProfileToken: profileToken != nil,
                knownProfileIDs: knownProfileIDs,
                legacyOwnerAccountID: legacyOwner
            )
            remembered = launchPreferences.rememberedProfile(for: key, accountEpoch: accountEpoch)
        case .legacy(let serverID):
            resolution = launchPreferences.legacyResolution(
                forServer: serverID,
                accountEpoch: accountEpoch,
                hasStoredProfileToken: profileToken != nil,
                knownProfileIDs: knownProfileIDs
            )
            remembered = launchPreferences.legacyRememberedProfile(forServer: serverID)
        }

        if case .needsSelection = resolution,
           let remembered,
           knownProfileIDs?.contains(remembered.profileID) == false {
            forgetRememberedProfile(in: scope)
        }

        switch resolution {
        case .needsSelection:
            let committed = await tokenStore.deactivateProfile(
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
            let committed = await tokenStore.activateProfile(
                profileID: remembered.profileID,
                profileToken: remembered.requiredPINAtSelection ? profileToken : nil,
                expectedAccount: expectedAccount
            )
            if committed {
                guard launchPreferences.clearBackgroundedAt() else {
                    _ = await tokenStore.deactivateProfile(
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
                _ = await tokenStore.deactivateProfile(
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
        guard !(await tokenStore.hasTemporaryScope()) else { return false }
        if let expectedProfileID, profileId != expectedProfileID { return false }
        let scope = await currentLaunchStateScope()
        let expectedAccount = await tokenStore.refreshAccountIdentity()
        let epoch = await tokenStore.getOrCreateAccountEpoch()
        let removedRememberedProfile = preserveRememberedProfile
            ? nil
            : rememberedProfile(in: scope, accountEpoch: epoch)

        if markSelectionRequired, let scope {
            guard markSelectionRequiredFor(scope) else {
                return false
            }
        }
        if !preserveRememberedProfile, let scope {
            forgetRememberedProfile(in: scope)
        }

        guard let transitionLease = await httpClient.beginIdentityTransition() else {
            if markSelectionRequired, let scope {
                clearSelectionRequiredFor(scope)
            }
            restoreRememberedProfile(removedRememberedProfile, in: scope)
            return false
        }
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileWillChange()
        #endif
        await httpClient.cancelInFlightRequests()
        let committed = await tokenStore.deactivateProfile(
            expectedAccount: expectedAccount,
            expectedProfileID: expectedProfileID
        )
        if committed {
            await clearPerProfileCaches()
        } else if markSelectionRequired, let scope {
            clearSelectionRequiredFor(scope)
        }
        if !committed {
            restoreRememberedProfile(removedRememberedProfile, in: scope)
        }
        await httpClient.endIdentityTransition(transitionLease)
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
        guard serverRegistry.activeServerId != nil, let scope = await currentLaunchStateScope() else {
            throw ProfileTransitionError.noActiveServer
        }
        guard let accountEpoch = await tokenStore.getOrCreateAccountEpoch() else {
            throw ProfileTransitionError.accountEpochUnavailable
        }
        guard let transitionLease = await httpClient.beginIdentityTransition() else {
            throw CancellationError()
        }
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileWillChange()
        #endif
        await httpClient.cancelInFlightRequests()
        guard !Task.isCancelled,
              await tokenStore.activateProfile(
                profileID: profileID,
                profileToken: profileToken,
                expectedAccount: expectedAccount
              ) else {
            await httpClient.endIdentityTransition(transitionLease)
            #if os(iOS) || os(tvOS)
            DiagnosticsCoordinator.activeProfileDidChange()
            #endif
            if Task.isCancelled { throw CancellationError() }
            throw ProfileTransitionError.identityChanged
        }
        if rememberSelection {
            guard remember(profileID: profileID, requiresPIN: requiresPIN, accountEpoch: accountEpoch, in: scope) else {
                _ = await tokenStore.deactivateProfile(
                    expectedAccount: expectedAccount,
                    expectedProfileID: profileID
                )
                await httpClient.endIdentityTransition(transitionLease)
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
        await httpClient.endIdentityTransition(transitionLease)
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileDidChange()
        #endif
    }

    // MARK: Launch state by scope

    private func rememberedProfile(in scope: LaunchStateScope?, accountEpoch: String?) -> RememberedProfile? {
        switch scope {
        case .signIn(let key, _)?:
            return launchPreferences.rememberedProfile(for: key, accountEpoch: accountEpoch)
        case .legacy(let serverID)?:
            return launchPreferences.legacyRememberedProfile(forServer: serverID)
        case nil:
            return nil
        }
    }

    @discardableResult
    private func remember(profileID: String, requiresPIN: Bool, accountEpoch: String, in scope: LaunchStateScope) -> Bool {
        switch scope {
        case .signIn(let key, let legacyOwner):
            return launchPreferences.remember(profileID: profileID, requiresPIN: requiresPIN,
                                              accountEpoch: accountEpoch, for: key, legacyOwnerAccountID: legacyOwner)
        case .legacy(let serverID):
            return launchPreferences.rememberLegacy(profileID: profileID, requiresPIN: requiresPIN,
                                                    accountEpoch: accountEpoch, forServer: serverID)
        }
    }

    private func forgetRememberedProfile(in scope: LaunchStateScope) {
        switch scope {
        case .signIn(let key, let legacyOwner):
            launchPreferences.forgetSignIn(key, legacyOwnerAccountID: legacyOwner)
        case .legacy(let serverID):
            launchPreferences.forgetLegacyProfile(forServer: serverID)
        }
    }

    private func markSelectionRequiredFor(_ scope: LaunchStateScope) -> Bool {
        switch scope {
        case .signIn(let key, _):
            return launchPreferences.markSelectionRequired(for: key)
        case .legacy(let serverID):
            return launchPreferences.markLegacySelectionRequired(forServer: serverID)
        }
    }

    private func clearSelectionRequiredFor(_ scope: LaunchStateScope) {
        switch scope {
        case .signIn(let key, let legacyOwner):
            launchPreferences.clearSelectionRequired(for: key, legacyOwnerAccountID: legacyOwner)
        case .legacy(let serverID):
            launchPreferences.clearLegacySelectionRequired(forServer: serverID)
        }
    }

    private func restoreRememberedProfile(
        _ remembered: RememberedProfile?,
        in scope: LaunchStateScope?
    ) {
        guard let remembered, let scope else { return }
        remember(profileID: remembered.profileID, requiresPIN: remembered.requiredPINAtSelection,
                 accountEpoch: remembered.accountEpoch, in: scope)
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

    /// Recovery for `HTTPClient`'s `.siloProfileVerificationRequired`: the
    /// server stopped accepting the active profile's proof (for example after
    /// an admin changed the account's access), but the account session is
    /// still valid. Delivery is asynchronous, so the event is applied only
    /// while the account that sent the rejected request is still current,
    /// and only to the selection that sent it.
    func recoverFromProfileVerificationRequired(_ event: ProfileVerificationRequiredEvent) async {
        guard await tokenStore.refreshAccountIdentity() == event.account else { return }
        await recoverFromInvalidProfile(
            expectedProfileID: event.profileID,
            expectedProfileSelection: event.profileSelection
        )
    }

    /// Recover from the server's profile-specific 403/404 responses. The
    /// expected ID prevents a late failed request from clearing a profile the
    /// user selected after that request started. A caller that knows which
    /// selection was rejected also passes `expectedProfileSelection`, so a
    /// recovery that waited behind the user selecting the same profile again
    /// leaves that new selection in place.
    func recoverFromInvalidProfile(
        expectedProfileID: String,
        expectedProfileSelection: UUID? = nil
    ) async {
        guard profileId == expectedProfileID else { return }
        let scope = await currentLaunchStateScope()
        let expectedAccount = await tokenStore.refreshAccountIdentity()
        guard let transitionLease = await httpClient.beginIdentityTransition() else {
            return
        }
        // Several failures can start a recovery for the same profile (the
        // Home prefetch and the global 403 signal, or one observer per
        // window). Leases queue, so a later caller gets here only after the
        // first finished; it must not cancel the requests Who's Watching has
        // started since, nor clear a selection made meanwhile.
        var isStillCurrent = profileId == expectedProfileID
        if isStillCurrent, let expectedProfileSelection {
            isStillCurrent = await tokenStore.isCurrentProfileSelection(expectedProfileSelection)
        }
        guard isStillCurrent else {
            await httpClient.endIdentityTransition(transitionLease)
            return
        }
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.activeProfileWillChange()
        #endif
        await httpClient.cancelInFlightRequests()
        let committed = await tokenStore.deactivateProfile(
            expectedAccount: expectedAccount,
            expectedProfileID: expectedProfileID,
            expectedProfileSelection: expectedProfileSelection
        )
        if committed {
            if let scope {
                forgetRememberedProfile(in: scope)
            }
            await clearPerProfileCaches()
        }
        await httpClient.endIdentityTransition(transitionLease)
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

    /// Saves the profiles a sign-in's account has, so user cards can draw
    /// them without the server (`SavedSignIn.profiles`). `key` is the
    /// sign-in the list was read for; a list read for another sign-in, or
    /// before migration, changes nothing. Neither does one read while a
    /// remote-playback identity answers requests: that list is another
    /// account's.
    func updateSignInDisplayCache(_ profiles: [UserProfile], for key: SignInKey?) async {
        guard let key, await tokenStore.currentSignInKey() == key,
              !(await tokenStore.hasTemporaryScope()) else { return }
        await tokenStore.updateSignInDisplay(key, username: nil, profiles: profiles.map(SavedSignInProfile.init))
    }

    /// Drop every cached response that's profile-scoped. Called while
    /// restoring or changing profile identity so userData (watched, favorites,
    /// watchlist, home recommendations) doesn't leak between accounts.
    @MainActor
    private func clearPerProfileCaches(preservingTrailerReturn: Bool = false, preservingWatchPartyRecent: Bool = false) {
        StartupContentPrefetcher.resetProfileScopedPrefetches()
        for prefix in CacheKey.perProfilePrefixes {
            ResponseCache.shared.clearMemory(withPrefix: prefix)
        }
        // Profiles are account-scoped and are the offline source for Who's
        // Watching. Keep that list across profile transitions; server/account
        // boundaries still clear it through `clearAllCaches()`.
        resetIdentityScopedStores(forgetWatchPartyRecent: !preservingWatchPartyRecent,
                                  preservingTrailerReturn: preservingTrailerReturn)
    }

    /// The in-memory stores both cache boundaries reset, after their own
    /// prefetch and response-cache clearing.
    @MainActor
    private func resetIdentityScopedStores(forgetWatchPartyRecent: Bool, preservingTrailerReturn: Bool) {
        PersonalStateHolds.shared.reset()
        // Overlay prefs are stored at profile scope (`ui.card_overlays`),
        // so the next profile must re-read them.
        OverlayPrefsStore.shared.clear()
        AdvisoryAgePreferenceStore.shared.clear()
        // Profile's preferred subtitle language drives detail-page track
        // ordering; drop it so the next profile re-hydrates its own.
        ProfilePrefsStore.shared.clear()
        // Server-wide AI capability + per-user ASR quota are reset on every
        // profile switch; `selectProfile` re-fetches after the switch lands.
        AICapabilities.shared.reset()
        // Hero cards' landed translations belong to this profile's language.
        CardDescriptionTranslation.shared.reset()
        ImageSizeCapability.shared.reset()
        WatchPartySession.shared.leave(forgetRecent: forgetWatchPartyRecent)
        RequestsFeatureStore.shared.reset()
        ShuffleFeatureStore.shared.reset()
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

    /// `GET /api/v2/auth/device/capability`, read without credentials.
    func deviceLoginCapability(expectedAccount: RefreshAccountIdentity) async throws -> APIv2DeviceCapability {
        try await apiV2Client.deviceLoginCapability(expectedAccount: expectedAccount)
    }

    // MARK: - Sign Out

    /// What a sign-out or removal acts on (spec §5.6).
    enum SignInRemovalTarget: Equatable, Sendable {
        /// The selected credential: its saved sign-in, its pending legacy
        /// server, or before migration the server's own session.
        case current
        /// One saved sign-in, current or not (Sign Out of {server}).
        case signIn(SignInKey)
        /// Every sign-in in a user, which removes the user (Remove from This
        /// Apple TV).
        case user(String)
    }

    /// Sign the current user out of the active server: the selected saved
    /// sign-in is removed (and its user, when it was the last one), or
    /// before migration the server's own session.
    func signOutWithOutcome() async -> SignOutOutcome {
        await removeSignIns(.current)
    }

    /// Signs out of or removes `target` under the identity gate (plan §2.6).
    /// The sessions are captured, then the sign-ins and this Apple TV user's
    /// proofs, remembered profiles, pending switches, links, and last
    /// servers for them are removed, and each session is revoked afterwards
    /// (refreshing first if it expired) without waiting. Diagnostics for a
    /// server are purged only when no sign-in remains on it. When the
    /// selected credential is affected, push is turned off for its server
    /// first and every cache is cleared; a temporary playback scope refuses.
    func removeSignIns(_ target: SignInRemovalTarget) async -> SignOutOutcome {
        let serverID = serverRegistry.activeServerId
        let selection = await tokenStore.currentSelection()
        let affectsCurrent = await includesSelection(target)
        var account: RefreshAccountIdentity?
        if affectsCurrent {
            let capturedAuth = await tokenStore.captureOrdinaryRequestAuth()
            guard case .allowed(let allowed) = Self.signOutAuthorization(
                activeServerId: serverID, capturedAuth: capturedAuth
            ) else { return .refused }
            account = allowed
            // Only a device that can still authenticate can tell the server
            // to stop pushing, so this runs before the credentials are
            // cleared. A refused sign-out keeps the server signed in, so its
            // pushes are turned back on.
            if let serverID { await unregisterPush(serverID) }
        } else if await tokenStore.hasTemporaryScope() {
            return .refused
        }
        guard let lease = await httpClient.beginIdentityTransition() else {
            if affectsCurrent, let serverID { await restorePush(serverID) }
            return .refused
        }
        if affectsCurrent {
            await httpClient.cancelInFlightRequests()
            guard !Task.isCancelled,
                  serverRegistry.activeServerId == serverID,
                  await tokenStore.refreshAccountIdentity() == account else {
                await httpClient.endIdentityTransition(lease)
                if let serverID { await restorePush(serverID) }
                return .refused
            }
            #if os(iOS) || os(tvOS)
            DiagnosticsCoordinator.activeProfileWillChange()
            #endif
        } else if await includesSelection(target) {
            // A switch that landed before the lease opened what this
            // removes, so its push and caches were never handled here.
            await httpClient.endIdentityTransition(lease)
            return .refused
        }
        let directory = try? await tokenStore.directory()

        var removedKeys: [SignInKey] = []
        var removedLegacyServers: [String] = []
        let removals: [SignInRemoval]
        switch target {
        case .current:
            switch selection {
            case .signIn(let key): removedKeys = [key]
            case .legacy(let legacyServerID): removedLegacyServers = [legacyServerID]
            case .none: break
            }
            removals = [await tokenStore.removeCurrentCredential()]
        case .signIn(let key):
            removedKeys = [key]
            removals = [await tokenStore.removeSignIn(key)]
        case .user(let userID):
            let user = directory?.user(withID: userID)
            removedKeys = user?.signIns ?? []
            removedLegacyServers = user?.pendingLegacyServerIDs ?? []
            removals = await tokenStore.removeUser(userID)
        }

        for key in removedKeys {
            launchPreferences.forgetSignIn(
                key,
                legacyOwnerAccountID: await tokenStore.legacyDataOwner(forServer: key.serverID)
            )
        }
        for legacyServerID in removedLegacyServers {
            launchPreferences.forgetLegacyProfile(forServer: legacyServerID)
        }
        for userID in Set(removals.compactMap(\.removedUserID)) {
            launchPreferences.forgetUser(userID)
        }
        if case .user(let userID) = target {
            launchPreferences.forgetUser(userID)
        }

        // Reports and consent are server-wide; another user still signed in
        // there keeps theirs.
        var diagnosticsRemoved = true
        for affectedServerID in Set(removedKeys.map(\.serverID) + removedLegacyServers) {
            if await !tokenStore.hasSavedSignIn(onServer: affectedServerID) {
                diagnosticsRemoved = await purgeDiagnostics(affectedServerID) && diagnosticsRemoved
            }
        }
        if affectsCurrent {
            await clearAllCaches()
        }
        await httpClient.endIdentityTransition(lease)
        revoke(removals.compactMap(\.credential))
        guard removals.allSatisfy(\.durable) else { return .localOnly }
        return diagnosticsRemoved ? .completed : .diagnosticsCleanupFailed
    }

    /// Whether `target` includes the selected credential right now.
    private func includesSelection(_ target: SignInRemovalTarget) async -> Bool {
        let selection = await tokenStore.currentSelection()
        switch target {
        case .current:
            return true
        case .signIn(let key):
            return selection == .signIn(key)
        case .user(let userID):
            guard selection != .none else { return false }
            return await tokenStore.currentUserID() == userID
        }
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
        resetIdentityScopedStores(forgetWatchPartyRecent: true, preservingTrailerReturn: false)
    }

    /// A remote-playback handoff changes server/account/profile without
    /// touching the persistent registry. Treat both entry and restoration as
    /// full auth boundaries so cached user data cannot cross identities.
    /// The owner's on-disk snapshots are kept, and while `temporaryIdentityActive`
    /// none are written or read: the persisted profile still names the owner.
    @MainActor
    func clearCachesForTemporaryIdentityChange(temporaryIdentityActive: Bool) {
        StartupContentPrefetcher.resetAllPrefetches()
        ResponseCache.shared.clearMemory()
        ResponseCache.shared.snapshotsSuspended = temporaryIdentityActive
        resetIdentityScopedStores(forgetWatchPartyRecent: true, preservingTrailerReturn: false)
    }

    /// A server switch is the same hard identity boundary as sign-out for
    /// process-wide response and prefetch caches, even when both servers are
    /// already authenticated and the router's auth state does not change.
    @MainActor
    func clearCachesForServerChange() {
        clearAllCaches()
    }
}
