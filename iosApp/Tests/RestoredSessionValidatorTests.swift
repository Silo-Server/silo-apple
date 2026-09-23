import XCTest
@testable import Silo

@MainActor
final class RestoredSessionValidatorTests: XCTestCase {
    private let expected = RefreshAccountIdentity(
        serverId: "server-a",
        serverURL: "https://silo.example",
        credentialGenerationID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    )

    func testLocalStateRequiresServerThenTokenThenProfile() {
        XCTAssertEqual(
            RestoredSessionAuthResolver.localState(
                hasServer: false,
                hasAccessToken: false,
                hasProfile: false
            ),
            .needsServerSetup
        )
        XCTAssertEqual(
            RestoredSessionAuthResolver.localState(
                hasServer: true,
                hasAccessToken: false,
                hasProfile: true
            ),
            .needsLogin
        )
        XCTAssertEqual(
            RestoredSessionAuthResolver.localState(
                hasServer: true,
                hasAccessToken: true,
                hasProfile: false
            ),
            .needsProfile
        )
        XCTAssertEqual(
            RestoredSessionAuthResolver.localState(
                hasServer: true,
                hasAccessToken: true,
                hasProfile: true
            ),
            .authenticated
        )
    }

    func testConfiguredServerAndSuccessfulAccountProbeAreValid() async {
        let harness = ValidationHarness(identity: expected)
        let result = await makeValidator(harness).validate(expected: expected)
        let accountProbeCount = await harness.accountProbeCount()

        XCTAssertEqual(result, .valid)
        XCTAssertEqual(accountProbeCount, 1)
        let recheckCount = await harness.contractRecheckCount()
        XCTAssertEqual(recheckCount, 0, "a v2 verdict needs no re-probe")
    }

    /// The server was updated in place while the recovery screen showed the
    /// update copy: the setup read now succeeds, the re-probe answers v2, and
    /// the account read goes ahead instead of repeating "still needs to be
    /// updated".
    func testUpdateRequiredVerdictIsRecheckedBeforeAccountRead() async {
        let harness = ValidationHarness(identity: expected, updateRequired: true, recheckAnswersV2: true)

        let result = await makeValidator(harness).validate(expected: expected)
        let recheckCount = await harness.contractRecheckCount()
        let accountProbeCount = await harness.accountProbeCount()

        XCTAssertEqual(result, .valid)
        XCTAssertEqual(recheckCount, 1)
        XCTAssertEqual(accountProbeCount, 1)
    }

    func testUpdateRequiredVerdictThatSurvivesRecheckSkipsAccountRead() async {
        let harness = ValidationHarness(identity: expected, updateRequired: true, recheckAnswersV2: false)

        let result = await makeValidator(harness).validate(expected: expected)
        let recheckCount = await harness.contractRecheckCount()
        let accountProbeCount = await harness.accountProbeCount()
        let hasAccessToken = await harness.hasAccessToken(serverID: expected.serverId)

        XCTAssertEqual(result, .serverRecovery(.serverUpdateRequired))
        XCTAssertEqual(recheckCount, 1)
        XCTAssertEqual(accountProbeCount, 0)
        XCTAssertTrue(hasAccessToken)
    }

    func testServerThatNeedsSetupEntersRecoveryWithoutAccountProbe() async {
        let harness = ValidationHarness(
            identity: expected,
            setupStatus: APIv2SetupStatus(needsSetup: true)
        )

        let result = await makeValidator(harness).validate(expected: expected)
        let accountProbeCount = await harness.accountProbeCount()
        let hasAccessToken = await harness.hasAccessToken(serverID: expected.serverId)

        XCTAssertEqual(result, .serverRecovery(.needsSetup))
        XCTAssertEqual(accountProbeCount, 0)
        XCTAssertTrue(hasAccessToken)
    }

    func testSetupNotFoundEntersNonDestructiveServerRecovery() async {
        let harness = ValidationHarness(
            identity: expected,
            setupFailure: APIv2Error.httpStatus(404)
        )

        let result = await makeValidator(harness).validate(expected: expected)
        let hasAccessToken = await harness.hasAccessToken(serverID: expected.serverId)

        XCTAssertEqual(result, .serverRecovery(.serverNotRecognized))
        XCTAssertTrue(hasAccessToken)
    }

