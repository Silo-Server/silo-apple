import Libavcodec
import Libavformat
import Libavutil
import XCTest
@testable import Silo

/// Exercises the TrueHD startup shape that triggered silent playback on iPad
/// and tvOS: at high video bitrates the one-megabyte stream probe can finish
/// before the first TrueHD major-sync unit, leaving the encoded stream's
/// sample format unknown until the decoder emits its first frame.
final class TrueHDAudioPipelineTests: XCTestCase {
    func testLoopbackFLACBridgeWaitsForDecodedTrueHDFormat() throws {
        let sourceURL = try fixtureURL()
        XCTAssertEqual(
            try cappedProbeAudioFormat(sourceURL),
            AV_SAMPLE_FMT_NONE.rawValue,
            "fixture must keep the TrueHD sample format unknown inside the production probe budget"
        )

        let outputDirectory = FileManager.default.temporaryDirectory
            .appending(path: "truehd-loopback-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        // A 1 s fixture only clears the plan's keyframe-coverage gate with a
        // sub-second target duration; without a trustworthy plan the writer
        // fails the session by design. The store is the artifact sink — its
        // debug mirror is what puts the bundle in `outputDirectory`.
        let writer = LoopbackSegmentWriter(
            sessionSpec: makeSpec(sourceURL: sourceURL),
            outputDirectory: outputDirectory,
            segmentStore: LoopbackSegmentStore(
                generation: 1,
                spillPolicy: .disabled(reason: "test"),
                debugDirectory: outputDirectory
            ),
            targetSegmentDuration: 0.5
        )
        let completion = expectation(description: "loopback writer completed")
        let lock = NSLock()
        var writerError: Error?
        writer.onFinished = { error in
            lock.lock()
            writerError = error
            lock.unlock()
            completion.fulfill()
        }

        writer.start()
        wait(for: [completion], timeout: 30)

        lock.lock()
        let result = writerError
        lock.unlock()
        XCTAssertNil(result)
        let initSegmentURL = outputDirectory.appending(path: "init.mp4")
        XCTAssertTrue(FileManager.default.fileExists(atPath: initSegmentURL.path))
        let playlist = try String(
            contentsOf: outputDirectory.appending(path: "playlist.m3u8"),
            encoding: .utf8
        )
        XCTAssertTrue(playlist.contains(#"#EXT-X-MAP:URI="init.mp4""#))
        let initSegment = try Data(contentsOf: initSegmentURL)
        XCTAssertNotNil(initSegment.range(of: Data("avc1".utf8)))
        XCTAssertNotNil(initSegment.range(of: Data("fLaC".utf8)))
        try assertGeneratedFLACPacket(
            outputDirectory: outputDirectory,
            initSegment: initSegment
        )
    }

    private func fixtureURL() throws -> URL {
        try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "delayed_truehd_probe",
                withExtension: "mkv"
            ),
            "Missing delayed_truehd_probe.mkv from SiloTests resources"
        )
    }

    private func cappedProbeAudioFormat(_ url: URL) throws -> Int32 {
        var formatContext: UnsafeMutablePointer<AVFormatContext>?
        var options: OpaquePointer?
        av_dict_set(&options, "analyzeduration", "500000", 0)
        av_dict_set(&options, "probesize", "1000000", 0)
        defer {
            av_dict_free(&options)
            avformat_close_input(&formatContext)
        }

        XCTAssertEqual(avformat_open_input(&formatContext, url.path, nil, &options), 0)
        let context = try XCTUnwrap(formatContext)
        XCTAssertGreaterThanOrEqual(avformat_find_stream_info(context, nil), 0)

        for index in 0 ..< Int(context.pointee.nb_streams) {
            guard let stream = context.pointee.streams[index],
                  let parameters = stream.pointee.codecpar,
                  parameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO else {
                continue
            }
            XCTAssertEqual(parameters.pointee.codec_id, AV_CODEC_ID_TRUEHD)
            return parameters.pointee.format
        }
        XCTFail("TrueHD audio stream missing from fixture")
        return AV_SAMPLE_FMT_NONE.rawValue
    }

    private func assertGeneratedFLACPacket(
        outputDirectory: URL,
        initSegment: Data
    ) throws {
        let mediaSegments = try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "m4s" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        XCTAssertFalse(mediaSegments.isEmpty)

        var fragmentedMP4 = initSegment
        for segment in mediaSegments {
            fragmentedMP4.append(try Data(contentsOf: segment))
        }
        let assembledURL = outputDirectory.appending(path: "assembled.mp4")
        try fragmentedMP4.write(to: assembledURL)

        var formatContext: UnsafeMutablePointer<AVFormatContext>?
        defer { avformat_close_input(&formatContext) }
        XCTAssertEqual(avformat_open_input(&formatContext, assembledURL.path, nil, nil), 0)
        let context = try XCTUnwrap(formatContext)
        XCTAssertGreaterThanOrEqual(avformat_find_stream_info(context, nil), 0)

        let audioStreamIndex = try XCTUnwrap(
            (0 ..< Int(context.pointee.nb_streams)).first { index in
                guard let parameters = context.pointee.streams[index]?.pointee.codecpar else {
                    return false
                }
                return parameters.pointee.codec_type == AVMEDIA_TYPE_AUDIO
                    && parameters.pointee.codec_id == AV_CODEC_ID_FLAC
            },
            "Generated fMP4 is missing its FLAC audio stream"
        )
        let audioParameters = try XCTUnwrap(
            context.pointee.streams[audioStreamIndex]?.pointee.codecpar
        )
        let decoder = try XCTUnwrap(avcodec_find_decoder(AV_CODEC_ID_FLAC))
        var decoderContext = avcodec_alloc_context3(decoder)
        defer { avcodec_free_context(&decoderContext) }
        let codecContext = try XCTUnwrap(decoderContext)
        XCTAssertGreaterThanOrEqual(
            avcodec_parameters_to_context(codecContext, audioParameters),
            0
        )
        XCTAssertGreaterThanOrEqual(avcodec_open2(codecContext, decoder, nil), 0)

        var packet = av_packet_alloc()
        defer { av_packet_free(&packet) }
        let outputPacket = try XCTUnwrap(packet)
        var frame = av_frame_alloc()
        defer { av_frame_free(&frame) }
        let decodedFrame = try XCTUnwrap(frame)
        var decodedSampleCount: Int32 = 0
        while av_read_frame(context, outputPacket) >= 0 {
            if outputPacket.pointee.stream_index == Int32(audioStreamIndex),
               outputPacket.pointee.size > 0,
               avcodec_send_packet(codecContext, outputPacket) >= 0 {
                while avcodec_receive_frame(codecContext, decodedFrame) >= 0 {
                    decodedSampleCount += decodedFrame.pointee.nb_samples
                    av_frame_unref(decodedFrame)
                }
            }
            av_packet_unref(outputPacket)
        }
        XCTAssertGreaterThan(
            decodedSampleCount,
            0,
            "TrueHD bridge declared FLAC but emitted no decodable audio samples"
        )
    }

    private func makeSpec(sourceURL: URL) -> LoopbackSessionSpec {
        LoopbackSessionSpec(
            sourceURL: sourceURL,
            headers: [:],
            sourceBitrateBps: 12_000_000,
            videoMode: .passthroughH264,
            sourceVideoFrameRate: 24,
            selectedAudio: LoopbackSessionSpec.SelectedAudio(
                trackIndex: 0,
                ffIndex: 1,
                sourceCodec: "truehd",
                sourceChannelCount: 6,
                sourceChannelLayout: "5.1",
                outputMode: .requireFLAC,
                preservesAtmos: false
            ),
            availableAudioTracks: [],
            manifestMetadata: LoopbackSessionSpec.ManifestMetadata(
                advertisedDolbyVisionProfile: nil,
                compatibilityBrand: nil,
                videoRange: "SDR",
                mayClaimAtmos: false
            )
        )
    }
}
