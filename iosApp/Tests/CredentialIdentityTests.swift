import Foundation
import XCTest
@testable import Silo

/// Pins the one ownership comparator and the fence built on it.
///
/// `sameCredentialIdentity(as:)` is the field set every fence in the client
/// relies on. The table below changes exactly one field at a time so a future
/// edit that drops a field (the leak the audit found in hand-written copies)
/// or adds `accessToken` (which would break shared-refresh detection) fails
/// here rather than in production.
final class CredentialIdentityTests: XCTestCase {
    private static let generation = UUID()

    private static func auth(
        serverId: String = "server-a",
        serverURL: String = "https://silo.example",
        generation: UUID = CredentialIdentityTests.generation,
        credentialOwner: CapturedHTTPRequestCredentialOwner = .persistentServer(serverId: "server-a"),
        accessToken: String? = "access",
        profileId: String? = "profile-a",
        profileToken: String? = "proof-a"
    ) -> CapturedOrdinaryRequestAuth {
        CapturedOrdinaryRequestAuth(
            account: RefreshAccountIdentity(
                serverId: serverId,
                serverURL: serverURL,
                credentialGenerationID: generation
            ),
            credentialOwner: credentialOwner,
            accessToken: accessToken,
            profileId: profileId,
            profileToken: profileToken
        )
    }

    func testIdenticalCapturesMatch() {
        XCTAssertTrue(Self.auth().sameCredentialIdentity(as: Self.auth()))
    }

    /// Each stored identity field, changed alone, breaks the match.
    func testEachIdentityFieldDifferingAloneBreaksTheMatch() {
        let base = Self.auth()
        let variants: [(String, CapturedOrdinaryRequestAuth)] = [
            ("account.serverId", Self.auth(serverId: "server-b")),
            ("account.serverURL", Self.auth(serverURL: "https://other.example")),
            ("account.credentialGenerationID", Self.auth(generation: UUID())),
            ("credentialOwner", Self.auth(credentialOwner: .temporary)),
            ("profileId", Self.auth(profileId: "profile-b")),
            ("profileId nil", Self.auth(profileId: nil)),
            ("profileToken", Self.auth(profileToken: "proof-b")),
            ("profileToken nil", Self.auth(profileToken: nil)),
        ]
        for (field, variant) in variants {
            XCTAssertFalse(
                base.sameCredentialIdentity(as: variant),
                "\(field) differing alone must break the identity match"
            )
            XCTAssertFalse(
                variant.sameCredentialIdentity(as: base),
                "\(field) comparison must be symmetric"
            )
        }
    }

    /// Access-token rotation is the one change that keeps the owner: a shared
    /// refresh must let its caller detect the new token through this match.
    func testAccessTokenDifferingAloneStillMatches() {
        let base = Self.auth()
        XCTAssertTrue(base.sameCredentialIdentity(as: Self.auth(accessToken: "rotated")))
        XCTAssertTrue(base.sameCredentialIdentity(as: Self.auth(accessToken: nil)))
        XCTAssertNotEqual(base, Self.auth(accessToken: "rotated"), "Equatable still sees the token")
    }

    // MARK: - withOwnerFence

    private func makeStore() async throws -> (TokenStore, SharedKeychain) {
        let name = "CredentialIdentityTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        addTeardownBlock {
            for key in [
                TokenStore.accessTokenKey(for: "server-a"),
                TokenStore.refreshTokenKey(for: "server-a"),
                TokenStore.profileTokenKey(for: "server-a"),
                TokenStore.accountEpochKey(for: "server-a"),
                AccountSessionPersistence.recordKey("server-a"),
                AccountSessionPersistence.markerKey("server-a"),
                SharedStorage.mirroredAccessTokenAccount,
                SharedStorage.mirroredProfileTokenAccount,
            ] {
                keychain.withAudience(.userIndependent).delete(key)
                keychain.withAudience(.currentUser).delete(key)
            }
            UserDefaults().removePersistentDomain(forName: name)
        }
        let store = TokenStore(
            keychain: keychain,
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await store.switchActiveServer(serverId: "server-a")
        await store.setServerUrl("https://silo.example")
        let saved = await store.saveTokens(accessToken: "access", refreshToken: "refresh")
        XCTAssertTrue(saved)
        await store.setProfileId("profile-a")
        let proofStored = await store.setProfileToken("proof-a")
        XCTAssertTrue(proofStored)
        return (store, keychain)
    }

    func testFencePassesWhenOwnerIsUnchanged() async throws {
        let (store, _) = try await makeStore()
        let ownerValue = await store.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(ownerValue)
        let result = try await store.withOwnerFence(owner) { "applied" }
        XCTAssertEqual(result, "applied")
    }

    func testFencePassesAcrossAccessTokenRotation() async throws {
        let (store, _) = try await makeStore()
        let ownerValue = await store.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(ownerValue)
        let result = try await store.withOwnerFence(owner) {
            let rotated = await store.saveRefreshedTokens(
                "access-2",
                "refresh-2",
                replacing: CapturedRefreshCredential(
                    account: owner.account,
                    refreshToken: "refresh",
                    owner: owner.credentialOwner
                )
            )
            XCTAssertTrue(rotated)
            return "applied"
        }
        XCTAssertEqual(result, "applied")
        let current = await store.getAccessToken()
        XCTAssertEqual(current, "access-2")
    }

