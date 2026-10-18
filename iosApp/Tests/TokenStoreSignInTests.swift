import Foundation
import XCTest
@testable import Silo

/// Saved sign-ins in `TokenStore`: add or refresh, removal, the index
/// invariants (plan §2.2), refresh and expiry per sign-in, rollback, proof
/// adoption, and the per-server readers resolving the current user's sign-in.
final class TokenStoreSignInTests: XCTestCase {
    private typealias F = SignInStoreFixture
    private let alexHome = SignInKey.make(F.home, "12")
    private let samHome = SignInKey.make(F.home, "13")
    private let alexFriend = SignInKey.make(F.friend, "12")
    private let samFriend = SignInKey.make(F.friend, "13")

    private let jamie = SavedSignInProfile(id: "default", name: "Jamie", avatarEmoji: "🦊",
                                           avatarImageUrl: nil, hasPin: true, isChild: false)

    /// A device in the user model with alex signed in to Home.
    private func signedIn() async throws -> (F, SignInInstallResult) {
        let f = try F.make(self)
        try f.startUserModel()
        await f.activate(F.home, url: F.homeURL)
        let alex = try await f.install("12", username: "alex", access: "alex-access", refresh: "alex-refresh",
                                       placement: .newUser)
        return (f, alex)
    }

    /// Adds `accountID`'s sign-in on `server` for `placement`, then returns
    /// to Home, as Add Server and Add User do.
    @discardableResult
    private func add(_ f: F, _ accountID: String, on server: String, url: String,
                     placement: SignInPlacement) async throws -> SignInInstallResult {
        await f.store.setServerUrl(url)
        await f.store.select(serverID: server, credential: .none, userID: placement.joinedUserID)
        return try await f.install(accountID, access: "\(accountID)-\(server)-access",
                                   refresh: "\(accountID)-\(server)-refresh", placement: placement)
    }

    // MARK: - Add or refresh

    func testNewSignInIsSavedSelectedAndMirrored() async throws {
        let (f, alex) = try await signedIn()

        XCTAssertTrue(alex.createdUser)
        XCTAssertNil(alex.superseded)
        let index = try XCTUnwrap(try f.index())
        XCTAssertEqual(index.users.map(\.signIns), [[alexHome]])
        XCTAssertEqual(index.users.first?.id, alex.userID)
        let saved = try XCTUnwrap(try f.signIn(alexHome))
        XCTAssertEqual(saved.username, "alex")
        XCTAssertTrue(saved.isSignedIn)
        let selection = await f.store.currentSelection()
        let user = await f.store.currentUserID()
        let access = await f.store.getAccessToken()
        XCTAssertEqual(selection, .signIn(alexHome))
        XCTAssertEqual(user, alex.userID)
        XCTAssertEqual(access, "alex-access")
        XCTAssertEqual(f.defaults.string(forKey: SharedStorage.activeAccountIdKey), "12")
        XCTAssertEqual(f.store.mirroredAccountID, "12")
        XCTAssertEqual(f.keychain.withAudience(.userIndependent).get(SharedStorage.mirroredAccessTokenAccount),
                       "alex-access")
        // No per-server mirrors: Top Shelf reads the sign-in itself.
        XCTAssertNil(f.keychain.withAudience(.userIndependent).get(SharedStorage.accessTokenAccount(for: F.home)))

        let relaunched = f.relaunched()
        await f.activate(F.home, url: F.homeURL, in: relaunched)
        let restored = await relaunched.getAccessToken()
        XCTAssertEqual(restored, "alex-access")
    }

    /// Signing in again as the same account refreshes that sign-in: new
    /// tokens and epoch, same user, `addedAt`, and profile cache, and the
    /// old session is handed back to revoke.
    func testRefreshKeepsUserAddedAtAndProfilesWithANewEpoch() async throws {
        let (f, alex) = try await signedIn()
        let result1 = await f.store.updateSignInDisplay(alexHome, username: nil, profiles: [jamie])
        XCTAssertTrue(result1)
        await f.store.setProfileId("default")
        _ = await f.store.setProfileToken("pin-proof")
        let before = try XCTUnwrap(try f.signIn(alexHome))

        let refreshed = try await f.install("12", access: "new-access", refresh: "new-refresh",
                                            placement: .refresh(alexHome))

        let after = try XCTUnwrap(try f.signIn(alexHome))
        XCTAssertEqual(refreshed.userID, alex.userID)
        XCTAssertFalse(refreshed.createdUser)
        XCTAssertEqual(refreshed.superseded, RevocableCredential(serverURL: F.homeURL, accessToken: "alex-access",
                                                                 refreshToken: "alex-refresh"))
        XCTAssertNotEqual(after.epoch, before.epoch)
        XCTAssertEqual(after.addedAt, before.addedAt)
        XCTAssertEqual(after.userID, before.userID)
        XCTAssertEqual(after.profiles, [jamie])
        XCTAssertEqual(after.username, "alex", "a sign-in response without a username keeps the known one")
        XCTAssertEqual(after.accessToken, "new-access")
        let proof = await f.store.getProfileToken()
        let profile = await f.store.getProfileId()
        XCTAssertNil(proof, "a new session never inherits a PIN proof")
        XCTAssertNil(profile)
        XCTAssertNil(try SignInProofStore(keychain: f.keychain).load(alexHome))
        XCTAssertEqual(try f.index()?.users.count, 1)
    }

