import Foundation
import XCTest
@testable import Silo

/// The one-time move from one session per server to Silo users (plan §3).
/// It must never lose a working sign-in, never write after a read error,
/// never let an old per-server record come back once users exist, and be
/// safe to run on every launch.
final class SavedSignInMigrationTests: XCTestCase {
    private typealias F = SignInStoreFixture
    private let rawServer = ServerRegistry.serverId(for: "https://raw.example")
    private let signedOutServer = ServerRegistry.serverId(for: "https://gone.example")

    private var servers: [(id: String, url: String)] {
        [(F.home, F.homeURL), (F.friend, F.friendURL),
         (rawServer, "https://raw.example"), (signedOutServer, "https://gone.example")]
    }

    /// Home verified (it named its account), Friend unverified, Raw from
    /// before canonical records, Gone signed out.
    private func seedEveryKind(_ f: F, homeEpoch: UUID, friendEpoch: UUID = UUID()) throws {
        try f.seedLegacySession(F.home, url: F.homeURL, accountID: "12", access: "home-access",
                                refresh: "home-refresh", epoch: homeEpoch)
        try f.seedLegacySession(F.friend, url: F.friendURL, accountID: nil, access: "friend-access",
                                refresh: "friend-refresh", epoch: friendEpoch)
        let account = f.keychain.withAudience(.userIndependent)
        account.set("raw-access", for: SharedStorage.accessTokenAccount(for: rawServer))
        account.set("raw-refresh", for: SharedStorage.refreshTokenAccount(for: rawServer))
        XCTAssertTrue(f.sessions.sessions.invalidate(signedOutServer))
    }

    func testVerifiedServersBecomeSignInsAndUnverifiedOnesStayPending() async throws {
        let f = try F.make(self)
        let epoch = UUID()
        try seedEveryKind(f, homeEpoch: epoch)

        let outcome = await f.store.migrateLegacySessionsIfNeeded(servers: servers, activeServerID: F.home)

        XCTAssertEqual(outcome, .migrated)
        let index = try XCTUnwrap(try f.index())
        XCTAssertEqual(index.users.count, 1)
        let user = try XCTUnwrap(index.users.first)
        let home = SignInKey.make(F.home, "12")
        XCTAssertEqual(index.migratedUserID, user.id)
        XCTAssertEqual(user.signIns, [home])
        XCTAssertEqual(user.pendingLegacyServerIDs, [F.friend, rawServer])
        XCTAssertNil(user.displayName)
        XCTAssertEqual(index.legacyDataOwnerByServerID, [F.home: "12"])
        XCTAssertEqual(LegacyLocalDataOwner.accountID(forServerID: F.home), "12")

        let signIn = try XCTUnwrap(try f.signIn(home))
        XCTAssertEqual(signIn.userID, user.id)
        XCTAssertEqual(signIn.origin, F.homeURL)
        XCTAssertEqual(signIn.accessToken, "home-access")
        XCTAssertEqual(signIn.refreshToken, "home-refresh")
        XCTAssertEqual(signIn.epoch, epoch, "remembered profiles match by epoch, so migration keeps it")
        XCTAssertNil(signIn.username)
        XCTAssertEqual(signIn.profiles, [])
        XCTAssertEqual(signIn.adoptsLegacyLocalData, true)

        // The migrated server's old record is retired; pending ones keep working.
        guard case .signedOut = try f.sessions.sessions.load(F.home) else { return XCTFail("home not tombstoned") }
        XCTAssertNil(f.keychain.withAudience(.userIndependent).get(SharedStorage.accessTokenAccount(for: F.home)))
        guard case .session = try f.sessions.sessions.load(F.friend) else { return XCTFail("friend lost") }
        XCTAssertEqual(f.keychain.withAudience(.userIndependent).get(SharedStorage.accessTokenAccount(for: rawServer)),
                       "raw-access")

        await f.activate(F.home, url: F.homeURL)
        let homeSelection = await f.store.currentSelection()
        let homeAccess = await f.store.getAccessToken()
        let homeEpoch = await f.store.getOrCreateAccountEpoch()
        XCTAssertEqual(homeSelection, .signIn(home))
        XCTAssertEqual(homeAccess, "home-access")
        XCTAssertEqual(homeEpoch, epoch.uuidString)
        XCTAssertEqual(f.defaults.string(forKey: SharedStorage.activeAccountIdKey), "12")

        await f.activate(F.friend, url: F.friendURL)
        let friendSelection = await f.store.currentSelection()
        let friendAccess = await f.store.getAccessToken()
        XCTAssertEqual(friendSelection, .legacy(serverID: F.friend))
        XCTAssertEqual(friendAccess, "friend-access")
        XCTAssertNil(f.defaults.string(forKey: SharedStorage.activeAccountIdKey))
    }

