import XCTest
@testable import Silo

/// Characterization ("pin") tests for the Apple playback route planner.
///
/// These lock in the planner's CURRENT behavior ahead of the one-player
/// refactor. They are deliberately assertive about tokens and blockers that
/// are not otherwise contract-tested: if the refactor changes any of them,
/// the change should be a conscious decision recorded in the diff rather
/// than a silent drift.
///
/// Where a pinned value looks wrong today it is marked
/// `// PIN: current behavior; likely bug, see cleanup notes` rather than
/// "fixed" here — this file must not change production behavior.
final class ApplePlaybackRoutePlannerPinTests: XCTestCase {

    // MARK: - Fixture builders

    private static let streamURL = URL(string: "https://example.invalid/stream")!

    private func makeSession(
        playMethod: String = "direct",
        position: Double = 0,
        audioTrackIndex: Int? = 0
    ) -> PlaybackSessionResponse {
        PlaybackSessionResponse(
            sessionId: "pin-session",
            userId: nil,
            profileId: nil,
            mediaFileId: 1,
            playMethod: playMethod,
            position: position,
            isPaused: false,
            streamUrl: Self.streamURL.absoluteString,
            audioTrackIndex: audioTrackIndex,
            durationSeconds: 120,
            subtitleUrls: nil,
            playbackInfo: nil
        )
    }

    private func makeAudioTrack(
        index: Int = 1,
        codec: String,
        channels: Int = 2,
        layout: String? = "stereo",
        title: String? = nil
    ) -> AudioTrack {
        AudioTrack(
            index: index,
            codec: codec,
            channels: channels,
            channelLayout: layout,
            bitrate: 128_000,
            sampleRate: 48_000,
            language: "eng",
            title: title,
            embeddedTitle: title,
            isDefault: true
        )
    }

