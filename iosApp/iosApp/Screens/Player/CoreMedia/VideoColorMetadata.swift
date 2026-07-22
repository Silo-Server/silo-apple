import CoreMedia
import CoreVideo
import Foundation
import Libavcodec
import Libavutil
import VideoToolbox

/// Pure-function helpers that translate FFmpeg color metadata
/// (`AVColorPrimaries`, `AVColorTransferCharacteristic`, `AVColorSpace`,
/// codec tag) into the matching CoreVideo / VideoToolbox attachment values.
/// Lifted out of `PlayerCore` so the SDR/HDR pixel-format pick and the
/// colorimetry-string mapping can be reused by the CMSampleBuffer builders
/// without going through PlayerCore static dispatch.
enum VideoColorMetadata {
    static func normalizedColorRangeName(_ value: String?) -> String? {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch normalized {
        case "tv", "pc": return normalized
        default: return nil
        }
    }

    static func colorRangeName(_ range: AVColorRange) -> String? {
        switch range {
        case AVCOL_RANGE_MPEG: return "tv"
        case AVCOL_RANGE_JPEG: return "pc"
        default: return nil
        }
    }

    /// Resolve FFmpeg's stream/frame value first and consult server metadata
    /// only when libav reports AVCOL_RANGE_UNSPECIFIED. Explicit local
    /// signaling always wins over the API fallback.
    static func isFullRange(_ range: AVColorRange, fallbackName: String?) -> Bool {
        if range == AVCOL_RANGE_UNSPECIFIED {
            return normalizedColorRangeName(fallbackName) == "pc"
        }
        return colorRangeName(range) == "pc"
    }

    static func pickPixelFormat(
        dynamicRange: SpikeDynamicRange,
        fullRange: Bool
    ) -> OSType {
        // HDR / DV paths always use 10-bit biplanar 4:2:0 (NV12-like); SDR
        // uses 8-bit. Range matches the advertised color_range so VT's
        // decoder pick and our requested pixel format agree — mismatched
        // combos return unimpErr (-4).
        switch (dynamicRange, fullRange) {
        case (.sdr, false): return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case (.sdr, true):  return kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        case (_, false):    return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        case (_, true):     return kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        }
    }

    /// Bit depth of an FFmpeg pixel format's first component (8 when the
    /// descriptor is unavailable). Drives the software decode path's choice
    /// between 8-bit planar/BGRA output and 10-bit biplanar output. Reading
    /// the depth off the actual decoded frame's format is more reliable than
    /// `bits_per_raw_sample`, which some codecs leave at 0 until well after
    /// open.
    static func sourceBitDepth(_ format: AVPixelFormat) -> Int32 {
        guard let desc = av_pix_fmt_desc_get(format) else { return 8 }
        return desc.pointee.comp.0.depth
    }

    /// CoreVideo pixel format for >8-bit software decode output: P010-layout
    /// biplanar 4:2:0 (16-bit samples, 10 significant MSBs), range-matched
    /// to the source the same way the 8-bit planar fast path picks its
    /// full/video-range variant.
    static func highBitDepthOutputPixelFormat(fullRange: Bool) -> OSType {
        fullRange
            ? kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
    }

    static func dynamicRange(forTransfer trc: AVColorTransferCharacteristic) -> SpikeDynamicRange {
        switch trc {
        case AVCOL_TRC_SMPTE2084:    return .hdr10
        case AVCOL_TRC_ARIB_STD_B67: return .hlg
        default:                     return .sdr
        }
    }

    static func proResCodecType(codecTag: UInt32) -> CMVideoCodecType {
        switch codecTag {
        case ffmpegTag("apco"), cmTag("apco"):
            return cmTag("apco")
        case ffmpegTag("apcs"), cmTag("apcs"):
            return cmTag("apcs")
        case ffmpegTag("apcn"), cmTag("apcn"):
            return cmTag("apcn")
        case ffmpegTag("apch"), cmTag("apch"), 0:
            return cmTag("apch")
        case ffmpegTag("ap4h"), cmTag("ap4h"):
            return cmTag("ap4h")
        case ffmpegTag("ap4x"), cmTag("ap4x"):
            return cmTag("ap4x")
        default:
            return cmTag("apch")
        }
    }

    /// Pack a four-character-code as a big-endian UInt32 (the CoreMedia
    /// convention for `CMVideoCodecType`). Not interchangeable with
    /// `ffmpegTag` — they encode opposite byte orders.
    private static func cmTag(_ value: String) -> CMVideoCodecType {
        let bytes = Array(value.utf8.prefix(4))
        guard bytes.count == 4 else { return 0 }
        return CMVideoCodecType(bytes[0]) << 24
            | CMVideoCodecType(bytes[1]) << 16
            | CMVideoCodecType(bytes[2]) << 8
            | CMVideoCodecType(bytes[3])
    }

    /// Pack a four-character-code as a little-endian UInt32 (the FFmpeg
    /// convention for `codec_tag`). Not interchangeable with `cmTag` — they
    /// encode opposite byte orders.
    private static func ffmpegTag(_ value: String) -> UInt32 {
        let bytes = Array(value.utf8.prefix(4))
        guard bytes.count == 4 else { return 0 }
        return UInt32(bytes[0])
            | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16
            | UInt32(bytes[3]) << 24
    }

    static func colorPrimariesString(_ pri: AVColorPrimaries) -> CFString? {
        switch pri {
        case AVCOL_PRI_BT470BG:   return kCVImageBufferColorPrimaries_EBU_3213
        case AVCOL_PRI_SMPTE170M: return kCVImageBufferColorPrimaries_SMPTE_C
        case AVCOL_PRI_BT709:     return kCVImageBufferColorPrimaries_ITU_R_709_2
        case AVCOL_PRI_BT2020:    return kCVImageBufferColorPrimaries_ITU_R_2020
        default:                  return nil
        }
    }

    static func transferFunctionString(_ trc: AVColorTransferCharacteristic) -> CFString? {
        switch trc {
        case AVCOL_TRC_SMPTE2084:               return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case AVCOL_TRC_BT2020_10, AVCOL_TRC_BT2020_12:
                                                return kCVImageBufferTransferFunction_ITU_R_2020
        case AVCOL_TRC_BT709:                   return kCVImageBufferTransferFunction_ITU_R_709_2
        case AVCOL_TRC_ARIB_STD_B67:            return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        case AVCOL_TRC_SMPTE240M:               return kCVImageBufferTransferFunction_SMPTE_240M_1995
        case AVCOL_TRC_LINEAR:                  return kCVImageBufferTransferFunction_Linear
        default:                                return nil
        }
    }

    static func ycbcrMatrixString(_ spc: AVColorSpace) -> CFString? {
        switch spc {
        case AVCOL_SPC_BT709:                   return kCVImageBufferYCbCrMatrix_ITU_R_709_2
        case AVCOL_SPC_BT470BG, AVCOL_SPC_SMPTE170M:
                                                return kCVImageBufferYCbCrMatrix_ITU_R_601_4
        case AVCOL_SPC_SMPTE240M:               return kCVImageBufferYCbCrMatrix_SMPTE_240M_1995
        case AVCOL_SPC_BT2020_CL, AVCOL_SPC_BT2020_NCL:
                                                return kCVImageBufferYCbCrMatrix_ITU_R_2020
        default:                                return nil
        }
    }
}
