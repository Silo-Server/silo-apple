import Foundation
import XCTest
@testable import Silo

/// The explicit-URL pairing client on the v2 wire. These calls skip
/// `APIv2Client` and its recorded probe verdict, so this client has to tell a
/// v1-only server's legacy 404 apart from a v2 problem itself, and it must
/// dispatch each request once.
final class PairingDeviceAPITests: XCTestCase {
    private let server = "https://pair.example"
    private var stub = StubURLProtocol.Handler()

    override func setUp() {
        super.setUp()
        stub = StubURLProtocol.Handler()
    }

    private func api() -> PairingDeviceAPI {
        PairingDeviceAPI(session: stub.makeSession())
    }

    private func json(_ request: StubURLProtocol.Request) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
    }

    func testReceiverStartAndPollArePublicV2Requests() async throws {
        stub.route(StubURLProtocol.method("POST", path: "/api/v2/auth/device/start")) { _ in
            .json(Self.start, status: 201)
        }
        stub.route(StubURLProtocol.method("POST", path: "/api/v2/auth/device/poll")) { _ in
            .json(Self.approvedPoll)
        }
        let started = try await api().start(serverURL: server, deviceName: "Living room TV", devicePlatform: "tvos")
        XCTAssertEqual(started.deviceCode, "dev-1")
        XCTAssertEqual(started.matchCode, "42")
        let poll = try await api().poll(serverURL: server, deviceCode: started.deviceCode)
        XCTAssertEqual(poll.tokens?.accessToken, "acc")
        XCTAssertEqual(poll.tokens?.user.id, "1")

        let requests = stub.requests
        XCTAssertEqual(requests.map(\.path), ["/api/v2/auth/device/start", "/api/v2/auth/device/poll"])
        XCTAssertTrue(requests.allSatisfy { $0.header("authorization") == nil })
        let startBody = try json(requests[0])
        XCTAssertEqual(startBody["device_name"] as? String, "Living room TV")
        XCTAssertEqual(startBody["device_platform"] as? String, "tvos")
        XCTAssertNil(startBody["client_purpose"], "an unset member is omitted, never sent as null")
        XCTAssertEqual(try json(requests[1])["device_code"] as? String, "dev-1")
    }

    func testStartRequiresCreated() async {
        stub.route(StubURLProtocol.any) { _ in .json(Self.start, status: 200) }
        do {
            _ = try await api().start(serverURL: server, deviceName: "TV", devicePlatform: "tvos")
            XCTFail("start answers 201")
        } catch APIv2Error.incompleteAuthResponse {
        } catch {
            XCTFail("Unexpected \(error)")
        }
    }

    func testRemotePlaybackStartRequestsATemporarySession() async throws {
        stub.route(StubURLProtocol.any) { _ in .json(Self.start, status: 201) }
        _ = try await api().startRemotePlayback(serverURL: server, deviceName: "TV", devicePlatform: "tvos")
        let body = try json(XCTUnwrap(stub.requests.first))
        XCTAssertEqual(body["client_purpose"] as? String, "remote_playback")
        XCTAssertEqual(body["temporary"] as? Bool, true)
    }

    /// Go's plain 404 on a v2 path can only be a v1-only server's legacy
    /// listener. A v2 404 problem is an ordinary missing request.
    func testLegacyNotFoundIsUpdateRequiredButAProblem404IsNot() async throws {
        stub.expect(StubURLProtocol.any) { _ in .text("404 page not found\n", status: 404) }
        do {
            _ = try await api().poll(serverURL: server, deviceCode: "dev-1")
            XCTFail("a legacy 404 is not a poll answer")
        } catch {
            XCTAssertEqual(UpdateRequirement(error), .server)
        }

        stub.expect(StubURLProtocol.any) { _ in
            Self.problem(404, "not_found")
        }
        do {
            _ = try await api().poll(serverURL: server, deviceCode: "dev-1")
            XCTFail("a missing request is not a poll answer")
        } catch APIv2Error.problem(let problem) {
            XCTAssertEqual(problem.status, 404)
            XCTAssertNil(UpdateRequirement(APIv2Error.problem(problem)))
        }

        stub.expect(StubURLProtocol.any) { _ in .text("<html>not found</html>", status: 404, contentType: "text/html") }
        do {
            _ = try await api().poll(serverURL: server, deviceCode: "dev-1")
            XCTFail("a proxy 404 is not a poll answer")
        } catch APIv2Error.httpStatus(404) {}
    }

    func testClientUpgradeRequiredMapsToTheAppUpdate() async {
        stub.route(StubURLProtocol.any) { _ in Self.problem(410, "client_upgrade_required") }
        do {
            _ = try await api().start(serverURL: server, deviceName: "TV", devicePlatform: "tvos")
            XCTFail("410 is not a start answer")
        } catch {
            XCTAssertEqual(UpdateRequirement(error), .app)
        }
    }

    func testCompanionLookupAndApproveCarryTheChosenServersBearer() async throws {
        stub.route(StubURLProtocol.method("GET", path: "/api/v2/auth/device")) { _ in .json(Self.lookup) }
        stub.route(StubURLProtocol.method("POST", path: "/api/v2/auth/device/approve")) { _ in
            .json(#"{"status":"approved"}"#)
        }
        let lookup = try await api().lookup(serverURL: server, bearer: "chosen", userCode: "ABCD-1234")
        XCTAssertEqual(lookup.matchCode, "42")
        try await api().approve(serverURL: server, bearer: "chosen", userCode: "ABCD-1234")

        let requests = stub.requests
        XCTAssertEqual(requests.map(\.path), ["/api/v2/auth/device", "/api/v2/auth/device/approve"])
        XCTAssertEqual(requests[0].query, ["code": "ABCD-1234"])
        XCTAssertEqual(requests.map { $0.header("authorization") }, ["Bearer chosen", "Bearer chosen"])
        XCTAssertEqual(try json(requests[1]) as NSDictionary, ["code": "ABCD-1234"])
    }

    /// Approve is dispatched once: a conflict, an expiry or a lost answer is
    /// reported, never re-sent.
    func testApproveIsSentOnce() async throws {
        for reply in [Self.problem(409, "conflict"), Self.problem(410, "device_login_expired")] {
            stub.reset()
            stub.route(StubURLProtocol.any) { _ in reply }
            do {
                try await api().approve(serverURL: server, bearer: "chosen", userCode: "ABCD-1234")
                XCTFail("a \(reply.status) is not an approval")
            } catch APIv2Error.problem(let problem) {
                XCTAssertEqual(problem.status, reply.status)
                XCTAssertNil(UpdateRequirement(APIv2Error.problem(problem)), "an expired code is not an app update")
            }
            XCTAssertEqual(stub.requests.count, 1)
        }

        stub.reset()
        stub.route(StubURLProtocol.any) { _ in throw URLError(.networkConnectionLost) }
        do {
            try await api().approve(serverURL: server, bearer: "chosen", userCode: "ABCD-1234")
            XCTFail("a lost answer is not an approval")
        } catch is URLError {}
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testRemotePlaybackCapabilityNeedsAnAvailableDocument() async throws {
        stub.expect(StubURLProtocol.any) { _ in .json(Self.capability(state: "available")) }
        let available = try await api().remotePlaybackCapability(serverURL: server)
        XCTAssertEqual(stub.requests.last?.path, "/api/v2/auth/device/capability")
        XCTAssertTrue(available.offersRemotePlaybackHandoff(protocolVersion: 2))
        XCTAssertFalse(available.offersRemotePlaybackHandoff(protocolVersion: 3))

        stub.expect(StubURLProtocol.any) { _ in .json(Self.capability(state: "not_configured")) }
        let unconfigured = try await api().remotePlaybackCapability(serverURL: server)
        XCTAssertFalse(unconfigured.offersRemotePlaybackHandoff(protocolVersion: 2))
    }

    // MARK: Fixtures

    private static func problem(_ status: Int, _ type: String) -> StubURLProtocol.Response {
        StubURLProtocol.Response(
            status: status,
            headers: ["Content-Type": "application/problem+json"],
            body: Data(#"{"type":"https://siloserver.org/problems/\#(type)","title":"t","status":\#(status),"detail":"d"}"#.utf8)
        )
    }

    /// Server fixtures vendored by scripts/sync-apiv2-fixtures.sh.
    private static func fixture(_ name: String, setting members: [String: Any] = [:]) -> String {
        APIv2FixtureTestSupport.text(named: name, bundleClass: PairingDeviceAPITests.self, setting: members)
    }

    private static func capability(state: String) -> String {
        fixture("get_device_login_capability_ok", setting: ["state": state])
    }

    private static var start: String { fixture("start_device_login_ok") }
    private static var approvedPoll: String { fixture("poll_device_login_ok") }
    private static var lookup: String { fixture("get_device_login_ok") }
}
