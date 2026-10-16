import Foundation
import XCTest
@testable import Silo

#if os(tvOS)
/// These use the production TV Keychain audiences and TokenStore integration.
/// Removing only the local selector exercises the unconfigured inheritance path;
/// it does not pretend to switch the simulator's actual Apple TV system user.
final class TVLegacyAccountMigrationTests: XCTestCase {
    private let serverID = "migration-server"
    private let origin = "https://migration.example"

    func testRawLegacyBindingCreatesOneAuthorityAndLogoutCannotRestoreAnInheritedCopy() async throws {
        let h = try harness()
        let epoch = UUID()
        try seedRaw(h, access: "legacy-access-A", refresh: "legacy-refresh-A", epoch: epoch)
        let store = await activeStore(h)
        let captured = await store.captureOrdinaryRequestAuth()
        let expected = try XCTUnwrap(captured)
        XCTAssertEqual(expected.accessToken, "legacy-access-A")

        try await store.bindVerifiedAccount("account-A", expected: expected)

        let boundValue = await store.captureDurableAccountAuth()
        let bound = try XCTUnwrap(boundValue)
        XCTAssertEqual(bound.accountID, "account-A")
        XCTAssertEqual(bound.accountEpoch, epoch)
        XCTAssertEqual(try h.sessions.savedAccountIDs(for: serverID), ["account-A"])
        let envelope = try XCTUnwrap(h.account.getChecked(TVAccountSessionStorage.recordKey(serverID)))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(envelope.utf8)) as? [String: Any])
        XCTAssertEqual((json["sessions"] as? [String: Any])?.count, 1)
        XCTAssertNil(try h.profile.getChecked(TVAccountSessionStorage.selectionKey(serverID)))

        let cleared = await store.clearTokens()
        XCTAssertTrue(cleared)
        XCTAssertEqual(try h.sessions.load(serverID), .signedOut)
        XCTAssertTrue(h.profile.delete(TVAccountSessionStorage.selectionKey(serverID)))
        let restarted = await activeStore(h)
        let inheritedAccess = await restarted.getAccessToken()
        XCTAssertNil(inheritedAccess)
        XCTAssertEqual(try h.sessions.load(serverID), .signedOut)
    }

    func testVerifiedCanonicalMigratesLegacyPINProofOnlyForMatchingRememberedEpoch() async throws {
        for matchesEpoch in [true, false] {
            let h = try harness()
            let session = canonical("account-A")
            try seedLegacyCanonical(session, in: h)
            XCTAssertTrue(h.profile.set("legacy-PIN-proof", for: TokenStore.profileTokenKey(for: serverID)))
            let sessionEpoch = try XCTUnwrap(session.epoch).uuidString
            let remembered = RememberedProfile(profileID: "profile-A", requiredPINAtSelection: true,
                accountEpoch: matchesEpoch ? sessionEpoch : UUID().uuidString)
            h.defaults.set(try JSONEncoder().encode(ProfileLaunchState(rememberedByServerID: [serverID: remembered])),
                forKey: SharedStorage.profileLaunchStateKey)

            let store = await activeStore(h)
            let proof = await store.getProfileToken()

            XCTAssertEqual(proof, matchesEpoch ? "legacy-PIN-proof" : nil)
            XCTAssertEqual(try h.profile.getChecked(SharedStorage.profileTokenAccount(for: serverID, accountID: "account-A")),
                matchesEpoch ? "legacy-PIN-proof" : nil)
            XCTAssertNil(try h.account.getChecked(TVAccountSessionStorage.recordKey(serverID)),
                "Restoration must not migrate the session schema while reading")
        }
    }

    func testVerifiedAccountProofIsNotOverwrittenByLegacyPINProof() async throws {
        let h = try harness()
        let session = canonical("account-A")
        try seedLegacyCanonical(session, in: h)
        XCTAssertTrue(h.profile.set("legacy-proof", for: TokenStore.profileTokenKey(for: serverID)))
        let accountKey = SharedStorage.profileTokenAccount(for: serverID, accountID: "account-A")
        XCTAssertTrue(h.profile.set("account-A-proof", for: accountKey))
        let remembered = RememberedProfile(profileID: "profile-A", requiredPINAtSelection: true,
            accountEpoch: try XCTUnwrap(session.epoch).uuidString)
        h.defaults.set(try JSONEncoder().encode(ProfileLaunchState(rememberedByServerID: [serverID: remembered])),
            forKey: SharedStorage.profileLaunchStateKey)

        let store = await activeStore(h)
        let proof = await store.getProfileToken()

        XCTAssertEqual(proof, "account-A-proof")
        XCTAssertEqual(try h.profile.getChecked(accountKey), "account-A-proof")
    }

    func testFailedSignOutAndServerRemovalPreserveRawLegacyAuthorityForRelaunch() async throws {
        for removesServer in [false, true] {
            let h = try harness()
            let epoch = UUID()
            try seedRaw(h, access: "legacy-access-A", refresh: "legacy-refresh-A", epoch: epoch)
            let store = await activeStore(h, sessions: selectorRejectingPersistence(h))

            let removed: Bool
            if removesServer { removed = await store.deleteTokens(for: serverID) }
            else { removed = await store.clearTokens() }

            XCTAssertFalse(removed)
            XCTAssertEqual(try h.account.getChecked(TokenStore.accessTokenKey(for: serverID)), "legacy-access-A")
            XCTAssertEqual(try h.account.getChecked(TokenStore.refreshTokenKey(for: serverID)), "legacy-refresh-A")
            XCTAssertEqual(try h.account.getChecked(TokenStore.accountEpochKey(for: serverID)), epoch.uuidString)
            let restarted = await activeStore(h)
            let restoredAccess = await restarted.getAccessToken()
            XCTAssertEqual(restoredAccess, "legacy-access-A")
        }
    }

    @MainActor
    func testAdoptedRegistryDoesNotBindOldProfileToLastActiveRawMirrorEpoch() throws {
        let h = try harness()
        let accountA = canonical("account-A")
        try h.sessions.save(accountA, serverID: serverID)
        let mirrorEpoch = UUID()
        try seedRaw(h, access: "last-mirror-B", refresh: "last-refresh-B", epoch: mirrorEpoch)
        XCTAssertTrue(h.profile.set("old-profile-proof", for: TokenStore.profileTokenKey(for: serverID)))
        let legacy = LegacyRegistry(activeServerId: serverID,
            entries: [ServerEntry(id: serverID, url: origin, fetchedName: "Migration Test",
                profileId: "old-profile-A", lastUsedAt: Date(timeIntervalSinceReferenceDate: 1))])
        h.defaults.set(try JSONEncoder().encode(legacy), forKey: ServerRegistry.defaultsKey)
        h.defaults.set(true, forKey: ServerRegistry.migratedKey)
        let preferences = ProfileLaunchPreferences(defaults: h.defaults)
        let store = TokenStore(keychain: h.keychain, defaults: h.defaults)
        let http = HTTPClient(tokenStore: store)

        let registry = ServerRegistry(defaults: h.defaults, keychain: h.keychain,
            launchPreferences: preferences, tokenStore: store, httpClient: http)

        XCTAssertNil(registry.entry(with: serverID)?.legacyProfileId)
        XCTAssertNil(preferences.rememberedProfile(for: serverID))
        XCTAssertNil(preferences.rememberedProfile(for: serverID, accountEpoch: mirrorEpoch.uuidString))
        XCTAssertEqual(try h.sessions.load(serverID), .session(accountA))
    }

    @MainActor
    func testFailedLoginSelectorWriteRestoresRawLegacyAccountImmediatelyAndAfterRestart() async throws {
        let h = try harness()
        let epoch = UUID()
        try seedRaw(h, access: "legacy-access-A", refresh: "legacy-refresh-A", epoch: epoch)
        XCTAssertTrue(h.profile.set("legacy-proof-A", for: TokenStore.profileTokenKey(for: serverID)))
        let persistence = selectorRejectingPersistence(h)
        let store = await activeStore(h, sessions: persistence)
        await store.setProfileId("profile-A")
        let preferences = ProfileLaunchPreferences(defaults: h.defaults)
        preferences.behavior = .automatic
        XCTAssertTrue(preferences.remember(profileID: "profile-A", requiresPIN: true,
            accountEpoch: epoch.uuidString, for: serverID))
        let previousPreferences = preferences.state
        let stub = APIv2TestStub()
        stub.reply(200, #"{"access_token":"login-B","refresh_token":"refresh-B","expires_in":3600,"user":{"id":"account-B","username":"B","email":"b@example.test","role":"user","permissions":[],"download_allowed":true}}"#)
        let http = HTTPClient(session: stub.makeSession(), tokenStore: store)
        let registry = ServerRegistry(defaults: h.defaults, keychain: h.keychain,
            launchPreferences: preferences, tokenStore: store, httpClient: http)
        // An empty test registry clears its active URL. The test explicitly
        // supplies its synthetic origin without performing discovery or I/O.
        await store.setServerUrl(origin)
        let auth = AuthService(serverRegistry: registry, launchPreferences: preferences,
            apiV2Client: APIv2Client(http: http, tokenStore: store, isUpdateRequired: { false }),
            httpClient: http, tokenStore: store, defaults: h.defaults, sessionPersistence: persistence,
            purgeDiagnostics: { _ in true }, unregisterPush: { _ in })

        do {
            try await auth.login(username: "B", password: "synthetic-password")
            XCTFail("A login whose selector could not be saved succeeded")
        } catch AccountSessionPersistenceError.unavailable {}

        let access = await store.getAccessToken()
        let profile = await store.getProfileId()
        let proof = await store.getProfileToken()
        XCTAssertEqual(access, "legacy-access-A")
        XCTAssertEqual(profile, "profile-A")
        XCTAssertEqual(proof, "legacy-proof-A")
        XCTAssertEqual(preferences.state, previousPreferences)
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/auth/login"])
        let restarted = await activeStore(h)
        let reopenedAccess = await restarted.getAccessToken()
        let reopenedProof = await restarted.getProfileToken()
        XCTAssertEqual(reopenedAccess, "legacy-access-A")
        XCTAssertEqual(reopenedProof, "legacy-proof-A")
    }

    private struct LegacyRegistry: Codable {
        let activeServerId: String?
        let entries: [ServerEntry]
    }

    private struct Harness {
        let keychain: SharedKeychain
        let defaults: SharedDefaults
        var account: SharedKeychain { keychain.withAudience(.userIndependent) }
        var profile: SharedKeychain { keychain.withAudience(.currentUser) }
        var sessions: AccountSessionPersistence { AccountSessionPersistence(keychain: keychain) }
    }

    private func harness() throws -> Harness {
        let name = "TVLegacyAccountMigrationTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defaults.set(origin, forKey: SharedStorage.serverUrlKey)
        defaults.set(true, forKey: ServerRegistry.migratedKey)
        let keychain = SharedKeychain(service: name, accessGroup: nil,
            usesUserIndependentKeychain: true, allowsAppLocalFallback: false)
        let keys = [AccountSessionPersistence.recordKey(serverID), AccountSessionPersistence.markerKey(serverID),
            TVAccountSessionStorage.recordKey(serverID), TVAccountSessionStorage.markerKey(serverID),
            TVAccountSessionStorage.selectionKey(serverID), TokenStore.accessTokenKey(for: serverID),
            TokenStore.refreshTokenKey(for: serverID), TokenStore.accountEpochKey(for: serverID),
            TokenStore.profileTokenKey(for: serverID),
            SharedStorage.profileTokenAccount(for: serverID, accountID: "account-A"),
            SharedStorage.profileTokenAccount(for: serverID, accountID: "account-B"),
            SharedStorage.mirroredAccessTokenAccount, SharedStorage.mirroredProfileTokenAccount,
            SharedStorage.keychainAccountPrefix + "serverRegistry.v2"]
        addTeardownBlock {
            for audience in [KeychainAudience.currentUser, .userIndependent] {
                for key in keys { keychain.withAudience(audience).delete(key) }
            }
            suite.removePersistentDomain(forName: name)
        }
        return Harness(keychain: keychain, defaults: defaults)
    }

    private func activeStore(_ h: Harness, sessions: AccountSessionPersistence? = nil) async -> TokenStore {
        h.defaults.set(origin, forKey: SharedStorage.serverUrlKey)
        let store = TokenStore(keychain: h.keychain, defaults: h.defaults, sessionPersistence: sessions)
        await store.switchActiveServer(serverId: serverID)
        return store
    }

    private func selectorRejectingPersistence(_ h: Harness) -> AccountSessionPersistence {
        AccountSessionPersistence(tvStorage: TVAccountSessionStorage(
            sharedRead: { try h.account.getChecked($0) }, sharedWrite: { h.account.set($0, for: $1) },
            sharedRemove: { h.account.delete($0) },
            selectionRead: { try h.profile.getChecked($0) }, selectionWrite: { _, _ in false },
            selectionRemove: { h.profile.delete($0) }))
    }

    private func seedRaw(_ h: Harness, access: String, refresh: String, epoch: UUID) throws {
        XCTAssertTrue(h.account.set(access, for: TokenStore.accessTokenKey(for: serverID)))
        XCTAssertTrue(h.account.set(refresh, for: TokenStore.refreshTokenKey(for: serverID)))
        XCTAssertTrue(h.account.set(epoch.uuidString, for: TokenStore.accountEpochKey(for: serverID)))
    }

    private func seedLegacyCanonical(_ value: CanonicalAccountSession, in h: Harness) throws {
        let raw = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        XCTAssertTrue(h.account.set("1", for: AccountSessionPersistence.markerKey(serverID)))
        XCTAssertTrue(h.account.set(raw, for: AccountSessionPersistence.recordKey(serverID)))
    }

    private func canonical(_ accountID: String) -> CanonicalAccountSession {
        CanonicalAccountSession(version: 1, signedOut: false, origin: origin, accountID: accountID,
            epoch: UUID(), accessToken: "access-\(accountID)", refreshToken: "refresh-\(accountID)")
    }
}
#endif
