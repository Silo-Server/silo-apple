#if os(macOS)
import AppKit
import AVFoundation
import SwiftUI

struct PlayerSurface: NSViewRepresentable {
    let player: PlayerCore

    func makeNSView(context: Context) -> PlayerSurfaceHostView {
        let view = PlayerSurfaceHostView()
        view.attach(player: player)
        return view
    }

    func updateNSView(_ nsView: PlayerSurfaceHostView, context: Context) {
        nsView.attach(player: player)
    }

    static func dismantleNSView(_ nsView: PlayerSurfaceHostView, coordinator: ()) {
        nsView.detachSubtitleOverlay()
    }
}

final class PlayerSurfaceHostView: NSView {
    private let displayLayer = AVSampleBufferDisplayLayer()
    private weak var attachedPlayer: PlayerCore?
    private let subtitleOverlay = SubtitleOverlayView()

    /// Latest presentation size from the attached player; `.zero` until the
    /// video format is known (overlay falls back to full bounds).
    private var videoPresentationSize: CGSize = .zero

    /// Observes the hosting window moving between displays; re-registered
    /// whenever the view changes window, released in `deinit`.
    private var screenChangeToken: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        displayLayer.videoGravity = .resizeAspect
        layer?.addSublayer(displayLayer)
        updateDisplayLayerScale()

        subtitleOverlay.autoresizingMask = []
        addSubview(subtitleOverlay, positioned: .above, relativeTo: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let screenChangeToken {
            NotificationCenter.default.removeObserver(screenChangeToken)
        }
    }

    func attach(player: PlayerCore) {
        if attachedPlayer === player { return }
        if let attachedPlayer {
            attachedPlayer.detachSubtitleOverlay(owner: self)
            attachedPlayer.onSigPeakChange = nil
        }
        attachedPlayer = player
        player.attach(to: displayLayer)
        subtitleOverlay.renderer = player.subtitleRendererForOverlay
        player.attachSubtitleOverlay(subtitleOverlay, owner: self)

        // Track the video's presentation size so layout() can pin the
        // subtitle overlay to the displayed video rect — keeps libass font
        // scale proportional to the video as the window is resized.
        videoPresentationSize = player.videoPresentationSize
        player.onVideoPresentationSizeChange = { [weak self] size in
            self?.videoPresentationSize = size
            self?.needsLayout = true
        }

        // macOS EDR: sig-peak > 1 means the stream is HDR and the user has
        // HDR enabled. Combine with the screen's available EDR headroom
        // before flipping the flag, same as iOS.
        player.onSigPeakChange = { [weak self, weak player] peak in
            guard let self, let player, self.attachedPlayer === player else { return }
            self.updateEDR(sigPeak: peak)
        }
        updateEDR(sigPeak: player.lastSigPeak)
    }

    func detachSubtitleOverlay() {
        attachedPlayer?.detachSubtitleOverlay(owner: self)
    }

    override func layout() {
        super.layout()
        displayLayer.frame = bounds
        subtitleOverlay.frame = VideoDisplayRect.compute(
            videoSize: videoPresentationSize,
            bounds: bounds,
            gravity: displayLayer.videoGravity
        )
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateDisplayLayerScale()
        // Backing changes accompany a move to another display, which can
        // change available EDR headroom.
        updateEDR(sigPeak: attachedPlayer?.lastSigPeak ?? 0)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Dragging the window between an HDR and an SDR display changes the
        // headroom without changing backing scale, so neither
        // `viewDidChangeBackingProperties` nor this override alone covers it.
        if let screenChangeToken {
            NotificationCenter.default.removeObserver(screenChangeToken)
            self.screenChangeToken = nil
        }
        if let window {
            screenChangeToken = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeScreenNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                self.updateEDR(sigPeak: self.attachedPlayer?.lastSigPeak ?? 0)
            }
        }
        updateEDR(sigPeak: attachedPlayer?.lastSigPeak ?? 0)
    }

    /// Toggle EDR on the display layer based on stream peak + current screen
    /// headroom. The decision itself lives in `HDRDisplayCriteriaPolicy` so
    /// this host and the iOS one cannot drift apart.
    private func updateEDR(sigPeak: Double) {
        let enable = HDRDisplayCriteriaPolicy.shouldEnableEDR(
            sigPeak: sigPeak,
            screenHeadroom: PlatformScreen.potentialEDRHeadroom(of: window?.screen)
        )
        let dynamicRange: CALayer.DynamicRange = enable ? .high : .standard
        if displayLayer.preferredDynamicRange != dynamicRange {
            displayLayer.preferredDynamicRange = dynamicRange
        }
    }

    private func updateDisplayLayerScale() {
        displayLayer.contentsScale = layer?.contentsScale
            ?? window?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 2
    }
}
#endif
