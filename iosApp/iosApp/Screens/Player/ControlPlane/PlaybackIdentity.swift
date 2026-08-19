import Foundation

/// Identity of one engine load.
///
/// Stage 2 replaces the three by-value generation counters the view model
/// captured into its callbacks (`streamLoadGeneration`, `freshLoadGeneration`,
/// `serverOutageRecoveryGeneration`) and the backend's `loopbackGeneration` /
/// `activeLoopbackSessionID` string compare with one minted value that travels
/// on every effect and every event. A mutation is applied only when the
/// carried `LoadID` still equals the current one, so a late callback from a
/// superseded load is dropped structurally instead of by comparing numbers
/// captured when the closure was created.
///
/// A new `LoadID` is minted for **every** engine load — including an in-place
/// server replan that deliberately keeps the live `AVPlayerBackend` instance
/// (design §4 I4): the engine survives, its callback binding does not.
struct LoadID: Hashable, Sendable {
    let raw: UUID

    init() {
        self.raw = UUID()
    }

    /// Replays a known id (tests, and the wave-3 actor binding an event stream
    /// to the load it was created for).
    init(raw: UUID) {
        self.raw = raw
    }
}

/// Identity of the server-side playback session a load is bound to.
///
/// Produced by `PlaybackSessionBridge` (wave 1D widens `currentSessionId` into
/// this type) and carried by every session-scoped effect and event, replacing
/// the five view-model mirrors/echoes of the bridge's session id
/// (`activePlaybackSessionId`, `staleSessionRecoverySessionId`,
/// `backgroundRenewalSessionId`, `activeServerOutageRecoverySessionId`, and the
/// replan attempt snapshot).
struct SessionIdentity: Equatable, Sendable {
    /// `PlaybackSessionBridge.sessionId`. `nil` for an offline load, which has
    /// no server session at all.
    let serverSessionId: String?
    /// `ActiveProtocolV3.playbackAttemptId` — `"apple:<uuid>"` online,
    /// `"offline:<uuid>"` for a local download.
    let playbackAttemptId: String
    /// `ActiveProtocolV3.planAttemptId` — `"apple-plan:<uuid>"`.
    let planAttemptId: String?
    /// The server's `plan_attempt_key` for the adopted plan.
    let planAttemptKey: String?
    /// `ApplePlaybackV3CapabilitySnapshot.outputContextId` the plan was
    /// negotiated for. Empty for an offline load (no capability negotiation).
    let outputContextId: String

    init(
        serverSessionId: String?,
        playbackAttemptId: String,
        planAttemptId: String?,
        planAttemptKey: String?,
        outputContextId: String
    ) {
        self.serverSessionId = serverSessionId
        self.playbackAttemptId = playbackAttemptId
        self.planAttemptId = planAttemptId
        self.planAttemptKey = planAttemptKey
        self.outputContextId = outputContextId
    }

    /// True when both identities name the same server session and playback
    /// attempt.
    ///
    /// A server replan keeps `serverSessionId` and `playbackAttemptId` and
    /// mints a new `planAttemptId`/`planAttemptKey` — the bridge's
    /// `ProtocolV3AttemptIdentity` comparison is over the plan attempt, which
    /// is exactly what must *not* match a replan response to the session that
    /// asked for it. This is the session-level comparison.
    func belongsToSameSession(as other: SessionIdentity) -> Bool {
        serverSessionId == other.serverSessionId
            && playbackAttemptId == other.playbackAttemptId
    }

    /// Identity for a load prepared by `OfflinePlaybackBuilder`: no server
    /// session, no plan attempt, no negotiated output context — but still a
    /// stable value, so offline loads travel the same effect/event path.
    static func offline() -> SessionIdentity {
        SessionIdentity(
            serverSessionId: nil,
            playbackAttemptId: "offline:\(UUID().uuidString)",
            planAttemptId: nil,
            planAttemptKey: nil,
            outputContextId: ""
        )
    }
}
