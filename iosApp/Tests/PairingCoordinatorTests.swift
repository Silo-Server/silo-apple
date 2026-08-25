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
    var pollResponse: DeviceLoginPollResponse?
    var pollResults: [Result<DeviceLoginPollResponse, Error>] = []

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

    func poll(serverURL: String, deviceCode: String) async throws -> DeviceLoginPollResponse {
        pollCount += 1
        if !pollResults.isEmpty {
            return try pollResults.removeFirst().get()
        }
        if let pollResponse { return pollResponse }
        throw PairingDeviceAPI.APIError.http(500)
    }

    func lookup(serverURL: String, bearer: String, userCode: String) async throws -> DeviceLookupResponse {
        if let lookupError { throw lookupError }
        return DeviceLookupResponse(matchCode: lookupMatchCode, deviceName: nil, devicePlatform: nil, status: nil)
    }

    func approve(serverURL: String, bearer: String, userCode: String) async throws {
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

private let approvedPoll = DeviceLoginPollResponse(
    status: "approved", pollAfter: nil, accessToken: "ACCESS", refreshToken: "REFRESH", expiresIn: 3600, user: nil
)

private let pendingPoll = DeviceLoginPollResponse(
    status: "pending", pollAfter: 1, accessToken: nil, refreshToken: nil, expiresIn: nil, user: nil
)

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
        servers: [ServerEntry]
    ) -> CompanionPairingCoordinator {
        let coordinator = CompanionPairingCoordinator(
            channel: channel,
            stream: channel.stream,
            tvName: "Living Room",
            api: api,
            deviceModel: "iPhone",
            availableServers: { servers },
            accessToken: { _ in "token" }
        )
        coordinator.start()
        return coordinator
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
            channel.sent.contains { if case .pushServer(let url, _) = $0 { return url == servers[1].url } else { return false } }
        }
        channel.deliver(.deviceStarted(serverURL: servers[1].url, userCode: "USER-2", matchCode: "ZZZZ"))

        await expectEventually("summary") {
            if case .finished(let ok, let bad) = coordinator.state { return ok == ["Home"] && bad == ["Remote"] }
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
            if case .finished(let ok, let bad) = coordinator.state { return ok.isEmpty && bad == ["Home"] }
            return false
        }
        XCTAssertTrue(api.approvedCodes.isEmpty)
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

    private func makeCoordinator(api: FakePairingAPI, recorder: PersistRecorder) -> ReceiverPairingCoordinator {
        ReceiverPairingCoordinator(api: api) { url, _, access, _ in
            recorder.persisted.append(Persisted(url: url, access: access))
            return true
        }
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
            .failure(PairingDeviceAPI.APIError.http(502)),
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
        api.pollResults = [.failure(PairingDeviceAPI.APIError.http(404))]
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
            if case .failed(let name) = coordinator.state { return name == "Home" }
            return false
        }

        XCTAssertEqual(api.pollCount, 1)
        XCTAssertTrue(recorder.persisted.isEmpty)
        channel.deliver(.done)
        await runTask.value
    }

    func testCancellationDuringTransientPollBackoffDoesNotPublishFailure() async {
        let channel = FakePairingChannel()
        let api = FakePairingAPI()
        api.pollResults = [.failure(PairingDeviceAPI.APIError.http(502))]
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
        let coordinator = ReceiverPairingCoordinator(api: api) { url, _, access, _ in
            await gate.wait()
            recorder.persisted.append(Persisted(url: url, access: access))
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
        let coordinator = ReceiverPairingCoordinator(api: api) { url, _, access, _ in
            await gate.wait()
            recorder.persisted.append(Persisted(url: url, access: access))
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
        api.startError = PairingDeviceAPI.APIError.http(500)
        let coordinator = makeCoordinator(api: api, recorder: PersistRecorder())
        let runTask = Task { await coordinator.run(session: channel, stream: channel.stream) }

        channel.deliver(.pushServer(serverURL: "https://home.example", serverName: "Home"))
        await expectEventually("consent prompt") {
            if case .consentRequested = coordinator.state { return true }
            return false
        }
        coordinator.allowPendingServer()
        await expectEventually("failed state") {
            if case .failed(let name) = coordinator.state { return name == "Home" }
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
        api.startError = PairingDeviceAPI.APIError.http(500)
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
        let coordinator = ReceiverPairingCoordinator(api: api) { url, _, access, _ in
            guard let lease = await http.beginIdentityTransition() else {
                return false
            }
            recorder.persisted.append(Persisted(url: url, access: access))
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

        await http.endIdentityTransition(blockingLease)
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
