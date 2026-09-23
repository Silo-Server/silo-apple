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
        let remoteLookup = Self.get_device_login_ok
            .replacingOccurrences(of: #""client_purpose": "device_login""#, with: #""client_purpose": "remote_playback""#)
            .replacingOccurrences(of: #""temporary": false"#, with: #""temporary": true"#)
        stub.sequence([
            .json(200, remoteLookup),
            .json(200, #"{"status":"approved"}"#),
            .json(200, #"{"status":"denied"}"#),
        ])

        let lookup = try await api.deviceLookup(code: "ABCD-1234", identity: identity,
            expectedAccount: auth.account, expectedAuth: auth)
        XCTAssertEqual(lookup.matchCode, "42")
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

    /// The tvOS QR poll ends on a v1-only server, a 410 upgrade answer, or a
    /// removed request, and keeps polling through transient failures.
    func testQRPollFailuresFollowTheV2Answer() async throws {
        let (api, tokens) = try await harness()
        let identityValue = await tokens.refreshAccountIdentity()
        let identity = try XCTUnwrap(identityValue)
        func pollFailure() async -> QRLoginViewModel.PollFailure? {
            do {
                _ = try await api.pollDeviceLogin(deviceCode: "secret", expectedAccount: identity)
                XCTFail("poll failure expected")
                return nil
            } catch {
                return QRLoginViewModel.pollFailure(for: error)
            }
        }
        func problem(_ status: Int, _ type: String) -> String {
            #"{"type":"https://siloserver.org/docs/api/v2/problems/\#(type)","title":"t","status":\#(status),"detail":"d"}"#
        }

        // Go's plain 404 on a /api/v2 route is a v1-only server, not an expired code.
        stub.reply(404, "404 page not found\n")
        let legacy = await pollFailure()
        XCTAssertEqual(legacy, .terminal(message: UpdateRequirement.serverMessage))
        stub.reply(404, problem(404, "not_found"))
        let removed = await pollFailure()
        XCTAssertEqual(removed, .terminal(message: "This sign-in request has expired."))
        stub.reply(410, problem(410, "client_upgrade_required"))
        let upgrade = await pollFailure()
        XCTAssertEqual(upgrade, .terminal(message: UpdateRequirement.appMessage))
        stub.reply(503, problem(503, "service_unavailable"))
        let unavailable = await pollFailure()
        XCTAssertEqual(unavailable, .keepPolling)
        stub.fail(.timedOut)
        let offline = await pollFailure()
        XCTAssertEqual(offline, .keepPolling)
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
            XCTAssertEqual(QRLoginViewModel.startFailureMessage(for: error), UpdateRequirement.serverMessage)
        }
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/auth/device/start"])
    }

    /// The view model runs start, a pending poll and the approved poll, waits
    /// for the pending answer's `poll_after` rather than the start interval,
    /// and binds the token pair's account.
    @MainActor
    func testQRSignInFollowsPollAfterAndBindsTheTokenPairAccount() async throws {
        let (model, tokens) = try await qrViewModel()
        stub.sequence([
            .json(201, Self.start_device_login_ok.replacingOccurrences(of: #""interval": 5"#, with: #""interval": 30"#)),
            .json(200, #"{"status":"pending","poll_after":1,"profile_id":"","profile_token":"","temporary":false}"#),
            .json(200, Self.poll_device_login_ok),
        ])
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        // Settling within 10 s shows the loop waited `poll_after` (1 s), not
        // the start `interval` (30 s).
        let state = try await settle(model)
        model.cancel()
        XCTAssertEqual(state, .approved)
        let durable = await tokens.captureDurableAccountAuth()
        XCTAssertEqual(durable?.accountID, "1")
        let access = await tokens.getAccessToken()
        XCTAssertEqual(access, "acc")
        XCTAssertEqual(stub.requestedPaths,
            ["/api/v2/auth/device/start", "/api/v2/auth/device/poll", "/api/v2/auth/device/poll"])
        let poll = try XCTUnwrap(stub.requests.last)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(poll.body)) as? [String: String])
        XCTAssertEqual(body, ["device_code": "dev-1"])
    }

    /// A temporary session belongs to a SiloRemote handoff. Sign-in refuses
    /// it and installs nothing.
    @MainActor
    func testQRSignInRefusesATemporaryApproval() async throws {
        let (model, tokens) = try await qrViewModel()
        let temporary = Self.poll_device_login_ok
            .replacingOccurrences(of: #""profile_id": """#, with: #""profile_id": "remote-profile""#)
            .replacingOccurrences(of: #""profile_token": """#, with: #""profile_token": "remote-proof""#)
            .replacingOccurrences(of: #""temporary": false"#,
                with: #""temporary": true, "session_expires_at": "2026-01-02T03:14:05.678Z""#)
        // The answer passes wire validation, so the refusal is the sign-in's own.
        let decoded = try HTTPClient.makeJSONDecoder().decode(APIv2DevicePoll.self, from: Data(temporary.utf8)).validated()
        XCTAssertTrue(decoded.temporary)
        stub.sequence([.json(201, Self.start_device_login_ok), .json(200, temporary)])
        await model.begin(deviceName: "TV", devicePlatform: "tvos")
        let state = try await settle(model)
        model.cancel()
        XCTAssertEqual(state, .error(message: APIv2Error.incompleteAuthResponse.localizedDescription))
        let access = await tokens.getAccessToken()
        XCTAssertNil(access)
        let durable = await tokens.captureDurableAccountAuth()
        XCTAssertNil(durable)
        XCTAssertEqual(stub.requestedPaths, ["/api/v2/auth/device/start", "/api/v2/auth/device/poll"])
    }

    @MainActor
    private func qrViewModel() async throws -> (QRLoginViewModel, TokenStore) {
        let (api, tokens) = try await harness()
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        let name = "AuthDeviceV2Tests.auth.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let auth = AuthService(launchPreferences: ProfileLaunchPreferences(defaults: SharedDefaults(suite: suite, standard: suite)),
            apiV2Client: api, httpClient: http, tokenStore: tokens)
        return (QRLoginViewModel(auth: auth, tokenStore: tokens), tokens)
    }

    /// Waits for the QR flow to reach `.approved` or `.error`.
    @MainActor
    private func settle(_ model: QRLoginViewModel, timeout: TimeInterval = 10) async throws -> QRLoginViewModel.State {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch model.state {
            case .approved, .error: return model.state
            case .idle, .starting, .awaiting: try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        XCTFail("QR sign-in did not settle: \(model.state)")
        return model.state
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
