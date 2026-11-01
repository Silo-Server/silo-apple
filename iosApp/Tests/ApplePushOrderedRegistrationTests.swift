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
    private static let thirdServerURL = "https://third.example"
    private static let thirdServerID = ServerRegistry.serverId(for: thirdServerURL)
    private static let tokenExpiry = "2099-01-01T00:00:00Z"
    /// A day before the stub's tokens expire, inside the renewal window.
    private static let renewalDue = ISO8601DateFormatter().date(from: tokenExpiry)!.addingTimeInterval(-86_400)
    private static let capabilityPath = "/api/v2/devices/push/apple/capabilities"
    private static let registrationPath = "/api/v2/devices/push/apple"
    private static let retirementPath = "/api/v2/devices/push/apple/retire"
    private static let resetPath = "/api/v2/devices/push/apple/reset"
    private static let sessionsPath = "/api/v2/auth/sessions"
    /// A capability that offers the owner reset (`installation_reset_available`).
    private static let resetCapability =
        #"{"allowed":true,"registration_available":true,"installation_reset_available":true,"revision":"r1","state":"available"}"#
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

        /// Answers to `retireApplePushInstallation`; `retired` echoes the
        /// generation it was sent.
        enum RetirementReply {
            case retired
            case status(Int)
            case problem(Int, String)
            case transportFailure
            /// Waits for the gate, then answers with the given status.
            case gated(StubURLProtocol.Gate, status: Int)
        }

        /// Answers to `resetApplePushInstallation`; with none queued the
        /// server answers 200 with `reset: true`.
        enum ResetReply {
            case reset(Bool)
            case problem(Int, String)
        }

        let handler = StubURLProtocol.Handler()
        private let lock = NSLock()
        private var resetReplies: [ResetReply] = []
        private var capability = #"{"allowed":true,"registration_available":true,"revision":"r1","state":"available"}"#
        private var replies: [Reply] = []
        private var retirementReplies: [RetirementReply] = []
        private var capabilityGate: StubURLProtocol.Gate?
        /// Per address: the caller's own login session, and the account's
        /// sessions one page at a time (`listSessions`).
        private var sessions: [String: (current: String, pages: [[String]])] = [:]
        /// Addresses whose `/api/v2/auth/refresh` answers 401.
        private var refusingRefresh: Set<String> = []

        init() {
            handler.route(StubURLProtocol.method("GET", path: ApplePushOrderedRegistrationTests.capabilityPath)) { [self] _ in
                if let gate = lock.withLock({ () -> StubURLProtocol.Gate? in
                    defer { capabilityGate = nil }
                    return capabilityGate
                }) {
                    await gate.wait()
                }
                return .json(lock.withLock { capability })
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
            handler.route(StubURLProtocol.method("POST", path: HTTPClient.refreshPath)) { [self] request in
                guard let host = request.url?.host, lock.withLock({ refusingRefresh.contains(host) }) else {
                    return .status(503)
                }
                return .json(#"{"type":"https://silo.example/problems/unauthorized","title":"t","status":401,"detail":"d"}"#,
                    status: 401, headers: ["Content-Type": "application/problem+json"])
            }
            handler.route(StubURLProtocol.method("GET", path: ApplePushOrderedRegistrationTests.sessionsPath)) { [self] request in
                guard let host = request.url?.host, let listing = lock.withLock({ sessions[host] }) else {
                    return .status(404)
                }
                let index = Int(request.query["cursor"] ?? "0") ?? 0
                let page = index < listing.pages.count ? listing.pages[index] : []
                func item(_ id: String) -> [String: Any] {
                    ["id": id, "device_name": "iPhone", "ip_address": "", "created_at": "2026-01-02T03:04:05.678Z",
                     "expires_at": "2099-01-02T03:04:05.678Z", "last_seen_at": NSNull(), "current": id == listing.current]
                }
                var pageInfo: [String: Any] = ["has_more": index + 1 < listing.pages.count]
                if index + 1 < listing.pages.count { pageInfo["next_cursor"] = String(index + 1) }
                let body: [String: Any] = ["current_session": item(listing.current), "items": page.map(item),
                                           "page": pageInfo]
                return .json(String(decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self))
            }
            handler.route(StubURLProtocol.method("POST", path: ApplePushOrderedRegistrationTests.resetPath)) { [self] _ in
                switch lock.withLock({ resetReplies.isEmpty ? ResetReply.reset(true) : resetReplies.removeFirst() }) {
                case .reset(let cleared):
                    return .json(#"{"reset":\#(cleared)}"#)
                case .problem(let status, let type):
                    return .json(#"{"type":"https://silo.example/problems/\#(type)","title":"t","status":\#(status),"detail":"d"}"#,
                        status: status, headers: ["Content-Type": "application/problem+json"])
                }
            }
            handler.route(StubURLProtocol.method("POST", path: ApplePushOrderedRegistrationTests.retirementPath)) { [self] request in
                var reply = lock.withLock { retirementReplies.isEmpty ? RetirementReply.retired : retirementReplies.removeFirst() }
                if case .gated(let gate, let status) = reply {
                    await gate.wait()
                    reply = .status(status)
                }
                switch reply {
                case .retired:
                    let generation = request.header("X-Push-Generation") ?? ""
                    return .json(#"{"generation":"\#(generation)","removed":true}"#)
                case .status(let status):
                    return .status(status)
                case .problem(let status, let type):
                    return .json(#"{"type":"https://silo.example/problems/\#(type)","title":"t","status":\#(status),"detail":"d"}"#,
                        status: status, headers: ["Content-Type": "application/problem+json"])
                case .transportFailure, .gated:
                    throw URLError(.networkConnectionLost)
                }
            }
        }

        func setCapability(_ json: String) { lock.withLock { capability = json } }
        /// Holds the next capability answer until `gate` opens.
        func gateCapability(_ gate: StubURLProtocol.Gate) { lock.withLock { capabilityGate = gate } }
        func enqueue(_ reply: Reply) { lock.withLock { replies.append(reply) } }
        func enqueueRetirement(_ reply: RetirementReply) { lock.withLock { retirementReplies.append(reply) } }
        func enqueueReset(_ reply: ResetReply) { lock.withLock { resetReplies.append(reply) } }
        /// Makes `/api/v2/auth/refresh` at `host` answer 401; otherwise 503.
        func refuseRefresh(host: String) { lock.withLock { _ = refusingRefresh.insert(host) } }
        /// What `listSessions` answers at `host`: the caller's session
        /// `current`, and `pages` of the account's session IDs.
        func setSessions(host: String, current: String, pages: [[String]]) {
            lock.withLock { sessions[host] = (current, pages) }
        }

        var resets: [StubURLProtocol.Request] {
            handler.requests.filter { $0.method == "POST" && $0.path == ApplePushOrderedRegistrationTests.resetPath }
        }

        var retirements: [StubURLProtocol.Request] {
            handler.requests.filter { $0.method == "POST" && $0.path == ApplePushOrderedRegistrationTests.retirementPath }
        }

        var registrations: [StubURLProtocol.Request] {
            handler.requests.filter { $0.method == "POST" && $0.path == ApplePushOrderedRegistrationTests.registrationPath }
        }
    }

    /// The deployment identity each saved server reports, changeable mid-test.
    private final class Identities: @unchecked Sendable {
        private let lock = NSLock()
        private var reported: [String: String] = [:]
        func set(_ identity: String, for serverID: String) { lock.withLock { reported[serverID] = identity } }
        func identity(of serverID: String) -> String? { lock.withLock { reported[serverID] } }
    }

    /// Whether the registrar's next deployment lookups wait on a gate.
    private final class Pause: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var isOn: Bool {
            get { lock.withLock { on } }
            set { lock.withLock { on = newValue } }
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
        let retirementStore: ApplePushRetirementStore
        let identities = Identities()

        /// A new registrar is a new process: only the Keychain carries over.
        func registrar(clock: Clock? = nil, savedServerIdentity: String? = nil,
                       savedServerIDs: [String] = [ApplePushOrderedRegistrationTests.serverID,
                                                   ApplePushOrderedRegistrationTests.otherServerID],
                       retirementBudget: Duration = .seconds(2),
                       beforeIdentityLookup: @escaping @Sendable () async -> Void = {}) -> ApplePushRegistrar {
            let now: @Sendable () -> Date = clock.map { clock in { clock.now } } ?? { Date() }
            let session = server.handler.makeSession()
            let retirements = ApplePushRetirementQueue(store: retirementStore, journal: journal, now: now) {
                try await APIv2Client.retireApplePushInstallation(serverURL: $0, deviceID: $1, installationKey: $2,
                    generation: $3, session: session)
            }
            return ApplePushRegistrar(api: api, tokenStore: tokens, journal: journal, displayTargets: targets,
                savedServers: ApplePushSavedServerClient(http: http, tokenStore: tokens,
                    session: session),
                savedServerIdentity: { [identities] serverID in
                    await beforeIdentityLookup()
                    return identities.identity(of: serverID) ?? savedServerIdentity
                },
                savedServerIDs: { savedServerIDs },
                retirements: retirements,
                retirementBudget: retirementBudget, now: now)
        }

        /// Signs in to the server again after its credentials were deleted:
        /// a new account epoch for the same registry id.
        func signInAgain() async throws {
            let saved = await tokens.saveTokens(accessToken: "access-2", refreshToken: "refresh-2")
            XCTAssertTrue(saved)
            await tokens.setProfileId("profile-a")
            let proofStored = await tokens.setProfileToken("proof-a")
            XCTAssertTrue(proofStored)
            let captured = await tokens.captureOrdinaryRequestAuth()
            try await tokens.bindVerifiedAccount("12", expected: XCTUnwrap(captured))
        }

        /// Signs in to the same deployment, and the same account, under a
        /// second address, which becomes the active one.
        func signInToSecondAddress(accessToken: String = "second-access") async throws {
            await tokens.switchActiveServer(serverId: ApplePushOrderedRegistrationTests.otherServerID)
            await tokens.setServerUrl(ApplePushOrderedRegistrationTests.otherServerURL)
            let saved = await tokens.saveTokens(accessToken: accessToken, refreshToken: "second-refresh")
            XCTAssertTrue(saved)
            await tokens.setProfileId("profile-a")
            let proofStored = await tokens.setProfileToken("proof-a")
            XCTAssertTrue(proofStored)
            let captured = await tokens.captureOrdinaryRequestAuth()
            try await tokens.bindVerifiedAccount("12", expected: XCTUnwrap(captured))
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
            let perServer = [Self.serverID, Self.otherServerID, Self.thirdServerID].flatMap { serverID in [
                TokenStore.accessTokenKey(for: serverID),
                TokenStore.refreshTokenKey(for: serverID),
                TokenStore.profileTokenKey(for: serverID),
                TokenStore.accountEpochKey(for: serverID),
                AccountSessionPersistence.recordKey(serverID),
                AccountSessionPersistence.markerKey(serverID),
                ApplePushInstallationJournal.account(for: serverID),
                ApplePushInstallationJournal.linkAccount(for: serverID),
            ] }
            for key in perServer + [
                SharedStorage.mirroredAccessTokenAccount,
                SharedStorage.mirroredProfileTokenAccount,
                SharedStorage.applePushDisplayTokenAccount,
                SharedStorage.applePushDisplayTargetsAccount,
                ApplePushRetirementStore.account,
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
            defaults: defaults,
            retirementStore: ApplePushRetirementStore(keychain: keychain.withAudience(.userIndependent)))
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

    // MARK: - One server under two addresses

    /// One server saved under a second address: the device ID is the same,
    /// so the server holds the first address's installation key. Once the
    /// first address lists the second address's login session, which only
    /// the backend that issued it knows, both addresses share one journal
    /// record: the second registers with the first's key at the next
    /// generation, nothing is reset, and one display target is left.
    func testProvenSecondAddressSharesTheInstallationInsteadOfResettingIt() async throws {
        let h = try await makeHarness()
        let registrar = try await joinSecondAddress(h)

        XCTAssertTrue(h.server.resets.isEmpty)
        let sends = h.server.registrations
        let key = try XCTUnwrap(sends.first?.header("X-Push-Installation-Key"))
        XCTAssertEqual(sends.map { $0.url?.host }, ["silo.example", "other.example", "other.example"])
        XCTAssertNotEqual(sends[1].header("X-Push-Installation-Key"), key)
        XCTAssertEqual(sends[2].header("X-Push-Installation-Key"), key)
        XCTAssertEqual(sends[2].header("X-Push-Generation"), "2")
        XCTAssertEqual(try h.journal.load(serverID: Self.otherServerID), try h.record())
        XCTAssertEqual(h.targets.targets().map(\.registryServerID), [Self.otherServerID])
        let reader = ApplePushDisplayStateReader(defaults: h.defaults, keychain: h.targets.keychain)
        XCTAssertEqual(reader.route(for: [
            "silo_delivery_id": "delivery-1", "silo_server_id": "deployment-a", "silo_profile_id": "profile-a",
        ]), .fetch(ApplePushDisplayAuthState(serverURL: Self.otherServerURL, profileID: "profile-a",
            accessToken: "", profileToken: "", displayToken: "display-1")))
        _ = registrar
    }


    /// A saved server that claims another's deployment identity never gets
    /// its key: unless the first address lists the claimant's own login
    /// session, and not as the first address's own, the claimant keeps its
    /// own record and resets the installation with its own key.
    func testClaimedIdentityWithoutTheSessionProofSharesNothing() async throws {
        for claimed in ["session-9", "session-1"] {
            let h = try await makeHarness()
            h.server.setCapability(Self.resetCapability)
            let registrar = h.registrar(savedServerIdentity: "deployment-a")
            _ = await registrar.register(Self.body(), owner: try await h.owner())
            let key = try XCTUnwrap(h.server.registrations.first?.header("X-Push-Installation-Key"))
            try await h.signInToSecondAddress()
            h.server.setSessions(host: "other.example", current: claimed, pages: [[claimed]])
            h.server.setSessions(host: "silo.example", current: "session-1", pages: [["session-1"]])
            h.server.enqueue(.problem(403, "push_installation_key_mismatch"))

            let result = await registrar.register(Self.body(), owner: try await h.owner())

            XCTAssertEqual(result, Self.accepted, claimed)
            XCTAssertEqual(h.server.resets.count, 1, claimed)
            let claimant = h.server.handler.requests.filter { $0.url?.host == "other.example" }
            XCTAssertFalse(claimant.contains { $0.header("X-Push-Installation-Key") == key }, claimed)
            XCTAssertNotEqual(try h.journal.load(serverID: Self.otherServerID)?.installationKey, key, claimed)
            XCTAssertEqual(try h.record()?.installationKey, key, claimed)
        }
    }

    /// After the second address took the shared installation, the first
    /// holds no registration of its own: removing it sends nothing and
    /// leaves the second address's pushes and target alone.
    func testRemovingTheAddressThatDoesNotHoldTheSharedInstallationSendsNothing() async throws {
        let h = try await makeHarness()
        let registrar = try await joinSecondAddress(h)
        let sent = h.server.handler.requests.count

        let removed = await registrar.unregister(serverID: Self.serverID, activeOwner: try await h.owner())

        XCTAssertEqual(removed, .unchanged)
        XCTAssertEqual(h.server.handler.requests.count, sent)
        XCTAssertEqual(h.targets.targets().map(\.registryServerID), [Self.otherServerID])
    }

    /// Once the address that registered last is removed, its retirement
    /// stops the shared installation, and the other address, still saved and
    /// signed in, registers it again under its own last owner with the
    /// shared key, without being the active server.
    func testSurvivingAddressTakesTheSharedInstallationBackAfterTheHolderIsRemoved() async throws {
        let h = try await makeHarness()
        let registrar = try await joinSecondAddress(h)
        let key = try XCTUnwrap(h.record()?.installationKey)
        let removed = await registrar.unregister(serverID: Self.otherServerID, activeOwner: try await h.owner())
        XCTAssertEqual(removed, .retirement(.retired))
        await h.tokens.switchActiveServer(serverId: Self.serverID)
        await h.tokens.setServerUrl(Self.serverURL)
        await h.tokens.deleteTokens(for: Self.otherServerID)

        await registrar.registerSavedServers(Self.body(), among: [Self.serverID], skipping: nil)

        let renewed = try XCTUnwrap(h.server.registrations.last)
        XCTAssertEqual(renewed.url?.host, "silo.example")
        XCTAssertEqual(renewed.header("X-Push-Installation-Key"), key)
        XCTAssertEqual(renewed.header("X-Push-Generation"), "4")
        XCTAssertEqual(h.targets.targets().map(\.registryServerID), [Self.serverID])
    }

    /// A link is keyed by the address. When that address later reports
    /// another deployment (a reassigned LAN address, a new install), it
    /// stops sharing the record and starts over with a key of its own.
    func testAddressReportingAnotherDeploymentStopsSharingTheKey() async throws {
        let h = try await makeHarness()
        let registrar = try await joinSecondAddress(h)
        let key = try XCTUnwrap(h.record()?.installationKey)
        // A copy left in the address's own slot by an interrupted link.
        let leftover = try String(decoding: JSONEncoder().encode(XCTUnwrap(h.record())), as: UTF8.self)
        XCTAssertTrue(h.journal.keychain.set(leftover, for: ApplePushInstallationJournal.account(for: Self.otherServerID)))
        h.identities.set("deployment-z", for: Self.otherServerID)
        let sent = h.server.registrations.count

        let result = await registrar.register(Self.body(token: Self.tokenB), owner: try await h.owner())

        XCTAssertEqual(result, Self.accepted)
        let after = h.server.registrations.dropFirst(sent)
        XCTAssertEqual(after.map { $0.header("X-Push-Generation") }, ["1"])
        XCTAssertFalse(after.contains { $0.header("X-Push-Installation-Key") == key })
        XCTAssertEqual(try h.record()?.installationKey, key)
    }

    /// Once the second address reports another server, its link ends, but
    /// the shared record still names it as the last to register.
    /// Removing the first address then retires the installation with its
    /// own key rather than leaving it to an address that left, and a
    /// removal that did not happen turns it back on as the first address.
    func testRemovingTheFirstAddressAfterTheSecondLeftTheServerRetiresIt() async throws {
        let h = try await makeHarness()
        let registrar = try await joinSecondAddress(h)
        let key = try XCTUnwrap(h.record()?.installationKey)
        // Nothing has run for the second address since it moved.
        h.identities.set("deployment-z", for: Self.otherServerID)

        let removed = await registrar.unregister(serverID: Self.serverID, activeOwner: try await h.owner())

        XCTAssertEqual(removed, .retirement(.retired))
        let retirement = try XCTUnwrap(h.server.retirements.last)
        XCTAssertEqual(retirement.url?.host, "silo.example")
        XCTAssertEqual(retirement.header("X-Push-Installation-Key"), key)

        let restored = await registrar.restore(serverID: Self.serverID)

        XCTAssertEqual(restored, Self.accepted)
        let registration = try XCTUnwrap(h.server.registrations.last)
        XCTAssertEqual(registration.url?.host, "silo.example")
        XCTAssertEqual(registration.header("X-Push-Installation-Key"), key)
    }

    /// When the first address later reports another server, the second
    /// keeps the shared record, its key and its display target, and goes on
    /// registering with that key; the first starts over with its own key.
    func testFirstAddressReportingAnotherDeploymentLeavesTheSharedRecordToTheSecond() async throws {
        let h = try await makeHarness()
        let registrar = try await joinSecondAddress(h)
        let shared = try XCTUnwrap(h.journal.load(serverID: Self.otherServerID))
        h.identities.set("deployment-z", for: Self.serverID)
        await h.tokens.switchActiveServer(serverId: Self.serverID)
        await h.tokens.setServerUrl(Self.serverURL)
        let sent = h.server.registrations.count

        let result = await registrar.register(Self.body(token: Self.tokenB), owner: try await h.owner())

        XCTAssertEqual(result, Self.accepted)
        let after = h.server.registrations.dropFirst(sent)
        XCTAssertEqual(after.map { $0.header("X-Push-Generation") }, ["1"])
        XCTAssertFalse(after.contains { $0.header("X-Push-Installation-Key") == shared.installationKey })
        XCTAssertEqual(try h.journal.load(serverID: Self.otherServerID), shared)
        XCTAssertTrue(h.targets.targets().map(\.registryServerID).contains(Self.otherServerID))

        await registrar.registerSavedServers(Self.body(token: Self.tokenB), among: [Self.otherServerID], skipping: nil)

        let second = try XCTUnwrap(h.server.registrations.last)
        XCTAssertEqual(second.url?.host, "other.example")
        XCTAssertEqual(second.header("X-Push-Installation-Key"), shared.installationKey)
    }

    /// A hold on the address's own record names a generation the shared
    /// record can reach with another intent, so it ends with the link: a
    /// registration after the link whose answer is lost is replayed.
    func testHoldOnTheReplacedRecordDoesNotBlockTheSharedRegistration() async throws {
        let h = try await makeHarness()
        h.server.setCapability(Self.resetCapability)
        let registrar = h.registrar(clock: Clock(), savedServerIdentity: "deployment-a")
        _ = await registrar.register(Self.body(), owner: try await h.owner())
        try await h.signInToSecondAddress()
        let second = try await h.owner()
        h.server.enqueue(.problem(403, "permission_denied"))
        _ = await registrar.register(Self.body(), owner: second)
        h.server.enqueue(.problem(403, "permission_denied"))
        let held = await registrar.register(Self.body(token: Self.tokenB), owner: second)
        XCTAssertEqual(held, .held(reason: "http_403_permission_denied"))
        h.server.setSessions(host: "other.example", current: "session-2", pages: [["session-2"]])
        h.server.setSessions(host: "silo.example", current: "session-1", pages: [["session-1", "session-2"]])
        let tokenC = String(repeating: "ef", count: 32)
        h.server.enqueue(.problem(403, "push_installation_key_mismatch"))
        h.server.enqueue(.transportFailure)
        let lost = await registrar.register(Self.body(token: tokenC), owner: second)
        XCTAssertEqual(lost, .uncertain)

        let replayed = await registrar.register(Self.body(token: tokenC), owner: second)

        XCTAssertEqual(replayed, Self.accepted)
        XCTAssertEqual(h.server.registrations.suffix(2).map { $0.header("X-Push-Generation") }, ["2", "2"])
    }

    /// The address that registered last can keep its session after its
    /// refresh is refused. With no usable credential there, the other
    /// address registers the shared installation as itself; a refresh that
    /// only failed for now does not move it.
    func testSurvivingAddressRegistersAsItselfWhenTheHolderHasNoCredential() async throws {
        let h = try await makeHarness()
        // The second address's access token lapses ten seconds after
        // sign-in, long enough to link, and its server refuses the refresh:
        // its session stays saved under the same owner, with no credential
        // to send. A refresh that fails before then keeps the token.
        func segment(_ json: String) -> String {
            Data(json.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let issued = Int(Date().timeIntervalSince1970)
        let lapsing = segment(#"{"alg":"HS256"}"#) + "." + segment(#"{"exp":\#(issued + 10),"iat":\#(issued)}"#) + ".sig"
        let registrar = try await joinSecondAddress(h, accessToken: lapsing)
        let key = try XCTUnwrap(h.record()?.installationKey)
        while !MediaAccessTokenExpiry.isExpired(lapsing, now: Date()) {
            try await Task.sleep(for: .milliseconds(200))
        }
        await h.tokens.switchActiveServer(serverId: Self.serverID)
        await h.tokens.setServerUrl(Self.serverURL)
        let sent = h.server.registrations.count

        // A refresh the server could not answer (503) leaves the
        // installation with the second address.
        await registrar.registerSavedServers(Self.body(token: Self.tokenB), among: [Self.serverID], skipping: nil)
        XCTAssertEqual(h.server.registrations.count, sent)

        h.server.refuseRefresh(host: "other.example")
        await registrar.registerSavedServers(Self.body(token: Self.tokenB), among: [Self.serverID], skipping: nil)

        let registration = try XCTUnwrap(h.server.registrations.last)
        XCTAssertEqual(registration.url?.host, "silo.example")
        XCTAssertEqual(registration.header("X-Push-Installation-Key"), key)
    }

    /// Two addresses that registered before either could prove it each hold
    /// a target, and pushes for that server fall back to generic text. The
    /// first address's next renewal is refused for the other's key; once
    /// the other address lists its session, the first shares that record,
    /// sends nothing more, and drops its target, so pushes display again.
    /// Once the other address is removed, the first registers as itself.
    func testRenewalRefusedForTheOtherAddressesKeyHandsItsTargetOver() async throws {
        let h = try await makeHarness()
        h.server.setCapability(Self.resetCapability)
        let clock = Clock()
        let registrar = h.registrar(clock: clock, savedServerIdentity: "deployment-a")
        _ = await registrar.register(Self.body(), owner: try await h.owner())
        try await h.signInToSecondAddress()
        h.server.enqueue(.problem(403, "push_installation_key_mismatch"))
        let reset = await registrar.register(Self.body(), owner: try await h.owner())
        XCTAssertEqual(reset, Self.accepted)
        XCTAssertEqual(h.targets.targets().count, 2)
        h.server.setSessions(host: "silo.example", current: "session-1", pages: [["session-1"]])
        h.server.setSessions(host: "other.example", current: "session-2", pages: [["session-2", "session-1"]])
        clock.set(Self.renewalDue)
        h.server.enqueue(.problem(403, "push_installation_key_mismatch"))
        let sent = h.server.registrations.count

        await registrar.registerSavedServers(Self.body(), among: [Self.serverID, Self.otherServerID],
                                             skipping: Self.otherServerID)

        XCTAssertEqual(h.server.registrations.count, sent + 1)
        XCTAssertEqual(h.server.resets.count, 1)
        XCTAssertEqual(try h.record(), try h.journal.load(serverID: Self.otherServerID))
        XCTAssertEqual(h.targets.targets().map(\.registryServerID), [Self.otherServerID])
        let reader = ApplePushDisplayStateReader(defaults: h.defaults, keychain: h.targets.keychain)
        XCTAssertEqual(reader.route(for: [
            "silo_delivery_id": "delivery-1", "silo_server_id": "deployment-a", "silo_profile_id": "profile-a",
        ]), .fetch(ApplePushDisplayAuthState(serverURL: Self.otherServerURL, profileID: "profile-a",
            accessToken: "", profileToken: "", displayToken: "display-1")))

        _ = await registrar.unregister(serverID: Self.otherServerID, activeOwner: try await h.owner())
        await h.tokens.switchActiveServer(serverId: Self.serverID)
        await h.tokens.setServerUrl(Self.serverURL)
        await h.tokens.deleteTokens(for: Self.otherServerID)
        await registrar.registerSavedServers(Self.body(), among: [Self.serverID], skipping: nil)

        let renewed = try XCTUnwrap(h.server.registrations.last)
        XCTAssertEqual(renewed.url?.host, "silo.example")
        XCTAssertEqual(renewed.header("X-Profile-Id"), "profile-a")
        XCTAssertEqual(h.targets.targets().map(\.registryServerID), [Self.serverID])
    }

    /// The address that registered last moves to another server. When its
    /// link ends, its display target for the old server goes with it, so
    /// the other address's registration leaves that server one target and
    /// its pushes keep their text.
    func testUnlinkingAMovedAddressDropsItsDisplayTarget() async throws {
        let h = try await makeHarness()
        let registrar = try await joinSecondAddress(h)
        XCTAssertEqual(h.targets.targets().map(\.registryServerID), [Self.otherServerID])
        // Nothing has run for the second address since it moved.
        h.identities.set("deployment-z", for: Self.otherServerID)
        await h.tokens.switchActiveServer(serverId: Self.serverID)
        await h.tokens.setServerUrl(Self.serverURL)

        await registrar.registerSavedServers(Self.body(), among: [Self.serverID], skipping: nil)

        XCTAssertEqual(h.server.registrations.last?.url?.host, "silo.example")
        XCTAssertEqual(h.targets.targets().map(\.registryServerID), [Self.serverID])
        let reader = ApplePushDisplayStateReader(defaults: h.defaults, keychain: h.targets.keychain)
        XCTAssertNotEqual(reader.route(for: [
            "silo_delivery_id": "delivery-1", "silo_server_id": "deployment-a", "silo_profile_id": "profile-a",
        ]), .ambiguousTarget)
    }

    /// A saved address whose link was proven for another deployment does
    /// not lend that record: a third address on the deployment it reaches
    /// now, even one that address's session list vouches for, never gets
    /// the old deployment's key and resets with its own.
    func testAddressWithAStaleLinkLendsNoRecord() async throws {
        let h = try await makeHarness()
        let first = try await joinSecondAddress(h)
        let key = try XCTUnwrap(h.record()?.installationKey)
        _ = first
        // The second address now reaches another server, and nothing has
        // run for it since; the third address reaches that server too.
        h.identities.set("deployment-b", for: Self.otherServerID)
        h.identities.set("deployment-b", for: Self.thirdServerID)
        await h.tokens.switchActiveServer(serverId: Self.thirdServerID)
        await h.tokens.setServerUrl(Self.thirdServerURL)
        let saved = await h.tokens.saveTokens(accessToken: "third-access", refreshToken: "third-refresh")
        XCTAssertTrue(saved)
        await h.tokens.setProfileId("profile-a")
        let proofStored = await h.tokens.setProfileToken("proof-a")
        XCTAssertTrue(proofStored)
        let captured = await h.tokens.captureOrdinaryRequestAuth()
        try await h.tokens.bindVerifiedAccount("12", expected: XCTUnwrap(captured))
        h.server.setSessions(host: "third.example", current: "session-3", pages: [["session-3"]])
        h.server.setSessions(host: "other.example", current: "session-2", pages: [["session-2", "session-3"]])
        h.server.enqueue(.problem(403, "push_installation_key_mismatch"))
        let registrar = h.registrar(savedServerIdentity: "deployment-a",
            savedServerIDs: [Self.serverID, Self.otherServerID, Self.thirdServerID])

        let result = await registrar.register(Self.body(), owner: try await h.owner())

        XCTAssertEqual(result, Self.accepted)
        let third = h.server.handler.requests.filter { $0.url?.host == "third.example" }
        XCTAssertFalse(third.contains { $0.header("X-Push-Installation-Key") == key })
        XCTAssertEqual(h.server.resets.count, 1)
        XCTAssertNotEqual(try h.journal.load(serverID: Self.thirdServerID)?.installationKey, key)
    }

    /// A `restore` that runs while `unregister` is still looking up the
    /// address's deployment wins: the older teardown sends nothing, and the
    /// account still saved there keeps its pushes.
    func testRestoreWhileTheTeardownLooksUpTheAddressWins() async throws {
        let h = try await makeHarness()
        let gate = StubURLProtocol.Gate()
        let pause = Pause()
        let registrar = h.registrar(savedServerIdentity: "deployment-a", beforeIdentityLookup: {
            if pause.isOn { await gate.wait() }
        })
        let owner = try await h.owner()
        let registered = await registrar.register(Self.body(), owner: owner)
        XCTAssertEqual(registered, Self.accepted)
        let sent = h.server.handler.requests.count
        pause.isOn = true
        let removal = Task { await registrar.unregister(serverID: Self.serverID, activeOwner: owner) }
        while await gate.waiterCount == 0 { await Task.yield() }
        pause.isOn = false

        _ = await registrar.restore(serverID: Self.serverID)
        await gate.open()
        _ = await removal.value

        XCTAssertTrue(h.server.retirements.isEmpty)
        XCTAssertFalse(h.server.handler.requests.dropFirst(sent).contains { Self.pushMode(of: $0) == "off" })
        let changed = await registrar.register(Self.body(token: Self.tokenB), owner: owner)
        XCTAssertEqual(changed, Self.accepted)
    }

    /// The other address registers the shared installation while the
    /// holder's removal waits on its retirement. That registration ends the
    /// removal's teardown: no `off` follows it with the shared key, so the
    /// address still saved keeps its pushes.
    func testRegistrationFromTheOtherAddressEndsTheHoldersTeardown() async throws {
        let h = try await makeHarness()
        let registrar = try await joinSecondAddress(h)
        let firstOwner = try XCTUnwrap(h.record()?.owners?[Self.serverID])
        let holder = try await h.owner()
        let gate = StubURLProtocol.Gate()
        h.server.enqueueRetirement(.gated(gate, status: 503))
        let sent = h.server.handler.requests.count
        let removal = Task { await registrar.unregister(serverID: Self.otherServerID, activeOwner: holder) }
        while h.server.retirements.isEmpty { await Task.yield() }

        let taken = await registrar.register(Self.body(token: Self.tokenB), savedServer: firstOwner)
        await gate.open()
        _ = await removal.value

        XCTAssertEqual(taken, Self.accepted)
        XCTAssertFalse(h.server.handler.requests.dropFirst(sent).contains { Self.pushMode(of: $0) == "off" })
    }

    /// A registration planned from the shared record waits on the server
    /// while its address moves to another server and another pass ends the
    /// link. It then neither copies the shared record into the address's own
    /// slot nor sends the shared key there.
    func testRegistrationPlannedBeforeTheLinkEndedDoesNotKeepTheSharedKey() async throws {
        let h = try await makeHarness()
        let registrar = try await joinSecondAddress(h)
        let key = try XCTUnwrap(h.record()?.installationKey)
        let second = try await h.owner()
        let gate = StubURLProtocol.Gate()
        h.server.gateCapability(gate)
        let pending = Task { await registrar.register(Self.body(token: Self.tokenB), owner: second) }
        while await gate.waiterCount == 0 { await Task.yield() }
        let sent = h.server.registrations.count
        h.identities.set("deployment-z", for: Self.otherServerID)
        let maintenance = Task {
            await registrar.registerSavedServers(Self.body(), among: [Self.serverID], skipping: nil)
        }
        while try h.journal.recordSlot(for: Self.otherServerID) != Self.otherServerID { await Task.yield() }

        await gate.open()
        let result = await pending.value
        await maintenance.value

        XCTAssertNotEqual(result, Self.accepted)
        let moved = h.server.registrations.dropFirst(sent).filter { $0.url?.host == "other.example" }
        XCTAssertFalse(moved.contains { $0.header("X-Push-Installation-Key") == key })
        XCTAssertNotEqual(try h.journal.load(serverID: Self.otherServerID)?.installationKey, key)
        XCTAssertEqual(try h.record()?.installationKey, key)
    }

    private static func pushMode(of request: StubURLProtocol.Request) -> String? {
        guard request.method == "POST", request.path == registrationPath,
              let sent = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any] else {
            return nil
        }
        return sent["push_mode"] as? String
    }

    /// Registers the first address, signs in to the second, and registers it
    /// through a key mismatch the first address's session list resolves. The
    /// second address's session is on the first address's second page.
    private func joinSecondAddress(_ h: Harness, accessToken: String = "second-access") async throws
        -> ApplePushRegistrar {
        h.server.setCapability(Self.resetCapability)
        let registrar = h.registrar(savedServerIdentity: "deployment-a")
        let first = try await h.owner()
        _ = await registrar.register(Self.body(), owner: first)
        try await h.signInToSecondAddress(accessToken: accessToken)
        let second = try await h.owner()
        h.server.setSessions(host: "other.example", current: "session-2", pages: [["session-2"]])
        h.server.setSessions(host: "silo.example", current: "session-1", pages: [["session-1"], ["session-2"]])
        h.server.enqueue(.problem(403, "push_installation_key_mismatch"))

        let result = await registrar.register(Self.body(), owner: second)

        XCTAssertEqual(result, Self.accepted)
        return registrar
    }

    // MARK: - Lost installation key

    /// A reinstall keeps the device ID but loses the journal, so the server
    /// refuses the new key. Its owner resets the installation with the
    /// current key and registers again above the generation it had reached,
    /// so nothing it sent before the reset can outrank the new registration.
    func testKeyMismatchResetsTheInstallationAndRegistersAgainAboveItsGeneration() async throws {
        let h = try await makeHarness()
        h.server.setCapability(Self.resetCapability)
        let key = try XCTUnwrap(ApplePushInstallationJournal.randomInstallationKey())
        try h.journal.save(ApplePushInstallationRecord(installationKey: key, generation: 5, latest: nil),
                           serverID: Self.serverID)
        h.server.enqueue(.problem(403, "push_installation_key_mismatch"))
        let owner = try await h.owner()

        let result = await h.registrar().register(Self.body(), owner: owner)

        XCTAssertEqual(result, Self.accepted)
        XCTAssertEqual(h.server.handler.requests.map(\.path),
                       [Self.capabilityPath, Self.registrationPath, Self.resetPath, Self.registrationPath])
        let reset = try XCTUnwrap(h.server.resets.first)
        XCTAssertEqual(reset.header("X-Push-Installation-Key"), key)
        XCTAssertNil(reset.header("X-Push-Generation"))
        XCTAssertEqual(reset.header("X-Profile-Id"), "profile-a")
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(reset.body)) as? [String: String])
        XCTAssertEqual(sent, ["device_id": "device-1"])
        let sends = h.server.registrations
        XCTAssertEqual(sends.map { $0.header("X-Push-Generation") }, ["6", "7"])
        XCTAssertEqual(sends.map { $0.header("X-Push-Installation-Key") }, [key, key])
        XCTAssertEqual(try h.record()?.generation, 7)
        XCTAssertEqual(h.targets.targets(), [Self.target()])
    }

    /// Without the server's reset, or for a refusal the reset cannot cure,
    /// a 403 keeps today's behaviour: the intent is held, nothing is reset.
    func testForbiddenWithoutAResetToTryHoldsTheIntent() async throws {
        let noField = #"{"allowed":true,"registration_available":true,"revision":"r1","state":"available"}"#
        let notOffered =
            #"{"allowed":true,"registration_available":true,"installation_reset_available":false,"revision":"r1","state":"available"}"#
        let cases: [(capability: String, problem: String)] = [
            (noField, "push_installation_key_mismatch"),
            (notOffered, "push_installation_key_mismatch"),
            (Self.resetCapability, "permission_denied"),
        ]
        for (capability, problem) in cases {
            let h = try await makeHarness()
            h.server.setCapability(capability)
            h.server.enqueue(.problem(403, problem))
            let owner = try await h.owner()

            let result = await h.registrar().register(Self.body(), owner: owner)

            XCTAssertEqual(result, .held(reason: "http_403_\(problem)"), problem)
            XCTAssertTrue(h.server.resets.isEmpty, problem)
            XCTAssertEqual(h.server.registrations.count, 1, problem)
            XCTAssertEqual(try h.record()?.latest?.outcome, .pending, problem)
        }
    }

    /// `reset: false` means the server held nothing to clear; the
    /// registration after it binds the key all the same.
    func testResetThatClearedNothingStillRegistersAgain() async throws {
        let h = try await makeHarness()
        h.server.setCapability(Self.resetCapability)
        let key = try XCTUnwrap(ApplePushInstallationJournal.randomInstallationKey())
        try h.journal.save(ApplePushInstallationRecord(installationKey: key, generation: 5, latest: nil),
                           serverID: Self.serverID)
        h.server.enqueue(.problem(403, "push_installation_key_mismatch"))
        h.server.enqueueReset(.reset(false))
        let owner = try await h.owner()

        let result = await h.registrar().register(Self.body(), owner: owner)

        XCTAssertEqual(result, Self.accepted)
        XCTAssertEqual(h.server.registrations.map { $0.header("X-Push-Generation") }, ["6", "7"])
    }

    /// One reset per attempt: a registration refused again after the reset,
    /// or a refused reset, holds the generation like any 403, so the two can
    /// never loop. A reset with no answer is tried again on the next attempt.
    func testMismatchIsResetAtMostOncePerAttempt() async throws {
        let h = try await makeHarness()
        h.server.setCapability(Self.resetCapability)
        h.server.enqueue(.problem(403, "push_installation_key_mismatch"))
        h.server.enqueue(.problem(403, "push_installation_key_mismatch"))
        let clock = Clock()
        let registrar = h.registrar(clock: clock)
        let owner = try await h.owner()

        let result = await registrar.register(Self.body(), owner: owner)

        XCTAssertEqual(result, .held(reason: "http_403_push_installation_key_mismatch"))
        XCTAssertEqual(h.server.resets.count, 1)
        XCTAssertEqual(h.server.registrations.map { $0.header("X-Push-Generation") }, ["1", "2"])
        let held = await registrar.register(Self.body(), owner: owner)
        XCTAssertEqual(held, .notSent(reason: "held"))

        // A reset with no answer keeps the intent pending, unheld.
        clock.advance(by: ApplePushRegistrar.heldGenerationRetryInterval + 1)
        h.server.enqueue(.problem(403, "push_installation_key_mismatch"))
        h.server.enqueueReset(.problem(503, "service_unavailable"))
        let unanswered = await registrar.register(Self.body(), owner: owner)
        XCTAssertEqual(unanswered, .uncertain)
        XCTAssertEqual(try h.record()?.latest?.outcome, .pending)

        // A refused reset holds the generation that was refused.
        h.server.enqueue(.problem(403, "push_installation_key_mismatch"))
        h.server.enqueueReset(.problem(403, "permission_denied"))
        let refused = await registrar.register(Self.body(), owner: owner)
        XCTAssertEqual(refused, .held(reason: "http_403_push_installation_key_mismatch"))
        XCTAssertEqual(h.server.resets.count, 3)
        XCTAssertEqual(h.server.registrations.count, 4)
        XCTAssertEqual(try h.record()?.generation, 2)
        let afterRefusal = await registrar.register(Self.body(), owner: owner)
        XCTAssertEqual(afterRefusal, .notSent(reason: "held"))
    }

    /// A hold left by an earlier refused reset sits below the generation
    /// registered after a later reset, so it does not block that
    /// registration's replay when its answer is lost.
    func testHoldFromAnEarlierRefusedResetDoesNotBlockTheRegistrationAfterAReset() async throws {
        let h = try await makeHarness()
        h.server.setCapability(Self.resetCapability)
        let registrar = h.registrar(clock: Clock())
        let owner = try await h.owner()

        h.server.enqueue(.problem(403, "push_installation_key_mismatch"))
        h.server.enqueueReset(.problem(403, "permission_denied"))
        let refused = await registrar.register(Self.body(), owner: owner)
        XCTAssertEqual(refused, .held(reason: "http_403_push_installation_key_mismatch"))

        // A new token allocates generation 2; the reset succeeds and the
        // registration at generation 3 gets no answer.
        h.server.enqueue(.problem(403, "push_installation_key_mismatch"))
        h.server.enqueue(.transportFailure)
        let unanswered = await registrar.register(Self.body(token: Self.tokenB), owner: owner)
        XCTAssertEqual(unanswered, .uncertain)
        XCTAssertEqual(try h.record()?.generation, 3)

        let replayed = await registrar.register(Self.body(token: Self.tokenB), owner: owner)
        XCTAssertEqual(replayed, Self.accepted)
        XCTAssertEqual(h.server.registrations.map { $0.header("X-Push-Generation") }, ["1", "2", "3", "3"])
    }

    /// A teardown's `off` never takes the installation back. When one
    /// server is saved under two addresses and the older one is removed,
    /// its mismatch means the other address owns the installation; a reset
    /// there would turn that address's pushes off.
    func testTeardownOffOnAKeyMismatchIsHeldWithoutAReset() async throws {
        let h = try await makeHarness()
        h.server.setCapability(Self.resetCapability)
        let registrar = h.registrar()
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)
        h.server.enqueueRetirement(.status(503))
        h.server.enqueue(.problem(403, "push_installation_key_mismatch"))

        let result = await registrar.unregister(serverID: Self.serverID, activeOwner: owner)

        XCTAssertEqual(result, .held(reason: "http_403_push_installation_key_mismatch"))
        XCTAssertTrue(h.server.resets.isEmpty)
        XCTAssertEqual(h.server.registrations.map { $0.header("X-Push-Generation") }, ["1", "3"])
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

    /// A server the person is not using keeps its display token current
    /// through that server's own stored session. Removing it, when the
    /// server predates the retirement endpoint, turns its pushes off the same
    /// way, with the same installation key, above the generation the refused
    /// retirement took.
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
        h.server.enqueueRetirement(.status(404))

        let off = await registrar.unregister(serverID: Self.serverID, activeOwner: otherOwner)

        guard case .registered = off else { return XCTFail("unexpected \(off)") }
        XCTAssertEqual(h.server.retirements.map { $0.header("X-Push-Generation") }, ["2"])
        let request = try XCTUnwrap(h.server.registrations.last)
        XCTAssertEqual(request.url?.host, "silo.example")
        XCTAssertEqual(request.header("Authorization"), "Bearer access")
        XCTAssertEqual(request.header("X-Push-Generation"), "3")
        XCTAssertEqual(request.header("X-Push-Installation-Key"), renewal.header("X-Push-Installation-Key"))
        XCTAssertTrue(request.bodyString?.contains(#""push_mode":"off""#) ?? false)
        XCTAssertEqual(h.targets.targets(), [])
        // The server took the `off`; nothing is left to retire.
        let pending = try h.retirementStore.load()
        XCTAssertEqual(pending, [])
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

    /// Sign-out waits only briefly for a server to stop pushing before
    /// deleting the credentials, so the retirement takes its generation ahead
    /// of registrations already waiting for their turn, and none of those
    /// for the departing account runs afterwards to turn pushes back on.
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
        XCTAssertEqual(h.server.registrations.map { $0.header("X-Push-Generation") }, ["1"])
        XCTAssertEqual(h.server.retirements.map { $0.header("X-Push-Generation") }, ["2"])
    }

    /// A sign-out or removal that fails after retiring a server leaves it
    /// saved and signed in, so its pushes come back on above the retired
    /// generation, and a retirement still pending is dropped rather than
    /// sent later.
    func testRestoreTurnsPushesBackOnAfterATeardownThatDidNotHappen() async throws {
        let h = try await makeHarness()
        let registrar = h.registrar()
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)
        h.server.enqueueRetirement(.transportFailure)
        h.server.enqueue(.transportFailure)
        let retired = await registrar.unregister(serverID: Self.serverID, activeOwner: owner)
        XCTAssertEqual(retired, .uncertain)

        let restored = await registrar.restore(serverID: Self.serverID)

        XCTAssertEqual(restored, Self.accepted)
        let sends = h.server.registrations
        XCTAssertEqual(sends.map { $0.header("X-Push-Generation") }, ["1", "3", "5"])
        XCTAssertEqual(sends.map { $0.bodyString?.contains(#""push_mode":"off""#) }, [false, true, false])
        XCTAssertEqual(sends[0].body, sends[2].body)
        XCTAssertEqual(h.targets.targets(), [Self.target()])
        await registrar.retirements.retryDue(afterPush: true)
        XCTAssertEqual(h.server.retirements.count, 1)
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

    // MARK: - Retirement

    /// Removing a server retires this installation there with the journal's
    /// next generation and key and no session, so it still works once the
    /// credentials are gone.
    func testRemovalRetiresTheInstallationWithoutASession() async throws {
        let h = try await makeHarness()
        let registrar = h.registrar()
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)

        let result = await registrar.unregister(serverID: Self.serverID, activeOwner: owner)

        XCTAssertEqual(result, .retirement(.retired))
        let retirement = try XCTUnwrap(h.server.retirements.first)
        XCTAssertEqual(h.server.retirements.count, 1)
        XCTAssertEqual(retirement.url?.host, "silo.example")
        XCTAssertEqual(retirement.header("X-Push-Generation"), "2")
        XCTAssertEqual(retirement.header("X-Push-Installation-Key"), try h.record()?.installationKey)
        XCTAssertNil(retirement.header("Authorization"))
        XCTAssertNil(retirement.header("X-Profile-Id"))
        XCTAssertNil(retirement.header("X-Profile-Token"))
        let sent = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(retirement.body)) as? [String: String])
        XCTAssertEqual(sent, ["device_id": "device-1"])
        // Nothing went through a session after the first registration.
        XCTAssertEqual(h.server.registrations.count, 1)
        let pending = try h.retirementStore.load()
        XCTAssertEqual(pending, [])
    }

    /// An unanswered retirement stays queued with its generation and is sent
    /// again, byte for byte, by a later process after the credentials are
    /// gone, once its back-off has passed.
    func testUnansweredRetirementIsSentAgainWithTheSameGeneration() async throws {
        let h = try await makeHarness()
        let clock = Clock()
        let registrar = h.registrar(clock: clock)
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)
        h.server.enqueueRetirement(.transportFailure)
        h.server.enqueue(.transportFailure)
        let first = await registrar.unregister(serverID: Self.serverID, activeOwner: owner)
        XCTAssertEqual(first, .uncertain)
        await h.tokens.deleteTokens(for: Self.serverID)
        let queued = try h.retirementStore.load()
        XCTAssertEqual(queued.map(\.generation), [4])

        h.server.enqueueRetirement(.transportFailure)
        await registrar.retirements.retryDue()
        await registrar.retirements.retryDue()
        XCTAssertEqual(h.server.retirements.count, 2, "a retry inside the back-off sends nothing")

        let relaunched = h.registrar(clock: clock)
        await relaunched.retirements.retryDue()

        let sends = h.server.retirements
        XCTAssertEqual(sends.count, 3)
        XCTAssertEqual(sends.map { $0.header("X-Push-Generation") }, ["2", "4", "4"])
        XCTAssertEqual(sends[1].header("X-Push-Installation-Key"), sends[2].header("X-Push-Installation-Key"))
        XCTAssertEqual(sends[1].body, sends[2].body)
        let pending = try h.retirementStore.load()
        XCTAssertEqual(pending, [])
    }

    /// 200, 403 (the key no longer matches) and 409 (the server holds a
    /// newer registration) each settle the retirement for good; a server
    /// error does not.
    func testOnlyAFinalAnswerDropsTheRetirement() async throws {
        let cases: [(PushServer.RetirementReply, ApplePushRetirementQueue.Outcome?)] = [
            (.retired, .retired),
            (.problem(403, "forbidden"), .dropped(reason: "http_403_forbidden")),
            (.problem(409, "conflict"), .dropped(reason: "http_409_conflict")),
            (.status(503), nil),
        ]
        for (reply, expected) in cases {
            let h = try await makeHarness()
            let registrar = h.registrar()
            let owner = try await h.owner()
            _ = await registrar.register(Self.body(), owner: owner)
            h.server.enqueueRetirement(reply)
            h.server.enqueue(.transportFailure)

            let result = await registrar.unregister(serverID: Self.serverID, activeOwner: owner)

            let pending = try h.retirementStore.load()
            if let expected {
                XCTAssertEqual(result, .retirement(expected))
                XCTAssertEqual(pending, [], "\(reply)")
            } else {
                // Unanswered: the session `off` is tried too, and when it is
                // lost as well, a retirement above it stays queued.
                XCTAssertEqual(result, .uncertain)
                XCTAssertEqual(pending.map(\.generation), [4], "\(reply)")
            }
        }
    }

    /// A server without the endpoint is turned off with its session. When
    /// that answer is lost too, a retirement above the `off`'s generation
    /// waits for the server to be updated, counted from the first queueing,
    /// and is given up 30 days on.
    func testRetirementOnAServerWithoutTheEndpointIsGivenUpAfterThirtyDays() async throws {
        let h = try await makeHarness()
        let clock = Clock()
        let registrar = h.registrar(clock: clock)
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)
        h.server.enqueueRetirement(.status(404))
        h.server.enqueue(.transportFailure)

        let result = await registrar.unregister(serverID: Self.serverID, activeOwner: owner)

        XCTAssertEqual(result, .uncertain)
        XCTAssertEqual(h.server.registrations.map { $0.header("X-Push-Generation") }, ["1", "3"])
        var pending = try h.retirementStore.load()
        XCTAssertEqual(pending.map(\.generation), [4])
        XCTAssertEqual(pending.first?.queuedAt, clock.now)

        clock.advance(by: 29 * 24 * 60 * 60)
        h.server.enqueueRetirement(.status(405))
        await registrar.retirements.retryDue()
        pending = try h.retirementStore.load()
        XCTAssertEqual(pending.map(\.generation), [4])

        clock.advance(by: 2 * 24 * 60 * 60)
        h.server.enqueueRetirement(.status(404))
        await registrar.retirements.retryDue()
        pending = try h.retirementStore.load()
        XCTAssertEqual(pending, [])
        XCTAssertEqual(h.server.retirements.map { $0.header("X-Push-Generation") }, ["2", "4", "4"])
    }

    /// Adding the server again and signing in registers above the retired
    /// generation, never replaying the old intent at it, and the stale
    /// retirement is not sent again.
    func testReaddingTheServerDropsItsRetirementAndRegistersAboveIt() async throws {
        let h = try await makeHarness()
        let registrar = h.registrar()
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)
        h.server.enqueueRetirement(.transportFailure)
        h.server.enqueue(.transportFailure)
        _ = await registrar.unregister(serverID: Self.serverID, activeOwner: owner)
        await h.tokens.deleteTokens(for: Self.serverID)
        try await h.signInAgain()

        let result = await registrar.register(Self.body(), owner: try await h.owner())

        XCTAssertEqual(result, Self.accepted)
        let sends = h.server.registrations
        XCTAssertEqual(sends.map { $0.header("X-Push-Generation") }, ["1", "3", "5"])
        XCTAssertEqual(sends[0].body, sends[2].body)
        let pending = try h.retirementStore.load()
        XCTAssertEqual(pending, [])
        await registrar.retirements.retryDue(afterPush: true)
        XCTAssertEqual(h.server.retirements.count, 1)
    }

    /// A refused sign-out whose `restore` could not register leaves the
    /// journal retired with nothing queued. The next sign-out retires the
    /// installation again at the same generation instead of sending nothing.
    func testSignOutAfterAFailedRestoreRetiresAgain() async throws {
        let h = try await makeHarness()
        let registrar = h.registrar()
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)
        h.server.enqueueRetirement(.transportFailure)
        h.server.enqueue(.transportFailure)
        _ = await registrar.unregister(serverID: Self.serverID, activeOwner: owner)
        h.server.setCapability(#"{"allowed":true,"registration_available":false,"revision":"r2","state":"not_configured"}"#)
        let restored = await registrar.restore(serverID: Self.serverID)
        XCTAssertEqual(restored, .unavailable)
        XCTAssertEqual(try h.retirementStore.load(), [])

        let result = await registrar.unregister(serverID: Self.serverID, activeOwner: owner)

        XCTAssertEqual(result, .retirement(.retired))
        XCTAssertEqual(h.server.retirements.map { $0.header("X-Push-Generation") }, ["2", "4"])
        XCTAssertEqual(try h.retirementStore.load(), [])
    }

    /// The same, on a server without the endpoint: the next sign-out still
    /// has its session, so it turns pushes off rather than only queueing a
    /// retirement the server cannot answer.
    func testSignOutAfterAFailedRestoreTurnsOffAServerWithoutTheEndpoint() async throws {
        let h = try await makeHarness()
        let registrar = h.registrar()
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)
        h.server.enqueueRetirement(.status(404))
        h.server.enqueue(.transportFailure)
        _ = await registrar.unregister(serverID: Self.serverID, activeOwner: owner)
        h.server.setCapability(#"{"allowed":true,"registration_available":false,"revision":"r2","state":"not_configured"}"#)
        _ = await registrar.restore(serverID: Self.serverID)
        XCTAssertEqual(try h.retirementStore.load(), [])
        h.server.setCapability(#"{"allowed":true,"registration_available":true,"revision":"r3","state":"available"}"#)
        h.server.enqueueRetirement(.status(404))

        _ = await registrar.unregister(serverID: Self.serverID, activeOwner: owner)

        let sends = h.server.registrations
        XCTAssertEqual(sends.map { $0.header("X-Push-Generation") }, ["1", "3", "5"])
        XCTAssertEqual(sends.last?.bodyString?.contains(#""push_mode":"off""#), true)
        XCTAssertEqual(try h.retirementStore.load(), [])
    }

    /// A registration the departing account started before the sign-out,
    /// and that allocates only once the sign-out is waiting for its turn, is
    /// retired above rather than ending the teardown.
    func testRegistrationAlreadyRunningAtSignOutIsRetiredAbove() async throws {
        let h = try await makeHarness()
        let registrar = h.registrar()
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)
        let gate = StubURLProtocol.Gate()
        h.server.gateCapability(gate)
        let running = Task { await registrar.register(Self.body(token: Self.tokenB), owner: owner) }
        let capabilityChecks = { h.server.handler.requests.filter { $0.path == Self.capabilityPath }.count }
        let deadline = ContinuousClock.now + .seconds(5)
        while capabilityChecks() < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(capabilityChecks(), 2)
        let teardown = Task { await registrar.unregister(serverID: Self.serverID, activeOwner: owner) }
        try await Task.sleep(for: .milliseconds(200))

        await gate.open()
        _ = await running.value
        let result = await teardown.value

        XCTAssertEqual(result, .retirement(.retired))
        XCTAssertEqual(h.server.registrations.map { $0.header("X-Push-Generation") }, ["1", "2"])
        XCTAssertEqual(h.server.retirements.map { $0.header("X-Push-Generation") }, ["3"])
    }

    /// A retirement that does not answer in time does not hold up the
    /// session `off`, which has to land before the credentials are deleted.
    func testSlowRetirementDoesNotHoldUpTheOff() async throws {
        let h = try await makeHarness()
        let registrar = h.registrar(retirementBudget: .milliseconds(100))
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)
        let gate = StubURLProtocol.Gate()
        h.server.enqueueRetirement(.gated(gate, status: 503))
        let teardown = Task { await registrar.unregister(serverID: Self.serverID, activeOwner: owner) }
        try await Task.sleep(for: .milliseconds(800))

        let sends = h.server.registrations
        await gate.open()
        _ = await teardown.value
        XCTAssertEqual(sends.map { $0.header("X-Push-Generation") }, ["1", "3"])
        XCTAssertEqual(sends.last?.bodyString?.contains(#""push_mode":"off""#), true)
        XCTAssertEqual(try h.retirementStore.load(), [])
    }

    /// A retirement answered only after the sign-out gave up waiting and
    /// `restore` turned pushes back on must not then turn them off or queue
    /// another retirement.
    func testLateRetirementAnswerAfterRestoreLeavesPushesOn() async throws {
        let h = try await makeHarness()
        let registrar = h.registrar()
        let owner = try await h.owner()
        _ = await registrar.register(Self.body(), owner: owner)
        let gate = StubURLProtocol.Gate()
        h.server.enqueueRetirement(.gated(gate, status: 404))
        let teardown = Task { await registrar.unregister(serverID: Self.serverID, activeOwner: owner) }
        try await h.server.handler.waitForRequest(where: StubURLProtocol.method("POST", path: Self.retirementPath))

        let restored = await registrar.restore(serverID: Self.serverID)
        XCTAssertEqual(restored, Self.accepted)
        await gate.open()
        _ = await teardown.value

        let sends = h.server.registrations
        XCTAssertEqual(sends.map { $0.header("X-Push-Generation") }, ["1", "3"])
        XCTAssertEqual(sends.map { $0.bodyString?.contains(#""push_mode":"off""#) }, [false, false])
        XCTAssertEqual(try h.retirementStore.load(), [])
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
