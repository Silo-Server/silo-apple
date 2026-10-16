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
            XCTAssertEqual(try h.profile.getChecked(TokenStore.profileTokenKey(for: serverID)),
                matchesEpoch ? nil : "legacy-PIN-proof", "A different epoch must retain its own proof")
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

    func testDeletingMigratedPINProofRemainsEffectiveAfterRelaunch() async throws {
        for hasAccountProof in [false, true] {
            let h = try harness()
            let session = canonical("account-A")
            try seedLegacyCanonical(session, in: h)
            let legacyKey = TokenStore.profileTokenKey(for: serverID)
            let accountKey = SharedStorage.profileTokenAccount(for: serverID, accountID: "account-A")
            XCTAssertTrue(h.profile.set("legacy-proof", for: legacyKey))
            if hasAccountProof { XCTAssertTrue(h.profile.set("account-proof", for: accountKey)) }
            let remembered = RememberedProfile(profileID: "profile-A", requiredPINAtSelection: true,
                accountEpoch: try XCTUnwrap(session.epoch).uuidString)
            h.defaults.set(try JSONEncoder().encode(ProfileLaunchState(rememberedByServerID: [serverID: remembered])),
                forKey: SharedStorage.profileLaunchStateKey)
            let store = await activeStore(h)
            let migrated = await store.getProfileToken()
            XCTAssertEqual(migrated, hasAccountProof ? "account-proof" : "legacy-proof")

            let deactivated = await store.deactivateProfile(expectedAccount: nil)

            XCTAssertTrue(deactivated)
            XCTAssertNil(try h.profile.getChecked(legacyKey))
            XCTAssertNil(try h.profile.getChecked(accountKey))
            let restarted = await activeStore(h)
            let restored = await restarted.getProfileToken()
            XCTAssertNil(restored)
            XCTAssertNil(try h.profile.getChecked(accountKey))
        }
    }

    func testVerifiedLegacyBindingConsumesPINProofBeforeAProfileCanDeleteIt() async throws {
        let h = try harness()
        let epoch = UUID()
        try seedRaw(h, access: "legacy-access-A", refresh: "legacy-refresh-A", epoch: epoch)
        let legacyKey = TokenStore.profileTokenKey(for: serverID)
        XCTAssertTrue(h.profile.set("legacy-proof", for: legacyKey))
        let remembered = RememberedProfile(profileID: "profile-A", requiredPINAtSelection: true,
            accountEpoch: epoch.uuidString)
        h.defaults.set(try JSONEncoder().encode(ProfileLaunchState(rememberedByServerID: [serverID: remembered])),
            forKey: SharedStorage.profileLaunchStateKey)
        let store = await activeStore(h)
        let captured = await store.captureOrdinaryRequestAuth()

        try await store.bindVerifiedAccount("account-A", expected: XCTUnwrap(captured))

        let boundProof = await store.getProfileToken()
        XCTAssertEqual(boundProof, "legacy-proof")
        XCTAssertNil(try h.profile.getChecked(legacyKey))
        let deactivated = await store.deactivateProfile(expectedAccount: nil)
        XCTAssertTrue(deactivated)
        let restarted = await activeStore(h)
        let restored = await restarted.getProfileToken()
        XCTAssertNil(restored)
    }

    func testCurrentUserBindsInheritedLegacyDefaultAfterSameAccountLogin() async throws {
        let h = try harness()
        let epoch = UUID()
        let legacy = CanonicalAccountSession(version: 1, signedOut: false, origin: origin,
            accountID: nil, epoch: epoch, accessToken: "legacy-access-A", refreshToken: "legacy-refresh-A")
        try seedLegacyCanonical(legacy, in: h)
        let verified = canonical("account-A")
        try h.sessions.save(verified, serverID: serverID)
        XCTAssertTrue(h.profile.delete(TVAccountSessionStorage.selectionKey(serverID)))
        let store = await activeStore(h)
        let stub = APIv2TestStub()
        stub.reply(200, #"{"id":"account-A","username":"A","email":"a@example.test","role":"user","permissions":[],"download_allowed":true}"#)
        let api = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: store),
            tokenStore: store, isUpdateRequired: { false })

        let account = try await api.currentUser()

        XCTAssertEqual(account.id, "account-A")
        let bound = await store.captureDurableAccountAuth()
        XCTAssertEqual(bound?.accountID, "account-A")
        XCTAssertEqual(bound?.accountEpoch, epoch)
        XCTAssertEqual(bound?.request.accessToken, "legacy-access-A")
        XCTAssertEqual(try h.sessions.savedAccountIDs(for: serverID), ["account-A"])
        let restarted = await activeStore(h)
        let restored = await restarted.captureDurableAccountAuth()
        XCTAssertEqual(restored?.accountEpoch, epoch)
        XCTAssertEqual(restored?.request.accessToken, "legacy-access-A")
    }

    func testCurrentUserBindingKeepsTheAuthenticatedProfileProofWhenTheAccountHasAnotherProof() async throws {
        for rawLegacy in [true, false] {
            let h = try harness()
            let epoch = UUID()
            if rawLegacy {
                try seedRaw(h, access: "legacy-access-A", refresh: "legacy-refresh-A", epoch: epoch)
            } else {
                try seedLegacyCanonical(CanonicalAccountSession(version: 1, signedOut: false, origin: origin,
                    accountID: nil, epoch: epoch, accessToken: "legacy-access-A", refreshToken: "legacy-refresh-A"), in: h)
            }
            let sourceKey = TokenStore.profileTokenKey(for: serverID)
            let destinationKey = SharedStorage.profileTokenAccount(for: serverID, accountID: "account-A")
            XCTAssertTrue(h.profile.set("proof-A", for: sourceKey))
            XCTAssertTrue(h.profile.set("proof-B", for: destinationKey))
            let preferences = ProfileLaunchPreferences(defaults: h.defaults)
            preferences.behavior = .automatic
            XCTAssertTrue(preferences.remember(profileID: "profile-A", requiresPIN: true,
                accountEpoch: epoch.uuidString, for: serverID))
            let store = await activeStore(h)
            await store.setProfileId("profile-A")
            let stub = APIv2TestStub()
            stub.reply(path: "/api/v2/account/me", 200,
                #"{"id":"account-A","username":"A","email":"a@example.test","role":"user","permissions":[],"download_allowed":true}"#)
            stub.reply(path: "/api/v2/proof-check", 200, "{}")
            let http = HTTPClient(session: stub.makeSession(), tokenStore: store)
            let api = APIv2Client(http: http, tokenStore: store, isUpdateRequired: { false })

            _ = try await api.currentUser()
            let _: [String: String] = try await http.get("/api/v2/proof-check")

            for request in stub.requests {
                XCTAssertEqual(request.header("X-Profile-Id"), "profile-A")
                XCTAssertEqual(request.header("X-Profile-Token"), "proof-A")
            }
            let bound = await store.captureDurableAccountAuth()
            XCTAssertEqual(bound?.accountID, "account-A")
            XCTAssertEqual(bound?.accountEpoch, epoch)
            XCTAssertEqual(bound?.request.profileId, "profile-A")
            XCTAssertEqual(bound?.request.profileToken, "proof-A")
            XCTAssertEqual(try h.profile.getChecked(destinationKey), "proof-A")
            XCTAssertNil(try h.profile.getChecked(sourceKey))
            let restarted = await activeStore(h)
            let restored = await restarted.captureOrdinaryRequestAuth()
            XCTAssertEqual(restored?.profileId, "profile-A")
            XCTAssertEqual(restored?.profileToken, "proof-A")
            XCTAssertEqual(ProfileLaunchPreferences(defaults: h.defaults).resolution(for: serverID,
                accountEpoch: epoch.uuidString, hasStoredProfileToken: restored?.profileToken != nil),
                .restore(RememberedProfile(profileID: "profile-A", requiredPINAtSelection: true, accountEpoch: epoch.uuidString)))
            let deleted = await restarted.deactivateProfile(expectedAccount: nil)
            XCTAssertTrue(deleted)
            let afterDeletion = await activeStore(h)
            let proofAfterDeletion = await afterDeletion.getProfileToken()
            XCTAssertNil(proofAfterDeletion)
        }
    }

    func testStaleLegacyBindingCannotReplaceAnotherEpochsProfileProof() async throws {
        let h = try harness()
        let legacy = CanonicalAccountSession(version: 1, signedOut: false, origin: origin,
            accountID: nil, epoch: UUID(), accessToken: "legacy-access-A", refreshToken: "legacy-refresh-A")
        try seedLegacyCanonical(legacy, in: h)
        let sourceKey = TokenStore.profileTokenKey(for: serverID)
        let destinationKey = SharedStorage.profileTokenAccount(for: serverID, accountID: "account-A")
        XCTAssertTrue(h.profile.set("proof-A", for: sourceKey))
        XCTAssertTrue(h.profile.set("proof-B", for: destinationKey))
        let store = await activeStore(h)
        await store.setProfileId("profile-A")
        let captured = await store.captureOrdinaryRequestAuth()
        let replacement = canonical("account-A")
        try h.sessions.save(replacement, serverID: serverID)

        do {
            try await store.bindVerifiedAccount("account-A", expected: XCTUnwrap(captured))
            XCTFail("A binding from the replaced epoch succeeded")
        } catch HTTPError.requestIdentityChanged {}

        XCTAssertEqual(try h.sessions.load(serverID), .session(replacement))
        XCTAssertEqual(try h.profile.getChecked(sourceKey), "proof-A")
        XCTAssertEqual(try h.profile.getChecked(destinationKey), "proof-B")
    }

    func testStaleProfileCannotBindItsProofOverTheCurrentProfile() async throws {
        let h = try harness()
        try seedRaw(h, access: "legacy-access-A", refresh: "legacy-refresh-A", epoch: UUID())
        let sourceKey = TokenStore.profileTokenKey(for: serverID)
        let destinationKey = SharedStorage.profileTokenAccount(for: serverID, accountID: "account-A")
        XCTAssertTrue(h.profile.set("proof-A", for: sourceKey))
        XCTAssertTrue(h.profile.set("proof-B", for: destinationKey))
        let store = await activeStore(h)
        await store.setProfileId("profile-A")
        let captured = await store.captureOrdinaryRequestAuth()
        await store.setProfileId("profile-C")
        let wroteProof = await store.setProfileToken("proof-C")
        XCTAssertTrue(wroteProof)

        do {
            try await store.bindVerifiedAccount("account-A", expected: XCTUnwrap(captured))
            XCTFail("A binding from the replaced profile succeeded")
        } catch HTTPError.requestIdentityChanged {}

        let current = await store.captureOrdinaryRequestAuth()
        XCTAssertEqual(current?.profileId, "profile-C")
        XCTAssertEqual(current?.profileToken, "proof-C")
        XCTAssertEqual(try h.profile.getChecked(sourceKey), "proof-C")
        XCTAssertEqual(try h.profile.getChecked(destinationKey), "proof-B")
        XCTAssertEqual(try h.sessions.load(serverID), .legacy)
    }

    func testFailedBoundProofPublicationRequiresSelectionAndSendsNoProfileAfterRelaunch() async throws {
        for (failsDestination, remembersProfile) in [(true, true), (false, true), (true, false), (false, false)] {
            let h = try harness()
            let epoch = UUID()
            try seedRaw(h, access: "legacy-access-A", refresh: "legacy-refresh-A", epoch: epoch)
            let sourceKey = TokenStore.profileTokenKey(for: serverID)
            let destinationKey = SharedStorage.profileTokenAccount(for: serverID, accountID: "account-A")
            XCTAssertTrue(h.profile.set("proof-A", for: sourceKey))
            XCTAssertTrue(h.profile.set("proof-B", for: destinationKey))
            let preferences = ProfileLaunchPreferences(defaults: h.defaults)
            preferences.behavior = .automatic
            if remembersProfile {
                XCTAssertTrue(preferences.remember(profileID: "profile-A", requiresPIN: true,
                    accountEpoch: epoch.uuidString, for: serverID))
            }
            let store = await activeStore(h, launchPreferences: preferences, boundProfileProofPersistence: { proof, key in
                if key == (failsDestination ? destinationKey : sourceKey) { return false }
                if let proof { return h.profile.set(proof, for: key) }
                return h.profile.delete(key)
            })
            await store.setProfileId("profile-A")
            let captured = await store.captureOrdinaryRequestAuth()

            do {
                try await store.bindVerifiedAccount("account-A", expected: XCTUnwrap(captured))
                XCTFail("A failed bound-proof publication succeeded")
            } catch AccountSessionPersistenceError.unavailable {}

            let blockedAccess = await store.getAccessToken()
            let blockedProof = await store.getProfileToken()
            XCTAssertNil(blockedAccess)
            XCTAssertNil(blockedProof)
            XCTAssertEqual(preferences.resolution(for: serverID, accountEpoch: epoch.uuidString,
                hasStoredProfileToken: true), .needsSelection)
            XCTAssertTrue(preferences.state.requiresSelection(for: serverID, accountEpoch: epoch.uuidString))
            XCTAssertEqual(try h.profile.getChecked(sourceKey), failsDestination ? nil : "proof-A")
            XCTAssertEqual(try h.profile.getChecked(destinationKey), "proof-B")
            if failsDestination {
                guard case .session(let bound) = try h.sessions.load(serverID) else {
                    return XCTFail("The account publication should precede a destination-proof failure")
                }
                XCTAssertEqual(bound.accountID, "account-A")
                XCTAssertEqual(bound.epoch, epoch)
            } else {
                XCTAssertEqual(try h.sessions.load(serverID), .legacy,
                    "Failed source retirement must prevent verified-session publication")
            }
            let restarted = await activeStore(h)
            let restored = await restarted.captureOrdinaryRequestAuth()
            XCTAssertEqual(restored?.accessToken, "legacy-access-A")
            XCTAssertNil(restored?.profileId)
            XCTAssertNil(restored?.profileToken)
            let coldPreferences = ProfileLaunchPreferences(defaults: h.defaults)
            XCTAssertEqual(coldPreferences.resolution(for: serverID, accountEpoch: epoch.uuidString,
                hasStoredProfileToken: true), .needsSelection)
            let stub = APIv2TestStub()
            let http = HTTPClient(session: stub.makeSession(), tokenStore: restarted)
            let _: [String: String] = try await http.get("/api/v2/proof-check")
            XCTAssertNil(stub.requests.first?.header("X-Profile-Id"))
            XCTAssertNil(stub.requests.first?.header("X-Profile-Token"))
            XCTAssertEqual(try h.profile.getChecked(sourceKey), failsDestination ? nil : "proof-A",
                "Cold loading a pending binding must not migrate or consume its proof")
            try await recoverProfileAndDeleteProof(h, store: restarted, epoch: epoch, preferences: coldPreferences)
        }
    }

    func testMarkerFailureAfterProofRetirementStillRequiresFreshProfileSelection() async throws {
        let h = try harness()
        let epoch = UUID()
        try seedRaw(h, access: "legacy-access-A", refresh: "legacy-refresh-A", epoch: epoch)
        let sourceKey = TokenStore.profileTokenKey(for: serverID)
        let destinationKey = SharedStorage.profileTokenAccount(for: serverID, accountID: "account-A")
        XCTAssertTrue(h.profile.set("proof-A", for: sourceKey))
        XCTAssertTrue(h.profile.set("proof-B", for: destinationKey))
        let preferences = ProfileLaunchPreferences(defaults: h.defaults)
        XCTAssertTrue(preferences.remember(profileID: "profile-A", requiresPIN: true,
            accountEpoch: epoch.uuidString, for: serverID))
        let sessions = AccountSessionPersistence(tvStorage: TVAccountSessionStorage(
            sharedRead: { try h.account.getChecked($0) },
            sharedWrite: { value, key in
                key != TVAccountSessionStorage.markerKey(self.serverID) && h.account.set(value, for: key)
            }, sharedRemove: { h.account.delete($0) },
            selectionRead: { try h.profile.getChecked($0) },
            selectionWrite: { h.profile.set($0, for: $1) }, selectionRemove: { h.profile.delete($0) }))
        let store = await activeStore(h, sessions: sessions, launchPreferences: preferences)
        await store.setProfileId("profile-A")
        let captured = await store.captureOrdinaryRequestAuth()

        do {
            try await store.bindVerifiedAccount("account-A", expected: XCTUnwrap(captured))
            XCTFail("A binding whose adoption marker failed succeeded")
        } catch HTTPError.requestIdentityChanged {}

        XCTAssertEqual(try h.sessions.load(serverID), .legacy)
        XCTAssertNil(try h.profile.getChecked(sourceKey))
        XCTAssertEqual(try h.profile.getChecked(destinationKey), "proof-B")
        let restarted = await activeStore(h)
        let restored = await restarted.captureOrdinaryRequestAuth()
        XCTAssertNil(restored?.profileId)
        XCTAssertNil(restored?.profileToken)
        XCTAssertTrue(ProfileLaunchState.load(from: h.defaults).requiresSelection(for: serverID, accountEpoch: epoch.uuidString))
        try await recoverProfileAndDeleteProof(h, store: restarted, epoch: epoch,
            preferences: ProfileLaunchPreferences(defaults: h.defaults))
    }

    func testBindingWithoutAnAuthenticatedProofRemovesAnOlderSavedProof() async throws {
        let h = try harness()
        let epoch = UUID()
        try seedRaw(h, access: "legacy-access-A", refresh: "legacy-refresh-A", epoch: epoch)
        let destinationKey = SharedStorage.profileTokenAccount(for: serverID, accountID: "account-A")
        XCTAssertTrue(h.profile.set("proof-B", for: destinationKey))
        let preferences = ProfileLaunchPreferences(defaults: h.defaults)
        preferences.behavior = .automatic
        XCTAssertTrue(preferences.remember(profileID: "profile-A", requiresPIN: true,
            accountEpoch: epoch.uuidString, for: serverID))
        let store = await activeStore(h, launchPreferences: preferences)
        await store.setProfileId("profile-A")
        let captured = await store.captureOrdinaryRequestAuth()

        try await store.bindVerifiedAccount("account-A", expected: XCTUnwrap(captured))

        XCTAssertNil(try h.profile.getChecked(destinationKey))
        let restarted = await activeStore(h)
        let restored = await restarted.captureOrdinaryRequestAuth()
        XCTAssertNil(restored?.profileToken)
        XCTAssertEqual(ProfileLaunchPreferences(defaults: h.defaults).resolution(for: serverID,
            accountEpoch: epoch.uuidString, hasStoredProfileToken: restored?.profileToken != nil), .needsSelection)
    }

    func testSuccessfulBindingPreservesAnExistingSelectionRequirement() async throws {
        let h = try harness()
        let epoch = UUID()
        try seedRaw(h, access: "legacy-access-A", refresh: "legacy-refresh-A", epoch: epoch)
        XCTAssertTrue(h.profile.set("proof-A", for: TokenStore.profileTokenKey(for: serverID)))
        let preferences = ProfileLaunchPreferences(defaults: h.defaults)
        preferences.behavior = .automatic
        XCTAssertTrue(preferences.remember(profileID: "profile-A", requiresPIN: true,
            accountEpoch: epoch.uuidString, for: serverID))
        let store = await activeStore(h, launchPreferences: preferences)
        await store.setProfileId("profile-A")
        let captured = await store.captureOrdinaryRequestAuth()
        XCTAssertTrue(preferences.markSelectionRequired(for: serverID))

        try await store.bindVerifiedAccount("account-A", expected: XCTUnwrap(captured))

        XCTAssertEqual(preferences.resolution(for: serverID, accountEpoch: epoch.uuidString,
            hasStoredProfileToken: true), .needsSelection)
        let current = await store.captureOrdinaryRequestAuth()
        XCTAssertNil(current?.profileId)
        XCTAssertNil(current?.profileToken)
        XCTAssertEqual(try h.profile.getChecked(SharedStorage.profileTokenAccount(for: serverID, accountID: "account-A")), "proof-A")
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

    private func recoverProfileAndDeleteProof(_ h: Harness, store: TokenStore, epoch: UUID,
                                              preferences: ProfileLaunchPreferences) async throws {
        let identity = await store.refreshAccountIdentity()
        let expected = try XCTUnwrap(identity)
        let activated = await store.activateProfile(profileID: "profile-C", profileToken: "fresh-proof-C",
            expectedAccount: expected)
        XCTAssertTrue(activated)
        XCTAssertTrue(preferences.remember(profileID: "profile-C", requiresPIN: true,
            accountEpoch: epoch.uuidString, for: serverID))
        let deactivated = await store.deactivateProfile(expectedAccount: nil)
        XCTAssertTrue(deactivated)
        let restarted = await activeStore(h)
        let proof = await restarted.getProfileToken()
        XCTAssertNil(proof, "Recovery and explicit deletion must not resurrect either legacy proof")
        let captured = await restarted.captureOrdinaryRequestAuth()
        try await restarted.bindVerifiedAccount("account-A", expected: XCTUnwrap(captured))
        let afterBinding = await activeStore(h)
        let reboundProof = await afterBinding.getProfileToken()
        XCTAssertNil(reboundProof, "A subsequent verified bind must not revive the old destination proof")
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

    private func activeStore(_ h: Harness, sessions: AccountSessionPersistence? = nil,
                             launchPreferences: ProfileLaunchPreferences? = nil,
                             boundProfileProofPersistence: (@Sendable (String?, String) -> Bool)? = nil) async -> TokenStore {
        h.defaults.set(origin, forKey: SharedStorage.serverUrlKey)
        let store = TokenStore(keychain: h.keychain, defaults: h.defaults, sessionPersistence: sessions,
            launchPreferences: launchPreferences, boundProfileProofPersistence: boundProfileProofPersistence)
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
