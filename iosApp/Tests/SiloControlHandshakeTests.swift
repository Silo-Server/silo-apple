#if os(iOS)
import XCTest
@testable import Silo

/// The launch path waits on `SiloControlHandshake` for the TV's hello and
/// handoff replies. These pin what it relies on: frames wake a parked wait,
/// replies are matched to the pending offer and kept if they arrive early,
/// and a closed connection ends every wait at once instead of at its
/// deadline.
@MainActor
final class SiloControlHandshakeTests: XCTestCase {
    /// Production-length deadline for waits that something must resume.
    private let longWait: Duration = .seconds(30)
    /// Far below `longWait`: a wait that ends within this was resumed, not
    /// timed out.
    private let prompt: Duration = .seconds(5)

    func testClosingEndsEveryParkedWaitImmediately() async {
        let handshake = SiloControlHandshake()
        handshake.beginHandoff(requestId: "r1")
        let version = Task { try await handshake.negotiatedVersion(within: longWait) }
        let reply = Task { try await handshake.firstReply(to: "r1", within: longWait) }
        await letWaitsPark()

        let closedAt = ContinuousClock.now
        handshake.close()
        let versionResult = await version.result
        let replyResult = await reply.result

        XCTAssertLessThan(ContinuousClock.now - closedAt, prompt)
        XCTAssertEqual(versionResult.thrown as? SiloControlHandoffError, .connectionClosed)
        XCTAssertEqual(replyResult.thrown as? SiloControlHandoffError, .connectionClosed)

        // A wait that starts after the drop fails without waiting.
        let late = await Task { try await handshake.ready(for: "r1", within: longWait) }.result
        XCTAssertEqual(late.thrown as? SiloControlHandoffError, .connectionClosed)
    }

    func testHelloResumesTheVersionWaitAndStaysForLaterWaits() async throws {
        let handshake = SiloControlHandshake()
        let version = Task { try await handshake.negotiatedVersion(within: longWait) }
        await letWaitsPark()

        let sentAt = ContinuousClock.now
        handshake.receive(.hello(hello(versions: [1, 2])))
        let negotiated = try await version.value

        XCTAssertLessThan(ContinuousClock.now - sentAt, prompt)
        XCTAssertEqual(negotiated, 2)
        let later = try await handshake.negotiatedVersion(within: .milliseconds(1))
        XCTAssertEqual(later, 2)
    }

    func testHelloWithoutACommonVersionAnswersNilAtOnce() async throws {
        let handshake = SiloControlHandshake()
        let version = Task { try await handshake.negotiatedVersion(within: longWait) }
        await letWaitsPark()

        let sentAt = ContinuousClock.now
        handshake.receive(.hello(hello(versions: [99])))
        let negotiated = try await version.value

        XCTAssertLessThan(ContinuousClock.now - sentAt, prompt)
        XCTAssertNil(negotiated)
    }

    func testVersionWaitAnswersNilWhenNoHelloArrives() async throws {
        let handshake = SiloControlHandshake()
        let negotiated = try await handshake.negotiatedVersion(within: .milliseconds(50))
        XCTAssertNil(negotiated)
    }

    func testFirstReplyIsAChallengeOrAnImmediateReady() async throws {
        // A parked wait resumes on the TV's challenge.
        let challenging = SiloControlHandshake()
        challenging.beginHandoff(requestId: "r1")
        let reply = Task { try await challenging.firstReply(to: "r1", within: longWait) }
        await letWaitsPark()
        let sentAt = ContinuousClock.now
        challenging.receive(.handoffChallenge(challenge("r1")))
        let first = try await reply.value
        XCTAssertLessThan(ContinuousClock.now - sentAt, prompt)
        XCTAssertEqual(first, .challenge(challenge("r1")))

        // The TV's ready can land while the phone is still approving the
        // challenge with the server; the ready wait must not miss it.
        challenging.receive(.handoffReady(ready("r1")))
        let approved = try await challenging.ready(for: "r1", within: .milliseconds(1))
        XCTAssertEqual(approved, ready("r1"))

        // A TV that still holds this phone's profile answers ready with no
        // challenge, possibly before the phone starts waiting.
        let reusing = SiloControlHandshake()
        reusing.beginHandoff(requestId: "r2")
        reusing.receive(.handoffReady(ready("r2")))
        let immediate = try await reusing.firstReply(to: "r2", within: .milliseconds(1))
        XCTAssertEqual(immediate, .ready(ready("r2")))
    }

