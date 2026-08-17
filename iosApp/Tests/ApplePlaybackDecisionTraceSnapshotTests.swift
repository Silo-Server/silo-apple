import Foundation
import XCTest
@testable import Silo

/// Stage-0 characterization: a full-array snapshot of `decisionTrace` for the
/// canonical source shapes.
///
/// `ApplePlaybackRoutePlannerPinTests` pins the complete trace for exactly one
/// input (mp4/h264/aac) and spot-checks membership everywhere else, so token
/// *ordering* and token *count* are unpinned for every other route. The trace
/// is the only artifact that records why a route was chosen — it is what the
/// `[CMP-ROUTE]` diagnostics line carries — so a control-plane rewrite that
/// silently drops or reorders tokens would be invisible today.
///
/// Device facts are injected rather than probed so the snapshot is identical
/// on every simulator and device.
final class ApplePlaybackDecisionTraceSnapshotTests: XCTestCase {

    // MARK: - Fixture builders

    private static let streamURL = URL(string: "https://example.invalid/stream")!

    /// Fixed device facts: no hardware AV1, HEVC encoder available. The
    /// planner's bridge arm reads both, and `.probe()` would answer from the
    /// host Mac's VideoToolbox.
    private static let bridgeCapabilities = AppleVideoBridgeCapabilities(
        supportsAV1HardwareDecode: false,
        supportsHEVCEncode: true
    )

    private func makeSession(playMethod: String = "direct") -> PlaybackSessionResponse {
        PlaybackSessionResponse(
            sessionId: "trace-session",
            userId: nil,
            profileId: nil,
            mediaFileId: 1,
            playMethod: playMethod,
            position: 0,
            isPaused: false,
            streamUrl: Self.streamURL.absoluteString,
            audioTrackIndex: 0,
            durationSeconds: 120,
            subtitleUrls: nil,
            playbackInfo: nil
        )
    }

    private func audio(
        codec: String,
        channels: Int = 2,
        layout: String? = "stereo"
    ) -> AudioTrack {
        AudioTrack(
            index: 1,
            codec: codec,
            channels: channels,
            channelLayout: layout,
            bitrate: 128_000,
            sampleRate: 48_000,
            language: "eng",
            title: nil,
            embeddedTitle: nil,
            isDefault: true
        )
    }

    private func video(
        codec: String = "hevc",
        width: Int = 3840,
        height: Int = 2160,
        colorTransfer: String? = nil,
        videoRange: String? = nil,
        dolbyVision: String? = nil
    ) -> VideoTrack {
        VideoTrack(
            index: 0,
            codec: codec,
            width: width,
            height: height,
            frameRate: "23.976",
            bitrate: 20_000,
            profile: "Main 10",
            level: 153,
            bitDepth: 10,
            colorRange: "tv",
            colorSpace: nil,
            colorPrimaries: nil,
            colorTransfer: colorTransfer,
            videoRange: videoRange,
            dolbyVision: dolbyVision,
            title: nil,
            language: nil
        )
    }

    private func subtitle(codec: String, isDefault: Bool = true) -> SubtitleTrack {
        SubtitleTrack(
            index: 2,
            codec: codec,
            language: "eng",
            title: "English",
            embeddedTitle: "English",
            forced: false,
            hearingImpaired: false,
            isDefault: isDefault,
            external: false,
            externalPath: nil
        )
    }

    private func version(
        container: String,
        codecVideo: String?,
        codecAudio: String?,
        videoTracks: [VideoTrack]? = nil,
        audioTracks: [AudioTrack]? = nil,
        subtitleTracks: [SubtitleTrack]? = nil
    ) -> FileVersion {
        FileVersion(
            fileId: 1,
            fileName: "trace.\(container)",
            resolution: "2160p",
            codecVideo: codecVideo,
            codecAudio: codecAudio,
            hdr: false,
            container: container,
            fileSize: 1_000_000,
            duration: 120,
            bitrate: 20_000,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            chapters: nil,
            effectiveAudioTrackIndex: 0
        )
    }

