import XCTest
@testable import Silo

/// Pins the dec3 JOC-extension surgery that makes DDP-Atmos signalling
/// survive the FFmpeg 7.1 muxer (which writes num_dep_sub/chan_loc but not
/// the ETSI TS 103 420 extension AVFoundation keys on for Atmos).
final class ISOBoxSurgeryDec3Tests: XCTestCase {

    // MARK: - Synthetic box-tree builder

    private func box(_ type: String, _ payload: Data) -> Data {
        var out = Data()
        let size = UInt32(8 + payload.count)
        out.append(contentsOf: [
            UInt8((size >> 24) & 0xFF), UInt8((size >> 16) & 0xFF),
            UInt8((size >> 8) & 0xFF), UInt8(size & 0xFF),
        ])
        out.append(type.data(using: .ascii)!)
        out.append(payload)
        return out
    }

    private func hdlr(_ handler: String) -> Data {
        var payload = Data(count: 8)  // FullBox version/flags + pre_defined
        payload.append(handler.data(using: .ascii)!)
        payload.append(0)  // empty name
        return box("hdlr", payload)
    }

    private func trak(handler: String, stblChildren: Data) -> Data {
        let stbl = box("stbl", stblChildren)
        let minf = box("minf", stbl)
        let mdia = box("mdia", hdlr(handler) + minf)
        return box("trak", mdia)
    }

    /// An `ec-3` AudioSampleEntry: 28 bytes of entry fields, then children.
    private func ec3Entry(dec3Payload: Data) -> Data {
        box("ec-3", Data(count: 28) + box("dec3", dec3Payload))
    }

    private func initSegment(dec3Payload: Data, videoTrakFirst: Bool = true) -> Data {
        let stsdPayload = Data(count: 8) + ec3Entry(dec3Payload: dec3Payload)  // FullBox + entry_count
        let audioTrak = trak(handler: "soun", stblChildren: box("stsd", stsdPayload))
        let videoTrak = trak(handler: "vide", stblChildren: Data())
        let moov = box("moov", videoTrakFirst ? videoTrak + audioTrak : audioTrak + videoTrak)
        return box("ftyp", Data(count: 8)) + moov
    }

    // MARK: - Bit-exact vectors (hand-computed)

    /// FFmpeg 7.1 output (its non-ETSI 5-reserved-bit layout): data_rate=768,
    /// one independent substream (bsid 16, acmod 3/2, lfeon 1),
    /// num_dep_sub=1, chan_loc=4. No JOC extension.
    private let jocLessPayload = Data([0x18, 0x00, 0x20, 0x0F, 0x00, 0x81, 0x00])
    /// jocLessPayload converted to the ETSI layout (3 reserved bits) with
    /// the JOC extension (flag=1, complexity=16).
    private let extendedPayload = Data([0x18, 0x00, 0x20, 0x0F, 0x02, 0x04, 0x01, 0x10])
    /// The exact dec3 payload FFmpeg 7.1 wrote on-device for a real
    /// streaming WEB-DL DDP-Atmos stream (num_dep_sub=0 — streaming Atmos
    /// carries JOC in the independent frame's EMDF).
    private let devicePayload = Data([0x18, 0x00, 0x20, 0x0F, 0x00, 0x00])
    /// GROUND TRUTH: what FFmpeg 8.1 emits when remuxing the identical
    /// device stream (`1800200f000110`). The conversion must match it
    /// byte-for-byte.
    private let deviceExtendedPayload = Data([0x18, 0x00, 0x20, 0x0F, 0x00, 0x01, 0x10])

    // MARK: - Tests

    func testAppendsExtensionBitExact() {
        let input = initSegment(dec3Payload: jocLessPayload)
        guard let output = ISOBoxSurgery.appendDec3JOCExtension(into: input, complexityIndex: 16) else {
            return XCTFail("surgery must succeed on the JOC-less tree")
        }
        XCTAssertEqual(output.count, input.count + 1)

        guard let moov = ISOBoxSurgery.findTopLevelBox(in: output, type: "moov"),
              let audioTrak = ISOBoxSurgery.findAudioTrak(in: output, moov: moov),
              let mdia = ISOBoxSurgery.findChildBox(in: output, parent: audioTrak, childType: "mdia"),
              let minf = ISOBoxSurgery.findChildBox(in: output, parent: mdia, childType: "minf"),
              let stbl = ISOBoxSurgery.findChildBox(in: output, parent: minf, childType: "stbl"),
              let stsd = ISOBoxSurgery.findChildBox(in: output, parent: stbl, childType: "stsd"),
              let entry = ISOBoxSurgery.findAnyFirstChildBox(in: output, parent: stsd, contentSkip: 8),
              let dec3 = ISOBoxSurgery.findChildBox(in: output, parent: entry, childType: "dec3", contentSkip: 28)
        else {
            return XCTFail("patched tree must still walk")
        }
        XCTAssertEqual(dec3.size, 8 + extendedPayload.count)
        XCTAssertEqual(output.subdata(in: (dec3.start + 8) ..< (dec3.start + dec3.size)), extendedPayload)
    }

