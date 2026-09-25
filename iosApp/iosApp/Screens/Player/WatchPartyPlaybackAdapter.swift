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

/// How a member applies a room correction, matching the web client's
/// `roomSyncCatchup.ts` so native and browser members converge the same way.
/// Small drift against a target the stream cannot reach without a rebuild
/// converges by playback rate; everything reachable in place stays a seek.
enum WatchPartyCorrection: Equatable {
    case none
    case seek
    case rate(Double)

    /// Drift within this band converges by rate instead of rebuilding the stream.
    static let catchupBand: Double = 2
    /// Playback already this close to the room needs no correction.
    static let deadband: Double = 0.35
    static let minRate: Double = 0.9
    static let maxRate: Double = 1.25
    /// A 1s deficit plays at 1.125x and converges in about 8s; the band edge
    /// reaches the cap. Gentle on purpose: this runs during normal playback.
    private static let rateDivisor: Double = 8

    /// `drift` is the room target minus the local position, in seconds.
    static func resolve(drift: Double, locallySeekable: Bool) -> Self {
        guard drift.isFinite, abs(drift) > deadband else { return .none }
        if locallySeekable || abs(drift) > catchupBand { return .seek }
        return .rate(min(maxRate, max(minRate, 1 + drift / rateDivisor)))
    }

    /// The room keeps advancing at 1x after a correction executes, so a rate
    /// catch-up converges on that moving position, not the static target.
    static func expectedPosition(_ target: Double, elapsed: TimeInterval) -> Double {
        max(0, target + max(0, elapsed))
    }

    static func converged(target: Double, elapsed: TimeInterval, local: Double) -> Bool {
        abs(expectedPosition(target, elapsed: elapsed) - local) <= deadband
    }
}

/// Correction-driven media loads, matching the web client. A correction whose
/// target is not buffered has to load media and lands late by its load time;
/// with a load on every correction a slow viewer chases the advancing room
/// forever. Only one load runs at a time, later ones back off from 10 to 60
/// seconds until the viewer converges, and each aims ahead of the room by the
/// load time the previous one took, up to 10 seconds.
struct WatchPartyReloadBudget: Equatable {
    static let minInterval: TimeInterval = 10
    static let maxInterval: TimeInterval = 60
    /// A load that never lands stops blocking the next one after this long.
    static let staleAfter: TimeInterval = 30
    static let maxLead: TimeInterval = 10

    /// Identifies the current load, so a completion from an earlier load
    /// cannot act on a later one aimed at the same position.
    private(set) var generation: UInt64 = 0
    /// Where the in-flight load aims, or nil when none runs.
    private(set) var target: Double?
    /// Whether this load's own seek was taken.
    private(set) var loadStarted = false
    private(set) var startedAt: Date = .distantPast
    private(set) var nextAllowedAt: Date = .distantPast
    /// Loads since the viewer last converged on the room.
    private(set) var attempts = 0
    /// Load time the last load took, added to the next target.
    private(set) var lead: TimeInterval = 0

    func allowed(at now: Date) -> Bool {
        if target != nil { return now.timeIntervalSince(startedAt) >= Self.staleAfter }
        return now >= nextAllowedAt
    }

    /// Records a load toward `roomPosition` and returns where to aim it. The
    /// lead never aims past the end of the media, which the room refuses.
    mutating func begin(roomPosition: Double, at now: Date, duration: Double) -> Double {
        generation &+= 1
        var aim = roomPosition + lead
        if duration > 0 { aim = min(aim, max(roomPosition, duration)) }
        target = aim
        loadStarted = false
        startedAt = now
        attempts += 1
        nextAllowedAt = now.addingTimeInterval(Self.staleAfter)
        return aim
    }

    mutating func noteLoading() {
        if target != nil { loadStarted = true }
    }

    /// Whether playback at `position` is this load playing. The stream it
    /// replaces can sit on either side of the target, so position alone
    /// cannot settle a load whose seek has not been taken.
    func landed(at position: Double) -> Bool {
        guard let target, loadStarted else { return false }
        let offset = position - target
        return offset >= -WatchPartyCorrection.deadband && offset <= WatchPartyCorrection.catchupBand
    }

    /// The load is playing: remember its load time and space the next one.
    mutating func land(at now: Date) {
        guard target != nil else { return }
        generation &+= 1
        lead = min(Self.maxLead, max(0, now.timeIntervalSince(startedAt)))
        target = nil
        nextAllowedAt = now.addingTimeInterval(backoff)
    }

    /// The load was refused or superseded; space the next one.
    mutating func abandon(at now: Date) {
        generation &+= 1
        target = nil
        nextAllowedAt = now.addingTimeInterval(backoff)
    }

    /// The viewer reached the room; the next drift starts a fresh backoff.
    mutating func settle() {
        attempts = 0
        nextAllowedAt = .distantPast
    }

    private var backoff: TimeInterval {
        min(Self.maxInterval, Self.minInterval * pow(2, Double(max(0, attempts - 1))))
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

    /// `correction` marks a seek that realigns this member rather than an
    /// explicit room seek, so it leaves the correction load budget alone.
    @discardableResult
    func apply(_ action: WatchPartyPlaybackAction, correction: Bool = false) async throws -> WatchPartyPlaybackSnapshot {
        guard let player, let context else { throw WatchPartyPlaybackError.invalidated }
        return try await player.applyWatchPartyTransport(action, context: context, correction: correction)
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
