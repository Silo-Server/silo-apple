import AetherEngine
import Foundation

/// Whether a stream that already played is connected to the server.
/// `reconnecting` while the player retries after a mid-stream drop, `lost`
/// once it gave up and offers Try again.
enum PlaybackConnectionState: Equatable {
    case connected
    case reconnecting
    case lost
}

/// The rules of a mid-stream reconnect (playback protocol v3 §6.2, "A lost
/// connection is not a failed route").
///
/// A stream that already showed frames and then lost the server has not
/// failed its route, so the player must not report it with
/// `failure_recovery`: that operation excludes the current route, and a
/// direct-play viewer would come back on a transcode. Instead each attempt
/// asks for the current route again with a `track_change` that changes
/// nothing, at the saved position. When the session did not survive (a server
/// restart answers 404) the player starts a new session at the same position
/// with the same tracks.
enum PlaybackReconnectPolicy {
    /// The classification a reconnect replan carries. It maps to
    /// `track_change` (see `PlaybackSessionBridge.replanOperation`), which
    /// keeps the current route eligible.
    static let classification = "connection_lost"

    /// Backoff: 1 s doubling to a 15 s cap, for 12 attempts, about two and a
    /// quarter minutes in total.
    static let baseDelay: TimeInterval = 1
    static let maxDelay: TimeInterval = 15
    static let maxAttempts = 12
    /// A cycle that starts within this long of the previous one recovering
    /// continues that cycle's budget, so a server that answers the API but
    /// drops every stream cannot keep the player retrying forever.
    static let stableInterval: TimeInterval = 30

    /// Delay before the next attempt once `attempts` attempts were made.
    static func delay(afterAttempts attempts: Int) -> TimeInterval {
        let exponent = min(max(0, attempts), 16)
        return min(maxDelay, baseDelay * pow(2, Double(exponent)))
    }

    /// Which request of an attempt failed.
    enum Step: Equatable {
        /// The no-op `track_change` replan against the current session.
        case replan
        /// A new session at the saved position.
        case start
    }

    /// What an attempt's failure means for the cycle.
    enum Verdict: Equatable {
        /// The server could not be reached, was overloaded, or asked for a
        /// retry: wait for the next attempt.
        case retryLater
        /// The server answered the replan, but the session did not survive.
        /// Start a new session at the saved position.
        case startNewSession
        /// The server refused a new session: stop and tell the viewer.
        case giveUp
    }

    static func verdict(for error: Error, step: Step) -> Verdict {
        if isUnanswered(error) { return .retryLater }
        switch step {
        case .replan:
            // Anything the server said means the session is gone (404 after a
            // restart, an expiry, a terminal answer). That includes
            // `installation_changed`: a replan always carries the old
            // session's installation and cannot succeed, while a new start
            // probes the new one. A failure on this side (the adopted plan's
            // load) is not the server's verdict; try again later.
            return isServerAnswer(error) ? .startNewSession : .retryLater
        case .start:
            // The start already re-probed after `installation_changed`
            // (`withInstallationRefresh`); one that still says so is a server
            // mid-upgrade, which a later attempt can reach.
            if PlaybackV3CapabilityGate.isInstallationChanged(error) { return .retryLater }
            return isServerAnswer(error) ? .giveUp : .retryLater
        }
    }

    /// Whether a request failed without the server deciding anything: it was
    /// unreachable or overloaded (`isTransient`), or another replan of the
    /// session held the lease. A recovery replan that fails this way after
    /// the viewing played joins the reconnect instead of ending playback.
    static func isUnanswered(_ error: Error) -> Bool {
        if isTransient(error) { return true }
        if let problem = problem(in: error), problem.identifier == "replan_in_progress" {
            return true
        }
        return false
    }

    /// Whether a failed request may succeed if it is sent again later: it
    /// never got an answer (connection refused, timeout, DNS, connection
    /// lost), or the server answered 5xx, 408 or 429.
    static func isTransient(_ error: Error) -> Bool {
        if let status = httpStatus(in: error) {
            return status >= 500 || status == 408 || status == 429
        }
        var transport = error
        if case HTTPError.network(let underlying) = error { transport = underlying }
        if let urlError = transport as? URLError { return urlError.code != .cancelled }
        if case HTTPError.network = error { return true }
        return false
    }

    /// Whether an Aether failure on a transport that already showed a frame
    /// is the server going away rather than the route failing. The URL
    /// error underneath says so directly. Otherwise a source that died is
    /// a lost connection only while the app also cannot reach the server
    /// (`serverUnreachable`): a dead transcoder on a server that answers is a
    /// route failure and keeps the ordinary recovery.
    static func isConnectionLoss(_ failure: PlaybackErrorInfo, serverUnreachable: Bool) -> Bool {
        if failure.underlyingDomain == NSURLErrorDomain,
           let code = failure.underlyingCode,
           connectivityErrorCodes.contains(code) {
            return true
        }
        return serverUnreachable && sourceFailureKinds.contains(failure.kind)
    }

