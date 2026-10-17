import Foundation
import XCTest
@testable import Silo

final class TopShelfAccountSessionTests: XCTestCase {
    private static let sectionsPath = "/api/v2/home/sections"

    /// Exercises the production TV envelope and selector without requiring an
    /// XCTest runner to switch its own tvOS persona.
    private final class Storage: @unchecked Sendable {
        private let lock = NSLock()
        private var shared: [String: String] = [:]
        private var selections: [String: [String: String]] = [:]
        private var user = "first"
        private var writes = 0

        var writeCount: Int { lock.withLock { writes } }

        func switchUser(_ user: String) { lock.withLock { self.user = user } }

        func corruptSelection() {
            _ = writeSelection("invalid selector", for: TVAccountSessionStorage.selectionKey("server"))
        }

        func corruptEnvelope() {
            _ = writeShared("invalid envelope", for: TVAccountSessionStorage.recordKey("server"))
        }

        func persistence() -> AccountSessionPersistence {
            AccountSessionPersistence(tvStorage: TVAccountSessionStorage(
                sharedRead: { self.readShared($0) },
                sharedWrite: { self.writeShared($0, for: $1) },
                sharedRemove: { self.removeShared($0) },
                selectionRead: { self.readSelection($0) },
                selectionWrite: { self.writeSelection($0, for: $1) },
                selectionRemove: { self.removeSelection($0) }
            ))
        }

        private func readShared(_ key: String) -> String? { lock.withLock { shared[key] } }
        private func readSelection(_ key: String) -> String? { lock.withLock { selections[user]?[key] } }

        private func writeShared(_ value: String, for key: String) -> Bool {
            lock.withLock { shared[key] = value; writes += 1; return true }
        }

        private func writeSelection(_ value: String, for key: String) -> Bool {
            lock.withLock { selections[user, default: [:]][key] = value; writes += 1; return true }
        }

        private func removeShared(_ key: String) -> Bool {
            lock.withLock { shared.removeValue(forKey: key); writes += 1; return true }
        }

        private func removeSelection(_ key: String) -> Bool {
            lock.withLock { selections[user]?.removeValue(forKey: key); writes += 1; return true }
        }
    }

    private struct Harness {
        let client: TopShelfHTTPClient
        let storage: Storage
        let sessions: AccountSessionPersistence
        let defaults: UserDefaults
        let stub: APIv2TestStub
        let keychain: SharedKeychain
        let account: CanonicalAccountSession

        func remember(_ account: CanonicalAccountSession, requiresPIN: Bool = false) throws {
            let epoch = try XCTUnwrap(account.epoch).uuidString
            let state = ProfileLaunchState(rememberedByServerID: [
                "server": RememberedProfile(profileID: "profile", requiredPINAtSelection: requiresPIN,
                    accountEpoch: epoch),
            ])
            defaults.set(try JSONEncoder().encode(state), forKey: SharedStorage.profileLaunchStateKey)
        }
    }

    private func session(accountID: String = "account-b", epoch: UUID = UUID(),
                         origin: String = "https://media.example") -> CanonicalAccountSession {
        CanonicalAccountSession(version: 1, signedOut: false, origin: origin, accountID: accountID,
            epoch: epoch, accessToken: "access-\(accountID)", refreshToken: "refresh-\(accountID)")
    }

