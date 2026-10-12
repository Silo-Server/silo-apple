#if os(iOS)
import Foundation
import XCTest
@testable import Silo

/// Ordered Apple push registration on `POST /api/v2/devices/push/apple`:
/// the installation key and generation headers, the journal's allocation and
/// exact-replay rules, and the three outcomes.
final class ApplePushOrderedRegistrationTests: XCTestCase {
    private static let serverURL = "https://silo.example"
    /// Registry ids are derived from the address, which is what lets a saved
    /// server's stored session be used while another server is active.
    private static let serverID = ServerRegistry.serverId(for: serverURL)
    private static let otherServerURL = "https://other.example"
    private static let otherServerID = ServerRegistry.serverId(for: otherServerURL)
    private static let tokenExpiry = "2099-01-01T00:00:00Z"
    /// A day before the stub's tokens expire, inside the renewal window.
    private static let renewalDue = ISO8601DateFormatter().date(from: tokenExpiry)!.addingTimeInterval(-86_400)
    private static let capabilityPath = "/api/v2/devices/push/apple/capabilities"
    private static let registrationPath = "/api/v2/devices/push/apple"
    private static let tokenA = String(repeating: "ab", count: 32)
    private static let tokenB = String(repeating: "cd", count: 32)

    /// A server that echoes the generation it was sent unless a queued reply
    /// says otherwise.
    private final class PushServer: @unchecked Sendable {
        enum Reply {
            case receipt(generation: String? = nil, enabled: Bool = true, removed: Bool = false,
                         displayToken: String? = "display-1", serverID: String? = "deployment-a")
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
                case .receipt(let generation, let enabled, let removed, let displayToken, let serverID):
                    let sent = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any]
                    var body: [String: Any] = [
                        "generation": generation ?? request.header("X-Push-Generation") ?? "",
                        "id": "registration-1", "server_device_id": "server-device-1",
                        "push_mode": sent?["push_mode"] ?? "private_push", "enabled": enabled, "removed": removed,
                    ]
                    if let displayToken {
                        body["display_token"] = displayToken
                        body["display_token_expires_at"] = ApplePushOrderedRegistrationTests.tokenExpiry
                    }
                    if let serverID {
                        body["server_id"] = serverID
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

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { current } }
        func advance(by interval: TimeInterval) { lock.withLock { current += interval } }
        func set(_ date: Date) { lock.withLock { current = date } }
    }

    private struct Harness {
        let tokens: TokenStore
        let server: PushServer
        let journal: ApplePushInstallationJournal
        let targets: ApplePushDisplayTargetStore
        let http: HTTPClient
        let api: APIv2Client
        let defaults: SharedDefaults

        func registrar(clock: Clock? = nil, savedServerIdentity: String? = nil) -> ApplePushRegistrar {
            let now: @Sendable () -> Date = clock.map { clock in { clock.now } } ?? { Date() }
            return ApplePushRegistrar(api: api, tokenStore: tokens, journal: journal, displayTargets: targets,
                savedServers: ApplePushSavedServerClient(http: http, tokenStore: tokens,
                    session: server.handler.makeSession()),
                savedServerIdentity: { _ in savedServerIdentity }, now: now)
        }

        /// Signs in to a second saved server, which becomes the active one.
        func signInToOtherServer() async throws {
            await tokens.switchActiveServer(serverId: ApplePushOrderedRegistrationTests.otherServerID)
            await tokens.setServerUrl(ApplePushOrderedRegistrationTests.otherServerURL)
            let saved = await tokens.saveTokens(accessToken: "other-access", refreshToken: "other-refresh")
            XCTAssertTrue(saved)
            await tokens.setProfileId("other-profile")
            let captured = await tokens.captureOrdinaryRequestAuth()
            try await tokens.bindVerifiedAccount("34", expected: XCTUnwrap(captured))
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
            let perServer = [Self.serverID, Self.otherServerID].flatMap { serverID in [
                TokenStore.accessTokenKey(for: serverID),
                TokenStore.refreshTokenKey(for: serverID),
                TokenStore.profileTokenKey(for: serverID),
                TokenStore.accountEpochKey(for: serverID),
                AccountSessionPersistence.recordKey(serverID),
                AccountSessionPersistence.markerKey(serverID),
                ApplePushInstallationJournal.account(for: serverID),
            ] }
            for key in perServer + [
                SharedStorage.mirroredAccessTokenAccount,
                SharedStorage.mirroredProfileTokenAccount,
                SharedStorage.applePushDisplayTokenAccount,
                SharedStorage.applePushDisplayTargetsAccount,
            ] {
                keychain.withAudience(.userIndependent).delete(key)
                keychain.withAudience(.currentUser).delete(key)
            }
            UserDefaults().removePersistentDomain(forName: name)
        }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let tokens = TokenStore(keychain: keychain, defaults: defaults)
        await tokens.switchActiveServer(serverId: Self.serverID)
        await tokens.setServerUrl(Self.serverURL)
        let saved = await tokens.saveTokens(accessToken: "access", refreshToken: "refresh")
        XCTAssertTrue(saved)
        await tokens.setProfileId("profile-a")
        let proofStored = await tokens.setProfileToken("proof-a")
        XCTAssertTrue(proofStored)
        let captured = await tokens.captureOrdinaryRequestAuth()
        let requestOwner = try XCTUnwrap(captured)
        try await tokens.bindVerifiedAccount("12", expected: requestOwner)