    /// An end of stream this far from the end, or earlier, cannot be the
    /// item finishing. Matches the near-end window in which a playback
    /// error still counts as a natural end.
    static let naturalEndSeconds: Double = 8
    static let naturalEndFraction: Double = 0.985

    /// Whether `position` is short of the end of an item `duration` long.
    /// False when the duration is unknown, which leaves an end of stream as
    /// it was reported.
    static func isBeforeNaturalEnd(position: Double, duration: Double) -> Bool {
        guard duration.isFinite, duration > 0, position.isFinite, position >= 0 else {
            return false
        }
        return duration - position > naturalEndSeconds
            && position / duration < naturalEndFraction
    }

    /// Where to reconnect when the engine reports end of stream, or nil when
    /// it is the item finishing. Aether turns a source that stopped
    /// delivering (its reconnect ladder ran out after a seek past the
    /// buffer) into an ordinary end of stream, and its clock can run on, or
    /// park, without a frame, so the playhead is the last position the
    /// stream actually played from (`PlaybackSourceWatch.playhead`). An end
    /// of stream short of the end while the source was failing is a lost
    /// connection (§6.2).
    static func endOfStreamReconnectPosition(
        playhead: Double,
        duration: Double,
        sourceStalled: Bool,
        serverUnreachable: Bool
    ) -> Double? {
        guard sourceStalled || serverUnreachable,
              isBeforeNaturalEnd(position: playhead, duration: duration) else {
            return nil
        }
        return playhead
    }

    /// `NSURLErrorDomain` codes that mean the request never got an answer.
    static let connectivityErrorCodes: Set<Int> = [
        NSURLErrorTimedOut,
        NSURLErrorCannotFindHost,
        NSURLErrorCannotConnectToHost,
        NSURLErrorNetworkConnectionLost,
        NSURLErrorDNSLookupFailed,
        NSURLErrorNotConnectedToInternet,
        NSURLErrorInternationalRoamingOff,
        NSURLErrorCallIsActive,
        NSURLErrorDataNotAllowed,
    ]

    /// Failures that say the media source stopped answering without saying
    /// why. A refused source (an HTTP status) is an answer, and decoder or
    /// pipeline failures are about the route.
    static let sourceFailureKinds: Set<PlaybackErrorKind> = [
        .vodSourceFailed,
        .nativeItemFailed,
        .sourceOpenFailed,
        .reloadFailed,
    ]

    private static func problem(in error: Error) -> APIv2Problem? {
        guard case APIv2Error.problem(let problem) = error else { return nil }
        return problem
    }

    private static func httpStatus(in error: Error) -> Int? {
        switch error {
        case APIv2Error.problem(let problem): return problem.status
        case APIv2Error.httpStatus(let status): return status
        case HTTPError.http(let status, _): return status
        case APIError.httpError(let status): return status
        default: return nil
        }
    }

    private static func isServerAnswer(_ error: Error) -> Bool {
        if httpStatus(in: error) != nil { return true }
        if error is PlaybackV3TerminalFailure { return true }
        if case APIv2Error.serverUpdateRequired = error { return true }
        return false
    }
}

/// What the player knows about the current transport's source: whether its
/// reader stopped delivering, and a seek target the stream has not played
/// from yet.
///
/// After a seek past the buffer over a dead source, Aether's clock runs on
/// without a frame and can end at a parked position. The seek target stays
/// the playhead until playback moves on from it while the source delivers,
/// or while the engine plays it from media buffered ahead of its clock.
struct PlaybackSourceWatch: Equatable {
    /// How far past a seek target playback has to move, with the source
    /// delivering or media buffered ahead, before the clock is trusted again.
    static let confirmationSeconds: Double = 2
    static let confirmationWindowSeconds: Double = 30

    /// The engine reports the source as stalled: its reader is retrying or
    /// gave up. A stalled phase outranks seeking, playing and paused, so any
    /// of those means the reader delivers again.
    private(set) var isStalled = false
    private(set) var unconfirmedSeekTarget: Double?

    mutating func observe(_ phase: PlaybackPhase) {
        switch phase {
        case .stalled:
            isStalled = true
        case .playing, .paused, .seeking, .rebuffering:
            isStalled = false
        case .idle, .loading, .ended, .error:
            break
        }
    }

    mutating func seekCommitted(to target: Double) {
        guard target.isFinite else { return }
        unconfirmedSeekTarget = max(0, target)
    }

    /// `hasMediaAhead` is whether the engine holds media ahead of its clock
    /// (`PlayerStallPresentation.hasMediaAhead`). Over a stalled source it
    /// tells a seek within the read-ahead buffer, which really plays, from a
    /// seek past it, where the clock runs on without a frame.
    mutating func observePlayhead(_ time: Double, hasMediaAhead: Bool = false) {
        guard let target = unconfirmedSeekTarget, !isStalled || hasMediaAhead, time.isFinite else { return }
        // Playback moves through this window tick by tick. A clock that
        // jumps past it in one step (to a parked end of media) did not play
        // from the target.
        let moved = time - target
        if moved >= Self.confirmationSeconds, moved <= Self.confirmationWindowSeconds {
            unconfirmedSeekTarget = nil
        }
    }

