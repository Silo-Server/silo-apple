import Foundation
import XCTest
@testable import Silo

final class WatchPartyWorkRecoveryTests: XCTestCase {
    private func identity() -> WatchPartyWorkRecovery.Identity {
        .init(engagement: UUID(), connection: UUID(), room: "synthetic-room", selection: 3, generation: 7,
              session: "synthetic-session", command: "synthetic-command", canControl: true, canSeek: true, phase: .playing)
    }

    private func refusal(_ id: String?, code: String = "realtime_rate_limited", milliseconds: Int = 250,
                         started: Bool? = false) -> WatchPartyWorkError {
        .init(code: code, message: "Synthetic refusal", requestId: id,
              retryAfterMilliseconds: milliseconds, workStarted: started)
    }

    func testCorrelatedPreWorkTransportRetriesOnceWithOriginalIDAfterFloor() throws {
        var recovery = WatchPartyWorkRecovery()
        let owner = identity()
        let original = recovery.track(.init(type: "transport_request", action: .pause, positionSeconds: 12), identity: owner, at: 10)
        _ = recovery.refuse(refusal(original.requestId, milliseconds: 1000), at: 10.1, jitter: 0.2)
        XCTAssertTrue(recovery.takeTransportRetries(identity: owner, at: 11.29).messages.isEmpty)
        let retry = try XCTUnwrap(recovery.takeTransportRetries(identity: owner, at: 11.31).messages.first)
        let originalJSON = try JSONSerialization.jsonObject(with: Data(original.encoded().utf8)) as? NSDictionary
        let retryJSON = try JSONSerialization.jsonObject(with: Data(retry.encoded().utf8)) as? NSDictionary
        XCTAssertEqual(retryJSON, originalJSON)
        XCTAssertTrue(recovery.takeTransportRetries(identity: owner, at: 11.4).messages.isEmpty)
        _ = recovery.refuse(refusal(original.requestId), at: 11.5, jitter: 0)
        XCTAssertTrue(recovery.transport.isEmpty, "A second refusal does not authorize a third attempt")
    }

    func testUncorrelatedLegacyDownstreamAndUnknownErrorsNeverAuthorizeReplay() {
        for error in [refusal(nil), refusal("other"), refusal(nil, code: "realtime_input_limited"),
                      refusal(nil, started: nil), refusal(nil, started: true)] {
            var recovery = WatchPartyWorkRecovery()
            let owner = identity()
            let message = recovery.track(.init(type: "transport_request", action: .play), identity: owner, at: 0)
            var error = error
            if error.workStarted != false { error.requestId = message.requestId }
            _ = recovery.refuse(error, at: 0, jitter: 0)
            XCTAssertTrue(recovery.takeTransportRetries(identity: owner, at: 1).messages.isEmpty)
        }
    }

    func testEveryIdentityAxisInvalidatesExplicitRetry() {
        let original = identity()
        var changed: [WatchPartyWorkRecovery.Identity] = []
        var value = original; value.engagement = UUID(); changed.append(value)
        value = original; value.connection = UUID(); changed.append(value)
        value = original; value.room = "another-room"; changed.append(value)
        value = original; value.selection += 1; changed.append(value)
        value = original; value.generation += 1; changed.append(value)
        value = original; value.session = "new-session"; changed.append(value)
        value = original; value.command = "new-command"; changed.append(value)
        value = original; value.canControl = false; changed.append(value)
        value = original; value.canSeek = false; changed.append(value)
        value = original; value.phase = .lobby; changed.append(value)
        for identity in changed {
            var recovery = WatchPartyWorkRecovery()
            let message = recovery.track(.init(type: "transport_request", action: .play), identity: original, at: 0)
            _ = recovery.refuse(refusal(message.requestId), at: 0, jitter: 0)
            XCTAssertTrue(recovery.takeTransportRetries(identity: identity, at: 0.3).messages.isEmpty)
            XCTAssertTrue(recovery.transport.isEmpty)
        }
    }