    private func makeVideoTrack(
        codec: String = "hevc",
        colorTransfer: String? = nil,
        videoRange: String? = nil,
        dolbyVision: String? = nil
    ) -> VideoTrack {
        VideoTrack(
            index: 0,
            codec: codec,
            width: 3840,
            height: 2160,
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

    private func makeSubtitleTrack(
        index: Int = 2,
        codec: String,
        isDefault: Bool = true,
        forced: Bool = false
    ) -> SubtitleTrack {
        SubtitleTrack(
            index: index,
            codec: codec,
            language: "eng",
            title: "English",
            embeddedTitle: "English",
            forced: forced,
            hearingImpaired: false,
            isDefault: isDefault,
            external: false,
            externalPath: nil
        )
    }

    private func makeVersion(
        container: String,
        codecVideo: String?,
        codecAudio: String?,
        videoTracks: [VideoTrack]? = nil,
        audioTracks: [AudioTrack]? = nil,
        subtitleTracks: [SubtitleTrack]? = nil,
        bitrate: Int? = 20_000
    ) -> FileVersion {
        FileVersion(
            fileId: 1,
            fileName: "pin.\(container)",
            resolution: "2160p",
            codecVideo: codecVideo,
            codecAudio: codecAudio,
            hdr: false,
            container: container,
            fileSize: 1_000_000,
            duration: 120,
            bitrate: bitrate,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            chapters: nil,
            effectiveAudioTrackIndex: 0
        )
    }

    private func plan(
        version: FileVersion,
        session: PlaybackSessionResponse? = nil,
        requirements: PlaybackRouteRequirements = .baseline,
        hlsRouteFeatureEnabled: Bool = true,
        siloPlayerPrimaryEnabled: Bool = true,
        dolbyVisionPolicy: DolbyVisionPolicy.Snapshot = .default,
        selectedPrimarySubtitleTrackId: Int64? = nil
    ) -> PlaybackExecutionPlan {
        ApplePlaybackRoutePlanner().makeExecutionPlan(
            input: ApplePlaybackPlannerInput(
                session: session ?? makeSession(),
                selectedVersion: version,
                streamRequest: StreamRequest(
                    url: Self.streamURL,
                    headers: ["Authorization": "Bearer pin"],
                    serverUrl: "https://example.invalid"
                ),
                routeRequirements: requirements,
                selectedAudioTrackId: nil,
                pendingAudioFfIndex: nil,
                preferredAudioTrackIndex: nil,
                selectedPrimarySubtitleTrackId: selectedPrimarySubtitleTrackId,
                selectedSecondarySubtitleTrackId: nil,
                hlsRouteFeatureEnabled: hlsRouteFeatureEnabled,
                siloPlayerPrimaryEnabled: siloPlayerPrimaryEnabled,
                dolbyVisionPolicy: dolbyVisionPolicy
            )
        )
    }

    // MARK: - 1 & 2: native direct assets

    func testMP4H264AACRoutesNativeDirect() {
        let version = makeVersion(
            container: "mp4",
            codecVideo: "h264",
            codecAudio: "aac",
            audioTracks: [makeAudioTrack(codec: "aac")]
        )
        let result = plan(version: version)

        XCTAssertEqual(result.engine, .avPlayerNativeDirect)
        XCTAssertEqual(result.reason, "native_direct_asset")
        XCTAssertNil(result.loopbackSession)
        XCTAssertEqual(result.parityBlockers, [])
        XCTAssertTrue(result.featureFlagEnabled)
        XCTAssertEqual(result.normalizationSummary, PlaybackNormalizationSummary.none)
        XCTAssertEqual(result.routeFamily, .nativePlayer)
        // Full trace pinned once, to lock ordering as well as membership.
        XCTAssertEqual(result.decisionTrace, [
            "pip_disabled_until_validated",
            "external_playback_disabled_until_validated",
            "delivery_direct",
            "container_mp4",
            "video_h264",
            "audio_aac",
            "silo_assessment",
            "silo_not_needed",
            "fallback_order_native_silo_compatibility"
        ])
    }

    func testMP4HEVCEAC3RoutesNativeDirect() {
        let version = makeVersion(
            container: "mp4",
            codecVideo: "hevc",
            codecAudio: "eac3",
            videoTracks: [makeVideoTrack(colorTransfer: "bt709")],
            audioTracks: [makeAudioTrack(codec: "eac3", channels: 6, layout: "5.1")]
        )
        let result = plan(version: version)

        XCTAssertEqual(result.engine, .avPlayerNativeDirect)
        XCTAssertEqual(result.reason, "native_direct_asset")
        XCTAssertNil(result.loopbackSession)
        XCTAssertEqual(result.parityBlockers, [])
        XCTAssertTrue(result.decisionTrace.contains("audio_eac3"))
    }

    // MARK: - 3: MKV / H.264 / AAC and the VOD gate

    func testMKVH264LoopbackWhenSiloPlayerPrimaryEnabled() {
        let version = makeVersion(
            container: "mkv",
            codecVideo: "h264",
            codecAudio: "aac",
            audioTracks: [makeAudioTrack(codec: "aac")]
        )
        let result = plan(version: version, siloPlayerPrimaryEnabled: true)

        XCTAssertEqual(result.engine, .siloPlayerLoopback)
        XCTAssertEqual(result.reason, "h264_container_loopback")
        XCTAssertEqual(result.parityBlockers, [])
        XCTAssertEqual(result.loopbackSession?.videoMode, .passthroughH264)
        XCTAssertEqual(result.loopbackSession?.servingMode, .vodPlan)
        XCTAssertEqual(result.loopbackSession?.selectedAudio.outputMode, .copy)
        XCTAssertEqual(result.loopbackSession?.manifestMetadata.videoRange, "SDR")
        XCTAssertNil(result.loopbackSession?.manifestMetadata.advertisedDolbyVisionProfile)
        XCTAssertNil(result.loopbackSession?.manifestMetadata.compatibilityBrand)
        XCTAssertTrue(result.decisionTrace.contains("silo_vod_gate_open"))
        XCTAssertTrue(result.decisionTrace.contains("h264_container_loopback_selected"))
        XCTAssertTrue(result.decisionTrace.contains("fallback_order_silo_compatibility"))
        XCTAssertEqual(result.normalizationSummary.containerMode, "local_fmp4_hls")
        XCTAssertEqual(result.normalizationSummary.videoMode, "h264_passthrough")
        XCTAssertEqual(result.normalizationSummary.audioMode, "copy")
    }

    func testMKVH264FallsBackToPlayerCoreWhenGateClosed() {
        let version = makeVersion(
            container: "mkv",
            codecVideo: "h264",
            codecAudio: "aac",
            audioTracks: [makeAudioTrack(codec: "aac")]
        )
        let result = plan(version: version, siloPlayerPrimaryEnabled: false)

        XCTAssertEqual(result.engine, .playerCoreDirect)
        XCTAssertEqual(result.reason, "native_direct_blocked")
        XCTAssertNil(result.loopbackSession)
        XCTAssertEqual(result.parityBlockers, [
            "container_not_allowlisted",
            "silo_h264_loopback_startup_unreliable"
        ])
        // Full trace pinned: this is the fallback path most likely to shift.
        XCTAssertEqual(result.decisionTrace, [
            "pip_disabled_until_validated",
            "external_playback_disabled_until_validated",
            "delivery_direct",
            "container_mkv",
            "video_h264",
            "audio_aac",
            "silo_assessment",
            "silo_container_mkv",
            "silo_video_h264",
            "silo_reason_h264_container_loopback",
            "silo_h264_loopback_disabled",
            "silo_blocker_h264_loopback_startup_unreliable",
            "fallback_order_compatibility_only",
            "blocker_container_not_allowlisted",
            "blocker_silo_h264_loopback_startup_unreliable"
        ])
        XCTAssertEqual(result.normalizationSummary.videoMode, "compatibility_decode")
    }

    // MARK: - 4: MKV / HEVC SDR, both gate states

    func testMKVHEVCSDRLoopbackWhenGateOpen() {
        let version = makeVersion(
            container: "mkv",
            codecVideo: "hevc",
            codecAudio: "aac",
            videoTracks: [makeVideoTrack(colorTransfer: "bt709")],
            audioTracks: [makeAudioTrack(codec: "aac")]
        )
        let result = plan(version: version, siloPlayerPrimaryEnabled: true)

        XCTAssertEqual(result.engine, .siloPlayerLoopback)
        XCTAssertEqual(result.reason, "hevc_container_loopback")
        XCTAssertEqual(result.loopbackSession?.videoMode, .passthroughHEVC)
        XCTAssertEqual(result.loopbackSession?.servingMode, .vodPlan)
        XCTAssertEqual(result.loopbackSession?.manifestMetadata.videoRange, "SDR")
        XCTAssertEqual(result.parityBlockers, [])
    }

    func testMKVHEVCSDRFallsBackToPlayerCoreWhenGateClosed() {
        let version = makeVersion(
            container: "mkv",
            codecVideo: "hevc",
            codecAudio: "aac",
            videoTracks: [makeVideoTrack(colorTransfer: "bt709")],
            audioTracks: [makeAudioTrack(codec: "aac")]
        )
        let result = plan(version: version, siloPlayerPrimaryEnabled: false)

        XCTAssertEqual(result.engine, .playerCoreDirect)
        XCTAssertNil(result.loopbackSession)
        XCTAssertEqual(result.parityBlockers, [
            "container_not_allowlisted",
            "silo_hevc_sdr_loopback_startup_unreliable"
        ])
        XCTAssertTrue(result.decisionTrace.contains("silo_hevc_sdr_loopback_disabled"))
    }

    /// PIN: current behavior; likely bug, see cleanup notes.
    /// A source with no video-track color metadata at all resolves to "SDR"
    /// and therefore hits the SDR startup gate, even though the transfer is
    /// genuinely unknown rather than known-SDR.
    func testMKVHEVCWithUnknownTransferIsTreatedAsSDRForTheGate() {
        let version = makeVersion(
            container: "mkv",
            codecVideo: "hevc",
            codecAudio: "aac",
            videoTracks: nil,
            audioTracks: [makeAudioTrack(codec: "aac")]
        )
        let result = plan(version: version, siloPlayerPrimaryEnabled: false)

        XCTAssertEqual(result.engine, .playerCoreDirect)
        XCTAssertTrue(result.parityBlockers.contains("silo_hevc_sdr_loopback_startup_unreliable"))
    }

    // MARK: - 5: MKV / HEVC HDR10 (PQ) — loopback regardless of the gate

    func testMKVHEVCHDR10LoopsBackRegardlessOfGate() {
        for gateOpen in [true, false] {
            let version = makeVersion(
                container: "mkv",
                codecVideo: "hevc",
                codecAudio: "aac",
                videoTracks: [makeVideoTrack(colorTransfer: "smpte2084", videoRange: "HDR10")],
                audioTracks: [makeAudioTrack(codec: "aac")]
            )
            let result = plan(version: version, siloPlayerPrimaryEnabled: gateOpen)

            XCTAssertEqual(result.engine, .siloPlayerLoopback, "gateOpen=\(gateOpen)")
            XCTAssertEqual(result.reason, "hevc_container_loopback", "gateOpen=\(gateOpen)")
            XCTAssertEqual(result.loopbackSession?.videoMode, .passthroughHEVC, "gateOpen=\(gateOpen)")
            XCTAssertEqual(result.loopbackSession?.manifestMetadata.videoRange, "PQ", "gateOpen=\(gateOpen)")
            // The gate only picks the serving mode once HDR keeps the route.
            XCTAssertEqual(
                result.loopbackSession?.servingMode,
                gateOpen ? .vodPlan : .event,
                "gateOpen=\(gateOpen)"
            )
            XCTAssertEqual(result.parityBlockers, [], "gateOpen=\(gateOpen)")
        }
    }

    // MARK: - 6: Dolby Vision profiles 5 / 7 / 8

    func testDolbyVisionProfilesAlwaysLoopBackWithProfileSpecificHandling() {
        struct Expectation {
            let profile: String
            let profileNumber: Int
            let colorTransfer: String?
            let videoMode: LoopbackSessionSpec.VideoMode
            let reason: String
            let traceToken: String
            let advertisedProfile: Int?
            let compatibilityBrand: String?
            let videoRange: String
        }
        let expectations: [Expectation] = [
            Expectation(
                profile: "Profile 5",
                profileNumber: 5,
                colorTransfer: "smpte2084",
                videoMode: .passthroughProfile5,
                reason: "dolby_vision_profile5_loopback",
                traceToken: "profile5_loopback_selected",
                advertisedProfile: 5,
                compatibilityBrand: nil,
                videoRange: "PQ"
            ),
            Expectation(
                profile: "Profile 7",
                profileNumber: 7,
                colorTransfer: "smpte2084",
                videoMode: .convertProfile7To81,
                reason: "dolby_vision_profile7_to81_base_layer_loopback",
                traceToken: "profile7_to81_base_layer_loopback_selected",
                advertisedProfile: 8,
                compatibilityBrand: "db1p",
                videoRange: "PQ"
            ),
            Expectation(
                profile: "Profile 8",
                profileNumber: 8,
                colorTransfer: "smpte2084",
                videoMode: .passthroughProfile8(.hdr10),
                reason: "dolby_vision_profile81_passthrough_loopback",
                traceToken: "profile81_passthrough_loopback_selected",
                advertisedProfile: 8,
                compatibilityBrand: "db1p",
                videoRange: "PQ"
            ),
            Expectation(
                profile: "Profile 8",
                profileNumber: 8,
                colorTransfer: "arib-std-b67",
                videoMode: .passthroughProfile8(.hlg),
                reason: "dolby_vision_profile84_passthrough_loopback",
                traceToken: "profile84_passthrough_loopback_selected",
                advertisedProfile: 8,
                compatibilityBrand: "db4h",
                videoRange: "HLG"
            )
        ]

        for expected in expectations {
            for gateOpen in [true, false] {
                let label = "\(expected.profile)/\(expected.colorTransfer ?? "nil")/gate=\(gateOpen)"
                let version = makeVersion(
                    container: "mkv",
                    codecVideo: "hevc",
                    codecAudio: "aac",
                    videoTracks: [makeVideoTrack(
                        colorTransfer: expected.colorTransfer,
                        videoRange: "DolbyVision",
                        dolbyVision: expected.profile
                    )],
                    audioTracks: [makeAudioTrack(codec: "aac")]
                )
                let result = plan(version: version, siloPlayerPrimaryEnabled: gateOpen)

                XCTAssertEqual(result.engine, .siloPlayerLoopback, label)
                XCTAssertEqual(result.reason, expected.reason, label)
                XCTAssertEqual(result.loopbackSession?.videoMode, expected.videoMode, label)
                XCTAssertEqual(
                    result.loopbackSession?.manifestMetadata.advertisedDolbyVisionProfile,
                    expected.advertisedProfile,
                    label
                )
                XCTAssertEqual(
                    result.loopbackSession?.manifestMetadata.compatibilityBrand,
                    expected.compatibilityBrand,
                    label
                )
                XCTAssertEqual(
                    result.loopbackSession?.manifestMetadata.videoRange,
                    expected.videoRange,
                    label
                )
                XCTAssertEqual(result.parityBlockers, [], label)
                XCTAssertTrue(result.decisionTrace.contains(expected.traceToken), label)
                XCTAssertTrue(
                    result.decisionTrace.contains("silo_dv_profile_owned_by_dv_policy"),
                    label
                )
                XCTAssertEqual(result.sourceMetadata.dolbyVisionProfile, expected.profileNumber, label)
                XCTAssertTrue(
                    result.decisionTrace.contains("dolby_vision_profile_\(expected.profileNumber)"),
                    label
                )
            }
        }
    }

    /// PIN: current behavior. A Dolby Vision source in a *native-direct*
    /// container still takes the loopback route — the DV branch is evaluated
    /// before the native-direct eligibility check.
    func testDolbyVisionInMP4StillTakesLoopbackAheadOfNativeDirect() {
        let version = makeVersion(
            container: "mp4",
            codecVideo: "hevc",
            codecAudio: "aac",
            videoTracks: [makeVideoTrack(
                colorTransfer: "smpte2084",
                videoRange: "DolbyVision",
                dolbyVision: "Profile 5"
            )],
            audioTracks: [makeAudioTrack(codec: "aac")]
        )
        let result = plan(version: version)

        XCTAssertEqual(result.engine, .siloPlayerLoopback)
        XCTAssertEqual(result.reason, "dolby_vision_profile5_loopback")
    }

    func testDolbyVisionDisabledPolicyDropsProfile8ToBaseLayerLoopback() {
        let version = makeVersion(
            container: "mkv",
            codecVideo: "hevc",
            codecAudio: "aac",
            videoTracks: [makeVideoTrack(
                colorTransfer: "smpte2084",
                videoRange: "DolbyVision",
                dolbyVision: "Profile 8"
            )],
            audioTracks: [makeAudioTrack(codec: "aac")]
        )
        let result = plan(
            version: version,
            dolbyVisionPolicy: .init(dolbyVisionEnabled: false, preferProfile7HDR10Fallback: false)
        )

        // Resolution is `.dolbyVisionDisabled`, so the loopback carries the
        // plain HEVC base layer — but the route still reports through the
        // Dolby Vision branch's vocabulary, and the manifest advertises no
        // DV profile or compatibility brand.
        XCTAssertEqual(result.engine, .siloPlayerLoopback)
        XCTAssertEqual(result.reason, "dolby_vision_disabled_base_layer_loopback")
        XCTAssertEqual(result.loopbackSession?.videoMode, .passthroughHEVC)
        XCTAssertNil(result.loopbackSession?.manifestMetadata.advertisedDolbyVisionProfile)
        XCTAssertNil(result.loopbackSession?.manifestMetadata.compatibilityBrand)
        XCTAssertEqual(result.loopbackSession?.manifestMetadata.videoRange, "PQ")
        XCTAssertTrue(result.decisionTrace.contains("dolby_vision_profile_8"))
        XCTAssertTrue(result.decisionTrace.contains("dolby_vision_disabled_base_layer_selected"))
    }

    // MARK: - 7: loopback audio output modes

    func testLoopbackAudioOutputModeMatrixThroughThePlanner() {
        struct Case {
            let codec: String
            let channels: Int
            let title: String?
            let expectedMode: LoopbackSessionSpec.AudioOutputMode
            let expectedAtmos: Bool
            let expectsLossyDegradation: Bool
        }
        let cases: [Case] = [
            Case(codec: "truehd", channels: 8, title: "TrueHD 7.1",
                 expectedMode: .requireFLAC, expectedAtmos: false, expectsLossyDegradation: false),
            Case(codec: "dts", channels: 6, title: "DTS 5.1",
                 expectedMode: .transcodeFLAC, expectedAtmos: false, expectsLossyDegradation: false),
            Case(codec: "dts", channels: 2, title: "DTS Stereo",
                 expectedMode: .transcodeAAC, expectedAtmos: false, expectsLossyDegradation: true),
            Case(codec: "eac3", channels: 6, title: "English (Dolby Atmos)",
                 expectedMode: .copy, expectedAtmos: true, expectsLossyDegradation: false)
        ]

        for testCase in cases {
            let label = "\(testCase.codec)/\(testCase.channels)ch"
            let version = makeVersion(
                container: "mkv",
                codecVideo: "hevc",
                codecAudio: testCase.codec,
                videoTracks: [makeVideoTrack(colorTransfer: "smpte2084")],
                audioTracks: [makeAudioTrack(
                    codec: testCase.codec,
                    channels: testCase.channels,
                    layout: testCase.channels > 2 ? "5.1" : "stereo",
                    title: testCase.title
                )]
            )
            let result = plan(version: version)

            XCTAssertEqual(result.engine, .siloPlayerLoopback, label)
            XCTAssertEqual(
                result.loopbackSession?.selectedAudio.outputMode,
                testCase.expectedMode,
                label
            )
            XCTAssertEqual(
                result.loopbackSession?.selectedAudio.preservesAtmos,
                testCase.expectedAtmos,
                label
            )
            XCTAssertEqual(
                result.loopbackSession?.manifestMetadata.mayClaimAtmos,
                testCase.expectedAtmos,
                label
            )
            XCTAssertEqual(
                result.degradationWarnings.contains("Loopback audio may use an explicit lossy fallback."),
                testCase.expectsLossyDegradation,
                label
            )
        }
    }

    /// EAC3 is on the native-direct audio allowlist, so an MKV EAC3 source is
    /// a *container* loopback; TrueHD and DTS are audio normalizations.
    func testLoopbackReasonDistinguishesAudioNormalizationFromContainerOnly() {
        let hdr = [makeVideoTrack(colorTransfer: "smpte2084")]
        let truehd = makeVersion(
            container: "mkv", codecVideo: "hevc", codecAudio: "truehd",
            videoTracks: hdr, audioTracks: [makeAudioTrack(codec: "truehd", channels: 8)]
        )
        XCTAssertEqual(plan(version: truehd).reason, "hevc_audio_normalization_loopback")

        let eac3 = makeVersion(
            container: "mkv", codecVideo: "hevc", codecAudio: "eac3",
            videoTracks: hdr, audioTracks: [makeAudioTrack(codec: "eac3", channels: 6)]
        )
        XCTAssertEqual(plan(version: eac3).reason, "hevc_container_loopback")
    }

    // MARK: - 8: codecs and containers that fall through to PlayerCore

    func testUncopyableVideoAndContainersFallThroughToPlayerCore() {
        struct Case {
            let container: String
            let videoCodec: String
            let audioCodec: String
            let expectedBlockers: [String]
        }
        let cases: [Case] = [
            Case(container: "mkv", videoCodec: "av1", audioCodec: "aac",
                 expectedBlockers: [
                    "container_not_allowlisted",
                    "video_codec_not_allowlisted",
                    "silo_video_not_copyable"
                 ]),
            Case(container: "mkv", videoCodec: "vp9", audioCodec: "aac",
                 expectedBlockers: [
                    "container_not_allowlisted",
                    "video_codec_not_allowlisted",
                    "silo_video_not_copyable"
                 ]),
            Case(container: "avi", videoCodec: "mpeg4", audioCodec: "mp3",
                 expectedBlockers: [
                    "container_not_allowlisted",
                    "video_codec_not_allowlisted",
                    "silo_container_not_normalizable",
                    "silo_video_not_copyable"
                 ]),
            Case(container: "mkv", videoCodec: "mpeg2video", audioCodec: "aac",
                 expectedBlockers: [
                    "container_not_allowlisted",
                    "video_codec_not_allowlisted",
                    "silo_video_not_copyable"
                 ])
        ]

        for testCase in cases {
            let label = "\(testCase.container)/\(testCase.videoCodec)"
            let version = makeVersion(
                container: testCase.container,
                codecVideo: testCase.videoCodec,
                codecAudio: testCase.audioCodec,
                audioTracks: [makeAudioTrack(codec: testCase.audioCodec)]
            )
            let result = plan(version: version)

            XCTAssertEqual(result.engine, .playerCoreDirect, label)
            XCTAssertEqual(result.reason, "native_direct_blocked", label)
            XCTAssertNil(result.loopbackSession, label)
            XCTAssertEqual(result.parityBlockers, testCase.expectedBlockers, label)
            XCTAssertEqual(result.routeFamily, .compatibilityPlayer, label)
        }
    }

    // MARK: - 9: bitmap subtitles

    func testMandatoryPGSSubtitlesStayOnLoopbackAsClientRendered() {
        let version = makeVersion(
            container: "mkv",
            codecVideo: "h264",
            codecAudio: "aac",
            audioTracks: [makeAudioTrack(codec: "aac")],
            subtitleTracks: [makeSubtitleTrack(codec: "hdmv_pgs_subtitle")]
        )
        let result = plan(version: version, siloPlayerPrimaryEnabled: true)

        XCTAssertEqual(result.engine, .siloPlayerLoopback)
        XCTAssertEqual(result.reason, "h264_subtitle_normalization_loopback")
        XCTAssertEqual(result.parityBlockers, [])
        XCTAssertTrue(result.decisionTrace.contains(
            "silo_bitmap_subtitles_client_rendered_hdmv_pgs_subtitle"
        ))
        XCTAssertTrue(result.decisionTrace.contains("silo_subtitles_extract_or_register"))
        XCTAssertEqual(result.normalizationSummary.subtitleMode, "extract_or_sidecar")
    }

    func testMandatoryDVBSubtitlesBlockLoopbackAndFallBackToPlayerCore() {
        let version = makeVersion(
            container: "mkv",
            codecVideo: "h264",
            codecAudio: "aac",
            audioTracks: [makeAudioTrack(codec: "aac")],
            subtitleTracks: [makeSubtitleTrack(codec: "dvb_subtitle")]
        )
        let result = plan(version: version, siloPlayerPrimaryEnabled: true)

        XCTAssertEqual(result.engine, .playerCoreDirect)
        XCTAssertEqual(result.parityBlockers, [
            "container_not_allowlisted",
            "embedded_subtitles_require_compatibility",
            "silo_bitmap_subtitles_require_compatibility"
        ])
        XCTAssertTrue(result.decisionTrace.contains("silo_bitmap_subtitles_dvb_subtitle"))
    }

    /// PIN: current behavior. Only *mandatory* (default/forced) or explicitly
    /// selected embedded subtitles gate the route — an optional DVB track that
    /// is neither default nor selected leaves the loopback route intact even
    /// though the native-direct check still counts it as a blocker.
    func testNonMandatoryDVBSubtitlesDoNotBlockLoopback() {
        let version = makeVersion(
            container: "mkv",
            codecVideo: "h264",
            codecAudio: "aac",
            audioTracks: [makeAudioTrack(codec: "aac")],
            subtitleTracks: [makeSubtitleTrack(codec: "dvb_subtitle", isDefault: false)]
        )
        let result = plan(version: version, siloPlayerPrimaryEnabled: true)

        XCTAssertEqual(result.engine, .siloPlayerLoopback)
        XCTAssertEqual(result.reason, "h264_subtitle_normalization_loopback")
    }

    // MARK: - 10: remux / transcode delivery and the HLS feature flag

    func testTranscodeDeliveryHonoursHLSFeatureFlag() {
        let version = makeVersion(
            container: "mkv",
            codecVideo: "hevc",
            codecAudio: "aac",
            audioTracks: [makeAudioTrack(codec: "aac")]
        )

        let enabled = plan(
            version: version,
            session: makeSession(playMethod: "transcode", position: 42),
            hlsRouteFeatureEnabled: true
        )
        XCTAssertEqual(enabled.engine, .avPlayerHLS)
        XCTAssertEqual(enabled.reason, "apple_hls_route_enabled")
        XCTAssertTrue(enabled.featureFlagEnabled)
        XCTAssertEqual(enabled.parityBlockers, [])
        XCTAssertEqual(enabled.startMode, .absolutePosition(42))
        XCTAssertNil(enabled.loopbackSession)
        XCTAssertEqual(enabled.decisionTrace, [
            "pip_disabled_until_validated",
            "external_playback_disabled_until_validated",
            "delivery_transcode",
            "avplayer_hls_enabled",
            "fallback_order_hls_controlled_retry"
        ])
        XCTAssertEqual(enabled.normalizationSummary.containerMode, "transcode")

        let disabled = plan(
            version: version,
            session: makeSession(playMethod: "transcode", position: 42),
            hlsRouteFeatureEnabled: false
        )
        XCTAssertEqual(disabled.engine, .playerCoreDirect)
        XCTAssertEqual(disabled.reason, "parity_gate_blocked")
        XCTAssertFalse(disabled.featureFlagEnabled)
        XCTAssertEqual(disabled.parityBlockers, ["feature_flag_off"])
        XCTAssertTrue(disabled.decisionTrace.contains("avplayer_hls_disabled"))
    }

    func testRemuxDeliveryStartsAtTopOfManifest() {
        let version = makeVersion(
            container: "mkv",
            codecVideo: "hevc",
            codecAudio: "aac",
            audioTracks: [makeAudioTrack(codec: "aac")]
        )
        let result = plan(
            version: version,
            session: makeSession(playMethod: "remux", position: 42),
            hlsRouteFeatureEnabled: true
        )

        XCTAssertEqual(result.engine, .avPlayerHLS)
        XCTAssertEqual(result.startMode, .startOfManifest)
        XCTAssertTrue(result.decisionTrace.contains("delivery_remux"))
        XCTAssertEqual(result.normalizationSummary.videoMode, "server_output")
    }

    // MARK: - 11: codec normalization tables

    func testNormalizedVideoCodecTable() {
        let expected: [(String?, String?)] = [
            ("h264", "h264"),
            ("H.264", "h264"),
            ("avc", "h264"),
            ("avc1", "h264"),
            ("  AVC1  ", "h264"),
            ("hevc", "hevc"),
            ("h265", "hevc"),
            ("H.265", "hevc"),
            ("hvc1", "hevc"),
            ("hev1", "hevc"),
            // PIN: current behavior; likely bug, see cleanup notes.
            // The ISO-BMFF sample entry "av01" is not folded into "av1", so
            // the two spellings hash to different route decisions upstream.
            ("av01", "av01"),
            ("av1", "av1"),
            ("vp9", "vp9"),
            ("mpeg2video", "mpeg2video"),
            (nil, nil),
            ("", nil),
            ("   ", nil)
        ]
        for (raw, want) in expected {
            XCTAssertEqual(
                ApplePlaybackRoutePlanner.normalizedVideoCodec(raw),
                want,
                "raw=\(raw ?? "nil")"
            )
        }
    }

    /// PIN: current behavior; likely bug, see cleanup notes.
    /// `PlayerViewModel` carries a private copy of this same table that is
    /// missing the `"e-ac-3"` case, so the two disagree for that spelling.
    /// Only the planner's copy is pinned here — the duplicate is expected to
    /// disappear in the one-player refactor rather than be tested into place.
    func testNormalizedAudioCodecTable() {
        let expected: [(String?, String?)] = [
            ("aac", "aac"),
            ("MP4A", "aac"),
            ("ac3", "ac3"),
            ("eac3", "eac3"),
            ("ec3", "eac3"),
            ("ec-3", "eac3"),
            ("e-ac-3", "eac3"),
            ("truehd", "truehd"),
            ("true-hd", "truehd"),
            ("dolbytruehd", "truehd"),
            ("mlp", "truehd"),
            ("mlpa", "truehd"),
            ("alac", "alac"),
            ("mp3", "mp3"),
            ("dts", "dts"),
            ("flac", "flac"),
            // PIN: current behavior; likely bug, see cleanup notes.
            // Matroska's CodecID spellings ("A_EAC3", "A_AC3", "A_TRUEHD")
            // are not folded, so an MKV probed with raw CodecIDs would fall
            // off the native-direct audio allowlist.
            ("A_EAC3", "a_eac3"),
            ("A_AC3", "a_ac3"),
            ("A_TRUEHD", "a_truehd"),
            (nil, nil),
            ("", nil)
        ]
        for (raw, want) in expected {
            XCTAssertEqual(
                ApplePlaybackRoutePlanner.normalizedAudioCodec(raw),
                want,
                "raw=\(raw ?? "nil")"
            )
        }
    }

    /// `loopbackAudioOutputMode` runs its own normalization (lowercase, strip
    /// dashes) rather than reusing `normalizedAudioCodec`, so the two tables
    /// disagree on a few spellings.
    func testLoopbackAudioOutputModeTable() {
        func track(_ codec: String?, channels: Int? = 2, title: String? = nil) -> PlayerTrack {
            PlayerTrack(
                trackId: 10_000,
                kind: .audio,
                title: title,
                lang: "eng",
                codec: codec,
                audioChannelsLayout: nil,
                audioChannelCount: channels,
                bitrate: nil,
                isDefault: true,
                isForced: false,
                isHearingImpaired: false,
                isVisualImpaired: false,
                isExternal: false,
                isSelected: true,
                ffIndex: 1,
                srcId: 0
            )
        }

        XCTAssertEqual(ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track("aac")), .copy)
        XCTAssertEqual(ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track("ac3")), .copy)
        XCTAssertEqual(ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track("eac3")), .copy)
        XCTAssertEqual(ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track("e-ac-3")), .copy)
        XCTAssertEqual(ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track("EAC3")), .copy)
        // PIN: current behavior; likely bug, see cleanup notes.
        // "ec3" / "ec-3" normalize to "eac3" in `normalizedAudioCodec` but not
        // here (dash stripping turns "ec-3" into "ec3", which is unmapped), so
        // an already-Apple-compatible EC-3 track gets re-encoded to AAC.
        XCTAssertEqual(ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track("ec3")), .transcodeAAC)
        XCTAssertEqual(ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track("ec-3")), .transcodeAAC)

        XCTAssertEqual(
            ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track("truehd", channels: 8)),
            .requireFLAC
        )
        XCTAssertEqual(
            ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track("true-hd", channels: 8)),
            .requireFLAC
        )
        XCTAssertEqual(
            ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track("mlp", channels: 8)),
            .requireFLAC
        )
        XCTAssertEqual(
            ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track("mlpa", channels: 8)),
            .requireFLAC
        )
        XCTAssertEqual(
            ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track("dts", channels: 6)),
            .transcodeFLAC
        )
        XCTAssertEqual(
            ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track("dts", channels: 2)),
            .transcodeAAC
        )
        // PIN: current behavior; likely bug, see cleanup notes.
        // A missing channel count is treated as "stereo", so a 5.1 track with
        // no numeric channel count silently downmixes through AAC.
        XCTAssertEqual(
            ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track("dts", channels: nil)),
            .transcodeAAC
        )
        // PIN: current behavior. Lossless FLAC/PCM sources are "transcoded"
        // to FLAC rather than copied.
        XCTAssertEqual(
            ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track("flac", channels: 6)),
            .transcodeFLAC
        )
        XCTAssertEqual(
            ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track(nil)),
            .transcodeAAC
        )

        // Atmos preservation is EAC3-only, and matches on the track title.
        XCTAssertTrue(ApplePlaybackRoutePlanner.loopbackAudioPreservesAtmos(
            for: track("eac3", channels: 6, title: "English (Dolby Atmos)")
        ))
        XCTAssertTrue(ApplePlaybackRoutePlanner.loopbackAudioPreservesAtmos(
            for: track("e-ac-3", channels: 6, title: "EAC3 JOC")
        ))
        XCTAssertFalse(ApplePlaybackRoutePlanner.loopbackAudioPreservesAtmos(
            for: track("eac3", channels: 6, title: "English 5.1")
        ))
        XCTAssertFalse(ApplePlaybackRoutePlanner.loopbackAudioPreservesAtmos(
            for: track("truehd", channels: 8, title: "TrueHD Atmos")
        ))
        // PIN: current behavior; likely bug, see cleanup notes.
        // "ec3" misses the Atmos check for the same normalization gap above.
        XCTAssertFalse(ApplePlaybackRoutePlanner.loopbackAudioPreservesAtmos(
            for: track("ec3", channels: 6, title: "Atmos")
        ))
    }

    // MARK: - makeLoopbackSessionSpec directly

    func testMakeLoopbackSessionSpecPinsManifestMetadataAndSourceFields() {
        let version = makeVersion(
            container: "mkv",
            codecVideo: "hevc",
            codecAudio: "eac3",
            videoTracks: [makeVideoTrack(colorTransfer: "smpte2084")],
            audioTracks: [
                makeAudioTrack(index: 1, codec: "eac3", channels: 6, layout: "5.1", title: "Atmos"),
                makeAudioTrack(index: 2, codec: "aac", channels: 2, title: "Commentary")
            ],
            bitrate: 20_000
        )
        let spec = ApplePlaybackRoutePlanner.makeLoopbackSessionSpec(
            for: version,
            selectedAudioTrackIndex: 1,
            selectedAudioTrackId: nil,
            pendingAudioFfIndex: nil,
            preferredAudioTrackIndex: nil,
            streamRequest: StreamRequest(url: Self.streamURL, headers: [:], serverUrl: ""),
            videoMode: .passthroughHEVC,
            videoRange: "PQ",
            sourceStartTimeSeconds: -5,
            servingMode: .vodPlan
        )

        XCTAssertNotNil(spec)
        // `selectedAudioTrackIndex` matches the ordinal (`srcId`), not ffIndex.
        XCTAssertEqual(spec?.selectedAudio.trackIndex, 1)
        XCTAssertEqual(spec?.selectedAudio.ffIndex, 2)
        XCTAssertEqual(spec?.selectedAudio.sourceCodec, "aac")
        XCTAssertEqual(spec?.selectedAudio.outputMode, .copy)
        XCTAssertEqual(spec?.availableAudioTracks.count, 2)
        // Negative start times clamp to zero.
        XCTAssertEqual(spec?.sourceStartTimeSeconds, 0)
        XCTAssertEqual(spec?.sourceVideoFrameRate, 23.976)
        // PIN: current behavior; likely bug, see cleanup notes.
        // `FileVersion.bitrate` is multiplied by 1_000 as if it were kbps.
        XCTAssertEqual(spec?.sourceBitrateBps, 20_000_000)
        XCTAssertEqual(spec?.manifestMetadata.videoRange, "PQ")
        XCTAssertNil(spec?.manifestMetadata.advertisedDolbyVisionProfile)
        XCTAssertNil(spec?.manifestMetadata.compatibilityBrand)
    }

    func testMakeLoopbackSessionSpecWithoutAudioTracksReportsAbsentAudio() {
        let version = makeVersion(
            container: "mkv",
            codecVideo: "hevc",
            codecAudio: nil,
            videoTracks: [makeVideoTrack(colorTransfer: "smpte2084")],
            audioTracks: []
        )
        let spec = ApplePlaybackRoutePlanner.makeLoopbackSessionSpec(
            for: version,
            selectedAudioTrackIndex: nil,
            selectedAudioTrackId: nil,
            pendingAudioFfIndex: nil,
            preferredAudioTrackIndex: nil,
            streamRequest: StreamRequest(url: Self.streamURL, headers: [:], serverUrl: ""),
            videoMode: .passthroughProfile5
        )

        XCTAssertEqual(spec?.selectedAudio, .absent)
        XCTAssertFalse(spec?.selectedAudio.isPresent ?? true)
        XCTAssertEqual(spec?.manifestMetadata.advertisedDolbyVisionProfile, 5)
        XCTAssertEqual(spec?.servingMode, .event, "servingMode defaults to .event")
        XCTAssertEqual(spec?.manifestMetadata.videoRange, "PQ", "videoRange defaults to PQ")
    }

    // MARK: - makeRouteRequirements

    func testMakeRouteRequirementsDerivesClaimsFromSourceMetadata() {
        let version = makeVersion(
            container: "mkv",
            codecVideo: "hevc",
            codecAudio: "truehd",
            videoTracks: [makeVideoTrack(
                colorTransfer: "smpte2084",
                videoRange: "DolbyVision",
                dolbyVision: "Profile 7"
            )],
            audioTracks: [makeAudioTrack(codec: "truehd", channels: 8, title: "TrueHD Atmos")],
            subtitleTracks: [makeSubtitleTrack(codec: "subrip")]
        )
        let requirements = ApplePlaybackRoutePlanner.makeRouteRequirements(
            selectedVersion: version,
            session: makeSession(),
            dolbyVisionPolicy: .default
        )

        XCTAssertTrue(requirements.needsPrimaryAudioSelection)
        XCTAssertTrue(requirements.needsPrimarySubtitleSelection)
        XCTAssertFalse(requirements.needsSidecarPrimarySubtitles)
        XCTAssertFalse(requirements.needsSecondarySubtitles)
        XCTAssertFalse(requirements.needsChapters)
        XCTAssertTrue(requirements.needsNowPlayingIntegration)
        XCTAssertTrue(requirements.needsValidatedDolbyVisionClaim)
        XCTAssertTrue(requirements.needsValidatedAtmosClaim)
        // PIN: current behavior. PiP/external playback are never held back by
        // `makeRouteRequirements`, unlike `.baseline`.
        XCTAssertFalse(requirements.keepsPictureInPictureDisabledUntilValidated)
        XCTAssertFalse(requirements.keepsExternalPlaybackDisabledUntilValidated)

        // Turning Dolby Vision off clears the DV claim but not the Atmos one.
        let dvOff = ApplePlaybackRoutePlanner.makeRouteRequirements(
            selectedVersion: version,
            session: makeSession(),
            dolbyVisionPolicy: .init(dolbyVisionEnabled: false, preferProfile7HDR10Fallback: false)
        )
        XCTAssertFalse(dvOff.needsValidatedDolbyVisionClaim)
        XCTAssertTrue(dvOff.needsValidatedAtmosClaim)
    }

    // MARK: - PlaybackEngineKind / LoopbackServingMode

    func testPlaybackEngineKindLabels() {
        let expected: [(PlaybackEngineKind, String, PlaybackRouteFamily, String)] = [
            (.playerCoreDirect, "playerCoreDirect", .compatibilityPlayer, "Compatibility Playback"),
            (.avPlayerHLS, "avPlayerHLS", .nativePlayer, "Server Stream"),
            (.avPlayerNativeDirect, "avPlayerNativeDirect", .nativePlayer, "Direct"),
            (.siloPlayerLoopback, "siloPlayerLoopback", .siloPlayer, "Direct Stream")
        ]
        for (engine, label, family, playbackLabel) in expected {
            XCTAssertEqual(engine.label, label)
            XCTAssertEqual(engine.routeFamily, family)
            XCTAssertEqual(engine.appPlaybackLabel, playbackLabel)
        }
    }

    func testLoopbackServingModeGateDefaultsToVODPlan() {
        let key = LoopbackServingMode.primaryGateKey
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }

        defaults.removeObject(forKey: key)
        XCTAssertEqual(LoopbackServingMode.gated, .vodPlan, "absent key serves VOD")

        defaults.set(true, forKey: key)
        XCTAssertEqual(LoopbackServingMode.gated, .vodPlan)

        defaults.set(false, forKey: key)
        XCTAssertEqual(LoopbackServingMode.gated, .event, "explicit false is the kill switch")
    }
}
