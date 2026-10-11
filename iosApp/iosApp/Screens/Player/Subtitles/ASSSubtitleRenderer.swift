import AetherEngine
import CoreGraphics
import CoreVideo
import Foundation
import SwiftLibass

/// One libass instance and the canvases it draws into. Aether owns demux and
/// timing; libass owns authored layout, fonts, drawings, karaoke, and animation.
///
/// Not thread-safe: `ASSOverlayPresenter` confines it to its actor.
final class ASSSubtitleRenderer {
    /// One Aether cue's raw ASS event lines.
    struct Cue: Sendable, Equatable {
        let id: Int
        let start: Double
        let end: Double
        let lines: [String]

        /// Matroska event lines (`ReadOrder,Layer,Style,…,Text`) from a raw
        /// text cue whose window libass can take.
        static func lines(of cue: SubtitleCue) -> [String] {
            guard case .text(let raw) = cue.body, hasUsableWindow(start: cue.startTime, end: cue.endTime) else {
                return []
            }
            return lines(fromRaw: raw)
        }

        static func lines(fromRaw raw: String) -> [String] {
            raw.split(separator: "\n").compactMap { line in
                let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
                guard fields.count == 9, Int(fields[0]) != nil else { return nil }
                return String(line)
            }
        }

        /// Finite, positive in length, and within libass's millisecond range.
        static func hasUsableWindow(start: Double, end: Double) -> Bool {
            let limit = Double(Int64.max / 1_000)
            return start.isFinite && end.isFinite && abs(start) < limit && abs(end) < limit && end > max(0, start)
        }
    }

    /// Output size in pixels.
    struct Canvas: Hashable, Sendable {
        let width: Int
        let height: Int

        var isValid: Bool { width > 0 && height > 0 && width <= 16_384 && height <= 16_384 }
    }

    enum Output {
        /// Same pixels as the previous render.
        case unchanged
        /// Nothing to draw at this time.
        case empty
        case frame(CVPixelBuffer)
        /// Every canvas is still queued for display. The next render repeats
        /// this one, even if libass reports no change.
        case unavailable
    }

    enum RenderError: Error {
        case initializationFailed
        case invalidData
    }

    /// Canvases in flight: rendered ahead, queued, or on screen.
    static let maximumCanvases = 10
    /// A cue Aether drops this long after it ended has aged out of its retained
    /// window. Anything more recent was retracted and restarts the event list.
    static let agedOutSeconds: Double = 60
    /// Aged-out events kept for a backward seek, beyond the cues Aether retains.
    static let maximumRetiredEvents = 20_000

    /// Own the C allocations explicitly: the library, renderer and track are
    /// freed together, in order, when the header or fonts change.
    private final class Track {
        let library: OpaquePointer
        let renderer: OpaquePointer
        let track: UnsafeMutablePointer<ASS_Track>

        init(header: String, fonts: [FontAttachment]) throws {
            // Validate before allocating native resources so rejected input owns nothing.
            for font in fonts {
                guard !font.data.isEmpty, font.data.count <= Int32.max else { throw RenderError.invalidData }
            }
            var bytes = Array(header.utf8CString)
            guard bytes.count <= Int32.max else { throw RenderError.invalidData }
            let length = Int32(bytes.count - 1)

            guard let library = ass_library_init() else { throw RenderError.initializationFailed }
            guard let renderer = ass_renderer_init(library) else {
                ass_library_done(library)
                throw RenderError.initializationFailed
            }
            guard let track = ass_new_track(library) else {
                ass_renderer_done(renderer)
                ass_library_done(library)
                throw RenderError.initializationFailed
            }
            self.library = library
            self.renderer = renderer
            self.track = track
            // Subtitle text and attachment names must not enter diagnostic logs.
            ass_set_message_cb(library, { _, _, _, _ in }, nil)
            for font in fonts {
                font.data.withUnsafeBytes { bytes in
                    ass_add_font(library, font.filename,
                                 bytes.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(bytes.count))
                }
            }
            ass_set_fonts(renderer, nil, "Helvetica", Int32(ASS_FONTPROVIDER_CORETEXT.rawValue), nil, 1)
            bytes.withUnsafeMutableBufferPointer { ass_process_codec_private(track, $0.baseAddress, length) }
            ass_set_check_readorder(track, 0)
        }

