//
//  SubtitleOverlayView.swift
//  Silo (Apple platforms)
//
//  Composites libass output onto the player surface. Sits above the
//  AVPlayer video layer. Pinned to all four edges — libass handles the subtitle positioning via its
//  frame-size + margins model, so this view is always full-frame.
//
//  The view holds a single `CALayer.contents` CGImage that the
//  `SubtitleRenderer` produces on its dedicated queue. We don't compose
//  on the main thread; we only assign the already-baked image.
//
//  Bitmap subtitle tracks (PGS/DVD) render through a second layer group:
//  one sublayer per active cue image, framed by the caller in overlay
//  points (the overlay is sized to the video rect, so normalized cue
//  rects scale directly). Both layers coexist so a text track in one
//  slot and a bitmap track in the other composite correctly.
//

import CoreGraphics
import Foundation
import QuartzCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Tracks every live SwiftUI player surface for one playback backend.
///
/// The Next Up transition briefly keeps its mini-player and the returning
/// full-screen player alive together. A single weak overlay property is racy:
/// the outgoing surface can be the last writer and then deallocate, leaving the
/// subtitle pump with `nil`. Keeping weak registrations lets detach restore the
/// newest remaining surface instead.
final class SubtitleOverlayAttachmentRegistry {
    private final class Entry {
        weak var owner: AnyObject?
        weak var overlay: SubtitleOverlayView?
        var sequence: UInt64

        init(owner: AnyObject, overlay: SubtitleOverlayView, sequence: UInt64) {
            self.owner = owner
            self.overlay = overlay
            self.sequence = sequence
        }
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var sequence: UInt64 = 0

    func attach(owner: AnyObject, overlay: SubtitleOverlayView) {
        lock.lock()
        defer { lock.unlock() }
        pruneReleasedEntries()
        sequence &+= 1
        entries[ObjectIdentifier(owner)] = Entry(
            owner: owner,
            overlay: overlay,
            sequence: sequence
        )
    }

    func detach(owner: AnyObject) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeValue(forKey: ObjectIdentifier(owner))
        pruneReleasedEntries()
    }

    var currentOverlay: SubtitleOverlayView? {
        lock.lock()
        defer { lock.unlock() }
        pruneReleasedEntries()
        return entries.values.max(by: { $0.sequence < $1.sequence })?.overlay
    }

    private func pruneReleasedEntries() {
        entries = entries.filter { _, entry in
            entry.owner != nil && entry.overlay != nil
        }
    }
}

private func withoutImplicitLayerAnimation(_ updates: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    updates()
    CATransaction.commit()
}

/// One positioned bitmap subtitle cue. `frame` is the image rect in
/// overlay points (top-left origin). Bitmap cues render exactly as
/// authored — no preference-driven restyling. All layout math lives
/// with the caller; the overlay only assigns layer geometry.
struct BitmapCuePlacement {
    let image: CGImage
    let frame: CGRect
}

/// Grow/shrink the host's sublayer list to exactly `count` cue image
/// layers. Cue images are pre-cropped to their frames, so `.resize`
/// maps the image 1:1 onto its layer. Callers wrap this in a
/// no-animation transaction.
private func syncBitmapCueLayerCount(_ count: Int, host: CALayer) {
    var current = host.sublayers?.count ?? 0
    while current > count {
        host.sublayers?.last?.removeFromSuperlayer()
        current -= 1
    }
    while current < count {
        let image = CALayer()
        image.contentsGravity = .resize
        image.isOpaque = false
        host.addSublayer(image)
        current += 1
    }
}

/// Assign one placement to its image layer.
private func applyBitmapCuePlacement(_ placement: BitmapCuePlacement, to imageLayer: CALayer) {
    imageLayer.contents = placement.image
    imageLayer.frame = placement.frame
}

private func removeBitmapCueLayers(host: CALayer) {
    host.sublayers?.forEach { $0.removeFromSuperlayer() }
}

#if canImport(UIKit)
final class SubtitleOverlayView: UIView {

    /// Strong reference to the renderer. Held here (not just via the
    /// session) because the overlay's `layoutSubviews` notifies the
    /// renderer of frame-size changes directly.
    weak var renderer: SubtitleRenderer?

    /// Distance from this overlay's edges to the displayed video rect.
    /// Zero when the host sizes the overlay to the video rect (iOS);
    /// set by the tvOS hosts, which size the overlay to the full frame so
    /// libass can place the "Bottom" preset in the letterbox bar.
    var videoInsets: SubtitleVideoInsets = .zero {
        didSet {
            guard videoInsets != oldValue else { return }
            pushFrameGeometry()
        }
    }

