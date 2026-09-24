import Foundation
import Observation

/// Captured room selection. Wire IDs and room authority belong to WatchPartySession.
struct WatchPartyPlaybackContext: Equatable, Sendable {
    let roomId: String
    let selectionRevision: Int64
    let contentId: String
    let fileId: Int
    let libraryId: Int?
    let startPosition: Double
}

enum WatchPartyPlaybackAction: Equatable, Sendable {
    case play
    case pause
    case seek(Double)

    func isPermitted(canPlayPause: Bool, canSeek: Bool) -> Bool {
        switch self {
        case .play, .pause: return canPlayPause
        case .seek: return canSeek
        }
    }
}

struct WatchPartyPlaybackSnapshot: Equatable, Sendable {
    var sessionId: String?
    var fileId: Int?
    var sourceTime: Double = 0
    var duration: Double = 0
    var isPlaying = false
    var isBuffering = false
    var isReady = false
    var isSeeking = false
    /// The stream reached end of file and is parked there.
    var isEnded = false
}

enum WatchPartyPlaybackError: Error {
    case invalidated
    case notReady
}

enum WatchPartyCorrection: Equatable {
    case none
    case seek
    case temporaryRate(Double)

    static func resolve(drift: Double, locallySeekable: Bool) -> Self {
        guard drift.isFinite, abs(drift) > 0.35 else { return .none }
        if locallySeekable || abs(drift) > 2 { return .seek }
        return .temporaryRate(drift > 0 ? 1.05 : 0.95)
    }
}

/// The only room-specific interface exposed by the existing video player.
/// Command identity, scheduling, attachment and reporting stay in the room session.
@MainActor @Observable
final class WatchPartyPlaybackAdapter {
    @ObservationIgnored private weak var player: PlayerViewModel?
    private(set) var context: WatchPartyPlaybackContext?
    private(set) var snapshot = WatchPartyPlaybackSnapshot()
    var canPlayPause = false
    var canSeek = false
    @ObservationIgnored var onSnapshot: ((WatchPartyPlaybackSnapshot) -> Void)?
    @ObservationIgnored var onSessionCommitted: ((String) -> Void)?
    @ObservationIgnored var onUserTransport: ((WatchPartyPlaybackAction, Double, Bool) -> Void)?
    @ObservationIgnored var onLocalExit: (() -> Void)?
    @ObservationIgnored var onResyncRequired: (() -> Void)?
    @ObservationIgnored var onFailure: ((String?, String) -> Void)?

    init(player: PlayerViewModel) { self.player = player }

    func prepare(_ context: WatchPartyPlaybackContext) {
        guard self.context != context else { return }
        self.context = context
        snapshot = WatchPartyPlaybackSnapshot()
        player?.prepareWatchParty(context, adapter: self)
    }

    @discardableResult
    func apply(_ action: WatchPartyPlaybackAction) async throws -> WatchPartyPlaybackSnapshot {
        guard let player, let context else { throw WatchPartyPlaybackError.invalidated }
        return try await player.applyWatchPartyTransport(action, context: context)
    }

    func canSeekLocally(to position: Double) -> Bool {
        player?.canSeekWatchPartyLocally(to: position) == true
    }

    /// Only for a server-targeted correction of an already playing viewer.
    /// Explicit host seeks continue to use apply(.seek).
    func correct(to position: Double) async throws -> WatchPartyPlaybackSnapshot {
        guard let player, let context else { throw WatchPartyPlaybackError.invalidated }
        return try await player.correctWatchPartyPlayback(to: position, context: context)
    }

    func cancelCorrection() { player?.cancelWatchPartyCorrection() }

    /// A suspended native pipeline may have been released by Aether. Mount it
    /// paused before the room's attachment/readiness handshake can continue.
    func restoreIfNeeded(at position: Double) {
        guard context != nil else { return }
        player?.restoreWatchPartyPlaybackIfNeeded(at: position)
    }

    /// Return true even when denied: the caller must never fall through to solo transport.
    @discardableResult
    func request(_ action: WatchPartyPlaybackAction, isPaused: Bool? = nil) -> Bool {
        guard context != nil else { return false }
        // Play from the end would re-anchor the room at a finished or dead
        // position. A seek is how a member leaves the end.
        if action == .play, snapshot.isEnded { return true }
        if action.isPermitted(canPlayPause: canPlayPause, canSeek: canSeek) {
            onUserTransport?(action, snapshot.sourceTime, isPaused ?? !snapshot.isPlaying)
        }
        return true
    }

    func stop() {
        context = nil
        player?.stopWatchPartyPlayback(adapter: self)
        update(WatchPartyPlaybackSnapshot())
    }

    func update(_ value: WatchPartyPlaybackSnapshot) {
        let priorSession = snapshot.sessionId
        snapshot = value
        if let sessionId = value.sessionId, priorSession != sessionId {
            onSessionCommitted?(sessionId)
        }
        onSnapshot?(value)
    }

    func playerDidExit() {
        guard context != nil else { return }
        context = nil
        snapshot = WatchPartyPlaybackSnapshot()
        onLocalExit?()
    }
}
