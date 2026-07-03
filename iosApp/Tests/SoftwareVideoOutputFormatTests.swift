import CoreVideo
import Libavutil
import XCTest
@testable import Silo

/// Covers the pure decision helpers behind the software decode path's
/// bit-depth-aware output: which FFmpeg pixel formats count as >8-bit, and
/// which CoreVideo P010 variant each color range maps to. These drive whether
/// 10-bit VP9/AV1 keeps its depth or falls back to the 8-bit paths.
final class SoftwareVideoOutputFormatTests: XCTestCase {
    func testEightBitFormatsReportDepthEight() {
        XCTAssertEqual(VideoColorMetadata.sourceBitDepth(AV_PIX_FMT_YUV420P), 8)
        XCTAssertEqual(VideoColorMetadata.sourceBitDepth(AV_PIX_FMT_YUVJ420P), 8)
        XCTAssertEqual(VideoColorMetadata.sourceBitDepth(AV_PIX_FMT_NV12), 8)
    }

    func testTenBitFormatsReportDepthTen() {
        XCTAssertEqual(VideoColorMetadata.sourceBitDepth(AV_PIX_FMT_YUV420P10LE), 10)
        XCTAssertEqual(VideoColorMetadata.sourceBitDepth(AV_PIX_FMT_P010LE), 10)
    }

    func testTwelveBitFormatsExceedEight() {
        XCTAssertEqual(VideoColorMetadata.sourceBitDepth(AV_PIX_FMT_YUV420P12LE), 12)
    }

    func testUnknownFormatDefaultsToEight() {
        // AV_PIX_FMT_NONE has no descriptor; the helper must not treat it
        // as high bit depth (that would send garbage into the P010 path).
        XCTAssertEqual(VideoColorMetadata.sourceBitDepth(AV_PIX_FMT_NONE), 8)
    }

    func testHighBitDepthOutputRangeMapping() {
        XCTAssertEqual(
            VideoColorMetadata.highBitDepthOutputPixelFormat(fullRange: false),
            kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        )
        XCTAssertEqual(
            VideoColorMetadata.highBitDepthOutputPixelFormat(fullRange: true),
            kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        )
    }
}