    /// Layer that holds the composited subtitle image. Separate from
    /// `self.layer` so we can swap its `contents` without disturbing
    /// any other decoration the view might grow in the future.
    private let contentsLayer = CALayer()

    /// Container for bitmap subtitle cue layers (PGS/DVD): one sublayer
    /// per active cue, replaced wholesale by `updateBitmapCues`.
    private let bitmapCueHost = CALayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isUserInteractionEnabled = false
        // Overlay sits above the AVSampleBufferDisplayLayer; having
        // its own layer inside makes the z-order explicit. Contents are
        // rendered at the layer's exact pixel size, so `.resize` maps 1:1.
        contentsLayer.contentsGravity = .resize
        contentsLayer.isOpaque = false
        layer.addSublayer(contentsLayer)
        bitmapCueHost.isOpaque = false
        layer.addSublayer(bitmapCueHost)
        // The composited image is a libass-rendered bitmap, not text.
        // Without a textual representation VoiceOver would either announce
        // a misleading static label or read raw image-element noise; hide
        // the overlay from accessibility instead. Once the renderer
        // exposes the active event text, this can be replaced with a
        // proper `accessibilityValue` binding.
        isAccessibilityElement = false
        accessibilityElementsHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    /// Placement of the current composited image in overlay points; nil
    /// means the image covers the full bounds. Kept so layout passes
    /// don't stretch a bounded image back over the whole overlay.
    private var contentsFrameOverride: CGRect?

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitLayerAnimation {
            contentsLayer.frame = resolvedContentsFrame
            bitmapCueHost.frame = bounds
        }
        pushFrameGeometry()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Window change can mean a new screen scale (external display,
        // airplay). Re-push frame size so libass re-paints at the right
        // pixel density.
        if window != nil {
            pushFrameGeometry()
        }
    }

    private func pushFrameGeometry() {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        withoutImplicitLayerAnimation {
            contentsLayer.contentsScale = scale
        }
        renderer?.updateFrameSize(bounds.size, scale: scale, videoInsets: videoInsets)
    }

    /// Assign the newest composited image. `frame` is the image's
    /// placement in overlay points (top-left origin); nil or `.zero`
    /// means the image covers the full bounds. Call on main thread.
    func updateContents(_ image: CGImage?, frame: CGRect? = nil) {
        withoutImplicitLayerAnimation {
            if image != nil, let frame, frame != .zero {
                contentsFrameOverride = frame
            } else {
                contentsFrameOverride = nil
            }
            contentsLayer.frame = resolvedContentsFrame
            // CALayer.contents takes `Any?` — pass `image` directly to avoid
            // the ARC/CFType dance of an explicit `as CGImage`.
            contentsLayer.contents = image
        }
    }

    /// tvOS can crop the outer portion of the full-screen render surface for
    /// overscan. The Bottom preset intentionally uses the letterbox bar, but
    /// its final composited image still has to remain inside the title-safe
    /// region. Translate the already-rendered image as one unit so multi-line
    /// cues preserve their spacing and alignment.
    private var resolvedContentsFrame: CGRect {
        guard var frame = contentsFrameOverride else { return bounds }
        #if os(tvOS)
        let safeFrame = bounds.inset(by: safeAreaInsets)
        guard !safeFrame.isEmpty else { return frame }

        if frame.width <= safeFrame.width {
            if frame.minX < safeFrame.minX {
                frame.origin.x += safeFrame.minX - frame.minX
            } else if frame.maxX > safeFrame.maxX {
                frame.origin.x -= frame.maxX - safeFrame.maxX
            }
        }
        if frame.height <= safeFrame.height {
            if frame.minY < safeFrame.minY {
                frame.origin.y += safeFrame.minY - frame.minY
            } else if frame.maxY > safeFrame.maxY {
                frame.origin.y -= frame.maxY - safeFrame.maxY
            }
        }
        #endif
        return frame
    }

    /// Replace the bitmap cue layers with the given placements. Frames
    /// are in overlay points, top-left origin (the caller has already
    /// scaled normalized cue rects by the overlay bounds). Call on main.
    func updateBitmapCues(_ placements: [BitmapCuePlacement]) {
        withoutImplicitLayerAnimation {
            syncBitmapCueLayerCount(placements.count, host: bitmapCueHost)
            guard let sublayers = bitmapCueHost.sublayers else { return }
            for (index, placement) in placements.enumerated() {
                applyBitmapCuePlacement(placement, to: sublayers[index])
            }
        }
    }

    /// Remove every bitmap cue layer. Call on main.
    func clearBitmapCues() {
        withoutImplicitLayerAnimation {
            removeBitmapCueLayers(host: bitmapCueHost)
        }
    }

