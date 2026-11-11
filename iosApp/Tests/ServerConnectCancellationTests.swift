import XCTest
@testable import Silo

/// Cancelling a server connect stops it and leaves no trace: no error, no
/// plain-HTTP question, no further address, and the saved servers as they
/// were. A cancel that arrives once the server has answered is too late; the
/// connect then finishes whole, so no server is ever saved or active without
/// the app moving on to it.
@MainActor
final class ServerConnectCancellationTests: XCTestCase {
    private static let newURL = "https://new.example"
    private static let newID = ServerRegistry.serverId(for: newURL)
    private static let home = ServerEntry(
        id: ServerRegistry.serverId(for: "https://home.example"),
        url: "https://home.example",
        fetchedName: "Home",
        lastUsedAt: Date(timeIntervalSince1970: 1)
    )

    // MARK: - The setup form

    func testCancellingWhileAnAddressDoesNotAnswerLeavesTheFormAndServersAsTheyWere() async throws {
        let stack = try await makeStack()
        // The address takes the connection and never answers.
        stack.stub.hold(path: ServerIdentity.brandingPath)
        let service = stack.service
        let viewModel = ServerSetupViewModel(
            checkServer: { try await service.checkServer(url: $0) },
            hasSession: { false },
            resolveBareName: { _ in nil }
        )
        viewModel.host = "new.example"
        let router = AppRouter()
        let stateBefore = router.authState

        let connect = Task { await viewModel.connect(router: router) }
        await stack.stub.waitUntilHeld()
        XCTAssertTrue(viewModel.isLoading)
        connect.cancel()
        await connect.value

        XCTAssertFalse(viewModel.isLoading)
        XCTAssertNil(viewModel.error, "a cancelled connect is not a failure")
        XCTAssertNil(viewModel.insecurePrompt, "nothing is asked after a cancel")
        XCTAssertEqual(viewModel.host, "new.example")
        XCTAssertEqual(router.authState, stateBefore)
        XCTAssertEqual(stack.registry.activeServerId, Self.home.id)
        XCTAssertEqual(stack.registry.entries.map(\.id), [Self.home.id])
    }

    func testCancellingStopsBeforeTheNextAddress() async {
        let (probed, probes) = AsyncStream.makeStream(of: String.self)
        let viewModel = ServerSetupViewModel(
            checkServer: { url in
                probes.yield(url)
                guard url.hasPrefix("http://") else { throw URLError(.cannotConnectToHost) }
                // Never answers; ends only when the connect is cancelled.
                try await Task.sleep(for: .seconds(3600))
                throw URLError(.timedOut)
            },
            hasSession: { false },
            resolveBareName: { _ in nil }
        )
        viewModel.host = "new.example"
        let router = AppRouter()
        // HTTPS fails at once, and the person agrees to plain HTTP.
        await viewModel.connect(router: router)
        XCTAssertNotNil(viewModel.insecurePrompt)

        let connect = Task { await viewModel.confirmInsecure(router: router) }
        var urls = probed.makeAsyncIterator()
        var tried = [await urls.next(), await urls.next()]
        connect.cancel()
        await connect.value
        probes.finish()
        while let url = await urls.next() { tried.append(url) }

        XCTAssertEqual(tried, ["https://new.example", "http://new.example"])
        XCTAssertNil(viewModel.error, "a cancelled connect is not a failure")
        XCTAssertFalse(viewModel.isLoading)
    }

    func testAConnectCancelledBeforeItStartsAsksNothing() async {
        let viewModel = ServerSetupViewModel(
            checkServer: { _ in APIv2SetupStatus(needsSetup: false) },
            hasSession: { false },
            resolveBareName: { _ in nil }
        )
        // A found server on plain HTTP asks before anything is sent.
        let found = DiscoveredServer(serverId: "id", name: "Den", url: "http://192.168.1.5:8090", route: .localNetwork)

        let connect = Task { await viewModel.connect(to: found, router: AppRouter()) }
        connect.cancel()
        await connect.value

        XCTAssertNil(viewModel.insecurePrompt, "nothing is asked after a cancel")
        XCTAssertFalse(viewModel.isLoading)
    }

    func testACancelAfterTheServerAnsweredStillOpensSignIn() async {
        let (probed, probes) = AsyncStream.makeStream(of: String.self)
        let answered = StubURLProtocol.Gate()
        let viewModel = ServerSetupViewModel(
            checkServer: { url in
                probes.yield(url)
                // Past the point where the server is saved and made active,
                // which a cancel no longer interrupts.
                await Task { await answered.wait() }.value
                return APIv2SetupStatus(needsSetup: false)
            },
            hasSession: { false },
            resolveBareName: { _ in nil }
        )
        viewModel.host = "new.example"
        let router = AppRouter()

        let connect = Task { await viewModel.connect(router: router) }
        var urls = probed.makeAsyncIterator()
        _ = await urls.next()
        connect.cancel()
        await answered.open()
        await connect.value

        XCTAssertEqual(router.authState, .needsLogin)
        XCTAssertNil(viewModel.error)
    }

