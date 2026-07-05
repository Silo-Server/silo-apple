//
//  ISOBoxSurgery.swift
//  Continuum (iOS + tvOS) — Dolby Vision Profile 5 AVPlayer route
//
//  Pure functions over ISO/IEC 14496-12 (ISO Base Media File Format) byte
//  buffers. `LoopbackSegmentWriter` uses these to post-process an fMP4 init segment
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

    /// First VCL IRAP NAL type (BLA 16-18, IDR 19-20, CRA 21, reserved IRAP
    /// 22-23) in a length-prefixed HEVC packet, or nil when the packet holds
    /// no IRAP. The matroska demuxer can deliver the head-of-stream IRAP
    /// without `AV_PKT_FLAG_KEY`; the bitstream is authoritative, so callers
    /// use this to repair the keyframe flag before gating on it.
    static func firstIRAPNALType(packetBytes: UnsafeBufferPointer<UInt8>,
                                 nalLengthSize: Int) -> Int? {
        guard nalLengthSize > 0 else { return nil }
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
            if (16...23).contains(nalType) {
                return nalType
            }
        }
        return nil
    }

    /// First VCL NAL type (0-31) in a length-prefixed HEVC packet, or nil
    /// when the packet holds no VCL NAL. Unlike `firstIRAPNALType`, this
    /// distinguishes "the opener is a non-IRAP picture" (a container key
    /// flag lying about a random-access point) from "nothing to judge".
    static func firstHEVCVCLNALType(packetBytes: UnsafeBufferPointer<UInt8>,
                                    nalLengthSize: Int) -> Int? {
        guard nalLengthSize > 0 else { return nil }
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
            if (0...31).contains(nalType) {
                return nalType
            }
        }
        return nil
    }

    /// First VCL NAL type (1-5) in a length-prefixed AVC packet, or nil when
    /// the packet holds no VCL NAL. Only IDR (type 5) is a clean cold-decode
    /// start for H.264 — container key flags can mark open-GOP I-frames or
    /// stale-cue targets as sync samples, and a fresh decode there renders
    /// inter-predicted blocks against missing references.
    static func firstAVCVCLNALType(packetBytes: UnsafeBufferPointer<UInt8>,
                                   nalLengthSize: Int) -> Int? {
        guard nalLengthSize > 0 else { return nil }
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
            guard nalSize >= 1 else { continue }
            let nalType = Int(nalStart.pointee) & 0x1F
            if (1...5).contains(nalType) {
                return nalType
            }
        }
        return nil
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
