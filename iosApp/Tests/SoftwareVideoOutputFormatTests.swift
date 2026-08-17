import Libavutil
import XCTest
@testable import Silo

/// Covers the pure bit-depth helper behind the probe's reported source depth:
/// which FFmpeg pixel formats count as >8-bit.
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
}
