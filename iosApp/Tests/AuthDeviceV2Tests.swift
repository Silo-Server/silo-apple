import Foundation
import XCTest
@testable import Silo

/// Public and account-scoped auth operations on the v2 wire: no bearer on
/// public paths, no refresh replay of a single-dispatch auth mutation, and
/// the captured account fence on the handoff decision.
final class AuthDeviceV2Tests: XCTestCase {
    private var stub = APIv2TestStub()

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func harness() async throws -> (APIv2Client, TokenStore) {
        let name = "AuthDeviceV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://auth.example")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens)
    }

    func testActualLoginFixtureAndPublicRequestGrammar() async throws {
        let (api, tokens) = try await harness()
        _ = await tokens.saveTokens(accessToken: "old", refreshToken: "old-refresh")
        let capturedValue = await tokens.refreshAccountIdentity()
        let captured = try XCTUnwrap(capturedValue)
        stub.reply(200, Self.login_ok)
        let result = try await api.login(username: "laura", password: "password", expectedAccount: captured)
        XCTAssertEqual(result.user.id, "1")
        XCTAssertEqual(result.accessToken, "acc")
        let request = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(request.path, "/api/v2/auth/login")
        XCTAssertNil(request.header("authorization"), "a prior bearer cannot authorize a fresh login")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(body["username"] as? String, "laura")
        XCTAssertNil(body["provider"])
    }

    func testIncompleteLoginBodyIsRefused() async throws {
        let (api, tokens) = try await harness()
        let capturedValue = await tokens.refreshAccountIdentity()
        let captured = try XCTUnwrap(capturedValue)
        stub.reply(200, #"{"access_token":"","refresh_token":"ref","expires_in":1,"user":{"id":"1","username":"u","email":"e","role":"user","permissions":[],"download_allowed":true}}"#)
        do {
            _ = try await api.login(username: "u", password: "p", expectedAccount: captured)
            XCTFail("an empty access token is not a login")
        } catch APIv2Error.incompleteAuthResponse { }
    }

    func testNonretryablePublicMutationsNeverRefreshOrReplay() async throws {
        let (api, tokens) = try await harness()
        _ = await tokens.saveTokens(accessToken: "old", refreshToken: "refresh")
        let identityValue = await tokens.refreshAccountIdentity()
        let identity = try XCTUnwrap(identityValue)
        for operation in 0..<3 {
            for transportFailure in [false, true] {
                stub.reset()
                if transportFailure { stub.fail(.networkConnectionLost) } else { stub.reply(401, "{}") }
                do {
                    switch operation {
                    case 0: _ = try await api.login(username: "u", password: "p", expectedAccount: identity)
                    case 1: _ = try await api.startDeviceLogin(.init(deviceName: "TV", devicePlatform: "tvos"), expectedAccount: identity)
                    default: _ = try await api.pollDeviceLogin(deviceCode: "secret", expectedAccount: identity)
                    }
                    XCTFail("Failure expected for operation \(operation)")
                } catch APIv2Error.httpStatus(401) where !transportFailure {
                    // A 401 on a public auth path is the answer, not a refresh trigger.
                } catch HTTPError.network(let underlying) where transportFailure {
                    XCTAssertEqual((underlying as? URLError)?.code, .networkConnectionLost)
                }
                XCTAssertEqual(stub.requests.count, 1, "operation \(operation): exactly one dispatch, never a refresh or a replay")
                XCTAssertNil(stub.requests.first?.header("authorization"))
                XCTAssertFalse(stub.requestedPaths.contains { $0.hasSuffix("/auth/refresh") })
            }
        }
    }

    func testHandoffDecisionRejectsChangedCapturedAccountBeforeDispatch() async throws {
        let (api, tokens) = try await harness()
        try await tokens.installAccountSession(accessToken: "old", refreshToken: "old-refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let accountValue = await tokens.refreshAccountIdentity()
        let account = try XCTUnwrap(accountValue)
        let identity = HTTPRequestIdentity(serverId: account.serverId, serverURL: account.serverURL,
            profileId: "profile", clientFamily: "ios")
        try await tokens.installAccountSession(accessToken: "new", refreshToken: "new-refresh", accountID: "1")
        await tokens.setProfileId("profile")
        do {
            try await api.decideDeviceLogin(code: "code", approveHandoff: true, identity: identity, expectedAccount: account)
            XCTFail("Old handoff intent accepted")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    func testHandoffDecisionRequiresTheMatchingStatus() async throws {
        let (api, tokens) = try await harness()
        try await tokens.installAccountSession(accessToken: "acc", refreshToken: "ref", accountID: "1")
        await tokens.setProfileId("profile")
        let accountValue = await tokens.refreshAccountIdentity()
        let account = try XCTUnwrap(accountValue)
        let identity = HTTPRequestIdentity(serverId: account.serverId, serverURL: account.serverURL,
            profileId: "profile", clientFamily: AppleDeviceIdentity.current.clientFamily)
        stub.reply(200, #"{"status":"denied"}"#)
        do {
            try await api.decideDeviceLogin(code: "code", approveHandoff: true, identity: identity, expectedAccount: account)
            XCTFail("an approval answered as denied is not a success")
        } catch APIv2Error.incompleteAuthResponse { }
        stub.reply(200, #"{"status":"approved"}"#)
        try await api.decideDeviceLogin(code: "code", approveHandoff: true, identity: identity, expectedAccount: account)
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/auth/device/approve-handoff", "/api/v2/auth/device/approve-handoff"])
        XCTAssertEqual(stub.requests.last?.header("authorization"), "Bearer acc")
    }

    func testActualNestedPollAndStrictStartLookupCapabilityFixtures() async throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let poll = try decoder.decode(APIv2DevicePoll.self, from: Data(Self.poll_device_login_ok.utf8)).validated()
        XCTAssertEqual(poll.tokens?.user.id, "1")
        XCTAssertEqual(poll.tokens?.accessToken, "acc")
        XCTAssertFalse(poll.temporary)
        _ = try decoder.decode(APIv2DeviceStart.self, from: Data(Self.start_device_login_ok.utf8))
        _ = try decoder.decode(APIv2DeviceLookup.self, from: Data(Self.get_device_login_ok.utf8))
        _ = try decoder.decode(APIv2DeviceCapability.self, from: Data(Self.get_device_login_capability_ok.utf8))

        let approvedWithoutTokens = #"{"status":"approved","poll_after":5,"profile_id":"","profile_token":"","temporary":false}"#
        XCTAssertThrowsError(try decoder.decode(APIv2DevicePoll.self, from: Data(approvedWithoutTokens.utf8)).validated()) { error in
            guard case APIv2Error.incompleteAuthResponse = error else { return XCTFail("Unexpected \(error)") }
        }
        let pendingWithTokens = Self.poll_device_login_ok.replacingOccurrences(of: #""status": "approved""#, with: #""status": "pending""#)
        XCTAssertThrowsError(try decoder.decode(APIv2DevicePoll.self, from: Data(pendingWithTokens.utf8)).validated()) { error in
            guard case APIv2Error.incompleteAuthResponse = error else { return XCTFail("Unexpected \(error)") }
        }
        let unknownStatus = #"{"status":"revoked","poll_after":5,"profile_id":"","profile_token":"","temporary":false}"#
        XCTAssertThrowsError(try decoder.decode(APIv2DevicePoll.self, from: Data(unknownStatus.utf8)).validated()) { error in
            guard case APIv2Error.incompleteAuthResponse = error else { return XCTFail("Unexpected \(error)") }
        }
    }

    func testDeviceStartRequiresCreatedAndLookupRequiresOK() async throws {
        let (api, tokens) = try await harness()
        let identityValue = await tokens.refreshAccountIdentity()
        let identity = try XCTUnwrap(identityValue)
        stub.reply(200, Self.start_device_login_ok)
        do {
            _ = try await api.startDeviceLogin(.init(deviceName: "TV", devicePlatform: "tvos"), expectedAccount: identity)
            XCTFail("start requires 201")
        } catch APIv2Error.incompleteAuthResponse { }
        stub.reply(201, Self.start_device_login_ok)
        let start = try await api.startDeviceLogin(.init(deviceName: "TV", devicePlatform: "tvos"), expectedAccount: identity)
        XCTAssertEqual(start.deviceCode, "dev-1")
        XCTAssertEqual(start.userCode, "ABCD-1234")
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/auth/device/start", "/api/v2/auth/device/start"])
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
}