    // MARK: - Index invariants

    /// Invariant 1: a sign-in belongs to one user. Invariant 2: a user holds
    /// one sign-in, or pending legacy server, per server. A refused install
    /// writes nothing.
    func testPlacementsThatBreakAnInvariantAreRefused() async throws {
        let (f, alex) = try await signedIn()
        try await add(f, "13", on: F.home, url: F.homeURL, placement: .newUser)
        let index = try f.index()

        await f.store.setServerUrl(F.homeURL)
        await f.store.select(serverID: F.home, credential: .none, userID: nil)
        for placement: SignInPlacement in [.newUser, .join(userID: "nobody"), .refresh(samHome)] {
            do {
                try await f.install("12", access: "x", refresh: "y", placement: placement)
                XCTFail("\(placement) put alex's sign-in in a second user or refreshed another account")
            } catch SignInInstallError.invalidPlacement {}
        }
        do {
            try await f.install("14", access: "x", refresh: "y", placement: .join(userID: alex.userID))
            XCTFail("a user got two sign-ins on one server")
        } catch SignInInstallError.invalidPlacement {}
        do {
            try await f.install("14", access: "x", refresh: "y", placement: .refresh(.make(F.home, "14")))
            XCTFail("refreshed an account that isn't saved")
        } catch SignInInstallError.invalidPlacement {}
        XCTAssertEqual(try f.index(), index)
        XCTAssertNil(try f.signIn(.make(F.home, "14")))

        // A pending legacy server counts as the user's sign-in on it.
        let pending = try F.make(self)
        try pending.signIns.signInStore.saveIndex(SiloUserIndex(users: [
            SiloUser(id: "u", createdAt: Date(), signIns: [], pendingLegacyServerIDs: [F.home]),
        ]))
        await pending.store.setServerUrl(F.homeURL)
        await pending.store.select(serverID: F.home, credential: .none, userID: "u")
        do {
            try await pending.install("12", access: "x", refresh: "y", placement: .join(userID: "u"))
            XCTFail("joined a user that already has the server pending")
        } catch SignInInstallError.invalidPlacement {}
    }

    /// Invariant 3: a user with nothing left is removed in the same write.
    func testRemovingAUsersLastSignInRemovesTheUser() async throws {
        let (f, alex) = try await signedIn()
        try await add(f, "12", on: F.friend, url: F.friendURL, placement: .join(userID: alex.userID))

        let first = await f.store.removeSignIn(alexHome)
        XCTAssertTrue(first.durable)
        XCTAssertNil(first.removedUserID)
        XCTAssertEqual(try f.index()?.users.map(\.signIns), [[alexFriend]])

        let last = await f.store.removeSignIn(alexFriend)
        XCTAssertTrue(last.durable)
        XCTAssertEqual(last.removedUserID, alex.userID)
        XCTAssertEqual(last.credential?.accessToken, "12-\(F.friend)-access")
        XCTAssertEqual(try f.index()?.users, [])
        XCTAssertNil(try f.signIn(alexFriend))
    }

    func testRemoveUserRemovesEverySignInInOneWrite() async throws {
        let (f, alex) = try await signedIn()
        try await add(f, "12", on: F.friend, url: F.friendURL, placement: .join(userID: alex.userID))
        let sam = try await add(f, "13", on: F.home, url: F.homeURL, placement: .newUser)
        let writesBefore = f.signIns.attemptedWrites.filter { $0 == SharedStorage.usersIndexAccount }.count

        let removals = await f.store.removeUser(alex.userID)

        XCTAssertEqual(removals.count, 2)
        XCTAssertTrue(removals.allSatisfy(\.durable))
        XCTAssertEqual(Set(removals.compactMap(\.credential?.accessToken)),
                       ["alex-access", "12-\(F.friend)-access"])
        XCTAssertEqual(f.signIns.attemptedWrites.filter { $0 == SharedStorage.usersIndexAccount }.count,
                       writesBefore + 1)
        XCTAssertEqual(try f.index()?.users.map(\.id), [sam.userID])
        XCTAssertNil(try f.signIn(alexHome))
        XCTAssertNil(try f.signIn(alexFriend))
    }

    func testRemoveServerCoversEveryUser() async throws {
        let (f, alex) = try await signedIn()
        try await add(f, "12", on: F.friend, url: F.friendURL, placement: .join(userID: alex.userID))
        let sam = try await add(f, "13", on: F.home, url: F.homeURL, placement: .newUser)
        try f.seedLegacySession(F.home, url: F.homeURL, accountID: "12", access: "leftover", refresh: "r")

        let removals = await f.store.removeServer(F.home)

        XCTAssertTrue(removals.allSatisfy(\.durable))
        XCTAssertEqual(Set(removals.compactMap(\.credential?.accessToken)),
                       ["alex-access", "13-\(F.home)-access"])
        XCTAssertTrue(removals.contains { $0.removedUserID == sam.userID })
        let index = try XCTUnwrap(try f.index())
        XCTAssertEqual(index.users.map(\.id), [alex.userID])
        XCTAssertEqual(index.users.first?.signIns, [alexFriend])
        XCTAssertNil(try f.signIn(alexHome))
        XCTAssertNil(try f.signIn(samHome))
        guard case .signedOut = try f.sessions.sessions.load(F.home) else { return XCTFail("server record kept") }
    }