        deinit {
            ass_free_track(track)
            ass_renderer_done(renderer)
            ass_library_done(library)
        }
    }

    /// Libass keys an event by its text and its millisecond window. Matroska
    /// ReadOrder is part of the text but repeats across overlapping events, so
    /// libass's own ReadOrder check stays off and this set deduplicates instead.
    private struct Event: Hashable {
        let text: String
        let start: Int64
        let duration: Int64
    }

    private var track: Track?
    /// The last header passed in and its NUL-stripped form.
    private var incomingHeader: String?
    private var cleanedHeader = ""
    /// The cleaned header the current `track` was built with.
    private var header: String?
    private var fonts: [FontAttachment] = []
    /// Every cue libass holds, by Aether cue id, as it was handed over.
    private var ingested: [Int: Cue] = [:]
    private var events: Set<Event> = []
    private var canvas: Canvas?
    private var pool: CVPixelBufferPool?
    private var emptyCanvas: CVPixelBuffer?
    private var repeatNextRender = false

    /// Feeds libass the cues it has not seen.
    ///
    /// Aether republishes its whole retained array on every change. New cues are
    /// appended to the existing track. Cues Aether prunes after they age out stay
    /// in libass for a backward seek. A cue that disappears while it can still be
    /// drawn, or comes back under the same id with other timing or text (a
    /// reloaded sidecar numbers its cues from zero again), restarts the event
    /// list, keeping the renderer's font and glyph caches. So does `replacing`,
    /// for a reload whose cues supersede everything libass holds. Only a new
    /// header or font set rebuilds libass itself.
    ///
    /// Returns whether frames in `window` (seconds on the cue clock) may now
    /// render differently, so frames already queued for that span are stale.
    func update(header: String, fonts: [FontAttachment], cues: [Cue], window: ClosedRange<Double>,
                replacing: Bool = false) throws -> Bool {
        if incomingHeader != header {
            incomingHeader = header
            cleanedHeader = header.replacingOccurrences(of: "\0", with: "")
        }
        var affectsWindow = false
        if track == nil || self.header != cleanedHeader || self.fonts != fonts {
            track = try Track(header: cleanedHeader, fonts: fonts)
            self.header = cleanedHeader
            self.fonts = fonts
            ingested = [:]
            events = []
            canvas = nil
            affectsWindow = true
        }
        guard let track else { return affectsWindow }

        var incoming: [Int: Cue] = [:]
        incoming.reserveCapacity(cues.count)
        for cue in cues { incoming[cue.id] = cue }
        let restarts = replacing || ingested.contains { id, cue in
            guard let current = incoming[id] else {
                return cue.end > window.lowerBound - Self.agedOutSeconds
            }
            return current != cue
        }
        if restarts || ingested.count > incoming.count + Self.maximumRetiredEvents {
            ass_flush_events(track.track)
            ingested = [:]
            events = []
            affectsWindow = true
        }

        for cue in cues where ingested[cue.id] == nil {
            guard Cue.hasUsableWindow(start: cue.start, end: cue.end) else { throw RenderError.invalidData }
            let start = Int64((max(0, cue.start) * 1_000).rounded())
            let duration = Int64((cue.end * 1_000).rounded()) - start
            guard duration > 0 else { throw RenderError.invalidData }
            ingested[cue.id] = cue
            if cue.start <= window.upperBound, cue.end > window.lowerBound { affectsWindow = true }
            for line in cue.lines {
                let event = Event(text: line, start: start, duration: duration)
                guard events.insert(event).inserted else { continue }
                var bytes = Array(line.utf8CString)
                guard bytes.count <= Int32.max else { throw RenderError.invalidData }
                let length = Int32(bytes.count - 1)
                bytes.withUnsafeMutableBufferPointer {
                    ass_process_chunk(track.track, $0.baseAddress, length, start, duration)
                }
            }
        }
        return affectsWindow
    }

