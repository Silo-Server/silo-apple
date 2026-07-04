//
//  ISOBoxSurgery.swift
//  Continuum (iOS + tvOS) — Dolby Vision Profile 5 AVPlayer route
//
//  Pure functions over ISO/IEC 14496-12 (ISO Base Media File Format) byte
//  buffers. `DVSegmentWriter` uses these to post-process an fMP4 init segment
//  the FFmpeg mp4 muxer produces — the muxer in our build doesn't emit the
//  `dvvC` box required for Dolby Vision signalling, so we patch one in by
//  walking the box tree to find the video `hvcC` and inserting the `dvvC`
//  immediately after it (then bumping every ancestor container's size).
//
//  Also hosts the HEVC parameter-set NAL scanner and the `hvcC` atom builder:
//  MKV doesn't populate HEVC extradata with VPS/SPS/PPS (leaves a 23-byte
//  header with `numOfArrays=0`), so we grab them from the first video keyframe
//  and synthesise a complete `hvcC` for the muxer.
//
//  Everything here is static + data-in-data-out, so it's trivially testable
//  without the FFmpeg pipeline.
//
//  References:
//    - ISO/IEC 14496-12 (Boxes)
//    - ISO/IEC 14496-15 §8.3.3 (HEVCDecoderConfigurationRecord / hvcC)
//    - ETSI TS 103 572 (DOVIDecoderConfigurationRecord / dvvC)

import Foundation

enum ISOBoxSurgery {
    /// Byte range of a single ISO BMFF box within some `Data` buffer.
    /// `start` is the offset of the 4-byte size field; `size` is the box's
    /// total size including that header.
    struct Box {
        let start: Int
        let size: Int
    }

    // MARK: - Box tree walking

    /// Locate a top-level box (`ftyp`, `moov`, …) by FourCC by scanning from
    /// offset 0. Returns nil if absent or malformed.
    static func findTopLevelBox(in data: Data, type: String) -> Box? {
        var cursor = 0
        while cursor + 8 <= data.count {
            let size = Int(readU32BE(data, at: cursor))
            if size < 8 || cursor + size > data.count { return nil }
            let t = readFourCC(data, at: cursor + 4)
            if t == type { return Box(start: cursor, size: size) }
            cursor += size
        }
        return nil
    }

    /// Locate a child box by FourCC within a container box's contents.
    /// `contentSkip` is the number of bytes between the parent header and the
    /// first child box (e.g. 8 for `stsd` to skip its FullBox prefix).
    static func findChildBox(in data: Data, parent: Box, childType: String,
                             contentSkip: Int = 0) -> Box? {
        var cursor = parent.start + 8 + contentSkip
        let end = parent.start + parent.size
        while cursor + 8 <= end {
            let size = Int(readU32BE(data, at: cursor))
            if size < 8 || cursor + size > end { return nil }
            let t = readFourCC(data, at: cursor + 4)
            if t == childType { return Box(start: cursor, size: size) }
            cursor += size
        }
        return nil
    }

    /// Return the first child box of a container, whatever its FourCC.
    /// Useful for stsd sample entries where the FourCC varies
    /// (`dvh1` / `hvc1` / `hev1` / `dvhe`).
    static func findAnyFirstChildBox(in data: Data, parent: Box,
                                     contentSkip: Int = 0) -> Box? {
        let cursor = parent.start + 8 + contentSkip
        let end = parent.start + parent.size
        if cursor + 8 > end { return nil }
        let size = Int(readU32BE(data, at: cursor))
        if size < 8 || cursor + size > end { return nil }
        return Box(start: cursor, size: size)
    }

    /// Walk all `trak` children of `moov` and return the first one whose
    /// `mdia > hdlr` handler_type is `vide`. MKV sources often list audio
    /// first and FFmpeg preserves that ordering, so we can't assume the
    /// first `trak` is video.
    static func findVideoTrak(in data: Data, moov: Box) -> Box? {
        var cursor = moov.start + 8
        let end = moov.start + moov.size
        while cursor + 8 <= end {
            let size = Int(readU32BE(data, at: cursor))
            if size < 8 || cursor + size > end { return nil }
            let t = readFourCC(data, at: cursor + 4)
            if t == "trak" {
                let trak = Box(start: cursor, size: size)
                if isVideoTrak(in: data, trak: trak) {
                    return trak
                }
            }
            cursor += size
        }
        return nil
    }

