import XCTest
@testable import Silo

final class ProfileLaunchPolicyTests: XCTestCase {
    private let serverID = "server-a"
    private let accountEpoch = "account-a"

    func testDefaultStateUsesAutomaticAndRequiresAProfile() {
        let state = ProfileLaunchState()

        XCTAssertEqual(state.behavior, .automatic)
        XCTAssertEqual(
            state.resolution(
                for: serverID,
                accountEpoch: accountEpoch,
                hasStoredProfileToken: false
            ),
            .needsSelection
        )
    }

    func testAskEveryLaunchNeverRestoresRememberedProfile() {
        let remembered = RememberedProfile(
            profileID: "profile-a",
            requiredPINAtSelection: false,
            accountEpoch: accountEpoch
        )
        let state = ProfileLaunchState(
            behavior: .askEveryLaunch,
            rememberedByServerID: [serverID: remembered]
        )

        XCTAssertEqual(
            state.resolution(
                for: serverID,
                accountEpoch: accountEpoch,
                hasStoredProfileToken: true
            ),
            .needsSelection
        )
        XCTAssertEqual(state.rememberedByServerID[serverID], remembered)
    }

    func testAutomaticRestoresPINlessProfileOffline() {
        let remembered = RememberedProfile(
            profileID: "profile-a",
            requiredPINAtSelection: false,
            accountEpoch: accountEpoch
        )
        let state = ProfileLaunchState(
            rememberedByServerID: [serverID: remembered]
        )

        XCTAssertEqual(
            state.resolution(
                for: serverID,
                accountEpoch: accountEpoch,
                hasStoredProfileToken: false
            ),
            .restore(remembered)
        )
    }

    func testAutomaticRequiresProtectedProfileProofAndMatchingAccount() {
        let remembered = RememberedProfile(
            profileID: "profile-a",
            requiredPINAtSelection: true,
            accountEpoch: accountEpoch
        )
        let state = ProfileLaunchState(
            rememberedByServerID: [serverID: remembered]
        )

        XCTAssertEqual(
            state.resolution(
                for: serverID,
                accountEpoch: accountEpoch,
                hasStoredProfileToken: false
            ),
            .needsSelection
        )
        XCTAssertEqual(
            state.resolution(
                for: serverID,
                accountEpoch: "replacement-account",
                hasStoredProfileToken: true
            ),
            .needsSelection
        )
        XCTAssertEqual(
            state.resolution(
                for: serverID,
                accountEpoch: accountEpoch,
                hasStoredProfileToken: true
            ),
            .restore(remembered)
        )
    }

    func testPendingSwitchAndKnownDeletedProfileRequireSelection() {
        let remembered = RememberedProfile(
            profileID: "profile-a",
            requiredPINAtSelection: false,
            accountEpoch: accountEpoch
        )
        let pending = ProfileLaunchState(
            rememberedByServerID: [serverID: remembered],
            selectionRequiredServerIDs: [serverID]
        )
        let stale = ProfileLaunchState(
            rememberedByServerID: [serverID: remembered]
        )

        XCTAssertEqual(
            pending.resolution(
                for: serverID,
                accountEpoch: accountEpoch,
                hasStoredProfileToken: false
            ),
            .needsSelection
        )
        XCTAssertEqual(
            stale.resolution(
                for: serverID,
                accountEpoch: accountEpoch,
                hasStoredProfileToken: false,
                knownProfileIDs: ["profile-b"]
            ),
            .needsSelection
        )
    }

