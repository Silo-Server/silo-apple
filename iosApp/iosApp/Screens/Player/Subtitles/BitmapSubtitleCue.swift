//
//  BitmapSubtitleCue.swift
//  Continuum (Apple platforms)
//
//  Pure model + conversion helpers for embedded bitmap subtitles
//  (PGS, DVD "VobSub"). The FFmpeg extractor hands over paletted index
//  planes; everything in this file is plain Foundation/CoreGraphics so
//  the premultiply and cue-timing logic stays unit-testable without a
//  decoder in the loop.
//

import CoreGraphics
import Foundation

/// One decoded bitmap subtitle image plus its display window.
///
/// `normalizedFrame` is the image's position within the subtitle canvas
/// (== video frame), top-left origin, every component in 0...1. The
/// overlay pump multiplies it by the current video rect at present time,
/// so cues survive layout/rotation changes without re-decoding.
struct BitmapSubtitleCue {
    let startSeconds: Double
    /// Mutable: PGS "next event trims the previous one" semantics shorten
    /// an already-stored cue when the following composition arrives.
    var endSeconds: Double
    let image: CGImage
    let normalizedFrame: CGRect
}

/// PAL8 → premultiplied RGBA conversion for FFmpeg bitmap subtitle rects.
enum BitmapSubtitlePalette {

    /// Converted pixel data cropped to the opaque bounding box.
    /// `cropX`/`cropY` are offsets into the original plane, so callers
    /// add them to the rect origin when positioning the image.
    struct ConvertedPlane {
        let rgba: [UInt8]
        let cropX: Int
        let cropY: Int
        let cropWidth: Int
        let cropHeight: Int
    }

    /// Round-half-up premultiplication of one channel by alpha.
    static func premultiply(_ channel: UInt8, by alpha: UInt8) -> UInt8 {
        UInt8((Int(channel) * Int(alpha) + 127) / 255)
    }

    /// Convert a paletted subtitle plane into premultiplied RGBA bytes,
    /// cropped to the bounding box of pixels whose palette alpha is at
    /// least `alphaFloor`.
    ///
    /// - `indexPlane`: PAL8 palette indexes, `stride` bytes per row.
    /// - `palette`: 256 four-byte entries. FFmpeg stores each entry as a
    ///   native-endian 32-bit 0xAARRGGBB value, which on little-endian
    ///   Apple hardware lays out in memory as [B, G, R, A].
    /// - `alphaFloor`: some Blu-ray→MKV remuxes ship full-frame planes
    ///   that are almost entirely transparent (megabytes per cue);
    ///   cropping against a small alpha floor keeps images tight.
    ///
    /// Returns nil when no pixel reaches `alphaFloor` (nothing visible)
    /// or the geometry is malformed (a stride shorter than the width
    /// would over-read every row).
    static func premultipliedRGBA(
        indexPlane: UnsafePointer<UInt8>,
        width: Int,
        height: Int,
        stride: Int,
        palette: UnsafePointer<UInt8>,
        alphaFloor: UInt8 = 8
    ) -> ConvertedPlane? {
        guard width > 0, height > 0, stride >= width else { return nil }

        // Pass 1: opaque bounding box.
        var left = width
        var top = height
        var right = -1
        var bottom = -1
        for row in 0..<height {
            let rowBase = row * stride
            for col in 0..<width {
                let entry = Int(indexPlane[rowBase + col]) * 4
                if palette[entry + 3] >= alphaFloor {
                    if col < left { left = col }
                    if col > right { right = col }
                    if row < top { top = row }
                    if row > bottom { bottom = row }
                }
            }
        }
        guard right >= left, bottom >= top else { return nil }

        // Pass 2: palette lookup + premultiply into the cropped box.
        let cropWidth = right - left + 1
        let cropHeight = bottom - top + 1
        var rgba = [UInt8](repeating: 0, count: cropWidth * cropHeight * 4)
        for row in 0..<cropHeight {
            let srcBase = (top + row) * stride + left
            let dstBase = row * cropWidth * 4
            for col in 0..<cropWidth {
                let entry = Int(indexPlane[srcBase + col]) * 4
                let alpha = palette[entry + 3]
                let out = dstBase + col * 4
                // Palette is [B, G, R, A]; output is RGBA. Premultiplied
                // because straight alpha draws dark fringes around glyph
                // edges once CoreAnimation composites the layer.
                rgba[out] = premultiply(palette[entry + 2], by: alpha)
                rgba[out + 1] = premultiply(palette[entry + 1], by: alpha)
                rgba[out + 2] = premultiply(palette[entry], by: alpha)
                rgba[out + 3] = alpha
            }
        }
        return ConvertedPlane(
            rgba: rgba,
            cropX: left,
            cropY: top,
            cropWidth: cropWidth,
            cropHeight: cropHeight
        )
    }

