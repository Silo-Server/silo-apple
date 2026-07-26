#if os(macOS)
import AVKit
import SwiftUI

struct AVPlayerSurface: NSViewRepresentable {
    let backend: AVPlayerBackend
    var bakedLetterbox: BakedLetterbox = .none

    func makeNSView(context: Context) -> ContinuumMacPlayerView {
        let view = ContinuumMacPlayerView()
        view.attach(player: backend.avPlayer)
        view.attachSubtitleRenderer(backend.subtitleRendererForOverlay)
        view.bakedLetterbox = bakedLetterbox
        backend.subtitleOverlay = view.subtitleOverlay
        return view
    }

    func updateNSView(_ nsView: ContinuumMacPlayerView, context: Context) {
        nsView.attach(player: backend.avPlayer)
        nsView.attachSubtitleRenderer(backend.subtitleRendererForOverlay)
        nsView.bakedLetterbox = bakedLetterbox
        backend.subtitleOverlay = nsView.subtitleOverlay
    }
}

final class ContinuumMacPlayerView: AVPlayerView {
    let subtitleOverlay = SubtitleOverlayView()

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

    func attach(player: AVPlayer) {
        if self.player === player { return }
        self.player = player
    }

    func attachSubtitleRenderer(_ renderer: SubtitleRenderer?) {
        subtitleOverlay.renderer = renderer
    }

    private func addSubtitleOverlay() {
        subtitleOverlay.autoresizingMask = []
        subtitleOverlay.wantsLayer = true
        overlayParent.addSubview(subtitleOverlay, positioned: .above, relativeTo: nil)
    }

    private func positionSubtitleOverlays() {
        overlayParent.addSubview(subtitleOverlay, positioned: .above, relativeTo: nil)
    }

    /// Bars baked into the picture, from the playback session; see
    /// `BakedLetterbox`.
    var bakedLetterbox: BakedLetterbox = .none {
        didSet {
            guard bakedLetterbox != oldValue else { return }
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        let frame = videoBounds.isEmpty ? bounds : videoBounds
        subtitleOverlay.frame = VideoDisplayRect.pictureRect(
            in: frame,
            letterbox: bakedLetterbox,
            gravity: videoGravity
        )
    }

    private var overlayParent: NSView {
        contentOverlayView ?? self
    }
}
#endif
