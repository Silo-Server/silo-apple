import Foundation
import MediaPlayer
import OSLog
#if canImport(UIKit)
import UIKit
#endif

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
    }

    private enum Destination: Equatable {
        case none
        case shared
        #if os(iOS) || os(tvOS)
        case session(ObjectIdentifier)
        #endif
    }

    private struct SkipIntervals {
        var backward: TimeInterval = 10
        var forward: TimeInterval = 10
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
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
    private weak var session: MPNowPlayingSession?

    /// Rebinds to Aether's native-video session, or to the shared fallback
    /// only for a route for which Aether cannot vend a video session.
    func attach(
        session: MPNowPlayingSession?,
        useSharedFallback: Bool,
        handlers: Handlers
    ) {
        let nextDestination: Destination
        if let session {
            nextDestination = .session(ObjectIdentifier(session))
        } else if useSharedFallback {
            nextDestination = .shared
        } else {
            nextDestination = .none
        }

        self.handlers = handlers
        guard destination != nextDestination else {
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
            commandCenter = MPRemoteCommandCenter.shared()
            infoCenter = MPNowPlayingInfoCenter.default()
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
            commandCenter = MPRemoteCommandCenter.shared()
            infoCenter = MPNowPlayingInfoCenter.default()
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

    func setPreferredSkipInterval(_ seconds: TimeInterval) {
        setPreferredSkipIntervals(backward: seconds, forward: seconds)
    }

    func setPreferredSkipIntervals(backward: TimeInterval, forward: TimeInterval) {
        preferredSkipIntervals = SkipIntervals(
            backward: max(1, backward),
            forward: max(1, forward)
        )
        guard let center = commandCenter else { return }
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

    private func fetchArtwork(from url: URL) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()
            if let response = response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                Self.logger.warning("Artwork fetch HTTP \(response.statusCode)")
                return
            }
            #if canImport(UIKit)
            guard let image = UIImage(data: data) else {
                Self.logger.warning("Artwork decode failed")
                return
            }
            guard artworkURL == url, handlers != nil else { return }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(
                boundsSize: image.size
            ) { _ in image }
            publishNowPlayingInfo()
            #else
            _ = data
            #endif
        } catch is CancellationError {
            return
        } catch {
            Self.logger.warning(
                "Artwork fetch failed: \(String(describing: error), privacy: .private)"
            )
        }
    }

    private func registerRemoteCommands() {
        guard let center = commandCenter else { return }

        center.playCommand.isEnabled = true
        addTarget(to: center.playCommand) { [weak self] _ in
            guard let play = self?.handlers?.play else { return .commandFailed }
            play()
            return .success
        }

        center.pauseCommand.isEnabled = true
        addTarget(to: center.pauseCommand) { [weak self] _ in
            guard let pause = self?.handlers?.pause else { return .commandFailed }
            pause()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        addTarget(to: center.togglePlayPauseCommand) { [weak self] _ in
            guard let handlers = self?.handlers else { return .commandFailed }
            handlers.isPaused() ? handlers.play() : handlers.pause()
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [
            NSNumber(value: preferredSkipIntervals.forward),
        ]
        center.skipForwardCommand.isEnabled = true
        addTarget(to: center.skipForwardCommand) { [weak self] event in
            guard let self, let handlers else { return .commandFailed }
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
            handlers.seek(event.positionTime)
            return .success
        }

        addTarget(to: center.stopCommand) { [weak self] _ in
            guard let stop = self?.handlers?.stop else { return .noSuchContent }
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
        guard let center = commandCenter else { return }
        center.stopCommand.isEnabled = handlers?.stop != nil
        center.nextTrackCommand.isEnabled = handlers.map {
            $0.next != nil && $0.isNextEnabled()
        } ?? false
    }

    private func publishNowPlayingInfo() {
        guard let infoCenter else { return }
        infoCenter.nowPlayingInfo = nowPlayingInfo.isEmpty ? nil : nowPlayingInfo
    }

    private func unbindCurrentDestination() {
        unregisterRemoteCommands()
        infoCenter?.nowPlayingInfo = nil
        commandCenter = nil
        infoCenter = nil
        #if os(iOS) || os(tvOS)
        session = nil
        #endif
    }
}