    func testFenceRejectsProfileSwitchDuringBody() async throws {
        let (store, _) = try await makeStore()
        let ownerValue = await store.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(ownerValue)
        do {
            _ = try await store.withOwnerFence(owner) {
                let activated = await store.activateProfile(
                    profileID: "profile-b",
                    profileToken: "proof-b",
                    expectedAccount: owner.account
                )
                XCTAssertTrue(activated)
                return "must not be applied"
            }
            XCTFail("Fence accepted a response after the profile changed")
        } catch HTTPError.authorityChanged {}
    }

    func testFenceRejectsProfileProofClearDuringBody() async throws {
        let (store, _) = try await makeStore()
        let ownerValue = await store.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(ownerValue)
        do {
            _ = try await store.withOwnerFence(owner) {
                let cleared = await store.setProfileToken(nil)
                XCTAssertTrue(cleared)
                return "must not be applied"
            }
            XCTFail("Fence accepted a response after the profile proof was cleared")
        } catch HTTPError.authorityChanged {}
    }

    func testFenceRejectsSignOutAndReloginDuringBody() async throws {
        let (store, _) = try await makeStore()
        let ownerValue = await store.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(ownerValue)
        do {
            _ = try await store.withOwnerFence(owner) {
                let cleared = await store.clearTokens()
                XCTAssertTrue(cleared)
                let saved = await store.saveTokens(accessToken: "access-again", refreshToken: "refresh-again")
                XCTAssertTrue(saved)
                await store.setProfileId("profile-a")
                _ = await store.setProfileToken("proof-a")
                return "must not be applied"
            }
            XCTFail("Fence accepted a response across a sign-out and re-login on the same server")
        } catch HTTPError.authorityChanged {}
    }

    func testFenceRejectsTemporaryScopeInstalledDuringBody() async throws {
        let (store, _) = try await makeStore()
        let ownerValue = await store.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(ownerValue)
        do {
            _ = try await store.withOwnerFence(owner) {
                await store.beginTemporaryScope(TemporaryAuthScope(
                    serverId: "server-a",
                    serverURL: "https://silo.example",
                    accessToken: "temporary",
                    refreshToken: "temporary-refresh",
                    profileId: "profile-a",
                    profileToken: "proof-a",
                    controllerDeviceId: "controller",
                    expiresAt: Date().addingTimeInterval(60)
                ))
                return "must not be applied"
            }
            XCTFail("Fence accepted a response after a temporary owner replaced the persistent one")
        } catch HTTPError.authorityChanged {}
    }

    func testFenceRejectsStaleOwnerBeforeBodyRuns() async throws {
        let (store, _) = try await makeStore()
        let ownerValue = await store.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(ownerValue)
        await store.setProfileId("profile-b")
        let bodyRan = BodyFlag()
        do {
            _ = try await store.withOwnerFence(owner) {
                bodyRan.set()
                return "must not run"
            }
            XCTFail("Fence dispatched under an owner that had already changed")
        } catch HTTPError.authorityChanged {}
        XCTAssertFalse(bodyRan.value, "A stale owner must be refused before the request is sent")
    }

    // MARK: - withCurrentDurableAuthority

    /// A durable authority is bound to the verified account and its epoch, so
    /// it must outlive the one credential change a request owner ignores too:
    /// access-token rotation.
    func testDurableAuthoritySurvivesAccessTokenRotation() async throws {
        let (store, _) = try await makeStore()
        let ownerValue = await store.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(ownerValue)
        // A durable authority only exists for a verified account binding.
        try await store.bindVerifiedAccount("12", expected: owner)
        let durableValue = await store.captureDurableAccountAuth()
        let durable = try XCTUnwrap(durableValue)
        let rotated = await store.saveRefreshedTokens(
            "access-2",
            "refresh-2",
            replacing: CapturedRefreshCredential(
                account: owner.account,
                refreshToken: "refresh",
                owner: owner.credentialOwner
            )
        )
        XCTAssertTrue(rotated)
        let ran = BodyFlag()
        try await store.withCurrentDurableAuthority(durable) { ran.set() }
        XCTAssertTrue(ran.value, "queued work must still run for the same account after a token refresh")
    }

    /// A profile switch does change the owner the queued work was prepared
    /// for, so the durable fence must refuse it.
    func testDurableAuthorityRejectsProfileSwitch() async throws {
        let (store, _) = try await makeStore()
        let ownerValue = await store.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(ownerValue)
        try await store.bindVerifiedAccount("12", expected: owner)
        let durableValue = await store.captureDurableAccountAuth()
        let durable = try XCTUnwrap(durableValue)
        await store.setProfileId("profile-b")
        _ = await store.setProfileToken("proof-b")
        let ran = BodyFlag()
        do {
            try await store.withCurrentDurableAuthority(durable) { ran.set() }
            XCTFail("Durable fence accepted work prepared for another profile")
        } catch HTTPError.authorityChanged {}
        XCTAssertFalse(ran.value)
    }

    func testFencePropagatesBodyErrorsUnchanged() async throws {
        let (store, _) = try await makeStore()
        let ownerValue = await store.captureOrdinaryRequestAuth()
        let owner = try XCTUnwrap(ownerValue)
        do {
            _ = try await store.withOwnerFence(owner) { () async throws -> String in
                throw HTTPError.http(statusCode: 503, body: nil)
            }
            XCTFail("Body error was swallowed")
        } catch HTTPError.http(let status, _) {
            XCTAssertEqual(status, 503)
        }
    }
}

private final class BodyFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    var value: Bool { lock.withLock { flag } }
    func set() { lock.withLock { flag = true } }
}