    private func plan(
        _ version: FileVersion,
        session: PlaybackSessionResponse? = nil
    ) -> PlaybackExecutionPlan {
        ApplePlaybackRoutePlanner().makeExecutionPlan(
            input: ApplePlaybackPlannerInput(
                session: session ?? makeSession(),
                selectedVersion: version,
                streamRequest: StreamRequest(
                    url: Self.streamURL,
                    headers: ["Authorization": "Bearer trace"],
                    serverUrl: "https://example.invalid"
                ),
                routeRequirements: .baseline,
                selectedAudioTrackId: nil,
                pendingAudioFfIndex: nil,
                preferredAudioTrackIndex: nil,
                selectedPrimarySubtitleTrackId: nil,
                selectedSecondarySubtitleTrackId: nil,
                dolbyVisionPolicy: .default,
                videoBridgeCapabilities: Self.bridgeCapabilities
            )
        )
    }

    // MARK: - Canonical inputs

    private struct Case {
        let label: String
        let version: FileVersion
        let engine: PlaybackEngineKind
        let trace: [String]
    }

    private func canonicalCases() -> [Case] {
        [
            Case(
                label: "mp4/h264/aac",
                version: version(
                    container: "mp4", codecVideo: "h264", codecAudio: "aac",
                    audioTracks: [audio(codec: "aac")]
                ),
                engine: .avPlayerNativeDirect,
                trace: [
                    "delivery_direct",
                    "container_mp4",
                    "video_h264",
                    "audio_aac",
                    "silo_assessment",
                    "silo_not_needed",
                    "fallback_order_native_silo_hls"
                ]
            ),
            Case(
                label: "mp4/h264/aac + embedded srt",
                version: version(
                    container: "mp4", codecVideo: "h264", codecAudio: "aac",
                    audioTracks: [audio(codec: "aac")],
                    subtitleTracks: [subtitle(codec: "subrip")]
                ),
                engine: .siloPlayerLoopback,
                trace: [
                    "h264_subtitle_normalization_loopback_selected",
                    "delivery_direct",
                    "container_mp4",
                    "video_h264",
                    "audio_aac",
                    "embedded_subtitles_subrip",
                    "silo_assessment",
                    "silo_container_mp4",
                    "silo_video_h264",
                    "silo_subtitles_extract_or_register",
                    "silo_vod_gate_open",
                    "silo_eligible",
                    "silo_reason_h264_subtitle_normalization_loopback",
                    "fallback_order_silo_hls"
                ]
            ),
            Case(
                label: "mkv/hevc/eac3",
                version: version(
                    container: "mkv", codecVideo: "hevc", codecAudio: "eac3",
                    videoTracks: [video(colorTransfer: "bt709")],
                    audioTracks: [audio(codec: "eac3", channels: 6, layout: "5.1")]
                ),
                engine: .siloPlayerLoopback,
                trace: [
                    "hevc_container_loopback_selected",
                    "delivery_direct",
                    "container_mkv",
                    "video_hevc",
                    "audio_eac3",
                    "silo_assessment",
                    "silo_container_mkv",
                    "silo_video_hevc",
                    "silo_vod_gate_open",
                    "silo_eligible",
                    "silo_reason_hevc_container_loopback",
                    "fallback_order_silo_hls"
                ]
            ),
            Case(
                label: "mkv/hevc/truehd",
                version: version(
                    container: "mkv", codecVideo: "hevc", codecAudio: "truehd",
                    videoTracks: [video(colorTransfer: "smpte2084")],
                    audioTracks: [audio(codec: "truehd", channels: 8, layout: "7.1")]
                ),
                engine: .siloPlayerLoopback,
                trace: [
                    "hevc_audio_normalization_loopback_selected",
                    "delivery_direct",
                    "container_mkv",
                    "video_hevc",
                    "audio_truehd",
                    "silo_assessment",
                    "silo_container_mkv",
                    "silo_video_hevc",
                    "silo_vod_gate_open",
                    "silo_eligible",
                    "silo_reason_hevc_audio_normalization_loopback",
                    "fallback_order_silo_hls"
                ]
            ),
            Case(
                label: "webm/vp9/opus 1080p",
                version: version(
                    container: "webm", codecVideo: "vp9", codecAudio: "opus",
                    videoTracks: [video(codec: "vp9", width: 1920, height: 1080)],
                    audioTracks: [audio(codec: "opus")]
                ),
                engine: .siloPlayerLoopback,
                trace: [
                    "vp9_video_bridge_loopback_selected",
                    "delivery_direct",
                    "container_webm",
                    "video_vp9",
                    "audio_opus",
                    "silo_assessment",
                    "silo_container_webm",
                    "silo_video_vp9",
                    "silo_video_bridge_hevc",
                    "silo_vod_gate_open",
                    "silo_eligible",
                    "silo_reason_vp9_video_bridge_loopback",
                    "fallback_order_silo_hls"
                ]
            ),
            Case(
                label: "webm/vp9/opus 2160p",
                version: version(
                    container: "webm", codecVideo: "vp9", codecAudio: "opus",
                    videoTracks: [video(codec: "vp9")],
                    audioTracks: [audio(codec: "opus")]
                ),
                engine: .avPlayerHLS,
                trace: [
                    "delivery_direct",
                    "container_webm",
                    "video_vp9",
                    "audio_opus",
                    "silo_assessment",
                    "silo_container_webm",
                    "silo_video_vp9",
                    "silo_blocker_video_bridge_resolution_unsupported",
                    "fallback_order_hls_controlled_retry",
                    "blocker_container_not_allowlisted",
                    "blocker_video_codec_not_allowlisted",
                    "blocker_audio_codec_not_allowlisted",
                    "blocker_silo_video_bridge_resolution_unsupported"
                ]
            ),
            Case(
                label: "mp4/dv profile 5",
                version: version(
                    container: "mp4", codecVideo: "hevc", codecAudio: "eac3",
                    videoTracks: [video(
                        colorTransfer: "smpte2084",
                        videoRange: "DolbyVision",
                        dolbyVision: "Profile 5"
                    )],
                    audioTracks: [audio(codec: "eac3", channels: 6, layout: "5.1")]
                ),
                engine: .siloPlayerLoopback,
                trace: [
                    "dolby_vision_profile_5",
                    "profile5_loopback_selected",
                    "delivery_direct",
                    "container_mp4",
                    "video_hevc",
                    "audio_eac3",
                    "silo_assessment",
                    "silo_dv_profile_owned_by_dv_policy",
                    "fallback_order_silo_hls"
                ]
            ),
            Case(
                label: "mkv/dv profile 7",
                version: version(
                    container: "mkv", codecVideo: "hevc", codecAudio: "truehd",
                    videoTracks: [video(
                        colorTransfer: "smpte2084",
                        videoRange: "DolbyVision",
                        dolbyVision: "Profile 7"
                    )],
                    audioTracks: [audio(codec: "truehd", channels: 8, layout: "7.1")]
                ),
                engine: .siloPlayerLoopback,
                trace: [
                    "dolby_vision_profile_7",
                    "profile7_to81_base_layer_loopback_selected",
                    "delivery_direct",
                    "container_mkv",
                    "video_hevc",
                    "audio_truehd",
                    "silo_assessment",
                    "silo_dv_profile_owned_by_dv_policy",
                    "fallback_order_silo_hls"
                ]
            ),
            Case(
                label: "mkv/dv profile 8",
                version: version(
                    container: "mkv", codecVideo: "hevc", codecAudio: "eac3",
                    videoTracks: [video(
                        colorTransfer: "smpte2084",
                        videoRange: "DolbyVision",
                        dolbyVision: "Profile 8"
                    )],
                    audioTracks: [audio(codec: "eac3", channels: 6, layout: "5.1")]
                ),
                engine: .siloPlayerLoopback,
                trace: [
                    "dolby_vision_profile_8",
                    "profile81_passthrough_loopback_selected",
                    "delivery_direct",
                    "container_mkv",
                    "video_hevc",
                    "audio_eac3",
                    "silo_assessment",
                    "silo_dv_profile_owned_by_dv_policy",
                    "fallback_order_silo_hls"
                ]
            ),
            Case(
                label: "mkv/h264/aac + embedded pgs",
                version: version(
                    container: "mkv", codecVideo: "h264", codecAudio: "aac",
                    audioTracks: [audio(codec: "aac")],
                    subtitleTracks: [subtitle(codec: "hdmv_pgs_subtitle")]
                ),
                engine: .siloPlayerLoopback,
                trace: [
                    "h264_subtitle_normalization_loopback_selected",
                    "delivery_direct",
                    "container_mkv",
                    "video_h264",
                    "audio_aac",
                    "embedded_subtitles_hdmv_pgs_subtitle",
                    "silo_assessment",
                    "silo_container_mkv",
                    "silo_video_h264",
                    "silo_bitmap_subtitles_client_rendered_hdmv_pgs_subtitle",
                    "silo_subtitles_extract_or_register",
                    "silo_vod_gate_open",
                    "silo_eligible",
                    "silo_reason_h264_subtitle_normalization_loopback",
                    "fallback_order_silo_hls"
                ]
            ),
            Case(
                label: "mkv/h264/aac + embedded dvb",
                version: version(
                    container: "mkv", codecVideo: "h264", codecAudio: "aac",
                    audioTracks: [audio(codec: "aac")],
                    subtitleTracks: [subtitle(codec: "dvb_subtitle")]
                ),
                engine: .avPlayerHLS,
                trace: [
                    "delivery_direct",
                    "container_mkv",
                    "video_h264",
                    "audio_aac",
                    "embedded_subtitles_dvb_subtitle",
                    "silo_assessment",
                    "silo_container_mkv",
                    "silo_video_h264",
                    "silo_bitmap_subtitles_dvb_subtitle",
                    "silo_blocker_bitmap_subtitles_require_hls",
                    "fallback_order_hls_controlled_retry",
                    "blocker_container_not_allowlisted",
                    "blocker_embedded_subtitles_require_hls",
                    "blocker_silo_bitmap_subtitles_require_hls"
                ]
            ),
            Case(
                label: "unknown container",
                version: version(
                    container: "wtv", codecVideo: "h264", codecAudio: "aac",
                    audioTracks: [audio(codec: "aac")]
                ),
                engine: .avPlayerHLS,
                trace: [
                    "delivery_direct",
                    "container_wtv",
                    "video_h264",
                    "audio_aac",
                    "silo_assessment",
                    "silo_container_wtv",
                    "silo_video_h264",
                    "silo_blocker_container_not_normalizable",
                    "fallback_order_hls_controlled_retry",
                    "blocker_container_not_allowlisted",
                    "blocker_silo_container_not_normalizable"
                ]
            ),
            Case(
                label: "unknown video codec",
                version: version(
                    container: "mkv", codecVideo: "cinepak", codecAudio: "aac",
                    videoTracks: [video(codec: "cinepak")],
                    audioTracks: [audio(codec: "aac")]
                ),
                engine: .avPlayerHLS,
                trace: [
                    "delivery_direct",
                    "container_mkv",
                    "video_cinepak",
                    "audio_aac",
                    "silo_assessment",
                    "silo_container_mkv",
                    "silo_video_cinepak",
                    "silo_blocker_video_not_bridgeable",
                    "fallback_order_hls_controlled_retry",
                    "blocker_container_not_allowlisted",
                    "blocker_video_codec_not_allowlisted",
                    "blocker_silo_video_not_bridgeable"
                ]
            )
        ]
    }

