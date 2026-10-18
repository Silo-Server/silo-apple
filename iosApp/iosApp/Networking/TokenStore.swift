import Foundation
import Synchronization

struct RefreshAccountIdentity: Hashable, Sendable {
    let serverId: String
    let serverURL: String
    /// Process-local epoch for the exact credential owner. Persistent epochs
    /// change on login/sign-out/retarget; temporary scopes supply their stable
    /// handoff generation. Guarded refresh rotation preserves the epoch.
    let credentialGenerationID: UUID
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

/// Durable account owner for queued or persisted work. Unlike the request
/// owner it survives access-token rotation and profile switches: it is bound
/// to the verified account id and the account epoch installed by a login.
struct CapturedDurableAccountAuth: Sendable {
    let accountID: String
    let accountEpoch: UUID
    let request: CapturedOrdinaryRequestAuth
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

/// A server session to end after its sign-in was removed or replaced on this
/// device (`HTTPClient.revoke(_:)`). Holds secrets; never logged.
struct RevocableCredential: Equatable, Sendable {
    let serverURL: String
    let accessToken: String
    let refreshToken: String?
}

/// The server account a sign-in response named (`TokenPair.user`). Pairing
/// and device-code sign-ins carry no username until `/api/v2/account/me`.
struct SignInAccount: Equatable, Sendable {
    let id: String
    let username: String?
}

/// Where `TokenStore.installSignIn` puts a new session.
enum SignInPlacement: Equatable, Sendable {
    /// The account is already saved: new tokens and epoch, keeping its user,
    /// `addedAt`, and profile cache.
    case refresh(SignInKey)
    /// A new sign-in in an existing user.
    case join(userID: String)
    /// A new sign-in that creates a new user.
    case newUser
}

struct SignInInstallResult: Equatable, Sendable {
    let key: SignInKey
    let userID: String
    let createdUser: Bool
    /// The refreshed sign-in's previous session, to revoke.
    let superseded: RevocableCredential?
}

enum SignInInstallError: Error, Equatable {
    /// The placement would break an index invariant: an account in two
    /// users, two sign-ins on one server in one user, or a refresh of an
    /// account that isn't saved.
    case invalidPlacement
}

/// Thrown by reads of the user model while `users.v1` has never been
/// written: the device still runs on per-server sessions.
enum SavedSignInAccessError: Error, Equatable {
    case notMigrated
}

struct SignInRemoval: Equatable, Sendable {
    /// Captured before deletion so the session can be revoked. Nil when the
    /// sign-in held no session.
    let credential: RevocableCredential?
    /// The user deleted by this removal because it had nothing left.
    let removedUserID: String?
    /// Whether the sign-in can no longer come back after a relaunch.
    let durable: Bool
}

/// What an account read did to the selected credential.
enum BindOutcome: Equatable, Sendable {
    case unchanged
    case usernameUpdated
    /// A pending legacy server became this saved sign-in (plan §3.3).
    case legacyMigrated(SignInKey)
    /// A pending legacy server's account was already saved in some user; the
    /// legacy session was dropped and nothing is selected.
    case legacyDuplicate(existing: SignInKey)
}

enum LegacyMigrationOutcome: Equatable, Sendable {
    /// `users.v1` already existed.
    case notNeeded
    case migrated
    /// Nothing was written; the next launch tries again.
    case deferred(LegacyMigrationDeferral)
}

enum LegacyMigrationDeferral: String, Equatable, Sendable {
    case indexUnreadable
    case sessionUnreadable
    /// The caller passed no servers, but the stored server list couldn't be
    /// read or still names some.
    case serverListUnreadable
    case writeFailed
}

/// What one server's credentials looked like at one moment: the user index,
/// every saved sign-in on the server (plus one more key, if asked), this
/// Apple TV user's proofs for them, the server's old per-server slot, and
/// the selection. `TokenStore.restore(_:)` puts back exactly that.
struct SignInSnapshot: Equatable, Sendable {
    /// False when a keychain read failed; restoring then fails closed, so
    /// callers refuse before mutating anything.
    let isReadable: Bool
    fileprivate let serverID: String
    fileprivate let index: SiloUserIndex?
    fileprivate let keys: [SignInKey]
    fileprivate let signIns: [SignInKey: SavedSignIn]
    fileprivate let proofs: [SignInKey: SignInProfileProof]
    fileprivate let legacySlot: TokenStore.AccountSessionSnapshot
    fileprivate let selectedServerID: String
    fileprivate let selection: CredentialSelection
    fileprivate let userID: String?
}

/// Actor that owns session credentials.
///
/// Two regimes share one API. Before the user index (`users.v1`) exists,
/// every server has one per-server slot (`AccountSessionPersistence` plus the
/// raw per-token mirrors) and the selection is `.legacy(serverID)`. Once
/// migration writes the index, credentials are saved sign-ins
/// (`SavedSignIn`, one per server account) grouped into Silo users, and the
/// selection names one of them; a per-server slot is read only for a
/// migrated user's pending legacy servers (plan §3.3).
///
/// The active server URL and profile ID live in `SharedDefaults`, with the
/// selected account mirrored to `activeAccountId`. The active access and
/// profile tokens are mirrored to fixed Keychain accounts for the
/// extensions. `HTTPClient` collapses concurrent 401s into one refresh per
/// `RefreshAccountIdentity`.
actor TokenStore {
    static let shared = TokenStore()

    static let accountCredentialAudience: KeychainAudience = .userIndependent
    static let profileCredentialAudience: KeychainAudience = .currentUser

    private let accountKeychain: SharedKeychain
    private let profileKeychain: SharedKeychain
    private let defaults: SharedDefaults
    private let sessions: AccountSessionPersistence
    /// The user index and saved sign-ins. Read-only outside the actor, for
    /// synchronous readers such as `AuthService.isLoggedIn`; every write
    /// goes through this actor.
    nonisolated let savedSignIns: SavedSignInStore
    private let proofs: SignInProofStore
    #if os(iOS)
    private let displayTargets: ApplePushDisplayTargetStore
    #endif
    private var canonicalSession: CanonicalAccountSession?
    /// The selected saved sign-in as last read or written, including an
    /// expired one. Nil for other selections.
    private var cachedSignIn: SavedSignIn?
    /// Credentials that must not be served in this process: a slot that
    /// could not be read, or a rollback that could not be made durable.
    /// Keyed `legacy:<serverID>` or `signIn:<serverID>/<accountID>`.
    private var runtimeBlocked: Set<String> = []

    private let serverUrlDefaultsKey = SharedStorage.serverUrlKey
    private let profileIdDefaultsKey = SharedStorage.profileIdKey

    // MARK: - Keychain key derivation
    //
    // Per-server Keychain account names.
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

    /// Server whose credential is currently selected. Empty string means
    /// "no active server": reads return nil and saves no-op.
    private var activeServerId: String = ""
    /// Which credential on `activeServerId` requests use.
    private var selection: CredentialSelection = .none {
        didSet { selectionSnapshot.withLock { $0 = selection } }
    }
    /// `selection` for synchronous readers (`mirroredSelection`).
    private nonisolated let selectionSnapshot = Mutex<CredentialSelection>(.none)
    /// The Silo user the selection belongs to. Nil before migration and
    /// while no user is chosen.
    private var activeUserID: String?
    /// `SiloUserIndex.legacyDataOwnerByServerID` as last read or written.
    private var legacyDataOwners: [String: String] = [:]
    /// Whether `legacyDataOwners` came from an index read or write in this
    /// process.
    private var hasReadLegacyDataOwners = false

    private var cachedAccessToken: String?
    private var cachedRefreshToken: String?
    private var cachedProfileToken: String?
    /// Process-local identity for the persistent credential currently
    /// selected. Refresh rotation leaves it unchanged; every session
    /// replacement or routing boundary installs a fresh epoch.
    private var persistentCredentialGenerationID = UUID()
    /// Process-local identity for one installation of the persistent profile
    /// ID and proof. Every activation, deactivation, or direct profile write
    /// replaces it, so selecting the same profile again with the same proof
    /// (or with none) is still a new selection.
    private var profileSelectionGeneration = UUID()
    /// Playback-scoped credentials received by a TV through remote handoff.
    /// They are process-only and never written into persistent slots.
    private var temporaryScope: TemporaryAuthScope?
    /// A terminally rejected temporary generation remains installed until
    /// remote-playback teardown, but it must never submit its refresh token
    /// again or emit duplicate expiry notifications.
    private var rejectedTemporaryCredentialGenerations: Set<UUID> = []
    /// Selection the current cache was loaded for. Nil means the cache is
    /// invalid and must be re-read on next access.
    private var loadedSelection: CredentialSelection?

    /// Last values written to the shared-extension keychain slots. Skips
    /// redundant Keychain writes; the access value is re-mirrored after every
    /// refresh.
    private var lastMirroredAccessToken: String?
    private var lastMirroredProfileToken: String?

    init(keychain: SharedKeychain = SharedKeychain(),
         defaults: SharedDefaults = .shared,
         sessionPersistence: AccountSessionPersistence? = nil,
         savedSignIns: SavedSignInStore? = nil,
         signInProofs: SignInProofStore? = nil) {
        self.accountKeychain = keychain.withAudience(Self.accountCredentialAudience)
        self.profileKeychain = keychain.withAudience(Self.profileCredentialAudience)
        self.defaults = defaults
        self.sessions = sessionPersistence ?? AccountSessionPersistence(keychain: keychain)
        self.savedSignIns = savedSignIns ?? SavedSignInStore(keychain: keychain)
        self.proofs = signInProofs ?? SignInProofStore(keychain: keychain)
        #if os(iOS)
        self.displayTargets = ApplePushDisplayTargetStore(keychain: keychain.withAudience(Self.profileCredentialAudience))
        #endif
    }

    /// The `activeAccountId` mirror this store writes: the selected saved
    /// sign-in's account, or nil.
    nonisolated var mirroredAccountID: String? {
        AccountScopeReader.currentAccountID(defaults: defaults)
    }

    /// The selected credential, for synchronous readers such as
    /// `AuthService.isLoggedIn`. `.none` until this process selects one.
    nonisolated var mirroredSelection: CredentialSelection {
        selectionSnapshot.withLock { $0 }
    }

    // MARK: - Diagnostics
    //
    // Session lines are deliberately outcome-only. Everything this actor holds
    // — access/refresh/profile tokens, profile ids, account ids, server ids
    // (base64 of the server URL, so an id *is* the hostname), server URLs — is
    // credential or identifying material and must never reach a log line, not
    // truncated and not hashed. What a report needs to explain "I got logged
    // out" is the sequence of outcomes and a stable classification of each
    // refusal, so that is all these emit: a fixed `phase`, a fixed `outcome`,
    // and a fixed `reason`, every one of them a compile-time literal.

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
        case AccountSessionPersistenceError.unavailable: return "persistenceUnavailable"
        case AccountSessionPersistenceError.invalidRecord: return "invalidSessionRecord"
        case AccountSessionPersistenceError.invalidIdentity: return "invalidSessionIdentity"
        case SavedSignInStoreError.writeFailed: return "persistenceUnavailable"
        case SavedSignInStoreError.corrupt, SavedSignInStoreError.keyMismatch: return "invalidSignInRecord"
        case SavedSignInStoreError.unsupportedVersion: return "unsupportedSignInRecord"
        case SavedSignInAccessError.notMigrated: return "notMigrated"
        case SignInInstallError.invalidPlacement: return "invalidPlacement"
        case HTTPError.requestIdentityChanged: return "identityChanged"
        case is DecodingError: return "invalidSessionRecord"
        case is SharedKeychain.ReadError: return "keychainReadFailed"
        default: return "persistenceUnavailable"
        }
    }

