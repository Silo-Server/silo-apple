#if os(iOS)
import Foundation
import XCTest
@testable import Silo

/// Ordered Apple push registration on `POST /api/v2/devices/push/apple`:
/// the installation key and generation headers, the journal's allocation and
/// exact-replay rules, and the three outcomes.
final class ApplePushOrderedRegistrationTests: XCTestCase {
    private static let serverID = "server-a"
    private static let capabilityPath = "/api/v2/devices/push/apple/capabilities"
    private static let registrationPath = "/api/v2/devices/push/apple"
    private static let tokenA = String(repeating: "ab", count: 32)
    private static let tokenB = String(repeating: "cd", count: 32)

    /// A server that echoes the generation it was sent unless a queued reply
    /// says otherwise.
    private final class PushServer: @unchecked Sendable {
        enum Reply {
            case receipt(generation: String? = nil, enabled: Bool = true, removed: Bool = false,
                         displayToken: String? = "display-1")
            case problem(Int, String)
            case transportFailure
            case gated(StubURLProtocol.Gate)
        }

        let handler = StubURLProtocol.Handler()
        private let lock = NSLock()
        private var capability = #"{"allowed":true,"registration_available":true,"revision":"r1","state":"available"}"#
        private var replies: [Reply] = []

        init() {
            handler.route(StubURLProtocol.method("GET", path: ApplePushOrderedRegistrationTests.capabilityPath)) { [self] _ in
                .json(lock.withLock { capability })
            }
            handler.route(StubURLProtocol.method("POST", path: ApplePushOrderedRegistrationTests.registrationPath)) { [self] request in
                var reply = lock.withLock { replies.isEmpty ? Reply.receipt() : replies.removeFirst() }
                if case .gated(let gate) = reply {
                    await gate.wait()
                    reply = .receipt()
                }
                switch reply {
                case .receipt(let generation, let enabled, let removed, let displayToken):
                    var body: [String: Any] = [
                        "generation": generation ?? request.header("X-Push-Generation") ?? "",
                        "id": "registration-1", "server_device_id": "server-device-1",
                        "push_mode": "private_push", "enabled": enabled, "removed": removed,
                    ]
                    if let displayToken {
                        body["display_token"] = displayToken
                        body["display_token_expires_at"] = "2099-01-01T00:00:00Z"
                    }
                    return .json(String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self))
                case .problem(let status, let type):
                    return .json(#"{"type":"https://silo.example/problems/\#(type)","title":"t","status":\#(status),"detail":"d"}"#,
                        status: status, headers: ["Content-Type": "application/problem+json"])
                case .transportFailure, .gated:
                    throw URLError(.networkConnectionLost)
                }
            }
        }

        func setCapability(_ json: String) { lock.withLock { capability = json } }
        func enqueue(_ reply: Reply) { lock.withLock { replies.append(reply) } }

