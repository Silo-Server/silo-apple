import XCTest
@testable import Silo

/// State-machine tests for both pairing coordinators, driven through the
/// `PairingChannel` / `PairingDeviceAuthorizing` seams with scripted fakes —
/// no sockets, no servers. Each test guards a specific flow bug: the deaf
/// confirm pause, the consent gate, the clobbered failure screen, match-code
/// binding for auto-approved servers, and end-of-stream summaries.

// MARK: - Fakes

@MainActor
private final class FakePairingChannel: PairingChannel {
    private(set) var sent: [PairingMessage] = []
    private(set) var closeCount = 0
    var sendError: Error?

    let stream: AsyncThrowingStream<PairingMessage, Error>
    private let feed: AsyncThrowingStream<PairingMessage, Error>.Continuation

    init() {
        (stream, feed) = AsyncThrowingStream.makeStream()
    }

    func send(_ message: PairingMessage) async throws {
        if let sendError { throw sendError }
        sent.append(message)
    }

    func queue(_ message: PairingMessage) async {
        sent.append(message)
    }

    func close() async {
        closeCount += 1
        feed.finish()
    }

    func closeGracefully(goodbye: PairingMessage) async {
        sent.append(goodbye)
        closeCount += 1
        feed.finish()
    }

    // Test-side controls
    func deliver(_ message: PairingMessage) { feed.yield(message) }
    func dropConnection() { feed.finish() }

    var lastSent: PairingMessage? { sent.last }
}

private final class FakePairingAPI: PairingDeviceAuthorizing, @unchecked Sendable {
    // All mutation happens on the main actor (the coordinators are
    // @MainActor and their child tasks inherit it), hence @unchecked.
    var lookupMatchCode: String? = "ABCD"
    var lookupError: Error?
    var approveError: Error?
    var startError: Error?
    var pollResponse: APIv2DevicePoll?
    var pollResults: [Result<APIv2DevicePoll, Error>] = []

    private(set) var startedServers: [String] = []
    private(set) var approvedCodes: [String] = []
    private(set) var pollCount = 0

    func start(serverURL: String, deviceName: String, devicePlatform: String) async throws -> DeviceLoginStartResponse {
        if let startError { throw startError }
        startedServers.append(serverURL)
        return DeviceLoginStartResponse(
            deviceCode: "DEV-1",
            userCode: "USER-1",
            matchCode: "ABCD",
            verificationUri: "https://server/activate",
            verificationUriComplete: "https://server/activate?token=USER-1",
            expiresAt: Date().addingTimeInterval(300),
            expiresIn: 300,
            interval: 1,
            deviceName: deviceName,
            devicePlatform: devicePlatform
        )
    }

    func poll(serverURL: String, deviceCode: String) async throws -> APIv2DevicePoll {
        pollCount += 1
        if !pollResults.isEmpty {
            return try pollResults.removeFirst().get()
        }
        if let pollResponse { return pollResponse }
        throw APIv2Error.httpStatus(500)
    }

    func lookup(serverURL: String, bearer: String, userCode: String) async throws -> DeviceLookupResponse {
        if let lookupError { throw lookupError }
        return DeviceLookupResponse(matchCode: lookupMatchCode, deviceName: nil, devicePlatform: nil, status: nil)
    }

    private(set) var approveAttempts = 0

    func approve(serverURL: String, bearer: String, userCode: String) async throws {
        approveAttempts += 1
        if let approveError { throw approveError }
        approvedCodes.append(userCode)
    }
}

// MARK: - Helpers

@MainActor
private func expectEventually(
    _ label: String,
    timeout: TimeInterval = 5,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ condition: () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("timed out waiting for: \(label)", file: file, line: line)
}

private func entry(_ id: String, name: String) -> ServerEntry {
    ServerEntry(id: id, url: "https://\(id).example", fetchedName: name, profileId: nil, lastUsedAt: Date())
}

private func devicePoll(_ status: String, tokens: APIv2LoginTokens? = nil) -> APIv2DevicePoll {
    APIv2DevicePoll(status: status, pollAfter: 1, tokens: tokens, profileId: "", profileToken: "",
        temporary: false, sessionExpiresAt: nil)
}

private let approvedPoll = devicePoll("approved", tokens: APIv2LoginTokens(
    accessToken: "ACCESS", refreshToken: "REFRESH", expiresIn: 3600,
    user: APIv2Account(id: "account-1", username: "laura", email: "laura@example.test",
        role: .user, permissions: [], downloadAllowed: true, impersonation: nil)
))

private let pendingPoll = devicePoll("pending")

private func problem(_ status: Int, _ type: String) -> APIv2Problem {
    APIv2Problem(type: "https://siloserver.org/problems/\(type)", title: type, status: status,
        detail: "", instance: nil, errors: nil)
}

private let expiredProblem = problem(404, "not_found")

// MARK: - Server session persistence

@MainActor
final class ServerSessionPersistenceTests: XCTestCase {
    func testRegistryMutationsRollBackWhenPersistenceFails() async throws {
        let suiteName = "ServerSessionPersistenceTests.suite.\(UUID().uuidString)"
        let standardName = "ServerSessionPersistenceTests.standard.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let standard = try XCTUnwrap(UserDefaults(suiteName: standardName))
        defer {
            suite.removePersistentDomain(forName: suiteName)
            standard.removePersistentDomain(forName: standardName)
        }
        var allowsPersistence = true
        let defaults = SharedDefaults(suite: suite, standard: standard)
        let registry = ServerRegistry(
            defaults: defaults,
            keychain: SharedKeychain(
                service: "ServerSessionPersistenceTests.\(UUID().uuidString)",
                accessGroup: nil
            ),
            launchPreferences: ProfileLaunchPreferences(defaults: defaults),
            persistenceOverride: { _, _ in allowsPersistence }
        )
        let first = ServerEntry(
            id: "first",
            url: "https://first.example",
            fetchedName: "First",
            lastUsedAt: Date()
        )
        let second = ServerEntry(
            id: "second",
            url: "https://second.example",
            fetchedName: "Second",
            lastUsedAt: Date()
        )
        XCTAssertNotNil(registry.addOrUpdate(first))

        allowsPersistence = false
        XCTAssertNil(registry.addOrUpdate(second))
        XCTAssertNil(registry.entry(with: second.id))
        let switched = await registry.switchTo(serverId: first.id)
        XCTAssertFalse(switched)
        XCTAssertNil(registry.activeServerId)
        let removed = await registry.remove(serverId: first.id)
        XCTAssertFalse(removed)
        XCTAssertEqual(registry.entry(with: first.id), first)
    }

