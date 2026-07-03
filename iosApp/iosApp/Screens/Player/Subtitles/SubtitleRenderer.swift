//
//  SubtitleRenderer.swift
//  Continuum (iOS + tvOS)
//
//  libass wrapper and frame compositor. Owns the singleton `ASS_Library`
//  plus one `ASS_Renderer` per subtitle slot for the current playback
//  session. libass style overrides are renderer-scoped, so primary and
//  secondary tracks must not share a renderer when one track is authored
//  ASS and the other is Silo-styled generated ASS. All libass API calls
//  are serialised through `sessionQueue` because libass is not thread-safe.
//
//  The compositor path:
//
//    1. The active playback backend's display pump dispatches onto
//       `sessionQueue`.
//    2. `render(atMilliseconds:frameSize:scale:)` calls `ass_render_frame`
//       for each slot, checks `detect_change`, and if dirty composites
//       the `ASS_Image*` linked lists into a single `CGImage`.
//    3. The caller hops the `CGImage` back onto main and assigns it to
//       the overlay view's `CALayer.contents`.
//
//  The compositor uses a single-buffer `CGContext` because subtitles are
//  sparse — most frames report `detect_change == 0` and skip the
//  composite entirely.
//

import CoreGraphics
import Foundation
import Libass
import OSLog
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Per-slot libass track state. Wrapped in a class so track mutations
/// and `ass_free_track` on drop are keyed off a reference, not a value.
/// ARC keeps the handle alive across queue hops even if another hop
/// drops the slot.
///
/// `ASS_Track` is a fully-exposed C struct (its layout lives in
/// `ass_types.h`), so Swift imports pointers to it as
/// `UnsafeMutablePointer<ASS_Track>`. `ASS_Library` and `ASS_Renderer`
/// are opaque forward-declared structs and come across as
/// `OpaquePointer`.
final class ASSTrackHandle {
    let ptr: UnsafeMutablePointer<ASS_Track>
    let isNativeASS: Bool   // true iff codec is ASS/SSA (author-styled)
    let flushesOnSeek: Bool

    init(ptr: UnsafeMutablePointer<ASS_Track>, isNativeASS: Bool, flushesOnSeek: Bool) {
        self.ptr = ptr
        self.isNativeASS = isNativeASS
        self.flushesOnSeek = flushesOnSeek
    }

    deinit {
        ass_free_track(ptr)
    }
}

/// Result of a render call. `image` is the composited `CGImage` when
/// `isDirty` is true; otherwise it's the previous frame (caller should
/// skip assigning it to the overlay).
struct SubtitleRenderOutput {
    let image: CGImage?
    let isDirty: Bool
    /// Whether libass produced an image list for *this* timestamp, i.e. a cue
    /// is actually being rasterized right now — independent of `isDirty` (which
    /// only flags a change since the previous frame). Used by the live-subtitle
    /// diagnostic to tell "cue painted" from "cue fed but rendered nothing"
    /// (e.g. a font/shaping miss).
    var hasContent: Bool = false
}