    func testMalformedSetupResponseEntersNonDestructiveServerRecovery() async {
        let harness = ValidationHarness(
            identity: expected,
            setupFailure: HTTPError.decodingFailed(
                type: "APIv2SetupStatus",
                underlying: NSError(domain: "RestoredSessionValidatorTests", code: 1)
            )
        )

        let result = await makeValidator(harness).validate(expected: expected)
        let hasAccessToken = await harness.hasAccessToken(serverID: expected.serverId)

        XCTAssertEqual(result, .serverRecovery(.serverNotRecognized))
        XCTAssertTrue(hasAccessToken)
    }

    func testTransientSetupFailuresRemainIndeterminateAndPreserveToken() async {
        let failures: [Error] = [
            HTTPError.network(underlying: URLError(.cannotFindHost)),
            APIv2Error.httpStatus(408),
            APIv2Error.httpStatus(429),
            APIv2Error.httpStatus(500),
            APIv2Error.httpStatus(503),
        ]

        for failure in failures {
            let harness = ValidationHarness(identity: expected, setupFailure: failure)
            let result = await makeValidator(harness).validate(expected: expected)
            let hasAccessToken = await harness.hasAccessToken(serverID: expected.serverId)
            XCTAssertEqual(result, .indeterminate, "Expected \(failure) to be retryable")
            XCTAssertTrue(hasAccessToken)
        }
    }

    func testCancelledProbeIsIndeterminateAndPreservesToken() async {
        let harness = ValidationHarness(identity: expected, setupCancellation: true)

        let result = await makeValidator(harness).validate(expected: expected)
        let hasAccessToken = await harness.hasAccessToken(serverID: expected.serverId)

        XCTAssertEqual(result, .indeterminate)
        XCTAssertTrue(hasAccessToken)
    }

    func testDeletedAccountTerminalRejectionRoutesToLogin() async {
        let replacementIdentity = RefreshAccountIdentity(
            serverId: expected.serverId,
            serverURL: expected.serverURL,
            credentialGenerationID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )
        let harness = ValidationHarness(
            identity: expected,
            accountFailure: APIv2Error.httpStatus(401),
            identityAfterAccountFailure: replacementIdentity,
            hasAccessTokenAfterAccountFailure: false
        )

        let result = await makeValidator(harness).validate(expected: expected)

        XCTAssertEqual(result, .needsLogin)
    }

    func testTransientAccountFailureKeepsRestoredSession() async {
        let harness = ValidationHarness(
            identity: expected,
            accountFailure: APIv2Error.httpStatus(503)
        )

        let result = await makeValidator(harness).validate(expected: expected)
        let hasAccessToken = await harness.hasAccessToken(serverID: expected.serverId)

        XCTAssertEqual(result, .indeterminate)
        XCTAssertTrue(hasAccessToken)
    }

    func testAccountUnauthorizedWithTokenStillPresentIsIndeterminate() async {
        let harness = ValidationHarness(
            identity: expected,
            accountFailure: APIv2Error.httpStatus(401)
        )

        let result = await makeValidator(harness).validate(expected: expected)
        let hasAccessToken = await harness.hasAccessToken(serverID: expected.serverId)

        XCTAssertEqual(result, .indeterminate)
        XCTAssertTrue(hasAccessToken)
    }

    func testLateSetupResultCannotValidateDifferentCredentialGeneration() async {
        let replacementIdentity = RefreshAccountIdentity(
            serverId: expected.serverId,
            serverURL: expected.serverURL,
            credentialGenerationID: UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        )
        let harness = ValidationHarness(
            identity: expected,
            identityAfterSetup: replacementIdentity
        )

        let result = await makeValidator(harness).validate(expected: expected)
        let accountProbeCount = await harness.accountProbeCount()

        XCTAssertEqual(result, .identityChanged)
        XCTAssertEqual(accountProbeCount, 0)
    }

