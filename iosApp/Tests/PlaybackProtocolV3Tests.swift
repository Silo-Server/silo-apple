import Foundation
import XCTest
@testable import Silo

/// Minimal cross-task observation point for the cancellation-shield tests.
actor PlaybackTestActorBox<Value: Sendable> {
    private(set) var value: Value?

    func set(_ newValue: Value) { value = newValue }
}

@MainActor
final class PlaybackProtocolV3Tests: XCTestCase {
    func testServerGoldenDecisionDecodesAndPublishesCompleteSubtitleInventory() throws {
        let response = try PlaybackV3FixtureTestSupport.decode(
            PlaybackV3DecisionResponse.self,
            named: "decision_response",
            bundleClass: Self.self
        )

        guard case .playable(let plan, let sessionId) = response.validatedForApple() else {
            return XCTFail("Expected the recovered server fixture to be playable")
        }
        XCTAssertEqual(sessionId, "11111111-1111-4111-8111-111111111111")
        XCTAssertFalse(plan.planAttemptKey.isEmpty)
        XCTAssertEqual(plan.source.durationSeconds, 7_200)
        XCTAssertEqual(plan.availableQualities.map(\.label), ["original"])
        XCTAssertEqual(plan.subtitle.inventory.map(\.combinedIndex), [0, 1, 2, 3, 4])
        XCTAssertEqual(plan.subtitle.inventory[3].delivery, "burn_in_only")
        XCTAssertNil(plan.subtitle.inventory[3].url)
        let qualityOptions = ApplePlaybackQuality.playbackOptions(
            serverQualities: plan.availableQualities,
            fallbackVersion: nil
        )
        XCTAssertEqual(qualityOptions.map(\.id), ["auto", "original"])
        XCTAssertEqual(qualityOptions.map(\.bitrateKbps), [0, 8_000])

        let session = ApplePlaybackV3PlanAdapter.playbackSession(
            plan: plan,
            sessionId: sessionId,
            selectedVersion: makeVersion(
                container: "mp4",
                videoCodec: "h264",
                audioCodec: "aac"
            ),
            serverFeatures: response.serverFeatures
        )
        XCTAssertEqual(session.position, 12.5)
        XCTAssertEqual(session.durationSeconds, 7_200)
        // Starting with subtitles off must not hide selectable sidecars.
        XCTAssertEqual(session.subtitleUrls?.count, 4)
        let authoredASS = try XCTUnwrap(session.subtitleUrls?.first(where: { $0.index == 1 }))
        XCTAssertEqual(authoredASS.default, false)
        XCTAssertEqual(authoredASS.hearingImpaired, false)
        XCTAssertEqual(
            authoredASS.fontBundleUrl,
            "/stream/11111111-1111-4111-8111-111111111111/subtitles/1/fonts?file_id=42"
        )
    }

    func testAuthorizedMediaOriginsIsNegotiatedPerAttemptAndNeverByAudio() {
        // Not a static claim: the capability report and the audiobook surface
        // must never carry it, and the video start request only adds it when
        // the server advertised it.
        XCTAssertFalse(
            ApplePlaybackV3Capabilities.features
                .contains(PlaybackProtocolV3.authorizedMediaOriginsFeature)
        )
        XCTAssertFalse(
            ApplePlaybackV3Capabilities.audiobookFeatures
                .contains(PlaybackProtocolV3.authorizedMediaOriginsFeature)
        )
        XCTAssertEqual(
            ApplePlaybackV3Capabilities.startFeatures(authorizedMediaOrigins: false),
            ApplePlaybackV3Capabilities.features
        )

        let negotiated = ApplePlaybackV3Capabilities.startFeatures(authorizedMediaOrigins: true)
        XCTAssertTrue(negotiated.contains(PlaybackProtocolV3.authorizedMediaOriginsFeature))
        // Meaningful only alongside header-authenticated media.
        XCTAssertTrue(negotiated.contains(PlaybackProtocolV3.headerAuthenticatedMediaFeature))
        XCTAssertEqual(
            negotiated.filter { $0 != PlaybackProtocolV3.authorizedMediaOriginsFeature },
            ApplePlaybackV3Capabilities.features
        )
    }

    func testRecoveredServerRequestAndCapabilityFixturesDecode() throws {
        let capability = try PlaybackV3FixtureTestSupport.decode(
            PlaybackV3CapabilityResponse.self,
            named: "capability_response",
            bundleClass: Self.self
        )
        XCTAssertEqual(capability.protocolVersions, [3])
        XCTAssertTrue(capability.features.contains(PlaybackProtocolV3.neutralContractFeature))
        XCTAssertTrue(capability.features.contains(PlaybackProtocolV3.headerAuthenticatedMediaFeature))
        XCTAssertEqual(
            Set(capability.deliveries),
            [
                "original_http",
                "server_remux_progressive",
                "server_remux_hls",
                "server_transcode_hls"
            ]
        )

        let start = try PlaybackV3FixtureTestSupport.decode(
            PlaybackV3StartRequest.self,
            named: "start_request",
            bundleClass: Self.self
        )
        XCTAssertEqual(start.progressPersistence, "client")
        XCTAssertEqual(start.startPosition, 12.5)
        XCTAssertEqual(start.clientCapabilities.videoEvidence, PlaybackProtocolV3.Evidence.exact)
        XCTAssertEqual(start.clientPlaybackContext.device.platform, "android")
        XCTAssertEqual(start.clientPlaybackContext.output.outputContextId, "7")
        XCTAssertEqual(Set(start.clientPlaybackContext.deliveries.keys), ["original_http"])

        let replan = try fixtureObject(named: "replan_request")
        let decision = try PlaybackV3FixtureTestSupport.decode(
            PlaybackV3DecisionResponse.self,
            named: "decision_response",
            bundleClass: Self.self
        )
        let plan = try XCTUnwrap(decision.playbackPlan)
        XCTAssertTrue(decision.serverFeatures.contains(PlaybackProtocolV3.neutralContractFeature))
        XCTAssertTrue(decision.serverFeatures.contains(PlaybackProtocolV3.headerAuthenticatedMediaFeature))
        XCTAssertEqual(replan["failed_plan_id"] as? String, plan.planId)
        XCTAssertEqual(replan["plan_attempt_key"] as? String, plan.planAttemptKey)
        XCTAssertEqual(replan["attempted_plan_keys"] as? [String], [plan.planAttemptKey])
        XCTAssertNil(replan["engine"])
        XCTAssertNil(replan["output_route_generation"])

        let routeEvent = try fixtureObject(named: "route_event")
        XCTAssertEqual(routeEvent["output_context_id"] as? String, "7")
        XCTAssertEqual(routeEvent["plan_id"] as? String, plan.planId)
        XCTAssertEqual(routeEvent["plan_attempt_key"] as? String, plan.planAttemptKey)

        let subtitleFixture = try fixtureObject(named: "subtitle_inventory")
        let inventory = try XCTUnwrap(subtitleFixture["inventory"] as? [[String: Any]])
        XCTAssertEqual(inventory.compactMap { $0["combined_index"] as? Int }, [0, 1, 2, 3, 4])

        let attemptKeys = try fixtureArray(named: "attempt_keys")
        XCTAssertFalse(attemptKeys.isEmpty)
        for vector in attemptKeys {
            let serverKey = try XCTUnwrap(vector["server_plan_attempt_key"] as? String)
            XCTAssertEqual(vector["replan_echo"] as? String, serverKey)
            XCTAssertEqual(vector["attempted_plan_keys"] as? [String], [serverKey])
            XCTAssertEqual(
                vector["expected_server_action"] as? String,
                "reject_already_attempted_plan"
            )
        }
    }