final class SubtitleRenderer {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "SubtitleRenderer"
    )
    private static let sessionQueueKey = DispatchSpecificKey<String>()
    private let sessionQueueID = UUID().uuidString

    /// Serial queue guarding all libass state. All `ass_*` calls run
    /// here — no exceptions.
    let sessionQueue = DispatchQueue(
        label: "com.continuum.subtitle.session",
        qos: .userInitiated
    )
    // Opaque pointers to the underlying C objects. `OpaquePointer` is
    // required because the libass C types aren't importable as Swift
    // types through the binary xcframework.
    private var library: OpaquePointer?          // ASS_Library*
    private var primaryRenderer: OpaquePointer?  // ASS_Renderer*
    private var secondaryRenderer: OpaquePointer? // ASS_Renderer*

    // Slot tracks. Protected by `handleLock` so main-thread reads
    // (triggered from `layoutSubviews` for frame-size invalidation) can
    // snapshot them without racing with `sessionQueue` mutations.
    private let handleLock = NSLock()
    private var primary: ASSTrackHandle?
    private var secondary: ASSTrackHandle?

    // Cached frame/storage size in pixels. Only updated when it changes
    // so we don't churn libass's internal caches.
    private var lastWidth: Int32 = 0
    private var lastHeight: Int32 = 0
    /// libass margins in pixels: distance from the overlay frame's edges to
    /// the displayed video rect. Non-zero only when the host sizes the
    /// overlay beyond the video (tvOS full-frame overlay).
    private var lastMarginTop: Int32 = 0
    private var lastMarginBottom: Int32 = 0
    private var lastMarginLeft: Int32 = 0
    private var lastMarginRight: Int32 = 0
    private var frameSizeDirty = false

    // Most recent user styling params per slot. Re-applied after any
    // track swap (since overrides live on the renderer, not the track,
    // but native-ASS tracks need a different treatment).
    private var currentParams: SubtitleStylingOverride.Parameters = .default

    /// libass keys font scaling to the video area (frame minus letterbox
    /// margins), which makes Silo-styled text shrink on wide-aspect content.
    /// This multiplier re-keys the scale to the full frame height so text
    /// size stays constant on screen. 1.0 whenever margins are zero.
    private var fontScaleCompensation: Double = 1.0

    // Output canvas. Allocated lazily at the requested pixel size and
    // reused across frames. A single mutable buffer feeds a single
    // `CGContext`; the `CGImage` handed to the overlay is a copy so
    // CoreAnimation can retain it across future rewrites.
    private var canvas: CompositorCanvas?

    // MARK: - Lifecycle

    init() {
        sessionQueue.setSpecific(key: Self.sessionQueueKey, value: sessionQueueID)
        sessionQueue.sync {
            guard let lib = ass_library_init() else {
                Self.logger.error("ass_library_init failed")
                return
            }
            library = lib

            // Silence all but errors. Level 5 = warning, we keep those
            // for surfacing font lookup failures etc.
            ass_set_message_cb(lib, { level, _, _, _ in
                // libass occasionally fires level 0 (fatal) during style
                // parsing; even those we swallow because the renderer
                // simply produces no output for unparseable chunks.
                _ = level
            }, nil)

            guard let primary = ass_renderer_init(lib) else {
                Self.logger.error("ass_renderer_init failed for primary")
                return
            }
            primaryRenderer = primary
            configureRenderer(primary)

            guard let secondary = ass_renderer_init(lib) else {
                Self.logger.error("ass_renderer_init failed for secondary")
                return
            }
            secondaryRenderer = secondary
            configureRenderer(secondary)
        }
    }

    deinit {
        // Tear down in a final sync pass. Handles dispose their `ASS_Track`
        // on deinit; the renderer + library need explicit teardown here.
        let teardown = { [self] in
            self.primary = nil
            self.secondary = nil
            if let r = self.primaryRenderer {
                ass_renderer_done(r)
                self.primaryRenderer = nil
            }
            if let r = self.secondaryRenderer {
                ass_renderer_done(r)
                self.secondaryRenderer = nil
            }
            if let l = self.library {
                ass_library_done(l)
                self.library = nil
            }
        }
        if DispatchQueue.getSpecific(key: Self.sessionQueueKey) == sessionQueueID {
            teardown()
        } else {
            sessionQueue.sync(execute: teardown)
        }
    }

    // MARK: - Library accessors

    /// Handle for the `ASS_Library*`. Used by the session to add
    /// embedded fonts via `ass_add_font`.
    var libraryPointer: OpaquePointer? { library }

    // MARK: - Track management

    /// Create a new empty track in the given slot. Replaces any existing
    /// track. If `extradata` is non-nil it is fed to
    /// `ass_process_codec_private` (this is the `[Script Info]` +
    /// `[V4+ Styles]` block for embedded ASS tracks, or the
    /// FFmpeg-synthesised header for SRT/WebVTT-coded streams).
    ///
    /// Thread: may be called from any queue; hops onto `sessionQueue`.
    func createTrack(
        slot: SubtitleSlot,
        isNativeASS: Bool,
        extradata: UnsafePointer<UInt8>?,
        extradataSize: Int
    ) {
        let snapshotSize = extradataSize
        let copy: Data? = extradata.map { Data(bytes: $0, count: snapshotSize) }
        sessionQueue.async { [weak self] in
            guard let self, let lib = self.library else { return }
            guard let track = ass_new_track(lib) else {
                Self.logger.warning("ass_new_track failed")
                return
            }
            if let copy, !copy.isEmpty {
                copy.withUnsafeBytes { raw in
                    let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self)
                    ass_process_codec_private(track, base, Int32(copy.count))
                }
            }
            // Duplicate packet elimination is default-on in libass. Our
            // embedded feeder passes each packet exactly once, so the
            // ReadOrder-based dedup isn't needed and sometimes drops
            // legit repeated text. Disable it.
            ass_set_check_readorder(track, 0)

            let handle = ASSTrackHandle(ptr: track, isNativeASS: isNativeASS, flushesOnSeek: true)
            self.handleLock.lock()
            switch slot {
            case .primary:   self.primary = handle
            case .secondary: self.secondary = handle
            }
            self.handleLock.unlock()

            // Apply current styling overrides now that the slot is live.
            SubtitleStylingOverride.apply(
                renderer: self.renderer(for: slot),
                params: self.currentParams,
                isNativeASS: isNativeASS,
                slot: slot,
                fontScaleCompensation: self.fontScaleCompensation
            )
        }
    }

    /// Install a fully-parsed ASS document into the given slot. Used for
    /// sidecar fetches (ASS content arrives as one blob) and for SRT
    /// content after VTT-to-ASS conversion wraps it. Frees any existing
    /// track in the slot.
    ///
    /// Thread: may be called from any queue.
    func installFullASS(
        slot: SubtitleSlot,
        assDocument: String,
        isNativeASS: Bool
    ) {
        sessionQueue.async { [weak self] in
            guard let self, let lib = self.library else { return }
            // `ass_read_memory` takes a mutable char*; it may mutate the
            // buffer during parsing. Own a fresh mutable copy here so we
            // don't alias the Swift String's backing storage.
            let length = assDocument.utf8.count
            let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: length + 1)
            defer { buffer.deallocate() }
            _ = assDocument.withCString { src in
                memcpy(buffer, src, length)
            }
            buffer[length] = 0

            guard let track = ass_read_memory(lib, buffer, length, nil) else {
                Self.logger.warning("ass_read_memory failed (slot=\(slot.rawValue))")
                return
            }
            Self.logger.info(
                "[CMP-SUB] libass installed full document slot=\(slot.rawValue, privacy: .public) chars=\(length, privacy: .public) nativeASS=\(isNativeASS, privacy: .public)"
            )
            ass_set_check_readorder(track, 0)

            let handle = ASSTrackHandle(ptr: track, isNativeASS: isNativeASS, flushesOnSeek: false)
            self.handleLock.lock()
            switch slot {
            case .primary:   self.primary = handle
            case .secondary: self.secondary = handle
            }
            self.handleLock.unlock()

            SubtitleStylingOverride.apply(
                renderer: self.renderer(for: slot),
                params: self.currentParams,
                isNativeASS: isNativeASS,
                slot: slot,
                fontScaleCompensation: self.fontScaleCompensation
            )
        }
    }

    /// Drop the track in the given slot (or both slots if `.all`).
    /// Thread: any queue.
    func dropTrack(slot: SubtitleSlot) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.handleLock.lock()
            switch slot {
            case .primary:   self.primary = nil
            case .secondary: self.secondary = nil
            }
            self.handleLock.unlock()
        }
    }

    func dropAllTracks() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.handleLock.lock()
            self.primary = nil
            self.secondary = nil
            self.handleLock.unlock()
        }
    }

    /// Cheap snapshot for the display-link pump: lets the caller skip the
    /// per-vsync dispatch onto `sessionQueue` when neither slot has a
    /// track installed.
    var hasAnyActiveTrack: Bool {
        handleLock.lock()
        defer { handleLock.unlock() }
        return primary != nil || secondary != nil
    }

    /// Clear pending/shown events on a track without freeing it. Used on
    /// seek where we want to keep the parsed script / codec private but
    /// drop any libass-cached events with stale timings.
    func flushTrack(slot: SubtitleSlot) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.handleLock.lock()
            let handle: ASSTrackHandle? = {
                switch slot {
                case .primary:   return self.primary
                case .secondary: return self.secondary
                }
            }()
            self.handleLock.unlock()
            if let h = handle, h.flushesOnSeek {
                ass_flush_events(h.ptr)
            }
        }
    }

    /// Feed a single Dialogue event (in libass chunk format — i.e. the
    /// content of FFmpeg's `rect.ass`, sans the `Dialogue:` prefix).
    /// Thread: any queue.
    func feedChunk(
        slot: SubtitleSlot,
        eventText: String,
        startMs: Int64,
        durationMs: Int64
    ) {
        let text = eventText
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.handleLock.lock()
            let handle: ASSTrackHandle? = {
                switch slot {
                case .primary:   return self.primary
                case .secondary: return self.secondary
                }
            }()
            self.handleLock.unlock()
            guard let h = handle else { return }
            text.withCString { cstr in
                let len = Int32(strlen(cstr))
                ass_process_chunk(h.ptr, cstr, len, startMs, durationMs)
            }
        }
    }

    // MARK: - Font attachment

    /// Register an embedded font with libass. Called from `PlayerCore`
    /// when it walks `AVMEDIA_TYPE_ATTACHMENT` streams on file open.
    /// Thread: any queue.
    func addEmbeddedFont(name: String, data: Data) {
        let snapshot = data
        let nameCopy = name
        sessionQueue.async { [weak self] in
            guard let self, let lib = self.library else { return }
            snapshot.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: CChar.self) else { return }
                nameCopy.withCString { nameC in
                    ass_add_font(lib, nameC, base, Int32(snapshot.count))
                }
            }
        }
    }

    // MARK: - Frame size

    /// Update the libass frame/storage size and video-area margins. Called
    /// by the overlay view's `layoutSubviews`. Safe from main thread — hops
    /// internally.
    func updateFrameSize(
        _ size: CGSize,
        scale: CGFloat,
        videoInsets: SubtitleVideoInsets = .zero
    ) {
        let w = Int32(max(1, size.width * scale))
        let h = Int32(max(1, size.height * scale))
        let margins = Self.pixelMargins(for: videoInsets, scale: scale)
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.applyFrameGeometryOnSessionQueue(width: w, height: h, margins: margins)
        }
    }

    // MARK: - Settings

    /// Apply user styling preferences to the renderer. Called whenever
    /// `PlayerSettings` change or a new track is installed.
    /// Thread: any queue.
    func applySettings(_ params: SubtitleStylingOverride.Parameters) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.currentParams = params
            self.reapplyStylingOnSessionQueue()
            self.frameSizeDirty = true  // force repaint on next tick
        }
    }

    /// Re-apply the current styling params (with the current font-scale
    /// compensation) to both slot renderers. Callable only from
    /// `sessionQueue`.
    private func reapplyStylingOnSessionQueue() {
        handleLock.lock()
        let primaryHandle = primary
        let secondaryHandle = secondary
        handleLock.unlock()
        SubtitleStylingOverride.apply(
            renderer: primaryRenderer,
            params: currentParams,
            isNativeASS: primaryHandle?.isNativeASS ?? false,
            slot: .primary,
            fontScaleCompensation: fontScaleCompensation
        )
        SubtitleStylingOverride.apply(
            renderer: secondaryRenderer,
            params: currentParams,
            isNativeASS: secondaryHandle?.isNativeASS ?? false,
            slot: .secondary,
            fontScaleCompensation: fontScaleCompensation
        )
    }

    // MARK: - Render + composite

    /// Render the current frame. Callable only from `sessionQueue`. The
    /// caller is responsible for hopping back to main to assign the
    /// returned image to the overlay layer's `contents`.
    func renderOnSessionQueue(
        atMilliseconds now: Int64,
        frameSize: CGSize,
        scale: CGFloat,
        videoInsets: SubtitleVideoInsets = .zero
    ) -> SubtitleRenderOutput {
        guard primaryRenderer != nil || secondaryRenderer != nil else {
            return SubtitleRenderOutput(image: nil, isDirty: false)
        }
        ensureFrameSizeOnSessionQueue(frameSize, scale: scale, videoInsets: videoInsets)

        handleLock.lock()
        let primaryHandle = primary
        let secondaryHandle = secondary
        handleLock.unlock()

        let widthPx = Int(lastWidth)
        let heightPx = Int(lastHeight)
        guard widthPx > 0, heightPx > 0 else {
            return SubtitleRenderOutput(image: nil, isDirty: false)
        }

        var changeSecondary: Int32 = 0
        var changePrimary: Int32 = 0
        let imgSecondary: UnsafeMutablePointer<ASS_Image>? = secondaryHandle.flatMap {
            guard let renderer = secondaryRenderer else { return nil }
            return ass_render_frame(renderer, $0.ptr, now, &changeSecondary)
        }
        let imgPrimary: UnsafeMutablePointer<ASS_Image>? = primaryHandle.flatMap {
            guard let renderer = primaryRenderer else { return nil }
            return ass_render_frame(renderer, $0.ptr, now, &changePrimary)
        }
        let hasContent = imgPrimary != nil || imgSecondary != nil
        let anyChange = changePrimary != 0 || changeSecondary != 0 || frameSizeDirty
        if !anyChange {
            return SubtitleRenderOutput(image: nil, isDirty: false, hasContent: hasContent)
        }

        // Composite into the canvas. Secondary first so primary draws
        // on top if they happen to overlap.
        let canvas = ensureCanvas(widthPx: widthPx, heightPx: heightPx)
        canvas.clear()
        if let imgSecondary { canvas.draw(imageList: imgSecondary) }
        if let imgPrimary   { canvas.draw(imageList: imgPrimary) }

        frameSizeDirty = false

        let cgImage = canvas.snapshot(scale: scale)
        return SubtitleRenderOutput(image: cgImage, isDirty: true, hasContent: hasContent)
    }

    private func ensureFrameSizeOnSessionQueue(
        _ size: CGSize,
        scale: CGFloat,
        videoInsets: SubtitleVideoInsets = .zero
    ) {
        let safeScale = scale.isFinite && scale > 0 ? scale : 1
        let w = Int32(max(1, size.width * safeScale))
        let h = Int32(max(1, size.height * safeScale))
        let margins = Self.pixelMargins(for: videoInsets, scale: safeScale)
        applyFrameGeometryOnSessionQueue(width: w, height: h, margins: margins)
    }

    private static func pixelMargins(
        for insets: SubtitleVideoInsets,
        scale: CGFloat
    ) -> (top: Int32, bottom: Int32, left: Int32, right: Int32) {
        let safeScale = scale.isFinite && scale > 0 ? scale : 1
        func px(_ points: CGFloat) -> Int32 {
            Int32(max(0, (points * safeScale).rounded()))
        }
        return (px(insets.top), px(insets.bottom), px(insets.left), px(insets.right))
    }

    private func applyFrameGeometryOnSessionQueue(
        width w: Int32,
        height h: Int32,
        margins: (top: Int32, bottom: Int32, left: Int32, right: Int32)
    ) {
        let sizeChanged = w != lastWidth || h != lastHeight
        let marginsChanged = margins.top != lastMarginTop
            || margins.bottom != lastMarginBottom
            || margins.left != lastMarginLeft
            || margins.right != lastMarginRight
        guard sizeChanged || marginsChanged else { return }
        forEachRenderer {
            ass_set_frame_size($0, w, h)
            ass_set_storage_size($0, w, h)
            // Margins mark the video area inside the frame; libass keys
            // font scaling to that area, and `use_margins` placement (set
            // per-slot in SubtitleStylingOverride.apply) may render regular
            // cues into the margin bars.
            ass_set_margins($0, margins.top, margins.bottom, margins.left, margins.right)
            ass_set_pixel_aspect($0, 1.0)
        }
        lastWidth = w
        lastHeight = h
        lastMarginTop = margins.top
        lastMarginBottom = margins.bottom
        lastMarginLeft = margins.left
        lastMarginRight = margins.right
        frameSizeDirty = true
        // Canvas will be reallocated on the next dirty render.
        canvas = nil

        // libass keys font scale to the video area (frame height minus
        // vertical margins), so letterboxed content would render smaller
        // text than full-frame content. Compensate so Silo-styled text is
        // keyed to the full frame height instead; a no-op (1.0) when
        // margins are zero. Reapply overrides only when the factor moves so
        // steady-state layout passes stay cheap.
        let videoAreaHeight = h - margins.top - margins.bottom
        let compensation = videoAreaHeight > 0 ? Double(h) / Double(videoAreaHeight) : 1.0
        if abs(compensation - fontScaleCompensation) > 0.001 {
            fontScaleCompensation = compensation
            reapplyStylingOnSessionQueue()
        }
    }

    private func configureRenderer(_ renderer: OpaquePointer) {
        // Sensible defaults until the overlay view calls `updateFrameSize`
        // with real dimensions.
        ass_set_frame_size(renderer, 1920, 1080)
        ass_set_storage_size(renderer, 1920, 1080)
        ass_set_pixel_aspect(renderer, 1.0)
        ass_set_use_margins(renderer, 1)

        // Font lookup via the AUTODETECT provider, which resolves to
        // CoreText on Apple platforms when libass is built without
        // fontconfig (as mpvkit's iOS/tvOS xcframework is). Passing
        // `nil` for the config path and `update=1` scans the system
        // font database immediately so the first render doesn't
        // stall on lookup.
        ass_set_fonts(
            renderer,
            nil,                                       // default_font path
            "Arial",                                   // default_family fallback
            Int32(ASS_FONTPROVIDER_AUTODETECT.rawValue),
            nil,                                       // config path
            1                                          // update now
        )
    }

    private func renderer(for slot: SubtitleSlot) -> OpaquePointer? {
        switch slot {
        case .primary:
            return primaryRenderer
        case .secondary:
            return secondaryRenderer
        }
    }

    private func forEachRenderer(_ body: (OpaquePointer) -> Void) {
        if let primaryRenderer {
            body(primaryRenderer)
        }
        if let secondaryRenderer {
            body(secondaryRenderer)
        }
    }

    private func ensureCanvas(widthPx: Int, heightPx: Int) -> CompositorCanvas {
        if let existing = canvas, existing.widthPx == widthPx, existing.heightPx == heightPx {
            return existing
        }
        let fresh = CompositorCanvas(widthPx: widthPx, heightPx: heightPx)
        canvas = fresh
        return fresh
    }
}

