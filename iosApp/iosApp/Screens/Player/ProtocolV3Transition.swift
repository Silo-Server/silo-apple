import Foundation

/// The Protocol V3 attempt the bridge is currently executing.
struct ActiveProtocolV3 {
    let playbackAttemptId: String
    var planAttemptId: String
    var planAttemptKey: String
    var attemptedPlanKeys: [String]
    var attemptCount: Int
    var clientQualityId: String
    /// True after the user selects an exact quality identifier advertised
    /// by the active plan. Recovery replans must keep that identifier
    /// instead of translating it through the local Settings ladder.
    var usesServerQualityPreference: Bool
    /// The independent bandwidth ceiling captured for this attempt. Every
    /// replan must repeat it or recovery silently widens the connection.
    var bandwidthCapKbps: Int?
    var snapshot: ApplePlaybackV3CapabilitySnapshot
    var serverFeatures: [String]
    /// Attempt-sticky: the server silently restores the negotiated origin
    /// state on a replan, so every replan repeats what the start request
    /// negotiated. Changing it means a new attempt, not a replan.
    let negotiatedAuthorizedMediaOrigins: Bool
    var plan: PlaybackV3Plan
}

struct ProtocolV3AttemptIdentity: Equatable {
    let playbackAttemptId: String
    let planAttemptId: String
    let planAttemptKey: String

    init(_ active: ActiveProtocolV3) {
        playbackAttemptId = active.playbackAttemptId
        planAttemptId = active.planAttemptId
        planAttemptKey = active.planAttemptKey
    }
}

/// A validated start response that has not been adopted yet.
struct StagedProtocolV3Start {
    let playbackAttemptId: String
    let clientQualityId: String
    let bandwidthCapKbps: Int?
    let snapshot: ApplePlaybackV3CapabilitySnapshot
    let serverFeatures: [String]
    let negotiatedAuthorizedMediaOrigins: Bool
    let plan: PlaybackV3Plan
    let sessionId: String
    let selectedVersion: FileVersion
    let session: PlaybackSessionResponse
}

/// The bridge's Protocol V3 session state and its two-phase route transition.
///
/// A server decision is only provisional until the owning player proves that
/// Aether accepted the corresponding source. Keeping the prior state here
/// prevents a cancelled/failed load from publishing a session and plan that
/// never became executable. A successful commit also retires the replaced
/// server session exactly once.
///
/// This is a pure value type: every mutation returns the side effects the
/// bridge must perform — which session to retire, which route event to emit —
/// rather than performing them itself.
struct ProtocolV3Transition {
    /// Work the bridge owes the server after a state mutation.
    struct Outcome {
        var retireSessionId: String?
        var commitEvent: CommitEvent?

        static let none = Outcome()
    }

    /// A route event that becomes due only once a candidate commits, named
    /// against the immutable attempt identity that was current at commit time.
    struct CommitEvent {
        let active: ActiveProtocolV3
        let sessionId: String
        let event: String
        let diagnostics: [String: String]
    }

    private struct Pending {
        let priorSessionId: String?
        let priorSession: PlaybackSessionResponse?
        let priorActive: ActiveProtocolV3?
        let candidateSessionId: String
        let candidatePlanId: String
        let commitEvent: String?
        let commitDiagnostics: [String: String]
    }

    private(set) var sessionId: String?
    private(set) var session: PlaybackSessionResponse?
    private(set) var active: ActiveProtocolV3?
    private var pending: Pending?

    // MARK: - Adoption

    mutating func adopt(active: ActiveProtocolV3, session: PlaybackSessionResponse) {
        self.active = active
        self.session = session
        sessionId = session.sessionId
    }

    /// Drops all session-scoped state and reports what the caller still has to
    /// retire: the attempt being stopped and any session a staged transition
    /// had superseded but not yet retired.
    mutating func clear() -> (active: ActiveProtocolV3?, supersededSessionId: String?) {
        let stopping = active
        let superseded = pending?.priorSessionId
        sessionId = nil
        session = nil
        active = nil
        pending = nil
        return (stopping, superseded)
    }

    // MARK: - Two-phase transition

    /// Records a server-issued candidate plan as pending until Aether commits
    /// the matching load epoch, preserving the last committed state for rollback.
    mutating func stage(
        candidateSessionId: String,
        candidatePlanId: String,
        commitEvent: String? = nil,
        commitDiagnostics: [String: String] = [:]
    ) -> Outcome {
        // A newer load superseding an uncommitted candidate restores the last
        // committed bridge state and retires the abandoned allocation first.
        // A replan issued against that uncommitted candidate reuses its
        // session id, so the "abandoned" allocation is the one about to be
        // staged again; retiring it would DELETE the session the engine is
        // about to read from and strand playback in 404 backoff.
        let outcome = rollbackPending(retainingSessionId: candidateSessionId)
        pending = Pending(
            priorSessionId: sessionId,
            priorSession: session,
            priorActive: active,
            candidateSessionId: candidateSessionId,
            candidatePlanId: candidatePlanId,
            commitEvent: commitEvent,
            commitDiagnostics: commitDiagnostics
        )
        return outcome
    }

