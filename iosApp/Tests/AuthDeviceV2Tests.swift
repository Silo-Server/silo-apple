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

    /// The server URL may carry a base path. The public-path rule must still
    /// recognise the auth endpoints under it, or a bearer leaks onto them.
    func testPublicAuthPathsCarryNoBearerUnderAServerBasePath() async throws {
        let (api, tokens) = try await harness()
        await tokens.setServerUrl("https://auth.example/silo")
        _ = await tokens.saveTokens(accessToken: "old", refreshToken: "refresh")
        let identityValue = await tokens.refreshAccountIdentity()
        let identity = try XCTUnwrap(identityValue)
        stub.reply(200, #"{"status":"pending","poll_after":5,"profile_id":"","profile_token":"","temporary":false}"#)
        _ = try await api.pollDeviceLogin(deviceCode: "secret", expectedAccount: identity)
        let request = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(request.path, "/silo/api/v2/auth/device/poll")
        XCTAssertNil(request.header("authorization"), "a prefixed public auth path still carries no bearer")
        XCTAssertNil(request.header("x-profile-token"))
    }

    // MARK: - Device identity on sign-in

    /// The server records the device on the login session a sign-in opens,
    /// so every public auth request carries the identity headers while still
    /// carrying no credentials.
    private func assertDeviceIdentityWithoutCredentials(
        _ request: StubURLProtocol.Request,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let device = AppleDeviceIdentity.current
        let label = "\(request.method) \(request.path)"
        XCTAssertEqual(request.header("X-Silo-Device-Id"), device.id, label, file: file, line: line)
        XCTAssertEqual(request.header("X-Silo-Device-Name"), device.name, label, file: file, line: line)
        XCTAssertEqual(request.header("X-Silo-Device-Platform"), device.platform, label, file: file, line: line)
        XCTAssertEqual(request.header("X-Silo-Client-Family"), device.clientFamily, label, file: file, line: line)
        XCTAssertEqual(request.header("X-Silo-Client"), device.clientName, label, file: file, line: line)
        XCTAssertEqual(request.header("X-Silo-Client-Version"), device.appVersion, label, file: file, line: line)
        XCTAssertNil(request.header("authorization"), label, file: file, line: line)
        XCTAssertNil(request.header("x-profile-id"), label, file: file, line: line)
        XCTAssertNil(request.header("x-profile-token"), label, file: file, line: line)
    }

    /// Runs every sign-in the app sends through `HTTPClient` and checks each
    /// request it dispatched.
    private func assertSignInsCarryTheDeviceIdentity(
        _ api: APIv2Client,
        _ tokens: TokenStore,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let identityValue = await tokens.refreshAccountIdentity()
        let identity = try XCTUnwrap(identityValue, file: file, line: line)

        stub.reply(path: "/api/v2/auth/login", 200, Self.login_ok)
        _ = try await api.login(username: "laura", password: "password", expectedAccount: identity)
        stub.reply(path: APIv2Client.oauthCompletePath, 200, Self.login_ok)
        _ = try await api.completeOAuthLogin(code: "code", codeVerifier: "verifier", expectedAccount: identity)
        stub.reply(path: "/api/v2/auth/network/5/sign-in", 200, Self.login_ok)
        _ = try await api.signInWithNetworkIdentity(apiPath: "/api/v2/auth/network/5/sign-in",
                                                    expectedAccount: identity)
        stub.reply(path: Self.capabilityPath, 200, Self.get_device_login_capability_ok)
        _ = try await api.deviceLoginCapability(expectedAccount: identity)
        stub.reply(path: Self.startPath, 201, Self.start_device_login_ok)
        _ = try await api.startDeviceLogin(.init(deviceName: "TV", devicePlatform: "tvos"), expectedAccount: identity)
        stub.reply(path: "/api/v2/auth/device/poll", 200,
                   #"{"status":"pending","poll_after":5,"profile_id":"","profile_token":"","temporary":false}"#)
        _ = try await api.pollDeviceLogin(deviceCode: "secret", expectedAccount: identity)

        XCTAssertEqual(stub.requestedPaths, [
            "/api/v2/auth/login", APIv2Client.oauthCompletePath, "/api/v2/auth/network/5/sign-in",
            Self.capabilityPath, Self.startPath, "/api/v2/auth/device/poll",
        ], file: file, line: line)
        for request in stub.requests {
            assertDeviceIdentityWithoutCredentials(request, file: file, line: line)
        }
    }

    /// A fresh install has no session, so the requests take the client's
    /// no-account header path.
    func testSignInRequestsCarryTheDeviceIdentityOnAFreshInstall() async throws {
        let (api, tokens) = try await harness()
        try await assertSignInsCarryTheDeviceIdentity(api, tokens)
    }

    /// Signing in again over a saved session takes the captured-session
    /// header path, which must also leave the bearer and profile off.
    func testSignInRequestsCarryTheDeviceIdentityOverASavedSession() async throws {
        let (api, tokens) = try await harness()
        try await tokens.installAccountSession(accessToken: "acc", refreshToken: "ref", accountID: "1")
        await tokens.setProfileId("profile")
        _ = await tokens.setProfileToken("proof")
        try await assertSignInsCarryTheDeviceIdentity(api, tokens)
    }

    func testTokenRefreshCarriesTheDeviceIdentityAndNoBearer() async throws {
        let (api, tokens) = try await harness()
        try await tokens.installAccountSession(accessToken: "expired", refreshToken: "ref", accountID: "1")
        let accountValue = await tokens.refreshAccountIdentity()
        let account = try XCTUnwrap(accountValue)
        stub.reply(path: HTTPClient.refreshPath, 200, #"{"access_token":"fresh","refresh_token":"ref-2","expires_in":3600}"#)
        stub.sequence([.json(401, #"{"type":"https://siloserver.org/docs/api/v2/problems/session_expired","title":"Session expired","status":401,"detail":"The session is no longer valid; sign in again."}"#)])
        stub.reply(204, "")
        try await api.logout(expectedAccount: account)

        let refresh = try XCTUnwrap(stub.requests.first { $0.path == HTTPClient.refreshPath })
        assertDeviceIdentityWithoutCredentials(refresh)
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

    // MARK: SiloRemote handoff

    private func handoffOwner(_ tokens: TokenStore) async throws -> (HTTPRequestIdentity, CapturedOrdinaryRequestAuth) {
        try await tokens.installAccountSession(accessToken: "acc", refreshToken: "ref", accountID: "1")
        await tokens.setProfileId("profile")
        let authValue = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(authValue)
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: "profile", clientFamily: AppleDeviceIdentity.current.clientFamily)
        return (identity, auth)
    }

    /// The phone reads the TV's request, approves it for its profile, and
    /// denies it on the way out of a failed handoff, all on the v2 paths.
    func testHandoffLookupApproveAndDenyUseTheV2Wire() async throws {
        let (api, tokens) = try await harness()
        let (identity, auth) = try await handoffOwner(tokens)
        let remoteLookup = Self.fixture("get_device_login_ok", setting: ["client_purpose": "remote_playback", "temporary": true])
        stub.sequence([
            .json(200, remoteLookup),
            .json(200, #"{"status":"approved"}"#),
            .json(200, #"{"status":"denied"}"#),
        ])

        let lookup = try await api.deviceLookup(code: "ABCD-1234", identity: identity,
            expectedAccount: auth.account, expectedAuth: auth)
        XCTAssertEqual(lookup.matchCode, "warm pony")
        XCTAssertEqual(lookup.serverName, "Silo")
        XCTAssertEqual(lookup.serverId, "3f2a9d5e-6b1c-4c7e-9a0d-2f4b8c1e7a35")
        XCTAssertEqual(lookup.userCode, "4821-7730")
        XCTAssertEqual(lookup.clientPurpose, "remote_playback")
        XCTAssertEqual(lookup.temporary, true)
        try await api.decideDeviceLogin(code: "ABCD-1234", approveHandoff: true, identity: identity,
            expectedAccount: auth.account, expectedAuth: auth)
        try await api.decideDeviceLogin(code: "ABCD-1234", approveHandoff: false, identity: identity,
            expectedAccount: auth.account, expectedAuth: auth)

        XCTAssertEqual(stub.requests.map(\.method), ["GET", "POST", "POST"])
        XCTAssertEqual(stub.requestedPaths,
            ["/api/v2/auth/device", "/api/v2/auth/device/approve-handoff", "/api/v2/auth/device/deny"])
        XCTAssertEqual(stub.requests.first?.query, ["code": "ABCD-1234"])
        for request in stub.requests {
            XCTAssertEqual(request.header("authorization"), "Bearer acc")
            XCTAssertEqual(request.header("x-profile-id"), "profile", "approve-handoff requires X-Profile-Id")
        }
        for request in stub.requests.dropFirst() {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String])
            XCTAssertEqual(body, ["code": "ABCD-1234"])
        }
    }

    /// A deny answered as approved is not a deny, and an expired request
    /// surfaces the server's problem instead of a generic failure.
    func testHandoffDecisionFailuresAreTyped() async throws {
        let (api, tokens) = try await harness()
        let (identity, auth) = try await handoffOwner(tokens)
        stub.reply(200, #"{"status":"approved"}"#)
        do {
            try await api.decideDeviceLogin(code: "code", approveHandoff: false, identity: identity,
                expectedAccount: auth.account, expectedAuth: auth)
            XCTFail("a deny answered as approved is not a success")
        } catch APIv2Error.incompleteAuthResponse { }
        stub.reply(410, #"{"type":"https://siloserver.org/docs/api/v2/problems/gone","title":"Gone","status":410,"detail":"This pairing request has expired."}"#)
        do {
            try await api.decideDeviceLogin(code: "code", approveHandoff: true, identity: identity,
                expectedAccount: auth.account, expectedAuth: auth)
            XCTFail("an expired request is not approved")
        } catch APIv2Error.problem(let problem) {
            XCTAssertEqual(problem.status, 410)
        }
        let tokensAfter = await tokens.getAccessToken()
        XCTAssertEqual(tokensAfter, "acc", "a 410 leaves the session alone")
    }

    /// The captured owner covers the profile proof too: a re-verified
    /// profile between the TV's challenge and the approval refuses the
    /// approval before it is sent.
    func testHandoffApprovalRefusesAChangedProfileProofBeforeDispatch() async throws {
        let (api, tokens) = try await harness()
        let (identity, auth) = try await handoffOwner(tokens)
        _ = await tokens.setProfileToken("new-proof")
        stub.reply(200, #"{"status":"approved"}"#)
        do {
            try await api.decideDeviceLogin(code: "code", approveHandoff: true, identity: identity,
                expectedAccount: auth.account, expectedAuth: auth)
            XCTFail("an approval under a replaced owner was sent")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertTrue(stub.requests.isEmpty)
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
        let pendingWithTokens = Self.fixture("poll_device_login_ok", setting: ["status": "pending"])
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
        XCTAssertEqual(start.userCode, "4821-7730")
        XCTAssertEqual(start.verificationUriComplete, "https://silo.example.test/activate?code=48217730")
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/auth/device/start", "/api/v2/auth/device/start"])
    }

    // MARK: Logout

    /// v2 logout refuses `X-Profile-Id`. Neither the persistent session's
    /// profile nor a SiloRemote temporary scope's profile proof may ride along.
    func testLogoutSendsOnlyTheBearer() async throws {
        let (api, tokens) = try await harness()
        try await tokens.installAccountSession(accessToken: "acc", refreshToken: "ref", accountID: "1")
        await tokens.setProfileId("profile")
        _ = await tokens.setProfileToken("proof")
        let persistentValue = await tokens.refreshAccountIdentity()
        let persistent = try XCTUnwrap(persistentValue)
        stub.reply(204, "")
        try await api.logout(expectedAccount: persistent)

        await tokens.beginTemporaryScope(TemporaryAuthScope(serverId: "server", serverURL: "https://auth.example",
            accessToken: "temporary", refreshToken: "temporary-refresh", profileId: "remote-profile",
            profileToken: "remote-proof", controllerDeviceId: "controller", expiresAt: Date().addingTimeInterval(600)))
        let temporaryValue = await tokens.refreshAccountIdentity()
        let temporary = try XCTUnwrap(temporaryValue)
        try await api.logout(expectedAccount: temporary)

        XCTAssertEqual(stub.requestedPaths, ["/api/v2/auth/logout", "/api/v2/auth/logout"])
        XCTAssertEqual(stub.requests.map { $0.header("authorization") }, ["Bearer acc", "Bearer temporary"])
        for request in stub.requests {
            XCTAssertEqual(request.method, "POST")
            XCTAssertNil(request.header("x-profile-id"))
            XCTAssertNil(request.header("x-profile-token"))
        }
    }

    /// Logout is `natural_idempotent`, so an expired bearer refreshes and the
    /// revocation is resent once, still without the profile header.
    func testLogoutResendAfterRefreshKeepsProfileHeaderOff() async throws {
        let (api, tokens) = try await harness()
        try await tokens.installAccountSession(accessToken: "expired", refreshToken: "ref", accountID: "1")
        await tokens.setProfileId("profile")
        let accountValue = await tokens.refreshAccountIdentity()
        let account = try XCTUnwrap(accountValue)
        stub.reply(path: HTTPClient.refreshPath, 200, #"{"access_token":"fresh","refresh_token":"ref-2","expires_in":3600}"#)
        stub.sequence([.json(401, #"{"type":"https://siloserver.org/docs/api/v2/problems/session_expired","title":"Session expired","status":401,"detail":"The session is no longer valid; sign in again."}"#)])
        stub.reply(204, "")
        try await api.logout(expectedAccount: account)

        let logouts = stub.requests.filter { $0.path == "/api/v2/auth/logout" }
        XCTAssertEqual(logouts.map { $0.header("authorization") }, ["Bearer expired", "Bearer fresh"])
        XCTAssertTrue(logouts.allSatisfy { $0.header("x-profile-id") == nil })
    }

    func testLogoutRequiresNoContent() async throws {
        let (api, tokens) = try await harness()
        try await tokens.installAccountSession(accessToken: "acc", refreshToken: "ref", accountID: "1")
        let accountValue = await tokens.refreshAccountIdentity()
        let account = try XCTUnwrap(accountValue)
        stub.reply(200, "{}")
        do {
            try await api.logout(expectedAccount: account)
            XCTFail("logout answers 204")
        } catch APIv2Error.incompleteAuthResponse { }
    }

    /// A v1-only verdict skips the revocation instead of sending it anywhere
    /// else; the caller's local sign-out does not depend on it.
    func testLogoutIsNotSentToAV1OnlyServer() async throws {
        let (_, tokens) = try await harness()
        try await tokens.installAccountSession(accessToken: "acc", refreshToken: "ref", accountID: "1")
        let accountValue = await tokens.refreshAccountIdentity()
        let account = try XCTUnwrap(accountValue)
        let api = APIv2Client(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens),
            tokenStore: tokens, isUpdateRequired: { true })
        do {
            try await api.logout(expectedAccount: account)
            XCTFail("a v1-only server must not receive the v2 logout")
        } catch APIv2Error.serverUpdateRequired { }
        XCTAssertTrue(stub.requests.isEmpty)
    }

    // MARK: Sign-in errors

    /// The login form reads v2 problem statuses, and an update requirement
    /// wins over every other reading.
    func testLoginMessagesFollowProblemStatusAndUpdateRequirement() throws {
        func problem(_ status: Int, _ type: String) throws -> Error {
            APIv2Error.problem(try HTTPClient.makeJSONDecoder().decode(APIv2Problem.self, from: Data(
                #"{"type":"https://siloserver.org/docs/api/v2/problems/\#(type)","title":"t","status":\#(status),"detail":"server detail"}"#.utf8)))
        }
        XCTAssertEqual(LoginViewModel.message(for: APIv2Error.serverUpdateRequired), UpdateRequirement.serverMessage)
        XCTAssertEqual(LoginViewModel.message(for: try problem(410, "client_upgrade_required")), UpdateRequirement.appMessage)
        let wrongPassword = LoginViewModel.message(for: try problem(401, "invalid_token"))
        let disabled = LoginViewModel.message(for: try problem(403, "permission_denied"))
        let invalid = LoginViewModel.message(for: try problem(422, "validation_failed"))
        let limited = LoginViewModel.message(for: try problem(429, "rate_limited"))
        XCTAssertEqual(Set([wrongPassword, disabled, invalid, limited]).count, 4, "each rejection reads differently")
        XCTAssertFalse([wrongPassword, disabled, invalid, limited].contains("server detail"))
        // A bare 401/403 is not Silo's login answer (a proxy or WAF sent it),
        // so it must not blame the credentials or the account.
        for code in [401, 403] {
            let bare = LoginViewModel.message(for: APIv2Error.httpStatus(code))
            XCTAssertFalse([wrongPassword, disabled].contains(bare), "bare \(code)")
            XCTAssertEqual(bare, APIv2Error.httpStatus(code).localizedDescription)
        }
        XCTAssertEqual(LoginViewModel.message(for: APIv2Error.httpStatus(429)), limited)
        XCTAssertEqual(LoginViewModel.message(for: try problem(503, "service_unavailable")), "server detail")
    }

    // MARK: QR sign-in

    /// A failed poll ends the attempt on a v1-only server or a 410 upgrade
    /// answer, shows a new code for a removed request, and backs off (rate
    /// limited or transient) otherwise.
    func testQRPollResultsFollowTheV2Answer() async throws {
        let (api, tokens) = try await harness()
        let identityValue = await tokens.refreshAccountIdentity()
        let identity = try XCTUnwrap(identityValue)
        func pollResult() async -> QRLoginViewModel.PollResult? {
            do {
                _ = try await api.pollDeviceLogin(deviceCode: "secret", expectedAccount: identity)
                XCTFail("poll failure expected")
                return nil
            } catch {
                return QRLoginViewModel.pollResult(for: error)
            }
        }
        func problem(_ status: Int, _ type: String) -> String {
            #"{"type":"https://siloserver.org/docs/api/v2/problems/\#(type)","title":"t","status":\#(status),"detail":"d"}"#
        }

        // Go's plain 404 on a /api/v2 route is a v1-only server, not an expired code.
        stub.reply(404, "404 page not found\n")
        let legacy = await pollResult()
        XCTAssertEqual(legacy, .finished(.updateRequired(message: UpdateRequirement.serverMessage)))
        stub.reply(404, problem(404, "not_found"))
        let removed = await pollResult()
        XCTAssertEqual(removed, .expired)
        stub.reply(410, problem(410, "client_upgrade_required"))
        let upgrade = await pollResult()
        XCTAssertEqual(upgrade, .finished(.updateRequired(message: UpdateRequirement.appMessage)))
        stub.reply(429, problem(429, "rate_limited"))
        let limited = await pollResult()
        XCTAssertEqual(limited, .rateLimited)
        stub.reply(503, problem(503, "service_unavailable"))
        let unavailable = await pollResult()
        XCTAssertEqual(unavailable, .transient)
        stub.fail(.timedOut)
        let offline = await pollResult()
        XCTAssertEqual(offline, .transient)
        XCTAssertEqual(Set(stub.requestedPaths), ["/api/v2/auth/device/poll"])
    }

    func testQRStartShowsTheUpdateMessageForAV1OnlyServer() async throws {
        let (api, tokens) = try await harness()
        let identityValue = await tokens.refreshAccountIdentity()
        let identity = try XCTUnwrap(identityValue)
        stub.reply(404, "404 page not found\n")
        do {
            _ = try await api.startDeviceLogin(.init(deviceName: "TV", devicePlatform: "tvos"), expectedAccount: identity)
            XCTFail("a v1-only server cannot open a pairing request")
        } catch {
            XCTAssertEqual(QRLoginViewModel.startResult(for: error), .terminal(.updateRequired(message: UpdateRequirement.serverMessage)))
        }
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/auth/device/start"])
    }

    /// The view model reads the capability, runs start, a pending poll and
    /// the approved poll, waits for the pending answer's `poll_after` rather
    /// than the start interval, and binds the token pair's account.
    @MainActor
    func testQRSignInFollowsPollAfterAndBindsTheTokenPairAccount() async throws {
        let (model, tokens) = try await qrViewModel()
        stub.sequence([
            .json(200, Self.get_device_login_capability_ok),
            .json(201, Self.fixture("start_device_login_ok", setting: ["interval": 30])),
            .json(200, #"{"status":"pending","poll_after":1,"opened":false,"profile_id":"","profile_token":"","temporary":false}"#),
            .json(200, Self.poll_device_login_ok),
        ])
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        let status = try await settle(model)
        model.stop()
        XCTAssertEqual(status, .approved(account: "laura"))
        let durable = await tokens.captureDurableAccountAuth()
        XCTAssertEqual(durable?.accountID, "1")
        let access = await tokens.getAccessToken()
        XCTAssertEqual(access, "acc")
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/auth/device/capability", "/api/v2/auth/device/start",
            "/api/v2/auth/device/poll", "/api/v2/auth/device/poll"])
        let poll = try XCTUnwrap(stub.requests.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(poll.body)) as? [String: String])
        XCTAssertEqual(body, ["device_code": "dev-1"])
        XCTAssertNil(stub.requests.first?.header("authorization"), "the capability is read without credentials")
    }

    /// A temporary session belongs to a SiloRemote handoff. Sign-in refuses
    /// it and installs nothing.
    @MainActor
    func testQRSignInRefusesATemporaryApproval() async throws {
        let (model, tokens) = try await qrViewModel()
        let temporary = Self.fixture("poll_device_login_ok", setting: [
            "profile_id": "remote-profile",
            "profile_token": "remote-proof",
            "temporary": true,
            "session_expires_at": "2026-01-02T03:14:05.678Z",
        ])
        // The answer passes wire validation, so the refusal is the sign-in's own.
        let decoded = try HTTPClient.makeJSONDecoder().decode(APIv2DevicePoll.self, from: Data(temporary.utf8)).validated()
        XCTAssertTrue(decoded.temporary)
        stub.sequence([.json(200, Self.get_device_login_capability_ok), .json(201, Self.start_device_login_ok), .json(200, temporary)])
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        let status = try await settle(model)
        model.stop()
        XCTAssertEqual(status, .couldNotFinish)
        let access = await tokens.getAccessToken()
        XCTAssertNil(access)
        let durable = await tokens.captureDurableAccountAuth()
        XCTAssertNil(durable)
    }

    /// A code that expires while the screen is visible is polled once more
    /// (a late approval or extension would win), then replaced in place
    /// without a user action and withdrawn on the server; the renewal is
    /// flagged for the status line.
    @MainActor
    func testQRRenewsAnExpiredCodeInPlaceAfterOneLastPoll() async throws {
        let (model, _) = try await qrViewModel()
        stub.reply(path: Self.capabilityPath, 200, Self.get_device_login_capability_ok)
        stub.sequence(path: Self.startPath, [
            .json(201, Self.fixture("start_device_login_ok", setting: ["expires_in": 0])),
            .json(201, Self.fixture("start_device_login_ok", setting: ["device_code": "dev-2", "user_code": "1111-2222"])),
        ])
        // An older server: pending answers carry no expires_at.
        stub.reply(path: Self.pollPath, 200, Self.pendingPoll)
        stub.reply(path: Self.cancelPath, 200, Self.fixture("cancel_device_login_ok"))
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        try await waitFor(model) { $0.session?.deviceCode == "dev-2" && $0.status == .waiting }
        XCTAssertTrue(model.codeWasRenewed)
        XCTAssertEqual(model.session?.userCode, "1111-2222")
        XCTAssertEqual(Array(stub.requestedPaths.filter { $0 != Self.cancelPath }.prefix(4)),
            [Self.capabilityPath, Self.startPath, Self.pollPath, Self.startPath])
        try await waitForCancel(of: "dev-1")
        model.stop()
    }

    /// Only the server's `expires_at` moves the deadline: an opened request
    /// whose poll carries none is still replaced when its start expiry
    /// passes, rather than held on a client-side guess.
    @MainActor
    func testQROpenedRequestWithoutExpiresAtKeepsTheStartDeadline() async throws {
        let (model, _) = try await qrViewModel()
        stub.reply(path: Self.capabilityPath, 200, Self.get_device_login_capability_ok)
        stub.sequence(path: Self.startPath, [
            .json(201, Self.fixture("start_device_login_ok", setting: ["expires_in": 0])),
            .json(201, Self.fixture("start_device_login_ok", setting: ["device_code": "dev-2", "user_code": "1111-2222"])),
        ])
        stub.reply(path: Self.pollPath, 200, #"{"status":"pending","poll_after":1,"opened":true,"profile_id":"","profile_token":"","temporary":false}"#)
        stub.reply(path: Self.cancelPath, 200, Self.fixture("cancel_device_login_ok"))
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        try await waitFor(model) { $0.session?.deviceCode == "dev-2" }
        XCTAssertTrue(model.codeWasRenewed)
        try await waitForCancel(of: "dev-1")
        model.stop()
    }

    /// A pending poll's `expires_at` (an approver's lookup extended the
    /// request) moves the local deadline, so the code stays on screen
    /// instead of being replaced.
    @MainActor
    func testQRFollowsThePollsExpiresAt() async throws {
        let (model, _) = try await qrViewModel()
        stub.reply(path: Self.capabilityPath, 200, Self.get_device_login_capability_ok)
        // Expired by the start answer's own clock at once…
        stub.sequence(path: Self.startPath, [.json(201, Self.fixture("start_device_login_ok", setting: ["expires_in": 0]))])
        // …but the server holds it ten more minutes (start expires_at + 600s).
        stub.reply(path: Self.pollPath, 200, Self.fixture("poll_device_login_opened", setting: ["expires_at": "2026-01-02T03:29:05.678Z"]))
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        try await waitFor(model) { _ in self.stub.requestedPaths.filter { $0 == Self.pollPath }.count >= 3 }
        XCTAssertEqual(model.status, .opened)
        XCTAssertEqual(model.session?.deviceCode, "dev-1")
        XCTAssertFalse(model.codeWasRenewed)
        XCTAssertEqual(stub.requestedPaths.filter { $0 == Self.startPath }.count, 1)
        XCTAssertFalse(stub.requestedPaths.contains(Self.cancelPath))
        model.stop()
    }

    /// After the renewal window (about an hour) the screen pauses instead of
    /// renewing forever; "Show a new code" starts a fresh window.
    @MainActor
    func testQRPausesAfterTheRenewalWindowAndRestartsOnRequest() async throws {
        var timing = Self.fastTiming
        timing.renewalLimit = 0
        let (model, _) = try await qrViewModel(timing: timing)
        stub.reply(path: Self.capabilityPath, 200, Self.get_device_login_capability_ok)
        stub.sequence(path: Self.startPath, [
            .json(201, Self.fixture("start_device_login_ok", setting: ["expires_in": 0])),
            .json(201, Self.fixture("start_device_login_ok", setting: ["device_code": "dev-2"])),
        ])
        stub.reply(path: Self.pollPath, 200, Self.pendingPoll)
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        try await waitFor(model) { $0.status == .paused }
        XCTAssertNil(model.session)
        XCTAssertFalse(model.showsCode)
        XCTAssertEqual(stub.requestedPaths.filter { $0 == Self.startPath }.count, 1)

        await model.retry()
        try await waitFor(model) { $0.status == .waiting }
        XCTAssertEqual(model.session?.deviceCode, "dev-2")
        XCTAssertFalse(model.codeWasRenewed, "a requested code is not a renewal")
        XCTAssertEqual(stub.requestedPaths.filter { $0 == Self.startPath }.count, 2)
        model.stop()
    }

    /// Going to the background pauses polling after the request in flight;
    /// an approval that request collects is still installed.
    @MainActor
    func testQRPausingDuringAnApprovedPollStillSignsIn() async throws {
        let (model, tokens) = try await qrViewModel()
        stub.reply(path: Self.capabilityPath, 200, Self.get_device_login_capability_ok)
        stub.reply(path: Self.startPath, 201, Self.start_device_login_ok)
        stub.reply(path: Self.pollPath, 200, Self.poll_device_login_ok)
        stub.hold(path: Self.pollPath)
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        await stub.waitUntilHeld()
        model.setActive(false)
        stub.release()
        try await waitFor(model) { $0.status == .approved(account: "laura") }
        let access = await tokens.getAccessToken()
        XCTAssertEqual(access, "acc")
    }

    /// "Try again" while a poll is collecting an approval lets it finish
    /// and keeps the sign-in, rather than starting a new code.
    @MainActor
    func testQRRetryDuringAnApprovedPollKeepsTheSignIn() async throws {
        let (model, tokens) = try await qrViewModel()
        stub.reply(path: Self.capabilityPath, 200, Self.get_device_login_capability_ok)
        stub.reply(path: Self.startPath, 201, Self.start_device_login_ok)
        stub.reply(path: Self.pollPath, 200, Self.poll_device_login_ok)
        stub.hold(path: Self.pollPath)
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        await stub.waitUntilHeld()
        let retry = Task { await model.retry() }
        await Task.yield()
        stub.release()
        await retry.value
        XCTAssertEqual(model.status, .approved(account: "laura"))
        let access = await tokens.getAccessToken()
        XCTAssertEqual(access, "acc")
        XCTAssertEqual(stub.requestedPaths.filter { $0 == Self.startPath }.count, 1)
        XCTAssertFalse(stub.requestedPaths.contains(Self.cancelPath))
    }

    /// "Change server" while "Try again" waits for the poll in flight: the
    /// stop wins, so the retry starts no new code for the old server.
    @MainActor
    func testQRStopWhileRetryWaitsWins() async throws {
        let (model, _) = try await qrViewModel()
        stub.reply(path: Self.capabilityPath, 200, Self.get_device_login_capability_ok)
        stub.reply(path: Self.startPath, 201, Self.start_device_login_ok)
        stub.reply(path: Self.pollPath, 200, Self.pendingPoll)
        stub.reply(path: Self.cancelPath, 200, Self.fixture("cancel_device_login_ok"))
        stub.hold(path: Self.pollPath)
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        await stub.waitUntilHeld()
        let retry = Task { await model.retry() }
        await Task.yield()
        model.stop()
        stub.release()
        await retry.value
        try await waitForCancel(of: "dev-1")
        XCTAssertFalse(model.isPolling, "the overtaken retry must not restart the loop")
        XCTAssertNil(model.session)
        XCTAssertEqual(stub.requestedPaths.filter { $0 == Self.startPath }.count, 1, "no new code after stop()")

        // The screen still starts normally when it appears again.
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        try await waitFor(model) { $0.status == .waiting && $0.session != nil }
        XCTAssertEqual(stub.requestedPaths.filter { $0 == Self.startPath }.count, 2)
        model.stop()
    }

    /// No polls while the scene is inactive; one at once on return.
    @MainActor
    func testQRPausesPollingInTheBackgroundAndPollsOnReturn() async throws {
        let (model, _) = try await qrViewModel()
        stub.reply(path: Self.capabilityPath, 200, Self.get_device_login_capability_ok)
        stub.reply(path: Self.startPath, 201, Self.start_device_login_ok)
        stub.reply(path: Self.pollPath, 200, Self.pendingPoll)
        func polls() -> Int { stub.requestedPaths.filter { $0 == Self.pollPath }.count }
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        try await waitFor(model) { _ in polls() >= 2 }
        model.setActive(false)
        // A poll already in flight lands, then the loop ends: with no loop,
        // nothing polls in the background.
        try await waitFor(model) { !$0.isPolling }
        let paused = polls()
        XCTAssertEqual(model.status, .waiting)
        model.setActive(true)
        try await waitFor(model) { _ in polls() > paused }
        model.stop()
    }

    /// A nearby phone waiting on the code on screen hears how it ended:
    /// signed in, declined, replaced by a renewal, or the screen stopped.
    @MainActor
    func testQRNearbyWaitersFollowApprovalDenialRenewalAndStop() async throws {
        func scenario(start: [APIv2TestStub.Reply], polls: [APIv2TestStub.Reply],
                      holdFirstPoll: Bool = false) async throws -> QRLoginViewModel {
            stub = APIv2TestStub()
            let (model, _) = try await qrViewModel()
            stub.reply(path: Self.capabilityPath, 200, Self.get_device_login_capability_ok)
            stub.sequence(path: Self.startPath, start)
            stub.sequence(path: Self.pollPath, polls)
            stub.reply(path: Self.pollPath, 200, Self.pendingPoll)
            stub.reply(path: Self.cancelPath, 200, Self.fixture("cancel_device_login_ok"))
            if holdFirstPoll { stub.hold(path: Self.pollPath) }
            await model.begin(deviceName: "TV", devicePlatform: "tvos")
            return model
        }
        let started = APIv2TestStub.Reply.json(201, Self.start_device_login_ok)
        let slowPending = APIv2TestStub.Reply.json(200, #"{"status":"pending","poll_after":5,"opened":false,"profile_id":"","profile_token":"","temporary":false}"#)

        var model = try await scenario(start: [started], polls: [slowPending, .json(200, Self.poll_device_login_ok)])
        var code = await model.codeForNearbyApproval()
        XCTAssertEqual(code?.deviceCode, "dev-1")
        var outcome = await model.nearbyApprovalOutcome(deviceCode: "dev-1")
        XCTAssertEqual(outcome, .signedIn)

        let denied = #"{"status":"denied","poll_after":5,"profile_id":"","profile_token":"","temporary":false}"#
        model = try await scenario(start: [started], polls: [slowPending, .json(200, denied)])
        code = await model.codeForNearbyApproval()
        XCTAssertEqual(code?.deviceCode, "dev-1")
        outcome = await model.nearbyApprovalOutcome(deviceCode: "dev-1")
        XCTAssertEqual(outcome, .failed(.denied))

        // The code expires locally; its last poll is held until the phone waits.
        model = try await scenario(start: [
            .json(201, Self.fixture("start_device_login_ok", setting: ["expires_in": 0])),
            .json(201, Self.fixture("start_device_login_ok", setting: ["device_code": "dev-2"])),
        ], polls: [], holdFirstPoll: true)
        await stub.waitUntilHeld()
        code = await model.codeForNearbyApproval()
        XCTAssertEqual(code?.deviceCode, "dev-1")
        let renewing = model
        let renewed = Task { await renewing.nearbyApprovalOutcome(deviceCode: "dev-1") }
        try await waitFor(renewing) { $0.nearbyWaiterCount == 1 }
        stub.release()
        outcome = await renewed.value
        XCTAssertEqual(outcome, .failed(.expired), "a renewed code is gone")
        model.stop()

        model = try await scenario(start: [started], polls: [])
        code = await model.codeForNearbyApproval()
        XCTAssertEqual(code?.deviceCode, "dev-1")
        let stopping = model
        let waiter = Task { await stopping.nearbyApprovalOutcome(deviceCode: "dev-1") }
        try await waitFor(stopping) { $0.nearbyWaiterCount == 1 }
        model.stop()
        outcome = await waiter.value
        XCTAssertEqual(outcome, .failed(.authFailed), "leaving the screen is not an expired code")
    }

    /// A phone reaching a declined screen gets a new code: someone is at
    /// the TV. A server without device sign-in offers the phone nothing.
    @MainActor
    func testQRNearbyPhoneRestartsADeclinedScreen() async throws {
        let (model, _) = try await qrViewModel()
        stub.reply(path: Self.capabilityPath, 200, Self.get_device_login_capability_ok)
        stub.sequence(path: Self.startPath, [
            .json(201, Self.start_device_login_ok),
            .json(201, Self.fixture("start_device_login_ok", setting: ["device_code": "dev-2"])),
        ])
        stub.reply(path: Self.pollPath, 200, #"{"status":"denied","poll_after":5,"profile_id":"","profile_token":"","temporary":false}"#)
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        try await waitFor(model) { $0.status == .denied }
        XCTAssertTrue(model.offersNearbySignIn)
        stub.reply(path: Self.pollPath, 200, Self.pendingPoll)
        let code = await model.codeForNearbyApproval()
        XCTAssertEqual(code?.deviceCode, "dev-2")
        model.stop()
    }

    /// While the server can't be reached the screen says so and keeps
    /// retrying with backoff; it recovers on its own.
    @MainActor
    func testQRShowsUnreachableAndRecovers() async throws {
        let (model, _) = try await qrViewModel()
        stub.sequence([.json(200, Self.get_device_login_capability_ok)])
        stub.fail(.timedOut)
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        try await waitFor(model) { $0.status == .unreachable }
        let failedStarts = stub.requestedPaths.filter { $0 == "/api/v2/auth/device/start" }.count
        XCTAssertGreaterThanOrEqual(failedStarts, 1)
        stub.reply(path: "/api/v2/auth/device/start", 201, Self.start_device_login_ok)
        stub.reply(path: "/api/v2/auth/device/poll", 200, #"{"status":"pending","poll_after":5,"opened":false,"profile_id":"","profile_token":"","temporary":false}"#)
        stub.reply(.failure(URLError(.timedOut)))
        try await waitFor(model) { $0.status == .waiting }
        XCTAssertTrue(model.showsCode)
        model.stop()
    }

    /// A 429 streak longer than the threshold reads as "too many requests".
    @MainActor
    func testQRShowsRateLimitedWhen429Persists() async throws {
        let (model, _) = try await qrViewModel()
        stub.sequence([.json(200, Self.get_device_login_capability_ok)])
        stub.reply(429, #"{"type":"https://siloserver.org/docs/api/v2/problems/rate_limited","title":"t","status":429,"detail":"d"}"#)
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        try await waitFor(model) { $0.status == .rateLimited }
        model.stop()
    }

    /// The opened signal keeps the code and says "Continue on your phone".
    @MainActor
    func testQROpenedSignalShowsContinueOnYourPhone() async throws {
        let (model, _) = try await qrViewModel()
        stub.sequence([.json(200, Self.get_device_login_capability_ok), .json(201, Self.start_device_login_ok)])
        stub.reply(200, Self.fixture("poll_device_login_opened"))
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        try await waitFor(model) { $0.status == .opened }
        XCTAssertEqual(model.session?.deviceCode, "dev-1")
        XCTAssertEqual(TVSignInPresentation.statusLine(for: model.status, codeWasRenewed: false, serverHost: "h"),
            "Continue on your phone")
        model.stop()
    }

    /// A server that reports device sign-in unavailable goes straight to the
    /// password form, without opening a request.
    @MainActor
    func testQRNoDeviceSignInWhenTheCapabilityIsOff() async throws {
        let (model, _) = try await qrViewModel()
        stub.sequence([.json(200, Self.fixture("get_device_login_capability_ok", setting: ["state": "disabled"]))])
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        try await waitFor(model) { $0.status == .noDeviceSignIn }
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/auth/device/capability"])
        XCTAssertFalse(model.offersNearbySignIn, "the TV stops advertising to nearby phones")
        let code = await model.codeForNearbyApproval()
        XCTAssertNil(code)
    }

    /// Leaving the screen withdraws the code on a server that supports it,
    /// with the device code and no bearer; an older server is left alone.
    @MainActor
    func testQRStopWithdrawsTheCodeOnlyWhenTheServerSupportsCancel() async throws {
        for supportsCancel in [true, false] {
            stub.reset()
            let (model, _) = try await qrViewModel()
            stub.sequence([
                .json(200, Self.fixture("get_device_login_capability_ok", setting: ["cancel": supportsCancel])),
                .json(201, Self.start_device_login_ok),
            ])
            stub.reply(path: "/api/v2/auth/device/poll", 200, #"{"status":"pending","poll_after":5,"opened":false,"profile_id":"","profile_token":"","temporary":false}"#)
            stub.reply(path: "/api/v2/auth/device/cancel", 200, Self.fixture("cancel_device_login_ok"))
            await model.begin(deviceName: "TV", devicePlatform: "tvos")
            try await waitFor(model) { $0.status == .waiting }
            model.stop()
            XCTAssertNil(model.session)
            if supportsCancel {
                try await waitForRequest("/api/v2/auth/device/cancel")
                let cancel = try XCTUnwrap(stub.requests.first { $0.path == "/api/v2/auth/device/cancel" })
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(cancel.body)) as? [String: String])
                XCTAssertEqual(body, ["device_code": "dev-1"])
                XCTAssertNil(cancel.header("authorization"))
            } else {
                try await Task.sleep(for: .milliseconds(200))
                XCTAssertFalse(stub.requestedPaths.contains("/api/v2/auth/device/cancel"))
            }
        }
    }

    /// Password sign-in and a phone approval complete once: suspending lets
    /// the in-flight poll finish, reports an approval that already won, and
    /// otherwise stops polling until the password attempt ends.
    @MainActor
    func testQRPasswordSignInAndApprovalCompleteOnce() async throws {
        let (model, _) = try await qrViewModel()
        stub.sequence([.json(200, Self.get_device_login_capability_ok), .json(201, Self.start_device_login_ok)])
        let pending = #"{"status":"pending","poll_after":1,"opened":false,"profile_id":"","profile_token":"","temporary":false}"#
        stub.reply(200, pending)
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        try await waitFor(model) { $0.status == .waiting }
        let mayUsePassword = await model.suspendForPasswordSignIn()
        XCTAssertTrue(mayUsePassword)
        XCTAssertFalse(model.isPolling, "no polls while a password sign-in is in flight")

        // The password failed: polling resumes, and the phone's approval wins.
        stub.reply(200, Self.poll_device_login_ok)
        model.finishPasswordSignIn(succeeded: false)
        _ = try await settle(model)
        let secondTry = await model.suspendForPasswordSignIn()
        XCTAssertFalse(secondTry, "the approval already signed this TV in")
        XCTAssertEqual(model.status, .approved(account: "laura"))
    }

    /// "Try again" or a nearby phone during a password sign-in must not
    /// restart polling: a device approval would race the password and both
    /// could install a session. The code is renewed only after the password
    /// failed.
    @MainActor
    func testQRRetryDuringAPasswordSignInWaitsForItToFinish() async throws {
        let (model, _) = try await qrViewModel()
        stub.reply(path: Self.capabilityPath, 200, Self.get_device_login_capability_ok)
        stub.sequence(path: Self.startPath, [
            .json(201, Self.start_device_login_ok),
            .json(201, Self.fixture("start_device_login_ok", setting: ["device_code": "dev-2"])),
        ])
        stub.reply(path: Self.pollPath, 200, Self.pendingPoll)
        stub.reply(path: Self.cancelPath, 200, Self.fixture("cancel_device_login_ok"))
        func count(_ path: String) -> Int { stub.requestedPaths.filter { $0 == path }.count }
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        try await waitFor(model) { $0.status == .waiting }
        let mayUsePassword = await model.suspendForPasswordSignIn()
        XCTAssertTrue(mayUsePassword)
        let polls = count(Self.pollPath)

        await model.retry()
        let nearby = await model.codeForNearbyApproval()
        XCTAssertNil(nearby, "no code for a phone while a password is being checked")
        XCTAssertFalse(model.isPolling, "the retry waits for the password before starting the loop")
        XCTAssertEqual(count(Self.startPath), 1, "no new code while the password is in flight")
        XCTAssertEqual(count(Self.pollPath), polls, "no polls while the password is in flight")
        XCTAssertEqual(model.status, .gettingCode)
        XCTAssertNil(model.session)

        model.finishPasswordSignIn(succeeded: false)
        try await waitFor(model) { $0.status == .waiting && $0.session?.deviceCode == "dev-2" }
        XCTAssertEqual(count(Self.startPath), 2)
        model.stop()
    }

    /// "Try again" says a new code is coming at once, even while a hung
    /// request holds up the restart.
    @MainActor
    func testQRRetryShowsProgressWhileARequestIsInFlight() async throws {
        let (model, _) = try await qrViewModel()
        stub.reply(path: Self.capabilityPath, 200, Self.get_device_login_capability_ok)
        stub.reply(path: Self.startPath, 201, Self.start_device_login_ok)
        stub.reply(path: Self.pollPath, 200, Self.pendingPoll)
        stub.reply(path: Self.cancelPath, 200, Self.fixture("cancel_device_login_ok"))
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        try await waitFor(model) { $0.status == .waiting }
        stub.hold(path: Self.pollPath)
        await stub.waitUntilHeld()
        let retry = Task { await model.retry() }
        try await waitFor(model) { $0.status == .gettingCode }
        XCTAssertFalse(model.showsCode)
        stub.release()
        await retry.value
        try await waitFor(model) { $0.status == .waiting && $0.session != nil }
        model.stop()
    }

    @MainActor
    private func qrViewModel(timing: QRLoginViewModel.Timing = fastTiming) async throws -> (QRLoginViewModel, TokenStore) {
        let (api, tokens) = try await harness()
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        let name = "AuthDeviceV2Tests.auth.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let auth = AuthService(launchPreferences: ProfileLaunchPreferences(defaults: SharedDefaults(suite: suite, standard: suite)),
            apiV2Client: api, httpClient: http, tokenStore: tokens)
        let devices = PairingDeviceAPI(session: stub.makeSession())
        return (QRLoginViewModel(auth: auth, tokenStore: tokens, timing: timing,
            // Server seconds run a hundred times faster here.
            sleeper: { seconds in try? await Task.sleep(for: .milliseconds(Int64(max(0, seconds) * 10))) },
            devices: devices), tokens)
    }

    private static let fastTiming: QRLoginViewModel.Timing = {
        var timing = QRLoginViewModel.Timing.standard
        timing.unreachableWhileStarting = 0
        timing.unreachableWhilePolling = 0
        timing.rateLimitedAfter = 0
        timing.maxBackoff = 0.05
        timing.minimumPoll = 0.05
        return timing
    }()

    /// Waits for the QR flow to reach a state it leaves only on a user action.
    @MainActor
    private func settle(_ model: QRLoginViewModel, timeout: TimeInterval = 10) async throws -> QRLoginViewModel.Status {
        try await waitFor(model, timeout: timeout) { $0.status.isTerminal }
        return model.status
    }

    @MainActor
    private func waitFor(_ model: QRLoginViewModel, timeout: TimeInterval = 10,
                         file: StaticString = #filePath, line: UInt = #line,
                         _ condition: (QRLoginViewModel) -> Bool) async throws {
        if await eventually(timeout: .seconds(timeout), { condition(model) }) { return }
        XCTFail("QR sign-in did not reach the expected state: \(model.status)", file: file, line: line)
    }

    /// Waits for a withdrawal of `deviceCode`.
    private func waitForCancel(of deviceCode: String) async throws {
        try await waitUntil("\(deviceCode) to be withdrawn") {
            stub.requests.filter { $0.path == Self.cancelPath }.contains { request in
                request.body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?["device_code"] == deviceCode
            }
        }
    }

    private func waitForRequest(_ path: String) async throws {
        try await waitUntil("a request to \(path)") { stub.requestedPaths.contains(path) }
    }

    /// Server fixtures vendored by scripts/sync-apiv2-fixtures.sh.
    private static func fixture(_ name: String, setting members: [String: Any] = [:]) -> String {
        APIv2FixtureTestSupport.text(named: name, bundleClass: AuthDeviceV2Tests.self, setting: members)
    }
    private static var login_ok: String { fixture("login_ok") }
    private static var poll_device_login_ok: String { fixture("poll_device_login_ok") }
    private static var start_device_login_ok: String { fixture("start_device_login_ok") }
    private static var get_device_login_ok: String { fixture("get_device_login_ok") }
    private static var get_device_login_capability_ok: String { fixture("get_device_login_capability_ok") }
    private static let capabilityPath = "/api/v2/auth/device/capability"
    private static let startPath = "/api/v2/auth/device/start"
    private static let pollPath = "/api/v2/auth/device/poll"
    private static let cancelPath = "/api/v2/auth/device/cancel"
    /// A pending answer as older servers send it: no `expires_at`.
    private static let pendingPoll = #"{"status":"pending","poll_after":1,"opened":false,"profile_id":"","profile_token":"","temporary":false}"#
}