    func testResultOrSecondRefusalWhileValidationSuspendsCancelsChosenRetry() throws {
        for applied in [true, false] {
            var recovery = WatchPartyWorkRecovery()
            let owner = identity()
            let original = recovery.track(.init(type: "transport_request", action: .pause), identity: owner, at: 0)
            _ = recovery.refuse(refusal(original.requestId), at: 0, jitter: 0)
            let chosen = try XCTUnwrap(recovery.takeTransportRetries(identity: owner, at: 0.3).messages.first)
            XCTAssertTrue(recovery.canDispatchTransportRetry(chosen.requestId, identity: owner, at: 0.3))
            if applied {
                XCTAssertTrue(recovery.applied(requestId: original.requestId, action: "transport_request", identity: owner, at: 0.31))
            } else {
                _ = recovery.refuse(refusal(original.requestId), at: 0.31, jitter: 0)
            }
            XCTAssertFalse(recovery.canDispatchTransportRetry(chosen.requestId, identity: owner, at: 0.32))
        }
    }

    func testTimeoutDisconnectAndDownstreamFailureNeverReplay() {
        let owner = identity()
        var recovery = WatchPartyWorkRecovery()
        let message = recovery.track(.init(type: "transport_request", action: .pause), identity: owner, at: 0)
        XCTAssertEqual(recovery.failed(requestId: message.requestId), .transport)
        XCTAssertTrue(recovery.takeTransportRetries(identity: owner, at: 1).messages.isEmpty)
        _ = recovery.track(.init(type: "transport_request", action: .play), identity: owner, at: 0)
        XCTAssertTrue(recovery.expire(identity: owner, at: 5))
        XCTAssertTrue(recovery.transport.isEmpty)
        _ = recovery.track(.init(type: "transport_request", action: .play), identity: owner, at: 6)
        XCTAssertTrue(recovery.disconnected())
        XCTAssertTrue(recovery.takeTransportRetries(identity: owner, at: 7).messages.isEmpty)
    }

    func testRefusedAndSelectedButUnsentRetriesAreNeverUncertainOnDisconnectOrExpiry() throws {
        let owner = identity()
        for selected in [false, true] {
            for disconnect in [false, true] {
                var recovery = WatchPartyWorkRecovery()
                let message = recovery.track(.init(type: "transport_request", action: .pause), identity: owner, at: 0)
                _ = recovery.refuse(refusal(message.requestId), at: 0, jitter: 0)
                if selected {
                    XCTAssertEqual(recovery.takeTransportRetries(identity: owner, at: 0.3).messages.count, 1)
                }
                let uncertain = disconnect ? recovery.disconnected() : recovery.expire(identity: owner, at: 5)
                XCTAssertFalse(uncertain, "An explicitly refused retry has not crossed the dispatch boundary")
                XCTAssertTrue(recovery.discardedUnsentTransport)
                XCTAssertTrue(recovery.transport.isEmpty)
            }
        }
    }

    func testRetryWhoseDispatchBeganIsUncertainAndCannotDispatchTwice() throws {
        let owner = identity()
        for disconnect in [false, true] {
            var recovery = WatchPartyWorkRecovery()
            let message = recovery.track(.init(type: "transport_request", action: .pause), identity: owner, at: 0)
            _ = recovery.refuse(refusal(message.requestId), at: 0, jitter: 0)
            let retry = try XCTUnwrap(recovery.takeTransportRetries(identity: owner, at: 0.3).messages.first)
            XCTAssertTrue(recovery.beginTransportRetry(retry.requestId, identity: owner, at: 0.3))
            XCTAssertFalse(recovery.beginTransportRetry(retry.requestId, identity: owner, at: 0.3))
            XCTAssertTrue(disconnect ? recovery.disconnected() : recovery.expire(identity: owner, at: 5))
            XCTAssertFalse(recovery.discardedUnsentTransport)
        }
    }

