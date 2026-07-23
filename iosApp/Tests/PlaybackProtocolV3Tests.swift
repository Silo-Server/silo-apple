import Foundation
import XCTest
@testable import Silo

final class PlaybackProtocolV3Tests: XCTestCase {
    func testDecisionValidationAndSessionTimeline() throws {
        let plan = makePlan(playerStart: 12.5, timelineOffset: 7.25)
        let response = PlaybackV3DecisionResponse(
            protocolVersion: 3,
            serverFeatures: ["playback_plan_v3", "seek_reanchor_v1"],
            outcome: "playable",
            sessionId: "session-v3",
            playbackPlan: plan,
            terminal: nil
        )

        guard case .playable(let validated, let sessionId) = response.validatedForApple() else {
            return XCTFail("Expected a playable V3 response")
        }
        XCTAssertEqual(sessionId, "session-v3")
        XCTAssertEqual(validated.planId, "plan:fixture")

        let session = ApplePlaybackV3PlanAdapter.playbackSession(
            plan: validated,
            sessionId: sessionId,
            selectedVersion: makeVersion(container: "mp4", videoCodec: "h264", audioCodec: "aac")
        )
        XCTAssertEqual(session.position, 12.5)
        XCTAssertEqual(session.timelineOffsetSeconds, 7.25)
        XCTAssertEqual(session.playMethod, "direct")
    }

    func testCanonicalAttemptKeyMatchesGoAndAndroidFixtures() {
        let hls = makePlan(
            planId: "plan:fixture",
            delivery: "server_remux_hls",
            engine: "media3_hls",
            streamProtocol: "hls",
            container: "hls",
            videoCodec: "hevc",
            audioCodec: "aac",
            width: 3_840,
            height: 2_160,
            bitrateKbps: 20_000,
            dynamicRange: "hdr10",
            subtitleMode: "burn_in",
            transformations: [
                .init(name: "hdr_to_sdr_tonemap", executor: "server", recipeVersion: "1", validatedClaims: []),
                .init(name: "audio_to_aac", executor: "server", recipeVersion: "1", validatedClaims: [])
            ]
        )
        XCTAssertEqual(
            hls.attemptKey(
                outputRouteGeneration: 7,
                localMutations: ["transport_reopen", "pcm:truehd:8"]
            ),
            "v3:6d4724f01b6ff692"
        )

        let dv81 = makePlan(
            planId: "plan:dv81-fixture",
            container: "mkv",
            videoCodec: "hevc",
            audioCodec: "truehd",
            width: 3_840,
            height: 2_160,
            bitrateKbps: 65_000,
            dynamicRange: "dolby_vision",
            transformations: [
                .init(name: "client_dv7_to_dv81", executor: "client", recipeVersion: "1", validatedClaims: [])
            ]
        )
        XCTAssertEqual(dv81.attemptKey(outputRouteGeneration: 9), "v3:2a88b5e686373440")

        let quirk = makePlan(
            planId: "plan:quirk",
            container: "mkv",
            videoCodec: "hevc",
            audioCodec: "eac3",
            width: 3_840,
            height: 2_160,
            bitrateKbps: 60_000,
            dynamicRange: "dolby_vision",
            appliedQuirks: [
                .init(
                    id: "android.fire_tv.dv8_hdr10plus_sei_v1",
                    registryRevision: "2026-07-13.1",
                    action: "client_runtime_correction",
                    reason: nil
                )
            ],
            runtimeCorrections: ["client_dv8_hdr10plus_sanitizer_v1"]
        )
        XCTAssertEqual(quirk.attemptKey(outputRouteGeneration: 9), "v3:8d843bfffeb3adc3")
    }

