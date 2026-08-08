import Foundation
import XCTest
@testable import Silo

final class PlaybackProtocolV3Tests: XCTestCase {
    func testServerGoldenDecisionDecodesAndPublishesCompleteSubtitleInventory() throws {
        let response = try decodeFixture(
            PlaybackV3DecisionResponse.self,
            named: "decision_response"
        )

        guard case .playable(let plan, let sessionId) = response.validatedForApple() else {
            return XCTFail("Expected the recovered server fixture to be playable")
        }
        XCTAssertEqual(sessionId, "11111111-1111-4111-8111-111111111111")
        XCTAssertEqual(plan.planAttemptKey, "v3:f0144c47fa349e3e")
        XCTAssertEqual(plan.source.durationSeconds, 7_265.5)
        XCTAssertEqual(plan.availableQualities.map(\.label), ["original", "720p", "480p"])
        XCTAssertEqual(plan.subtitle.inventory.map(\.combinedIndex), [0, 1, 2, 3, 4])
        XCTAssertEqual(plan.subtitle.inventory[3].delivery, "burn_in_only")
        XCTAssertNil(plan.subtitle.inventory[3].url)
        let qualityOptions = ApplePlaybackQuality.playbackOptions(
            serverQualities: plan.availableQualities,
            fallbackVersion: nil
        )
        XCTAssertEqual(qualityOptions.map(\.id), ["auto", "original", "720p", "480p"])
        XCTAssertEqual(qualityOptions.map(\.bitrateKbps), [0, 8_000, 2_000, 1_500])

        let session = ApplePlaybackV3PlanAdapter.playbackSession(
            plan: plan,
            sessionId: sessionId,
            selectedVersion: makeVersion(
                container: "mp4",
                videoCodec: "h264",
                audioCodec: "aac"
            )
        )
        XCTAssertEqual(session.position, 12.5)
        XCTAssertEqual(session.durationSeconds, 7_265.5)
        // Starting with subtitles off must not hide selectable sidecars.
        XCTAssertEqual(session.subtitleUrls?.count, 4)
    }

