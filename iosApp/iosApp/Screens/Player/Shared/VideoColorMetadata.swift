import CoreVideo
import Foundation
import Libavutil

/// Pure-function helpers that translate FFmpeg color metadata
/// (`AVColorRange`, `AVPixelFormat`) into the values the probe and the tvOS
/// display-criteria path read, plus the Dolby Vision base-layer colorimetry
/// the HDMI mode request and the decoded frames must agree on.
enum VideoColorMetadata {
    static func colorRangeName(_ range: AVColorRange) -> String? {
        switch range {
        case AVCOL_RANGE_MPEG: return "tv"
        case AVCOL_RANGE_JPEG: return "pc"
        default: return nil
        }
    }

    /// Bit depth of an FFmpeg pixel format's first component (8 when the
    /// descriptor is unavailable). Reading the depth off the actual decoded
    /// frame's format is more reliable than `bits_per_raw_sample`, which some
    /// codecs leave at 0 until well after open.
    static func sourceBitDepth(_ format: AVPixelFormat) -> Int32 {
        guard let desc = av_pix_fmt_desc_get(format) else { return 8 }
        return desc.pointee.comp.0.depth
    }

    /// The colorimetry a Dolby Vision base layer is actually graded in.
    ///
    /// A native-DV stream carries its dynamic metadata in the configuration
    /// box and the RPU NALs, and the display applies it — but the base-layer
    /// pixels VideoToolbox decodes underneath are graded in one specific
    /// transfer, and every consumer downstream of decode reads the
    /// declaration to interpret them. Profile 8.1's base is PQ, 8.2's is
    /// Rec.709 SDR, 8.4's is HLG; the source's own VUI is unreliable here
    /// (Profile 8 streams routinely tag the container for the DV layer), so
    /// the compatibility ID decides.
    ///
    /// The tvOS HDMI criteria in `TVDisplayCriteria` request a mode from the
    /// same triple, so the mode the panel is asked for and the frames it is
    /// handed describe the same base layer.
    static func dolbyVisionBaseLayerColorimetry(
        _ baseLayer: LoopbackSessionSpec.DVProfile8BaseLayer
    ) -> (primaries: CFString, transfer: CFString, matrix: CFString) {
        switch baseLayer {
        case .hdr10:
            return (
                kCVImageBufferColorPrimaries_ITU_R_2020,
                kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                kCVImageBufferYCbCrMatrix_ITU_R_2020
            )
        case .hlg:
            return (
                kCVImageBufferColorPrimaries_ITU_R_2020,
                kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                kCVImageBufferYCbCrMatrix_ITU_R_2020
            )
        case .sdr:
            return (
                kCVImageBufferColorPrimaries_ITU_R_709_2,
                kCVImageBufferTransferFunction_ITU_R_709_2,
                kCVImageBufferYCbCrMatrix_ITU_R_709_2
            )
        }
    }
}