    /// `hdlr` layout (ISO/IEC 14496-12 §8.4.3): 4-byte FullBox header
    /// (version + flags) then 4 bytes pre_defined (zero) then the 4-byte
    /// handler_type. For video tracks that's `vide`.
    static func isVideoTrak(in data: Data, trak: Box) -> Bool {
        guard let mdia = findChildBox(in: data, parent: trak, childType: "mdia") else { return false }
        guard let hdlr = findChildBox(in: data, parent: mdia, childType: "hdlr") else { return false }
        let typeOffset = hdlr.start + 16  // 8 box header + 4 FullBox + 4 pre_defined
        guard typeOffset + 4 <= hdlr.start + hdlr.size else { return false }
        return readFourCC(data, at: typeOffset) == "vide"
    }

    // MARK: - Box surgery

    /// Insert the given `dvvC` box immediately after the video track's
    /// `hvcC` box and adjust all ancestor container sizes by the inserted
    /// length. Returns nil if the expected tree shape isn't present —
    /// callers should ship the unmodified data rather than propagating a
    /// partial edit.
    static func injectDvvC(into data: Data, doviBytes: Data) -> Data? {
        guard let moov = findTopLevelBox(in: data, type: "moov") else { return nil }
        guard let trak = findVideoTrak(in: data, moov: moov) else { return nil }
        guard let mdia = findChildBox(in: data, parent: trak, childType: "mdia") else { return nil }
        guard let minf = findChildBox(in: data, parent: mdia, childType: "minf") else { return nil }
        guard let stbl = findChildBox(in: data, parent: minf, childType: "stbl") else { return nil }
        guard let stsd = findChildBox(in: data, parent: stbl, childType: "stsd") else { return nil }
        // stsd has an 8-byte FullBox header (version+flags+entry_count) before
        // its first child sample entry.
        guard let entry = findAnyFirstChildBox(in: data, parent: stsd, contentSkip: 8) else { return nil }
        // Visual sample entry has a 78-byte reserved/visual header before its
        // child boxes (8 SampleEntry + 70 VisualSampleEntry).
        guard let hvcC = findChildBox(in: data, parent: entry, childType: "hvcC", contentSkip: 78) else { return nil }

        let staleDVBoxes = childBoxes(in: data, parent: entry, contentSkip: 78)
            .filter { $0.type == "dvcC" || $0.type == "dvvC" }
        let insertionIndex = hvcC.start + hvcC.size
        let removedBeforeInsertion = staleDVBoxes
            .filter { $0.box.start < insertionIndex }
            .reduce(0) { $0 + $1.box.size }
        let removedBytes = staleDVBoxes.reduce(0) { $0 + $1.box.size }

        var out = data
        for stale in staleDVBoxes.sorted(by: { $0.box.start > $1.box.start }) {
            out.removeSubrange(stale.box.start ..< stale.box.start + stale.box.size)
        }

        let dvvCBox = buildDvvCBox(doviBytes: doviBytes)
        let adjustedInsertionIndex = insertionIndex - removedBeforeInsertion
        out.insert(contentsOf: dvvCBox, at: adjustedInsertionIndex)

        let delta = dvvCBox.count - removedBytes
        for box in [moov, trak, mdia, minf, stbl, stsd, entry] {
            addToBoxSize(in: &out, boxOffset: box.start, delta: delta)
        }
        return out
    }

    static func childBoxes(in data: Data, parent: Box, contentSkip: Int = 0) -> [(type: String, box: Box)] {
        var result: [(type: String, box: Box)] = []
        var cursor = parent.start + 8 + contentSkip
        let end = parent.start + parent.size
        while cursor + 8 <= end {
            let size = Int(readU32BE(data, at: cursor))
            if size < 8 || cursor + size > end { return result }
            let type = readFourCC(data, at: cursor + 4)
            result.append((type, Box(start: cursor, size: size)))
            cursor += size
        }
        return result
    }

