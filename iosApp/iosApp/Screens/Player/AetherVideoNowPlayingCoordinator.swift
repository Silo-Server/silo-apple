import Foundation
import MediaPlayer
import Nuke
import OSLog
#if canImport(UIKit)
import UIKit
#endif

/// Arbitrates the process-wide `MPRemoteCommandCenter.shared()` and
/// `MPNowPlayingInfoCenter.default()` between every Silo owner that can bind
/// them at the same time: video's software-renderer fallback route, the
/// audiobook software route (and every audiobook route on macOS), and
/// SiloControl remote-media sessions.
///
/// Both centers are process-wide, so an owner tearing its binding down would
/// otherwise disable every shared transport command and clear shared metadata
/// even while another owner's targets are still registered. Claims are keyed
/// by owner identity and stacked; only the newest claimant drives the centers.
/// `MPRemoteCommandCenter` invokes every registered target, so a second live
/// target set would send one lock-screen press to stale local playback as
/// well as to the owner whose metadata is shown. Claiming suspends the
/// previous holder, and every owner leaves through `releaseSharedCenters`,
/// which disables the transport, drops the claim, and then either restores
/// the next claimant or clears the shared metadata.
@MainActor
final class SharedNowPlayingArbiter {
    static let shared = SharedNowPlayingArbiter()

    private struct Claim {
        weak var owner: AnyObject?
        let suspend: () -> Void
        let restore: () -> Void
    }

    private var claims: [Claim] = []

    private init() {}

    /// Every transport command any Silo owner can enable. Enabling is part of
    /// a binding, so a command left enabled after its targets are gone keeps
    /// advertising a transport nobody drives.
    static func disableTransportCommands(on center: MPRemoteCommandCenter) {
        for command in [
            center.playCommand,
            center.pauseCommand,
            center.togglePlayPauseCommand,
            center.skipForwardCommand,
            center.skipBackwardCommand,
            center.changePlaybackPositionCommand,
            center.stopCommand,
            center.nextTrackCommand,
        ] {
            command.isEnabled = false
        }
    }

    /// Makes `owner` the current holder of the shared centers, suspending the
    /// previous holder first. The caller registers its own targets after
    /// claiming. `suspend` must remove the owner's remote-command targets.
    /// `restore` must re-register them, re-enable every command the owner
    /// drives, and republish its metadata; it must be a no-op if the owner is
    /// no longer bound to the shared centers. Neither may call the arbiter.
    func claim(
        _ owner: AnyObject,
        suspend: @escaping () -> Void,
        restore: @escaping () -> Void
    ) {
        prune()
        if let previous = claims.last, previous.owner !== owner {
            previous.suspend()
            // The new owner enables only what it drives, so commands only
            // the suspended owner drove (stop, next) must not stay live.
            Self.disableTransportCommands(on: MPRemoteCommandCenter.shared())
        }
        claims.removeAll { $0.owner === owner }
        claims.append(Claim(owner: owner, suspend: suspend, restore: restore))
    }

    /// Whether `owner` is the newest claimant and so may register targets,
    /// change command state, and publish metadata on the shared centers. A
    /// suspended owner keeps its state locally until it is restored.
    func isCurrentClaimant(_ owner: AnyObject) -> Bool {
        claims.last?.owner === owner
    }

    /// Ends `owner`'s binding to the process-wide centers. The caller must
    /// have removed its own targets first. Disables every transport command,
    /// drops the claim, then restores only the newest remaining claimant, so
    /// one owner's targets and metadata hold the centers. When `owner` was
    /// the last claimant, clears
    /// `MPNowPlayingInfoCenter.default().nowPlayingInfo` instead. A restore
    /// must re-enable every command its owner drives.
    func releaseSharedCenters(_ owner: AnyObject) {
        Self.disableTransportCommands(on: MPRemoteCommandCenter.shared())
        prune()
        claims.removeAll { $0.owner === owner }
        guard let next = claims.last else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        next.restore()
    }

    private func prune() {
        claims.removeAll { $0.owner == nil }
    }
}