    /// Invariant 5: the index write is the commit point. Adding writes the
    /// item first, so a crash leaves only an unreachable item; removing
    /// writes the index first, so a crash leaves at most an unlisted item.
    func testTheIndexWriteIsTheCommitPoint() async throws {
        let f = try F.make(self)
        try f.startUserModel()
        await f.activate(F.home, url: F.homeURL)
        let item = SharedStorage.signInAccount(alexHome)
        let index = SharedStorage.usersIndexAccount

        var mark = f.signIns.attemptedWrites.count
        try await f.install("12", access: "a", refresh: "r", placement: .newUser)
        let added = Array(f.signIns.attemptedWrites.dropFirst(mark))
        XCTAssertLessThan(try XCTUnwrap(added.firstIndex(of: item)), try XCTUnwrap(added.firstIndex(of: index)))

        mark = f.signIns.attemptedWrites.count
        _ = await f.store.removeSignIn(alexHome)
        let removed = Array(f.signIns.attemptedWrites.dropFirst(mark))
        XCTAssertLessThan(try XCTUnwrap(removed.firstIndex(of: index)), try XCTUnwrap(removed.firstIndex(of: item)))
    }

    /// Invariant 6: an index that can't be decoded falls back to its last
    /// good copy, so one corrupt item doesn't sign everyone out.
    func testACorruptIndexFallsBackToItsLastGoodCopy() async throws {
        let (f, _) = try await signedIn()
        var values = f.signIns.values
        values[SharedStorage.usersIndexAccount] = "garbage"
        f.signIns.values = values

        let relaunched = f.relaunched()
        await f.activate(F.home, url: F.homeURL, in: relaunched)

        let access = await relaunched.getAccessToken()
        XCTAssertEqual(access, "alex-access")
    }

    /// Without a readable index a server's sign-ins can't be found, so
    /// removing the server fails and the registry keeps it.
    func testRemovingAServerWithAnUnreadableIndexRemovesNothing() async throws {
        let (f, _) = try await signedIn()
        f.signIns.failingReads = [SharedStorage.usersIndexAccount]

        let removals = await f.store.removeServer(F.home)

        XCTAssertFalse(removals.allSatisfy(\.durable))
        f.signIns.failingReads = []
        XCTAssertEqual(try f.signIn(alexHome)?.accessToken, "alex-access")
        XCTAssertEqual(try f.index()?.users.first?.signIns, [alexHome])
    }

    /// The index write is the commit point: when it fails the item is still
    /// deleted, so the session can't come back, and the runtime is blocked.
    /// Diagnostics are server-wide, so sign-out erases them only once nobody
    /// is signed in to the server; an index that can't be read counts as
    /// somebody still being signed in.
    func testAnUnreadableIndexStillCountsAsSignedInToTheServer() async throws {
        let (f, _) = try await signedIn()
        let home = await f.store.hasSavedSignIn(onServer: F.home)
        let friend = await f.store.hasSavedSignIn(onServer: F.friend)
        XCTAssertTrue(home)
        XCTAssertFalse(friend)

        f.signIns.failsAllReads = true
        defer { f.signIns.failsAllReads = false }
        let unreadable = await f.store.hasSavedSignIn(onServer: F.friend)
        XCTAssertTrue(unreadable)
    }

    func testRemovalThatCannotWriteTheIndexStillKeepsTheSessionFromReturning() async throws {
        let (f, _) = try await signedIn()
        f.signIns.failingWrites = [SharedStorage.usersIndexAccount]

        let removal = await f.store.removeSignIn(alexHome)

        XCTAssertTrue(removal.durable)
        XCTAssertEqual(try f.index()?.users.first?.signIns, [alexHome], "the index still lists it")
        XCTAssertNil(try f.signIn(alexHome))
        let access = await f.store.getAccessToken()
        XCTAssertNil(access)
        let relaunched = f.relaunched()
        await f.activate(F.home, url: F.homeURL, in: relaunched)
        let restored = await relaunched.getAccessToken()
        XCTAssertNil(restored)
    }

