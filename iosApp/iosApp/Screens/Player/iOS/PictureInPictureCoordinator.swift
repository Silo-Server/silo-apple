#if os(iOS)
import AVKit
import Observation
import OSLog

/// Owns the `AVPictureInPictureController` for the AVPlayer-backed routes
/// (Native Player HLS / Direct and the SiloPlayer loopback route).
///
/// `AVPictureInPictureController` has to be bound to the live `AVPlayerLayer`,
/// which SwiftUI creates and tears down with `AVPlayerLayerView`. That view
/// attaches itself here when it comes on screen and detaches on dismantle, so
/// the rest of the shell can stay unaware of the layer's lifecycle:
/// `MobilePlayerControls` only reads `isPossible` / `isActive` to draw the
/// toggle, and `PlayerViewModel.handleScenePhase` reads `isEngaged` so
/// backgrounding into PiP doesn't pause playback.
@Observable
final class PictureInPictureCoordinator {
    static let shared = PictureInPictureCoordinator()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "PictureInPicture"
    )

    /// True while the system reports PiP can start right now: the layer is on
    /// screen, a video track is ready, and the device supports PiP.
    private(set) var isPossible = false
    /// True between `didStart` and `didStop`.
    private(set) var isActive = false
    /// True from `willStart` until the start resolves. Kept separate from
    /// `isActive` so the scene-phase handler doesn't pause playback during the
    /// window where iOS auto-starts PiP as the app is being backgrounded.
    private(set) var isTransitioning = false

    /// True while PiP owns (or is about to own) playback. Call sites that need
    /// to suppress background pauses should use this rather than `isActive`.
    var isEngaged: Bool { isActive || isTransitioning }

    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private weak var attachedLayer: AVPlayerLayer?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var delegateProxy: DelegateProxy?
    @ObservationIgnored private weak var lifecycleOwner: AnyObject?
    @ObservationIgnored private var onEngagementEnded: (() -> Void)?
    /// Set when the system asks us to restore the full-screen UI, i.e. the user
    /// tapped the PiP window's restore button. The `didStop` that follows is
    /// not "playback lost its route" — the user is on their way back into the
    /// app — and the scene may still read as backgrounded when it lands.
    @ObservationIgnored private var isRestoringUserInterface = false

    private init() {}

    /// Binds PiP to `playerLayer`. Safe to call repeatedly with the same layer
    /// (SwiftUI re-runs `updateUIView` constantly); only a genuine layer swap
    /// rebuilds the controller.
    func attach(playerLayer: AVPlayerLayer) {
        guard isSupported else { return }
        guard attachedLayer !== playerLayer else { return }
        // A genuine layer swap. Release the previous binding first: the old
        // controller retains its layer (and through it the AVPlayer and the
        // whole item/loopback graph), and its delegate callbacks stop once we
        // drop it, so its state has to be reset here rather than awaited.
        releaseController()
        guard let controller = AVPictureInPictureController(playerLayer: playerLayer) else {
            Self.logger.error("AVPictureInPictureController could not be created for the player layer")
            return
        }

        let proxy = DelegateProxy(coordinator: self)
        controller.delegate = proxy
        delegateProxy = proxy
        // The whole point of PiP for a video app: swiping home hands playback
        // to the floating window instead of stopping it.
        controller.canStartPictureInPictureAutomaticallyFromInline = true

        possibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] observed, _ in
            let possible = observed.isPictureInPicturePossible
            DispatchQueue.main.async {
                // `invalidate()` stops future callbacks but cannot recall one
                // already queued here, so re-check that this is still the live
                // controller before publishing — otherwise a detach can be
                // followed by a stale `isPossible = true`.
                guard let self, self.controller === observed else { return }
                self.isPossible = possible
            }
        }

        self.controller = controller
        attachedLayer = playerLayer
        Self.logger.info("PiP controller bound to player layer")
    }

    /// Drops the controller when the surface goes away. PiP without a source
    /// layer is meaningless, so an in-flight window is torn down too. Note the
    /// surface is *not* dismantled while PiP is running in the background — the
    /// SwiftUI hierarchy stays mounted — so this only fires when the player is
    /// genuinely closed.
    func detach(playerLayer: AVPlayerLayer) {
        guard attachedLayer === playerLayer else { return }
        releaseController()
    }

    /// Teardown for the player-close path. `detach` is keyed on layer identity,
    /// which is the right guard for SwiftUI's dismantle but is a no-op if the
    /// surface was never mounted or was replaced out of order. The coordinator
    /// is a singleton and the controller strongly retains its `AVPlayerLayer` —
    /// and through it the `AVPlayer`, its item, and the loopback server — so
    /// `PlayerViewModel.cleanup()` calls this to guarantee the graph is
    /// released with the session.
    ///
    /// Owner-guarded, because "close the old player, open the next" runs the
    /// two sessions' lifecycles concurrently: a late cleanup from the outgoing
    /// session must not tear down the controller the incoming one just bound.
    /// The incoming session's `attach` already released the old controller
    /// when the layer swapped, so nothing leaks by skipping.
    func endSession(owner: AnyObject) {
        guard lifecycleOwner === owner else {
            Self.logger.info("Skipping PiP teardown; another session owns the controller")
            return
        }
        lifecycleOwner = nil
        onEngagementEnded = nil
        releaseController()
    }

    /// Binds background-playback policy to the current player session. Owner
    /// identity prevents a late cleanup from clearing a newer session's hook.
    func bindLifecycle(owner: AnyObject, onEngagementEnded: @escaping () -> Void) {
        lifecycleOwner = owner
        self.onEngagementEnded = onEngagementEnded
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            guard controller.isPictureInPicturePossible else {
                Self.logger.info("PiP start ignored; not possible yet")
                return
            }
            controller.startPictureInPicture()
        }
    }

    private func releaseController() {
        defer { resetState() }
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        }
        // `stopPictureInPicture()` resolves asynchronously, but the controller
        // is released on the next line — `didStop` will never be delivered, so
        // clearing the delegate makes that explicit and `resetState()` (rather
        // than the callback) owns the published flags. Without this, `isActive`
        // would stay stuck at `true` and suppress the background pause for
        // every later playback session.
        controller.delegate = nil
        possibleObservation?.invalidate()
        possibleObservation = nil
        self.controller = nil
        delegateProxy = nil
        attachedLayer = nil
        Self.logger.info("PiP controller released")
    }

    private func resetState() {
        isPossible = false
        isActive = false
        isTransitioning = false
        isRestoringUserInterface = false
    }

    // MARK: - Delegate callbacks

    fileprivate func handleWillStart() {
        isTransitioning = true
        isRestoringUserInterface = false
    }

    fileprivate func handleDidStart() {
        isTransitioning = false
        isActive = true
        Self.logger.info("PiP started")
    }

    fileprivate func handleRestoreRequested() {
        isRestoringUserInterface = true
    }

    fileprivate func handleDidStop() {
        isTransitioning = false
        isActive = false
        let wasRestoring = isRestoringUserInterface
        isRestoringUserInterface = false
        Self.logger.info("PiP stopped restoring=\(wasRestoring ? 1 : 0, privacy: .public)")
        // Returning to the full-screen player keeps playing; only PiP genuinely
        // going away while the app stays in the background is a reason to stop.
        guard !wasRestoring else { return }
        onEngagementEnded?()
    }

    fileprivate func handleFailedToStart(_ error: Error) {
        isTransitioning = false
        isActive = false
        Self.logger.error("PiP failed to start: \(error.localizedDescription, privacy: .public)")
        onEngagementEnded?()
    }

    /// `AVPictureInPictureControllerDelegate` needs an `NSObject`; keeping it
    /// in a proxy lets the coordinator stay a plain `@Observable` class.
    private final class DelegateProxy: NSObject, AVPictureInPictureControllerDelegate {
        private weak var coordinator: PictureInPictureCoordinator?

        init(coordinator: PictureInPictureCoordinator) {
            self.coordinator = coordinator
        }

        func pictureInPictureControllerWillStartPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            coordinator?.handleWillStart()
        }

        func pictureInPictureControllerDidStartPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            coordinator?.handleDidStart()
        }

        func pictureInPictureControllerDidStopPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            coordinator?.handleDidStop()
        }

        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            failedToStartPictureInPictureWithError error: Error
        ) {
            coordinator?.handleFailedToStart(error)
        }

        /// The full-screen player shell stays mounted behind the PiP window,
        /// so there is nothing to rebuild — report success immediately and let
        /// playback hand back to the inline layer.
        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
                @escaping (Bool) -> Void
        ) {
            coordinator?.handleRestoreRequested()
            completionHandler(true)
        }
    }
}
#endif