    func testDistinctTransportRetriesRetainOriginalIntentOrder() {
        var recovery = WatchPartyWorkRecovery()
        let owner = identity()
        // Equal clock values still have an explicit user-intent order.
        let play = recovery.track(.init(type: "transport_request", action: .play), identity: owner, at: 0)
        let pause = recovery.track(.init(type: "transport_request", action: .pause), identity: owner, at: 0)
        _ = recovery.refuse(refusal(pause.requestId), at: 0, jitter: 0)
        _ = recovery.refuse(refusal(play.requestId), at: 0, jitter: 0)
        let retries = recovery.takeTransportRetries(identity: owner, at: 0.3).messages
        XCTAssertEqual(retries.map(\.requestId), [play.requestId, pause.requestId])
        XCTAssertEqual(retries.map(\.action), [.play, .pause])
    }

    func testLongAdvertisedFloorDiscardsRatherThanExceedingFiveSecondIntentLifetime() {
        var recovery = WatchPartyWorkRecovery()
        let owner = identity()
        let message = recovery.track(.init(type: "transport_request", action: .play), identity: owner, at: 0)
        _ = recovery.refuse(refusal(message.requestId, milliseconds: 6000), at: 0, jitter: 0)
        XCTAssertTrue(recovery.transport.isEmpty)
        XCTAssertFalse(recovery.canSend(.lobby, at: 5))
        XCTAssertTrue(recovery.canSend(.lobby, at: 6))
    }

    func testCommitFramesCanAdvanceGenerationBeforeActionResultButWrongIdentityCannotAcknowledge() {
        var recovery = WatchPartyWorkRecovery()
        let owner = identity()
        let message = recovery.track(.init(type: "transport_request", action: .play), identity: owner, at: 0)
        var committed = owner; committed.generation += 1; committed.command = "committed-command"
        XCTAssertFalse(recovery.applied(requestId: message.requestId, action: "lobby_ready", identity: committed, at: 1))
        var replaced = committed; replaced.connection = UUID()
        XCTAssertFalse(recovery.applied(requestId: message.requestId, action: "transport_request", identity: replaced, at: 1))
        XCTAssertTrue(recovery.applied(requestId: message.requestId, action: "transport_request", identity: committed, at: 1))
        XCTAssertFalse(recovery.expire(identity: committed, at: 6))
    }

    func testDesiredKindsReplaceOldPayloadAndShareRecoveryFloorWithoutBlockingActions() throws {
        var recovery = WatchPartyWorkRecovery()
        let owner = identity()
        let old = recovery.track(.init(type: "state_report", sessionId: owner.session, positionSeconds: 1), identity: owner, at: 0)
        _ = recovery.refuse(refusal(old.requestId, milliseconds: 1200), at: 0, jitter: -1)
        for kind in [WatchPartyWorkRecovery.Kind.attach, .ready, .buffering, .report] {
            XCTAssertFalse(recovery.canSend(kind, at: 1.19))
            XCTAssertTrue(recovery.canSend(kind, at: 1.2))
        }
        XCTAssertTrue(recovery.canSend(.transport, at: 0))
        let current = recovery.track(.init(type: "state_report", sessionId: owner.session, positionSeconds: 9), identity: owner, at: 1.2)
        XCTAssertEqual(recovery.desired.count, 1)
        XCTAssertEqual(recovery.desired[.report]?.message.positionSeconds, 9)
        XCTAssertNotEqual(current.requestId, old.requestId)
        var changed = owner; changed.session = "replacement"
        XCTAssertFalse(recovery.expire(identity: changed, at: 1.3))
        XCTAssertTrue(recovery.desired.isEmpty)
    }