    /// A pending server's own slot is gone for good once no user lists it
    /// (even when its tombstone can't be written) and once it is tombstoned
    /// (even when the index still lists it), so either sign-out is durable.
    func testSigningOutOfAPendingServerIsDurableOnceUnlistedOrTombstoned() async throws {
        for failing in [AccountSessionPersistence.markerKey(F.friend), SharedStorage.usersIndexAccount] {
            let f = try F.make(self)
            try f.seedLegacySession(F.home, url: F.homeURL, accountID: "12", access: "a", refresh: "r")
            try f.seedLegacySession(F.friend, url: F.friendURL, accountID: nil, access: "friend-access",
                                    refresh: "friend-refresh")
            _ = await f.store.migrateLegacySessionsIfNeeded(
                servers: [(F.home, F.homeURL), (F.friend, F.friendURL)], activeServerID: F.home)
            await f.activate(F.friend, url: F.friendURL)
            let selected = await f.store.currentSelection()
            XCTAssertEqual(selected, .legacy(serverID: F.friend))
            if failing == SharedStorage.usersIndexAccount {
                f.signIns.failingWrites = [failing]
            } else {
                f.sessions.failingWrites = [failing]
            }

            let removal = await f.store.removeCurrentCredential()

            XCTAssertTrue(removal.durable, failing)
            XCTAssertEqual(removal.credential?.accessToken, "friend-access", failing)
            f.signIns.failingWrites = []
            f.sessions.failingWrites = []
            let relaunched = f.relaunched()
            await f.activate(F.friend, url: F.friendURL, in: relaunched)
            let access = await relaunched.getAccessToken()
            XCTAssertNil(access, failing)
        }
    }

    func testSigningOutTheCurrentSignInClearsTheSelectionAndSurvivesRelaunch() async throws {
        let (f, alex) = try await signedIn()
        await f.store.setProfileId("default")

        let removal = await f.store.removeCurrentCredential()

        XCTAssertTrue(removal.durable)
        XCTAssertEqual(removal.removedUserID, alex.userID)
        XCTAssertEqual(removal.credential, RevocableCredential(serverURL: F.homeURL, accessToken: "alex-access",
                                                               refreshToken: "alex-refresh"))
        let selection = await f.store.currentSelection()
        let user = await f.store.currentUserID()
        let hasCredential = await f.store.hasUsableCredential()
        XCTAssertEqual(selection, .none)
        XCTAssertNil(user)
        XCTAssertFalse(hasCredential)
        XCTAssertNil(f.defaults.string(forKey: SharedStorage.activeAccountIdKey))
        XCTAssertNil(f.defaults.string(forKey: SharedStorage.profileIdKey))
        XCTAssertNil(f.keychain.withAudience(.userIndependent).get(SharedStorage.mirroredAccessTokenAccount))
        let relaunched = f.relaunched()
        await f.activate(F.home, url: F.homeURL, in: relaunched)
        let restored = await relaunched.getAccessToken()
        XCTAssertNil(restored)
    }

    // MARK: - Refresh and expiry

    /// A rejected refresh marks the sign-in expired and keeps it in its user,
    /// so it can show "Sign in again".
    func testExpiryMarksTheSignInAndKeepsItInTheIndex() async throws {
        let (f, _) = try await signedIn()
        await f.store.setProfileId("default")
        _ = await f.store.setProfileToken("pin-proof")
        let accountValue = await f.store.refreshAccountIdentity()
        let account = try XCTUnwrap(accountValue)
        let capturedValue = await f.store.captureRefreshCredential(expected: account)
        let captured = try XCTUnwrap(capturedValue)

        let disposition = await f.store.invalidateRejectedRefresh(captured)

        XCTAssertEqual(disposition, .persistentSessionCleared)
        let saved = try XCTUnwrap(try f.signIn(alexHome))
        XCTAssertNil(saved.accessToken)
        XCTAssertNil(saved.refreshToken)
        XCTAssertNil(saved.epoch)
        XCTAssertEqual(saved.username, "alex")
        XCTAssertEqual(try f.index()?.users.first?.signIns, [alexHome])
        let summary = try await f.store.directory().signIns[alexHome]
        XCTAssertEqual(summary?.isSignedIn, false)
        let consumed = await f.store.shouldConsumeSessionExpiryEvent(
            SessionExpiryEvent(account: account, disposition: .persistentSessionCleared))
        XCTAssertTrue(consumed)
        XCTAssertNil(try SignInProofStore(keychain: f.keychain).load(alexHome))
        let selection = await f.store.currentSelection()
        XCTAssertEqual(selection, .signIn(alexHome))
    }

    func testRefreshRotatesOnlyTheSelectedSignInAndKeepsItsEpoch() async throws {
        let (f, _) = try await signedIn()
        let epoch = try f.signIn(alexHome)?.epoch
        let authValue = await f.store.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(authValue)

        let saved = await f.store.saveRefreshedTokens("rotated", "rotated-refresh", replacing:
            CapturedRefreshCredential(account: auth.account, refreshToken: "alex-refresh", owner: auth.credentialOwner))

        XCTAssertTrue(saved)
        let stored = try XCTUnwrap(try f.signIn(alexHome))
        XCTAssertEqual(stored.accessToken, "rotated")
        XCTAssertEqual(stored.refreshToken, "rotated-refresh")
        XCTAssertEqual(stored.epoch, epoch)
        XCTAssertNil(f.keychain.withAudience(.userIndependent).get(SharedStorage.accessTokenAccount(for: F.home)))
        XCTAssertEqual(f.keychain.withAudience(.userIndependent).get(SharedStorage.mirroredAccessTokenAccount), "rotated")
    }

