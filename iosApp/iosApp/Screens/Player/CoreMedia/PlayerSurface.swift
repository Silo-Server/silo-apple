//
//  PlayerSurface.swift
//  Continuum (iOS + tvOS)
//
//  SwiftUI host for the native player core. Provides an
//  AVSampleBufferDisplayLayer-backed UIView and hands it to a
//  PlayerCore instance via `attach(to:)`.
//
//  Subtitle overlay: a `SubtitleOverlayView` sits above the display
//  layer and receives libass-composited `CGImage` frames from
//  `PlayerCore.pumpSubtitleOverlay`. Subtitle positioning, colors,
//  borders, animations, and ASS typesetting all flow through libass —
//  the overlay view is just a CALayer host for the composited pixels.
//
//  iOS HDR: the host view subscribes to `onSigPeakChange` and updates
//  `preferredDynamicRange` on the display layer when the
//  stream is HDR and the display has EDR headroom to spare. On tvOS
//  the callback never fires (HDR is driven via AVDisplayManager / HDMI
//  negotiation).

import AVFoundation
import SwiftUI
import UIKit

struct PlayerSurface: UIViewRepresentable {
    let player: PlayerCore
    let videoGravity: AVLayerVideoGravity
    var bakedLetterbox: BakedLetterbox = .none

    func makeUIView(context: Context) -> PlayerSurfaceHostView {
        let view = PlayerSurfaceHostView()
        view.attach(player: player)
        view.setVideoGravity(videoGravity)
        view.bakedLetterbox = bakedLetterbox
        return view
    }

    func updateUIView(_ uiView: PlayerSurfaceHostView, context: Context) {
        uiView.attach(player: player)
        uiView.setVideoGravity(videoGravity)
        uiView.bakedLetterbox = bakedLetterbox
    }
}

/// UIView whose backing CALayer is AVSampleBufferDisplayLayer. The synchronizer
/// drives frame timing — we don't need a manual CMTimebase here, unlike the
/// Phase 0 spike, because the layer is added to an
/// AVSampleBufferRenderSynchronizer that provides its own timebase.
final class PlayerSurfaceHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        // swiftlint:disable:next force_cast
        layer as! AVSampleBufferDisplayLayer
    }

    private weak var attachedPlayer: PlayerCore?

    /// libass-backed subtitle overlay. Sized to the displayed video rect in
    /// `layoutSubviews()` (not the full view) so libass — which scales the
    /// ASS 1080-line coordinate space to the overlay's pixel height — keeps
    /// the font size proportional to the video across orientations, and so
    /// subtitles render inside the video frame in portrait.
    private let subtitleOverlay = SubtitleOverlayView()

    /// Latest presentation size from the attached player; `.zero` until the
    /// video format is known (overlay falls back to full bounds).
    private var videoPresentationSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspect
        setupSubtitleOverlay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupSubtitleOverlay() {
        subtitleOverlay.autoresizingMask = []
        addSubview(subtitleOverlay)
    }

    func attach(player: PlayerCore) {
        if attachedPlayer === player { return }
        attachedPlayer = player
        player.attach(to: displayLayer)

        // Wire the overlay to the player's libass session. The
        // renderer reference is held weakly on the overlay so it
        // doesn't extend the session's lifetime beyond playback.
        subtitleOverlay.renderer = player.subtitleRendererForOverlay
        player.subtitleOverlay = subtitleOverlay

        // Track the video's presentation size so layoutSubviews() can pin
        // the subtitle overlay to the displayed video rect.
        videoPresentationSize = player.videoPresentationSize
        player.onVideoPresentationSizeChange = { [weak self] size in
            self?.videoPresentationSize = size
            self?.setNeedsLayout()
        }

        // iOS EDR: sig-peak > 0 means the stream is HDR and the user has
        // HDR enabled. Combine with the screen's available EDR headroom
        // before flipping the flag. tvOS never fires this callback.
        player.onSigPeakChange = { [weak self] peak in
            self?.updateEDR(sigPeak: peak)
        }
        updateEDR(sigPeak: player.lastSigPeak)
    }

    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        guard displayLayer.videoGravity != gravity else { return }
        displayLayer.videoGravity = gravity
        attachedPlayer?.setVideoGravity(gravity)
        setNeedsLayout()
    }

    /// Bars baked into the picture, from the playback session. The subtitle
    /// overlay is keyed to the image rather than the frame so cues sit over
    /// the picture instead of inside a black bar.
    var bakedLetterbox: BakedLetterbox = .none {
        didSet {
            guard bakedLetterbox != oldValue else { return }
            setNeedsLayout()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        displayLayer.frame = bounds
        let videoRect = VideoDisplayRect.pictureRect(
            in: VideoDisplayRect.compute(
                videoSize: videoPresentationSize,
                bounds: bounds,
                gravity: displayLayer.videoGravity
            ),
            letterbox: bakedLetterbox,
            gravity: displayLayer.videoGravity
        )
        #if os(tvOS)
        // Full-frame overlay with libass margins marking the video area:
        // fonts keep scaling with the video rect, and the "Bottom" position
        // preset can render below the picture into the letterbox bar.
        subtitleOverlay.frame = bounds
        subtitleOverlay.videoInsets = SubtitleVideoInsets(videoRect: videoRect, bounds: bounds)
        #else
        subtitleOverlay.frame = videoRect
        #endif
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        // Moving between windows/screens can change available EDR headroom.
        if let peak = attachedPlayer?.lastSigPeak {
            updateEDR(sigPeak: peak)
        }
    }

    /// Toggle EDR on the display layer based on stream peak + current screen
    /// headroom. iOS-only; tvOS composites HDR through HDMI and doesn't
    /// expose `preferredDynamicRange` on this layer in a way
    /// that matters.
    func updateEDR(sigPeak: Double) {
        #if os(iOS)
        let headroom = window?.screen.potentialEDRHeadroom ?? 1.0
        let enable = sigPeak > 1.0 && headroom > 1.0
        let dynamicRange: CALayer.DynamicRange = enable ? .high : .standard
        if displayLayer.preferredDynamicRange != dynamicRange {
            displayLayer.preferredDynamicRange = dynamicRange
        }
        #endif
    }
}