    /// The order sign-ins were added isn't recorded, so the active server's
    /// is the oldest and names the user (spec §9).
    func testActiveServersSignInIsTheOldest() async throws {
        let f = try F.make(self)
        try f.seedLegacySession(F.home, url: F.homeURL, accountID: "12", access: "a", refresh: "r")
        try f.seedLegacySession(F.friend, url: F.friendURL, accountID: "40", access: "b", refresh: "s")

        _ = await f.store.migrateLegacySessionsIfNeeded(servers: servers, activeServerID: F.friend)

        let user = try XCTUnwrap(try f.index()?.users.first)
        XCTAssertEqual(user.signIns, [SignInKey.make(F.friend, "40"), SignInKey.make(F.home, "12")])
        let friend = try XCTUnwrap(try f.signIn(.make(F.friend, "40")))
        let home = try XCTUnwrap(try f.signIn(.make(F.home, "12")))
        XCTAssertLessThan(friend.addedAt, home.addedAt)
    }

    func testDeviceWithoutSignInsGetsAnEmptyIndexAndKeepsItsServers() async throws {
        let f = try F.make(self)
        XCTAssertTrue(f.sessions.sessions.invalidate(signedOutServer))

        let outcome = await f.store.migrateLegacySessionsIfNeeded(servers: servers, activeServerID: signedOutServer)

        XCTAssertEqual(outcome, .migrated)
        XCTAssertEqual(try f.index(), SiloUserIndex())
        let directory = try await f.store.directory()
        XCTAssertTrue(directory.users.isEmpty)
    }

    /// No servers is trusted only when the stored server list agrees. A list
    /// that failed to load looks empty too, and committing an empty index
    /// then would retire every per-server session for good.
    func testNoServersDefersWhileTheStoredListStillNamesSome() async throws {
        let f = try F.make(self)
        try f.seedLegacySession(F.home, url: F.homeURL, accountID: "12", access: "home-access", refresh: "r")
        let stored = #"{"activeServerId":"\#(F.home)","entries":[{"id":"\#(F.home)","url":"\#(F.homeURL)"}]}"#
        f.defaults.set(Data(stored.utf8), forKey: SharedStorage.serverRegistryDefaultsKey)

        let outcome = await f.store.migrateLegacySessionsIfNeeded(servers: [], activeServerID: nil)

        XCTAssertEqual(outcome, .deferred(.serverListUnreadable))
        XCTAssertNil(try f.index())
        guard case .session = try f.sessions.sessions.load(F.home) else { return XCTFail("old record touched") }
        // The list loads at the next launch, and the session moves then.
        let retried = await f.relaunched().migrateLegacySessionsIfNeeded(
            servers: [(F.home, F.homeURL)], activeServerID: F.home)
        XCTAssertEqual(retried, .migrated)
        XCTAssertEqual(try f.signIn(.make(F.home, "12"))?.accessToken, "home-access")

        // A new device with nothing stored, or a list emptied on purpose,
        // starts the user model at once.
        for list in [nil, #"{"entries":[]}"#] {
            let fresh = try F.make(self)
            if let list { fresh.defaults.set(Data(list.utf8), forKey: SharedStorage.serverRegistryDefaultsKey) }
            let empty = await fresh.store.migrateLegacySessionsIfNeeded(servers: [], activeServerID: nil)
            XCTAssertEqual(empty, .migrated)
            XCTAssertEqual(try fresh.index(), SiloUserIndex())
        }
    }

