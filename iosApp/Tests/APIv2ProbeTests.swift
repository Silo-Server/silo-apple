import Foundation
import XCTest
@testable import Silo

/// The v2 contract probe against a stubbed transport: only a valid info
/// document is `.v2`, only the legacy listener's plain 404 is
/// `.updateServer`, and everything else stays its own failure.
final class APIv2ProbeTests: XCTestCase {
    private let serverURL = "https://probe.example"

    override func setUp() {
        super.setUp()
        APIv2StubProtocol.reset()
    }

    override func tearDown() {
        APIv2StubProtocol.reset()
        super.tearDown()
    }

    private func probe() -> APIv2Probe {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIv2StubProtocol.self]
        return APIv2Probe(httpClient: HTTPClient(session: URLSession(configuration: configuration)))
    }

    private func run(_ reply: APIv2StubProtocol.Reply) async -> APIv2ProbeResult {
        APIv2StubProtocol.configure([APIv2Probe.path: reply])
        let result = await probe().probe(serverURL: serverURL)
        XCTAssertEqual(APIv2StubProtocol.requestedPaths(), [APIv2Probe.path], "the probe is a single request")
        return result
    }

    private static let validInfo = """
    {"server_version":"abc123","api_major":2,"contract_digest":"d",
     "links":{"openapi":"/api/v2/openapi.json","capabilities":"/api/v2/capabilities"}}
    """

    func testValidInfoIsV2() async {
        let result = await run(.response(200, Self.validInfo, "application/json"))
        guard case .v2(let info) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(info.apiMajor, 2)
        XCTAssertEqual(info.serverVersion, "abc123")
        XCTAssertEqual(APIv2StubProtocol.acceptHeaders(), ["application/json"])
    }

    func testValidInfoFixtureIsV2() async throws {
        let body = try String(
            contentsOf: APIv2FixtureTestSupport.fixtureURL(named: "get_system_info_ok", bundleClass: Self.self),
            encoding: .utf8
        )
        let result = await run(.response(200, body, "application/json"))
        guard case .v2 = result else { return XCTFail("\(result)") }
    }

    func testLegacyPlain404IsUpdateServer() async {
        let result = await run(.response(404, "404 page not found\n", "text/plain; charset=utf-8"))
        XCTAssertEqual(result, .updateServer)
    }

    func testHTML404IsNotUpdateServer() async {
        // A proxy's 404 page proves nothing about which Silo answered.
        let result = await run(.response(404, "<html><body>Not Found</body></html>", "text/html"))
        XCTAssertEqual(result, .failure(.httpStatus(404)))
    }

    func testProblem404IsNotUpdateServer() async throws {
        let body = try String(
            contentsOf: APIv2FixtureTestSupport.fixtureURL(named: "not_found", bundleClass: Self.self),
            encoding: .utf8
        )
        // A v2 server's own problem 404 means the path is wrong, not the server old.
        let result = await run(.response(404, body, "application/problem+json"))
        XCTAssertEqual(result, .failure(.httpStatus(404)))
    }

    func testHTML200IsMalformedNotUpdateServer() async {
        let result = await run(.response(200, "<html><body>Sign in</body></html>", "text/html"))
        XCTAssertEqual(result, .failure(.malformedResponse))
    }

    func testMalformedJSONIsMalformed() async {
        let result = await run(.response(200, #"{"server_version": "x", "api_major": "#, "application/json"))
        XCTAssertEqual(result, .failure(.malformedResponse))
    }

    func testMissingMemberIsMalformed() async {
        let result = await run(.response(200, #"{"server_version":"x","api_major":2}"#, "application/json"))
        XCTAssertEqual(result, .failure(.malformedResponse))
    }

    func testWrongMajorIsUnexpectedContract() async {
        let body = Self.validInfo.replacingOccurrences(of: "\"api_major\":2", with: "\"api_major\":3")
        let result = await run(.response(200, body, "application/json"))
        XCTAssertEqual(result, .failure(.unexpectedContract(apiMajor: 3)))
    }

    func test401IsHTTPStatus() async {
        let result = await run(.response(401, #"{"type":"x","title":"t","status":401,"detail":"d"}"#, "application/problem+json"))
        XCTAssertEqual(result, .failure(.httpStatus(401)))
    }

    func test429IsHTTPStatus() async {
        let result = await run(.response(429, "", "text/plain"))
        XCTAssertEqual(result, .failure(.httpStatus(429)))
    }

    func test500IsHTTPStatus() async {
        let result = await run(.response(500, "<html>502</html>", "text/html"))
        XCTAssertEqual(result, .failure(.httpStatus(500)))
    }

    func testTimeoutIsTimeout() async {
        let result = await run(.error(URLError(.timedOut)))
        XCTAssertEqual(result, .failure(.timeout))
    }

    func testTLSFailureIsTLS() async {
        let result = await run(.error(URLError(.secureConnectionFailed)))
        XCTAssertEqual(result, .failure(.tls))
    }

    func testConnectionRefusedIsTransport() async {
        let result = await run(.error(URLError(.cannotConnectToHost)))
        XCTAssertEqual(result, .failure(.transport))
    }

    func testLegacyNotFoundRule() {
        XCTAssertTrue(APIv2Probe.isLegacyNotFound(body: "404 page not found\n"))
        XCTAssertTrue(APIv2Probe.isLegacyNotFound(body: "404 page not found"))
        XCTAssertFalse(APIv2Probe.isLegacyNotFound(body: nil))
        XCTAssertFalse(APIv2Probe.isLegacyNotFound(body: ""))
        XCTAssertFalse(APIv2Probe.isLegacyNotFound(body: "<h1>404 page not found</h1>"))
        // Only the single trailing newline Go writes is tolerated.
        XCTAssertFalse(APIv2Probe.isLegacyNotFound(body: " 404 page not found"))
        XCTAssertFalse(APIv2Probe.isLegacyNotFound(body: "\n404 page not found\n"))
        XCTAssertFalse(APIv2Probe.isLegacyNotFound(body: "404 page not found\n\n"))
        XCTAssertFalse(APIv2Probe.isLegacyNotFound(body: "404 page not found \n"))
    }

    // MARK: State

    @MainActor
    func testConnectionMonitorRecordsOnlyContractEvidence() {
        let monitor = ConnectionMonitor.shared
        let previousProvider = monitor.activeServerIdProvider
        addTeardownBlock { @MainActor in
            monitor.activeServerIdProvider = previousProvider
            monitor.resetContractStatus()
        }
        monitor.activeServerIdProvider = { "server-a" }
        monitor.resetContractStatus()
        XCTAssertEqual(monitor.contractStatus, .unknown)
        monitor.noteContractProbe(.failure(.timeout), serverId: "server-a")
        XCTAssertEqual(monitor.contractStatus, .unknown, "a timeout is not contract evidence")
        monitor.noteContractProbe(.updateServer, serverId: "server-a")
        XCTAssertTrue(monitor.isServerUpdateRequired)
        monitor.noteContractProbe(.failure(.httpStatus(500)), serverId: "server-a")
        XCTAssertTrue(monitor.isServerUpdateRequired, "a later 5xx does not clear the verdict")
        monitor.resetContractStatus()
        XCTAssertFalse(monitor.isServerUpdateRequired)
    }

    // MARK: No v1 replay

    /// A failed v2 mutation is not replayed against `/api/v1`.
    func testFailedUpdateProfileIsNotRetriedAgainstV1() async throws {
        let suiteName = "apiv2-no-replay-\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        let tokenStore = TokenStore(
            keychain: SharedKeychain(service: "APIv2ProbeTests.\(UUID().uuidString)", accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokenStore.switchActiveServer(serverId: "server-v2")
        await tokenStore.setServerUrl("http://apiv2-test.invalid")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIv2StubProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration), tokenStore: tokenStore)
        let api = SiloAPI(
            http: http,
            tokenStore: tokenStore,
            v2: APIv2Client(http: http, isUpdateRequired: { false })
        )

        let problem = try String(
            contentsOf: APIv2FixtureTestSupport.fixtureURL(named: "update_profile_null_not_clearable", bundleClass: Self.self),
            encoding: .utf8
        )
        APIv2StubProtocol.configure(["/api/v2/profiles/p-1": .response(422, problem, "application/problem+json")])

        var body = UpdateProfileBody()
        body.subtitleMode = "off"
        do {
            try await api.updateProfile(profileId: "p-1", body: body)
            XCTFail("expected the 422 to surface")
        } catch APIv2Error.problem(let decoded) {
            XCTAssertEqual(decoded.identifier, "validation_failed")
        }

        let paths = APIv2StubProtocol.requestedPaths()
        XCTAssertEqual(paths, ["/api/v2/profiles/p-1"], "exactly one v2 request, no replay")
        XCTAssertFalse(paths.contains { $0.hasPrefix("/api/v1") })
        XCTAssertEqual(APIv2StubProtocol.methods(), ["PATCH"])
    }

    func testUpdateServerStateBlocksPilotCalls() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIv2StubProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration))
        let client = APIv2Client(http: http, isUpdateRequired: { true })
        do {
            _ = try await client.currentUser()
            XCTFail("expected refusal")
        } catch APIv2Error.serverUpdateRequired {
            XCTAssertEqual(APIv2StubProtocol.requestedPaths(), [], "no request leaves the device")
        }
    }

    /// The active server's verdict must not block probing a different,
    /// explicit-URL candidate; otherwise an updated server could never be
    /// added while the active one is update-required.
    func testUpdateServerStateDoesNotBlockCandidateSetupStatus() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [APIv2StubProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration))
        let client = APIv2Client(http: http, isUpdateRequired: { true })
        APIv2StubProtocol.configure([
            "/api/v2/system/setup": .response(200, #"{"needs_setup":true}"#, "application/json"),
        ])

        let status = try await client.setupStatus(serverURL: serverURL)

        XCTAssertTrue(status.needsSetup)
        XCTAssertEqual(APIv2StubProtocol.requestedPaths(), ["/api/v2/system/setup"], "the candidate is contacted")
    }
}

final class APIv2StubProtocol: URLProtocol {
    enum Reply {
        case response(Int, String, String)
        case error(URLError)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [String: Reply] = [:]
    nonisolated(unsafe) private static var requests: [URLRequest] = []

    static func configure(_ configured: [String: Reply]) {
        lock.withLock {
            replies = configured
            requests = []
        }
    }

    static func reset() { configure([:]) }

    static func requestedPaths() -> [String] {
        lock.withLock { requests.compactMap { $0.url?.path } }
    }

    static func methods() -> [String] {
        lock.withLock { requests.compactMap(\.httpMethod) }
    }

    static func acceptHeaders() -> [String] {
        lock.withLock { requests.compactMap { $0.value(forHTTPHeaderField: "Accept") } }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let reply = Self.lock.withLock {
            Self.requests.append(request)
            return Self.replies[url.path] ?? .response(500, "unexpected", "text/plain")
        }
        switch reply {
        case .error(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .response(let status, let body, let contentType):
            guard let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil,
                headerFields: ["Content-Type": contentType]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