    func testRecoveredServerRequestAndCapabilityFixturesDecode() throws {
        let capability = try decodeFixture(
            PlaybackV3CapabilityResponse.self,
            named: "capability_response"
        )
        XCTAssertEqual(capability.protocolVersions, [3])
        XCTAssertEqual(
            Set(capability.deliveries),
            [
                "original_http",
                "server_remux_progressive",
                "server_remux_hls",
                "server_transcode_hls"
            ]
        )

        let start = try decodeFixture(PlaybackV3StartRequest.self, named: "start_request")
        XCTAssertEqual(start.clientCapabilities.videoEvidence, PlaybackProtocolV3.Evidence.exact)
        XCTAssertEqual(start.clientPlaybackContext.device.platform, "android")
        XCTAssertEqual(start.clientPlaybackContext.output.outputContextId, "7")
        XCTAssertEqual(Set(start.clientPlaybackContext.deliveries.keys), ["original_http"])

        let replan = try fixtureObject(named: "replan_request")
        XCTAssertEqual(replan["plan_attempt_key"] as? String, "v3:0000000000000001")
        XCTAssertNil(replan["engine"])
        XCTAssertNil(replan["output_route_generation"])

        let routeEvent = try fixtureObject(named: "route_event")
        XCTAssertEqual(routeEvent["output_context_id"] as? String, "7")
        XCTAssertEqual(routeEvent["plan_attempt_key"] as? String, "v3:0000000000000001")

        let subtitleFixture = try fixtureObject(named: "subtitle_inventory")
        let inventory = try XCTUnwrap(subtitleFixture["inventory"] as? [[String: Any]])
        XCTAssertEqual(inventory.compactMap { $0["combined_index"] as? Int }, [0, 1, 2, 3, 4])

        let attemptKeys = try fixtureArray(named: "attempt_keys")
        XCTAssertFalse(attemptKeys.isEmpty)
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

    func testSilentRenewalAcceptsOnlyTheSameEffectiveDirectRoute() {
        let current = makePlan(
            planAttemptKey: "v3:first",
            playerStart: 10
        )
        let renewed = makePlan(
            planId: "plan:renewed",
            planAttemptKey: "v3:second",
            playerStart: 42
        )
        XCTAssertTrue(
            PlaybackSessionBridge.canRetargetDirectSession(from: current, to: renewed),
            "fresh plan and attempt identities plus a later player start are safe behind the proxy"
        )
        XCTAssertFalse(
            PlaybackSessionBridge.canRetargetDirectSession(
                from: current,
                to: makePlan(
                    planAttemptKey: "v3:changed-recipe",
                    audioCodec: "eac3",
                    playerStart: 42
                )
            )
        )
        XCTAssertFalse(
            PlaybackSessionBridge.canRetargetDirectSession(
                from: current,
                to: makePlan(
                    planAttemptKey: "v3:changed-delivery",
                    delivery: "server_remux_hls",
                    streamProtocol: "hls",
                    container: "hls",
                    playerStart: 42
                )
            )
        )
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

    func testDeliveryClassesMapToAppleExecutorsWithoutEngineAliases() throws {
        let streamRequest = makeStreamRequest()
        let base = makeBaseExecutionPlan(streamRequest: streamRequest)
        let cases: [(String, String, PlaybackEngineKind, PlaybackDeliveryStrategy)] = [
            ("original_http", "http_progressive", .playerCoreDirect, .direct),
            ("server_remux_progressive", "http_progressive", .avPlayerNativeDirect, .remux),
            ("server_remux_hls", "hls", .avPlayerHLS, .remux),
            ("server_transcode_hls", "hls", .avPlayerHLS, .transcode)
        ]

        for (delivery, streamProtocol, expectedEngine, expectedDelivery) in cases {
            let plan = makePlan(
                delivery: delivery,
                streamProtocol: streamProtocol,
                container: streamProtocol == "hls" ? "hls" : "mp4"
            )
            let adapted = try ApplePlaybackV3PlanAdapter.makeExecutionPlan(
                v3: PreparedPlaybackV3(
                    playbackAttemptId: "apple:attempt",
                    planAttemptId: "apple-plan:attempt",
                    planAttemptKey: plan.planAttemptKey,
                    outputContextId: "apple:output",
                    serverFeatures: [
                        PlaybackProtocolV3.planFeature,
                        PlaybackProtocolV3.seekReanchorFeature,
                        PlaybackProtocolV3.directStreamResumeFeature
                    ],
                    plan: plan
                ),
                basePlan: base,
                streamRequest: streamRequest,
                routeRequirements: .baseline
            )
            XCTAssertEqual(adapted.engine, expectedEngine, delivery)
            XCTAssertEqual(adapted.delivery.name, expectedDelivery.name, delivery)
            XCTAssertEqual(adapted.wireDelivery, delivery)
            XCTAssertEqual(adapted.supportsDirectStreamResume, delivery == "original_http")
            XCTAssertEqual(adapted.startMode.seconds, 4.5)
            XCTAssertEqual(adapted.sourceMetadata.colorRange, "tv")
        }
    }

    func testDirectStreamResumeRequiresNegotiatedResponseFeature() throws {
        let streamRequest = makeStreamRequest()
        let plan = makePlan()
        let adapted = try ApplePlaybackV3PlanAdapter.makeExecutionPlan(
            v3: PreparedPlaybackV3(
                playbackAttemptId: "apple:attempt",
                planAttemptId: "apple-plan:attempt",
                planAttemptKey: plan.planAttemptKey,
                outputContextId: "apple:output",
                serverFeatures: [PlaybackProtocolV3.planFeature],
                plan: plan
            ),
            basePlan: makeBaseExecutionPlan(streamRequest: streamRequest),
            streamRequest: streamRequest,
            routeRequirements: .baseline
        )

        XCTAssertFalse(adapted.supportsDirectStreamResume)
    }

    func testUnsupportedPlanRequirementsAreRejected() {
        let unknownTransform = makePlan(transformations: [
            .init(
                name: "client_unknown_transform",
                executor: "client",
                recipeVersion: "1",
                validatedClaims: []
            )
        ])
        XCTAssertThrowsError(try ApplePlaybackV3PlanAdapter.validate(unknownTransform)) { error in
            XCTAssertEqual(
                error as? ApplePlaybackV3PlanError,
                .unsupportedClientTransformation("client_unknown_transform")
            )
        }

        XCTAssertThrowsError(
            try ApplePlaybackV3PlanAdapter.validate(
                makePlan(runtimeCorrections: ["client_unknown_correction"])
            )
        )
        XCTAssertThrowsError(
            try ApplePlaybackV3PlanAdapter.validate(
                makePlan(streamProtocol: "dash")
            )
        )
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
        )
    }

    func testClientDolbyVisionTransformExecutesExactServerSelection() throws {
        let streamRequest = makeStreamRequest(path: "dv7.mkv")
        let base = makeBaseExecutionPlan(
            streamRequest: streamRequest,
            engine: .siloPlayerLoopback,
            loopbackSession: makeLoopbackSession(
                streamRequest: streamRequest,
                videoMode: .passthroughHEVC
            )
        )

        let dv81 = try adaptedPlan(
            makePlan(
                container: "mkv",
                videoCodec: "hevc",
                dynamicRange: "dolby_vision",
                transformations: [
                    .init(
                        name: "client_dv7_to_dv81",
                        executor: "client",
                        recipeVersion: "1",
                        validatedClaims: []
                    )
                ]
            ),
            base: base,
            streamRequest: streamRequest
        )
        XCTAssertEqual(dv81.engine, .siloPlayerLoopback)
        XCTAssertEqual(dv81.loopbackSession?.videoMode, .convertProfile7To81)
        XCTAssertEqual(dv81.loopbackSession?.manifestMetadata.advertisedDolbyVisionProfile, 8)
        XCTAssertEqual(dv81.loopbackSession?.manifestMetadata.compatibilityBrand, "db1p")

        let hdr10 = try adaptedPlan(
            makePlan(
                container: "mkv",
                videoCodec: "hevc",
                dynamicRange: "hdr10",
                transformations: [
                    .init(
                        name: "client_dv7_to_hdr10",
                        executor: "client",
                        recipeVersion: "1",
                        validatedClaims: []
                    )
                ]
            ),
            base: base,
            streamRequest: streamRequest
        )
        XCTAssertEqual(hdr10.engine, .siloPlayerLoopback)
        XCTAssertEqual(hdr10.loopbackSession?.videoMode, .passthroughHEVC)
        XCTAssertNil(hdr10.loopbackSession?.manifestMetadata.advertisedDolbyVisionProfile)
        XCTAssertNil(hdr10.loopbackSession?.manifestMetadata.compatibilityBrand)
        XCTAssertEqual(hdr10.loopbackSession?.manifestMetadata.videoRange, "PQ")
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
        XCTAssertEqual(renewal.preferredSubtitleTrackIndex, 5)
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
            PlaybackProtocolV3.Evidence.platformAttested
        )
        XCTAssertEqual(snapshot.capabilities.codecsVideo, ["h264"])
        XCTAssertEqual(snapshot.capabilities.codecsVideoHardware, ["h264"])
        XCTAssertEqual(snapshot.capabilities.videoDecode.first?.profiles, [])
        XCTAssertEqual(snapshot.capabilities.videoDecode.first?.levels, [])
        XCTAssertNil(snapshot.capabilities.audioPassthrough)
        XCTAssertNil(snapshot.context.output.audioPassthrough)
        XCTAssertTrue(snapshot.outputContextId?.hasPrefix("apple:") == true)
        XCTAssertFalse(snapshot.capabilities.hdr)

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
        XCTAssertTrue(original.subtitles.fontAttachments)
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
        let output = try XCTUnwrap(context["output"] as? [String: Any])
        XCTAssertEqual(output["output_context_id"] as? String, snapshot.outputContextId)
    }

