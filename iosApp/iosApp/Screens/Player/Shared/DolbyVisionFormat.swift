import Foundation
import Libavcodec
import Libavformat
import Libavutil

/// Dolby Vision configuration parsing. The entry point is a pure function
/// over the FFmpeg side data — there is no decode-core state captured here,
/// so any demux pipeline can read the config without going through a player
/// instance.
enum DolbyVisionFormat {
    /// Parsed `AVDOVIDecoderConfigurationRecord` fields we care about. Kept as
    /// a plain struct so future FFmpeg layout changes can only break our
    /// *parser*, not the downstream consumers.
    struct Config {
        let versionMajor: UInt8
        let versionMinor: UInt8
        /// Dolby Vision profile (4, 5, 7, 8, 9, 10).
        let profile: UInt8
        let level: UInt8
        let rpuPresent: Bool
        let elPresent: Bool
        let blPresent: Bool
        /// `dv_bl_signal_compatibility_id`: 0 = none, 1 = HDR10, 2 = SDR, 4 = HLG.
        let compatId: UInt8
    }

    /// Look up `AV_PKT_DATA_DOVI_CONF` side data on the codecparams. AVStream
    /// does not carry a side-data array in this FFmpeg revision — the codec
    /// side-data array populated by `avformat_find_stream_info` is the only
    /// published access path.
    static func readConfig(
        stream: UnsafeMutablePointer<AVStream>,
        codecpar: AVCodecParameters
    ) -> Config? {
        guard let sdArray = codecpar.coded_side_data,
              codecpar.nb_coded_side_data > 0,
              let sd = av_packet_side_data_get(
                sdArray,
                codecpar.nb_coded_side_data,
                AV_PKT_DATA_DOVI_CONF)
        else { return nil }
        guard let raw = sd.pointee.data,
              sd.pointee.size >= MemoryLayout<AVDOVIDecoderConfigurationRecord>.size
        else { return nil }
        let rec = raw.withMemoryRebound(
            to: AVDOVIDecoderConfigurationRecord.self,
            capacity: 1
        ) { $0.pointee }
        return Config(
            versionMajor: rec.dv_version_major,
            versionMinor: rec.dv_version_minor,
            profile: rec.dv_profile,
            level: rec.dv_level,
            rpuPresent: rec.rpu_present_flag != 0,
            elPresent: rec.el_present_flag != 0,
            blPresent: rec.bl_present_flag != 0,
            compatId: rec.dv_bl_signal_compatibility_id
        )
    }
}