// MARK: - Compositor canvas

/// Premultiplied-alpha 8-bit-per-channel RGBA buffer with a `CGContext`
/// bound to it. We keep the buffer alive across frames (reset via
/// `clear()`), and produce a fresh `CGImage` per dirty frame so
/// CoreAnimation can retain the image while we write the next one.
private final class CompositorCanvas {
    let widthPx: Int
    let heightPx: Int

    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferLength: Int
    private let bytesPerRow: Int
    private let context: CGContext

    init(widthPx: Int, heightPx: Int) {
        self.widthPx = widthPx
        self.heightPx = heightPx
        self.bytesPerRow = widthPx * 4
        self.bufferLength = bytesPerRow * heightPx
        self.buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferLength)
        self.buffer.initialize(repeating: 0, count: bufferLength)

        let space = CGColorSpaceCreateDeviceRGB()
        // Premultiplied BGRA matches what CALayer.contents expects when
        // the host layer is standard RGB. libass alpha masks are
        // straightforward-alpha; the draw path premultiplies the color
        // channels explicitly.
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let ctx = CGContext(
            data: buffer,
            width: widthPx,
            height: heightPx,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo
        ) else {
            fatalError("CompositorCanvas: failed to create CGContext")
        }
        self.context = ctx
    }

    deinit {
        buffer.deallocate()
    }

    func clear() {
        buffer.initialize(repeating: 0, count: bufferLength)
    }

    /// Walk a libass `ASS_Image*` linked list and composite each rect's
    /// alpha mask + flat color into the canvas.
    ///
    /// The libass `color` field is `RRGGBBAA` with alpha inverted
    /// (00 = opaque, FF = transparent). Each pixel's effective alpha is
    /// `maskAlpha * (255 - colorAlphaInverted) / 255`, then the RGB
    /// channels are premultiplied by that effective alpha and blended
    /// over the existing canvas contents using straightforward `over`
    /// compositing.
    func draw(imageList head: UnsafeMutablePointer<ASS_Image>) {
        var current: UnsafeMutablePointer<ASS_Image>? = head
        while let node = current {
            let img = node.pointee
            let w = Int(img.w)
            let h = Int(img.h)
            let stride = Int(img.stride)
            let dstX = Int(img.dst_x)
            let dstY = Int(img.dst_y)
            guard w > 0, h > 0, let bitmap = img.bitmap else {
                current = img.next
                continue
            }

            // libass render output color is RRGGBBTT, where TT is inverted
            // transparency. (An earlier fallback here re-read the color as
            // AABBGGRR when the documented read looked fully transparent —
            // that was masking incorrectly packed override-style colors
            // from SubtitleStylingOverride, and it resurrected genuinely
            // faded-out glyphs as opaque. Both are fixed; trust the
            // documented order.)
            let rgba = unpackDocumentedRenderColor(img.color)
            if rgba.alpha == 0 {
                current = img.next
                continue
            }
            let colorAlpha = UInt32(rgba.alpha)

            // Clip to canvas bounds.
            let startX = max(0, dstX)
            let startY = max(0, dstY)
            let endX = min(widthPx, dstX + w)
            let endY = min(heightPx, dstY + h)
            if startX >= endX || startY >= endY {
                current = img.next
                continue
            }

            for y in startY..<endY {
                let srcY = y - dstY
                let maskRow = bitmap.advanced(by: srcY * stride)
                let canvasRow = buffer.advanced(by: y * bytesPerRow)
                for x in startX..<endX {
                    let srcX = x - dstX
                    let maskAlpha = UInt32(maskRow[srcX])
                    if maskAlpha == 0 { continue }
                    // Effective alpha (0-255) for this pixel's fill.
                    let effAlpha = (maskAlpha * colorAlpha) / 255
                    if effAlpha == 0 { continue }

                    // Byte order is BGRA little-endian (byteOrder32Little +
                    // premultipliedFirst → BB GG RR AA in memory).
                    let offset = x * 4
                    let canvasB = UInt32(canvasRow[offset])
                    let canvasG = UInt32(canvasRow[offset + 1])
                    let canvasR = UInt32(canvasRow[offset + 2])
                    let canvasA = UInt32(canvasRow[offset + 3])

                    let srcR = (UInt32(rgba.r) * effAlpha) / 255
                    let srcG = (UInt32(rgba.g) * effAlpha) / 255
                    let srcB = (UInt32(rgba.b) * effAlpha) / 255

                    // Over-composite: dst = src + dst * (1 - srcA).
                    let invA = 255 - effAlpha
                    let outB = srcB + (canvasB * invA) / 255
                    let outG = srcG + (canvasG * invA) / 255
                    let outR = srcR + (canvasR * invA) / 255
                    let outA = effAlpha + (canvasA * invA) / 255

                    canvasRow[offset]     = UInt8(min(255, outB))
                    canvasRow[offset + 1] = UInt8(min(255, outG))
                    canvasRow[offset + 2] = UInt8(min(255, outR))
                    canvasRow[offset + 3] = UInt8(min(255, outA))
                }
            }

            current = img.next
        }
    }

    /// Produce a `CGImage` copying the current buffer state. Scale is
    /// informational only (we use pixel dimensions everywhere); the
    /// layer host applies `contentsScale` to map to point dimensions.
    func snapshot(scale: CGFloat) -> CGImage? {
        _ = scale
        return context.makeImage()
    }

    private func unpackDocumentedRenderColor(_ color: UInt32) -> (r: UInt8, g: UInt8, b: UInt8, alpha: UInt8) {
        let transparency = UInt8(color & 0xFF)
        return (
            UInt8((color >> 24) & 0xFF),
            UInt8((color >> 16) & 0xFF),
            UInt8((color >> 8) & 0xFF),
            UInt8(255 - UInt16(transparency))
        )
    }

}