    func testBufferingRefusalHealsOnlyCurrentStallAndRecoveryCancelsIt() {
        var timer = WatchPartyStallTimer()
        let origin = Date(timeIntervalSince1970: 0)
        XCTAssertFalse(timer.observe(buffering: true, at: origin))
        XCTAssertTrue(timer.observe(buffering: true, at: origin.addingTimeInterval(2)))
        timer.refused()
        XCTAssertTrue(timer.observe(buffering: true, at: origin.addingTimeInterval(3)))
        timer.refused()
        XCTAssertFalse(timer.observe(buffering: false, at: origin.addingTimeInterval(4)))
        XCTAssertFalse(timer.observe(buffering: true, at: origin.addingTimeInterval(5)))
    }

    func testLobbyIsNotSavedBySocketSendAndNeedsMatchingResultOrEcho() {
        var recovery = WatchPartyWorkRecovery()
        var owner = identity(); owner.phase = .lobby; owner.session = nil
        let message = recovery.track(.init(type: "lobby_ready", ready: true), identity: owner, at: 0)
        XCTAssertNotNil(recovery.desired[.lobby])
        XCTAssertFalse(recovery.applied(requestId: "stale", action: "lobby_ready", identity: owner, at: 1))
        XCTAssertTrue(recovery.applied(requestId: message.requestId, action: "lobby_ready", identity: owner, at: 1))
        _ = recovery.track(.init(type: "lobby_ready", ready: false), identity: owner, at: 2)
        recovery.echo(.lobby, identity: owner, at: 2.1)
        XCTAssertNil(recovery.desired[.lobby])
    }

    func testOutageBackoffPersistsThroughDisconnectsAndOpens() {
        var recovery = WatchPartyWorkRecovery()
        let owner = identity()
        var now = 0.0
        for delay in [2.0, 4, 8, 16, 30, 30] {
            let message = recovery.track(.init(type: "attach_session", sessionId: owner.session), identity: owner, at: now)
            _ = recovery.refuse(refusal(message.requestId, code: "realtime_unavailable", milliseconds: 2000), at: now, jitter: 0.25)
            XCTAssertEqual(recovery.remainingDelay(.attach, at: now), delay + 0.25, accuracy: 0.0001)
            _ = recovery.disconnected() // No reset on the next socket open.
            now += delay + 1
        }
    }

    func testShieldAndOpaqueBackoffResetOnlyAfterUsefulAcceptedActivity() {
        var recovery = WatchPartyWorkRecovery()
        for delay in [5.0, 10, 20, 30, 30] {
            XCTAssertEqual(recovery.reconnectDelay(shield: true, at: 0), delay)
        }
        for delay in [1.0, 2, 4, 8, 16, 30, 30] {
            XCTAssertEqual(recovery.reconnectDelay(shield: false, at: 0), delay)
        }
        recovery.accepted(at: 10)
        recovery.accepted(at: 39)
        XCTAssertEqual(recovery.reconnectDelay(shield: false, at: 39), 30)
        for time in stride(from: 40.0, through: 70.0, by: 2) { recovery.accepted(at: time) }
        XCTAssertEqual(recovery.reconnectDelay(shield: false, at: 70), 0)
        XCTAssertEqual(recovery.reconnectDelay(shield: true, at: 70), 5)
    }

    func testIdleAcceptedSamplesDoNotCountAsThirtySecondsOfUsefulActivity() {
        var recovery = WatchPartyWorkRecovery()
        XCTAssertEqual(recovery.reconnectDelay(shield: false, at: 0), 1)
        recovery.accepted(at: 1)
        recovery.accepted(at: 40)
        XCTAssertEqual(recovery.reconnectDelay(shield: false, at: 40), 2)
    }

