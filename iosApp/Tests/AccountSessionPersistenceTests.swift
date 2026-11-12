import Foundation
import Security
import XCTest
@testable import Silo

final class AccountSessionPersistenceTests: XCTestCase {
    private func harness() async throws -> (TokenStore, SharedKeychain, SharedDefaults, AccountStore) {
        let name = "AccountSessionPersistenceTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        let accounts = AccountStore(keychain: keychain, defaults: defaults)
        let store = TokenStore(keychain: keychain, defaults: defaults, accounts: accounts)
        await store.switchActiveServer(serverId: "server")
        await store.setServerUrl("https://session.example")
        return (store, keychain, defaults, accounts)
    }
    private func restarted(_ keychain: SharedKeychain, _ defaults: SharedDefaults) async -> TokenStore {
        let store = TokenStore(keychain: keychain, defaults: defaults)
        await store.switchActiveServer(serverId: "server")
        return store
    }
    @MainActor
    private func lifecycleHarness(
        purgeDiagnostics: @escaping @Sendable (String) async -> Bool = { _ in true },
        unregisterPush: @escaping @Sendable (String) async -> Void = { _ in }
    ) async throws -> (
        store: TokenStore, keys: SharedKeychain, defaults: SharedDefaults,
        accounts: AccountStore, registry: ServerRegistry, auth: AuthService, http: HTTPClient, stub: APIv2TestStub
    ) {
        let (store, keys, defaults, accounts) = try await harness()
        defaults.set(true, forKey: ServerRegistry.migratedKey)
        let preferences = ProfileLaunchPreferences(defaults: defaults)
        let stub = APIv2TestStub()
        stub.reply(204, "")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: store)
        let registry = ServerRegistry(defaults: defaults, keychain: keys, accounts: accounts,
            launchPreferences: preferences, tokenStore: store, httpClient: http, unregisterPush: unregisterPush)
        XCTAssertNotNil(registry.addOrUpdate(ServerEntry(id: "server", url: "https://session.example",
            fetchedName: "Test Server", lastUsedAt: Date())))
        let switched = await registry.switchTo(serverId: "server")
        XCTAssertTrue(switched)
        let auth = AuthService(serverRegistry: registry, launchPreferences: preferences,
            httpClient: http, tokenStore: store, defaults: defaults, accounts: accounts,
            purgeDiagnostics: purgeDiagnostics, unregisterPush: unregisterPush)
        try await store.installAccountSession(accessToken: "original", refreshToken: "refresh", accountID: "12")
        await store.setProfileId("profile")
        _ = await store.setProfileToken("proof")
        let epoch = await store.getOrCreateAccountEpoch()
        let account = await store.refreshAccountIdentity()?.localAccountId
        preferences.remember(profileID: "profile", requiresPIN: true,
            accountEpoch: try XCTUnwrap(epoch), forAccount: try XCTUnwrap(account))
        return (store, keys, defaults, accounts, registry, auth, http, stub)
    }

    /// Records each request to turn a server's pushes off with the access
    /// token the device still held at the time.
    private final class PushOffProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var store: TokenStore?

        var calls: [String] { lock.withLock { recorded } }

        func record(_ serverID: String) async {
            let token = await store?.getAccessToken()
            lock.withLock { recorded.append("\(serverID):\(token ?? "none")") }
        }
    }

    /// A server can only be told to stop pushing while this device can still
    /// authenticate to it, so sign-out and removal ask before clearing.
    @MainActor
    func testSignOutAndRemovalTurnPushOffBeforeClearingCredentials() async throws {
        for removesServer in [false, true] {
            let probe = PushOffProbe()
            let h = try await lifecycleHarness(unregisterPush: { await probe.record($0) })
            probe.store = h.store

            if removesServer {
                let removed = await h.registry.remove(serverId: "server")
                XCTAssertTrue(removed)
            } else {
                let outcome = await h.auth.signOutWithOutcome()
                XCTAssertEqual(outcome, .completed)
            }

            XCTAssertEqual(probe.calls, ["server:original"])
            let remaining = await h.store.getAccessToken()
            XCTAssertNil(remaining)
        }
    }

    /// Removing a server turns its pushes off first. When the removal then
    /// fails, the server stays saved and signed in, so its pushes are turned
    /// back on rather than left off for good.
    @MainActor
    func testFailedRemovalOfAnInactiveServerTurnsItsPushesBackOn() async throws {
        let (store, keys, defaults, _) = try await harness()
        defaults.set(true, forKey: ServerRegistry.migratedKey)
        let pushes = PushCalls()
        var allowsPersistence = true
        let registry = ServerRegistry(defaults: defaults, keychain: keys,
            launchPreferences: ProfileLaunchPreferences(defaults: defaults),
            persistenceOverride: { _, _ in allowsPersistence }, tokenStore: store,
            httpClient: HTTPClient(session: APIv2TestStub().makeSession(), tokenStore: store),
            unregisterPush: { pushes.record("off \($0)") }, restorePush: { pushes.record("on \($0)") })
        XCTAssertNotNil(registry.addOrUpdate(ServerEntry(id: "server", url: "https://session.example",
            fetchedName: nil, lastUsedAt: Date())))
        XCTAssertNotNil(registry.addOrUpdate(ServerEntry(id: "other", url: "https://other.example",
            fetchedName: nil, lastUsedAt: Date())))
        allowsPersistence = false

        let removed = await registry.remove(serverId: "other")

        XCTAssertFalse(removed)
        XCTAssertNotNil(registry.entry(with: "other"))
        XCTAssertEqual(pushes.calls, ["off other", "on other"])
    }

    private final class PushCalls: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var calls: [String] { lock.withLock { recorded } }
        func record(_ call: String) { lock.withLock { recorded.append(call) } }
    }

    @MainActor
    func testSignOutReportsDiagnosticsFailureWithoutKeepingCredentials() async throws {
        let h = try await lifecycleHarness(purgeDiagnostics: { _ in false })
        let outcome = await h.auth.signOutWithOutcome()
        XCTAssertEqual(outcome, .diagnosticsCleanupFailed)
        XCTAssertFalse(h.auth.isLoggedIn)
        XCTAssertNotNil(h.registry.activeServer)
        let restored = await restarted(h.keys, h.defaults).getAccessToken()
        XCTAssertNil(restored)
        try await h.store.installAccountSession(accessToken: "replacement", refreshToken: "new-refresh", accountID: "12")
        XCTAssertTrue(h.auth.isLoggedIn)
    }

    @MainActor
    func testSignOutCompletesBeforeServerRepliesAndStaysSignedOutAfterRestart() async throws {
        let h = try await lifecycleHarness()
        h.stub.hold()
        defer { h.stub.release() }
        let completed = expectation(description: "Local sign-out does not wait for the server")
        let operation = Task {
            let result = await h.auth.signOutWithOutcome()
            completed.fulfill()
            return result
        }
        await fulfillment(of: [completed], timeout: 2)
        let result = await operation.value
        XCTAssertEqual(result, .completed)
        XCTAssertNotNil(h.registry.activeServer)
        XCTAssertFalse(h.auth.isLoggedIn)
        XCTAssertNil(h.defaults.string(forKey: SharedStorage.profileIdKey))
        XCTAssertTrue(ProfileLaunchPreferences(defaults: h.defaults).state.rememberedByAccountID.isEmpty)
        let restored = await restarted(h.keys, h.defaults).getAccessToken()
        XCTAssertNil(restored)
        await h.stub.waitUntilHeld()
        XCTAssertEqual(h.stub.requestedPaths, ["/api/v2/auth/logout"])
        XCTAssertEqual(h.stub.requests.first?.header("Authorization"), "Bearer original")
        // v2 logout refuses the profile header; the outgoing profile and its
        // proof stay off the revocation.
        XCTAssertNil(h.stub.requests.first?.header("X-Profile-Id"))
        XCTAssertNil(h.stub.requests.first?.header("X-Profile-Token"))
    }

    @MainActor
    func testLateUnauthorizedLogoutCannotRefreshOrClearNewLogin() async throws {
        let h = try await lifecycleHarness()
        let capture = await h.store.captureOrdinaryRequestAuth()
        let outgoing = try XCTUnwrap(capture)
        h.stub.reply(401, "{}")
        h.stub.hold()
        defer { h.stub.release() }
        let revoke = Task { await h.http.revokeSession(outgoing) }
        await h.stub.waitUntilHeld()
        _ = await h.store.clearTokens()
        let expected = await h.store.refreshAccountIdentity()
        try await h.auth.installSession(accessToken: "replacement", refreshToken: "replacement-refresh",
            accountID: "1", expectedAccount: XCTUnwrap(expected))
        h.stub.release()
        await revoke.value
        let access = await h.store.getAccessToken()
        XCTAssertEqual(access, "replacement")
        XCTAssertTrue(h.auth.isLoggedIn)
        XCTAssertEqual(h.stub.requestedPaths, ["/api/v2/auth/logout"])
    }

    @MainActor
    func testRemovingLastServerSurvivesRestartAndReaddingRequiresLogin() async throws {
        let h = try await lifecycleHarness()
        let removed = await h.registry.remove(serverId: "server")
        XCTAssertTrue(removed)
        XCTAssertTrue(h.registry.entries.isEmpty)
        XCTAssertNil(h.registry.activeServerId)
        XCTAssertNil(h.defaults.string(forKey: SharedStorage.serverUrlKey))
        XCTAssertNil(h.defaults.string(forKey: SharedStorage.profileIdKey))
        let restored = ServerRegistry(defaults: h.defaults, keychain: h.keys,
            launchPreferences: ProfileLaunchPreferences(defaults: h.defaults),
            tokenStore: h.store, httpClient: h.http)
        XCTAssertTrue(restored.entries.isEmpty)
        XCTAssertNil(restored.activeServerId)
        XCTAssertNotNil(restored.addOrUpdate(ServerEntry(id: "server", url: "https://session.example",
            fetchedName: nil, lastUsedAt: Date())))
        let switched = await restored.switchTo(serverId: "server")
        XCTAssertTrue(switched)
        let access = await h.store.getAccessToken()
        XCTAssertNil(access)
        let account = await h.store.refreshAccountIdentity()
        try await h.auth.installSession(accessToken: "new-login", refreshToken: "new-refresh",
            accountID: "1", expectedAccount: XCTUnwrap(account))
        let relaunched = await restarted(h.keys, h.defaults).getAccessToken()
        XCTAssertEqual(relaunched, "new-login")
    }

    @MainActor
    func testRemovingActiveServerPreservesFallbackAccount() async throws {
        let h = try await lifecycleHarness()
        XCTAssertNotNil(h.registry.addOrUpdate(ServerEntry(id: "fallback", url: "https://fallback.example",
            fetchedName: nil, lastUsedAt: .distantPast)))
        let before = await h.store.captureAccountInstallationExpectation()
        try await h.store.installAccountSessionForServer(serverID: "fallback", origin: "https://fallback.example",
            accessToken: "fallback-access", refreshToken: "fallback-refresh", accountID: "34", expected: before)
        let removed = await h.registry.remove(serverId: "server")
        XCTAssertTrue(removed)
        XCTAssertEqual(h.registry.activeServerId, "fallback")
        XCTAssertEqual(h.defaults.string(forKey: SharedStorage.serverUrlKey), "https://fallback.example")
        let access = await h.store.getAccessToken()
        XCTAssertEqual(access, "fallback-access")
        let oldAccess = await h.store.getAccessToken(for: "server")
        XCTAssertNil(oldAccess)
        XCTAssertTrue(h.auth.isLoggedIn)
    }

    func testDelayedLoginInstallRejectsSameAccountReloginInsideActor() async throws {
        let (store, _, _, _) = try await harness()
        try await store.installAccountSession(accessToken: "first", refreshToken: "first-refresh", accountID: "12")
        let captured = await store.refreshAccountIdentity()
        let expected = try XCTUnwrap(captured)
        try await store.installAccountSession(accessToken: "new-login", refreshToken: "new-refresh", accountID: "12")
        do {
            try await store.installAccountSession(accessToken: "delayed", refreshToken: "delayed-refresh", accountID: "12", expectedAccount: expected)
            XCTFail("Delayed installer replaced newer login")
        } catch HTTPError.requestIdentityChanged {}
        let current = await store.getAccessToken()
        XCTAssertEqual(current, "new-login")
    }

    func testReceiverExpectationFencesSwitchAwayAndBackAndConsumesSuccess() async throws {
        let (store, _, _, accounts) = try await harness()
        let expected = await store.captureAccountInstallationExpectation()
        await store.switchActiveServer(serverId: "other")
        await store.switchActiveServer(serverId: "server")
        do {
            try await store.installAccountSessionForServer(serverID: "candidate", origin: "https://candidate.example",
                accessToken: "delayed", refreshToken: "delayed-refresh", accountID: "12", expected: expected)
            XCTFail("Changed owner accepted")
        } catch HTTPError.requestIdentityChanged {}
        let fresh = await store.captureAccountInstallationExpectation()
        try await store.installAccountSessionForServer(serverID: "candidate", origin: "https://candidate.example",
            accessToken: "new", refreshToken: "new-refresh", accountID: "12", expected: fresh)
        let active = await store.getActiveServerId()
        XCTAssertEqual(active, "server", "Persisting an explicit candidate does not retarget active credentials")
        do {
            try await store.installAccountSessionForServer(serverID: "candidate", origin: "https://candidate.example",
                accessToken: "duplicate", refreshToken: "duplicate-refresh", accountID: "12", expected: fresh)
            XCTFail("Successful installation must consume its expectation")
        } catch HTTPError.requestIdentityChanged {}
        let value = try XCTUnwrap(accounts.accounts(onServer: "candidate").first)
        XCTAssertEqual(value.accessToken, "new")
    }

    func testTemporaryHandoffCannotReplaceNewerLogin() async throws {
        let (store, _, _, _) = try await harness()
        let expected = await store.captureAccountInstallationExpectation()
        try await store.installAccountSession(accessToken: "new-login", refreshToken: "new-refresh", accountID: "12")
        let scope = TemporaryAuthScope(serverId: "candidate", serverURL: "https://candidate.example",
            accessToken: "temporary", refreshToken: "temporary-refresh", profileId: "profile",
            profileToken: "proof", controllerDeviceId: "controller", expiresAt: Date().addingTimeInterval(600))
        let installed = await store.beginTemporaryScope(scope, expected: expected)
        XCTAssertNil(installed)
        let current = await store.getAccessToken()
        XCTAssertEqual(current, "new-login")
    }

    func testReceiverInitialSetupAndExistingProfileProofBoundary() async throws {
        let (store, keys, defaults, _) = try await harness()
        try await store.installAccountSession(accessToken: "old", refreshToken: "old-refresh", accountID: "12")
        await store.setProfileId("old-profile")
        _ = await store.setProfileToken("old-proof")
        let expected = await store.captureAccountInstallationExpectation()
        try await store.installAccountSessionForServer(serverID: "server", origin: "https://session.example",
            accessToken: "new", refreshToken: "new-refresh", accountID: "13", expected: expected)
        let proof = await store.getProfileToken()
        XCTAssertNil(proof)
        let fresh = TokenStore(keychain: keys, defaults: defaults)
        let blankExpected = await fresh.captureAccountInstallationExpectation()
        XCTAssertNil(blankExpected.account)
        try await fresh.installAccountSessionForServer(serverID: "candidate", origin: "https://candidate.example",
            accessToken: "setup", refreshToken: "setup-refresh", accountID: "14", expected: blankExpected)
        await fresh.setServerUrl("https://candidate.example")
        await fresh.switchActiveServer(serverId: "candidate")
        let access = await fresh.getAccessToken()
        XCTAssertEqual(access, "setup")
    }

    /// The profile limit read with a profile list is kept with the account,
    /// so the profile menu knows it after a restart, before any list is
    /// read again.
    func testProfileLimitIsSavedWithTheCachedProfileList() async throws {
        let (store, keys, defaults, _) = try await harness()
        try await store.installAccountSession(accessToken: "one", refreshToken: "refresh-one", accountID: "12")
        let identityValue = await store.refreshAccountIdentity()
        let identity = try XCTUnwrap(identityValue)
        let only = AccountProfile(
            id: "p-owner", name: "Owner", avatarEmoji: nil, avatarImageUrl: nil, hasPin: false, isChild: false
        )

        let saved = await store.updateCachedProfiles([only], maxProfiles: 1, expected: identity)
        XCTAssertTrue(saved)
        let unchanged = await store.updateCachedProfiles([only], maxProfiles: 1, expected: identity)
        XCTAssertFalse(unchanged)

        let afterRestart = try XCTUnwrap(
            AccountStore(keychain: keys, defaults: defaults).accounts(onServer: "server").first
        )
        XCTAssertEqual(afterRestart.cachedProfiles, [only])
        XCTAssertEqual(afterRestart.maxProfiles, 1)

        // A later list that omits the limit means it is unknown again.
        let cleared = await store.updateCachedProfiles([only], maxProfiles: nil, expected: identity)
        XCTAssertTrue(cleared)
        XCTAssertNil(try AccountStore(keychain: keys, defaults: defaults).accounts(onServer: "server").first?.maxProfiles)
    }

    func testInstallRestartReloginAndOriginBinding() async throws {
        let (store, keys, defaults, _) = try await harness()
        try await store.installAccountSession(accessToken: "one", refreshToken: "refresh-one", accountID: "12")
        let first = await store.getOrCreateAccountEpoch()
        let next = await restarted(keys, defaults)
        let restored = await next.getAccessToken()
        XCTAssertEqual(restored, "one")
        let restoredEpoch = await next.getOrCreateAccountEpoch()
        XCTAssertEqual(restoredEpoch, first)
        try await next.installAccountSession(accessToken: "two", refreshToken: "refresh-two", accountID: "12")
        let second = await next.getOrCreateAccountEpoch()
        XCTAssertNotEqual(first, second)
        await next.setServerUrl("https://different.example")
        let foreign = await next.getAccessToken()
        XCTAssertNil(foreign)
    }
    func testAccountReadCannotBindItsResultToAReplacementLogin() async throws {
        let (store, _, _, _) = try await harness()
        await store.saveTokens(accessToken: "original", refreshToken: "original-refresh")
        let stub = StubURLProtocol.Handler()
        stub.expect(StubURLProtocol.method("GET", path: "/api/v2/account/me")) { _ in
            _ = await store.clearTokens()
            await store.saveTokens(accessToken: "replacement", refreshToken: "replacement-refresh")
            return .json(#"{"id":"12","username":"Original","email":"","role":"user","permissions":[],"download_allowed":true}"#)
        }
        stub.route(StubURLProtocol.method("GET", path: "/api/v2/account/me")) { _ in
            .json(#"{"id":"34","username":"Replacement","email":"","role":"user","permissions":[],"download_allowed":true}"#)
        }
        let client = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: store),
                                 tokenStore: store, isUpdateRequired: { false })

        _ = try? await client.currentUser()
        let durable = await store.captureDurableAccountAuth()
        XCTAssertNil(durable, "The replacement login has not verified its account ID")

        _ = try await client.currentUser()
        let verified = await store.captureDurableAccountAuth()
        XCTAssertEqual(verified?.accountID, "34")
    }

    func testRefreshPreservesEpochAndStaleRefreshCannotReplaceRelogin() async throws {
        let (store, _, _, _) = try await harness()
        try await store.installAccountSession(accessToken: "one", refreshToken: "refresh-one", accountID: "12")
        let capturedValue = await store.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(capturedValue)
        let epoch = await store.getOrCreateAccountEpoch()
        let captured = CapturedRefreshCredential(account: auth.account, refreshToken: "refresh-one", owner: auth.credentialOwner)
        let saved = await store.saveRefreshedTokens("two", "refresh-two", replacing: captured)
        XCTAssertTrue(saved)
        let after = await store.getOrCreateAccountEpoch()
        XCTAssertEqual(epoch, after)
        try await store.installAccountSession(accessToken: "new-login", refreshToken: "new-refresh", accountID: "12")
        let stale = await store.saveRefreshedTokens("old-response", "old-refresh", replacing: captured)
        XCTAssertFalse(stale)
        let current = await store.getAccessToken()
        XCTAssertEqual(current, "new-login")
    }
    @MainActor
    func testLoginInstallsIntoItsInjectedStore() async throws {
        let (store, _, defaults, _) = try await harness()
        try await store.installAccountSession(accessToken: "original", refreshToken: "refresh", accountID: "12")
        await store.setProfileId("old-profile")
        _ = await store.setProfileToken("old-proof")
        let stub = APIv2TestStub()
        stub.reply(200, Self.tokenPair)
        let http = HTTPClient(session: stub.makeSession(), tokenStore: store)
        let auth = AuthService(launchPreferences: ProfileLaunchPreferences(defaults: defaults),
            apiV2Client: APIv2Client(http: http, tokenStore: store, isUpdateRequired: { false }),
            httpClient: http, tokenStore: store)
        try await auth.login(username: "new", password: "password")
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/auth/login"])
        XCTAssertEqual(stub.requests.first?.url?.host, "session.example")
        let access = await store.getAccessToken()
        let proof = await store.getProfileToken()
        let profile = await store.getProfileId()
        XCTAssertEqual(access, "replacement")
        XCTAssertNil(proof)
        XCTAssertNil(profile)
        // The session is bound to the account the token pair names, so
        // durable account work can capture it right after sign-in.
        let durable = await store.captureDurableAccountAuth()
        XCTAssertEqual(durable?.accountID, "34")
    }

    /// Wrong credentials are the answer, not a session failure: the previous
    /// session and profile stay, and the 401 never starts a refresh.
    @MainActor
    func testRejectedLoginKeepsPreviousSessionWithoutRefresh() async throws {
        let (store, _, defaults, _) = try await harness()
        try await store.installAccountSession(accessToken: "original", refreshToken: "refresh", accountID: "12")
        await store.setProfileId("profile")
        let stub = APIv2TestStub()
        stub.reply(401, #"{"type":"https://siloserver.org/docs/api/v2/problems/invalid_token","title":"Invalid token","status":401,"detail":"Invalid username or password."}"#)
        let http = HTTPClient(session: stub.makeSession(), tokenStore: store)
        let auth = AuthService(launchPreferences: ProfileLaunchPreferences(defaults: defaults),
            apiV2Client: APIv2Client(http: http, tokenStore: store, isUpdateRequired: { false }),
            httpClient: http, tokenStore: store)
        do {
            try await auth.login(username: "new", password: "wrong")
            XCTFail("A rejected login installed a session")
        } catch APIv2Error.problem(let problem) {
            XCTAssertEqual(problem.status, 401)
        }
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/auth/login"])
        let access = await store.getAccessToken()
        let profile = await store.getProfileId()
        XCTAssertEqual(access, "original")
        XCTAssertEqual(profile, "profile")
        let durable = await store.captureDurableAccountAuth()
        XCTAssertEqual(durable?.accountID, "12")
    }

    private static let tokenPair = #"{"access_token":"replacement","refresh_token":"new-refresh","expires_in":3600,"user":{"id":"34","username":"new","email":"new@example.test","role":"user","permissions":[],"download_allowed":true}}"#

    func testRollbackRestoresInactiveTargetsProfileProof() async throws {
        for sameServer in [false, true] {
            let (store, keys, defaults, _) = try await harness()
            try await store.installAccountSession(accessToken: "original", refreshToken: "refresh", accountID: "12")
            _ = await store.setProfileToken("target-proof")
            if !sameServer {
                // A profile proof belongs to an account, so the other server
                // needs one of its own.
                await store.switchActiveServer(serverId: "other")
                await store.setServerUrl("https://other.example")
                try await store.installAccountSession(accessToken: "other", refreshToken: "other-refresh", accountID: "56")
                _ = await store.setProfileToken("active-proof")
            }
            let snapshot = await store.accountSessionSnapshot(for: "server")
            await store.switchActiveServer(serverId: "server")
            await store.setServerUrl("https://session.example")
            _ = await store.setProfileToken(nil)
            try await store.installAccountSession(accessToken: "replacement", refreshToken: "new-refresh", accountID: "34")
            let restored = await store.restoreAccountSession(snapshot, for: "server")
            XCTAssertTrue(restored)
            let proof = await store.getProfileToken()
            XCTAssertEqual(proof, "target-proof")
            let relaunched = await restarted(keys, defaults)
            let durableProof = await relaunched.getProfileToken()
            XCTAssertEqual(durableProof, "target-proof")
            if !sameServer {
                await store.switchActiveServer(serverId: "other")
                await store.setServerUrl("https://other.example")
                let activeProof = await store.getProfileToken()
                XCTAssertEqual(activeProof, "active-proof")
            }
        }
    }

    func testSessionSnapshotRestoresEachSlotStateExactly() async throws {
        let (store, keys, defaults, accounts) = try await harness()

        // A saved session comes back as it was, and survives a relaunch.
        try await store.installAccountSession(accessToken: "one", refreshToken: "refresh-one", accountID: "12")
        let session = await store.accountSessionSnapshot(for: "server")
        guard case .saved(let value, _) = session else { return XCTFail("expected a session snapshot") }
        XCTAssertEqual(value.accounts.map(\.accessToken), ["one"])
        try await store.installAccountSession(accessToken: "two", refreshToken: "refresh-two", accountID: "34")
        let restored = await store.restoreAccountSession(session, for: "server")
        XCTAssertTrue(restored)
        let active = await store.getAccessToken()
        XCTAssertEqual(active, "one")
        let relaunched = await restarted(keys, defaults).getAccessToken()
        XCTAssertEqual(relaunched, "one")

        // A signed-out server is signed out again rather than left with the
        // replacement credentials.
        _ = await store.clearTokens()
        let signedOut = await store.accountSessionSnapshot(for: "server")
        guard case .saved(let empty, _) = signedOut else { return XCTFail("expected a signed-out snapshot") }
        XCTAssertTrue(empty.accounts.isEmpty)
        try await store.installAccountSession(accessToken: "three", refreshToken: "refresh-three", accountID: "56")
        let tombstoned = await store.restoreAccountSession(signedOut, for: "server")
        XCTAssertTrue(tombstoned)
        XCTAssertTrue(try accounts.accounts(onServer: "server").isEmpty, "expected the server signed out")
        let afterTombstone = await store.getAccessToken()
        XCTAssertNil(afterTombstone)
    }

    func testTemporaryCredentialsCannotReplaceDurableBinding() async throws {
        let (store, _, _, accounts) = try await harness()
        try await store.installAccountSession(accessToken: "owner", refreshToken: "owner-refresh", accountID: "12")
        let before = try accounts.accounts(onServer: "server")
        XCTAssertEqual(before.count, 1)
        await store.beginTemporaryScope(TemporaryAuthScope(serverId: "server", serverURL: "https://session.example",
            accessToken: "temporary", refreshToken: "temporary-refresh", profileId: "guest", profileToken: "proof",
            controllerDeviceId: "controller", expiresAt: Date().addingTimeInterval(60)))
        let saved = await store.saveTokens(accessToken: "temporary-two", refreshToken: "temporary-two-refresh")
        XCTAssertTrue(saved)
        do {
            try await store.installAccountSession(accessToken: "wrong", refreshToken: "wrong-refresh", accountID: "99")
            XCTFail("Persistent install succeeded while a temporary scope owned request authentication")
        } catch AccountStoreError.invalidIdentity {}
        let after = try accounts.accounts(onServer: "server")
        XCTAssertEqual(before, after)
        let epoch = await store.getOrCreateAccountEpoch()
        XCTAssertNil(epoch)
    }

    func testDurableCaptureRequiresVerifiedBindingAndKeepsRuntimeScope() async throws {
        let (store, _, _, _) = try await harness()
        let saved = await store.saveTokens(accessToken: "unverified", refreshToken: "refresh")
        XCTAssertTrue(saved)
        let unverified = await store.captureDurableAccountAuth()
        XCTAssertNil(unverified)
        await store.setProfileId("profile-one")
        let beforeValue = await store.captureOrdinaryRequestAuth()
        let before = try XCTUnwrap(beforeValue)
        try await store.bindVerifiedAccount("12", expected: before)
        let boundValue = await store.captureDurableAccountAuth()
        let bound = try XCTUnwrap(boundValue)
        XCTAssertEqual(bound.accountID, "12")
        XCTAssertEqual(bound.request.profileId, "profile-one")
        await store.setProfileId("profile-two")
        let changedValue = await store.captureDurableAccountAuth()
        let changed = try XCTUnwrap(changedValue)
        XCTAssertEqual(changed.accountEpoch, bound.accountEpoch)
        XCTAssertEqual(changed.request.profileId, "profile-two")
    }

}