    /// Commits the server decision only after Aether's load epoch commits.
    /// Returns nil when a newer transition or teardown already won.
    mutating func commit(_ prepared: PreparedPlayback) -> Outcome? {
        guard let pending = adoptedPending(matching: prepared) else { return nil }
        self.pending = nil
        var outcome = Outcome(retireSessionId: Self.supersededSessionId(pending))
        if let event = pending.commitEvent, let active {
            outcome.commitEvent = CommitEvent(
                active: active,
                sessionId: pending.candidateSessionId,
                event: event,
                diagnostics: pending.commitDiagnostics
            )
        }
        return outcome
    }

    /// Promotes a candidate that Aether could not open solely so the client
    /// can report that exact failed attempt and request the next server route.
    /// This is not an execution commit: it emits no success event, binds no
    /// realtime channel, and cannot report first frame. The failed candidate
    /// nevertheless becomes the current server attempt because a V3 replan
    /// must echo the identity of the plan that actually failed.
    mutating func promoteForRecovery(_ prepared: PreparedPlayback) -> Outcome? {
        guard let pending = adoptedPending(matching: prepared) else { return nil }
        self.pending = nil
        return Outcome(retireSessionId: Self.supersededSessionId(pending))
    }

    /// Restores the last committed state after an invalid URL, cancellation, or
    /// Aether load failure and retires a distinct candidate session.
    /// Same-session replans restore client state; the server keeps its own
    /// immutable attempt history for the next bounded replan.
    mutating func rollback(_ prepared: PreparedPlayback) -> Outcome {
        guard stagedPending(matching: prepared) != nil else { return .none }
        return rollbackPending()
    }

    /// `retainingSessionId` names a session the caller is about to stage again;
    /// it is left alive on the server instead of being retired as abandoned.
    private mutating func rollbackPending(retainingSessionId: String? = nil) -> Outcome {
        guard let pending else { return .none }
        self.pending = nil
        sessionId = pending.priorSessionId
        session = pending.priorSession
        active = pending.priorActive
        guard Self.shouldRetireRolledBackCandidate(
            candidateSessionId: pending.candidateSessionId,
            priorSessionId: pending.priorSessionId,
            retainingSessionId: retainingSessionId
        ) else { return .none }
        return Outcome(retireSessionId: pending.candidateSessionId)
    }

    /// A rolled-back candidate is retired only when nothing else still owns
    /// it: not the committed prior session it replaced, and not a transition
    /// that is about to stage the same session id again (a replan against an
    /// uncommitted start reuses the start's session).
    static func shouldRetireRolledBackCandidate(
        candidateSessionId: String,
        priorSessionId: String?,
        retainingSessionId: String?
    ) -> Bool {
        candidateSessionId != priorSessionId && candidateSessionId != retainingSessionId
    }

    // MARK: - Queries

    /// Returns the committed wire session only when it still belongs to the
    /// exact plan the player is recovering. This lets the player rebuild the
    /// same immutable plan with refreshed request headers without asking the
    /// server to advance the route ladder.
    func committedSession(
        planId expectedPlanId: String,
        sessionId expectedSessionId: String
    ) -> PlaybackSessionResponse? {
        guard pending == nil,
              sessionId == expectedSessionId,
              session?.sessionId == expectedSessionId,
              active?.plan.planId == expectedPlanId else {
            return nil
        }
        return session
    }

    func matchesAttempt(
        _ expected: ProtocolV3AttemptIdentity,
        sessionId expectedSessionId: String
    ) -> Bool {
        guard sessionId == expectedSessionId,
              session?.sessionId == expectedSessionId,
              let active else {
            return false
        }
        return ProtocolV3AttemptIdentity(active) == expected
    }

    /// The staged transition this prepared playback came from, if it is still
    /// the staged one. Identity is the candidate session and plan the server
    /// issued. Whether the bridge already points at that candidate is a
    /// separate question: commit and recovery require it, while a rollback has
    /// to recognise a candidate the bridge never adopted.
    private func stagedPending(matching prepared: PreparedPlayback) -> Pending? {
        guard let pending,
              pending.candidateSessionId == prepared.session.sessionId,
              pending.candidatePlanId == prepared.protocolV3?.plan.planId else {
            return nil
        }
        return pending
    }

    private func adoptedPending(matching prepared: PreparedPlayback) -> Pending? {
        guard let pending = stagedPending(matching: prepared),
              sessionId == pending.candidateSessionId,
              active?.plan.planId == pending.candidatePlanId else {
            return nil
        }
        return pending
    }

    private static func supersededSessionId(_ pending: Pending) -> String? {
        guard let priorSessionId = pending.priorSessionId,
              priorSessionId != pending.candidateSessionId else { return nil }
        return priorSessionId
    }
}