    func testPlanAttemptKeyIsOpaqueAndEchoedVerbatim() throws {
        let serverKey = "v3:server-owned-token"
        let plan = makePlan(planAttemptKey: serverKey)
        let prepared = PreparedPlaybackV3(
            playbackAttemptId: "apple:attempt",
            planAttemptId: "apple-plan:attempt",
            planAttemptKey: plan.planAttemptKey,
            outputContextId: "apple:output",
            serverFeatures: [PlaybackProtocolV3.planFeature],
            plan: plan
        )
        XCTAssertEqual(prepared.planAttemptKey, serverKey)

        let request = makeReplanRequest(
            planAttemptKey: prepared.planAttemptKey,
            operation: PlaybackProtocolV3.ReplanOperation.failureRecovery,
            failure: PlaybackV3Failure(
                classification: "decoder_failed",
                message: "fixture",
                decoderName: nil
            )
        )
        let object = try encodedObject(request)
        XCTAssertEqual(object["plan_attempt_key"] as? String, serverKey)
        XCTAssertNil(object["engine"])
        XCTAssertNil(object["output_route_generation"])
    }

    func testIntentReplansCarryNoFailureAndUseNeutralOperations() throws {
        XCTAssertEqual(
            PlaybackSessionBridge.replanOperation(forClassification: "audio_track_changed"),
            PlaybackProtocolV3.ReplanOperation.trackChange
        )
        XCTAssertEqual(
            PlaybackSessionBridge.replanOperation(forClassification: "subtitle_track_changed"),
            PlaybackProtocolV3.ReplanOperation.trackChange
        )
        XCTAssertEqual(
            PlaybackSessionBridge.replanOperation(forClassification: "quality_changed"),
            PlaybackProtocolV3.ReplanOperation.qualityChange
        )
        XCTAssertEqual(
            PlaybackSessionBridge.replanOperation(forClassification: "decoder_failed"),
            PlaybackProtocolV3.ReplanOperation.failureRecovery
        )
        XCTAssertNil(
            PlaybackSessionBridge.replanFailure(
                operation: PlaybackProtocolV3.ReplanOperation.seekReanchor,
                classification: "seek_reanchor",
                message: "intent"
            )
        )
        XCTAssertEqual(
            PlaybackSessionBridge.replanFailure(
                operation: PlaybackProtocolV3.ReplanOperation.failureRecovery,
                classification: "decoder_failed",
                message: "broken"
            )?.classification,
            "decoder_failed"
        )

        let request = makeReplanRequest(
            planAttemptKey: "v3:intent",
            operation: PlaybackProtocolV3.ReplanOperation.qualityChange,
            failure: nil
        )
        let object = try encodedObject(request)
        XCTAssertEqual(object["operation"] as? String, "quality_change")
        XCTAssertNil(object["failure"])
        XCTAssertEqual(object["attempted_plan_keys"] as? [String], [])
    }

    func testOutputRouteChangeUsesTheIntentOperationWhenTheServerOffersIt() throws {
        let advertised = [
            PlaybackProtocolV3.planFeature,
            PlaybackProtocolV3.outputChangeFeature
        ]
        XCTAssertEqual(
            PlaybackSessionBridge.replanOperation(
                forClassification: "output_route_changed",
                serverFeatures: advertised
            ),
            PlaybackProtocolV3.ReplanOperation.outputChange,
            "an output-route change is an intent replan, so the previous route stays eligible"
        )
        // "Clients must keep the active route when this feature is absent": a
        // server without `output_change_v1` rejects the operation outright, so
        // the historical failure-recovery spelling remains the only option.
        XCTAssertEqual(
            PlaybackSessionBridge.replanOperation(
                forClassification: "output_route_changed",
                serverFeatures: [PlaybackProtocolV3.planFeature]
            ),
            PlaybackProtocolV3.ReplanOperation.failureRecovery
        )
        // The feature must never redirect an unrelated classification.
        XCTAssertEqual(
            PlaybackSessionBridge.replanOperation(
                forClassification: "decoder_failed",
                serverFeatures: advertised
            ),
            PlaybackProtocolV3.ReplanOperation.failureRecovery
        )
        XCTAssertTrue(
            ApplePlaybackV3Capabilities.features.contains(
                PlaybackProtocolV3.outputChangeFeature
            ),
            "the client must advertise the operation it intends to send"
        )
        // The server rejects an `output_change` that carries a failure block.
        XCTAssertNil(
            PlaybackSessionBridge.replanFailure(
                operation: PlaybackProtocolV3.ReplanOperation.outputChange,
                classification: "output_route_changed",
                message: "route changed"
            )
        )
        let request = makeReplanRequest(
            planAttemptKey: "v3:output",
            operation: PlaybackProtocolV3.ReplanOperation.outputChange,
            failure: nil
        )
        let object = try encodedObject(request)
        XCTAssertEqual(object["operation"] as? String, "output_change")
        XCTAssertNil(object["failure"])
    }