    // MARK: - Snapshot

    func testDecisionTraceSnapshot() {
        for testCase in canonicalCases() {
            let result = plan(testCase.version)
            XCTAssertEqual(result.engine, testCase.engine, testCase.label)
            XCTAssertEqual(
                result.decisionTrace,
                testCase.trace,
                "\(testCase.label) decisionTrace drifted"
            )
        }
    }

    /// Whatever the route, every trace carries the delivery token and exactly
    /// one `silo_assessment` marker, and never repeats a token: it is the log
    /// of one planning pass, not an accumulation across retries.
    func testEveryTraceIsWellFormed() {
        for testCase in canonicalCases() {
            let trace = plan(testCase.version).decisionTrace
            XCTAssertEqual(
                trace.filter { $0 == "delivery_direct" }.count,
                1,
                testCase.label
            )
            XCTAssertEqual(
                trace.filter { $0 == "silo_assessment" }.count,
                1,
                testCase.label
            )
            XCTAssertEqual(Set(trace).count, trace.count, "\(testCase.label) repeated a token")
        }
    }

    /// PIN: current behavior. The trace is not chronological. Tokens are
    /// appended as the planner reasons, but the *outcome* tokens (the Dolby
    /// Vision profile, and the `..._selected` route token) are prepended, so
    /// the array reads outcome-first and evidence-second. Anything that treats
    /// the trace as an ordered log — a reader, or a rewrite that rebuilds it —
    /// has to reproduce that.
    func testRouteOutcomeTokensArePrependedNotAppended() {
        let loopback = plan(version(
            container: "mkv", codecVideo: "hevc", codecAudio: "aac",
            videoTracks: [video(colorTransfer: "bt709")],
            audioTracks: [audio(codec: "aac")]
        )).decisionTrace
        XCTAssertEqual(loopback.first, "hevc_container_loopback_selected")
        XCTAssertEqual(loopback.dropFirst().first, "delivery_direct")

        let dolbyVision = plan(version(
            container: "mkv", codecVideo: "hevc", codecAudio: "eac3",
            videoTracks: [video(
                colorTransfer: "smpte2084",
                videoRange: "DolbyVision",
                dolbyVision: "Profile 8"
            )],
            audioTracks: [audio(codec: "eac3", channels: 6, layout: "5.1")]
        )).decisionTrace
        XCTAssertEqual(dolbyVision.first, "dolby_vision_profile_8")
        XCTAssertEqual(dolbyVision.dropFirst().first, "profile81_passthrough_loopback_selected")

        // A route that fell through prepends nothing: the fallback trace does
        // start with the delivery token.
        let fallback = plan(version(
            container: "wtv", codecVideo: "h264", codecAudio: "aac",
            audioTracks: [audio(codec: "aac")]
        )).decisionTrace
        XCTAssertEqual(fallback.first, "delivery_direct")
    }