    /// A record whose bytes were read but can't be used: corrupt, from
    /// another format, or naming another key. Unlike a keychain read error,
    /// reading it again won't help, and it authorizes nothing.
    private static func isUnusableRecord(_ error: Error) -> Bool {
        switch error {
        case is DecodingError,
             AccountSessionPersistenceError.invalidRecord,
             SavedSignInStoreError.corrupt,
             SavedSignInStoreError.keyMismatch,
             SavedSignInStoreError.unsupportedVersion:
            return true
        default:
            return false
        }
    }

    // MARK: - Selection

    /// Select the credential requests use: a saved sign-in, a per-server
    /// legacy slot, or none (a chooser or sign-in screen is showing). Mints a
    /// new credential generation, reloads the credential and this Apple TV
    /// user's proof, and writes the `activeAccountId` and Top Shelf mirrors.
    /// A credential for another server than `serverID` selects nothing.
    /// Selecting what is already selected changes nothing.
    func select(serverID: String?, credential: CredentialSelection, userID: String?) {
        applySelection(serverID: serverID, credential: credential, userID: userID)
        ensureLoaded()
        mirrorActiveTokensForExtension()
    }

    /// Whether the selected credential holds an access token. Never changes
    /// the selection.
    func hasUsableCredential() -> Bool {
        ensureLoaded()
        return cachedAccessToken != nil
    }

    func currentSelection() -> CredentialSelection { selection }

    func currentSignInKey() -> SignInKey? {
        guard case .signIn(let key) = selection else { return nil }
        return key
    }

    func currentUserID() -> String? { activeUserID }

    /// The credential the launch rules (spec §6.2) give `serverID` when no
    /// chooser is involved: before migration, the server's own slot;
    /// afterwards the user's sign-in or pending legacy server there. The user
    /// is the selected one, else the one this Apple TV user (or device) is
    /// linked to, else the user migration created when this Apple TV user
    /// used Silo before users existed, else the only user. Background
    /// launches (push, download refresh) use this; foreground launches go
    /// through `SiloUserCoordinator`, which selects explicitly.
    func launchSelection(forServer serverID: String) -> (credential: CredentialSelection, userID: String?) {
        guard !serverID.isEmpty else { return (.none, nil) }
        let index: SiloUserIndex?
        do { index = try loadIndex() } catch {
            // Unreadable index: no writes, and this launch uses the server's
            // own slot as before migration (plan §3.5).
            recordSessionEvent(phase: "selectCredential", outcome: "fallback", reason: Self.persistenceFailureReason(error))
            return (.legacy(serverID: serverID), nil)
        }
        guard let index else { return (.legacy(serverID: serverID), nil) }
        let launch = ProfileLaunchState.load(from: defaults)
        // As in `SiloLaunchResolver`: an active server the registry fell
        // back to (a new Apple TV user's first launch, the survivor of a
        // removal) is not history, so it never opens the migrated user.
        let openedServerBefore = defaults.string(forKey: SharedStorage.activeServerIdKey) != nil
            && !defaults.bool(forKey: ServerRegistry.activeServerFallbackKey)
        let hasLegacyHistory = (launch.lastServerByUserID ?? [:]).isEmpty
            && (!launch.rememberedByServerID.isEmpty || openedServerBefore)
        func user(_ id: String?) -> SiloUser? { id.flatMap { id in index.users.first { $0.id == id } } }
        let chosen = user(activeUserID)
            ?? user(launch.linkedUserID)
            ?? (hasLegacyHistory ? user(index.migratedUserID) : nil)
            ?? (index.users.count == 1 ? index.users.first : nil)
        guard let chosen else { return (.none, nil) }
        return (Self.credential(of: chosen, onServer: serverID), chosen.id)
    }

    /// Point the store at `serverId` with the launch rules' credential there
    /// (`launchSelection(forServer:)`), loading it and refreshing the Top
    /// Shelf mirrors. A no-op when `serverId` is already active, so a choice
    /// made through `select` stands.
    func switchActiveServer(serverId: String) {
        guard serverId != activeServerId else { return }
        let resolved = launchSelection(forServer: serverId)
        select(serverID: serverId, credential: resolved.credential, userID: resolved.userID)
    }

    /// The same choice as `switchActiveServer`, without loading credentials
    /// or touching the Top Shelf mirrors. Used during background launches
    /// before routing settles.
    func retargetActiveServer(serverId: String) {
        guard serverId != activeServerId else { return }
        let resolved = launchSelection(forServer: serverId)
        applySelection(serverID: serverId, credential: resolved.credential, userID: resolved.userID)
    }

    private func applySelection(serverID: String?, credential: CredentialSelection, userID: String?) {
        let serverID = serverID ?? ""
        var credential = credential
        switch credential {
        case .legacy(let owner) where owner != serverID:
            credential = .none
        case .signIn(let key) where key.serverID != serverID:
            credential = .none
        default:
            break
        }
        if serverID.isEmpty { credential = .none }
        defer { writeAccountMirror() }
        guard serverID != activeServerId || credential != selection || userID != activeUserID else { return }
        persistentCredentialGenerationID = UUID()
        activeServerId = serverID
        selection = credential
        activeUserID = userID
        invalidateLoadedCredential()
    }

    /// The current user's credential on `serverID`, without changing the
    /// selection. Before migration every server is its own slot; afterwards
    /// a server outside the current user, or no current user (a chooser is
    /// showing), has none. An unreadable index releases nothing.
    private func storedCredential(forServer serverID: String) -> CredentialSelection {
        guard !serverID.isEmpty else { return .none }
        if serverID == activeServerId { return selection }
        let index: SiloUserIndex?
        do { index = try loadIndex() } catch { return .none }
        guard let index else { return .legacy(serverID: serverID) }
        guard let userID = activeUserID, let user = index.users.first(where: { $0.id == userID }) else {
            return .none
        }
        return Self.credential(of: user, onServer: serverID)
    }

    private static func credential(of user: SiloUser, onServer serverID: String) -> CredentialSelection {
        if let key = user.signIns.first(where: { $0.serverID == serverID }) {
            return .signIn(key)
        }
        if user.pendingLegacyServerIDs?.contains(serverID) == true {
            return .legacy(serverID: serverID)
        }
        return .none
    }

    private static func user(_ user: SiloUser, has serverID: String) -> Bool {
        user.signIns.contains(where: { $0.serverID == serverID })
            || user.pendingLegacyServerIDs?.contains(serverID) == true
    }

    private static func serverID(of selection: CredentialSelection) -> String? {
        switch selection {
        case .none: return nil
        case .legacy(let serverID): return serverID
        case .signIn(let key): return key.serverID
        }
    }

    private static func blockKey(_ selection: CredentialSelection) -> String? {
        switch selection {
        case .none: return nil
        case .legacy(let serverID): return "legacy:\(serverID)"
        case .signIn(let key): return "signIn:\(key.storageKey)"
        }
    }

    private func isBlocked(_ selection: CredentialSelection) -> Bool {
        Self.blockKey(selection).map(runtimeBlocked.contains) ?? false
    }

    private func block(_ selection: CredentialSelection) {
        if let key = Self.blockKey(selection) { runtimeBlocked.insert(key) }
    }

    private func unblock(_ selection: CredentialSelection) {
        if let key = Self.blockKey(selection) { runtimeBlocked.remove(key) }
    }

    private func invalidateLoadedCredential() {
        canonicalSession = nil
        cachedSignIn = nil
        cachedAccessToken = nil
        cachedRefreshToken = nil
        cachedProfileToken = nil
        loadedSelection = nil
    }

    private func writeAccountMirror() {
        if case .signIn(let key) = selection {
            defaults.set(key.accountID, forKey: SharedStorage.activeAccountIdKey)
        } else {
            defaults.removeObject(forKey: SharedStorage.activeAccountIdKey)
        }
    }

    // MARK: - User index

    /// Strict index read. Every successful read republishes the legacy
    /// data owners for synchronous local-data stores.
    private func loadIndex() throws -> SiloUserIndex? {
        let index = try savedSignIns.loadIndex()
        if let index { publishLegacyOwners(index) }
        return index
    }

    /// The commit point of every user-model change (invariant 5).
    private func saveIndex(_ index: SiloUserIndex) throws {
        try savedSignIns.saveIndex(index)
        publishLegacyOwners(index)
    }

    private func publishLegacyOwners(_ index: SiloUserIndex) {
        let owners = index.legacyDataOwnerByServerID ?? [:]
        hasReadLegacyDataOwners = true
        legacyDataOwners = owners
        LegacyLocalDataOwner.publish(owners)
    }

    /// The device's users and a secret-free summary of each readable
    /// sign-in. Throws `SavedSignInAccessError.notMigrated` before migration
    /// and the read error when the index can't be read. A sign-in whose
    /// item is missing, unreadable, or names another user has no summary.
    func directory() throws -> SiloUserDirectorySnapshot {
        guard let index = try loadIndex() else { throw SavedSignInAccessError.notMigrated }
        var summaries: [SignInSummary] = []
        for user in index.users {
            for key in user.signIns {
                guard let signIn = try? savedSignIns.loadSignIn(key), signIn.userID == user.id else { continue }
                summaries.append(SignInSummary(signIn))
            }
        }
        return SiloUserDirectorySnapshot(index: index, signIns: summaries)
    }

    /// The account that took over `serverID`'s state from before sign-ins
    /// existed (`SiloUserIndex.legacyDataOwnerByServerID`). Nil before
    /// migration and for servers no migrated sign-in owns.
    func legacyDataOwner(forServer serverID: String) -> String? {
        if !hasReadLegacyDataOwners {
            // This process may not have read the index yet. Every later
            // read or write of the index republishes the owners.
            _ = try? loadIndex()
        }
        return legacyDataOwners[serverID]
    }

    /// Whether any user has a sign-in, or a pending legacy server, on
    /// `serverID`. False before migration. True when the index can't be
    /// read: callers keep server-wide state (diagnostics) that another
    /// user may still need.
    func hasSavedSignIn(onServer serverID: String) -> Bool {
        let index: SiloUserIndex?
        do { index = try loadIndex() } catch { return true }
        guard let index else { return false }
        return index.users.contains { Self.user($0, has: serverID) }
    }

    // MARK: - Migration (plan §3.2)