    /// Companion authorization may install a different user's credentials for
    /// an existing URL. That boundary must not inherit the previous account's
    /// profile, while ordinary metadata upserts continue preserving it.
    func testNewSessionUpsertClearsExistingProfileAndRefreshesServerName() {
        let suiteName = "ServerSessionPersistenceTests.suite.\(UUID().uuidString)"
        let standardName = "ServerSessionPersistenceTests.standard.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        let standard = UserDefaults(suiteName: standardName)!
        defer {
            suite.removePersistentDomain(forName: suiteName)
            standard.removePersistentDomain(forName: standardName)
        }

        let defaults = SharedDefaults(suite: suite, standard: standard)
        let launchPreferences = ProfileLaunchPreferences(defaults: defaults)
        let registry = ServerRegistry(
            defaults: defaults,
            keychain: SharedKeychain(service: "ServerSessionPersistenceTests.\(UUID().uuidString)", accessGroup: nil),
            launchPreferences: launchPreferences
        )
        let serverID = ServerRegistry.serverId(for: "https://home.example")
        registry.addOrUpdate(ServerEntry(
            id: serverID,
            url: "https://home.example",
            fetchedName: "Home",
            lastUsedAt: Date()
        ))
        launchPreferences.remember(
            profileID: "OLD-PROFILE",
            requiresPIN: false,
            accountEpoch: "old-account",
            for: serverID
        )

        registry.addOrUpdate(ServerEntry(
            id: serverID,
            url: "https://home.example",
            fetchedName: "Home Renamed",
            profileId: nil,
            lastUsedAt: Date()
        ), preservingProfile: false)

        XCTAssertNil(launchPreferences.rememberedProfile(for: serverID))
        XCTAssertEqual(registry.entry(with: serverID)?.fetchedName, "Home Renamed")
        XCTAssertEqual(registry.entry(with: serverID)?.displayName, "Home Renamed")
    }
}

// MARK: - Companion

@MainActor
final class CompanionPairingCoordinatorTests: XCTestCase {
    private func makeCoordinator(
        channel: FakePairingChannel,
        api: FakePairingAPI,
        servers: [ServerEntry],
        endpoints: [ServerEndpoint]? = nil
    ) -> CompanionPairingCoordinator {
        let coordinator = CompanionPairingCoordinator(
            channel: channel,
            stream: channel.stream,
            tvName: "Living Room",
            api: api,
            deviceModel: "iPhone",
            availableServers: { servers },
            accessToken: { _ in "token" },
            serverEndpoints: { _, _ in endpoints }
        )
        coordinator.start()
        return coordinator
    }

    /// A server with a verified identity is pushed with that identity and
    /// the deployment's other addresses, and a typed TV failure reaches the
    /// summary. A server without one is pushed the legacy way.
    func testPushCarriesIdentityAndEndpointsAndSummarisesTypedFailure() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        let identified = ServerEntry(
            id: "a", url: "https://a.example", fetchedName: "Home", profileId: nil,
            lastUsedAt: Date(), verifiedServerId: "S"
        )
        let legacy = entry("b", name: "Legacy")
        let endpoints = [ServerEndpoint(url: "https://public.example", kind: .public)]
        let coordinator = makeCoordinator(channel: channel, api: api, servers: [identified, legacy], endpoints: endpoints)