    /// Clear the overlay immediately. Used on track disable / playback
    /// teardown.
    func clear() {
        withoutImplicitLayerAnimation {
            contentsLayer.contents = nil
            removeBitmapCueLayers(host: bitmapCueHost)
        }
    }
}
#elseif canImport(AppKit)
final class SubtitleOverlayView: NSView {
    /// Strong reference to the renderer. Held here (not just via the
    /// session) because layout notifies the renderer of frame-size changes
    /// directly.
    weak var renderer: SubtitleRenderer?

    /// Distance from this overlay's edges to the displayed video rect.
    /// Always zero on macOS (the hosts size the overlay to the video rect);
    /// present so shared pump code can read it uniformly.
    var videoInsets: SubtitleVideoInsets = .zero {
        didSet {
            guard videoInsets != oldValue else { return }
            updateLayout()
        }
    }

    /// Layer that holds the composited subtitle image. Separate from
    /// `self.layer` so we can swap its `contents` without disturbing the
    /// hosting `AVPlayerView`.
    private let contentsLayer = CALayer()

    /// Container for bitmap subtitle cue layers (PGS/DVD): one sublayer
    /// per active cue, replaced wholesale by `updateBitmapCues`.
    /// Geometry-flipped so cue frames use the same top-left origin the
    /// UIKit variant (and the normalized cue rects) use, despite AppKit's
    /// bottom-left layer space.
    private let bitmapCueHost = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.zPosition = 10_000
        layer?.isOpaque = false
        layer?.masksToBounds = false
        contentsLayer.contentsGravity = .resize
        contentsLayer.isOpaque = false
        contentsLayer.zPosition = 10_000
        layer?.addSublayer(contentsLayer)
        bitmapCueHost.isOpaque = false
        bitmapCueHost.zPosition = 10_001
        bitmapCueHost.isGeometryFlipped = true
        layer?.addSublayer(bitmapCueHost)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override func layout() {
        super.layout()
        updateLayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayout()
    }

    /// Placement of the current composited image in overlay points,
    /// top-left origin; nil means the image covers the full bounds.
    private var contentsFrameOverride: CGRect?

    private func updateLayout() {
        withoutImplicitLayerAnimation {
            applyContentsFrame()
            bitmapCueHost.frame = bounds
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        withoutImplicitLayerAnimation {
            contentsLayer.contentsScale = scale
        }
        renderer?.updateFrameSize(bounds.size, scale: scale, videoInsets: videoInsets)
    }

    /// `contentsLayer` is not geometry-flipped, so a bounded frame given
    /// in top-left-origin overlay points must be flipped into AppKit's
    /// bottom-left layer space.
    private func applyContentsFrame() {
        if let frame = contentsFrameOverride {
            contentsLayer.frame = CGRect(
                x: frame.minX,
                y: bounds.height - frame.maxY,
                width: frame.width,
                height: frame.height
            )
        } else {
            contentsLayer.frame = bounds
        }
    }

    /// Assign the newest composited image. `frame` is the image's
    /// placement in overlay points (top-left origin); nil or `.zero`
    /// means the image covers the full bounds. Call on main thread.
    func updateContents(_ image: CGImage?, frame: CGRect? = nil) {
        withoutImplicitLayerAnimation {
            if image != nil, let frame, frame != .zero {
                contentsFrameOverride = frame
            } else {
                contentsFrameOverride = nil
            }
            applyContentsFrame()
            contentsLayer.contents = image
        }
    }

    /// Replace the bitmap cue layers with the given placements. Frames
    /// are in overlay points, top-left origin — `bitmapCueHost` is
    /// geometry-flipped (the flip is inherited by the container's own
    /// sublayers), so no manual y-flip is needed. Call on main.
    func updateBitmapCues(_ placements: [BitmapCuePlacement]) {
        withoutImplicitLayerAnimation {
            syncBitmapCueLayerCount(placements.count, host: bitmapCueHost)
            guard let sublayers = bitmapCueHost.sublayers else { return }
            for (index, placement) in placements.enumerated() {
                applyBitmapCuePlacement(placement, to: sublayers[index])
            }
        }
    }

    /// Remove every bitmap cue layer. Call on main.
    func clearBitmapCues() {
        withoutImplicitLayerAnimation {
            removeBitmapCueLayers(host: bitmapCueHost)
        }
    }

    /// Clear the overlay immediately. Used on track disable / playback
    /// teardown.
    func clear() {
        withoutImplicitLayerAnimation {
            contentsLayer.contents = nil
            removeBitmapCueLayers(host: bitmapCueHost)
        }
    }
}
#endif
