import Foundation
import XCTest
@testable import Silo

final class PlaybackProtocolV3ConformanceFixtureTests: XCTestCase {
    /// The vendored server matrix decodes through the production playback
    /// types (claims, transformations, subtitle decisions, qualities, the
    /// persisted decision). The scenario values belong to the server planner.
    func testEveryScenarioDecodesThroughTheProductionTypes() throws {
        XCTAssertNoThrow(try PlaybackV3FixtureTestSupport.decode(
            PlaybackV3ConformanceMatrix.self,
            named: "conformance_matrix",
            bundleClass: Self.self
        ))
    }

    func testMatrixDecodesClientIntentAndMapsOutputChangeOperation() throws {
        let matrix = try PlaybackV3FixtureTestSupport.decode(
            PlaybackV3ConformanceMatrix.self,
            named: "conformance_matrix",
            bundleClass: Self.self
        )

        XCTAssertTrue(
            matrix.replanScenarios.allSatisfy { $0.request.failure == nil },
            "track, quality, output and seek-reanchor intent vectors must omit failure"
        )

        // An output-route change is an intent replan, not a failure recovery:
        // the golden vector names the operation the client must send and omits
        // the failure block the server would reject.
        let outputChange = try replanScenario(named: "output_change", in: matrix)
        XCTAssertEqual(
            outputChange.request.operation,
            PlaybackProtocolV3.ReplanOperation.outputChange
        )
        XCTAssertNil(outputChange.request.failure)
        XCTAssertEqual(
            PlaybackSessionBridge.replanOperation(
                forClassification: "output_route_changed",
                serverFeatures: [
                    PlaybackProtocolV3.planFeature,
                    PlaybackProtocolV3.outputChangeFeature
                ]
            ),
            outputChange.request.operation
        )

        let recovery = try protocolScenario(named: "failure_recovery_preserves_intent", in: matrix)
        let recoveryRequest = try XCTUnwrap(recovery.input.replanRequest)
        XCTAssertEqual(recoveryRequest.operation, PlaybackProtocolV3.ReplanOperation.failureRecovery)
        XCTAssertEqual(recoveryRequest.failure?.classification, "network_degraded")
        XCTAssertEqual(recoveryRequest.attemptedPlanKeys, [recoveryRequest.planAttemptKey])
        XCTAssertEqual(recoveryRequest.selectedTracks.subtitle?.index, 2)

        let restart = try protocolScenario(named: "restart_replays_terminal_attempt", in: matrix)
        XCTAssertEqual(restart.input.persistedDecision?.terminal?.reason, "transcode_start_failed")

        let restartRequest = try XCTUnwrap(restart.input.startRequest)
        XCTAssertEqual(restartRequest.progressPersistence, "client")
        XCTAssertNotNil(restartRequest.startPosition)
        XCTAssertTrue(
            restart.input.persistedDecision?.serverFeatures.contains(
                PlaybackProtocolV3.neutralContractFeature
            ) == true
        )
    }

    private func replanScenario(
        named name: String,
        in matrix: PlaybackV3ConformanceMatrix
    ) throws -> PlaybackV3ConformanceReplanScenario {
        try XCTUnwrap(matrix.replanScenarios.first { $0.name == name })
    }

    private func protocolScenario(
        named name: String,
        in matrix: PlaybackV3ConformanceMatrix
    ) throws -> PlaybackV3ConformanceProtocolScenario {
        try XCTUnwrap(matrix.protocolScenarios.first { $0.name == name })
    }
}

private struct PlaybackV3ConformanceMatrix: Decodable {
    let schemaVersion: Int
    let plannerScenarios: [PlaybackV3ConformancePlannerScenario]
    let replanScenarios: [PlaybackV3ConformanceReplanScenario]
    let protocolScenarios: [PlaybackV3ConformanceProtocolScenario]
}

private struct PlaybackV3ConformancePlannerScenario: Decodable {
    let name: String
    let category: String
    let request: PlaybackV3ConformanceStartRequest
    let source: PlaybackV3SourceDescriptor
    let attemptedPlanKeys: [String]?
    let expected: PlaybackV3ConformancePlannerExpectation
}

private struct PlaybackV3ConformanceStartRequest: Decodable {
    let protocolVersion: Int
    let playbackAttemptId: String
    let qualityPreference: String
    let progressPersistence: String?
    let startPosition: Double?
    let audioTrackIndex: Int?
    let subtitleTrackId: String?
    let subtitleTrackIndex: Int?
    let clientCapabilities: PlaybackV3ConformanceCapabilities
    let clientPlaybackContext: PlaybackV3ConformanceClientContext
}

private struct PlaybackV3ConformanceCapabilities: Decodable {
    let videoEvidence: String
    let audioEvidence: String
    let hdr: Bool
    let hdrDetails: PlaybackV3HDRCapabilities?
    let audioPassthrough: PlaybackV3AudioPassthrough?
}

private struct PlaybackV3ConformanceClientContext: Decodable {
    let protocolVersion: Int
    let device: PlaybackV3ConformanceDevice
    let output: PlaybackV3OutputContext
    let deliveries: [String: PlaybackV3ConformanceDelivery]
}

private struct PlaybackV3ConformanceDevice: Decodable {
    let platform: String
}

private struct PlaybackV3ConformanceDelivery: Decodable {
    let enabled: Bool
    let validatedClaims: [String]?
    let transformations: [PlaybackV3Transformation]?
}

private struct PlaybackV3ConformancePlannerExpectation: Decodable {
    let outcome: String
    let delivery: String?
    let decisionReason: String?
    let planId: String?
    let planAttemptKey: String?
    let selectedTracks: PlaybackV3SelectedTracks?
    let subtitle: PlaybackV3SubtitleDecision?
    let claims: PlaybackV3ValidationClaims?
    let transformations: [PlaybackV3Transformation]?
    // Decode through the production model so audio-only rungs without a
    // video height exercise the same contract used by the app.
    let availableQualities: [PlaybackV3AvailableQuality]?
}

private struct PlaybackV3ConformanceReplanScenario: Decodable {
    let name: String
    let category: String
    let request: PlaybackV3ConformanceReplanRequest
}

private struct PlaybackV3ConformanceReplanRequest: Decodable {
    let operation: String
    let playbackAttemptId: String
    let replanRequestId: String
    let failedPlanId: String
    let planAttemptKey: String
    let attemptedPlanKeys: [String]
    let positionSeconds: Double
    let selectedTracks: PlaybackV3SelectedTracks
    let failure: PlaybackV3Failure?
}

private struct PlaybackV3ConformanceProtocolScenario: Decodable {
    let name: String
    let category: String
    let input: PlaybackV3ConformanceProtocolInput
}

private struct PlaybackV3ConformanceProtocolInput: Decodable {
    let body: PlaybackV3ConformanceDraftBody?
    let planId: String?
    let attemptedPlanKeys: [String]?
    let replanRequest: PlaybackV3ConformanceReplanRequest?
    let startRequest: PlaybackV3ConformanceStartRequest?
    let persistedDecision: PlaybackV3DecisionResponse?
    let restarted: Bool?
    let routeEvent: PlaybackV3ConformanceRouteEvent?
}

private struct PlaybackV3ConformanceDraftBody: Decodable {
    let protocolVersion: Int?
    let fileId: Int
}

private struct PlaybackV3ConformanceRouteEvent: Decodable {
    let protocolVersion: Int
    let playbackAttemptId: String
    let sessionId: String?
    let planId: String?
    let planAttemptId: String?
    let planAttemptKey: String?
    let event: String
    let outputContextId: String?
    let diagnostics: [String: String]
}
