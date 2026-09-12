import Foundation
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
                self.values[key] = value; return true
            }
        }, remove: { key in
            self.lock.withLock {
                if self.failRemoval { return false }; self.values.removeValue(forKey: key); return true
            }
        })
    }
}
