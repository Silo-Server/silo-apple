import Foundation
import XCTest
@testable import Silo

/// The shared device-code poll policy behind tvOS QR sign-in, phone-to-TV
/// pairing and the SiloRemote handoff. Each loop test runs on a virtual
/// clock: the scripted `sleep` records the wait and advances `now`, so the
/// deadline and pacing are exact and nothing waits in real time.
@MainActor
final class DeviceLoginPollerTests: XCTestCase {

    // MARK: Retry and pacing

    /// A network loss, a bare 5xx, a 5xx problem and a 429 are all polled
    /// again on the start interval; a pending answer's `poll_after` then
    /// paces the next poll.
    func testTransientFailuresKeepPollingUntilApproved() async throws {
        let script = PollScript([
            .failure(URLError(.networkConnectionLost)),
            .failure(APIv2Error.httpStatus(502)),
            .failure(APIv2Error.problem(problem(503, "service_unavailable"))),
            .failure(APIv2Error.problem(problem(429, "rate_limited"))),
            .success(poll("pending", pollAfter: 2)),
            .success(poll("approved")),
        ])
        let approved = try await script.wait(interval: 3)
        XCTAssertEqual(approved.status, "approved")
        XCTAssertEqual(script.polls, 6)
        XCTAssertEqual(script.sleeps, [3, 3, 3, 3, 2])
    }

    /// The server never answers: the wait stops at the code's own lifetime.
    func testDeadlineEndsTheWaitWhenTheServerNeverAnswers() async {
        let script = PollScript([], otherwise: .failure(URLError(.timedOut)))
        let error = await script.failure(interval: 3, expiresIn: 10)
        XCTAssertEqual(error as? DeviceLoginPoller.Failure, .expired)
        XCTAssertEqual(script.polls, 4) // t = 0, 3, 6, 9
        XCTAssertEqual(script.sleeps, [3, 3, 3, 3])
    }

    func testPendingAnswersHonorPollAfterUntilTheDeadline() async {
        let script = PollScript([], otherwise: .success(poll("pending", pollAfter: 4)))
        let error = await script.failure(interval: 1, expiresIn: 10)
        XCTAssertEqual(error as? DeviceLoginPoller.Failure, .expired)
        XCTAssertEqual(script.polls, 3) // t = 0, 4, 8
        XCTAssertEqual(script.sleeps, [4, 4, 4])
    }

    // MARK: Terminal answers

    func testTerminalStatusesEndTheWaitAfterOnePoll() async {
        let expected: [(String, DeviceLoginPoller.Failure)] = [
            ("denied", .denied), ("expired", .expired), ("consumed", .consumed),
        ]
        for (status, failure) in expected {
            let script = PollScript([.success(poll(status))])
            let error = await script.failure()
            XCTAssertEqual(error as? DeviceLoginPoller.Failure, failure, status)
            XCTAssertEqual(script.polls, 1, status)
            XCTAssertEqual(script.sleeps, [], status)
        }
    }

    /// A 404, as a problem or a bare status, means the server expired and
    /// removed the request.
    func testRemovedRequestEndsTheWait() async {
        for removal in [APIv2Error.problem(problem(404, "not_found")), APIv2Error.httpStatus(404)] {
            let script = PollScript([.failure(removal)])
            let error = await script.failure()
            XCTAssertEqual(error as? DeviceLoginPoller.Failure, .removed)
            XCTAssertEqual(script.polls, 1)
        }
    }

    /// A status outside the contract ends the wait the way
    /// `APIv2DevicePoll.validated()` refuses it on the wire, in every flow.
    func testUnknownStatusEndsTheWaitLikeValidation() async {
        let script = PollScript([.success(poll("slow_down"))])
        let error = await script.failure()
        XCTAssertTrue(isIncompleteAuthResponse(error), String(describing: error))
        XCTAssertEqual(script.polls, 1)
        XCTAssertEqual(script.sleeps, [])
    }

