import Foundation
import XCTest
@testable import Silo

/// The v2 contract probe against the shared stub: only a valid info document
/// is `.v2`, only the legacy listener's plain 404 is `.updateServer`, and
/// everything else stays its own failure.
final class APIv2ProbeTests: XCTestCase {
    private let serverURL = "https://probe.example"
    private var stub = APIv2TestStub()

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func probe() -> APIv2Probe {
        APIv2Probe(httpClient: HTTPClient(session: stub.makeSession()))
    }

    private func run(_ reply: APIv2TestStub.Reply) async -> APIv2ProbeResult {
        stub.reply(reply)
        let result = await probe().probe(serverURL: serverURL)
        XCTAssertEqual(stub.requestedPaths, [APIv2Probe.path], "the probe is a single request")
        return result
    }

    private static let validInfo = """
    {"server_version":"abc123","api_major":2,"contract_digest":"d",
     "links":{"openapi":"/api/v2/openapi.json","capabilities":"/api/v2/capabilities"}}
    """

    func testValidInfoIsV2() async {
        let result = await run(.json(200, Self.validInfo))
        guard case .v2(let info) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(info.apiMajor, 2)
        XCTAssertEqual(info.serverVersion, "abc123")
        XCTAssertEqual(stub.requests.map { $0.header("accept") }, ["application/json"])
    }

    func testValidInfoFixtureIsV2() async throws {
        let body = try String(
            contentsOf: APIv2FixtureTestSupport.fixtureURL(named: "get_system_info_ok", bundleClass: Self.self),
            encoding: .utf8
        )
        let result = await run(.json(200, body))
        guard case .v2 = result else { return XCTFail("\(result)") }
    }

    func testLegacyPlain404IsUpdateServer() async {
        let result = await run(.text(404, "404 page not found\n", contentType: "text/plain; charset=utf-8"))
        XCTAssertEqual(result, .updateServer)
    }

    func testHTML404IsNotUpdateServer() async {
        // A proxy's 404 page proves nothing about which Silo answered.
        let result = await run(.text(404, "<html><body>Not Found</body></html>", contentType: "text/html"))
        XCTAssertEqual(result, .failure(.httpStatus(404)))
    }

    func testProblem404IsNotUpdateServer() async throws {
        let body = try String(
            contentsOf: APIv2FixtureTestSupport.fixtureURL(named: "not_found", bundleClass: Self.self),
            encoding: .utf8
        )
        // A v2 server's own problem 404 means the path is wrong, not the server old.
        let result = await run(.json(404, body))
        XCTAssertEqual(result, .failure(.httpStatus(404)))
    }

    func testHTML200IsMalformedNotUpdateServer() async {
        let result = await run(.text(200, "<html><body>Sign in</body></html>", contentType: "text/html"))
        XCTAssertEqual(result, .failure(.malformedResponse))
    }

    func testMalformedJSONIsMalformed() async {
        let result = await run(.json(200, #"{"server_version": "x", "api_major": "#))
        XCTAssertEqual(result, .failure(.malformedResponse))
    }

    func testMissingMemberIsMalformed() async {
        let result = await run(.json(200, #"{"server_version":"x","api_major":2}"#))
        XCTAssertEqual(result, .failure(.malformedResponse))
    }

    func testWrongMajorIsUnexpectedContract() async {
        let body = Self.validInfo.replacingOccurrences(of: "\"api_major\":2", with: "\"api_major\":3")
        let result = await run(.json(200, body))
        XCTAssertEqual(result, .failure(.unexpectedContract(apiMajor: 3)))
    }

    func test401IsHTTPStatus() async {
        let result = await run(.json(401, #"{"type":"x","title":"t","status":401,"detail":"d"}"#))
        XCTAssertEqual(result, .failure(.httpStatus(401)))
    }

    func test429IsHTTPStatus() async {
        let result = await run(.text(429, "", contentType: "text/plain"))
        XCTAssertEqual(result, .failure(.httpStatus(429)))
    }

    func test500IsHTTPStatus() async {
        let result = await run(.text(500, "<html>502</html>", contentType: "text/html"))
        XCTAssertEqual(result, .failure(.httpStatus(500)))
    }

    func testTimeoutIsTimeout() async {
        let result = await run(.failure(URLError(.timedOut)))
        XCTAssertEqual(result, .failure(.timeout))
    }

    func testTLSFailureIsTLS() async {
        let result = await run(.failure(URLError(.secureConnectionFailed)))
        XCTAssertEqual(result, .failure(.tls))
    }

    func testConnectionRefusedIsTransport() async {
        let result = await run(.failure(URLError(.cannotConnectToHost)))
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
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokenStore)
        let client = APIv2Client(http: http, tokenStore: tokenStore, isUpdateRequired: { false })

        let problem = try String(
            contentsOf: APIv2FixtureTestSupport.fixtureURL(named: "update_profile_null_not_clearable", bundleClass: Self.self),
            encoding: .utf8
        )
        stub.reply(path: "/api/v2/profiles/p-1", 422, problem)

        var body = UpdateProfileBody()
        body.subtitleMode = "off"
        do {
            _ = try await client.updateProfile(id: "p-1", patch: body.asAPIv2Patch)
            XCTFail("expected the 422 to surface")
        } catch APIv2Error.problem(let decoded) {
            XCTAssertEqual(decoded.identifier, "validation_failed")
        }

        let paths = stub.requestedPaths
        XCTAssertEqual(paths, ["/api/v2/profiles/p-1"], "exactly one v2 request, no replay")
        XCTAssertFalse(paths.contains { $0.hasPrefix("/api/v1") })
        XCTAssertEqual(stub.methods, ["PATCH"])
    }

    func testUpdateServerStateBlocksPilotCalls() async throws {
        let http = HTTPClient(session: stub.makeSession())
        let client = APIv2Client(http: http, isUpdateRequired: { true })
        do {
            _ = try await client.currentUser()
            XCTFail("expected refusal")
        } catch APIv2Error.serverUpdateRequired {
            XCTAssertEqual(stub.requestedPaths, [], "no request leaves the device")
        }
    }

    /// The active server's verdict must not block probing a different,
    /// explicit-URL candidate; otherwise an updated server could never be
    /// added while the active one is update-required.
    func testUpdateServerStateDoesNotBlockCandidateSetupStatus() async throws {
        let http = HTTPClient(session: stub.makeSession())
        let client = APIv2Client(http: http, isUpdateRequired: { true })
        stub.reply(path: "/api/v2/system/setup", 200, #"{"needs_setup":true}"#)

        let status = try await client.setupStatus(serverURL: serverURL)

        XCTAssertTrue(status.needsSetup)
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/system/setup"], "the candidate is contacted")
    }
}
