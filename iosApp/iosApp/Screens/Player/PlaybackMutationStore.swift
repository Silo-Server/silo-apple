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
    var allocatedSequence: Int64 = 0
    var pendingProgress: PlaybackSequencedSample?
    var accepted: PlaybackSequencedSample?
    var stop: PlaybackSequencedStop?
    var stopState: StopState = .none
    var historyID: String?
    enum StopState: String, Codable { case none, pending, draining, terminal }
}

private struct PlaybackMutationStoreFile: Codable {
    var version = 1
    var sessions: [UUID: StoredPlaybackMutationSession] = [:]
}

/// Durable idempotency data, not authority. Callers must obtain current canonical
/// credentials before each request. This actor never dispatches or replays traffic.
actor PlaybackMutationStore {
    static let shared = PlaybackMutationStore(url: FileManager.default.urls(for: .applicationSupportDirectory,
        in: .userDomainMask)[0].appendingPathComponent("playback-mutations.json"))

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

    func register(sessionID: String, authority: PlaybackMutationAuthority) throws -> StoredPlaybackMutationSession {
        var file = try read()
        if let existing = file.sessions.values.first(where: { $0.sessionID == sessionID && $0.authority == authority }) { return existing }
        guard !sessionID.isEmpty else { throw PlaybackSequencedError.invalidSession }
        let session = StoredPlaybackMutationSession(id: UUID(), sessionID: sessionID, authority: authority)
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
        guard session.stop == nil else { throw PlaybackSequencedError.invalidSession }
        // An uncertain sample is retried exactly before a newer logical sample.
        if let pending = session.pendingProgress { return pending }
        guard session.allocatedSequence < Int64.max else { throw PlaybackSequencedError.invalidSample }
        let sample = try PlaybackSequencedSample(sequence: session.allocatedSequence + 1, position: position, isPaused: isPaused)
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
            sample = try PlaybackSequencedSample(sequence: session.allocatedSequence + 1, position: position, isPaused: isPaused)
        } else { sample = nil }
        return PlaybackSequencedStop(stopID: UUID(), sample: sample)
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

    func prepareStop(_ id: UUID, authority: PlaybackMutationAuthority, position: Double?,
                     isPaused: Bool) throws -> PlaybackSequencedStop {
        let stop = try proposedStop(id, authority: authority, position: position, isPaused: isPaused)
        return try persistStop(id, authority: authority, stop: stop)
    }

    func acknowledgeStop(_ id: UUID, authority: PlaybackMutationAuthority, sent: PlaybackSequencedStop,
                         receipt: PlaybackSequencedStopReceipt) throws {
        var file = try read()
        guard var session = file.sessions[id], session.authority == authority,
              session.stop == sent, receipt.stopId == sent.stopID else { throw PlaybackSequencedError.authorityChanged }
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

    func pendingStops(authority: PlaybackMutationAuthority, afterRestart: Bool) throws -> [StoredPlaybackMutationSession] {
        guard !afterRestart || authority.installationID != nil else { return [] }
        return try read().sessions.values.filter {
            $0.authority == authority && $0.stop != nil && $0.stopState != .terminal
        }
    }
}