        let server = PushServer()
        let http = HTTPClient(session: server.handler.makeSession(), tokenStore: tokens)
        let api = APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false })
        let targets = ApplePushDisplayTargetStore(keychain: keychain.withAudience(.currentUser))
        return Harness(tokens: tokens, server: server, journal: journal, targets: targets, http: http, api: api,
            defaults: defaults)
    }

    private static func target(profileID: String = "profile-a", token: String = "display-1",
                               serverID: String? = "deployment-a") -> ApplePushDisplayTarget {
        ApplePushDisplayTarget(serverID: serverID, profileID: profileID, registryServerID: Self.serverID,
            serverURL: Self.serverURL, displayToken: token, expiresAt: Self.tokenExpiry)
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
        // Keyed by the deployment and profile pushes will name.
        XCTAssertEqual(h.targets.targets(), [Self.target()])
    }

    /// An older server's receipt names no deployment; the registry's
    /// verified identity keys the target instead.
    func testReceiptWithoutServerIDKeysTheTargetByTheSavedServersIdentity() async throws {
        let h = try await makeHarness()
        h.server.enqueue(.receipt(serverID: nil))
        let owner = try await h.owner()

        _ = await h.registrar(savedServerIdentity: "deployment-saved").register(Self.body(), owner: owner)

        XCTAssertEqual(h.targets.targets(), [Self.target(serverID: "deployment-saved")])
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
        // The server replaced the profile's registration, and so does the device.
        XCTAssertEqual(h.targets.targets(), [Self.target(profileID: "profile-b")])
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

    func testValidationFailureIsRefusal() async throws {
        let h = try await makeHarness()
        h.server.enqueue(.problem(422, "validation_failed"))
        let owner = try await h.owner()
        let result = await h.registrar().register(Self.body(), owner: owner)
        XCTAssertEqual(result, .refused(reason: "http_422_validation_failed"))
        XCTAssertEqual(try h.record()?.latest?.outcome, .refused(reason: "http_422_validation_failed"))
    }

    /// The server answers 403 both for a bad installation proof and for a
    /// login authority check that can fail transiently. The intent stays
    /// pending and is replayed exactly once the hold ends.
    func testForbiddenHoldsIntentPendingAndReplaysItAfterBackoff() async throws {
        let h = try await makeHarness()
        let clock = Clock()
        let registrar = h.registrar(clock: clock)
        let owner = try await h.owner()
        h.server.enqueue(.problem(403, "permission_denied"))

        let first = await registrar.register(Self.body(), owner: owner)
        XCTAssertEqual(first, .held(reason: "http_403_permission_denied"))
        XCTAssertEqual(try h.record()?.latest?.outcome, .pending)
        let count = h.server.handler.requests.count

        let during = await registrar.register(Self.body(), owner: owner)
        XCTAssertEqual(during, .notSent(reason: "held"))
        XCTAssertEqual(h.server.handler.requests.count, count, "a held intent must not be resent before the hold ends")

        clock.advance(by: ApplePushRegistrar.heldGenerationRetryInterval + 1)
        let after = await registrar.register(Self.body(), owner: owner)

        XCTAssertEqual(after, Self.accepted)
        let sends = h.server.registrations
        XCTAssertEqual(sends.map { $0.header("X-Push-Generation") }, ["1", "1"])
        XCTAssertEqual(sends[0].header("X-Push-Installation-Key"), sends[1].header("X-Push-Installation-Key"))
        XCTAssertEqual(sends[0].body, sends[1].body)
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
        XCTAssertEqual(h.targets.targets(), [])
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
    /// removed, the display target is removed and the intent is not renewed
    /// again.
    func testRemovedRegistrationClearsDisplayTargetAndStopsRenewal() async throws {
        let h = try await makeHarness()
        let clock = Clock()
        let registrar = h.registrar(clock: clock)
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)
        XCTAssertEqual(h.targets.targets(), [Self.target()])
        clock.set(Self.renewalDue)
        h.server.enqueue(.receipt(removed: true, displayToken: "must-not-store"))

        let renewal = await registrar.register(Self.body(), owner: owner)

        XCTAssertEqual(renewal, .registered(ApplePushAcceptedRegistration(
            id: "registration-1", serverDeviceID: "server-device-1", enabled: true, removed: true)))
        XCTAssertEqual(h.server.registrations.map { $0.header("X-Push-Generation") }, ["1", "1"])
        XCTAssertEqual(h.targets.targets(), [])
        let count = h.server.handler.requests.count
        let after = await registrar.register(Self.body(), owner: owner)
        XCTAssertEqual(after, .unchanged)
        XCTAssertEqual(h.server.handler.requests.count, count)
    }

    /// A renewal is an exact replay the server never acts on, so its refusal
    /// leaves the accepted registration in place and the renewal is retried
    /// once the hold ends.
    func testRefusedRenewalKeepsAcceptedRegistrationAndRenewsAfterBackoff() async throws {
        let h = try await makeHarness()
        let clock = Clock()
        let registrar = h.registrar(clock: clock)
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)
        let accepted = try h.record()?.latest?.outcome
        clock.set(Self.renewalDue)
        h.server.enqueue(.problem(403, "permission_denied"))

        let renewal = await registrar.register(Self.body(), owner: owner)
        XCTAssertEqual(renewal, .held(reason: "http_403_permission_denied"))
        XCTAssertEqual(try h.record()?.latest?.outcome, accepted)
        let count = h.server.handler.requests.count

        let during = await registrar.register(Self.body(), owner: owner)
        XCTAssertEqual(during, .unchanged)
        XCTAssertEqual(h.server.handler.requests.count, count)

        clock.advance(by: ApplePushRegistrar.heldGenerationRetryInterval + 1)
        h.server.enqueue(.receipt(displayToken: "display-2"))
        let after = await registrar.register(Self.body(), owner: owner)

        XCTAssertEqual(after, Self.accepted)
        XCTAssertEqual(h.server.registrations.map { $0.header("X-Push-Generation") }, ["1", "1", "1"])
        XCTAssertEqual(h.targets.targets(), [Self.target(token: "display-2")])
    }

    /// A 409 on a renewal means the server has moved past this generation,
    /// so the accepted state is no longer true and renewal stops.
    func testConflictOnRenewalIsRecordedAsRefusal() async throws {
        let h = try await makeHarness()
        let clock = Clock()
        let registrar = h.registrar(clock: clock)
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)
        clock.set(Self.renewalDue)
        h.server.enqueue(.problem(409, "conflict"))

        let renewal = await registrar.register(Self.body(), owner: owner)

        XCTAssertEqual(renewal, .refused(reason: "http_409_conflict"))
        XCTAssertEqual(try h.record()?.latest?.outcome, .refused(reason: "http_409_conflict"))
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
        XCTAssertEqual(h.targets.targets(), [])
        XCTAssertEqual(try h.record()?.latest?.outcome, .pending)
    }

    // MARK: - Saved servers

    /// A server the person is not using keeps its display token current,
    /// and removing it turns its pushes off, each through that server's own
    /// stored session, installation key and next generation.
    func testSavedServerRenewsAndTurnsOffWithItsOwnStoredSession() async throws {
        let h = try await makeHarness()
        let clock = Clock()
        let registrar = h.registrar(clock: clock)
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)
        try await h.signInToOtherServer()
        let otherOwner = try await h.owner()
        clock.set(Self.renewalDue)
        h.server.enqueue(.receipt(displayToken: "display-2"))

        await registrar.registerSavedServers(Self.body(), among: [Self.serverID, Self.otherServerID],
                                             skipping: Self.otherServerID)

        let renewal = try XCTUnwrap(h.server.registrations.last)
        XCTAssertEqual(renewal.url?.host, "silo.example")
        XCTAssertEqual(renewal.header("Authorization"), "Bearer access")
        XCTAssertEqual(renewal.header("X-Profile-Id"), "profile-a")
        XCTAssertEqual(renewal.header("X-Profile-Token"), "proof-a")
        XCTAssertEqual(renewal.header("X-Push-Generation"), "1")
        XCTAssertEqual(renewal.body, h.server.registrations.first?.body)
        XCTAssertEqual(h.targets.targets(), [Self.target(token: "display-2")])

        let off = await registrar.unregister(serverID: Self.serverID, activeOwner: otherOwner)

        guard case .registered = off else { return XCTFail("unexpected \(off)") }
        let request = try XCTUnwrap(h.server.registrations.last)
        XCTAssertEqual(request.url?.host, "silo.example")
        XCTAssertEqual(request.header("Authorization"), "Bearer access")
        XCTAssertEqual(request.header("X-Push-Generation"), "2")
        XCTAssertEqual(request.header("X-Push-Installation-Key"), renewal.header("X-Push-Installation-Key"))
        XCTAssertTrue(request.bodyString?.contains(#""push_mode":"off""#) ?? false)
        XCTAssertEqual(h.targets.targets(), [])
    }

    /// A profile switch whose answer was lost leaves the old profile's
    /// target and a pending intent for the new profile. Once another server
    /// is active, maintenance still sends that intent again with the saved
    /// server's own session, and the target follows the answer.
    func testSavedServerMaintenanceReplaysALostProfileSwitch() async throws {
        let h = try await makeHarness()
        let registrar = h.registrar()
        let first = try await h.owner()
        _ = await registrar.register(Self.body(), owner: first)
        await h.tokens.setProfileId("profile-b")
        _ = await h.tokens.setProfileToken("proof-b")
        let switched = try await h.owner()
        h.server.enqueue(.transportFailure)
        let lost = await registrar.register(Self.body(), owner: switched)
        XCTAssertEqual(lost, .uncertain)
        XCTAssertEqual(h.targets.targets(), [Self.target()])
        try await h.signInToOtherServer()

        await registrar.registerSavedServers(Self.body(), among: [Self.serverID, Self.otherServerID],
                                             skipping: Self.otherServerID)

        let replay = try XCTUnwrap(h.server.registrations.last)
        XCTAssertEqual(replay.url?.host, "silo.example")
        XCTAssertEqual(replay.header("X-Profile-Id"), "profile-b")
        XCTAssertEqual(replay.header("X-Push-Generation"), "2")
        XCTAssertEqual(h.targets.targets(), [Self.target(profileID: "profile-b")])
    }

    /// Sign-out waits only briefly for a server to turn pushes off before
    /// deleting the credentials the request needs, so the off goes ahead of
    /// registrations already waiting for their turn, and none of those for
    /// the departing account runs afterwards to turn pushes back on.
    func testUnregisterGoesAheadOfQueuedRegistrationsAndHoldsThemBack() async throws {
        let h = try await makeHarness()
        let registrar = h.registrar()
        let owner = try await h.owner()
        let gate = StubURLProtocol.Gate()
        h.server.enqueue(.gated(gate))
        let running = Task { await registrar.register(Self.body(), owner: owner) }
        try await h.server.handler.waitForRequest(where: StubURLProtocol.method("POST", path: Self.registrationPath))
        let queued = Task { await registrar.register(Self.body(token: Self.tokenB), owner: owner) }
        try await Task.sleep(for: .milliseconds(200))
        let off = Task { await registrar.unregister(serverID: Self.serverID, activeOwner: owner) }
        try await Task.sleep(for: .milliseconds(200))

        await gate.open()
        _ = await (running.value, off.value)
        let heldBack = await queued.value

        XCTAssertEqual(heldBack, .notSent(reason: "departing"))
        let sends = h.server.registrations
        XCTAssertEqual(sends.map { $0.header("X-Push-Generation") }, ["1", "2"])
        XCTAssertEqual(sends.map { $0.bodyString?.contains(#""push_mode":"off""#) }, [false, true])
    }

    /// A sign-out or removal that fails after turning a server off leaves it
    /// saved and signed in, so its pushes come back on, and its target with
    /// them.
    func testRestoreTurnsPushesBackOnAfterATeardownThatDidNotHappen() async throws {
        let h = try await makeHarness()
        let registrar = h.registrar()
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)
        _ = await registrar.unregister(serverID: Self.serverID, activeOwner: owner)
        XCTAssertEqual(h.targets.targets(), [])

        let restored = await registrar.restore(serverID: Self.serverID)

        XCTAssertEqual(restored, Self.accepted)
        let sends = h.server.registrations
        XCTAssertEqual(sends.map { $0.header("X-Push-Generation") }, ["1", "2", "3"])
        XCTAssertEqual(sends.map { $0.bodyString?.contains(#""push_mode":"off""#) }, [false, true, false])
        XCTAssertEqual(h.targets.targets(), [Self.target()])
    }

    /// A deployment identity is self-asserted. A saved server claiming
    /// another's cannot displace that server's target, and a push naming the
    /// contested server and profile is fetched from neither.
    func testSavedServerClaimingAnothersIdentityCannotDisplaceItsTarget() async throws {
        let h = try await makeHarness()
        let registrar = h.registrar()
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)
        try await h.signInToOtherServer()
        await h.tokens.setProfileId("profile-a")
        let claimant = try await h.owner()
        h.server.enqueue(.receipt(displayToken: "display-b", serverID: "deployment-a"))

        _ = await registrar.register(Self.body(), owner: claimant)

        XCTAssertEqual(h.targets.target(registeredBy: Self.serverID), Self.target())
        let reader = ApplePushDisplayStateReader(defaults: h.defaults, keychain: h.targets.keychain)
        XCTAssertEqual(reader.route(for: [
            "silo_delivery_id": "delivery-1", "silo_server_id": "deployment-a", "silo_profile_id": "profile-a",
        ]), .ambiguousTarget)
    }

    /// Who's Watching and profile switches leave every server's target in
    /// place: the server's registration still belongs to that profile until
    /// a new one replaces it. Clearing a server's credentials takes only
    /// that server's target with them.
    func testTargetsOutliveProfileChangesAndGoWithTheirServersCredentials() async throws {
        let h = try await makeHarness()
        let other = ApplePushDisplayTarget(serverID: "deployment-b", profileID: "other-profile",
            registryServerID: Self.otherServerID, serverURL: Self.otherServerURL, displayToken: "display-b",
            expiresAt: Self.tokenExpiry)
        XCTAssertTrue(h.targets.save(Self.target()))
        XCTAssertTrue(h.targets.save(other))

        let deactivated = await h.tokens.deactivateProfile(expectedAccount: nil)
        XCTAssertTrue(deactivated)
        let identity = await h.tokens.refreshAccountIdentity()
        let account = try XCTUnwrap(identity)
        let activated = await h.tokens.activateProfile(profileID: "profile-b", profileToken: nil, expectedAccount: account)
        XCTAssertTrue(activated)
        XCTAssertEqual(h.targets.targets(), [Self.target(), other])

        await h.tokens.deleteTokens(for: Self.otherServerID)
        XCTAssertEqual(h.targets.targets(), [Self.target()])
        await h.tokens.clearTokens()
        XCTAssertEqual(h.targets.targets(), [])
    }

    /// An install updated from the single-token build keeps displaying the
    /// active server's pushes: its token becomes that server's target.
    func testLegacyDisplayTokenMovesIntoTheActiveServersTarget() throws {
        let name = "ApplePushLegacyMigration.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        addTeardownBlock {
            keychain.delete(SharedStorage.applePushDisplayTokenAccount)
            keychain.delete(SharedStorage.applePushDisplayTargetsAccount)
        }
        defaults.set(Self.serverID, forKey: SharedStorage.activeServerIdKey)
        defaults.set("profile-a", forKey: SharedStorage.profileIdKey)
        defaults.set(Self.serverID, forKey: SharedStorage.applePushDisplayTokenServerIdKey)
        defaults.set(Self.tokenExpiry, forKey: SharedStorage.applePushDisplayTokenExpiresAtKey)
        XCTAssertTrue(keychain.set("display-1", for: SharedStorage.applePushDisplayTokenAccount))
        let server = ServerEntry(id: Self.serverID, url: Self.serverURL, fetchedName: nil, lastUsedAt: Date(),
            verifiedServerId: "deployment-a")
        let store = ApplePushDisplayTargetStore(keychain: keychain)

        store.migrateLegacyToken(defaults: defaults) { $0 == server.id ? server : nil }

        XCTAssertEqual(store.targets(), [Self.target()])
        XCTAssertNil(keychain.get(SharedStorage.applePushDisplayTokenAccount))
        XCTAssertNil(defaults.string(forKey: SharedStorage.applePushDisplayTokenServerIdKey))
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
