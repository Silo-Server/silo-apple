import AetherEngine
import Foundation
import XCTest
@testable import Silo

/// Mid-stream reconnect after the server drops (playback protocol v3 §6.2):
/// which replan a lost connection sends, the backoff and budget, and how each
/// answer moves the cycle on.
final class PlaybackReconnectTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    // MARK: - Operation

    func testLostConnectionReplansWithTrackChangeNotFailureRecovery() {
        let operation = PlaybackSessionBridge.replanOperation(
            forClassification: PlaybackReconnectPolicy.classification
        )
        XCTAssertEqual(operation, PlaybackProtocolV3.ReplanOperation.trackChange)
        XCTAssertEqual(
            PlaybackSessionBridge.replanOperation(
                forClassification: PlaybackReconnectPolicy.classification,
                serverFeatures: [PlaybackProtocolV3.planFeature, PlaybackProtocolV3.outputChangeFeature]
            ),
            PlaybackProtocolV3.ReplanOperation.trackChange
        )
        // An intent replan: no failure block, so the route stays eligible.
        XCTAssertNil(PlaybackSessionBridge.replanFailure(
            operation: operation,
            classification: PlaybackReconnectPolicy.classification,
            message: "reconnect"
        ))
    }

    func testStartupNetworkFailureKeepsFailureRecovery() {
        // A stream that fails before its own first frame keeps the ordinary
        // recovery: that route may be unreachable from this device.
        XCTAssertEqual(
            PlaybackSessionBridge.replanOperation(forClassification: "network_degraded"),
            PlaybackProtocolV3.ReplanOperation.failureRecovery
        )
    }

    // MARK: - Backoff

    func testBackoffDoublesFromOneSecondToAFifteenSecondCap() {
        let delays = (0..<PlaybackReconnectPolicy.maxAttempts).map {
            PlaybackReconnectPolicy.delay(afterAttempts: $0)
        }
        XCTAssertEqual(delays, [1, 2, 4, 8, 15, 15, 15, 15, 15, 15, 15, 15])
        XCTAssertEqual(PlaybackReconnectPolicy.delay(afterAttempts: 1_000), 15)
    }

    func testCycleGivesUpAfterTwelveUnansweredAttempts() {
        var cycle = PlaybackReconnectCycle()
        var next = cycle.begin(position: 120, resume: true, freshBudget: false, now: start)
        var waits: [TimeInterval] = []
        var attempts = 0
        while case .attempt(let delay)? = next {
            waits.append(delay)
            cycle.beginAttempt()
            attempts += 1
            next = cycle.retryLater(now: start)
        }
        XCTAssertEqual(next, .giveUp)
        XCTAssertEqual(attempts, 12)
        XCTAssertEqual(waits, [1, 2, 4, 8, 15, 15, 15, 15, 15, 15, 15, 15])
        XCTAssertEqual(waits.reduce(0, +), 135)
        XCTAssertFalse(cycle.isActive)
        // The position and intent survive the give-up for Try again.
        XCTAssertEqual(cycle.position, 120)
        XCTAssertTrue(cycle.resume)
    }

    func testOnlyOneCycleRunsAtATime() {
        var cycle = PlaybackReconnectCycle()
        XCTAssertEqual(cycle.begin(position: 10, resume: true, freshBudget: false, now: start), .attempt(after: 1))
        let generation = cycle.generation
        // A second loss report joins the running cycle.
        XCTAssertNil(cycle.begin(position: 99, resume: false, freshBudget: false, now: start))
        XCTAssertEqual(cycle.position, 10)
        XCTAssertTrue(cycle.resume)
        XCTAssertTrue(cycle.isCurrent(generation))

        cycle.end(recovered: false, now: start)
        XCTAssertFalse(cycle.isCurrent(generation))
    }

    func testTryAgainStartsAtOnceWithAFullBudget() {
        var cycle = PlaybackReconnectCycle()
        _ = cycle.begin(position: 30, resume: false, freshBudget: false, now: start)
        for _ in 0..<PlaybackReconnectPolicy.maxAttempts {
            cycle.beginAttempt()
            _ = cycle.retryLater(now: start)
        }
        XCTAssertFalse(cycle.isActive)

        XCTAssertEqual(
            cycle.begin(position: cycle.position, resume: cycle.resume, freshBudget: true, now: start),
            .attempt(after: 0)
        )
        XCTAssertEqual(cycle.attempts, 0)
        XCTAssertEqual(cycle.position, 30)
        XCTAssertFalse(cycle.resume)
    }

    func testDropRightAfterRecoveryContinuesTheBudget() {
        var cycle = PlaybackReconnectCycle()
        _ = cycle.begin(position: 0, resume: true, freshBudget: false, now: start)
        cycle.beginAttempt()
        _ = cycle.retryLater(now: start)
        cycle.beginAttempt()
        cycle.end(recovered: true, now: start)

        // Dropped again 10 s after recovering: the budget carries on.
        XCTAssertEqual(
            cycle.begin(position: 5, resume: true, freshBudget: false, now: start.addingTimeInterval(10)),
            .attempt(after: 4)
        )
        XCTAssertEqual(cycle.attempts, 2)
        cycle.end(recovered: true, now: start.addingTimeInterval(20))

        // Stable for longer than the window: a new cycle starts over.
        XCTAssertEqual(
            cycle.begin(position: 5, resume: true, freshBudget: false, now: start.addingTimeInterval(60)),
            .attempt(after: 1)
        )
        XCTAssertEqual(cycle.attempts, 0)
    }

    func testStreamThatKeepsDroppingAfterRecoveryGivesUp() {
        var cycle = PlaybackReconnectCycle()
        _ = cycle.begin(position: 0, resume: true, freshBudget: false, now: start)
        for _ in 0..<PlaybackReconnectPolicy.maxAttempts { cycle.beginAttempt() }
        cycle.end(recovered: true, now: start)
        XCTAssertEqual(cycle.begin(position: 0, resume: true, freshBudget: false, now: start.addingTimeInterval(5)), .giveUp)
        XCTAssertFalse(cycle.isActive)
    }

    func testSeekWhileReconnectingMovesTheSavedPosition() {
        var cycle = PlaybackReconnectCycle()
        _ = cycle.begin(position: 100, resume: true, freshBudget: false, now: start)
        cycle.updatePosition(250)
        XCTAssertEqual(cycle.position, 250)
        cycle.updatePosition(.nan)
        XCTAssertEqual(cycle.position, 250)
        cycle.end(recovered: false, now: start)
        cycle.updatePosition(10)
        XCTAssertEqual(cycle.position, 250, "an ended cycle keeps its saved position")
    }

    func testSeekWhileAnAttemptIsOutMovesTheNewTransport() {
        var cycle = PlaybackReconnectCycle()
        _ = cycle.begin(position: 100, resume: true, freshBudget: false, now: start)
        // The viewer seeked while the request was out.
        cycle.updatePosition(250)
        XCTAssertEqual(cycle.beginHandoff(requestedPosition: 100, now: start), true)
        XCTAssertFalse(cycle.isActive)
        XCTAssertEqual(cycle.finishHandoff(), 250)
        XCTAssertFalse(cycle.isHandingOff)
        XCTAssertNil(cycle.finishHandoff(), "a handoff is applied once")
    }

    func testSeekWhileTheNewTransportLoadsMovesIt() {
        // The plan came back, so the cycle is over, but the new transport is
        // not installed yet: a seek now still belongs to the reconnect.
        var cycle = PlaybackReconnectCycle()
        _ = cycle.begin(position: 100, resume: false, freshBudget: false, now: start)
        XCTAssertEqual(cycle.beginHandoff(requestedPosition: 100, now: start), false)
        XCTAssertTrue(cycle.isHandingOff)
        cycle.updatePosition(400)
        XCTAssertEqual(cycle.finishHandoff(), 400)
    }

    func testHandoffWithoutASeekNeedsNoSeek() {
        var cycle = PlaybackReconnectCycle()
        _ = cycle.begin(position: 100, resume: true, freshBudget: false, now: start)
        _ = cycle.beginHandoff(requestedPosition: 100, now: start)
        cycle.updatePosition(100.2)
        XCTAssertNil(cycle.finishHandoff())
    }

    func testCancellingEndsTheHandoff() {
        var cycle = PlaybackReconnectCycle()
        XCTAssertNil(cycle.beginHandoff(requestedPosition: 100, now: start), "no cycle, no handoff")
        _ = cycle.begin(position: 100, resume: true, freshBudget: false, now: start)
        _ = cycle.beginHandoff(requestedPosition: 100, now: start)
        cycle.updatePosition(250)
        cycle.end(recovered: false, now: start)
        XCTAssertFalse(cycle.isHandingOff)
        XCTAssertNil(cycle.finishHandoff())
        cycle.updatePosition(300)
        XCTAssertEqual(cycle.position, 250)
    }

    func testOtherContentStartsWithAFullBudget() {
        // The previous item recovered on its last attempt; another item that
        // drops right after must still get every attempt.
        var cycle = PlaybackReconnectCycle()
        _ = cycle.begin(position: 0, resume: true, freshBudget: false, now: start)
        for _ in 0..<PlaybackReconnectPolicy.maxAttempts { cycle.beginAttempt() }
        _ = cycle.beginHandoff(requestedPosition: 0, now: start)
        _ = cycle.finishHandoff()
        cycle.resetBudget()
        XCTAssertEqual(
            cycle.begin(position: 0, resume: true, freshBudget: false, now: start.addingTimeInterval(5)),
            .attempt(after: PlaybackReconnectPolicy.baseDelay)
        )
        XCTAssertEqual(cycle.attempts, 0)
    }

    // MARK: - Answers

    func testUnreachableOrOverloadedServerWaitsForTheNextAttempt() {
        let unanswered: [Error] = [
            HTTPError.network(underlying: URLError(.cannotConnectToHost)),
            HTTPError.network(underlying: URLError(.timedOut)),
            HTTPError.network(underlying: URLError(.networkConnectionLost)),
            URLError(.notConnectedToInternet),
            problem(status: 503, identifier: "service_unavailable"),
            APIv2Error.httpStatus(502),
            problem(status: 408, identifier: "request_timeout"),
            problem(status: 429, identifier: "rate_limited"),
            problem(status: 409, identifier: "replan_in_progress"),
        ]
        for error in unanswered {
            XCTAssertTrue(PlaybackReconnectPolicy.isUnanswered(error), "\(error)")
            XCTAssertEqual(PlaybackReconnectPolicy.verdict(for: error, step: .replan), .retryLater, "\(error)")
            XCTAssertEqual(PlaybackReconnectPolicy.verdict(for: error, step: .start), .retryLater, "\(error)")
        }
        XCTAssertFalse(PlaybackReconnectPolicy.isTransient(HTTPError.network(underlying: URLError(.cancelled))))
    }

    func testSessionGoneAfterRestartStartsANewSession() {
        let answers: [Error] = [
            problem(status: 404, identifier: "not_found"),
            // A replan carries the old installation and cannot succeed.
            problem(status: 409, identifier: "installation_changed"),
            PlaybackV3TerminalFailure(reason: "session_expired", message: "Expired", retryable: false),
        ]
        for error in answers {
            XCTAssertFalse(PlaybackReconnectPolicy.isUnanswered(error), "\(error)")
            XCTAssertEqual(PlaybackReconnectPolicy.verdict(for: error, step: .replan), .startNewSession, "\(error)")
        }
    }

    func testRefusedNewSessionGivesUpButAnInstallationChangeWaits() {
        XCTAssertEqual(
            PlaybackReconnectPolicy.verdict(for: problem(status: 404, identifier: "not_found"), step: .start),
            .giveUp
        )
        XCTAssertEqual(
            PlaybackReconnectPolicy.verdict(
                for: PlaybackV3TerminalFailure(reason: "policy_denied", message: "No", retryable: false),
                step: .start
            ),
            .giveUp
        )
        XCTAssertEqual(
            PlaybackReconnectPolicy.verdict(for: problem(status: 409, identifier: "installation_changed"), step: .start),
            .retryLater
        )
    }

    func testFailureOnThisSideIsNotTheServersVerdict() {
        XCTAssertEqual(PlaybackReconnectPolicy.verdict(for: CancellationError(), step: .replan), .retryLater)
        XCTAssertEqual(PlaybackReconnectPolicy.verdict(for: CancellationError(), step: .start), .retryLater)
    }

    // MARK: - Lost connection or failed route

    func testURLConnectivityFailureIsALostConnection() {
        let failure = PlaybackErrorInfo(
            kind: .nativeItemFailed,
            message: "Could not connect to the server.",
            underlyingDomain: NSURLErrorDomain,
            underlyingCode: NSURLErrorCannotConnectToHost
        )
        XCTAssertTrue(PlaybackReconnectPolicy.isConnectionLoss(failure, serverUnreachable: false))
    }

    func testDeadSourceIsALostConnectionOnlyWhileTheServerIsUnreachable() {
        let failure = PlaybackErrorInfo(kind: .vodSourceFailed, message: "pump reconnect exhausted", underlyingCode: -1)
        XCTAssertTrue(PlaybackReconnectPolicy.isConnectionLoss(failure, serverUnreachable: true))
        XCTAssertFalse(PlaybackReconnectPolicy.isConnectionLoss(failure, serverUnreachable: false))
    }

    func testRouteFailuresKeepTheOrdinaryRecovery() {
        let failures = [
            PlaybackErrorInfo(kind: .softwarePipelineFailed, message: "decoder"),
            PlaybackErrorInfo(kind: .sourceRefused, message: "HTTP 404", underlyingCode: 404),
            PlaybackErrorInfo(kind: .sourceRateLimited, message: "HTTP 429", underlyingCode: 429),
            PlaybackErrorInfo(
                kind: .sourceCertificateRejected,
                message: "trust",
                underlyingDomain: NSURLErrorDomain,
                underlyingCode: NSURLErrorServerCertificateUntrusted
            ),
        ]
        for failure in failures {
            XCTAssertFalse(
                PlaybackReconnectPolicy.isConnectionLoss(failure, serverUnreachable: true),
                failure.kind.rawValue
            )
        }
    }

    private func problem(status: Int, identifier: String) -> APIv2Error {
        .problem(APIv2Problem(
            type: "https://silo.example/problems/\(identifier)",
            title: identifier,
            status: status,
            detail: identifier,
            instance: nil,
            errors: nil
        ))
    }
}
