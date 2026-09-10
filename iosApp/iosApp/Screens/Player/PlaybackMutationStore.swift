import Foundation

struct PlaybackMutationAuthority: Codable, Equatable, Sendable {
    let serverID: String
    let origin: String
    let accountID: String
    let accountEpoch: UUID
    let profileID: String
    /// Only an authenticated server capability may establish this value.
    /// Nil records are never eligible for automatic cross-process replay.
    let installationID: String?

    init(auth: CapturedDurableAccountAuth, installationID: String?) throws {
        guard case .persistentServer = auth.request.credentialOwner,
              let profile = auth.request.profileId, !profile.isEmpty,
              !auth.accountID.isEmpty, installationID?.isEmpty != true else {
            throw PlaybackSequencedError.authorityChanged
        }
        serverID = auth.request.account.serverId
        origin = auth.request.account.serverURL
        accountID = auth.accountID
        accountEpoch = auth.accountEpoch
        profileID = profile
        self.installationID = installationID
    }
}

struct StoredPlaybackMutationSession: Codable, Sendable {
    let id: UUID
    let sessionID: String
    let authority: PlaybackMutationAuthority
    var progressTimeline: APIv2ProgressTimeline? = nil
    /// The attempt that allocated this session. Nil only for a record written by
    /// an older build; owner-loss recovery for such a record stays fail-closed.
    var attemptID: String? = nil
    var ownerLoss: PlaybackOwnerLossRecovery? = nil
    var allocatedSequence: Int64 = 0
    var pendingProgress: PlaybackSequencedSample?
    var accepted: PlaybackSequencedSample?
    var stop: PlaybackSequencedStop?
    var stopState: StopState = .none
    var historyID: String?
    enum StopState: String, Codable { case none, pending, draining, terminal, abandoned
        var isTerminal: Bool { self == .terminal || self == .abandoned } }
}

struct StoredPlaybackStart: Codable, Sendable {
    let id: UUID
    let authority: PlaybackMutationAuthority
    let attemptID: String
    let body: Data
    var response: Data?
    var progressTimeline: APIv2ProgressTimeline? = nil
    var ownerLoss: PlaybackOwnerLossRecovery? = nil
    var finished = false
}

struct StoredPlaybackReplan: Codable, Sendable {
    let id: UUID
    let sessionID: String
    let authority: PlaybackMutationAuthority
    let requestID: String
    let body: Data
    var response: Data?
}

private struct PlaybackMutationStoreFile: Codable {
    var starts: [UUID: StoredPlaybackStart]?
    var replans: [UUID: StoredPlaybackReplan]?
    var version = 1
    var sessions: [UUID: StoredPlaybackMutationSession] = [:]
}

