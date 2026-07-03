import XCTest
@testable import Silo

/// The bootstrap keyframe-flag repair (living-room Ali Wong startup stall)
/// gates on `firstIRAPNALType`: an HEVC packet whose bitstream carries a VCL
/// IRAP NAL is a valid fragment opener even when the demuxer failed to set
/// `AV_PKT_FLAG_KEY`. These tests pin the NAL walk over AVCC length-prefixed
/// packets, including the malformed shapes the scanner must refuse.
final class ISOBoxSurgeryIRAPTests: XCTestCase {
    /// Builds one length-prefixed packet from (nalType, payloadSize) pairs.
    /// The 2-byte HEVC NAL header encodes the type in bits 1-6 of byte 0.
    private func packet(nalLengthSize: Int, nals: [(type: Int, payload: Int)]) -> [UInt8] {
        var bytes: [UInt8] = []
        for nal in nals {
            let nalSize = 2 + nal.payload
            for shift in stride(from: (nalLengthSize - 1) * 8, through: 0, by: -8) {
                bytes.append(UInt8((nalSize >> shift) & 0xFF))
            }
            bytes.append(UInt8((nal.type << 1) & 0x7E))
            bytes.append(0x01)
            bytes.append(contentsOf: [UInt8](repeating: 0xAB, count: nal.payload))
        }
        return bytes
    }

    private func firstIRAP(_ bytes: [UInt8], nalLengthSize: Int = 4) -> Int? {
        bytes.withUnsafeBufferPointer {
            ISOBoxSurgery.firstIRAPNALType(packetBytes: $0, nalLengthSize: nalLengthSize)
        }
    }

    func testIDRAfterParameterSetsIsFound() {
        // The shape of a real MKV keyframe packet: VPS/SPS/PPS, SEI, then IDR.
        let bytes = packet(nalLengthSize: 4, nals: [
            (type: 32, payload: 8), (type: 33, payload: 16), (type: 34, payload: 4),
            (type: 39, payload: 6), (type: 19, payload: 32),
        ])
        XCTAssertEqual(firstIRAP(bytes), 19)
    }

    func testCRAWithoutParameterSetsIsFound() {
        let bytes = packet(nalLengthSize: 4, nals: [(type: 39, payload: 6), (type: 21, payload: 32)])
        XCTAssertEqual(firstIRAP(bytes), 21)
    }

    func testTrailingPicturePacketHasNoIRAP() {
        // TRAIL_N/TRAIL_R (0/1) plus an unspec DV RPU NAL (62) — the packets
        // the bootstrap must keep rejecting even after the flag repair.
        let bytes = packet(nalLengthSize: 4, nals: [
            (type: 1, payload: 24), (type: 0, payload: 12), (type: 62, payload: 8),
        ])
        XCTAssertNil(firstIRAP(bytes))
    }

    func testHonorsNonFourByteLengthPrefix() {
        let bytes = packet(nalLengthSize: 2, nals: [(type: 20, payload: 10)])
        XCTAssertEqual(firstIRAP(bytes, nalLengthSize: 2), 20)
    }

    func testTruncatedLengthPrefixStopsCleanly() {
        var bytes = packet(nalLengthSize: 4, nals: [(type: 1, payload: 4)])
        // Declared size runs past the buffer end: scanner must stop, not read over.
        bytes.append(contentsOf: [0x00, 0x00, 0xFF, 0xFF, 0x28])
        XCTAssertNil(firstIRAP(bytes))
    }

    func testEmptyAndInvalidInputs() {
        XCTAssertNil(firstIRAP([]))
        XCTAssertNil(firstIRAP(packet(nalLengthSize: 4, nals: [(type: 19, payload: 4)]), nalLengthSize: 0))
    }
}
