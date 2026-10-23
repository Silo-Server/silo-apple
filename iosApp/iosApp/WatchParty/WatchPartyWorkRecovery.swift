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
        enum Delivery { case dispatched, refused, selected }
        var message: WatchPartyClientMessage
        let identity: Identity
        let started: TimeInterval
        let sequence: UInt64
        let inputID: UUID?
        var retryAt: TimeInterval?
        var retried = false
        var allowsAutomaticRetry = true
        var delivery: Delivery = .dispatched
    }

    enum Refusal {
        case ignored, desired(Kind), retryTransport, discardedTransport
    }

    private(set) var desired: [Kind: Pending] = [:]
    private(set) var transport: [String: Pending] = [:]
    private var nextSequence: UInt64 = 0
    private(set) var discardedUnsentTransport = false
    private var recoveryFloor: TimeInterval = 0
    private var actionFloor: TimeInterval = 0
    private var recoveryOutages = 0
    private var actionOutages = 0
    private var opaqueFailures = 0
    private var shieldFailures = 0
    private var usefulSince: TimeInterval?
    private(set) var hadRefusal = false

    func canSend(_ kind: Kind, at now: TimeInterval) -> Bool {
        now >= (kind.isAction ? actionFloor : recoveryFloor)
    }

    func remainingDelay(_ kind: Kind, at now: TimeInterval) -> TimeInterval {
        max(0, (kind.isAction ? actionFloor : recoveryFloor) - now)
    }

    mutating func track(_ message: WatchPartyClientMessage, identity: Identity, at now: TimeInterval,
                        inputID: UUID? = nil, allowsAutomaticRetry: Bool = true) -> WatchPartyClientMessage {
        guard let kind = Kind(rawValue: message.type) else { return message }
        var message = message
        message.requestId = UUID().uuidString.lowercased()
        nextSequence += 1
        let pending = Pending(message: message, identity: identity, started: now, sequence: nextSequence,
                              inputID: inputID, allowsAutomaticRetry: allowsAutomaticRetry)
        if kind == .transport { transport[message.requestId!] = pending }
        else { desired[kind] = pending }
        return message
    }

    mutating func refuse(_ error: WatchPartyWorkError, at now: TimeInterval, jitter: TimeInterval) -> Refusal {
        guard error.isPreWorkRefusal else { return .ignored }
        resetBackoffAfterHealthyLifetime(at: now)
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
            guard pending.allowsAutomaticRetry, !pending.retried, pending.delivery != .selected, deadline <= pending.started + 5 else {
                transport.removeValue(forKey: id)
                return .discardedTransport
            }
            pending.retryAt = deadline
            pending.delivery = .refused
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
        for (id, var pending) in transport.sorted(by: { $0.value.sequence < $1.value.sequence }) {
            guard pending.retryAt != nil else { continue }
            if pending.identity != identity || now >= pending.started + 5 {
                transport.removeValue(forKey: id)
                discarded = true
            } else if let deadline = pending.retryAt, now >= deadline, canSend(.transport, at: now) {
                pending.retryAt = nil
                pending.delivery = .selected
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
        return !pending.retried && pending.retryAt == nil && pending.identity == identity
            && pending.delivery == .selected && now < pending.started + 5 && canSend(.transport, at: now)
    }

    /// Selection is still known unsent. Cross this boundary only after the
    /// caller's final suspension and authority checks, immediately before send.
    mutating func beginTransportRetry(_ requestId: String?, identity: Identity, at now: TimeInterval) -> Bool {
        guard let requestId, var pending = transport[requestId], pending.delivery == .selected,
              pending.identity == identity, !pending.retried, now < pending.started + 5 else { return false }
        guard canSend(.transport, at: now) else {
            // A different refusal may advance the floor while validation is
            // suspended. Selection did not consume the one permitted retry.
            pending.retryAt = actionFloor
            pending.delivery = .refused
            transport[requestId] = pending
            return false
        }
        pending.retried = true
        pending.delivery = .dispatched
        transport[requestId] = pending
        return true
    }

    /// New explicit input supersedes known-unsent retries synchronously.
    /// Dispatched work retains result/uncertainty tracking, but a later refusal
    /// cannot restore its retry permission after newer explicit user input.
    mutating func supersedeTransportRetries() -> Bool {
        var discarded = false
        for (id, var pending) in transport {
            if pending.delivery != .dispatched {
                transport.removeValue(forKey: id)
                discarded = true
            } else {
                pending.allowsAutomaticRetry = false
                transport[id] = pending
            }
        }
        return discarded
    }

    mutating func expire(identity: Identity, at now: TimeInterval) -> Bool {
        var uncertain = false
        discardedUnsentTransport = false
        for (id, pending) in transport {
            let current = pending.delivery == .dispatched ? pending.identity.canAcknowledge(identity) : pending.identity == identity
            guard !current || now >= pending.started + 5 else { continue }
            if pending.delivery == .dispatched { uncertain = true }
            else { discardedUnsentTransport = true }
            transport.removeValue(forKey: id)
        }
        for (kind, pending) in desired where pending.identity != identity {
            desired.removeValue(forKey: kind)
        }
        return uncertain
    }

    mutating func disconnected() -> Bool {
        let uncertain = transport.values.contains { $0.delivery == .dispatched }
        discardedUnsentTransport = transport.values.contains { $0.delivery != .dispatched }
        transport.removeAll()
        desired.removeAll()
        usefulSince = nil
        return uncertain
    }

    mutating func accepted(at now: TimeInterval) {
        // A valid initial snapshot or operation echo establishes useful work.
        // Its healthy lifetime can mature without a second unsolicited frame.
        if usefulSince == nil { usefulSince = now }
        resetBackoffAfterHealthyLifetime(at: now)
    }

    private mutating func resetBackoffAfterHealthyLifetime(at now: TimeInterval) {
        if let usefulSince, now - usefulSince >= 30 {
            opaqueFailures = 0; shieldFailures = 0
            recoveryOutages = 0; actionOutages = 0
            hadRefusal = false
        }
    }

    mutating func reconnectDelay(shield: Bool, at now: TimeInterval) -> TimeInterval {
        // Open/pongs alone do not establish useful work. A refusal interrupts
        // the lifetime; another accepted snapshot/operation must start it again.
        resetBackoffAfterHealthyLifetime(at: now)
        let healthy = usefulSince.map { now - $0 >= 30 } == true
        usefulSince = nil
        if !shield, !hadRefusal, healthy { return 0 }
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

/// One fixed input window for absolute seeks. The session orders following
/// play/pause controls after this window without merging their intents.
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
