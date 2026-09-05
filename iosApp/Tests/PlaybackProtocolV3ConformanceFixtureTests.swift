import Foundation
import XCTest
@testable import Silo

final class PlaybackProtocolV3ConformanceFixtureTests: XCTestCase {
    func testHTTPErrorDecodesServerErrorEnvelope() throws {
        let url = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "error_response",
            bundleClass: Self.self
        )
        let body = try String(contentsOf: url, encoding: .utf8)
        let error = HTTPError.http(statusCode: 426, body: body)

        XCTAssertEqual(error.serverErrorCode, "client_upgrade_required")
        XCTAssertEqual(
            error.errorDescription,
            "This server requires playback protocol v3. Update the app to continue."
        )
    }

    func testMatrixCoversEveryNeutralContractCategory() throws {
        let matrix = try PlaybackV3FixtureTestSupport.decode(
            PlaybackV3ConformanceMatrix.self,
            named: "conformance_matrix",
            bundleClass: Self.self
        )
        XCTAssertEqual(matrix.schemaVersion, 1)
        XCTAssertEqual(matrix.plannerScenarios.count, 21)
        XCTAssertEqual(matrix.replanScenarios.count, 10)
        XCTAssertEqual(matrix.protocolScenarios.count, 8)

        let categories = Set(
            matrix.plannerScenarios.map(\.category)
                + matrix.replanScenarios.map(\.category)
                + matrix.protocolScenarios.map(\.category)
        )
        XCTAssertTrue(
            Set([
                "evidence_tier_gating",
                "deliveries_negotiation",
                "audio_only_planning",
                "hdr_dv_matrix",
                "audio_matrix",
                "subtitle_matrix",
                "available_qualities",
                "track_change_replan",
                "quality_change_replan",
                "output_change_replan",
                "idempotent_replan",
                "concurrent_replan",
                "mid_seek_replan",
                "legacy_426",
                "draft_v3_426",
                "output_context_invalidation",
                "attempt_key_echo_and_loop",
                "recovery_matrix",
                "restart_matrix",
                "capacity_matrix",
                "route_event_limits"
            ]).isSubset(of: categories)
        )

        let names = matrix.plannerScenarios.map(\.name)
            + matrix.replanScenarios.map(\.name)
            + matrix.protocolScenarios.map(\.name)
        XCTAssertEqual(Set(names).count, names.count, "conformance scenario names must be unique")
    }

    // These checks cover fixture integrity and production model decoding, not server planning.
    func testMatrixDecodesHDRDVAudioAndSubtitleExpectations() throws {
        let matrix = try PlaybackV3FixtureTestSupport.decode(
            PlaybackV3ConformanceMatrix.self,
            named: "conformance_matrix",
            bundleClass: Self.self
        )

        let hdr10 = try plannerScenario(named: "hdr10_exact_direct", in: matrix)
        XCTAssertEqual(hdr10.source.dynamicRange, "hdr10")
        XCTAssertEqual(hdr10.expected.delivery, "original_http")
        XCTAssertEqual(hdr10.expected.claims?.video.hdr10, true)

        let clientManaged = try plannerScenario(named: "client_managed_hdr_selected_audio", in: matrix)
        XCTAssertEqual(clientManaged.source.dynamicRange, "hdr10")
        XCTAssertEqual(clientManaged.request.audioTrackIndex, 1)
        XCTAssertEqual(
            Set(clientManaged.request.clientPlaybackContext.deliveries["original_http"]?.validatedClaims ?? []),
            Set([
                PlaybackProtocolV3.clientManagedDynamicRangeClaim,
                PlaybackProtocolV3.clientSelectedAudioTrackClaim
            ])
        )
        XCTAssertEqual(clientManaged.expected.delivery, "original_http")
        XCTAssertEqual(clientManaged.expected.decisionReason, "client_managed_dynamic_range")
        XCTAssertEqual(clientManaged.expected.selectedTracks?.audio?.index, 1)

        let dolbyVision = try plannerScenario(named: "dolby_vision_8_exact_direct", in: matrix)
        XCTAssertEqual(dolbyVision.source.dolbyVisionProfile, 8)
        XCTAssertEqual(dolbyVision.expected.delivery, "original_http")
        XCTAssertEqual(dolbyVision.expected.claims?.video.dolbyVision, true)

        let fallback = try plannerScenario(named: "dolby_vision_7_hdr10_fallback", in: matrix)
        XCTAssertEqual(fallback.source.dolbyVisionProfile, 7)
        XCTAssertEqual(fallback.expected.delivery, "server_remux_progressive")
        XCTAssertEqual(fallback.expected.transformations?.map(\.executor), ["server"])

        let hdrToneMap = try plannerScenario(named: "hdr10_to_sdr_tone_map", in: matrix)
        XCTAssertEqual(hdrToneMap.source.dynamicRange, "hdr10")
        XCTAssertEqual(hdrToneMap.expected.delivery, "server_transcode_hls")
        XCTAssertEqual(
            hdrToneMap.expected.transformations?.last,
            PlaybackV3Transformation(
                name: "hdr_to_sdr_tonemap",
                executor: "server",
                recipeVersion: "1",
                validatedClaims: ["hdr_metadata_removed", "sdr_bt709_output"]
            )
        )
        XCTAssertEqual(
            hdrToneMap.expected.availableQualities?.first {
                $0.label == "1080p-medium"
            }?.displayName,
            "1080p Medium"
        )

        let dolbyVisionToneMap = try plannerScenario(
            named: "dolby_vision_7_id6_to_sdr_tone_map",
            in: matrix
        )
        XCTAssertEqual(dolbyVisionToneMap.source.dolbyVisionProfile, 7)
        XCTAssertEqual(dolbyVisionToneMap.source.dvBlCompatId, 6)
        XCTAssertEqual(dolbyVisionToneMap.expected.delivery, "server_transcode_hls")
        XCTAssertEqual(
            dolbyVisionToneMap.expected.transformations?.last?.name,
            "hdr_to_sdr_tonemap"
        )

        let audioConversion = try plannerScenario(named: "truehd_audio_conversion", in: matrix)
        XCTAssertEqual(audioConversion.source.audioCodec, "truehd")
        XCTAssertEqual(audioConversion.expected.claims?.audio.codec, "aac")
        XCTAssertEqual(audioConversion.expected.claims?.audio.passthrough, false)

        let passthrough = try plannerScenario(named: "truehd_exact_layout_passthrough", in: matrix)
        XCTAssertEqual(passthrough.expected.claims?.audio.codec, "truehd")
        XCTAssertEqual(passthrough.expected.claims?.audio.passthrough, true)

        let pgs = try plannerScenario(named: "embedded_pgs_sidecar", in: matrix)
        XCTAssertEqual(pgs.request.subtitleTrackIndex, 0)
        XCTAssertEqual(pgs.expected.subtitle?.mode, "render")
        XCTAssertEqual(pgs.expected.subtitle?.inventory.first?.codec, "hdmv_pgs_subtitle")
        XCTAssertEqual(pgs.expected.subtitle?.inventory.first?.delivery, "sidecar")

        let ass = try plannerScenario(named: "embedded_ass_authored_render", in: matrix)
        XCTAssertEqual(ass.expected.subtitle?.mode, "render")
        XCTAssertEqual(ass.expected.subtitle?.inventory.first?.codec, "ass")

        let dvd = try plannerScenario(named: "embedded_dvd_burn_in", in: matrix)
        XCTAssertEqual(dvd.expected.subtitle?.mode, "burn_in")
        XCTAssertEqual(dvd.expected.delivery, "server_transcode_hls")
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

    private func plannerScenario(
        named name: String,
        in matrix: PlaybackV3ConformanceMatrix
    ) throws -> PlaybackV3ConformancePlannerScenario {
        try XCTUnwrap(matrix.plannerScenarios.first { $0.name == name })
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
    let supportedOnDevice: Bool
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
    let firstOutputContextId: String?
    let secondOutputContextId: String?
    let firstPlanAttemptKey: String?
    let secondPlanAttemptKey: String?
    let serverPlanAttemptKey: String?
    let replanEcho: String?
    let attemptedPlanKeys: [String]?
    let replanRequest: PlaybackV3ConformanceReplanRequest?
    let startRequest: PlaybackV3ConformanceStartRequest?
    let persistedDecision: PlaybackV3DecisionResponse?
    let restarted: Bool?
    let capacityAvailable: Bool?
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
