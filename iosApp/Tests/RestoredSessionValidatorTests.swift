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
    }

    func testSuccessfulAccountProbeAcceptsRenamedUsernameSession() async {
        let harness = ValidationHarness(
            identity: expected,
            account: UserInfo(id: "42", username: "renamed-user", isAdmin: false)
        )

        let result = await makeValidator(harness).validate(expected: expected)

        XCTAssertEqual(result, .valid)
    }

    func testServerThatNeedsSetupEntersRecoveryWithoutAccountProbe() async {
        let harness = ValidationHarness(
            identity: expected,
            setupStatus: SetupStatus(needsSetup: true)
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
            setupFailure: .http(statusCode: 404, body: nil)
        )

        let result = await makeValidator(harness).validate(expected: expected)
        let hasAccessToken = await harness.hasAccessToken(serverID: expected.serverId)

        XCTAssertEqual(result, .serverRecovery(.serverNotRecognized))
        XCTAssertTrue(hasAccessToken)
    }

    func testMalformedSetupResponseEntersNonDestructiveServerRecovery() async {
        let harness = ValidationHarness(
            identity: expected,
            setupFailure: .decodingFailed(
                type: "SetupStatus",
                underlying: NSError(domain: "RestoredSessionValidatorTests", code: 1)
            )
        )

        let result = await makeValidator(harness).validate(expected: expected)
        let hasAccessToken = await harness.hasAccessToken(serverID: expected.serverId)

        XCTAssertEqual(result, .serverRecovery(.serverNotRecognized))
        XCTAssertTrue(hasAccessToken)
    }

    func testTransientSetupFailuresRemainIndeterminateAndPreserveToken() async {
        let failures: [HTTPError] = [
            .network(underlying: URLError(.cannotFindHost)),
            .http(statusCode: 408, body: nil),
            .http(statusCode: 429, body: nil),
            .http(statusCode: 500, body: nil),
            .http(statusCode: 503, body: nil),
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
            accountFailure: .http(statusCode: 401, body: nil),
            identityAfterAccountFailure: replacementIdentity,
            hasAccessTokenAfterAccountFailure: false
        )

        let result = await makeValidator(harness).validate(expected: expected)

        XCTAssertEqual(result, .needsLogin)
    }

    func testTransientAccountFailureKeepsRestoredSession() async {
        let harness = ValidationHarness(
            identity: expected,
            accountFailure: .http(statusCode: 503, body: nil)
        )

        let result = await makeValidator(harness).validate(expected: expected)
        let hasAccessToken = await harness.hasAccessToken(serverID: expected.serverId)

        XCTAssertEqual(result, .indeterminate)
        XCTAssertTrue(hasAccessToken)
    }

    func testAccountUnauthorizedWithTokenStillPresentIsIndeterminate() async {
        let harness = ValidationHarness(
            identity: expected,
            accountFailure: .http(statusCode: 401, body: nil)
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
            accessTokenReader: { serverID in await harness.hasAccessToken(serverID: serverID) }
        )
    }
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
    private let setupStatus: SetupStatus
    private let setupFailure: HTTPError?
    private let setupCancellation: Bool
    private let accountFailure: HTTPError?
    private let account: UserInfo
    private let identityAfterSetup: RefreshAccountIdentity?
    private let identityAfterAccountFailure: RefreshAccountIdentity?
    private let hasAccessTokenAfterAccountFailure: Bool
    private var accessTokenPresent = true
    private var accountProbes = 0

    init(
        identity: RefreshAccountIdentity,
        setupStatus: SetupStatus = SetupStatus(needsSetup: false),
        setupFailure: HTTPError? = nil,
        setupCancellation: Bool = false,
        accountFailure: HTTPError? = nil,
        account: UserInfo = UserInfo(id: "42", username: "original-user", isAdmin: false),
        identityAfterSetup: RefreshAccountIdentity? = nil,
        identityAfterAccountFailure: RefreshAccountIdentity? = nil,
        hasAccessTokenAfterAccountFailure: Bool = true
    ) {
        self.identity = identity
        self.setupStatus = setupStatus
        self.setupFailure = setupFailure
        self.setupCancellation = setupCancellation
        self.accountFailure = accountFailure
        self.account = account
        self.identityAfterSetup = identityAfterSetup
        self.identityAfterAccountFailure = identityAfterAccountFailure
        self.hasAccessTokenAfterAccountFailure = hasAccessTokenAfterAccountFailure
    }

    func probeSetup(serverURL: String) throws -> SetupStatus {
        if setupCancellation { throw CancellationError() }
        if let setupFailure { throw setupFailure }
        if let identityAfterSetup { identity = identityAfterSetup }
        return setupStatus
    }

    func probeAccount() throws -> UserInfo {
        accountProbes += 1
        if let accountFailure {
            if let identityAfterAccountFailure { identity = identityAfterAccountFailure }
            accessTokenPresent = hasAccessTokenAfterAccountFailure
            throw accountFailure
        }
        return account
    }

    func currentIdentity() -> RefreshAccountIdentity? { identity }

    func hasAccessToken(serverID: String) -> Bool {
        identity?.serverId == serverID && accessTokenPresent
    }

    func accountProbeCount() -> Int { accountProbes }
}
