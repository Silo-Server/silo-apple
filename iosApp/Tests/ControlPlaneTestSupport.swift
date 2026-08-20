import Foundation
@testable import Silo

/// The fixtures `PlaybackReducerTests` and `PlaybackSessionActorTests` share.
///
/// Both files drive the same control plane — one through `PlaybackReducer`
/// directly, one through `PlaybackSessionActor` — so they need the same load
/// request, session identity, execution plan and prepared session. They used to
/// carry a copy each, including two hand-written `protocol_version: 3` plan
/// blobs that had already drifted apart, which meant a wire-shape change had to
/// be found and fixed twice.
///
/// The V3 plan is still hand-written rather than decoded from
/// `Tests/Fixtures/PlaybackV3/decision_response.json`: the vendored fixture is a
/// whole decision response pinned to opaque server values, while these tests
/// need to *choose* the effective file id, audio index and subtitle ordinal in
/// order to prove that an adopt rewrites the replay request with the plan's
/// values rather than the request's. It is decoded, not built, so it still
/// cannot drift from the wire shape.
enum ControlPlaneFixtures {

    static func makeRequest(
        contentId: String = "content-1",
        offlineDownloadId: String? = nil
    ) -> LoadRequest {
        LoadRequest(
            contentId: contentId,
            preferredFileId: 7,
            preferredAudioTrackIndex: 1,
            preferredSubtitleTrackIndex: nil,
            preferredSidecarSubtitleTrackId: nil,
            startFromBeginning: false,
            offlineDownloadId: offlineDownloadId
        )
    }

    static func makeIdentity(
        session: String? = "session-1",
        attempt: String = "apple:attempt-1",
        planAttempt: String? = "apple-plan:1",
        planAttemptKey: String? = "plan-key-1",
        outputContext: String = "output-1"
    ) -> SessionIdentity {
        SessionIdentity(
            serverSessionId: session,
            playbackAttemptId: attempt,
            planAttemptId: planAttempt,
            planAttemptKey: planAttemptKey,
            outputContextId: outputContext
        )
    }

    static func makeSessionSpec(
        sourceStartTimeSeconds: Double = 0
    ) -> LoopbackSessionSpec {
        LoopbackSessionSpec(
            sourceURL: URL(string: "https://example.invalid/movie.mkv")!,
            headers: [:],
            sourceStartTimeSeconds: sourceStartTimeSeconds,
            sourceBitrateBps: 20_000_000,
            videoMode: .passthroughHEVC,
            sourceVideoFrameRate: 23.976,
            selectedAudio: .absent,
            availableAudioTracks: [],
            manifestMetadata: LoopbackSessionSpec.ManifestMetadata(
                advertisedDolbyVisionProfile: nil,
                compatibilityBrand: nil,
                videoRange: "SDR",
                mayClaimAtmos: false
            )
        )
    }

    /// The plan the control plane carries: the whole `PlaybackExecutionPlan`,
    /// because that is what the engine install executes.
    static func makePlan(
        engine: PlaybackEngineKind = .avPlayerNativeDirect,
        startSeconds: Double = 0,
        delivery: PlaybackDeliveryStrategy = .direct
    ) -> PlaybackExecutionPlan {
        let isManifestAnchored = engine == .avPlayerHLS && startSeconds == 0
        let url = engine == .avPlayerHLS
            ? URL(string: "https://example.invalid/master.m3u8")!
            : URL(string: "https://example.invalid/movie.mkv")!
        return PlaybackExecutionPlan(
            delivery: delivery,
            engine: engine,
            startMode: isManifestAnchored ? .startOfManifest : .absolutePosition(startSeconds),
            streamRequest: StreamRequest(
                url: url,
                headers: ["Authorization": "Bearer x"],
                serverUrl: "https://example.invalid"
            ),
            loopbackSession: engine == .siloPlayerLoopback
                ? makeSessionSpec(sourceStartTimeSeconds: startSeconds)
                : nil,
            requirements: .baseline,
            parityBlockers: [],
            decisionTrace: [],
            degradationWarnings: [],
            reason: "test"
        )
    }

    static func makePlanRef(
        engine: PlaybackEngineKind = .avPlayerNativeDirect,
        startSeconds: Double = 0,
        delivery: PlaybackDeliveryStrategy = .direct
    ) -> ExecutionPlanRef {
        ExecutionPlanRef(makePlan(engine: engine, startSeconds: startSeconds, delivery: delivery))
    }

    static func makeWatchDetail(fileId: Int = 7) throws -> WatchDetail {
        let json = Data("""
        {
          "content_id": "content-1",
          "type": "movie",
          "title": "Test",
          "versions": [{"file_id": \(fileId), "duration": 900}]
        }
        """.utf8)
        return try HTTPClient.makeJSONDecoder().decode(WatchDetail.self, from: json)
    }