    /// The credential generation changes on every selection, so a refresh
    /// sent for alex can't land on sam's sign-in on the same server, and a
    /// queued write for alex's account can't go out as sam.
    func testLateRefreshForOneSignInCannotLandOnAnotherOnTheSameServer() async throws {
        let (f, alex) = try await signedIn()
        let alexAuthValue = await f.store.captureOrdinaryRequestAuth()
        let alexAuth = try XCTUnwrap(alexAuthValue)
        let sam = try await add(f, "13", on: F.home, url: F.homeURL, placement: .newUser)
        _ = alex
        await f.store.setProfileId("default")

        let landed = await f.store.saveRefreshedTokens("late", "late-refresh", replacing:
            CapturedRefreshCredential(account: alexAuth.account, refreshToken: "alex-refresh",
                                      owner: alexAuth.credentialOwner))
        let scoped = await f.store.saveRefreshedTokens("late", "late-refresh", replacing: "13-\(F.home)-refresh",
            expected: HTTPRequestIdentity(serverId: F.home, serverURL: F.homeURL, profileId: "default",
                                          clientFamily: "tv", accountID: "12"),
            credentialOwner: .persistentServer(serverId: F.home))

        XCTAssertFalse(landed)
        XCTAssertFalse(scoped)
        XCTAssertEqual(try f.signIn(samHome)?.accessToken, "13-\(F.home)-access")
        XCTAssertEqual(try f.signIn(alexHome)?.accessToken, "alex-access")
        let access = await f.store.getAccessToken()
        XCTAssertEqual(access, "13-\(F.home)-access")
        XCTAssertEqual(sam.key, samHome)

        do {
            _ = try await f.store.captureRequestAuth(expected: HTTPRequestIdentity(serverId: F.home,
                serverURL: F.homeURL, profileId: "default", clientFamily: "tv", accountID: "12"))
            XCTFail("a write queued for alex went out as sam")
        } catch HTTPError.requestIdentityChanged {}
        let samWrite = try await f.store.captureRequestAuth(expected: HTTPRequestIdentity(serverId: F.home,
            serverURL: F.homeURL, profileId: "default", clientFamily: "tv", accountID: "13"))
        XCTAssertEqual(samWrite.accessToken, "13-\(F.home)-access")
    }

    // MARK: - Proofs

    /// Each Apple TV user's PIN proof from before sign-ins existed moves to
    /// the sign-in that took over the server's data, and to no other.
    func testOnlyTheLegacyOwnerAdoptsTheOldProof() async throws {
        let f = try F.make(self)
        let profileKeys = f.keychain.withAudience(.currentUser)
        profileKeys.set("old-proof", for: SharedStorage.profileTokenAccount(for: F.home))
        for (key, user) in [(alexHome, "alex"), (samHome, "sam")] {
            try f.signIns.signInStore.saveSignIn(SavedSignIn(key: key, userID: user, origin: F.homeURL,
                accessToken: "\(user)-access", refreshToken: "\(user)-refresh", epoch: UUID(), addedAt: Date()))
        }
        try f.signIns.signInStore.saveIndex(SiloUserIndex(
            users: [SiloUser(id: "alex", createdAt: Date(), signIns: [alexHome]),
                    SiloUser(id: "sam", createdAt: Date(), signIns: [samHome])],
            migratedUserID: "alex", legacyDataOwnerByServerID: [F.home: "12"]))
        await f.store.setServerUrl(F.homeURL)

        await f.store.select(serverID: F.home, credential: .signIn(samHome), userID: "sam")
        let samProof = await f.store.getProfileToken()
        XCTAssertNil(samProof)
        XCTAssertEqual(profileKeys.get(SharedStorage.profileTokenAccount(for: F.home)), "old-proof")

        await f.store.select(serverID: F.home, credential: .signIn(alexHome), userID: "alex")
        let alexProof = await f.store.getProfileToken()
        XCTAssertEqual(alexProof, "old-proof")
        XCTAssertEqual(try SignInProofStore(keychain: f.keychain).load(alexHome),
                       SignInProfileProof(profileID: nil, token: "old-proof"))
        XCTAssertNil(profileKeys.get(SharedStorage.profileTokenAccount(for: F.home)))
    }

