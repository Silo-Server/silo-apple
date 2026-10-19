import Foundation
import XCTest
@testable import Silo

extension APIv2Account {
    /// An `/api/v2/account/me` answer naming `id`.
    static func stub(id: String, username: String = "user", email: String? = nil) -> APIv2Account {
        APIv2Account(id: id, username: username, email: email, role: .user, permissions: [],
                     downloadAllowed: true, impersonation: nil)
    }
}

/// Keychain items in memory for the closure-based credential stores, with
/// read and write failures that a test switches on per item or for all.
final class CredentialItemMemory: @unchecked Sendable {
    struct ReadFailure: Error {}

    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var reads: Set<String> = []
    private var writes: Set<String> = []
    private var allReadsFail = false
    private var allWritesFail = false
    private var writeLog: [String] = []

    var values: [String: String] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
    /// Item names whose reads throw, as a locked keychain does.
    var failingReads: Set<String> {
        get { lock.withLock { reads } }
        set { lock.withLock { reads = newValue } }
    }
    /// Item names whose writes fail.
    var failingWrites: Set<String> {
        get { lock.withLock { writes } }
        set { lock.withLock { writes = newValue } }
    }
    var failsAllReads: Bool {
        get { lock.withLock { allReadsFail } }
        set { lock.withLock { allReadsFail = newValue } }
    }
    var failsAllWrites: Bool {
        get { lock.withLock { allWritesFail } }
        set { lock.withLock { allWritesFail = newValue } }
    }
    /// Every write and removal attempted, in order, failed or not.
    var attemptedWrites: [String] { lock.withLock { writeLog } }

    func read(_ key: String) throws -> String? {
        try lock.withLock {
            if allReadsFail || reads.contains(key) { throw ReadFailure() }
            return storage[key]
        }
    }

    func write(_ value: String, _ key: String) -> Bool {
        lock.withLock {
            writeLog.append(key)
            if allWritesFail || writes.contains(key) { return false }
            storage[key] = value
            return true
        }
    }

    func remove(_ key: String) -> Bool {
        lock.withLock {
            writeLog.append(key)
            if allWritesFail || writes.contains(key) { return false }
            storage.removeValue(forKey: key)
            return true
        }
    }

    var signInStore: SavedSignInStore {
        SavedSignInStore(read: { try self.read($0) }, write: { self.write($0, $1) }, remove: { self.remove($0) })
    }

    var sessions: AccountSessionPersistence {
        AccountSessionPersistence(read: { try self.read($0) }, write: { self.write($0, $1) }, remove: { self.remove($0) })
    }
}

/// An isolated `TokenStore`: its own keychain service (raw per-server slots,
/// proofs, Top Shelf mirrors) and defaults suite, with the canonical
/// per-server sessions and the saved sign-ins in memory.
struct SignInStoreFixture {
    let store: TokenStore
    let keychain: SharedKeychain
    let defaults: SharedDefaults
    let sessions: CredentialItemMemory
    let signIns: CredentialItemMemory

    /// Registry-shaped server IDs, so origin binding (`belongsTo`) holds.
    static let home = ServerRegistry.serverId(for: "https://home.example")
    static let friend = ServerRegistry.serverId(for: "https://friend.example")
    static let homeURL = "https://home.example"
    static let friendURL = "https://friend.example"

    static func make(_ test: XCTestCase, name: String = #function) throws -> SignInStoreFixture {
        let suiteName = "SignInStoreFixture.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        test.addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let keychain = SharedKeychain(service: suiteName, accessGroup: nil)
        let sessions = CredentialItemMemory()
        let signIns = CredentialItemMemory()
        return SignInStoreFixture(
            store: TokenStore(keychain: keychain, defaults: defaults,
                              sessionPersistence: sessions.sessions, savedSignIns: signIns.signInStore),
            keychain: keychain,
            defaults: defaults,
            sessions: sessions,
            signIns: signIns
        )
    }

    /// The same keychain, defaults, and memory in a new process.
    func relaunched() -> TokenStore {
        TokenStore(keychain: keychain, defaults: defaults,
                   sessionPersistence: sessions.sessions, savedSignIns: signIns.signInStore)
    }

    /// Point `store` at a server the way the registry does: URL mirror,
    /// active-server mirror, then the launch rules' credential there.
    func activate(_ serverID: String, url: String, in store: TokenStore? = nil) async {
        let store = store ?? self.store
        defaults.set(serverID, forKey: SharedStorage.activeServerIdKey)
        await store.setServerUrl(url)
        let selected = await store.launchSelection(forServer: serverID)
        await store.select(serverID: serverID, credential: selected)
    }

    /// A pre-migration session on `serverID`, written the way builds before
    /// sign-ins existed wrote it.
    func seedLegacySession(_ serverID: String, url: String, accountID: String?,
                           access: String, refresh: String, epoch: UUID = UUID()) throws {
        try sessions.sessions.save(CanonicalAccountSession(version: 1, signedOut: false, origin: url,
            accountID: accountID, epoch: epoch, accessToken: access, refreshToken: refresh), serverID: serverID)
        let account = keychain.withAudience(.userIndependent)
        account.set(access, for: SharedStorage.accessTokenAccount(for: serverID))
        account.set(refresh, for: SharedStorage.refreshTokenAccount(for: serverID))
        account.set(epoch.uuidString, for: SharedStorage.accountEpochAccount(for: serverID))
    }

    /// Writes an empty accounts index, as migration does on a device with
    /// no sign-ins.
    func startAccountModel() throws {
        try signIns.signInStore.saveIndex(SiloAccountIndex())
    }

    func index() throws -> SiloAccountIndex? {
        try signIns.signInStore.loadIndex()
    }

    func signIn(_ key: SignInKey) throws -> SavedSignIn? {
        try signIns.signInStore.loadSignIn(key)
    }

    /// Sign in on the active server: a new account, or a refresh of the
    /// saved one.
    @discardableResult
    func install(_ accountID: String, username: String? = nil, access: String, refresh: String,
                 in store: TokenStore? = nil) async throws -> SignInInstallResult {
        let store = store ?? self.store
        let identity = await store.refreshAccountIdentity()
        let expected = try XCTUnwrap(identity)
        return try await store.installSignIn(
            accessToken: access, refreshToken: refresh,
            account: SignInAccount(id: accountID, username: username),
            origin: expected.serverURL, expected: expected
        )
    }
}

extension SignInKey {
    static func make(_ serverID: String, _ accountID: String) -> SignInKey {
        SignInKey(serverID: serverID, accountID: accountID)!
    }
}

extension ServerRegistry {
    /// Switches to `serverId` with the credential the launch rules give it
    /// outside a chooser (`TokenStore.launchSelection(forServer:)`), read
    /// from `tokenStore`, the registry's own store. The app names the
    /// credential of every switch; tests that only need "this server, as it
    /// would open" use this.
    @discardableResult
    func switchTo(
        serverId: String,
        launchSelectionFrom tokenStore: TokenStore,
        resolveDestinationProfile: Bool = false
    ) async -> Bool {
        let selected = await tokenStore.launchSelection(forServer: serverId)
        return await switchTo(serverId: serverId, credential: selected,
                              resolveDestinationProfile: resolveDestinationProfile)
    }
}