    /// Update requirements, an approval whose tokens cannot be collected
    /// again, and a changed active account end the wait with the poll's own
    /// error, so each flow can word it.
    func testTerminalErrorsAreRethrownUnchanged() async {
        let upgrade = APIv2Error.problem(problem(410, UpdateRequirement.clientUpgradeRequiredProblem))
        let legacy = await PollScript([.failure(APIv2Error.serverUpdateRequired)]).failure()
        XCTAssertEqual(legacy.flatMap { UpdateRequirement($0) }, .server)
        let appUpdate = await PollScript([.failure(upgrade)]).failure()
        XCTAssertEqual(appUpdate.flatMap { UpdateRequirement($0) }, .app)
        let incomplete = await PollScript([.failure(APIv2Error.incompleteAuthResponse)]).failure()
        XCTAssertTrue(isIncompleteAuthResponse(incomplete))
        let identityChanged = await PollScript([.failure(HTTPError.requestIdentityChanged)]).failure()
        guard case HTTPError.requestIdentityChanged? = identityChanged else {
            return XCTFail("identity change expected, got \(String(describing: identityChanged))")
        }
    }

    // MARK: Cancellation

    /// A cancel that lands while an approval is in flight wins: the caller
    /// gets `CancellationError` and never the approval.
    func testCancellationWinsOverAnApprovalThatRacedIt() async {
        let task = Task { @MainActor in
            try await DeviceLoginPoller.waitForApproval(
                interval: 1,
                expiresIn: 60,
                poll: {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return poll("approved")
                },
                sleep: { _ in XCTFail("no wait expected") }
            )
        }
        let result = await task.result
        XCTAssertTrue(isCancellation(result), String(describing: result))
    }

    /// Cancelling during the wait after a transient failure ends with
    /// `CancellationError`, not a failure, and polls no more.
    func testCancellationDuringARetryWaitEndsWithCancellation() async {
        let script = PollScript([.failure(APIv2Error.httpStatus(502))], otherwise: .success(poll("approved")))
        script.onSleep = {
            // The owner cancels while the wait runs, so the sleep throws.
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        let result = await Task { @MainActor in try await script.wait(interval: 30) }.result
        XCTAssertTrue(isCancellation(result), String(describing: result))
        XCTAssertEqual(script.polls, 1)
        XCTAssertEqual(script.sleeps, [30])
    }

    /// A cancel that lands just as the wait reaches the code's expiry still
    /// ends with `CancellationError`, not `.expired`.
    func testCancellationAtTheDeadlineWinsOverExpiry() async {
        let script = PollScript([], otherwise: .failure(APIv2Error.httpStatus(502)))
        script.onSleep = {
            // The wait ran its full length; the cancel lands as it returns.
            withUnsafeCurrentTask { $0?.cancel() }
        }
        let result = await Task { @MainActor in try await script.wait(interval: 3, expiresIn: 3) }.result
        XCTAssertTrue(isCancellation(result), String(describing: result))
        XCTAssertEqual(script.polls, 1)
        XCTAssertEqual(script.sleeps, [3])
    }

    // MARK: SiloRemote handoff

    #if os(tvOS)
    /// Regression: a network blip while the phone approves used to end the
    /// handoff with the raw transport error. The code is still live, so the
    /// TV polls again and collects the approval.
    func testHandoffKeepsPollingThroughATransientFailure() async throws {
        let script = PollScript([
            .failure(URLError(.networkConnectionLost)),
            .success(poll("approved", temporary: true)),
        ])
        let approved = try await RemotePlaybackIdentityManager.awaitApproval(of: handoffStart) { try script.poll() }
        XCTAssertEqual(approved.status, "approved")
        XCTAssertTrue(approved.temporary)
        XCTAssertEqual(script.polls, 2)
    }

    /// The handoff names each terminal outcome the way the phone is told.
    func testHandoffMapsTerminalOutcomes() async {
        func outcome(_ answer: Result<APIv2DevicePoll, Error>) async -> RemotePlaybackIdentityManager.HandoffError? {
            let script = PollScript([answer])
            do {
                _ = try await RemotePlaybackIdentityManager.awaitApproval(of: handoffStart) { try script.poll() }
                XCTFail("handoff failure expected")
            } catch {
                XCTAssertEqual(script.polls, 1)
                return error as? RemotePlaybackIdentityManager.HandoffError
            }
            return nil
        }
        guard case .denied? = await outcome(.success(poll("denied"))) else { return XCTFail("denied") }
        guard case .expired? = await outcome(.success(poll("consumed"))) else { return XCTFail("consumed") }
        guard case .expired? = await outcome(.failure(APIv2Error.httpStatus(404))) else { return XCTFail("bare 404") }
        guard case .invalidResponse? = await outcome(.success(poll("slow_down"))) else { return XCTFail("unknown status") }
    }

    private var handoffStart: DeviceLoginStartResponse {
        DeviceLoginStartResponse(
            deviceCode: "dev-1",
            userCode: "ABCD-1234",
            matchCode: "42",
            verificationUri: "https://silo.example.test/link",
            verificationUriComplete: "https://silo.example.test/link?code=ABCD-1234",
            expiresAt: Date().addingTimeInterval(30),
            expiresIn: 30,
            interval: 1,
            deviceName: "Living room TV",
            devicePlatform: "tvos",
            clientPurpose: "remote_playback",
            temporary: true
        )
    }
    #endif
}

// MARK: - Script

/// Scripted poll answers on a virtual clock.
@MainActor
private final class PollScript {
    private var answers: [Result<APIv2DevicePoll, Error>]
    private let otherwise: Result<APIv2DevicePoll, Error>?
    private var clock = Date(timeIntervalSince1970: 1_000_000)
    private(set) var polls = 0
    private(set) var sleeps: [Int] = []
    /// Runs at the end of each virtual sleep, after the clock has advanced.
    var onSleep: (() throws -> Void)?