        channel.deliver(.hello(tvName: "Living Room", tvDeviceId: "tv", state: .setup, supportedVersions: [1]))
        await expectEventually("picker") {
            if case .pickServers = coordinator.state { return true }
            return false
        }
        await coordinator.pushSelected([identified, legacy])
        await expectEventually("first push") {
            channel.sent.contains {
                if case .pushServer("https://a.example", "Home", "S", endpoints) = $0 { return true }
                return false
            }
        }
        channel.deliver(.serverResult(serverURL: "https://a.example", status: .failed, error: "unreachable"))
        await expectEventually("legacy push") {
            channel.sent.contains {
                if case .pushServer("https://b.example", "Legacy", nil, nil) = $0 { return true }
                return false
            }
        }
        channel.deliver(.serverResult(serverURL: "https://b.example", status: .failed, error: nil))
        await expectEventually("summary") {
            if case .finished(let ok, let bad) = coordinator.state {
                return ok.isEmpty && bad.map(\.code) == [.unreachable, .authFailed]
            }
            return false
        }
        if case .finished(_, let bad) = coordinator.state {
            XCTAssertTrue(bad[0].summary.contains("couldn't reach"))
        }
    }

    private func hello() -> PairingMessage {
        .hello(tvName: "Living Room", tvDeviceId: "tv-1", state: .setup, supportedVersions: [PairingProtocol.version])
    }

    func testHelloPresentsServerPicker() async {
        let channel = FakePairingChannel()
        let coordinator = makeCoordinator(channel: channel, api: FakePairingAPI(), servers: [entry("a", name: "Home")])
        channel.deliver(hello())
        await expectEventually("server picker") {
            if case .pickServers(_, let servers) = coordinator.state { return servers.count == 1 }
            return false
        }
    }

    func testUnsupportedVersionEndsWithError() async {
        let channel = FakePairingChannel()
        let coordinator = makeCoordinator(channel: channel, api: FakePairingAPI(), servers: [entry("a", name: "Home")])
        channel.deliver(.hello(tvName: "TV", tvDeviceId: "tv-1", state: .setup, supportedVersions: [99]))
        await expectEventually("version error") {
            if case .error = coordinator.state { return true }
            return false
        }
        XCTAssertEqual(channel.lastSent, .cancel(reason: "version_unsupported"))
    }

    /// Regression: while paused on the match-code confirm, the coordinator
    /// must still hear a TV-side cancel (the old pull-based design went deaf).
    func testCancelFromTVWhileConfirmingSurfacesError() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        let coordinator = makeCoordinator(channel: channel, api: api, servers: [entry("a", name: "Home")])
        channel.deliver(hello())
        await expectEventually("picker") {
            if case .pickServers = coordinator.state { return true }
            return false
        }
        guard case let .pickServers(_, servers) = coordinator.state else {
            return XCTFail("expected pickServers, got \(coordinator.state)")
        }
        await coordinator.pushSelected(servers)
        channel.deliver(.deviceStarted(serverURL: "https://a.example", userCode: "USER-1", matchCode: "ABCD"))
        await expectEventually("confirm step") {
            if case .confirmMatch(_, _, let code) = coordinator.state { return code == "ABCD" }
            return false
        }
        channel.deliver(.cancel(reason: "receiver_cancelled"))
        await expectEventually("cancelled error") {
            if case .error(let message) = coordinator.state { return message.contains("cancelled") }
            return false
        }
        XCTAssertTrue(api.approvedCodes.isEmpty, "must not approve a session the TV abandoned")
    }

    /// Regression: servers after the first are auto-approved, so the code the
    /// TV displayed must be verified against the server's authoritative one.
    func testAutoApproveRefusesMismatchedMatchCode() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        let servers = [entry("a", name: "Home"), entry("b", name: "Remote")]
        let coordinator = makeCoordinator(channel: channel, api: api, servers: servers)
        channel.deliver(hello())
        await expectEventually("picker") {
            if case .pickServers = coordinator.state { return true }
            return false
        }
        await coordinator.pushSelected(servers)

        // First server: codes agree; the user confirms.
        channel.deliver(.deviceStarted(serverURL: servers[0].url, userCode: "USER-1", matchCode: "ABCD"))
        await expectEventually("confirm step") {
            if case .confirmMatch = coordinator.state { return true }
            return false
        }
        await coordinator.confirmMatch()
        channel.deliver(.serverResult(serverURL: servers[0].url, status: .signedIn, error: nil))

        // Second server: the TV shows ZZZZ but the server says ABCD — splice.
        await expectEventually("second push") {
            channel.sent.contains { if case .pushServer(let url, _, _, _) = $0 { return url == servers[1].url } else { return false } }
        }
        channel.deliver(.deviceStarted(serverURL: servers[1].url, userCode: "USER-2", matchCode: "ZZZZ"))

        await expectEventually("summary") {
            if case .finished(let ok, let bad) = coordinator.state { return ok == ["Home"] && bad.map(\.name) == ["Remote"] }
            return false
        }
        XCTAssertEqual(api.approvedCodes, ["USER-1"], "the spliced server must never be approved")
    }

    /// Regression: a dropped connection mid-flow must read as a connection
    /// error, not a success-shaped summary full of "failed" servers.
    func testConnectionDropMidFlowShowsError() async {
        let channel = FakePairingChannel()
        let coordinator = makeCoordinator(channel: channel, api: FakePairingAPI(), servers: [entry("a", name: "Home")])
        channel.deliver(hello())
        await expectEventually("picker") {
            if case .pickServers = coordinator.state { return true }
            return false
        }
        guard case let .pickServers(_, servers) = coordinator.state else {
            return XCTFail("expected pickServers, got \(coordinator.state)")
        }
        await coordinator.pushSelected(servers)
        channel.dropConnection()
        await expectEventually("connection lost") {
            if case .error(let message) = coordinator.state { return message.contains("lost") }
            return false
        }
    }

    /// The match code is the trust anchor: a server that omits it hard-fails
    /// rather than presenting an empty prompt.
    func testMissingMatchCodeFailsServer() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.lookupMatchCode = nil
        let coordinator = makeCoordinator(channel: channel, api: api, servers: [entry("a", name: "Home")])
        channel.deliver(hello())
        await expectEventually("picker") {
            if case .pickServers = coordinator.state { return true }
            return false
        }
        guard case let .pickServers(_, servers) = coordinator.state else {
            return XCTFail("expected pickServers, got \(coordinator.state)")
        }
        await coordinator.pushSelected(servers)
        channel.deliver(.deviceStarted(serverURL: servers[0].url, userCode: "USER-1", matchCode: "ABCD"))
        await expectEventually("zero-success summary") {
            if case .finished(let ok, let bad) = coordinator.state { return ok.isEmpty && bad.map(\.name) == ["Home"] }
            return false
        }
        XCTAssertTrue(api.approvedCodes.isEmpty)
    }

    /// A v1-only server fails its lookup with the typed update code, so the
    /// summary says what to update instead of a generic TV failure.
    func testLookupOnV1OnlyServerSummarisesUpdateRequired() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.lookupError = APIv2Error.serverUpdateRequired
        let coordinator = makeCoordinator(channel: channel, api: api, servers: [entry("a", name: "Home")])
        channel.deliver(hello())
        await expectEventually("picker") {
            if case .pickServers = coordinator.state { return true }
            return false
        }
        guard case let .pickServers(_, servers) = coordinator.state else {
            return XCTFail("expected pickServers, got \(coordinator.state)")
        }
        await coordinator.pushSelected(servers)
        channel.deliver(.deviceStarted(serverURL: servers[0].url, userCode: "USER-1", matchCode: "ABCD"))
        await expectEventually("update summary") {
            if case .finished(let ok, let bad) = coordinator.state { return ok.isEmpty && bad.map(\.code) == [.updateRequired] }
            return false
        }
        XCTAssertTrue(api.approvedCodes.isEmpty)
    }

    /// A 409 means the request was already decided elsewhere. The approval
    /// is not sent again, and the error says what happened instead of
    /// blaming the phone's connection.
    func testAlreadyDecidedApprovalEndsWithoutRetrying() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.approveError = APIv2Error.problem(problem(409, "conflict"))
        let coordinator = makeCoordinator(channel: channel, api: api, servers: [entry("a", name: "Home")])
        channel.deliver(hello())
        await expectEventually("picker") {
            if case .pickServers = coordinator.state { return true }
            return false
        }
        guard case let .pickServers(_, servers) = coordinator.state else {
            return XCTFail("expected pickServers, got \(coordinator.state)")
        }
        await coordinator.pushSelected(servers)
        channel.deliver(.deviceStarted(serverURL: servers[0].url, userCode: "USER-1", matchCode: "ABCD"))
        await expectEventually("confirm prompt") {
            if case .confirmMatch = coordinator.state { return true }
            return false
        }
        await coordinator.confirmMatch()
        await expectEventually("approve error") {
            if case .error(let message) = coordinator.state { return message.contains("already approved or declined") }
            return false
        }
        XCTAssertEqual(api.approveAttempts, 1)
        XCTAssertEqual(channel.lastSent, .cancel(reason: "approve_failed"))
    }
}