    func testAbsoluteSeekWindowKeepsLatestTargetAndOriginalDeadline() throws {
        var window = WatchPartySeekWindow()
        let owner = identity()
        window.submit(.init(type: "transport_request", action: .seek, positionSeconds: 10), identity: owner, at: 0)
        window.submit(.init(type: "transport_request", action: .seek, positionSeconds: 30), identity: owner, at: 0.2)
        XCTAssertEqual(window.message?.positionSeconds, 30, "The pending absolute target is immediately available")
        XCTAssertNil(window.take(identity: owner, at: 0.249))
        XCTAssertEqual(window.take(identity: owner, at: 0.25)?.positionSeconds, 30)
        XCTAssertNil(window.take(identity: owner, at: 1))
        window.submit(.init(type: "transport_request", action: .seek, positionSeconds: 50), identity: owner, at: 2)
        var replacement = owner; replacement.generation += 1
        XCTAssertNil(window.take(identity: replacement, at: 2.5))
        XCTAssertNil(window.message)
    }

    func testDistinctPlayAndPauseAreNeverMerged() {
        var recovery = WatchPartyWorkRecovery()
        let owner = identity()
        let play = recovery.track(.init(type: "transport_request", action: .play), identity: owner, at: 0)
        let pause = recovery.track(.init(type: "transport_request", action: .pause), identity: owner, at: 0.1)
        XCTAssertNotEqual(play.requestId, pause.requestId)
        XCTAssertEqual(recovery.transport.count, 2)
    }

    func testWireErrorsResultsCapabilitiesAndCloseClassificationAreAdditive() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let data = Data(#"{"type":"error","code":"realtime_rate_limited","message":"Busy","request_id":"test","retry_after_ms":750,"work_started":false}"#.utf8)
        guard case .error(let error) = try decoder.decode(WatchPartyServerMessage.self, from: data) else { return XCTFail() }
        XCTAssertTrue(error.isPreWorkRefusal)
        XCTAssertEqual(error.retryAfterMilliseconds, 750)
        guard case .actionResult(let id, let action, let status) = try decoder.decode(WatchPartyServerMessage.self,
            from: Data(#"{"type":"action_result","request_id":"test","action":"lobby_ready","status":"applied"}"#.utf8)) else { return XCTFail() }
        XCTAssertEqual(id, "test"); XCTAssertEqual(action, "lobby_ready"); XCTAssertEqual(status, "applied")
        guard case .unknown = try decoder.decode(WatchPartyServerMessage.self, from: Data(#"{"type":"future"}"#.utf8)) else { return XCTFail() }
        let old = try decoder.decode(WatchPartyCapabilities.self, from: Data(#"{"state":"available","allowed":true}"#.utf8))
        XCTAssertFalse(old.supportsWorkAdmission)
        let current = try decoder.decode(WatchPartyCapabilities.self, from: Data(#"{"state":"available","work_admission":{"version":1,"scope":"node","backend":"memory","epoch":"synthetic"}}"#.utf8))
        XCTAssertTrue(current.supportsWorkAdmission)
        XCTAssertEqual(current.workAdmission?.scope, "node")
        XCTAssertTrue(WatchPartySocketError.remoteClose(code: 1008, reason: "realtime input shield").isInputShield)
        XCTAssertFalse(WatchPartySocketError.remoteClose(code: 1008, reason: "selection required").isInputShield)
        XCTAssertFalse(WatchPartySocketError.remoteClose(code: 1000, reason: "realtime input shield").isInputShield)
    }

    func testTicketRetryUsesGreatestStructuredOrHeaderFloor() {
        let raw = HTTPRawResponse(data: Data(#"{"retry_after_ms":2500}"#.utf8), statusCode: 429, headers: ["Retry-After": "4"])
        XCTAssertEqual(WatchPartyTicketRefusal(raw).retryAfter, 4)
        let now = Date(timeIntervalSince1970: 0)
        let unavailable = HTTPRawResponse(data: Data(#"{"retry_after_ms":7000}"#.utf8), statusCode: 503,
            headers: ["Retry-After": "Thu, 01 Jan 1970 00:00:05 GMT"])
        let refusal = WatchPartyTicketRefusal(unavailable, now: now)
        XCTAssertTrue(refusal.unavailable)
        XCTAssertEqual(refusal.retryAfter, 7)
    }
}
