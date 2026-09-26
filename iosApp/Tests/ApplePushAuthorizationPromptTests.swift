#if os(iOS)
import UserNotifications
import XCTest
@testable import Silo

/// The notification permission prompt that `prepareForAuthenticatedProfile()`
/// starts. ContentView awaits `prepare` on the session hydration chain, so it
/// must return while the system alert is still waiting for the user, ask only
/// once, and register for remote notifications only when the user allows.
@MainActor
final class ApplePushAuthorizationPromptTests: XCTestCase {
    private struct PromptFailure: Error {}

    /// Stands in for UNUserNotificationCenter, UIApplication and AuthService.
    /// A permission request suspends until the test answers it, like the
    /// system alert does.
    @MainActor
    private final class FakeAuthorization {
        var hasProfile = true
        var status: UNAuthorizationStatus = .notDetermined
        /// Fulfilled when the next permission request starts.
        var requestStarted: XCTestExpectation?
        /// When set, requests answer with this at once instead of waiting.
        var immediateAnswer: Bool?
        private(set) var statusReadCount = 0
        private(set) var requestCount = 0
        private(set) var registerCount = 0
        private var pendingAnswers: [CheckedContinuation<Bool, Error>] = []

        var client: ApplePushAuthorizationClient {
            ApplePushAuthorizationClient(
                hasAuthenticatedProfile: { [self] in hasProfile },
                authorizationStatus: { [self] in
                    statusReadCount += 1
                    return status
                },
                requestAuthorization: { [self] in
                    requestCount += 1
                    requestStarted?.fulfill()
                    requestStarted = nil
                    if let immediateAnswer { return immediateAnswer }
                    return try await withCheckedThrowingContinuation { pendingAnswers.append($0) }
                },
                registerForRemoteNotifications: { [self] in registerCount += 1 }
            )
        }

        func resume(granted: Bool) {
            let answers = pendingAnswers
            pendingAnswers.removeAll()
            answers.forEach { $0.resume(returning: granted) }
        }

        func fail() {
            let answers = pendingAnswers
            pendingAnswers.removeAll()
            answers.forEach { $0.resume(throwing: PromptFailure()) }
        }
    }

    private var fake: FakeAuthorization!
    private var coordinator: ApplePushRegistrationCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        fake = FakeAuthorization()
        coordinator = ApplePushRegistrationCoordinator(authorization: fake.client)
    }

    override func tearDown() async throws {
        // Answer anything still waiting, including a request that has not
        // reached the fake yet, so no test leaves a suspended task behind.
        fake.immediateAnswer = false
        fake.resume(granted: false)
        await coordinator.pendingAuthorizationRequest?.value
        fake = nil
        coordinator = nil
        try await super.tearDown()
    }

    /// Calls `prepare` and waits up to two seconds for it to return, so a
    /// `prepare` that waits for the user's answer fails the test instead of
    /// hanging it.
    private func prepareExpectingReturn() async {
        let returned = expectation(description: "prepare returned")
        let coordinator = coordinator!
        Task {
            await coordinator.prepareForAuthenticatedProfile()
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)
    }

    /// Regression: `prepare` used to await the system alert, which held
    /// download capability hydration and queued Downloads links until the
    /// user answered.
    func testPromptDoesNotHoldPrepareUntilTheUserAnswers() async throws {
        let requestStarted = expectation(description: "permission requested")
        fake.requestStarted = requestStarted

        await prepareExpectingReturn()
        await fulfillment(of: [requestStarted], timeout: 2)

        XCTAssertEqual(fake.requestCount, 1)
        XCTAssertEqual(fake.registerCount, 0)
        let request = try XCTUnwrap(coordinator.pendingAuthorizationRequest)

        fake.resume(granted: true)
        await request.value

        XCTAssertEqual(fake.registerCount, 1)
        XCTAssertNil(coordinator.pendingAuthorizationRequest)
    }

    func testPrepareWhilePromptIsOpenDoesNotAskAgain() async throws {
        let requestStarted = expectation(description: "permission requested")
        fake.requestStarted = requestStarted

        await prepareExpectingReturn()
        await fulfillment(of: [requestStarted], timeout: 2)
        let request = try XCTUnwrap(coordinator.pendingAuthorizationRequest)

        await prepareExpectingReturn()
        XCTAssertEqual(coordinator.pendingAuthorizationRequest, request)

        fake.resume(granted: true)
        await request.value

        XCTAssertEqual(fake.requestCount, 1)
        XCTAssertEqual(fake.registerCount, 1)
    }

    func testDeclinedPromptDoesNotRegisterForRemoteNotifications() async throws {
        let requestStarted = expectation(description: "permission requested")
        fake.requestStarted = requestStarted

        await prepareExpectingReturn()
        await fulfillment(of: [requestStarted], timeout: 2)
        let request = try XCTUnwrap(coordinator.pendingAuthorizationRequest)
        fake.resume(granted: false)
        await request.value

        XCTAssertEqual(fake.registerCount, 0)
        XCTAssertNil(coordinator.pendingAuthorizationRequest)

        fake.status = .denied
        await prepareExpectingReturn()

        XCTAssertEqual(fake.requestCount, 1)
        XCTAssertEqual(fake.registerCount, 0)
        XCTAssertNil(coordinator.pendingAuthorizationRequest)
    }

    func testFailedPromptDoesNotRegisterForRemoteNotifications() async throws {
        let requestStarted = expectation(description: "permission requested")
        fake.requestStarted = requestStarted

        await prepareExpectingReturn()
        await fulfillment(of: [requestStarted], timeout: 2)
        let request = try XCTUnwrap(coordinator.pendingAuthorizationRequest)
        fake.fail()
        await request.value

        XCTAssertEqual(fake.requestCount, 1)
        XCTAssertEqual(fake.registerCount, 0)
        XCTAssertNil(coordinator.pendingAuthorizationRequest)
    }

    func testAuthorizedStatusRegistersWithoutPrompting() async {
        for status in [UNAuthorizationStatus.authorized, .provisional, .ephemeral] {
            let fake = FakeAuthorization()
            fake.status = status
            let coordinator = ApplePushRegistrationCoordinator(authorization: fake.client)

            await coordinator.prepareForAuthenticatedProfile()

            XCTAssertEqual(fake.registerCount, 1, "status \(status.rawValue)")
            XCTAssertEqual(fake.requestCount, 0, "status \(status.rawValue)")
            XCTAssertNil(coordinator.pendingAuthorizationRequest, "status \(status.rawValue)")
        }
    }

    func testNoAuthenticatedProfileDoesNothing() async {
        fake.hasProfile = false

        await coordinator.prepareForAuthenticatedProfile()

        XCTAssertEqual(fake.statusReadCount, 0)
        XCTAssertEqual(fake.requestCount, 0)
        XCTAssertEqual(fake.registerCount, 0)
        XCTAssertNil(coordinator.pendingAuthorizationRequest)
    }
}
#endif