    init(_ answers: [Result<APIv2DevicePoll, Error>], otherwise: Result<APIv2DevicePoll, Error>? = nil) {
        self.answers = answers
        self.otherwise = otherwise
    }

    func poll() throws -> APIv2DevicePoll {
        polls += 1
        if !answers.isEmpty { return try answers.removeFirst().get() }
        if let otherwise { return try otherwise.get() }
        XCTFail("unexpected poll #\(polls)")
        throw URLError(.unknown)
    }

    func wait(interval: Int = 3, expiresIn: Int = 600) async throws -> APIv2DevicePoll {
        try await DeviceLoginPoller.waitForApproval(
            interval: interval,
            expiresIn: expiresIn,
            poll: { try self.poll() },
            sleep: { seconds in
                self.sleeps.append(seconds)
                self.clock.addTimeInterval(TimeInterval(seconds))
                try self.onSleep?()
            },
            now: { self.clock }
        )
    }

    /// The error the wait ends with; a failed test when it approves instead.
    func failure(interval: Int = 3, expiresIn: Int = 600) async -> Error? {
        do {
            _ = try await wait(interval: interval, expiresIn: expiresIn)
            XCTFail("the wait was expected to fail")
            return nil
        } catch {
            return error
        }
    }
}

private func poll(_ status: String, pollAfter: Int = 1, temporary: Bool = false) -> APIv2DevicePoll {
    APIv2DevicePoll(status: status, pollAfter: pollAfter, tokens: nil, profileId: "", profileToken: "",
        temporary: temporary, sessionExpiresAt: nil)
}

private func problem(_ status: Int, _ type: String) -> APIv2Problem {
    APIv2Problem(type: "https://siloserver.org/problems/\(type)", title: type, status: status,
        detail: "", instance: nil, errors: nil)
}

private func isIncompleteAuthResponse(_ error: Error?) -> Bool {
    if case APIv2Error.incompleteAuthResponse? = error { return true }
    return false
}

private func isCancellation(_ result: Result<APIv2DevicePoll, Error>) -> Bool {
    if case .failure(let error) = result { return error is CancellationError }
    return false
}
