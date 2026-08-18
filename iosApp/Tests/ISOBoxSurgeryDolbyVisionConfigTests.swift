import XCTest
@testable import Silo

/// Pins the Dolby Vision configuration-box surgery that gives the loopback
/// route's `dvh1` sample entry its DV signalling. The box type is not a
/// constant: Profile 5 must be carried in `dvcC` and the cross-compatible
/// Profile 8 in `dvvC`, and a Profile 5 track written with `dvvC` is not
/// recognised as Dolby Vision at all.
final class ISOBoxSurgeryDolbyVisionConfigTests: XCTestCase {

    /// A `dvh1` VisualSampleEntry: 78 bytes of entry fields, then children.
    private func dvh1Entry(children: Data) -> Data {
        ISOBoxTestTree.box("dvh1", Data(count: 78) + children)
    }

    /// An init segment shaped like the muxer's: audio trak first (MKV
    /// ordering FFmpeg preserves), so the walk has to find `vide` by handler.
    private func initSegment(sampleEntryChildren: Data) -> Data {
        let stsdPayload = Data(count: 8) + dvh1Entry(children: sampleEntryChildren)
        let videoTrak = ISOBoxTestTree.trak(handler: "vide", stblChildren: ISOBoxTestTree.box("stsd", stsdPayload))
        let audioTrak = ISOBoxTestTree.trak(handler: "soun", stblChildren: Data())
        return ISOBoxTestTree.box("ftyp", Data(count: 8)) + ISOBoxTestTree.box("moov", audioTrak + videoTrak)
    }

    private let hvcCBox = Data([0x00, 0x00, 0x00, 0x1F]) + "hvcC".data(using: .ascii)!
        + Data(count: 23)

    /// FFmpeg's `AVDOVIDecoderConfigurationRecord` as our reader sees it: one
    /// byte per field — version_major, version_minor, profile, level, rpu,
    /// el, bl, bl_compat_id.
    private func record(profile: UInt8, level: UInt8, compatID: UInt8) -> Data {
        Data([1, 0, profile, level, 1, 0, 1, compatID])
    }

    // MARK: - Sample entry children

    private func configBoxes(in segment: Data) -> [(type: String, box: ISOBoxSurgery.Box)] {
        guard let moov = ISOBoxSurgery.findTopLevelBox(in: segment, type: "moov"),
              let trak = ISOBoxSurgery.findVideoTrak(in: segment, moov: moov),
              let mdia = ISOBoxSurgery.findChildBox(in: segment, parent: trak, childType: "mdia"),
              let minf = ISOBoxSurgery.findChildBox(in: segment, parent: mdia, childType: "minf"),
              let stbl = ISOBoxSurgery.findChildBox(in: segment, parent: minf, childType: "stbl"),
              let stsd = ISOBoxSurgery.findChildBox(in: segment, parent: stbl, childType: "stsd"),
              let entry = ISOBoxSurgery.findAnyFirstChildBox(in: segment, parent: stsd, contentSkip: 8)
        else { return [] }
        return ISOBoxSurgery.childBoxes(in: segment, parent: entry, contentSkip: 78)
    }

    // MARK: - Box type follows the profile

    func testProfile5WritesDvcC() {
        let input = initSegment(sampleEntryChildren: hvcCBox)
        guard let output = ISOBoxSurgery.injectDolbyVisionConfig(
            into: input, doviBytes: record(profile: 5, level: 6, compatID: 0)
        ) else {
            return XCTFail("injection must succeed on a well-formed dvh1 tree")
        }

        let children = configBoxes(in: output)
        XCTAssertEqual(children.map(\.type), ["hvcC", "dvcC"])
        XCTAssertEqual(output.count, input.count + 32)
    }

    func testProfile8WritesDvvC() {
        let input = initSegment(sampleEntryChildren: hvcCBox)
        guard let output = ISOBoxSurgery.injectDolbyVisionConfig(
            into: input, doviBytes: record(profile: 8, level: 6, compatID: 1)
        ) else {
            return XCTFail("injection must succeed on a well-formed dvh1 tree")
        }

        let children = configBoxes(in: output)
        XCTAssertEqual(children.map(\.type), ["hvcC", "dvvC"])
        XCTAssertEqual(output.count, input.count + 32)
    }

