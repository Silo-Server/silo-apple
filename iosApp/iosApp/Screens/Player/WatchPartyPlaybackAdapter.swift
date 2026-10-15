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

/// How a member converges on the room. Every client (web, Apple, Android)
/// uses these bands and rates, so a mixed room behaves the same everywhere.
/// Drift up to `hardSeek` converges by a pitch-preserved playback rate of at
/// most 4 percent, too small for viewers to notice; only larger drift seeks.
enum WatchPartyCorrection: Equatable {
    case none
    case seek
    case rate(Double)

    /// No correction starts below this drift.
    static let deadband: Double = 0.4
    /// A rate nudge in progress ends once playback is this close.
    static let settle: Double = 0.1
    /// Only drift beyond this makes a playing member seek.
    static let hardSeek: Double = 5
    /// A member that is not playing seeks beyond this drift when the target
    /// is reachable in place; it costs a frame jump, not a rebuild.
    static let stoppedSeek: Double = 1
    static let minRateDelta: Double = 0.01
    static let maxRateDelta: Double = 0.04
    /// One second of drift plays 4 percent fast and converges in about 25s.
    private static let rateGain: Double = 25
    private static let rateStep: Double = 0.005

    /// `drift` is the room position minus the local position, in seconds:
    /// positive when this member is behind.
    static func resolve(drift: Double) -> Self {
        guard drift.isFinite, abs(drift) > deadband else { return .none }
        if abs(drift) > hardSeek { return .seek }
        return .rate(rate(for: drift))
    }

    /// The rate to play at for `drift`, given the rate playing now. A nudge
    /// starts beyond `deadband` and runs until `settle`, so playback that
    /// hovers at the deadband does not flip between rates.
    static func nudge(drift: Double, currentRate: Double) -> Double {
        guard drift.isFinite else { return 1 }
        let threshold = currentRate == 1 ? deadband : settle
        return abs(drift) <= threshold ? 1 : rate(for: drift)
    }

    /// Whether a member that is not playing moves to the target before it
    /// plays or pauses there. Smaller drift is left to the nudge once it plays.
    static func seeksWhileStopped(drift: Double, reachableInPlace: Bool) -> Bool {
        guard drift.isFinite else { return false }
        return abs(drift) > hardSeek || (reachableInPlace && abs(drift) > stoppedSeek)
    }

    static func rate(for drift: Double) -> Double {
        let delta = min(maxRateDelta, max(minRateDelta, abs(drift) / rateGain))
        let stepped = (delta / rateStep).rounded() * rateStep
        return drift > 0 ? 1 + stepped : 1 - stepped
    }

    /// Whether a correction can seek at once instead of loading new media.
    /// Only a target the stream reaches in place can be buffered; any other
    /// seek rebuilds the stream. Aether reports only the buffer ahead of
    /// playback, and a target behind it is media just played, which a browser
    /// keeps buffered too. Without buffer data, which server HLS never
    /// reports, seek at once as before rather than rate-limit every correction.
    static func targetBuffered(_ target: Double, local: Double, locallySeekable: Bool, forwardBuffer: Double?) -> Bool {
        guard locallySeekable else { return false }
        guard target > local, let forwardBuffer, forwardBuffer.isFinite else { return true }
        return target <= local + max(0, forwardBuffer)
    }
}

/// Why a party member seeks, which decides what the seek does to a correction
/// load in flight.
enum WatchPartySeekOrigin: Equatable {
    /// An explicit room seek. It supersedes any correction load and ends the
    /// backoff, as on the web client.
    case room
    /// A seek that realigns this member with the room: a correction to
    /// buffered media, or a command applied to a member that is not playing.
    /// It replaces the seek of any correction load in flight, which would
    /// otherwise never land and block the next load until it went stale.
    case realign
    /// The seek of a correction load, tracked by the load budget itself.
    case correctionLoad
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
    /// How far past its target a load may play and still count as landed.
    static let landingWindow: TimeInterval = 2

    /// Identifies the current load, so a completion from an earlier load
    /// cannot act on a later one aimed at the same position.
    private(set) var generation: UInt64 = 0
    /// Where the in-flight load aims, or nil when none runs.
    private(set) var target: Double?
    /// Whether this load's own seek was taken.
    private(set) var loadStarted = false
    /// Whether that seek finished, so playback is this load's stream.
    private(set) var seekCompleted = false
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

    /// Whether a load is still expected to land. One that never lands, such
    /// as a rebuilt stream that opened far past its aim, stops counting after
    /// `staleAfter`, so it cannot hold off rate corrections indefinitely.
    func inFlight(at now: Date) -> Bool {
        target != nil && now.timeIntervalSince(startedAt) < Self.staleAfter
    }

    /// Records a load toward `roomPosition` and returns where to aim it. The
    /// lead never aims past the end of the media, which the room refuses.
    mutating func begin(roomPosition: Double, at now: Date, duration: Double) -> Double {
        generation &+= 1
        var aim = roomPosition + lead
        if duration > 0 { aim = min(aim, max(roomPosition, duration)) }
        target = aim
        loadStarted = false
        seekCompleted = false
        startedAt = now
        attempts += 1
        nextAllowedAt = now.addingTimeInterval(Self.staleAfter)
        return aim
    }

    mutating func noteLoading() {
        if target != nil { loadStarted = true }
    }

    /// The load's seek finished. Whatever plays now is this load, however
    /// far past its aim the rebuilt stream opened.
    mutating func noteSeekCompleted() {
        if target != nil, loadStarted { seekCompleted = true }
    }

    /// Whether playback at `position` is this load playing. The stream it
    /// replaces can sit on either side of the target, so position alone
    /// cannot settle a load whose seek has not been taken.
    func landed(at position: Double) -> Bool {
        guard let target, loadStarted else { return false }
        let offset = position - target
        return offset >= -WatchPartyCorrection.deadband && (seekCompleted || offset <= Self.landingWindow)
    }

    /// The load is playing: remember its load time and space the next one.
    mutating func land(at now: Date) {
        guard target != nil else { return }
        generation &+= 1
        lead = min(Self.maxLead, max(0, now.timeIntervalSince(startedAt)))
        target = nil
        nextAllowedAt = now.addingTimeInterval(backoff)
    }

    /// Another seek replaced the in-flight load's seek, so it will never
    /// land. Space the next load as for any attempt; with no load in flight
    /// this does nothing.
    mutating func retire(at now: Date) {
        guard target != nil else { return }
        abandon(at: now)
    }

    /// The load went stale without landing. As `allowed(at:)` already does
    /// for a stale load, the next one may start at once: the viewer is still
    /// behind, and backing off here would leave it there for up to a minute.
    mutating func expire(at now: Date) {
        guard target != nil else { return }
        generation &+= 1
        target = nil
        nextAllowedAt = now
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

    /// `origin` says why a seek happens; see `WatchPartySeekOrigin`.
    @discardableResult
    func apply(_ action: WatchPartyPlaybackAction, origin: WatchPartySeekOrigin = .room) async throws -> WatchPartyPlaybackSnapshot {
        guard let player, let context else { throw WatchPartyPlaybackError.invalidated }
        return try await player.applyWatchPartyTransport(action, context: context, origin: origin)
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

    /// Converges a playing member on the room by playback rate; never seeks.
    func nudge(drift: Double) { player?.nudgeWatchPartyPlayback(drift: drift) }

    /// Whether `position` can be reached without rebuilding the stream.
    func canReachInPlace(_ position: Double) -> Bool {
        player?.watchPartyTargetReachableInPlace(position) == true
    }

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
