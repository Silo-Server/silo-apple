import Libavcodec
import Libavformat
import Libavutil
import XCTest
@testable import Silo

/// Runs the real `LoopbackSegmentWriter` with the video bridge engaged over
/// committed non-copyable fixtures (VP9/WebM and MPEG-4 Part 2/AVI), and
/// checks the properties the rest of the pipeline depends on:
///
///  - the session finishes cleanly and produces media segments;
///  - `init.mp4` carries the ENCODER's codec, a non-empty `hvcC`/`avcC`, and
///    the matching `hvc1`/`avc1` sample entry;
///  - every segment's first video sample is a sync sample — the single most
///    load-bearing bit in the bridge, because `LoopbackSegmentCutter` and
///    `+frag_keyframe` both advance on `AV_PKT_FLAG_KEY` alone;
///  - the concatenated output decodes, i.e. the parameter sets in `init.mp4`
///    actually describe the samples in the segments.
///
/// Skipped when no VideoToolbox encoder can be opened, so a headless runner
/// degrades instead of failing.
final class LoopbackVideoBridgeWriterTests: XCTestCase {
    private struct Fixture {
        let resource: String
        let ext: String
    }

    private static let vp9 = Fixture(resource: "v3_vp9_opus", ext: "webm")
    private static let mpeg4 = Fixture(resource: "v3_mpeg4_mp3", ext: "avi")

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            Self.videoToolboxEncoderOpens(),
            "no VideoToolbox video encoder available in this environment"
        )
    }

    // MARK: - Environment probe

    /// Opens a throwaway encoder exactly the way the bridge does. A build
    /// without the VideoToolbox wrappers, or a host that refuses even the
    /// software fallback, skips the suite rather than failing it.
    private static func videoToolboxEncoderOpens() -> Bool {
        for name in ["hevc_videotoolbox", "h264_videotoolbox"] {
            guard let encoder = avcodec_find_encoder_by_name(name) else { continue }
            var ctx = avcodec_alloc_context3(encoder)
            guard ctx != nil else { continue }
            defer { avcodec_free_context(&ctx) }
            ctx!.pointee.width = 320
            ctx!.pointee.height = 240
            ctx!.pointee.pix_fmt = AV_PIX_FMT_NV12
            ctx!.pointee.time_base = AVRational(num: 1, den: 1000)
            ctx!.pointee.framerate = AVRational(num: 24, den: 1)
            ctx!.pointee.max_b_frames = 0
            if let priv = ctx!.pointee.priv_data {
                _ = av_opt_set(priv, "allow_sw", "1", 0)
                _ = av_opt_set(priv, "realtime", "0", 0)
            }
            if avcodec_open2(ctx, encoder, nil) >= 0 { return true }
        }
        return false
    }

    // MARK: - Harness

    private func fixtureURL(_ fixture: Fixture) throws -> URL {
        try XCTUnwrap(
            Bundle(for: Self.self).url(forResource: fixture.resource, withExtension: fixture.ext),
            "missing \(fixture.resource).\(fixture.ext) from SiloTests resources"
        )
    }

    private func makeSpec(
        sourceURL: URL,
        audioCodec: String,
        audioFfIndex: Int
    ) -> LoopbackSessionSpec {
        LoopbackSessionSpec(
            sourceURL: sourceURL,
            headers: [:],
            sourceStartTimeSeconds: 0,
            sourceBitrateBps: nil,
            videoMode: .passthroughHEVC,
            videoOutputMode: .transcodeHEVC,
            sourceVideoWidth: nil,
            sourceVideoHeight: nil,
            sourceVideoFrameRate: 24,
            selectedAudio: LoopbackSessionSpec.SelectedAudio(
                trackIndex: 0,
                ffIndex: audioFfIndex,
                sourceCodec: audioCodec,
                sourceChannelCount: 2,
                sourceChannelLayout: "stereo",
                outputMode: .transcodeAAC,
                preservesAtmos: false
            ),
            availableAudioTracks: [],
            manifestMetadata: LoopbackSessionSpec.ManifestMetadata(
                advertisedDolbyVisionProfile: nil,
                compatibilityBrand: nil,
                videoRange: "SDR",
                mayClaimAtmos: false
            ),
            servingMode: .vodPlan
        )
    }

    private struct WriterRun {
        let outputDirectory: URL
        let error: Error?
        let parameterSets: Data?
        let plan: LoopbackSegmentPlan?
    }

    private func runWriter(spec: LoopbackSessionSpec) -> WriterRun {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-bridge-\(UUID().uuidString)", isDirectory: true)
        let writer = LoopbackSegmentWriter(sessionSpec: spec, outputDirectory: dir)
        let lock = NSLock()
        var finishedError: Error?
        var parameterSets: Data?
        var plan: LoopbackSegmentPlan?
        let finished = expectation(description: "writer finished")
        writer.onBridgedVideoParameterSetsResolved = { data in
            lock.lock()
            parameterSets = data
            lock.unlock()
        }
        writer.onSegmentPlanResolved = { resolved in
            lock.lock()
            plan = resolved
            lock.unlock()
        }
        writer.onFinished = { error in
            lock.lock()
            finishedError = error
            lock.unlock()
            finished.fulfill()
        }
        writer.start()
        wait(for: [finished], timeout: 180)
        lock.lock()
        defer { lock.unlock() }
        return WriterRun(
            outputDirectory: dir,
            error: finishedError,
            parameterSets: parameterSets,
            plan: plan
        )
    }

    private func segmentNames(_ run: WriterRun) -> [String] {
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: run.outputDirectory.path)) ?? []
        return contents.filter { $0.hasPrefix("seg_") && $0.hasSuffix(".m4s") }.sorted()
    }

    // MARK: - FFmpeg assertions

    /// Opens an fMP4 byte stream from memory. `init.mp4` alone describes the
    /// tracks; `init.mp4 + segment` is a complete decodable movie.
    private func withDemuxer<T>(
        _ data: Data,
        _ body: (UnsafeMutablePointer<AVFormatContext>) throws -> T
    ) throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bridge-probe-\(UUID().uuidString).mp4")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        XCTAssertEqual(avformat_open_input(&ctx, url.path, nil, nil), 0, "open probe stream")
        defer { avformat_close_input(&ctx) }
        let context = try XCTUnwrap(ctx)
        XCTAssertGreaterThanOrEqual(avformat_find_stream_info(context, nil), 0)
        return try body(context)
    }

    private func videoStreamIndex(in ctx: UnsafeMutablePointer<AVFormatContext>) -> Int? {
        for index in 0 ..< Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams?[index],
                  let codecpar = stream.pointee.codecpar,
                  codecpar.pointee.codec_type == AVMEDIA_TYPE_VIDEO else { continue }
            return index
        }
        return nil
    }

    private func fourCC(_ tag: UInt32) -> String {
        String(
            bytes: [
                UInt8(tag & 0xFF),
                UInt8((tag >> 8) & 0xFF),
                UInt8((tag >> 16) & 0xFF),
                UInt8((tag >> 24) & 0xFF),
            ],
            encoding: .ascii
        ) ?? ""
    }

    private func decodesAtLeastOneVideoFrame(_ data: Data) throws -> Bool {
        try withDemuxer(data) { ctx in
            guard let index = videoStreamIndex(in: ctx),
                  let stream = ctx.pointee.streams?[index],
                  let codecpar = stream.pointee.codecpar,
                  let decoder = avcodec_find_decoder(codecpar.pointee.codec_id) else {
                return false
            }
            var decoderCtx = avcodec_alloc_context3(decoder)
            guard decoderCtx != nil else { return false }
            defer { avcodec_free_context(&decoderCtx) }
            guard avcodec_parameters_to_context(decoderCtx, codecpar) >= 0,
                  avcodec_open2(decoderCtx, decoder, nil) >= 0,
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
            while av_read_frame(ctx, packet) >= 0 {
                defer { av_packet_unref(packet) }
                guard packet.pointee.stream_index == Int32(index) else { continue }
                guard avcodec_send_packet(decoderCtx, packet) >= 0 else { continue }
                if avcodec_receive_frame(decoderCtx, frame) >= 0 { return true }
            }
            _ = avcodec_send_packet(decoderCtx, nil)
            return avcodec_receive_frame(decoderCtx, frame) >= 0
        }
    }

    /// True when the first video sample the demuxer reads out of this stream
    /// is flagged as a sync sample. FFmpeg derives the flag from the fragment's
    /// `trun`/`tfhd` sample flags, so this is a faithful read of what AVPlayer
    /// sees rather than a re-implementation of the box parsing.
    private func firstVideoSampleIsSync(_ data: Data) throws -> Bool {
        try withDemuxer(data) { ctx in
            guard let index = videoStreamIndex(in: ctx), let packet = av_packet_alloc() else {
                return false
            }
            defer {
                var packet: UnsafeMutablePointer<AVPacket>? = packet
                av_packet_free(&packet)
            }
            while av_read_frame(ctx, packet) >= 0 {
                defer { av_packet_unref(packet) }
                guard packet.pointee.stream_index == Int32(index) else { continue }
                return (packet.pointee.flags & AV_PKT_FLAG_KEY) != 0
            }
            return false
        }
    }

    // MARK: - Shared assertions

    private func assertBridgedOutput(
        _ run: WriterRun,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertNil(run.error, "writer failed: \(String(describing: run.error))", file: file, line: line)
        let segments = segmentNames(run)
        XCTAssertGreaterThanOrEqual(segments.count, 1, "no media segments produced", file: file, line: line)

        let initData = try Data(contentsOf: run.outputDirectory.appendingPathComponent("init.mp4"))
        XCTAssertFalse(initData.isEmpty, "init.mp4 is empty", file: file, line: line)

        // init.mp4 must describe the ENCODER's output, with real parameter
        // sets and the fMP4 sample entry AVPlayer keys its decoder off.
        try withDemuxer(initData) { ctx in
            let index = try XCTUnwrap(videoStreamIndex(in: ctx), file: file, line: line)
            let codecpar = try XCTUnwrap(ctx.pointee.streams?[index]?.pointee.codecpar, file: file, line: line)
            XCTAssertTrue(
                codecpar.pointee.codec_id == AV_CODEC_ID_HEVC || codecpar.pointee.codec_id == AV_CODEC_ID_H264,
                "unexpected bridged codec \(String(cString: avcodec_get_name(codecpar.pointee.codec_id)))",
                file: file,
                line: line
            )
            XCTAssertGreaterThan(codecpar.pointee.extradata_size, 0, "empty hvcC/avcC", file: file, line: line)
            let tag = fourCC(codecpar.pointee.codec_tag)
            XCTAssertTrue(["hvc1", "avc1"].contains(tag), "sample entry \(tag)", file: file, line: line)
        }

        XCTAssertNotNil(run.parameterSets, "parameter sets were never published", file: file, line: line)
        XCTAssertFalse(run.parameterSets?.isEmpty ?? true, file: file, line: line)

        // Every segment must open on a sync sample, or the cutter would never
        // advance and AVPlayer could not start there.
        var concatenated = initData
        for name in segments {
            let segment = try Data(contentsOf: run.outputDirectory.appendingPathComponent(name))
            XCTAssertFalse(segment.isEmpty, "\(name) is empty", file: file, line: line)
            XCTAssertTrue(
                try firstVideoSampleIsSync(initData + segment),
                "\(name) does not open on a sync sample",
                file: file,
                line: line
            )
            concatenated.append(segment)
        }

        XCTAssertTrue(
            try decodesAtLeastOneVideoFrame(concatenated),
            "bridged output is not self-consistently decodable",
            file: file,
            line: line
        )
    }

    // MARK: - Tests

    func testBridgesVP9WebmIntoDecodableHLSSegments() throws {
        let run = runWriter(
            spec: makeSpec(sourceURL: try fixtureURL(Self.vp9), audioCodec: "opus", audioFfIndex: 1)
        )
        try assertBridgedOutput(run)
    }

    func testBridgesMPEG4AVIIntoDecodableHLSSegments() throws {
        let run = runWriter(
            spec: makeSpec(sourceURL: try fixtureURL(Self.mpeg4), audioCodec: "mp3", audioFfIndex: 1)
        )
        try assertBridgedOutput(run)
    }

    func testBridgedPlanUsesAUniformStride() throws {
        let run = runWriter(
            spec: makeSpec(sourceURL: try fixtureURL(Self.vp9), audioCodec: "opus", audioFfIndex: 1)
        )
        XCTAssertNil(run.error)
        let plan = try XCTUnwrap(run.plan)
        XCTAssertFalse(
            plan.usedKeyframeIndex,
            "a bridged session must never plan against the SOURCE keyframe index"
        )
    }
}
