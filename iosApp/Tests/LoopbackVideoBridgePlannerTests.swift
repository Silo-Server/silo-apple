import XCTest
@testable import Silo

/// Pins the loopback video-bridge routing decision. Every device fact is
/// injected through `AppleVideoBridgeCapabilities`, so the truth table below
/// is the same on a laptop, a CI runner, and an Apple TV — the simulator's
/// `VTIsHardwareDecodeSupported` answers for the host GPU and must never be
/// allowed to move these assertions.
final class LoopbackVideoBridgePlannerTests: XCTestCase {
    private let bridgeCapable = AppleVideoBridgeCapabilities(
        supportsAV1HardwareDecode: false,
        supportsHEVCEncode: true
    )
    private let av1Capable = AppleVideoBridgeCapabilities(
        supportsAV1HardwareDecode: true,
        supportsHEVCEncode: true
    )
    private let h264Only = AppleVideoBridgeCapabilities(
        supportsAV1HardwareDecode: false,
        supportsHEVCEncode: false
    )

    // MARK: - Fixtures

    private func version(
        codec: String,
        container: String,
        width: Int = 1920,
        height: Int = 1080,
        colorTransfer: String? = "bt709",
        dolbyVision: String? = nil,
        audioCodec: String = "aac"
    ) -> FileVersion {
        FileVersion(
            fileId: 1,
            fileName: "fixture.\(container)",
            resolution: "\(width)x\(height)",
            codecVideo: codec,
            codecAudio: audioCodec,
            hdr: false,
            container: container,
            fileSize: 1_000_000,
            duration: 120,
            bitrate: 4_000,
            videoTracks: [
                VideoTrack(
                    index: 0, codec: codec, width: width, height: height,
                    frameRate: "24.000", bitrate: 4_000_000, profile: nil,
                    level: nil, bitDepth: 8, colorRange: "tv", colorSpace: nil,
                    colorPrimaries: nil, colorTransfer: colorTransfer,
                    videoRange: nil, dolbyVision: dolbyVision,
                    title: nil, language: nil
                )
            ],
            audioTracks: [
                AudioTrack(
                    index: 1, codec: audioCodec, channels: 2,
                    channelLayout: "stereo", bitrate: 128_000, sampleRate: 48_000,
                    language: "eng", title: "Stereo", embeddedTitle: nil, isDefault: true
                )
            ],
            subtitleTracks: [],
            chapters: nil,
            effectiveAudioTrackIndex: 0
        )
    }

    private func mode(
        _ codec: String,
        container: String = "mkv",
        width: Int = 1920,
        height: Int = 1080,
        colorTransfer: String? = "bt709",
        dolbyVision: String? = nil,
        capabilities: AppleVideoBridgeCapabilities? = nil
    ) -> (mode: LoopbackSessionSpec.VideoOutputMode, blocker: String?) {
        ApplePlaybackRoutePlanner.loopbackVideoOutputMode(
            for: codec,
            version: version(
                codec: codec,
                container: container,
                width: width,
                height: height,
                colorTransfer: colorTransfer,
                dolbyVision: dolbyVision
            ),
            capabilities: capabilities ?? bridgeCapable
        )
    }

    // MARK: - Truth table

    func testCopyCodecsStayOnTheRemuxPath() {
        for codec in ["h264", "hevc"] {
            let decision = mode(codec)
            XCTAssertEqual(decision.mode, .copy, codec)
            XCTAssertNil(decision.blocker, codec)
        }
    }

    func testBridgeCodecsResolveToHEVCEncode() {
        for codec in ["vp9", "vp8", "mpeg2video", "mpeg4", "msmpeg4v3", "vc1", "wmv3"] {
            let decision = mode(codec)
            XCTAssertEqual(decision.mode, .transcodeHEVC, codec)
            XCTAssertNil(decision.blocker, codec)
        }
    }

    func testBridgeFallsToH264WhenHEVCEncodeUnavailable() {
        for codec in ["vp9", "mpeg4", "wmv3"] {
            let decision = mode(codec, capabilities: h264Only)
            XCTAssertEqual(decision.mode, .transcodeH264, codec)
            XCTAssertNil(decision.blocker, codec)
        }
    }