    func testPlanRuntimeFallbackIsUsedOnlyWhenSourceRuntimeIsAbsent() throws {
        let catalog = makeVersion(container: "mp4", videoCodec: "h264", audioCodec: "aac")
        let authoritative = ApplePlaybackV3PlanAdapter.playbackSession(
            plan: makePlan(sourceDurationSeconds: 5_400),
            sessionId: "session-v3",
            selectedVersion: catalog
        )
        XCTAssertEqual(authoritative.durationSeconds, 5_400)

        let fallback = ApplePlaybackV3PlanAdapter.playbackSession(
            plan: makePlan(sourceDurationSeconds: nil),
            sessionId: "session-v3",
            selectedVersion: catalog
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
        let source = try decoder.decode(
            PlaybackV3SourceDescriptor.self,
            from: Data(json.utf8)
        )
        XCTAssertNil(source.durationSeconds)
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private func fixtureURL(named name: String) throws -> URL {
        try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: name, withExtension: "json"),
            "Missing vendored Playback V3 fixture \(name).json"
        )
    }

    private func decodeFixture<T: Decodable>(_ type: T.Type, named name: String) throws -> T {
        try decoder.decode(type, from: Data(contentsOf: fixtureURL(named: name)))
    }

    private func fixtureObject(named name: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL(named: name)))
                as? [String: Any]
        )
    }

    private func fixtureArray(named name: String) throws -> [[String: Any]] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL(named: name)))
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

    private func adaptedPlan(
        _ plan: PlaybackV3Plan,
        base: PlaybackExecutionPlan,
        streamRequest: StreamRequest
    ) throws -> PlaybackExecutionPlan {
        try ApplePlaybackV3PlanAdapter.makeExecutionPlan(
            v3: PreparedPlaybackV3(
                playbackAttemptId: "apple:attempt",
                planAttemptId: "apple-plan:attempt",
                planAttemptKey: plan.planAttemptKey,
                outputContextId: "apple:output",
                serverFeatures: [
                    PlaybackProtocolV3.planFeature,
                    PlaybackProtocolV3.seekReanchorFeature
                ],
                plan: plan
            ),
            basePlan: base,
            streamRequest: streamRequest,
            routeRequirements: .baseline
        )
    }

    private func makeStreamRequest(path: String = "video") -> StreamRequest {
        StreamRequest(
            url: URL(string: "https://example.test/\(path)")!,
            headers: ["Authorization": "Bearer test"],
            serverUrl: "https://example.test"
        )
    }

    private func makeBaseExecutionPlan(
        streamRequest: StreamRequest,
        engine: PlaybackEngineKind = .playerCoreDirect,
        loopbackSession: LoopbackSessionSpec? = nil
    ) -> PlaybackExecutionPlan {
        let routeCapabilities = engine.routeCapabilities
        return PlaybackExecutionPlan(
            delivery: .direct,
            engine: engine,
            startMode: .absolutePosition(4.5),
            streamRequest: streamRequest,
            loopbackSession: loopbackSession,
            capabilities: routeCapabilities.backendCapabilities,
            routeCapabilities: routeCapabilities,
            requirements: .baseline,
            featureFlagEnabled: true,
            parityBlockers: [],
            decisionTrace: ["test"],
            degradationWarnings: [],
            reason: "test",
            playbackSessionId: "session-v3"
        )
    }

    private func makeLoopbackSession(
        streamRequest: StreamRequest,
        videoMode: LoopbackSessionSpec.VideoMode
    ) -> LoopbackSessionSpec {
        LoopbackSessionSpec(
            sourceURL: streamRequest.url,
            headers: streamRequest.headers,
            sourceBitrateBps: 20_000_000,
            videoMode: videoMode,
            sourceVideoFrameRate: 23.976,
            selectedAudio: LoopbackSessionSpec.SelectedAudio(
                trackIndex: 0,
                ffIndex: 1,
                sourceCodec: "eac3",
                sourceChannelCount: 6,
                sourceChannelLayout: "5.1",
                outputMode: .copy,
                preservesAtmos: true
            ),
            availableAudioTracks: [],
            manifestMetadata: LoopbackSessionSpec.ManifestMetadata(
                advertisedDolbyVisionProfile: nil,
                compatibilityBrand: nil,
                videoRange: "PQ",
                mayClaimAtmos: true
            )
        )
    }

    private func makeVersion(
        container: String,
        videoCodec: String,
        audioCodec: String,
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
            audioTracks: nil,
            subtitleTracks: subtitleTracks,
            chapters: nil
        )
    }

    private func makeSubtitle(
        index: Int?,
        codec: String,
        external: Bool,
        path: String?,
        forced: Bool = false,
        isDefault: Bool = false
    ) -> SubtitleTrack {
        SubtitleTrack(
            index: index,
            codec: codec,
            language: "en",
            title: codec.uppercased(),
            embeddedTitle: nil,
            forced: forced,
            hearingImpaired: false,
            isDefault: isDefault,
            external: external,
            externalPath: path
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
            audioChannelsLayout: nil,
            audioChannelCount: nil,
            bitrate: nil,
            isDefault: false,
            isForced: false,
            isHearingImpaired: false,
            isVisualImpaired: false,
            isExternal: isExternal,
            isSelected: true,
            ffIndex: ffIndex,
            srcId: srcId
        )
    }
}