    // MARK: - Loopback session presence (review §9 "makeLoopbackFallbackPlan nil/non-nil")

    /// The planner is the single decider of local normalizability: a source it
    /// can normalize always carries a loopback session, and one it cannot
    /// never does — which is what makes the view model's fallback rung return
    /// nil rather than build a session it has no recipe for.
    func testLoopbackSessionExistsExactlyWhenTheEngineIsLoopback() {
        for testCase in canonicalCases() {
            let result = plan(testCase.version)
            XCTAssertEqual(
                result.loopbackSession != nil,
                result.engine == .siloPlayerLoopback,
                testCase.label
            )
        }
    }

    // MARK: - needsServerReplanBeforeLoad truth table

    /// The predicate is the abort-and-replan gate for a direct delivery that
    /// resolved to the server-HLS engine — the one shape where
    /// `plan.streamRequest.url` is a media file rather than a manifest. Pinned
    /// over the full engine × delivery cross-product, independent of whichever
    /// sources happen to produce each combination today.
    func testNeedsServerReplanBeforeLoadTruthTable() {
        let engines: [PlaybackEngineKind] = [
            .avPlayerHLS, .avPlayerNativeDirect, .siloPlayerLoopback
        ]
        let deliveries: [PlaybackDeliveryStrategy] = [.direct, .remux, .transcode]

        for engine in engines {
            for delivery in deliveries {
                let expected = engine == .avPlayerHLS && delivery == .direct
                XCTAssertEqual(
                    PlayerViewModel.needsServerReplanBeforeLoad(
                        plan: makePlan(engine: engine, delivery: delivery)
                    ),
                    expected,
                    "engine=\(engine.label) delivery=\(delivery.name)"
                )
            }
        }
    }

    private func makePlan(
        engine: PlaybackEngineKind,
        delivery: PlaybackDeliveryStrategy
    ) -> PlaybackExecutionPlan {
        PlaybackExecutionPlan(
            delivery: delivery,
            engine: engine,
            startMode: .absolutePosition(0),
            streamRequest: StreamRequest(
                url: Self.streamURL,
                headers: [:],
                serverUrl: "https://example.invalid"
            ),
            loopbackSession: nil,
            routeCapabilities: engine.routeCapabilities,
            requirements: .baseline,
            parityBlockers: [],
            decisionTrace: [],
            degradationWarnings: [],
            reason: "truth_table"
        )
    }
}
