import AetherEngine
import AssKit
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

    private var renderer: AssRenderer?
    private var header: String?
    private var fonts: [FontAttachment] = []
    private var events: Set<Event> = []
    private var frame: Frame?
    private var revision: UInt64?

    func render(header: String, fonts: [FontAttachment], events incoming: [Event],
                revision: UInt64, time: Double, size: CGSize, scale: CGFloat) throws -> Frame? {
        guard time.isFinite, abs(time) < Double(Int64.max / 1_000),
              size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return nil }
        let nextEvents = self.revision == revision ? events : Set(incoming)
        // Aether prunes old cues and clears them at a seek. Rebuild on removal
        // so neither the font store nor the cue set grows for a whole session.
        if renderer == nil || self.header != header || self.fonts != fonts
            || !events.isSubset(of: nextEvents) {
            let next = try AssRenderer()
            try next.addFonts(fonts.map { AssMemoryFont(name: $0.filename, data: $0.data) })
            // Refresh the provider after installing the attachment font store.
            next.configureFonts(AssRendererConfiguration())
            let cleanHeader = header.replacingOccurrences(of: "\0", with: "")
            try next.loadTrack(Data(cleanHeader.utf8), checkReadOrder: false)
            renderer = next
            self.header = header
            self.fonts = fonts
            events = []
            frame = nil
        }
        guard let renderer else { return nil }
        if self.revision != revision || events.isEmpty {
            for event in incoming where !events.contains(event) {
                // Content + timestamps are the identity. Real MKVs reuse ReadOrder
                // zero, so libass's ReadOrder deduplication must stay disabled.
                try renderer.appendEvent(event.text, startTime: max(0, event.start),
                                         duration: event.end - max(0, event.start))
                events.insert(event)
            }
        }
        self.revision = revision
        let output = try renderer.render(AssRenderRequest(time: time, viewportSize: size, scale: scale))
        if case .changed(let patch) = output {
            // Every patch includes the complete current image and transparent
            // pixels over the previous bounds, so replace the overlay atomically.
            if patch.data.isEmpty {
                frame = nil
            } else if let provider = CGDataProvider(data: patch.data as CFData),
                      let image = CGImage(width: patch.pixelWidth, height: patch.pixelHeight,
                          bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: patch.bytesPerRow,
                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                            .union(.byteOrder32Little), provider: provider, decode: nil,
                          shouldInterpolate: false, intent: .defaultIntent) {
                frame = Frame(image: image, rect: patch.rect)
            } else {
                throw AssKitError.renderFailed(-1)
            }
        }
        return frame
    }
}
