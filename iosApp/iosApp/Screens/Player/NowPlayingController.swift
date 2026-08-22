import Foundation
import MediaPlayer
import OSLog
#if canImport(UIKit)
import UIKit
#endif

/// Bridges a SiloControl remote-media session into `MPNowPlayingInfoCenter` +
/// the shared `MPRemoteCommandCenter`. Library video and audiobook playback
/// use their Aether-scoped coordinators instead.
///
/// The owner supplies command handlers as closures via `attach(handlers:)`.
///
/// Single ownership: the SiloControl client owns one instance and attaches it
/// only for the lifetime of a remote-media session.
final class NowPlayingController {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "NowPlaying"
    )

    /// Command handlers the view model supplies. All fire on the main queue
    /// (the OS already dispatches remote commands there).
    struct Handlers {
        /// Called when the user presses Play on the lock screen / remote.
        var play: () -> Void
        /// Called when the user presses Pause.
        var pause: () -> Void
        /// True if currently paused. Used by togglePlayPause to decide
        /// which verb to fire.
        var isPaused: () -> Bool
        /// Absolute playback time in seconds, used by skip commands to
        /// compute the seek target.
        var currentTime: () -> Double
        /// Called with an absolute seek target in seconds.
        var seek: (Double) -> Void
        /// Called when the user presses Stop, when the system exposes it.
        var stop: (() -> Void)?
        /// Called when the user presses Next, when the active session has one.
        var next: (() -> Void)?
        /// True when `next` should be exposed as an enabled command.
        var isNextEnabled: () -> Bool = { false }
    }

    private struct SkipIntervals {
        var backward: TimeInterval
        var forward: TimeInterval
    }

    private var handlers: Handlers?
    private var isActive = false
    private var remoteCommandTargets: [(command: MPRemoteCommand, target: Any)] = []
    /// URL of the artwork most recently requested. Used to dedupe fetches
    /// when `setArtworkURL` is called repeatedly with the same source while
    /// a fetch is already in flight or has already published.
    private var currentArtworkURL: URL?
    private var artworkFetchTask: Task<Void, Never>?
    private var preferredSkipIntervals = SkipIntervals(backward: 10, forward: 10)

    enum MediaKind {
        case video
        case audio

        var nowPlayingValue: NSNumber {
            switch self {
            case .video:
                NSNumber(value: MPNowPlayingInfoMediaType.video.rawValue)
            case .audio:
                NSNumber(value: MPNowPlayingInfoMediaType.audio.rawValue)
            }
        }
    }

    // MARK: - Lifecycle

    /// Attach command handlers. Idempotent and safe to call more than once
    /// when the remote-control session changes.
    func attach(handlers: Handlers) {
        self.handlers = handlers
        if !isActive {
            registerRemoteCommands()
            isActive = true
        } else {
            updateCommandAvailability()
        }
    }

    func detach() {
        guard isActive else { return }
        isActive = false
        handlers = nil

        artworkFetchTask?.cancel()
        artworkFetchTask = nil
        currentArtworkURL = nil

        unregisterRemoteCommands()

        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func setPreferredSkipInterval(_ seconds: TimeInterval) {
        setPreferredSkipIntervals(backward: seconds, forward: seconds)
    }

    func setPreferredSkipIntervals(backward: TimeInterval, forward: TimeInterval) {
        preferredSkipIntervals = SkipIntervals(
            backward: max(1, backward),
            forward: max(1, forward)
        )
        guard isActive else { return }
        let center = MPRemoteCommandCenter.shared()
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: preferredSkipIntervals.forward)]
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: preferredSkipIntervals.backward)]
    }

    // MARK: - State updates

    /// Refresh the Now Playing dictionary. Call on file-loaded, on
    /// time-change (≤1 Hz — do not flood), and on pause change. `isPlaying`
    /// feeds the playback-rate field which the OS uses to animate the
    /// scrubber between time updates.
    func update(
        title: String,
        duration: Double,
        position: Double,
        isPlaying: Bool,
        mediaKind: MediaKind = .video,
        artist: String? = nil,
        albumTitle: String? = nil,
        playbackRate: Double = 1.0
    ) {
        guard isActive else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = title
        if let artist, !artist.isEmpty {
            info[MPMediaItemPropertyArtist] = artist
        }
        if let albumTitle, !albumTitle.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = albumTitle
        }
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? playbackRate : 0.0
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = playbackRate
        info[MPNowPlayingInfoPropertyMediaType] = mediaKind.nowPlayingValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        updateCommandAvailability()
    }

    /// Fetch and publish poster artwork for the active item. Idempotent for
    /// the same URL — repeated calls with an unchanged URL no-op rather than
    /// re-fetching. Pass `nil` to clear the artwork field. Fetch happens on
    /// a background `URLSession.shared` data task; failures are logged and
    /// leave the existing artwork (if any) unchanged.
    func setArtworkURL(_ url: URL?) {
        guard isActive else { return }
        if currentArtworkURL == url {
            return
        }
        currentArtworkURL = url
        artworkFetchTask?.cancel()
        artworkFetchTask = nil
        guard let url else {
            applyArtwork(nil)
            return
        }
        artworkFetchTask = Task { [weak self] in
            await self?.fetchAndApplyArtwork(url: url)
        }
    }

    private func fetchAndApplyArtwork(url: URL) async {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            try Task.checkCancellation()
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                Self.logger.warning(
                    "Artwork fetch HTTP \(http.statusCode)"
                )
                return
            }
            #if canImport(UIKit)
            guard let image = UIImage(data: data) else {
                Self.logger.warning("Artwork decode failed")
                return
            }
            await MainActor.run { [weak self] in
                guard let self, self.isActive else { return }
                guard self.currentArtworkURL == url else { return }
                self.applyArtwork(image)
            }
            #else
            // macOS Now Playing doesn't take MPMediaItemArtwork the same way;
            // skip publishing rather than misuse the API.
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

    #if canImport(UIKit)
    private func applyArtwork(_ image: UIImage?) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        if let image {
            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            info[MPMediaItemPropertyArtwork] = artwork
        } else {
            info[MPMediaItemPropertyArtwork] = nil
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    #else
    private func applyArtwork(_ image: Any?) {
        // No-op on macOS for this client. macOS surfaces playback differently.
    }
    #endif

    // MARK: - Remote commands

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        addTarget(to: center.playCommand) { [weak self] _ in
            self?.handlers?.play()
            return .success
        }

        center.pauseCommand.isEnabled = true
        addTarget(to: center.pauseCommand) { [weak self] _ in
            self?.handlers?.pause()
            return .success
        }

        center.togglePlayPauseCommand.isEnabled = true
        addTarget(to: center.togglePlayPauseCommand) { [weak self] _ in
            guard let h = self?.handlers else { return .commandFailed }
            if h.isPaused() {
                h.play()
            } else {
                h.pause()
            }
            return .success
        }

        center.skipForwardCommand.preferredIntervals = [NSNumber(value: preferredSkipIntervals.forward)]
        center.skipForwardCommand.isEnabled = true
        addTarget(to: center.skipForwardCommand) { [weak self] event in
            guard let h = self?.handlers else { return .commandFailed }
            let fallback = self?.preferredSkipIntervals.forward ?? 10
            let skip = (event as? MPSkipIntervalCommandEvent)?.interval ?? fallback
            h.seek(h.currentTime() + skip)
            return .success
        }

        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: preferredSkipIntervals.backward)]
        center.skipBackwardCommand.isEnabled = true
        addTarget(to: center.skipBackwardCommand) { [weak self] event in
            guard let h = self?.handlers else { return .commandFailed }
            let fallback = self?.preferredSkipIntervals.backward ?? 10
            let skip = (event as? MPSkipIntervalCommandEvent)?.interval ?? fallback
            h.seek(max(0, h.currentTime() - skip))
            return .success
        }

        center.changePlaybackPositionCommand.isEnabled = true
        addTarget(to: center.changePlaybackPositionCommand) { [weak self] event in
            guard let h = self?.handlers,
                  let positionEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            h.seek(positionEvent.positionTime)
            return .success
        }

        addTarget(to: center.stopCommand) { [weak self] _ in
            guard let stop = self?.handlers?.stop else { return .noSuchContent }
            stop()
            return .success
        }

        addTarget(to: center.nextTrackCommand) { [weak self] _ in
            guard let h = self?.handlers,
                  h.isNextEnabled(),
                  let next = h.next else {
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
        guard isActive else { return }
        let center = MPRemoteCommandCenter.shared()
        center.stopCommand.isEnabled = handlers?.stop != nil
        center.nextTrackCommand.isEnabled = handlers.map { $0.next != nil && $0.isNextEnabled() } ?? false
    }
}
