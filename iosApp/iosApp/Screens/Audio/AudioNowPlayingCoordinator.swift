import Foundation
import MediaPlayer
import OSLog
#if canImport(UIKit)
import UIKit
#endif

/// Owns the system-media boundary for the audiobook player.
///
/// Aether's native audio route owns an `MPNowPlayingSession` tied to its
/// `AVPlayer`. Commands and metadata must use that session's centers so the
/// app remains the active Now Playing owner while paused in the background.
/// Software-audio routes do not have such a session, so those routes use the
/// process-wide centers explicitly as a fallback.
@MainActor
final class AudioNowPlayingCoordinator {
    struct Handlers {
        let play: () -> Void
        let pause: () -> Void
        let isPaused: () -> Bool
        let currentTime: () -> Double
        let seek: (Double) -> Void
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "AudioNowPlaying"
    )

    private var handlers: Handlers?
    private var commandCenter: MPRemoteCommandCenter?
    private var infoCenter: MPNowPlayingInfoCenter?
    private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
    private var preferredSkipInterval: TimeInterval = 30
    private var nowPlayingInfo: [String: Any] = [:]
    private var artworkURL: URL?
    private var artworkFetchTask: Task<Void, Never>?

    #if os(iOS) || os(tvOS)
    private weak var session: MPNowPlayingSession?

    /// Binds to Aether's player-scoped centers when available. Turning off
    /// automatic publication is intentional: Aether's player clock is local
    /// to one audiobook file, while Silo publishes a stitched whole-book
    /// duration and playhead across file boundaries.
    func attach(session: MPNowPlayingSession?, handlers: Handlers) {
        self.handlers = handlers
        unbindCurrentCenters()
        self.session = session

        if let session {
            session.automaticallyPublishesNowPlayingInfo = false
            commandCenter = session.remoteCommandCenter
            infoCenter = session.nowPlayingInfoCenter
            session.becomeActiveIfPossible(completion: { _ in })
        } else {
            bindSharedCenters()
        }

        registerRemoteCommands()
        publishNowPlayingInfo()
    }
    #else
    /// MPNowPlayingSession is unavailable on macOS. This is the same explicit
    /// fallback used when an Aether software-audio route has no session.
    func attach(handlers: Handlers) {
        self.handlers = handlers
        unbindCurrentCenters()
        bindSharedCenters()
        registerRemoteCommands()
        publishNowPlayingInfo()
    }
    #endif

    func detach() {
        handlers = nil
        unbindCurrentCenters()
        #if os(iOS) || os(tvOS)
        session = nil
        #endif
        artworkFetchTask?.cancel()
        artworkFetchTask = nil
        artworkURL = nil
        nowPlayingInfo = [:]
    }

    func update(
        title: String,
        artist: String?,
        albumTitle: String,
        duration: Double,
        position: Double,
        isPlaying: Bool,
        playbackRate: Double
    ) {
        nowPlayingInfo[MPMediaItemPropertyTitle] = title
        if let artist, !artist.isEmpty {
            nowPlayingInfo[MPMediaItemPropertyArtist] = artist
        } else {
            nowPlayingInfo[MPMediaItemPropertyArtist] = nil
        }
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle] = albumTitle
        nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = max(0, duration)
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, position)
        nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = playbackRate
        nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = NSNumber(
            value: MPNowPlayingInfoMediaType.audio.rawValue
        )
        publishNowPlayingInfo()
    }

    func setArtworkURL(_ url: URL?) {
        guard artworkURL != url else { return }
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
            guard artworkURL == url else { return }
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            nowPlayingInfo[MPMediaItemPropertyArtwork] = artwork
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
            guard let handler = self?.handlers?.play else { return .commandFailed }
            handler()
            return .success
        }

        center.pauseCommand.isEnabled = true
        addTarget(to: center.pauseCommand) { [weak self] _ in
            guard let handler = self?.handlers?.pause else { return .commandFailed }
            handler()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        addTarget(to: center.togglePlayPauseCommand) { [weak self] _ in
            guard let handlers = self?.handlers else { return .commandFailed }
            handlers.isPaused() ? handlers.play() : handlers.pause()
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: preferredSkipInterval)]
        center.skipForwardCommand.isEnabled = true
        addTarget(to: center.skipForwardCommand) { [weak self] event in
            guard let self, let handlers else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? preferredSkipInterval
            handlers.seek(handlers.currentTime() + interval)
            return .success
        }

        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: preferredSkipInterval)]
        center.skipBackwardCommand.isEnabled = true
        addTarget(to: center.skipBackwardCommand) { [weak self] event in
            guard let self, let handlers else { return .commandFailed }
            let interval = (event as? MPSkipIntervalCommandEvent)?.interval ?? preferredSkipInterval
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

    private func publishNowPlayingInfo() {
        guard let infoCenter else { return }
        infoCenter.nowPlayingInfo = nowPlayingInfo.isEmpty ? nil : nowPlayingInfo
    }

    /// Binds the process-wide centers and registers this coordinator as a
    /// claimant so another coordinator's teardown cannot silently strip them.
    private func bindSharedCenters() {
        commandCenter = MPRemoteCommandCenter.shared()
        infoCenter = MPNowPlayingInfoCenter.default()
        SharedNowPlayingArbiter.shared.claim(self) { [weak self] in
            self?.restoreSharedBinding()
        }
    }

    /// Re-registers targets and republishes metadata after another claimant
    /// released the shared centers. No-op unless still bound to them.
    private func restoreSharedBinding() {
        guard commandCenter === MPRemoteCommandCenter.shared() else { return }
        unregisterRemoteCommands()
        registerRemoteCommands()
        publishNowPlayingInfo()
    }

    /// Drops the current binding. Clearing published metadata is process-wide
    /// when bound to the shared centers, so it may only happen once the last
    /// claimant leaves; otherwise the surviving claimant is restored instead.
    private func unbindCurrentCenters() {
        unregisterRemoteCommands()
        let mayClearPublishedInfo = commandCenter === MPRemoteCommandCenter.shared()
            ? SharedNowPlayingArbiter.shared.release(self)
            : true
        if mayClearPublishedInfo {
            infoCenter?.nowPlayingInfo = nil
        }
        commandCenter = nil
        infoCenter = nil
    }
}
