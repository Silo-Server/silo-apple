import AVFoundation
import Libavcodec
import Libavformat
import Libavutil
import XCTest
@testable import Silo

/// Exercises representative playback inputs inside the simulator test host.
/// The fixtures are deliberately tiny but contain real encoded packets; this
/// catches packaging, demux, native-asset, and route-policy regressions without
/// pretending the simulator validates physical-display HDR/Dolby Vision.
final class PlaybackMediaFixtureTests: XCTestCase {
    private struct Fixture {
        let resource: String
        let ext: String
        let videoCodec: String
        let audioCodec: String
    }

    private let fixtures = [
        Fixture(resource: "v3_h264_aac", ext: "mp4", videoCodec: "h264", audioCodec: "aac"),
        Fixture(resource: "v3_h264_aac", ext: "mov", videoCodec: "h264", audioCodec: "aac"),
        Fixture(resource: "v3_h264_aac", ext: "m4v", videoCodec: "h264", audioCodec: "aac"),
        Fixture(resource: "v3_h264_aac", ext: "mkv", videoCodec: "h264", audioCodec: "aac"),
        Fixture(resource: "v3_h264_aac", ext: "ts", videoCodec: "h264", audioCodec: "aac"),
        Fixture(resource: "v3_h264_aac", ext: "m2ts", videoCodec: "h264", audioCodec: "aac"),
        Fixture(resource: "v3_mpeg4_mp3", ext: "avi", videoCodec: "mpeg4", audioCodec: "mp3"),
        Fixture(resource: "v3_vp9_opus", ext: "webm", videoCodec: "vp9", audioCodec: "opus"),
        Fixture(resource: "v3_h264_aac", ext: "m3u8", videoCodec: "h264", audioCodec: "aac")
    ]

    func testFFmpegDemuxesAllRepresentativeContainersInSimulator() throws {
        for fixture in fixtures {
            let url = try fixtureURL(fixture)
            var formatContext: UnsafeMutablePointer<AVFormatContext>?
            XCTAssertEqual(
                avformat_open_input(&formatContext, url.path, nil, nil),
                0,
                "open \(fixture.ext)"
            )
            defer { avformat_close_input(&formatContext) }
            let context = try XCTUnwrap(formatContext)
            XCTAssertGreaterThanOrEqual(avformat_find_stream_info(context, nil), 0, fixture.ext)

            var videoCodec: String?
            var audioCodec: String?
            for index in 0 ..< Int(context.pointee.nb_streams) {
                guard let stream = context.pointee.streams[index],
                      let parameters = stream.pointee.codecpar else { continue }
                let codecName = String(cString: avcodec_get_name(parameters.pointee.codec_id))
                switch parameters.pointee.codec_type {
                case AVMEDIA_TYPE_VIDEO:
                    videoCodec = codecName
                case AVMEDIA_TYPE_AUDIO:
                    audioCodec = codecName
                default:
                    break
                }
            }
            XCTAssertEqual(videoCodec, fixture.videoCodec, fixture.ext)
            XCTAssertEqual(audioCodec, fixture.audioCodec, fixture.ext)
        }
    }

    func testAVFoundationLoadsNativeAndHLSAssetsInSimulator() async throws {
        for fixture in fixtures where ["mp4", "mov", "m4v", "m3u8"].contains(fixture.ext) {
            let asset = AVURLAsset(url: try fixtureURL(fixture))
            let isPlayable = try await asset.load(.isPlayable)
            XCTAssertTrue(isPlayable, fixture.ext)
            if fixture.ext != "m3u8" {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                XCTAssertFalse(tracks.isEmpty, fixture.ext)
            }
        }
    }

    func testFFmpegDecodesVideoAndAudioFromAllRepresentativeContainers() throws {
        for fixture in fixtures {
            let url = try fixtureURL(fixture)
            XCTAssertTrue(
                try decodesFrame(from: url, mediaType: AVMEDIA_TYPE_VIDEO),
                "video decode \(fixture.ext)"
            )
            XCTAssertTrue(
                try decodesFrame(from: url, mediaType: AVMEDIA_TYPE_AUDIO),
                "audio decode \(fixture.ext)"
            )
        }
    }

