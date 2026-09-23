import XCTest
@testable import Silo

final class ServerIdentityResolverTests: XCTestCase {
    private var stub = ServerIdentityStub()

    override func setUp() {
        super.setUp()
        stub = ServerIdentityStub()
    }

    private static let brandingPath = "/api/v2/theme/branding"

    private static func branding(name: String) -> String {
        #"{"server_name":"\#(name)","login_subtitle":"","storage_available":false}"#
    }

    func testReadsTrimmedNameFromV2Branding() async {
        stub.configure([
            Self.brandingPath: (200, Self.branding(name: "  Home Silo  ")),
        ])

        let name = await resolver().fetchServerName(serverURL: "https://silo.example")

        XCTAssertEqual(name, "Home Silo")
        XCTAssertEqual(stub.requestedPaths(), [Self.brandingPath])
    }

    /// Blank names, failures, malformed bodies and a v1-only server's legacy
    /// 404 all leave the stored name alone, and none of them falls back to
    /// another endpoint.
    func testUnusableBrandingReturnsNilWithoutFallback() async {
        let cases: [(String, StubURLProtocol.Response)] = [
            ("blank name", .json(Self.branding(name: "  "))),
            ("server error", .json(#"{"type":"about:blank","title":"x","status":500,"detail":""}"#, status: 500)),
            ("malformed", .json(#"{"server_name":42}"#)),
            ("v1-only server", .text("404 page not found\n", status: 404, contentType: "text/plain")),
        ]
        for (name, response) in cases {
            stub.handler.reset()
            stub.handler.route(StubURLProtocol.path(Self.brandingPath)) { _ in response }

            let fetched = await resolver().fetchServerName(serverURL: "https://silo.example")

            XCTAssertNil(fetched, name)
            XCTAssertEqual(stub.requestedPaths(), [Self.brandingPath], name)
        }
    }

    func testStaleActiveServerResponseDoesNotRenameRegistryEntries() async {
        let previousTokenServerId = await TokenStore.shared.getActiveServerId()
        let suiteName = "ServerIdentityResolverTests.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: suiteName) else {
            XCTFail("Failed to create isolated defaults suite")
            return
        }
        defer { suite.removePersistentDomain(forName: suiteName) }

        let registry = ServerRegistry(
            defaults: SharedDefaults(suite: suite, standard: suite),
            keychain: SharedKeychain(service: suiteName)
        )
        let serverA = ServerEntry(
            id: ServerRegistry.serverId(for: "https://a.example"),
            url: "https://a.example",
            fetchedName: "Server A",
            profileId: nil,
            lastUsedAt: .now
        )
        let serverB = ServerEntry(
            id: ServerRegistry.serverId(for: "https://b.example"),
            url: "https://b.example",
            fetchedName: "Server B",
            profileId: nil,
            lastUsedAt: .now
        )
        registry.addOrUpdate(serverA)
        registry.addOrUpdate(serverB)
        await registry.switchTo(serverId: serverA.id)

        stub.configure([
            Self.brandingPath: (200, Self.branding(name: "Updated A")),
        ], blockedPaths: [Self.brandingPath])
        defer { stub.release(path: Self.brandingPath) }

        let service = AuthService(
            serverIdentityResolver: resolver(),
            serverRegistry: registry
        )
        let refresh = Task { await service.refreshActiveServerName() }
        await waitForRequest(path: Self.brandingPath)

        await registry.switchTo(serverId: serverB.id)
        stub.release(path: Self.brandingPath)
        await refresh.value

        XCTAssertEqual(registry.activeServerId, serverB.id)
        XCTAssertEqual(registry.entry(with: serverA.id)?.fetchedName, "Server A")
        XCTAssertEqual(registry.entry(with: serverB.id)?.fetchedName, "Server B")
        await TokenStore.shared.switchActiveServer(serverId: previousTokenServerId)
    }

    // MARK: - Deployment identity

    func testProbeReportsIdentityAtAnyAddress() async {
        stub.configure([
            "/api/v2/system/identity": (200, #"{"server_id":"96c1bd08-b839-4d47-980e-57d4e7a44cfa"}"#),
        ])

        let result = await resolver().probeIdentity(serverURL: "https://silo.overlay.example/")

        XCTAssertEqual(result, .identity("96c1bd08-b839-4d47-980e-57d4e7a44cfa"))
        let fetched = await resolver().fetchServerIdentity(serverURL: "https://silo.overlay.example")
        XCTAssertEqual(fetched, "96c1bd08-b839-4d47-980e-57d4e7a44cfa")
    }

    func testLegacy404IsReachableButUnsupported() async {
        stub.handler.reset()
        stub.handler.route(StubURLProtocol.path("/api/v2/system/identity")) { _ in
            .text("404 page not found\n", status: 404, contentType: "text/plain")
        }

        let result = await resolver().probeIdentity(serverURL: "https://silo.example")

        XCTAssertEqual(result, .unsupportedServer)
    }

    func testProxy404AndTransportFailuresAreUnreachable() async {
        stub.configure([
            "/api/v2/system/identity": (404, "<html>nope</html>"),
        ])
        let proxy = await resolver().probeIdentity(serverURL: "https://silo.example")
        XCTAssertEqual(proxy, .unreachable)

        stub.handler.reset()
        stub.handler.route(StubURLProtocol.any) { _ in throw URLError(.cannotConnectToHost) }
        let transport = await resolver().probeIdentity(serverURL: "https://silo.example")
        XCTAssertEqual(transport, .unreachable)
        let fetched = await resolver().fetchServerIdentity(serverURL: "https://silo.example")
        XCTAssertNil(fetched)
    }

    func testConnectionsUsesTheSuppliedBearerAndRequiresAvailability() async {
        stub.configure([
            "/api/v2/system/connections": (200, #"{"revision":"r","state":"available","allowed":true,"server_id":"S","current":{"kind":"provider","provider":"tailscale"},"endpoints":[{"kind":"public","url":"https://silo.example"}]}"#),
        ])

        let document = await resolver().fetchConnections(serverURL: "https://silo.example", bearer: "TOKEN")

        XCTAssertEqual(document?.serverId, "S")
        XCTAssertEqual(document?.current?.provider, "tailscale")
        XCTAssertEqual(stub.handler.requests.first?.header("Authorization"), "Bearer TOKEN")

        stub.configure([
            "/api/v2/system/connections": (200, #"{"state":"not_configured","allowed":true,"server_id":"S","endpoints":[]}"#),
        ])
        let unavailable = await resolver().fetchConnections(serverURL: "https://silo.example", bearer: "TOKEN")
        XCTAssertNil(unavailable)
    }

    private func resolver() -> ServerIdentityResolver {
        ServerIdentityResolver(
            httpClient: HTTPClient(session: stub.handler.makeSession())
        )
    }

    private func waitForRequest(path: String) async {
        do {
            try await stub.handler.waitForRequest(where: StubURLProtocol.path(path))
        } catch {
            XCTFail("Timed out waiting for request: \(path)")
        }
    }
}

/// Path-keyed replies on the shared stub. A blocked path stalls its reply on
/// a gate until `release(path:)` opens it.
private final class ServerIdentityStub: @unchecked Sendable {
    let handler = StubURLProtocol.Handler()
    private let lock = NSLock()
    private var gates: [String: StubURLProtocol.Gate] = [:]

    func configure(
        _ responses: [String: (status: Int, body: String)],
        blockedPaths: Set<String> = []
    ) {
        handler.reset()
        lock.withLock {
            gates = Dictionary(uniqueKeysWithValues: blockedPaths.map { ($0, StubURLProtocol.Gate()) })
        }
        for (path, response) in responses {
            handler.route(StubURLProtocol.path(path)) { [weak self] _ in
                if let gate = self?.lock.withLock({ self?.gates[path] }) {
                    await gate.wait()
                }
                return .json(response.body, status: response.status)
            }
        }
        handler.route(StubURLProtocol.any) { _ in
            .json(#"{"error":"unexpected"}"#, status: 500)
        }
    }

    func requestedPaths() -> [String] {
        handler.requests.map(\.path)
    }

    func release(path: String) {
        guard let gate = lock.withLock({ gates[path] }) else { return }
        Task { await gate.open() }
    }
}