    func testRememberPersistsAndClearsPendingSwitch() throws {
        let suiteName = "ProfileLaunchPolicyTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defer { suite.removePersistentDomain(forName: suiteName) }

        let preferences = ProfileLaunchPreferences(defaults: defaults)
        preferences.behavior = .askEveryLaunch
        XCTAssertTrue(preferences.markSelectionRequired(for: serverID))
        preferences.remember(
            profileID: "profile-a",
            requiresPIN: true,
            accountEpoch: accountEpoch,
            for: serverID
        )

        let restored = ProfileLaunchPreferences(defaults: defaults)
        XCTAssertEqual(restored.behavior, .askEveryLaunch)
        XCTAssertEqual(
            restored.rememberedProfile(for: serverID),
            RememberedProfile(
                profileID: "profile-a",
                requiredPINAtSelection: true,
                accountEpoch: accountEpoch
            )
        )
        XCTAssertFalse(restored.state.selectionRequiredServerIDs.contains(serverID))
    }

    func testTopShelfRequiresAutomaticMatchingCurrentUserIdentity() {
        let pinless = RememberedProfile(
            profileID: "profile-a",
            requiredPINAtSelection: false,
            accountEpoch: accountEpoch
        )
        var state = ProfileLaunchState(
            rememberedByServerID: [serverID: pinless]
        )

        XCTAssertTrue(TopShelfProfilePolicy.allowsPersonalizedContent(
            state: state,
            serverID: serverID,
            activeProfileID: "profile-a",
            accountEpoch: accountEpoch,
            hasStoredProfileToken: false
        ))

        state.behavior = .askEveryLaunch
        XCTAssertFalse(TopShelfProfilePolicy.allowsPersonalizedContent(
            state: state,
            serverID: serverID,
            activeProfileID: "profile-a",
            accountEpoch: accountEpoch,
            hasStoredProfileToken: true
        ))

        state.behavior = .automatic
        state.selectionRequiredServerIDs.insert(serverID)
        XCTAssertFalse(TopShelfProfilePolicy.allowsPersonalizedContent(
            state: state,
            serverID: serverID,
            activeProfileID: "profile-a",
            accountEpoch: accountEpoch,
            hasStoredProfileToken: true
        ))
    }

    func testTopShelfRequiresCurrentUserProofForProtectedProfile() {
        let protected = RememberedProfile(
            profileID: "profile-a",
            requiredPINAtSelection: true,
            accountEpoch: accountEpoch
        )
        let state = ProfileLaunchState(
            rememberedByServerID: [serverID: protected]
        )

        XCTAssertFalse(TopShelfProfilePolicy.allowsPersonalizedContent(
            state: state,
            serverID: serverID,
            activeProfileID: "profile-a",
            accountEpoch: accountEpoch,
            hasStoredProfileToken: false
        ))
        XCTAssertTrue(TopShelfProfilePolicy.allowsPersonalizedContent(
            state: state,
            serverID: serverID,
            activeProfileID: "profile-a",
            accountEpoch: accountEpoch,
            hasStoredProfileToken: true
        ))
    }

    func testCredentialAudienceClassification() {
        XCTAssertEqual(TokenStore.accountCredentialAudience, .userIndependent)
        XCTAssertEqual(TokenStore.profileCredentialAudience, .currentUser)
    }
}

final class ProfileLaunchIdentityTests: XCTestCase {
    func testAccountEpochRotatesAndRejectsStaleActivation() async throws {
        let harness = try makeTokenHarness()
        defer { harness.cleanup() }
        await harness.store.switchActiveServer(serverId: harness.serverID)
        await harness.store.setServerUrl("https://silo.example")
        await harness.store.saveTokens(accessToken: "access-a", refreshToken: "refresh-a")

        let firstEpochValue = await harness.store.getOrCreateAccountEpoch()
        let firstEpoch = try XCTUnwrap(firstEpochValue)
        let firstAccountValue = await harness.store.refreshAccountIdentity()
        let firstAccount = try XCTUnwrap(firstAccountValue)
        await harness.store.saveTokens(accessToken: "access-b", refreshToken: "refresh-b")
        let secondEpochValue = await harness.store.getOrCreateAccountEpoch()
        let secondEpoch = try XCTUnwrap(secondEpochValue)
        let staleActivation = await harness.store.activateProfile(
            profileID: "profile-a",
            profileToken: nil,
            expectedAccount: firstAccount
        )

        XCTAssertNotEqual(firstEpoch, secondEpoch)
        XCTAssertFalse(staleActivation)
    }

