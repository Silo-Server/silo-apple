import Foundation
import XCTest
@testable import Silo

/// Stage-0 characterization: the V3 decision → executable plan step.
///
/// `ApplePlaybackV3PlanAdapter.makeExecutionPlan` is the seam where the
/// server's `delivery` token becomes a concrete Apple engine, and where the
/// Apple planner's own route choice is either honoured (`original_http`) or
/// overridden (every server-produced delivery). Nothing else in the tree
/// pinned that mapping end-to-end, so a control-plane rewrite could reroute a
/// delivery silently.
///
/// Every case starts from the vendored golden `decision_response.json` and
/// mutates only the fields under test, so the wire shape stays the server's
/// rather than one invented here.
final class PlaybackV3ExecutionPlanMatrixTests: XCTestCase {

    // MARK: - Fixture plumbing

    private static let streamURL = URL(string: "https://example.invalid/stream.bin")!
    private static let sourceURL = URL(string: "https://example.invalid/source.mkv")!

    /// Decode the golden decision, apply mutations to the `playback_plan`
    /// object, and re-decode through the production model.
    private func plan(
        mutating mutations: [String: Any] = [:],
        streamMutations: [String: Any] = [:],
        timelineMutations: [String: Any] = [:]
    ) throws -> PlaybackV3Plan {
        let url = try PlaybackV3FixtureTestSupport.fixtureURL(
            named: "decision_response",
            bundleClass: Self.self
        )
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        var planObject = try XCTUnwrap(root["playback_plan"] as? [String: Any])
        if !streamMutations.isEmpty {
            var stream = try XCTUnwrap(planObject["stream"] as? [String: Any])
            for (key, value) in streamMutations { stream[key] = value }
            planObject["stream"] = stream
        }
        if !timelineMutations.isEmpty {
            var timeline = try XCTUnwrap(planObject["timeline"] as? [String: Any])
            for (key, value) in timelineMutations { timeline[key] = value }
            planObject["timeline"] = timeline
        }
        for (key, value) in mutations { planObject[key] = value }
        return try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3Plan.self,
            from: try JSONSerialization.data(withJSONObject: planObject)
        )
    }

    private func prepared(_ plan: PlaybackV3Plan) -> PreparedPlaybackV3 {
        PreparedPlaybackV3(
            playbackAttemptId: "apple:attempt",
            planAttemptId: "apple:plan-attempt",
            planAttemptKey: plan.planAttemptKey,
            outputContextId: "apple:output",
            serverFeatures: [
                PlaybackProtocolV3.planFeature,
                PlaybackProtocolV3.neutralContractFeature
            ],
            plan: plan
        )
    }

    private func loopbackSpec() -> LoopbackSessionSpec {
        LoopbackSessionSpec(
            sourceURL: Self.sourceURL,
            headers: ["Authorization": "Bearer fixture"],
            sourceStartTimeSeconds: 0,
            videoMode: .passthroughHEVC,
            sourceVideoFrameRate: 23.976,
            selectedAudio: .absent,
            availableAudioTracks: [],
            manifestMetadata: LoopbackSessionSpec.ManifestMetadata(
                advertisedDolbyVisionProfile: nil,
                compatibilityBrand: nil,
                videoRange: "PQ",
                mayClaimAtmos: false
            )
        )
    }

    /// The plan the Apple route planner produced before the adapter ran. Only
    /// `engine`, `loopbackSession`, `decisionTrace` and `sourceMetadata` of it
    /// are consumed by the adapter.
    private func basePlan(
        engine: PlaybackEngineKind,
        loopbackSession: LoopbackSessionSpec? = nil
    ) -> PlaybackExecutionPlan {
        PlaybackExecutionPlan(
            delivery: .direct,
            engine: engine,
            startMode: .absolutePosition(0),
            streamRequest: streamRequest(),
            loopbackSession: loopbackSession,
            requirements: .baseline,
            parityBlockers: [],
            decisionTrace: ["delivery_direct", "container_mkv"],
            degradationWarnings: [],
            reason: "base",
            normalizationSummary: PlaybackNormalizationSummary(
                containerMode: "local_fmp4_hls",
                videoMode: "hevc_passthrough",
                audioMode: "copy",
                subtitleMode: "none"
            )
        )
    }

    private func streamRequest() -> StreamRequest {
        StreamRequest(
            url: Self.streamURL,
            headers: ["Authorization": "Bearer fixture"],
            serverUrl: "https://example.invalid"
        )
    }

    private func execute(
        _ v3Plan: PlaybackV3Plan,
        base: PlaybackExecutionPlan
    ) throws -> PlaybackExecutionPlan {
        try ApplePlaybackV3PlanAdapter.makeExecutionPlan(
            v3: prepared(v3Plan),
            basePlan: base,
            streamRequest: streamRequest(),
            routeRequirements: .baseline
        )
    }

    // MARK: - Delivery → engine matrix

    func testOriginalHTTPKeepsWhateverTheApplePlannerChose() throws {
        let v3Plan = try plan()

        for engine: PlaybackEngineKind in [.avPlayerNativeDirect, .avPlayerHLS] {
            let result = try execute(v3Plan, base: basePlan(engine: engine))
            XCTAssertEqual(result.engine, engine, "\(engine)")
            XCTAssertEqual(result.delivery, .direct, "\(engine)")
            XCTAssertEqual(result.wireDelivery, "original_http", "\(engine)")
            XCTAssertNil(result.loopbackSession, "\(engine)")
        }

        let loopback = try execute(
            v3Plan,
            base: basePlan(engine: .siloPlayerLoopback, loopbackSession: loopbackSpec())
        )
        XCTAssertEqual(loopback.engine, .siloPlayerLoopback)
        XCTAssertEqual(loopback.delivery, .direct)
        XCTAssertEqual(loopback.loopbackSession?.sourceURL, Self.sourceURL)
        XCTAssertEqual(loopback.loopbackSession?.videoMode, .passthroughHEVC)
    }

    func testServerRemuxProgressiveForcesNativeDirectAndDropsTheLoopback() throws {
        let v3Plan = try plan(mutating: ["delivery": "server_remux_progressive"])
        let result = try execute(
            v3Plan,
            base: basePlan(engine: .siloPlayerLoopback, loopbackSession: loopbackSpec())
        )

        XCTAssertEqual(result.engine, .avPlayerNativeDirect)
        XCTAssertEqual(result.delivery, .remux)
        XCTAssertEqual(result.wireDelivery, "server_remux_progressive")
        XCTAssertNil(result.loopbackSession)
    }

    func testBothServerHLSDeliveriesForceTheHLSEngine() throws {
        let cases: [(String, PlaybackDeliveryStrategy)] = [
            ("server_remux_hls", .remux),
            ("server_transcode_hls", .transcode)
        ]
        for (delivery, expectedStrategy) in cases {
            let v3Plan = try plan(
                mutating: ["delivery": delivery],
                streamMutations: ["protocol": "hls", "mime_type": "application/vnd.apple.mpegurl"]
            )
            let result = try execute(
                v3Plan,
                base: basePlan(engine: .siloPlayerLoopback, loopbackSession: loopbackSpec())
            )

            XCTAssertEqual(result.engine, .avPlayerHLS, delivery)
            XCTAssertEqual(result.delivery, expectedStrategy, delivery)
            XCTAssertEqual(result.wireDelivery, delivery, delivery)
            XCTAssertNil(result.loopbackSession, delivery)
        }
    }

    // MARK: - Transport inputs

    /// The adapter never reads `plan.stream.url`: the caller has already
    /// resolved it (absolute URL, auth headers) into a `StreamRequest`, and
    /// both slots on the execution plan are that same request.
    func testStreamRequestIsTheCallersAndFillsBothSlots() throws {
        let result = try execute(try plan(), base: basePlan(engine: .avPlayerNativeDirect))

        XCTAssertEqual(result.streamRequest.url, Self.streamURL)
        XCTAssertEqual(result.sourceStreamRequest.url, Self.streamURL)
        XCTAssertEqual(result.streamRequest.headers, ["Authorization": "Bearer fixture"])
        XCTAssertNotEqual(
            result.streamRequest.url.absoluteString,
            "/stream/11111111-1111-4111-8111-111111111111"
        )
    }

    func testStartModeIsTheClampedPlayerStartOfTheTimeline() throws {
        let golden = try execute(try plan(), base: basePlan(engine: .avPlayerNativeDirect))
        XCTAssertEqual(golden.startMode, .absolutePosition(12.5))

        // Every delivery starts the same way: the adapter never emits
        // `.startOfManifest`, even for a server HLS window.
        let hls = try execute(
            try plan(
                mutating: ["delivery": "server_remux_hls"],
                streamMutations: ["protocol": "hls"]
            ),
            base: basePlan(engine: .avPlayerNativeDirect)
        )
        XCTAssertEqual(hls.startMode, .absolutePosition(12.5))

        let negative = try execute(
            try plan(timelineMutations: ["player_start_seconds": -30]),
            base: basePlan(engine: .avPlayerNativeDirect)
        )
        XCTAssertEqual(negative.startMode, .absolutePosition(0))
    }

    // MARK: - Decision trace

    func testDecisionTraceAppendsProtocolTokensToThePlannerTrace() throws {
        let v3Plan = try plan()
        let base = basePlan(engine: .avPlayerNativeDirect)
        let result = try execute(v3Plan, base: base)

        XCTAssertEqual(result.decisionTrace, base.decisionTrace + [
            "protocol_v3",
            "v3_plan_\(v3Plan.planId)",
            "v3_delivery_original_http"
        ])
        XCTAssertEqual(result.reason, "v3_validated_original_playback")
        XCTAssertEqual(result.playbackSessionId, v3Plan.sessionId)
        XCTAssertEqual(result.parityBlockers, [])
    }

    func testQuirkAndRuntimeCorrectionTokensFollowTheTransformationTokens() throws {
        let v3Plan = try plan(mutating: [
            "applied_quirks": [[
                "id": "atv_dv_pq",
                "registry_revision": "r7",
                "action": "force_pq"
            ]],
            "runtime_corrections": ["client_surface_recovery_v1"]
        ])
        let base = basePlan(engine: .avPlayerNativeDirect)
        let result = try execute(v3Plan, base: base)

        XCTAssertEqual(result.decisionTrace, base.decisionTrace + [
            "protocol_v3",
            "v3_plan_\(v3Plan.planId)",
            "v3_delivery_original_http",
            "v3_quirk_r7_atv_dv_pq",
            "v3_runtime_correction_client_surface_recovery_v1"
        ])
    }

    // MARK: - Client transformations

    func testClientDolbyVisionTransformForcesTheLoopbackExecutor() throws {
        let v3Plan = try plan(mutating: [
            "transformations": [[
                "name": "client_dv7_to_dv81",
                "executor": "client",
                "recipe_version": "v1",
                "validated_claims": ["dolby_vision"]
            ]]
        ])
        let base = basePlan(engine: .avPlayerNativeDirect, loopbackSession: loopbackSpec())
        let result = try execute(v3Plan, base: base)

        // The planner said native-direct; a client transformation overrules it.
        XCTAssertEqual(result.engine, .siloPlayerLoopback)
        XCTAssertEqual(result.loopbackSession?.videoMode, .convertProfile7To81)
        XCTAssertEqual(result.loopbackSession?.manifestMetadata.advertisedDolbyVisionProfile, 8)
        XCTAssertEqual(result.loopbackSession?.manifestMetadata.compatibilityBrand, "db1p")
        XCTAssertEqual(
            result.decisionTrace.last,
            "v3_transform_client_client_dv7_to_dv81_v1"
        )
    }

    func testClientTransformWithoutALoopbackBaseIsRejected() throws {
        let v3Plan = try plan(mutating: [
            "transformations": [[
                "name": "client_dv7_to_dv81",
                "executor": "client",
                "recipe_version": "v1",
                "validated_claims": []
            ]]
        ])
        XCTAssertThrowsError(
            try execute(v3Plan, base: basePlan(engine: .avPlayerNativeDirect))
        ) { error in
            XCTAssertEqual(
                error as? ApplePlaybackV3PlanError,
                .invalidClientTransformation(
                    "client_dv7_to_dv81 requires the Apple loopback executor"
                )
            )
        }
    }

    // MARK: - Validation gate ahead of the mapping

    func testProtocolAndDeliveryMustAgreeBeforeAnyEngineIsChosen() throws {
        // HLS transport under a direct delivery, and a progressive transport
        // under an HLS delivery, are both rejected rather than silently routed.
        XCTAssertThrowsError(
            try execute(
                try plan(streamMutations: ["protocol": "hls"]),
                base: basePlan(engine: .avPlayerNativeDirect)
            )
        ) { error in
            XCTAssertEqual(
                error as? ApplePlaybackV3PlanError,
                .invalidTransport("HLS protocol/delivery mismatch")
            )
        }

        XCTAssertThrowsError(
            try execute(
                try plan(mutating: ["delivery": "server_transcode_hls"]),
                base: basePlan(engine: .avPlayerNativeDirect)
            )
        ) { error in
            XCTAssertEqual(
                error as? ApplePlaybackV3PlanError,
                .invalidTransport("progressive protocol/delivery mismatch")
            )
        }
    }

    func testUnsupportedDeliveryNeverReachesAnEngine() throws {
        XCTAssertThrowsError(
            try execute(
                try plan(mutating: ["delivery": "server_burn_in_hls"]),
                base: basePlan(engine: .avPlayerNativeDirect)
            )
        ) { error in
            XCTAssertEqual(
                error as? ApplePlaybackV3PlanError,
                .unsupportedDelivery("server_burn_in_hls")
            )
        }
    }

    // MARK: - Source metadata + normalization summary

    func testSourceMetadataComesFromTheServerProbeNotTheCatalog() throws {
        let result = try execute(try plan(), base: basePlan(engine: .avPlayerNativeDirect))

        XCTAssertEqual(result.sourceMetadata.container, "mp4")
        XCTAssertEqual(result.sourceMetadata.videoCodec, "h264")
        XCTAssertEqual(result.sourceMetadata.audioCodec, "aac")
        XCTAssertNil(result.sourceMetadata.dolbyVisionProfile)
    }

    func testNormalizationSummaryKeepsThePlannerContainerOnlyForOriginalHTTP() throws {
        let base = basePlan(engine: .siloPlayerLoopback, loopbackSession: loopbackSpec())

        let direct = try execute(try plan(), base: base)
        XCTAssertEqual(direct.normalizationSummary.containerMode, "local_fmp4_hls")
        XCTAssertEqual(direct.normalizationSummary.videoMode, "h264")
        XCTAssertEqual(direct.normalizationSummary.audioMode, "aac")
        XCTAssertEqual(direct.normalizationSummary.subtitleMode, "off")

        let remux = try execute(
            try plan(mutating: ["delivery": "server_remux_progressive"]),
            base: base
        )
        XCTAssertEqual(remux.normalizationSummary.containerMode, "server_remux_progressive")
    }
}
