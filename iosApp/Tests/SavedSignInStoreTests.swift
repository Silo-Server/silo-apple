import Foundation
import XCTest
@testable import Silo

/// Sign-ins can only be found through the index, so a corrupt or unreadable
/// item must never read as "no accounts" or as someone else's sign-in.
final class SavedSignInStoreTests: XCTestCase {
    private let alex = SignInKey(serverID: "aG9tZQ", accountID: "12")!
    private let sam = SignInKey(serverID: "aG9tZQ", accountID: "13")!

    private func signIn(_ key: SignInKey, signedIn: Bool = true) -> SavedSignIn {
        SavedSignIn(
            key: key,
            origin: "https://home.example",
            username: "alex",
            email: "alex@home.example",
            accessToken: signedIn ? "access" : nil,
            refreshToken: signedIn ? "refresh" : nil,
            epoch: signedIn ? UUID() : nil,
            addedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            profiles: [SavedSignInProfile(id: "default", name: "Jamie", avatarEmoji: "🦊",
                avatarImageUrl: nil, hasPin: true, isChild: false)],
            adoptsLegacyLocalData: true
        )
    }

    private func index(_ keys: [SignInKey], pending: [String] = []) -> SiloAccountIndex {
        SiloAccountIndex(
            accounts: keys.map(SiloAccountRef.signIn) + pending.map { .pendingLegacy(serverID: $0) },
            migrated: true,
            legacyDataOwnerByServerID: [alex.serverID: alex.accountID]
        )
    }

    func testIndexSignInAndProofRoundTrip() throws {
        let memory = KeychainMemory()
        let store = memory.signInStore

        XCTAssertNil(try store.loadIndex(), "an index that was never written reads as nil")
        let saved = index([alex], pending: ["b3RoZXI"])
        try store.saveIndex(saved)
        XCTAssertEqual(try store.loadIndex(), saved)

        XCTAssertNil(try store.loadSignIn(alex))
        let alexSignIn = signIn(alex)
        try store.saveSignIn(alexSignIn)
        XCTAssertEqual(try store.loadSignIn(alex), alexSignIn)
        XCTAssertNil(try store.loadSignIn(sam), "another account on the same server has its own item")
        XCTAssertTrue(store.removeSignIn(alex))
        XCTAssertNil(try store.loadSignIn(alex))

        let proofs = memory.proofStore
        let proof = SignInProfileProof(profileID: "default", token: "pin-proof")
        XCTAssertNil(try proofs.load(alex))
        XCTAssertTrue(proofs.save(proof, for: alex))
        XCTAssertEqual(try proofs.load(alex), proof)
        XCTAssertNil(try proofs.load(sam))
        XCTAssertTrue(proofs.remove(alex))
        XCTAssertNil(try proofs.load(alex))
    }

    func testSignedInRequiresBothTokensAndAnEpoch() {
        XCTAssertTrue(signIn(alex).isSignedIn)
        XCTAssertFalse(signIn(alex, signedIn: false).isSignedIn, "an expired sign-in has no tokens")
        var partial = signIn(alex)
        partial.accessToken = ""
        XCTAssertFalse(partial.isSignedIn)
        partial = signIn(alex)
        partial.epoch = nil
        XCTAssertFalse(partial.isSignedIn)
    }

    func testStrictReadErrorThrowsAndNeverReturnsNil() throws {
        let memory = KeychainMemory()
        let store = memory.signInStore
        try store.saveIndex(index([alex]))
        try store.saveSignIn(signIn(alex))
        XCTAssertTrue(memory.proofStore.save(SignInProfileProof(profileID: nil, token: "t"), for: alex))

        memory.failingReads = [SharedStorage.usersIndexAccount]
        XCTAssertThrowsError(try store.loadIndex(), "a read error is not an absent index, and skips the backup") { error in
            XCTAssertTrue(error is KeychainMemory.ReadFailure)
        }
        memory.failingReads = [SharedStorage.signInAccount(alex), SharedStorage.signInProofAccount(alex)]
        XCTAssertThrowsError(try store.loadSignIn(alex))
        XCTAssertThrowsError(try memory.proofStore.load(alex))
    }

    func testCorruptIndexFallsBackToTheLastWrittenCopy() throws {
        let memory = KeychainMemory()
        let store = memory.signInStore
        try store.saveIndex(index([alex]))
        let latest = index([alex, sam])
        try store.saveIndex(latest)

        for corrupt in ["{not json", #"{"version":1,"users":[{"id":"u","createdAt":0,"signIns":[{"serverID":"a.b","accountID":"1"}]}]}"#] {
            memory.values[SharedStorage.usersIndexAccount] = corrupt
            XCTAssertEqual(try store.loadIndex(), latest, "the backup matches the last successful write")
        }

        memory.values[SharedStorage.usersIndexBackupAccount] = nil
        XCTAssertThrowsError(try store.loadIndex()) { error in
            XCTAssertEqual(error as? SavedSignInStoreError, .corrupt)
        }

        memory.values[SharedStorage.usersIndexBackupAccount] = "{}"
        memory.failingReads = [SharedStorage.usersIndexBackupAccount]
        XCTAssertThrowsError(try store.loadIndex()) { error in
            XCTAssertTrue(error is KeychainMemory.ReadFailure, "an unreadable backup is a read error too")
        }
    }

