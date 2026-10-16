import Foundation
import XCTest
@testable import Silo

final class TVAccountLifecycleTests: XCTestCase {
    private let origin = "https://accounts.example"

    private func harness(_ memory: TVLifecycleMemory, persona: String) async throws -> (TokenStore, SharedKeychain, SharedDefaults) {
        let name = "TVAccountLifecycleTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let keys = SharedKeychain(service: name, accessGroup: nil)
        let store = TokenStore(keychain: keys, defaults: defaults, sessionPersistence: memory.persistence(persona))
        await store.setServerUrl(origin)
        await store.switchActiveServer(serverId: "server")
        return (store, keys, defaults)
    }

    @MainActor
    func testInstallingAnotherAccountThroughAuthPreservesFirstAccount() async throws {
        let memory = TVLifecycleMemory()
        let (first, _, _) = try await harness(memory, persona: "first")
        try await first.installAccountSession(accessToken: "access-A", refreshToken: "refresh-A", accountID: "A")
        let (second, keys, defaults) = try await harness(memory, persona: "second")
        defaults.set(true, forKey: ServerRegistry.migratedKey)
        let preferences = ProfileLaunchPreferences(defaults: defaults)
        let http = HTTPClient(session: APIv2TestStub().makeSession(), tokenStore: second)
        let registry = ServerRegistry(defaults: defaults, keychain: keys, launchPreferences: preferences,
            tokenStore: second, httpClient: http)
        XCTAssertNotNil(registry.addOrUpdate(ServerEntry(id: "server", url: origin, fetchedName: "Fixture", lastUsedAt: Date())))
        let switched = await registry.switchTo(serverId: "server")
        XCTAssertTrue(switched)
        let auth = AuthService(serverRegistry: registry, launchPreferences: preferences, httpClient: http,
            tokenStore: second, defaults: defaults, sessionPersistence: memory.persistence("second"))
        let identity = await second.refreshAccountIdentity()
        try await auth.installSession(accessToken: "access-B", refreshToken: "refresh-B", accountID: "B",
            expectedAccount: try XCTUnwrap(identity))

        let (restarted, _, _) = try await harness(memory, persona: "first")
        let restored = await restarted.getAccessToken()
        XCTAssertEqual(restored, "access-A")
        let selected = await second.getAccessToken()
        XCTAssertEqual(selected, "access-B")
    }

    func testRollbackRestoresPreviousSelectionAndPreexistingDestination() async throws {
        let memory = TVLifecycleMemory()
        let (first, _, _) = try await harness(memory, persona: "first")
        let (second, _, _) = try await harness(memory, persona: "second")
        try await first.installAccountSession(accessToken: "access-A", refreshToken: "refresh-A", accountID: "A")
        try await second.installAccountSession(accessToken: "old-B", refreshToken: "old-refresh-B", accountID: "B")
        let before = await first.accountSessionSnapshot(for: "server")

        try await first.installAccountSession(accessToken: "replacement-B", refreshToken: "replacement-refresh-B", accountID: "B")
        let rolledBack = await first.restoreAccountSession(before, for: "server")

        XCTAssertTrue(rolledBack)
        let selected = await first.getAccessToken()
        XCTAssertEqual(selected, "access-A")
        let (restarted, _, _) = try await harness(memory, persona: "second")
        let other = await restarted.getAccessToken()
        XCTAssertEqual(other, "old-B")
    }

    #if os(tvOS)
    @MainActor
    func testChoosingAnotherAccountRejectsAStaleOwnerAndDoesNotRevokeSavedAccounts() async throws {
        let memory = TVLifecycleMemory()
        let (store, keys, defaults) = try await harness(memory, persona: "first")
        defaults.set(true, forKey: ServerRegistry.migratedKey)
        let preferences = ProfileLaunchPreferences(defaults: defaults)
        let stub = APIv2TestStub()
        let http = HTTPClient(session: stub.makeSession(), tokenStore: store)
        let registry = ServerRegistry(defaults: defaults, keychain: keys, launchPreferences: preferences,
            tokenStore: store, httpClient: http)
        XCTAssertNotNil(registry.addOrUpdate(ServerEntry(id: "server", url: origin, fetchedName: "Fixture", lastUsedAt: Date())))
        let switched = await registry.switchTo(serverId: "server")
        XCTAssertTrue(switched)
        let auth = AuthService(serverRegistry: registry, launchPreferences: preferences, httpClient: http,
            tokenStore: store, defaults: defaults, sessionPersistence: memory.persistence("first"))
        try await store.installAccountSession(accessToken: "access-A", refreshToken: "refresh-A", accountID: "A")
        let oldIdentity = await store.refreshAccountIdentity()
        memory.copySelection(from: "first", to: "saved-A")
        try await store.installAccountSession(accessToken: "access-B", refreshToken: "refresh-B", accountID: "B")
        let currentIdentity = await store.refreshAccountIdentity()
        memory.copySelection(from: "first", to: "saved-B")
        let requestCount = stub.requests.count

        let refused = await auth.beginAnotherAccount(expectedAccount: try XCTUnwrap(oldIdentity))
        XCTAssertFalse(refused)
        let stillB = await store.getAccessToken()
        XCTAssertEqual(stillB, "access-B")
        let changed = await auth.beginAnotherAccount(expectedAccount: try XCTUnwrap(currentIdentity))

        XCTAssertTrue(changed)
        let selected = await store.getAccessToken()
        XCTAssertNil(selected)
        guard case .session(let savedA) = try memory.persistence("saved-A").load("server"),
              case .session(let savedB) = try memory.persistence("saved-B").load("server") else {
            return XCTFail("Choosing another account revoked a saved session")
        }
        XCTAssertEqual(savedA.accessToken, "access-A")
        XCTAssertEqual(savedB.accessToken, "access-B")
        XCTAssertEqual(stub.requests.count, requestCount, "Account selection must not send logout")
    }

