import Foundation
import XCTest
@testable import Silo

/// `HTTPClient.revoke(_:)`: the server ends a session only for a valid
/// access token, so a sign-in idle past its token's lifetime is refreshed
/// once, in memory, before logging out. Nothing it learns is stored outside
/// the pending-revocation queue, and local sign-out never waits for it. A
/// logout that doesn't get through is tried again, then queued for the next
/// launch or return to the foreground.
final class SignInRevocationTests: XCTestCase {
    private typealias F = SignInStoreFixture
    private static let logout = "/api/v2/auth/logout"
    private let credential = RevocableCredential(serverURL: F.homeURL, accessToken: "old-access",
                                                 refreshToken: "old-refresh")
    /// Three tries with no wait between them.
    private static let quickRetries = HTTPClient.RevocationPolicy(attempts: 3, timeout: 5, backoff: [.zero])

    private func client(_ stub: APIv2TestStub, store: TokenStore? = nil) throws -> HTTPClient {
        HTTPClient(session: stub.makeSession(), tokenStore: try store ?? F.make(self).store,
                   revocationPolicy: Self.quickRetries)
    }

    private static func refreshed(_ access: String) -> String {
        #"{"access_token":"\#(access)","refresh_token":"fresh-refresh","expires_in":3600}"#
    }

