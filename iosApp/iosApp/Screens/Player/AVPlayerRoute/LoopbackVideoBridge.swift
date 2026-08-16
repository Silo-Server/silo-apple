//
//  LoopbackVideoBridge.swift
//  Silo — AVPlayer loopback route
//
//  Software-decode → VideoToolbox-encode bridge for source video codecs the
//  loopback cannot remux (VP9, VP8, AV1 without hardware decode, MPEG-2,
//  MPEG-4 Part 2, MSMPEG4v3, VC-1, WMV3).
//
//  Why this shape:
//    - Both ends are FFmpeg `AVCodecContext`s, exactly like the audio bridge
//      in `LoopbackSegmentWriter`. That buys the muxer contract for free:
//      `avcodec_parameters_from_context` fills the output codecpar,
//      `AV_CODEC_FLAG_GLOBAL_HEADER` produces the `hvcC` / `avcC` the fMP4
//      init segment needs, and encoder output already carries
//      `AV_PKT_FLAG_KEY` — the single most load-bearing bit in the pipeline,
//      because it is what advances `LoopbackSegmentCutter` and what
//      `+frag_keyframe` cuts on.
//    - The encoder runs on the SOURCE stream's time base and the source PTS
//      rides through untouched, so an encoded packet is indistinguishable
//      from a copied one downstream: it goes through the very same
//      `routeVideoPacketToMux` → `rewritePacketForOutput` path, keeps the VOD
//      anchor shift, and lands on the plan's PTS axis.
//    - Segment boundaries are forced, not observed. Before each frame the
//      bridge checks whether its PTS crossed the next plan boundary and, if
//      so, stamps `AV_PICTURE_TYPE_I` + the key flag on the frame. Output
//      keyframes then land EXACTLY on plan boundaries and every cutter,
//      restart-gate, and naming-drift check works unmodified.
//
//  Threading:
//    Mux queue only. There is no worker thread and no callback thread — the
//    FFmpeg VideoToolbox encoder wrapper owns the `VTCompressionSession` and
//    hands packets back synchronously through `avcodec_receive_packet`.
//

import Foundation
import OSLog
import Libavcodec
import Libavformat
import Libavutil
import Libswscale

/// `AV_FRAME_FLAG_KEY`. FFmpeg spells it as an object-like macro over a shift
/// expression, which the Swift importer drops, so it is restated here.
private let avFrameFlagKey: Int32 = 1 << 1

