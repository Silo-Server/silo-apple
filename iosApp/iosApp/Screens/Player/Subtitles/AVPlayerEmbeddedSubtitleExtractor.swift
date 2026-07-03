//
//  AVPlayerEmbeddedSubtitleExtractor.swift
//  Continuum
//
//  Subtitle-only FFmpeg extractor used by AVPlayer routes. AVPlayer keeps
//  owning media transport; this object opens the original media source in a
//  separate FFmpeg context, exposes embedded subtitle streams to the shared
//  picker, and feeds selected streams into SubtitleSession — text codecs go
//  through libass, bitmap codecs (PGS/DVD) are decoded to premultiplied-RGBA
//  cue images for the overlay's bitmap layer.
//

import Foundation
import Libavcodec
import Libavformat
import Libavutil
import OSLog

struct AVPlayerSubtitleExtractionSource: Hashable {
    let mediaURL: URL
    let requestHeaders: [String: String]
    let routeLabel: String
    let seekable: Bool
}

struct AVPlayerExtractedSubtitleTrack: Hashable {
    let streamIndex: Int32
    let trackId: Int64
    let title: String?
    let language: String?
    let codec: String?
    let isDefault: Bool
    let isForced: Bool
    let isHearingImpaired: Bool
    let isVisualImpaired: Bool

    func playerTrack(isSelected: Bool) -> PlayerTrack {
        PlayerTrack(
            trackId: trackId,
            kind: .sub,
            title: title,
            lang: language,
            codec: codec,
            audioChannelsLayout: nil,
            audioChannelCount: nil,
            bitrate: nil,
            isDefault: isDefault,
            isForced: isForced,
            isHearingImpaired: isHearingImpaired,
            isVisualImpaired: isVisualImpaired,
            isExternal: false,
            isSelected: isSelected,
            ffIndex: Int(streamIndex),
            srcId: Int(streamIndex)
        )
    }
}

final class AVPlayerEmbeddedSubtitleExtractor {
    private static let maxReadAheadSeconds: Double = 45

    private struct SlotSelection {
        let trackId: Int64
        let streamIndex: Int32
        let startSeconds: Double
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "AVPlayerEmbeddedSubtitleExtractor"
    )

    private let subtitleSession: SubtitleSession
    private let stateLock = NSLock()
    private var source: AVPlayerSubtitleExtractionSource?
    private var extractedTracks: [AVPlayerExtractedSubtitleTrack] = []
    private var activeSelections: [SubtitleSlot: SlotSelection] = [:]
    private var slotGenerations: [SubtitleSlot: UInt64] = [.primary: 0, .secondary: 0]
    private var probeGeneration: UInt64 = 0

    var currentMediaTimeProvider: (() -> Double)?
    var onTracksChanged: (([AVPlayerExtractedSubtitleTrack]) -> Void)?

    init(subtitleSession: SubtitleSession) {
        self.subtitleSession = subtitleSession
    }

    func configure(source newSource: AVPlayerSubtitleExtractionSource?) {
        stateLock.lock()
        source = newSource
        extractedTracks = []
        activeSelections.removeAll()
        probeGeneration &+= 1
        slotGenerations[.primary, default: 0] &+= 1
        slotGenerations[.secondary, default: 0] &+= 1
        let generation = probeGeneration
        let sourceSnapshot = source
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onTracksChanged?([])
        }