    /// Moves today's per-server sessions into one Silo user, once. Verified
    /// sessions become saved sign-ins with the same epoch; unverified ones
    /// stay pending legacy servers in that user until their first account
    /// read. Idempotent: an existing index means done, and only retries the
    /// cleanup of migrated slots. A keychain read error or a failed write
    /// defers without changing anything that is read afterwards.
    func migrateLegacySessionsIfNeeded(
        servers: [(id: String, url: String)],
        activeServerID: String?
    ) -> LegacyMigrationOutcome {
        let existing: SiloUserIndex?
        do { existing = try loadIndex() } catch {
            recordSessionEvent(phase: "signInMigration", outcome: "deferred", reason: "indexUnreadable")
            return .deferred(.indexUnreadable)
        }
        if let existing {
            cleanUpMigratedLegacySlots(existing)
            return .notNeeded
        }

        var verified: [(key: SignInKey, session: CanonicalAccountSession)] = []
        var pending: [String] = []
        var seen: Set<String> = []
        for server in servers where !server.id.isEmpty && seen.insert(server.id).inserted {
            let state: AccountSessionPersistence.State
            do {
                state = try sessions.load(server.id)
            } catch where Self.isUnusableRecord(error) {
                // Today this record blocks its server until the next sign-in,
                // so it is not a working sign-in to carry over.
                continue
            } catch {
                recordSessionEvent(phase: "signInMigration", outcome: "deferred", reason: "sessionUnreadable")
                return .deferred(.sessionUnreadable)
            }
            switch state {
            case .signedOut:
                continue
            case .session(let value):
                if let accountID = value.accountID,
                   let key = SignInKey(serverID: server.id, accountID: accountID),
                   let origin = value.origin,
                   ServerRegistry.normalize(url: origin) == ServerRegistry.normalize(url: server.url) {
                    verified.append((key, value))
                } else {
                    pending.append(server.id)
                }
            case .legacy:
                let access: String?
                do {
                    access = try accountKeychain.getChecked(Self.accessTokenKey(for: server.id))
                } catch {
                    recordSessionEvent(phase: "signInMigration", outcome: "deferred", reason: "sessionUnreadable")
                    return .deferred(.sessionUnreadable)
                }
                if access?.isEmpty == false { pending.append(server.id) }
            }
        }

        guard !verified.isEmpty || !pending.isEmpty else {
            // Saved servers without a sign-in stay in the server list. No
            // servers at all is trusted only when the stored list agrees: a
            // list that failed to load at launch looks empty too, and an
            // index committed then would retire every per-server session for
            // good (invariant 4).
            if servers.isEmpty,
               SharedStorage.storedServerIDs(keychain: accountKeychain, defaults: defaults)?.isEmpty != true {
                recordSessionEvent(phase: "signInMigration", outcome: "deferred", reason: "serverListUnreadable")
                return .deferred(.serverListUnreadable)
            }
            let index = SiloUserIndex()
            do { try saveIndex(index) } catch {
                recordSessionEvent(phase: "signInMigration", outcome: "deferred", reason: "writeFailed")
                return .deferred(.writeFailed)
            }
            reselectRetiredLegacySelection(index)
            recordSessionEvent(phase: "signInMigration", outcome: "migrated", reason: "noSignIns")
            return .migrated
        }

        let now = Date()
        let userID = UUID().uuidString
        var migrated: [SavedSignIn] = []
        for (key, session) in verified {
            // The active server's sign-in is the oldest, so it names the user
            // (spec §9: the order isn't recorded).
            let signIn = SavedSignIn(
                key: key,
                userID: userID,
                origin: ServerRegistry.normalize(url: session.origin ?? ""),
                accessToken: session.accessToken,
                refreshToken: session.refreshToken,
                epoch: session.epoch,
                addedAt: key.serverID == activeServerID ? now.addingTimeInterval(-1) : now,
                adoptsLegacyLocalData: true
            )
            do { try savedSignIns.saveSignIn(signIn) } catch {
                // Items written so far are unreachable without the index and
                // are overwritten by the retry.
                recordSessionEvent(phase: "signInMigration", outcome: "deferred", reason: "writeFailed")
                return .deferred(.writeFailed)
            }
            migrated.append(signIn)
        }
        let ordered = migrated.enumerated()
            .sorted { ($0.element.addedAt, $0.offset) < ($1.element.addedAt, $1.offset) }
            .map(\.element.key)
        let user = SiloUser(
            id: userID,
            createdAt: now,
            signIns: ordered,
            pendingLegacyServerIDs: pending.isEmpty ? nil : pending
        )
        let index = SiloUserIndex(
            users: [user],
            migratedUserID: userID,
            legacyDataOwnerByServerID: verified.isEmpty
                ? nil
                : Dictionary(verified.map { ($0.key.serverID, $0.key.accountID) }, uniquingKeysWith: { first, _ in first })
        )
        do { try saveIndex(index) } catch {
            recordSessionEvent(phase: "signInMigration", outcome: "deferred", reason: "writeFailed")
            return .deferred(.writeFailed)
        }
        cleanUpMigratedLegacySlots(index)
        reselectRetiredLegacySelection(index)
        recordSessionEvent(phase: "signInMigration", outcome: "migrated", reason: "signIns")
        return .migrated
    }

    /// A selection made before migration (a background launch) can still
    /// name a server's own slot that no user lists as pending, which is
    /// never read again once the index exists (invariant 4): a migrated
    /// server's tombstone, or a server that had no working sign-in.
    private func reselectRetiredLegacySelection(_ index: SiloUserIndex) {
        guard case .legacy(let serverID) = selection,
              !index.users.contains(where: { $0.pendingLegacyServerIDs?.contains(serverID) == true }) else { return }
        let resolved = launchSelection(forServer: activeServerId)
        select(serverID: activeServerId, credential: resolved.credential, userID: resolved.userID)
    }

    /// Step 6 of plan §3.2, retried on every migration call. Once the index
    /// exists these slots are never read (invariant 4), so failures are
    /// harmless; this only keeps stale tokens from lingering. This Apple TV
    /// user's `<serverID>.profileToken` stays for proof adoption.
    private func cleanUpMigratedLegacySlots(_ index: SiloUserIndex) {
        let pending = Set(index.users.flatMap { $0.pendingLegacyServerIDs ?? [] })
        for serverID in (index.legacyDataOwnerByServerID ?? [:]).keys where !pending.contains(serverID) {
            let needsTombstone: Bool
            switch try? sessions.load(serverID) {
            case .signedOut?: needsTombstone = false
            default: needsTombstone = true
            }
            if needsTombstone { _ = sessions.invalidate(serverID) }
            let hasRawSlot = (try? accountKeychain.getChecked(Self.accessTokenKey(for: serverID))) != nil
                || (try? accountKeychain.getChecked(Self.refreshTokenKey(for: serverID))) != nil
            if needsTombstone || hasRawSlot {
                deleteRawSlots(serverID)
            }
        }
    }

    private func deleteRawSlots(_ serverID: String) {
        accountKeychain.delete(Self.accessTokenKey(for: serverID))
        accountKeychain.delete(Self.refreshTokenKey(for: serverID))
        accountKeychain.delete(Self.accountEpochKey(for: serverID))
    }

    // MARK: - Active server

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

    /// One shared binding for future queued authenticated operations. Unverified
    /// legacy sessions and temporary playback credentials cannot acquire it.
    func captureDurableAccountAuth() -> CapturedDurableAccountAuth? {
        guard temporaryScope == nil, let request = captureOrdinaryRequestAuth(),
              !isBlocked(selection), let access = request.accessToken else { return nil }
        switch selection {
        case .none:
            return nil
        case .signIn(let key):
            guard let signIn = cachedSignIn, let epoch = signIn.epoch,
                  ServerRegistry.normalize(url: signIn.origin) == request.account.serverURL,
                  signIn.accessToken == access else { return nil }
            return CapturedDurableAccountAuth(accountID: key.accountID, accountEpoch: epoch, request: request)
        case .legacy:
            guard let session = canonicalSession, let accountID = session.accountID, let epoch = session.epoch,
                  session.origin == request.account.serverURL, session.accessToken == access else { return nil }
            return CapturedDurableAccountAuth(accountID: accountID, accountEpoch: epoch, request: request)
        }
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
        // Profile IDs repeat across accounts on one server, so a write queued
        // for one account must not go out under another's matching profile.
        if let expectedAccountID = expected.accountID {
            let currentAccountID = temporaryScope == nil ? currentSignInKey()?.accountID : nil
            guard currentAccountID == expectedAccountID else {
                recordSessionEvent(phase: "captureRequestAuth", outcome: "failed", reason: "accountChanged")
                throw HTTPError.requestIdentityChanged
            }
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
        if let expectedAccountID = expected.accountID,
           currentSignInKey()?.accountID != expectedAccountID {
            return false
        }
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
    /// The credential generation changes on every selection, so a rotation
    /// for one sign-in can never land on another sign-in of the same server.
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
            switch selection {
            case .none:
                return false
            case .signIn(let key):
                return saveRefreshedSignIn(key, accessValue: accessValue, refreshValue: value)
            case .legacy(let serverID):
                return saveRefreshedLegacySession(serverID, accessValue: accessValue, refreshValue: value,
                                                  capturedURL: captured.account.serverURL)
            }
        }
    }

    /// Rotates the selected sign-in's tokens, keeping its epoch, after
    /// checking the stored item is still the one this process loaded. No
    /// per-server mirrors: Top Shelf reads the sign-in itself.
    private func saveRefreshedSignIn(_ key: SignInKey, accessValue: String, refreshValue: String) -> Bool {
        guard let original = cachedSignIn else {
            recordSessionEvent(phase: "tokenRefresh", outcome: "discarded", reason: "savedSignInMismatch")
            return false
        }
        let stored: SavedSignIn?
        do { stored = try savedSignIns.loadSignIn(key) } catch {
            recordSessionEvent(phase: "tokenRefresh", outcome: "discarded", reason: Self.persistenceFailureReason(error))
            return false
        }
        guard stored == original else {
            recordSessionEvent(phase: "tokenRefresh", outcome: "discarded", reason: "savedSignInMismatch")
            return false
        }
        var rotated = original
        rotated.accessToken = accessValue
        rotated.refreshToken = refreshValue
        do { try savedSignIns.saveSignIn(rotated) } catch {
            recordSessionEvent(phase: "tokenRefresh", outcome: "failed", reason: Self.persistenceFailureReason(error))
            blockRuntimeSession()
            return false
        }
        cachedSignIn = rotated
        cachedAccessToken = accessValue
        cachedRefreshToken = refreshValue
        recordSessionEvent(phase: "tokenRefresh", outcome: "succeeded", reason: "savedSignIn")
        // Account refresh must not re-mirror a stale profile credential
        // during an in-progress profile transition.
        mirrorActiveAccessValueForExtension()
        return true
    }