final class LoopbackVideoBridge {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "LoopbackVideoBridge"
    )

    /// Whether an HEVC VideoToolbox encoder exists in this build at all.
    /// Read by the planner's capability probe; a missing HEVC encoder falls
    /// the bridge to H.264 rather than blocking the route.
    static var hevcEncoderAvailable: Bool {
        avcodec_find_encoder_by_name("hevc_videotoolbox") != nil
    }

    /// Whether ANY VideoToolbox encoder exists. False means the bridge cannot
    /// run on this build and the route must fall to server transcode.
    static var anyEncoderAvailable: Bool {
        hevcEncoderAvailable || avcodec_find_encoder_by_name("h264_videotoolbox") != nil
    }

    // MARK: - Configuration

    private let outputMode: LoopbackSessionSpec.VideoOutputMode
    private let targetSegmentDuration: Double
    private let sourceBitrateBps: Double?
    private let declaredFrameRate: Float?

    // MARK: - FFmpeg state (mux queue only)

    private var decoderCtx: UnsafeMutablePointer<AVCodecContext>?
    private var encoderCtx: UnsafeMutablePointer<AVCodecContext>?
    private var decodedFrame: UnsafeMutablePointer<AVFrame>?
    private var scaledFrame: UnsafeMutablePointer<AVFrame>?
    private var swsCtx: OpaquePointer?
    private var sourceTimeBase = AVRational(num: 1, den: 90_000)

    /// The encoder's `hvcC` / `avcC`, captured at open (the FFmpeg
    /// VideoToolbox wrapper synthesizes parameter sets during
    /// `avcodec_open2` when the global-header flag is set) or from the first
    /// encoded packet. Installed on the output codecpar before `writeHeader`.
    private(set) var parameterSets: Data?
    /// The RFC 6381 sample entry the muxer must stamp: `hvc1` or `avc1`.
    private(set) var sampleEntryCodec = "hvc1"
    private(set) var outputCodecID: AVCodecID = AV_CODEC_ID_NONE
    private(set) var encodedFrameCount = 0
    private(set) var decodedFrameCount = 0

    // MARK: - Keyframe scheduling

    /// Source-PTS fences the encoder must open a keyframe on, ascending.
    /// Empty means "no plan": the bridge then synthesizes a uniform stride
    /// from `targetSegmentDuration`, which is what the EVENT path needs.
    private var keyframeBoundaries: [Int64] = []
    private var nextBoundaryIndex = 0
    private var syntheticNextKeyframePTS: Int64?
    /// Frames below this PTS are decoded but never encoded — a restarted
    /// producer must decode from the source keyframe preceding its boundary
    /// while emitting nothing before the boundary itself.
    private var emitThresholdPTS: Int64?
    private(set) var hasOpenedEmitGate = true
    private var lastFramePTS: Int64?

    // MARK: - Throughput watchdog

    /// Wall-clock seconds spent INSIDE the bridge. Measured here rather than
    /// against the mux loop's clock because the producer legitimately parks
    /// for minutes in `waitForVODWindowIfNeeded`, which would otherwise read
    /// as a stalled encoder.
    private var encodeWallSeconds: Double = 0
    private var firstEmittedPTS: Int64?
    private var lastEmittedPTS: Int64?
    private static let watchdogMinimumWallSeconds: Double = 10
    private static let watchdogMinimumRealtimeRatio: Double = 1.1

    init(
        outputMode: LoopbackSessionSpec.VideoOutputMode,
        targetSegmentDuration: Double,
        sourceBitrateBps: Double?,
        declaredFrameRate: Float?
    ) {
        self.outputMode = outputMode
        self.targetSegmentDuration = max(0.5, targetSegmentDuration)
        self.sourceBitrateBps = sourceBitrateBps
        self.declaredFrameRate = declaredFrameRate
    }

    // MARK: - Setup

    /// Opens the decoder/encoder pair and fills the already-allocated output
    /// stream's codecpar from the ENCODER (never from the source). The output
    /// stream keeps the source time base so downstream timestamp handling is
    /// byte-for-byte the copy path's.
    func open(
        inputStream: UnsafeMutablePointer<AVStream>,
        outputStream: UnsafeMutablePointer<AVStream>,
        outputFormat: UnsafePointer<AVOutputFormat>?
    ) throws {
        guard let codecpar = inputStream.pointee.codecpar else {
            throw LoopbackWriterError.videoTranscodeSetup("video source has no codec parameters")
        }
        sourceTimeBase = inputStream.pointee.time_base
        if sourceTimeBase.num <= 0 || sourceTimeBase.den <= 0 {
            sourceTimeBase = AVRational(num: 1, den: 90_000)
        }

        try openDecoder(codecpar: codecpar)
        let width = codecpar.pointee.width
        let height = codecpar.pointee.height
        guard width > 0, height > 0 else {
            throw LoopbackWriterError.videoTranscodeSetup("video source has no dimensions")
        }
        try openEncoder(
            width: width,
            height: height,
            sourceCodecpar: codecpar,
            outputFormat: outputFormat
        )

        outputStream.pointee.time_base = sourceTimeBase
        guard avcodec_parameters_from_context(outputStream.pointee.codecpar, encoderCtx) >= 0 else {
            throw LoopbackWriterError.videoTranscodeSetup("codecpar from video encoder failed")
        }
        outputStream.pointee.codecpar.pointee.codec_tag = 0

        let summary = "[CMP-AVP] video bridge open"
            + " source=\(String(cString: avcodec_get_name(codecpar.pointee.codec_id)))"
            + " output=\(sampleEntryCodec)"
            + " size=\(width)x\(height)"
            + " bitrate=\(encoderCtx?.pointee.bit_rate ?? 0)"
            + " gop=\(encoderCtx?.pointee.gop_size ?? 0)"
            + " parameterSets=\(parameterSets?.count ?? 0)"
        cmpLog(summary)
    }

    private func openDecoder(codecpar: UnsafeMutablePointer<AVCodecParameters>) throws {
        let codecID = codecpar.pointee.codec_id
        // libdav1d is dramatically faster than FFmpeg's native AV1 decoder and
        // is a hard dependency of the vendored product, so name it explicitly.
        let decoder = codecID == AV_CODEC_ID_AV1
            ? (avcodec_find_decoder_by_name("libdav1d") ?? avcodec_find_decoder(codecID))
            : avcodec_find_decoder(codecID)
        guard let decoder else {
            let name = String(cString: avcodec_get_name(codecID))
            throw LoopbackWriterError.videoTranscodeSetup("video decoder unavailable for \(name)")
        }

        var ctx = avcodec_alloc_context3(decoder)
        guard ctx != nil else {
            throw LoopbackWriterError.videoTranscodeSetup("video decoder alloc failed")
        }
        if avcodec_parameters_to_context(ctx, codecpar) < 0 {
            avcodec_free_context(&ctx)
            throw LoopbackWriterError.videoTranscodeSetup("video decoder parameters failed")
        }
        // Same threading budget `PlayerCore.setupSoftwareVideoDecoder` tuned:
        // software decode must not starve the audio bridge, the ISO box
        // splitter, and the segment file writes that share this thread.
        ctx!.pointee.thread_count = Int32(min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 6))
        ctx!.pointee.thread_type = FF_THREAD_FRAME | FF_THREAD_SLICE
        if avcodec_open2(ctx, decoder, nil) < 0 {
            avcodec_free_context(&ctx)
            throw LoopbackWriterError.videoTranscodeSetup("video decoder open failed")
        }
        decoderCtx = ctx
    }

    private func openEncoder(
        width: Int32,
        height: Int32,
        sourceCodecpar: UnsafeMutablePointer<AVCodecParameters>,
        outputFormat: UnsafePointer<AVOutputFormat>?
    ) throws {
        var lastError = "no encoder candidates"
        for candidate in encoderCandidates() {
            guard let encoder = avcodec_find_encoder_by_name(candidate.name) else {
                lastError = "encoder missing \(candidate.name)"
                continue
            }
            var ctx = avcodec_alloc_context3(encoder)
            guard ctx != nil else {
                lastError = "encoder alloc failed \(candidate.name)"
                continue
            }

            ctx!.pointee.width = width
            ctx!.pointee.height = height
            ctx!.pointee.pix_fmt = AV_PIX_FMT_NV12
            // Encoder time base == source time base: the source PTS then
            // survives the round trip exactly, with no rational rounding, and
            // the output stream can keep riding the source clock.
            ctx!.pointee.time_base = sourceTimeBase
            let fps = effectiveFrameRate()
            ctx!.pointee.framerate = AVRational(num: Int32((fps * 1000).rounded()), den: 1000)
            // No B-frames: PTS == DTS on every encoded sample, which keeps the
            // look-behind duration telescoping, the monotonic-DTS normalizer,
            // and the missing-DTS repair path entirely out of the picture.
            ctx!.pointee.max_b_frames = 0
            ctx!.pointee.has_b_frames = 0
            ctx!.pointee.gop_size = Int32(max(1, (targetSegmentDuration * fps).rounded(.up)))
            ctx!.pointee.bit_rate = targetBitRate(width: width, height: height)
            ctx!.pointee.rc_max_rate = ctx!.pointee.bit_rate * 3 / 2
            ctx!.pointee.color_range = sourceCodecpar.pointee.color_range == AVCOL_RANGE_UNSPECIFIED
                ? AVCOL_RANGE_MPEG
                : sourceCodecpar.pointee.color_range
            ctx!.pointee.color_primaries = sourceCodecpar.pointee.color_primaries == AVCOL_PRI_UNSPECIFIED
                ? AVCOL_PRI_BT709
                : sourceCodecpar.pointee.color_primaries
            ctx!.pointee.color_trc = sourceCodecpar.pointee.color_trc == AVCOL_TRC_UNSPECIFIED
                ? AVCOL_TRC_BT709
                : sourceCodecpar.pointee.color_trc
            ctx!.pointee.colorspace = sourceCodecpar.pointee.color_space == AVCOL_SPC_UNSPECIFIED
                ? AVCOL_SPC_BT709
                : sourceCodecpar.pointee.color_space
            if let outputFormat, (outputFormat.pointee.flags & AVFMT_GLOBALHEADER) != 0 {
                // Makes the wrapper publish `hvcC`/`avcC` as extradata instead
                // of inlining parameter sets, which is what `moov` needs.
                ctx!.pointee.flags |= AV_CODEC_FLAG_GLOBAL_HEADER
            }
            applyVideoToolboxOptions(ctx!)

            let rc = avcodec_open2(ctx, encoder, nil)
            if rc < 0 {
                lastError = "encoder open failed \(candidate.name) rc=\(rc)"
                avcodec_free_context(&ctx)
                continue
            }

            encoderCtx = ctx
            outputCodecID = candidate.codecID
            sampleEntryCodec = candidate.sampleEntry
            if let extradata = ctx!.pointee.extradata, ctx!.pointee.extradata_size > 0 {
                parameterSets = Data(bytes: extradata, count: Int(ctx!.pointee.extradata_size))
            }
            return
        }
        throw LoopbackWriterError.videoTranscodeSetup(lastError)
    }

    /// Encoder ladder. `.transcodeHEVC` keeps H.264 as the fallback so a
    /// device (or simulator) without an HEVC encoder still bridges rather
    /// than dropping the whole route to server transcode.
    private func encoderCandidates() -> [(name: String, codecID: AVCodecID, sampleEntry: String)] {
        switch outputMode {
        case .transcodeH264:
            return [("h264_videotoolbox", AV_CODEC_ID_H264, "avc1")]
        case .transcodeHEVC, .copy, .passthroughAV1:
            return [
                ("hevc_videotoolbox", AV_CODEC_ID_HEVC, "hvc1"),
                ("h264_videotoolbox", AV_CODEC_ID_H264, "avc1"),
            ]
        }
    }

    /// VideoToolbox-wrapper private options. All best-effort: a build whose
    /// wrapper lacks one of them must still open.
    ///
    /// - `allow_sw` keeps the simulator (and any device without the hardware
    ///   encoder for this codec) working instead of failing to open.
    /// - `realtime=0` because the producer deliberately runs AHEAD of the
    ///   playhead under the VOD window throttle; latency is not the scarce
    ///   resource, quality-per-bit is.
    /// - `prio_speed=1` trades a little quality for thermal headroom, which
    ///   matters on Apple TV where software decode already occupies the core.
    private func applyVideoToolboxOptions(_ ctx: UnsafeMutablePointer<AVCodecContext>) {
        guard let priv = ctx.pointee.priv_data else { return }
        _ = av_opt_set(priv, "allow_sw", "1", 0)
        _ = av_opt_set(priv, "realtime", "0", 0)
        _ = av_opt_set(priv, "prio_speed", "1", 0)
    }

    private func effectiveFrameRate() -> Double {
        if let declaredFrameRate, declaredFrameRate > 0, declaredFrameRate < 1000 {
            return Double(declaredFrameRate)
        }
        return 24.0
    }

    /// HEVC target bitrate by resolution, ×1.6 for H.264, clamped to 1.2× the
    /// source's own average so a 900 kbps 1080p web rip is not re-encoded to
    /// 6 Mbps and blown through the generated-ahead and spill budgets.
    private func targetBitRate(width: Int32, height: Int32) -> Int64 {
        let longEdge = Int(max(width, height))
        let hevcTarget: Int64 = switch longEdge {
        case ..<641: 1_000_000
        case ..<1281: 3_000_000
        case ..<1921: 6_000_000
        case ..<2561: 10_000_000
        default: 18_000_000
        }
        let base = outputCodecIDIsH264 ? Int64(Double(hevcTarget) * 1.6) : hevcTarget
        guard let sourceBitrateBps, sourceBitrateBps.isFinite, sourceBitrateBps > 0 else {
            return base
        }
        return max(400_000, min(base, Int64(sourceBitrateBps * 1.2)))
    }

    private var outputCodecIDIsH264: Bool {
        outputMode == .transcodeH264
    }

    // MARK: - Keyframe / emit scheduling

    /// Installs the plan's boundaries (source PTS ticks) so the encoder can be
    /// forced to open a keyframe exactly on each one, and the restart gate
    /// that discards encoder input before the session's anchor boundary.
    ///
    /// - Parameters:
    ///   - boundaries: ascending source-PTS fences from the session's anchor
    ///     segment onward. Pass an empty array for EVENT sessions.
    ///   - emitThresholdPTS: nil for a head-of-stream session. For a restart,
    ///     the anchor boundary: frames below it are decoded (the decoder needs
    ///     the preceding source keyframe) but never encoded.
    func installPlan(boundaries: [Int64], emitThresholdPTS: Int64?) {
        keyframeBoundaries = boundaries
        nextBoundaryIndex = 0
        self.emitThresholdPTS = emitThresholdPTS
        hasOpenedEmitGate = emitThresholdPTS == nil
    }

    /// Whether `pts` opens a new segment and therefore has to be an IDR.
    /// Advances the schedule, so it must be called exactly once per encoded
    /// frame and in PTS order (guaranteed: B-frames are off, so decode order
    /// is presentation order).
    private func consumeForcedKeyframe(pts: Int64) -> Bool {
        if !keyframeBoundaries.isEmpty {
            var forced = false
            while nextBoundaryIndex < keyframeBoundaries.count,
                  pts >= keyframeBoundaries[nextBoundaryIndex] {
                nextBoundaryIndex += 1
                forced = true
            }
            return forced
        }
        // EVENT sessions have no plan: synthesize a uniform stride anchored at
        // the first encoded frame so `+frag_keyframe` still cuts on cadence.
        let stride = max(
            1,
            Int64((targetSegmentDuration * Double(sourceTimeBase.den) / Double(sourceTimeBase.num)).rounded())
        )
        guard let next = syntheticNextKeyframePTS else {
            syntheticNextKeyframePTS = pts + stride
            return true
        }
        guard pts >= next else { return false }
        var advanced = next
        while pts >= advanced { advanced += stride }
        syntheticNextKeyframePTS = advanced
        return true
    }

    // MARK: - Per-packet path

    /// Decode one source packet and encode every frame it yields. Encoded
    /// packets are handed to `sink` in presentation order with
    /// `stream_index` already set to `inputStreamIndex`, so the caller can
    /// route them through the ordinary copy-path plumbing.
    ///
    /// `emitEncodedPackets: false` decodes without encoding — the pre-roll
    /// mode a restarted producer uses to warm the decoder ahead of its anchor
    /// boundary, mirroring the audio bridge's `emitDecodedFrames: false`.
    func transcodePacket(
        _ pkt: UnsafeMutablePointer<AVPacket>?,
        inputStreamIndex: Int,
        emitEncodedPackets: Bool = true,
        sink: (UnsafeMutablePointer<AVPacket>) throws -> Void
    ) throws {
        guard let decoderCtx else { return }
        let started = CFAbsoluteTimeGetCurrent()
        defer { encodeWallSeconds += CFAbsoluteTimeGetCurrent() - started }

        let sendR = avcodec_send_packet(decoderCtx, pkt)
        // AVERROR(EAGAIN) means the decoder is full; the receive loop below
        // drains it and the packet is retried by the caller's next read. A
        // hard decode error is counted, not thrown: a damaged GOP must not
        // fail the whole session.
        if sendR < 0, sendR != -Int32(EAGAIN) {
            noteDecodeError(stage: "send", rc: sendR)
        }
        try drainDecoder(inputStreamIndex: inputStreamIndex, emitEncodedPackets: emitEncodedPackets, sink: sink)
        try checkThroughput()
    }

    private func drainDecoder(
        inputStreamIndex: Int,
        emitEncodedPackets: Bool,
        sink: (UnsafeMutablePointer<AVPacket>) throws -> Void
    ) throws {
        guard let decoderCtx else { return }
        let frame = try reusableDecodedFrame()
        while true {
            let recvR = avcodec_receive_frame(decoderCtx, frame)
            if recvR == -Int32(EAGAIN) || recvR == Self.avErrorEOF {
                return
            }
            if recvR < 0 {
                noteDecodeError(stage: "receive", rc: recvR)
                return
            }
            decodedFrameCount += 1
            if emitEncodedPackets {
                try encodeDecodedFrame(frame, inputStreamIndex: inputStreamIndex, sink: sink)
            }
            av_frame_unref(frame)
        }
    }

    private func encodeDecodedFrame(
        _ frame: UnsafeMutablePointer<AVFrame>,
        inputStreamIndex: Int,
        sink: (UnsafeMutablePointer<AVPacket>) throws -> Void
    ) throws {
        var pts = frame.pointee.best_effort_timestamp
        if pts == Int64.min { pts = frame.pointee.pts }
        if pts == Int64.min {
            // No usable timestamp: synthesize from the previous frame plus one
            // frame period rather than dropping, so a container with sparse
            // timestamps does not punch holes in the output.
            let step = max(
                1,
                Int64((Double(sourceTimeBase.den) / Double(sourceTimeBase.num) / effectiveFrameRate()).rounded())
            )
            pts = (lastFramePTS ?? 0) + step
        }
        lastFramePTS = pts

        if let threshold = emitThresholdPTS, pts < threshold {
            // Restart pre-roll: decoded for reference, never encoded.
            return
        }
        hasOpenedEmitGate = true

        let converted = try convertedFrame(from: frame)
        converted.pointee.pts = pts
        if consumeForcedKeyframe(pts: pts) {
            // Forcing the picture type is what makes the encoder's keyframes
            // land ON the plan boundaries instead of wherever its own GOP
            // cadence happens to fall.
            converted.pointee.pict_type = AV_PICTURE_TYPE_I
            converted.pointee.flags |= avFrameFlagKey
        } else {
            converted.pointee.pict_type = AV_PICTURE_TYPE_NONE
            converted.pointee.flags &= ~avFrameFlagKey
        }

        guard let encoderCtx else { return }
        let sendR = avcodec_send_frame(encoderCtx, converted)
        if sendR < 0, sendR != -Int32(EAGAIN) {
            throw LoopbackWriterError.videoTranscodeSetup("video encoder send failed rc=\(sendR)")
        }
        try drainEncoder(inputStreamIndex: inputStreamIndex, sink: sink)
    }

    private func drainEncoder(
        inputStreamIndex: Int,
        sink: (UnsafeMutablePointer<AVPacket>) throws -> Void
    ) throws {
        guard let encoderCtx else { return }
        while true {
            var packet = av_packet_alloc()
            guard let encoded = packet else {
                throw LoopbackWriterError.allocPacket
            }
            let recvR = avcodec_receive_packet(encoderCtx, encoded)
            if recvR == -Int32(EAGAIN) || recvR == Self.avErrorEOF {
                av_packet_free(&packet)
                return
            }
            if recvR < 0 {
                av_packet_free(&packet)
                throw LoopbackWriterError.videoTranscodeSetup("video encoder receive failed rc=\(recvR)")
            }
            captureParameterSetsIfNeeded()
            encoded.pointee.stream_index = Int32(inputStreamIndex)
            if encoded.pointee.dts == Int64.min {
                encoded.pointee.dts = encoded.pointee.pts
            }
            encodedFrameCount += 1
            if encoded.pointee.pts != Int64.min {
                if firstEmittedPTS == nil { firstEmittedPTS = encoded.pointee.pts }
                lastEmittedPTS = encoded.pointee.pts
            }
            do {
                try sink(encoded)
            } catch {
                av_packet_free(&packet)
                throw error
            }
            av_packet_free(&packet)
        }
    }

    /// A record shaped like the first bytes of an `hvcC` / `avcC` so the
    /// writer's existing RFC 6381 builders can read profile / tier / level off
    /// the ENCODER's output.
    ///
    /// FFmpeg's VideoToolbox wrappers publish extradata as **Annex-B parameter
    /// sets**, not as an ISO configuration record — `movenc` converts them on
    /// the way into `moov`, so `init.mp4` is correct, but parsing those bytes
    /// as `hvcC` yields a nonsense `hvc1.0.….L0` CODECS string that AVPlayer's
    /// master-variant filter drops. An HEVC SPS carries `profile_tier_level`
    /// at byte 3, in exactly the layout `hvcC` bytes 1…12 use; an H.264 SPS
    /// carries profile / compatibility / level at bytes 1…3, matching `avcC`.
    /// So the prefix is synthesized from the SPS.
    var codecStringHeader: Data? {
        guard let parameterSets, !parameterSets.isEmpty else { return nil }
        let isHEVC = outputCodecID == AV_CODEC_ID_HEVC
        guard Self.isAnnexB(parameterSets) else { return parameterSets }
        guard let sps = Self.firstAnnexBNAL(in: parameterSets, isHEVC: isHEVC, nalType: isHEVC ? 33 : 7) else {
            return nil
        }
        if isHEVC {
            guard sps.count >= 15 else { return nil }
            return Data([0x01]) + Data(sps[3..<15])
        }
        guard sps.count >= 4 else { return nil }
        return Data([0x01]) + Data(sps[1..<4])
    }

    private static func isAnnexB(_ data: Data) -> Bool {
        let bytes = Array(data.prefix(4))
        if bytes.count >= 4, bytes[0] == 0, bytes[1] == 0, bytes[2] == 0, bytes[3] == 1 { return true }
        if bytes.count >= 3, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1 { return true }
        return false
    }

    private static func firstAnnexBNAL(in data: Data, isHEVC: Bool, nalType: UInt8) -> [UInt8]? {
        let bytes = Array(data)
        var starts: [Int] = []
        var index = 0
        while index + 3 <= bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0 {
                if index + 3 < bytes.count, bytes[index + 2] == 0, bytes[index + 3] == 1 {
                    starts.append(index + 4)
                    index += 4
                    continue
                }
                if bytes[index + 2] == 1 {
                    starts.append(index + 3)
                    index += 3
                    continue
                }
            }
            index += 1
        }
        for (position, start) in starts.enumerated() {
            guard start < bytes.count else { continue }
            let type: UInt8 = isHEVC ? ((bytes[start] >> 1) & 0x3F) : (bytes[start] & 0x1F)
            guard type == nalType else { continue }
            // The NAL ends where the next start code begins; the trailing
            // start-code prefix (3 or 4 bytes) is excluded by walking back
            // from the next payload offset.
            let end: Int
            if position + 1 < starts.count {
                let nextStart = starts[position + 1]
                end = max(start, nextStart - (nextStart >= 4 && bytes[nextStart - 4] == 0 ? 4 : 3))
            } else {
                end = bytes.count
            }
            return removingEmulationPrevention(Array(bytes[start..<end]))
        }
        return nil
    }

    /// Strips `0x03` emulation-prevention bytes. Load-bearing here: an HEVC
    /// SPS for a Main-profile stream carries six zero constraint bytes right
    /// before `general_level_idc`, so the escape lands inside the very field
    /// range the codec string is read from — without this the level parses as
    /// `L0` and AVPlayer's master-variant filter drops the variant.
    private static func removingEmulationPrevention(_ bytes: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var zeroRun = 0
        for byte in bytes {
            if zeroRun >= 2, byte == 0x03 {
                zeroRun = 0
                continue
            }
            output.append(byte)
            zeroRun = byte == 0 ? zeroRun + 1 : 0
        }
        return output
    }

    private func captureParameterSetsIfNeeded() {
        guard parameterSets == nil,
              let ctx = encoderCtx,
              let extradata = ctx.pointee.extradata,
              ctx.pointee.extradata_size > 0 else { return }
        parameterSets = Data(bytes: extradata, count: Int(ctx.pointee.extradata_size))
    }

    private func convertedFrame(from source: UnsafeMutablePointer<AVFrame>) throws -> UnsafeMutablePointer<AVFrame> {
        guard let encoderCtx else {
            throw LoopbackWriterError.videoTranscodeSetup("video encoder missing")
        }
        let sourceFormat = AVPixelFormat(rawValue: source.pointee.format)
        if swsCtx == nil {
            // SWS_POINT: dimensions never change (the bridge re-encodes, it
            // does not rescale), so this is a pure colour-space conversion and
            // an interpolating filter would only cost CPU.
            swsCtx = sws_getContext(
                source.pointee.width, source.pointee.height, sourceFormat,
                encoderCtx.pointee.width, encoderCtx.pointee.height, encoderCtx.pointee.pix_fmt,
                SWS_POINT, nil, nil, nil
            )
            guard swsCtx != nil else {
                throw LoopbackWriterError.videoTranscodeSetup("swscale context alloc failed")
            }
        }
        let target = try reusableScaledFrame()
        // Plane-pointer marshalling lifted from
        // `PlayerCore.makeHighBitDepthBiPlanarPixelBuffer`: the AVFrame's
        // fixed-size C tuples have to be rebound to Swift arrays before
        // swscale can take their base addresses.
        var srcData = withUnsafeBytes(of: source.pointee.data) { raw -> [UnsafePointer<UInt8>?] in
            raw.bindMemory(to: UnsafeMutablePointer<UInt8>?.self).map { $0.map { UnsafePointer($0) } }
        }
        var srcLinesize = withUnsafeBytes(of: source.pointee.linesize) { raw -> [Int32] in
            raw.bindMemory(to: Int32.self).map { $0 }
        }
        var dstData = withUnsafeBytes(of: target.pointee.data) { raw -> [UnsafeMutablePointer<UInt8>?] in
            raw.bindMemory(to: UnsafeMutablePointer<UInt8>?.self).map { $0 }
        }
        var dstLinesize = withUnsafeBytes(of: target.pointee.linesize) { raw -> [Int32] in
            raw.bindMemory(to: Int32.self).map { $0 }
        }
        let scaled = srcData.withUnsafeMutableBufferPointer { srcDataBP in
            srcLinesize.withUnsafeMutableBufferPointer { srcLineBP in
                dstData.withUnsafeMutableBufferPointer { dstDataBP in
                    dstLinesize.withUnsafeMutableBufferPointer { dstLineBP in
                        sws_scale(
                            swsCtx,
                            srcDataBP.baseAddress,
                            srcLineBP.baseAddress,
                            0,
                            source.pointee.height,
                            dstDataBP.baseAddress,
                            dstLineBP.baseAddress
                        )
                    }
                }
            }
        }
        guard scaled == source.pointee.height else {
            throw LoopbackWriterError.videoTranscodeSetup(
                "swscale produced \(scaled) rows, expected \(source.pointee.height)"
            )
        }
        target.pointee.color_range = encoderCtx.pointee.color_range
        target.pointee.color_primaries = encoderCtx.pointee.color_primaries
        target.pointee.color_trc = encoderCtx.pointee.color_trc
        target.pointee.colorspace = encoderCtx.pointee.colorspace
        return target
    }

    private func reusableDecodedFrame() throws -> UnsafeMutablePointer<AVFrame> {
        if let decodedFrame { return decodedFrame }
        guard let frame = av_frame_alloc() else {
            throw LoopbackWriterError.allocOutput
        }
        decodedFrame = frame
        return frame
    }

    /// One writable NV12 frame reused for every encode. `avcodec_send_frame`
    /// references the buffer rather than taking it, so the frame is re-made
    /// writable each time instead of being reallocated per picture.
    private func reusableScaledFrame() throws -> UnsafeMutablePointer<AVFrame> {
        guard let encoderCtx else {
            throw LoopbackWriterError.videoTranscodeSetup("video encoder missing")
        }
        if let scaledFrame {
            guard av_frame_make_writable(scaledFrame) >= 0 else {
                throw LoopbackWriterError.videoTranscodeSetup("scaled frame not writable")
            }
            return scaledFrame
        }
        guard let frame = av_frame_alloc() else {
            throw LoopbackWriterError.allocOutput
        }
        frame.pointee.format = encoderCtx.pointee.pix_fmt.rawValue
        frame.pointee.width = encoderCtx.pointee.width
        frame.pointee.height = encoderCtx.pointee.height
        guard av_frame_get_buffer(frame, 0) >= 0 else {
            var free: UnsafeMutablePointer<AVFrame>? = frame
            av_frame_free(&free)
            throw LoopbackWriterError.videoTranscodeSetup("scaled frame alloc failed")
        }
        scaledFrame = frame
        return frame
    }

    // MARK: - Flush

    /// Clean-EOF drain: decoder flush → encode the tail → encoder flush.
    /// Never called on cancellation — a cancelled session's tail is discarded,
    /// exactly like the audio bridge's.
    func finish(
        inputStreamIndex: Int,
        sink: (UnsafeMutablePointer<AVPacket>) throws -> Void
    ) throws {
        guard let decoderCtx, encoderCtx != nil else { return }
        _ = avcodec_send_packet(decoderCtx, nil)
        try drainDecoder(inputStreamIndex: inputStreamIndex, emitEncodedPackets: true, sink: sink)
        if let encoderCtx {
            _ = avcodec_send_frame(encoderCtx, nil)
        }
        try drainEncoder(inputStreamIndex: inputStreamIndex, sink: sink)
        if decodedFrameCount == 0 {
            throw LoopbackWriterError.videoTranscodeSetup("video decoder produced no frames")
        }
    }

    // MARK: - Watchdog

    /// Fails the session when sustained bridge throughput drops below
    /// ~1.1× realtime, so the route ladder falls to server HLS transcode
    /// instead of stuttering forever behind a too-slow software decode.
    private func checkThroughput() throws {
        guard encodeWallSeconds >= Self.watchdogMinimumWallSeconds,
              let first = firstEmittedPTS,
              let last = lastEmittedPTS,
              last > first else { return }
        let mediaSeconds = Double(last - first)
            * Double(sourceTimeBase.num)
            / Double(sourceTimeBase.den)
        let ratio = mediaSeconds / encodeWallSeconds
        guard ratio < Self.watchdogMinimumRealtimeRatio else { return }
        let achievedFPS = Double(encodedFrameCount) / encodeWallSeconds
        let requiredFPS = achievedFPS / max(ratio, 0.0001) * Self.watchdogMinimumRealtimeRatio
        let detail = String(
            format: "[CMP-AVP] video bridge too slow: %.1fs media in %.1fs wall (%.2fx realtime)",
            mediaSeconds, encodeWallSeconds, ratio
        )
        Self.logger.error("\(detail, privacy: .public)")
        throw LoopbackWriterError.videoBridgeTooSlow(fps: achievedFPS, required: requiredFPS)
    }

    private func noteDecodeError(stage: String, rc: Int32) {
        decodeErrorTotal += 1
        if decodeErrorTotal <= 5 {
            Self.logger.error(
                "[CMP-AVP] video bridge decode \(stage, privacy: .public) failed rc=\(rc, privacy: .public)"
            )
        }
    }

    private var decodeErrorTotal = 0

    // MARK: - Teardown

    func teardown() {
        if swsCtx != nil {
            sws_freeContext(swsCtx)
            swsCtx = nil
        }
        if scaledFrame != nil {
            av_frame_free(&scaledFrame)
        }
        if decodedFrame != nil {
            av_frame_free(&decodedFrame)
        }
        if encoderCtx != nil {
            avcodec_free_context(&encoderCtx)
        }
        if decoderCtx != nil {
            avcodec_free_context(&decoderCtx)
        }
    }

    private static let avErrorEOF = -Int32(bitPattern: 0x20464F45)
}