    private func harness(account: CanonicalAccountSession? = nil) throws -> Harness {
        let name = "TopShelfAccountSessionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        let shared = keychain.withAudience(.userIndependent)
        let profile = keychain.withAudience(.currentUser)
        addTeardownBlock {
            for key in [SharedStorage.accessTokenAccount(for: "server"),
                        SharedStorage.refreshTokenAccount(for: "server"),
                        SharedStorage.accountEpochAccount(for: "server"),
                        AccountSessionPersistence.recordKey("server"),
                        AccountSessionPersistence.markerKey("server"),
                        TVAccountSessionStorage.recordKey("server"),
                        TVAccountSessionStorage.markerKey("server")] {
                _ = shared.delete(key)
            }
            _ = profile.delete(TVAccountSessionStorage.selectionKey("server"))
            _ = profile.delete(SharedStorage.profileTokenAccount(for: "server"))
            #if os(tvOS)
            _ = profile.delete(SharedStorage.profileTokenAccount(for: "server", accountID: "account-b"))
            #endif
            UserDefaults().removePersistentDomain(forName: name)
        }
        // Stale shared mirrors must never override an adopted TV envelope.
        XCTAssertTrue(shared.set("raw-access", for: SharedStorage.accessTokenAccount(for: "server")))
        XCTAssertTrue(shared.set("raw-refresh", for: SharedStorage.refreshTokenAccount(for: "server")))
        XCTAssertTrue(shared.set("raw-epoch", for: SharedStorage.accountEpochAccount(for: "server")))
        defaults.set("server", forKey: SharedStorage.activeServerIdKey)
        defaults.set("https://media.example", forKey: SharedStorage.serverUrlKey)
        defaults.set("profile", forKey: SharedStorage.profileIdKey)
        let storage = Storage()
        let sessions = storage.persistence()
        _ = try sessions.installAccountSession(session(accountID: "account-a"), serverID: "server")
        storage.switchUser("second")
        let account = account ?? session()
        _ = try sessions.installAccountSession(account, serverID: "server")
        let stub = APIv2TestStub()
        let client = TopShelfHTTPClient(defaults: SharedDefaults(suite: defaults, standard: defaults),
            keychain: keychain, session: stub.makeSession(), sessions: sessions)
        let harness = Harness(client: client, storage: storage, sessions: sessions, defaults: defaults,
            stub: stub, keychain: keychain, account: account)
        try harness.remember(account)
        return harness
    }

    func testSelectedCanonicalAccountOverridesRawMirrorsWithoutWritingStorage() async throws {
        let h = try harness()
        let writesBefore = h.storage.writeCount
        let client = try XCTUnwrap(h.client.authenticated())
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)

        XCTAssertTrue(client.isPersonalizedContentAllowed)
        _ = try await client.fetchHomeSections(imageSizeQuery: [:])