    func testBoxTypeSplitsAtProfile7() {
        XCTAssertEqual(ISOBoxSurgery.dolbyVisionConfigBoxType(profile: 5), "dvcC")
        XCTAssertEqual(ISOBoxSurgery.dolbyVisionConfigBoxType(profile: 7), "dvcC")
        XCTAssertEqual(ISOBoxSurgery.dolbyVisionConfigBoxType(profile: 8), "dvvC")
        XCTAssertEqual(ISOBoxSurgery.dolbyVisionConfigBoxType(profile: 10), "dvvC")
    }

    // MARK: - Structure

    func testAncestorSizesAbsorbTheInsertedBox() {
        let input = initSegment(sampleEntryChildren: hvcCBox)
        guard let output = ISOBoxSurgery.injectDolbyVisionConfig(
            into: input, doviBytes: record(profile: 5, level: 6, compatID: 0)
        ) else {
            return XCTFail("injection must succeed on a well-formed dvh1 tree")
        }

        // Every ancestor box must still describe its own contents, or the
        // walk that finds them again would run off the end.
        guard let moov = ISOBoxSurgery.findTopLevelBox(in: output, type: "moov"),
              let trak = ISOBoxSurgery.findVideoTrak(in: output, moov: moov),
              let mdia = ISOBoxSurgery.findChildBox(in: output, parent: trak, childType: "mdia"),
              let minf = ISOBoxSurgery.findChildBox(in: output, parent: mdia, childType: "minf"),
              let stbl = ISOBoxSurgery.findChildBox(in: output, parent: minf, childType: "stbl"),
              let stsd = ISOBoxSurgery.findChildBox(in: output, parent: stbl, childType: "stsd"),
              let entry = ISOBoxSurgery.findAnyFirstChildBox(in: output, parent: stsd, contentSkip: 8)
        else {
            return XCTFail("patched tree must still walk to the sample entry")
        }
        XCTAssertEqual(moov.start + moov.size, output.count)
        for (outer, inner) in [(moov, trak), (trak, mdia), (mdia, minf),
                               (minf, stbl), (stbl, stsd), (stsd, entry)] {
            XCTAssertLessThanOrEqual(inner.start + inner.size, outer.start + outer.size)
        }

        guard let config = ISOBoxSurgery.findChildBox(
            in: output, parent: entry, childType: "dvcC", contentSkip: 78
        ) else {
            return XCTFail("dvcC must be reachable as a sample entry child")
        }
        XCTAssertEqual(config.size, 32)
        // Payload fields survive the repack: profile 5 in the high 7 bits of
        // byte 2 of the record, level 6 in the 6 bits that follow.
        XCTAssertEqual(output[config.start + 8], 1)   // dv_version_major
        XCTAssertEqual(output[config.start + 10], (5 << 1) | 0)
        XCTAssertEqual(output[config.start + 11], (6 << 3) | 0b101)  // level, rpu, bl
    }

    func testStaleConfigBoxOfTheOtherTypeIsReplaced() {
        let staleDvvC = Data([0x00, 0x00, 0x00, 0x20]) + "dvvC".data(using: .ascii)! + Data(count: 24)
        let input = initSegment(sampleEntryChildren: hvcCBox + staleDvvC)
        guard let output = ISOBoxSurgery.injectDolbyVisionConfig(
            into: input, doviBytes: record(profile: 5, level: 6, compatID: 0)
        ) else {
            return XCTFail("injection must succeed with a stale box present")
        }

        // Exactly one configuration box, and it is the Profile 5 spelling.
        XCTAssertEqual(configBoxes(in: output).map(\.type), ["hvcC", "dvcC"])
        XCTAssertEqual(output.count, input.count)
    }

    // MARK: - Refusals

    func testMalformedRecordLeavesTheSegmentUntouched() {
        let input = initSegment(sampleEntryChildren: hvcCBox)
        XCTAssertNil(ISOBoxSurgery.injectDolbyVisionConfig(into: input, doviBytes: Data([1, 0, 5])))
        XCTAssertNil(ISOBoxSurgery.buildDolbyVisionConfigBox(doviBytes: Data()))
    }

    func testMissingHvcCRefusesInjection() {
        let input = initSegment(sampleEntryChildren: Data())
        XCTAssertNil(ISOBoxSurgery.injectDolbyVisionConfig(
            into: input, doviBytes: record(profile: 5, level: 6, compatID: 0)
        ))
    }
}
