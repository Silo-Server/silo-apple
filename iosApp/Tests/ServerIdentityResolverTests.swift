import XCTest
@testable import Silo

final class ServerIdentityResolverTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ServerIdentityStubProtocol.reset()
    }

    func testPrefersNativeBrandingName() async {
        ServerIdentityStubProtocol.configure([
            "/api/v1/theme/branding": (200, #"{"server_name":"  Home Silo  "}"#),
            "/api/v1/health": (200, #"{"status":"ok","server_name":"StreamApp"}"#),
        ])

        let name = await resolver().fetchServerName(serverURL: "https://silo.example")

        XCTAssertEqual(name, "Home Silo")
        XCTAssertEqual(ServerIdentityStubProtocol.requestedPaths(), ["/api/v1/theme/branding"])
    }

    func testFallsBackToHealthForOlderServer() async {
        ServerIdentityStubProtocol.configure([
            "/api/v1/theme/branding": (404, #"{"error":"not_found"}"#),
            "/api/v1/health": (200, #"{"status":"ok","server_name":"Legacy Home"}"#),
        ])

        let name = await resolver().fetchServerName(serverURL: "https://silo.example")

        XCTAssertEqual(name, "Legacy Home")
        XCTAssertEqual(
            ServerIdentityStubProtocol.requestedPaths(),
            ["/api/v1/theme/branding", "/api/v1/health"]
        )
    }

    func testBlankBrandingNameFallsBackToHealth() async {
        ServerIdentityStubProtocol.configure([
            "/api/v1/theme/branding": (200, #"{"server_name":"  "}"#),
            "/api/v1/health": (200, #"{"status":"ok","server_name":"Fallback"}"#),
        ])

        let name = await resolver().fetchServerName(serverURL: "https://silo.example")

        XCTAssertEqual(name, "Fallback")
    }

    func testBrandingFailureDoesNotFallBackToHealth() async {
        ServerIdentityStubProtocol.configure([
            "/api/v1/theme/branding": (500, #"{"error":"unavailable"}"#),
            "/api/v1/health": (200, #"{"status":"ok","server_name":"Compat Name"}"#),
        ])

        let name = await resolver().fetchServerName(serverURL: "https://silo.example")

        XCTAssertNil(name)
        XCTAssertEqual(ServerIdentityStubProtocol.requestedPaths(), ["/api/v1/theme/branding"])
    }

    func testBrandingDecodeFailureDoesNotFallBackToHealth() async {
        ServerIdentityStubProtocol.configure([
            "/api/v1/theme/branding": (200, #"{"server_name":42}"#),
            "/api/v1/health": (200, #"{"status":"ok","server_name":"Compat Name"}"#),
        ])

        let name = await resolver().fetchServerName(serverURL: "https://silo.example")

        XCTAssertNil(name)
        XCTAssertEqual(ServerIdentityStubProtocol.requestedPaths(), ["/api/v1/theme/branding"])
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

        ServerIdentityStubProtocol.configure([
            "/api/v1/theme/branding": (200, #"{"server_name":"Updated A"}"#),
        ], blockedPaths: ["/api/v1/theme/branding"])
        defer { ServerIdentityStubProtocol.release(path: "/api/v1/theme/branding") }

        let service = AuthService(
            serverIdentityResolver: resolver(),
            serverRegistry: registry
        )
        let refresh = Task { await service.refreshActiveServerName() }
        await waitForRequest(path: "/api/v1/theme/branding")

        await registry.switchTo(serverId: serverB.id)
        ServerIdentityStubProtocol.release(path: "/api/v1/theme/branding")
        await refresh.value

        XCTAssertEqual(registry.activeServerId, serverB.id)
        XCTAssertEqual(registry.entry(with: serverA.id)?.fetchedName, "Server A")
        XCTAssertEqual(registry.entry(with: serverB.id)?.fetchedName, "Server B")
        await TokenStore.shared.switchActiveServer(serverId: previousTokenServerId)
    }

    private func resolver() -> ServerIdentityResolver {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServerIdentityStubProtocol.self]
        return ServerIdentityResolver(
            httpClient: HTTPClient(session: URLSession(configuration: configuration))
        )
    }

    private func waitForRequest(path: String) async {
        for _ in 0..<100 {
            if ServerIdentityStubProtocol.requestedPaths().contains(path) {
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for request: \(path)")
    }
}

private final class ServerIdentityStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static let responseCondition = NSCondition()
    nonisolated(unsafe) private static var responses: [String: (status: Int, body: String)] = [:]
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var blockedPaths: Set<String> = []
    nonisolated(unsafe) private static var releasedPaths: Set<String> = []

    static func configure(
        _ configuredResponses: [String: (status: Int, body: String)],
        blockedPaths configuredBlockedPaths: Set<String> = []
    ) {
        lock.withLock {
            responses = configuredResponses
            paths = []
        }
        responseCondition.withLock {
            blockedPaths = configuredBlockedPaths
            releasedPaths = []
        }
    }

    static func requestedPaths() -> [String] {
        lock.withLock { paths }
    }

    static func reset() {
        lock.withLock {
            responses = [:]
            paths = []
        }
        responseCondition.withLock {
            blockedPaths = []
            releasedPaths = []
            responseCondition.broadcast()
        }
    }

    static func release(path: String) {
        responseCondition.withLock {
            releasedPaths.insert(path)
            responseCondition.broadcast()
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let response = Self.lock.withLock {
            Self.paths.append(url.path)
            return Self.responses[url.path] ?? (500, #"{"error":"unexpected"}"#)
        }
        Self.responseCondition.withLock {
            while Self.blockedPaths.contains(url.path),
                  !Self.releasedPaths.contains(url.path) {
                Self.responseCondition.wait()
            }
        }

        guard let httpResponse = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: httpResponse, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
