import Foundation
import XCTest
@testable import Silo

/// `HTTPClient.revoke(_:)`: the server ends a session only for a valid
/// access token, so a sign-in idle past its token's lifetime is refreshed
/// once, in memory, before logging out. Nothing it learns is ever stored, and
/// local sign-out never waits for it.
final class SignInRevocationTests: XCTestCase {
    private typealias F = SignInStoreFixture
    private static let logout = "/api/v2/auth/logout"
    private let credential = RevocableCredential(serverURL: F.homeURL, accessToken: "old-access",
                                                 refreshToken: "old-refresh")

    private func client(_ stub: APIv2TestStub, store: TokenStore? = nil) throws -> HTTPClient {
        HTTPClient(session: stub.makeSession(), tokenStore: try store ?? F.make(self).store)
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
        try f.startUserModel()
        await f.activate(F.home, url: F.homeURL)
        try await f.install("13", access: "current-access", refresh: "current-refresh", placement: .newUser)
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

    func testFailuresEndTheAttemptQuietly() async throws {
        // A refused refresh means the session is already gone: no retry.
        var stub = APIv2TestStub()
        stub.reply(path: Self.logout, 401, "{}")
        stub.reply(path: HTTPClient.refreshPath, 401, "{}")
        try await client(stub).revoke(credential)
        XCTAssertEqual(stub.requestedPaths, [Self.logout, HTTPClient.refreshPath])

        // A server fault on logout isn't a stale token: no refresh.
        stub = APIv2TestStub()
        stub.reply(path: Self.logout, 500, "{}")
        try await client(stub).revoke(credential)
        XCTAssertEqual(stub.requestedPaths, [Self.logout])

        // Unreachable.
        stub = APIv2TestStub()
        stub.fail()
        try await client(stub).revoke(credential)
        XCTAssertEqual(stub.requestedPaths, [Self.logout])

        // Nothing to refresh with.
        stub = APIv2TestStub()
        stub.reply(path: Self.logout, 401, "{}")
        try await client(stub).revoke(RevocableCredential(serverURL: F.homeURL, accessToken: "a", refreshToken: nil))
        XCTAssertEqual(stub.requestedPaths, [Self.logout])
    }

    /// Sign-out removes the sign-in first and returns without waiting; the
    /// logout that follows carries the removed session.
    @MainActor
    func testSignOutRevokesAfterTheSignInIsGone() async throws {
        let f = try F.make(self)
        try f.startUserModel()
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
        try await f.install("12", access: "alex-access", refresh: "alex-refresh", placement: .newUser)
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
        XCTAssertNil(try f.signIn(.make(F.home, "12")), "removed before the server heard about it")
        XCTAssertEqual(try f.index()?.users, [])
        XCTAssertFalse(auth.isLoggedIn)
        XCTAssertNil(auth.accountID)
        XCTAssertEqual(stub.requests.first?.header("Authorization"), "Bearer alex-access")
    }

    /// Removing a server signs every user out of it and revokes each session.
    @MainActor
    func testRemovingAServerRevokesEveryUsersSession() async throws {
        let f = try F.make(self)
        try f.startUserModel()
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
        try await f.install("12", access: "alex-access", refresh: "r", placement: .newUser)
        await f.store.select(serverID: F.home, credential: .none, userID: nil)
        try await f.install("13", access: "sam-access", refresh: "r", placement: .newUser)

        let removed = await registry.remove(serverId: F.home)

        XCTAssertTrue(removed)
        XCTAssertEqual(try f.index()?.users, [])
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
        try f.startUserModel()
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
        try await f.install("12", access: "alex-access", refresh: "r", placement: .newUser)
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
        try f.startUserModel()
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
        try await f.install("12", access: "alex-access", refresh: "r", placement: .newUser)
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
