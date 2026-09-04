import Foundation
import XCTest
@testable import Silo

final class ThumbHashDecoderTests: XCTestCase {
    // Canonical vectors from go.n16f.net/thumbhash v1.1.0, the encoder used
    // by Silo Server's imageutil. The Firefox vector carries alpha.
    private let opaqueHash = "1QcSHQRnh493V4dIh4eXh1h4kJUI"
    private let alphaHash = "X5qGNQw7oElslqhGWfSE+Q6oJ1h2iHB2Rw=="

    func testDecodesCanonicalOpaqueHashWithEncodedAspectRatio() throws {
        let decoded = try XCTUnwrap(ThumbHashDecoder.decodeRGBA(opaqueHash))

        XCTAssertEqual(decoded.width, 23)
        XCTAssertEqual(decoded.height, 32)
        XCTAssertEqual(decoded.pixels.count, 23 * 32 * 4)
        XCTAssertTrue(alphaValues(in: decoded.pixels).allSatisfy { $0 == 255 })
    }

    func testDecodesCanonicalAlphaHash() throws {
        let decoded = try XCTUnwrap(ThumbHashDecoder.decodeRGBA(alphaHash))
        let alpha = alphaValues(in: decoded.pixels)

        XCTAssertEqual(decoded.width, 32)
        XCTAssertEqual(decoded.height, 32)
        XCTAssertEqual(decoded.pixels.count, 32 * 32 * 4)
        XCTAssertTrue(alpha.contains { $0 < 255 })
        XCTAssertTrue(alpha.contains { $0 > 0 })
    }

    func testRejectsEmptyInvalidAndTruncatedHashes() {
        XCTAssertNil(ThumbHashDecoder.decodeRGBA(""))
        XCTAssertNil(ThumbHashDecoder.decodeRGBA("not base64"))
        XCTAssertNil(ThumbHashDecoder.decodeRGBA(Data([1, 2, 3, 4]).base64EncodedString()))

        let validBytes = Data(base64Encoded: opaqueHash)!
        XCTAssertNil(
            ThumbHashDecoder.decodeRGBA(validBytes.dropLast().base64EncodedString()),
            "a valid header must not permit truncated packed coefficients"
        )
        XCTAssertNil(
            ThumbHashDecoder.decodeRGBA((validBytes + Data([0])).base64EncodedString()),
            "trailing bytes are not part of the ThumbHash format"
        )
    }

    func testRejectsMissingAlphaHeaderAndZeroDimension() {
        XCTAssertNil(
            ThumbHashDecoder.decodeRGBA(
                Data([0, 0, 0x80, 1, 0]).base64EncodedString()
            )
        )
        XCTAssertNil(
            ThumbHashDecoder.decodeRGBA(
                Data([0, 0, 0, 0, 0]).base64EncodedString()
            )
        )
    }

    func testLowEncodedDimensionUsesClampedDecoderAspectRatio() throws {
        // Portrait, no alpha, encoded luminance count 1. The decoder clamps
        // that axis to 3 coefficients, matching go.n16f Hash.Size.
        let hash = Data([0, 0, 0, 1, 0] + Array(repeating: 0, count: 12))
            .base64EncodedString()
        let decoded = try XCTUnwrap(ThumbHashDecoder.decodeRGBA(hash))

        XCTAssertEqual(decoded.width, 14)
        XCTAssertEqual(decoded.height, 32)
    }

    private func alphaValues(in pixels: Data) -> [UInt8] {
        stride(from: 3, to: pixels.count, by: 4).map { pixels[$0] }
    }
}
