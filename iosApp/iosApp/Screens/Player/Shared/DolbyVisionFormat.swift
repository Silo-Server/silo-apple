import CoreMedia
import Foundation
import Libavcodec
import Libavformat
import Libavutil
import VideoToolbox

/// Dolby Vision configuration parsing, serialization, and routing strategy.
/// All entry points are pure functions over the FFmpeg side data — there is
/// no decode-core state captured here, so the same decisions can be made by
/// alternate demux pipelines (e.g. AVPlayerBackend's loopback session
/// resolver) without going through a player instance.
enum DolbyVisionFormat {
    /// Parsed `AVDOVIDecoderConfigurationRecord` fields we care about. Kept as
    /// a plain struct so future FFmpeg layout changes can only break our
    /// *parser*, not the downstream routing logic.
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

    /// What we plan to tell VideoToolbox + AVDisplayManager about this stream.
    enum Routing {
        /// Emit a `dvcC` or `dvvC` sample-description atom and advertise DV.
        /// Valid when the BL is HDR10/SDR/HLG-compatible (P8.1/8.2/8.4, P10).
        case native(boxKey: String, dr: SpikeDynamicRange, requiresDvDisplay: Bool)
        /// Drop any enhancement layer / DV metadata; advertise as plain HDR10.
        /// Used for Profile 4 and Profile 7.
        case strippedHdr10
        /// Dolby Vision Profile 5 — VT has no decoder path for P5 on tvOS
        /// (`VTDecompressionSessionCreate` returns unimpErr for every
        /// combination of codecType / dvcC atom / color attachments we've
        /// tried). Route the stream through the AVPlayer backend instead:
        /// `AVPlayerBackend` remuxes via the `mp4` muxer with `dvh1` FourCC
        /// and serves local HLS that AVPlayer consumes through its own DV
        /// decode pipeline.
        case p5Passthrough
        /// Refuse playback with a user-facing reason.
        case refused(reason: String)
    }

    /// Look up `AV_PKT_DATA_DOVI_CONF` side data on the codecparams. AVStream
    /// does not carry a side-data array in this FFmpeg revision — the codec
    /// side-data array populated by `avformat_find_stream_info` is the only
    /// published access path.
    static func readConfig(
        stream: UnsafeMutablePointer<AVStream>,
        codecpar: AVCodecParameters
    ) -> Config? {
        // Debug: dump the side-data type counts so we can tell whether this
        // file lacks the DOVI side data entirely or whether our lookup is
        // missing it.
        if codecpar.nb_coded_side_data > 0 {
            var types: [UInt32] = []
            for i in 0..<Int(codecpar.nb_coded_side_data) {
                if let entry = codecpar.coded_side_data?.advanced(by: i) {
                    types.append(entry.pointee.type.rawValue)
                }
            }
            print("[CMP] codecpar side_data count=\(codecpar.nb_coded_side_data) types=\(types)")
        } else {
            print("[CMP] codecpar side_data count=0")
        }

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

    /// Serialize `Config` into the 24-byte ISO BMFF Dolby Vision
    /// configuration box payload. Byte layout (MSB-first, per
    /// dolby-vision-bitstreams-within-the-iso-base-media-file-format-v2.1.2):
    ///
    ///   byte 0      dv_version_major
    ///   byte 1      dv_version_minor
    ///   byte 2-3    dv_profile (7) | dv_level (6) | rpu (1) | el (1) | bl (1)
    ///   byte 4      dv_bl_signal_compatibility_id (4 high bits) | reserved (4)
    ///   byte 5–23   reserved (zero)
    static func serializeBox(_ c: Config) -> Data {
        var bytes = [UInt8](repeating: 0, count: 24)
        bytes[0] = c.versionMajor
        bytes[1] = c.versionMinor
        let w: UInt16 =
            (UInt16(c.profile & 0x7F) << 9) |
            (UInt16(c.level   & 0x3F) << 3) |
            (c.rpuPresent ? 0b100 : 0) |
            (c.elPresent  ? 0b010 : 0) |
            (c.blPresent  ? 0b001 : 0)
        bytes[2] = UInt8(w >> 8)
        bytes[3] = UInt8(w & 0xFF)
        bytes[4] = (c.compatId & 0x0F) << 4
        return Data(bytes)
    }

    /// Route the parsed DOVI config to a VideoToolbox strategy. Profile 10
    /// (AV1 DV) is gated on the hardware AV1 decoder. The policy snapshot
    /// carries the user's Dolby Vision setting; profiles with a compatible
    /// base layer strip to it when the setting resolves to
    /// `.dolbyVisionDisabled` (Profile 5 never does — see
    /// `DolbyVisionPolicy.resolution`).
    static func decideRouting(_ c: Config, policy: DolbyVisionPolicy.Snapshot) -> Routing {
        let resolution = DolbyVisionPolicy.resolution(forProfile: Int(c.profile), snapshot: policy)
        switch c.profile {
        case 4:
            // Dual-layer HEVC + DM; rare. We don't have a FEL fuse path, so
            // play the base layer as HDR10.
            return .strippedHdr10
        case 5:
            // DV-only passthrough. Decode as plain HEVC via hvc1 with no dvcC
            // and no forced color attachments. The TV picks up DV RPU metadata
            // from SEI NALs in the elementary stream once HDMI is in DV mode.
            // Gate on DV-capable display because the BL pixels are IPT PQ-c2
            // and render incorrectly on SDR/HDR10 displays.
            return .p5Passthrough
        case 7:
            // Dual-layer BL+FEL/MEL (UHD rips). VT has no public FEL path;
            // base layer is HDR10-viewable.
            return .strippedHdr10
        case 8, 9:
            // 8.x compat: 1=HDR10, 2=SDR, 4=HLG. The base layer is valid in
            // the advertised compat mode, so DV→fallback is always safe; the
            // stripped path keeps whatever dynamic range the VUI declares,
            // which is the base layer's own.
            guard resolution != .dolbyVisionDisabled else {
                return .strippedHdr10
            }
            // `dvcC`, deliberately, even though the box-type rule the muxing
            // side follows (`ISOBoxSurgery.dolbyVisionConfigBoxType`) would
            // say `dvvC` above Profile 7. This key is not written to a file —
            // it goes into `kCMFormatDescriptionExtension_SampleDescription`
            // `ExtensionAtoms`, where VideoToolbox is the only authority on
            // what it accepts, and this is the combination Profile 8 decode
            // was brought up on (`hvc1` sessions reject `dvh1` samples). Do not
            // align it with the writer without validating P8 playback on an
            // Apple TV first; the two are not the same contract.
            return .native(boxKey: "dvcC", dr: .dolbyVision, requiresDvDisplay: false)
        case 10:
            // AV1 DV. Only on A15+ Apple TV 4K hardware.
            guard VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) else {
                return .refused(
                    reason: "AV1 Dolby Vision not supported on this Apple TV model"
                )
            }
            guard resolution != .dolbyVisionDisabled else {
                return .strippedHdr10
            }
            return .native(boxKey: "dvvC", dr: .dolbyVision, requiresDvDisplay: false)
        default:
            return .refused(reason: "Unknown Dolby Vision profile \(c.profile)")
        }
    }
}