    func testLogsOutWithTheSessionsAccessToken() async throws {
        let stub = APIv2TestStub()
        stub.reply(204, "")

        try await client(stub).revoke(credential)

        XCTAssertEqual(stub.requestedPaths, [Self.logout])
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url?.host, "home.example")
        XCTAssertEqual(request.header("Authorization"), "Bearer old-access")
        XCTAssertNil(request.header("X-Profile-Id"))
    }

    func testUnauthorizedLogoutRefreshesThenLogsOutOnce() async throws {
        let stub = APIv2TestStub()
        stub.sequence(path: Self.logout, [.json(401, "{}"), .json(204, "")])
        stub.reply(path: HTTPClient.refreshPath, 200, Self.refreshed("fresh-access"))

        try await client(stub).revoke(credential)

        XCTAssertEqual(stub.requestedPaths, [Self.logout, HTTPClient.refreshPath, Self.logout])
        let refresh = stub.requests[1]
        XCTAssertNil(refresh.header("Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(refresh.body)) as? [String: String])
        XCTAssertEqual(body, ["refresh_token": "old-refresh"])
        XCTAssertEqual(stub.requests[2].header("Authorization"), "Bearer fresh-access")
    }

    /// The refreshed pair exists only for the retry: the store's selected
    /// sign-in and every saved item stay exactly as they were.
    func testRefreshedTokensAreNeverStored() async throws {
        let f = try F.make(self)
        try f.startAccountModel()
        await f.activate(F.home, url: F.homeURL)
        try await f.install("13", access: "current-access", refresh: "current-refresh")
        let items = f.signIns.values
        let sessions = f.sessions.values
        let stub = APIv2TestStub()
        stub.sequence(path: Self.logout, [.json(401, "{}"), .json(204, "")])
        stub.reply(path: HTTPClient.refreshPath, 200, Self.refreshed("fresh-access"))

        try await client(stub, store: f.store).revoke(credential)

        XCTAssertEqual(f.signIns.values, items)
        XCTAssertEqual(f.sessions.values, sessions)
        XCTAssertFalse(f.signIns.values.values.contains { $0.contains("fresh-access") })
        let access = await f.store.getAccessToken()
        let refresh = await f.store.getRefreshToken()
        XCTAssertEqual(access, "current-access")
        XCTAssertEqual(refresh, "current-refresh")
        XCTAssertNotEqual(f.keychain.withAudience(.userIndependent).get(SharedStorage.mirroredAccessTokenAccount),
                          "fresh-access")
    }

    /// A session the server already treats as invalid is done after one
    /// try: a refused refresh, a logout refused again after a refresh, 404,
    /// or a 401 with nothing to refresh with. Nothing is queued.
    func testASessionTheServerAlreadyRejectsIsDone() async throws {
        func revoke(_ stub: APIv2TestStub, _ credential: RevocableCredential? = nil) async throws -> TokenStore {
            let store = try F.make(self).store
            try await client(stub, store: store).revoke(credential ?? self.credential)
            return store
        }
        var stub = APIv2TestStub()
        stub.reply(path: Self.logout, 401, "{}")
        stub.reply(path: HTTPClient.refreshPath, 401, "{}")
        var store = try await revoke(stub)
        XCTAssertEqual(stub.requestedPaths, [Self.logout, HTTPClient.refreshPath])
        XCTAssertEqual(try store.pendingRevocations.load(), [])

        stub = APIv2TestStub()
        stub.reply(path: Self.logout, 401, "{}")
        stub.reply(path: HTTPClient.refreshPath, 200, Self.refreshed("fresh-access"))
        store = try await revoke(stub)
        XCTAssertEqual(stub.requestedPaths, [Self.logout, HTTPClient.refreshPath, Self.logout])
        XCTAssertEqual(try store.pendingRevocations.load(), [])

        stub = APIv2TestStub()
        stub.reply(path: Self.logout, 404, "{}")
        store = try await revoke(stub)
        XCTAssertEqual(stub.requestedPaths, [Self.logout])
        XCTAssertEqual(try store.pendingRevocations.load(), [])

        stub = APIv2TestStub()
        stub.reply(path: Self.logout, 401, "{}")
        store = try await revoke(stub, RevocableCredential(serverURL: F.homeURL, accessToken: "a", refreshToken: nil))
        XCTAssertEqual(stub.requestedPaths, [Self.logout])
        XCTAssertEqual(try store.pendingRevocations.load(), [])
    }

    /// No answer or a server fault tries again, without refreshing (it isn't
    /// a stale token), until the logout gets through.
    func testAFailedLogoutIsTriedAgainUntilItGetsThrough() async throws {
        let f = try F.make(self)
        let stub = APIv2TestStub()
        stub.sequence(path: Self.logout, [.failure(URLError(.timedOut)), .json(503, "{}"), .json(204, "")])

        try await client(stub, store: f.store).revoke(credential)

        XCTAssertEqual(stub.requestedPaths, [Self.logout, Self.logout, Self.logout])
        XCTAssertTrue(stub.requests.allSatisfy { $0.header("Authorization") == "Bearer old-access" })
        XCTAssertEqual(try f.store.pendingRevocations.load(), [])
    }

    /// A session still live after every try is queued in the
    /// user-independent keychain, where a relaunched store finds it.
    func testASessionStillLiveAfterEveryTryIsQueuedForTheNextLaunch() async throws {
        let f = try F.make(self)
        let stub = APIv2TestStub()
        stub.fail(.timedOut)

        try await client(stub, store: f.store).revoke(credential)

        XCTAssertEqual(stub.requestedPaths, [Self.logout, Self.logout, Self.logout])
        let relaunched = f.relaunched()
        let queued = try relaunched.pendingRevocations.load()
        XCTAssertEqual(queued.map(\.credential), [credential])
        XCTAssertNotNil(f.keychain.withAudience(.userIndependent).get(PendingRevocationStore.account),
                        "shared by every Apple TV user, like the sign-ins")
    }

    /// The session is queued before the first try, so a revocation cut short
    /// (the app quit during the retries) is finished at the next launch. The
    /// retry pass leaves a session still being tried to its revocation.
    func testASessionIsQueuedWhileItsRevocationRuns() async throws {
        let f = try F.make(self)
        let stub = APIv2TestStub()
        stub.reply(204, "")
        stub.hold(path: Self.logout)
        defer { stub.release() }
        let http = try client(stub, store: f.store)
        let credential = credential
        let revocation = Task { await http.revoke(credential) }
        await stub.waitUntilHeld()

        XCTAssertEqual(try f.relaunched().pendingRevocations.load().map(\.credential), [credential])
        await http.retryPendingRevocations()
        XCTAssertEqual(stub.requestedPaths, [Self.logout], "left to the revocation trying it")

        stub.release()
        await revocation.value
        XCTAssertEqual(try f.store.pendingRevocations.load(), [])
    }

    /// A refresh made to revoke replaces the queued tokens (the old refresh
    /// token is spent) and reaches nothing else.
    func testRefreshedTokensAreKeptOnlyInTheQueueEntry() async throws {
        let f = try F.make(self)
        try f.startAccountModel()
        await f.activate(F.home, url: F.homeURL)
        try await f.install("13", access: "current-access", refresh: "current-refresh")
        let items = f.signIns.values
        let sessions = f.sessions.values
        let stub = APIv2TestStub()
        stub.sequence(path: Self.logout, [.json(401, "{}")])
        stub.reply(path: Self.logout, 503, "{}")
        stub.reply(path: HTTPClient.refreshPath, 200, Self.refreshed("fresh-access"))

        try await client(stub, store: f.store).revoke(credential)

        XCTAssertEqual(stub.requestedPaths, [Self.logout, HTTPClient.refreshPath, Self.logout, Self.logout, Self.logout])
        XCTAssertEqual(try f.store.pendingRevocations.load().map(\.credential),
                       [RevocableCredential(serverURL: F.homeURL, accessToken: "fresh-access", refreshToken: "fresh-refresh")])
        XCTAssertEqual(f.signIns.values, items)
        XCTAssertEqual(f.sessions.values, sessions)
        let access = await f.store.getAccessToken()
        XCTAssertEqual(access, "current-access")
    }

    /// The retry at launch and on return to the foreground: ended and
    /// already-invalid sessions leave the queue, the rest stay for next time.
    func testQueuedRevocationsAreRetriedOnActivation() async throws {
        let f = try F.make(self)
        let now = Date()
        let ended = PendingRevocation(RevocableCredential(serverURL: F.homeURL, accessToken: "ended", refreshToken: "r"),
                                      queuedAt: now.addingTimeInterval(-30))
        let gone = PendingRevocation(RevocableCredential(serverURL: F.friendURL, accessToken: "gone", refreshToken: "r"),
                                     queuedAt: now.addingTimeInterval(-20))
        let unreachable = PendingRevocation(RevocableCredential(serverURL: F.homeURL, accessToken: "down",
                                                                refreshToken: "r"),
                                            queuedAt: now.addingTimeInterval(-10))
        XCTAssertTrue(f.store.pendingRevocations.save([ended, gone, unreachable]))
        let stub = APIv2TestStub()
        stub.sequence(path: Self.logout, [.json(204, ""), .json(404, "{}"), .failure(URLError(.timedOut))])
        let http = try client(stub, store: f.store)

        await http.retryPendingRevocations()

        XCTAssertEqual(stub.requests.map { $0.header("Authorization") }, ["Bearer ended", "Bearer gone", "Bearer down"])
        XCTAssertEqual(stub.requests[1].url?.host, "friend.example", "each at its own server")
        XCTAssertEqual(try f.store.pendingRevocations.load().map(\.id), [unreachable.id])

        stub.reply(204, "")
        await http.retryPendingRevocations()
        XCTAssertEqual(try f.store.pendingRevocations.load(), [])
        XCTAssertNil(f.keychain.withAudience(.userIndependent).get(PendingRevocationStore.account))
    }

    /// The queue can't grow forever: past 30 days an entry drops, and past
    /// twenty the oldest go.
    func testThePendingQueueIsBoundedByAgeAndCount() throws {
        let memory = CredentialItemMemory()
        let store = PendingRevocationStore(read: { try memory.read("queue") },
                                           write: { memory.write($0, "queue") },
                                           remove: { memory.remove("queue") })
        let now = Date()
        let stale = PendingRevocation(RevocableCredential(serverURL: F.homeURL, accessToken: "stale", refreshToken: nil),
                                      queuedAt: now.addingTimeInterval(-PendingRevocationStore.maxAge - 1))
        let recent = (0..<25).map {
            PendingRevocation(RevocableCredential(serverURL: F.homeURL, accessToken: "a\($0)", refreshToken: nil),
                              queuedAt: now.addingTimeInterval(TimeInterval($0) - 100))
        }

        XCTAssertTrue(store.save([stale] + recent, now: now))

        let loaded = try store.load(now: now)
        XCTAssertEqual(loaded.count, PendingRevocationStore.maxCount)
        XCTAssertEqual(loaded.map(\.accessToken), (5..<25).map { "a\($0)" }, "the newest, oldest first")
        XCTAssertEqual(try store.load(now: now.addingTimeInterval(PendingRevocationStore.maxAge)), [])
        XCTAssertNil(memory.values["queue"], "an expired queue leaves the keychain")

        // A keychain that can't be read is never taken for an empty queue.
        XCTAssertTrue(store.save(recent, now: now))
        memory.failsAllReads = true
        XCTAssertThrowsError(try store.load(now: now))
    }

    /// Sign-out ends the sign-in locally first and returns without waiting;
    /// the logout that follows carries the session it ended. The account
    /// stays, to sign in again.
    @MainActor
    func testSignOutRevokesAfterTheSignInIsGone() async throws {
        let f = try F.make(self)
        try f.startAccountModel()
        f.defaults.set(true, forKey: ServerRegistry.migratedKey)
        let stub = APIv2TestStub()
        stub.reply(204, "")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: f.store)
        let preferences = ProfileLaunchPreferences(defaults: f.defaults)
        let registry = ServerRegistry(defaults: f.defaults, keychain: f.keychain, launchPreferences: preferences,
                                      tokenStore: f.store, httpClient: http, unregisterPush: { _ in })
        XCTAssertNotNil(registry.addOrUpdate(ServerEntry(id: F.home, url: F.homeURL, fetchedName: "Home",
                                                         lastUsedAt: Date())))
        let switched = await registry.switchTo(serverId: F.home, launchSelectionFrom: f.store)
        XCTAssertTrue(switched)
        try await f.install("12", access: "alex-access", refresh: "alex-refresh")
        let auth = AuthService(serverRegistry: registry, launchPreferences: preferences, httpClient: http,
                               tokenStore: f.store, sessionPersistence: f.sessions.sessions,
                               purgeDiagnostics: { _ in true }, unregisterPush: { _ in })
        XCTAssertTrue(auth.isLoggedIn)
        XCTAssertEqual(auth.accountID, "12")
        stub.hold(path: Self.logout)
        defer { stub.release() }

        let outcome = await auth.signOutWithOutcome()

        XCTAssertEqual(outcome, .completed)
        await stub.waitUntilHeld()
        XCTAssertEqual(try f.signIn(.make(F.home, "12"))?.isSignedIn, false,
                       "signed out before the server heard about it")
        XCTAssertEqual(try f.index()?.accounts, [.signIn(.make(F.home, "12"))])
        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertNil(auth.accountID)
        XCTAssertEqual(stub.requests.first?.header("Authorization"), "Bearer alex-access")
    }

    /// Removing a server removes every account on it and revokes each session.
    @MainActor
    func testRemovingAServerRevokesEveryAccountsSession() async throws {
        let f = try F.make(self)
        try f.startAccountModel()
        f.defaults.set(true, forKey: ServerRegistry.migratedKey)
        let stub = APIv2TestStub()
        stub.reply(204, "")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: f.store)
        let registry = ServerRegistry(defaults: f.defaults, keychain: f.keychain,
                                      launchPreferences: ProfileLaunchPreferences(defaults: f.defaults),
                                      tokenStore: f.store, httpClient: http, unregisterPush: { _ in })
        XCTAssertNotNil(registry.addOrUpdate(ServerEntry(id: F.home, url: F.homeURL, fetchedName: nil,
                                                         lastUsedAt: Date())))
        let switched = await registry.switchTo(serverId: F.home, launchSelectionFrom: f.store)
        XCTAssertTrue(switched)
        try await f.install("12", access: "alex-access", refresh: "r")
        await f.store.select(serverID: F.home, credential: .none)
        try await f.install("13", access: "sam-access", refresh: "r")

        let removed = await registry.remove(serverId: F.home)

        XCTAssertTrue(removed)
        XCTAssertEqual(try f.index()?.accounts, [])
        try await waitUntil { stub.requestedPaths.count == 2 }
        XCTAssertEqual(Set(stub.requests.compactMap { $0.header("Authorization") }),
                       ["Bearer alex-access", "Bearer sam-access"])
    }

    /// A server's own session from before canonical records names no
    /// address. Removing that server while it is active first points the
    /// active-URL mirror at the fallback server; the revocation still goes
    /// only to the removed server's own address.
    @MainActor
    func testRemovingTheActiveServerRevokesItsOldSessionAtItsOwnAddress() async throws {
        let f = try F.make(self)
        f.defaults.set(true, forKey: ServerRegistry.migratedKey)
        let account = f.keychain.withAudience(.userIndependent)
        account.set("raw-access", for: SharedStorage.accessTokenAccount(for: F.home))
        account.set("raw-refresh", for: SharedStorage.refreshTokenAccount(for: F.home))
        let stub = APIv2TestStub()
        stub.reply(204, "")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: f.store)
        let registry = ServerRegistry(defaults: f.defaults, keychain: f.keychain,
                                      launchPreferences: ProfileLaunchPreferences(defaults: f.defaults),
                                      tokenStore: f.store, httpClient: http, unregisterPush: { _ in })
        XCTAssertNotNil(registry.addOrUpdate(ServerEntry(id: F.friend, url: F.friendURL, fetchedName: nil,
                                                         lastUsedAt: .distantPast)))
        XCTAssertNotNil(registry.addOrUpdate(ServerEntry(id: F.home, url: F.homeURL, fetchedName: nil,
                                                         lastUsedAt: Date())))
        _ = await f.store.migrateLegacySessionsIfNeeded(
            servers: registry.entries.map { (id: $0.id, url: $0.url) }, activeServerID: F.home)
        let switched = await registry.switchTo(serverId: F.home, launchSelectionFrom: f.store)
        XCTAssertTrue(switched)
        let selection = await f.store.currentSelection()
        XCTAssertEqual(selection, .legacy(serverID: F.home), "a pending server on its old per-server slot")

        let removed = await registry.remove(serverId: F.home)

        XCTAssertTrue(removed)
        XCTAssertEqual(registry.activeServerId, F.friend)
        try await waitUntil { stub.requests.contains { $0.path == Self.logout } }
        let logouts = stub.requests.filter { $0.path == Self.logout }
        XCTAssertEqual(logouts.map { $0.url?.host }, ["home.example"])
        XCTAssertEqual(logouts.first?.header("Authorization"), "Bearer raw-access")
    }

    /// A removal that can't be made durable keeps the server and revokes
    /// nothing. The token store may already have dropped the selected
    /// sign-in, so the account mirror follows the store rather than naming
    /// an account nothing serves.
    @MainActor
    func testFailedServerRemovalRevokesNothingAndKeepsTheMirrorWithTheStore() async throws {
        let f = try F.make(self)
        try f.startAccountModel()
        f.defaults.set(true, forKey: ServerRegistry.migratedKey)
        let stub = APIv2TestStub()
        stub.reply(204, "")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: f.store)
        let registry = ServerRegistry(defaults: f.defaults, keychain: f.keychain,
                                      launchPreferences: ProfileLaunchPreferences(defaults: f.defaults),
                                      tokenStore: f.store, httpClient: http, unregisterPush: { _ in })
        XCTAssertNotNil(registry.addOrUpdate(ServerEntry(id: F.home, url: F.homeURL, fetchedName: nil,
                                                         lastUsedAt: Date())))
        let switched = await registry.switchTo(serverId: F.home, launchSelectionFrom: f.store)
        XCTAssertTrue(switched)
        try await f.install("12", access: "alex-access", refresh: "r")
        XCTAssertEqual(f.defaults.string(forKey: SharedStorage.activeAccountIdKey), "12")
        f.signIns.failingWrites = [SharedStorage.usersIndexAccount, SharedStorage.signInAccount(.make(F.home, "12"))]

        let removed = await registry.remove(serverId: F.home)

        XCTAssertFalse(removed)
        XCTAssertEqual(registry.activeServerId, F.home)
        let key = await f.store.currentSignInKey()
        XCTAssertEqual(f.defaults.string(forKey: SharedStorage.activeAccountIdKey), key?.accountID)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(stub.requestedPaths.contains(Self.logout))
    }

    /// The profile likewise comes back only with the sign-in it was picked
    /// under. Here the store has already dropped that sign-in, so no
    /// profile is left open with nothing selected. When the removal fails
    /// before touching the sign-in, the profile is kept.
    @MainActor
    func testFailedServerRemovalRestoresTheProfileOnlyWithItsSignIn() async throws {
        let f = try F.make(self)
        try f.startAccountModel()
        f.defaults.set(true, forKey: ServerRegistry.migratedKey)
        let stub = APIv2TestStub()
        stub.reply(204, "")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: f.store)
        let registry = ServerRegistry(defaults: f.defaults, keychain: f.keychain,
                                      launchPreferences: ProfileLaunchPreferences(defaults: f.defaults),
                                      tokenStore: f.store, httpClient: http, unregisterPush: { _ in })
        XCTAssertNotNil(registry.addOrUpdate(ServerEntry(id: F.home, url: F.homeURL, fetchedName: nil,
                                                         lastUsedAt: Date())))
        let switched = await registry.switchTo(serverId: F.home, launchSelectionFrom: f.store)
        XCTAssertTrue(switched)
        try await f.install("12", access: "alex-access", refresh: "r")
        await f.store.setProfileId("default")

        // The index can't be read: nothing is removed, and the profile stays.
        f.signIns.failsAllReads = true
        let unreadable = await registry.remove(serverId: F.home)
        f.signIns.failsAllReads = false
        XCTAssertFalse(unreadable)
        let kept = await f.store.currentSelection()
        XCTAssertEqual(kept, .signIn(.make(F.home, "12")))
        XCTAssertEqual(f.defaults.string(forKey: SharedStorage.profileIdKey), "default")

        // The sign-in is dropped but can't be made durable.
        f.signIns.failingWrites = [SharedStorage.usersIndexAccount, SharedStorage.signInAccount(.make(F.home, "12"))]
        let removed = await registry.remove(serverId: F.home)

        XCTAssertFalse(removed)
        XCTAssertEqual(registry.activeServerId, F.home)
        let selection = await f.store.currentSelection()
        XCTAssertEqual(selection, .none)
        XCTAssertNil(f.defaults.string(forKey: SharedStorage.profileIdKey))
        let profile = await f.store.getProfileId()
        XCTAssertNil(profile)
    }

    private func waitUntil(_ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }
}
