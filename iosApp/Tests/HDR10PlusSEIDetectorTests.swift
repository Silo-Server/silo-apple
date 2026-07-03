import XCTest
@testable import Silo

final class HDR10PlusSEIDetectorTests: XCTestCase {
    /// ITU-T T.35 header for SMPTE ST 2094-40 (HDR10+) dynamic metadata.
    private let needle: [UInt8] = [0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04]
    /// Filler byte chosen so no window across filler + needle boundaries can
    /// form an accidental second needle (0xAA never appears in the needle).
    private let filler: UInt8 = 0xAA

    func testDetectsNeedleAtBufferStart() {
        var detector = HDR10PlusSEIDetector()
        let buffer = Data(needle + [UInt8](repeating: filler, count: 16))
        XCTAssertTrue(detector.scan(buffer))
        XCTAssertTrue(detector.detected)
    }

    func testDetectsNeedleAtBufferEnd() {
        var detector = HDR10PlusSEIDetector()
        let buffer = Data([UInt8](repeating: filler, count: 16) + needle)
        XCTAssertTrue(detector.scan(buffer))
        XCTAssertTrue(detector.detected)
    }

    func testDetectsNeedleAtArbitraryOffsets() {
        for offset in 1...8 {
            var detector = HDR10PlusSEIDetector()
            let buffer = Data(
                [UInt8](repeating: filler, count: offset)
                    + needle
                    + [UInt8](repeating: filler, count: 8)
            )
            XCTAssertTrue(detector.scan(buffer), "needle missed at offset \(offset)")
            XCTAssertTrue(detector.detected)
        }
    }

    func testIgnoresBufferWithoutNeedle() {
        var detector = HDR10PlusSEIDetector()
        XCTAssertFalse(detector.scan(Data([UInt8](repeating: filler, count: 64))))
        XCTAssertFalse(detector.detected)
    }

    func testIgnoresNearMissLastByte() {
        var detector = HDR10PlusSEIDetector()
        var nearMiss = needle
        nearMiss[nearMiss.count - 1] = 0x05
        let buffer = Data([UInt8](repeating: filler, count: 4) + nearMiss)
        XCTAssertFalse(detector.scan(buffer))
        XCTAssertFalse(detector.detected)
    }

    func testIgnoresNeedleTruncatedAtBufferEnd() {
        var detector = HDR10PlusSEIDetector()
        let buffer = Data([UInt8](repeating: filler, count: 8) + needle.dropLast())
        XCTAssertFalse(detector.scan(buffer))
        XCTAssertFalse(detector.detected)
    }

    func testIgnoresBuffersShorterThanNeedle() {
        for count in 0..<needle.count {
            var detector = HDR10PlusSEIDetector()
            XCTAssertFalse(detector.scan(Data(needle.prefix(count))))
            XCTAssertFalse(detector.detected)
        }
    }

    func testLatchesAfterFirstHit() {
        var detector = HDR10PlusSEIDetector()
        let buffer = Data([UInt8](repeating: filler, count: 4) + needle)
        XCTAssertTrue(detector.scan(buffer))
        // A second needle-bearing packet must NOT re-fire: the writer's
        // one-shot callback contract depends on the latch.
        XCTAssertFalse(detector.scan(buffer))
        XCTAssertTrue(detector.detected)
    }
}
