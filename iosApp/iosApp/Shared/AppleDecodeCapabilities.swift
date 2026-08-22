import Foundation

/// What this Apple client can actually decode, stated once.
///
/// Playback and download surfaces report the same underlying stack using
/// different wire shapes: V3 can describe every detailed decoder, while the
/// legacy portion of download creation must remain hardware-only so an older
/// server that ignores additive decoder evidence fails safely. The codec and
/// container vocabulary still lives here so spelling cannot drift silently.
///
/// What differs between surfaces is policy and evidence shape, kept at the
/// call site where its safety reason can be stated. Only the underlying "the
/// stack can open this" vocabulary is shared.
enum AppleDecodeCapabilities {
    #if targetEnvironment(simulator)
    static let isSimulator = true
    #else
    static let isSimulator = false
    #endif

    /// Video codecs the pinned media stack has exercised end to end. H.264
    /// includes the software High-10 path; MPEG-2 includes the interlaced path.
    /// The remaining non-Apple codecs are bounded software claims in the V3
    /// snapshot rather than pretending VideoToolbox supplied them.
    static let softwareVideoCodecs = ["av1", "vp9", "mpeg2video", "vc1"]
    static let videoCodecs: [String] = (isSimulator ? ["h264"] : ["h264", "hevc"])
        + softwareVideoCodecs

    /// The subset of `videoCodecs` VideoToolbox decodes in hardware.
    static let hardwareVideoCodecs: [String] = isSimulator ? ["h264"] : ["h264", "hevc"]

    /// Server-packaged progressive/HLS routes remain on their native codec
    /// vocabulary. The software claims above describe Aether's original-file
    /// path and must not silently broaden a receiver/native-HLS contract.
    static let packagedVideoCodecs = hardwareVideoCodecs

    /// Audio codecs the client decodes. The simulator keeps the conservative
    /// subset it was aligned to alongside its H.264-only video claim, rather
    /// than the device's full list.
    static let audioCodecs: [String] = isSimulator
        ? ["aac", "ac3", "eac3", "mp3", "opus", "flac"]
        : [
            "aac", "ac3", "eac3", "dts", "truehd", "flac", "alac", "mp3",
            "opus", "vorbis", "pcm", "pcm_s16le", "pcm_s24le"
        ]

    /// Video containers the client demuxes. Both spellings of the two aliased
    /// ones (`mkv`/`matroska`, `ts`/`mpegts`) are listed: the server sends
    /// whichever its scanner recorded, and a claim it cannot match reads as
    /// "unsupported".
    static let videoContainers: [String] = isSimulator
        ? ["mp4", "mov", "m4v", "mkv", "matroska", "ts", "m2ts", "mpegts"]
        : ["mp4", "mov", "m4v", "mkv", "matroska", "webm", "avi", "ts", "m2ts", "mpegts"]

    /// Bare audio containers proven by the first Aether-only Silo fixture
    /// matrix. The scanner currently normalizes M4A/M4B to `mp4`, but the
    /// aliases remain honest for legacy metadata and future scanner changes.
    ///
    /// Aether supports additional containers, including Ogg. They stay out of
    /// this server-facing flat vocabulary until Silo has exercised every
    /// codec/container pairing that the cross-product would authorize.
    static let audioContainers = ["mp3", "m4a", "m4b", "aac", "flac", "wav"]

    /// The full direct-play container vocabulary used by flat capability
    /// surfaces and by the `original_http` V3 delivery.
    static let containers = videoContainers + audioContainers

    /// The resolution ceiling to claim, or nil for "no client-imposed cap".
    /// The simulator renders at 1080p; on device the ceiling is the display
    /// pipeline's own, which the flat caps leave unstated.
    static let maxResolution: String? = isSimulator ? "1080p" : nil

    /// `maxResolution` for surfaces that need it spelled out rather than left
    /// open — the V3 snapshot's per-codec decode entries pair it with
    /// explicit pixel dimensions, so "no cap" has nothing to mean there.
    static let maxResolutionToken: String = maxResolution ?? "2160p"

    static let maxDecodeWidth: Int = isSimulator ? 1_920 : 3_840
    static let maxDecodeHeight: Int = isSimulator ? 1_080 : 2_160
}
