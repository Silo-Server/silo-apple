import Foundation

/// Delivery bookkeeping for the room socket only. Deadlines use monotonic time;
/// the session's existing reporting loop services them without queuing old reports.
struct WatchPartyWorkRecovery {
    enum Kind: String, CaseIterable {
        case attach = "attach_session", ready, report = "state_report", buffering
        case transport = "transport_request", lobby = "lobby_ready"
        var isAction: Bool { self == .transport || self == .lobby }
    }

    struct Identity: Equatable {
        var engagement: UUID
        var connection: UUID
        var room: String
        var selection: Int64
        var generation: Int64
        var session: String?
        var command: String?
        var canControl: Bool
        var canSeek: Bool
        var phase: WatchPartyPhase

        /// Commit frames precede action_result and may advance generation.
        /// That permits acknowledgement, but never retry under a new generation.
        func canAcknowledge(_ other: Self) -> Bool {
            var copy = self
            copy.generation = other.generation
            copy.command = other.command
            return copy == other
        }
    }

    struct Pending {
        var message: WatchPartyClientMessage
        let identity: Identity
        let started: TimeInterval
        var retryAt: TimeInterval?
        var retried = false
    }

    enum Refusal {
        case ignored, desired(Kind), retryTransport, discardedTransport
    }

    private(set) var desired: [Kind: Pending] = [:]
    private(set) var transport: [String: Pending] = [:]
    private var recoveryFloor: TimeInterval = 0
    private var actionFloor: TimeInterval = 0
    private var recoveryOutages = 0
    private var actionOutages = 0
    private var opaqueFailures = 0
    private var shieldFailures = 0
    private var usefulSince: TimeInterval?
    private var lastUseful: TimeInterval?
    private(set) var hadRefusal = false

    func canSend(_ kind: Kind, at now: TimeInterval) -> Bool {
        now >= (kind.isAction ? actionFloor : recoveryFloor)
    }

    func remainingDelay(_ kind: Kind, at now: TimeInterval) -> TimeInterval {
        max(0, (kind.isAction ? actionFloor : recoveryFloor) - now)
    }

    mutating func track(_ message: WatchPartyClientMessage, identity: Identity, at now: TimeInterval) -> WatchPartyClientMessage {
        guard let kind = Kind(rawValue: message.type) else { return message }
        var message = message
        message.requestId = UUID().uuidString.lowercased()
        let pending = Pending(message: message, identity: identity, started: now)
        if kind == .transport { transport[message.requestId!] = pending }
        else { desired[kind] = pending }
        return message
    }

    mutating func refuse(_ error: WatchPartyWorkError, at now: TimeInterval, jitter: TimeInterval) -> Refusal {
        guard error.isPreWorkRefusal else { return .ignored }
        hadRefusal = true
        usefulSince = nil
        let unavailable = error.code == "realtime_unavailable"
        // Timing applies to the class even if an older periodic report's ID
        // has since been superseded. It never authorizes transport replay.
        let id = error.requestId
        let kind = desired.first(where: { $0.value.message.requestId == id && id != nil })?.key
        let isTransport = id.map { transport[$0] != nil } ?? false
        let delay = max(0.25, error.retryAfterMilliseconds.map { Double($0) / 1000 } ?? 2)
        let noise = min(0.25, max(0, jitter))
        let isAction = isTransport || kind?.isAction == true
        let outageIndex = isAction ? actionOutages : recoveryOutages
        let outageDelay = [2.0, 4, 8, 16, 30][min(outageIndex, 4)]
        let deadline = now + max(delay, unavailable ? outageDelay : 0) + noise
        if isAction { actionFloor = max(actionFloor, deadline); if unavailable { actionOutages += 1 } }
        else { recoveryFloor = max(recoveryFloor, deadline); if unavailable { recoveryOutages += 1 } }
        if kind == nil && !isTransport { actionFloor = max(actionFloor, deadline) }
        if let id, var pending = transport[id] {
            guard !pending.retried, deadline <= pending.started + 5 else {
                transport.removeValue(forKey: id)
                return .discardedTransport
            }
            pending.retryAt = deadline
            transport[id] = pending
            return .retryTransport
        }
        if let kind { desired.removeValue(forKey: kind); return .desired(kind) }
        return .ignored
    }

    mutating func applied(requestId: String?, action: String, identity: Identity, at now: TimeInterval) -> Bool {
        guard let requestId else { return false }
        if action == Kind.transport.rawValue, let pending = transport[requestId], pending.identity.canAcknowledge(identity) {
            transport.removeValue(forKey: requestId)
        } else if action == Kind.lobby.rawValue, let pending = desired[.lobby],
                  pending.message.requestId == requestId, pending.identity.canAcknowledge(identity) {
            desired.removeValue(forKey: .lobby)
        } else { return false }
        accepted(at: now)
        return true
    }