    func testAccountProfilesAndPINProofsRestoreIndependentlyAfterRelaunch() async throws {
        let memory = TVLifecycleMemory()
        let (store, keys, defaults) = try await harness(memory, persona: "first")
        let preferences = ProfileLaunchPreferences(defaults: defaults)
        preferences.behavior = .automatic
        try await store.installAccountSession(accessToken: "access-A", refreshToken: "refresh-A", accountID: "A")
        let epochA = await store.getOrCreateAccountEpoch()
        _ = await store.setProfileToken("proof-A")
        preferences.remember(profileID: "profile-A", requiresPIN: true, accountEpoch: try XCTUnwrap(epochA), for: "server")
        memory.copySelection(from: "first", to: "saved-A")

        try await store.installAccountSession(accessToken: "access-B", refreshToken: "refresh-B", accountID: "B")
        let freshBProof = await store.getProfileToken()
        XCTAssertNil(freshBProof)
        let epochB = await store.getOrCreateAccountEpoch()
        _ = await store.setProfileToken("proof-B")
        preferences.remember(profileID: "profile-B", requiresPIN: true, accountEpoch: try XCTUnwrap(epochB), for: "server")
        memory.copySelection(from: "saved-A", to: "first")

        let restarted = TokenStore(keychain: keys, defaults: defaults, sessionPersistence: memory.persistence("first"))
        await restarted.switchActiveServer(serverId: "server")
        let restoredProof = await restarted.getProfileToken()
        let restoredAccess = await restarted.getAccessToken()
        let restartedPreferences = ProfileLaunchPreferences(defaults: defaults)
        XCTAssertTrue(restartedPreferences.activateAccount(for: "server", accountEpoch: epochA))
        XCTAssertEqual(restoredAccess, "access-A")
        XCTAssertEqual(restoredProof, "proof-A")
        XCTAssertEqual(restartedPreferences.resolution(for: "server", accountEpoch: epochA,
            hasStoredProfileToken: restoredProof != nil), .restore(RememberedProfile(profileID: "profile-A",
                requiredPINAtSelection: true, accountEpoch: try XCTUnwrap(epochA))))
        XCTAssertEqual(keys.withAudience(.currentUser).get(SharedStorage.profileTokenAccount(for: "server", accountID: "B")), "proof-B")
    }

    func testRemovingServerErasesAllCurrentUserAccountProofs() async throws {
        let memory = TVLifecycleMemory()
        let (store, keys, _) = try await harness(memory, persona: "first")
        try await store.installAccountSession(accessToken: "access-A", refreshToken: "refresh-A", accountID: "A")
        _ = await store.setProfileToken("proof-A")
        try await store.installAccountSession(accessToken: "access-B", refreshToken: "refresh-B", accountID: "B")
        _ = await store.setProfileToken("proof-B")

        let removed = await store.deleteTokens(for: "server")

        XCTAssertTrue(removed)
        for accountID in ["A", "B"] {
            XCTAssertNil(keys.withAudience(.currentUser).get(SharedStorage.profileTokenAccount(for: "server", accountID: accountID)))
        }
        XCTAssertEqual(try memory.persistence("new").load("server"), .signedOut)
    }
    #endif

    func testLateRefreshRejectionCannotClearAReplacementSelectedInStorage() async throws {
        let memory = TVLifecycleMemory()
        let (store, _, _) = try await harness(memory, persona: "first")
        try await store.installAccountSession(accessToken: "access-A", refreshToken: "refresh-A", accountID: "A")
        let identity = await store.refreshAccountIdentity()
        let captured = await store.captureRefreshCredential(expected: try XCTUnwrap(identity))
        let replacement = CanonicalAccountSession(version: 1, signedOut: false, origin: origin,
            accountID: "B", epoch: UUID(), accessToken: "access-B", refreshToken: "refresh-B")
        _ = try memory.persistence("first").installAccountSession(replacement, serverID: "server")

        let outcome = await store.invalidateRejectedRefresh(try XCTUnwrap(captured))

        XCTAssertNil(outcome)
        XCTAssertEqual(try memory.persistence("first").load("server"), .session(replacement))
    }
}

private final class TVLifecycleMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var shared: [String: String] = [:]
    private var selections: [String: [String: String]] = [:]

    func copySelection(from source: String, to destination: String) {
        lock.withLock { selections[destination] = selections[source] }
    }

    func persistence(_ persona: String) -> AccountSessionPersistence {
        AccountSessionPersistence(tvStorage: TVAccountSessionStorage(
            sharedRead: { key in self.lock.withLock { self.shared[key] } },
            sharedWrite: { value, key in self.lock.withLock { self.shared[key] = value; return true } },
            sharedRemove: { key in self.lock.withLock { self.shared[key] = nil; return true } },
            selectionRead: { key in self.lock.withLock { self.selections[persona]?[key] } },
            selectionWrite: { value, key in self.lock.withLock { self.selections[persona, default: [:]][key] = value; return true } },
            selectionRemove: { key in self.lock.withLock { self.selections[persona]?[key] = nil; return true } }))
    }
}