    /// Build a 32-byte `dvvC` box from FFmpeg's DOVI decoder configuration
    /// record bytes. Layout (per ETSI TS 103 572 / ISO 14496-12):
    ///
    ///   u32 size = 32        (big-endian)
    ///   u32 'dvvC'
    ///   u8  dv_version_major
    ///   u8  dv_version_minor
    ///   u7  dv_profile
    ///   u6  dv_level
    ///   u1  rpu_present_flag
    ///   u1  el_present_flag
    ///   u1  bl_present_flag
    ///   u4  dv_bl_signal_compatibility_id
    ///   u28 reserved = 0
    ///   u32 reserved[4] = 0  (16 bytes of zeros)
    ///
    /// FFmpeg's `AVDOVIDecoderConfigurationRecord` stores each field as one
    /// byte in the order: version_major, version_minor, profile, level,
    /// rpu_flag, el_flag, bl_flag, bl_compat_id. We read those 8 bytes and
    /// repack into the on-disk bit layout.
    static func buildDvvCBox(doviBytes: Data) -> Data {
        guard doviBytes.count >= 8 else { return Data() }
        let versionMajor = doviBytes[0]
        let versionMinor = doviBytes[1]
        let profile      = doviBytes[2] & 0x7F
        let level        = doviBytes[3] & 0x3F
        let rpu          = doviBytes[4] & 0x01
        let el           = doviBytes[5] & 0x01
        let bl           = doviBytes[6] & 0x01
        let compatId     = doviBytes[7] & 0x0F

        var box = Data()
        box.append(contentsOf: [0x00, 0x00, 0x00, 0x20])    // size = 32
        box.append(contentsOf: [0x64, 0x76, 0x76, 0x43])    // 'dvvC'
        box.append(versionMajor)
        box.append(versionMinor)
        box.append((profile << 1) | ((level >> 5) & 0x01))
        box.append(((level & 0x1F) << 3) | (rpu << 2) | (el << 1) | bl)
        box.append((compatId & 0x0F) << 4)
        box.append(contentsOf: [0x00, 0x00, 0x00])
        box.append(Data(count: 16))
        return box
    }

    /// Build a full HVCC extradata from the source's 23-byte HVCC header and
    /// parsed VPS / SPS / PPS NAL units.
    ///
    /// Array layout per ISO/IEC 14496-15 §8.3.3.1.2:
    ///   u8  array_completeness(1) reserved(1) NAL_unit_type(6)
    ///   u16 numNalus
    ///     u16 nalUnitLength
    ///     u8[nalUnitLength] nalUnit
    static func buildHvcC(header: Data, vps: [Data], sps: [Data], pps: [Data]) -> Data {
        var out = Data()
        out.append(contentsOf: header.prefix(22))
        out.append(0x03)  // numOfArrays

        func appendArray(type: UInt8, nals: [Data]) {
            out.append(0x80 | type)  // array_completeness=1 | NAL_type
            let count = nals.count
            out.append(UInt8((count >> 8) & 0xFF))
            out.append(UInt8(count & 0xFF))
            for nal in nals {
                let n = nal.count
                out.append(UInt8((n >> 8) & 0xFF))
                out.append(UInt8(n & 0xFF))
                out.append(nal)
            }
        }
        appendArray(type: 32, nals: vps)
        appendArray(type: 33, nals: sps)
        appendArray(type: 34, nals: pps)
        return out
    }

    static func hvcCContainsParameterSets(_ data: Data) -> Bool {
        guard data.count >= 23 else { return false }
        var cursor = 23
        let arrayCount = Int(data[22])
        var hasVPS = false
        var hasSPS = false
        var hasPPS = false

        for _ in 0..<arrayCount {
            guard cursor + 3 <= data.count else { return false }
            let nalType = data[cursor] & 0x3F
            cursor += 1
            let nalCount = (Int(data[cursor]) << 8) | Int(data[cursor + 1])
            cursor += 2
            for _ in 0..<nalCount {
                guard cursor + 2 <= data.count else { return false }
                let nalSize = (Int(data[cursor]) << 8) | Int(data[cursor + 1])
                cursor += 2
                guard cursor + nalSize <= data.count else { return false }
                cursor += nalSize
            }
            switch nalType {
            case 32:
                hasVPS = nalCount > 0
            case 33:
                hasSPS = nalCount > 0
            case 34:
                hasPPS = nalCount > 0
            default:
                break
            }
        }

        return hasVPS && hasSPS && hasPPS
    }

    // MARK: - NAL parsing