    /// A locked keychain is never mistaken for "no index" or "no session":
    /// nothing is written, and the old sessions keep working this launch.
    func testReadErrorsDeferWithoutWriting() async throws {
        let f = try F.make(self)
        try seedEveryKind(f, homeEpoch: UUID())
        let sessionsBefore = f.sessions.values

        f.signIns.failsAllReads = true
        var outcome = await f.store.migrateLegacySessionsIfNeeded(servers: servers, activeServerID: F.home)
        XCTAssertEqual(outcome, .deferred(.indexUnreadable))
        f.signIns.failsAllReads = false

        f.sessions.failingReads = [AccountSessionPersistence.recordKey(F.friend)]
        outcome = await f.store.migrateLegacySessionsIfNeeded(servers: servers, activeServerID: F.home)
        XCTAssertEqual(outcome, .deferred(.sessionUnreadable))
        f.sessions.failingReads = []

        XCTAssertTrue(f.signIns.attemptedWrites.isEmpty, "no partial index or sign-in")
        XCTAssertNil(try f.index())
        XCTAssertEqual(f.sessions.values, sessionsBefore)
        await f.activate(F.home, url: F.homeURL)
        let selection = await f.store.currentSelection()
        let access = await f.store.getAccessToken()
        XCTAssertEqual(selection, .legacy(serverID: F.home))
        XCTAssertEqual(access, "home-access")
    }

    /// A record whose bytes can't be decoded blocks its server today until
    /// the next sign-in; it isn't a working sign-in, so it doesn't hold up
    /// everyone else's migration.
    func testCorruptRecordIsNotCarriedOverAndDoesNotDeferMigration() async throws {
        let f = try F.make(self)
        try f.seedLegacySession(F.home, url: F.homeURL, accountID: "12", access: "a", refresh: "r")
        XCTAssertTrue(f.sessions.write("broken", AccountSessionPersistence.recordKey(F.friend)))

        let outcome = await f.store.migrateLegacySessionsIfNeeded(servers: servers, activeServerID: F.home)

        XCTAssertEqual(outcome, .migrated)
        let user = try XCTUnwrap(try f.index()?.users.first)
        XCTAssertEqual(user.signIns, [.make(F.home, "12")])
        XCTAssertNil(user.pendingLegacyServerIDs)
    }

    func testFailedWritesLeaveOldRecordsUsableAndRetrySucceeds() async throws {
        for failing in [SharedStorage.usersIndexAccount, SharedStorage.signInAccount(.make(F.home, "12"))] {
            let f = try F.make(self)
            let epoch = UUID()
            try seedEveryKind(f, homeEpoch: epoch)
            f.signIns.failingWrites = [failing]

            var outcome = await f.store.migrateLegacySessionsIfNeeded(servers: servers, activeServerID: F.home)

            XCTAssertEqual(outcome, .deferred(.writeFailed))
            XCTAssertNil(try f.index())
            guard case .session(let kept) = try f.sessions.sessions.load(F.home) else {
                return XCTFail("old record touched before the index was committed")
            }
            XCTAssertEqual(kept.accessToken, "home-access")
            let relaunched = f.relaunched()
            await f.activate(F.home, url: F.homeURL, in: relaunched)
            let access = await relaunched.getAccessToken()
            XCTAssertEqual(access, "home-access")

            f.signIns.failingWrites = []
            outcome = await relaunched.migrateLegacySessionsIfNeeded(servers: servers, activeServerID: F.home)
            XCTAssertEqual(outcome, .migrated)
            XCTAssertEqual(try f.index()?.users.count, 1)
            XCTAssertEqual(try f.signIn(.make(F.home, "12"))?.epoch, epoch)
        }
    }

