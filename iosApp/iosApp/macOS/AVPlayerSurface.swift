#if os(macOS)
import AVKit
import SwiftUI

struct AVPlayerSurface: NSViewRepresentable {
    let backend: AVPlayerBackend

    func makeNSView(context: Context) -> SiloMacPlayerView {
        let view = SiloMacPlayerView()
        view.attach(backend: backend)
        return view
    }

    func updateNSView(_ nsView: SiloMacPlayerView, context: Context) {
        nsView.attach(backend: backend)
    }

    static func dismantleNSView(_ nsView: SiloMacPlayerView, coordinator: ()) {
        nsView.detachSubtitleOverlay()
    }
}

final class SiloMacPlayerView: AVPlayerView {
    let subtitleOverlay = SubtitleOverlayView()
    private weak var backend: AVPlayerBackend?
    private var readyForDisplayObservation: NSKeyValueObservation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        controlsStyle = .none
        videoGravity = .resizeAspect
        showsFrameSteppingButtons = false
        showsFullScreenToggleButton = true
        showsSharingServiceButton = false
        updatesNowPlayingInfoCenter = false
        addSubtitleOverlay()
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
        if player !== backend.avPlayer {
            player = backend.avPlayer
        }
        subtitleOverlay.renderer = backend.subtitleRendererForOverlay
        backend.attachSubtitleOverlay(subtitleOverlay, owner: self)
    }

    func detachSubtitleOverlay() {
        backend?.detachSubtitleOverlay(owner: self)
    }

    /// `AVPlayerView` owns its own layer, so the first-frame signal comes off
    /// the view rather than off an `AVPlayerLayer` the way it does on
    /// iOS/tvOS. Same contract either way: the backend's initial video display
    /// gate holds the loading overlay until this fires.
    private func observeReadyForDisplay() {
        readyForDisplayObservation?.invalidate()
        readyForDisplayObservation = observe(\.isReadyForDisplay, options: [.new, .initial]) { [weak self] view, _ in
            guard view.isReadyForDisplay else { return }
            DispatchQueue.main.async {
                self?.backend?.videoSurfaceBecameReadyForDisplay()
            }
        }
    }

    private func addSubtitleOverlay() {
        subtitleOverlay.autoresizingMask = []
        subtitleOverlay.wantsLayer = true
        overlayParent.addSubview(subtitleOverlay, positioned: .above, relativeTo: nil)
    }

    override func layout() {
        super.layout()
        let frame = videoBounds.isEmpty ? bounds : videoBounds
        subtitleOverlay.frame = frame
    }

    private var overlayParent: NSView {
        contentOverlayView ?? self
    }
}
#endif
