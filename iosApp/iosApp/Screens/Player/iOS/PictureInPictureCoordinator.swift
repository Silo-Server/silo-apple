#if os(iOS)
import AetherEngine
import AVFoundation
import AVKit
import Combine
import CoreMedia
import Observation
import OSLog

/// Owns the system Picture in Picture controller for the active Aether session.
///
/// Aether can change its rendering route at runtime. Native routes expose an
/// `AVPlayerLayer`; software routes expose a `SoftwarePiPSource` backed by an
/// `AVSampleBufferDisplayLayer`. This coordinator follows both sources and
/// keeps the active PiP controller alive across same-route reload seams.
@MainActor
@Observable
final class PictureInPictureCoordinator {
    static let shared = PictureInPictureCoordinator()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "PictureInPicture"
    )

    /// True while the current source is ready for AVKit to start PiP.
    private(set) var isPossible = false
    /// True between AVKit's did-start and did-stop callbacks.
    private(set) var isActive = false
    /// True after will-start until the start succeeds or fails.
    private(set) var isTransitioning = false
    /// True when Aether currently exposes either a native or software PiP source.
    private(set) var hasSource = false
    /// Stable external-picture state, including AirPlay's transient item-reload gap.
    private(set) var isExternalPlaybackActive = false

    /// True while PiP owns, or is about to own, playback.
    var isEngaged: Bool { isActive || isTransitioning }
    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Why a Picture in Picture start did not happen, for a host that wants to
    /// tell the user instead of leaving a tapped button looking inert.
    enum StartFailure {
        /// AVKit rejected the start outright.
        case failed(Error)
        /// The source is not ready for a start yet (`isPictureInPicturePossible`
        /// is still false).
        case notReady
    }

    private enum SourceKind {
        case native
        case software
    }

    @ObservationIgnored private weak var engine: AetherEngine?
    @ObservationIgnored private weak var lifecycleOwner: AnyObject?
    /// Keeps the player presentation alive only while AVKit is taking over its
    /// media graph. The normal owner reference stays weak so an idle
    /// coordinator can never strand a dismissed player.
    @ObservationIgnored private var engagedOwner: AnyObject?
    @ObservationIgnored private weak var currentPlayer: AVPlayer?
    @ObservationIgnored private weak var attachedLayer: AVPlayerLayer?
    @ObservationIgnored private var softwareSource: SoftwarePiPSource?
    @ObservationIgnored private var sourceKind: SourceKind?
    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private var controllerGeneration: UInt64 = 0
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var externalPlaybackObservation: NSKeyValueObservation?
    @ObservationIgnored private var routeChangeObserver: NSObjectProtocol?
    @ObservationIgnored private var delegateProxy: DelegateProxy?
    @ObservationIgnored private var subscriptions: Set<AnyCancellable> = []
    @ObservationIgnored private var onEngagementEnded: (() -> Void)?
    /// Asked to put the full-screen player back on screen when AVKit's restore
    /// control is used. Answering `false` means no surface can come back, which
    /// must end the engagement rather than leave playback running headless.
    @ObservationIgnored private var onRestoreUserInterface: ((@escaping (Bool) -> Void) -> Void)?
    /// Surfaces a start that never happened. AVKit reports both cases only to
    /// the delegate, so without this the user sees a button that does nothing.
    @ObservationIgnored private var onStartFailure: ((StartFailure) -> Void)?
    @ObservationIgnored private var isRestoringUserInterface = false
    /// A source disappeared while PiP was engaged. Re-read Aether when PiP stops.
    @ObservationIgnored private var pendingRebind = false
    /// A backend-class transition cannot reuse the active controller safely.
    @ObservationIgnored private var shouldStopForSourceChange = false

    private init() {}

    /// Bind the coordinator to one Aether session. Repeated calls for the same
    /// owner/engine are idempotent; a new owner fully releases the previous graph.
    func bind(
        engine: AetherEngine,
        owner: AnyObject,
        onEngagementEnded: (() -> Void)? = nil,
        onRestoreUserInterface: ((@escaping (Bool) -> Void) -> Void)? = nil,
        onStartFailure: ((StartFailure) -> Void)? = nil
    ) {
        if self.engine === engine, lifecycleOwner === owner {
            if let onEngagementEnded {
                self.onEngagementEnded = onEngagementEnded
            }
            if let onRestoreUserInterface {
                self.onRestoreUserInterface = onRestoreUserInterface
            }
            if let onStartFailure {
                self.onStartFailure = onStartFailure
            }
            adoptCurrentEngineSource()
            refreshExternalPlaybackState()
            return
        }

        let isSameOwner = lifecycleOwner === owner
        let retainedEngagementHandler = isSameOwner
            ? (onEngagementEnded ?? self.onEngagementEnded)
            : onEngagementEnded
        let retainedRestoreHandler = isSameOwner
            ? (onRestoreUserInterface ?? self.onRestoreUserInterface)
            : onRestoreUserInterface
        let retainedStartFailureHandler = isSameOwner
            ? (onStartFailure ?? self.onStartFailure)
            : onStartFailure
        // The outgoing session keeps its engagement only when the same owner is
        // rebinding a replacement engine; a genuinely new owner has to have its
        // deferred cleanup run here, because the delegate that would have run it
        // is detached below.
        tearDownBoundSession(continuingOwner: owner)

        self.engine = engine
        lifecycleOwner = owner
        self.onEngagementEnded = retainedEngagementHandler
        self.onRestoreUserInterface = retainedRestoreHandler
        self.onStartFailure = retainedStartFailureHandler

        engine.$currentAVPlayer
            .sink { [weak self, weak engine] player in
                // Aether publishes this MainActor-isolated state synchronously.
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    self.receiveNativePlayer(player)
                }
            }
            .store(in: &subscriptions)

        // The native host and its layer survive item handovers. Observe the
        // separately published item seam so external-route and native-subtitle
        // ownership are re-applied to the replacement without rebuilding PiP.
        engine.$currentAVPlayerItem
            .sink { [weak self, weak engine] _ in
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    self.adoptCurrentEngineSource()
                    self.refreshExternalPlaybackState()
                }
            }
            .store(in: &subscriptions)

        engine.$softwarePiPSource
            .sink { [weak self, weak engine] source in
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    self.receiveSoftwareSource(source)
                }
            }
            .store(in: &subscriptions)

        // A track can change while video is already in PiP or on an external
        // display. Re-assert native ownership after both the selection and the
        // native rendition table settle so the newly selected track, rather
        // than the previous ordinal, is rendered by AVKit/the receiver.
        engine.$activeSubtitleTrackIndex
            .sink { [weak self, weak engine] _ in
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    self.syncNativeSubtitleRendering()
                }
            }
            .store(in: &subscriptions)

        engine.$nativeSubtitleTracks
            .sink { [weak self, weak engine] _ in
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    self.syncNativeSubtitleRendering()
                }
            }
            .store(in: &subscriptions)

        // Aether publishes the host/layer before it commits the effective
        // route at the end of a load. The route edge is therefore the final
        // opportunity to apply loopback-native subtitle ownership after a
        // same-player item handover.
        engine.$videoRoute
            .sink { [weak self, weak engine] route in
                MainActor.assumeIsolated {
                    guard route == .loopback,
                          let self, let engine, self.engine === engine else { return }
                    self.syncNativeSubtitleRendering()
                }
            }
            .store(in: &subscriptions)

        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshExternalPlaybackState()
            }
        }

        adoptCurrentEngineSource()
        refreshExternalPlaybackState()
    }

    /// Owner-keyed teardown prevents an outgoing view from releasing a newer
    /// session's controller during overlapping SwiftUI presentation lifecycles.
    func endSession(owner: AnyObject) {
        guard lifecycleOwner === owner else {
            Self.logger.info("Skipping PiP teardown; another session owns the coordinator")
            return
        }
        tearDownBoundSession(continuingOwner: nil)
    }

    /// End whatever session is bound, regardless of which owner holds it,
    /// because the app crossed an identity boundary — sign-out, server or
    /// profile switch, or a cleared session.
    ///
    /// Ordinary teardown is owner-keyed and driven by the player's
    /// disappearance, which deliberately defers `cleanup()` while PiP is
    /// engaged. An identity change tears the authenticated view hierarchy down
    /// on that same deferred path, so without this the previous identity's
    /// engine, server playback session, and PiP window all survive into the
    /// next one. `tearDownBoundSession` runs the engaged owner's deferred
    /// cleanup synchronously, which is what stops the engine and closes the
    /// session.
    func endSessionForIdentityChange() {
        guard lifecycleOwner != nil || engagedOwner != nil else { return }
        Self.logger.info("Ending the PiP session for an identity boundary")
        tearDownBoundSession(continuingOwner: nil)
    }

    /// Entry point for the shared auth paths, which are not statically
    /// isolated to the main actor. The hop is safe in either order relative to
    /// the player's own disappearance: whichever runs second finds the
    /// engagement already ended.
    nonisolated static func endEngagedSessionForIdentityChange() {
        Task { @MainActor in
            shared.endSessionForIdentityChange()
        }
    }

    func ownsEngagedSession(_ owner: AnyObject) -> Bool {
        lifecycleOwner === owner && isEngaged
    }

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive || isActive {
            controller.stopPictureInPicture()
        } else {
            guard controller.isPictureInPicturePossible else {
                Self.logger.info("PiP start ignored; not possible yet")
                onStartFailure?(.notReady)
                return
            }
            controller.startPictureInPicture()
        }
    }

    // MARK: - Aether source binding

    private func receiveNativePlayer(_ player: AVPlayer?) {
        externalPlaybackObservation?.invalidate()
        externalPlaybackObservation = nil
        currentPlayer = player

        guard let player else {
            if sourceKind == .native {
                if isEngaged {
                    pendingRebind = true
                } else {
                    releaseController(stopIfActive: false)
                }
            }
            refreshExternalPlaybackState()
            return
        }

        externalPlaybackObservation = player.observe(
            \.isExternalPlaybackActive,
            options: [.initial, .new]
        ) { [weak self, weak player] _, _ in
            Task { @MainActor [weak self, weak player] in
                guard let self, self.currentPlayer === player else { return }
                self.refreshExternalPlaybackState()
            }
        }

        if let layer = engine?.nativePlayerLayer {
            bindNativeLayer(layer)
        }
        refreshExternalPlaybackState()
    }

    private func receiveSoftwareSource(_ source: SoftwarePiPSource?) {
        guard let source else {
            if sourceKind == .software {
                if isEngaged {
                    pendingRebind = true
                } else {
                    releaseController(stopIfActive: false)
                }
            }
            return
        }
        bindSoftwareSource(source)
        refreshExternalPlaybackState()
    }

    private func adoptCurrentEngineSource() {
        guard let engine else { return }
        if engine.currentAVPlayer != nil, let layer = engine.nativePlayerLayer {
            bindNativeLayer(layer)
        } else if let source = engine.softwarePiPSource {
            bindSoftwareSource(source)
        } else if !isEngaged {
            releaseController(stopIfActive: false)
        }
    }

    private func bindNativeLayer(_ layer: AVPlayerLayer) {
        guard isSupported else {
            hasSource = false
            return
        }

        if sourceKind == .native, attachedLayer === layer {
            hasSource = true
            pendingRebind = false
            shouldStopForSourceChange = false
            return
        }

        if isEngaged {
            pendingRebind = true
            shouldStopForSourceChange = true
            Self.logger.info("Native PiP source changed while active; stopping for a safe rebind")
            controller?.stopPictureInPicture()
            return
        }

        releaseController(stopIfActive: false)
        guard let pictureInPicture = AVPictureInPictureController(playerLayer: layer) else {
            Self.logger.error("AVPictureInPictureController rejected Aether's native player layer")
            return
        }
        let proxy = DelegateProxy(coordinator: self)
        configureController(pictureInPicture, proxy: proxy)
        sourceKind = .native
        attachedLayer = layer
        softwareSource = nil
        hasSource = true
        pendingRebind = false
        shouldStopForSourceChange = false
        Self.logger.info("PiP bound to Aether native player layer")
    }

    private func bindSoftwareSource(_ source: SoftwarePiPSource) {
        guard isSupported else {
            hasSource = false
            return
        }

        if sourceKind == .software, let controller, let proxy = delegateProxy {
            if softwareSource === source {
                hasSource = true
                pendingRebind = false
                shouldStopForSourceChange = false
                return
            }
            if isEngaged {
                // A software reload creates a new display layer. Replacing the
                // ContentSource on the same controller keeps the PiP window up.
                softwareSource = source
                controller.contentSource = AVPictureInPictureController.ContentSource(
                    sampleBufferDisplayLayer: source.layer,
                    playbackDelegate: proxy
                )
                hasSource = true
                pendingRebind = false
                shouldStopForSourceChange = false
                Self.logger.info("PiP swapped to Aether's reloaded software source")
                return
            }
        }

        if isEngaged {
            pendingRebind = true
            shouldStopForSourceChange = true
            Self.logger.info("PiP backend class changed while active; stopping for a safe rebind")
            controller?.stopPictureInPicture()
            return
        }

        releaseController(stopIfActive: false)
        let proxy = DelegateProxy(coordinator: self)
        let contentSource = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: source.layer,
            playbackDelegate: proxy
        )
        let pictureInPicture = AVPictureInPictureController(contentSource: contentSource)
        configureController(pictureInPicture, proxy: proxy)
        sourceKind = .software
        softwareSource = source
        attachedLayer = nil
        hasSource = true
        pendingRebind = false
        shouldStopForSourceChange = false
        Self.logger.info("PiP bound to Aether software sample-buffer source")
    }

    private func configureController(
        _ pictureInPicture: AVPictureInPictureController,
        proxy: DelegateProxy
    ) {
        controllerGeneration &+= 1
        let generation = controllerGeneration
        controller = pictureInPicture
        delegateProxy = proxy
        pictureInPicture.delegate = proxy
        pictureInPicture.canStartPictureInPictureAutomaticallyFromInline = true
        possibleObservation = pictureInPicture.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] observed, _ in
            let isPossible = observed.isPictureInPicturePossible
            Task { @MainActor [weak self] in
                guard let self, self.controllerGeneration == generation else { return }
                self.isPossible = isPossible
            }
        }
    }

    private func releaseController(stopIfActive: Bool) {
        controllerGeneration &+= 1
        if stopIfActive, let controller,
           controller.isPictureInPictureActive || isEngaged {
            controller.stopPictureInPicture()
        }
        controller?.delegate = nil
        possibleObservation?.invalidate()
        possibleObservation = nil
        controller = nil
        delegateProxy = nil
        attachedLayer = nil
        softwareSource = nil
        sourceKind = nil
        hasSource = false
        isPossible = false
        isActive = false
        isTransitioning = false
        isRestoringUserInterface = false
    }

    /// Release the bound graph.
    ///
    /// `releaseController(stopIfActive:)` detaches the AVKit delegate in the same
    /// turn it asks for a stop, so `handleDidStop` can never arrive for a
    /// controller torn down here. When PiP was engaged, that callback was the
    /// only thing that would have ended the engagement, and the engaged owner has
    /// already deferred its own `cleanup()` — final progress and the server
    /// session stop — waiting for exactly that. So run the engagement-ended work
    /// synchronously instead of dropping it on the floor.
    ///
    /// `continuingOwner` is the owner about to take the coordinator over. It only
    /// matters when the same owner rebinds a replacement engine: that session is
    /// not ending, so its cleanup must not run.
    private func tearDownBoundSession(continuingOwner: AnyObject?) {
        engine?.pictureInPictureActive = false
        engine?.setNativeSubtitleRendering(false)
        subscriptions.removeAll()
        externalPlaybackObservation?.invalidate()
        externalPlaybackObservation = nil
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
        routeChangeObserver = nil
        releaseController(stopIfActive: true)
        currentPlayer = nil
        isExternalPlaybackActive = false
        pendingRebind = false
        shouldStopForSourceChange = false
        engine = nil
        lifecycleOwner = nil

        // Hand the engagement off before the references go, and keep the owner
        // alive across its own cleanup — `engagedOwner` is the only strong
        // reference holding it up.
        let isEndingEngagement = engagedOwner != nil && engagedOwner !== continuingOwner
        let endedOwner = engagedOwner
        let endedEngagementHandler = isEndingEngagement ? onEngagementEnded : nil
        // Cleared first so a late `handleDidStop`, or the owner-keyed
        // `endSession` that its `cleanup()` calls back into, both find nothing
        // left to end and cannot run this a second time.
        engagedOwner = nil
        onEngagementEnded = nil
        onRestoreUserInterface = nil
        onStartFailure = nil

        if let endedEngagementHandler {
            Self.logger.info("PiP torn down while engaged; running the outgoing session's cleanup")
            withExtendedLifetime(endedOwner) { endedEngagementHandler() }
        }
    }

    // MARK: - External playback + subtitle ownership

    private func refreshExternalPlaybackState() {
        let hasNativePicture = currentPlayer != nil
            || sourceKind == .native
            || engine?.nativePlayerLayer != nil
        let routeIsExternal = AVAudioSession.sharedInstance().currentRoute.outputs.contains {
            $0.portType == .airPlay || $0.portType == .HDMI
        }
        let active = currentPlayer?.isExternalPlaybackActive == true
            || (hasNativePicture && routeIsExternal)
        isExternalPlaybackActive = active
        syncNativeSubtitleRendering()
    }

    private func syncNativeSubtitleRendering() {
        guard let engine else { return }
        // This handoff applies only to Aether's loopback-native route. Remote
        // HLS subtitles already live in AVPlayer's media-selection group (and
        // use ids absent from the generated rendition table); software PiP
        // burns its overlay into the sample-buffer frames itself.
        guard engine.videoRoute == .loopback else { return }
        engine.setNativeSubtitleRendering(
            engine.pictureInPictureActive || isExternalPlaybackActive
        )
    }

    // MARK: - AVKit delegate callbacks

    fileprivate func handleWillStart() {
        // This callback is synchronous on the main thread. Set Aether first so
        // its did-enter-background observer sees PiP as a keepalive reason.
        engine?.pictureInPictureActive = true
        engagedOwner = lifecycleOwner
        isTransitioning = true
        isRestoringUserInterface = false
        syncNativeSubtitleRendering()
    }

    fileprivate func handleDidStart() {
        engine?.pictureInPictureActive = true
        isTransitioning = false
        isActive = true
        syncNativeSubtitleRendering()
        Self.logger.info("PiP started")
        if shouldStopForSourceChange {
            controller?.stopPictureInPicture()
        }
    }

    /// AVKit is stopping PiP because the user asked for the full-screen player
    /// back. `completion(true)` must mean the player really is on screen again:
    /// `handleDidStop` reads the outcome to decide whether the engagement — and
    /// with it the deferred `cleanup()` — has to end.
    fileprivate func handleRestoreRequested(completion: @escaping (Bool) -> Void) {
        isRestoringUserInterface = false
        guard let onRestoreUserInterface else {
            // Nobody owns the player presentation. Answering `true` here is what
            // left playback running with no UI and no session teardown.
            Self.logger.error("PiP restore requested with no presentation owner")
            completion(false)
            return
        }
        var hasAnswered = false
        onRestoreUserInterface { [weak self] didRestore in
            // AVKit's handler must run exactly once.
            guard !hasAnswered else { return }
            hasAnswered = true
            if didRestore {
                self?.isRestoringUserInterface = true
            } else {
                Self.logger.error("PiP restore could not re-present the player")
            }
            completion(didRestore)
        }
    }

    fileprivate func handleDidStop() {
        engine?.pictureInPictureActive = false
        isTransitioning = false
        isActive = false
        syncNativeSubtitleRendering()
        // True only when the app layer confirmed the full-screen player is back
        // on screen. A close-button stop, a failed restore, and a rebind stop
        // all land here as false, and each one has to end the engagement so the
        // deferred `cleanup()` runs.
        let didRestoreUserInterface = isRestoringUserInterface
        isRestoringUserInterface = false
        Self.logger.info(
            "PiP stopped restored=\(didRestoreUserInterface ? 1 : 0, privacy: .public)"
        )

        if pendingRebind {
            pendingRebind = false
            shouldStopForSourceChange = false
            adoptCurrentEngineSource()
        }
        // Released before the callback so the owner-keyed `endSession` that its
        // `cleanup()` may call back into cannot end the same engagement twice.
        let endedOwner = engagedOwner
        engagedOwner = nil
        if !didRestoreUserInterface {
            withExtendedLifetime(endedOwner) { onEngagementEnded?() }
        }
    }

    fileprivate func handleFailedToStart(_ error: Error) {
        engine?.pictureInPictureActive = false
        isTransitioning = false
        isActive = false
        syncNativeSubtitleRendering()
        Self.logger.error(
            "PiP failed to start: \(MediaLogRedactor.sanitize(error), privacy: .public)"
        )
        onStartFailure?(.failed(error))
        if pendingRebind {
            pendingRebind = false
            shouldStopForSourceChange = false
            adoptCurrentEngineSource()
        }
        let endedOwner = engagedOwner
        engagedOwner = nil
        withExtendedLifetime(endedOwner) { onEngagementEnded?() }
    }

    fileprivate func softwareSetPlaying(_ playing: Bool) {
        softwareSource?.setPlaying(playing)
    }

    fileprivate func softwareTimeRange() -> CMTimeRange {
        softwareSource?.timeRange()
            ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    fileprivate func softwareIsPaused() -> Bool {
        softwareSource?.isPaused ?? true
    }

    fileprivate func softwareSkip(by seconds: Double) {
        softwareSource?.skip(by: seconds)
    }

    /// AVKit delivers both delegate protocols on the main thread. The proxy
    /// keeps the observable coordinator independent of NSObject while the
    /// synchronous `assumeIsolated` call preserves will-start ordering.
    private final class DelegateProxy: NSObject,
        AVPictureInPictureControllerDelegate,
        AVPictureInPictureSampleBufferPlaybackDelegate
    {
        private weak var coordinator: PictureInPictureCoordinator?

        init(coordinator: PictureInPictureCoordinator) {
            self.coordinator = coordinator
        }

        func pictureInPictureControllerWillStartPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            MainActor.assumeIsolated { coordinator?.handleWillStart() }
        }

        func pictureInPictureControllerDidStartPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            MainActor.assumeIsolated { coordinator?.handleDidStart() }
        }

        func pictureInPictureControllerDidStopPictureInPicture(
            _ pictureInPictureController: AVPictureInPictureController
        ) {
            MainActor.assumeIsolated { coordinator?.handleDidStop() }
        }

        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            failedToStartPictureInPictureWithError error: Error
        ) {
            MainActor.assumeIsolated { coordinator?.handleFailedToStart(error) }
        }

        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler:
                @escaping (Bool) -> Void
        ) {
            MainActor.assumeIsolated {
                guard let coordinator else {
                    completionHandler(false)
                    return
                }
                coordinator.handleRestoreRequested(completion: completionHandler)
            }
        }

        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            setPlaying playing: Bool
        ) {
            MainActor.assumeIsolated { coordinator?.softwareSetPlaying(playing) }
        }

        func pictureInPictureControllerTimeRangeForPlayback(
            _ pictureInPictureController: AVPictureInPictureController
        ) -> CMTimeRange {
            MainActor.assumeIsolated {
                coordinator?.softwareTimeRange()
                    ?? CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
            }
        }

        func pictureInPictureControllerIsPlaybackPaused(
            _ pictureInPictureController: AVPictureInPictureController
        ) -> Bool {
            MainActor.assumeIsolated { coordinator?.softwareIsPaused() ?? true }
        }

        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            didTransitionToRenderSize newRenderSize: CMVideoDimensions
        ) {}

        func pictureInPictureController(
            _ pictureInPictureController: AVPictureInPictureController,
            skipByInterval skipInterval: CMTime,
            completion completionHandler: @escaping () -> Void
        ) {
            MainActor.assumeIsolated {
                coordinator?.softwareSkip(by: skipInterval.seconds)
            }
            completionHandler()
        }
    }
}
#endif