    func testMigrationRunsOnce() async throws {
        let f = try F.make(self)
        try seedEveryKind(f, homeEpoch: UUID())
        let first = await f.store.migrateLegacySessionsIfNeeded(servers: servers, activeServerID: F.home)
        let index = try f.index()

        let second = await f.relaunched().migrateLegacySessionsIfNeeded(servers: servers, activeServerID: F.home)

        XCTAssertEqual(first, .migrated)
        XCTAssertEqual(second, .notNeeded)
        XCTAssertEqual(try f.index(), index)
    }

    /// Invariant 4: once the index exists, a migrated server's old record
    /// is never read, even when the process died before cleaning it up, and
    /// the next migration call cleans it up. An empty index is a valid state.
    func testOldRecordsNeverComeBackOnceTheIndexExists() async throws {
        let f = try F.make(self)
        let home = SignInKey.make(F.home, "12")
        let epoch = UUID()
        try f.seedLegacySession(F.home, url: F.homeURL, accountID: "12", access: "stale-access",
                                refresh: "stale-refresh", epoch: epoch)
        // Killed between the index commit and cleanup (plan §3.5).
        try f.signIns.signInStore.saveSignIn(SavedSignIn(key: home, userID: "u", origin: F.homeURL,
            accessToken: "current-access", refreshToken: "current-refresh", epoch: epoch, addedAt: Date()))
        try f.signIns.signInStore.saveIndex(SiloUserIndex(
            users: [SiloUser(id: "u", createdAt: Date(), signIns: [home])],
            migratedUserID: "u", legacyDataOwnerByServerID: [F.home: "12"]))

        await f.activate(F.home, url: F.homeURL)
        let access = await f.store.getAccessToken()
        XCTAssertEqual(access, "current-access")

        let outcome = await f.store.migrateLegacySessionsIfNeeded(servers: servers, activeServerID: F.home)
        XCTAssertEqual(outcome, .notNeeded)
        guard case .signedOut = try f.sessions.sessions.load(F.home) else { return XCTFail("cleanup not retried") }
        XCTAssertNil(f.keychain.withAudience(.userIndependent).get(SharedStorage.accessTokenAccount(for: F.home)))

        // With no users at all, a leftover record still stays out.
        let empty = try F.make(self)
        try empty.seedLegacySession(F.home, url: F.homeURL, accountID: "12", access: "stale", refresh: "r")
        try empty.startUserModel()
        await empty.activate(F.home, url: F.homeURL)
        let none = await empty.store.getAccessToken()
        let selection = await empty.store.currentSelection()
        XCTAssertNil(none)
        XCTAssertEqual(selection, .none)
    }

    /// A selection made before migration (a background launch) is moved to
    /// the sign-in, since its old record is now a tombstone.
    func testMigrationMovesAnEarlierLegacySelectionToTheSignIn() async throws {
        let f = try F.make(self)
        try f.seedLegacySession(F.home, url: F.homeURL, accountID: "12", access: "home-access", refresh: "r")
        await f.activate(F.home, url: F.homeURL)
        let before = await f.store.currentSelection()
        XCTAssertEqual(before, .legacy(serverID: F.home))

        _ = await f.store.migrateLegacySessionsIfNeeded(servers: servers, activeServerID: F.home)

        let after = await f.store.currentSelection()
        let access = await f.store.getAccessToken()
        XCTAssertEqual(after, .signIn(.make(F.home, "12")))
        XCTAssertEqual(access, "home-access")
    }