    /// A new session never inherits a PIN proof. That includes this Apple TV
    /// user's proof saved under the server's old name, which the sign-in
    /// that took over the server would otherwise adopt on its next load:
    /// here it expired before this Apple TV user ever loaded it.
    func testANewSessionForTheLegacyOwnerNeverAdoptsTheOldProof() async throws {
        let f = try F.make(self)
        let profileKeys = f.keychain.withAudience(.currentUser)
        profileKeys.set("old-proof", for: SharedStorage.profileTokenAccount(for: F.home))
        try f.signIns.signInStore.saveSignIn(SavedSignIn(key: alexHome, userID: "alex", origin: F.homeURL,
            accessToken: nil, refreshToken: nil, epoch: nil, addedAt: Date(), adoptsLegacyLocalData: true))
        try f.signIns.signInStore.saveIndex(SiloUserIndex(
            users: [SiloUser(id: "alex", createdAt: Date(), signIns: [alexHome])],
            migratedUserID: "alex", legacyDataOwnerByServerID: [F.home: "12"]))
        await f.activate(F.home, url: F.homeURL)

        try await f.install("12", access: "new-access", refresh: "new-refresh", placement: .refresh(alexHome))

        XCTAssertNil(profileKeys.get(SharedStorage.profileTokenAccount(for: F.home)))
        let relaunched = f.relaunched()
        await f.activate(F.home, url: F.homeURL, in: relaunched)
        let proof = await relaunched.getProfileToken()
        XCTAssertNil(proof)
        XCTAssertNil(try SignInProofStore(keychain: f.keychain).load(alexHome))
    }

    /// Removing the legacy owner's sign-in takes this Apple TV user's old
    /// proof with it, so signing in as that account again can't adopt it.
    func testRemovingTheLegacyOwnerRemovesTheOldProof() async throws {
        let f = try F.make(self)
        let profileKeys = f.keychain.withAudience(.currentUser)
        profileKeys.set("old-proof", for: SharedStorage.profileTokenAccount(for: F.home))
        try f.signIns.signInStore.saveSignIn(SavedSignIn(key: alexHome, userID: "alex", origin: F.homeURL,
            accessToken: "a", refreshToken: "r", epoch: UUID(), addedAt: Date(), adoptsLegacyLocalData: true))
        try f.signIns.signInStore.saveIndex(SiloUserIndex(
            users: [SiloUser(id: "alex", createdAt: Date(), signIns: [alexHome])],
            migratedUserID: "alex", legacyDataOwnerByServerID: [F.home: "12"]))
        // Friend's is open, so Home's sign-in was never loaded here.
        await f.activate(F.friend, url: F.friendURL)

        let removal = await f.store.removeSignIn(alexHome)

        XCTAssertTrue(removal.durable)
        XCTAssertNil(profileKeys.get(SharedStorage.profileTokenAccount(for: F.home)))
        await f.activate(F.home, url: F.homeURL)
        try await f.install("12", access: "again", refresh: "again-refresh", placement: .newUser)
        let relaunched = f.relaunched()
        await f.activate(F.home, url: F.homeURL, in: relaunched)
        let proof = await relaunched.getProfileToken()
        XCTAssertNil(proof)
    }

    func testActivatingAProfileBindsItsProofToThatProfile() async throws {
        let (f, _) = try await signedIn()
        let accountValue = await f.store.refreshAccountIdentity()
        let account = try XCTUnwrap(accountValue)

        let result2 = await f.store.activateProfile(profileID: "default", profileToken: "pin", expectedAccount: account)
        XCTAssertTrue(result2)
        XCTAssertEqual(try SignInProofStore(keychain: f.keychain).load(alexHome),
                       SignInProfileProof(profileID: "default", token: "pin"))
        let result3 = await f.store.deactivateProfile(expectedAccount: account)
        XCTAssertTrue(result3)
        XCTAssertNil(try SignInProofStore(keychain: f.keychain).load(alexHome))

        await f.store.select(serverID: F.home, credential: .none, userID: nil)
        let noneAccountValue = await f.store.refreshAccountIdentity()
        let noneAccount = try XCTUnwrap(noneAccountValue)
        let activated = await f.store.activateProfile(profileID: "default", profileToken: nil, expectedAccount: noneAccount)
        XCTAssertFalse(activated, "no credential, no profile")
    }

    // MARK: - Other servers

    /// Approving a TV, sending servers, and push use the current user's
    /// sign-in on each server; with no current user there is none.
    func testOtherServerReadsResolveTheCurrentUsersSignIn() async throws {
        let (f, alex) = try await signedIn()
        try await add(f, "12", on: F.friend, url: F.friendURL, placement: .join(userID: alex.userID))
        let sam = try await add(f, "13", on: F.friend, url: F.friendURL, placement: .newUser)

        await f.store.setServerUrl(F.homeURL)
        await f.store.select(serverID: F.home, credential: .signIn(alexHome), userID: alex.userID)
        let alexBearer = await f.store.getAccessToken(for: F.friend)
        let alexSession = await f.store.inactiveServerSession(for: F.friend)
        let alexEpoch = await f.store.getOrCreateAccountEpoch(for: F.friend)
        XCTAssertEqual(alexBearer, "12-\(F.friend)-access")
        XCTAssertEqual(alexSession?.accountID, "12")
        XCTAssertEqual(alexEpoch, try f.signIn(alexFriend)?.epoch?.uuidString)

        await f.store.select(serverID: F.home, credential: .none, userID: sam.userID)
        let samBearer = await f.store.getAccessToken(for: F.friend)
        XCTAssertEqual(samBearer, "13-\(F.friend)-access")

        await f.store.select(serverID: F.home, credential: .none, userID: nil)
        let nobody = await f.store.getAccessToken(for: F.friend)
        let nobodySession = await f.store.inactiveServerSession(for: F.friend)
        XCTAssertNil(nobody)
        XCTAssertNil(nobodySession)
    }