    func testAncestorSizesGrowByDelta() {
        let input = initSegment(dec3Payload: jocLessPayload)
        guard let output = ISOBoxSurgery.appendDec3JOCExtension(into: input, complexityIndex: 16) else {
            return XCTFail("surgery must succeed")
        }
        guard let moovIn = ISOBoxSurgery.findTopLevelBox(in: input, type: "moov"),
              let moovOut = ISOBoxSurgery.findTopLevelBox(in: output, type: "moov") else {
            return XCTFail("moov must exist in both")
        }
        XCTAssertEqual(moovOut.size, moovIn.size + 1)
        // The video trak (first child) must be byte-identical.
        guard let videoIn = ISOBoxSurgery.findVideoTrak(in: input, moov: moovIn),
              let videoOut = ISOBoxSurgery.findVideoTrak(in: output, moov: moovOut) else {
            return XCTFail("video trak must exist in both")
        }
        XCTAssertEqual(
            input.subdata(in: videoIn.start ..< videoIn.start + videoIn.size),
            output.subdata(in: videoOut.start ..< videoOut.start + videoOut.size)
        )
    }

    func testAlreadyExtendedReturnsNil() {
        for payload in [extendedPayload, deviceExtendedPayload] {
            let input = initSegment(dec3Payload: payload)
            XCTAssertNil(
                ISOBoxSurgery.appendDec3JOCExtension(into: input, complexityIndex: 16),
                "an ETSI-layout dec3 with a valid extension (FFmpeg ≥ 8) must be left untouched"
            )
        }
    }

    func testAppendThenReappendIsIdempotent() {
        let input = initSegment(dec3Payload: jocLessPayload)
        guard let once = ISOBoxSurgery.appendDec3JOCExtension(into: input, complexityIndex: 16) else {
            return XCTFail("first pass must succeed")
        }
        XCTAssertNil(ISOBoxSurgery.appendDec3JOCExtension(into: once, complexityIndex: 16))
    }

    func testDevicePayloadConvertsToFFmpeg8GroundTruth() {
        // The exact on-device case: the 7.1-written payload must convert to
        // the byte-identical output FFmpeg 8.1 produces for the same stream.
        // (Two prior failures pinned here: requiring a dependent substream,
        // and extending 7.1's 5-reserved-bit layout instead of rewriting to
        // ETSI's 3 — the flag landed two bits past where Apple reads it.)
        let input = initSegment(dec3Payload: devicePayload)
        guard let output = ISOBoxSurgery.appendDec3JOCExtension(into: input, complexityIndex: 16) else {
            return XCTFail("surgery must convert the ndep=0 streaming-Atmos shape")
        }
        guard let moov = ISOBoxSurgery.findTopLevelBox(in: output, type: "moov"),
              let audioTrak = ISOBoxSurgery.findAudioTrak(in: output, moov: moov),
              let mdia = ISOBoxSurgery.findChildBox(in: output, parent: audioTrak, childType: "mdia"),
              let minf = ISOBoxSurgery.findChildBox(in: output, parent: mdia, childType: "minf"),
              let stbl = ISOBoxSurgery.findChildBox(in: output, parent: minf, childType: "stbl"),
              let stsd = ISOBoxSurgery.findChildBox(in: output, parent: stbl, childType: "stsd"),
              let entry = ISOBoxSurgery.findAnyFirstChildBox(in: output, parent: stsd, contentSkip: 8),
              let dec3 = ISOBoxSurgery.findChildBox(in: output, parent: entry, childType: "dec3", contentSkip: 28)
        else {
            return XCTFail("patched tree must still walk")
        }
        XCTAssertEqual(output.subdata(in: (dec3.start + 8) ..< (dec3.start + dec3.size)), deviceExtendedPayload)
        // And idempotence on the ndep=0 shape.
        XCTAssertNil(ISOBoxSurgery.appendDec3JOCExtension(into: output, complexityIndex: 16))
    }

    func testMissingDec3ReturnsNil() {
        let stsdPayload = Data(count: 8) + box("ec-3", Data(count: 28))  // no dec3 child
        let audioTrak = trak(handler: "soun", stblChildren: box("stsd", stsdPayload))
        let input = box("moov", audioTrak)
        XCTAssertNil(ISOBoxSurgery.appendDec3JOCExtension(into: input, complexityIndex: 16))
    }

    func testAudioTrakFoundBehindVideoTrak() {
        // MKV sources often list video first; the walker must skip it.
        let input = initSegment(dec3Payload: jocLessPayload, videoTrakFirst: true)
        XCTAssertNotNil(ISOBoxSurgery.appendDec3JOCExtension(into: input, complexityIndex: 16))
        let flipped = initSegment(dec3Payload: jocLessPayload, videoTrakFirst: false)
        XCTAssertNotNil(ISOBoxSurgery.appendDec3JOCExtension(into: flipped, complexityIndex: 16))
    }
}