    /// A backup that missed the latest write must not stand in for it: it
    /// could list a removed sign-in or miss an added one.
    func testFailedBackupWriteRemovesTheStaleBackup() throws {
        let memory = KeychainMemory()
        let store = memory.signInStore
        try store.saveIndex(index([alex]))

        memory.failingWrites = [SharedStorage.usersIndexBackupAccount]
        let latest = index([sam])
        try store.saveIndex(latest)
        XCTAssertEqual(try store.loadIndex(), latest, "the index itself committed")
        XCTAssertNil(memory.values[SharedStorage.usersIndexBackupAccount])

        memory.values[SharedStorage.usersIndexAccount] = "{not json"
        XCTAssertThrowsError(try store.loadIndex()) { error in
            XCTAssertEqual(error as? SavedSignInStoreError, .corrupt)
        }
    }

    func testFailedOrUnverifiedWritesThrowAndKeepThePreviousIndex() throws {
        let memory = KeychainMemory()
        let store = memory.signInStore
        let previous = index([alex])
        try store.saveIndex(previous)

        memory.failingWrites = [SharedStorage.usersIndexAccount, SharedStorage.signInAccount(alex)]
        XCTAssertThrowsError(try store.saveIndex(index([sam]))) { error in
            XCTAssertEqual(error as? SavedSignInStoreError, .writeFailed)
        }
        XCTAssertThrowsError(try store.saveSignIn(signIn(alex))) { error in
            XCTAssertEqual(error as? SavedSignInStoreError, .writeFailed)
        }
        XCTAssertEqual(try store.loadIndex(), previous)

        memory.failingWrites = []
        memory.garblesWrites = true
        XCTAssertThrowsError(try store.saveIndex(index([sam])), "a write that reads back differently failed") { error in
            XCTAssertEqual(error as? SavedSignInStoreError, .writeFailed)
        }
        XCTAssertFalse(memory.proofStore.save(SignInProfileProof(profileID: "p", token: "t"), for: alex))
    }

