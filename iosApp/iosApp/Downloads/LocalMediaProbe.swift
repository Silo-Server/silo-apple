import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Reads the video parameters route planning needs straight out of a
/// downloaded file.
///
/// Online these arrive on the catalog's `FileVersion`: the server probed the
/// file and shipped `video_tracks`. The offline manifest carries no video
/// track at all, so without this a downloaded Dolby Vision file plans as plain
/// HEVC and silently loses DV, and the loopback route cannot work out its HLS
/// `VIDEO-RANGE` because `transferKind` has no `color_transfer` to read.
///
/// Probing the delivered file is also the more truthful source offline. A
/// transcoded download is a *different file* from the one the catalog
/// describes — it may have had its DV RPU stripped or been re-encoded — so
/// catalog metadata would over-claim. This reports what is actually on disk,
/// which makes the transcode case correct by construction rather than by
/// special-casing it.
enum LocalMediaProbe {
    /// Probe cost is on the path to first frame, and routing only needs the
    /// stream header, so keep the scan short. Matches the caps
    /// `LoopbackSegmentWriter` uses when it opens the same file moments later.
    private static let analyzeDurationMicroseconds = "500000"
    private static let probeSizeBytes = "1000000"

    /// Every video stream in the file, in stream order. Empty when the file
    /// cannot be opened or has no video — callers treat that as "no metadata",
    /// which lands on exactly the behavior that existed before probing.
    ///
    /// Synchronous and blocking: it opens a file and runs a header scan. Call
    /// it off the main actor.
    static func videoTracks(at url: URL) -> [VideoTrack] {
        var options: OpaquePointer?
        av_dict_set(&options, "analyzeduration", analyzeDurationMicroseconds, 0)
        av_dict_set(&options, "probesize", probeSizeBytes, 0)

        // FFmpeg's `file` protocol takes a raw filesystem path and does NOT
        // percent-decode, so a downloads directory under "Application Support"
        // only resolves via `path`, never `absoluteString`.
        var ctx: UnsafeMutablePointer<AVFormatContext>?
        let opened = avformat_open_input(&ctx, url.path, nil, &options)
        av_dict_free(&options)
        guard opened == 0, let ctx else { return [] }
        defer {
            var closing: UnsafeMutablePointer<AVFormatContext>? = ctx
            avformat_close_input(&closing)
        }

        // The Dolby Vision configuration record reaches `coded_side_data` only
        // once the stream info scan has run, so this is not optional here.
        guard avformat_find_stream_info(ctx, nil) >= 0 else { return [] }

        var tracks: [VideoTrack] = []
        for index in 0..<Int(ctx.pointee.nb_streams) {
            guard let stream = ctx.pointee.streams?[index] else { continue }
            let codecpar = stream.pointee.codecpar.pointee
            guard codecpar.codec_type == AVMEDIA_TYPE_VIDEO else { continue }
            // Cover art and thumbnails ride in video streams; they are not the
            // presentation video and must not be mistaken for it.
            guard stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0 else { continue }

            let dolbyVision = DolbyVisionFormat.readConfig(stream: stream, codecpar: codecpar)
            tracks.append(VideoTrack(
                index: index,
                codec: codecName(codecpar.codec_id),
                width: codecpar.width > 0 ? Int(codecpar.width) : nil,
                height: codecpar.height > 0 ? Int(codecpar.height) : nil,
                frameRate: frameRateToken(stream.pointee.avg_frame_rate),
                bitrate: codecpar.bit_rate > 0 ? Int(codecpar.bit_rate) : nil,
                profile: nil,
                level: codecpar.level > 0 ? Int(codecpar.level) : nil,
                bitDepth: bitDepth(of: codecpar),
                colorRange: VideoColorMetadata.colorRangeName(codecpar.color_range),
                colorTransfer: enumName(av_color_transfer_name(codecpar.color_trc)),
                // Deliberately nil. `video_range` is the server's higher-level
                // roll-up, and `transferKind` only falls back to it when
                // `color_transfer` is missing — which it is not here. Deriving
                // our own would risk disagreeing with the server's vocabulary.
                videoRange: nil,
                // A bare profile number: `dolbyVisionProfile(from:)` parses
                // that first, and leaving it nil when no configuration record
                // is present is what keeps `versionHasDolbyVision` honest.
                dolbyVision: dolbyVision.map { String($0.profile) },
                title: nil,
                language: nil
            ))
        }
        return tracks
    }

    private static func codecName(_ id: AVCodecID) -> String? {
        enumName(avcodec_get_name(id))
    }

    private static func enumName(_ raw: UnsafePointer<CChar>?) -> String? {
        guard let raw else { return nil }
        let name = String(cString: raw)
        // FFmpeg returns these sentinels rather than null for unset values.
        guard !name.isEmpty, name != "unknown", name != "none", name != "reserved" else {
            return nil
        }
        return name
    }

    private static func bitDepth(of codecpar: AVCodecParameters) -> Int? {
        let format = AVPixelFormat(rawValue: codecpar.format)
        guard format != AV_PIX_FMT_NONE else { return nil }
        return Int(VideoColorMetadata.sourceBitDepth(format))
    }

    /// Decimal token matching the server's `frame_rate` spelling ("23.976"), so
    /// a probed track and a catalog track render identically.
    private static func frameRateToken(_ rate: AVRational) -> String? {
        guard rate.den > 0, rate.num > 0 else { return nil }
        let value = Double(rate.num) / Double(rate.den)
        guard value.isFinite, value > 0 else { return nil }
        return String(format: "%g", (value * 1000).rounded() / 1000)
    }
}