    func testAV1PassesThroughOnlyWithHardwareDecode() {
        XCTAssertEqual(mode("av1", capabilities: av1Capable).mode, .passthroughAV1)
        XCTAssertEqual(mode("av1", capabilities: bridgeCapable).mode, .transcodeHEVC)
    }

    func testUnknownCodecIsBlocked() {
        let decision = mode("theora")
        XCTAssertEqual(decision.mode, .copy)
        XCTAssertEqual(decision.blocker, "video_not_bridgeable")
    }

    func testDolbyVisionNeverBridges() {
        for profile in [5, 7, 8] {
            for codec in ["vp9", "av1", "mpeg2video", "vc1"] {
                let decision = mode(
                    codec,
                    dolbyVision: "Profile \(profile)",
                    capabilities: av1Capable
                )
                XCTAssertFalse(decision.mode.isBridged, "\(codec) p\(profile)")
                XCTAssertNotEqual(decision.mode, .passthroughAV1, "\(codec) p\(profile)")
                XCTAssertEqual(decision.blocker, "dv_not_bridgeable", "\(codec) p\(profile)")
            }
            for codec in ["h264", "hevc"] {
                let decision = mode(codec, dolbyVision: "Profile \(profile)")
                XCTAssertEqual(decision.mode, .copy, "\(codec) p\(profile)")
                XCTAssertNil(decision.blocker, "\(codec) p\(profile)")
            }
        }
    }

    func testHDRBridgeIsBlockedInPhaseOne() {
        let decision = mode("vp9", colorTransfer: "smpte2084")
        XCTAssertEqual(decision.blocker, "video_hdr_bridge_unsupported")
        XCTAssertFalse(decision.mode.isBridged)
    }

    func testResolutionCapBlocksAbove1080p() {
        XCTAssertEqual(mode("vp9", width: 1920, height: 1080).mode, .transcodeHEVC)
        let uhd = mode("vp9", width: 3840, height: 2160)
        XCTAssertEqual(uhd.blocker, "video_bridge_resolution_unsupported")
        XCTAssertFalse(uhd.mode.isBridged)
    }

    // MARK: - Container tiers

    func testBridgeContainersOpenOnlyForBridgedModes() {
        for container in ["avi", "wmv", "asf", "webm", "flv", "mpg", "vob"] {
            XCTAssertFalse(
                ApplePlaybackRoutePlanner.siloContainerIsNormalizable(container, videoOutputMode: .copy),
                container
            )
            XCTAssertTrue(
                ApplePlaybackRoutePlanner.siloContainerIsNormalizable(
                    container,
                    videoOutputMode: .transcodeHEVC
                ),
                container
            )
        }
        // The copy tier is unchanged.
        for container in ["mkv", "ts", "m2ts", "mp4", "mov"] {
            XCTAssertTrue(
                ApplePlaybackRoutePlanner.siloContainerIsNormalizable(container, videoOutputMode: .copy),
                container
            )
        }
    }

    // MARK: - End-to-end plan

    private func plan(
        codec: String,
        container: String,
        audioCodec: String = "mp3",
        capabilities: AppleVideoBridgeCapabilities? = nil
    ) throws -> PlaybackExecutionPlan {
        let selectedVersion = version(codec: codec, container: container, audioCodec: audioCodec)
        let url = try XCTUnwrap(URL(string: "https://example.invalid/fixture.\(container)"))
        let session = PlaybackSessionResponse(
            sessionId: "bridge-session",
            userId: nil,
            profileId: nil,
            mediaFileId: 1,
            playMethod: "direct",
            position: 0,
            isPaused: false,
            streamUrl: url.absoluteString,
            audioTrackIndex: 0,
            durationSeconds: 120,
            subtitleUrls: nil,
            playbackInfo: nil
        )
        return ApplePlaybackRoutePlanner().makeExecutionPlan(
            input: ApplePlaybackPlannerInput(
                session: session,
                selectedVersion: selectedVersion,
                streamRequest: StreamRequest(url: url, headers: [:], serverUrl: ""),
                routeRequirements: .baseline,
                selectedAudioTrackId: nil,
                pendingAudioFfIndex: nil,
                preferredAudioTrackIndex: 0,
                selectedPrimarySubtitleTrackId: nil,
                selectedSecondarySubtitleTrackId: nil,
                hlsRouteFeatureEnabled: true,
                siloPlayerPrimaryEnabled: true,
                dolbyVisionPolicy: .default,
                videoBridgeCapabilities: capabilities ?? bridgeCapable
            )
        )
    }