    /// The last position the stream played from.
    func playhead(currentTime: Double) -> Double {
        unconfirmedSeekTarget ?? currentTime
    }
}

/// One mid-stream reconnect cycle: its budget, the saved position and the
/// viewer's play intent. A value type with no clock or timers of its own so
/// the schedule can be tested; the player owns the timer and the requests.
struct PlaybackReconnectCycle: Equatable {
    /// What the player does next.
    enum Next: Equatable {
        /// Run the next attempt after this delay.
        case attempt(after: TimeInterval)
        /// The budget is spent: tell the viewer the connection was lost.
        case giveUp
    }

    private(set) var isActive = false
    /// Invalidates the timer and requests of a cycle that has ended.
    private(set) var generation: UInt64 = 0
    private(set) var attempts = 0
    private(set) var position: Double = 0
    /// Whether playback resumes once a plan is adopted.
    private(set) var resume = true
    private var recoveredAt: Date?
    /// Set from a plan's adoption until the new transport is installed. The
    /// cycle has ended, but a seek in that window still belongs to the
    /// handoff: the outgoing transport is dead, and the new one starts where
    /// the attempt asked.
    private(set) var handoff: Handoff?

    struct Handoff: Equatable {
        /// The position the attempt asked the server for.
        let requested: Double?
        /// Where the viewer wants to be.
        var position: Double
    }

    var isHandingOff: Bool { handoff != nil }

    /// Starts a cycle. Nil while one is already running: a second loss
    /// report joins it. `freshBudget` is the viewer's Try again, which starts
    /// over at once; otherwise a cycle that starts soon after the previous one
    /// recovered continues its budget.
    mutating func begin(position: Double, resume: Bool, freshBudget: Bool, now: Date) -> Next? {
        guard !isActive else { return nil }
        isActive = true
        generation &+= 1
        handoff = nil
        let recentlyRecovered = recoveredAt.map {
            now.timeIntervalSince($0) < PlaybackReconnectPolicy.stableInterval
        } ?? false
        if freshBudget || !recentlyRecovered {
            attempts = 0
        }
        self.position = position.isFinite ? max(0, position) : 0
        self.resume = resume
        if attempts >= PlaybackReconnectPolicy.maxAttempts {
            // The stream keeps dropping right after every recovery.
            end(recovered: false, now: now)
            return .giveUp
        }
        return .attempt(after: freshBudget ? 0 : PlaybackReconnectPolicy.delay(afterAttempts: attempts))
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        isActive && self.generation == generation
    }

    /// Counts the attempt about to be sent.
    mutating func beginAttempt() {
        attempts += 1
    }

    /// The attempt could not reach the server: wait, or give up once the
    /// budget is spent.
    mutating func retryLater(now: Date) -> Next {
        guard attempts < PlaybackReconnectPolicy.maxAttempts else {
            end(recovered: false, now: now)
            return .giveUp
        }
        return .attempt(after: PlaybackReconnectPolicy.delay(afterAttempts: attempts))
    }

    /// A seek while reconnecting, or while a plan is being handed over, is
    /// where the viewer wants to resume.
    mutating func updatePosition(_ position: Double) {
        guard isActive || handoff != nil, position.isFinite else { return }
        self.position = max(0, position)
        handoff?.position = self.position
    }

    /// How far the viewer may have moved from what an attempt asked for
    /// before the new transport has to seek.
    static let seekToleranceSeconds: Double = 0.5

    /// The server answered an attempt made at `requestedPosition` with a
    /// plan: ends the cycle as recovered and starts the handoff. Returns
    /// whether the new transport plays, or nil when no cycle was running.
    mutating func beginHandoff(requestedPosition: Double?, now: Date) -> Bool? {
        guard isActive else { return nil }
        end(recovered: true, now: now)
        handoff = Handoff(requested: requestedPosition, position: position)
        return resume
    }

    /// The new transport is installed (or never will be): ends the handoff.
    /// Returns where to seek the new transport when the viewer moved away
    /// from the position the attempt asked for, otherwise nil.
    mutating func finishHandoff() -> Double? {
        guard let handoff else { return nil }
        self.handoff = nil
        guard let requested = handoff.requested, requested.isFinite else { return handoff.position }
        return abs(handoff.position - requested) > Self.seekToleranceSeconds ? handoff.position : nil
    }

    /// Forgets the budget and the last recovery. Playing other content
    /// starts with a full budget; the stream that kept dropping was another
    /// item's. Only while no cycle runs.
    mutating func resetBudget() {
        guard !isActive else { return }
        attempts = 0
        recoveredAt = nil
    }

    /// Ends the cycle and any handoff. `recovered` records when a plan came
    /// back, so a stream that drops again right away continues this cycle's
    /// budget.
    mutating func end(recovered: Bool, now: Date) {
        handoff = nil
        guard isActive else { return }
        isActive = false
        generation &+= 1
        if recovered { recoveredAt = now }
    }
}
