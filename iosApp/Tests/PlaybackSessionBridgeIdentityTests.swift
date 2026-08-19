import Foundation
import XCTest
@testable import Silo

/// The first tests that stand up a real `PlaybackSessionBridge`.
///
/// Everything the bridge would reach the network for now goes through the
/// injected `PlaybackTransport`, so a start / replan / stop sequence can be
/// driven from the vendored `decision_response.json` and asserted on:
/// which session the bridge adopted, that a stop names the session it meant to
/// stop, and that the replan ladder counts attempts the way the server expects.
final class PlaybackSessionBridgeIdentityTests: XCTestCase {

    private static let fixtureSessionId = "11111111-1111-4111-8111-111111111111"
    private static let fixturePlanAttemptKey = "v3:f0144c47fa349e3e"
    private static let contentId = "content-fixture-1"

    private var scope: TemporaryAuthScope!

    /// The bridge reads the profile id (and the capability gate the server id)
    /// off `TokenStore`. A temporary scope supplies both without touching the
    /// Keychain or the shared defaults, and unwinds itself in `tearDown`.
    override func setUp() async throws {
        try await super.setUp()
        let scope = TemporaryAuthScope(
            serverId: "playback-session-bridge-identity-tests",
            serverURL: "https://bridge.tests.invalid",
            accessToken: "access",
            refreshToken: "refresh",
            profileId: "profile-fixture",
            profileToken: "profile-token",
            controllerDeviceId: "controller-fixture",
            expiresAt: Date().addingTimeInterval(3600)
        )
        self.scope = scope
        await TokenStore.shared.beginTemporaryScope(scope)
    }

    override func tearDown() async throws {
        if let scope {
            await TokenStore.shared.endTemporaryScope(
                expectedGenerationID: scope.credentialGenerationID
            )
        }
        scope = nil
        try await super.tearDown()
    }

    // MARK: - (a) start adopts the fixture session

    func testStartSessionAdoptsTheFixtureSessionIdentity() async throws {
        let transport = try makeTransport()
        await transport.enqueueStart(try decisionResponse())
        let bridge = makeBridge(transport)

        let prepared = try await bridge.startSession(
            contentId: Self.contentId,
            startFromBeginning: true
        )

        XCTAssertEqual(prepared.session.sessionId, Self.fixtureSessionId)
        XCTAssertEqual(prepared.selectedVersion.fileId, 42)
        let currentSessionId = await bridge.currentSessionId
        XCTAssertEqual(currentSessionId, Self.fixtureSessionId)

        let protocolV3 = try XCTUnwrap(prepared.protocolV3)
        XCTAssertTrue(protocolV3.playbackAttemptId.hasPrefix("apple:"))
        XCTAssertTrue(protocolV3.planAttemptId.hasPrefix("apple-plan:"))
        XCTAssertEqual(protocolV3.planAttemptKey, Self.fixturePlanAttemptKey)

        let startRequests = await transport.startRequests()
        XCTAssertEqual(startRequests.count, 1)
        XCTAssertEqual(startRequests.first?.fileId, 42)
        XCTAssertEqual(startRequests.first?.playbackAttemptId, protocolV3.playbackAttemptId)
        let stops = await transport.stopPlaybackSessionIds()
        XCTAssertEqual(stops, [])
    }

    // MARK: - (b) a stop for a superseded session is a no-op

    func testStopSessionForAnotherSessionIdIsANoOp() async throws {
        let transport = try makeTransport()
        await transport.enqueueStart(try decisionResponse())
        let bridge = makeBridge(transport)
        _ = try await bridge.startSession(contentId: Self.contentId, startFromBeginning: true)

        await bridge.stopSession(
            expectedSessionId: "some-other-session",
            position: 120,
            isPaused: false
        )

        let currentSessionId = await bridge.currentSessionId
        XCTAssertEqual(currentSessionId, Self.fixtureSessionId)
        let stops = await transport.stopPlaybackSessionIds()
        XCTAssertEqual(stops, [])
        let progress = await transport.progressReports()
        XCTAssertEqual(progress.count, 0)
    }

    // MARK: - (c) a stop for the live session clears it exactly once

    func testStopSessionForTheCurrentSessionClearsItAndStopsOnce() async throws {
        let transport = try makeTransport()
        await transport.enqueueStart(try decisionResponse())
        let bridge = makeBridge(transport)
        _ = try await bridge.startSession(contentId: Self.contentId, startFromBeginning: true)

        await bridge.stopSession(
            expectedSessionId: Self.fixtureSessionId,
            position: 120,
            isPaused: false
        )

        let currentSessionId = await bridge.currentSessionId
        XCTAssertNil(currentSessionId)
        let stops = await transport.stopPlaybackSessionIds()
        XCTAssertEqual(stops, [Self.fixtureSessionId])
        let progress = await transport.progressReports()
        XCTAssertEqual(progress.map(\.sessionId), [Self.fixtureSessionId])

        // The second stop has nothing to name any more, so it must not reach
        // the server a second time.
        await bridge.stopSession(position: 120, isPaused: false)
        let stopsAfterSecond = await transport.stopPlaybackSessionIds()
        XCTAssertEqual(stopsAfterSecond, [Self.fixtureSessionId])
    }

    // MARK: - (d) a replan advances the plan attempt and keeps the identity

