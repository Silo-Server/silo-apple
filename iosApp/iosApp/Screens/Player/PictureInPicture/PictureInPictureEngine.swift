//
//  PictureInPictureEngine.swift
//  Continuum (iOS)
//
//  Engine-side seam for Picture in Picture. Both playback engines can vend
//  an AVKit content source; the controller lifecycle lives in
//  `PlayerPictureInPictureCoordinator`. Kept separate from `PlaybackEngine`
//  so the AVKit dependency and PiP semantics stay iOS-scoped — tvOS/macOS
//  never see this protocol.
//

#if os(iOS)
import AVKit

protocol PictureInPictureEngine: AnyObject {
    /// Build the content source AVKit should drive. Returns nil until the
    /// render surface has attached a live layer; `onPictureInPictureLayerReady`
    /// fires once construction becomes possible.
    func makePictureInPictureContentSource() -> AVPictureInPictureController.ContentSource?

    /// Fired (on main) whenever the engine's render layer becomes available
    /// or changes, so the coordinator can (re)build its controller.
    var onPictureInPictureLayerReady: (() -> Void)? { get set }

    /// Coordinator notification that PiP became active/inactive. Engines use
    /// it to keep frames flowing while the app is backgrounded (PlayerCore's
    /// sample-buffer path needs a render tick that outlives CADisplayLink).
    func pictureInPictureDidChange(active: Bool)
}

extension AVFoundationPlayerEngine: PictureInPictureEngine {
    var onPictureInPictureLayerReady: (() -> Void)? {
        get { backend.onPictureInPictureLayerReady }
        set { backend.onPictureInPictureLayerReady = newValue }
    }

    func makePictureInPictureContentSource() -> AVPictureInPictureController.ContentSource? {
        guard let layer = backend.pictureInPictureSourceLayer else { return nil }
        return AVPictureInPictureController.ContentSource(playerLayer: layer)
    }

    func pictureInPictureDidChange(active: Bool) {
        backend.pictureInPictureDidChange(active: active)
    }
}

extension CompatibilityPlayerEngine: PictureInPictureEngine {
    var onPictureInPictureLayerReady: (() -> Void)? {
        get { core.onPictureInPictureLayerReady }
        set { core.onPictureInPictureLayerReady = newValue }
    }

    func makePictureInPictureContentSource() -> AVPictureInPictureController.ContentSource? {
        core.makePictureInPictureContentSource()
    }

    func pictureInPictureDidChange(active: Bool) {
        core.pictureInPictureDidChange(active: active)
    }
}
#endif
