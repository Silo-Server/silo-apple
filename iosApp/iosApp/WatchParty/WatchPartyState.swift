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

    static func projectedPosition(_ command: WatchPartyTransportCommand, serverNow: Date) -> Double {
        command.positionSeconds + (command.playbackState == .playing ? max(0, serverNow.timeIntervalSince(command.executeAt)) : 0)
    }

    /// Waiting seeks require a landed destination; a buffering pause only
    /// requires the applied command and actual media readiness.
    static func canAcknowledge(_ completed: WatchPartyTransportCommand?, roomPlaybackState: WatchPartyPlaybackState,
                               sourceTime: Double, isHost: Bool) -> Bool {
        guard let completed, sourceTime.isFinite, sourceTime >= 0 else { return false }
        guard roomPlaybackState == .waiting, completed.action == .seek else { return true }
        return abs(sourceTime - completed.positionSeconds) <= (isHost ? 15 : 1)
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