    func testRenewingAnotherServersSignInWritesOnlyThatSignIn() async throws {
        let (f, alex) = try await signedIn()
        try await add(f, "12", on: F.friend, url: F.friendURL, placement: .join(userID: alex.userID))
        await f.store.setServerUrl(F.homeURL)
        await f.store.select(serverID: F.home, credential: .signIn(alexHome), userID: alex.userID)
        let storedValue = await f.store.inactiveServerSession(for: F.friend)
        let stored = try XCTUnwrap(storedValue)

        let saved = await f.store.saveInactiveServerRefresh(accessToken: "renewed", refreshToken: "renewed-refresh",
                                                            replacing: stored, for: F.friend)
        let stale = await f.store.saveInactiveServerRefresh(accessToken: "stale", refreshToken: "stale-refresh",
                                                            replacing: stored, for: F.friend)

        XCTAssertTrue(saved)
        XCTAssertFalse(stale, "the sign-in rotated meanwhile")
        let friend = try XCTUnwrap(try f.signIn(alexFriend))
        XCTAssertEqual(friend.accessToken, "renewed")
        XCTAssertEqual(friend.epoch, stored.epoch)
        let active = await f.store.getAccessToken()
        XCTAssertEqual(active, "alex-access")
    }

    // MARK: - Names and display cache

    func testRenameTrimsCapsAndClears() async throws {
        let (f, alex) = try await signedIn()
        let long = String(repeating: "a", count: 45)

        let result4 = await f.store.renameUser(alex.userID, to: "  Living Room  ")
        XCTAssertTrue(result4)
        XCTAssertEqual(try f.index()?.users.first?.displayName, "Living Room")
        let result5 = await f.store.renameUser(alex.userID, to: long)
        XCTAssertTrue(result5)
        XCTAssertEqual(try f.index()?.users.first?.displayName, String(repeating: "a", count: 40))
        let result6 = await f.store.renameUser(alex.userID, to: "   ")
        XCTAssertTrue(result6)
        XCTAssertNil(try f.index()?.users.first?.displayName)
        let result7 = await f.store.renameUser("nobody", to: "x")
        XCTAssertFalse(result7)
    }

    func testDisplayCacheUpdatesWithoutRewritingWhenUnchanged() async throws {
        let (f, _) = try await signedIn()
        let result8 = await f.store.updateSignInDisplay(alexHome, username: "alex", profiles: [jamie])
        XCTAssertTrue(result8)
        let writes = f.signIns.attemptedWrites.count

        let result9 = await f.store.updateSignInDisplay(alexHome, username: "alex", profiles: [jamie])
        XCTAssertTrue(result9)
        XCTAssertEqual(f.signIns.attemptedWrites.count, writes, "nothing changed, nothing written")

        // Token rotation still matches the item after a display update.
        let authValue = await f.store.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(authValue)
        let rotated = await f.store.saveRefreshedTokens("rotated", "rotated-refresh", replacing:
            CapturedRefreshCredential(account: auth.account, refreshToken: "alex-refresh", owner: auth.credentialOwner))
        XCTAssertTrue(rotated)
        XCTAssertEqual(try f.signIn(alexHome)?.profiles, [jamie])
    }

    func testAccountReadFillsTheUsernameAndRefusesAnotherAccount() async throws {
        let f = try F.make(self)
        try f.startUserModel()
        await f.activate(F.home, url: F.homeURL)
        try await f.install("12", access: "a", refresh: "r", placement: .newUser)
        let capturedValue = await f.store.captureOrdinaryRequestAuth()
        let captured = try XCTUnwrap(capturedValue)

        let filled = try await f.store.bindVerifiedAccount(.stub(id: "12", username: "alex"), expected: captured)
        let again = try await f.store.bindVerifiedAccount(.stub(id: "12", username: "alex"), expected: captured)

        XCTAssertEqual(filled, .usernameUpdated)
        XCTAssertEqual(again, .unchanged)
        XCTAssertEqual(try f.signIn(alexHome)?.username, "alex")
        do {
            try await f.store.bindVerifiedAccount(.stub(id: "99"), expected: captured)
            XCTFail("another account's answer was bound to alex's sign-in")
        } catch AccountSessionPersistenceError.invalidIdentity {}
    }

    func testDirectoryHasNoSecretsAndSkipsOrphans() async throws {
        let (f, _) = try await signedIn()
        try f.signIns.signInStore.saveSignIn(SavedSignIn(key: samHome, userID: "someone-else", origin: F.homeURL,
            accessToken: "x", refreshToken: "y", epoch: UUID(), addedAt: Date()))
        var index = try XCTUnwrap(try f.index())
        index.users[0].signIns.append(samHome)
        try f.signIns.signInStore.saveIndex(index)

        let directory = try await f.store.directory()

        XCTAssertEqual(Array(directory.signIns.keys), [alexHome], "an item naming another user is an orphan")
        XCTAssertEqual(directory.signIns[alexHome]?.username, "alex")

        let unmigrated = try F.make(self)
        do {
            _ = try await unmigrated.store.directory()
            XCTFail("a device without an index has no directory")
        } catch SavedSignInAccessError.notMigrated {}
    }
}

