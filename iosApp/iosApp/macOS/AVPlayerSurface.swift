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