    /// Cold-launch validation through the production composition
    /// (`RestoredSessionValidator.live(client:tokenStore:)`): v2 setup, then
    /// the v2 account read, against stubbed replies and a real token store.
    /// A version mismatch shows the update copy, a 404 keeps the recovery
    /// screen, and only a refresh the server rejects signs the user out.
    func testV2RepliesKeepRecoveryUpdateAndLoginOutcomes() async throws {
        let setupPath = "/api/v2/system/setup"
        let accountPath = "/api/v2/account/me"
        let setupOK = StubURLProtocol.Response.json(#"{"needs_setup":false,"wizard_completed":true}"#)
        let account = StubURLProtocol.Response.json(
            #"{"id":"42","username":"alice","email":"","role":"user","permissions":[],"download_allowed":true}"#)
        let legacyNotFound = StubURLProtocol.Response.text(
            UpdateRequirementTests.legacyNotFound, status: 404, contentType: "text/plain; charset=utf-8")
        let proxyNotFound = StubURLProtocol.Response.text("<h1>Not Found</h1>", status: 404, contentType: "text/html")
        let upgrade = Self.problem(status: 410, body: UpdateRequirementTests.upgradeProblem)
        let notFound = Self.problem(status: 404, type: "not_found")
        let unavailable = Self.problem(status: 503, type: "service_unavailable")
        let unauthorized = Self.problem(status: 401, type: "invalid_token")

        struct Case {
            let name: String
            let setup: StubURLProtocol.Response
            var account: StubURLProtocol.Response? = nil
            var refresh: StubURLProtocol.Response? = nil
            let expected: RestoredSessionValidationResult
            var keepsToken = true
            var paths: [String]
        }
        let cases = [
            Case(name: "valid", setup: setupOK, account: account, expected: .valid,
                 paths: [setupPath, accountPath]),
            Case(name: "setup legacy 404", setup: legacyNotFound, expected: .serverRecovery(.serverUpdateRequired),
                 paths: [setupPath]),
            Case(name: "setup 410 upgrade", setup: upgrade, expected: .serverRecovery(.appUpdateRequired),
                 paths: [setupPath]),
            Case(name: "setup problem 404", setup: notFound, expected: .serverRecovery(.serverNotRecognized),
                 paths: [setupPath]),
            Case(name: "setup proxy 404", setup: proxyNotFound, expected: .serverRecovery(.serverNotRecognized),
                 paths: [setupPath]),
            Case(name: "account legacy 404", setup: setupOK, account: legacyNotFound,
                 expected: .serverRecovery(.serverUpdateRequired), paths: [setupPath, accountPath]),
            Case(name: "account 410 upgrade", setup: setupOK, account: upgrade,
                 expected: .serverRecovery(.appUpdateRequired), paths: [setupPath, accountPath]),
            Case(name: "account problem 404", setup: setupOK, account: notFound,
                 expected: .serverRecovery(.serverNotRecognized), paths: [setupPath, accountPath]),
            Case(name: "account 503", setup: setupOK, account: unavailable, expected: .indeterminate,
                 paths: [setupPath, accountPath]),
            Case(name: "revoked: 401, refresh rejected", setup: setupOK, account: unauthorized,
                 refresh: Self.problem(status: 401, type: "session_expired"), expected: .needsLogin,
                 keepsToken: false, paths: [setupPath, accountPath, HTTPClient.refreshPath]),
            Case(name: "401, refresh unavailable", setup: setupOK, account: unauthorized, refresh: unavailable,
                 expected: .indeterminate, paths: [setupPath, accountPath, HTTPClient.refreshPath]),
        ]

        for c in cases {
            let stub = StubURLProtocol.Handler()
            stub.route(StubURLProtocol.method("GET", path: setupPath)) { _ in c.setup }
            if let reply = c.account {
                stub.route(StubURLProtocol.method("GET", path: accountPath)) { _ in reply }
            }
            if let reply = c.refresh {
                stub.route(StubURLProtocol.method("POST", path: HTTPClient.refreshPath)) { _ in reply }
            }
            let tokens = try await makeTokenStore()
            let validator = RestoredSessionValidator.live(client: APIv2Client(
                http: HTTPClient(session: stub.makeSession(), tokenStore: tokens),
                tokenStore: tokens, isUpdateRequired: { false }), tokenStore: tokens,
                isServerUpdateRequired: { false }, contractRecheck: {})
            let identity = await tokens.refreshAccountIdentity()
            let restored = try XCTUnwrap(identity, c.name)

            let result = await validator.validate(expected: restored)
            let hasAccessToken = await tokens.hasAccessTokenForActiveServer(serverId: restored.serverId)

            XCTAssertEqual(result, c.expected, c.name)
            XCTAssertEqual(hasAccessToken, c.keepsToken, c.name)
            XCTAssertEqual(stub.requests.map(\.path), c.paths, c.name)
        }
    }

    /// A v1-only verdict that a re-probe confirms refuses the account read
    /// before it leaves the device and reads as update-required, never as a
    /// sign-out. One the re-probe clears lets the gated account read through
    /// the same client.
    func testUpdateRequiredVerdictGatesAccountReadUntilRecheckClearsIt() async throws {
        for recheckAnswersV2 in [false, true] {
            let stub = StubURLProtocol.Handler()
            stub.route(StubURLProtocol.method("GET", path: "/api/v2/system/setup")) { _ in
                .json(#"{"needs_setup":false,"wizard_completed":true}"#)
            }
            stub.route(StubURLProtocol.method("GET", path: "/api/v2/account/me")) { _ in
                .json(#"{"id":"42","username":"alice","email":"","role":"user","permissions":[],"download_allowed":true}"#)
            }
            let tokens = try await makeTokenStore()
            let verdict = VerdictBox(updateRequired: true)
            let validator = RestoredSessionValidator.live(
                client: APIv2Client(
                    http: HTTPClient(session: stub.makeSession(), tokenStore: tokens),
                    tokenStore: tokens, isUpdateRequired: { await verdict.updateRequired }),
                tokenStore: tokens,
                isServerUpdateRequired: { await verdict.updateRequired },
                contractRecheck: { if recheckAnswersV2 { await verdict.set(updateRequired: false) } })
            let identity = await tokens.refreshAccountIdentity()
            let restored = try XCTUnwrap(identity)

            let result = await validator.validate(expected: restored)
            let hasAccessToken = await tokens.hasAccessTokenForActiveServer(serverId: restored.serverId)

            let name = recheckAnswersV2 ? "re-probe answers v2" : "re-probe still v1-only"
            XCTAssertEqual(result, recheckAnswersV2 ? .valid : .serverRecovery(.serverUpdateRequired), name)
            XCTAssertTrue(hasAccessToken, name)
            XCTAssertEqual(
                stub.requests.map(\.path),
                recheckAnswersV2 ? ["/api/v2/system/setup", "/api/v2/account/me"] : ["/api/v2/system/setup"],
                name)
        }
    }

    private static func problem(status: Int, type: String) -> StubURLProtocol.Response {
        problem(status: status, body: """
        {"type":"https://siloserver.org/docs/api/v2/problems/\(type)","title":"\(type)","status":\(status),"detail":""}
        """)
    }

    private static func problem(status: Int, body: String) -> StubURLProtocol.Response {
        .json(body, status: status, headers: ["Content-Type": "application/problem+json"])
    }

    private func makeTokenStore() async throws -> TokenStore {
        let name = "RestoredSessionValidatorTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        addTeardownBlock {
            _ = await tokens.clearTokens()
            UserDefaults().removePersistentDomain(forName: name)
        }
        await tokens.switchActiveServer(serverId: expected.serverId)
        await tokens.setServerUrl(expected.serverURL)
        let saved = await tokens.saveTokens(accessToken: "access", refreshToken: "refresh")
        XCTAssertTrue(saved)
        return tokens
    }

    func testConfirmedForgetCompletesAndRoutesOutsideTheRecoveryViewLifetime() async throws {
        let gate = ServerRemovalGate()
        let router = AppRouter()
        router.authState = .serverRecovery(.serverNotRecognized)
        let coordinator = RestoredServerRecoveryCoordinator(
            removeServer: { serverID in
                await gate.remove(serverID: serverID)
            },
            resolveDestination: { .needsServerSetup }
        )

        let task = try XCTUnwrap(coordinator.forget(serverID: "server-a", router: router))
        XCTAssertTrue(coordinator.isForgetting)
        await gate.allowRemoval()
        await task.value

        let removedServerID = await gate.removedServerID()
        XCTAssertEqual(removedServerID, "server-a")
        XCTAssertFalse(coordinator.isForgetting)
        XCTAssertNil(coordinator.error)
        XCTAssertEqual(router.authState, .needsServerSetup)
    }

    private func makeValidator(_ harness: ValidationHarness) -> RestoredSessionValidator {
        RestoredSessionValidator(
            setupProbe: { serverURL in try await harness.probeSetup(serverURL: serverURL) },
            accountProbe: { try await harness.probeAccount() },
            identityReader: { await harness.currentIdentity() },
            accessTokenReader: { serverID in await harness.hasAccessToken(serverID: serverID) },
            isServerUpdateRequired: { await harness.isServerUpdateRequired() },
            contractRecheck: { await harness.recheckContract() }
        )
    }
}

private actor VerdictBox {
    private(set) var updateRequired: Bool

    init(updateRequired: Bool) { self.updateRequired = updateRequired }

    func set(updateRequired: Bool) { self.updateRequired = updateRequired }
}

private actor ServerRemovalGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isRemovalAllowed = false
    private var serverID: String?

    func remove(serverID: String) async -> Bool {
        self.serverID = serverID
        if !isRemovalAllowed {
            await withCheckedContinuation { continuation = $0 }
        }
        return true
    }

    func allowRemoval() {
        isRemovalAllowed = true
        continuation?.resume()
        continuation = nil
    }

    func removedServerID() -> String? { serverID }
}

private actor ValidationHarness {
    private var identity: RefreshAccountIdentity?
    private let setupStatus: APIv2SetupStatus
    private let setupFailure: Error?
    private let setupCancellation: Bool
    private let accountFailure: Error?
    private let identityAfterSetup: RefreshAccountIdentity?
    private let identityAfterAccountFailure: RefreshAccountIdentity?
    private let hasAccessTokenAfterAccountFailure: Bool
    private var accessTokenPresent = true
    private var accountProbes = 0
    private var updateRequired: Bool
    private let recheckAnswersV2: Bool
    private var contractRechecks = 0

    init(
        identity: RefreshAccountIdentity,
        setupStatus: APIv2SetupStatus = APIv2SetupStatus(needsSetup: false),
        setupFailure: Error? = nil,
        setupCancellation: Bool = false,
        accountFailure: Error? = nil,
        identityAfterSetup: RefreshAccountIdentity? = nil,
        identityAfterAccountFailure: RefreshAccountIdentity? = nil,
        hasAccessTokenAfterAccountFailure: Bool = true,
        updateRequired: Bool = false,
        recheckAnswersV2: Bool = false
    ) {
        self.identity = identity
        self.setupStatus = setupStatus
        self.setupFailure = setupFailure
        self.setupCancellation = setupCancellation
        self.accountFailure = accountFailure
        self.identityAfterSetup = identityAfterSetup
        self.identityAfterAccountFailure = identityAfterAccountFailure
        self.hasAccessTokenAfterAccountFailure = hasAccessTokenAfterAccountFailure
        self.updateRequired = updateRequired
        self.recheckAnswersV2 = recheckAnswersV2
    }

    func isServerUpdateRequired() -> Bool { updateRequired }

    func recheckContract() {
        contractRechecks += 1
        if recheckAnswersV2 { updateRequired = false }
    }

    func contractRecheckCount() -> Int { contractRechecks }

    func probeSetup(serverURL: String) throws -> APIv2SetupStatus {
        if setupCancellation { throw CancellationError() }
        if let setupFailure { throw setupFailure }
        if let identityAfterSetup { identity = identityAfterSetup }
        return setupStatus
    }

    func probeAccount() throws {
        accountProbes += 1
        if let accountFailure {
            if let identityAfterAccountFailure { identity = identityAfterAccountFailure }
            accessTokenPresent = hasAccessTokenAfterAccountFailure
            throw accountFailure
        }
    }

    func currentIdentity() -> RefreshAccountIdentity? { identity }

    func hasAccessToken(serverID: String) -> Bool {
        identity?.serverId == serverID && accessTokenPresent
    }

    func accountProbeCount() -> Int { accountProbes }
}
