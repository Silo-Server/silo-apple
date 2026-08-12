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
    let preservesScriptSpecificFonts: Bool

    init(
        ptr: UnsafeMutablePointer<ASS_Track>,
        isNativeASS: Bool,
        flushesOnSeek: Bool,
        preservesScriptSpecificFonts: Bool = false
    ) {
        self.ptr = ptr
        self.isNativeASS = isNativeASS
        self.flushesOnSeek = flushesOnSeek
        self.preservesScriptSpecificFonts = preservesScriptSpecificFonts
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
    // Temporary [CMP-SUBDIAG] fields: which input made this render dirty.
    var diagChangePrimary: Int32 = 0
    var diagChangeSecondary: Int32 = 0
    var diagWasFrameSizeDirty: Bool = false
    var diagGeometryApplies: Int = 0
    // Temporary [CMP-SUBDIAG] fields: what libass produced this render.
    var diagImageCount: Int = 0
    var diagImageBytes: Int = 0
    var diagTrackEvents: Int32 = 0
    /// Placement of `image` in overlay points (top-left origin). The
    /// composite covers only the union of the rects libass painted, not
    /// the full frame; the overlay positions its contents layer here.
    /// `.zero` when `image` is nil.
    var imageFrame: CGRect = .zero
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
    // Temporary [CMP-SUBDIAG]: geometry (frame size / margin) applies.
    private var geometryApplyCount = 0
    // Temporary [CMP-SUBFEED]: fed dialogue chunks logged.
    private var diagFeedLogCount = 0
    // Temporary [CMP-SUBIMG]: per-image dumps on fingerprint change.
    private var diagImageDumpCount = 0
    /// FNV-1a fingerprint of the last composited image list. 0 = nothing
    /// composited yet (distinct from the FNV offset basis an empty list
    /// hashes to, so the first render always composites).
    private var lastCompositedImageFingerprint: UInt64 = 0

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

            // Temporary [CMP-SUBDIAG]: surface libass warnings (level <= 5)
            // to stdout to catch per-render font-selection failures. The
            // shipping callback swallows everything.
            ass_set_message_cb(lib, { level, fmt, args, _ in
                guard level <= 5, let fmt, let args else { return }
                let message = NSString(format: String(cString: fmt), arguments: args) as String
                print("[CMP-SUBASS] L\(level) \(message)")
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
        isNativeASS: Bool,
        preservesScriptSpecificFonts: Bool = false
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

            let handle = ASSTrackHandle(
                ptr: track,
                isNativeASS: isNativeASS,
                flushesOnSeek: false,
                preservesScriptSpecificFonts: preservesScriptSpecificFonts
            )
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
                fontScaleCompensation: self.fontScaleCompensation,
                preservesScriptSpecificFonts: preservesScriptSpecificFonts
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
            self.diagFeedLogCount += 1
            if self.diagFeedLogCount <= 6 {
                print("[CMP-SUBFEED] #\(self.diagFeedLogCount) slot=\(slot) start=\(startMs) dur=\(durationMs) text=\(String(text.prefix(160)))")
            }
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

    /// Pixel scale actually used for libass rasterization. Low-power Apple
    /// TVs (A12 and earlier) cap the raster at 1080p-class sizes: at the 4K
    /// UI scale libass shapes and rasterizes every glyph at 4x the pixel
    /// area, which dominates the residual cue-change render cost there. The
    /// overlay layer upscales the composite to the display instead, trading
    /// a little edge sharpness for the raster time.
    static func renderScale(for size: CGSize, requested scale: CGFloat) -> CGFloat {
        let safe = scale.isFinite && scale > 0 ? scale : 1
        guard capsRenderAt1080p, size.height > 0 else { return safe }
        return min(safe, max(1, 1080 / size.height))
    }

    /// AppleTV14,x (A15, 3rd-gen 4K) is the first model with headroom for
    /// 4K glyph rasterization; earlier models cap at 1080p.
    private static let capsRenderAt1080p = DevicePower.isLowPowerAppleTV

    /// Update the libass frame/storage size and video-area margins. Called
    /// by the overlay view's `layoutSubviews`. Safe from main thread — hops
    /// internally.
    func updateFrameSize(
        _ size: CGSize,
        scale: CGFloat,
        videoInsets: SubtitleVideoInsets = .zero
    ) {
        let renderScale = Self.renderScale(for: size, requested: scale)
        let w = Int32(max(1, size.width * renderScale))
        let h = Int32(max(1, size.height * renderScale))
        let margins = Self.pixelMargins(for: videoInsets, scale: renderScale)
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
            fontScaleCompensation: fontScaleCompensation,
            preservesScriptSpecificFonts: primaryHandle?.preservesScriptSpecificFonts ?? false
        )
        SubtitleStylingOverride.apply(
            renderer: secondaryRenderer,
            params: currentParams,
            isNativeASS: secondaryHandle?.isNativeASS ?? false,
            slot: .secondary,
            fontScaleCompensation: fontScaleCompensation,
            preservesScriptSpecificFonts: secondaryHandle?.preservesScriptSpecificFonts ?? false
        )
    }

    // MARK: - Render + composite

    /// Merge nearby libass image rectangles into cue-sized regions. libass
    /// does not expose an event identifier on `ASS_Image`, but images for one
    /// cue are spatially adjacent while simultaneous dialogue/sign events at
    /// different positions are not. Connected-component merging preserves
    /// those independent regions instead of spanning the empty space between
    /// them with one caption window.
    static func groupedPaintedBounds(
        _ rects: [CGRect],
        joiningDistance: CGFloat
    ) -> [CGRect] {
        let distance = max(0, joiningDistance)
        var groups: [CGRect] = []

        for rect in rects where !rect.isNull && !rect.isEmpty {
            var merged = rect
            var index = 0
            while index < groups.count {
                let mergeRegion = merged.insetBy(dx: -distance, dy: -distance)
                if mergeRegion.intersects(groups[index]) {
                    merged = merged.union(groups.remove(at: index))
                    index = 0
                } else {
                    index += 1
                }
            }
            groups.append(merged)
        }

        return groups.sorted {
            $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY
        }
    }

    /// Native ASS receives a compositor window only when Apple says the
    /// window opacity itself overrides authored content.
    static func shouldDrawCaptionWindow(
        isNativeASS: Bool,
        opacityPercent: Int,
        overrides: SystemCaptionContentOverrides
    ) -> Bool {
        guard opacityPercent > 0 else { return false }
        return !isNativeASS || overrides.contains(.windowOpacity)
    }

    /// Native ASS needs an explicit compositor box because changing a libass
    /// shadow bitmap cannot create a background when the track authored none.
    static func shouldSynthesizeGlyphBackground(
        isNativeASS: Bool,
        opacityPercent: Int,
        overrides: SystemCaptionContentOverrides,
        hasAuthoredBackground: Bool = false
    ) -> Bool {
        let backgroundOverrides: SystemCaptionContentOverrides = [
            .backgroundColor,
            .backgroundOpacity,
        ]
        return isNativeASS
            && opacityPercent > 0
            && !hasAuthoredBackground
            && !overrides.isDisjoint(with: backgroundOverrides)
    }

    /// libass represents a BorderStyle 4 caption background as an entirely
    /// filled bitmap but does not assign it a distinct image type. Detect the
    /// exact mask so background and edge precedence can be applied
    /// independently for native ASS cues.
    static func isSolidBackgroundMask(
        _ bitmap: UnsafePointer<UInt8>?,
        width: Int,
        height: Int,
        stride: Int
    ) -> Bool {
        guard let bitmap, width > 0, height > 0, stride >= width else { return false }
        for y in 0..<height {
            let row = bitmap.advanced(by: y * stride)
            for x in 0..<width where row[x] != 0xFF {
                return false
            }
        }
        return true
    }

    fileprivate static func isGlyphBackgroundImage(_ image: ASS_Image) -> Bool {
        isSolidBackgroundMask(
            image.bitmap,
            width: Int(image.w),
            height: Int(image.h),
            stride: Int(image.stride)
        )
    }

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
        let wasFrameSizeDirty = frameSizeDirty

        // libass's detect_change flag is unreliable here: it reports
        // content change (2) on every render of a static cue. The culprit
        // is the background-box layer — libass re-rasterizes the box bitmap
        // every frame into a rotating buffer pool, so its pointer differs
        // per render even though the pixels are identical (text glyph
        // bitmaps cache with stable pointers). Trusting the flag — or
        // pointer identity — meant compositing + snapshotting the
        // full-frame 4K canvas every vsync a cue was visible (100-400 ms
        // per frame, scaling with glyph size). Fingerprint the image list
        // by placement, color, and SAMPLED bitmap content so an
        // identical-but-reallocated bitmap fingerprints identically, and
        // composite only on real change.
        var imageFingerprint: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ value: UInt64) {
            imageFingerprint = (imageFingerprint ^ value) &* 0x0000_0100_0000_01b3
        }
        for head in [imgSecondary, imgPrimary] {
            var node = head
            while let cur = node {
                let img = cur.pointee
                mix(UInt64(bitPattern: Int64(img.dst_x)))
                mix(UInt64(bitPattern: Int64(img.dst_y)))
                mix(UInt64(bitPattern: Int64(img.w)))
                mix(UInt64(bitPattern: Int64(img.h)))
                mix(UInt64(img.color))
                if let bitmap = img.bitmap, img.h > 0, img.w > 0 {
                    let total = Int(img.stride) * (Int(img.h) - 1) + Int(img.w)
                    let step = max(1, total / 64)
                    var offset = 0
                    while offset < total {
                        mix(UInt64(bitmap[offset]))
                        offset += step
                    }
                }
                node = img.next
            }
        }
        let imagesChanged = imageFingerprint != lastCompositedImageFingerprint
        let anyChange = imagesChanged || frameSizeDirty
        if imagesChanged, imgPrimary != nil, diagImageDumpCount < 12 {
            diagImageDumpCount += 1
            var node = imgPrimary
            var idx = 0
            while let cur = node, idx < 6 {
                let img = cur.pointee
                let ptrTag = (img.bitmap.map { UInt(bitPattern: UnsafeRawPointer($0)) } ?? 0) & 0xFFFFF
                print("[CMP-SUBIMG] dump#\(diagImageDumpCount) img\(idx) ptr=\(String(ptrTag, radix: 16)) x=\(img.dst_x) y=\(img.dst_y) w=\(img.w) h=\(img.h) color=\(String(img.color, radix: 16)) now=\(now)")
                idx += 1
                node = img.next
            }
        }
        var diagImageCount = 0
        var diagImageBytes = 0
        for head in [imgPrimary, imgSecondary] {
            var node = head
            while let cur = node {
                diagImageCount += 1
                diagImageBytes += Int(cur.pointee.h) * Int(cur.pointee.stride)
                node = cur.pointee.next
            }
        }
        let diagTrackEvents = primaryHandle.map { $0.ptr.pointee.n_events } ?? 0
        if !anyChange {
            return SubtitleRenderOutput(
                image: nil, isDirty: false, hasContent: hasContent,
                diagChangePrimary: changePrimary, diagChangeSecondary: changeSecondary,
                diagWasFrameSizeDirty: wasFrameSizeDirty, diagGeometryApplies: geometryApplyCount,
                diagImageCount: diagImageCount, diagImageBytes: diagImageBytes,
                diagTrackEvents: diagTrackEvents
            )
        }

        frameSizeDirty = false
        lastCompositedImageFingerprint = imageFingerprint

        // BorderStyle 4 backgrounds are the largest libass masks in a cue.
        // Classify each bitmap once for this dirty frame and pass the identity
        // set through every grouping and compositor pass; uniform edges alone
        // redraw the image list eight times.
        var glyphBackgroundBitmaps: Set<UInt> = []
        for head in [imgPrimary, imgSecondary] {
            var node = head
            while let current = node {
                let image = current.pointee
                if Self.isGlyphBackgroundImage(image), let bitmap = image.bitmap {
                    glyphBackgroundBitmaps.insert(UInt(bitPattern: UnsafeRawPointer(bitmap)))
                }
                node = image.next
            }
        }
        func isGlyphBackground(_ image: ASS_Image) -> Bool {
            guard let bitmap = image.bitmap else { return false }
            return glyphBackgroundBitmaps.contains(UInt(bitPattern: UnsafeRawPointer(bitmap)))
        }

        // Composite only the union of the rects libass painted. The
        // full-frame canvas was the dominant render cost on tvOS: at 4K
        // (scale 2) every cue change cleared, copied (`makeImage`), and
        // re-uploaded a 33 MiB buffer when the painted region is
        // typically 1-2 MiB. Clipped to the frame like `draw` does.
        func paintedRects(
            _ head: UnsafeMutablePointer<ASS_Image>?,
            charactersOnly: Bool = false
        ) -> [CGRect] {
            var result: [CGRect] = []
            var node = head
            while let cur = node {
                let img = cur.pointee
                let isCharacter = !isGlyphBackground(img)
                    && img.type == IMAGE_TYPE_CHARACTER
                if (!charactersOnly || isCharacter),
                   img.w > 0, img.h > 0, img.bitmap != nil {
                    let minX = max(0, Int(img.dst_x))
                    let minY = max(0, Int(img.dst_y))
                    let maxX = min(widthPx, Int(img.dst_x) + Int(img.w))
                    let maxY = min(heightPx, Int(img.dst_y) + Int(img.h))
                    if maxX > minX, maxY > minY {
                        result.append(CGRect(
                            x: minX,
                            y: minY,
                            width: maxX - minX,
                            height: maxY - minY
                        ))
                    }
                }
                node = img.next
            }
            return result
        }

        let playfieldScale = Double(heightPx) / 1080.0
        let windowPadding = max(2, Int((currentParams.fontSize * 0.12 * playfieldScale).rounded()))
        let cueJoiningDistance = max(
            CGFloat(windowPadding * 2),
            CGFloat(currentParams.fontSize * 0.35 * playfieldScale)
        )
        let primaryRects = paintedRects(imgPrimary)
        let secondaryRects = paintedRects(imgSecondary)
        let primaryGroups = Self.groupedPaintedBounds(
            primaryRects,
            joiningDistance: cueJoiningDistance
        )
        let secondaryGroups = Self.groupedPaintedBounds(
            secondaryRects,
            joiningDistance: cueJoiningDistance
        )
        let primaryCharacterGroups = Self.groupedPaintedBounds(
            paintedRects(imgPrimary, charactersOnly: true),
            joiningDistance: cueJoiningDistance
        )
        let secondaryCharacterGroups = Self.groupedPaintedBounds(
            paintedRects(imgSecondary, charactersOnly: true),
            joiningDistance: cueJoiningDistance
        )
        func hasAuthoredGlyphBackground(_ head: UnsafeMutablePointer<ASS_Image>?) -> Bool {
            var node = head
            while let current = node {
                if isGlyphBackground(current.pointee) { return true }
                node = current.pointee.next
            }
            return false
        }
        func captionWindowBounds(
            _ groups: [CGRect],
            for handle: ASSTrackHandle?
        ) -> [CGRect] {
            guard let handle,
                  Self.shouldDrawCaptionWindow(
                      isNativeASS: handle.isNativeASS,
                      opacityPercent: currentParams.captionWindowOpacityPercent,
                      overrides: currentParams.systemContentOverrides
                  ) else { return [] }
            return groups.map { bounds in
                CGRect(
                    x: max(0, Int(bounds.minX) - windowPadding),
                    y: max(0, Int(bounds.minY) - windowPadding),
                    width: min(widthPx, Int(bounds.maxX) + windowPadding)
                        - max(0, Int(bounds.minX) - windowPadding),
                    height: min(heightPx, Int(bounds.maxY) + windowPadding)
                        - max(0, Int(bounds.minY) - windowPadding)
                )
            }
        }
        let primaryWindowBounds = captionWindowBounds(primaryGroups, for: primaryHandle)
        let secondaryWindowBounds = captionWindowBounds(secondaryGroups, for: secondaryHandle)

        let glyphBackgroundPadding = max(
            1,
            Int((currentParams.boxPadding * playfieldScale).rounded())
        )
        func nativeGlyphBackgroundBounds(
            _ groups: [CGRect],
            imageList: UnsafeMutablePointer<ASS_Image>?,
            for handle: ASSTrackHandle?
        ) -> [CGRect] {
            guard let handle,
                  Self.shouldSynthesizeGlyphBackground(
                      isNativeASS: handle.isNativeASS,
                      opacityPercent: currentParams.backgroundOpacityPercent,
                      overrides: currentParams.systemContentOverrides,
                      hasAuthoredBackground: hasAuthoredGlyphBackground(imageList)
                  )
                    else { return [] }
            return groups.map { bounds in
                CGRect(
                    x: max(0, Int(bounds.minX) - glyphBackgroundPadding),
                    y: max(0, Int(bounds.minY) - glyphBackgroundPadding),
                    width: min(widthPx, Int(bounds.maxX) + glyphBackgroundPadding)
                        - max(0, Int(bounds.minX) - glyphBackgroundPadding),
                    height: min(heightPx, Int(bounds.maxY) + glyphBackgroundPadding)
                        - max(0, Int(bounds.minY) - glyphBackgroundPadding)
                )
            }
        }
        let primaryGlyphBackgroundBounds = nativeGlyphBackgroundBounds(
            primaryCharacterGroups,
            imageList: imgPrimary,
            for: primaryHandle
        )
        let secondaryGlyphBackgroundBounds = nativeGlyphBackgroundBounds(
            secondaryCharacterGroups,
            imageList: imgSecondary,
            for: secondaryHandle
        )

        typealias EdgeLayer = (
            offsetX: Int,
            offsetY: Int,
            color: (UInt8, UInt8, UInt8),
            alpha: UInt8
        )
        func compositedEdgeLayers(
            for handle: ASSTrackHandle?
        ) -> [EdgeLayer] {
            guard let handle else { return [] }
            if handle.isNativeASS,
               currentParams.systemContentOverrides.contains(.edge) {
                let single: (Double, Double, String, Int)?
                switch currentParams.systemTextEdgeStyle {
                case .some(.none), nil:
                    return []
                case .some(.raised):
                    single = (-1, -1, "#FFFFFF", 80)
                case .some(.depressed):
                    single = (1, 1, "#000000", 90)
                case .some(.dropShadow):
                    single = (1.5, 1.5, "#000000", 50)
                case .some(.uniform):
                    let radius = max(
                        1,
                        Int((currentParams.effectiveBorderSize * playfieldScale).rounded())
                    )
                    let color = SubtitleStylingOverride.rgbBytes(
                        fromHex: currentParams.effectiveOutlineColorHex
                    )
                    return [
                        (-radius, -radius, color, 255),
                        (0, -radius, color, 255),
                        (radius, -radius, color, 255),
                        (-radius, 0, color, 255),
                        (radius, 0, color, 255),
                        (-radius, radius, color, 255),
                        (0, radius, color, 255),
                        (radius, radius, color, 255),
                    ]
                }
                guard let single else { return [] }
                return [(
                    Int((single.0 * playfieldScale).rounded()),
                    Int((single.1 * playfieldScale).rounded()),
                    SubtitleStylingOverride.rgbBytes(fromHex: single.2),
                    UInt8(max(0, min(255, single.3 * 255 / 100)))
                )]
            }
            guard let shadow = currentParams.compositedEdgeShadow else { return [] }
            return [(
                Int((shadow.offsetX * playfieldScale).rounded()),
                Int((shadow.offsetY * playfieldScale).rounded()),
                SubtitleStylingOverride.rgbBytes(fromHex: shadow.colorHex),
                UInt8(max(0, min(255, shadow.opacityPercent * 255 / 100)))
            )]
        }
        let primaryEdgeLayers = compositedEdgeLayers(for: primaryHandle)
        let secondaryEdgeLayers = compositedEdgeLayers(for: secondaryHandle)
        func shadowBounds(
            _ head: UnsafeMutablePointer<ASS_Image>?,
            edges: [EdgeLayer]
        ) -> [CGRect] {
            paintedRects(head, charactersOnly: true).flatMap { bounds in
                edges.map {
                    bounds.offsetBy(dx: CGFloat($0.offsetX), dy: CGFloat($0.offsetY))
                }
            }
        }
        let primaryShadowBounds = shadowBounds(imgPrimary, edges: primaryEdgeLayers)
        let secondaryShadowBounds = shadowBounds(imgSecondary, edges: secondaryEdgeLayers)

        let allBounds = primaryRects + secondaryRects
            + primaryWindowBounds + secondaryWindowBounds
            + primaryGlyphBackgroundBounds + secondaryGlyphBackgroundBounds
            + primaryShadowBounds + secondaryShadowBounds
        let minX = max(0, Int(allBounds.map(\.minX).min() ?? CGFloat(widthPx)))
        let minY = max(0, Int(allBounds.map(\.minY).min() ?? CGFloat(heightPx)))
        let maxX = min(widthPx, Int(ceil(allBounds.map(\.maxX).max() ?? 0)))
        let maxY = min(heightPx, Int(ceil(allBounds.map(\.maxY).max() ?? 0)))
        guard maxX > minX, maxY > minY else {
            // Cue ended (or everything rasterized off-frame): dirty with a
            // nil image so the overlay clears without a full-frame pass.
            return SubtitleRenderOutput(
                image: nil, isDirty: true, hasContent: hasContent,
                diagChangePrimary: changePrimary, diagChangeSecondary: changeSecondary,
                diagWasFrameSizeDirty: wasFrameSizeDirty, diagGeometryApplies: geometryApplyCount,
                diagImageCount: diagImageCount, diagImageBytes: diagImageBytes,
                diagTrackEvents: diagTrackEvents
            )
        }

        func draw(
            _ imageList: UnsafeMutablePointer<ASS_Image>,
            on canvas: CompositorCanvas,
            frameOffsetX: Int,
            frameOffsetY: Int,
            handle: ASSTrackHandle?,
            edgeLayers: [EdgeLayer]
        ) {
            let isNativeASS = handle?.isNativeASS == true
            let characterColor = isNativeASS ? currentParams.nativeForegroundColorOverride : nil
            let characterAlpha = isNativeASS ? currentParams.nativeForegroundAlphaOverride : nil
            let backgroundColor = isNativeASS ? currentParams.nativeBackgroundColorOverride : nil
            let backgroundAlpha = isNativeASS ? currentParams.nativeBackgroundAlphaOverride : nil
            let replacesAuthoredEdge = isNativeASS
                && currentParams.systemContentOverrides.contains(.edge)

            if !edgeLayers.isEmpty || replacesAuthoredEdge {
                // BorderStyle 4 emits the box through the non-character image
                // layers. Draw those first, then the independent system edge,
                // then the foreground glyphs so neither layer hides another.
                canvas.draw(
                    imageList: imageList,
                    offsetX: frameOffsetX,
                    offsetY: frameOffsetY,
                    selection: .excludingCharacters,
                    suppressAuthoredEdges: replacesAuthoredEdge,
                    glyphBackgroundColorOverride: backgroundColor,
                    glyphBackgroundAlphaOverride: backgroundAlpha,
                    glyphBackgroundBitmaps: glyphBackgroundBitmaps
                )
                for edge in edgeLayers {
                    canvas.draw(
                        imageList: imageList,
                        offsetX: frameOffsetX,
                        offsetY: frameOffsetY,
                        translationX: edge.offsetX,
                        translationY: edge.offsetY,
                        selection: .charactersOnly,
                        characterColorOverride: edge.color,
                        characterAlphaOverride: edge.alpha,
                        glyphBackgroundBitmaps: glyphBackgroundBitmaps
                    )
                }
                canvas.draw(
                    imageList: imageList,
                    offsetX: frameOffsetX,
                    offsetY: frameOffsetY,
                    selection: .charactersOnly,
                    characterColorOverride: characterColor,
                    characterAlphaOverride: characterAlpha,
                    glyphBackgroundBitmaps: glyphBackgroundBitmaps
                )
            } else {
                canvas.draw(
                    imageList: imageList,
                    offsetX: frameOffsetX,
                    offsetY: frameOffsetY,
                    characterColorOverride: characterColor,
                    characterAlphaOverride: characterAlpha,
                    glyphBackgroundColorOverride: backgroundColor,
                    glyphBackgroundAlphaOverride: backgroundAlpha,
                    glyphBackgroundBitmaps: glyphBackgroundBitmaps
                )
            }
        }

        // Secondary first so primary draws on top if they overlap. Apple's
        // caption window is a separate layer behind the complete cue; native
        // ASS receives it only when Apple says the system value overrides
        // authored content.
        let canvas = ensureCanvas(widthPx: maxX - minX, heightPx: maxY - minY)
        canvas.clear()
        func captionWindowStyle(
            for handle: ASSTrackHandle?
        ) -> (color: (UInt8, UInt8, UInt8), alpha: UInt8, radius: Double) {
            let isNativeASS = handle?.isNativeASS == true
            let usesSystemColor = !isNativeASS
                || currentParams.systemContentOverrides.contains(.windowColor)
            let usesSystemRadius = !isNativeASS
                || currentParams.systemContentOverrides.contains(.windowCornerRadius)
            return (
                SubtitleStylingOverride.rgbBytes(
                    fromHex: usesSystemColor ? currentParams.captionWindowColorHex : "#000000"
                ),
                UInt8(max(0, min(255, currentParams.captionWindowOpacityPercent * 255 / 100))),
                (usesSystemRadius ? currentParams.captionWindowCornerRadius : 0) * playfieldScale
            )
        }
        let secondaryWindowStyle = captionWindowStyle(for: secondaryHandle)
        for bounds in secondaryWindowBounds {
            canvas.drawRoundedRect(
                x: Int(bounds.minX) - minX,
                y: Int(bounds.minY) - minY,
                width: Int(bounds.width),
                height: Int(bounds.height),
                radius: secondaryWindowStyle.radius,
                color: secondaryWindowStyle.color,
                alpha: secondaryWindowStyle.alpha
            )
        }
        let glyphBackgroundColor = SubtitleStylingOverride.rgbBytes(
            fromHex: currentParams.backgroundColorHex
        )
        let glyphBackgroundAlpha = UInt8(
            max(0, min(255, currentParams.backgroundOpacityPercent * 255 / 100))
        )
        for bounds in secondaryGlyphBackgroundBounds {
            canvas.drawRoundedRect(
                x: Int(bounds.minX) - minX,
                y: Int(bounds.minY) - minY,
                width: Int(bounds.width),
                height: Int(bounds.height),
                radius: 0,
                color: glyphBackgroundColor,
                alpha: glyphBackgroundAlpha
            )
        }
        if let imgSecondary {
            draw(
                imgSecondary,
                on: canvas,
                frameOffsetX: minX,
                frameOffsetY: minY,
                handle: secondaryHandle,
                edgeLayers: secondaryEdgeLayers
            )
        }
        let primaryWindowStyle = captionWindowStyle(for: primaryHandle)
        for bounds in primaryWindowBounds {
            canvas.drawRoundedRect(
                x: Int(bounds.minX) - minX,
                y: Int(bounds.minY) - minY,
                width: Int(bounds.width),
                height: Int(bounds.height),
                radius: primaryWindowStyle.radius,
                color: primaryWindowStyle.color,
                alpha: primaryWindowStyle.alpha
            )
        }
        for bounds in primaryGlyphBackgroundBounds {
            canvas.drawRoundedRect(
                x: Int(bounds.minX) - minX,
                y: Int(bounds.minY) - minY,
                width: Int(bounds.width),
                height: Int(bounds.height),
                radius: 0,
                color: glyphBackgroundColor,
                alpha: glyphBackgroundAlpha
            )
        }
        if let imgPrimary {
            draw(
                imgPrimary,
                on: canvas,
                frameOffsetX: minX,
                frameOffsetY: minY,
                handle: primaryHandle,
                edgeLayers: primaryEdgeLayers
            )
        }

        let cgImage = canvas.snapshot(scale: scale)
        // Canvas pixels map to points through the (possibly capped) render
        // scale, not the requested display scale.
        let renderScale = Self.renderScale(for: frameSize, requested: scale)
        return SubtitleRenderOutput(
            image: cgImage, isDirty: true, hasContent: hasContent,
            diagChangePrimary: changePrimary, diagChangeSecondary: changeSecondary,
            diagWasFrameSizeDirty: wasFrameSizeDirty, diagGeometryApplies: geometryApplyCount,
            diagImageCount: diagImageCount, diagImageBytes: diagImageBytes,
            diagTrackEvents: diagTrackEvents,
            imageFrame: CGRect(
                x: CGFloat(minX) / renderScale,
                y: CGFloat(minY) / renderScale,
                width: CGFloat(maxX - minX) / renderScale,
                height: CGFloat(maxY - minY) / renderScale
            )
        )
    }

    private func ensureFrameSizeOnSessionQueue(
        _ size: CGSize,
        scale: CGFloat,
        videoInsets: SubtitleVideoInsets = .zero
    ) {
        let renderScale = Self.renderScale(for: size, requested: scale)
        let w = Int32(max(1, size.width * renderScale))
        let h = Int32(max(1, size.height * renderScale))
        let margins = Self.pixelMargins(for: videoInsets, scale: renderScale)
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
        geometryApplyCount += 1
        if geometryApplyCount <= 20 || geometryApplyCount % 60 == 0 {
            print("[CMP-SUBGEOM] #\(geometryApplyCount) \(w)x\(h) margins=\(margins.top)/\(margins.bottom)/\(margins.left)/\(margins.right) was=\(lastWidth)x\(lastHeight) \(lastMarginTop)/\(lastMarginBottom)/\(lastMarginLeft)/\(lastMarginRight)")
        }
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
        // At a full-frame 4K canvas with the enlarged tvOS size ladder and
        // letterbox font compensation, a single styled cue's glyph bitmaps
        // can exceed libass's default bitmap cache (~30 MB). Once that
        // happens every render is a cache miss: full re-rasterization
        // (~100-200 ms at 3840×2160) and detect_change flags content change
        // on every frame because the bitmaps are newly allocated. Raise the
        // ceiling so steady-state renders of a static cue are cache hits.
        ass_set_cache_limits(renderer, 0, 128)

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
    enum ImageSelection {
        case all
        case charactersOnly
        case excludingCharacters
    }

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

    /// Draw Apple's caption-window layer behind a complete cue. Coordinates
    /// are in this cropped canvas's top-left pixel space.
    func drawRoundedRect(
        x: Int,
        y: Int,
        width: Int,
        height: Int,
        radius: Double,
        color: (UInt8, UInt8, UInt8),
        alpha: UInt8
    ) {
        guard width > 0, height > 0, alpha > 0 else { return }
        let startX = max(0, x)
        let startY = max(0, y)
        let endX = min(widthPx, x + width)
        let endY = min(heightPx, y + height)
        guard startX < endX, startY < endY else { return }

        let r = max(0, min(radius, Double(min(width, height)) / 2))
        let rSquared = r * r
        let leftCenter = Double(x) + r
        let rightCenter = Double(x + width) - r
        let topCenter = Double(y) + r
        let bottomCenter = Double(y + height) - r
        let srcAlpha = UInt32(alpha)
        let srcR = (UInt32(color.0) * srcAlpha) / 255
        let srcG = (UInt32(color.1) * srcAlpha) / 255
        let srcB = (UInt32(color.2) * srcAlpha) / 255
        let invA = 255 - srcAlpha

        for py in startY..<endY {
            let canvasRow = buffer.advanced(by: py * bytesPerRow)
            for px in startX..<endX {
                if r > 0 {
                    let sampleX = Double(px) + 0.5
                    let sampleY = Double(py) + 0.5
                    let centerX = min(max(sampleX, leftCenter), rightCenter)
                    let centerY = min(max(sampleY, topCenter), bottomCenter)
                    let dx = sampleX - centerX
                    let dy = sampleY - centerY
                    if (dx * dx) + (dy * dy) > rSquared { continue }
                }

                let offset = px * 4
                let dstB = UInt32(canvasRow[offset])
                let dstG = UInt32(canvasRow[offset + 1])
                let dstR = UInt32(canvasRow[offset + 2])
                let dstA = UInt32(canvasRow[offset + 3])
                canvasRow[offset] = UInt8(min(255, srcB + (dstB * invA) / 255))
                canvasRow[offset + 1] = UInt8(min(255, srcG + (dstG * invA) / 255))
                canvasRow[offset + 2] = UInt8(min(255, srcR + (dstR * invA) / 255))
                canvasRow[offset + 3] = UInt8(min(255, srcAlpha + (dstA * invA) / 255))
            }
        }
    }

    /// Walk a libass `ASS_Image*` linked list and composite each rect's
    /// alpha mask + flat color into the canvas. `offsetX`/`offsetY` map
    /// frame-space destinations into this canvas (the caller sizes the
    /// canvas to the union of the painted rects, not the full frame).
    ///
    /// The libass `color` field is `RRGGBBAA` with alpha inverted
    /// (00 = opaque, FF = transparent). Each pixel's effective alpha is
    /// `maskAlpha * (255 - colorAlphaInverted) / 255`, then the RGB
    /// channels are premultiplied by that effective alpha and blended
    /// over the existing canvas contents using straightforward `over`
    /// compositing.
    func draw(
        imageList head: UnsafeMutablePointer<ASS_Image>,
        offsetX: Int = 0,
        offsetY: Int = 0,
        translationX: Int = 0,
        translationY: Int = 0,
        selection: ImageSelection = .all,
        characterColorOverride: (UInt8, UInt8, UInt8)? = nil,
        characterAlphaOverride: UInt8? = nil,
        suppressAuthoredEdges: Bool = false,
        glyphBackgroundColorOverride: (UInt8, UInt8, UInt8)? = nil,
        glyphBackgroundAlphaOverride: UInt8? = nil,
        glyphBackgroundBitmaps: Set<UInt> = []
    ) {
        var current: UnsafeMutablePointer<ASS_Image>? = head
        while let node = current {
            let img = node.pointee
            let isGlyphBackground = img.bitmap.map {
                glyphBackgroundBitmaps.contains(UInt(bitPattern: UnsafeRawPointer($0)))
            } ?? false
            let isCharacter = !isGlyphBackground && img.type == IMAGE_TYPE_CHARACTER
            let shouldDraw = switch selection {
            case .all: true
            case .charactersOnly: isCharacter
            case .excludingCharacters: !isCharacter
            }
            if !shouldDraw {
                current = img.next
                continue
            }
            if suppressAuthoredEdges && !isCharacter && !isGlyphBackground {
                current = img.next
                continue
            }
            let w = Int(img.w)
            let h = Int(img.h)
            let stride = Int(img.stride)
            let dstX = Int(img.dst_x) - offsetX + translationX
            let dstY = Int(img.dst_y) - offsetY + translationY
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
            var rgba = unpackDocumentedRenderColor(img.color)
            if isCharacter {
                if let characterColorOverride {
                    rgba.r = characterColorOverride.0
                    rgba.g = characterColorOverride.1
                    rgba.b = characterColorOverride.2
                }
                if let characterAlphaOverride {
                    rgba.alpha = characterAlphaOverride
                }
            } else if isGlyphBackground {
                if let glyphBackgroundColorOverride {
                    rgba.r = glyphBackgroundColorOverride.0
                    rgba.g = glyphBackgroundColorOverride.1
                    rgba.b = glyphBackgroundColorOverride.2
                }
                if let glyphBackgroundAlphaOverride {
                    rgba.alpha = glyphBackgroundAlphaOverride
                }
            }
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