    /// Clears every event, keeping libass and its caches.
    func removeAllEvents() {
        guard let track, !ingested.isEmpty else { return }
        ass_flush_events(track.track)
        ingested = [:]
        events = []
    }

    /// Renders the subtitles at `time` (seconds on the cue clock).
    ///
    /// `force` draws even when libass reports the same output as the previous
    /// call, for a layer that has just been emptied.
    func render(time: Double, canvas: Canvas, force: Bool) -> Output {
        guard let track, canvas.isValid, time.isFinite, abs(time) < Double(Int64.max / 1_000) else {
            return force ? .empty : .unchanged
        }
        var force = force || repeatNextRender
        if canvas != self.canvas {
            ass_set_frame_size(track.renderer, Int32(canvas.width), Int32(canvas.height))
            self.canvas = canvas
            pool = Self.makePool(canvas)
            force = true
        }
        var changed: Int32 = 0
        let images = ass_render_frame(track.renderer, track.track, Self.libassMilliseconds(time), &changed)
        guard changed != 0 || force else { return .unchanged }
        guard Self.hasPixels(images) else {
            repeatNextRender = false
            return .empty
        }
        guard let pool, let buffer = Self.makeBuffer(from: pool) else {
            repeatNextRender = true
            return .unavailable
        }
        repeatNextRender = false
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return .empty }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        memset(base, 0, bytesPerRow * height)
        ASSImageCompositor.composite(images, into: base, width: CVPixelBufferGetWidth(buffer),
                                     height: height, bytesPerRow: bytesPerRow)
        return .frame(buffer)
    }

    /// A small transparent canvas that clears the overlay when queued.
    func transparentCanvas() -> CVPixelBuffer? {
        if let emptyCanvas { return emptyCanvas }
        guard let pool = Self.makePool(Canvas(width: 2, height: 2)),
              let buffer = Self.makeBuffer(from: pool) else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        emptyCanvas = buffer
        return buffer
    }

    /// Libass's clock for a frame timestamp: truncated, as FFmpeg's subtitle
    /// filters do, so an event that starts on the next whole millisecond waits
    /// for the frame it was timed to. Rounding would show it on the frame
    /// before (23.976 fps frame 199 sits at 8.29996 s). The epsilon absorbs
    /// floating-point error at timestamps that are whole milliseconds.
    static func libassMilliseconds(_ seconds: Double) -> Int64 {
        Int64((seconds * 1_000 + 1e-6).rounded(.down))
    }

    private static func hasPixels(_ images: UnsafeMutablePointer<ASS_Image>?) -> Bool {
        var next = images
        while let image = next {
            if image.pointee.w > 0, image.pointee.h > 0, image.pointee.color & 0xFF != 0xFF { return true }
            next = image.pointee.next
        }
        return false
    }

    private static func makePool(_ canvas: Canvas) -> CVPixelBufferPool? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: canvas.width,
            kCVPixelBufferHeightKey: canvas.height,
            kCVPixelBufferIOSurfacePropertiesKey: [CFString: Any](),
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        return pool
    }

    private static func makeBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        let limit = [kCVPixelBufferPoolAllocationThresholdKey: maximumCanvases] as CFDictionary
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, limit, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVBufferSetAttachment(buffer, kCVImageBufferAlphaChannelModeKey,
                              kCVImageBufferAlphaChannelMode_PremultipliedAlpha, .shouldPropagate)
        if let sRGB = CGColorSpace(name: CGColorSpace.sRGB) {
            CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, sRGB, .shouldPropagate)
        }
        return buffer
    }
}
