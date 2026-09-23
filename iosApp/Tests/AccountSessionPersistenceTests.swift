import Foundation
import Security
import XCTest
@testable import Silo

final class AccountSessionPersistenceTests: XCTestCase {
    private func harness(_ memory: SessionMemory = SessionMemory()) async throws -> (TokenStore, SharedKeychain, SharedDefaults, SessionMemory) {
        let name = "AccountSessionPersistenceTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        let store = TokenStore(keychain: keychain, defaults: defaults, sessionPersistence: memory.persistence)
        await store.switchActiveServer(serverId: "server")
        await store.setServerUrl("https://session.example")
        return (store, keychain, defaults, memory)
    }
    private func restarted(_ keychain: SharedKeychain, _ defaults: SharedDefaults, _ memory: SessionMemory) async -> TokenStore {
        let store = TokenStore(keychain: keychain, defaults: defaults, sessionPersistence: memory.persistence)
        await store.switchActiveServer(serverId: "server")
        return store
    }
    @MainActor
    private func lifecycleHarness(purgeDiagnostics: @escaping @Sendable (String) async -> Bool = { _ in true }) async throws -> (
        store: TokenStore, keys: SharedKeychain, defaults: SharedDefaults,
        memory: SessionMemory, registry: ServerRegistry, auth: AuthService, http: HTTPClient, stub: APIv2TestStub
    ) {
        let (store, keys, defaults, memory) = try await harness()
        defaults.set(true, forKey: "continuumServerRegistry.migrated.v1")
        let preferences = ProfileLaunchPreferences(defaults: defaults)
        let stub = APIv2TestStub()
        stub.reply(204, "")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: store)
        let registry = ServerRegistry(defaults: defaults, keychain: keys,
            launchPreferences: preferences, tokenStore: store, httpClient: http)
        XCTAssertNotNil(registry.addOrUpdate(ServerEntry(id: "server", url: "https://session.example",
            fetchedName: "Test Server", lastUsedAt: Date())))
        let switched = await registry.switchTo(serverId: "server")
        XCTAssertTrue(switched)
        let auth = AuthService(serverRegistry: registry, launchPreferences: preferences,
            httpClient: http, tokenStore: store, sessionPersistence: memory.persistence,
            purgeDiagnostics: purgeDiagnostics)
        try await store.installAccountSession(accessToken: "original", refreshToken: "refresh", accountID: "12")
        await store.setProfileId("profile")
        _ = await store.setProfileToken("proof")
        let epoch = await store.getOrCreateAccountEpoch()
        preferences.remember(profileID: "profile", requiresPIN: true,
            accountEpoch: try XCTUnwrap(epoch), for: "server")
        return (store, keys, defaults, memory, registry, auth, http, stub)
    }

    @MainActor
    func testSignOutReportsDiagnosticsFailureWithoutKeepingCredentials() async throws {
        let h = try await lifecycleHarness(purgeDiagnostics: { _ in false })
        let outcome = await h.auth.signOutWithOutcome()
        XCTAssertEqual(outcome, .diagnosticsCleanupFailed)
        XCTAssertFalse(h.auth.isLoggedIn)
        XCTAssertNotNil(h.registry.activeServer)
        let restored = await restarted(h.keys, h.defaults, h.memory).getAccessToken()
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
        XCTAssertNil(ProfileLaunchPreferences(defaults: h.defaults).rememberedProfile(for: "server"))
        let restored = await restarted(h.keys, h.defaults, h.memory).getAccessToken()
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
        let relaunched = await restarted(h.keys, h.defaults, h.memory).getAccessToken()
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

    @MainActor
    func testFailedServerRemovalRetainsEntryAndReleasesIdentityGate() async throws {
        let h = try await lifecycleHarness()
        h.memory.rejectTombstones = true
        h.memory.failRemoval = true
        let removed = await h.registry.remove(serverId: "server")
        XCTAssertFalse(removed)
        XCTAssertEqual(h.registry.activeServerId, "server")
        XCTAssertNotNil(h.registry.entry(with: "server"))
        XCTAssertEqual(h.defaults.string(forKey: SharedStorage.serverUrlKey), "https://session.example")
        let restored = ServerRegistry(defaults: h.defaults, keychain: h.keys,
            launchPreferences: ProfileLaunchPreferences(defaults: h.defaults),
            tokenStore: h.store, httpClient: h.http)
        XCTAssertEqual(restored.activeServerId, "server")
        XCTAssertNotNil(restored.entry(with: "server"))
        h.memory.rejectTombstones = false
        h.memory.failRemoval = false
        let retry = await h.registry.remove(serverId: "server")
        XCTAssertTrue(retry)
        XCTAssertTrue(h.registry.entries.isEmpty)
    }

    @MainActor
    func testLoginStateUsesCanonicalRecordInsteadOfLegacyMirror() async throws {
        let h = try await lifecycleHarness()
        // A mirror can be missing after a failed best-effort mirror write.
        h.keys.withAudience(.userIndependent).delete(TokenStore.accessTokenKey(for: "server"))
        XCTAssertTrue(h.auth.isLoggedIn)
        XCTAssertTrue(h.memory.persistence.invalidate("server"))
        // A legacy copy can survive erasure or migrate from an older tvOS keychain.
        h.keys.withAudience(.userIndependent).set("stale", for: TokenStore.accessTokenKey(for: "server"))
        XCTAssertFalse(h.auth.isLoggedIn)
    }

    @MainActor
    func testSignOutReportsFailedPersistenceAndClearsRuntimeCredentials() async throws {
        let h = try await lifecycleHarness()
        h.memory.failRecordWrites = true
        h.memory.failRemoval = true
        let result = await h.auth.signOutWithOutcome()
        XCTAssertEqual(result, .localOnly)
        let access = await h.store.getAccessToken()
        XCTAssertNil(access)
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
        let (store, _, _, memory) = try await harness()
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
        guard case .session(let value) = try memory.persistence.load("candidate") else { return XCTFail() }
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
        let (store, keys, defaults, memory) = try await harness()
        try await store.installAccountSession(accessToken: "old", refreshToken: "old-refresh", accountID: "12")
        await store.setProfileId("old-profile")
        _ = await store.setProfileToken("old-proof")
        let expected = await store.captureAccountInstallationExpectation()
        try await store.installAccountSessionForServer(serverID: "server", origin: "https://session.example",
            accessToken: "new", refreshToken: "new-refresh", accountID: "13", expected: expected)
        let proof = await store.getProfileToken()
        XCTAssertNil(proof)
        let fresh = TokenStore(keychain: keys, defaults: defaults, sessionPersistence: memory.persistence)
        let blankExpected = await fresh.captureAccountInstallationExpectation()
        XCTAssertNil(blankExpected.account)
        try await fresh.installAccountSessionForServer(serverID: "candidate", origin: "https://candidate.example",
            accessToken: "setup", refreshToken: "setup-refresh", accountID: "14", expected: blankExpected)
        await fresh.setServerUrl("https://candidate.example")
        await fresh.switchActiveServer(serverId: "candidate")
        let access = await fresh.getAccessToken()
        XCTAssertEqual(access, "setup")
    }

    func testInstallRestartReloginAndOriginBinding() async throws {
        let (store, keys, defaults, memory) = try await harness()
        try await store.installAccountSession(accessToken: "one", refreshToken: "refresh-one", accountID: "12")
        let first = await store.getOrCreateAccountEpoch()
        let next = await restarted(keys, defaults, memory)
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
    func testFailedInstallNeverPublishesOrFallsBackToLegacyMirrors() async throws {
        let memory = SessionMemory()
        let (store, keys, defaults, _) = try await harness(memory)
        let account = keys.withAudience(.userIndependent)
        account.set("legacy", for: TokenStore.accessTokenKey(for: "server"))
        account.set("legacy-refresh", for: TokenStore.refreshTokenKey(for: "server"))
        memory.failRecordWrites = true
        do {
            try await store.installAccountSession(accessToken: "new", refreshToken: "new-refresh", accountID: "12")
            XCTFail("Install succeeded although the session record could not be written")
        } catch AccountSessionPersistenceError.unavailable {}
        let active = await store.getAccessToken()
        XCTAssertNil(active)
        let next = await restarted(keys, defaults, memory)
        let afterRestart = await next.getAccessToken()
        XCTAssertNil(afterRestart, "Adoption marker blocks stale legacy fallback")
    }
    func testVerifiedLegacyMigrationPreservesEpochAndBindsAccount() async throws {
        let (store, keys, _, memory) = try await harness()
        let account = keys.withAudience(.userIndependent)
        let epoch = UUID().uuidString
        account.set("legacy", for: TokenStore.accessTokenKey(for: "server"))
        account.set("legacy-refresh", for: TokenStore.refreshTokenKey(for: "server"))
        account.set(epoch, for: TokenStore.accountEpochKey(for: "server"))
        await store.setServerUrl("https://session.example/")
        let capturedValue = await store.captureOrdinaryRequestAuth()
        let captured = try XCTUnwrap(capturedValue)
        try await store.bindVerifiedAccount("12", expected: captured)
        guard case .session(let value) = try memory.persistence.load("server") else { return XCTFail() }
        XCTAssertEqual(value.accountID, "12")
        XCTAssertEqual(value.epoch?.uuidString, epoch)
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
    func testFailedRefreshPublishesNoMixedCredentials() async throws {
        let (store, keys, defaults, memory) = try await harness()
        try await store.installAccountSession(accessToken: "one", refreshToken: "refresh-one", accountID: "12")
        let capturedValue = await store.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(capturedValue)
        memory.failRecordWrites = true
        let saved = await store.saveRefreshedTokens("two", "refresh-two", replacing:
            CapturedRefreshCredential(account: auth.account, refreshToken: "refresh-one", owner: auth.credentialOwner))
        XCTAssertFalse(saved)
        let active = await store.getAccessToken()
        XCTAssertNil(active)
        let next = await restarted(keys, defaults, memory)
        let restored = await next.getAccessToken()
        XCTAssertEqual(restored, "one", "Only the previously committed pair survives")
    }
    func testSignoutTombstoneAndRemovalFallbackPreventMirrorRevival() async throws {
        for fallback in [false, true] {
            let (store, keys, defaults, memory) = try await harness()
            try await store.installAccountSession(accessToken: "one", refreshToken: "refresh-one", accountID: "12")
            memory.failRecordWrites = fallback
            let durable = await store.clearTokens()
            XCTAssertTrue(durable)
            keys.withAudience(.userIndependent).set("stale-mirror", for: TokenStore.accessTokenKey(for: "server"))
            let next = await restarted(keys, defaults, memory)
            let restored = await next.getAccessToken()
            XCTAssertNil(restored)
        }
    }
    func testSignoutFailureReportsDurabilityLimitAndBlocksRuntime() async throws {
        let (store, keys, defaults, memory) = try await harness()
        try await store.installAccountSession(accessToken: "one", refreshToken: "refresh-one", accountID: "12")
        memory.failRecordWrites = true
        memory.failRemoval = true
        let durable = await store.clearTokens()
        XCTAssertFalse(durable)
        let active = await store.getAccessToken()
        XCTAssertNil(active)
        let next = await restarted(keys, defaults, memory)
        let restored = await next.getAccessToken()
        XCTAssertEqual(restored, "one", "Both persistent invalidation mechanisms failed; do not claim durable sign-out")
    }
    func testRejectedRefreshKeepsLocalStateWhenTombstoneCannotPersist() async throws {
        let (store, keys, defaults, memory) = try await harness()
        try await store.installAccountSession(accessToken: "one", refreshToken: "refresh-one", accountID: "12")
        let accountValue = await store.refreshAccountIdentity()
        let account = try XCTUnwrap(accountValue)
        let capturedValue = await store.captureRefreshCredential(expected: account)
        let captured = try XCTUnwrap(capturedValue)
        memory.failRecordWrites = true
        memory.failRemoval = true

        let disposition = await store.invalidateRejectedRefresh(captured)

        XCTAssertNil(disposition, "A tombstone that did not persist is not a cleared session")
        let access = await store.getAccessToken()
        XCTAssertEqual(access, "one", "Local credentials stay until the durable record agrees they are gone")
        let next = await restarted(keys, defaults, memory)
        let restored = await next.getAccessToken()
        XCTAssertEqual(restored, "one")

        memory.failRecordWrites = false
        memory.failRemoval = false
        let retried = await store.invalidateRejectedRefresh(captured)
        XCTAssertEqual(retried, .persistentSessionCleared, "The same captured credential can retry once persistence recovers")
        let cleared = await store.getAccessToken()
        XCTAssertNil(cleared)
    }
    @MainActor
    func testFailedLoginRestoresSessionAndRetainsRememberedProfile() async throws {
        let (store, keys, defaults, memory) = try await harness()
        try await store.installAccountSession(accessToken: "original", refreshToken: "refresh", accountID: "12")
        await store.setProfileId("profile")
        _ = await store.setProfileToken("proof")
        let epoch = await store.getOrCreateAccountEpoch()
        let preferences = ProfileLaunchPreferences(defaults: defaults)
        preferences.remember(profileID: "profile", requiresPIN: true, accountEpoch: try XCTUnwrap(epoch), for: "server")
        let before = preferences.state
        let stub = APIv2TestStub()
        stub.reply(200, Self.tokenPair)
        let http = HTTPClient(session: stub.makeSession(), tokenStore: store)
        let auth = AuthService(launchPreferences: preferences,
            apiV2Client: APIv2Client(http: http, tokenStore: store, isUpdateRequired: { false }),
            httpClient: http, tokenStore: store)
        memory.failAccessToken = "replacement"
        do {
            try await auth.login(username: "new", password: "password")
            XCTFail("Failed persistence reported login success")
        } catch AccountSessionPersistenceError.unavailable { }
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/auth/login"])
        XCTAssertEqual(stub.requests.first?.url?.host, "session.example")
        let restored = await store.getAccessToken()
        let profile = await store.getProfileId()
        let proof = await store.getProfileToken()
        XCTAssertEqual(restored, "original")
        XCTAssertEqual(profile, "profile")
        XCTAssertEqual(proof, "proof")
        XCTAssertEqual(preferences.state, before)
        let relaunched = await restarted(keys, defaults, memory).getAccessToken()
        XCTAssertEqual(relaunched, "original")
        XCTAssertEqual(ProfileLaunchPreferences(defaults: defaults).state, before)
        let lease = await http.beginIdentityTransition()
        XCTAssertNotNil(lease, "Failed login must release its transition lease")
        if let lease { await http.endIdentityTransition(lease) }
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

    func testFailedProfileRestoreInvalidatesPartialSessionAcrossRelaunch() async throws {
        for proof in [String?.none, "original-proof"] {
            for rejectTombstone in [false, true] {
                let (_, keys, defaults, memory) = try await harness()
                let blockedKeys = SharedKeychain(service: keys.service,
                    accessGroup: "unentitled.rollback.tests", allowsAppLocalFallback: false)
                let store = TokenStore(keychain: blockedKeys, defaults: defaults, sessionPersistence: memory.persistence)
                await store.switchActiveServer(serverId: "server")
                let original = CanonicalAccountSession(version: 1, signedOut: false,
                    origin: "https://session.example", accountID: "12", epoch: UUID(),
                    accessToken: "original", refreshToken: "refresh")
                memory.rejectTombstones = rejectTombstone
                let restored = await store.restoreAccountSession(.session(original, profileToken: proof), for: "server")
                XCTAssertFalse(restored)
                let current = await store.getAccessToken()
                XCTAssertNil(current)
                guard case .signedOut = try memory.persistence.load("server") else {
                    return XCTFail("Partial session survived a failed profile-proof restore")
                }
                // Reopen with a working Keychain: the process-local block must
                // not be what prevents the partial session from returning.
                let relaunched = await restarted(keys, defaults, memory)
                let access = await relaunched.getAccessToken()
                XCTAssertNil(access)
            }
        }
    }

    func testRollbackRestoresInactiveTargetsProfileProof() async throws {
        for sameServer in [false, true] {
            let (store, keys, defaults, memory) = try await harness()
            try await store.installAccountSession(accessToken: "original", refreshToken: "refresh", accountID: "12")
            _ = await store.setProfileToken("target-proof")
            if !sameServer {
                await store.switchActiveServer(serverId: "other")
                _ = await store.setProfileToken("active-proof")
            }
            let snapshot = await store.accountSessionSnapshot(for: "server")
            await store.switchActiveServer(serverId: "server")
            _ = await store.setProfileToken(nil)
            try await store.installAccountSession(accessToken: "replacement", refreshToken: "new-refresh", accountID: "34")
            let restored = await store.restoreAccountSession(snapshot, for: "server")
            XCTAssertTrue(restored)
            let proof = await store.getProfileToken()
            XCTAssertEqual(proof, "target-proof")
            let relaunched = await restarted(keys, defaults, memory)
            let durableProof = await relaunched.getProfileToken()
            XCTAssertEqual(durableProof, "target-proof")
            if !sameServer {
                await store.switchActiveServer(serverId: "other")
                let activeProof = await store.getProfileToken()
                XCTAssertEqual(activeProof, "active-proof")
            }
        }
    }

    func testSnapshotRejectsUnreadableLegacyOrProfileSlots() async throws {
        let (store, keys, _, _) = try await harness()
        // Disable persona-specific storage so this raw Security write targets
        // the same slot on both iOS and tvOS.
        let plainKeys = SharedKeychain(service: keys.service, accessGroup: nil, usesUserIndependentKeychain: false)
        let checkedStore = TokenStore(keychain: plainKeys, sessionPersistence: SessionMemory().persistence)
        for key in [TokenStore.accessTokenKey(for: "server"), TokenStore.refreshTokenKey(for: "server"),
                    TokenStore.accountEpochKey(for: "server"), TokenStore.profileTokenKey(for: "server")] {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: keys.service, kSecAttrAccount as String: key,
                kSecValueData as String: Data([0xFF])]
            XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
            let snapshot = await checkedStore.accountSessionSnapshot(for: "server")
            XCTAssertEqual(snapshot, .unreadable)
            XCTAssertTrue(plainKeys.delete(key))
        }
        let empty = await store.accountSessionSnapshot(for: "server")
        XCTAssertEqual(empty, .legacy(accessToken: nil, refreshToken: nil, epoch: nil, profileToken: nil))
    }

    func testLegacyRestoreFailsClosedWhenKeychainWritesOrDeletesFail() async throws {
        for access in [String?.none, "legacy-access"] {
            let (_, _, defaults, memory) = try await harness()
            let blockedKeys = SharedKeychain(service: "Unavailable.\(UUID().uuidString)",
                accessGroup: "unentitled.rollback.tests", allowsAppLocalFallback: false)
            let store = TokenStore(keychain: blockedKeys, defaults: defaults, sessionPersistence: memory.persistence)
            await store.switchActiveServer(serverId: "server")
            try memory.persistence.save(CanonicalAccountSession(version: 1, signedOut: false,
                origin: "https://session.example", accountID: "12", epoch: UUID(),
                accessToken: "paired", refreshToken: "paired-refresh"), serverID: "server")
            let restored = await store.restoreAccountSession(.legacy(accessToken: access,
                refreshToken: "legacy-refresh", epoch: nil, profileToken: nil), for: "server")
            XCTAssertFalse(restored)
            let token = await store.getAccessToken()
            XCTAssertNil(token)
            guard case .session = try memory.persistence.load("server") else {
                return XCTFail("Failed legacy restore must not remove canonical authority")
            }
        }
    }

    func testSessionSnapshotRestoresEachSlotStateExactly() async throws {
        let (store, keys, defaults, memory) = try await harness()

        // A canonical session comes back as it was, and survives a relaunch.
        try await store.installAccountSession(accessToken: "one", refreshToken: "refresh-one", accountID: "12")
        let session = await store.accountSessionSnapshot(for: "server")
        guard case .session(let value, _) = session else { return XCTFail("expected a session snapshot") }
        XCTAssertEqual(value.accessToken, "one")
        try await store.installAccountSession(accessToken: "two", refreshToken: "refresh-two", accountID: "34")
        let restored = await store.restoreAccountSession(session, for: "server")
        XCTAssertTrue(restored)
        let active = await store.getAccessToken()
        XCTAssertEqual(active, "one")
        let relaunched = await restarted(keys, defaults, memory).getAccessToken()
        XCTAssertEqual(relaunched, "one")

        // A signed-out slot is tombstoned again rather than left with the
        // replacement credentials.
        _ = await store.clearTokens()
        let signedOut = await store.accountSessionSnapshot(for: "server")
        XCTAssertEqual(signedOut, .signedOut(profileToken: nil))
        try await store.installAccountSession(accessToken: "three", refreshToken: "refresh-three", accountID: "56")
        let tombstoned = await store.restoreAccountSession(signedOut, for: "server")
        XCTAssertTrue(tombstoned)
        guard case .signedOut = try memory.persistence.load("server") else { return XCTFail("expected a tombstone") }
        let afterTombstone = await store.getAccessToken()
        XCTAssertNil(afterTombstone)

        // Legacy per-token slots are put back and the adoption is undone, so
        // the previous account is neither tombstoned nor replaced.
        let (legacyStore, legacyKeys, legacyDefaults, legacyMemory) = try await harness()
        legacyKeys.withAudience(.userIndependent).set("legacy-access", for: TokenStore.accessTokenKey(for: "server"))
        legacyKeys.withAudience(.userIndependent).set("legacy-refresh", for: TokenStore.refreshTokenKey(for: "server"))
        let legacy = await legacyStore.accountSessionSnapshot(for: "server")
        XCTAssertEqual(legacy, .legacy(accessToken: "legacy-access", refreshToken: "legacy-refresh", epoch: nil, profileToken: nil))
        try await legacyStore.installAccountSession(accessToken: "paired", refreshToken: "paired-refresh", accountID: "78")
        let unadopted = await legacyStore.restoreAccountSession(legacy, for: "server")
        XCTAssertTrue(unadopted)
        guard case .legacy = try legacyMemory.persistence.load("server") else { return XCTFail("expected the slot to be un-adopted") }
        let legacyBack = await restarted(legacyKeys, legacyDefaults, legacyMemory).getAccessToken()
        XCTAssertEqual(legacyBack, "legacy-access")

        // A restore that cannot persist blocks the server instead of
        // claiming the previous state is back.
        legacyMemory.failRecordWrites = true
        legacyMemory.failRemoval = true
        let failed = await legacyStore.restoreAccountSession(session, for: "server")
        XCTAssertFalse(failed)
        let blocked = await legacyStore.getAccessToken()
        XCTAssertNil(blocked)
    }

    func testTemporaryCredentialsCannotReplaceDurableBinding() async throws {
        let (store, _, _, memory) = try await harness()
        try await store.installAccountSession(accessToken: "owner", refreshToken: "owner-refresh", accountID: "12")
        guard case .session(let before) = try memory.persistence.load("server") else { return XCTFail() }
        await store.beginTemporaryScope(TemporaryAuthScope(serverId: "server", serverURL: "https://session.example",
            accessToken: "temporary", refreshToken: "temporary-refresh", profileId: "guest", profileToken: "proof",
            controllerDeviceId: "controller", expiresAt: Date().addingTimeInterval(60)))
        let saved = await store.saveTokens(accessToken: "temporary-two", refreshToken: "temporary-two-refresh")
        XCTAssertTrue(saved)
        do {
            try await store.installAccountSession(accessToken: "wrong", refreshToken: "wrong-refresh", accountID: "99")
            XCTFail("Persistent install succeeded while a temporary scope owned request authentication")
        } catch AccountSessionPersistenceError.invalidIdentity {}
        guard case .session(let after) = try memory.persistence.load("server") else { return XCTFail() }
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

    func testReadFailureAndCorruptionNeverFallback() async throws {
        let (_, keys, defaults, memory) = try await harness()
        keys.withAudience(.userIndependent).set("legacy", for: TokenStore.accessTokenKey(for: "server"))
        memory.failRead = true
        let store = await restarted(keys, defaults, memory)
        let token = await store.getAccessToken()
        XCTAssertNil(token)
        memory.failRead = false
        _ = memory.persistence.write("broken", AccountSessionPersistence.recordKey("server"))
        let next = await restarted(keys, defaults, memory)
        let invalid = await next.getAccessToken()
        XCTAssertNil(invalid)
    }
}

private final class SessionMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    var failRecordWrites = false
    var failAccessToken: String?
    var rejectTombstones = false
    var failRemoval = false
    var failRead = false
    var persistence: AccountSessionPersistence {
        AccountSessionPersistence(read: { key in
            try self.lock.withLock {
                if self.failRead { throw AccountSessionPersistenceError.unavailable }
                return self.values[key]
            }
        }, write: { value, key in
            self.lock.withLock {
                if self.failRecordWrites && key.hasSuffix(".accountSession") { return false }
                if let session = try? JSONDecoder().decode(CanonicalAccountSession.self, from: Data(value.utf8)) {
                    if let rejected = self.failAccessToken, session.accessToken == rejected { return false }
                    if self.rejectTombstones && session.signedOut { return false }
                }
                self.values[key] = value; return true
            }
        }, remove: { key in
            self.lock.withLock {
                if self.failRemoval { return false }; self.values.removeValue(forKey: key); return true
            }
        })
    }
}
