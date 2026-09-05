import Foundation
import XCTest
@testable import Silo

final class AuthDeviceV2Tests: XCTestCase {
    private func harness() async throws -> (APIv2Client, TokenStore, URLSession) {
        let name = "AuthDeviceV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name); AuthDeviceProtocol.reset() }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil), defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://auth.example")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthDeviceProtocol.self]
        let session = URLSession(configuration: configuration)
        let http = HTTPClient(session: session, tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens, session)
    }
    func testActualLoginFixtureAndPublicRequestGrammar() async throws {
        let (api, tokens, _) = try await harness()
        _ = await tokens.saveTokens(accessToken: "old", refreshToken: "old-refresh")
        let captured = await tokens.refreshAccountIdentity()
        AuthDeviceProtocol.reply(200, Self.login_ok)
        let result = try await api.login(username: "laura", password: "password", expectedAccount: XCTUnwrap(captured))
        XCTAssertEqual(result.user.id, "1")
        let request = try XCTUnwrap(AuthDeviceProtocol.requests().last)
        XCTAssertEqual(request.0.url?.path, "/api/v2/auth/login")
        XCTAssertNil(request.0.value(forHTTPHeaderField: "Authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.1)) as? [String: Any])
        XCTAssertEqual(body["username"] as? String, "laura")
        XCTAssertNil(body["provider"])
    }
    func testNonretryablePublicMutationsNeverRefreshOrReplay() async throws {
        let (api, tokens, _) = try await harness()
        _ = await tokens.saveTokens(accessToken: "old", refreshToken: "refresh")
        let captured = await tokens.refreshAccountIdentity()
        let identity = try XCTUnwrap(captured)
        for operation in 0..<3 {
            for status in [401, -1] {
                AuthDeviceProtocol.reset()
                AuthDeviceProtocol.reply(status, "{}")
                do {
                    if operation == 0 { _ = try await api.login(username: "u", password: "p", expectedAccount: identity) }
                    else if operation == 1 { _ = try await api.startDeviceLogin(.init(deviceName: "TV", devicePlatform: "tvos"), expectedAccount: identity) }
                    else { _ = try await api.pollDeviceLogin(deviceCode: "secret", expectedAccount: identity) }
                    XCTFail("Failure expected")
                } catch {}
                XCTAssertEqual(AuthDeviceProtocol.requests().count, 1)
                XCTAssertNil(AuthDeviceProtocol.requests().first?.0.value(forHTTPHeaderField: "Authorization"))
            }
        }
    }
    func testHandoffDecisionRejectsChangedCapturedAccountBeforeDispatch() async throws {
        let (api, tokens, _) = try await harness()
        try await tokens.installAccountSession(accessToken: "old", refreshToken: "old-refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let captured = await tokens.refreshAccountIdentity()
        let account = try XCTUnwrap(captured)
        let identity = HTTPRequestIdentity(serverId: account.serverId, serverURL: account.serverURL,
            profileId: "profile", clientFamily: "ios")
        try await tokens.installAccountSession(accessToken: "new", refreshToken: "new-refresh", accountID: "1")
        await tokens.setProfileId("profile")
        do {
            try await api.decideDeviceLogin(code: "code", approveHandoff: true, identity: identity, expectedAccount: account)
            XCTFail("Old handoff intent accepted")
        } catch HTTPError.requestIdentityChanged {}
        XCTAssertTrue(AuthDeviceProtocol.requests().isEmpty)
    }

    func testActualNestedPollAndStrictStartLookupCapabilityFixtures() async throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let poll = try decoder.decode(APIv2DevicePoll.self, from: Data(Self.poll_device_login_ok.utf8)).presentation()
        XCTAssertEqual(poll.user?.id, "1")
        XCTAssertNotNil(poll.accessToken)
        XCTAssertFalse(try XCTUnwrap(poll.temporary))
        _ = try decoder.decode(APIv2DeviceStart.self, from: Data(Self.start_device_login_ok.utf8))
        _ = try decoder.decode(APIv2DeviceLookup.self, from: Data(Self.get_device_login_ok.utf8))
        _ = try decoder.decode(APIv2DeviceCapability.self, from: Data(Self.get_device_login_capability_ok.utf8))
        let invalid = #"{"status":"approved","poll_after":5,"profile_id":"","profile_token":"","temporary":false}"#
        XCTAssertThrowsError(try decoder.decode(APIv2DevicePoll.self, from: Data(invalid.utf8)).presentation())
    }
    func testExplicitCandidateProbeAndSingleAttemptCollection() async throws {
        let (_, _, session) = try await harness()
        let api = PairingDeviceAPI(session: session)
        AuthDeviceProtocol.probeBody = Self.get_system_info_ok
        AuthDeviceProtocol.reply(201, Self.start_device_login_ok)
        _ = try await api.start(serverURL: "https://candidate.example", deviceName: "TV", devicePlatform: "tvos")
        AuthDeviceProtocol.reply(200, Self.poll_device_login_ok)
        let result = try await api.poll(serverURL: "https://candidate.example", deviceCode: "secret")
        XCTAssertEqual(result.user?.id, "1")
        AuthDeviceProtocol.reply(-1, "")
        do { _ = try await api.poll(serverURL: "https://candidate.example", deviceCode: "secret"); XCTFail() } catch {}
        XCTAssertEqual(AuthDeviceProtocol.requests().map { $0.0.url!.path }, ["/api/v2/system/info", "/api/v2/auth/device/start", "/api/v2/auth/device/poll", "/api/v2/auth/device/poll"])
    }
    func testCandidateInvalidContractNeverStarts() async throws {
        let (_, _, session) = try await harness()
        AuthDeviceProtocol.probeBody = "{}"
        do { _ = try await PairingDeviceAPI(session: session).start(serverURL: "https://candidate.example", deviceName: "TV", devicePlatform: "tvos"); XCTFail() } catch {}
        XCTAssertEqual(AuthDeviceProtocol.requests().count, 1)
    }
    private static let login_ok = #"""
{
  "access_token": "acc",
  "refresh_token": "ref",
  "expires_in": 3600,
  "user": {
    "id": "1",
    "username": "laura",
    "email": "laura@example.test",
    "role": "user",
    "permissions": [
      "marker_edit"
    ],
    "download_allowed": true
  }
}
"""#
    private static let poll_device_login_ok = #"""
{
  "status": "approved",
  "poll_after": 5,
  "tokens": {
    "access_token": "acc",
    "refresh_token": "ref",
    "expires_in": 3600,
    "user": {
      "id": "1",
      "username": "laura",
      "email": "laura@example.test",
      "role": "user",
      "permissions": [],
      "download_allowed": true
    }
  },
  "profile_id": "",
  "profile_token": "",
  "temporary": false
}
"""#
    private static let start_device_login_ok = #"""
{
  "device_code": "dev-1",
  "user_code": "ABCD-1234",
  "match_code": "42",
  "verification_uri": "https://silo.example.test/link",
  "verification_uri_complete": "https://silo.example.test/link?code=ABCD-1234",
  "expires_at": "2026-01-02T03:14:05.678Z",
  "expires_in": 600,
  "interval": 5,
  "device_name": "Living room TV",
  "device_platform": "tvos",
  "client_purpose": "device_login",
  "temporary": false
}
"""#
    private static let get_device_login_ok = #"""
{
  "status": "pending",
  "user_code": "ABCD-1234",
  "match_code": "42",
  "device_name": "Living room TV",
  "device_platform": "tvos",
  "ip_address_hint": "192.168.1.x",
  "expires_at": "2026-01-02T03:14:05.678Z",
  "client_purpose": "device_login",
  "temporary": false
}
"""#
    private static let get_device_login_capability_ok = #"""
{
  "revision": "1",
  "state": "available",
  "remote_playback_handoff": true,
  "protocol_versions": [
    2
  ]
}
"""#
    private static let approve_device_login_ok = #"""
{
  "status": "approved"
}
"""#
    private static let get_system_info_ok = #"""
{
  "server_version": "unavailable",
  "api_major": 2,
  "contract_digest": "049e02cec0a3f85245a3d63f10d37fed29b129c884610760d6fd64fb7040e583",
  "links": {
    "openapi": "/api/v2/openapi.json",
    "capabilities": "/api/v2/capabilities"
  }
}
"""#
}
private final class AuthDeviceProtocol: URLProtocol {
    nonisolated(unsafe) static var probeBody: String?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = (200, Data(), [String: String]())
    nonisolated(unsafe) private static var failure = false
    nonisolated(unsafe) private static var recorded: [(URLRequest, Data?)] = []
    nonisolated(unsafe) private static var onHeldRequest: (() -> Void)?
    nonisolated(unsafe) private static var pending: (() -> Void)?
    static func hold(_ notify: @escaping () -> Void) { lock.withLock { onHeldRequest = notify } }
    static func release() {
        let deliver = lock.withLock { let value = pending; pending = nil; onHeldRequest = nil; return value }
        deliver?()
    }
    static func reset() { lock.withLock { probeBody = nil; response = (200, Data(), [:]); failure = false; recorded = []; onHeldRequest = nil; pending = nil } }
    static func reply(_ status: Int, _ body: String, headers: [String: String] = [:]) { lock.withLock { response = (status, Data(body.utf8), headers); failure = false } }
    static func fail() { lock.withLock { failure = true } }
    static func requests() -> [(URLRequest, Data?)] { lock.withLock { recorded } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; bytes.append(buffer, count: count)
            }
            data = bytes
        }
        let (reply, failed) = Self.lock.withLock { Self.recorded.append((request, data)); if request.url?.path == "/api/v2/system/info", let body = Self.probeBody { return ((200, Data(body.utf8), [String: String]()), false) }; return (Self.response, Self.response.0 == -1) }
        if failed { client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return }
        let deliver: () -> Void = { [self] in
            let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: reply.2)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.1)
            client?.urlProtocolDidFinishLoading(self)
        }
        let notify: (() -> Void)? = Self.lock.withLock {
            if let notify = Self.onHeldRequest { Self.pending = deliver; return notify }
            return nil
        }
        if let notify { notify() } else { deliver() }
    }
    override func stopLoading() {}
}
