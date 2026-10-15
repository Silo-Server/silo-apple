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

/// What became of a transport request made through the adapter.
enum WatchPartyRequestOutcome: Equatable {
    /// No party: the caller runs its own transport.
    case solo
    /// The room session sent the request to the room.
    case sent
    /// The party took the request but did not send it: not permitted, a play
    /// from the end, or a session not connected and attached. The caller
    /// still must not run it locally.
    case dropped
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
enum WatchPartyCorrection {
    /// No correction starts below this drift.
    static let deadband: Double = 0.4
    /// A rate nudge in progress ends once playback is this close.
    static let settle: Double = 0.1
    /// Only drift beyond this makes a playing member seek.
    static let hardSeek: Double = 5
    /// The seek band when this member is the host and runs a room command.
    /// A released server takes a host report more than 2 seconds off as the
    /// host's decision and moves the room to it, so a host left up to
    /// `hardSeek` behind would pull every viewer back with it.
    static let hostSeek: Double = 2
    /// A member that is not playing seeks beyond this drift when the target
    /// is reachable in place; it costs a frame jump, not a rebuild.
    static let stoppedSeek: Double = 1
    static let minRateDelta: Double = 0.01
    static let maxRateDelta: Double = 0.04
    /// One second of drift plays 4 percent fast and converges in about 25s.
    private static let rateGain: Double = 25
    private static let rateStep: Double = 0.005

    /// The seek band for a room command this member runs. The drift loop
    /// between commands never seeks, so it has no band.
    static func seekBand(isHost: Bool) -> Double { isHost ? hostSeek : hardSeek }

    /// Whether a playing member seeks for `drift` instead of converging by
    /// rate. `drift` is the room position minus the local position, in
    /// seconds: positive when this member is behind.
    static func seeks(drift: Double, band: Double = hardSeek) -> Bool {
        drift.isFinite && abs(drift) > band
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
    static func seeksWhileStopped(drift: Double, reachableInPlace: Bool, band: Double = hardSeek) -> Bool {
        guard drift.isFinite else { return false }
        return abs(drift) > band || (reachableInPlace && abs(drift) > stoppedSeek)
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

/// A seek this member asked the room for, held on the timeline until the room
/// runs it. In a burst of skips the room's seeks for the earlier skips land
/// first: they move the engine but leave the newest request on the timeline,
/// so the next skip still builds on it. A newer command that replaces the
/// room's seek before it runs, a disconnect, or a timeout releases the
/// request instead. Mirrors Android's pending seek.
struct WatchPartyHeldSeek: Equatable {
    /// A room seek this close to the held request answers it. The server
    /// folds a repeat seek this close to its waiting seek into that seek.
    static let match: Double = 1

    /// The requested position the timeline shows.
    let target: Double
    /// Where the engine plays until the room's seek to `target` runs: its
    /// position at the request, or where an earlier room seek since sent it.
    /// Clock ticks from there are stale, also after that seek runs.
    var origin: Double
    /// The room's seek to `target` has arrived and waits to run.
    var seekArrived = false

    func isAnswered(byRoomSeekTo commanded: Double) -> Bool {
        target.isFinite && commanded.isFinite && abs(target - commanded) <= Self.match
    }

    /// Whether a room command starting now releases this request. Once the
    /// room's seek to it has arrived, any other command that runs replaced
    /// that seek, which will never run here. A command the room sent before
    /// its seek, such as a correction, leaves the request held.
    func isReleased(byCommandSeekingTo position: Double?) -> Bool {
        guard seekArrived else { return false }
        guard let position else { return true }
        return !isAnswered(byRoomSeekTo: position)
    }

    /// The room's seek to `commanded` runs while the timeline shows
    /// `current`. Returns the position to show and the origin of the seek
    /// filter, whose ticks are stale. A seek for an earlier skip in a burst
    /// leaves `held` waiting; the seek that answers it ends it.
    static func roomSeek(to commanded: Double, held: inout WatchPartyHeldSeek?,
                         from current: Double) -> (shown: Double, origin: Double) {
        guard let request = held else { return (commanded, current) }
        if request.isAnswered(byRoomSeekTo: commanded) {
            held = nil
            return (commanded, request.origin)
        }
        held?.origin = commanded
        return (request.target, commanded)
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

    /// Whether playback went from `before` to `after` by moving toward `aim`,
    /// rather than staying on the stream the load was meant to replace. That
    /// stream keeps playing while a refused reanchor is waited out, so it is
    /// judged where it would have played to, `played` seconds on.
    static func moved(from before: Double, played: TimeInterval = 0, to after: Double, toward aim: Double) -> Bool {
        guard before.isFinite, after.isFinite, aim.isFinite, played.isFinite else { return false }
        let oldStream = before + max(0, played)
        return abs(after - aim) + WatchPartyCorrection.stoppedSeek < abs(oldStream - aim)
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
    /// Returns whether the room session sent the request.
    @ObservationIgnored var onUserTransport: ((WatchPartyPlaybackAction, Double, Bool) -> Bool)?
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
    /// Explicit host seeks continue to use apply(.seek). Drift beyond
    /// `seekBand` seeks; see `WatchPartyCorrection.seekBand(isHost:)`.
    func correct(to position: Double, seekBand: Double) async throws -> WatchPartyPlaybackSnapshot {
        guard let player, let context else { throw WatchPartyPlaybackError.invalidated }
        return try await player.correctWatchPartyPlayback(to: position, seekBand: seekBand, context: context)
    }

    func cancelCorrection() { player?.cancelWatchPartyCorrection() }

    /// The room's seek to `position` arrived; it runs a lead later.
    func roomSeekArrived(at position: Double) { player?.noteWatchPartyRoomSeekArrived(at: position) }

    /// A room command starts to run; `position` is its target when it seeks.
    func roomCommandStarts(seekingTo position: Double?) { player?.watchPartyRoomCommandStarts(seekingTo: position) }

    /// The room will not run this member's held seek request: the
    /// connection ended or its commands were dropped.
    func releaseHeldSeek() { player?.releaseWatchPartyHeldSeek() }

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
        submit(action, isPaused: isPaused) != .solo
    }

    /// `request`, telling the caller whether the room will hear of it.
    func submit(_ action: WatchPartyPlaybackAction, isPaused: Bool? = nil) -> WatchPartyRequestOutcome {
        guard context != nil else { return .solo }
        // Play from the end would re-anchor the room at a finished or dead
        // position. A seek is how a member leaves the end.
        if action == .play, snapshot.isEnded { return .dropped }
        guard action.isPermitted(canPlayPause: canPlayPause, canSeek: canSeek),
              onUserTransport?(action, snapshot.sourceTime, isPaused ?? !snapshot.isPlaying) == true else { return .dropped }
        return .sent
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
