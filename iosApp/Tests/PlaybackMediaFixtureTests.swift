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
}
