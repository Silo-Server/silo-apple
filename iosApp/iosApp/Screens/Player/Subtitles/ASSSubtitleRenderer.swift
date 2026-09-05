import AetherEngine
import SwiftAssRenderer
import SwiftLibass
import CoreGraphics
import Foundation

/// One libass instance, confined to its actor. Aether owns demux and timing;
/// libass owns authored layout, fonts, drawings, karaoke, and animation.
actor ASSSubtitleRenderer {
    struct Event: Hashable, Sendable {
        let text: String
        let start: Double
        let end: Double

        static func events(from cues: [SubtitleCue]) -> [Event] {
            cues.flatMap { cue -> [Event] in
                guard case .text(let raw) = cue.body,
                      cue.startTime.isFinite, cue.endTime.isFinite,
                      cue.endTime > max(0, cue.startTime) else { return [] }
                return raw.split(separator: "\n").compactMap { line in
                    let fields = line.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
                    guard fields.count == 9, Int(fields[0]) != nil else { return nil }
                    return Event(text: String(line), start: cue.startTime, end: cue.endTime)
                }
            }
        }
    }

    struct Frame: @unchecked Sendable {
        let image: CGImage
        let rect: CGRect
    }

    private enum RenderError: Error {
        case initializationFailed
        case invalidData
        case imageFailed
    }

    /// Own the C allocations explicitly. The convenience renderer in
    /// swift-ass-renderer 1.3.1 copies ASS_Track values and does not free the
    /// parsed tracks; streamed updates need bounded lifetime and incremental input.
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

    private var renderer: Track?
    private let pipeline = BlendImagePipeline()
    private var header: String?
    private var fonts: [FontAttachment] = []
    private var events: Set<Event> = []
    private var frame: Frame?
    private var revision: UInt64?
    private var canvasScale: CGFloat?

    func render(header: String, fonts: [FontAttachment], events incoming: [Event],
                revision: UInt64, time: Double, size: CGSize, scale: CGFloat) throws -> Frame? {
        guard time.isFinite, abs(time) < Double(Int64.max / 1_000),
              size.width.isFinite, size.height.isFinite, scale.isFinite, scale > 0,
              size.width > 0, size.height > 0,
              size.width * scale < CGFloat(Int32.max),
              size.height * scale < CGFloat(Int32.max) else { return nil }
        let cleanHeader = header.replacingOccurrences(of: "\0", with: "")
        let nextEvents = self.revision == revision ? events : Set(incoming)
        // Aether prunes old cues and clears them at a seek. Rebuild on removal
        // so neither the font store nor the cue set grows for a whole session.
        if renderer == nil || self.header != cleanHeader || self.fonts != fonts
            || !events.isSubset(of: nextEvents) {
            renderer = try Track(header: cleanHeader, fonts: fonts)
            self.header = cleanHeader
            self.fonts = fonts
            events = []
            frame = nil
        }
        guard let renderer else { return nil }
        if self.revision != revision || events.isEmpty {
            for event in incoming where !events.contains(event) {
                let start = max(0, event.start)
                let duration = event.end - start
                guard start.isFinite, duration.isFinite, duration > 0,
                      start < Double(Int64.max / 1_000), duration < Double(Int64.max / 1_000) else {
                    throw RenderError.invalidData
                }
                var bytes = Array(event.text.utf8CString)
                guard bytes.count <= Int32.max else { throw RenderError.invalidData }
                let length = Int32(bytes.count - 1)
                bytes.withUnsafeMutableBufferPointer {
                    ass_process_chunk(renderer.track, $0.baseAddress, length,
                                      Int64(start * 1_000), Int64(duration * 1_000))
                }
                events.insert(event)
            }
        }
        self.revision = revision
        ass_set_frame_size(renderer.renderer, Int32(size.width * scale), Int32(size.height * scale))
        var changed: Int32 = 0
        let first = ass_render_frame(renderer.renderer, renderer.track, Int64(time * 1_000), &changed)
        guard changed != 0 || canvasScale != scale else { return frame }
        canvasScale = scale
        guard let first else {
            frame = nil
            return nil
        }
        let images = linkedImages(from: first.pointee).filter { $0.w > 0 && $0.h > 0 }
        guard !images.isEmpty else {
            frame = nil
            return nil
        }
        guard let output = pipeline.process(images: images, boundingRect: imagesBoundingRect(images: images)) else {
            throw RenderError.imageFailed
        }
        let rect = CGRect(x: output.imageRect.minX / scale, y: output.imageRect.minY / scale,
                          width: output.imageRect.width / scale, height: output.imageRect.height / scale)
        frame = Frame(image: output.image, rect: rect)
        return frame
    }
}