    private func saveRefreshedLegacySession(
        _ serverId: String,
        accessValue: String,
        refreshValue value: String,
        capturedURL: String
    ) -> Bool {
        if let original = canonicalSession {
            let stored: AccountSessionPersistence.State
            do { stored = try sessions.load(serverId) }
            catch {
                recordSessionEvent(
                    phase: "tokenRefresh",
                    outcome: "discarded",
                    reason: Self.persistenceFailureReason(error)
                )
                return false
            }
            guard case .session(let current) = stored, current == original else {
                recordSessionEvent(
                    phase: "tokenRefresh",
                    outcome: "discarded",
                    reason: "canonicalSessionMismatch"
                )
                return false
            }
        }
        let rotated = CanonicalAccountSession(version: 1, signedOut: false,
            origin: canonicalSession?.origin ?? capturedURL,
            accountID: canonicalSession?.accountID,
            epoch: canonicalSession?.epoch
                ?? accountKeychain.get(Self.accountEpochKey(for: serverId)).flatMap(UUID.init(uuidString:))
                ?? UUID(),
            accessToken: accessValue, refreshToken: value)
        do { try sessions.save(rotated, serverID: serverId) }
        catch {
            recordSessionEvent(
                phase: "tokenRefresh",
                outcome: "failed",
                reason: Self.persistenceFailureReason(error)
            )
            blockRuntimeSession()
            return false
        }
        canonicalSession = rotated
        mirrorCanonicalSession(rotated, serverID: serverId)
        cachedAccessToken = accessValue
        cachedRefreshToken = value
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

            // The durable step is written first. If it cannot be persisted,
            // the stored record still holds the rejected tokens and would
            // restore them on the next launch, so nothing local is cleared
            // and no expiry is reported: the caller sees the same outcome as
            // any other skipped invalidation and the next 401 retries the
            // whole sequence.
            switch selection {
            case .none:
                return nil
            case .signIn(let key):
                // The sign-in stays in its user, expired, so it can show
                // "Sign in again" (plan §2.4).
                guard var expired = cachedSignIn else { return nil }
                expired.accessToken = nil
                expired.refreshToken = nil
                expired.epoch = nil
                do { try savedSignIns.saveSignIn(expired) } catch {
                    recordSessionEvent(
                        phase: "sessionInvalidation",
                        outcome: "failed",
                        reason: "persistenceUnavailable"
                    )
                    return nil
                }
                cachedSignIn = expired
                removeProofs(for: key)
            case .legacy:
                guard sessions.invalidate(serverId) else {
                    recordSessionEvent(
                        phase: "sessionInvalidation",
                        outcome: "failed",
                        reason: "persistenceUnavailable"
                    )
                    return nil
                }
                block(selection)
                canonicalSession = nil
                deleteRawSlots(serverId)
                profileKeychain.delete(Self.profileTokenKey(for: serverId))
            }
            recordSessionEvent(
                phase: "sessionInvalidation",
                outcome: "cleared",
                reason: "refreshRejected"
            )
            cachedAccessToken = nil
            cachedRefreshToken = nil
            cachedProfileToken = nil
            defaults.removeObject(forKey: profileIdDefaultsKey)
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
    /// active server: the current user's credential on that server. Used by
    /// companion pairing to approve a device on a server other than the one
    /// currently active.
    func getAccessToken(for serverId: String) -> String? {
        guard !serverId.isEmpty else { return nil }
        if serverId == activeServerId {
            ensureLoaded()
            if let canonicalSession, !Self.session(canonicalSession, belongsTo: serverId) { return nil }
            if let cachedSignIn, !Self.signIn(cachedSignIn, belongsTo: serverId) { return nil }
            return cachedAccessToken
        }
        switch storedCredential(forServer: serverId) {
        case .none:
            return nil
        case .signIn(let key):
            return storedSignIn(key, servingServer: serverId)?.accessToken
        case .legacy:
            guard !isBlocked(.legacy(serverID: serverId)) else { return nil }
            do {
                switch try sessions.load(serverId) {
                case .session(let value): return Self.session(value, belongsTo: serverId) ? value.accessToken : nil
                case .signedOut: return nil
                case .legacy: return accountKeychain.get(Self.accessTokenKey(for: serverId))
                }
            } catch {
                recordSessionEvent(
                    phase: "sessionLoad",
                    outcome: "failed",
                    reason: Self.persistenceFailureReason(error)
                )
                return nil
            }
        }
    }

    /// A saved server's stored session when that server is NOT the active
    /// one: what an approving phone needs to renew the bearer of a server it
    /// is not currently using. It is the current user's sign-in there, in the
    /// record shape the renewal compares against. Nil for the active server
    /// (its credentials rotate through `HTTPClient`'s single refresh flight),
    /// a blocked slot, a signed-out or expired one, or a legacy record
    /// without a canonical session.
    func inactiveServerSession(for serverId: String) -> CanonicalAccountSession? {
        guard !serverId.isEmpty, serverId != activeServerId, temporaryScope?.serverId != serverId else { return nil }
        switch storedCredential(forServer: serverId) {
        case .none:
            return nil
        case .signIn(let key):
            guard let signIn = storedSignIn(key, servingServer: serverId) else { return nil }
            return CanonicalAccountSession(version: 1, signedOut: false, origin: signIn.origin,
                accountID: key.accountID, epoch: signIn.epoch,
                accessToken: signIn.accessToken, refreshToken: signIn.refreshToken)
        case .legacy:
            guard !isBlocked(.legacy(serverID: serverId)),
                  case .session(let value)? = try? sessions.load(serverId), !value.signedOut,
                  Self.session(value, belongsTo: serverId),
                  value.accessToken?.isEmpty == false, value.refreshToken?.isEmpty == false else { return nil }
            return value
        }
    }

    /// A saved sign-in that may hand its bearer to `serverId`: signed in,
    /// not blocked, in the current user, and bound to the address the
    /// server's ID names.
    private func storedSignIn(_ key: SignInKey, servingServer serverId: String) -> SavedSignIn? {
        guard !isBlocked(.signIn(key)),
              let signIn = try? savedSignIns.loadSignIn(key),
              signIn.isSignedIn, signIn.userID == activeUserID,
              Self.signIn(signIn, belongsTo: serverId) else { return nil }
        return signIn
    }

    #if os(iOS)
    /// The verified account and sign-in epoch of the session stored for a
    /// saved server, active or not: the current user's sign-in there. Nil for
    /// a signed-out, blocked, legacy, or temporary slot, which cannot keep a
    /// push registration current.
    func savedSessionAccount(for serverId: String) -> (accountID: String, epoch: UUID)? {
        guard !serverId.isEmpty, temporaryScope?.serverId != serverId else { return nil }
        if serverId == activeServerId {
            guard !isBlocked(selection) else { return nil }
            ensureLoaded()
            switch selection {
            case .none:
                return nil
            case .signIn(let key):
                guard let signIn = cachedSignIn, signIn.isSignedIn, Self.signIn(signIn, belongsTo: serverId),
                      let epoch = signIn.epoch else { return nil }
                return (key.accountID, epoch)
            case .legacy:
                guard let session = canonicalSession, !session.signedOut, Self.session(session, belongsTo: serverId),
                      let accountID = session.accountID, let epoch = session.epoch else { return nil }
                return (accountID, epoch)
            }
        }
        switch storedCredential(forServer: serverId) {
        case .none:
            return nil
        case .signIn(let key):
            guard let signIn = storedSignIn(key, servingServer: serverId), let epoch = signIn.epoch else { return nil }
            return (key.accountID, epoch)
        case .legacy:
            guard !isBlocked(.legacy(serverID: serverId)),
                  case .session(let session)? = try? sessions.load(serverId), !session.signedOut,
                  Self.session(session, belongsTo: serverId),
                  let accountID = session.accountID, let epoch = session.epoch else { return nil }
            return (accountID, epoch)
        }
    }

    /// The profile verification proof stored for a saved server. The active
    /// server's counts only while `profileID` is its selected profile; an
    /// inactive server keeps the proof of the profile it last used.
    func savedProfileToken(for serverId: String, profileID: String) -> String? {
        guard temporaryScope == nil else { return nil }
        if serverId == activeServerId {
            guard defaults.string(forKey: profileIdDefaultsKey) == profileID else { return nil }
            ensureLoaded()
            return cachedProfileToken
        }
        switch storedCredential(forServer: serverId) {
        case .none:
            return nil
        case .signIn(let key):
            guard let proof = try? proofs.load(key), proof.profileID == nil || proof.profileID == profileID else {
                return nil
            }
            return proof.token
        case .legacy:
            return profileKeychain.get(Self.profileTokenKey(for: serverId))
        }
    }

    /// Runs a local push-registration write only while `owner`'s account
    /// still holds the stored session of `owner.serverID`, whether or not
    /// that server is active. Throws `HTTPError.authorityChanged` after a
    /// sign-out, a sign-in to another account, or a new sign-in epoch.
    func withSavedServerAuthority(_ owner: ApplePushIntentOwner,
                                  operation: @Sendable () throws -> Void) throws {
        try Task.checkCancellation()
        guard let current = savedSessionAccount(for: owner.serverID), current.accountID == owner.accountID,
              current.epoch == owner.accountEpoch else {
            throw HTTPError.authorityChanged
        }
        try operation()
    }
    #endif

    /// Whether a stored session is bound to the address its slot is keyed
    /// by. A registry id is derived from the saved server's URL
    /// (`ServerRegistry.serverId(for:)`), so the id itself names the one
    /// origin a bearer read for another device may send the session to. A
    /// record bound elsewhere, or an id that names no URL, releases nothing.
    static func session(_ value: CanonicalAccountSession, belongsTo serverId: String) -> Bool {
        guard let address = ServerRegistry.url(forServerId: serverId), let origin = value.origin else { return false }
        return ServerRegistry.normalize(url: origin) == address
    }

    /// The same origin binding for a saved sign-in.
    static func signIn(_ value: SavedSignIn, belongsTo serverId: String) -> Bool {
        guard let address = ServerRegistry.url(forServerId: serverId) else { return false }
        return ServerRegistry.normalize(url: value.origin) == address
    }

    /// Store a rotated token pair for an inactive server, but only when that
    /// slot still holds exactly the session the refresh was sent with. A slot
    /// that became active, was signed out, or rotated meanwhile keeps what it
    /// has; the caller then reports the approval as needing a fresh sign-in
    /// rather than writing over newer credentials.
    func saveInactiveServerRefresh(
        accessToken: String,
        refreshToken: String,
        replacing captured: CanonicalAccountSession,
        for serverId: String
    ) -> Bool {
        guard !accessToken.isEmpty, !refreshToken.isEmpty,
              inactiveServerSession(for: serverId) == captured else {
            recordSessionEvent(phase: "tokenRefresh", outcome: "discarded", reason: "inactiveSlotChanged")
            return false
        }
        switch storedCredential(forServer: serverId) {
        case .none:
            return false
        case .signIn(let key):
            guard var signIn = try? savedSignIns.loadSignIn(key) else { return false }
            signIn.accessToken = accessToken
            signIn.refreshToken = refreshToken
            do { try savedSignIns.saveSignIn(signIn) } catch {
                recordSessionEvent(phase: "tokenRefresh", outcome: "failed", reason: Self.persistenceFailureReason(error))
                return false
            }
        case .legacy:
            let rotated = CanonicalAccountSession(version: 1, signedOut: false, origin: captured.origin,
                accountID: captured.accountID, epoch: captured.epoch, accessToken: accessToken, refreshToken: refreshToken)
            do { try sessions.save(rotated, serverID: serverId) } catch {
                recordSessionEvent(phase: "tokenRefresh", outcome: "failed", reason: Self.persistenceFailureReason(error))
                return false
            }
        }
        recordSessionEvent(phase: "tokenRefresh", outcome: "succeeded", reason: "inactiveServer")
        return true
    }

    /// Compatibility entry point for unverified sessions; it creates no verified
    /// durable account binding. Before migration only: it writes the active
    /// server's per-server slot (`installAccountSession`).
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

    /// Install a session into the active server's per-server slot. Before
    /// migration only (the device has no user index yet): afterwards every
    /// sign-in goes through `installSignIn`, and this throws.
    func installAccountSession(accessToken: String, refreshToken: String, accountID: String?, clearProfile: Bool = true, expectedAccount: RefreshAccountIdentity? = nil) throws {
        if let expectedAccount, refreshAccountIdentity() != expectedAccount { throw HTTPError.requestIdentityChanged }
        let serverID = activeServerId
        let value: CanonicalAccountSession
        do {
            guard temporaryScope == nil, !serverID.isEmpty, !accessToken.isEmpty, !refreshToken.isEmpty,
                  accountID == nil || accountID?.isEmpty == false else { throw AccountSessionPersistenceError.invalidIdentity }
            let index: SiloUserIndex?
            do { index = try loadIndex() } catch { throw AccountSessionPersistenceError.unavailable }
            guard index == nil else { throw AccountSessionPersistenceError.invalidIdentity }
            let origin = ServerRegistry.normalize(url: defaults.string(forKey: serverUrlDefaultsKey) ?? "")
            guard !origin.isEmpty else { throw AccountSessionPersistenceError.invalidIdentity }
            value = CanonicalAccountSession(version: 1, signedOut: false, origin: origin, accountID: accountID,
                epoch: UUID(), accessToken: accessToken, refreshToken: refreshToken)
            do { try sessions.save(value, serverID: serverID) }
            catch { blockRuntimeSession(); throw error }
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
        let legacy = CredentialSelection.legacy(serverID: serverID)
        unblock(legacy)
        if clearProfile {
            defaults.removeObject(forKey: profileIdDefaultsKey)
            profileKeychain.delete(Self.profileTokenKey(for: serverID))
            cachedProfileToken = nil
        } else {
            // The install marks the cache loaded below, so the profile proof
            // must reflect the Keychain now: a blocked or never-loaded slot
            // would otherwise hide a stored proof until the next switch.
            cachedProfileToken = profileKeychain.get(Self.profileTokenKey(for: serverID))
        }
        persistentCredentialGenerationID = UUID()
        selection = legacy
        activeUserID = nil
        canonicalSession = value
        cachedSignIn = nil
        cachedAccessToken = accessToken
        cachedRefreshToken = refreshToken
        loadedSelection = selection
        writeAccountMirror()
        mirrorCanonicalSession(value, serverID: serverID)
        mirrorActiveTokensForExtension()
    }

    // MARK: - Saved sign-ins

    /// Add or refresh a sign-in on the active server and select it (plan
    /// §2.5). The key is the active server plus `account.id`; `placement`
    /// decides where it goes. It never touches other sign-ins on the server.
    /// Every install mints a new epoch and deletes this Apple TV user's
    /// proof for the key, so a refresh asks everyone to pick a profile again.
    ///
    /// The item is written first and the index second (invariant 5). Throws
    /// `HTTPError.requestIdentityChanged` when `expected` is no longer the
    /// active account identity, `AccountSessionPersistenceError` for an
    /// invalid account or a temporary scope (`.invalidIdentity`) and for a
    /// keychain failure (`.unavailable`), `SignInInstallError.invalidPlacement`,
    /// and `SavedSignInAccessError.notMigrated` before migration.
    @discardableResult
    func installSignIn(
        accessToken: String,
        refreshToken: String,
        account: SignInAccount,
        origin: String,
        placement: SignInPlacement,
        expected: RefreshAccountIdentity
    ) throws -> SignInInstallResult {
        do {
            return try commitSignIn(accessToken: accessToken, refreshToken: refreshToken, account: account,
                                    origin: origin, placement: placement, expected: expected)
        } catch {
            recordSessionEvent(phase: "sessionInstall", outcome: "failed", reason: Self.persistenceFailureReason(error))
            throw error
        }
    }

    private func commitSignIn(
        accessToken: String,
        refreshToken: String,
        account: SignInAccount,
        origin: String,
        placement: SignInPlacement,
        expected: RefreshAccountIdentity
    ) throws -> SignInInstallResult {
        guard temporaryScope == nil else { throw AccountSessionPersistenceError.invalidIdentity }
        guard refreshAccountIdentity() == expected else { throw HTTPError.requestIdentityChanged }
        let origin = ServerRegistry.normalize(url: origin)
        guard !accessToken.isEmpty, !refreshToken.isEmpty, origin == expected.serverURL,
              let key = SignInKey(serverID: expected.serverId, accountID: account.id) else {
            throw AccountSessionPersistenceError.invalidIdentity
        }
        let loadedIndex: SiloUserIndex?
        do { loadedIndex = try loadIndex() } catch { throw AccountSessionPersistenceError.unavailable }
        guard var index = loadedIndex else { throw SavedSignInAccessError.notMigrated }

        let owner = index.users.firstIndex { $0.signIns.contains(key) }
        let userID: String
        var existing: SavedSignIn?
        var createsUser = false
        switch placement {
        case .refresh(let target):
            guard target == key, let owner else { throw SignInInstallError.invalidPlacement }
            userID = index.users[owner].id
            do {
                existing = try savedSignIns.loadSignIn(key)
            } catch where Self.isUnusableRecord(error) {
                existing = nil
            } catch {
                throw AccountSessionPersistenceError.unavailable
            }
            if existing?.userID != userID { existing = nil }
        case .join(let target):
            guard owner == nil, let member = index.users.firstIndex(where: { $0.id == target }),
                  !Self.user(index.users[member], has: key.serverID) else {
                throw SignInInstallError.invalidPlacement
            }
            userID = target
        case .newUser:
            guard owner == nil else { throw SignInInstallError.invalidPlacement }
            userID = UUID().uuidString
            createsUser = true
        }

        let now = Date()
        let signIn = SavedSignIn(
            key: key,
            userID: userID,
            origin: origin,
            username: account.username ?? existing?.username,
            accessToken: accessToken,
            refreshToken: refreshToken,
            epoch: UUID(),
            addedAt: existing?.addedAt ?? now,
            profiles: existing?.profiles ?? [],
            adoptsLegacyLocalData: existing?.adoptsLegacyLocalData
        )
        do { try savedSignIns.saveSignIn(signIn) } catch { throw AccountSessionPersistenceError.unavailable }
        switch placement {
        case .refresh:
            break
        case .join:
            if let member = index.users.firstIndex(where: { $0.id == userID }) {
                index.users[member].signIns.append(key)
            }
        case .newUser:
            index.users.append(SiloUser(id: userID, createdAt: now, signIns: [key]))
        }
        if placement != .refresh(key) {
            // The item written above is unreachable until this commit; a
            // retry overwrites it.
            do { try saveIndex(index) } catch { throw AccountSessionPersistenceError.unavailable }
        }

        let superseded = existing.flatMap(Self.revocableCredential(of:))
            .flatMap { $0.accessToken == accessToken ? nil : $0 }
        removeProofs(for: key)
        unblock(.signIn(key))
        persistentCredentialGenerationID = UUID()
        selection = .signIn(key)
        activeUserID = userID
        canonicalSession = nil
        cachedSignIn = signIn
        cachedAccessToken = accessToken
        cachedRefreshToken = refreshToken
        cachedProfileToken = nil
        loadedSelection = selection
        defaults.removeObject(forKey: profileIdDefaultsKey)
        profileSelectionGeneration = UUID()
        writeAccountMirror()
        mirrorActiveTokensForExtension()
        recordSessionEvent(phase: "sessionInstall", outcome: "succeeded", reason: "savedSignIn")
        return SignInInstallResult(key: key, userID: userID, createdUser: createsUser, superseded: superseded)
    }

    private static func revocableCredential(of signIn: SavedSignIn) -> RevocableCredential? {
        guard let access = signIn.accessToken, !access.isEmpty else { return nil }
        return RevocableCredential(serverURL: ServerRegistry.normalize(url: signIn.origin),
                                   accessToken: access, refreshToken: signIn.refreshToken)
    }

    /// The session a sign-in holds, for revoking it. The selected sign-in
    /// answers from memory; any other from its saved item.
    func revocableCredential(for key: SignInKey) -> RevocableCredential? {
        if selection == .signIn(key) {
            ensureLoaded()
            if let access = cachedAccessToken, let signIn = cachedSignIn {
                return RevocableCredential(serverURL: ServerRegistry.normalize(url: signIn.origin),
                                           accessToken: access, refreshToken: cachedRefreshToken)
            }
        }
        guard let signIn = try? savedSignIns.loadSignIn(key) else { return nil }
        return Self.revocableCredential(of: signIn)
    }

    /// The session a server's per-server slot holds, for revoking it. A slot
    /// from before canonical records names no origin, so it goes to the
    /// address its server ID names, never to the active-URL mirror: removing
    /// the active server points that mirror at the fallback server first.
    private func legacyRevocableCredential(serverID: String) -> RevocableCredential? {
        if selection == .legacy(serverID: serverID) {
            ensureLoaded()
            let url = canonicalSession?.origin.map { ServerRegistry.normalize(url: $0) }
                ?? ServerRegistry.url(forServerId: serverID)
            if let access = cachedAccessToken, !access.isEmpty, let url, !url.isEmpty {
                return RevocableCredential(serverURL: url, accessToken: access, refreshToken: cachedRefreshToken)
            }
        }
        switch try? sessions.load(serverID) {
        case .session(let value)?:
            guard let origin = value.origin, let access = value.accessToken, !access.isEmpty else { return nil }
            return RevocableCredential(serverURL: ServerRegistry.normalize(url: origin),
                                       accessToken: access, refreshToken: value.refreshToken)
        case .legacy?:
            guard let url = ServerRegistry.url(forServerId: serverID),
                  let access = accountKeychain.get(Self.accessTokenKey(for: serverID)), !access.isEmpty else { return nil }
            return RevocableCredential(serverURL: url, accessToken: access,
                                       refreshToken: accountKeychain.get(Self.refreshTokenKey(for: serverID)))
        case .signedOut?, nil:
            return nil
        }
    }

    /// Captures one server's credentials for `restore(_:)`: the index, every
    /// saved sign-in on `serverID` plus `key`, this Apple TV user's proofs
    /// for them, the server's per-server slot, and the selection. A corrupt
    /// item counts as absent; a keychain read error makes the snapshot
    /// unreadable.
    func signInSnapshot(for key: SignInKey?, serverID: String) -> SignInSnapshot {
        var readable = !serverID.isEmpty
        var index: SiloUserIndex?
        do { index = try loadIndex() } catch { readable = false }
        var keys: [SignInKey] = key.map { [$0] } ?? []
        for user in index?.users ?? [] {
            for member in user.signIns where member.serverID == serverID && !keys.contains(member) {
                keys.append(member)
            }
        }
        var items: [SignInKey: SavedSignIn] = [:]
        var proofsByKey: [SignInKey: SignInProfileProof] = [:]
        for member in keys {
            do {
                items[member] = try savedSignIns.loadSignIn(member)
            } catch where Self.isUnusableRecord(error) {
                // Nothing usable to put back.
            } catch {
                readable = false
            }
            do {
                proofsByKey[member] = try proofs.load(member)
            } catch where Self.isUnusableRecord(error) {
            } catch {
                readable = false
            }
        }
        let legacySlot = accountSessionSnapshot(for: serverID)
        if legacySlot == .unreadable { readable = false }
        return SignInSnapshot(
            isReadable: readable,
            serverID: serverID,
            index: index,
            keys: keys,
            signIns: items,
            proofs: proofsByKey,
            legacySlot: legacySlot,
            selectedServerID: activeServerId,
            selection: selection,
            userID: activeUserID
        )
    }

    /// Puts back exactly what `snapshot` captured: saved items first, then
    /// the index (the commit point), then deletes items added since
    /// (invariant 5), then the selection. When the server's credentials
    /// can't be made durable, or the snapshot was unreadable, they are
    /// blocked for this process and this returns false. A selection on
    /// another server was never touched, so its block state stays.
    @discardableResult
    func restore(_ snapshot: SignInSnapshot) -> Bool {
        var durable = snapshot.isReadable
        if snapshot.isReadable {
            if accountSessionSnapshot(for: snapshot.serverID) != snapshot.legacySlot {
                durable = restoreAccountSession(snapshot.legacySlot, for: snapshot.serverID) && durable
            }
            for key in snapshot.keys {
                if let signIn = snapshot.signIns[key], (try? savedSignIns.loadSignIn(key)) != signIn {
                    do { try savedSignIns.saveSignIn(signIn) } catch { durable = false }
                }
                if let proof = snapshot.proofs[key] {
                    durable = proofs.save(proof, for: key) && durable
                } else {
                    proofs.remove(key)
                }
            }
            do {
                // Nothing deletes `users.v1` (invariant 4), so a snapshot taken
                // before migration leaves a later index in place.
                if let index = snapshot.index, try loadIndex() != index {
                    try saveIndex(index)
                }
            } catch {
                durable = false
            }
            for key in snapshot.keys where snapshot.signIns[key] == nil {
                if (try? savedSignIns.loadSignIn(key)) != nil {
                    durable = savedSignIns.removeSignIn(key) && durable
                }
            }
        }
        persistentCredentialGenerationID = UUID()
        activeServerId = snapshot.selectedServerID
        selection = snapshot.selection
        activeUserID = snapshot.userID
        invalidateLoadedCredential()
        for key in snapshot.keys {
            if durable { unblock(.signIn(key)) } else { block(.signIn(key)) }
        }
        if Self.serverID(of: selection) == snapshot.serverID {
            if durable { unblock(selection) } else { block(selection) }
        }
        if !durable {
            recordSessionEvent(phase: "sessionRestore", outcome: "failed", reason: "persistenceUnavailable")
        }
        ensureLoaded()
        writeAccountMirror()
        mirrorActiveTokensForExtension()
        return durable
    }

    // MARK: - Removal

    /// Sign out of the selected credential: its saved sign-in, its pending
    /// legacy server, or (before migration) the server's slot. The session
    /// is captured first so the caller can revoke it once local state is
    /// gone. Refuses while a temporary scope owns requests.
    @discardableResult
    func removeCurrentCredential() -> SignInRemoval {
        guard temporaryScope == nil else {
            return SignInRemoval(credential: nil, removedUserID: nil, durable: false)
        }
        switch selection {
        case .signIn(let key):
            return removeCredentials(keys: [key], legacyServerIDs: [], userID: nil, phase: "clearTokens")[0]
        case .legacy(let serverID):
            return removeCredentials(keys: [], legacyServerIDs: [serverID], userID: nil, phase: "clearTokens")[0]
        case .none:
            persistentCredentialGenerationID = UUID()
            invalidateLoadedCredential()
            loadedSelection = selection
            defaults.removeObject(forKey: profileIdDefaultsKey)
            clearMirroredTokensForExtension()
            if !activeServerId.isEmpty { removeDisplayTargets(registeredBy: activeServerId) }
            recordSessionEvent(phase: "clearTokens", outcome: "cleared", reason: "noCredential")
            return SignInRemoval(credential: nil, removedUserID: nil, durable: true)
        }
    }

    /// Sign out of the selected credential (`removeCurrentCredential`), or
    /// end a temporary scope. Returns whether the sign-out is durable.
    @discardableResult
    func clearTokens() -> Bool {
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
            return true
        }
        return removeCurrentCredential().durable
    }

    /// Remove one sign-in: the index first (dropping its user when nothing
    /// is left), then the item and this Apple TV user's proof. Other Apple
    /// TV users' proofs stay; they stop working with the revoked session.
    @discardableResult
    func removeSignIn(_ key: SignInKey) -> SignInRemoval {
        removeCredentials(keys: [key], legacyServerIDs: [], userID: nil, phase: "signInRemoval")[0]
    }

    /// Remove every sign-in and pending legacy server in a user, and the
    /// user, in one index write.
    @discardableResult
    func removeUser(_ userID: String) -> [SignInRemoval] {
        let index: SiloUserIndex?
        do { index = try loadIndex() } catch {
            return [SignInRemoval(credential: nil, removedUserID: nil, durable: false)]
        }
        guard let user = index?.users.first(where: { $0.id == userID }) else { return [] }
        return removeCredentials(keys: user.signIns, legacyServerIDs: user.pendingLegacyServerIDs ?? [],
                                 userID: userID, phase: "signInRemoval")
    }

    /// Remove everything saved for a server: every user's sign-in on it, its
    /// per-server slot (tombstoned), and its push display targets. When the
    /// index can't be read, its sign-ins can't be found, so nothing is
    /// removed and the result is not durable.
    @discardableResult
    func removeServer(_ serverID: String) -> [SignInRemoval] {
        guard !serverID.isEmpty else { return [] }
        let index: SiloUserIndex?
        do { index = try loadIndex() } catch {
            recordSessionEvent(phase: "deleteTokens", outcome: "failed", reason: Self.persistenceFailureReason(error))
            return [SignInRemoval(credential: nil, removedUserID: nil, durable: false)]
        }
        let keys = (index?.users ?? []).flatMap { $0.signIns.filter { $0.serverID == serverID } }
        let removals = removeCredentials(keys: keys, legacyServerIDs: [serverID], userID: nil, phase: "deleteTokens")
        removeDisplayTargets(registeredBy: serverID)
        return removals
    }

    /// Remove a server's per-server slot: tombstone it and drop it from every
    /// user's pending legacy servers. Before migration this is the server's
    /// only sign-in.
    @discardableResult
    func removeLegacyServer(_ serverID: String) -> SignInRemoval {
        removeCredentials(keys: [], legacyServerIDs: [serverID], userID: nil, phase: "signInRemoval")[0]
    }

    /// One removal: credentials captured first, then the index (commit
    /// point), then items, proofs, and per-server slots. Returns one result
    /// per key, then one per legacy server.
    private func removeCredentials(
        keys: [SignInKey],
        legacyServerIDs: [String],
        userID dropUserID: String?,
        phase: String
    ) -> [SignInRemoval] {
        let index: SiloUserIndex?
        var indexReadable = true
        do { index = try loadIndex() } catch {
            index = nil
            indexReadable = false
        }
        let credentials = keys.map { revocableCredential(for: $0) }
        let legacyCredentials = legacyServerIDs.map { legacyRevocableCredential(serverID: $0) }
        var ownerOfKey: [SignInKey: String] = [:]
        var ownerOfLegacy: [String: String] = [:]
        for user in index?.users ?? [] {
            for key in user.signIns where keys.contains(key) { ownerOfKey[key] = user.id }
            for serverID in user.pendingLegacyServerIDs ?? [] where legacyServerIDs.contains(serverID) {
                ownerOfLegacy[serverID] = user.id
            }
        }
        // A server's own slot holds a session only while it can still be
        // read: before migration (or while the index can't be read), or as a
        // pending legacy server.
        func legacyCounts(_ serverID: String) -> Bool {
            index == nil || ownerOfLegacy[serverID] != nil
        }

        var removedUsers: Set<String> = []
        var indexCommitted = indexReadable && index == nil
        if indexReadable, let index {
            var updated = index
            for member in updated.users.indices {
                updated.users[member].signIns.removeAll { keys.contains($0) }
                if let pending = updated.users[member].pendingLegacyServerIDs {
                    let remaining = pending.filter { !legacyServerIDs.contains($0) }
                    updated.users[member].pendingLegacyServerIDs = remaining.isEmpty ? nil : remaining
                }
            }
            let emptied = updated.users.filter { user in
                user.id == dropUserID || (user.signIns.isEmpty && (user.pendingLegacyServerIDs ?? []).isEmpty)
            }.map(\.id)
            updated.users.removeAll { emptied.contains($0.id) }
            if updated == index {
                indexCommitted = true
            } else {
                do {
                    try saveIndex(updated)
                    indexCommitted = true
                    removedUsers = Set(emptied)
                } catch {
                    recordSessionEvent(phase: phase, outcome: "failed", reason: Self.persistenceFailureReason(error))
                }
            }
        }

        var itemsRemoved: [Bool] = []
        for key in keys {
            // When the index write failed, deleting the item still keeps the
            // session from coming back; the index then lists a missing item.
            itemsRemoved.append(savedSignIns.removeSignIn(key))
            removeProofs(for: key)
            if indexCommitted { unblock(.signIn(key)) } else { block(.signIn(key)) }
        }
        var legacyRemoved: [Bool] = []
        for serverID in legacyServerIDs {
            let invalidated = sessions.invalidate(serverID)
            deleteRawSlots(serverID)
            profileKeychain.delete(Self.profileTokenKey(for: serverID))
            block(.legacy(serverID: serverID))
            // Gone for good once tombstoned, or once no user lists it as
            // pending: it is never read again (invariant 4).
            let stillListed = index == nil || (ownerOfLegacy[serverID] != nil && !indexCommitted)
            legacyRemoved.append(invalidated || !stillListed)
        }
        let isCurrentUser: (String?) -> Bool = { owner in owner != nil && owner == self.activeUserID }
        let currentUserLosesServer = keys.contains { isCurrentUser(ownerOfKey[$0]) }
            || legacyServerIDs.contains { index == nil || isCurrentUser(ownerOfLegacy[$0]) }
        if currentUserLosesServer {
            for serverID in Set(keys.map(\.serverID) + legacyServerIDs) {
                removeDisplayTargets(registeredBy: serverID)
            }
        }

        let removesSelection: Bool
        switch selection {
        case .none: removesSelection = false
        case .signIn(let key): removesSelection = keys.contains(key)
        case .legacy(let serverID): removesSelection = legacyServerIDs.contains(serverID)
        }
        if removesSelection {
            persistentCredentialGenerationID = UUID()
            // Before migration the server keeps its (now signed-out) slot
            // selected, as sign-out always has; afterwards nothing is.
            if index != nil || !indexReadable { selection = .none }
            invalidateLoadedCredential()
            loadedSelection = selection
            defaults.removeObject(forKey: profileIdDefaultsKey)
            clearMirroredTokensForExtension()
            writeAccountMirror()
        }
        if let current = activeUserID, removedUsers.contains(current) {
            activeUserID = nil
        }

        let keyResults = keys.enumerated().map { offset, key in
            SignInRemoval(
                credential: credentials[offset],
                removedUserID: ownerOfKey[key].flatMap { removedUsers.contains($0) ? $0 : nil },
                durable: indexCommitted || itemsRemoved[offset]
            )
        }
        let legacyResults = legacyServerIDs.enumerated().map { offset, serverID in
            SignInRemoval(
                credential: legacyCounts(serverID) ? legacyCredentials[offset] : nil,
                removedUserID: ownerOfLegacy[serverID].flatMap { removedUsers.contains($0) ? $0 : nil },
                durable: legacyRemoved[offset]
            )
        }
        let results = keyResults + legacyResults
        let allDurable = results.allSatisfy(\.durable)
        recordSessionEvent(
            phase: phase,
            outcome: allDurable ? "cleared" : "failed",
            reason: allDurable ? "persistentSession" : "persistenceUnavailable"
        )
        return results
    }

    // MARK: - User and display data

    /// Rename a user on this device (`SiloUserNaming.normalizedDisplayName`):
    /// trimmed and capped at 40 characters; an empty name restores the
    /// default.
    @discardableResult
    func renameUser(_ userID: String, to name: String?) -> Bool {
        let normalized = SiloUserNaming.normalizedDisplayName(name)
        guard let index = try? loadIndex(), let member = index.users.firstIndex(where: { $0.id == userID }) else {
            return false
        }
        guard index.users[member].displayName != normalized else { return true }
        var updated = index
        updated.users[member].displayName = normalized
        do { try saveIndex(updated) } catch { return false }
        return true
    }

    /// Update a sign-in's display cache (username, profiles for user cards).
    /// Nil leaves a field as it is; an unchanged cache is not rewritten.
    @discardableResult
    func updateSignInDisplay(_ key: SignInKey, username: String?, profiles: [SavedSignInProfile]?) -> Bool {
        guard let signIn = try? savedSignIns.loadSignIn(key) else { return false }
        var updated = signIn
        if let username { updated.username = username }
        if let profiles { updated.profiles = profiles }
        guard updated != signIn else { return true }
        do { try savedSignIns.saveSignIn(updated) } catch { return false }
        // Token rotation compares the stored item with this copy.
        if cachedSignIn == signIn { cachedSignIn = updated }
        return true
    }

    /// Bind the account `/api/v2/account/me` named to the credential that
    /// read it, under this exact token and process identity.
    ///
    /// - A saved sign-in must name the same account (otherwise identity
    ///   changed); its username is filled in when it differs.
    /// - A pending legacy server becomes a saved sign-in in its user, keeping
    ///   the epoch, the generation, and the cached tokens, or is dropped when
    ///   that account is already saved (plan §3.3). A failed write leaves the
    ///   server pending and working.
    /// - Before migration the server's own record is bound, as it always was.
    ///   Access-only legacy credentials can still read account metadata, but
    ///   cannot establish a refreshable durable login envelope.
    @discardableResult
    func bindVerifiedAccount(_ account: APIv2Account, expected: CapturedOrdinaryRequestAuth) throws -> BindOutcome {
        guard temporaryScope == nil else { return .unchanged }
        ensureLoaded()
        guard !account.id.isEmpty, refreshAccountIdentity() == expected.account,
              cachedAccessToken == expected.accessToken else { throw HTTPError.requestIdentityChanged }
        switch selection {
        case .none:
            return .unchanged
        case .signIn(let key):
            guard key.accountID == account.id else { throw AccountSessionPersistenceError.invalidIdentity }
            guard cachedSignIn?.username != account.username else { return .unchanged }
            return updateSignInDisplay(key, username: account.username, profiles: nil) ? .usernameUpdated : .unchanged
        case .legacy(let serverID):
            guard let access = cachedAccessToken, let refresh = cachedRefreshToken else { return .unchanged }
            if let canonicalSession, canonicalSession.accountID != nil, canonicalSession.accountID != account.id {
                throw AccountSessionPersistenceError.invalidIdentity
            }
            let index: SiloUserIndex?
            do { index = try loadIndex() } catch {
                // Bind nothing until the index can be read; the next account
                // read retries.
                return .unchanged
            }
            guard let index else {
                try bindLegacySession(serverID, accountID: account.id, access: access, refresh: refresh,
                                      serverURL: expected.account.serverURL)
                return .unchanged
            }
            guard let pendingOwner = index.users.firstIndex(where: {
                $0.pendingLegacyServerIDs?.contains(serverID) == true
            }) else {
                return .unchanged
            }
            guard let key = SignInKey(serverID: serverID, accountID: account.id) else {
                throw AccountSessionPersistenceError.invalidIdentity
            }
            if index.users.contains(where: { $0.signIns.contains(key) }) {
                return dropDuplicateLegacyServer(serverID, existing: key, index: index)
            }
            return migratePendingLegacyServer(serverID, key: key, username: account.username, access: access,
                                              refresh: refresh, serverURL: expected.account.serverURL,
                                              userIndex: pendingOwner, index: index)
        }
    }

    private func bindLegacySession(_ serverID: String, accountID: String, access: String, refresh: String, serverURL: String) throws {
        if canonicalSession?.accountID == accountID { return }
        let legacyEpoch = accountKeychain.get(Self.accountEpochKey(for: serverID)).flatMap(UUID.init(uuidString:))
        let value = CanonicalAccountSession(version: 1, signedOut: false, origin: serverURL,
            accountID: accountID, epoch: canonicalSession?.epoch ?? legacyEpoch ?? UUID(), accessToken: access, refreshToken: refresh)
        do { try sessions.save(value, serverID: serverID) }
        catch { blockRuntimeSession(); throw error }
        canonicalSession = value
        mirrorCanonicalSession(value, serverID: serverID)
    }

    private func migratePendingLegacyServer(
        _ serverID: String,
        key: SignInKey,
        username: String?,
        access: String,
        refresh: String,
        serverURL: String,
        userIndex: Int,
        index: SiloUserIndex
    ) -> BindOutcome {
        let user = index.users[userIndex]
        let epoch = canonicalSession?.epoch
            ?? accountKeychain.get(Self.accountEpochKey(for: serverID)).flatMap(UUID.init(uuidString:))
            ?? UUID()
        let signIn = SavedSignIn(
            key: key,
            userID: user.id,
            origin: canonicalSession?.origin.map { ServerRegistry.normalize(url: $0) } ?? serverURL,
            username: username,
            accessToken: access,
            refreshToken: refresh,
            epoch: epoch,
            addedAt: Date(),
            adoptsLegacyLocalData: true
        )
        do { try savedSignIns.saveSignIn(signIn) } catch {
            recordSessionEvent(phase: "signInMigration", outcome: "deferred", reason: "writeFailed")
            return .unchanged
        }
        var updated = index
        let pending = (user.pendingLegacyServerIDs ?? []).filter { $0 != serverID }
        updated.users[userIndex].pendingLegacyServerIDs = pending.isEmpty ? nil : pending
        updated.users[userIndex].signIns.append(key)
        var owners = updated.legacyDataOwnerByServerID ?? [:]
        owners[serverID] = key.accountID
        updated.legacyDataOwnerByServerID = owners
        do { try saveIndex(updated) } catch {
            recordSessionEvent(phase: "signInMigration", outcome: "deferred", reason: "writeFailed")
            return .unchanged
        }
        // Never read again (invariant 4). This Apple TV user's proof moves
        // below; others adopt theirs on their next launch.
        _ = sessions.invalidate(serverID)
        deleteRawSlots(serverID)
        // The same credential, now under its sign-in: the generation and the
        // cached tokens stay, so requests in flight are unaffected.
        selection = .signIn(key)
        activeUserID = user.id
        canonicalSession = nil
        cachedSignIn = signIn
        loadedSelection = selection
        cachedProfileToken = loadProof(for: key) ?? cachedProfileToken
        writeAccountMirror()
        recordSessionEvent(phase: "signInMigration", outcome: "migrated", reason: "pendingServer")
        return .legacyMigrated(key)
    }

    private func dropDuplicateLegacyServer(_ serverID: String, existing: SignInKey, index: SiloUserIndex) -> BindOutcome {
        var updated = index
        for member in updated.users.indices {
            if let pending = updated.users[member].pendingLegacyServerIDs {
                let remaining = pending.filter { $0 != serverID }
                updated.users[member].pendingLegacyServerIDs = remaining.isEmpty ? nil : remaining
            }
        }
        let emptied = updated.users.filter { $0.signIns.isEmpty && ($0.pendingLegacyServerIDs ?? []).isEmpty }.map(\.id)
        updated.users.removeAll { emptied.contains($0.id) }
        // The server's old local data belonged to this same account, so the
        // saved sign-in takes it over unless another account already has.
        var owners = updated.legacyDataOwnerByServerID ?? [:]
        if owners[serverID] == nil {
            owners[serverID] = existing.accountID
            updated.legacyDataOwnerByServerID = owners
        }
        do { try saveIndex(updated) } catch {
            recordSessionEvent(phase: "signInMigration", outcome: "deferred", reason: "writeFailed")
            return .unchanged
        }
        // The saved sign-in may share this server session, so it is dropped
        // without revoking it.
        _ = sessions.invalidate(serverID)
        deleteRawSlots(serverID)
        profileKeychain.delete(Self.profileTokenKey(for: serverID))
        persistentCredentialGenerationID = UUID()
        selection = .none
        if let current = activeUserID, emptied.contains(current) { activeUserID = nil }
        invalidateLoadedCredential()
        loadedSelection = selection
        defaults.removeObject(forKey: profileIdDefaultsKey)
        clearMirroredTokensForExtension()
        writeAccountMirror()
        recordSessionEvent(phase: "signInMigration", outcome: "migrated", reason: "duplicatePendingServer")
        return .legacyDuplicate(existing: existing)
    }

    // MARK: - Per-server slots (before migration, and pending legacy servers)

    /// Everything a server's credential slot held at one moment, so pairing
    /// can put it back exactly when a later commit fails. The four states
    /// mirror `AccountSessionPersistence.State` plus the never-adopted legacy
    /// per-token slots, which are not a canonical record but are still the
    /// user's session and must not be tombstoned by a rollback.
    enum AccountSessionSnapshot: Equatable, Sendable {
        case session(CanonicalAccountSession, profileToken: String?)
        case legacy(accessToken: String?, refreshToken: String?, epoch: String?, profileToken: String?)
        case signedOut(profileToken: String?)
        /// The slot could not be read. Restoring it fails closed.
        case unreadable
    }

    func accountSessionSnapshot(for serverID: String) -> AccountSessionSnapshot {
        guard !serverID.isEmpty else { return .unreadable }
        do {
            let profileToken = try profileKeychain.getChecked(Self.profileTokenKey(for: serverID))
            switch try sessions.load(serverID) {
            case .session(let value): return .session(value, profileToken: profileToken)
            case .signedOut: return .signedOut(profileToken: profileToken)
            case .legacy:
                return .legacy(accessToken: try accountKeychain.getChecked(Self.accessTokenKey(for: serverID)),
                    refreshToken: try accountKeychain.getChecked(Self.refreshTokenKey(for: serverID)),
                    epoch: try accountKeychain.getChecked(Self.accountEpochKey(for: serverID)), profileToken: profileToken)
            }
        } catch {
            return .unreadable
        }
    }

    /// Reinstates `snapshot` for `serverID`. When the restore cannot be made
    /// durable, returns false and blocks runtime use. If restoring the profile
    /// proof fails after the account commit, invalidate that partial session
    /// durably so it cannot return after relaunch.
    @discardableResult
    func restoreAccountSession(_ snapshot: AccountSessionSnapshot, for serverID: String) -> Bool {
        guard !serverID.isEmpty else { return false }
        var durable: Bool
        let profileToken: String?
        switch snapshot {
        case .session(let value, let proof):
            profileToken = proof
            durable = (try? sessions.save(value, serverID: serverID)) != nil
            if durable { mirrorCanonicalSession(value, serverID: serverID) }
        case .legacy(let access, let refresh, let epoch, let proof):
            profileToken = proof
            func put(_ value: String?, _ key: String) -> Bool {
                if let value { return accountKeychain.set(value, for: key) }
                return accountKeychain.delete(key)
            }
            let accessRestored = put(access, Self.accessTokenKey(for: serverID))
            let refreshRestored = put(refresh, Self.refreshTokenKey(for: serverID))
            let epochRestored = put(epoch, Self.accountEpochKey(for: serverID))
            // Keep canonical authority until every legacy field is restored.
            durable = accessRestored && refreshRestored && epochRestored
            if durable { durable = sessions.forget(serverID) }
        case .signedOut(let proof):
            profileToken = proof
            durable = sessions.invalidate(serverID)
            if durable {
                deleteRawSlots(serverID)
            }
        case .unreadable:
            profileToken = nil
            durable = false
        }
        var failureReason = "persistenceUnavailable"
        if durable {
            if let profileToken {
                durable = profileKeychain.set(profileToken, for: Self.profileTokenKey(for: serverID))
            } else {
                durable = profileKeychain.delete(Self.profileTokenKey(for: serverID))
            }
            if !durable {
                // Account and profile proofs use different Keychain audiences.
                // Revoke the account if its profile proof cannot be restored.
                failureReason = sessions.invalidate(serverID)
                    ? "profileRestoreFailedSessionInvalidated"
                    : "profileRestoreFailedInvalidationFailed"
            }
        }
        let slot = CredentialSelection.legacy(serverID: serverID)
        if durable {
            unblock(slot)
        } else {
            recordSessionEvent(phase: "sessionRestore", outcome: "failed", reason: failureReason)
            block(slot)
        }
        if selection == slot {
            persistentCredentialGenerationID = UUID()
            invalidateLoadedCredential()
            ensureLoaded()
            mirrorActiveTokensForExtension()
        }
        return durable
    }

    private func mirrorCanonicalSession(_ value: CanonicalAccountSession, serverID: String) {
        if let access = value.accessToken { accountKeychain.set(access, for: Self.accessTokenKey(for: serverID)) }
        if let refresh = value.refreshToken { accountKeychain.set(refresh, for: Self.refreshTokenKey(for: serverID)) }
        if let epoch = value.epoch { accountKeychain.set(epoch.uuidString, for: Self.accountEpochKey(for: serverID)) }
    }

    private func blockRuntimeSession() {
        block(selection)
        persistentCredentialGenerationID = UUID()
        cachedAccessToken = nil; cachedRefreshToken = nil; cachedProfileToken = nil
        canonicalSession = nil; cachedSignIn = nil
        loadedSelection = selection
        clearMirroredTokensForExtension()
        removeDisplayTargets(registeredBy: activeServerId)
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
        guard writeProof(token, profileID: defaults.string(forKey: profileIdDefaultsKey)) else { return false }
        cachedProfileToken = token
        profileSelectionGeneration = UUID()
        mirrorActiveTokensForExtension()
        return true
    }

    /// Writes, or with nil clears, this Apple TV user's proof for the
    /// selected credential. With nothing selected there is no slot, so only
    /// clearing succeeds.
    private func writeProof(_ token: String?, profileID: String?) -> Bool {
        switch selection {
        case .none:
            return token == nil
        case .legacy(let serverID):
            if let token { return profileKeychain.set(token, for: Self.profileTokenKey(for: serverID)) }
            return profileKeychain.delete(Self.profileTokenKey(for: serverID))
        case .signIn(let key):
            if let token { return proofs.save(SignInProfileProof(profileID: profileID, token: token), for: key) }
            return proofs.remove(key)
        }
    }

    /// Deletes this Apple TV user's proof for `key`, and, when `key` took
    /// over its server's data from before sign-ins existed, the proof still
    /// saved under the server's old per-server name, so a later load can't
    /// adopt a proof bound to a session that is gone.
    private func removeProofs(for key: SignInKey) {
        proofs.remove(key)
        if legacyDataOwners[key.serverID] == key.accountID {
            proofs.removeLegacy(serverID: key.serverID)
        }
    }

    /// The selected sign-in's proof for this Apple TV user. A sign-in that
    /// owns its server's data from before migration adopts the proof saved
    /// under the old per-server name the first time it has none (plan §2.4),
    /// so each Apple TV user moves only their own proof.
    private func loadProof(for key: SignInKey) -> String? {
        do {
            if let proof = try proofs.load(key) { return proof.token }
        } catch {
            recordSessionEvent(phase: "sessionLoad", outcome: "failed", reason: "invalidProfileProof")
            return nil
        }
        guard legacyDataOwner(forServer: key.serverID) == key.accountID,
              let legacy = proofs.loadLegacy(serverID: key.serverID) else { return nil }
        if proofs.save(SignInProfileProof(profileID: nil, token: legacy), for: key) {
            proofs.removeLegacy(serverID: key.serverID)
        }
        return legacy
    }

    func getOrCreateAccountEpoch() -> String? {
        guard temporaryScope == nil else { return nil }
        return getOrCreateAccountEpoch(for: activeServerId)
    }

    /// The epoch of the current user's credential on `serverID`: a saved
    /// sign-in's own, or a per-server slot's, minted on demand for a legacy
    /// slot that never had one.
    func getOrCreateAccountEpoch(for serverID: String) -> String? {
        guard !serverID.isEmpty else { return nil }
        switch storedCredential(forServer: serverID) {
        case .none:
            return nil
        case .signIn(let key):
            guard !isBlocked(.signIn(key)) else { return nil }
            if serverID == activeServerId {
                ensureLoaded()
                return cachedSignIn?.epoch?.uuidString
            }
            return (try? savedSignIns.loadSignIn(key))?.epoch?.uuidString
        case .legacy:
            return getOrCreateLegacyEpoch(for: serverID)
        }
    }

    private func getOrCreateLegacyEpoch(for serverID: String) -> String? {
        guard !isBlocked(.legacy(serverID: serverID)) else { return nil }
        do {
            switch try sessions.load(serverID) {
            case .session(let value): return value.epoch?.uuidString
            case .signedOut: return nil
            case .legacy: break
            }
        } catch {
            recordSessionEvent(
                phase: "sessionLoad",
                outcome: "failed",
                reason: Self.persistenceFailureReason(error)
            )
            return nil
        }
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

    /// Commits profile ID and verification proof in one actor turn after the
    /// caller has closed HTTP dispatch. Persistent mutations fail closed while
    /// a temporary remote-playback identity owns request authentication, and
    /// when no credential is selected.
    func activateProfile(
        profileID: String,
        profileToken: String?,
        expectedAccount: RefreshAccountIdentity
    ) -> Bool {
        guard temporaryScope == nil,
              selection != .none,
              refreshAccountIdentity() == expectedAccount,
              !profileID.isEmpty else {
            return false
        }
        ensureLoaded()
        guard writeProof(profileToken, profileID: profileID) else { return false }
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
        if !activeServerId.isEmpty,
           !writeProof(nil, profileID: nil) {
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
            loadedSelection = nil
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
        guard loadedSelection != selection else { return }
        canonicalSession = nil
        cachedSignIn = nil
        cachedAccessToken = nil
        cachedRefreshToken = nil
        cachedProfileToken = nil
        if !isBlocked(selection) {
            switch selection {
            case .none:
                break
            case .legacy(let serverID):
                loadLegacySession(serverID)
            case .signIn(let key):
                loadSavedSignIn(key)
            }
        }
        loadedSelection = selection
    }

    private func loadLegacySession(_ serverID: String) {
        do {
            switch try sessions.load(serverID) {
            case .session(let value):
                let origin = ServerRegistry.normalize(url: defaults.string(forKey: serverUrlDefaultsKey) ?? "")
                if value.origin == origin {
                    canonicalSession = value
                    cachedAccessToken = value.accessToken
                    cachedRefreshToken = value.refreshToken
                    cachedProfileToken = profileKeychain.get(Self.profileTokenKey(for: serverID))
                }
            case .signedOut: break
            case .legacy:
                cachedAccessToken = accountKeychain.get(Self.accessTokenKey(for: serverID))
                cachedRefreshToken = accountKeychain.get(Self.refreshTokenKey(for: serverID))
                cachedProfileToken = profileKeychain.get(Self.profileTokenKey(for: serverID))
            }
        } catch {
            // Fail closed: a record that cannot be read or decoded
            // blocks the runtime session until the next install.
            recordSessionEvent(
                phase: "sessionLoad",
                outcome: "blocked",
                reason: Self.persistenceFailureReason(error)
            )
            block(.legacy(serverID: serverID))
        }
    }

    /// A saved sign-in serves only the origin it was saved for, and only for
    /// the user that lists it.
    private func loadSavedSignIn(_ key: SignInKey) {
        let signIn: SavedSignIn?
        do { signIn = try savedSignIns.loadSignIn(key) } catch {
            recordSessionEvent(
                phase: "sessionLoad",
                outcome: "blocked",
                reason: Self.persistenceFailureReason(error)
            )
            block(.signIn(key))
            return
        }
        let origin = ServerRegistry.normalize(url: defaults.string(forKey: serverUrlDefaultsKey) ?? "")
        guard let signIn, ServerRegistry.normalize(url: signIn.origin) == origin,
              activeUserID == nil || signIn.userID == activeUserID else { return }
        cachedSignIn = signIn
        guard signIn.isSignedIn else { return }
        cachedAccessToken = signIn.accessToken
        cachedRefreshToken = signIn.refreshToken
        cachedProfileToken = loadProof(for: key)
    }

    /// Mirror the current active access + profile tokens to fixed-name
    /// Keychain slots the extensions read. They don't know which server is
    /// active, so they look for these server-independent accounts instead.
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
    /// caller's job (`ApplePushRegistrationCoordinator.unregister`).
    private func removeDisplayTargets(registeredBy serverId: String) {
        #if os(iOS)
        guard !serverId.isEmpty else { return }
        displayTargets.removeTargets(registeredBy: serverId)
        #endif
    }

    private func clearMirroredTokensForExtension() {
        accountKeychain.delete(SharedStorage.mirroredAccessTokenAccount)
        profileKeychain.delete(SharedStorage.mirroredProfileTokenAccount)
        lastMirroredAccessToken = nil
        lastMirroredProfileToken = nil
    }
}
