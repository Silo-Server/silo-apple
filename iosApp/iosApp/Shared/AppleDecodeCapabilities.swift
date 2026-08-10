import Foundation

/// What this Apple client can actually decode, stated once.
///
/// Three surfaces report decode capability to the server, and the server
/// plans deliveries against all of them: the V3 capability snapshot
/// (`ApplePlaybackV3Capabilities`), the playback bootstrap
/// (`PlaybackSessionBridge.makeClientCaps`), and download creation
/// (`DownloadCaps.current`). When their lists drift apart the same title is
/// planned differently depending on which door it came through, and nothing
/// fails loudly — ALAC sat in one list and not the other two until a review
/// caught it. So the vocabulary lives here.
///
/// What legitimately differs between the surfaces is *policy*, and that stays
/// at the call site where its reason can be written down: whether MPEG-2 is
/// claimed at all, whether this route claims HDR, and which codecs the
/// current output can take untouched. Only the underlying "the stack can open
/// this" lists are shared.
enum AppleDecodeCapabilities {
    #if targetEnvironment(simulator)
    static let isSimulator = true
    #else
    static let isSimulator = false
    #endif

    static let mpeg2VideoCodec = "mpeg2video"

    /// Video codecs the client decodes, without the opt-in MPEG-2 claim. The
    /// simulator has no video decoder beyond H.264, so it claims nothing
    /// else — a claim it cannot honor just moves the failure from the
    /// server's planner to a black screen here.
    static let videoCodecs: [String] = isSimulator ? ["h264"] : ["h264", "hevc"]

    /// The subset of `videoCodecs` VideoToolbox decodes in hardware. MPEG-2
    /// is never in it — its route is the software decoder.
    static let hardwareVideoCodecs: [String] = isSimulator ? ["h264"] : ["h264", "hevc"]

    /// Audio codecs the client decodes. The simulator keeps the conservative
    /// subset it was aligned to alongside its H.264-only video claim, rather
    /// than the device's full list.
    static let audioCodecs: [String] = isSimulator
        ? ["aac", "ac3", "eac3", "mp3", "opus", "flac"]
        : [
            "aac", "ac3", "eac3", "dts", "truehd", "flac", "alac", "mp3",
            "opus", "vorbis", "pcm", "pcm_s16le", "pcm_s24le"
        ]

    /// Containers the client demuxes. Both spellings of the two aliased ones
    /// (`mkv`/`matroska`, `ts`/`mpegts`) are listed: the server sends whichever
    /// its scanner recorded, and a claim it cannot match reads as "unsupported".
    static let containers: [String] = isSimulator
        ? ["mp4", "mov", "m4v", "mkv", "matroska", "ts", "m2ts", "mpegts"]
        : ["mp4", "mov", "m4v", "mkv", "matroska", "webm", "avi", "ts", "m2ts", "mpegts"]

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

    /// MPEG-2 is opt-in: PlayerCore decodes it in software, but the direct
    /// startup path does not, so a caller has to say it means the software
    /// route before the claim goes out. Never added on the simulator, which
    /// has no route that decodes it at all.
    static func videoCodecs(includingMPEG2: Bool) -> [String] {
        guard includingMPEG2, !isSimulator else { return videoCodecs }
        return videoCodecs + [mpeg2VideoCodec]
    }
}