    /// Parse length-prefixed NAL units out of one AVCC-style packet and
    /// collect any VPS / SPS / PPS into the provided arrays. Deduplicates
    /// identical NAL payloads. For HEVC, NAL type is bits 1-6 of byte 0:
    /// 32 = VPS, 33 = SPS, 34 = PPS.
    static func scanNALs(packetBytes: UnsafeBufferPointer<UInt8>,
                         nalLengthSize: Int,
                         vps: inout [Data],
                         sps: inout [Data],
                         pps: inout [Data]) {
        var offset = 0
        while offset + nalLengthSize <= packetBytes.count {
            var nalSize = 0
            for i in 0..<nalLengthSize {
                nalSize = (nalSize << 8) | Int(packetBytes[offset + i])
            }
            offset += nalLengthSize
            if nalSize <= 0 || offset + nalSize > packetBytes.count { break }
            let nalStart = packetBytes.baseAddress!.advanced(by: offset)
            offset += nalSize
            guard nalSize >= 2 else { continue }
            let nalType = (Int(nalStart.pointee) >> 1) & 0x3F
            switch nalType {
            case 32:
                let nalData = Data(bytes: nalStart, count: nalSize)
                if !vps.contains(nalData) { vps.append(nalData) }
            case 33:
                let nalData = Data(bytes: nalStart, count: nalSize)
                if !sps.contains(nalData) { sps.append(nalData) }
            case 34:
                let nalData = Data(bytes: nalStart, count: nalSize)
                if !pps.contains(nalData) { pps.append(nalData) }
            default: break
            }
        }
    }

    static func nalSummary(packetBytes: UnsafeBufferPointer<UInt8>,
                           nalLengthSize: Int,
                           limit: Int = 32) -> String {
        guard nalLengthSize > 0 else { return "invalid-nal-length" }
        var offset = 0
        var counts: [String: Int] = [:]
        var order: [String] = []
        var total = 0
        var truncated = false

        while offset + nalLengthSize <= packetBytes.count {
            var nalSize = 0
            for i in 0..<nalLengthSize {
                nalSize = (nalSize << 8) | Int(packetBytes[offset + i])
            }
            offset += nalLengthSize
            guard nalSize >= 2, offset + nalSize <= packetBytes.count else { break }
            let nalStart = packetBytes.baseAddress!.advanced(by: offset)
            let byte0 = nalStart.pointee
            let byte1 = nalStart.advanced(by: 1).pointee
            let nalType = Int((byte0 >> 1) & 0x3F)
            let layerID = Int(((byte0 & 0x01) << 5) | ((byte1 & 0xF8) >> 3))
            let key = "\(nalType)@L\(layerID)"
            if counts[key] == nil {
                order.append(key)
            }
            counts[key, default: 0] += 1
            total += 1
            offset += nalSize
            if total >= limit, offset + nalLengthSize <= packetBytes.count {
                truncated = true
                break
            }
        }

        guard !order.isEmpty else { return "none" }
        var parts = order.map { key in
            "\(key)x\(counts[key] ?? 0)"
        }
        if truncated {
            parts.append("...")
        }
        return parts.joined(separator: ",")
    }

    // MARK: - dec3 JOC extension (Atmos signalling)

    /// Walk all `trak` children of `moov` and return the first one whose
    /// `mdia > hdlr` handler_type is `soun`.
    static func findAudioTrak(in data: Data, moov: Box) -> Box? {
        var cursor = moov.start + 8
        let end = moov.start + moov.size
        while cursor + 8 <= end {
            let size = Int(readU32BE(data, at: cursor))
            if size < 8 || cursor + size > end { return nil }
            let t = readFourCC(data, at: cursor + 4)
            if t == "trak" {
                let trak = Box(start: cursor, size: size)
                if isAudioTrak(in: data, trak: trak) {
                    return trak
                }
            }
            cursor += size
        }
        return nil
    }

    static func isAudioTrak(in data: Data, trak: Box) -> Bool {
        guard let mdia = findChildBox(in: data, parent: trak, childType: "mdia") else { return false }
        guard let hdlr = findChildBox(in: data, parent: mdia, childType: "hdlr") else { return false }
        let typeOffset = hdlr.start + 16  // 8 box header + 4 FullBox + 4 pre_defined
        guard typeOffset + 4 <= hdlr.start + hdlr.size else { return false }
        return readFourCC(data, at: typeOffset) == "soun"
    }