// MARK: - Receiver

@MainActor
final class ReceiverPairingCoordinatorTests: XCTestCase {
    private struct Persisted: Equatable {
        let url: String
        let access: String
    }

    private final class PersistRecorder: @unchecked Sendable {
        var persisted: [Persisted] = []
        var verifiedIds: [String?] = []
        var accountIDs: [String] = []
    }

    @MainActor
    private final class PersistGate {
        var started = false
        var cancelled = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withTaskCancellationHandler {
                await withCheckedContinuation {
                    continuation = $0
                    started = true
                }
            } onCancel: {
                Task { @MainActor in self.cancelled = true }
            }
        }

        func release() {
            continuation?.resume()
            continuation = nil
        }
    }

    private func makeCoordinator(
        api: FakePairingAPI,
        recorder: PersistRecorder,
        identities: [String: ServerIdentityProbeResult] = [:],
        probeLog: ProbeLog? = nil
    ) -> ReceiverPairingCoordinator {
        ReceiverPairingCoordinator(
            api: api,
            identityProbe: { url in
                probeLog?.record(url)
                return identities[ServerRegistry.normalize(url: url)] ?? .unreachable
            }
        ) { pairing in
            recorder.persisted.append(Persisted(url: pairing.url, access: pairing.accessToken))
            recorder.verifiedIds.append(pairing.verifiedServerId)
            recorder.accountIDs.append(pairing.accountID)
            return true
        }
    }

    private func allowPush(_ channel: FakePairingChannel, _ coordinator: ReceiverPairingCoordinator) async {
        channel.deliver(.pushServer(serverURL: "https://home.example", serverName: "Home"))
        await expectEventually("consent prompt") {
            if case .consentRequested = coordinator.state { return true }
            return false
        }
        coordinator.allowPendingServer()
    }

    /// A v1-only server answers the v2 start with Go's plain 404. The TV
    /// explains the update instead of a generic sign-in failure, and tells
    /// the phone with the typed code.
    func testUpdateRequiredOnStartShowsTheUpdateMessage() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.startError = APIv2Error.serverUpdateRequired
        let coordinator = makeCoordinator(api: api, recorder: PersistRecorder())
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        await allowPush(channel, coordinator)
        await expectEventually("update-required failure") {
            coordinator.state == .failed(serverName: "Home", code: .updateRequired, help: UpdateRequirement.serverMessage)
        }
        XCTAssertTrue(channel.sent.contains {
            if case .serverResult("https://home.example", .failed, "update_required") = $0 { return true }
            return false
        })
        channel.deliver(.done)
        await runTask.value
    }

    /// A 410 `client_upgrade_required` on a poll ends the attempt with the
    /// app-update message instead of polling until the code expires.
    func testClientUpgradeRequiredOnPollStopsPolling() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResults = [.failure(APIv2Error.problem(problem(410, "client_upgrade_required")))]
        let recorder = PersistRecorder()
        let coordinator = makeCoordinator(api: api, recorder: recorder)
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        await allowPush(channel, coordinator)
        await expectEventually("update-required failure") {
            coordinator.state == .failed(serverName: "Home", code: .updateRequired, help: UpdateRequirement.appMessage)
        }
        XCTAssertEqual(api.pollCount, 1)
        XCTAssertTrue(recorder.persisted.isEmpty)
        channel.deliver(.done)
        await runTask.value
    }

    /// The approved poll's `TokenPair.user.id` is what the session binds as
    /// its verified account.
    func testApprovedPollPersistsTheVerifiedAccount() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResponse = approvedPoll
        let recorder = PersistRecorder()
        let coordinator = makeCoordinator(api: api, recorder: recorder)
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        await allowPush(channel, coordinator)
        await expectEventually("signed in") {
            if case .signedIn = coordinator.state { return true }
            return false
        }
        XCTAssertEqual(recorder.persisted, [Persisted(url: "https://home.example", access: "ACCESS")])
        XCTAssertEqual(recorder.accountIDs, ["account-1"])
        channel.deliver(.done)
        await runTask.value
    }

    private final class ProbeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [String] = []
        func record(_ url: String) { lock.withLock { urls.append(url) } }
        var probed: [String] { lock.withLock { urls } }
    }

    private static let identity = "96c1bd08-b839-4d47-980e-57d4e7a44cfa"
    private static let pushedURL = "https://silo.overlay.example"
    private static let publicURL = "https://silo.example"
    private static let endpoints = [
        ServerEndpoint(url: publicURL, kind: .public),
        ServerEndpoint(url: pushedURL, kind: .provider, provider: "tailscale", displayName: "Tailscale"),
    ]

    private func pushWithIdentity() -> PairingMessage {
        .pushServer(serverURL: Self.pushedURL, serverName: "Home", serverIdentity: Self.identity, endpoints: Self.endpoints)
    }

    /// The pushed (plugin) address is unreachable from the TV, and the public
    /// address answers with the same identity: the TV must OFFER it, name
    /// the provider in its help, and only switch when the user chooses. The
    /// frames back to the phone keep naming the pushed address; the TV
    /// persists the address that worked, with the verified identity.
    func testUnreachablePushOffersVerifiedAlternateAndPersistsWorkingAddress() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResponse = approvedPoll
        let recorder = PersistRecorder()
        let probes = ProbeLog()
        let coordinator = makeCoordinator(
            api: api, recorder: recorder,
            identities: [Self.publicURL: .identity(Self.identity)],
            probeLog: probes
        )
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(pushWithIdentity())
        await expectEventually("consent prompt") {
            if case .consentRequested(let name) = coordinator.state { return name == "Home" }
            return false
        }
        coordinator.allowPendingServer()
        await expectEventually("unreachable with alternate") {
            if case .unreachable(let name, let help, let alternate) = coordinator.state {
                return name == "Home" && help.contains("Tailscale") && alternate?.url == Self.publicURL
            }
            return false
        }
        XCTAssertTrue(api.startedServers.isEmpty, "no device login until the user chooses an address")
        XCTAssertEqual(probes.probed, [Self.pushedURL, Self.publicURL])

        coordinator.useAlternateAddress()
        await expectEventually("signed in") {
            if case .signedIn(let count) = coordinator.state { return count == 1 }
            return false
        }
        XCTAssertEqual(api.startedServers, [Self.publicURL])
        XCTAssertEqual(recorder.persisted.map(\.url), [Self.publicURL])
        XCTAssertEqual(recorder.verifiedIds, [Self.identity])
        let started = channel.sent.compactMap { message -> String? in
            if case .deviceStarted(let url, _, _) = message { return url } else { return nil }
        }
        let results = channel.sent.compactMap { message -> String? in
            if case .serverResult(let url, .signedIn, _) = message { return url } else { return nil }
        }
        XCTAssertEqual(started, [Self.pushedURL], "deviceStarted echoes the pushed address")
        XCTAssertEqual(results, [Self.pushedURL], "serverResult echoes the pushed address")

        channel.deliver(.done)
        await runTask.value
    }

    /// Retry after the user set the provider up: the pushed address is
    /// probed again and, once it answers with the right identity, used.
    func testRetryAfterProviderSetupUsesThePushedAddress() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResponse = approvedPoll
        let recorder = PersistRecorder()
        let answers = ProbeAnswers([.unreachable, .identity(Self.identity)])
        let coordinator = ReceiverPairingCoordinator(
            api: api,
            identityProbe: { _ in answers.next() }
        ) { pairing in
            recorder.persisted.append(Persisted(url: pairing.url, access: pairing.accessToken))
            return true
        }
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(.pushServer(serverURL: Self.pushedURL, serverName: "Home", serverIdentity: Self.identity, endpoints: nil))
        await expectEventually("consent prompt") {
            if case .consentRequested = coordinator.state { return true }
            return false
        }
        coordinator.allowPendingServer()
        await expectEventually("unreachable without alternate") {
            if case .unreachable(_, _, let alternate) = coordinator.state { return alternate == nil }
            return false
        }
        coordinator.retryPushedAddress()
        await expectEventually("signed in") {
            if case .signedIn = coordinator.state { return true }
            return false
        }
        XCTAssertEqual(api.startedServers, [Self.pushedURL])
        XCTAssertEqual(recorder.persisted.map(\.url), [Self.pushedURL])
        channel.deliver(.done)
        await runTask.value
    }

    private final class ProbeAnswers: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [ServerIdentityProbeResult]
        init(_ queue: [ServerIdentityProbeResult]) { self.queue = queue }
        func next() -> ServerIdentityProbeResult {
            lock.withLock { queue.isEmpty ? .unreachable : queue.removeFirst() }
        }
    }

    /// An address that answers as a different deployment is refused, never
    /// used, and the phone learns why.
    func testIdentityMismatchFailsWithoutDeviceLogin() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResponse = approvedPoll
        let recorder = PersistRecorder()
        let coordinator = makeCoordinator(
            api: api, recorder: recorder,
            identities: [Self.pushedURL: .identity("someone-else")]
        )
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(pushWithIdentity())
        await expectEventually("consent prompt") {
            if case .consentRequested = coordinator.state { return true }
            return false
        }
        coordinator.allowPendingServer()
        await expectEventually("identity mismatch failure") {
            if case .failed("Home", .identityMismatch, _) = coordinator.state { return true }
            return false
        }
        XCTAssertTrue(api.startedServers.isEmpty)
        XCTAssertTrue(recorder.persisted.isEmpty)
        XCTAssertTrue(channel.sent.contains {
            if case .serverResult(Self.pushedURL, .failed, "identity_mismatch") = $0 { return true }
            return false
        })
        channel.deliver(.done)
        await runTask.value
    }

    /// Cancelling from the unreachable screen ends the attempt cleanly, with
    /// nothing persisted and the receiver back at idle.
    func testCancelWhileUnreachableReturnsToIdle() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        let recorder = PersistRecorder()
        let coordinator = makeCoordinator(api: api, recorder: recorder)
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(pushWithIdentity())
        await expectEventually("consent prompt") {
            if case .consentRequested = coordinator.state { return true }
            return false
        }
        coordinator.allowPendingServer()
        await expectEventually("unreachable") {
            if case .unreachable = coordinator.state { return true }
            return false
        }
        await coordinator.cancel()
        await runTask.value
        guard case .idle = coordinator.state else {
            return XCTFail("expected idle, got \(coordinator.state)")
        }
        XCTAssertTrue(api.startedServers.isEmpty)
        XCTAssertTrue(recorder.persisted.isEmpty)
    }

    /// A push from an older phone carries no identity: the pushed address is
    /// used exactly, no probe runs, and a denied approval reports `denied`.
    func testLegacyPushSkipsProbingAndReportsTypedFailure() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResponse = devicePoll("denied")
        let recorder = PersistRecorder()
        let probes = ProbeLog()
        let coordinator = makeCoordinator(api: api, recorder: recorder, probeLog: probes)
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(.pushServer(serverURL: "https://home.example", serverName: "Home"))
        await expectEventually("consent prompt") {
            if case .consentRequested = coordinator.state { return true }
            return false
        }
        coordinator.allowPendingServer()
        await expectEventually("denied failure") {
            if case .failed("Home", .denied, nil) = coordinator.state { return true }
            return false
        }
        XCTAssertTrue(probes.probed.isEmpty)
        XCTAssertEqual(api.startedServers, ["https://home.example"])
        XCTAssertEqual(recorder.verifiedIds, [])
        XCTAssertTrue(channel.sent.contains {
            if case .serverResult("https://home.example", .failed, "denied") = $0 { return true }
            return false
        })
        channel.deliver(.done)
        await runTask.value
    }

    /// The consent gate: nothing touches the pushed URL until the TV user
    /// allows it, and denying ends the session back at idle.
    func testPushRequiresConsentBeforeAnyNetworkCall() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResponse = approvedPoll
        let recorder = PersistRecorder()
        let coordinator = makeCoordinator(api: api, recorder: recorder)
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(.pushServer(serverURL: "https://home.example", serverName: "Home"))
        await expectEventually("consent prompt") {
            if case .consentRequested(let name) = coordinator.state { return name == "Home" }
            return false
        }
        XCTAssertTrue(api.startedServers.isEmpty, "no device/start before the user allows it")

        coordinator.allowPendingServer()
        await expectEventually("signed in") {
            if case .signedIn(let count) = coordinator.state { return count == 1 }
            return false
        }
        XCTAssertEqual(api.startedServers.count, 1)
        XCTAssertEqual(recorder.persisted.map(\.access), ["ACCESS"])
        XCTAssertTrue(channel.sent.contains { if case .serverResult(_, .signedIn, _) = $0 { return true } else { return false } })

        channel.deliver(.done)
        await expectEventually("completed") {
            if case .completed(let names) = coordinator.state { return names == ["Home"] }
            return false
        }
        await runTask.value
    }

    func testDenyConsentEndsSessionAtIdle() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        let coordinator = makeCoordinator(api: api, recorder: PersistRecorder())
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(.pushServer(serverURL: "https://home.example", serverName: "Home"))
        await expectEventually("consent prompt") {
            if case .consentRequested = coordinator.state { return true }
            return false
        }
        await coordinator.denyPendingServer()
        await runTask.value
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertEqual(channel.lastSent, .cancel(reason: "consent_denied"))
        XCTAssertTrue(api.startedServers.isEmpty)
    }

    /// Regression: the server can restart or a reverse proxy can briefly
    /// return an error while a valid device-login request is pending. Keep
    /// polling the same request instead of making the whole companion setup
    /// terminal after that single transient response.
    func testTransientPollFailureRetriesAndEventuallySignsIn() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResults = [
            .failure(APIv2Error.httpStatus(502)),
            .success(approvedPoll),
        ]
        let recorder = PersistRecorder()
        let coordinator = makeCoordinator(api: api, recorder: recorder)
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(.pushServer(serverURL: "https://home.example", serverName: "Home"))
        await expectEventually("consent prompt") {
            if case .consentRequested = coordinator.state { return true }
            return false
        }
        coordinator.allowPendingServer()
        await expectEventually("signed in after retry") {
            if case .signedIn(let count) = coordinator.state { return count == 1 }
            return false
        }

        XCTAssertEqual(api.pollCount, 2)
        XCTAssertEqual(recorder.persisted.map(\.access), ["ACCESS"])
        XCTAssertTrue(channel.sent.contains {
            if case .serverResult(_, .signedIn, _) = $0 { return true }
            return false
        })

        channel.deliver(.done)
        await runTask.value
    }

    func testMissingPollRequestFailsWithoutRetrying() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResults = [.failure(APIv2Error.problem(expiredProblem))]
        let recorder = PersistRecorder()
        let coordinator = makeCoordinator(api: api, recorder: recorder)
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(.pushServer(serverURL: "https://home.example", serverName: "Home"))
        await expectEventually("consent prompt") {
            if case .consentRequested = coordinator.state { return true }
            return false
        }
        coordinator.allowPendingServer()
        await expectEventually("missing request failure") {
            if case .failed(let name, _, _) = coordinator.state { return name == "Home" }
            return false
        }

        XCTAssertEqual(api.pollCount, 1)
        XCTAssertTrue(recorder.persisted.isEmpty)
        channel.deliver(.done)
        await runTask.value
    }

    /// A status outside the poll contract ends the attempt the way every
    /// device-code flow ends it (and the way wire validation already
    /// refuses it), rather than being polled as if it were pending.
    func testUnknownPollStatusFailsWithoutPollingAgain() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResults = [.success(devicePoll("slow_down"))]
        api.pollResponse = pendingPoll
        let recorder = PersistRecorder()
        let coordinator = makeCoordinator(api: api, recorder: recorder)
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        await allowPush(channel, coordinator)
        await expectEventually("unknown status failure") {
            coordinator.state == .failed(serverName: "Home", code: .authFailed, help: nil)
        }

        XCTAssertEqual(api.pollCount, 1)
        XCTAssertTrue(recorder.persisted.isEmpty)
        XCTAssertTrue(channel.sent.contains {
            if case .serverResult("https://home.example", .failed, "auth_failed") = $0 { return true }
            return false
        })
        channel.deliver(.done)
        await runTask.value
    }

    func testCancellationDuringTransientPollBackoffDoesNotPublishFailure() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResults = [.failure(APIv2Error.httpStatus(502))]
        let recorder = PersistRecorder()
        let coordinator = makeCoordinator(api: api, recorder: recorder)
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(.pushServer(serverURL: "https://home.example", serverName: "Home"))
        await expectEventually("consent prompt") {
            if case .consentRequested = coordinator.state { return true }
            return false
        }
        coordinator.allowPendingServer()
        await expectEventually("first transient poll failure") { api.pollCount == 1 }

        channel.deliver(.cancel(reason: "test_cancel"))
        await runTask.value
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(recorder.persisted.isEmpty)
        XCTAssertFalse(channel.sent.contains {
            if case .serverResult(_, .failed, _) = $0 { return true }
            return false
        })
    }

    /// Regression: leaving the setup screen can race the non-cancellable
    /// persistence boundary. A committed sign-in result must reach the phone
    /// before the TV sends its teardown cancellation.
    func testCancellationAfterPersistenceStartsPublishesSuccessFirst() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResponse = approvedPoll
        let recorder = PersistRecorder()
        let gate = PersistGate()
        let coordinator = ReceiverPairingCoordinator(api: api) { pairing in
            await gate.wait()
            recorder.persisted.append(Persisted(url: pairing.url, access: pairing.accessToken))
            return true
        }
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(.pushServer(serverURL: "https://home.example", serverName: "Home"))
        await expectEventually("consent prompt") {
            if case .consentRequested = coordinator.state { return true }
            return false
        }
        coordinator.allowPendingServer()
        await expectEventually("persistence started") { gate.started }

        let cancelTask = Task { await coordinator.cancel() }
        await expectEventually("attempt cancelled at persistence boundary") { gate.cancelled }
        gate.release()
        await cancelTask.value

        let resultIndex = channel.sent.firstIndex {
            if case .serverResult(_, .signedIn, _) = $0 { return true }
            return false
        }
        let cancelIndex = channel.sent.firstIndex(of: .cancel(reason: "receiver_cancelled"))
        XCTAssertNotNil(resultIndex)
        XCTAssertNotNil(cancelIndex)
        if let resultIndex, let cancelIndex {
            XCTAssertLessThan(resultIndex, cancelIndex)
        }
        XCTAssertEqual(recorder.persisted.map(\.access), ["ACCESS"])
        await runTask.value
    }

    /// A phone-side timeout at the same boundary must not return the TV to
    /// setup after its credentials have already committed.
    func testPeerCancellationAfterPersistenceStartsPreservesCommittedSignIn() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResponse = approvedPoll
        let recorder = PersistRecorder()
        let gate = PersistGate()
        let coordinator = ReceiverPairingCoordinator(api: api) { pairing in
            await gate.wait()
            recorder.persisted.append(Persisted(url: pairing.url, access: pairing.accessToken))
            return true
        }
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(.pushServer(serverURL: "https://home.example", serverName: "Home"))
        await expectEventually("consent prompt") {
            if case .consentRequested = coordinator.state { return true }
            return false
        }
        coordinator.allowPendingServer()
        await expectEventually("persistence started") { gate.started }

        channel.deliver(.cancel(reason: "phone_timeout"))
        await expectEventually("attempt cancelled at persistence boundary") { gate.cancelled }
        gate.release()
        await runTask.value

        XCTAssertEqual(coordinator.state, .completed(serverNames: ["Home"]))
        XCTAssertEqual(recorder.persisted.map(\.access), ["ACCESS"])
        XCTAssertTrue(channel.sent.contains {
            if case .serverResult(_, .signedIn, _) = $0 { return true }
            return false
        })
    }

    /// Regression: the phone's `done` after a failed-only session must not
    /// clobber the failure explanation back to the idle chooser.
    func testDoneWithZeroSignInsKeepsFailureOnScreen() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.startError = APIv2Error.httpStatus(500)
        let coordinator = makeCoordinator(api: api, recorder: PersistRecorder())
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(.pushServer(serverURL: "https://home.example", serverName: "Home"))
        await expectEventually("consent prompt") {
            if case .consentRequested = coordinator.state { return true }
            return false
        }
        coordinator.allowPendingServer()
        await expectEventually("failed state") {
            if case .failed(let name, _, _) = coordinator.state { return name == "Home" }
            return false
        }
        channel.deliver(.done)
        await runTask.value
        guard case .failed = coordinator.state else {
            return XCTFail("failure screen was clobbered; state is \(coordinator.state)")
        }
    }

    /// Regression: the TV's "verifying automatically" copy must key off a
    /// COMMITTED sign-in, not attempt order — after a pre-confirm failure on
    /// the first server, the phone still asks the user to compare codes for
    /// the second, so the TV must not claim the phone is auto-approving.
    func testSecondAttemptAfterFailureIsNotAutomatic() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.startError = APIv2Error.httpStatus(500)
        let coordinator = makeCoordinator(api: api, recorder: PersistRecorder())
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(.pushServer(serverURL: "https://one.example", serverName: "One"))
        await expectEventually("consent prompt") {
            if case .consentRequested = coordinator.state { return true }
            return false
        }
        coordinator.allowPendingServer()
        await expectEventually("first attempt failed") {
            if case .failed = coordinator.state { return true }
            return false
        }

        api.startError = nil
        api.pollResponse = pendingPoll // hold the attempt at awaitingApproval
        channel.deliver(.pushServer(serverURL: "https://two.example", serverName: "Two"))
        await expectEventually("manual-confirmation copy") {
            if case let .awaitingApproval(_, _, automatic) = coordinator.state { return !automatic }
            return false
        }
        channel.dropConnection()
        await runTask.value
    }

    /// Regression: tokens are committed before the confirmation frame, so a
    /// connection that dies right after must still land on the summary.
    func testConnectionDropAfterSuccessStillCompletes() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResponse = approvedPoll
        let recorder = PersistRecorder()
        let coordinator = makeCoordinator(api: api, recorder: recorder)
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(.pushServer(serverURL: "https://home.example", serverName: "Home"))
        await expectEventually("consent prompt") {
            if case .consentRequested = coordinator.state { return true }
            return false
        }
        coordinator.allowPendingServer()
        await expectEventually("signed in") {
            if case .signedIn = coordinator.state { return true }
            return false
        }
        channel.dropConnection()
        await runTask.value
        guard case let .completed(names) = coordinator.state else {
            return XCTFail("expected completed after EOF-with-success; state is \(coordinator.state)")
        }
        XCTAssertEqual(names, ["Home"])
        XCTAssertEqual(recorder.persisted.map(\.url), ["https://home.example"])
    }

    /// A peer cancellation can arrive while the persistence transaction is
    /// queued behind another identity transition. If the lease is never
    /// acquired, the coordinator must not publish a sign-in that did not
    /// commit or include it in the completion summary.
    func testCancelledQueuedPersistDoesNotPublishSignedIn() async {
        let http = HTTPClient()
        guard let blockingLease = await http.beginIdentityTransition() else {
            return XCTFail("blocking transition was unexpectedly cancelled")
        }
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResponse = approvedPoll
        let recorder = PersistRecorder()
        let coordinator = ReceiverPairingCoordinator(api: api) { pairing in
            guard let lease = await http.beginIdentityTransition() else {
                return false
            }
            recorder.persisted.append(Persisted(url: pairing.url, access: pairing.accessToken))
            await http.endIdentityTransition(lease)
            return true
        }
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(.pushServer(serverURL: "https://home.example", serverName: "Home"))
        await expectEventually("consent prompt") {
            if case .consentRequested = coordinator.state { return true }
            return false
        }
        coordinator.allowPendingServer()
        guard await waitForIdentityTransitionWaiter(http) else {
            await http.endIdentityTransition(blockingLease)
            channel.dropConnection()
            await runTask.value
            return XCTFail("pairing persistence did not queue behind the active transition")
        }

        channel.deliver(.cancel(reason: "test_cancel"))
        await runTask.value
        XCTAssertEqual(coordinator.state, .idle)
        XCTAssertTrue(recorder.persisted.isEmpty)
        XCTAssertFalse(channel.sent.contains {
            if case .serverResult(_, .signedIn, _) = $0 { return true }
            return false
        })
        // A cancelled save is not a failure to report: whoever cancelled
        // owns the state.
        XCTAssertFalse(channel.sent.contains {
            if case .serverResult(_, .failed, _) = $0 { return true }
            return false
        })

        await http.endIdentityTransition(blockingLease)
    }

    /// A save the test fails or allows on demand; all access is on the
    /// main actor.
    private final class PersistOutcome: @unchecked Sendable {
        var succeed = false
        var calls: [String] = []
    }

    private func makeCoordinator(outcome: PersistOutcome, api: FakePairingAPI) -> ReceiverPairingCoordinator {
        ReceiverPairingCoordinator(api: api) { pairing in
            outcome.calls.append(pairing.url)
            return outcome.succeed
        }
    }

    private func isSaveFailure(_ state: ReceiverPairingCoordinator.State) -> Bool {
        if case let .failed(name, code, help) = state {
            return name == "Home" && code == .authFailed && help != nil
        }
        return false
    }

    /// Regression (F074): the phone approved but the TV could not save the
    /// server. The TV must show the failure and tell the phone right away,
    /// instead of sitting on the match code until the phone's watchdog fires.
    func testPersistFailureShowsFailureAndTellsPhone() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResponse = approvedPoll
        let outcome = PersistOutcome()
        let coordinator = makeCoordinator(outcome: outcome, api: api)
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        await allowPush(channel, coordinator)
        await expectEventually("save failure shown") { isSaveFailure(coordinator.state) }
        XCTAssertEqual(outcome.calls, ["https://home.example"])
        let failedResults = channel.sent.filter {
            if case .serverResult("https://home.example", .failed, "auth_failed") = $0 { return true }
            return false
        }
        XCTAssertEqual(failedResults.count, 1)
        XCTAssertFalse(channel.sent.contains {
            if case .serverResult(_, .signedIn, _) = $0 { return true }
            return false
        })

        channel.deliver(.done)
        await runTask.value
        guard case .failed("Home", .authFailed, _) = coordinator.state else {
            return XCTFail("expected the save failure to stay on screen; state is \(coordinator.state)")
        }
    }

    /// A failed save ends only that server's attempt: consent is still held,
    /// so the phone's next push signs in without asking again.
    func testPersistFailureStillAcceptsTheNextServer() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResponse = approvedPoll
        let outcome = PersistOutcome()
        let coordinator = makeCoordinator(outcome: outcome, api: api)
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        await allowPush(channel, coordinator)
        await expectEventually("save failure shown") { isSaveFailure(coordinator.state) }

        outcome.succeed = true
        channel.deliver(.pushServer(serverURL: "https://two.example", serverName: "Two"))
        await expectEventually("second server signed in") {
            coordinator.state == .signedIn(serverCount: 1)
        }
        XCTAssertEqual(outcome.calls, ["https://home.example", "https://two.example"])
        XCTAssertTrue(channel.sent.contains {
            if case .serverResult("https://two.example", .signedIn, _) = $0 { return true }
            return false
        })

        channel.deliver(.done)
        await runTask.value
        XCTAssertEqual(coordinator.state, .completed(serverNames: ["Two"]))
    }
}

private func waitForIdentityTransitionWaiter(_ http: HTTPClient) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if await http.pendingIdentityTransitionCount() > 0 {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}