    func testAppleRoutePolicyForH264ContainerMatrix() throws {
        let expected: [String: PlaybackEngineKind] = [
            "mp4": .avPlayerNativeDirect,
            "mov": .avPlayerNativeDirect,
            "m4v": .avPlayerNativeDirect,
            "mkv": .siloPlayerLoopback,
            "ts": .siloPlayerLoopback,
            "m2ts": .siloPlayerLoopback
        ]
        for (container, expectedEngine) in expected {
            let session = PlaybackSessionResponse(
                sessionId: "fixture-session",
                userId: nil,
                profileId: nil,
                mediaFileId: 42,
                playMethod: "direct",
                position: 0,
                isPaused: false,
                streamUrl: try fixtureURL(.init(
                    resource: "v3_h264_aac",
                    ext: container,
                    videoCodec: "h264",
                    audioCodec: "aac"
                )).absoluteString,
                audioTrackIndex: 0,
                durationSeconds: 2,
                subtitleUrls: nil,
                playbackInfo: nil
            )
            let version = FileVersion(
                fileId: 42,
                fileName: "fixture.\(container)",
                resolution: "320x180",
                codecVideo: "h264",
                codecAudio: "aac",
                hdr: false,
                container: container,
                fileSize: 100_000,
                duration: 2,
                bitrate: 400_000,
                videoTracks: nil,
                audioTracks: [AudioTrack(
                    index: 0,
                    codec: "aac",
                    channels: 2,
                    channelLayout: "stereo",
                    bitrate: 96_000,
                    sampleRate: 48_000,
                    language: "eng",
                    title: "Stereo",
                    embeddedTitle: nil,
                    isDefault: true
                )],
                subtitleTracks: nil,
                chapters: nil,
                effectiveAudioTrackIndex: 0
            )
            let url = try fixtureURL(.init(
                resource: "v3_h264_aac",
                ext: container,
                videoCodec: "h264",
                audioCodec: "aac"
            ))
            let stream = StreamRequest(url: url, headers: [:], serverUrl: "")
            let plan = ApplePlaybackRoutePlanner().makeExecutionPlan(
                input: ApplePlaybackPlannerInput(
                    session: session,
                    selectedVersion: version,
                    streamRequest: stream,
                    routeRequirements: .baseline,
                    selectedAudioTrackId: nil,
                    pendingAudioFfIndex: nil,
                    preferredAudioTrackIndex: 0,
                    selectedPrimarySubtitleTrackId: nil,
                    selectedSecondarySubtitleTrackId: nil,
                    hlsRouteFeatureEnabled: true,
                    siloPlayerPrimaryEnabled: true,
                    dolbyVisionPolicy: .default
                )
            )
            XCTAssertEqual(plan.engine, expectedEngine, container)
        }
    }