    func testDeliveryMatrixMapsToAppleEngines() throws {
        let streamRequest = StreamRequest(
            url: URL(string: "https://example.test/video")!,
            headers: ["Authorization": "Bearer test"],
            serverUrl: "https://example.test"
        )
        let base = makeBaseExecutionPlan(streamRequest: streamRequest)
        let cases: [(String, String, String, PlaybackEngineKind, PlaybackDeliveryStrategy)] = [
            ("original_http", "media3_direct", "http_progressive", .playerCoreDirect, .direct),
            ("server_remux_progressive", "media3_progressive_remux", "http_progressive", .avPlayerNativeDirect, .remux),
            ("server_remux_hls", "media3_hls", "hls", .avPlayerHLS, .remux),
            ("server_transcode_hls", "media3_hls", "hls", .avPlayerHLS, .transcode)
        ]

        for (delivery, engine, streamProtocol, expectedEngine, expectedDelivery) in cases {
            let plan = makePlan(
                delivery: delivery,
                engine: engine,
                streamProtocol: streamProtocol,
                container: streamProtocol == "hls" ? "hls" : "mp4"
            )
            let adapted = try ApplePlaybackV3PlanAdapter.makeExecutionPlan(
                v3: PreparedPlaybackV3(
                    playbackAttemptId: "apple:attempt",
                    planAttemptId: "apple-plan:attempt",
                    planAttemptKey: plan.attemptKey(outputRouteGeneration: 1),
                    outputRouteGeneration: 1,
                    serverFeatures: [
                        "playback_plan_v3",
                        "seek_reanchor_v1",
                        "direct_stream_resume_v1"
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
            XCTAssertTrue(
                adapted.serverFeatures.contains(PlaybackProtocolV3.directStreamResumeFeature)
            )
            XCTAssertEqual(adapted.startMode.seconds, 4.5, delivery)
        }
        XCTAssertTrue(
            ApplePlaybackV3Capabilities.features.contains(
                PlaybackProtocolV3.directStreamResumeFeature
            )
        )
    }

    func testUnsupportedClientRequirementsAreRejected() {
        let unknownTransform = makePlan(transformations: [
            .init(name: "client_unknown_transform", executor: "client", recipeVersion: "1", validatedClaims: [])
        ])
        XCTAssertThrowsError(try ApplePlaybackV3PlanAdapter.validate(unknownTransform)) { error in
            XCTAssertEqual(
                error as? ApplePlaybackV3PlanError,
                .unsupportedClientTransformation("client_unknown_transform")
            )
        }

        let unknownCorrection = makePlan(runtimeCorrections: ["client_unknown_correction"])
        XCTAssertThrowsError(try ApplePlaybackV3PlanAdapter.validate(unknownCorrection))

        let mismatchedEngine = makePlan(engine: "media3_hls")
        XCTAssertThrowsError(try ApplePlaybackV3PlanAdapter.validate(mismatchedEngine))

        let conflicting = makePlan(transformations: [
            .init(name: "client_dv7_to_dv81", executor: "client", recipeVersion: "1", validatedClaims: []),
            .init(name: "client_dv7_to_hdr10", executor: "client", recipeVersion: "1", validatedClaims: [])
        ])
        XCTAssertThrowsError(try ApplePlaybackV3PlanAdapter.validate(conflicting))
    }

    func testClientDolbyVisionTransformExecutesExactServerSelection() throws {
        let streamRequest = StreamRequest(
            url: URL(string: "https://example.test/dv7.mkv")!,
            headers: ["Authorization": "Bearer test"],
            serverUrl: "https://example.test"
        )
        let baseLoopback = makeLoopbackSession(
            streamRequest: streamRequest,
            videoMode: .passthroughHEVC
        )
        let base = makeBaseExecutionPlan(
            streamRequest: streamRequest,
            engine: .siloPlayerLoopback,
            loopbackSession: baseLoopback
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

    func testSubtitleIdentityTranslatesAppleStreamIndexToServerCombinedOrdinal() {
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

        let externalPlayerTrack = makePlayerSubtitle(
            trackId: SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: 0),
            isExternal: true,
            ffIndex: nil,
            srcId: 0
        )
        XCTAssertEqual(
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                for: externalPlayerTrack,
                in: version
            ),
            0
        )

        let embeddedPlayerTrack = makePlayerSubtitle(
            trackId: 12,
            isExternal: false,
            ffIndex: 5,
            srcId: 1
        )
        XCTAssertEqual(
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                for: embeddedPlayerTrack,
                in: version
            ),
            2
        )
    }

    func testSimulatorCapabilitySnapshotIsConservativeAndComplete() {
        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        XCTAssertEqual(snapshot.context.protocolVersion, 3)
        XCTAssertEqual(snapshot.context.platform, "ios")
        XCTAssertTrue(snapshot.context.features.contains("playback_plan_v3"))
        XCTAssertEqual(Set(snapshot.context.engines.keys), [
            "media3_direct", "media3_progressive_remux", "media3_hls"
        ])
        XCTAssertEqual(snapshot.capabilities.codecsVideo, ["h264"])
        XCTAssertFalse(snapshot.capabilities.hdr)
        XCTAssertGreaterThanOrEqual(snapshot.outputRouteGeneration, 0)
    }

    func testStartRequestUsesSnakeCaseContract() throws {
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
            outputRouteGeneration: snapshot.outputRouteGeneration,
            metered: false,
            bandwidthEstimateKbps: nil,
            bandwidthCapKbps: nil,
            clientCapabilities: snapshot.capabilities,
            clientPlaybackContext: snapshot.context
        )
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(request)) as? [String: Any]
        )
        XCTAssertEqual(object["protocol_version"] as? Int, 3)
        XCTAssertEqual(object["playback_attempt_id"] as? String, "apple:12345678")
        XCTAssertNotNil(object["client_capabilities"])
        XCTAssertNotNil(object["client_playback_context"])
    }

    private func makePlan(
        planId: String = "plan:fixture",
        delivery: String = "original_http",
        engine: String = "media3_direct",
        streamProtocol: String = "http_progressive",
        container: String = "mp4",
        videoCodec: String = "h264",
        audioCodec: String = "aac",
        width: Int = 1_920,
        height: Int = 1_080,
        bitrateKbps: Int = 8_000,
        dynamicRange: String = "sdr",
        subtitleMode: String = "off",
        transformations: [PlaybackV3Transformation] = [],
        appliedQuirks: [PlaybackV3AppliedQuirk] = [],
        runtimeCorrections: [String] = [],
        playerStart: Double = 4.5,
        timelineOffset: Double = 0
    ) -> PlaybackV3Plan {
        PlaybackV3Plan(
            protocolVersion: 3,
            planId: planId,
            sessionId: "session-v3",
            expiresAt: "2030-01-01T00:00:00Z",
            delivery: delivery,
            engine: engine,
            stream: PlaybackV3Stream(
                url: "/stream/session-v3",
                protocol: streamProtocol,
                container: container,
                mimeType: streamProtocol == "hls" ? "application/vnd.apple.mpegurl" : "video/mp4",
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
                audio: PlaybackV3TrackIdentity(id: "file:42:audio:0", index: 0),
                subtitle: nil
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
            subtitle: PlaybackV3SubtitleDecision(mode: subtitleMode, trackId: nil, artifact: nil),
            transformations: transformations,
            appliedQuirks: appliedQuirks,
            runtimeCorrections: runtimeCorrections,
            degradationWarnings: [],
            decisionReason: "validated_original_playback",
            requestedMediaFileId: 42,
            effectiveMediaFileId: 42,
            source: PlaybackV3SourceDescriptor(
                mediaFileId: 42,
                container: container,
                videoCodec: videoCodec,
                videoProfile: "high",
                videoLevel: 41,
                bitDepth: dynamicRange == "sdr" ? 8 : 10,
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
                audioLayout: "stereo"
            ),
            subtitleFidelityPolicy: "allow_simplified_rendering"
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
                planAttemptKey: plan.attemptKey(outputRouteGeneration: 1),
                outputRouteGeneration: 1,
                serverFeatures: ["playback_plan_v3", "seek_reanchor_v1"],
                plan: plan
            ),
            basePlan: base,
            streamRequest: streamRequest,
            routeRequirements: .baseline
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
        path: String?
    ) -> SubtitleTrack {
        SubtitleTrack(
            index: index,
            codec: codec,
            language: "en",
            title: codec.uppercased(),
            embeddedTitle: nil,
            forced: false,
            hearingImpaired: false,
            isDefault: false,
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