        var registrations: [StubURLProtocol.Request] {
            handler.requests.filter { $0.method == "POST" && $0.path == ApplePushOrderedRegistrationTests.registrationPath }
        }
    }

    private struct Harness {
        let tokens: TokenStore
        let server: PushServer
        let journal: ApplePushInstallationJournal
        let displayTokens: ApplePushDisplayTokenStore
        let api: APIv2Client

        func registrar() -> ApplePushRegistrar {
            ApplePushRegistrar(api: api, tokenStore: tokens, journal: journal, displayTokens: displayTokens)
        }

        func owner() async throws -> CapturedDurableAccountAuth {
            let value = await tokens.captureDurableAccountAuth()
            return try XCTUnwrap(value)
        }

        func record() throws -> ApplePushInstallationRecord? {
            try journal.load(serverID: ApplePushOrderedRegistrationTests.serverID)
        }
    }

    private func makeHarness() async throws -> Harness {
        let name = "ApplePushOrderedRegistrationTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        let journal = ApplePushInstallationJournal(keychain: keychain.withAudience(.userIndependent))
        addTeardownBlock {
            for key in [
                TokenStore.accessTokenKey(for: Self.serverID),
                TokenStore.refreshTokenKey(for: Self.serverID),
                TokenStore.profileTokenKey(for: Self.serverID),
                TokenStore.accountEpochKey(for: Self.serverID),
                AccountSessionPersistence.recordKey(Self.serverID),
                AccountSessionPersistence.markerKey(Self.serverID),
                SharedStorage.mirroredAccessTokenAccount,
                SharedStorage.mirroredProfileTokenAccount,
                SharedStorage.applePushDisplayTokenAccount,
                ApplePushInstallationJournal.account(for: Self.serverID),
            ] {
                keychain.withAudience(.userIndependent).delete(key)
                keychain.withAudience(.currentUser).delete(key)
            }
            UserDefaults().removePersistentDomain(forName: name)
        }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let tokens = TokenStore(keychain: keychain, defaults: defaults)
        await tokens.switchActiveServer(serverId: Self.serverID)
        await tokens.setServerUrl("https://silo.example")
        let saved = await tokens.saveTokens(accessToken: "access", refreshToken: "refresh")
        XCTAssertTrue(saved)
        await tokens.setProfileId("profile-a")
        let proofStored = await tokens.setProfileToken("proof-a")
        XCTAssertTrue(proofStored)
        let captured = await tokens.captureOrdinaryRequestAuth()
        let requestOwner = try XCTUnwrap(captured)
        try await tokens.bindVerifiedAccount("12", expected: requestOwner)

        let server = PushServer()
        let api = APIv2Client(http: HTTPClient(session: server.handler.makeSession(), tokenStore: tokens),
            tokenStore: tokens, isUpdateRequired: { false })
        let displayTokens = ApplePushDisplayTokenStore(keychain: keychain.withAudience(.currentUser), defaults: defaults)
        return Harness(tokens: tokens, server: server, journal: journal, displayTokens: displayTokens, api: api)
    }

    private static func body(token: String = tokenA) -> APIv2ApplePushRegistrationBody {
        APIv2ApplePushRegistrationBody(deviceId: "device-1", apnsToken: token, apnsEnvironment: "sandbox",
            apnsTopic: "org.siloserver.silo", pushMode: "private_push")
    }

    private static let accepted = ApplePushRegistrar.Result.registered(ApplePushAcceptedRegistration(
        id: "registration-1", serverDeviceID: "server-device-1", enabled: true, removed: false))

    // MARK: - Wire

    func testFirstRegistrationSendsOrderedHeadersAndProfileScope() async throws {
        let h = try await makeHarness()
        let owner = try await h.owner()
        let result = await h.registrar().register(Self.body(), owner: owner)

        XCTAssertEqual(result, Self.accepted)
        XCTAssertEqual(h.server.handler.requests.map(\.path), [Self.capabilityPath, Self.registrationPath])
        let request = try XCTUnwrap(h.server.registrations.first)
        let key = try XCTUnwrap(request.header("X-Push-Installation-Key"))
        XCTAssertTrue(ApplePushInstallationJournal.isInstallationKey(key))
        XCTAssertEqual(request.header("X-Push-Generation"), "1")
        XCTAssertEqual(request.header("X-Profile-Id"), "profile-a")
        XCTAssertEqual(request.header("X-Profile-Token"), "proof-a")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String])
        XCTAssertEqual(sent, [
            "device_id": "device-1", "apns_token": Self.tokenA, "apns_environment": "sandbox",
            "apns_topic": "org.siloserver.silo", "push_mode": "private_push",
        ])
        XCTAssertEqual(try h.record()?.installationKey, key)
        XCTAssertTrue(h.displayTokens.hasCurrentToken(forServerID: Self.serverID))
    }

    func testAcceptedIntentWithCurrentDisplayTokenSendsNothing() async throws {
        let h = try await makeHarness()
        let owner = try await h.owner()
        _ = await h.registrar().register(Self.body(), owner: owner)
        let count = h.server.handler.requests.count

        let result = await h.registrar().register(Self.body(), owner: owner)

        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(h.server.handler.requests.count, count)
    }

    // MARK: - Allocation and exact replay

    /// A lost answer keeps its generation. The next attempt, even from a new
    /// process, sends the same key, generation and body bytes.
    func testLostAnswerIsReplayedExactlyAfterRestart() async throws {
        let h = try await makeHarness()
        let owner = try await h.owner()
        h.server.enqueue(.transportFailure)
        let first = await h.registrar().register(Self.body(), owner: owner)
        XCTAssertEqual(first, .uncertain)
        XCTAssertEqual(try h.record()?.latest?.outcome, .pending)

        let replay = await h.registrar().register(Self.body(), owner: owner)

        XCTAssertEqual(replay, Self.accepted)
        let sends = h.server.registrations
        XCTAssertEqual(sends.count, 2)
        XCTAssertEqual(sends.map { $0.header("X-Push-Generation") }, ["1", "1"])
        XCTAssertEqual(sends[0].header("X-Push-Installation-Key"), sends[1].header("X-Push-Installation-Key"))
        XCTAssertEqual(sends[0].body, sends[1].body)
    }

    /// A new intent supersedes a lost one on the server whether or not the
    /// lost one landed, so it takes the next generation with the same key.
    func testChangedTokenAfterLostAnswerTakesNextGeneration() async throws {
        let h = try await makeHarness()
        let owner = try await h.owner()
        h.server.enqueue(.transportFailure)
        _ = await h.registrar().register(Self.body(), owner: owner)

        let result = await h.registrar().register(Self.body(token: Self.tokenB), owner: owner)

        XCTAssertEqual(result, Self.accepted)
        let sends = h.server.registrations
        XCTAssertEqual(sends.map { $0.header("X-Push-Generation") }, ["1", "2"])
        XCTAssertEqual(sends[0].header("X-Push-Installation-Key"), sends[1].header("X-Push-Installation-Key"))
        XCTAssertTrue(sends[1].bodyString?.contains(Self.tokenB) ?? false)
    }

    /// The key survives account and profile switches; the new owner's intent
    /// takes the next generation.
    func testProfileSwitchKeepsInstallationKeyAndAdvancesGeneration() async throws {
        let h = try await makeHarness()
        let first = try await h.owner()
        _ = await h.registrar().register(Self.body(), owner: first)
        await h.tokens.setProfileId("profile-b")
        _ = await h.tokens.setProfileToken("proof-b")

        let owner = try await h.owner()
        let result = await h.registrar().register(Self.body(), owner: owner)

        XCTAssertEqual(result, Self.accepted)
        let sends = h.server.registrations
        XCTAssertEqual(sends.map { $0.header("X-Push-Generation") }, ["1", "2"])
        XCTAssertEqual(sends.map { $0.header("X-Profile-Id") }, ["profile-a", "profile-b"])
        XCTAssertEqual(sends[0].header("X-Push-Installation-Key"), sends[1].header("X-Push-Installation-Key"))
    }

    // MARK: - Refusals

    func testRefusedIntentIsNotResentAndChangedIntentTakesNextGeneration() async throws {
        let h = try await makeHarness()
        let owner = try await h.owner()
        h.server.enqueue(.problem(409, "conflict"))
        let refused = await h.registrar().register(Self.body(), owner: owner)
        XCTAssertEqual(refused, .refused(reason: "http_409_conflict"))
        let count = h.server.handler.requests.count

        let again = await h.registrar().register(Self.body(), owner: owner)
        XCTAssertEqual(again, .unchanged)
        XCTAssertEqual(h.server.handler.requests.count, count, "a refused intent must not be sent again")

        let changed = await h.registrar().register(Self.body(token: Self.tokenB), owner: owner)
        XCTAssertEqual(changed, Self.accepted)
        XCTAssertEqual(h.server.registrations.map { $0.header("X-Push-Generation") }, ["1", "2"])
    }

    func testForbiddenAndValidationFailuresAreRefusals() async throws {
        for (status, type) in [(403, "permission_denied"), (422, "validation_failed")] {
            let h = try await makeHarness()
            h.server.enqueue(.problem(status, type))
            let owner = try await h.owner()
        let result = await h.registrar().register(Self.body(), owner: owner)
            XCTAssertEqual(result, .refused(reason: "http_\(status)_\(type)"))
            XCTAssertEqual(try h.record()?.latest?.outcome, .refused(reason: "http_\(status)_\(type)"))
        }
    }

    /// A server error is not about the intent: it stays pending for exact
    /// replay instead of being dropped or refused.
    func testServerErrorKeepsIntentPending() async throws {
        let h = try await makeHarness()
        h.server.enqueue(.problem(503, "service_unavailable"))
        let owner = try await h.owner()
        let result = await h.registrar().register(Self.body(), owner: owner)
        XCTAssertEqual(result, .uncertain)
        XCTAssertEqual(try h.record()?.latest?.outcome, .pending)
    }

    func testReceiptForAnotherGenerationIsRefusedAndStoresNoDisplayToken() async throws {
        let h = try await makeHarness()
        h.server.enqueue(.receipt(generation: "7"))
        let owner = try await h.owner()
        let result = await h.registrar().register(Self.body(), owner: owner)
        XCTAssertEqual(result, .refused(reason: "invalid_receipt"))
        XCTAssertFalse(h.displayTokens.hasCurrentToken(forServerID: Self.serverID))
    }

    // MARK: - Capability and journal gates

    func testUnavailableCapabilitySendsAndAllocatesNothing() async throws {
        let h = try await makeHarness()
        let owner = try await h.owner()
        h.server.setCapability(#"{"allowed":true,"registration_available":false,"revision":"r2","state":"not_configured"}"#)
        let result = await h.registrar().register(Self.body(), owner: owner)
        XCTAssertEqual(result, .unavailable)
        XCTAssertTrue(h.server.registrations.isEmpty)
        XCTAssertNil(try h.record())

        h.server.setCapability(#"{"allowed":true,"registration_available":true,"revision":"r3","state":"available"}"#)
        _ = await h.registrar().register(Self.body(), owner: owner)
        XCTAssertEqual(h.server.registrations.map { $0.header("X-Push-Generation") }, ["1"])
    }

    func testUnreadableJournalIsNeitherOverwrittenNorSent() async throws {
        let h = try await makeHarness()
        let account = ApplePushInstallationJournal.account(for: Self.serverID)
        XCTAssertTrue(h.journal.keychain.set("not a record", for: account))

        let owner = try await h.owner()
        let result = await h.registrar().register(Self.body(), owner: owner)

        guard case .notSent = result else { return XCTFail("unexpected \(result)") }
        XCTAssertTrue(h.server.handler.requests.isEmpty)
        XCTAssertEqual(try h.journal.keychain.getChecked(account), "not a record")
    }

    func testBodyOutsideTheContractConsumesNoGeneration() async throws {
        let h = try await makeHarness()
        let foreignTopic = APIv2ApplePushRegistrationBody(deviceId: "device-1", apnsToken: Self.tokenA,
            apnsEnvironment: "sandbox", apnsTopic: "org.example.personal", pushMode: "private_push")
        let owner = try await h.owner()
        let result = await h.registrar().register(foreignTopic, owner: owner)
        XCTAssertEqual(result, .notSent(reason: "invalid_apns_topic"))
        XCTAssertTrue(h.server.handler.requests.isEmpty)
        XCTAssertNil(try h.record())
    }

    // MARK: - Display token

    /// A renewal is an exact replay. When it reports the registration as
    /// removed, the display token is cleared and the intent is not renewed
    /// again.
    func testRemovedRegistrationClearsDisplayTokenAndStopsRenewal() async throws {
        let h = try await makeHarness()
        let owner = try await h.owner()
        _ = await h.registrar().register(Self.body(), owner: owner)
        h.displayTokens.store(nil, expiresAt: nil, serverId: Self.serverID)
        h.server.enqueue(.receipt(removed: true, displayToken: "must-not-store"))

        let renewal = await h.registrar().register(Self.body(), owner: owner)

        XCTAssertEqual(renewal, .registered(ApplePushAcceptedRegistration(
            id: "registration-1", serverDeviceID: "server-device-1", enabled: true, removed: true)))
        XCTAssertEqual(h.server.registrations.map { $0.header("X-Push-Generation") }, ["1", "1"])
        XCTAssertFalse(h.displayTokens.hasCurrentToken(forServerID: Self.serverID))
        let count = h.server.handler.requests.count
        let after = await h.registrar().register(Self.body(), owner: owner)
        XCTAssertEqual(after, .unchanged)
        XCTAssertEqual(h.server.handler.requests.count, count)
    }

    /// An owner change while the send is in flight discards the answer: no
    /// display token is written for the replaced profile, and the intent stays
    /// pending because its outcome was never seen.
    func testOwnerChangeInFlightStoresNoDisplayTokenAndKeepsIntentPending() async throws {
        let h = try await makeHarness()
        let owner = try await h.owner()
        let gate = StubURLProtocol.Gate()
        h.server.enqueue(.gated(gate))
        let registrar = h.registrar()
        let task = Task { await registrar.register(Self.body(), owner: owner) }
        try await h.server.handler.waitForRequest(where: StubURLProtocol.method("POST", path: Self.registrationPath))
        await h.tokens.setProfileId("profile-b")
        await gate.open()

        let result = await task.value

        XCTAssertEqual(result, .uncertain)
        XCTAssertFalse(h.displayTokens.hasCurrentToken(forServerID: Self.serverID))
        XCTAssertEqual(try h.record()?.latest?.outcome, .pending)
    }

    // MARK: - Journal

    func testInstallationKeyFormat() throws {
        let key = try XCTUnwrap(ApplePushInstallationJournal.randomInstallationKey())
        XCTAssertEqual(key.count, 43)
        XCTAssertTrue(ApplePushInstallationJournal.isInstallationKey(key))
        XCTAssertFalse(ApplePushInstallationJournal.isInstallationKey(key + "="))
        XCTAssertFalse(ApplePushInstallationJournal.isInstallationKey(String(key.dropLast())))
        XCTAssertFalse(ApplePushInstallationJournal.isInstallationKey(String(repeating: "+", count: 43)))
    }

    func testGenerationExhaustionAllocatesNothing() throws {
        let owner = ApplePushInstallationIntent(owner: try Self.intentOwner(), body: Self.body())
        let record = ApplePushInstallationRecord(
            installationKey: try XCTUnwrap(ApplePushInstallationJournal.randomInstallationKey()),
            generation: .max, latest: nil)
        XCTAssertThrowsError(try ApplePushInstallationJournal.plan(record, desired: owner, renewDisplayToken: false)) { error in
            XCTAssertEqual(error as? ApplePushInstallationJournal.JournalError, .generationExhausted)
        }
    }

    private static func intentOwner() throws -> ApplePushIntentOwner {
        let auth = CapturedDurableAccountAuth(accountID: "12", accountEpoch: UUID(),
            request: CapturedOrdinaryRequestAuth(
                account: RefreshAccountIdentity(serverId: serverID, serverURL: "https://silo.example",
                    credentialGenerationID: UUID()),
                credentialOwner: .persistentServer(serverId: serverID),
                accessToken: "access", profileId: "profile-a", profileToken: nil))
        return try XCTUnwrap(ApplePushIntentOwner(auth))
    }
}
#endif
