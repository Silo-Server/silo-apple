import XCTest
@testable import Silo

final class OnboardingInvitationTests: XCTestCase {
    override func setUp() {
        super.setUp()
        OnboardingRequestStubProtocol.reset()
    }

    func testServerEndpointCanonicalizesTrustedOrigins() throws {
        let endpoint = try XCTUnwrap(ServerEndpoint(rawValue: " HTTPS://Example.COM:8443/silo/ "))
        XCTAssertEqual(endpoint.baseURL, "https://example.com:8443/silo")
        XCTAssertEqual(endpoint.displayHost, "example.com:8443")

        let defaultPort = try XCTUnwrap(ServerEndpoint(rawValue: "https://Example.com:443/"))
        XCTAssertEqual(defaultPort.baseURL, "https://example.com")
        XCTAssertEqual(defaultPort.displayHost, "example.com")
    }

    func testServerEndpointRejectsNonHTTPAndAmbiguousURLs() {
        XCTAssertNil(ServerEndpoint(rawValue: "file:///etc/passwd"))
        XCTAssertNil(ServerEndpoint(rawValue: "https://user:pass@example.com"))
        XCTAssertNil(ServerEndpoint(rawValue: "https://example.com?silo=other"))
        XCTAssertNil(ServerEndpoint(rawValue: "https://example.com/#fragment"))
    }

    func testInvitationLinkAcceptsOnlyTheInviteRouteAndSafeToken() throws {
        var components = try XCTUnwrap(URLComponents(string: "silo://invite"))
        components.queryItems = [
            URLQueryItem(name: "server", value: "https://Example.com/silo/"),
            URLQueryItem(name: "token", value: "claim-token_123"),
        ]
        let claim = try XCTUnwrap(InvitationClaimLink(url: try XCTUnwrap(components.url)))
        XCTAssertEqual(claim.endpoint.baseURL, "https://example.com/silo")
        XCTAssertEqual(claim.token, "claim-token_123")

        XCTAssertNil(InvitationClaimLink(url: URL(string: "continuum://invite?server=https://example.com&token=abc")!))
        XCTAssertNil(InvitationClaimLink(url: URL(string: "silo://item?server=https://example.com&token=abc")!))
        XCTAssertNil(InvitationClaimLink(url: URL(string: "silo://invite?server=https://example.com&token=abc/def")!))
    }