    func testReplanIncrementsTheAttemptAndKeepsTheSessionIdentity() async throws {
        let transport = try makeTransport()
        await transport.enqueueStart(try decisionResponse())
        await transport.enqueueReplan(try decisionResponse(planAttemptKey: "v3:replan-1"))
        await transport.enqueueReplan(try decisionResponse(planAttemptKey: "v3:replan-2"))
        let bridge = makeBridge(transport)
        let started = try await bridge.startSession(
            contentId: Self.contentId,
            startFromBeginning: true
        )
        let startedV3 = try XCTUnwrap(started.protocolV3)

        let firstReplanned = try await bridge.replanProtocolV3(
            watchDetail: try watchDetail(),
            position: 42,
            classification: "decoder_error",
            message: "decoder gave up"
        )
        let firstReplan = try XCTUnwrap(firstReplanned)
        let firstV3 = try XCTUnwrap(firstReplan.protocolV3)

        XCTAssertEqual(firstV3.playbackAttemptId, startedV3.playbackAttemptId)
        XCTAssertEqual(firstV3.outputContextId, startedV3.outputContextId)
        XCTAssertNotEqual(firstV3.planAttemptId, startedV3.planAttemptId)
        XCTAssertEqual(firstV3.planAttemptKey, "v3:replan-1")
        let sessionAfterFirst = await bridge.currentSessionId
        XCTAssertEqual(sessionAfterFirst, Self.fixtureSessionId)

        let secondReplanned = try await bridge.replanProtocolV3(
            watchDetail: try watchDetail(),
            position: 43,
            classification: "decoder_error",
            message: "decoder gave up again"
        )
        XCTAssertNotNil(secondReplanned)

        let requests = await transport.replanRequests()
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].attemptCount, 1)
        XCTAssertEqual(requests[0].attemptedPlanKeys, [Self.fixturePlanAttemptKey])
        XCTAssertEqual(requests[0].playbackAttemptId, startedV3.playbackAttemptId)
        // The second request carries the incremented count and the key the
        // first replan burned.
        XCTAssertEqual(requests[1].attemptCount, 2)
        XCTAssertEqual(
            requests[1].attemptedPlanKeys,
            [Self.fixturePlanAttemptKey, "v3:replan-1"].sorted()
        )
        XCTAssertEqual(requests[1].playbackAttemptId, startedV3.playbackAttemptId)
    }

    // MARK: - (e) the ladder stops at eight attempts

    func testReplanLadderThrowsAttemptLimitReachedAfterEightAttempts() async throws {
        let transport = try makeTransport()
        await transport.enqueueStart(try decisionResponse())
        for index in 1...7 {
            await transport.enqueueReplan(try decisionResponse(planAttemptKey: "v3:replan-\(index)"))
        }
        let bridge = makeBridge(transport)
        _ = try await bridge.startSession(contentId: Self.contentId, startFromBeginning: true)

        for index in 1...7 {
            let response = try await bridge.replanProtocolV3(
                watchDetail: try watchDetail(),
                position: Double(index),
                classification: "decoder_error",
                message: "rung \(index)"
            )
            let replanned = try XCTUnwrap(response, "replan \(index) should have produced a plan")
            XCTAssertEqual(replanned.protocolV3?.planAttemptKey, "v3:replan-\(index)")
        }

        do {
            _ = try await bridge.replanProtocolV3(
                watchDetail: try watchDetail(),
                position: 8,
                classification: "decoder_error",
                message: "rung 8"
            )
            XCTFail("the eighth attempt must not reach the server")
        } catch let failure as PlaybackV3TerminalFailure {
            XCTAssertEqual(failure.reason, "attempt_limit_reached")
            XCTAssertFalse(failure.retryable)
        }

        // Seven POSTs, not eight: the cap is checked before the request.
        let requests = await transport.replanRequests()
        XCTAssertEqual(requests.count, 7)
        XCTAssertEqual(requests.map(\.attemptCount), [1, 2, 3, 4, 5, 6, 7])
    }

    // MARK: - Harness

    private func makeBridge(_ transport: FakePlaybackTransport) -> PlaybackSessionBridge {
        PlaybackSessionBridge(
            transport: transport,
            capabilityGate: PlaybackV3CapabilityGate(transport: transport)
        )
    }

    private func makeTransport() throws -> FakePlaybackTransport {
        FakePlaybackTransport(
            capability: try PlaybackV3FixtureTestSupport.decode(
                PlaybackV3CapabilityResponse.self,
                named: "capability_response",
                bundleClass: Self.self
            ),
            watchDetail: try watchDetail()
        )
    }

    /// The golden decision response, optionally re-keyed so a replan looks like
    /// a genuinely different plan to the loop detector. The session id is left
    /// alone: these tests are about identity surviving a replan.
    private func decisionResponse(planAttemptKey: String? = nil) throws -> PlaybackV3DecisionResponse {
        let url = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "decision_response",
            bundleClass: Self.self
        )
        var root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        if let planAttemptKey {
            var plan = try XCTUnwrap(root["playback_plan"] as? [String: Any])
            plan["plan_attempt_key"] = planAttemptKey
            plan["plan_id"] = "plan:\(planAttemptKey)"
            root["playback_plan"] = plan
        }
        return try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3DecisionResponse.self,
            from: try JSONSerialization.data(withJSONObject: root)
        )
    }

    /// The minimum watch detail the golden plan needs: one version whose
    /// `file_id` is the plan's effective media file.
    private func watchDetail() throws -> WatchDetail {
        let json = """
        {
          "content_id": "\(Self.contentId)",
          "type": "movie",
          "title": "Fixture Movie",
          "versions": [
            {
              "file_id": 42,
              "file_name": "fixture.mp4",
              "resolution": "1080p",
              "codec_video": "h264",
              "codec_audio": "aac",
              "container": "mp4",
              "duration": 7200,
              "bitrate": 8000
            }
          ]
        }
        """
        return try PlaybackV3FixtureTestSupport.decoder.decode(
            WatchDetail.self,
            from: Data(json.utf8)
        )
    }
}