    func testSubtitleOrdinalsComeFromTheInventoryWheneverOneExists() {
        let version = makeVersion(
            container: "mkv",
            videoCodec: "h264",
            audioCodec: "aac",
            subtitleTracks: [
                makeSubtitle(index: 2, codec: "ass", external: false, path: nil),
                makeSubtitle(index: 5, codec: "pgs", external: false, path: nil),
                makeSubtitle(index: nil, codec: "srt", external: true, path: "movie.en.srt")
            ]
        )
        // The catalog knows one external sidecar; the server also carries two
        // downloaded subtitles it never exposes, so the real embedded base is 3,
        // not the 1 that counting the catalog produces.
        let inventory = [
            makeInventoryItem(combinedIndex: 0, source: "external"),
            makeInventoryItem(combinedIndex: 1, source: "downloaded"),
            makeInventoryItem(combinedIndex: 2, source: "downloaded"),
            makeInventoryItem(combinedIndex: 3, source: "embedded"),
            makeInventoryItem(combinedIndex: 4, source: "embedded", delivery: "burn_in_only")
        ]

        XCTAssertEqual(
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                ffmpegStreamIndex: 2,
                in: version,
                inventory: inventory
            ),
            3
        )
        XCTAssertEqual(
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                ffmpegStreamIndex: 5,
                in: version,
                inventory: inventory
            ),
            4,
            "a burn-in-only track keeps its ordinal and must stay addressable"
        )
        XCTAssertEqual(
            ApplePlaybackV3PlanAdapter.ffmpegSubtitleStreamIndex(
                serverCombinedIndex: 4,
                in: version,
                inventory: inventory
            ),
            5
        )
        XCTAssertNil(
            ApplePlaybackV3PlanAdapter.ffmpegSubtitleStreamIndex(
                serverCombinedIndex: 1,
                in: version,
                inventory: inventory
            ),
            "a downloaded ordinal has no embedded FFmpeg stream index"
        )
        // A sidecar player track already echoes the server's combined ordinal,
        // so it is passed through rather than re-mapped.
        XCTAssertEqual(
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                for: makePlayerSubtitle(
                    trackId: SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 2),
                    isExternal: true,
                    ffIndex: nil,
                    srcId: 2
                ),
                in: version,
                inventory: inventory
            ),
            2
        )
        // Before any plan exists there is no inventory, and the counted
        // derivation is the only identity available for the start request.
        XCTAssertEqual(
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                ffmpegStreamIndex: 2,
                in: version,
                inventory: []
            ),
            1
        )
    }

    func testCancelledStartReclaimsTheSessionItStillAllocated() async {
        let reclaimed = PlaybackTestActorBox<String>()
        let requestStarted = XCTestExpectation(description: "shielded request started")

        let caller = Task<String, Error> {
            try await PlaybackCancellationShield.run {
                requestStarted.fulfill()
                try? await Task.sleep(nanoseconds: 200_000_000)
                // The POST landed despite the caller's cancellation.
                return "session-allocated"
            } reclaim: { allocated in
                await reclaimed.set(allocated)
            }
        }

        await fulfillment(of: [requestStarted], timeout: 5)
        caller.cancel()

        do {
            _ = try await caller.value
            XCTFail("a cancelled caller must not receive the shielded outcome")
        } catch {
            XCTAssertTrue(
                error is CancellationError,
                "the caller must give up promptly so its start timeout still fires"
            )
        }

        // The shielded request keeps running and retires what it allocated.
        var observed: String?
        for _ in 0..<100 where observed == nil {
            observed = await reclaimed.value
            if observed == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        }
        XCTAssertEqual(observed, "session-allocated")
    }

    func testUncancelledStartDeliversToTheCallerAndNeverReclaims() async throws {
        let reclaimed = PlaybackTestActorBox<String>()
        let value = try await PlaybackCancellationShield.run {
            "session-allocated"
        } reclaim: { allocated in
            await reclaimed.set(allocated)
        }

        XCTAssertEqual(value, "session-allocated")
        try? await Task.sleep(nanoseconds: 50_000_000)
        let observed = await reclaimed.value
        XCTAssertNil(observed, "a delivered outcome has exactly one owner")
    }

    func testOutputRouteReplanRequiresChangedOutputContextIdentity() {
        XCTAssertFalse(
            PlaybackSessionBridge.isMaterialOutputRouteChange(
                activeOutputContextId: "apple:bedroom",
                observedOutputContextId: "apple:bedroom"
            ),
            "player-owned AVAudioSession configuration notifications must not invalidate the plan"
        )
        XCTAssertTrue(
            PlaybackSessionBridge.isMaterialOutputRouteChange(
                activeOutputContextId: "apple:bedroom",
                observedOutputContextId: "apple:airplay"
            ),
            "a genuinely different output identity must request a new plan"
        )
        XCTAssertFalse(
            PlaybackSessionBridge.isMaterialOutputRouteChange(
                activeOutputContextId: nil,
                observedOutputContextId: nil
            )
        )
        XCTAssertTrue(
            PlaybackSessionBridge.isMaterialOutputRouteChange(
                activeOutputContextId: nil,
                observedOutputContextId: "apple:bedroom"
            )
        )
    }

    func testDeclaredDolbyVisionClientTransformsAreAcceptedOnOriginalHTTP() throws {
        for name in ["client_dv7_to_dv81", "client_dv7_to_hdr10"] {
            XCTAssertNoThrow(
                try ApplePlaybackV3PlanAdapter.validate(
                    makePlan(
                        container: "mkv",
                        videoCodec: "hevc",
                        dynamicRange: "dolby_vision",
                        transformations: [
                            .init(
                                name: name,
                                executor: "client",
                                recipeVersion: "1",
                                validatedClaims: []
                            )
                        ]
                    )
                ),
                "\(name) is declared in the capability snapshot and must stay executable"
            )
        }
    }

    func testCapabilitySnapshotDeclaresTheDolbyVisionClientTransforms() throws {
        XCTAssertTrue(
            ApplePlaybackV3Capabilities.features.contains(
                PlaybackProtocolV3.clientTransformFeature
            ),
            "the server rejects the whole request if a client executor entry lacks this flag"
        )
        XCTAssertEqual(
            ApplePlaybackV3Capabilities.deviceClientTransformations.map(\.name),
            ["client_dv7_to_dv81", "client_dv7_to_hdr10"]
        )
        XCTAssertEqual(
            Set(ApplePlaybackV3Capabilities.deviceClientTransformations.map(\.executor)),
            ["client"]
        )
        XCTAssertEqual(
            ApplePlaybackV3Capabilities.deviceClientTransformations.first?.validatedClaims,
            [
                "profile7_rpu_converted_to_profile81",
                "hdr10_base_layer_preserved",
                "enhancement_layer_discarded"
            ]
        )
        XCTAssertEqual(
            ApplePlaybackV3Capabilities.deviceClientTransformations.last?.validatedClaims,
            [
                "dolby_vision_metadata_removed",
                "hdr10_base_layer_preserved",
                "enhancement_layer_discarded"
            ]
        )

        // The snapshot itself is device-gated: the simulator has no real panel
        // or hardware HEVC decoder, so it declares nothing.
        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        let original = try XCTUnwrap(
            snapshot.context.deliveries[PlaybackProtocolV3.DeliveryClass.originalHTTP]
        )
        XCTAssertEqual(
            original.transformations,
            AppleDecodeCapabilities.isSimulator
                ? []
                : ApplePlaybackV3Capabilities.deviceClientTransformations
        )
        for deliveryClass in [
            PlaybackProtocolV3.DeliveryClass.progressive,
            PlaybackProtocolV3.DeliveryClass.hls
        ] {
            XCTAssertEqual(
                snapshot.context.deliveries[deliveryClass]?.transformations,
                [],
                "\(deliveryClass) is server-produced and carries no client recipe"
            )
        }
    }

    func testUnsupportedPlanRequirementsAreRejected() {
        let clientTransform = makePlan(transformations: [
            .init(
                name: "client_owned_recipe",
                executor: "client",
                recipeVersion: "1",
                validatedClaims: []
            )
        ])
        XCTAssertThrowsError(try ApplePlaybackV3PlanAdapter.validate(clientTransform)) { error in
            XCTAssertEqual(
                error as? ApplePlaybackV3PlanError,
                .unsupportedClientTransformation("client_owned_recipe")
            )
        }

        // Mutually exclusive: one plan may name at most one client recipe.
        XCTAssertThrowsError(
            try ApplePlaybackV3PlanAdapter.validate(
                makePlan(transformations: [
                    .init(
                        name: "client_dv7_to_dv81",
                        executor: "client",
                        recipeVersion: "1",
                        validatedClaims: []
                    ),
                    .init(
                        name: "client_dv7_to_hdr10",
                        executor: "client",
                        recipeVersion: "1",
                        validatedClaims: []
                    )
                ])
            )
        ) { error in
            XCTAssertEqual(
                error as? ApplePlaybackV3PlanError,
                .invalidClientTransformation("multiple mutually exclusive client transformations")
            )
        }

        // A packaged delivery is server-produced; there is no original
        // bitstream left for Aether to transform.
        XCTAssertThrowsError(
            try ApplePlaybackV3PlanAdapter.validate(
                makePlan(
                    delivery: "server_remux_hls",
                    streamProtocol: "hls",
                    transformations: [
                        .init(
                            name: "client_dv7_to_dv81",
                            executor: "client",
                            recipeVersion: "1",
                            validatedClaims: []
                        )
                    ]
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? ApplePlaybackV3PlanError,
                .invalidClientTransformation(
                    "client transformations require the original_http delivery"
                )
            )
        }

        XCTAssertThrowsError(
            try ApplePlaybackV3PlanAdapter.validate(
                makePlan(runtimeCorrections: ["removed_engine_correction"])
            )
        )
        XCTAssertThrowsError(
            try ApplePlaybackV3PlanAdapter.validate(
                makePlan(streamProtocol: "dash")
            )
        )
    }

    func testSubtitleIdentityUsesDenseServerCombinedOrdinals() {
        let version = makeVersion(
            container: "mkv",
            videoCodec: "h264",
            audioCodec: "aac",
            subtitleTracks: [
                makeSubtitle(index: 2, codec: "ass", external: false, path: nil),
                makeSubtitle(index: 5, codec: "pgs", external: false, path: nil),
                makeSubtitle(index: nil, codec: "srt", external: true, path: "movie.en.srt")
            ]
        )

        XCTAssertEqual(
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                ffmpegStreamIndex: 2,
                in: version
            ),
            1
        )
        XCTAssertEqual(
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                ffmpegStreamIndex: 5,
                in: version
            ),
            2
        )
        XCTAssertEqual(
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                for: makePlayerSubtitle(
                    trackId: SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 0),
                    isExternal: true,
                    ffIndex: nil,
                    srcId: 0
                ),
                in: version
            ),
            0
        )
        XCTAssertEqual(
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                for: makePlayerSubtitle(
                    trackId: 12,
                    isExternal: false,
                    ffIndex: 5,
                    srcId: 1
                ),
                in: version
            ),
            2
        )
        XCTAssertEqual(
            ApplePlaybackV3PlanAdapter.ffmpegSubtitleStreamIndex(
                serverCombinedIndex: 2,
                in: version
            ),
            5
        )
        XCTAssertNil(
            ApplePlaybackV3PlanAdapter.ffmpegSubtitleStreamIndex(
                serverCombinedIndex: 0,
                in: version
            ),
            "an external combined ordinal has no embedded FFmpeg stream index"
        )
    }

    func testAdoptedPlanBecomesDurableRenewalIntent() {
        let version = makeVersion(
            container: "mkv",
            videoCodec: "h264",
            audioCodec: "aac",
            subtitleTracks: [
                makeSubtitle(index: 2, codec: "ass", external: false, path: nil),
                makeSubtitle(index: 5, codec: "pgs", external: false, path: nil),
                makeSubtitle(index: nil, codec: "srt", external: true, path: "movie.en.srt")
            ]
        )
        let selectedSubtitle = PlaybackV3SubtitleInventoryItem(
            trackId: "file:42:subtitle:2",
            combinedIndex: 2,
            source: "embedded",
            codec: "pgs",
            language: "en",
            label: "English PGS",
            forced: false,
            default: false,
            hearingImpaired: false,
            delivery: "sidecar",
            url: "/api/v1/playback/session-v3/subtitles/2.sup",
            fontBundleUrl: nil
        )
        let original = PlayerViewModel.LoadRequest(
            contentId: "movie-1",
            preferredFileId: 7,
            preferredAudioTrackIndex: 0,
            preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: nil,
            startFromBeginning: true
        )
        let plan = makePlan(
            selectedAudioIndex: 3,
            selectedSubtitleIndex: 2,
            subtitleMode: "render",
            subtitleInventory: [selectedSubtitle]
        )

        let renewal = original.adoptingProtocolV3Intent(
            plan: plan,
            selectedVersion: version,
            activeQualityId: "720p"
        )

        XCTAssertEqual(renewal.preferredFileId, 42)
        XCTAssertEqual(renewal.preferredAudioTrackIndex, 3)
        XCTAssertNil(renewal.preferredSubtitleTrackIndex)
        XCTAssertEqual(renewal.preferredProtocolV3SubtitleIndex, 2)
        XCTAssertEqual(
            renewal.preferredSidecarSubtitleTrackId,
            SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 2)
        )
        XCTAssertEqual(renewal.preferredQualityOverride, "720p")
        XCTAssertFalse(renewal.startFromBeginning)
    }

    func testAdoptedSubtitleOffPlanClearsDurableSubtitleIntent() {
        let version = makeVersion(
            container: "mkv",
            videoCodec: "h264",
            audioCodec: "aac",
            subtitleTracks: [
                makeSubtitle(index: 5, codec: "pgs", external: false, path: nil)
            ]
        )
        let original = PlayerViewModel.LoadRequest(
            contentId: "movie-1",
            preferredFileId: 7,
            preferredAudioTrackIndex: 0,
            preferredSubtitleTrackIndex: 5,
            preferredSidecarSubtitleTrackId: SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 2),
            startFromBeginning: true,
            preferredProtocolV3SubtitleIndex: 2
        )

        let renewal = original.adoptingProtocolV3Intent(
            plan: makePlan(selectedAudioIndex: 3),
            selectedVersion: version,
            activeQualityId: "original"
        )

        XCTAssertEqual(renewal.preferredFileId, 42)
        XCTAssertEqual(renewal.preferredAudioTrackIndex, 3)
        XCTAssertNil(renewal.preferredSubtitleTrackIndex)
        XCTAssertNil(renewal.preferredProtocolV3SubtitleIndex)
        XCTAssertNil(renewal.preferredSidecarSubtitleTrackId)
        XCTAssertEqual(renewal.preferredQualityOverride, "original")
        XCTAssertFalse(renewal.startFromBeginning)
    }

    func testInitialAutoSubtitleIntentIsFrozenIntoProtocolV3Plan() {
        let version = makeVersion(
            container: "mkv",
            videoCodec: "h264",
            audioCodec: "aac",
            subtitleTracks: [
                makeSubtitle(index: nil, codec: "srt", external: true, path: "movie.en.srt"),
                makeSubtitle(index: 2, codec: "subrip", external: false, path: nil),
                makeSubtitle(
                    index: 4,
                    codec: "hdmv_pgs_subtitle",
                    external: false,
                    path: nil,
                    forced: true,
                    isDefault: true
                )
            ]
        )

        XCTAssertEqual(
            PlaybackSessionBridge.initialProtocolV3SubtitleIntent(
                version: version,
                explicitFFmpegIndex: nil,
                explicitCombinedIndex: nil,
                preferredLanguage: nil,
                mode: nil,
                showForced: false,
                trackSignature: nil,
                currentAudioLanguage: nil
            ),
            PlaybackSessionBridge.InitialProtocolV3SubtitleIntent(
                ffmpegStreamIndex: 4,
                combinedIndex: 2
            )
        )

        let accessibilityVersion = makeVersion(
            container: "mkv",
            videoCodec: "h264",
            audioCodec: "aac",
            subtitleTracks: [
                makeSubtitle(index: 2, codec: "subrip", external: false, path: nil),
                makeSubtitle(
                    index: 4,
                    codec: "subrip",
                    external: false,
                    path: nil,
                    hearingImpaired: true
                )
            ]
        )
        XCTAssertEqual(
            PlaybackSessionBridge.initialProtocolV3SubtitleIntent(
                version: accessibilityVersion,
                explicitFFmpegIndex: nil,
                explicitCombinedIndex: nil,
                preferredLanguage: "en",
                mode: .always,
                showForced: false,
                preferAccessibilityTracks: true,
                disableWhenNoLanguageMatch: true,
                trackSignature: nil,
                currentAudioLanguage: "ja"
            ),
            PlaybackSessionBridge.InitialProtocolV3SubtitleIntent(
                ffmpegStreamIndex: 4,
                combinedIndex: 1
            )
        )
        XCTAssertEqual(
            PlaybackSessionBridge.initialProtocolV3SubtitleIntent(
                version: version,
                explicitFFmpegIndex: -1,
                explicitCombinedIndex: nil,
                preferredLanguage: nil,
                mode: nil,
                showForced: false,
                trackSignature: nil,
                currentAudioLanguage: nil
            ),
            PlaybackSessionBridge.InitialProtocolV3SubtitleIntent(
                ffmpegStreamIndex: nil,
                combinedIndex: nil
            )
        )
    }

    func testSimulatorCapabilitiesAreNeutralAttestedAndOutputScoped() throws {
        try XCTSkipUnless(
            AppleDecodeCapabilities.isSimulator,
            "Attested codec and HDR values are device-specific; this vector pins the simulator profile."
        )
        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        XCTAssertEqual(snapshot.context.protocolVersion, 3)
        XCTAssertEqual(snapshot.context.device.platform, "ios")
        XCTAssertEqual(
            Set(snapshot.context.deliveries.keys),
            [
                PlaybackProtocolV3.DeliveryClass.originalHTTP,
                PlaybackProtocolV3.DeliveryClass.progressive,
                PlaybackProtocolV3.DeliveryClass.hls
            ]
        )
        XCTAssertEqual(
            snapshot.capabilities.videoEvidence,
            PlaybackProtocolV3.Evidence.platformAttested
        )
        XCTAssertEqual(
            snapshot.capabilities.audioEvidence,
            PlaybackProtocolV3.Evidence.declared
        )
        XCTAssertEqual(snapshot.capabilities.codecsVideo, ["h264", "av1", "vp9", "mpeg2video", "vc1"])
        XCTAssertEqual(snapshot.capabilities.codecsVideoHardware, ["h264"])
        XCTAssertTrue(
            ApplePlaybackV3Capabilities.features.contains(
                PlaybackProtocolV3.softwareVideoDecodeFeature
            )
        )
        XCTAssertEqual(
            Set(snapshot.capabilities.videoDecode.filter { !$0.hardware }.map(\.codec)),
            Set(["h264", "av1", "vp9", "mpeg2video", "vc1"])
        )
        XCTAssertEqual(snapshot.capabilities.videoDecode.first?.profiles, [])
        XCTAssertEqual(snapshot.capabilities.videoDecode.first?.levels, [])
        XCTAssertEqual(
            snapshot.context.deliveries[PlaybackProtocolV3.DeliveryClass.progressive]?.videoCodecs,
            AppleDecodeCapabilities.packagedVideoCodecs
        )
        XCTAssertNil(snapshot.capabilities.audioPassthrough)
        XCTAssertNil(snapshot.context.output.audioPassthrough)
        XCTAssertTrue(snapshot.outputContextId?.hasPrefix("apple:") == true)
        XCTAssertFalse(snapshot.capabilities.hdr)
        XCTAssertTrue(snapshot.outputDiagnosticsLogFields.contains("hdrOutputEligible="))
        XCTAssertTrue(snapshot.outputDiagnosticsLogFields.contains("dvModes="))
        XCTAssertFalse(snapshot.outputDiagnosticsLogFields.contains("output."))

        let hdrDetails = try XCTUnwrap(snapshot.capabilities.hdrDetails)
        XCTAssertFalse(hdrDetails.claimsAnyHDR)
        for (name, delivery) in snapshot.context.deliveries {
            XCTAssertEqual(delivery.hdrDetails, hdrDetails, "delivery \(name) disagrees on HDR")
            XCTAssertEqual(delivery.audioPassthroughCodecs, [])
        }
        let original = try XCTUnwrap(
            snapshot.context.deliveries[PlaybackProtocolV3.DeliveryClass.originalHTTP]
        )
        XCTAssertTrue(original.subtitles.embeddedBitmap)
        XCTAssertFalse(original.subtitles.sidecarBitmap)
        XCTAssertFalse(original.subtitles.assStyling)
        XCTAssertFalse(original.subtitles.fontAttachments)
        for delivery in snapshot.context.deliveries.values {
            XCTAssertEqual(delivery.features, [])
            XCTAssertFalse(delivery.authHeaderRefresh)
            XCTAssertEqual(delivery.transformations, [])
        }
    }

    func testServerPackagedDeliveriesUseConservativeCodecClaims() throws {
        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        for deliveryClass in [
            PlaybackProtocolV3.DeliveryClass.progressive,
            PlaybackProtocolV3.DeliveryClass.hls
        ] {
            let delivery = try XCTUnwrap(snapshot.context.deliveries[deliveryClass])
            XCTAssertEqual(delivery.videoCodecs, AppleDecodeCapabilities.packagedVideoCodecs)
        }
    }

    func testStartRequestUsesOnlyNeutralSnakeCaseContract() throws {
        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        let request = PlaybackV3StartRequest(
            protocolVersion: 3,
            clientFeatures: ApplePlaybackV3Capabilities.features,
            fileId: 42,
            profileId: "profile-1",
            playbackAttemptId: "apple:12345678",
            qualityPreference: "auto",
            subtitleFidelityPreference: "preserve",
            progressPersistence: nil,
            startPosition: 12.5,
            audioTrackId: "file:42:audio:0",
            audioTrackIndex: 0,
            subtitleTrackId: nil,
            subtitleTrackIndex: nil,
            metered: false,
            bandwidthEstimateKbps: nil,
            bandwidthCapKbps: nil,
            clientCapabilities: snapshot.capabilities,
            clientPlaybackContext: snapshot.context
        )
        let object = try encodedObject(request)
        XCTAssertEqual(object["protocol_version"] as? Int, 3)
        XCTAssertEqual(object["playback_attempt_id"] as? String, "apple:12345678")
        XCTAssertNotNil(object["client_capabilities"])
        let context = try XCTUnwrap(object["client_playback_context"] as? [String: Any])
        XCTAssertNotNil(context["deliveries"])
        XCTAssertNil(context["engines"])
        XCTAssertNil(context["platform"])
        XCTAssertNil(object["engine"])
        XCTAssertNil(object["output_route_generation"])
        XCTAssertNil(object["progress_persistence"])
        let output = try XCTUnwrap(context["output"] as? [String: Any])
        XCTAssertEqual(output["output_context_id"] as? String, snapshot.outputContextId)
    }

    func testAudioStartUsesClientOwnedProgressWithExplicitZeroPosition() throws {
        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        let request = PlaybackV3StartRequest(
            protocolVersion: 3,
            clientFeatures: ApplePlaybackV3Capabilities.features,
            fileId: 42,
            profileId: "profile-1",
            playbackAttemptId: "apple-audio:12345678",
            qualityPreference: "auto",
            subtitleFidelityPreference: "preserve",
            progressPersistence: "client",
            startPosition: 0,
            audioTrackId: nil,
            audioTrackIndex: nil,
            subtitleTrackId: nil,
            subtitleTrackIndex: nil,
            metered: false,
            bandwidthEstimateKbps: nil,
            bandwidthCapKbps: nil,
            clientCapabilities: snapshot.capabilities,
            clientPlaybackContext: snapshot.context
        )
        let object = try encodedObject(request)
        XCTAssertEqual(object["progress_persistence"] as? String, "client")
        XCTAssertEqual(object["start_position"] as? Double, 0)
    }

    func testAetherCapabilityGateRequiresNeutralAndHeaderAuthenticatedMedia() {
        let capability = PlaybackV3CapabilityResponse(
            enabled: true,
            protocolVersions: [3],
            features: [
                PlaybackProtocolV3.planFeature,
                PlaybackProtocolV3.neutralContractFeature,
                PlaybackProtocolV3.headerAuthenticatedMediaFeature
            ],
            deliveries: ["original_http"],
            transformations: [],
            reason: nil
        )
        XCTAssertTrue(PlaybackSessionBridge.supportsNeutralProtocolV3(capability))
        XCTAssertFalse(PlaybackSessionBridge.supportsNeutralProtocolV3(
            PlaybackV3CapabilityResponse(
                enabled: true,
                protocolVersions: [3],
                features: [
                    PlaybackProtocolV3.planFeature,
                    PlaybackProtocolV3.neutralContractFeature,
                ],
                deliveries: ["original_http"],
                transformations: [],
                reason: nil
            )
        ))
        XCTAssertFalse(PlaybackSessionBridge.supportsNeutralProtocolV3(
            PlaybackV3CapabilityResponse(
                enabled: true,
                protocolVersions: [3],
                features: [PlaybackProtocolV3.planFeature],
                deliveries: ["original_http"],
                transformations: [],
                reason: nil
            )
        ))
        XCTAssertTrue(PlaybackSessionBridge.isMissingProtocolV3Capability(
            HTTPError.http(statusCode: 404, body: nil)
        ))
        XCTAssertTrue(PlaybackSessionBridge.isMissingProtocolV3Capability(
            HTTPError.http(statusCode: 405, body: nil)
        ))
        XCTAssertFalse(PlaybackSessionBridge.isMissingProtocolV3Capability(
            HTTPError.http(statusCode: 500, body: nil)
        ))
    }

    func testTerminalStartRouteEventIsSessionlessAndAttemptScoped() {
        let snapshot = ApplePlaybackV3Capabilities.audiobookSnapshot()
        let event = PlaybackSessionBridge.terminalStartRouteEvent(
            playbackAttemptId: "apple:attempt-terminal",
            snapshot: snapshot,
            terminal: PlaybackV3Terminal(
                reason: "adaptation_unavailable",
                message: "No executable route is available.",
                retryable: false
            )
        )

        XCTAssertEqual(event.protocolVersion, 3)
        XCTAssertEqual(event.playbackAttemptId, "apple:attempt-terminal")
        XCTAssertEqual(event.event, "terminal")
        XCTAssertEqual(event.fallbackReason, "adaptation_unavailable")
        XCTAssertEqual(event.outputContextId, snapshot.outputContextId)
        XCTAssertNil(event.sessionId)
        XCTAssertNil(event.planId)
        XCTAssertNil(event.planAttemptId)
        XCTAssertNil(event.planAttemptKey)
        XCTAssertEqual(event.appliedQuirkIds, [])
        XCTAssertEqual(event.diagnostics["error_cause"], "No executable route is available.")
    }

    func testMissingPlaybackSessionDetectionRequiresTheSpecific404() {
        XCTAssertTrue(PlaybackSessionBridge.isPlaybackSessionMissing(
            HTTPError.http(
                statusCode: 404,
                body: #"{"error":"playback_session_not_found","message":"Playback session not found"}"#
            )
        ))
        XCTAssertTrue(PlaybackSessionBridge.isPlaybackSessionMissing(
            HTTPError.http(statusCode: 404, body: "Playback session not found")
        ))
        XCTAssertFalse(PlaybackSessionBridge.isPlaybackSessionMissing(
            HTTPError.http(statusCode: 404, body: "Not found")
        ))
        XCTAssertFalse(PlaybackSessionBridge.isPlaybackSessionMissing(
            HTTPError.http(
                statusCode: 500,
                body: #"{"error":"playback_session_not_found"}"#
            )
        ))
    }

    func testHDRAttestationDoesNotInventHDR10PlusOrMacDolbyVision() {
        let details = ApplePlaybackV3Capabilities.hdrDetails(
            hdr10: true,
            hlg: true,
            dolbyVision: false
        )
        XCTAssertTrue(details.hdr10)
        XCTAssertTrue(details.hlg)
        XCTAssertFalse(details.hdr10Plus)
        XCTAssertEqual(details.dolbyVisionProfiles, [])
    }

    func testEmptySubtitleInventoryStartsDownloadedIdentityAtZero() {
        XCTAssertEqual(PlayerViewModel.protocolV3DownloadedSubtitleBaseTrackCount([]), 0)
    }

    func testV3ReplanRestoresServerRenderedSubtitleAsDisplayOnlySelection() {
        let sidecarId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 3)

        XCTAssertEqual(
            PlayerViewModel.protocolV3SidecarRestoreIntent(
                snapshot: sidecarId,
                selectedSubtitleIndex: 3,
                subtitleMode: "render"
            ),
            .renderLocally(sidecarId)
        )
        XCTAssertEqual(
            PlayerViewModel.protocolV3SidecarRestoreIntent(
                snapshot: sidecarId,
                selectedSubtitleIndex: 3,
                subtitleMode: "burn_in"
            ),
            .serverRendered(sidecarId)
        )
        XCTAssertNil(PlayerViewModel.protocolV3SidecarRestoreIntent(
            snapshot: sidecarId,
            selectedSubtitleIndex: 3,
            subtitleMode: "off"
        ))
        XCTAssertNil(PlayerViewModel.protocolV3SidecarRestoreIntent(
            snapshot: sidecarId,
            selectedSubtitleIndex: 4,
            subtitleMode: "burn_in"
        ))
        XCTAssertNil(PlayerViewModel.protocolV3SidecarRestoreIntent(
            snapshot: sidecarId,
            selectedSubtitleIndex: 4,
            subtitleMode: "render"
        ))
    }

    func testV3AudioIntentOverridesBackendDefaultAfterReplan() {
        let version = makeVersion(
            container: "mkv",
            videoCodec: "h264",
            audioCodec: "truehd",
            audioTracks: [
                makeAudio(index: 0, codec: "truehd", isDefault: true),
                makeAudio(index: 1, codec: "ac3", isDefault: false)
            ]
        )
        let original = PlayerViewModel.LoadRequest(
            contentId: "movie-1",
            preferredFileId: 42,
            preferredAudioTrackIndex: 0,
            preferredSubtitleTrackIndex: -1,
            preferredSidecarSubtitleTrackId: nil,
            startFromBeginning: false
        )
        let adopted = original.adoptingProtocolV3Intent(
            plan: makePlan(selectedAudioIndex: 1),
            selectedVersion: version,
            activeQualityId: "original"
        )

        let intent = PlayerViewModel.protocolV3PendingTrackIntent(
            plan: makePlan(selectedAudioIndex: 1),
            request: adopted
        )

        XCTAssertEqual(adopted.preferredAudioTrackIndex, 1)
        XCTAssertEqual(intent.audioIndex, 1)
        XCTAssertEqual(intent.embeddedSubtitleIndex, -1)
        XCTAssertNil(intent.sidecarSubtitleTrackId)
    }

    func testStaleStreamGenerationCannotConsumePendingTrackIntent() {
        XCTAssertTrue(
            PlayerViewModel.isCurrentStreamCallback(7, currentGeneration: 7)
        )
        XCTAssertFalse(
            PlayerViewModel.isCurrentStreamCallback(6, currentGeneration: 7)
        )
    }

    func testAudiobookFeaturesDoNotClaimSeekReanchor() {
        XCTAssertFalse(
            ApplePlaybackV3Capabilities.audiobookFeatures.contains(
                PlaybackProtocolV3.seekReanchorFeature
            )
        )
        XCTAssertTrue(
            ApplePlaybackV3Capabilities.audiobookFeatures.contains(
                PlaybackProtocolV3.planFeature
            )
        )
        XCTAssertTrue(
            ApplePlaybackV3Capabilities.audiobookFeatures.contains(
                PlaybackProtocolV3.headerAuthenticatedMediaFeature
            )
        )
        XCTAssertFalse(
            ApplePlaybackV3Capabilities.audiobookFeatures.contains(
                PlaybackProtocolV3.softwareVideoDecodeFeature
            )
        )
    }

    func testAudiobookSnapshotOnlyAdvertisesAudioOnlyAetherRoutes() throws {
        let snapshot = ApplePlaybackV3Capabilities.audiobookSnapshot()
        XCTAssertEqual(snapshot.capabilities.codecsVideo, [])
        XCTAssertEqual(snapshot.capabilities.codecsVideoHardware, [])
        XCTAssertEqual(snapshot.capabilities.videoDecode, [])
        XCTAssertFalse(snapshot.capabilities.codecsAudio.contains("dts"))
        XCTAssertFalse(snapshot.capabilities.codecsAudio.contains("truehd"))
        XCTAssertFalse(snapshot.capabilities.codecsAudio.contains("vorbis"))
        XCTAssertFalse(snapshot.capabilities.containers.contains("mkv"))
        XCTAssertFalse(snapshot.capabilities.containers.contains("matroska"))
        XCTAssertTrue(snapshot.capabilities.containers.contains("mp4"))
        XCTAssertTrue(snapshot.capabilities.containers.contains("m4b"))
        XCTAssertTrue(snapshot.capabilities.containers.contains("flac"))

        for delivery in snapshot.context.deliveries.values {
            XCTAssertEqual(delivery.videoCodecs, [])
            XCTAssertEqual(delivery.audioPassthroughCodecs, [])
            XCTAssertEqual(delivery.transformations, [])
        }
        let original = try XCTUnwrap(
            snapshot.context.deliveries[PlaybackProtocolV3.DeliveryClass.originalHTTP]
        )
        XCTAssertEqual(original.features, [])
        XCTAssertFalse(original.authHeaderRefresh)
        XCTAssertFalse(original.audioDecodeCodecs.contains("dts"))
        XCTAssertFalse(original.audioDecodeCodecs.contains("truehd"))
        XCTAssertFalse(original.audioDecodeCodecs.contains("vorbis"))
    }

    func testAudioOnlyAndUnknownServerQualityRungsRemainUsable() {
        let options = ApplePlaybackQuality.playbackOptions(
            serverQualities: [
                PlaybackV3AvailableQuality(
                    label: "audio_high",
                    height: nil,
                    bitrateKbps: 320,
                    preservesSource: false
                )
            ],
            fallbackVersion: nil
        )
        XCTAssertEqual(options.map(\.id), ["auto", "audio_high"])
        XCTAssertEqual(options.last?.resolution, "")
        XCTAssertEqual(options.last?.bitrateKbps, 320)
    }

    func testEmptyServerQualityCatalogOnlyOffersAuto() {
        let options = ApplePlaybackQuality.playbackOptions(
            serverQualities: [],
            fallbackVersion: makeVersion(
                container: "mp4",
                videoCodec: "h264",
                audioCodec: "aac"
            )
        )
        XCTAssertEqual(options.map(\.id), [ApplePlaybackQuality.autoId])
    }

    func testCompoundAndUnknownV3QualityIdsSurvivePlanMatching() {
        let qualities = [
            PlaybackV3AvailableQuality(
                label: "1080p",
                height: 1_080,
                bitrateKbps: 8_000,
                preservesSource: false
            ),
            PlaybackV3AvailableQuality(
                label: "audio_high",
                height: nil,
                bitrateKbps: 320,
                preservesSource: false
            )
        ]
        XCTAssertEqual(
            ApplePlaybackQuality.activeProtocolV3QualityId(
                requestedQualityId: "1080p-8",
                availableQualities: qualities
            ),
            "1080p-8"
        )
        XCTAssertEqual(
            ApplePlaybackQuality.activeProtocolV3QualityId(
                requestedQualityId: "audio_high",
                availableQualities: qualities
            ),
            "audio_high"
        )
    }

    func testPlanRuntimeDistinguishesUnknownFromFeatureAbsence() throws {
        let catalog = makeVersion(container: "mp4", videoCodec: "h264", audioCodec: "aac")
        let authoritative = ApplePlaybackV3PlanAdapter.playbackSession(
            plan: makePlan(sourceDurationSeconds: 5_400),
            sessionId: "session-v3",
            selectedVersion: catalog,
            serverFeatures: [PlaybackProtocolV3.planSourceDurationFeature]
        )
        XCTAssertEqual(authoritative.durationSeconds, 5_400)

        let explicitlyUnknown = ApplePlaybackV3PlanAdapter.playbackSession(
            plan: makePlan(sourceDurationSeconds: nil),
            sessionId: "session-v3",
            selectedVersion: catalog,
            serverFeatures: [PlaybackProtocolV3.planSourceDurationFeature]
        )
        XCTAssertNil(explicitlyUnknown.durationSeconds)

        let fallback = ApplePlaybackV3PlanAdapter.playbackSession(
            plan: makePlan(sourceDurationSeconds: nil),
            sessionId: "session-v3",
            selectedVersion: catalog,
            serverFeatures: []
        )
        XCTAssertEqual(fallback.durationSeconds, 120)

        let json = """
        {
          "media_file_id": 42,
          "container": "mp4",
          "hdr10_plus": false,
          "dv_enhancement_layer": "none"
        }
        """
        let source = try PlaybackV3FixtureTestSupport.decoder.decode(
            PlaybackV3SourceDescriptor.self,
            from: Data(json.utf8)
        )
        XCTAssertNil(source.durationSeconds)
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func fixtureObject(named name: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: PlaybackV3FixtureTestSupport.fixtureURL(
                named: name,
                bundleClass: Self.self
            )))
                as? [String: Any]
        )
    }

    private func fixtureArray(named name: String) throws -> [[String: Any]] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: PlaybackV3FixtureTestSupport.fixtureURL(
                named: name,
                bundleClass: Self.self
            )))
                as? [[String: Any]]
        )
    }

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any]
        )
    }

    private func makeReplanRequest(
        planAttemptKey: String,
        operation: String,
        failure: PlaybackV3Failure?
    ) -> PlaybackV3ReplanRequest {
        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        return PlaybackV3ReplanRequest(
            protocolVersion: 3,
            clientFeatures: ApplePlaybackV3Capabilities.features,
            operation: operation,
            playbackAttemptId: "apple:attempt",
            replanRequestId: "apple-replan:request",
            failedPlanId: "plan:fixture",
            planAttemptId: "apple-plan:attempt",
            planAttemptKey: planAttemptKey,
            attemptedPlanKeys: operation == PlaybackProtocolV3.ReplanOperation.failureRecovery
                ? [planAttemptKey]
                : [],
            attemptCount: 1,
            qualityPreference: "auto",
            positionSeconds: 42.5,
            metered: false,
            bandwidthEstimateKbps: nil,
            bandwidthCapKbps: nil,
            selectedTracks: PlaybackV3SelectedTracks(
                audio: PlaybackV3TrackIdentity(id: "file:42:audio:0", index: 0),
                subtitle: nil
            ),
            failure: failure,
            localMutations: [],
            clientCapabilities: snapshot.capabilities,
            clientPlaybackContext: snapshot.context
        )
    }

    private func makePlan(
        planId: String = "plan:fixture",
        planAttemptKey: String = "v3:opaque-fixture",
        delivery: String = "original_http",
        streamProtocol: String = "http_progressive",
        container: String = "mp4",
        videoCodec: String = "h264",
        audioCodec: String = "aac",
        width: Int = 1_920,
        height: Int = 1_080,
        bitrateKbps: Int = 8_000,
        dynamicRange: String = "sdr",
        selectedAudioIndex: Int = 0,
        selectedSubtitleIndex: Int? = nil,
        subtitleMode: String = "off",
        subtitleInventory: [PlaybackV3SubtitleInventoryItem] = [],
        transformations: [PlaybackV3Transformation] = [],
        appliedQuirks: [PlaybackV3AppliedQuirk] = [],
        runtimeCorrections: [String] = [],
        playerStart: Double = 4.5,
        timelineOffset: Double = 0,
        sourceDurationSeconds: Double? = 5_400
    ) -> PlaybackV3Plan {
        PlaybackV3Plan(
            protocolVersion: 3,
            planId: planId,
            sessionId: "session-v3",
            expiresAt: "2030-01-01T00:00:00Z",
            delivery: delivery,
            planAttemptKey: planAttemptKey,
            stream: PlaybackV3Stream(
                url: "/stream/session-v3",
                protocol: streamProtocol,
                container: container,
                mimeType: streamProtocol == "hls"
                    ? "application/vnd.apple.mpegurl"
                    : "video/mp4",
                headers: [:],
                headerRefresh: "session",
                headerRefreshUrl: nil
            ),
            timeline: PlaybackV3Timeline(
                sourceStartSeconds: playerStart,
                streamOriginSeconds: 0,
                playerStartSeconds: playerStart,
                timelineOffsetSeconds: timelineOffset,
                seekWindowStartSeconds: nil,
                seekWindowEndSeconds: nil,
                canSeekAnywhere: true,
                seekRestoration: "player_position"
            ),
            selectedTracks: PlaybackV3SelectedTracks(
                audio: PlaybackV3TrackIdentity(
                    id: "file:42:audio:\(selectedAudioIndex)",
                    index: selectedAudioIndex
                ),
                subtitle: selectedSubtitleIndex.map {
                    PlaybackV3TrackIdentity(id: "file:42:subtitle:\($0)", index: $0)
                }
            ),
            effectiveRecipe: PlaybackV3EffectiveRecipe(
                videoCodec: videoCodec,
                audioCodec: audioCodec,
                width: width,
                height: height,
                frameRate: 23.976,
                bitrateKbps: bitrateKbps,
                dynamicRange: dynamicRange,
                audioChannels: 2,
                audioLayout: "stereo"
            ),
            claims: PlaybackV3ValidationClaims(
                video: PlaybackV3VideoClaims(
                    hdr10: dynamicRange == "hdr10",
                    hdr10Plus: false,
                    hlg: false,
                    dolbyVision: dynamicRange == "dolby_vision",
                    dolbyVisionReason: nil
                ),
                audio: PlaybackV3AudioClaims(
                    codec: audioCodec,
                    passthrough: false,
                    atmosPreserved: false,
                    dtsVariant: nil,
                    reason: "client_decode_supported"
                ),
                subtitles: PlaybackV3SubtitleClaims(
                    assStylingPreserved: false,
                    bitmapOverlay: false,
                    bitmapSidecar: false,
                    reason: nil
                )
            ),
            subtitle: PlaybackV3SubtitleDecision(
                mode: subtitleMode,
                trackId: selectedSubtitleIndex.map { "file:42:subtitle:\($0)" },
                artifact: nil,
                inventory: subtitleInventory
            ),
            transformations: transformations,
            appliedQuirks: appliedQuirks,
            runtimeCorrections: runtimeCorrections,
            degradationWarnings: [],
            decisionReason: "validated_original_playback",
            requestedMediaFileId: 42,
            effectiveMediaFileId: 42,
            source: PlaybackV3SourceDescriptor(
                mediaFileId: 42,
                durationSeconds: sourceDurationSeconds,
                container: container,
                videoCodec: videoCodec,
                videoProfile: "high",
                videoLevel: 41,
                bitDepth: dynamicRange == "sdr" ? 8 : 10,
                colorRange: "tv",
                width: width,
                height: height,
                frameRate: 23.976,
                bitrateKbps: bitrateKbps,
                dynamicRange: dynamicRange,
                hdr10Plus: false,
                dolbyVisionProfile: dynamicRange == "dolby_vision" ? 7 : nil,
                dvBlCompatId: nil,
                dvEnhancementLayer: "none",
                audioCodec: audioCodec,
                audioChannels: 2,
                audioLayout: "stereo",
                videoCopyUnsafe: false
            ),
            subtitleFidelityPolicy: "allow_simplified_rendering",
            availableQualities: [
                PlaybackV3AvailableQuality(
                    label: "original",
                    height: height,
                    bitrateKbps: bitrateKbps,
                    preservesSource: true
                )
            ]
        )
    }

    private func makeVersion(
        container: String,
        videoCodec: String,
        audioCodec: String,
        audioTracks: [AudioTrack]? = nil,
        subtitleTracks: [SubtitleTrack]? = nil
    ) -> FileVersion {
        FileVersion(
            fileId: 42,
            fileName: "fixture.\(container)",
            resolution: "1920x1080",
            codecVideo: videoCodec,
            codecAudio: audioCodec,
            hdr: false,
            container: container,
            fileSize: 1_000,
            duration: 120,
            bitrate: 8_000_000,
            videoTracks: nil,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            chapters: nil
        )
    }

    private func makeAudio(
        index: Int,
        codec: String,
        isDefault: Bool
    ) -> AudioTrack {
        AudioTrack(
            index: index,
            codec: codec,
            channels: 6,
            channelLayout: "5.1",
            bitrate: 640_000,
            sampleRate: 48_000,
            language: "en",
            title: codec.uppercased(),
            embeddedTitle: nil,
            isDefault: isDefault
        )
    }

    private func makeSubtitleUrl(index: Int, source: String) -> SubtitleUrl {
        SubtitleUrl(
            index: index,
            language: "en",
            codec: "srt",
            label: "English",
            source: source,
            forced: false,
            url: "/stream/subtitles/\(index)"
        )
    }

    private func makeSubtitle(
        index: Int?,
        codec: String,
        external: Bool,
        path: String?,
        forced: Bool = false,
        isDefault: Bool = false,
        hearingImpaired: Bool = false
    ) -> SubtitleTrack {
        SubtitleTrack(
            index: index,
            codec: codec,
            language: "en",
            title: codec.uppercased(),
            embeddedTitle: nil,
            forced: forced,
            hearingImpaired: hearingImpaired,
            isDefault: isDefault,
            external: external,
            externalPath: path
        )
    }

    private func makeInventoryItem(
        combinedIndex: Int,
        source: String,
        delivery: String = "sidecar"
    ) -> PlaybackV3SubtitleInventoryItem {
        PlaybackV3SubtitleInventoryItem(
            trackId: "file:42:subtitle:\(combinedIndex)",
            combinedIndex: combinedIndex,
            source: source,
            codec: "srt",
            language: "en",
            label: "English",
            forced: false,
            default: false,
            hearingImpaired: false,
            delivery: delivery,
            url: delivery == "sidecar" ? "/stream/subtitles/\(combinedIndex)" : nil,
            fontBundleUrl: nil
        )
    }

    private func makePlayerSubtitle(
        trackId: Int64,
        isExternal: Bool,
        ffIndex: Int?,
        srcId: Int?
    ) -> PlayerTrack {
        PlayerTrack(
            trackId: trackId,
            kind: .sub,
            title: "English",
            lang: "en",
            codec: "srt",
            audioChannelCount: nil,
            bitrate: nil,
            isDefault: false,
            isForced: false,
            isHearingImpaired: false,
            isExternal: isExternal,
            isSelected: true,
            ffIndex: ffIndex,
            srcId: srcId
        )
    }
}