    /// An earlier selection of a server that had no working sign-in names a
    /// slot no user lists either, so it is dropped as well: here a stray
    /// refresh token that must never be spent once users exist.
    func testMigrationDropsAnEarlierSelectionOfAServerWithoutASignIn() async throws {
        let f = try F.make(self)
        f.keychain.withAudience(.userIndependent).set("stray-refresh",
                                                      for: SharedStorage.refreshTokenAccount(for: rawServer))
        await f.activate(rawServer, url: "https://raw.example")
        let before = await f.store.currentSelection()
        let strayBefore = await f.store.getRefreshToken()
        XCTAssertEqual(before, .legacy(serverID: rawServer))
        XCTAssertEqual(strayBefore, "stray-refresh")

        let outcome = await f.store.migrateLegacySessionsIfNeeded(servers: servers, activeServerID: rawServer)

        XCTAssertEqual(outcome, .migrated)
        XCTAssertEqual(try f.index(), SiloUserIndex())
        let after = await f.store.currentSelection()
        let stray = await f.store.getRefreshToken()
        XCTAssertEqual(after, .none)
        XCTAssertNil(stray)
    }

    // MARK: - Servers signed out at migration

    /// Adds `accountID`'s sign-in on `server` for `placement`, as the sign-in
    /// screen does.
    @discardableResult
    private func signIn(_ f: F, _ accountID: String, on server: String, url: String,
                        placement: SignInPlacement) async throws -> SignInInstallResult {
        var joined: String?
        if case .join(let userID) = placement { joined = userID }
        await f.store.setServerUrl(url)
        await f.store.select(serverID: server, credential: .none, userID: joined)
        return try await f.install(accountID, access: "\(accountID)-access", refresh: "\(accountID)-refresh",
                                   placement: placement)
    }

    /// A server whose session had ended by the update gets no owner at
    /// migration. The migrated user's next sign-in there takes its old local
    /// data over, as signing in again always brought it back; a sign-in by
    /// another user first takes nothing, and nothing after it does either.
    func testTheMigratedUsersNextSignInOnASignedOutServerTakesOverItsOldData() async throws {
        for anotherUserFirst in [false, true] {
            let f = try F.make(self)
            try f.seedLegacySession(F.home, url: F.homeURL, accountID: "12", access: "home-access",
                                    refresh: "home-refresh")
            XCTAssertTrue(f.sessions.sessions.invalidate(F.friend))
            _ = await f.store.migrateLegacySessionsIfNeeded(
                servers: [(F.home, F.homeURL), (F.friend, F.friendURL)], activeServerID: F.home)
            let migrated = try XCTUnwrap(try f.index()?.migratedUserID)
            XCTAssertNil(try f.index()?.legacyDataOwnerByServerID?[F.friend])

            if anotherUserFirst {
                try await signIn(f, "13", on: F.friend, url: F.friendURL, placement: .newUser)
                XCTAssertNil(try f.index()?.legacyDataOwnerByServerID?[F.friend], "another user's account")
            }
            try await signIn(f, "40", on: F.friend, url: F.friendURL, placement: .join(userID: migrated))

            let owner = try f.index()?.legacyDataOwnerByServerID?[F.friend]
            XCTAssertEqual(owner, anotherUserFirst ? nil : "40")
            XCTAssertEqual(LegacyLocalDataOwner.accountID(forServerID: F.friend), owner)
            XCTAssertEqual(try f.index()?.legacyDataOwnerByServerID?[F.home], "12", "Home's owner stays")
        }
    }