    func testWrongVersionFailsClosed() throws {
        let memory = KeychainMemory()
        let store = memory.signInStore
        try store.saveIndex(index([alex]))
        try store.saveSignIn(signIn(alex))

        memory.values[SharedStorage.usersIndexAccount] = #"{"version":3,"accounts":[]}"#
        XCTAssertThrowsError(try store.loadIndex(), "a newer format doesn't fall back to an older copy") { error in
            XCTAssertEqual(error as? SavedSignInStoreError, .unsupportedVersion(3))
        }

        let raw = try XCTUnwrap(memory.values[SharedStorage.signInAccount(alex)])
        memory.values[SharedStorage.signInAccount(alex)] = raw.replacingOccurrences(of: #""version":1"#, with: #""version":2"#)
        XCTAssertThrowsError(try store.loadSignIn(alex)) { error in
            XCTAssertEqual(error as? SavedSignInStoreError, .unsupportedVersion(2))
        }
    }

    func testSignInStoredUnderAnotherKeyFailsClosed() throws {
        let memory = KeychainMemory()
        let store = memory.signInStore
        try store.saveSignIn(signIn(sam))
        memory.values[SharedStorage.signInAccount(alex)] = memory.values[SharedStorage.signInAccount(sam)]

        XCTAssertThrowsError(try store.loadSignIn(alex)) { error in
            XCTAssertEqual(error as? SavedSignInStoreError, .keyMismatch)
        }
        XCTAssertEqual(try store.loadSignIn(sam)?.key, sam)
    }

    /// Test builds of the first multi-account design grouped sign-ins into
    /// users. Each sign-in and pending server becomes its own account, in
    /// user order; the next save writes the current format.
    func testFirstMultiAccountIndexLoadsAsAccountsInUserOrder() throws {
        let memory = KeychainMemory()
        let store = memory.signInStore
        let friend = "ZnJpZW5k"
        memory.values[SharedStorage.usersIndexAccount] = #"""
        {"version":1,"users":[
          {"id":"user-a","createdAt":800000000,"displayName":"Living Room",
           "signIns":[{"serverID":"aG9tZQ","accountID":"13"}],"pendingLegacyServerIDs":["ZnJpZW5k"]},
          {"id":"user-b","createdAt":800000001,
           "signIns":[{"serverID":"aG9tZQ","accountID":"12"},{"serverID":"aG9tZQ","accountID":"13"}]}
        ],"migratedUserID":"user-a","legacyDataOwnerByServerID":{"aG9tZQ":"13"}}
        """#

        let loaded = try XCTUnwrap(try store.loadIndex())
        XCTAssertEqual(loaded.version, SiloAccountIndex.currentVersion)
        XCTAssertEqual(loaded.accounts, [.signIn(sam), .pendingLegacy(serverID: friend), .signIn(alex)],
                       "a sign-in two users shared is one account")
        XCTAssertEqual(loaded.migrated, true)
        XCTAssertEqual(loaded.legacyDataOwnerByServerID, [sam.serverID: sam.accountID])

        try store.saveIndex(loaded)
        XCTAssertEqual(try store.loadIndex(), loaded)
        XCTAssertFalse(try XCTUnwrap(memory.values[SharedStorage.usersIndexAccount]).contains("users"))
    }

    func testSignInFromTheFirstMultiAccountDesignStillDecodes() throws {
        let memory = KeychainMemory()
        let store = memory.signInStore
        memory.values[SharedStorage.signInAccount(alex)] = #"""
        {"version":1,"serverID":"aG9tZQ","accountID":"12","userID":"user-a","origin":"https://home.example",
         "username":"alex","accessToken":"access","refreshToken":"refresh",
         "epoch":"5D4B7A2E-3C1F-4E8A-9B6D-2F0C1A3E5B7D","addedAt":800000000,"profiles":[]}
        """#

        let loaded = try XCTUnwrap(try store.loadSignIn(alex))
        XCTAssertEqual(loaded.key, alex)
        XCTAssertEqual(loaded.username, "alex")
        XCTAssertNil(loaded.email)
        XCTAssertTrue(loaded.isSignedIn)

        var withEmail = loaded
        withEmail.email = "alex@home.example"
        try store.saveSignIn(withEmail)
        XCTAssertEqual(try store.loadSignIn(alex), withEmail)
        XCTAssertFalse(try XCTUnwrap(memory.values[SharedStorage.signInAccount(alex)]).contains("userID"))
    }

    func testLegacyProofIsReadAndRemovedFromTheOldPerServerSlot() {
        let memory = KeychainMemory()
        let proofs = memory.proofStore
        XCTAssertNil(proofs.loadLegacy(serverID: alex.serverID))

        memory.values[SharedStorage.profileTokenAccount(for: alex.serverID)] = "legacy-proof"
        XCTAssertEqual(proofs.loadLegacy(serverID: alex.serverID), "legacy-proof")
        XCTAssertNil(try? proofs.load(alex), "a legacy proof is never read as a sign-in's proof")

        XCTAssertTrue(proofs.removeLegacy(serverID: alex.serverID))
        XCTAssertNil(proofs.loadLegacy(serverID: alex.serverID))
    }

    /// The keychain-backed stores write where the memory-backed tests expect.
    func testKeychainBackedStoresRoundTrip() throws {
        let keychain = SharedKeychain(service: "SavedSignInStoreTests.\(UUID().uuidString)", accessGroup: nil)
        let store = SavedSignInStore(keychain: keychain)
        let proofs = SignInProofStore(keychain: keychain)
        addTeardownBlock {
            store.removeSignIn(self.alex)
            proofs.remove(self.alex)
            keychain.withAudience(.userIndependent).delete(SharedStorage.usersIndexAccount)
            keychain.withAudience(.userIndependent).delete(SharedStorage.usersIndexBackupAccount)
        }

        let saved = index([alex])
        try store.saveIndex(saved)
        try store.saveSignIn(signIn(alex))
        XCTAssertTrue(proofs.save(SignInProfileProof(profileID: "default", token: "proof"), for: alex))

        XCTAssertEqual(try store.loadIndex(), saved)
        XCTAssertEqual(try store.loadSignIn(alex)?.accountID, alex.accountID)
        XCTAssertEqual(try proofs.load(alex)?.token, "proof")
    }
}

/// Keychain items in memory, with per-account read and write failures.
private final class KeychainMemory: @unchecked Sendable {
    struct ReadFailure: Error {}

    private let lock = NSLock()
    private var storage: [String: String] = [:]
    private var reads: Set<String> = []
    private var writes: Set<String> = []
    private var garbles = false

    var values: [String: String] {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
    var failingReads: Set<String> {
        get { lock.withLock { reads } }
        set { lock.withLock { reads = newValue } }
    }
    var failingWrites: Set<String> {
        get { lock.withLock { writes } }
        set { lock.withLock { writes = newValue } }
    }
    /// Writes succeed but store something else, as a failed verify would see.
    var garblesWrites: Bool {
        get { lock.withLock { garbles } }
        set { lock.withLock { garbles = newValue } }
    }

    private func read(_ key: String) throws -> String? {
        try lock.withLock {
            if reads.contains(key) { throw ReadFailure() }
            return storage[key]
        }
    }

    private func write(_ value: String, _ key: String) -> Bool {
        lock.withLock {
            if writes.contains(key) { return false }
            storage[key] = garbles ? value + " " : value
            return true
        }
    }

    private func remove(_ key: String) -> Bool {
        lock.withLock {
            storage.removeValue(forKey: key)
            return true
        }
    }

    var signInStore: SavedSignInStore {
        SavedSignInStore(read: { try self.read($0) }, write: { self.write($0, $1) }, remove: { self.remove($0) })
    }

    var proofStore: SignInProofStore {
        SignInProofStore(read: { try self.read($0) }, write: { self.write($0, $1) }, remove: { self.remove($0) })
    }
}