    // MARK: - Saving the server

    func testACheckCancelledBeforeTheServerAnswersSavesNothing() async throws {
        let stack = try await makeStack()
        stack.stub.hold(path: "/api/v2/system/setup")
        let service = stack.service

        let check = Task { try await service.checkServer(url: Self.newURL) }
        await stack.stub.waitUntilHeld()
        check.cancel()
        let result = await check.result

        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(stack.registry.activeServerId, Self.home.id)
        XCTAssertEqual(stack.registry.entries.map(\.id), [Self.home.id])
    }

    func testACheckCancelledBetweenSavingAndSwitchingStillMakesTheServerActive() async throws {
        let check = TaskBox()
        // The switch cancels in-flight requests on its way; the cancel lands there.
        let stack = try await makeStack(duringSwitch: { check.cancel() })
        let service = stack.service

        let task = Task { try await service.checkServer(url: Self.newURL) }
        check.set(task)
        let status = try await task.value

        XCTAssertFalse(status.needsSetup)
        XCTAssertEqual(stack.registry.activeServerId, Self.newID)
        XCTAssertEqual(stack.registry.entries.map(\.id), [Self.home.id, Self.newID])
    }

    func testACheckCancelledAfterTheSwitchStillReportsTheServerItMadeActive() async throws {
        let stack = try await makeStack()
        // The contract read comes after the switch.
        stack.stub.hold(path: APIv2Probe.path)
        let service = stack.service

        let check = Task { try await service.checkServer(url: Self.newURL) }
        await stack.stub.waitUntilHeld()
        XCTAssertEqual(stack.registry.activeServerId, Self.newID)
        check.cancel()
        stack.stub.release()
        let status = try await check.value

        XCTAssertFalse(status.needsSetup)
        XCTAssertEqual(stack.registry.activeServerId, Self.newID)
    }

    // MARK: - Fixture

    private struct Stack {
        let stub: APIv2TestStub
        let registry: ServerRegistry
        let service: AuthService
    }

    /// A registry with Home saved and active, and a service that reaches a
    /// stubbed server at any other address.
    private func makeStack(duringSwitch: (@Sendable () async -> Void)? = nil) async throws -> Stack {
        let previousTokenServerId = await TokenStore.shared.getActiveServerId()
        addTeardownBlock {
            await TokenStore.shared.switchActiveServer(serverId: previousTokenServerId)
        }
        let name = "ServerConnectCancellationTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        defaults.set(true, forKey: ServerRegistry.migratedKey)
        defaults.set(
            try JSONEncoder().encode(SavedRegistry(activeServerId: Self.home.id, entries: [Self.home])),
            forKey: ServerRegistry.defaultsKey
        )

        let stub = APIv2TestStub()
        stub.reply(path: "/api/v2/system/setup", 200, #"{"needs_setup":false,"wizard_completed":true}"#)
        stub.reply(path: ServerIdentity.brandingPath, 200,
            #"{"server_name":"New","login_subtitle":"","storage_available":false}"#)
        stub.reply(path: APIv2Probe.path, 200,
            #"{"server_version":"2.0.0","api_major":2,"contract_digest":"d","links":{"openapi":"/api/v2/openapi.json","capabilities":"/api/v2/capabilities"}}"#)
        let http = HTTPClient(session: stub.makeSession(), cancellationPassBarrier: duringSwitch)
        let registry = ServerRegistry(
            defaults: defaults,
            keychain: SharedKeychain(service: name, accessGroup: nil),
            launchPreferences: ProfileLaunchPreferences(defaults: defaults),
            persistenceOverride: { _, _ in true },
            httpClient: http
        )
        let service = AuthService(
            serverIdentityResolver: ServerIdentityResolver(httpClient: http),
            serverRegistry: registry,
            contractProbe: APIv2Probe(httpClient: http),
            apiV2Client: APIv2Client(http: http, isUpdateRequired: { false }),
            httpClient: http
        )
        return Stack(stub: stub, registry: registry, service: service)
    }
}

/// The registry's saved shape.
private struct SavedRegistry: Encodable {
    var activeServerId: String?
    var entries: [ServerEntry]
}

/// A task that is cancelled from a place that cannot hold it yet.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<APIv2SetupStatus, Error>?

    func set(_ task: Task<APIv2SetupStatus, Error>) {
        lock.withLock { self.task = task }
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }
}