        XCTAssertEqual(h.stub.requests.first?.header("Authorization"), "Bearer access-account-b")
        XCTAssertEqual(h.storage.writeCount, writesBefore)
    }

    func testDefaultClientUsesCanonicalPersistenceBeforeRawMirrors() async throws {
        let h = try harness()
        try AccountSessionPersistence(keychain: h.keychain).save(h.account, serverID: "server")
        let client = try XCTUnwrap(TopShelfHTTPClient(
            defaults: SharedDefaults(suite: h.defaults, standard: h.defaults), keychain: h.keychain,
            session: h.stub.makeSession()).authenticated())
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)

        _ = try await client.fetchHomeSections(imageSizeQuery: [:])

        XCTAssertEqual(h.stub.requests.first?.header("Authorization"), "Bearer access-account-b")
    }

    func testReadingTopShelfDoesNotMigrateAnOldKeychainService() throws {
        let h = try harness()
        let account = SharedStorage.accessTokenAccount(for: "server")
        let oldAccount = SharedStorage.legacyKeychainAccount(for: account)
        let oldService = "TopShelfOldService.\(UUID())"
        let legacy = SharedKeychain(service: oldService, accessGroup: nil).withAudience(.userIndependent)
        addTeardownBlock { _ = legacy.delete(oldAccount) }
        XCTAssertTrue(h.keychain.withAudience(.userIndependent).delete(account))
        XCTAssertTrue(legacy.set("old-service-access", for: oldAccount))
        let migratingKeychain = SharedKeychain(service: h.keychain.service, accessGroup: nil,
            legacyService: oldService)
        let client = TopShelfHTTPClient(defaults: SharedDefaults(suite: h.defaults, standard: h.defaults),
            keychain: migratingKeychain, session: h.stub.makeSession())

        XCTAssertNil(client.authenticated())
        XCTAssertNil(try h.keychain.withAudience(.userIndependent).getChecked(account))
        XCTAssertEqual(legacy.get(oldAccount), "old-service-access")
    }

    func testRefreshUsesTheSelectedCanonicalAccountWithoutPersistingIt() async throws {
        let h = try harness()
        let writesBefore = h.storage.writeCount
        let client = try XCTUnwrap(h.client.authenticated())
        h.stub.sequence(path: Self.sectionsPath, [.json(401, "{}")])
        h.stub.reply(path: "/api/v2/auth/refresh", 200,
            #"{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":28800}"#)
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)

        _ = try await client.fetchHomeSections(imageSizeQuery: [:])

        XCTAssertEqual(h.stub.requests[1].bodyString, #"{"refresh_token":"refresh-account-b"}"#)
        XCTAssertEqual(h.storage.writeCount, writesBefore)
    }

    func testAUserWithoutASelectorStillUsesTheSharedFamilyDefault() async throws {
        let h = try harness()
        h.storage.switchUser("unselected")
        guard case .session(let shared) = try h.sessions.load("server") else {
            return XCTFail("Expected the shared family default")
        }
        try h.remember(shared)
        let client = try XCTUnwrap(h.client.authenticated())
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)

        _ = try await client.fetchHomeSections(imageSizeQuery: [:])

        XCTAssertEqual(h.stub.requests.first?.header("Authorization"), "Bearer access-account-a")
    }

    func testAnExplicitSignOutNeverFallsBackToRawMirrors() throws {
        let h = try harness()
        XCTAssertTrue(h.sessions.deselectAccount(serverID: "server"))

        XCTAssertNil(h.client.authenticated())
        XCTAssertFalse(h.client.isPersonalizedContentAllowed)
    }

    func testCorruptSelectorNeverFallsBackToRawMirrors() throws {
        let h = try harness()
        h.storage.corruptSelection()

        XCTAssertNil(h.client.authenticated())
        XCTAssertFalse(h.client.isPersonalizedContentAllowed)
    }

    func testCorruptEnvelopeNeverFallsBackToRawMirrors() throws {
        let h = try harness()
        h.storage.corruptEnvelope()

        XCTAssertNil(h.client.authenticated())
        XCTAssertFalse(h.client.isPersonalizedContentAllowed)
    }

    func testCanonicalCredentialsBoundToAnotherOriginAreNotReleased() throws {
        let h = try harness(account: session(origin: "https://other.example"))

        XCTAssertNil(h.client.authenticated())
        XCTAssertFalse(h.client.isPersonalizedContentAllowed)
    }

    func testCanonicalOriginAllowsTheNormalizedSavedAddress() async throws {
        let h = try harness()
        h.defaults.set(" https://media.example/// \n", forKey: SharedStorage.serverUrlKey)
        let client = try XCTUnwrap(h.client.authenticated())
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)

        _ = try await client.fetchHomeSections(imageSizeQuery: [:])

        XCTAssertEqual(h.stub.requests.first?.header("Authorization"), "Bearer access-account-b")
    }

    func testAccountChangeWithTheSameEpochCannotPublishAnInFlightResponse() async throws {
        let epoch = UUID()
        let h = try harness(account: session(epoch: epoch))
        let client = try XCTUnwrap(h.client.authenticated())
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)
        h.stub.hold(path: Self.sectionsPath)
        let request = Task { try await client.fetchHomeSections(imageSizeQuery: [:]) }
        await h.stub.waitUntilHeld()

        _ = try h.sessions.installAccountSession(session(accountID: "account-c", epoch: epoch), serverID: "server")
        XCTAssertTrue(h.client.isPersonalizedContentAllowed)
        h.stub.release()

        await assertNotAuthenticated(request)
        XCTAssertFalse(client.isCurrentScope)
    }

    func testEpochChangeCannotPublishAnInFlightResponse() async throws {
        let h = try harness()
        let client = try XCTUnwrap(h.client.authenticated())
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)
        h.stub.hold(path: Self.sectionsPath)
        let request = Task { try await client.fetchHomeSections(imageSizeQuery: [:]) }
        await h.stub.waitUntilHeld()

        let replacement = session()
        _ = try h.sessions.installAccountSession(replacement, serverID: "server")
        try h.remember(replacement)
        XCTAssertTrue(h.client.isPersonalizedContentAllowed)
        h.stub.release()

        await assertNotAuthenticated(request)
        XCTAssertFalse(client.isCurrentScope)
    }

    func testAccountChangeDuringARejectedRequestDoesNotRefresh() async throws {
        let epoch = UUID()
        let h = try harness(account: session(epoch: epoch))
        let client = try XCTUnwrap(h.client.authenticated())
        h.stub.reply(path: Self.sectionsPath, 401, "{}")
        h.stub.hold(path: Self.sectionsPath)
        let request = Task { try await client.fetchHomeSections(imageSizeQuery: [:]) }
        await h.stub.waitUntilHeld()

        _ = try h.sessions.installAccountSession(session(accountID: "account-c", epoch: epoch), serverID: "server")
        h.stub.release()

        await assertNotAuthenticated(request)
        XCTAssertEqual(h.stub.requestedPaths, [Self.sectionsPath])
    }

    func testSigningOutDuringRefreshSendsNoRetry() async throws {
        let h = try harness()
        let client = try XCTUnwrap(h.client.authenticated())
        h.stub.sequence(path: Self.sectionsPath, [.json(401, "{}")])
        h.stub.reply(path: "/api/v2/auth/refresh", 200,
            #"{"access_token":"fresh-access","refresh_token":"fresh-refresh","expires_in":28800}"#)
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)
        h.stub.hold(path: "/api/v2/auth/refresh")
        let request = Task { try await client.fetchHomeSections(imageSizeQuery: [:]) }
        await h.stub.waitUntilHeld()

        XCTAssertTrue(h.sessions.deselectAccount(serverID: "server"))
        h.stub.release()

        await assertNotAuthenticated(request)
        XCTAssertEqual(h.stub.requestedPaths, [Self.sectionsPath, "/api/v2/auth/refresh"])
    }

    func testAnOriginChangeCannotPublishAnInFlightResponse() async throws {
        let h = try harness()
        let client = try XCTUnwrap(h.client.authenticated())
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)
        h.stub.hold(path: Self.sectionsPath)
        let request = Task { try await client.fetchHomeSections(imageSizeQuery: [:]) }
        await h.stub.waitUntilHeld()

        h.defaults.set("https://other.example", forKey: SharedStorage.serverUrlKey)
        h.stub.release()

        await assertNotAuthenticated(request)
        XCTAssertFalse(client.isCurrentScope)
    }

    func testProfileProofReplacementCannotPublishAnInFlightResponse() async throws {
        let h = try harness()
        let profile = h.keychain.withAudience(.currentUser)
        let key = SharedStorage.profileTokenAccount(for: "server", accountID: "account-b")
        XCTAssertTrue(profile.set("initial-profile-proof", for: key))
        let client = try XCTUnwrap(h.client.authenticated())
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)
        h.stub.hold(path: Self.sectionsPath)
        let request = Task { try await client.fetchHomeSections(imageSizeQuery: [:]) }
        await h.stub.waitUntilHeld()

        XCTAssertTrue(profile.set("replacement-profile-proof", for: key))
        XCTAssertTrue(h.client.isPersonalizedContentAllowed)
        h.stub.release()

        await assertNotAuthenticated(request)
        XCTAssertFalse(client.isCurrentScope)
    }

    #if os(tvOS)
    func testProtectedProfileUsesOnlyTheSelectedAccountsProof() async throws {
        let h = try harness()
        let profile = h.keychain.withAudience(.currentUser)
        XCTAssertTrue(profile.set("old-account-proof", for: SharedStorage.profileTokenAccount(for: "server")))
        try h.remember(h.account, requiresPIN: true)
        XCTAssertFalse(h.client.isPersonalizedContentAllowed)
        XCTAssertTrue(profile.set("selected-account-proof",
            for: SharedStorage.profileTokenAccount(for: "server", accountID: "account-b")))
        XCTAssertTrue(h.client.isPersonalizedContentAllowed)
        let client = try XCTUnwrap(h.client.authenticated())
        h.stub.reply(path: Self.sectionsPath, 200, #"{"sections":[]}"#)

        _ = try await client.fetchHomeSections(imageSizeQuery: [:])

        XCTAssertEqual(h.stub.requests.first?.header("X-Profile-Token"), "selected-account-proof")
    }
    #endif

    private func assertNotAuthenticated<T>(_ task: Task<T, Error>,
                                            file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await task.value
            XCTFail("Expected no personalized content", file: file, line: line)
        } catch TopShelfHTTPClient.Error.notAuthenticated {
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }
}