    /// Array-based convenience for callers (and tests) holding Swift
    /// buffers. Validates buffer sizes before dropping to pointers.
    static func premultipliedRGBA(
        indexes: [UInt8],
        width: Int,
        height: Int,
        stride: Int,
        palette: [UInt8],
        alphaFloor: UInt8 = 8
    ) -> ConvertedPlane? {
        guard width > 0, height > 0, stride >= width,
              indexes.count >= (height - 1) * stride + width,
              palette.count >= 256 * 4 else { return nil }
        return indexes.withUnsafeBufferPointer { indexBuffer in
            palette.withUnsafeBufferPointer { paletteBuffer in
                guard let indexBase = indexBuffer.baseAddress,
                      let paletteBase = paletteBuffer.baseAddress else { return nil }
                return premultipliedRGBA(
                    indexPlane: indexBase,
                    width: width,
                    height: height,
                    stride: stride,
                    palette: paletteBase,
                    alphaFloor: alphaFloor
                )
            }
        }
    }

    /// Bake a converted plane into a premultiplied-alpha sRGB CGImage.
    static func makeImage(from plane: ConvertedPlane) -> CGImage? {
        guard plane.cropWidth > 0, plane.cropHeight > 0,
              plane.rgba.count == plane.cropWidth * plane.cropHeight * 4,
              let provider = CGDataProvider(data: Data(plane.rgba) as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        return CGImage(
            width: plane.cropWidth,
            height: plane.cropHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: plane.cropWidth * 4,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

/// Thread-safe store for the decoded bitmap cues of one subtitle slot.
///
/// The extractor's decode loop inserts cues from a background queue while
/// the display-link pump reads the active set at vsync rate, so access is
/// lock-guarded. `currentRevision` increments on every observable change
/// so readers can cheaply detect "nothing new since last tick".
final class BitmapSubtitleCueStore {

    /// Cues whose end falls this far behind the newest event are dropped.
    /// Bitmap decoders never revisit old compositions, so a short tail is
    /// only needed to ride out clock jitter around the playhead.
    private let retentionSeconds: Double
    /// Hard cap on retained cues — memory guard against pathological
    /// event-dense tracks (karaoke-style PGS).
    private let maxCueCount: Int

    private let lock = NSLock()
    /// Sorted by `startSeconds`. Guarded by `lock`.
    private var cues: [BitmapSubtitleCue] = []
    private var revision: UInt64 = 0

    init(retentionSeconds: Double = 30, maxCueCount: Int = 128) {
        self.retentionSeconds = retentionSeconds
        self.maxCueCount = maxCueCount
    }

    var currentRevision: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return revision
    }

    var cueCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cues.count
    }

    /// Insert freshly decoded cues and apply event semantics.
    ///
    /// `trimActiveAt` implements the PGS model where every composition —
    /// including an empty "clear" event — supersedes whatever is showing:
    /// any stored cue spanning that timestamp gets its end trimmed down to
    /// it. Pass nil for codecs with explicit durations (DVD).
    ///
    /// Cues with a non-positive duration are ignored. Retention pruning
    /// and the count cap run inside the same critical section.
    func apply(cues newCues: [BitmapSubtitleCue], trimActiveAt trimSeconds: Double? = nil) {
        lock.lock()
        defer { lock.unlock() }
        var mutated = false

        if let trimSeconds {
            for i in cues.indices
            where cues[i].startSeconds < trimSeconds && cues[i].endSeconds > trimSeconds {
                cues[i].endSeconds = trimSeconds
                mutated = true
            }
        }

        for cue in newCues where cue.endSeconds > cue.startSeconds {
            cues.insert(cue, at: insertionIndex(for: cue.startSeconds))
            mutated = true
        }

        // Prune against the newest event time we know about; a feed that
        // carries neither cues nor a trim has no time reference and skips
        // pruning.
        let newestStart = newCues.map(\.startSeconds).max()
        if let reference = [trimSeconds, newestStart].compactMap({ $0 }).max() {
            let cutoff = reference - retentionSeconds
            let beforeCount = cues.count
            cues.removeAll { $0.endSeconds < cutoff }
            if cues.count != beforeCount { mutated = true }
        }
        if cues.count > maxCueCount {
            cues.removeFirst(cues.count - maxCueCount)
            mutated = true
        }

        if mutated { revision &+= 1 }
    }

    /// Cues visible at `seconds` (start inclusive, end exclusive).
    func activeCues(at seconds: Double) -> [BitmapSubtitleCue] {
        lock.lock()
        defer { lock.unlock() }
        var active: [BitmapSubtitleCue] = []
        for cue in cues {
            if cue.startSeconds > seconds { break }
            if seconds < cue.endSeconds {
                active.append(cue)
            }
        }
        return active
    }

    /// Drop everything (seek/flush/teardown).
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        guard !cues.isEmpty else { return }
        cues.removeAll()
        revision &+= 1
    }

    /// First index whose start is greater than `startSeconds` (stable for
    /// equal starts: new cue lands after existing peers). Callers must
    /// hold `lock`.
    private func insertionIndex(for startSeconds: Double) -> Int {
        var low = 0
        var high = cues.count
        while low < high {
            let mid = (low + high) / 2
            if cues[mid].startSeconds <= startSeconds {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}
