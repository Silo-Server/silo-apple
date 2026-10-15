import Foundation

/// HTTP generations omit runtime readiness and attachment changes. A same-generation
/// HTTP response cannot replace a socket snapshot received after that request began.
struct WatchPartyRoomState {
    private(set) var room: WatchPartyRoom?
    private(set) var receipt: UInt64 = 0
    private(set) var terminal = false

    mutating func accept(_ incoming: WatchPartyRoom, requestReceipt: UInt64? = nil) -> Bool {
        guard !terminal else { return false }
        if let room {
            guard room.roomId == incoming.roomId, incoming.generation >= room.generation,
                  incoming.selectionRevision >= room.selectionRevision else { return false }
            if let requestReceipt, incoming.generation == room.generation, receipt > requestReceipt { return false }
        }
        room = incoming
        receipt &+= 1
        terminal = incoming.phase == .ended
        return true
    }

    mutating func end() { terminal = true }
}

struct WatchPartyCommandState {
    private(set) var pending: WatchPartyTransportCommand?
    private(set) var completed: WatchPartyTransportCommand?
    private var newestIssuedAt: Date = .distantPast
    private var seen: [String] = []

    mutating func receive(_ command: WatchPartyTransportCommand, room: WatchPartyRoom, sessionId: String?) -> Bool {
        guard room.phase == .playing, command.selectionRevision == room.selectionRevision,
              command.sessionId == nil || command.sessionId == sessionId,
              !command.commandId.isEmpty, !seen.contains(command.commandId),
              command.positionSeconds.isFinite, command.positionSeconds >= 0,
              command.issuedAt >= newestIssuedAt,
              [.play, .pause, .seek].contains(command.action),
              [.waiting, .paused, .playing].contains(command.playbackState) else { return false }
        newestIssuedAt = command.issuedAt
        seen.append(command.commandId)
        if seen.count > 64 { seen.removeFirst() }
        pending = command
        return true
    }

    mutating func complete(_ id: String) {
        guard pending?.commandId == id else { return }
        completed = pending
        pending = nil
    }

    /// How long after a command finished before the drift loop measures
    /// again; the player's clock settles after a play or seek.
    static let nudgeSettle: TimeInterval = 1

    /// A playhead that moved less than `heldClockAdvance` over at least
    /// `heldClockInterval` is held, not playing.
    static let heldClockInterval: TimeInterval = 0.4
    static let heldClockAdvance: Double = 0.1

    /// What the session's drift loop does on a report tick.
    enum LoopStep: Equatable {
        /// The room or this member is not playing, so the member runs at 1x.
        case reset
        /// A command just ran; the rate stays until playback settles.
        case wait
        /// Close this drift (room position minus local position) by rate.
        case nudge(Double)
    }

    /// The last command this member ran is the room's position at its execute
    /// time, advancing at 1x while the room plays.
    /// `playheadAdvancing` is false when the player claims to play but its
    /// position has not moved since the last tick: Aether's software path
    /// holds its clock to rebuffer without reporting it, and a rate written
    /// then restarts that clock. The loop waits it out.
    static func loopStep(reference: WatchPartyTransportCommand?, room: WatchPartyRoom, memberPlaying: Bool,
                         sourceTime: Double, serverNow: Date, sinceCompleted: TimeInterval,
                         playheadAdvancing: Bool = true) -> LoopStep {
        guard let reference, reference.playbackState == .playing,
              reference.selectionRevision == room.selectionRevision,
              room.phase == .playing, room.playbackState == .playing, !room.isPaused, memberPlaying else { return .reset }
        guard sinceCompleted >= nudgeSettle, playheadAdvancing else { return .wait }
        return .nudge(projectedPosition(reference, serverNow: serverNow) - sourceTime)
    }

    /// What a command does to this member's position when it executes.
    enum PositionStep: Equatable {
        /// The room's explicit seek: a barrier everyone lands on exactly.
        case roomSeek
        /// A playing member staying in a playing room: rate, or a large seek.
        case correct
        /// A stopped member moves before it plays or pauses there.
        case realign
        case none
    }

    /// `seekBand` is `WatchPartyCorrection.seekBand(isHost:)` for this member.
    static func positionStep(_ command: WatchPartyTransportCommand, memberPlaying: Bool,
                             drift: Double, reachableInPlace: Bool,
                             seekBand: Double) -> PositionStep {
        if command.action == .seek { return .roomSeek }
        if command.playbackState == .playing, memberPlaying { return .correct }
        return WatchPartyCorrection.seeksWhileStopped(drift: drift, reachableInPlace: reachableInPlace,
                                                      band: seekBand) ? .realign : .none
    }

    /// The room's position at `serverNow`: a command carries the room's
    /// position at its execute time, and a playing room advances at 1x.
    static func projectedPosition(_ command: WatchPartyTransportCommand, serverNow: Date) -> Double {
        command.positionSeconds + (command.playbackState == .playing ? max(0, serverNow.timeIntervalSince(command.executeAt)) : 0)
    }

    /// How far from a waiting seek's target a guest still acknowledges it.
    /// The server applies the tolerance that fits the seek: 1s for the room's
    /// own seek, 5s for the seek it sends a stalled guest, whose rebuilt stream
    /// often lands short and then closes the rest by rate. This client cannot
    /// tell the two apart and has no pre-roll, so it reports and lets the
    /// server decide.
    static let guestSeekAcknowledgeTolerance: Double = 5
    static let hostSeekAcknowledgeTolerance: Double = 15