        guard let sourceSnapshot else { return }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.probe(source: sourceSnapshot, generation: generation)
        }
    }

    func playerTracks(selectedPrimaryTrackId: Int64?) -> [PlayerTrack] {
        stateLock.lock()
        let snapshot = extractedTracks
        stateLock.unlock()
        return snapshot.map { track in
            track.playerTrack(isSelected: track.trackId == selectedPrimaryTrackId)
        }
    }

    func canSelect(trackId: Int64) -> Bool {
        guard SubtitleTrackIdSpace.isAVPlayerEmbedded(trackId) else { return false }
        stateLock.lock()
        defer { stateLock.unlock() }
        return extractedTracks.contains { $0.trackId == trackId }
    }

    func select(trackId: Int64, slot: SubtitleSlot, startSeconds: Double) {
        guard SubtitleTrackIdSpace.isAVPlayerEmbedded(trackId) else { return }
        let streamIndex = SubtitleTrackIdSpace.avPlayerEmbeddedStreamIndex(from: trackId)

        stateLock.lock()
        guard let source else {
            stateLock.unlock()
            subtitleSession.closeSlot(slot)
            return
        }
        slotGenerations[slot, default: 0] &+= 1
        let generation = slotGenerations[slot, default: 0]
        let selection = SlotSelection(
            trackId: trackId,
            streamIndex: streamIndex,
            startSeconds: max(0, startSeconds - 5)
        )
        activeSelections[slot] = selection
        stateLock.unlock()

        Self.logger.info(
            "[CMP-SUB] AVPlayer embedded select slot=\(slot.rawValue, privacy: .public) stream=\(streamIndex, privacy: .public) start=\(selection.startSeconds, privacy: .public)"
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.decode(
                source: source,
                selection: selection,
                slot: slot,
                generation: generation
            )
        }
    }

    func clear(slot: SubtitleSlot) {
        stateLock.lock()
        activeSelections.removeValue(forKey: slot)
        slotGenerations[slot, default: 0] &+= 1
        stateLock.unlock()
        subtitleSession.closeSlot(slot)
    }

    func seek(to mediaSeconds: Double) {
        stateLock.lock()
        let selections = activeSelections
        stateLock.unlock()
        for (slot, selection) in selections {
            select(trackId: selection.trackId, slot: slot, startSeconds: mediaSeconds)
        }
    }

    func teardown() {
        stateLock.lock()
        source = nil
        extractedTracks = []
        activeSelections.removeAll()
        probeGeneration &+= 1
        slotGenerations[.primary, default: 0] &+= 1
        slotGenerations[.secondary, default: 0] &+= 1
        stateLock.unlock()
    }

    private func probe(source: AVPlayerSubtitleExtractionSource, generation: UInt64) {
        do {
            let ctx = try openFormatContext(source: source)
            defer { closeFormatContext(ctx) }
            try readStreamInfo(ctx)
            registerEmbeddedFonts(from: ctx)

            let tracks = subtitleTracks(in: ctx)
            guard isProbeGenerationCurrent(generation) else { return }

            stateLock.lock()
            extractedTracks = tracks
            stateLock.unlock()

            Self.logger.info(
                "[CMP-SUB] AVPlayer embedded probe route=\(source.routeLabel, privacy: .public) tracks=\(tracks.count, privacy: .public)"
            )
            DispatchQueue.main.async { [weak self] in
                self?.onTracksChanged?(tracks)
            }
        } catch {
            guard isProbeGenerationCurrent(generation) else { return }
            Self.logger.info(
                "[CMP-SUB] AVPlayer embedded probe unavailable route=\(source.routeLabel, privacy: .public) error=\(String(describing: error), privacy: .public)"
            )
        }
    }

    private func decode(
        source: AVPlayerSubtitleExtractionSource,
        selection: SlotSelection,
        slot: SubtitleSlot,
        generation: UInt64
    ) {
        do {
            let ctx = try openFormatContext(source: source)
            defer { closeFormatContext(ctx) }
            try readStreamInfo(ctx)
            guard isSlotGenerationCurrent(slot: slot, generation: generation) else { return }

            registerEmbeddedFonts(from: ctx)
            if source.seekable, selection.startSeconds > 0 {
                let ts = Int64(selection.startSeconds * Double(AV_TIME_BASE))
                if avformat_seek_file(ctx, -1, Int64.min, ts, Int64.max, AVSEEK_FLAG_BACKWARD) < 0 {
                    _ = avformat_seek_file(ctx, -1, Int64.min, ts, Int64.max, 0)
                }
            }

            guard let decoder = openSubtitleDecoder(
                formatCtx: ctx,
                streamIndex: selection.streamIndex,
                slot: slot
            ) else {
                if isSlotGenerationCurrent(slot: slot, generation: generation) {
                    subtitleSession.closeSlot(slot)
                }
                return
            }
            var codecCtx: UnsafeMutablePointer<AVCodecContext>? = decoder.codecCtx
            defer { avcodec_free_context(&codecCtx) }

            guard isSlotGenerationCurrent(slot: slot, generation: generation) else { return }
            readPackets(
                formatCtx: ctx,
                decoder: decoder,
                streamIndex: selection.streamIndex,
                slot: slot,
                generation: generation
            )
        } catch {
            if isSlotGenerationCurrent(slot: slot, generation: generation) {
                Self.logger.warning(
                    "[CMP-SUB] AVPlayer embedded decode failed slot=\(slot.rawValue, privacy: .public) stream=\(selection.streamIndex, privacy: .public) error=\(String(describing: error), privacy: .public)"
                )
                subtitleSession.closeSlot(slot)
            }
        }
    }

    /// Everything the decode loop needs about an opened subtitle decoder.
    private struct OpenedSubtitleDecoder {
        let codecCtx: UnsafeMutablePointer<AVCodecContext>
        let timeBase: AVRational
        let isBitmap: Bool
        /// Container video dimensions, used as the subtitle-canvas
        /// fallback when the codec context doesn't report one (0 when the
        /// container has no usable video track header).
        let fallbackCanvasWidth: Int32
        let fallbackCanvasHeight: Int32
    }

    private func openSubtitleDecoder(
        formatCtx: UnsafeMutablePointer<AVFormatContext>,
        streamIndex: Int32,
        slot: SubtitleSlot
    ) -> OpenedSubtitleDecoder? {
        guard streamIndex >= 0,
              streamIndex < Int32(formatCtx.pointee.nb_streams),
              let stream = formatCtx.pointee.streams?[Int(streamIndex)],
              let codecparPtr = stream.pointee.codecpar,
              codecparPtr.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE,
              let codec = avcodec_find_decoder(codecparPtr.pointee.codec_id)
        else { return nil }

        var ctx = avcodec_alloc_context3(codec)
        guard ctx != nil else { return nil }
        if avcodec_parameters_to_context(ctx, codecparPtr) < 0 {
            avcodec_free_context(&ctx)
            return nil
        }

        let isBitmap = Self.isBitmapSubtitleCodec(codecparPtr.pointee.codec_id)
        var fallbackCanvas: (width: Int32, height: Int32) = (0, 0)
        if isBitmap {
            // Bitmap decoders position rects against a canvas the probe
            // can't always derive from the track header (dvd_subtitle
            // especially). Seed the codec context from the container's
            // video dimensions so normalized geometry has a denominator
            // before the first in-band composition update arrives.
            fallbackCanvas = Self.containerVideoDimensions(in: formatCtx)
            if ctx!.pointee.width == 0 { ctx!.pointee.width = fallbackCanvas.width }
            if ctx!.pointee.height == 0 { ctx!.pointee.height = fallbackCanvas.height }
        }

        if avcodec_open2(ctx, codec, nil) < 0 {
            avcodec_free_context(&ctx)
            return nil
        }

        if isBitmap {
            subtitleSession.openBitmapTrack(slot: slot)
        } else {
            let codecpar = codecparPtr.pointee
            let isNativeASS = codecpar.codec_id == AV_CODEC_ID_ASS
                || codecpar.codec_id == AV_CODEC_ID_SSA
            let headerPtr: UnsafePointer<UInt8>?
            let headerSize: Int
            if let sh = ctx?.pointee.subtitle_header,
               ctx!.pointee.subtitle_header_size > 0 {
                headerPtr = UnsafePointer(sh)
                headerSize = Int(ctx!.pointee.subtitle_header_size)
            } else {
                headerPtr = codecpar.extradata.map { UnsafePointer($0) }
                headerSize = Int(codecpar.extradata_size)
            }
            subtitleSession.openEmbedded(
                slot: slot,
                isNativeASS: isNativeASS,
                extradata: headerPtr,
                extradataSize: headerSize
            )
        }
        Self.logger.info(
            "[CMP-SUB] AVPlayer embedded decoder opened slot=\(slot.rawValue, privacy: .public) stream=\(streamIndex, privacy: .public) bitmap=\(isBitmap, privacy: .public)"
        )
        return ctx.map {
            OpenedSubtitleDecoder(
                codecCtx: $0,
                timeBase: stream.pointee.time_base,
                isBitmap: isBitmap,
                fallbackCanvasWidth: fallbackCanvas.width,
                fallbackCanvasHeight: fallbackCanvas.height
            )
        }
    }

    /// First usable video track dimensions from the container header.
    /// Video streams are AVDISCARD_ALL during probing, but their codecpar
    /// width/height come from the container header and remain readable.
    private static func containerVideoDimensions(
        in ctx: UnsafeMutablePointer<AVFormatContext>
    ) -> (width: Int32, height: Int32) {
        let nb = Int(ctx.pointee.nb_streams)
        guard let streams = ctx.pointee.streams else { return (0, 0) }
        for i in 0..<nb {
            guard let stream = streams[i],
                  let codecparPtr = stream.pointee.codecpar else { continue }
            let codecpar = codecparPtr.pointee
            if codecpar.codec_type == AVMEDIA_TYPE_VIDEO,
               codecpar.width > 0, codecpar.height > 0 {
                return (codecpar.width, codecpar.height)
            }
        }
        return (0, 0)
    }

    private func readPackets(
        formatCtx: UnsafeMutablePointer<AVFormatContext>,
        decoder: OpenedSubtitleDecoder,
        streamIndex: Int32,
        slot: SubtitleSlot,
        generation: UInt64
    ) {
        guard let pkt = av_packet_alloc() else { return }
        defer {
            var packet: UnsafeMutablePointer<AVPacket>? = pkt
            av_packet_free(&packet)
        }

        while isSlotGenerationCurrent(slot: slot, generation: generation) {
            let r = av_read_frame(formatCtx, pkt)
            guard r >= 0 else { break }
            defer { av_packet_unref(pkt) }
            guard pkt.pointee.stream_index == streamIndex else { continue }
            throttleIfNeeded(
                packetStartSeconds: packetStartSeconds(pkt, timeBase: decoder.timeBase),
                slot: slot,
                generation: generation
            )
            guard isSlotGenerationCurrent(slot: slot, generation: generation) else { break }
            decodeSubtitlePacket(
                pkt,
                decoder: decoder,
                slot: slot,
                generation: generation
            )
        }
    }

    private func throttleIfNeeded(packetStartSeconds: Double, slot: SubtitleSlot, generation: UInt64) {
        guard packetStartSeconds.isFinite else { return }
        while isSlotGenerationCurrent(slot: slot, generation: generation) {
            let liveSeconds = currentMediaTimeProvider?() ?? packetStartSeconds
            guard liveSeconds.isFinite else { return }
            let secondsAhead = packetStartSeconds - liveSeconds
            guard secondsAhead > Self.maxReadAheadSeconds else { return }
            Thread.sleep(forTimeInterval: min(0.5, max(0.05, secondsAhead - Self.maxReadAheadSeconds)))
        }
    }

    private func packetStartSeconds(_ pkt: UnsafeMutablePointer<AVPacket>, timeBase: AVRational) -> Double {
        let noPts = Int64.min
        let ptsRaw: Int64 = pkt.pointee.pts != noPts ? pkt.pointee.pts
            : (pkt.pointee.dts != noPts ? pkt.pointee.dts : 0)
        return Double(ptsRaw) * Double(timeBase.num) / Double(timeBase.den)
    }

    private func decodeSubtitlePacket(
        _ pkt: UnsafeMutablePointer<AVPacket>,
        decoder: OpenedSubtitleDecoder,
        slot: SubtitleSlot,
        generation: UInt64
    ) {
        let codecCtx = decoder.codecCtx
        let timeBase = decoder.timeBase
        var sub = AVSubtitle()
        defer { avsubtitle_free(&sub) }
        var gotSubtitle: Int32 = 0
        let r = avcodec_decode_subtitle2(codecCtx, &sub, &gotSubtitle, pkt)

        let isPGS = codecCtx.pointee.codec_id == AV_CODEC_ID_HDMV_PGS_SUBTITLE
        if r >= 0, gotSubtitle == 0, isPGS, pkt.pointee.size > 30 {
            // Some Matroska remuxes drop the PGS display-set END segment,
            // leaving the decoder accumulating forever with nothing
            // emitted. Push a minimal synthetic END segment at the same
            // timestamps to flush the pending composition. Only attempted
            // for substantial packets — tiny ones ARE end/control segments.
            flushPendingPGSComposition(
                codecCtx: codecCtx,
                timedLike: pkt,
                into: &sub,
                gotSubtitle: &gotSubtitle
            )
        }
        guard r >= 0, gotSubtitle != 0 else { return }
        guard isSlotGenerationCurrent(slot: slot, generation: generation) else { return }

        let basePtsSeconds = packetStartSeconds(pkt, timeBase: timeBase)
        let startMs = Int64((basePtsSeconds + Double(sub.start_display_time) / 1000.0) * 1000.0)
        let endMs: Int64 = {
            if sub.end_display_time != UInt32.max,
               sub.end_display_time > sub.start_display_time {
                return Int64((basePtsSeconds + Double(sub.end_display_time) / 1000.0) * 1000.0)
            }
            if pkt.pointee.duration > 0 {
                let durSeconds = Double(pkt.pointee.duration) * Double(timeBase.num) / Double(timeBase.den)
                return startMs + Int64(durSeconds * 1000.0)
            }
            // No explicit end anywhere. PGS relies on the next composition
            // trimming this cue (see `feedBitmapCues(trimActiveAt:)`); 5 s
            // is only the ceiling if the stream goes quiet.
            return startMs + 5000
        }()
        let durationMs = max(Int64(0), endMs - startMs)
        let startSeconds = Double(startMs) / 1000.0
        let endSeconds = Double(endMs) / 1000.0

        var bitmapCues: [BitmapSubtitleCue] = []
        for i in 0..<Int(sub.num_rects) {
            guard isSlotGenerationCurrent(slot: slot, generation: generation),
                  let rect = sub.rects[i]?.pointee else { continue }
            if rect.type == SUBTITLE_BITMAP {
                if let cue = bitmapCue(
                    from: rect,
                    decoder: decoder,
                    startSeconds: startSeconds,
                    endSeconds: endSeconds
                ) {
                    bitmapCues.append(cue)
                }
                continue
            }
            guard let assPtr = rect.ass else { continue }
            let ass = String(cString: assPtr)
            guard !ass.isEmpty else { continue }
            subtitleSession.feedEmbedded(
                slot: slot,
                eventText: ass,
                startMs: startMs,
                durationMs: durationMs
            )
        }

        if decoder.isBitmap {
            if isPGS {
                // Every PGS composition — including an empty clear event —
                // supersedes whatever is on screen, so the feed always
                // carries the trim timestamp even when no cue decoded.
                subtitleSession.feedBitmapCues(
                    slot: slot,
                    cues: bitmapCues,
                    trimActiveAt: startSeconds
                )
            } else if !bitmapCues.isEmpty {
                // DVD subs carry explicit durations; empty events mean
                // nothing and are dropped.
                subtitleSession.feedBitmapCues(
                    slot: slot,
                    cues: bitmapCues,
                    trimActiveAt: nil
                )
            }
        }
    }

    /// Feed a synthetic 3-byte PGS END segment (type 0x80, zero payload
    /// length; zero-padded for decoder over-read safety) carrying the
    /// original packet's timestamps, so an accumulated display set whose
    /// END segment was lost in remuxing still emits.
    private func flushPendingPGSComposition(
        codecCtx: UnsafeMutablePointer<AVCodecContext>,
        timedLike pkt: UnsafeMutablePointer<AVPacket>,
        into sub: inout AVSubtitle,
        gotSubtitle: inout Int32
    ) {
        var payload = [UInt8](repeating: 0, count: 64)
        payload[0] = 0x80
        payload.withUnsafeMutableBufferPointer { buffer in
            var synthetic = AVPacket()
            synthetic.data = buffer.baseAddress
            synthetic.size = 3
            synthetic.pts = pkt.pointee.pts
            synthetic.dts = pkt.pointee.dts
            synthetic.duration = pkt.pointee.duration
            synthetic.stream_index = pkt.pointee.stream_index
            _ = avcodec_decode_subtitle2(codecCtx, &sub, &gotSubtitle, &synthetic)
        }
    }

    /// Convert one decoded bitmap rect into an overlay cue: paletted plane
    /// → premultiplied RGBA (cropped to the opaque bounding box) → CGImage
    /// positioned as a normalized rect against the subtitle canvas.
    private func bitmapCue(
        from rect: AVSubtitleRect,
        decoder: OpenedSubtitleDecoder,
        startSeconds: Double,
        endSeconds: Double
    ) -> BitmapSubtitleCue? {
        guard rect.w > 0, rect.h > 0,
              let indexPlane = rect.data.0,
              let palette = rect.data.1
        else { return nil }
        guard let plane = BitmapSubtitlePalette.premultipliedRGBA(
            indexPlane: indexPlane,
            width: Int(rect.w),
            height: Int(rect.h),
            stride: Int(rect.linesize.0),
            palette: palette
        ), let image = BitmapSubtitlePalette.makeImage(from: plane) else { return nil }

        // Canvas: PGS composition updates land in the codec context as
        // decoding progresses; fall back to the container video dimensions
        // seeded at open. If both are unknown, park the cue in a generic
        // centered lower band rather than dropping it.
        let ctx = decoder.codecCtx.pointee
        let canvasWidth = ctx.width > 0 ? ctx.width : decoder.fallbackCanvasWidth
        let canvasHeight = ctx.height > 0 ? ctx.height : decoder.fallbackCanvasHeight
        let normalizedFrame: CGRect
        if canvasWidth > 0, canvasHeight > 0 {
            normalizedFrame = CGRect(
                x: Double(Int(rect.x) + plane.cropX) / Double(canvasWidth),
                y: Double(Int(rect.y) + plane.cropY) / Double(canvasHeight),
                width: Double(plane.cropWidth) / Double(canvasWidth),
                height: Double(plane.cropHeight) / Double(canvasHeight)
            )
        } else {
            normalizedFrame = CGRect(x: 0.2, y: 0.78, width: 0.6, height: 0.15)
        }
        return BitmapSubtitleCue(
            startSeconds: startSeconds,
            endSeconds: endSeconds,
            image: image,
            normalizedFrame: normalizedFrame
        )
    }

    private func subtitleTracks(in ctx: UnsafeMutablePointer<AVFormatContext>) -> [AVPlayerExtractedSubtitleTrack] {
        let nb = Int(ctx.pointee.nb_streams)
        let streams = ctx.pointee.streams
        var tracks: [AVPlayerExtractedSubtitleTrack] = []
        for i in 0..<nb {
            guard let stream = streams?[i],
                  let codecparPtr = stream.pointee.codecpar,
                  codecparPtr.pointee.codec_type == AVMEDIA_TYPE_SUBTITLE else { continue }
            let codecID = codecparPtr.pointee.codec_id
            guard Self.isRenderableSubtitleCodec(codecID) else { continue }
            let streamIndex = Int32(i)
            let disposition = stream.pointee.disposition
            let title = metadataValue(stream.pointee.metadata, key: "title")
            let dispositionHearingImpaired = (disposition & AV_DISPOSITION_HEARING_IMPAIRED) != 0
            let dispositionVisualImpaired = (disposition & AV_DISPOSITION_VISUAL_IMPAIRED) != 0
            // Some sources don't set the FFmpeg disposition flags but
            // include "[CC]" / "(SDH)" / "(closed captions)" / "for the
            // hearing impaired" hints in the title. Use a conservative
            // case-insensitive substring match so we don't surface SDH
            // tracks as plain text to users who explicitly disable SDH.
            let titleSDHHint: Bool = {
                guard let lower = title?.lowercased() else { return false }
                return lower.contains("sdh")
                    || lower.contains("hearing impaired")
                    || lower.contains("[cc]")
                    || lower.contains("closed caption")
            }()
            tracks.append(AVPlayerExtractedSubtitleTrack(
                streamIndex: streamIndex,
                trackId: SubtitleTrackIdSpace.makeAVPlayerEmbeddedTrackId(streamIndex: streamIndex),
                title: title,
                language: metadataValue(stream.pointee.metadata, key: "language"),
                codec: codecName(for: codecID),
                isDefault: (disposition & AV_DISPOSITION_DEFAULT) != 0,
                isForced: (disposition & AV_DISPOSITION_FORCED) != 0,
                isHearingImpaired: dispositionHearingImpaired || titleSDHHint,
                isVisualImpaired: dispositionVisualImpaired
            ))
        }
        return tracks
    }

    private static func isRenderableSubtitleCodec(_ codecID: AVCodecID) -> Bool {
        codecID == AV_CODEC_ID_ASS
            || codecID == AV_CODEC_ID_SSA
            || codecID == AV_CODEC_ID_SUBRIP
            || codecID == AV_CODEC_ID_WEBVTT
            || codecID == AV_CODEC_ID_MOV_TEXT
            || isBitmapSubtitleCodec(codecID)
    }

    /// Bitmap codecs we decode client-side into RGBA overlay cues. DVB is
    /// deliberately excluded: its region/CLUT model is broadcast-oriented
    /// and unvalidated here, so DVB tracks keep the burn-in fallback.
    static func isBitmapSubtitleCodec(_ codecID: AVCodecID) -> Bool {
        codecID == AV_CODEC_ID_HDMV_PGS_SUBTITLE
            || codecID == AV_CODEC_ID_DVD_SUBTITLE
    }

    private func registerEmbeddedFonts(from ctx: UnsafeMutablePointer<AVFormatContext>) {
        let nb = Int(ctx.pointee.nb_streams)
        let streams = ctx.pointee.streams
        for i in 0..<nb {
            guard let stream = streams?[i],
                  let codecparPtr = stream.pointee.codecpar else { continue }
            let codecpar = codecparPtr.pointee
            guard codecpar.codec_type == AVMEDIA_TYPE_ATTACHMENT,
                  codecpar.extradata_size > 0,
                  let ed = codecpar.extradata else { continue }

            var isFontMime = false
            var filename = "embedded_font_\(i)"
            if let mime = metadataValue(stream.pointee.metadata, key: "mimetype")?.lowercased(),
               mime.contains("font") || mime.contains("truetype") || mime.contains("opentype") {
                isFontMime = true
            }
            if let name = metadataValue(stream.pointee.metadata, key: "filename"), !name.isEmpty {
                filename = name
            }
            let codecId = codecpar.codec_id.rawValue
            let isFontCodec = codecId == 98_305 || codecId == 98_320
            guard isFontMime || isFontCodec else { continue }

            let data = Data(bytes: ed, count: Int(codecpar.extradata_size))
            subtitleSession.registerEmbeddedFont(name: filename, data: data)
        }
    }

    private func openFormatContext(source: AVPlayerSubtitleExtractionSource) throws -> UnsafeMutablePointer<AVFormatContext> {
        guard let ctx = avformat_alloc_context() else {
            throw ExtractionError.openFailed("avformat_alloc_context failed")
        }
        var optCtx: UnsafeMutablePointer<AVFormatContext>? = ctx
        var options: OpaquePointer?
        if !source.requestHeaders.isEmpty {
            let joined = source.requestHeaders
                .sorted(by: { $0.key < $1.key })
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\r\n") + "\r\n"
            av_dict_set(&options, "headers", joined, 0)
        }
        av_dict_set(&options, "reconnect", "1", 0)
        av_dict_set(&options, "reconnect_streamed", "1", 0)
        av_dict_set(&options, "reconnect_delay_max", "5", 0)
        av_dict_set(&options, "rw_timeout", "10000000", 0)
        av_dict_set(&options, "stimeout", "10000000", 0)
        // Bound the find_stream_info probe. We only render the codecs in
        // `isRenderableSubtitleCodec` (text: ASS/SSA/SRT/WebVTT/MovText;
        // bitmap: PGS/DVD, whose codec params come from container track
        // headers); everything else is discarded after open. Without
        // these caps, a multi-track MKV makes ffmpeg read up to
        // `probesize` (5 MiB default) per unsolvable stream looking for
        // codec params, which costs seconds on 4K loopback resume seeks
        // where we open the source twice (writer + this extractor).
        av_dict_set(&options, "analyzeduration", "500000", 0) // 500 ms
        av_dict_set(&options, "probesize", "1000000", 0)      // 1 MiB

        let location = source.mediaURL.isFileURL ? source.mediaURL.path : source.mediaURL.absoluteString
        let openResult = location.withCString { cString in
            avformat_open_input(&optCtx, cString, nil, &options)
        }
        av_dict_free(&options)
        guard openResult == 0, let opened = optCtx else {
            throw ExtractionError.openFailed(ffmpegError(openResult))
        }
        return opened
    }

    private func closeFormatContext(_ ctx: UnsafeMutablePointer<AVFormatContext>) {
        var context: UnsafeMutablePointer<AVFormatContext>? = ctx
        avformat_close_input(&context)
    }

    private func readStreamInfo(_ ctx: UnsafeMutablePointer<AVFormatContext>) throws {
        // Discard non-renderable streams BEFORE find_stream_info so ffmpeg
        // doesn't burn the per-stream `probesize` budget hunting codec
        // params for streams we'll never decode. We only render subtitle
        // codecs, and we don't need video/audio codec params at all in
        // this extractor — its only consumer is the subtitle decoder.
        // (Bitmap canvas fallbacks read the video dimensions straight from
        // the container track header, which survives the discard.)
        Self.discardNonRenderableSubtitleStreams(in: ctx)

        let result = avformat_find_stream_info(ctx, nil)
        guard result >= 0 else {
            throw ExtractionError.streamInfoFailed(ffmpegError(result))
        }
    }

    @discardableResult
    private static func discardNonRenderableSubtitleStreams(
        in ctx: UnsafeMutablePointer<AVFormatContext>
    ) -> Int {
        let nb = Int(ctx.pointee.nb_streams)
        var keptRenderable = 0
        var discardedSubs = 0
        var discardedOther = 0
        if let streams = ctx.pointee.streams {
            for i in 0..<nb {
                guard let stream = streams[i] else { continue }
                let codecpar = stream.pointee.codecpar.pointee
                if codecpar.codec_type == AVMEDIA_TYPE_SUBTITLE,
                   isRenderableSubtitleCodec(codecpar.codec_id) {
                    // Leave AVDISCARD_DEFAULT in place so the probe pulls
                    // just enough header data to enumerate the track.
                    keptRenderable += 1
                    continue
                }
                stream.pointee.discard = AVDISCARD_ALL
                if codecpar.codec_type == AVMEDIA_TYPE_SUBTITLE {
                    discardedSubs += 1
                } else {
                    discardedOther += 1
                }
            }
        }
        cmpLog("[CMP-SUB] extractor probe filter total=\(nb) kept=\(keptRenderable) discardedSubs=\(discardedSubs) discardedOther=\(discardedOther)")
        return discardedSubs
    }

    private func isProbeGenerationCurrent(_ generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == probeGeneration && source != nil
    }

    private func isSlotGenerationCurrent(slot: SubtitleSlot, generation: UInt64) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return generation == slotGenerations[slot, default: 0] && source != nil
    }

    private func metadataValue(_ dict: OpaquePointer?, key: String) -> String? {
        guard let entry = av_dict_get(dict, key, nil, 0),
              let value = entry.pointee.value else { return nil }
        let string = String(cString: value).trimmingCharacters(in: .whitespacesAndNewlines)
        return string.isEmpty ? nil : string
    }

    private func codecName(for codecID: AVCodecID) -> String? {
        if let descriptor = avcodec_descriptor_get(codecID),
           let name = descriptor.pointee.name {
            let value = String(cString: name).trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        let raw = String(cString: avcodec_get_name(codecID)).trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty || raw == "unknown_codec" ? nil : raw
    }

    private func ffmpegError(_ code: Int32) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        av_strerror(code, &buffer, buffer.count)
        return String(cString: buffer)
    }

    private enum ExtractionError: Error, CustomStringConvertible {
        case openFailed(String)
        case streamInfoFailed(String)

        var description: String {
            switch self {
            case .openFailed(let message):
                return "open failed: \(message)"
            case .streamInfoFailed(let message):
                return "stream info failed: \(message)"
            }
        }
    }
}