/// Owns Silo video's system-media publication and command routing.
///
/// Native Aether video uses the `MPNowPlayingSession` bound to Aether's
/// `AVPlayer`. Aether's software renderer has no player-scoped session, so it
/// uses the process-wide centers explicitly. Keeping both destinations behind
/// one rebinding boundary prevents commands or metadata from remaining
/// registered on the shared and player-scoped centers at the same time.
@MainActor
final class AetherVideoNowPlayingCoordinator {
    struct Handlers {
        var play: () -> Void
        var pause: () -> Void
        var isPaused: () -> Bool
        /// Silo source-media time, not Aether's transport-local player time.
        var currentTime: () -> Double
        /// Accepts a Silo source-media seek target.
        var seek: (Double) -> Void
        var stop: (() -> Void)?
        var next: (() -> Void)?
        var isNextEnabled: () -> Bool = { false }
        /// Whether the transport behind these handlers can act at all.
        /// `AetherPlaybackController.play()` silently returns once a failed
        /// load has cleared the active epoch, so a command answered `.success`
        /// in that state reports work the system will never see happen.
        /// Defaults to actionable for a host that has not declared otherwise.
        var hasActiveLoad: () -> Bool = { true }
    }

    private enum Destination: Equatable {
        case none
        case shared
        #if os(iOS) || os(tvOS)
        /// Payload-free: the bound session is retained and compared by
        /// reference, never by address.
        case session
        #endif
    }

    private struct SkipIntervals {
        var backward: TimeInterval = 10
        var forward: TimeInterval = 10
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "VideoNowPlaying"
    )

    private var destination: Destination = .none
    private var handlers: Handlers?
    private var commandCenter: MPRemoteCommandCenter?
    private var infoCenter: MPNowPlayingInfoCenter?
    private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var nowPlayingInfo: [String: Any] = [:]
    private var preferredSkipIntervals = SkipIntervals()
    private var artworkURL: URL?
    private var artworkFetchTask: Task<Void, Never>?

    #if os(iOS) || os(tvOS)
    /// Retained, not weak: the binding's identity check is only sound while
    /// the bound object cannot be deallocated out from under it. Released in
    /// `unbindCurrentDestination`, so the hold lasts exactly the binding.
    private var session: MPNowPlayingSession?

    /// Rebinds to Aether's native-video session, or to the shared fallback
    /// only for a route for which Aether cannot vend a video session.
    func attach(
        session: MPNowPlayingSession?,
        useSharedFallback: Bool,
        handlers: Handlers
    ) {
        let nextDestination: Destination
        if session != nil {
            nextDestination = .session
        } else if useSharedFallback {
            nextDestination = .shared
        } else {
            nextDestination = .none
        }

        self.handlers = handlers
        let isSameBinding = destination == nextDestination
            && (nextDestination != .session || session === self.session)
        guard !isSameBinding else {
            if let session {
                // A native host can survive an item reload while another app
                // temporarily becomes the active system-media owner.
                session.becomeActiveIfPossible(completion: { _ in })
            }
            updateCommandAvailability()
            publishNowPlayingInfo()
            return
        }

        unbindCurrentDestination()
        destination = nextDestination
        self.session = session

        switch nextDestination {
        case .none:
            break
        case .shared:
            bindSharedCenters()
        case .session:
            guard let session else { return }
            // Protocol V3 may expose a transport-local AVPlayer timeline with
            // a nonzero source offset. Manual publication is required so the
            // system scrubber and its seek commands stay on Silo's source
            // axis rather than Aether's player axis.
            session.automaticallyPublishesNowPlayingInfo = false
            commandCenter = session.remoteCommandCenter
            infoCenter = session.nowPlayingInfoCenter
            session.becomeActiveIfPossible(completion: { _ in })
        }

        registerRemoteCommands()
        publishNowPlayingInfo()
    }
    #else
    /// macOS has no Aether video `MPNowPlayingSession`; bind its active video
    /// route to the process-wide centers and remain detached while idle.
    func attach(useSharedFallback: Bool, handlers: Handlers) {
        let nextDestination: Destination = useSharedFallback ? .shared : .none
        self.handlers = handlers
        guard destination != nextDestination else {
            updateCommandAvailability()
            publishNowPlayingInfo()
            return
        }

        unbindCurrentDestination()
        destination = nextDestination
        if useSharedFallback {
            bindSharedCenters()
            registerRemoteCommands()
            publishNowPlayingInfo()
        }
    }
    #endif

