//
//  AVPlayerSurface.swift
//  Silo (iOS + tvOS) — shared AVPlayer render surface
//
//  UIViewRepresentable hosting an AVPlayerLayer. Used whenever the active
//  player route is AVPlayer-backed, including HLS playback, the narrow
//  native-direct route, and the Dolby Vision loopback fallback.
//
//  Kept deliberately thin: just a view with AVPlayerLayer as layerClass. All
//  route-specific loading and track plumbing lives in AVPlayerBackend; this
//  file only owns the render surface.

import AVFoundation
import SwiftUI
import UIKit

struct AVPlayerSurface: UIViewRepresentable {
    let backend: AVPlayerBackend
    let videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> AVPlayerLayerView {
        let view = AVPlayerLayerView()
        view.attach(backend: backend)
        view.setVideoGravity(videoGravity)
        view.attachSubtitleRenderer(backend.subtitleRendererForOverlay)
        backend.attachSubtitleOverlay(view.subtitleOverlay, owner: view)
        return view
    }

    func updateUIView(_ uiView: AVPlayerLayerView, context: Context) {
        uiView.attach(backend: backend)
        uiView.setVideoGravity(videoGravity)
        uiView.attachSubtitleRenderer(backend.subtitleRendererForOverlay)
        backend.attachSubtitleOverlay(uiView.subtitleOverlay, owner: uiView)
    }

    static func dismantleUIView(_ uiView: AVPlayerLayerView, coordinator: ()) {
        uiView.detachSubtitleOverlay()
        #if os(iOS)
        PictureInPictureCoordinator.shared.detach(playerLayer: uiView.playerLayer)
        #endif
    }
}

final class AVPlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        // swiftlint:disable:next force_cast
        layer as! AVPlayerLayer
    }

    let subtitleOverlay = SubtitleOverlayView()
    private weak var backend: AVPlayerBackend?
    private var readyForDisplayObservation: NSKeyValueObservation?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
        setupSubtitleOverlay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(backend: AVPlayerBackend) {
        if self.backend !== backend {
            self.backend?.detachSubtitleOverlay(owner: self)
            self.backend = backend
            observeReadyForDisplay()
        }
        let player = backend.avPlayer
        if playerLayer.player === player { return }
        playerLayer.player = player
        #if os(iOS)
        // PiP has to be bound to the live layer, and the layer is only useful
        // once it actually has a player attached.
        PictureInPictureCoordinator.shared.attach(playerLayer: playerLayer)
        #endif
    }

    func setVideoGravity(_ gravity: AVLayerVideoGravity) {
        guard playerLayer.videoGravity != gravity else { return }
        playerLayer.videoGravity = gravity
        setNeedsLayout()
    }

    func attachSubtitleRenderer(_ renderer: SubtitleRenderer?) {
        subtitleOverlay.renderer = renderer
    }

    func detachSubtitleOverlay() {
        backend?.detachSubtitleOverlay(owner: self)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        playerLayer.frame = bounds
        let videoRect = playerLayer.videoRect
        #if os(tvOS)
        // Full-frame overlay with libass margins marking the video area:
        // fonts keep scaling with the video rect, and the "Bottom" position
        // preset can render below the picture into the letterbox bar.
        subtitleOverlay.frame = bounds
        subtitleOverlay.videoInsets = SubtitleVideoInsets(videoRect: videoRect, bounds: bounds)
        #else
        subtitleOverlay.frame = videoRect.isEmpty ? bounds : videoRect
        #endif
    }

    private func setupSubtitleOverlay() {
        subtitleOverlay.autoresizingMask = []
        addSubview(subtitleOverlay)
    }

    private func observeReadyForDisplay() {
        readyForDisplayObservation?.invalidate()
        readyForDisplayObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new, .initial]) { [weak self] layer, _ in
            guard layer.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                // `videoRect` becomes meaningful once the layer is ready;
                // re-run layout so the subtitle overlay picks it up.
                self?.setNeedsLayout()
                self?.backend?.videoSurfaceBecameReadyForDisplay()
            }
        }
    }
}