    /// With every session ended by the update, the device's only user takes
    /// over each server's old data as it signs in there again; a second user
    /// doesn't, and neither does anyone on a server still pending.
    func testTheOnlyUsersSignInsTakeOverOldDataAndOtherUsersDont() async throws {
        let f = try F.make(self)
        try f.startUserModel()
        let alex = try await signIn(f, "12", on: F.home, url: F.homeURL, placement: .newUser)
        XCTAssertEqual(try f.index()?.legacyDataOwnerByServerID, [F.home: "12"])
        try await signIn(f, "13", on: F.friend, url: F.friendURL, placement: .newUser)
        XCTAssertEqual(try f.index()?.legacyDataOwnerByServerID, [F.home: "12"], "a second user takes nothing")
        XCTAssertNotEqual(alex.userID, try f.index()?.users.last?.id)

        let pending = try F.make(self)
        try pending.seedLegacySession(F.friend, url: F.friendURL, accountID: nil, access: "friend-access",
                                      refresh: "friend-refresh")
        _ = await pending.store.migrateLegacySessionsIfNeeded(servers: [(F.friend, F.friendURL)],
                                                              activeServerID: F.friend)
        let user = try XCTUnwrap(try pending.index()?.users.first)
        XCTAssertEqual(user.pendingLegacyServerIDs, [F.friend])
        try await signIn(pending, "40", on: F.friend, url: F.friendURL, placement: .newUser)
        XCTAssertNil(try pending.index()?.legacyDataOwnerByServerID?[F.friend],
                     "the pending session's account owns it once known")
    }

    // MARK: - Pending legacy servers (plan §3.3)

    func testFirstAccountReadMovesAPendingServerIntoItsUser() async throws {
        let f = try F.make(self)
        let epoch = UUID()
        try seedEveryKind(f, homeEpoch: UUID(), friendEpoch: epoch)
        f.keychain.withAudience(.currentUser).set("pin-proof", for: SharedStorage.profileTokenAccount(for: F.friend))
        _ = await f.store.migrateLegacySessionsIfNeeded(servers: servers, activeServerID: F.home)
        let userID = try XCTUnwrap(try f.index()?.users.first?.id)
        await f.activate(F.friend, url: F.friendURL)
        await f.store.setProfileId("default")
        let capturedValue = await f.store.captureOrdinaryRequestAuth()
        let captured = try XCTUnwrap(capturedValue)

        let outcome = try await f.store.bindVerifiedAccount(.stub(id: "34", username: "sam"), expected: captured)

        let key = SignInKey.make(F.friend, "34")
        XCTAssertEqual(outcome, .legacyMigrated(key))
        let user = try XCTUnwrap(try f.index()?.users.first)
        XCTAssertEqual(user.id, userID)
        XCTAssertEqual(user.signIns, [.make(F.home, "12"), key])
        XCTAssertEqual(user.pendingLegacyServerIDs, [rawServer])
        XCTAssertEqual(try f.index()?.legacyDataOwnerByServerID?[F.friend], "34")
        let signIn = try XCTUnwrap(try f.signIn(key))
        XCTAssertEqual(signIn.epoch, epoch)
        XCTAssertEqual(signIn.username, "sam")
        XCTAssertEqual(signIn.adoptsLegacyLocalData, true)
        guard case .signedOut = try f.sessions.sessions.load(F.friend) else { return XCTFail("old record kept") }

        // The same credential, so requests in flight keep their identity.
        let after = await f.store.captureOrdinaryRequestAuth()
        XCTAssertEqual(after, captured)
        let selection = await f.store.currentSelection()
        XCTAssertEqual(selection, .signIn(key))
        XCTAssertEqual(f.defaults.string(forKey: SharedStorage.activeAccountIdKey), "34")
        // This Apple TV user's proof moved to the sign-in.
        XCTAssertEqual(try SignInProofStore(keychain: f.keychain).load(key), SignInProfileProof(profileID: nil, token: "pin-proof"))
        XCTAssertNil(f.keychain.withAudience(.currentUser).get(SharedStorage.profileTokenAccount(for: F.friend)))
        let durable = await f.store.captureDurableAccountAuth()
        XCTAssertEqual(durable?.accountID, "34")
        XCTAssertEqual(durable?.accountEpoch, epoch)
    }