    func testHigh10FixtureUsesPlayerCoreSoftwareDecode() throws {
        let url = try fixtureURL(.init(
            resource: "v3_h264_high10_aac",
            ext: "mp4",
            videoCodec: "h264",
            audioCodec: "aac"
        ))
        var formatContext: UnsafeMutablePointer<AVFormatContext>?
        XCTAssertEqual(avformat_open_input(&formatContext, url.path, nil, nil), 0)
        defer { avformat_close_input(&formatContext) }
        let context = try XCTUnwrap(formatContext)
        XCTAssertGreaterThanOrEqual(avformat_find_stream_info(context, nil), 0)
        let videoStream = try XCTUnwrap((0 ..< Int(context.pointee.nb_streams)).compactMap { index in
            context.pointee.streams[index]
        }.first { $0.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO })
        let codecpar = videoStream.pointee.codecpar.pointee
        XCTAssertEqual(codecpar.codec_id, AV_CODEC_ID_H264)
        XCTAssertEqual(codecpar.profile & ~Int32(2_048), 110)
        XCTAssertEqual(VideoColorMetadata.sourceBitDepth(AVPixelFormat(rawValue: codecpar.format)), 10)
        XCTAssertTrue(PlayerCore.h264RequiresSoftwareDecode(codecpar))
        XCTAssertTrue(PlayerCore.h264SoftwareDecodeWithinAdvertisedBounds(codecpar, stream: videoStream.pointee))
        var highBaseRateStream = videoStream.pointee
        highBaseRateStream.avg_frame_rate = AVRational(num: 0, den: 0)
        highBaseRateStream.r_frame_rate = AVRational(num: 60, den: 1)
        XCTAssertFalse(PlayerCore.h264SoftwareDecodeWithinAdvertisedBounds(codecpar, stream: highBaseRateStream))
        var missingContainerMetadata = videoStream.pointee
        missingContainerMetadata.avg_frame_rate = AVRational(num: 0, den: 0)
        missingContainerMetadata.r_frame_rate = AVRational(num: 0, den: 0)
        var missingBitrate = codecpar
        missingBitrate.bit_rate = 0
        XCTAssertFalse(PlayerCore.h264SoftwareDecodeWithinAdvertisedBounds(
            missingBitrate,
            stream: missingContainerMetadata
        ))
        XCTAssertTrue(PlayerCore.h264SoftwareDecodeWithinAdvertisedBounds(
            missingBitrate,
            stream: missingContainerMetadata,
            authoritativeFrameRate: 23.976,
            authoritativeBitrateKbps: 4_096
        ))
        XCTAssertFalse(PlayerCore.h264SoftwareDecodeWithinAdvertisedBounds(
            missingBitrate,
            stream: missingContainerMetadata,
            authoritativeFrameRate: 60,
            authoritativeBitrateKbps: 4_096
        ))
        var oversized = codecpar
        oversized.width = 3_840
        XCTAssertFalse(PlayerCore.h264SoftwareDecodeWithinAdvertisedBounds(oversized, stream: videoStream.pointee))
        var ordinaryH264 = codecpar
        ordinaryH264.profile = 100
        ordinaryH264.format = AV_PIX_FMT_YUV420P.rawValue
        XCTAssertFalse(PlayerCore.h264RequiresSoftwareDecode(ordinaryH264))
        var hevcMain10 = codecpar
        hevcMain10.codec_id = AV_CODEC_ID_HEVC
        XCTAssertFalse(PlayerCore.h264RequiresSoftwareDecode(hevcMain10))
        XCTAssertEqual(
            PlayerCore.softwareVideoPresentationSize(codecpar),
            CGSize(width: 320, height: 180)
        )
        XCTAssertNil(PlayerCore.boundedSoftwareVideoOutputSize(
            sourceWidth: 1_280,
            sourceHeight: 720,
            pixelAspect: 100,
            displayTransform: .identity
        ))
        XCTAssertTrue(try decodesFrame(from: url, mediaType: AVMEDIA_TYPE_VIDEO))

        let probedTracks = LocalMediaProbe.videoTracks(at: url)
        let probedVideo = try XCTUnwrap(probedTracks.first)
        XCTAssertEqual(probedVideo.bitrate, 130)

        let session = PlaybackSessionResponse(
            sessionId: "high10-session", userId: nil, profileId: nil, mediaFileId: 77,
            playMethod: "direct", position: 0, isPaused: false,
            streamUrl: url.absoluteString, audioTrackIndex: 0, durationSeconds: 1,
            subtitleUrls: nil, playbackInfo: nil
        )
        let version = FileVersion(
            fileId: 77, fileName: "v3_h264_high10_aac.mp4", resolution: "320x180",
            codecVideo: "h264", codecAudio: "aac", hdr: false, container: "mp4",
            fileSize: 20_000, duration: 1, bitrate: 200,
            videoTracks: [VideoTrack(
                index: 0, codec: "h264", width: 320, height: 180, frameRate: "24",
                bitrate: 120, profile: "High 10", level: 51, bitDepth: 10,
                colorRange: "tv", colorSpace: nil, colorPrimaries: nil,
                colorTransfer: nil, videoRange: "SDR", dolbyVision: nil,
                title: nil, language: nil
            )],
            audioTracks: nil, subtitleTracks: nil, chapters: nil,
            effectiveAudioTrackIndex: 0
        )
        let plan = ApplePlaybackRoutePlanner().makeExecutionPlan(input: ApplePlaybackPlannerInput(
            session: session, selectedVersion: version,
            streamRequest: StreamRequest(url: url, headers: [:], serverUrl: ""),
            routeRequirements: .baseline, selectedAudioTrackId: nil,
            pendingAudioFfIndex: nil, preferredAudioTrackIndex: 0,
            selectedPrimarySubtitleTrackId: nil, selectedSecondarySubtitleTrackId: nil,
            hlsRouteFeatureEnabled: true, siloPlayerPrimaryEnabled: true,
            dolbyVisionPolicy: .default
        ))
        XCTAssertEqual(plan.engine, .playerCoreDirect)
        XCTAssertEqual(plan.reason, "h264_high10_software_decode")
        XCTAssertEqual(plan.sourceMetadata.frameRate, 24)
        XCTAssertEqual(plan.sourceMetadata.bitrateKbps, 120)
    }