private extension SignInPlacement {
    var joinedUserID: String? {
        if case .join(let userID) = self { return userID }
        return nil
    }
}

/// `AuthService` saving a finished sign-in where its placement says (plan
/// §2.5): a new user, a sign-in joining a user, a refresh that revokes the
/// superseded session, a failed save that changes nothing, and before
/// migration the server's own session replaced as it always was. Which
/// placement a sign-in gets is `SiloUserCoordinatorTests`' subject.
final class SignInCommitTests: XCTestCase {
    private typealias F = SignInStoreFixture

    private func pending(_ f: F, _ accountID: String, access: String) async throws -> PendingSignIn {
        let identity = await f.store.refreshAccountIdentity()
        return PendingSignIn(accessToken: access, refreshToken: "\(access)-refresh",
                             account: SignInAccount(id: accountID, username: nil), expected: try XCTUnwrap(identity))
    }

    /// An `AuthService` on the fixture's store, preferences, and a stubbed
    /// network, so revocations go nowhere.
    private func auth(_ f: F) -> AuthService {
        let stub = APIv2TestStub()
        stub.reply(204, "")
        return AuthService(launchPreferences: ProfileLaunchPreferences(defaults: f.defaults),
                           httpClient: HTTPClient(session: stub.makeSession(), tokenStore: f.store),
                           tokenStore: f.store)
    }

    private func commit(_ f: F, _ accountID: String, access: String,
                        placement: SignInPlacement) async throws -> SignInInstallResult {
        try await auth(f).commitSignIn(pending(f, accountID, access: access), placement: placement)
    }

    private func device() async throws -> F {
        let f = try F.make(self)
        try f.startUserModel()
        await f.activate(F.home, url: F.homeURL)
        return f
    }

    func testFirstSignInCreatesTheUserAndANewServerJoinsIt() async throws {
        let f = try await device()
        let first = try await commit(f, "12", access: "home", placement: .newUser)
        let user = try XCTUnwrap(try f.index()?.users.first)

        await f.activate(F.friend, url: F.friendURL)
        let second = try await commit(f, "40", access: "friend", placement: .join(userID: user.id))

        XCTAssertNil(first.superseded)
        XCTAssertNil(second.superseded)
        let index = try XCTUnwrap(try f.index())
        XCTAssertEqual(index.users.count, 1)
        XCTAssertEqual(index.users.first?.signIns, [.make(F.home, "12"), .make(F.friend, "40")])
        XCTAssertEqual(index.users.first?.id, user.id)
    }

    func testSigningInAgainRefreshesAndRevokesTheOldSession() async throws {
        let f = try await device()
        _ = try await commit(f, "12", access: "first", placement: .newUser)

        let refreshed = try await commit(f, "12", access: "second", placement: .refresh(.make(F.home, "12")))

        XCTAssertEqual(refreshed.superseded, RevocableCredential(serverURL: F.homeURL, accessToken: "first",
                                                                refreshToken: "first-refresh"))
        XCTAssertEqual(try f.index()?.users.first?.signIns, [.make(F.home, "12")])
        let access = await f.store.getAccessToken()
        XCTAssertEqual(access, "second")
    }

    /// A sign-in that can't be saved changes nothing: the selected sign-in
    /// and its profile stay.
    func testFailedSaveKeepsThePreviousSignIn() async throws {
        let f = try await device()
        _ = try await commit(f, "12", access: "alex", placement: .newUser)
        await f.store.setProfileId("default")
        let index = try f.index()
        f.signIns.failingWrites = [SharedStorage.signInAccount(.make(F.home, "13"))]

        do {
            _ = try await commit(f, "13", access: "sam", placement: .newUser)
            XCTFail("reported success without saving")
        } catch AccountSessionPersistenceError.unavailable {}

        XCTAssertEqual(try f.index(), index)
        XCTAssertEqual(try f.signIn(.make(F.home, "12"))?.accessToken, "alex")
        let access = await f.store.getAccessToken()
        let profile = await f.store.getProfileId()
        XCTAssertEqual(access, "alex")
        XCTAssertEqual(profile, "default")
    }

    /// Before migration, sign-in replaces the server's own session exactly
    /// as it always has.
    func testBeforeMigrationTheServersSessionIsReplaced() async throws {
        let f = try F.make(self)
        try f.seedLegacySession(F.home, url: F.homeURL, accountID: "12", access: "old", refresh: "old-refresh")
        await f.activate(F.home, url: F.homeURL)

        try await auth(f).commitLegacySignIn(pending(f, "13", access: "new"))

        XCTAssertNil(try f.index())
        guard case .session(let value) = try f.sessions.sessions.load(F.home) else { return XCTFail() }
        XCTAssertEqual(value.accountID, "13")
        XCTAssertEqual(value.accessToken, "new")
    }
}