    func testVP9WebmRoutesToTheBridgedLoopback() throws {
        let plan = try plan(codec: "vp9", container: "webm", audioCodec: "opus")
        XCTAssertEqual(plan.engine, .siloPlayerLoopback)
        XCTAssertEqual(plan.loopbackSession?.videoOutputMode, .transcodeHEVC)
        XCTAssertEqual(plan.loopbackSession?.videoMode, .passthroughHEVC)
        XCTAssertEqual(plan.reason, "vp9_video_bridge_loopback")
        XCTAssertTrue(plan.decisionTrace.contains("silo_video_vp9"), "\(plan.decisionTrace)")
        XCTAssertTrue(plan.decisionTrace.contains("silo_video_bridge_hevc"), "\(plan.decisionTrace)")
        XCTAssertEqual(plan.normalizationSummary.videoMode, "bridge_hevc")
    }

    func testMPEG4AVIRoutesToTheBridgedLoopback() throws {
        let plan = try plan(codec: "mpeg4", container: "avi", audioCodec: "mp3")
        XCTAssertEqual(plan.engine, .siloPlayerLoopback)
        XCTAssertEqual(plan.loopbackSession?.videoOutputMode, .transcodeHEVC)
        XCTAssertEqual(plan.reason, "mpeg4_video_bridge_loopback")
        // mp3 is not an mp4-muxable loopback codec, so the audio bridge's
        // default arm has to claim it.
        XCTAssertEqual(plan.loopbackSession?.selectedAudio.outputMode, .transcodeAAC)
    }

    func testWMV3RoutesToTheBridgedLoopback() throws {
        let plan = try plan(codec: "wmv3", container: "wmv", audioCodec: "wmav2")
        XCTAssertEqual(plan.engine, .siloPlayerLoopback)
        XCTAssertEqual(plan.loopbackSession?.videoOutputMode, .transcodeHEVC)
        XCTAssertEqual(plan.reason, "wmv3_video_bridge_loopback")
        XCTAssertEqual(plan.loopbackSession?.selectedAudio.outputMode, .transcodeAAC)
    }

    func testUnbridgeableCodecFallsToCompatibility() throws {
        let plan = try plan(codec: "theora", container: "ogv", audioCodec: "vorbis")
        XCTAssertEqual(plan.engine, .playerCoreDirect)
        XCTAssertTrue(
            plan.parityBlockers.contains("silo_video_not_bridgeable"),
            "\(plan.parityBlockers)"
        )
    }

    func testH264MKVStillCopies() throws {
        let plan = try plan(codec: "h264", container: "mkv", audioCodec: "dts")
        XCTAssertEqual(plan.engine, .siloPlayerLoopback)
        XCTAssertEqual(plan.loopbackSession?.videoOutputMode, .copy)
        XCTAssertEqual(plan.normalizationSummary.videoMode, "h264_passthrough")
    }

    // MARK: - Audio tail

    func testUnknownAudioCodecsGoThroughTheAudioBridge() {
        // The containers the video bridge unlocks carry mp3/mp2/vorbis/wma
        // audio; every one of them has to land on a transcoding arm or the
        // writer would try to remux a codec the mp4 muxer refuses.
        for (codec, channels, expected) in [
            ("mp3", 2, LoopbackSessionSpec.AudioOutputMode.transcodeAAC),
            ("mp2", 2, .transcodeAAC),
            ("vorbis", 2, .transcodeAAC),
            ("opus", 2, .transcodeAAC),
            ("wmav2", 2, .transcodeAAC),
            ("vorbis", 6, .transcodeFLAC),
            ("dts", 6, .transcodeFLAC),
        ] as [(String, Int, LoopbackSessionSpec.AudioOutputMode)] {
            let track = PlayerTrack(
                trackId: 10_000,
                kind: .audio,
                title: nil,
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
            XCTAssertEqual(
                ApplePlaybackRoutePlanner.loopbackAudioOutputMode(for: track),
                expected,
                "\(codec)/\(channels)"
            )
        }
    }
}
