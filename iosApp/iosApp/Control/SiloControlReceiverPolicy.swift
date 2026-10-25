import Foundation

/// Pure decisions for a receiver that serves several controllers at once.
/// Kept outside the tvOS conditional so the rules can be regression-tested
/// from the iOS test bundle; `TVControlReceiver` applies them.
enum SiloControlReceiverPolicy {
    /// Most controllers one TV keeps connected.
    static let maxControllers = 8

    /// What the admission rules need to know about a connected controller.
    struct ControllerSummary: Equatable {
        let id: UUID
        /// Order of acceptance; lower is older.
        let sequence: Int
        let didReceiveHello: Bool
        let passive: Bool
        var isAuthorized = true
        var isHandingOff = false
    }

    enum Admission: Equatable {
        case admit
        /// Admit after closing this controller to make room.
        case admitEvicting(UUID)
        case refuse
    }

    /// Whether a new connection fits. At the cap, a connection that never
    /// said hello goes first (likely half-open or a port scan), then a
    /// cross-server controller that isn't handing off (it can do nothing
    /// else, and nothing else times it out), then the oldest passive
    /// controller. A controller mid-handoff and an active one are never
    /// evicted by a stranger; the newcomer is refused instead.
    static func admission(existing: [ControllerSummary]) -> Admission {
        guard existing.count >= maxControllers else { return .admit }
        let byAge = existing.sorted { $0.sequence < $1.sequence }
        if let silent = byAge.first(where: { !$0.didReceiveHello }) {
            return .admitEvicting(silent.id)
        }
        if let idle = byAge.first(where: { !$0.isAuthorized && !$0.isHandingOff }) {
            return .admitEvicting(idle.id)
        }
        if let passive = byAge.first(where: { $0.passive && !$0.isHandingOff }) {
            return .admitEvicting(passive.id)
        }
        return .refuse
    }

    /// Other connections from the device that just said hello on
    /// `connection`. They are older sockets the device has abandoned (a
    /// Wi-Fi change, a return from background) whose heartbeat hasn't
    /// noticed yet, so the newest connection replaces them.
    static func connectionsReplaced(
        byHelloFrom deviceId: String,
        on connection: UUID,
        existing: [(id: UUID, deviceId: String?)]
    ) -> [UUID] {
        guard !deviceId.isEmpty else { return [] }
        return existing
            .filter { $0.id != connection && $0.deviceId == deviceId }
            .map(\.id)
    }

    /// A v2 launch plays under the temporary identity, so it is allowed only
    /// for the controller whose handoff produced the identity now active.
    /// Another controller's later handoff replaces the identity and with it
    /// every earlier controller's readiness.
    static func canLaunch(readyGeneration: UUID?, activeGeneration: UUID?) -> Bool {
        guard let readyGeneration, let activeGeneration else { return false }
        return readyGeneration == activeGeneration
    }

    /// Keep the presented player when a phone replaces a title under the
    /// same handoff. Rebuilding its view would run the outgoing player's
    /// identity teardown while the replacement is starting.
    static func canReplaceInPlayer(
        playerGeneration: UUID?, activeGeneration: UUID?,
        playerIsDisposed: Bool, playerIsWatchParty: Bool
    ) -> Bool {
        !playerIsDisposed && !playerIsWatchParty
            && canLaunch(readyGeneration: playerGeneration, activeGeneration: activeGeneration)
    }

    /// Whether an offer that matches the active identity (same server,
    /// profile and device ID) may reuse it without a new approval. Device IDs
    /// are self-reported, so the match alone proves nothing: reuse needs the
    /// connection that completed the handoff, or the resume token issued to
    /// it.
    static func mayReuseIdentity(
        offerMatchesIdentity: Bool,
        identityConnection: UUID?,
        connection: UUID,
        issuedResumeToken: String?,
        offeredResumeToken: String?
    ) -> Bool {
        guard offerMatchesIdentity else { return false }
        if identityConnection == connection { return true }
        guard let issuedResumeToken, let offeredResumeToken else { return false }
        return constantTimeEquals(issuedResumeToken, offeredResumeToken)
    }

    /// Whether a handoff must stop and ask before replacing what the TV is
    /// showing. Only a title playing under another profile needs consent.
    /// Controllers without `replace_confirmation` can't ask, so they keep
    /// the older newest-launch-wins behavior.
    static func needsReplaceConfirmation(
        titleOnScreen: Bool,
        playingUnderOfferedProfile: Bool,
        replaceConfirmed: Bool,
        controllerCanConfirm: Bool
    ) -> Bool {
        titleOnScreen && !playingUnderOfferedProfile && !replaceConfirmed && controllerCanConfirm
    }

    /// A confirmation covers only the title the user agreed to replace. If
    /// another one started while they decided, the TV asks again.
    static func confirmationCovers(
        onScreenContentId: String?,
        replaceConfirmed: Bool,
        replacingContentId: String?
    ) -> Bool {
        replaceConfirmed && replacingContentId == onScreenContentId
    }

    static func makeResumeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4)
            .map { _ in String(format: "%016llx", generator.next() as UInt64) }
            .joined()
    }

    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs.utf8), b = Array(rhs.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }

    /// Per-controller command budget: a token bucket, so a stuck
    /// integration loop can't wedge the player while bursts of hardware
    /// volume steps still go through.
    struct CommandBudget {
        static let perSecond: Double = 20
        static let burst: Double = 40

        private var tokens = burst
        private var refilledAt: Date?

        mutating func allow(at now: Date = Date()) -> Bool {
            if let refilledAt {
                let elapsed = max(0, now.timeIntervalSince(refilledAt))
                tokens = min(Self.burst, tokens + elapsed * Self.perSecond)
            }
            refilledAt = now
            guard tokens >= 1 else { return false }
            tokens -= 1
            return true
        }
    }
}