    /// A minimal but *real* `PreparedPlaybackV3`, decoded rather than
    /// hand-built so the fixture cannot drift from the wire shape. The
    /// selected subtitle is an external sidecar, which is the branch of
    /// `LoadRequest.adoptingProtocolV3Intent` that produces a sidecar track id
    /// and no embedded FFmpeg index — no `FileVersion` subtitle streams needed.
    static func makePreparedV3(
        sessionId: String = "session-v3",
        planAttemptKey: String = "v3:opaque-fixture",
        effectiveMediaFileId: Int = 9,
        audioIndex: Int = 5,
        subtitleCombinedIndex: Int? = 3
    ) throws -> PreparedPlaybackV3 {
        var selectedSubtitle = ""
        var inventory = ""
        if let index = subtitleCombinedIndex {
            selectedSubtitle = #", "subtitle": {"id": "file:9:subtitle:\#(index)", "index": \#(index)}"#
            inventory = #"""
            {"track_id": "file:9:subtitle:\#(index)", "combined_index": \#(index),
             "source": "external", "forced": false, "default": false,
             "hearing_impaired": false, "delivery": "sidecar",
             "url": "https://example.invalid/subs.vtt"}
            """#
        }
        let json = Data("""
        {
          "protocol_version": 3,
          "plan_id": "plan:fixture",
          "session_id": "\(sessionId)",
          "delivery": "original_http",
          "plan_attempt_key": "\(planAttemptKey)",
          "stream": {"url": "/stream/\(sessionId)", "protocol": "http_progressive",
                     "headers": {}, "header_refresh": "session"},
          "timeline": {"source_start_seconds": 0, "stream_origin_seconds": 0,
                       "player_start_seconds": 0, "timeline_offset_seconds": 0,
                       "can_seek_anywhere": true, "seek_restoration": "player_position"},
          "selected_tracks": {"audio": {"id": "file:\(effectiveMediaFileId):audio:\(audioIndex)", "index": \(audioIndex)}\(selectedSubtitle)},
          "effective_recipe": {},
          "claims": {
            "video": {"hdr10": false, "hdr10_plus": false, "hlg": false, "dolby_vision": false},
            "audio": {"passthrough": false, "atmos_preserved": false},
            "subtitles": {"ass_styling_preserved": false, "bitmap_overlay": false,
                          "bitmap_sidecar": false}
          },
          "subtitle": {"mode": "external", "inventory": [\(inventory)]},
          "transformations": [],
          "applied_quirks": [],
          "runtime_corrections": [],
          "degradation_warnings": [],
          "decision_reason": "validated_original_playback",
          "requested_media_file_id": \(effectiveMediaFileId),
          "effective_media_file_id": \(effectiveMediaFileId),
          "source": {"media_file_id": \(effectiveMediaFileId), "hdr10_plus": false,
                     "dv_enhancement_layer": "none"},
          "subtitle_fidelity_policy": "allow_simplified_rendering",
          "available_qualities": []
        }
        """.utf8)
        let plan = try HTTPClient.makeJSONDecoder().decode(PlaybackV3Plan.self, from: json)
        return PreparedPlaybackV3(
            playbackAttemptId: "apple:attempt-1",
            planAttemptId: "apple-plan:1",
            planAttemptKey: plan.planAttemptKey,
            outputContextId: "output-1",
            serverFeatures: [PlaybackProtocolV3.planFeature],
            plan: plan
        )
    }

    static func makePreparedRef(
        position: Double = 0,
        timelineOffsetSeconds: Double = 0,
        durationSeconds: Double? = 1000,
        activeQualityId: String = ApplePlaybackQuality.autoId,
        fileId: Int = 7,
        protocolV3: PreparedPlaybackV3? = nil
    ) throws -> PreparedPlaybackRef {
        let watchDetail = try makeWatchDetail(fileId: fileId)
        let session = PlaybackSessionResponse(
            sessionId: "session-1",
            userId: nil,
            profileId: nil,
            mediaFileId: fileId,
            playMethod: "direct",
            position: position,
            isPaused: false,
            streamUrl: "https://example.invalid/movie.mkv",
            audioTrackIndex: nil,
            durationSeconds: durationSeconds,
            timelineOffsetSeconds: timelineOffsetSeconds,
            subtitleUrls: nil,
            playbackInfo: nil
        )
        return PreparedPlaybackRef(
            PreparedPlayback(
                watchDetail: watchDetail,
                selectedVersion: watchDetail.versions[0],
                session: session,
                activeQualityId: activeQualityId,
                protocolV3: protocolV3
            )
        )
    }

    /// A prepared session carrying a live V3 plan whose identity matches
    /// `makeIdentity()`, which is what makes `Playing.hasProtocolV3` true — the
    /// precondition of both intents that mint a server replan.
    static func makeProtocolV3PreparedRef(
        position: Double = 0,
        durationSeconds: Double? = 1000
    ) throws -> PreparedPlaybackRef {
        try makePreparedRef(
            position: position,
            durationSeconds: durationSeconds,
            protocolV3: makePreparedV3(
                sessionId: "session-1",
                planAttemptKey: "plan-key-1",
                effectiveMediaFileId: 7,
                audioIndex: 1,
                subtitleCombinedIndex: nil
            )
        )
    }
}