    /// Rewrite the audio sample entry's `dec3` box into the ETSI layout with
    /// the E-AC-3 JOC extension (ETSI TS 103 420:
    /// `flag_ec3_extension_type_a` + `complexity_index_type_a`) and adjust
    /// every ancestor size. Two FFmpeg 7.1 muxer defects are corrected at
    /// once:
    ///
    ///  1. It never writes the JOC extension — the field AVFoundation keys
    ///     on to classify a track as Dolby Atmos.
    ///  2. Its substream entry writes FIVE reserved bits between `lfeon`
    ///     and `num_dep_sub` where ETSI TS 102 366 F.6 specifies THREE, so
    ///     everything after `lfeon` is bit-shifted versus what Apple
    ///     parses. (Simply appending the extension to the 7.1 payload put
    ///     the flag two bits past where Apple reads it — flag parsed as 0,
    ///     no Atmos. Device-verified.)
    ///
    /// The whole payload is therefore re-emitted bit-by-bit in the ETSI
    /// layout. Ground truth: FFmpeg 8.1 remuxing the identical device
    /// stream emits `1800200f000110`, pinned in ISOBoxSurgeryDec3Tests.
    ///
    /// Returns nil (caller ships the unmodified data) when the tree shape is
    /// missing, the sample entry isn't `ec-3`, or a valid ETSI-layout
    /// extension is already present (a future FFmpeg bump writes it
    /// natively). Whether the stream is actually JOC is the caller's call
    /// (`codecpar.profile == 30`) — the dec3 substream fields cannot tell:
    /// streaming DDP-Atmos carries JOC in the independent frame's EMDF with
    /// num_dep_sub = 0.
    static func appendDec3JOCExtension(into data: Data, complexityIndex: UInt8) -> Data? {
        guard let moov = findTopLevelBox(in: data, type: "moov") else { return nil }
        guard let trak = findAudioTrak(in: data, moov: moov) else { return nil }
        guard let mdia = findChildBox(in: data, parent: trak, childType: "mdia") else { return nil }
        guard let minf = findChildBox(in: data, parent: mdia, childType: "minf") else { return nil }
        guard let stbl = findChildBox(in: data, parent: minf, childType: "stbl") else { return nil }
        guard let stsd = findChildBox(in: data, parent: stbl, childType: "stsd") else { return nil }
        guard let entry = findAnyFirstChildBox(in: data, parent: stsd, contentSkip: 8) else { return nil }
        guard readFourCC(data, at: entry.start + 4) == "ec-3" else { return nil }
        // AudioSampleEntry: 8 SampleEntry bytes (6 reserved + 2
        // data_reference_index) + 20 AudioSampleEntry bytes (8 reserved +
        // 2 channelcount + 2 samplesize + 2 pre_defined + 2 reserved +
        // 4 samplerate) = 28 bytes before child boxes.
        guard let dec3 = findChildBox(in: data, parent: entry, childType: "dec3", contentSkip: 28) else { return nil }

        let payloadStart = dec3.start + 8
        let payloadCount = dec3.size - 8
        guard payloadCount >= 2 else { return nil }

        // Already in the ETSI layout with a valid extension (an FFmpeg ≥ 8
        // muxer writes both natively): leave untouched.
        if dec3PayloadHasETSIExtension(data: data, payloadStart: payloadStart, payloadCount: payloadCount) {
            return nil
        }

        // Parse FFmpeg 7.1's layout (5 reserved bits before num_dep_sub),
        // re-emit the ETSI layout (3 reserved bits) plus the JOC extension.
        // NOTE: no dependent-substream requirement — streaming DDP-Atmos
        // (the streaming 5.1-bed variant) carries JOC inside the
        // independent frame's EMDF metadata; num_dep_sub is 0 there.
        var reader = Dec3BitReader(data: data, byteOffset: payloadStart, byteCount: payloadCount)
        var writer = Dec3BitWriter()
        guard let dataRate = reader.read(13), let numIndSub = reader.read(3) else { return nil }
        writer.write(dataRate, bits: 13)
        writer.write(numIndSub, bits: 3)

        for _ in 0...Int(numIndSub) {
            guard let fscod = reader.read(2), let bsid = reader.read(5),
                  let reserved1 = reader.read(1), let asvc = reader.read(1),
                  let bsmod = reader.read(3), let acmod = reader.read(3),
                  let lfeon = reader.read(1), reader.read(5) != nil,
                  let numDepSub = reader.read(4) else { return nil }
            writer.write(fscod, bits: 2)
            writer.write(bsid, bits: 5)
            writer.write(reserved1, bits: 1)
            writer.write(asvc, bits: 1)
            writer.write(bsmod, bits: 3)
            writer.write(acmod, bits: 3)
            writer.write(lfeon, bits: 1)
            writer.write(0, bits: 3)  // ETSI reserved (7.1 wrongly wrote 5 bits)
            writer.write(numDepSub, bits: 4)
            if numDepSub > 0 {
                guard let chanLoc = reader.read(9) else { return nil }
                writer.write(chanLoc, bits: 9)
            } else {
                guard let reserved = reader.read(1) else { return nil }
                writer.write(reserved, bits: 1)
            }
        }

        writer.write(0, bits: 7)                       // reserved
        writer.write(1, bits: 1)                       // flag_ec3_extension_type_a
        writer.write(UInt32(complexityIndex), bits: 8) // complexity_index_type_a
        let newPayload = writer.flushed()

        var out = data
        out.replaceSubrange(payloadStart ..< payloadStart + payloadCount, with: newPayload)
        let delta = newPayload.count - payloadCount
        addToBoxSize(in: &out, boxOffset: dec3.start, delta: delta)
        for box in [moov, trak, mdia, minf, stbl, stsd, entry] {
            addToBoxSize(in: &out, boxOffset: box.start, delta: delta)
        }
        return out
    }