    /// Waiting seeks require a landed destination; a buffering pause only
    /// requires the applied command and actual media readiness.
    static func canAcknowledge(_ completed: WatchPartyTransportCommand?, roomPlaybackState: WatchPartyPlaybackState,
                               sourceTime: Double, isHost: Bool) -> Bool {
        guard let completed, sourceTime.isFinite, sourceTime >= 0 else { return false }
        guard roomPlaybackState == .waiting, completed.action == .seek else { return true }
        let tolerance = isHost ? hostSeekAcknowledgeTolerance : guestSeekAcknowledgeTolerance
        return abs(sourceTime - completed.positionSeconds) <= tolerance
    }

    /// The room waits for this member's `ready` only at a barrier, or while the
    /// member catches up after the room resumed without it. The server answers
    /// a `ready` in a playing room with a fresh sync command, which is another
    /// seek; a late joiner is marked ready by its first report that matches the
    /// room instead. Mirrors the web client's readiness gate.
    static func awaitsReadiness(_ room: WatchPartyRoom) -> Bool {
        let member = room.members.first(where: \.isSelf)
        guard member?.isReady != true else { return false }
        if room.playbackState == .waiting { return true }
        return room.phase == .playing && (room.playbackState == .playing || room.playbackState == .paused)
            && (room.selfIgnoreWait || member?.isBuffering == true)
    }
}

/// The offset from this device's clock to the server's, from ping/pong
/// samples. A sample's error is at most half its round trip, so the offset in
/// use is the one from the fastest recent round trip, not the latest: one slow
/// pong would otherwise move every command's local execute time.
struct WatchPartyClock {
    static let sampleLimit = 8
    static let maxRoundTrip: TimeInterval = 5
    /// Pings this fast until a connection has this many samples, then slowly.
    static let warmupSamples = 4
    static let warmupInterval: TimeInterval = 2
    static let interval: TimeInterval = 15

    private(set) var samples: [(roundTrip: TimeInterval, offset: TimeInterval)] = []

    /// Server time minus local time, or 0 before any sample.
    var offset: TimeInterval { fastest?.offset ?? 0 }

    /// The fastest sample, the newest on a tie.
    private var fastest: (roundTrip: TimeInterval, offset: TimeInterval)? {
        samples.reversed().min(by: { $0.roundTrip < $1.roundTrip })
    }

    /// Millisecond timestamps can make a LAN round trip read slightly negative.
    static let roundingSlack: TimeInterval = 0.002
    /// Beyond their round-trip error bounds, two offsets disagree by this much
    /// only when this device's clock moved between them.
    static let stepMargin: TimeInterval = 0.05

    /// Records a sample and returns whether it was usable.
    @discardableResult
    mutating func record(clientSent: Date, serverReceived: Date, serverSent: Date, clientReceived: Date) -> Bool {
        var roundTrip = clientReceived.timeIntervalSince(clientSent) - serverSent.timeIntervalSince(serverReceived)
        if roundTrip < 0, roundTrip >= -Self.roundingSlack { roundTrip = 0 }
        guard roundTrip.isFinite, roundTrip >= 0, roundTrip <= Self.maxRoundTrip else { return false }
        let offset = (serverReceived.timeIntervalSince(clientSent) + serverSent.timeIntervalSince(clientReceived)) / 2
        // Each offset is within half its round trip of the truth. When the new
        // one cannot agree with the best kept one, the device clock stepped
        // (a time sync, or waking from sleep) and the old samples are stale.
        if let best = fastest,
           abs(offset - best.offset) > (roundTrip + best.roundTrip) / 2 + Self.stepMargin {
            samples.removeAll()
        }
        samples.append((roundTrip: roundTrip, offset: offset))
        if samples.count > Self.sampleLimit { samples.removeFirst() }
        return true
    }
}

/// Times a member's stall for the room's `buffering` report. Stalls shorter
/// than the grace stay local, as on the web client: the room pauses only for a
/// stall that outlasts the catch-up band, and the short rebuffer after a
/// correction seek is not a stall. See the server's Watch Party buffering
/// policy.
struct WatchPartyStallTimer {
    static let grace: TimeInterval = 2

    private(set) var began: Date?
    private(set) var reported = false

    /// A seek or room command is in progress, so this tick cannot report. A
    /// stall timed before it is not the stall that follows it, so the grace
    /// restarts once it settles. A stall already reported stays reported
    /// while media is still stalled; media that recovered ends it, so the
    /// next stall is reported too.
    mutating func interrupt(buffering: Bool) {
        if buffering { began = nil } else { reset() }
    }

    /// Returns true once per stall, when it has lasted the grace period.
    mutating func observe(buffering: Bool, at now: Date) -> Bool {
        guard buffering else {
            reset()
            return false
        }
        let began = self.began ?? now
        self.began = began
        guard !reported, now.timeIntervalSince(began) >= Self.grace else { return false }
        reported = true
        return true
    }

    mutating func reset() {
        began = nil
        reported = false
    }
}

/// Only HTTP determines personal votes; every socket path carries common rows.
struct WatchPartyVotes {
    private(set) var rows: [WatchPartySuggestion] = []
    private(set) var personal: [String: Bool] = [:]
    private(set) var revision: UInt64 = 0

    mutating func receive(_ suggestions: [WatchPartySuggestion]) {
        rows = suggestions.map { suggestion in
            var row = suggestion
            row.votedByMe = personal[row.id] ?? false
            return row
        }
        revision &+= 1
    }

    mutating func reconcile(_ suggestions: [WatchPartySuggestion], requestedAt: UInt64) -> Bool {
        guard revision == requestedAt else { return false }
        personal = Dictionary(suggestions.map { ($0.id, $0.votedByMe) }, uniquingKeysWith: { _, newer in newer })
        rows = suggestions
        return true
    }

    mutating func invalidatePersonalReads() { revision &+= 1 }
}