    @discardableResult
    mutating func echo(_ kind: Kind, identity: Identity, at now: TimeInterval) -> Bool {
        guard let pending = desired[kind], pending.identity.canAcknowledge(identity),
              pending.identity.command == identity.command else { return false }
        desired.removeValue(forKey: kind)
        accepted(at: now)
        return true
    }

    /// A downstream failure or a failed/uncertain send never grants a retry.
    mutating func failed(requestId: String?) -> Kind? {
        guard let requestId else { return nil }
        if transport.removeValue(forKey: requestId) != nil { return .transport }
        if let kind = desired.first(where: { $0.value.message.requestId == requestId })?.key {
            desired.removeValue(forKey: kind)
            return kind
        }
        return nil
    }

    /// Retries keep the original request ID and payload. Every authority axis
    /// must still match, including generation and command, within five seconds.
    mutating func takeTransportRetries(identity: Identity, at now: TimeInterval) -> (messages: [WatchPartyClientMessage], discarded: Bool) {
        var messages: [WatchPartyClientMessage] = []
        var discarded = false
        for (id, var pending) in transport {
            guard pending.retryAt != nil else { continue }
            if pending.identity != identity || now > pending.started + 5 {
                transport.removeValue(forKey: id)
                discarded = true
            } else if let deadline = pending.retryAt, now >= deadline, canSend(.transport, at: now) {
                pending.retryAt = nil
                pending.retried = true
                transport[id] = pending
                messages.append(pending.message)
            }
        }
        return (messages, discarded)
    }

    /// Identity validation can suspend between choosing and dispatching a retry.
    /// An intervening result, error, or refusal must still cancel that dispatch.
    func canDispatchTransportRetry(_ requestId: String?, identity: Identity, at now: TimeInterval) -> Bool {
        guard let requestId, let pending = transport[requestId] else { return false }
        return pending.retried && pending.retryAt == nil && pending.identity == identity
            && now <= pending.started + 5 && canSend(.transport, at: now)
    }

    mutating func expire(identity: Identity, at now: TimeInterval) -> Bool {
        var uncertain = false
        for (id, pending) in transport where !pending.identity.canAcknowledge(identity) || now >= pending.started + 5 {
            uncertain = true
            transport.removeValue(forKey: id)
        }
        for (kind, pending) in desired where pending.identity != identity {
            desired.removeValue(forKey: kind)
        }
        return uncertain
    }

    mutating func disconnected() -> Bool {
        let uncertain = !transport.isEmpty
        transport.removeAll()
        desired.removeAll()
        usefulSince = nil
        lastUseful = nil
        return uncertain
    }

    mutating func accepted(at now: TimeInterval) {
        if usefulSince == nil || lastUseful.map({ now - $0 > 5 }) == true { usefulSince = now }
        lastUseful = now
        if let usefulSince, now - usefulSince >= 30 {
            opaqueFailures = 0; shieldFailures = 0
            recoveryOutages = 0; actionOutages = 0
            hadRefusal = false
        }
    }

    mutating func reconnectDelay(shield: Bool, at now: TimeInterval) -> TimeInterval {
        // Merely opening a socket, pongs, and the age of an idle socket do
        // not prove useful admitted activity or replenish the backoff.
        if !shield, !hadRefusal, let usefulSince, let lastUseful,
           now - usefulSince >= 30, now - lastUseful <= 5 { return 0 }
        usefulSince = nil
        lastUseful = nil
        if shield {
            let delay = [5.0, 10, 20, 30][min(shieldFailures, 3)]
            shieldFailures += 1
            return delay
        }
        let delay = [1.0, 2, 4, 8, 16, 30][min(opaqueFailures, 5)]
        opaqueFailures += 1
        return delay
    }
}

/// One fixed input window for absolute seeks. Play/pause bypass this state.
struct WatchPartySeekWindow {
    private(set) var message: WatchPartyClientMessage?
    private(set) var identity: WatchPartyWorkRecovery.Identity?
    private(set) var deadline: TimeInterval?

    mutating func submit(_ message: WatchPartyClientMessage, identity: WatchPartyWorkRecovery.Identity, at now: TimeInterval) {
        if self.identity != identity { cancel() }
        self.message = message
        self.identity = identity
        if deadline == nil { deadline = now + 0.25 }
    }

    mutating func take(identity: WatchPartyWorkRecovery.Identity?, at now: TimeInterval) -> WatchPartyClientMessage? {
        guard self.identity == identity else { cancel(); return nil }
        guard let deadline, now >= deadline else { return nil }
        defer { cancel() }
        return message
    }

    mutating func cancel() { message = nil; identity = nil; deadline = nil }
}

struct WatchPartyWorkError: Equatable {
    var code: String
    var message: String
    var requestId: String?
    var retryAfterMilliseconds: Int?
    var workStarted: Bool?
    var isPreWorkRefusal: Bool {
        ["realtime_rate_limited", "realtime_unavailable"].contains(code) && workStarted == false
    }
}