    func testFailedInviteLookupDoesNotRetargetActiveLogin() async throws {
        let (http, _) = await makeHTTPClient(activeURL: "https://active.example/silo")
        let invite = try XCTUnwrap(ServerEndpoint(rawValue: "https://invite.example/base"))

        do {
            let _: InvitationLookupResponse = try await http.getAnonymous(
                from: invite,
                "/api/v1/invitations/expired-token"
            )
            XCTFail("The invite lookup should fail")
        } catch let HTTPError.http(statusCode, _) {
            XCTAssertEqual(statusCode, 404)
        }

        let response: LoginResponse = try await http.post(
            "/api/v1/auth/login",
            body: LoginRequest(username: "user", password: "password")
        )
        XCTAssertEqual(response.accessToken, "active-access")

        let requests = OnboardingRequestStubProtocol.requests()
        XCTAssertEqual(requests.map { $0.url?.host }, ["invite.example", "active.example"])
        XCTAssertEqual(requests[0].url?.path, "/base/api/v1/invitations/expired-token")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[1].url?.path, "/silo/api/v1/auth/login")
    }

    func testOnboardingSurfaceUsesAQueryItemInsteadOfEmbeddingQueryInPath() async throws {
        let (http, tokenStore) = await makeHTTPClient(activeURL: "https://active.example/silo")
        let api = ContinuumAPI(http: http, tokenStore: tokenStore)

        let flow = try await api.onboardingFlow(surface: "phone")
        XCTAssertEqual(flow.tourId, "tour-test")

        let request = try XCTUnwrap(OnboardingRequestStubProtocol.requests().last)
        XCTAssertEqual(request.url?.path, "/silo/api/v1/onboarding/flow")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
            .queryItems, [URLQueryItem(name: "surface", value: "phone")])
    }

    @MainActor
    func testSettingTargetsAreAwaitedAndDispatchedToTheirOwnEndpoints() async throws {
        let api = OnboardingTourAPIStub()
        let model = OnboardingTourViewModel(api: api)

        let userStep = Self.settingStep(id: "user", target: "setting", key: "playback.auto_play_next")
        await model.choose(step: userStep, value: "true")
        let deviceStep = Self.settingStep(id: "device", target: "device_setting", key: "playback.quality")
        await model.choose(step: deviceStep, value: "1080p")

        let writes = await api.writes()
        XCTAssertEqual(writes, [
            "setting:playback.auto_play_next=true",
            "device:playback.quality=1080p",
        ])
        XCTAssertEqual(model.selectedValues["user"], "true")
        XCTAssertEqual(model.selectedValues["device"], "1080p")
        XCTAssertNil(model.error)
    }

    @MainActor
    func testFailedSettingWriteStaysVisibleAndDoesNotSelectValue() async {
        let api = OnboardingTourAPIStub(failWrites: true)
        let model = OnboardingTourViewModel(api: api)
        let step = Self.settingStep(id: "failed", target: "setting", key: "playback.auto_play_next")

        await model.choose(step: step, value: "true")

        XCTAssertNil(model.selectedValues["failed"])
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.finished)
    }

    @MainActor
    func testUnrenderableFlowDismissesWhenCompletionPostFails() async {
        let api = OnboardingTourAPIStub(failProgress: true)
        let model = OnboardingTourViewModel(api: api)

        await model.load()

        XCTAssertTrue(model.finished)
        XCTAssertTrue(model.steps.isEmpty)
    }

    private static func settingStep(id: String, target: String, key: String) -> OnboardingStep {
        OnboardingStep(
            id: id,
            kind: "setting_choice",
            title: nil,
            body: nil,
            illustration: nil,
            setting: OnboardingSettingSpec(
                target: target,
                key: key,
                control: "toggle",
                options: nil,
                default: nil,
                label: nil
            ),
            route: nil,
            actionLabel: nil
        )
    }

    private func makeHTTPClient(activeURL: String) async -> (HTTPClient, TokenStore) {
        let suiteName = "onboarding-invite-tests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let tokenStore = TokenStore(
            keychain: SharedKeychain(
                service: "OnboardingInvitationTests.\(UUID().uuidString)",
                accessGroup: nil
            ),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokenStore.setServerUrl(activeURL)
        await tokenStore.switchActiveServer(serverId: "active")
        await tokenStore.saveTokens(accessToken: "existing-access", refreshToken: "existing-refresh")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OnboardingRequestStubProtocol.self]
        return (
            HTTPClient(session: URLSession(configuration: configuration), tokenStore: tokenStore),
            tokenStore
        )
    }
}

private actor OnboardingTourAPIStub: OnboardingTourAPI {
    private var recordedWrites: [String] = []
    private let failWrites: Bool
    private let failProgress: Bool

    init(failWrites: Bool = false, failProgress: Bool = false) {
        self.failWrites = failWrites
        self.failProgress = failProgress
    }

    func writes() -> [String] { recordedWrites }

    func onboardingFlow(surface: String) async throws -> OnboardingFlow {
        OnboardingFlow(version: 1, tourId: "tour", steps: [])
    }

    func postOnboardingProgress(_ request: OnboardingProgressRequest) async throws {
        if failProgress { throw URLError(.cannotConnectToHost) }
    }
    func updateProfile(profileId: String, body: UpdateProfileBody) async throws {}

    func setSetting(key: String, value: String) async throws {
        if failWrites { throw URLError(.cannotConnectToHost) }
        recordedWrites.append("setting:\(key)=\(value)")
    }

    func setDeviceSetting(key: String, value: String) async throws {
        if failWrites { throw URLError(.cannotConnectToHost) }
        recordedWrites.append("device:\(key)=\(value)")
    }
}

private final class OnboardingRequestStubProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var recordedRequests: [URLRequest] = []

    static func reset() {
        lock.withLock { recordedRequests = [] }
    }

    static func requests() -> [URLRequest] {
        lock.withLock { recordedRequests }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.withLock { Self.recordedRequests.append(request) }
        let path = request.url?.path ?? ""
        let host = request.url?.host ?? ""

        let status: Int
        let body: Data
        if host == "invite.example" {
            status = 404
            body = Data(#"{"error":"not_found"}"#.utf8)
        } else if path.hasSuffix("/api/v1/auth/login") {
            status = 200
            body = Data(#"{"access_token":"active-access","refresh_token":"active-refresh","expires_in":3600,"user":{"id":1,"username":"user","email":"user@example.com","role":"user"}}"#.utf8)
        } else if path.hasSuffix("/api/v1/onboarding/flow") {
            status = 200
            body = Data(#"{"version":1,"tour_id":"tour-test","steps":[]}"#.utf8)
        } else {
            status = 500
            body = Data()
        }

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