    func testProfileCommitIsAtomicAndLateDeactivationCannotClearReplacement() async throws {
        let harness = try makeTokenHarness()
        defer { harness.cleanup() }
        await harness.store.switchActiveServer(serverId: harness.serverID)
        await harness.store.setServerUrl("https://silo.example")
        await harness.store.saveTokens(accessToken: "access", refreshToken: "refresh")
        let accountValue = await harness.store.refreshAccountIdentity()
        let account = try XCTUnwrap(accountValue)

        let activatedA = await harness.store.activateProfile(
            profileID: "profile-a",
            profileToken: "proof-a",
            expectedAccount: account
        )
        let profileA = await harness.store.getProfileId()
        let proofA = await harness.store.getProfileToken()
        XCTAssertTrue(activatedA)
        XCTAssertEqual(profileA, "profile-a")
        XCTAssertEqual(proofA, "proof-a")

        let activatedB = await harness.store.activateProfile(
            profileID: "profile-b",
            profileToken: nil,
            expectedAccount: account
        )
        let lateDeactivation = await harness.store.deactivateProfile(
            expectedAccount: account,
            expectedProfileID: "profile-a"
        )
        let profileB = await harness.store.getProfileId()
        let proofB = await harness.store.getProfileToken()
        XCTAssertTrue(activatedB)
        XCTAssertFalse(lateDeactivation)
        XCTAssertEqual(profileB, "profile-b")
        XCTAssertNil(proofB)
    }

    func testTemporaryRemoteIdentityRefusesPersistentProfileMutation() async throws {
        let harness = try makeTokenHarness()
        defer { harness.cleanup() }
        await harness.store.switchActiveServer(serverId: harness.serverID)
        await harness.store.setServerUrl("https://silo.example")
        await harness.store.saveTokens(accessToken: "access", refreshToken: "refresh")
        let persistentAccountValue = await harness.store.refreshAccountIdentity()
        let persistentAccount = try XCTUnwrap(persistentAccountValue)
        let temporary = TemporaryAuthScope(
            serverId: "remote-server",
            serverURL: "https://remote.example",
            accessToken: "remote-access",
            refreshToken: "remote-refresh",
            profileId: "remote-profile",
            profileToken: "remote-proof",
            controllerDeviceId: "controller",
            expiresAt: Date().addingTimeInterval(60)
        )
        await harness.store.beginTemporaryScope(temporary)

        let activation = await harness.store.activateProfile(
            profileID: "persistent-profile",
            profileToken: nil,
            expectedAccount: persistentAccount
        )
        let deactivation = await harness.store.deactivateProfile(
            expectedAccount: persistentAccount
        )
        let profileID = await harness.store.getProfileId()
        XCTAssertFalse(activation)
        XCTAssertFalse(deactivation)
        XCTAssertEqual(profileID, "remote-profile")
    }

    func testFailedKeychainWriteDoesNotPublishProfileProof() async throws {
        let suiteName = "ProfileLaunchIdentityTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = TokenStore(
            keychain: SharedKeychain(
                service: "ProfileLaunchIdentityTests.\(UUID().uuidString)",
                accessGroup: "invalid.access.group"
            ),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await store.switchActiveServer(serverId: "server-a")

        let persisted = await store.setProfileToken("proof")

        XCTAssertFalse(persisted)
        let profileToken = await store.getProfileToken()
        XCTAssertNil(profileToken)
    }

    private struct TokenHarness {
        let store: TokenStore
        let keychain: SharedKeychain
        let suite: UserDefaults
        let suiteName: String
        let serverID: String

        func cleanup() {
            for key in [
                TokenStore.accessTokenKey(for: serverID),
                TokenStore.refreshTokenKey(for: serverID),
                TokenStore.profileTokenKey(for: serverID),
                TokenStore.accountEpochKey(for: serverID),
                SharedStorage.mirroredAccessTokenAccount,
                SharedStorage.mirroredProfileTokenAccount,
            ] {
                keychain.delete(key)
            }
            suite.removePersistentDomain(forName: suiteName)
        }
    }