/// Durable idempotency data, not authority. Callers must obtain current canonical
/// credentials before each request. This actor never dispatches or replays traffic.
actor PlaybackMutationStore {
    /// tvOS rejects Application Support writes, which failed this journal before
    /// `/api/v2/playback/start` was ever sent. `AppleStorageRoot` owns that rule.
    static let shared: PlaybackMutationStore = {
        AppleStorageRoot.logSelectedCategory(subsystemCategory: "PlaybackMutations")
        return PlaybackMutationStore(
            url: AppleStorageRoot.baseDirectory().appendingPathComponent("playback-mutations.json"))
    }()

    private let url: URL
    private let write: @Sendable (Data, URL) throws -> Void

    init(url: URL, write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.url = url
        self.write = write
    }

    private func read() throws -> PlaybackMutationStoreFile {
        guard FileManager.default.fileExists(atPath: url.path) else { return PlaybackMutationStoreFile() }
        let file = try JSONDecoder().decode(PlaybackMutationStoreFile.self, from: Data(contentsOf: url))
        guard file.version == 1, file.sessions.allSatisfy({ $0.key == $0.value.id && $0.value.allocatedSequence >= 0 }) else {
            throw PlaybackSequencedError.invalidResponse
        }
        return file
    }

    private func persist(_ file: PlaybackMutationStoreFile) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(JSONEncoder().encode(file), url)
    }

    func register(sessionID: String, authority: PlaybackMutationAuthority, progressTimeline: APIv2ProgressTimeline? = nil, attemptID: String? = nil) throws -> StoredPlaybackMutationSession {
        var file = try read()
        if let existing = file.sessions.values.first(where: { $0.sessionID == sessionID && $0.authority == authority }) {
            guard existing.progressTimeline == progressTimeline else { throw PlaybackSequencedError.invalidResponse }
            return existing
        }
        try progressTimeline?.validate()
        guard !sessionID.isEmpty else { throw PlaybackSequencedError.invalidSession }
        let session = StoredPlaybackMutationSession(id: UUID(), sessionID: sessionID, authority: authority, progressTimeline: progressTimeline, attemptID: attemptID)
        file.sessions[session.id] = session
        try persist(file)
        return session
    }

    func session(_ id: UUID, authority: PlaybackMutationAuthority) throws -> StoredPlaybackMutationSession {
        guard let session = try read().sessions[id], session.authority == authority else { throw PlaybackSequencedError.authorityChanged }
        return session
    }

    func prepareProgress(_ id: UUID, authority: PlaybackMutationAuthority, position: Double,
                         isPaused: Bool) throws -> PlaybackSequencedSample {
        var file = try read()
        guard var session = file.sessions[id], session.authority == authority else { throw PlaybackSequencedError.authorityChanged }
        guard session.stop == nil, !session.stopState.isTerminal else { throw PlaybackSequencedError.invalidSession }
        // An uncertain sample is retried exactly before a newer logical sample.
        if let pending = session.pendingProgress { return pending }
        guard session.allocatedSequence < Int64.max else { throw PlaybackSequencedError.invalidSample }
        if let binding = session.progressTimeline, position > binding.partDurationSeconds { throw PlaybackSequencedError.invalidSample }
        let sample = try PlaybackSequencedSample(sequence: session.allocatedSequence + 1, position: position, isPaused: isPaused,
            timelineId: session.progressTimeline?.timelineId)
        session.allocatedSequence = sample.sequence
        session.pendingProgress = sample
        file.sessions[id] = session
        try persist(file)
        return sample
    }

    func acknowledgeProgress(_ id: UUID, authority: PlaybackMutationAuthority, sent: PlaybackSequencedSample,
                             receipt: PlaybackSequencedProgressReceipt) throws {
        var file = try read()
        guard var session = file.sessions[id], session.authority == authority else { throw PlaybackSequencedError.authorityChanged }
        if session.stopState == .abandoned { return }
        try session.progressTimeline?.validateReceipt(receipt.accepted)
        if session.pendingProgress == sent { session.pendingProgress = nil }
        if let accepted = receipt.accepted, accepted.sequence >= (session.accepted?.sequence ?? 0) {
            session.accepted = accepted
            session.allocatedSequence = max(session.allocatedSequence, accepted.sequence)
        }
        file.sessions[id] = session
        try persist(file)
    }

    func proposedStop(_ id: UUID, authority: PlaybackMutationAuthority, position: Double?,
                      isPaused: Bool) throws -> PlaybackSequencedStop {
        let session = try session(id, authority: authority)
        if let stop = session.stop { return stop }
        let sample: PlaybackSequencedSample?
        if let position, position.isFinite, position >= 0 {
            guard session.allocatedSequence < Int64.max else { throw PlaybackSequencedError.invalidSample }
            if let binding = session.progressTimeline, position > binding.partDurationSeconds { throw PlaybackSequencedError.invalidSample }
            sample = try PlaybackSequencedSample(sequence: session.allocatedSequence + 1, position: position, isPaused: isPaused,
                timelineId: session.progressTimeline?.timelineId)
        } else { sample = nil }
        return PlaybackSequencedStop(stopID: UUID(), sample: sample, timelineId: session.progressTimeline?.timelineId)
    }

    func persistStop(_ id: UUID, authority: PlaybackMutationAuthority, stop: PlaybackSequencedStop) throws -> PlaybackSequencedStop {
        var file = try read()
        guard var session = file.sessions[id], session.authority == authority else { throw PlaybackSequencedError.authorityChanged }
        if let saved = session.stop { return saved }
        session.allocatedSequence = max(session.allocatedSequence, stop.sample?.sequence ?? 0)
        session.stop = stop
        session.stopState = .pending
        file.sessions[id] = session
        try persist(file)
        return stop
    }

    func acknowledgeStop(_ id: UUID, authority: PlaybackMutationAuthority, sent: PlaybackSequencedStop,
                         receipt: PlaybackSequencedStopReceipt) throws {
        var file = try read()
        guard var session = file.sessions[id], session.authority == authority,
              session.stop == sent, receipt.stopId == sent.stopID else { throw PlaybackSequencedError.authorityChanged }
        // The first observed recovery commits AbortID. A late ordinary StopID
        // cannot replace that resolution, including after a journal reload.
        guard session.ownerLoss == nil else { throw PlaybackSequencedError.invalidResponse }
        if receipt.accepted != nil || sent.sample != nil {
            try session.progressTimeline?.validateReceipt(receipt.accepted)
        }
        // A late 202 never reopens a terminal receipt.
        if session.stopState == .terminal { return }
        session.stopState = receipt.outcome == .draining ? .draining : .terminal
        if let accepted = receipt.accepted, accepted.sequence >= (session.accepted?.sequence ?? 0) {
            session.accepted = accepted
            session.allocatedSequence = max(session.allocatedSequence, accepted.sequence)
        }
        session.historyID = receipt.historyId ?? session.historyID
        file.sessions[id] = session
        try persist(file)
    }

    func observeStopOwnerLoss(_ id: UUID, authority: PlaybackMutationAuthority, sent: PlaybackSequencedStop,
        recovery: PlaybackOwnerLossRecovery) throws {
        var file = try read()
        guard var session = file.sessions[id], session.authority == authority, authority.installationID != nil,
              session.stop == sent else { throw PlaybackSequencedError.authorityChanged }
        // A session may obtain the attempt only from its own durable record. No
        // ambient plan, login or first-observation binding is permitted, so a
        // record written before the attempt was journaled can never recover.
        guard let attemptID = session.attemptID else { throw PlaybackSequencedError.authorityChanged }
        try recovery.validate(attemptID: attemptID, sessionID: session.sessionID,
            previous: session.ownerLoss, timeline: session.progressTimeline)
        // A real matching StopID receipt already stored remains authoritative.
        guard session.stopState != .terminal,
              session.ownerLoss != nil || session.stopState != .draining else {
            throw PlaybackSequencedError.invalidResponse
        }
        session.ownerLoss = recovery
        session.stopState = recovery.state == .aborted ? .abandoned : .draining
        if recovery.state == .aborted {
            session.accepted = recovery.accepted
            session.historyID = nil
        }
        file.sessions[id] = session
        try persist(file)
    }

    func observeStartOwnerLoss(_ id: UUID, authority: PlaybackMutationAuthority,
        recovery: PlaybackOwnerLossRecovery) throws {
        var file = try read()
        guard var start = file.starts?[id], start.authority == authority, authority.installationID != nil else {
            throw PlaybackSequencedError.authorityChanged
        }
        let input = try JSONSerialization.jsonObject(with: start.body) as? [String: Any]
        guard input?["installation_id"] as? String == authority.installationID,
              input?["profile_id"] as? String == authority.profileID,
              input?["playback_attempt_id"] as? String == start.attemptID else { throw PlaybackSequencedError.authorityChanged }
        let decision = try start.response.map { try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackDecision.self, from: $0) }
        try recovery.validate(attemptID: start.attemptID, sessionID: decision?.sessionId ?? decision?.playbackPlan?.sessionId,
            previous: start.ownerLoss, timeline: start.progressTimeline)
        start.ownerLoss = recovery
        start.finished = recovery.state == .aborted
        file.starts?[id] = start
        try persist(file)
    }

    /// An uncertain replan is retained, never replayed or rebased by a later player callback.
    func prepareReplan(sessionID: String, authority: PlaybackMutationAuthority,
                       requestID: String, body: Data) throws -> StoredPlaybackReplan {
        var file = try read()
        guard !(file.replans?.values.contains {
            $0.sessionID == sessionID && $0.authority == authority && ($0.response == nil || $0.requestID == requestID)
        } ?? false) else {
            throw PlaybackV3TerminalFailure(reason: "replan_pending",
                message: "A playback change could not be confirmed. Close this player before starting again.", retryable: false)
        }
        let replan = StoredPlaybackReplan(id: UUID(), sessionID: sessionID, authority: authority,
            requestID: requestID, body: body)
        if file.replans == nil { file.replans = [:] }
        file.replans?[replan.id] = replan
        try persist(file)
        return replan
    }

    func acknowledgeReplan(_ replan: StoredPlaybackReplan, response: Data) throws {
        var file = try read()
        guard var saved = file.replans?[replan.id], saved.authority == replan.authority,
              saved.body == replan.body, saved.response == nil else { throw PlaybackSequencedError.authorityChanged }
        saved.response = response
        file.replans?[replan.id] = saved
        try persist(file)
    }

    func requireTerminalBoundSessions(authority: PlaybackMutationAuthority) throws {
        guard !((try read()).sessions.values.contains {
            $0.authority == authority && $0.progressTimeline != nil && $0.stopState.isTerminal == false
        }) else { throw PlaybackSequencedError.invalidSession }
    }

    /// Creation is reported atomically with persistence; callers must never
    /// infer fresh credential authority from a missing response alone.
    func prepareStartWithDisposition(authority: PlaybackMutationAuthority, attemptID: String,
        body: Data, progressTimeline: APIv2ProgressTimeline? = nil) throws -> (start: StoredPlaybackStart, created: Bool) {
        var file = try read()
        guard !(file.starts?.values.contains(where: {
            $0.authority == authority && $0.attemptID == attemptID && $0.finished
        }) ?? false) else { throw PlaybackSequencedError.invalidSession }
        guard !file.sessions.values.contains(where: {
            $0.authority == authority && $0.ownerLoss?.state == .draining && !$0.stopState.isTerminal
        }) else { throw PlaybackSequencedError.pendingStart }
        if let existing = file.starts?.values.first(where: { $0.authority == authority && !$0.finished }) {
            guard existing.attemptID == attemptID, existing.body == body, existing.progressTimeline == progressTimeline else { throw PlaybackSequencedError.pendingStart }
            return (existing, false)
        }
        if progressTimeline != nil {
            guard !file.sessions.values.contains(where: {
                $0.authority == authority && $0.progressTimeline != nil && $0.stopState.isTerminal == false
            }) else { throw PlaybackSequencedError.invalidSession }
        }
        let start = StoredPlaybackStart(id: UUID(), authority: authority, attemptID: attemptID, body: body, progressTimeline: progressTimeline)
        if file.starts == nil { file.starts = [:] }
        file.starts?[start.id] = start
        try persist(file)
        return (start, true)
    }

    func start(_ id: UUID, authority: PlaybackMutationAuthority) throws -> StoredPlaybackStart {
        guard let start = try read().starts?[id], start.authority == authority else {
            throw PlaybackSequencedError.authorityChanged
        }
        return start
    }

    func acknowledgeStart(_ id: UUID, authority: PlaybackMutationAuthority, response: Data?, finished: Bool) throws {
        var file = try read()
        guard var start = file.starts?[id], start.authority == authority else { throw PlaybackSequencedError.authorityChanged }
        if start.finished { return }
        start.response = response ?? start.response
        start.finished = finished
        file.starts?[id] = start
        try persist(file)
    }

    func hasUnresolvedStart(auth: CapturedDurableAccountAuth) throws -> Bool {
        let current = try PlaybackMutationAuthority(auth: auth, installationID: nil)
        return try read().starts?.values.contains {
            !$0.finished && $0.authority.serverID == current.serverID && $0.authority.origin == current.origin &&
            $0.authority.accountID == current.accountID && $0.authority.accountEpoch == current.accountEpoch &&
            $0.authority.profileID == current.profileID
        } ?? false
    }

    func pendingStarts(authority: PlaybackMutationAuthority) throws -> [StoredPlaybackStart] {
        try read().starts?.values.filter { $0.authority == authority && !$0.finished } ?? []
    }

    func pendingStops(authority: PlaybackMutationAuthority, afterRestart: Bool) throws -> [StoredPlaybackMutationSession] {
        guard !afterRestart || authority.installationID != nil else { return [] }
        return try read().sessions.values.filter {
            $0.authority == authority && ($0.stop != nil || (afterRestart && $0.progressTimeline != nil)) && $0.stopState.isTerminal == false
        }
    }
}