    func testRepliesToOtherRequestsAreIgnored() async {
        let handshake = SiloControlHandshake()
        handshake.beginHandoff(requestId: "r2")
        handshake.receive(.handoffChallenge(challenge("r1")))
        handshake.receive(.handoffReady(ready("r1")))
        handshake.receive(.handoffCancel(cancel("r1", message: "Old offer")))

        let result = await Task { try await handshake.firstReply(to: "r2", within: .milliseconds(100)) }.result
        XCTAssertEqual(result.thrown as? SiloControlHandoffError, .timedOut)
    }

    func testTVCancellationFailsTheWaitWithItsMessage() async {
        let handshake = SiloControlHandshake()
        handshake.beginHandoff(requestId: "r1")
        let waiting = Task { try await handshake.ready(for: "r1", within: longWait) }
        await letWaitsPark()

        let sentAt = ContinuousClock.now
        handshake.receive(.handoffCancel(cancel("r1", message: "The profile is in use.")))
        let result = await waiting.result

        XCTAssertLessThan(ContinuousClock.now - sentAt, prompt)
        XCTAssertEqual(result.thrown as? SiloControlHandoffError, .cancelled("The profile is in use."))
    }

    func testCancellingTheWaitingTaskEndsTheWait() async {
        let handshake = SiloControlHandshake()
        handshake.beginHandoff(requestId: "r1")
        let waiting = Task { try await handshake.firstReply(to: "r1", within: longWait) }
        await letWaitsPark()

        let cancelledAt = ContinuousClock.now
        waiting.cancel()
        let result = await waiting.result

        XCTAssertLessThan(ContinuousClock.now - cancelledAt, prompt)
        XCTAssertTrue(result.thrown is CancellationError)
    }

    func testChangeSignalWakesOnNotifyAndAtTheDeadline() async {
        let signal = SiloControlChangeSignal()
        let parked = Task { await signal.nextChange(before: .now + longWait) }
        await letWaitsPark()
        let notifiedAt = ContinuousClock.now
        signal.notify()
        await parked.value
        XCTAssertLessThan(ContinuousClock.now - notifiedAt, prompt)

        let startedAt = ContinuousClock.now
        await signal.nextChange(before: .now + .milliseconds(50))
        let waited = ContinuousClock.now - startedAt
        XCTAssertGreaterThanOrEqual(waited, .milliseconds(40))
        XCTAssertLessThan(waited, prompt)
    }

    // MARK: - Helpers

    /// Gives waits started in child tasks time to park, so the test drives
    /// the wake path rather than the check a wait makes before parking.
    private func letWaitsPark() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    private func hello(versions: [Int]) -> SiloControlHello {
        SiloControlHello(role: .tv, deviceName: "Living Room", deviceId: "tv-1",
                         serverId: "s1", serverName: nil, supportedVersions: versions)
    }

    private func challenge(_ requestId: String) -> SiloControlHandoffChallenge {
        SiloControlHandoffChallenge(requestId: requestId, userCode: "ABCD-EFGH", matchCode: "42",
                                    expiresAt: "2026-09-26T12:00:00Z")
    }

    private func ready(_ requestId: String) -> SiloControlHandoffReady {
        SiloControlHandoffReady(requestId: requestId, serverId: "s1", profileId: "p1",
                                sessionExpiresAt: "2026-09-26T13:00:00Z", reused: false)
    }

    private func cancel(_ requestId: String, message: String?) -> SiloControlHandoffCancel {
        SiloControlHandoffCancel(requestId: requestId, reason: "handoff_failed", message: message)
    }
}

private extension Result {
    var thrown: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
#endif
