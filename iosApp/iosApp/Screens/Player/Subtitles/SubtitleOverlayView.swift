//
//  SubtitleOverlayView.swift
//  Continuum (Apple platforms)
//
//  Composites libass output onto the player surface. Sits above the
//  `AVSampleBufferDisplayLayer` inside `PlayerSurfaceHostView`. Pinned
//  to all four edges — libass handles the subtitle positioning via its
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
import QuartzCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

private func withoutImplicitLayerAnimation(_ updates: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    updates()
    CATransaction.commit()
}

/// One positioned bitmap subtitle cue. `frame` is the image rect in
/// overlay points (top-left origin). `backgroundFrame` is the
/// preference-driven backing box around it — equal to `frame` when no
/// box is drawn. All layout math lives with the caller; the overlay
/// only assigns layer geometry.
struct BitmapCuePlacement {
    let image: CGImage
    let frame: CGRect
    let backgroundFrame: CGRect
    let backgroundColor: CGColor?
    let cornerRadius: CGFloat
}

/// Grow/shrink the host's sublayer list to exactly `count` cue layer
/// pairs: a container (the preference-driven backing box) holding one
/// image sublayer. Cue images are pre-cropped to their frames, so
/// `.resize` maps the image 1:1 onto its layer. Callers wrap this in a
/// no-animation transaction.
private func syncBitmapCueLayerCount(_ count: Int, host: CALayer) {
    var current = host.sublayers?.count ?? 0
    while current > count {
        host.sublayers?.last?.removeFromSuperlayer()
        current -= 1
    }
    while current < count {
        let container = CALayer()
        container.isOpaque = false
        container.masksToBounds = false
        let image = CALayer()
        image.contentsGravity = .resize
        image.isOpaque = false
        container.addSublayer(image)
        host.addSublayer(container)
        current += 1
    }
}

/// Assign one placement to its container/image layer pair. The image
/// frame is expressed in the container's coordinate space.
private func applyBitmapCuePlacement(_ placement: BitmapCuePlacement, to container: CALayer) {
    container.frame = placement.backgroundFrame
    container.backgroundColor = placement.backgroundColor
    container.cornerRadius = placement.cornerRadius
    guard let imageLayer = container.sublayers?.first else { return }
    imageLayer.contents = placement.image
    imageLayer.frame = CGRect(
        x: placement.frame.minX - placement.backgroundFrame.minX,
        y: placement.frame.minY - placement.backgroundFrame.minY,
        width: placement.frame.width,
        height: placement.frame.height
    )
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
        // its own layer inside makes the z-order explicit.
        contentsLayer.contentsGravity = .resizeAspectFill
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

    override func layoutSubviews() {
        super.layoutSubviews()
        withoutImplicitLayerAnimation {
            contentsLayer.frame = bounds
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

    /// Assign the newest composited image. Call on main thread.
    func updateContents(_ image: CGImage?) {
        // CALayer.contents takes `Any?` — pass `image` directly to avoid
        // the ARC/CFType dance of an explicit `as CGImage`.
        withoutImplicitLayerAnimation {
            contentsLayer.contents = image
        }
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
        contentsLayer.contentsGravity = .resizeAspectFill
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

    private func updateLayout() {
        withoutImplicitLayerAnimation {
            contentsLayer.frame = bounds
            bitmapCueHost.frame = bounds
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        withoutImplicitLayerAnimation {
            contentsLayer.contentsScale = scale
        }
        renderer?.updateFrameSize(bounds.size, scale: scale, videoInsets: videoInsets)
    }

    /// Assign the newest composited image. Call on main thread.
    func updateContents(_ image: CGImage?) {
        withoutImplicitLayerAnimation {
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