    func testHigh10PlayerCorePublishesNonSquarePresentationAndPixelAspectRatio() throws {
        let url = try fixtureURL(.init(
            resource: "v3_h264_high10_sar4x3",
            ext: "mp4",
            videoCodec: "h264",
            audioCodec: ""
        ))
        let presentationExpectation = expectation(description: "non-square presentation size")
        let frameExpectation = expectation(description: "PlayerCore software frame")
        let loadedExpectation = expectation(description: "PlayerCore loaded")
        let core = PlayerCore()
        defer { core.dispose() }
        let displayLayer = AVSampleBufferDisplayLayer()
        core.attach(to: displayLayer)
        core.onVideoPresentationSizeChange = { size in
            guard size == CGSize(width: 427, height: 180) else { return }
            presentationExpectation.fulfill()
        }
        var receivedFrame = false
        core.onSoftwareVideoFrameDecodedForTesting = { pixelBuffer in
            guard !receivedFrame else { return }
            receivedFrame = true
            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            let attachments = CVBufferCopyAttachments(pixelBuffer, .shouldPropagate) as? [CFString: Any]
            DispatchQueue.main.async {
                XCTAssertEqual(pixelFormat, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                let aspect = attachments?[kCVImageBufferPixelAspectRatioKey] as? [CFString: Any]
                XCTAssertEqual(aspect?[kCVImageBufferPixelAspectRatioHorizontalSpacingKey] as? Int, 4)
                XCTAssertEqual(aspect?[kCVImageBufferPixelAspectRatioVerticalSpacingKey] as? Int, 3)
                frameExpectation.fulfill()
            }
        }
        core.onFileLoaded = {
            loadedExpectation.fulfill()
            core.play()
        }
        core.onError = { message in
            XCTFail("PlayerCore failed: \(message)")
        }
        core.load(url: url, headers: [:], startTime: 0)
        wait(for: [loadedExpectation, presentationExpectation, frameExpectation], timeout: 10)
    }

    func testHigh10AdvertisedCeilingSustainsFullSecondOfFrames() throws {
        let url = try fixtureURL(.init(
            resource: "v3_h264_high10_720p24",
            ext: "mp4",
            videoCodec: "h264",
            audioCodec: ""
        ))
        XCTAssertEqual(try decodedFrameCount(from: url, mediaType: AVMEDIA_TYPE_VIDEO), 24)

        let loadedExpectation = expectation(description: "ceiling fixture loaded")
        let framesExpectation = expectation(description: "full second decoded through PlayerCore")
        let core = PlayerCore()
        defer { core.dispose() }
        let displayLayer = AVSampleBufferDisplayLayer()
        core.attach(to: displayLayer)
        var frameCount = 0
        var finished = false
        core.onSoftwareVideoFrameDecodedForTesting = { pixelBuffer in
            guard !finished else { return }
            XCTAssertEqual(
                CVPixelBufferGetPixelFormatType(pixelBuffer),
                kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            )
            frameCount += 1
            guard frameCount == 24 else { return }
            finished = true
            DispatchQueue.main.async {
                framesExpectation.fulfill()
            }
        }
        core.onFileLoaded = {
            loadedExpectation.fulfill()
            core.play()
        }
        core.onError = { message in XCTFail("PlayerCore failed: \(message)") }
        core.load(url: url, headers: [:], startTime: 0)
        wait(for: [loadedExpectation, framesExpectation], timeout: 10)
    }

    func testHigh10PlayerCoreAppliesDisplayMatrixRotation() throws {
        let url = try fixtureURL(.init(
            resource: "v3_h264_high10_rotated90",
            ext: "mp4",
            videoCodec: "h264",
            audioCodec: ""
        ))
        var formatContext: UnsafeMutablePointer<AVFormatContext>?
        XCTAssertEqual(avformat_open_input(&formatContext, url.path, nil, nil), 0)
        defer { avformat_close_input(&formatContext) }
        let context = try XCTUnwrap(formatContext)
        XCTAssertGreaterThanOrEqual(avformat_find_stream_info(context, nil), 0)
        let stream = try XCTUnwrap((0 ..< Int(context.pointee.nb_streams)).compactMap { index in
            context.pointee.streams[index]
        }.first { $0.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO })
        let rotation = PlayerCore.softwareVideoRotationDegrees(stream: stream)
        XCTAssertEqual(abs(rotation), 90)
        let displayTransform = PlayerCore.softwareVideoDisplayTransform(stream: stream)
        XCTAssertEqual(displayTransform.a, 0, accuracy: 0.0001)
        XCTAssertEqual(displayTransform.b, -1, accuracy: 0.0001)
        XCTAssertEqual(displayTransform.c, 1, accuracy: 0.0001)
        XCTAssertEqual(displayTransform.d, 0, accuracy: 0.0001)
        let rotatedSize = PlayerCore.softwareVideoPresentationSize(
            stream.pointee.codecpar.pointee,
            sampleAspectRatio: stream.pointee.codecpar.pointee.sample_aspect_ratio,
            rotationDegrees: rotation
        )
        XCTAssertEqual(rotatedSize.width, 180, accuracy: 0.0001)
        XCTAssertEqual(rotatedSize.height, 320, accuracy: 0.0001)

        let presentationExpectation = expectation(description: "rotated presentation size")
        let frameExpectation = expectation(description: "rotated software frame")
        let loadedExpectation = expectation(description: "rotated PlayerCore loaded")
        let core = PlayerCore()
        defer { core.dispose() }
        let displayLayer = AVSampleBufferDisplayLayer()
        core.attach(to: displayLayer)
        core.onVideoPresentationSizeChange = { size in
            guard size == CGSize(width: 180, height: 320) else { return }
            presentationExpectation.fulfill()
        }
        var receivedFrame = false
        core.onSoftwareVideoFrameDecodedForTesting = { pixelBuffer in
            guard !receivedFrame else { return }
            receivedFrame = true
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
            CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
            let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0)!
                .assumingMemoryBound(to: UInt16.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) / MemoryLayout<UInt16>.size
            let topLeft = luma[0]
            let topRight = luma[width - 1]
            let bottomLeft = luma[(height - 1) * stride]
            let bottomRight = luma[(height - 1) * stride + width - 1]
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
            DispatchQueue.main.async {
                XCTAssertEqual(width, 180)
                XCTAssertEqual(height, 320)
                XCTAssertEqual(pixelFormat, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
                // The asymmetric test pattern's bright right edge must become
                // the bottom edge after the encoded 90° display transform. These
                // checks fail for a blank, mirrored, or inverse-rotated frame.
                XCTAssertGreaterThan(Int(bottomLeft), Int(topLeft) + 10_000)
                XCTAssertGreaterThan(Int(bottomRight), Int(topRight) + 10_000)
                XCTAssertGreaterThan(Int(topLeft), Int(topRight) + 1_000)
                frameExpectation.fulfill()
            }
        }
        core.onFileLoaded = {
            loadedExpectation.fulfill()
            core.play()
        }
        core.onError = { message in XCTFail("PlayerCore failed: \(message)") }
        core.load(url: url, headers: [:], startTime: 0)
        wait(for: [loadedExpectation, presentationExpectation, frameExpectation], timeout: 10)

    }

    func testAppleLoopbackRouteSupportsVideoOnlyDolbyVision() throws {
        let streamURL = try XCTUnwrap(URL(string: "https://example.invalid/video-only-dv.mp4"))
        let session = PlaybackSessionResponse(
            sessionId: "video-only-dv-session",
            userId: nil,
            profileId: nil,
            mediaFileId: 43,
            playMethod: "direct",
            position: 0,
            isPaused: false,
            streamUrl: streamURL.absoluteString,
            audioTrackIndex: nil,
            durationSeconds: 30,
            subtitleUrls: nil,
            playbackInfo: nil
        )
        let version = FileVersion(
            fileId: 43,
            fileName: "video-only-dv.mp4",
            resolution: "2160p",
            codecVideo: "hevc",
            codecAudio: nil,
            hdr: true,
            container: "mp4",
            fileSize: 100_000,
            duration: 30,
            bitrate: 40_000,
            videoTracks: [
                VideoTrack(
                    index: 0, codec: "hevc", width: 3840, height: 2160,
                    frameRate: "60.000", bitrate: 40_000, profile: "Main 10",
                    level: 153, bitDepth: 10, colorRange: "pc", colorSpace: nil,
                    colorPrimaries: nil, colorTransfer: nil,
                    videoRange: "DolbyVision", dolbyVision: "Profile 5",
                    title: nil, language: nil
                )
            ],
            audioTracks: [],
            subtitleTracks: [],
            chapters: nil
        )
        let stream = StreamRequest(url: streamURL, headers: [:], serverUrl: "")

        let plan = ApplePlaybackRoutePlanner().makeExecutionPlan(
            input: ApplePlaybackPlannerInput(
                session: session,
                selectedVersion: version,
                streamRequest: stream,
                routeRequirements: .baseline,
                selectedAudioTrackId: nil,
                pendingAudioFfIndex: nil,
                preferredAudioTrackIndex: nil,
                selectedPrimarySubtitleTrackId: nil,
                selectedSecondarySubtitleTrackId: nil,
                hlsRouteFeatureEnabled: true,
                siloPlayerPrimaryEnabled: true,
                dolbyVisionPolicy: .default
            )
        )

        XCTAssertEqual(plan.engine, .siloPlayerLoopback)
        XCTAssertEqual(plan.loopbackSession?.videoMode, .passthroughProfile5)
        XCTAssertEqual(
            plan.loopbackSession?.selectedAudio,
            LoopbackSessionSpec.SelectedAudio.absent
        )
        XCTAssertEqual(plan.normalizationSummary.audioMode, "none")
    }

    private func fixtureURL(_ fixture: Fixture) throws -> URL {
        try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: fixture.resource, withExtension: fixture.ext),
            "Missing \(fixture.resource).\(fixture.ext) from SiloTests resources"
        )
    }

    private func decodesFrame(from url: URL, mediaType: Libavutil.AVMediaType) throws -> Bool {
        var formatContext: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&formatContext, url.path, nil, nil) == 0,
              let formatContext else {
            return false
        }
        defer {
            var context: UnsafeMutablePointer<AVFormatContext>? = formatContext
            avformat_close_input(&context)
        }
        guard avformat_find_stream_info(formatContext, nil) >= 0 else { return false }

        var streamIndex: Int32 = -1
        for index in 0 ..< Int(formatContext.pointee.nb_streams) {
            guard let stream = formatContext.pointee.streams[index],
                  let parameters = stream.pointee.codecpar,
                  parameters.pointee.codec_type == mediaType else { continue }
            streamIndex = Int32(index)
            break
        }
        guard streamIndex >= 0,
              let stream = formatContext.pointee.streams[Int(streamIndex)],
              let parameters = stream.pointee.codecpar,
              let decoder = avcodec_find_decoder(parameters.pointee.codec_id) else {
            return false
        }

        var decoderContext = avcodec_alloc_context3(decoder)
        guard decoderContext != nil else { return false }
        defer { avcodec_free_context(&decoderContext) }
        guard avcodec_parameters_to_context(decoderContext, parameters) >= 0,
              avcodec_open2(decoderContext, decoder, nil) >= 0,
              let packet = av_packet_alloc(),
              let frame = av_frame_alloc() else {
            return false
        }
        defer {
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            var frame: UnsafeMutablePointer<AVFrame>? = frame
            av_packet_free(&packet)
            av_frame_free(&frame)
        }

        while av_read_frame(formatContext, packet) >= 0 {
            defer { av_packet_unref(packet) }
            guard packet.pointee.stream_index == streamIndex else { continue }
            let sendResult = avcodec_send_packet(decoderContext, packet)
            guard sendResult >= 0 else { continue }
            if avcodec_receive_frame(decoderContext, frame) >= 0 {
                return true
            }
        }

        _ = avcodec_send_packet(decoderContext, nil)
        return avcodec_receive_frame(decoderContext, frame) >= 0
    }

    private func decodedFrameCount(
        from url: URL,
        mediaType: Libavutil.AVMediaType
    ) throws -> Int {
        var formatContext: UnsafeMutablePointer<AVFormatContext>?
        guard avformat_open_input(&formatContext, url.path, nil, nil) == 0,
              let formatContext else { return 0 }
        defer {
            var context: UnsafeMutablePointer<AVFormatContext>? = formatContext
            avformat_close_input(&context)
        }
        guard avformat_find_stream_info(formatContext, nil) >= 0 else { return 0 }
        let streamIndex = (0 ..< Int(formatContext.pointee.nb_streams)).first { index in
            formatContext.pointee.streams[index]?.pointee.codecpar.pointee.codec_type == mediaType
        }
        guard let streamIndex,
              let parameters = formatContext.pointee.streams[streamIndex]?.pointee.codecpar,
              let decoder = avcodec_find_decoder(parameters.pointee.codec_id),
              let decoderContext = avcodec_alloc_context3(decoder),
              let packet = av_packet_alloc(),
              let frame = av_frame_alloc() else { return 0 }
        defer {
            var decoderContextToFree: UnsafeMutablePointer<AVCodecContext>? = decoderContext
            avcodec_free_context(&decoderContextToFree)
            var packet: UnsafeMutablePointer<AVPacket>? = packet
            var frame: UnsafeMutablePointer<AVFrame>? = frame
            av_packet_free(&packet)
            av_frame_free(&frame)
        }
        guard avcodec_parameters_to_context(decoderContext, parameters) >= 0,
              avcodec_open2(decoderContext, decoder, nil) >= 0 else { return 0 }

        var count = 0
        func receiveReadyFrames() {
            while avcodec_receive_frame(decoderContext, frame) >= 0 {
                count += 1
                av_frame_unref(frame)
            }
        }
        while av_read_frame(formatContext, packet) >= 0 {
            if packet.pointee.stream_index == Int32(streamIndex),
               avcodec_send_packet(decoderContext, packet) >= 0 {
                receiveReadyFrames()
            }
            av_packet_unref(packet)
        }
        _ = avcodec_send_packet(decoderContext, nil)
        receiveReadyFrames()
        return count
    }
}