    func detach() {
        handlers = nil
        unbindCurrentDestination()
        destination = .none
        artworkFetchTask?.cancel()
        artworkFetchTask = nil
        artworkURL = nil
        nowPlayingInfo = [:]
    }

    func setPreferredSkipIntervals(backward: TimeInterval, forward: TimeInterval) {
        preferredSkipIntervals = SkipIntervals(
            backward: max(1, backward),
            forward: max(1, forward)
        )
        guard drivesBoundCenters, let center = commandCenter else { return }
        center.skipForwardCommand.preferredIntervals = [
            NSNumber(value: preferredSkipIntervals.forward),
        ]
        center.skipBackwardCommand.preferredIntervals = [
            NSNumber(value: preferredSkipIntervals.backward),
        ]
    }

    /// Publishes the source-media timeline. `position` and `duration` must be
    /// in the same coordinate space because the system returns scrub targets
    /// in the coordinate space represented by this dictionary.
    func update(
        title: String,
        duration: Double,
        position: Double,
        isPlaying: Bool,
        playbackRate: Double = 1
    ) {
        let safeDuration = duration.isFinite ? max(0, duration) : 0
        let safePosition = position.isFinite ? max(0, position) : 0
        let safeRate = playbackRate.isFinite && playbackRate > 0 ? playbackRate : 1

        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        if safeDuration > 0 {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = safeDuration
        } else {
            nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = nil
        }
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = safePosition
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? safeRate : 0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = safeRate
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = NSNumber(
            value: MPNowPlayingInfoMediaType.video.rawValue
        )
        publishNowPlayingInfo()
        updateCommandAvailability()
    }

    func setArtworkURL(_ url: URL?) {
        guard handlers != nil, artworkURL != url else { return }
        artworkURL = url
        artworkFetchTask?.cancel()
        artworkFetchTask = nil

        guard let url else {
            nowPlayingInfo[MPMediaItemPropertyArtwork] = nil
            publishNowPlayingInfo()
            return
        }

        artworkFetchTask = Task { [weak self] in
            await self?.fetchArtwork(from: url)
        }
    }