    private func makeTokenHarness() throws -> TokenHarness {
        let suiteName = "ProfileLaunchIdentityTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let keychain = SharedKeychain(
            service: "ProfileLaunchIdentityTests.\(UUID().uuidString)",
            accessGroup: nil
        )
        let store = TokenStore(
            keychain: keychain,
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        return TokenHarness(
            store: store,
            keychain: keychain,
            suite: suite,
            suiteName: suiteName,
            serverID: "server-a"
        )
    }
}

@MainActor
final class InvalidProfileRecoveryTests: XCTestCase {
    func testOnlyExplicitProfileErrorsTriggerRecovery() {
        XCTAssertTrue(StartupContentPrefetcher.indicatesInvalidProfile(
            HTTPError.http(statusCode: 403, body: #"{"error":"profile_unverified"}"#)
        ))
        XCTAssertTrue(StartupContentPrefetcher.indicatesInvalidProfile(
            HTTPError.http(statusCode: 404, body: #"{"error":"profile_not_found"}"#)
        ))
        XCTAssertFalse(StartupContentPrefetcher.indicatesInvalidProfile(
            HTTPError.http(statusCode: 404, body: #"{"error":"content_not_found"}"#)
        ))
        XCTAssertFalse(StartupContentPrefetcher.indicatesInvalidProfile(
            HTTPError.http(statusCode: 404, body: nil)
        ))
    }
}

@MainActor
final class ProfileLaunchMigrationTests: XCTestCase {
    private struct LegacyRegistryState: Codable {
        let activeServerId: String?
        let entries: [ServerEntry]
    }

    func testLegacyRegistryProfileMigratesBeforeProfileFieldIsRemoved() throws {
        let suiteName = "ProfileLaunchMigrationTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let keychain = SharedKeychain(
            service: "ProfileLaunchMigrationTests.\(UUID().uuidString)",
            accessGroup: nil
        )
        let serverID = "server-a"
        defer {
            for key in [
                TokenStore.accessTokenKey(for: serverID),
                TokenStore.refreshTokenKey(for: serverID),
                TokenStore.profileTokenKey(for: serverID),
                TokenStore.accountEpochKey(for: serverID),
            ] {
                keychain.delete(key)
            }
            suite.removePersistentDomain(forName: suiteName)
        }

        let legacy = LegacyRegistryState(
            activeServerId: serverID,
            entries: [ServerEntry(
                id: serverID,
                url: "https://silo.example",
                fetchedName: "Silo",
                profileId: "profile-a",
                lastUsedAt: Date(timeIntervalSinceReferenceDate: 1)
            )]
        )
        defaults.set(
            try JSONEncoder().encode(legacy),
            forKey: "continuumServerRegistry.v1"
        )
        XCTAssertTrue(keychain.set(
            "access",
            for: TokenStore.accessTokenKey(for: serverID)
        ))
        XCTAssertTrue(keychain.set(
            "proof",
            for: TokenStore.profileTokenKey(for: serverID)
        ))

        let preferences = ProfileLaunchPreferences(defaults: defaults)
        let registry = ServerRegistry(
            defaults: defaults,
            keychain: keychain,
            launchPreferences: preferences
        )

        let remembered = try XCTUnwrap(preferences.rememberedProfile(for: serverID))
        XCTAssertEqual(remembered.profileID, "profile-a")
        XCTAssertTrue(remembered.requiredPINAtSelection)
        XCTAssertNil(registry.entry(with: serverID)?.legacyProfileId)
        let migrated = try XCTUnwrap(defaults.data(forKey: "continuumServerRegistry.v1"))
        XCTAssertFalse(String(decoding: migrated, as: UTF8.self).contains("profileId"))
    }
}
