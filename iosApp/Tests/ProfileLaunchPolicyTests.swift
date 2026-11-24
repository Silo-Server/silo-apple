import XCTest
@testable import Silo

final class ProfileLaunchPolicyTests: XCTestCase {
    private let localAccountID = "local-account-a"
    private let accountEpoch = "account-a"

    func testProfileSelectionPoliciesKeepStableOrderAndLegacyEveryTimeRawValue() {
        XCTAssertEqual(
            ProfileLaunchBehavior.allCases,
            [.automatic, .askEveryLaunch, .afterOneHour, .afterTwelveHours]
        )
        XCTAssertEqual(ProfileLaunchBehavior.askEveryLaunch.rawValue, "askEveryLaunch")
        XCTAssertNil(ProfileLaunchBehavior.automatic.awayTimeout)
        XCTAssertNil(ProfileLaunchBehavior.askEveryLaunch.awayTimeout)
        XCTAssertEqual(ProfileLaunchBehavior.afterOneHour.awayTimeout, 60 * 60)
        XCTAssertEqual(ProfileLaunchBehavior.afterTwelveHours.awayTimeout, 12 * 60 * 60)
    }

    func testDefaultStateUsesAutomaticAndRequiresAProfile() {
        let state = ProfileLaunchState()

        XCTAssertEqual(state.behavior, .automatic)
        XCTAssertEqual(
            state.resolution(
                forAccount: localAccountID,
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
            rememberedByAccountID: [localAccountID: remembered]
        )

        XCTAssertEqual(
            state.resolution(
                forAccount: localAccountID,
                accountEpoch: accountEpoch,
                hasStoredProfileToken: true
            ),
            .needsSelection
        )
        XCTAssertEqual(state.rememberedByAccountID[localAccountID], remembered)
    }

    func testEveryTimeRequiresARealBackgroundIntervalOnWarmReturn() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        var state = ProfileLaunchState(behavior: .askEveryLaunch)

        XCTAssertFalse(state.requiresSelectionAfterBackground(at: start))

        state.backgroundedAt = start
        XCTAssertTrue(state.requiresSelectionAfterBackground(at: start))
    }

    func testTimedPoliciesRestoreBeforeAndRequireAtTimeout() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let remembered = RememberedProfile(
            profileID: "profile-a",
            requiredPINAtSelection: false,
            accountEpoch: accountEpoch
        )
        var oneHour = ProfileLaunchState(
            behavior: .afterOneHour,
            rememberedByAccountID: [localAccountID: remembered],
            backgroundedAt: start
        )

        XCTAssertEqual(
            oneHour.resolution(
                forAccount: localAccountID,
                accountEpoch: accountEpoch,
                hasStoredProfileToken: false,
                now: start.addingTimeInterval(3_599)
            ),
            .restore(remembered)
        )
        XCTAssertEqual(
            oneHour.resolution(
                forAccount: localAccountID,
                accountEpoch: accountEpoch,
                hasStoredProfileToken: false,
                now: start.addingTimeInterval(3_600)
            ),
            .needsSelection
        )