    /// Someone saved the pending server's account in another user meanwhile:
    /// that sign-in stays, the legacy session goes (not revoked: they may
    /// share it), and a user left empty is removed.
    func testPendingServerWhoseAccountIsAlreadySavedIsDropped() async throws {
        let f = try F.make(self)
        let existing = SignInKey.make(F.friend, "34")
        try f.seedLegacySession(F.friend, url: F.friendURL, accountID: nil, access: "legacy-access", refresh: "r")
        try f.signIns.signInStore.saveSignIn(SavedSignIn(key: existing, userID: "other", origin: F.friendURL,
            accessToken: "saved-access", refreshToken: "saved-refresh", epoch: UUID(), addedAt: Date()))
        try f.signIns.signInStore.saveIndex(SiloUserIndex(
            users: [SiloUser(id: "migrated", createdAt: Date(), signIns: [], pendingLegacyServerIDs: [F.friend]),
                    SiloUser(id: "other", createdAt: Date(), signIns: [existing])],
            migratedUserID: "migrated"))
        await f.store.setServerUrl(F.friendURL)
        await f.store.select(serverID: F.friend, credential: .legacy(serverID: F.friend), userID: "migrated")
        let capturedValue = await f.store.captureOrdinaryRequestAuth()
        let captured = try XCTUnwrap(capturedValue)

        let outcome = try await f.store.bindVerifiedAccount(.stub(id: "34"), expected: captured)

        XCTAssertEqual(outcome, .legacyDuplicate(existing: existing))
        let index = try XCTUnwrap(try f.index())
        XCTAssertEqual(index.users.map(\.id), ["other"])
        XCTAssertEqual(try f.signIn(existing)?.accessToken, "saved-access")
        guard case .signedOut = try f.sessions.sessions.load(F.friend) else { return XCTFail("legacy kept") }
        let selection = await f.store.currentSelection()
        let user = await f.store.currentUserID()
        let access = await f.store.getAccessToken()
        XCTAssertEqual(selection, .none)
        XCTAssertNil(user)
        XCTAssertNil(access)
    }

    /// A pending server whose move fails stays pending and keeps working
    /// through its old session; the next account read retries.
    func testFailedBindingKeepsTheServerPendingAndWorking() async throws {
        let f = try F.make(self)
        try seedEveryKind(f, homeEpoch: UUID())
        _ = await f.store.migrateLegacySessionsIfNeeded(servers: servers, activeServerID: F.home)
        await f.activate(F.friend, url: F.friendURL)
        let capturedValue = await f.store.captureOrdinaryRequestAuth()
        let captured = try XCTUnwrap(capturedValue)
        f.signIns.failingWrites = [SharedStorage.usersIndexAccount]

        let outcome = try await f.store.bindVerifiedAccount(.stub(id: "34"), expected: captured)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(try f.index()?.users.first?.pendingLegacyServerIDs, [F.friend, rawServer])
        let selection = await f.store.currentSelection()
        let access = await f.store.getAccessToken()
        XCTAssertEqual(selection, .legacy(serverID: F.friend))
        XCTAssertEqual(access, "friend-access")
        guard case .session = try f.sessions.sessions.load(F.friend) else { return XCTFail("old record lost") }

        f.signIns.failingWrites = []
        let retried = try await f.store.bindVerifiedAccount(.stub(id: "34"), expected: captured)
        XCTAssertEqual(retried, .legacyMigrated(.make(F.friend, "34")))
    }

    /// Before migration, an account read binds the server's own record as it
    /// always has, so the next launch migrates it as verified.
    func testAccountReadBeforeMigrationBindsTheServersRecord() async throws {
        let f = try F.make(self)
        try f.seedLegacySession(F.home, url: F.homeURL, accountID: nil, access: "a", refresh: "r")
        await f.activate(F.home, url: F.homeURL)
        let capturedValue = await f.store.captureOrdinaryRequestAuth()
        let captured = try XCTUnwrap(capturedValue)

        let outcome = try await f.store.bindVerifiedAccount(.stub(id: "12"), expected: captured)

        XCTAssertEqual(outcome, .unchanged)
        guard case .session(let bound) = try f.sessions.sessions.load(F.home) else { return XCTFail() }
        XCTAssertEqual(bound.accountID, "12")
        XCTAssertNil(try f.index())
    }
}