    /// Loads through the shared Nuke pipeline, so a poster already in its disk
    /// cache is not downloaded again. macOS publishes no artwork, so it skips
    /// the fetch.
    private func fetchArtwork(from url: URL) async {
        #if canImport(UIKit)
        do {
            // No memory-cache write: playback keeps decoded-image memory low,
            // and the published artwork already holds this image.
            let image = try await ImagePipeline.shared.image(
                for: ImageRequest(url: url, options: [.disableMemoryCacheWrites])
            )
            try Task.checkCancellation()
            guard artworkURL == url, handlers != nil else { return }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: image.size
            ) { _ in image }
            publishNowPlayingInfo()
        } catch is CancellationError {
            return
        } catch ImagePipeline.Error.cancelled {
            return
        } catch {
            Self.logger.warning(
                "Artwork fetch failed: \(String(describing: error), privacy: .private)"
            )
        }
        #endif
    }

    private func registerRemoteCommands() {
        guard let center = commandCenter else { return }

        center.playCommand.isEnabled = true
        addTarget(to: center.playCommand) { [weak self] _ in
            guard let handlers = self?.handlers else { return .commandFailed }
            guard handlers.hasActiveLoad() else { return .noActionableNowPlayingItem }
            handlers.play()
            return .success
        }

        center.pauseCommand.isEnabled = true
        addTarget(to: center.pauseCommand) { [weak self] _ in
            guard let handlers = self?.handlers else { return .commandFailed }
            guard handlers.hasActiveLoad() else { return .noActionableNowPlayingItem }
            handlers.pause()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        addTarget(to: center.togglePlayPauseCommand) { [weak self] _ in
            guard let handlers = self?.handlers else { return .commandFailed }
            guard handlers.hasActiveLoad() else { return .noActionableNowPlayingItem }
            handlers.isPaused() ? handlers.play() : handlers.pause()
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [
            NSNumber(value: preferredSkipIntervals.forward),
        ]
        center.skipForwardCommand.isEnabled = true
        addTarget(to: center.skipForwardCommand) { [weak self] event in
            guard let self, let handlers else { return .commandFailed }
            guard handlers.hasActiveLoad() else { return .noActionableNowPlayingItem }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval
                ?? preferredSkipIntervals.forward
            handlers.seek(handlers.currentTime() + interval)
            return .success
        }

        center.skipBackwardCommand.preferredIntervals = [
            NSNumber(value: preferredSkipIntervals.backward),
        ]
        center.skipBackwardCommand.isEnabled = true
        addTarget(to: center.skipBackwardCommand) { [weak self] event in
            guard let self, let handlers else { return .commandFailed }
            guard handlers.hasActiveLoad() else { return .noActionableNowPlayingItem }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval
                ?? preferredSkipIntervals.backward
            handlers.seek(max(0, handlers.currentTime() - interval))
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        addTarget(to: center.changePlaybackPositionCommand) { [weak self] event in
            guard let handlers = self?.handlers,
                  let event = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            guard handlers.hasActiveLoad() else { return .noActionableNowPlayingItem }
            handlers.seek(event.positionTime)
            return .success
        }

        addTarget(to: center.stopCommand) { [weak self] _ in
            guard let handlers = self?.handlers, let stop = handlers.stop else {
                return .noSuchContent
            }
            guard handlers.hasActiveLoad() else { return .noActionableNowPlayingItem }
            stop()
            return .success
        }

        addTarget(to: center.nextTrackCommand) { [weak self] _ in
            guard let handlers = self?.handlers,
                  handlers.isNextEnabled(),
                  let next = handlers.next else {
                return .noSuchContent
            }
            next()
            return .success
        }

        updateCommandAvailability()
    }

    private func addTarget(
        to command: MPRemoteCommand,
        handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus
    ) {
        let target = command.addTarget(handler: handler)
        remoteCommandTargets.append((command, target))
    }

    private func unregisterRemoteCommands() {
        for target in remoteCommandTargets {
            target.command.removeTarget(target.target)
        }
        remoteCommandTargets.removeAll()
    }

    private func updateCommandAvailability() {
        guard drivesBoundCenters, let center = commandCenter else { return }
        center.stopCommand.isEnabled = handlers?.stop != nil
        center.nextTrackCommand.isEnabled = handlers.map {
            $0.next != nil && $0.isNextEnabled()
        } ?? false
    }

    private func publishNowPlayingInfo() {
        guard drivesBoundCenters, let infoCenter else { return }
        infoCenter.nowPlayingInfo = nowPlayingInfo.isEmpty ? nil : nowPlayingInfo
    }

    /// False while suspended on the shared centers behind a newer claimant,
    /// whose metadata and command state this coordinator must not overwrite.
    /// A player-scoped center belongs to this binding alone.
    private var drivesBoundCenters: Bool {
        guard let commandCenter else { return false }
        return commandCenter !== MPRemoteCommandCenter.shared()
            || SharedNowPlayingArbiter.shared.isCurrentClaimant(self)
    }

    /// Binds the process-wide centers and registers this coordinator as a
    /// claimant so another coordinator's teardown cannot silently strip them.
    private func bindSharedCenters() {
        commandCenter = MPRemoteCommandCenter.shared()
        infoCenter = MPNowPlayingInfoCenter.default()
        SharedNowPlayingArbiter.shared.claim(
            self,
            suspend: { [weak self] in self?.unregisterRemoteCommands() },
            restore: { [weak self] in self?.restoreSharedBinding() }
        )
    }

    /// Re-registers targets and republishes metadata once this coordinator is
    /// again the newest claimant. No-op unless still bound to the shared centers.
    private func restoreSharedBinding() {
        guard commandCenter === MPRemoteCommandCenter.shared() else { return }
        unregisterRemoteCommands()
        registerRemoteCommands()
        publishNowPlayingInfo()
    }

    /// Drops the current binding. On the shared centers the arbiter owns the
    /// teardown order, so surviving claimants keep their commands and
    /// metadata. A player-scoped center belongs to this binding alone.
    private func unbindCurrentDestination() {
        unregisterRemoteCommands()
        if commandCenter === MPRemoteCommandCenter.shared() {
            SharedNowPlayingArbiter.shared.releaseSharedCenters(self)
        } else {
            if let commandCenter {
                SharedNowPlayingArbiter.disableTransportCommands(on: commandCenter)
            }
            infoCenter?.nowPlayingInfo = nil
        }
        commandCenter = nil
        infoCenter = nil
        #if os(iOS) || os(tvOS)
        session = nil
        #endif
    }
}