    /// True when the payload parses under the ETSI TS 102 366 layout
    /// (3 reserved bits before num_dep_sub) with a valid JOC extension
    /// (zero reserved bits, flag set) immediately after the substream loop.
    private static func dec3PayloadHasETSIExtension(
        data: Data, payloadStart: Int, payloadCount: Int
    ) -> Bool {
        var reader = Dec3BitReader(data: data, byteOffset: payloadStart, byteCount: payloadCount)
        guard reader.read(13) != nil, let numIndSub = reader.read(3) else { return false }
        for _ in 0...Int(numIndSub) {
            guard reader.read(2) != nil, reader.read(5) != nil,
                  reader.read(1) != nil, reader.read(1) != nil,
                  reader.read(3) != nil, reader.read(3) != nil,
                  reader.read(1) != nil, reader.read(3) != nil,
                  let numDepSub = reader.read(4) else { return false }
            if numDepSub > 0 {
                guard reader.read(9) != nil else { return false }
            } else {
                guard reader.read(1) != nil else { return false }
            }
        }
        guard reader.remainingBits >= 16,
              let reserved7 = reader.read(7), reserved7 == 0,
              let flag = reader.read(1), flag == 1 else { return false }
        return true
    }

    /// Minimal MSB-first bit reader over a byte range of `data`.
    struct Dec3BitReader {
        private let data: Data
        private var bit: Int
        private let endBit: Int

        init(data: Data, byteOffset: Int, byteCount: Int) {
            self.data = data
            self.bit = byteOffset * 8
            self.endBit = (byteOffset + byteCount) * 8
        }

        var remainingBits: Int { endBit - bit }

        mutating func read(_ count: Int) -> UInt32? {
            guard count > 0, count <= 32, count <= remainingBits else { return nil }
            var value: UInt32 = 0
            for _ in 0..<count {
                let byte = data[bit >> 3]
                let shift = 7 - (bit & 7)
                value = (value << 1) | UInt32((byte >> shift) & 1)
                bit += 1
            }
            return value
        }
    }

    /// Minimal MSB-first bit writer; `flushed()` zero-pads to a byte boundary.
    struct Dec3BitWriter {
        private var bytes: [UInt8] = []
        private var bitCount = 0

        mutating func write(_ value: UInt32, bits: Int) {
            for i in stride(from: bits - 1, through: 0, by: -1) {
                if bitCount & 7 == 0 { bytes.append(0) }
                let bitValue = UInt8((value >> UInt32(i)) & 1)
                bytes[bytes.count - 1] |= bitValue << (7 - UInt8(bitCount & 7))
                bitCount += 1
            }
        }

        func flushed() -> Data { Data(bytes) }
    }

    // MARK: - Byte helpers

    static func readU32BE(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    static func readU64BE(_ data: Data, at offset: Int) -> UInt64 {
        let high = UInt64(readU32BE(data, at: offset))
        let low = UInt64(readU32BE(data, at: offset + 4))
        return (high << 32) | low
    }

    static func readU24BE(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        return (b0 << 16) | (b1 << 8) | b2
    }

    static func readFourCC(_ data: Data, at offset: Int) -> String {
        let bytes: [UInt8] = [data[offset], data[offset + 1], data[offset + 2], data[offset + 3]]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    /// Adjust the big-endian u32 size field at the start of a box by `delta`.
    static func addToBoxSize(in data: inout Data, boxOffset: Int, delta: Int) {
        let current = Int(readU32BE(data, at: boxOffset))
        let updated = UInt32(current + delta)
        data[boxOffset]     = UInt8((updated >> 24) & 0xFF)
        data[boxOffset + 1] = UInt8((updated >> 16) & 0xFF)
        data[boxOffset + 2] = UInt8((updated >> 8) & 0xFF)
        data[boxOffset + 3] = UInt8(updated & 0xFF)
    }
}