        oneHour.behavior = .afterTwelveHours
        XCTAssertFalse(
            oneHour.requiresSelectionAtLaunch(
                at: start.addingTimeInterval((12 * 60 * 60) - 1)
            )
        )
        XCTAssertTrue(
            oneHour.requiresSelectionAtLaunch(
                at: start.addingTimeInterval(12 * 60 * 60)
            )
        )
    }

    func testAutomaticIgnoresAStaleBackgroundMarker() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let state = ProfileLaunchState(
            behavior: .automatic,
            backgroundedAt: start
        )

        XCTAssertFalse(
            state.requiresSelectionAtLaunch(
                at: start.addingTimeInterval(24 * 60 * 60)
            )
        )
        XCTAssertFalse(
            state.requiresSelectionAfterBackground(
                at: start.addingTimeInterval(24 * 60 * 60)
            )
        )
    }

    /// When Profile Selection asks for a choice, several saved accounts get
    /// Change Account and one account keeps its picker. When it asks for
    /// nothing, neither shows, however many accounts are saved.
    func testSelectionPromptFollowsProfileSelectionAndSavedAccountCount() {
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let hour: TimeInterval = 60 * 60
        typealias Row = (
            behavior: ProfileLaunchBehavior, awayFor: TimeInterval?, accounts: Int,
            atLaunch: ProfileSelectionPrompt?, afterBackground: ProfileSelectionPrompt?
        )
        let rows: [Row] = [
            // Every Time asks at every cold launch, and on a return only
            // after a real background interval.
            (.askEveryLaunch, nil, 1, .picker, nil),
            (.askEveryLaunch, nil, 2, .changeAccount, nil),
            (.askEveryLaunch, 0, 0, .picker, .picker),
            (.askEveryLaunch, 0, 1, .picker, .picker),
            (.askEveryLaunch, 0, 2, .changeAccount, .changeAccount),
            (.askEveryLaunch, 0, 5, .changeAccount, .changeAccount),
            // Automatic never asks.
            (.automatic, nil, 2, nil, nil),
            (.automatic, 24 * hour, 2, nil, nil),
            // A timer asks once it has lapsed.
            (.afterOneHour, nil, 2, nil, nil),
            (.afterOneHour, hour - 1, 2, nil, nil),
            (.afterOneHour, hour, 1, .picker, .picker),
            (.afterOneHour, hour, 2, .changeAccount, .changeAccount),
            (.afterTwelveHours, 12 * hour - 1, 2, nil, nil),
            (.afterTwelveHours, 12 * hour, 1, .picker, .picker),
            (.afterTwelveHours, 12 * hour, 2, .changeAccount, .changeAccount),
        ]

        for row in rows {
            let state = ProfileLaunchState(
                behavior: row.behavior,
                backgroundedAt: row.awayFor == nil ? nil : start
            )
            let now = start.addingTimeInterval(row.awayFor ?? 0)
            let label = "\(row.behavior.rawValue), away \(row.awayFor.map { "\($0)s" } ?? "never"), \(row.accounts) accounts"
            XCTAssertEqual(
                state.promptAtLaunch(savedAccountCount: row.accounts, at: now), row.atLaunch,
                "cold launch: \(label)"
            )
            XCTAssertEqual(
                state.promptAfterBackground(savedAccountCount: row.accounts, at: now), row.afterBackground,
                "return: \(label)"
            )
        }
    }

    func testLegacyLaunchStateWithoutBackgroundMarkerStillDecodes() throws {
        let legacy = Data(
            #"{"behavior":"automatic","rememberedByServerID":{},"selectionRequiredServerIDs":[]}"#.utf8
        )

        let decoded = try JSONDecoder().decode(ProfileLaunchState.self, from: legacy)

        XCTAssertEqual(decoded.behavior, .automatic)
        XCTAssertNil(decoded.backgroundedAt)
    }

    func testAutomaticRestoresPINlessProfileOffline() {
        let remembered = RememberedProfile(
            profileID: "profile-a",
            requiredPINAtSelection: false,
            accountEpoch: accountEpoch
        )
        let state = ProfileLaunchState(
            rememberedByAccountID: [localAccountID: remembered]
        )

        XCTAssertEqual(
            state.resolution(
                forAccount: localAccountID,
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
            rememberedByAccountID: [localAccountID: remembered]
        )

        XCTAssertEqual(
            state.resolution(
                forAccount: localAccountID,
                accountEpoch: accountEpoch,
                hasStoredProfileToken: false
            ),
            .needsSelection
        )
        XCTAssertEqual(
            state.resolution(
                forAccount: localAccountID,
                accountEpoch: "replacement-account",
                hasStoredProfileToken: true
            ),
            .needsSelection
        )
        XCTAssertEqual(
            state.resolution(
                forAccount: localAccountID,
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
            rememberedByAccountID: [localAccountID: remembered],
            selectionRequiredAccountIDs: [localAccountID]
        )
        let stale = ProfileLaunchState(
            rememberedByAccountID: [localAccountID: remembered]
        )

        XCTAssertEqual(
            pending.resolution(
                forAccount: localAccountID,
                accountEpoch: accountEpoch,
                hasStoredProfileToken: false
            ),
            .needsSelection
        )
        XCTAssertEqual(
            stale.resolution(
                forAccount: localAccountID,
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
        XCTAssertTrue(preferences.markBackgrounded(
            at: Date(timeIntervalSinceReferenceDate: 1_000)
        ))
        XCTAssertTrue(preferences.markSelectionRequired(forAccount: localAccountID))
        preferences.remember(
            profileID: "profile-a",
            requiresPIN: true,
            accountEpoch: accountEpoch,
            forAccount: localAccountID
        )

        let restored = ProfileLaunchPreferences(defaults: defaults)
        XCTAssertEqual(restored.behavior, .askEveryLaunch)
        XCTAssertEqual(
            restored.rememberedProfile(forAccount: localAccountID),
            RememberedProfile(
                profileID: "profile-a",
                requiredPINAtSelection: true,
                accountEpoch: accountEpoch
            )
        )
        XCTAssertFalse(restored.state.selectionRequiredAccountIDs.contains(localAccountID))
        XCTAssertNil(restored.state.backgroundedAt)
    }

    func testBackgroundMarkerPersistsAndClearsAcrossProcessRestores() throws {
        let suiteName = "ProfileLaunchPolicyTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defer { suite.removePersistentDomain(forName: suiteName) }
        let start = Date(timeIntervalSinceReferenceDate: 2_000)

        let preferences = ProfileLaunchPreferences(defaults: defaults)
        preferences.behavior = .afterOneHour
        XCTAssertTrue(preferences.markBackgrounded(at: start))
        XCTAssertEqual(
            ProfileLaunchPreferences(defaults: defaults).state.backgroundedAt,
            start
        )

        XCTAssertTrue(preferences.clearBackgroundedAt())
        XCTAssertNil(ProfileLaunchPreferences(defaults: defaults).state.backgroundedAt)
    }

    func testBehaviorRollsBackWhenPersistenceFails() throws {
        let suiteName = "ProfileLaunchPolicyTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defer { suite.removePersistentDomain(forName: suiteName) }
        var allowsPersistence = true
        let preferences = ProfileLaunchPreferences(
            defaults: defaults,
            persistenceOverride: { _ in allowsPersistence }
        )

        let initial = preferences.behavior
        allowsPersistence = false
        preferences.behavior = .afterOneHour

        XCTAssertEqual(preferences.behavior, initial)
    }

    /// The profile picker reads remembered profiles on the main thread while
    /// `AuthService` records a selection from a profile-switch task.
    func testConcurrentRememberAndReadKeepEveryServer() throws {
        let suiteName = "ProfileLaunchPolicyTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defer { suite.removePersistentDomain(forName: suiteName) }
        let preferences = ProfileLaunchPreferences(defaults: defaults)
        let serverCount = 64
        let accountEpoch = accountEpoch

        DispatchQueue.concurrentPerform(iterations: serverCount * 16) { index in
            let localAccountID = "account-\((index / 2) % serverCount)"
            if index.isMultiple(of: 2) {
                preferences.remember(
                    profileID: "profile-\(index)",
                    requiresPIN: false,
                    accountEpoch: accountEpoch,
                    forAccount: localAccountID
                )
            } else {
                _ = preferences.rememberedProfile(forAccount: localAccountID)
            }
        }

        XCTAssertEqual(preferences.state.rememberedByAccountID.count, serverCount)
        XCTAssertEqual(
            ProfileLaunchPreferences(defaults: defaults).state,
            preferences.state
        )
    }

    func testInvalidProfileNotificationCannotReplaceAnActiveProfile() {
        XCTAssertTrue(shouldPresentProfileSelectionAfterRecovery(
            isLoggedIn: true,
            activeProfileID: nil
        ))
        XCTAssertFalse(shouldPresentProfileSelectionAfterRecovery(
            isLoggedIn: true,
            activeProfileID: "replacement-profile"
        ))
        XCTAssertFalse(shouldPresentProfileSelectionAfterRecovery(
            isLoggedIn: false,
            activeProfileID: nil
        ))
    }

    func testTopShelfRespectsProfileSelectionPolicyAndMatchingCurrentUserIdentity() {
        let pinless = RememberedProfile(
            profileID: "profile-a",
            requiredPINAtSelection: false,
            accountEpoch: accountEpoch
        )
        var state = ProfileLaunchState(
            rememberedByAccountID: [localAccountID: pinless]
        )

        XCTAssertTrue(TopShelfProfilePolicy.allowsPersonalizedContent(
            state: state,
            localAccountID: localAccountID,
            activeProfileID: "profile-a",
            accountEpoch: accountEpoch,
            hasStoredProfileToken: false
        ))

        state.behavior = .askEveryLaunch
        XCTAssertFalse(TopShelfProfilePolicy.allowsPersonalizedContent(
            state: state,
            localAccountID: localAccountID,
            activeProfileID: "profile-a",
            accountEpoch: accountEpoch,
            hasStoredProfileToken: true
        ))

        state.behavior = .automatic
        state.selectionRequiredAccountIDs.insert(localAccountID)
        XCTAssertFalse(TopShelfProfilePolicy.allowsPersonalizedContent(
            state: state,
            localAccountID: localAccountID,
            activeProfileID: "profile-a",
            accountEpoch: accountEpoch,
            hasStoredProfileToken: true
        ))

        let start = Date(timeIntervalSinceReferenceDate: 3_000)
        state.behavior = .afterOneHour
        state.selectionRequiredAccountIDs.remove(localAccountID)
        state.backgroundedAt = start
        XCTAssertTrue(TopShelfProfilePolicy.allowsPersonalizedContent(
            state: state,
            localAccountID: localAccountID,
            activeProfileID: "profile-a",
            accountEpoch: accountEpoch,
            hasStoredProfileToken: false,
            now: start.addingTimeInterval(3_599)
        ))
        XCTAssertFalse(TopShelfProfilePolicy.allowsPersonalizedContent(
            state: state,
            localAccountID: localAccountID,
            activeProfileID: "profile-a",
            accountEpoch: accountEpoch,
            hasStoredProfileToken: false,
            now: start.addingTimeInterval(3_600)
        ))
    }

    func testTopShelfRequiresCurrentUserProofForProtectedProfile() {
        let protected = RememberedProfile(
            profileID: "profile-a",
            requiredPINAtSelection: true,
            accountEpoch: accountEpoch
        )
        let state = ProfileLaunchState(
            rememberedByAccountID: [localAccountID: protected]
        )

        XCTAssertFalse(TopShelfProfilePolicy.allowsPersonalizedContent(
            state: state,
            localAccountID: localAccountID,
            activeProfileID: "profile-a",
            accountEpoch: accountEpoch,
            hasStoredProfileToken: false
        ))
        XCTAssertTrue(TopShelfProfilePolicy.allowsPersonalizedContent(
            state: state,
            localAccountID: localAccountID,
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
                accessGroup: "invalid.access.group",
                allowsAppLocalFallback: false
            ),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await store.switchActiveServer(serverId: "server-a")

        let persisted = await store.setProfileToken("proof")

        XCTAssertFalse(persisted)
        let profileToken = await store.getProfileToken()
        XCTAssertNil(profileToken)
    }

    func testUnavailableConfiguredAccessGroupUsesAppLocalKeychainWhenEnabled() {
        let service = "ProfileLaunchIdentityTests.\(UUID().uuidString)"
        let account = "profile-proof"
        let sharedKeychain = SharedKeychain(
            service: service,
            accessGroup: "invalid.access.group",
            allowsAppLocalFallback: true
        )
        let appLocalKeychain = SharedKeychain(
            service: service,
            accessGroup: nil
        )
        defer { appLocalKeychain.delete(account) }

        XCTAssertTrue(sharedKeychain.set("proof", for: account))
        XCTAssertEqual(appLocalKeychain.get(account), "proof")
        XCTAssertEqual(sharedKeychain.get(account), "proof")
        XCTAssertEqual(appLocalKeychain.get(account), "proof")
        XCTAssertTrue(sharedKeychain.delete(account))
        XCTAssertNil(sharedKeychain.get(account))
        XCTAssertNil(appLocalKeychain.get(account))
    }

    func testAppLocalKeychainFallbackPolicyIsLimitedToLegacyIOSSideloads() {
        XCTAssertTrue(
            SideloadKeychainFallbackPolicy.isEnabled(
                buildChannel: "sideload",
                isPreIOS26: true
            )
        )
        XCTAssertFalse(
            SideloadKeychainFallbackPolicy.isEnabled(
                buildChannel: "sideload",
                isPreIOS26: false
            )
        )
        XCTAssertFalse(
            SideloadKeychainFallbackPolicy.isEnabled(
                buildChannel: "release",
                isPreIOS26: true
            )
        )
        XCTAssertFalse(
            SideloadKeychainFallbackPolicy.isEnabled(
                buildChannel: "dev",
                isPreIOS26: true
            )
        )
    }

    func testAppLocalKeychainFallbackPolicyRecognizesUnsignedArchiveGroup() {
        let unprefixedGroup = "org.siloserver.silo.shared"

        XCTAssertEqual(
            SideloadKeychainFallbackPolicy.resolvedAccessGroup(
                from: unprefixedGroup,
                allowsUnprefixedSideloadGroup: true
            ),
            unprefixedGroup
        )
        XCTAssertNil(
            SideloadKeychainFallbackPolicy.resolvedAccessGroup(
                from: unprefixedGroup,
                allowsUnprefixedSideloadGroup: false
            )
        )
        XCTAssertEqual(
            SideloadKeychainFallbackPolicy.resolvedAccessGroup(
                from: "TEAMID.\(unprefixedGroup)",
                allowsUnprefixedSideloadGroup: false
            ),
            "TEAMID.\(unprefixedGroup)"
        )
        XCTAssertEqual(
            SideloadKeychainFallbackPolicy.teamPrefix(
                from: "TEAMID.\(unprefixedGroup)"
            ),
            "TEAMID."
        )
        XCTAssertNil(
            SideloadKeychainFallbackPolicy.teamPrefix(from: unprefixedGroup)
        )
    }

    private struct TokenHarness {
        let store: TokenStore
        let keychain: SharedKeychain
        let suite: UserDefaults
        let suiteName: String
        let serverID: String

        func cleanup() {
            for key in [
                SharedStorage.accessTokenAccount(for: serverID),
                SharedStorage.refreshTokenAccount(for: serverID),
                SharedStorage.profileTokenAccount(for: serverID),
                SharedStorage.accountEpochAccount(for: serverID),
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
    func testOnlyExplicitProfileErrorsTriggerRecovery() throws {
        func problem(_ identifier: String, status: Int) throws -> APIv2Error {
            let json = #"{"type":"https://siloserver.org/docs/api/v2/problems/\#(identifier)","title":"t","status":\#(status),"detail":"d"}"#
            return .problem(try HTTPClient.makeJSONDecoder().decode(APIv2Problem.self, from: Data(json.utf8)))
        }
        XCTAssertTrue(StartupContentPrefetcher.indicatesInvalidProfile(
            try problem("profile_verification_required", status: 403)
        ))
        XCTAssertFalse(StartupContentPrefetcher.indicatesInvalidProfile(
            try problem("not_found", status: 404)
        ))
        // A plain HTTP failure carries no profile verdict, whatever its body.
        XCTAssertFalse(StartupContentPrefetcher.indicatesInvalidProfile(
            HTTPError.http(statusCode: 403, body: #"{"error":"profile_unverified"}"#)
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
        let entries: [LegacyServerEntry]
    }

    /// A registry entry as builds before the profile split saved it, with
    /// the profile on the server.
    private struct LegacyServerEntry: Codable {
        let id: String
        let url: String
        let fetchedName: String?
        let profileId: String?
        let lastUsedAt: Date
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
                SharedStorage.accessTokenAccount(for: serverID),
                SharedStorage.refreshTokenAccount(for: serverID),
                SharedStorage.profileTokenAccount(for: serverID),
                SharedStorage.accountEpochAccount(for: serverID),
            ] {
                keychain.delete(key)
            }
            suite.removePersistentDomain(forName: suiteName)
        }

        let legacy = LegacyRegistryState(
            activeServerId: serverID,
            entries: [LegacyServerEntry(
                id: serverID,
                url: "https://silo.example",
                fetchedName: "Silo",
                profileId: "profile-a",
                lastUsedAt: Date(timeIntervalSinceReferenceDate: 1)
            )]
        )
        defaults.set(
            try JSONEncoder().encode(legacy),
            forKey: ServerRegistry.defaultsKey
        )
        XCTAssertTrue(keychain.set(
            "access",
            for: SharedStorage.accessTokenAccount(for: serverID)
        ))
        XCTAssertTrue(keychain.set(
            "proof",
            for: SharedStorage.profileTokenAccount(for: serverID)
        ))

        let preferences = ProfileLaunchPreferences(defaults: defaults)
        let registry = ServerRegistry(
            defaults: defaults,
            keychain: keychain,
            launchPreferences: preferences
        )

        // Account migration then moves the remembered profile onto the
        // account the server's session became.
        let account = try XCTUnwrap(
            AccountStore(keychain: keychain, defaults: defaults).accounts(onServer: serverID).first
        )
        let remembered = try XCTUnwrap(preferences.rememberedProfile(forAccount: account.localAccountId))
        XCTAssertEqual(remembered.profileID, "profile-a")
        XCTAssertTrue(remembered.requiredPINAtSelection)
        XCTAssertNil(registry.entry(with: serverID)?.legacyProfileId)
        #if os(tvOS)
        // tvOS persists the registry in the shared keychain and clears the
        // defaults copy, so the legacy field is gone with the whole record.
        XCTAssertNil(defaults.data(forKey: ServerRegistry.defaultsKey))
        #else
        let migrated = try XCTUnwrap(defaults.data(forKey: ServerRegistry.defaultsKey))
        XCTAssertFalse(String(decoding: migrated, as: UTF8.self).contains("profileId"))
        #endif
    }

    // MARK: - TV first launch

    func testFreshTVAsksWhoIsWatchingAndOffersToRemember() {
        let tv = ProfileLaunchState.fresh(isTV: true)
        XCTAssertEqual(tv.behavior, .askEveryLaunch)
        XCTAssertEqual(tv.rememberOfferPending, true)

        let phone = ProfileLaunchState.fresh(isTV: false)
        XCTAssertEqual(phone.behavior, .automatic)
        XCTAssertNil(phone.rememberOfferPending)
    }

    func testStateSavedBeforeTheOfferExistedKeepsItsBehavior() throws {
        // State written by an earlier build has no rememberOfferPending key.
        let saved = #"{"behavior":"automatic","rememberedByServerID":{},"selectionRequiredServerIDs":[]}"#
        let decoded = try JSONDecoder().decode(ProfileLaunchState.self, from: Data(saved.utf8))
        XCTAssertEqual(decoded.behavior, .automatic)
        XCTAssertNil(decoded.rememberOfferPending)
    }

    func testRememberOfferAnswersPersistOnce() throws {
        for remember in [true, false] {
            let suiteName = "ProfileLaunchPolicyTests.\(UUID().uuidString)"
            let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { suite.removePersistentDomain(forName: suiteName) }
            let defaults = SharedDefaults(suite: suite, standard: suite)
            let fresh = try JSONEncoder().encode(ProfileLaunchState.fresh(isTV: true))
            defaults.set(fresh, forKey: SharedStorage.profileLaunchStateKey)

            let preferences = ProfileLaunchPreferences(defaults: defaults)
            XCTAssertTrue(preferences.isRememberOfferPending)
            XCTAssertTrue(preferences.answerRememberOffer(remember: remember))

            let restored = ProfileLaunchPreferences(defaults: defaults)
            XCTAssertFalse(restored.isRememberOfferPending)
            XCTAssertEqual(restored.behavior, remember ? .automatic : .askEveryLaunch)
        }
    }

    func testChoosingABehaviorInSettingsEndsTheOffer() throws {
        let suiteName = "ProfileLaunchPolicyTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defaults.set(try JSONEncoder().encode(ProfileLaunchState.fresh(isTV: true)), forKey: SharedStorage.profileLaunchStateKey)

        let preferences = ProfileLaunchPreferences(defaults: defaults)
        preferences.behavior = .afterOneHour
        XCTAssertFalse(preferences.isRememberOfferPending)
        XCTAssertEqual(ProfileLaunchPreferences(defaults: defaults).behavior, .afterOneHour)
    }

    func testChoosingTheCurrentBehaviorInSettingsEndsTheOffer() throws {
        let suiteName = "ProfileLaunchPolicyTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defaults.set(try JSONEncoder().encode(ProfileLaunchState.fresh(isTV: true)), forKey: SharedStorage.profileLaunchStateKey)

        let preferences = ProfileLaunchPreferences(defaults: defaults)
        preferences.behavior = .askEveryLaunch
        XCTAssertFalse(preferences.isRememberOfferPending)
        XCTAssertFalse(ProfileLaunchPreferences(defaults: defaults).isRememberOfferPending)
    }

    func testLegacyMigrationThatCannotBeSavedChangesNothing() throws {
        let serverID = "server-a"
        let accountEpoch = "account-a"
        let suiteName = "ProfileLaunchPolicyTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defaults.set(try JSONEncoder().encode(ProfileLaunchState.fresh(isTV: true)), forKey: SharedStorage.profileLaunchStateKey)
        var allowsPersistence = true
        let preferences = ProfileLaunchPreferences(defaults: defaults, persistenceOverride: { _ in allowsPersistence })
        allowsPersistence = false

        XCTAssertFalse(preferences.migrateLegacyProfile(
            profileID: "profile-a", requiresPIN: false, accountEpoch: accountEpoch, for: serverID
        ))
        XCTAssertNil(preferences.state.rememberedByServerID[serverID])
        XCTAssertEqual(preferences.behavior, .askEveryLaunch)
        XCTAssertTrue(preferences.isRememberOfferPending)
    }

    func testMigratedLegacyProfileKeepsOpeningOnAFreshTVState() throws {
        let serverID = "server-a"
        let accountEpoch = "account-a"
        let suiteName = "ProfileLaunchPolicyTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { suite.removePersistentDomain(forName: suiteName) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defaults.set(try JSONEncoder().encode(ProfileLaunchState.fresh(isTV: true)), forKey: SharedStorage.profileLaunchStateKey)

        let preferences = ProfileLaunchPreferences(defaults: defaults)
        XCTAssertTrue(preferences.migrateLegacyProfile(
            profileID: "profile-a",
            requiresPIN: false,
            accountEpoch: accountEpoch,
            for: serverID
        ))
        XCTAssertEqual(preferences.behavior, .automatic)
        XCTAssertFalse(preferences.isRememberOfferPending)
        // Account migration moves the server's memory onto its account.
        let localAccountID = "local-account-a"
        XCTAssertTrue(preferences.adoptLegacyServerMemory(owners: [serverID: localAccountID]))
        XCTAssertEqual(
            preferences.resolution(forAccount: localAccountID, accountEpoch: accountEpoch, hasStoredProfileToken: false),
            .restore(RememberedProfile(profileID: "profile-a", requiredPINAtSelection: false, accountEpoch: accountEpoch))
        )
    }
}
