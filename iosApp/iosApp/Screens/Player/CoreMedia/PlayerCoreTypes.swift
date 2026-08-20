import Foundation

extension PlayerCore {
    struct LoadRequest {
        let url: URL
        let headers: [String: String]
        let startTime: Double
    }

    struct ChapterInfo: Equatable, Identifiable {
        let index: Int
        let title: String?
        let time: Double
        var id: Int { index }
    }

    /// Cumulative playback-health counters for the diagnostics line, the
    /// stats panel, and (eventually) playback-diagnostics reporting. All
    /// values are session-lifetime totals; snapshot via
    /// `playbackHealthStats()`.
    struct PlaybackHealthStats: Equatable {
        var rebufferCount: Int
        var bufferingWallSeconds: Double
        var lastRebufferRecoverySeconds: Double?
        var seekCount: UInt64
        var coalescedSeekCount: UInt64
        var lastSeekToFirstFrameSeconds: Double?
        var avsyncFlushCount: UInt64
        var avsyncGopDropCount: UInt64
        var avsyncReseekCount: UInt64
        var avsyncDroppedPacketSeconds: Double
    }

    /// Reasons PlayerCore rejects a stream. The VM decides what to do with
    /// the rejection (e.g. route to an AVPlayer-backed fallback) — the
    /// core itself stays agnostic about fallbacks.
    enum StreamRejection {
        /// The source requires the bounded H.264 High 10 software decoder,
        /// but the stream discovered at runtime exceeds the advertised limits.
        case h264SoftwareDecodeOutOfBounds
        /// Dolby Vision Profile 5: `buildVideoFormatDescription` detected
        /// `AV_PKT_DATA_DOVI_CONF` with profile 5.
        case dolbyVisionProfile5
        /// `VTDecompressionSessionCreate` returned unimpErr on HEVC+PQ.
        /// Treated as a likely unsignalled DV stream (DOVI conf not surfaced
        /// by libavformat for this container).
        case videoToolboxUnsupportedHEVCPQ
        /// `VTDecompressionSessionCreate` returned unimpErr on iPhone HEVC
        /// HDR (for example HLG) after relaxed retries. Route the original
        /// source URL through the AVPlayer backend instead of failing hard.
        case videoToolboxUnsupportedHEVCHDR
        /// VideoToolbox accepted the H.264 session but then rejected the
        /// compressed samples as bad data. This is terminal for H.264 direct
        /// playback; do not mask it with software fallback.
        case videoToolboxBadDataH264
        /// VideoToolbox accepted the HEVC session but later rejected compressed
        /// samples as bad data. Route the original source through SiloPlayer's
        /// AVPlayer loopback so the stream can continue on the presentation
        /// path used for other HEVC VideoToolbox rejections.
        case videoToolboxBadDataHEVC
    }
}
