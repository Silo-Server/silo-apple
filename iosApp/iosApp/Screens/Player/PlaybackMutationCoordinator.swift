import Foundation
import Observation

/// Observable projection of `PlaybackMutationCoordinator`'s pending stop
/// notices. The coordinator owns the set; this type only mirrors it for SwiftUI
/// and has no writer of its own.
@Observable
@MainActor
final class PlaybackStopNotices {
    static let shared = PlaybackStopNotices()
    private(set) var pending: Set<UUID> = []
    fileprivate func apply(_ id: UUID, pending isPending: Bool) {
        if isPending { pending.insert(id) } else { pending.remove(id) }
    }
}

/// The one answer to "does this session belong to the v2 sequenced contract".
/// `registrationFailed` is not `notSequenced`: the server allocated the session
/// under the sequenced contract but this process never bound a durable mutation
/// record for it, so it must never fall back to a plain DELETE.
enum PlaybackSequencedSessionState: Sendable, Equatable {
    case notSequenced
    case registrationFailed
    case bound
}

/// Retains sequenced mutation intent independently of the player/bridge lifetime.
/// Cross-process replay is not activated without authenticated installation identity.
actor PlaybackMutationCoordinator {
    static let shared = PlaybackMutationCoordinator()

    /// One record per start attempt. `isResolving` is a re-entrancy lock, not a
    /// phase: it is held past the `.completed` transition, so a second caller
    /// still sees `pendingStart` until resolution returns.
    private struct StartAttempt {
        enum Phase { case unresolved, completed }
        var start: StoredPlaybackStart
        /// Memory only. A restored durable response cannot recreate these credentials.
        var originalAuth: CapturedOrdinaryRequestAuth?
        var phase = Phase.unresolved
        var isResolving = false
    }
    private struct StopIntent {
        let position: Double?
        let isPaused: Bool
        var proposed: PlaybackSequencedStop?
    }
    /// One record per bound session. A stop intent is never cleared once taken,
    /// so `acceptsMutations` only falls from true to false. `auxiliary` outlives
    /// every plan this session adopts and answers media resolution for it.
    private struct SessionState {
        let recordID: UUID
        let sessionID: String
        let authority: PlaybackMutationAuthority
        let auxiliary: PlaybackAuxiliaryAuthority
        var attemptID: String?
        var stop: StopIntent?
        var isDraining = false
        var restoredAfterRestart = false
        var acceptsMutations: Bool { stop == nil }
    }

    private let api: SiloAPI
    private let tokens: TokenStore
    private let store: PlaybackMutationStore
    private let retryDelays: [Duration]
    private let pendingStarts: @Sendable (PlaybackMutationAuthority) async throws -> [StoredPlaybackStart]
    private var attempts: [UUID: StartAttempt] = [:]
    private var sessions: [String: SessionState] = [:]
    /// Sessions the server allocated under the sequenced contract that this
    /// process could not bind. Separate from `sessions` because a failure can
    /// exist with no record at all, and outranks a record left by an earlier
    /// registration whose authority has since changed.
    private var failedRegistrations: Set<String> = []
    /// Authoritative pending-stop notices, mirrored by `PlaybackStopNotices`.
    /// Keyed by start id *and* by session record id, so it stays its own ledger.
    private var pendingStopNotices: Set<UUID> = []

    init(api: SiloAPI = .shared, tokens: TokenStore = .shared, store: PlaybackMutationStore = .shared,
         retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5), .seconds(5), .seconds(5)],
         pendingStarts: (@Sendable (PlaybackMutationAuthority) async throws -> [StoredPlaybackStart])? = nil) {
        self.api = api
        self.tokens = tokens
        self.store = store
        self.retryDelays = retryDelays
        self.pendingStarts = pendingStarts ?? { try await store.pendingStarts(authority: $0) }
    }

    /// The live record for a session that still accepts mutations: one read in
    /// place of the former context lookup plus stop-intent membership test.
    private func mutable(_ sessionID: String) -> SessionState? {
        sessions[sessionID].flatMap { $0.acceptsMutations ? $0 : nil }
    }

    /// Post-suspension re-read: the same binding, still accepting mutations.
    private func stillAccepts(_ session: SessionState) -> Bool {
        stillAccepts(sessionID: session.sessionID, recordID: session.recordID)
    }

    private func stillAccepts(sessionID: String, recordID: UUID) -> Bool {
        sessions[sessionID].map { $0.recordID == recordID && $0.acceptsMutations } ?? false
    }

    /// What `PlaybackAuxiliaryAuthority` is allowed to know about this actor's
    /// session map. `owns` is the durable-owner half of the former adoption
    /// guard: identity of the captured request auth, then the durable owner
    /// behind it, then the same binding again across that suspension.
    private func auxiliaryOwnership(sessionID: String, recordID: UUID) -> PlaybackAuxiliaryOwnership {
        PlaybackAuxiliaryOwnership(
            accepts: { [weak self] in await self?.stillAccepts(sessionID: sessionID, recordID: recordID) ?? false },
            owns: { [weak self] auth in await self?.isDurableOwner(auth, sessionID: sessionID, recordID: recordID) ?? false })
    }

    private func isDurableOwner(_ auth: CapturedOrdinaryRequestAuth, sessionID: String, recordID: UUID) async -> Bool {
        guard let session = sessions[sessionID], session.recordID == recordID, session.acceptsMutations,
              auth.profileId == session.authority.profileID,
              auth.account.serverId == session.authority.serverID,
              auth.account.serverURL == session.authority.origin,
              let owner = await tokens.captureDurableAccountAuth(), owner.request == auth,
              (try? PlaybackMutationAuthority(auth: owner, installationID: session.authority.installationID)) == session.authority,
              stillAccepts(sessionID: sessionID, recordID: recordID) else { return false }
        return true
    }

    private var isResolvingStart: Bool { attempts.values.contains { $0.isResolving } }

    /// A retired attempt is no longer replayable and no longer noticed.
    private func completeStart(_ id: UUID) async {
        attempts[id]?.phase = .completed
        await publishStopNotice(id, pending: false)
    }

    /// Retained bodies stay byte-exact, so key ordering is each call site's
    /// contract rather than a default of this helper.
    private func encodeBody(_ body: some Encodable, sortedKeys: Bool) throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if sortedKeys { encoder.outputFormatting = [.sortedKeys] }
        return try encoder.encode(body)
    }

    /// A session advertised under the sequenced contract is bound here or
    /// recorded as a registration failure. Both outcomes are readable through
    /// `sequencedState`; callers keep no parallel bookkeeping.
    func register(sessionID: String, features: [String], auth: CapturedDurableAccountAuth?,
                  installationID: String? = nil, attemptID: String? = nil, progressTimeline: APIv2ProgressTimeline? = nil) async throws {
        guard features.contains(PlaybackSequencedContract.feature) else { return }
        do {
            guard let auth else { throw PlaybackSequencedError.authorityChanged }
            let authority = try PlaybackMutationAuthority(auth: auth, installationID: installationID)
            _ = try await currentAuth(authority)
            let saved = try await store.register(sessionID: sessionID, authority: authority, progressTimeline: progressTimeline, attemptID: attemptID)
            // The journal write above suspends. Re-fence so a sign-out, account
            // switch or profile switch during it still fails closed into
            // `failedRegistrations` instead of binding a session this process no
            // longer owns; the check below only compares the *incoming*
            // authority against an earlier record, not the live durable owner.
            _ = try await currentAuth(authority)
            // A bare server session ID must never retarget an older bridge's
            // delayed callback to another account/profile/origin in this process.
            let previous = sessions[sessionID]
            if let previous, previous.authority != authority { throw PlaybackSequencedError.authorityChanged }
            // Re-registration keeps the live record: the store returns the same
            // durable id for one session under one authority, so stop intent,
            // restart marking and plan adoption survive the rebind.
            var session = previous?.recordID == saved.id ? previous!
                : SessionState(recordID: saved.id, sessionID: sessionID, authority: authority,
                    auxiliary: PlaybackAuxiliaryAuthority(sessionID: sessionID, tokens: tokens,
                        ownership: auxiliaryOwnership(sessionID: sessionID, recordID: saved.id)))
            session.attemptID = saved.attemptID ?? previous?.attemptID
            sessions[sessionID] = session
            failedRegistrations.remove(sessionID)
        } catch {
            failedRegistrations.insert(sessionID)
            throw error
        }
    }

    /// Single source of truth for "is this a v2 sequenced session". A recorded
    /// failure outranks a live record: an authority that changed under an
    /// already-bound session id is still unsafe to release plainly.
    func sequencedState(_ sessionID: String) -> PlaybackSequencedSessionState {
        if failedRegistrations.contains(sessionID) { return .registrationFailed }
        return sessions[sessionID] != nil ? .bound : .notSequenced
    }

    /// Mirrors one pending-stop notice onto the observable projection. The
    /// coordinator's own set is authoritative and deduplicates the hop.
    private func publishStopNotice(_ id: UUID, pending: Bool) async {
        let changed = pending ? pendingStopNotices.insert(id).inserted : pendingStopNotices.remove(id) != nil
        guard changed else { return }
        await PlaybackStopNotices.shared.apply(id, pending: pending)
    }

    func requireResolvedStartBeforeLegacy(auth: CapturedDurableAccountAuth) async throws {
        if try await store.hasUnresolvedStart(auth: auth) { throw PlaybackSequencedError.pendingStart }
    }

    /// Starting playback requires the configured v2 contract and a durable owner.
    func captureStartAuth() async throws -> (request: CapturedOrdinaryRequestAuth,
                                             durable: CapturedDurableAccountAuth?,
                                             capability: APIv2PlaybackCapabilities) {
        guard let request = await tokens.captureOrdinaryRequestAuth() else { throw PlaybackSequencedError.authorityChanged }
        let durable = await tokens.captureDurableAccountAuth()
        guard durable == nil || durable?.request == request else { throw PlaybackSequencedError.authorityChanged }
        let capability = try await api.v2.playbackCapabilities(auth: request)
        guard await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: request) != nil
            else { throw PlaybackSequencedError.authorityChanged }
        _ = try capability.requireAvailable()
        // The authority itself is re-derived and re-fenced by `startV2` and
        // `discoverTimeline`, which are the only callers that send a mutation.
        guard durable != nil else { throw PlaybackSequencedError.authorityChanged }
        return (request, durable, capability)
    }

    func discoverTimeline(fileID: Int, itemID: String, auth: CapturedDurableAccountAuth,
                          capability: APIv2PlaybackCapabilities) async throws -> APIv2PlaybackManifest {
        guard capability.features.contains(APIv2PlaybackManifest.feature) else {
            throw PlaybackV3TerminalFailure(reason: "bound_timeline_unsupported",
                message: "Update the server to play audiobooks with API v2.", retryable: false)
        }
        let installation = try capability.requireAvailable()
        let authority = try PlaybackMutationAuthority(auth: auth, installationID: installation)
        // A manifest read journals nothing, so the pre-dispatch fence is enough.
        return try await api.v2.playbackManifest(fileID: fileID, installationID: installation,
            itemID: itemID, auth: try await currentAuth(authority))
    }

    func startV2(request: PlaybackV3StartRequest, auth: CapturedDurableAccountAuth?,
                 capability: APIv2PlaybackCapabilities, progressTimeline: APIv2ProgressTimeline? = nil) async throws -> PlaybackV3DecisionResponse {
        guard let auth else { throw PlaybackSequencedError.authorityChanged }
        let installation = try capability.requireAvailable()
        let authority = try PlaybackMutationAuthority(auth: auth, installationID: installation)
        guard request.profileId == authority.profileID else { throw PlaybackSequencedError.authorityChanged }
        _ = try await currentAuth(authority)
        if request.progressPersistence == "client_bound" {
            guard capability.features.contains(APIv2PlaybackManifest.feature),
                  let progressTimeline, request.timelineId == progressTimeline.timelineId,
                  String(request.fileId) == progressTimeline.fileId else { throw PlaybackSequencedError.invalidResponse }
            try progressTimeline.validate()
            try await store.requireTerminalBoundSessions(authority: authority)
        } else if progressTimeline != nil || request.timelineId != nil { throw PlaybackSequencedError.invalidResponse }
        let body = try encodeBody(APIv2PlaybackStartBody(request, installationID: installation), sortedKeys: true)
        let prepared = try await store.prepareStartWithDisposition(authority: authority,
            attemptID: request.playbackAttemptId, body: body, progressTimeline: progressTimeline)
        let start = prepared.start
        if prepared.created { attempts[start.id, default: StartAttempt(start: start)].originalAuth = auth.request }
        guard attempts[start.id]?.phase != .completed else { throw PlaybackSequencedError.invalidSession }
        attempts[start.id, default: StartAttempt(start: start)].start = start
        await publishStopNotice(start.id, pending: true)
        // One retry for a start whose response never arrived. The journal holds
        // the byte-exact body and `resolveStart` revalidates authority before it
        // dispatches again, so the retry either repeats the identical attempt or
        // fails closed. Any other error is the server's answer and is not repeated.
        do { return try await resolveStart(start, retire: false) }
        catch let error as HTTPError {
            guard case .network = error else { throw error }
            return try await resolveStart(start, retire: false)
        }
    }

    private func resolveStart(_ start: StoredPlaybackStart, retire: Bool) async throws -> PlaybackV3DecisionResponse {
        // Explicit app Retry must not retire an allocation while its player
        // still owns the in-flight start and is about to begin playback.
        var attempt = attempts[start.id] ?? StartAttempt(start: start)
        guard attempt.phase != .completed else { throw PlaybackSequencedError.invalidSession }
        guard !attempt.isResolving else { throw PlaybackSequencedError.pendingStart }
        attempt.isResolving = true
        attempts[start.id] = attempt
        defer {
            attempts[start.id]?.isResolving = false
            if attempts[start.id]?.phase == .completed { attempts[start.id]?.originalAuth = nil }
        }
        // Snapshots held across actor suspension are not permission to retire
        // a start. Re-read the journal while owning this attempt's resolution.
        let start = try await store.start(start.id, authority: start.authority)
        guard !start.finished else {
            await completeStart(start.id)
            throw PlaybackSequencedError.invalidSession
        }
        let auth = try await currentAuth(start.authority)
        // Autoplay recovery can reuse only this process's original snapshot.
        // Explicit retirement may resolve uncertainty with current durable-owner
        // credentials, but cannot grant media authority from that replay.
        if !retire, let original = attempts[start.id]?.originalAuth, original != auth {
            throw PlaybackSequencedError.authorityChanged
        }
        let data: Data
        if let saved = start.response { data = saved }
        else {
            // A validation response does not prove that an earlier uncertain
            // dispatch never allocated a session. Retain the journal until an
            // authoritative replay resolves that allocation.
            let response = try await api.v2.playbackRequest(method: "POST", suffix: "/start", body: start.body, auth: auth)
            _ = try await currentAuth(start.authority)
            if let recovery = try PlaybackOwnerLossRecovery.decode(response.data, status: response.statusCode, start: true) {
                try await store.observeStartOwnerLoss(start.id, authority: start.authority, recovery: recovery)
                if recovery.state == .draining { throw PlaybackSequencedError.pendingStart }
                await completeStart(start.id)
                // A terminal decision has no renderer/session adoption. Original
                // body and any historical response remain unchanged in the journal.
                return try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackDecision.self, from: response.data).legacy()
            }
            guard start.ownerLoss == nil, response.statusCode == 201 else { throw PlaybackSequencedError.invalidResponse }
            data = response.data
            try await store.acknowledgeStart(start.id, authority: start.authority, response: data, finished: false)
        }
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackDecision.self, from: data)
        if start.progressTimeline != nil,
           wire.outcome == "adaptation_unavailable" || wire.terminal?.reason == "client_timeline_changed" {
            // Only a retained ordinary START decision can settle the original
            // bound attempt. HTTP errors (including 409) never reach this path.
            guard wire.protocolVersion == PlaybackProtocolV3.version,
                  wire.serverFeatures.contains(PlaybackProtocolV3.planFeature),
                  wire.outcome == "adaptation_unavailable",
                  wire.sessionId == nil, wire.playbackPlan == nil, wire.progressTimeline == nil,
                  let terminal = wire.terminal, !terminal.reason.isEmpty,
                  terminal.reason != "client_timeline_changed" || !terminal.retryable else {
                throw PlaybackSequencedError.invalidResponse
            }
        }
        let sessionID = wire.sessionId ?? wire.playbackPlan?.sessionId
        if let sessionID {
            guard wire.progressTimeline == start.progressTimeline else { throw PlaybackSequencedError.invalidResponse }
            if let binding = start.progressTimeline {
                guard wire.serverFeatures.contains(APIv2PlaybackManifest.feature),
                      wire.playbackPlan?.effectiveMediaFileId == binding.fileId else { throw PlaybackSequencedError.invalidResponse }
            }
            guard let durable = await tokens.captureDurableAccountAuth(),
                  try PlaybackMutationAuthority(auth: durable, installationID: start.authority.installationID) == start.authority else {
                throw PlaybackSequencedError.authorityChanged
            }
            try await register(sessionID: sessionID, features: [PlaybackSequencedContract.feature], auth: durable,
                installationID: start.authority.installationID, attemptID: start.attemptID, progressTimeline: start.progressTimeline)
            if retire { _ = try await stop(sessionID: sessionID, position: nil, isPaused: true) }
        } else if wire.outcome != "adaptation_unavailable" { throw PlaybackSequencedError.invalidResponse }
        // A known session is now independently journaled, even if local plan
        // projection fails. Explicit retry resolves uncertainty without autoplay.
        try await store.acknowledgeStart(start.id, authority: start.authority, response: data, finished: true)
        await completeStart(start.id)
        do {
            let response = try wire.legacy()
            if let sessionID, !retire {
                let input = try JSONSerialization.jsonObject(with: start.body) as? [String: Any]
                let features = input?["client_features"] as? [String] ?? []
                // The original auth outlives completion: only the `defer` above
                // drops it from the retired attempt.
                try await sessions[sessionID]?.auxiliary.adopt(plan: response.playbackPlan,
                    auth: attempts[start.id]?.originalAuth,
                    allowsAuthorizedOrigins: features.contains(PlaybackProtocolV3.authorizedMediaOriginsFeature))
            }
            return response
        }
        catch {
            if let sessionID { _ = try? await stop(sessionID: sessionID, position: nil, isPaused: true) }
            throw error
        }
    }

    /// Restore notices and ownership only. No persisted request is dispatched.
    func restorePending() async {
        do {
            guard let auth = await tokens.captureDurableAccountAuth() else { return }
            let capability = try await api.v2.playbackCapabilities(auth: auth.request)
            let authority = try PlaybackMutationAuthority(auth: auth, installationID: capability.requireAvailable())
            for start in try await pendingStarts(authority) {
                guard attempts[start.id]?.phase != .completed else { continue }
                attempts[start.id, default: StartAttempt(start: start)].start = start
                // Publishing suspends; a concurrent resolution may retire the attempt.
                await publishStopNotice(start.id, pending: true)
                if attempts[start.id]?.phase == .completed { await publishStopNotice(start.id, pending: false) }
            }
            for session in try await store.pendingStops(authority: authority, afterRestart: true) {
                // A live player or resolving allocation owns its session. Only
                // an abandoned bound session gets an explicit stop-recovery notice.
                let abandoned = session.stop == nil
                if abandoned {
                    guard sessions[session.sessionID] == nil, !isResolvingStart else { continue }
                }
                try await register(sessionID: session.sessionID, features: [PlaybackSequencedContract.feature], auth: auth,
                    installationID: authority.installationID, attemptID: session.attemptID,
                    progressTimeline: session.progressTimeline)
                if abandoned { sessions[session.sessionID]?.restoredAfterRestart = true }
                await publishStopNotice(session.id, pending: true)
            }
        } catch { /* Unknown or changed authority remains quarantined. */ }
    }

    func replan(sessionID: String, request: PlaybackV3ReplanRequest) async throws -> PlaybackV3DecisionResponse {
        guard let session = mutable(sessionID), let installation = session.authority.installationID,
              session.attemptID == request.playbackAttemptId else { throw PlaybackSequencedError.authorityChanged }
        guard ["seek_reanchor", "seek_failure_recovery", "failure_recovery"].contains(request.operation) else {
            throw PlaybackV3TerminalFailure(reason: "capability_unsupported",
                message: "This server does not support changing playback tracks, quality or output during API v2 playback.", retryable: false)
        }
        let allowsAuthorizedOrigins = await session.auxiliary.allowsAuthorizedOrigins
        let auth = try await currentAuth(session.authority)
        let body = try encodeBody(APIv2PlaybackReplanBody(installationID: installation, request: request), sortedKeys: true)
        let saved = try await store.prepareReplan(sessionID: sessionID, authority: session.authority,
            requestID: request.replanRequestId, body: body)
        guard stillAccepts(session) else { throw PlaybackSequencedError.invalidSession }
        let raw = try await api.v2.playbackRequest(method: "POST", suffix: "/\(sessionID)/replan", body: saved.body, auth: auth)
        guard raw.statusCode == 200 else { throw PlaybackSequencedError.invalidResponse }
        _ = try await currentAuth(session.authority)
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackDecision.self, from: raw.data)
        guard (wire.sessionId ?? wire.playbackPlan?.sessionId) == sessionID else { throw PlaybackSequencedError.invalidResponse }
        let response = try wire.legacy()
        try await store.acknowledgeReplan(saved, response: raw.data)
        guard stillAccepts(session) else { throw PlaybackSequencedError.invalidSession }
        try await session.auxiliary.adopt(plan: response.playbackPlan, auth: auth,
            allowsAuthorizedOrigins: allowsAuthorizedOrigins)
        return response
    }

    /// Diagnostics have one dispatch and never drive a playback mutation retry.
    /// A stop intent does not silence them, so this reads the record directly.
    func reportRouteEvent(_ event: PlaybackV3RouteEvent) async throws {
        guard let sessionID = event.sessionId, let session = sessions[sessionID],
              session.attemptID == event.playbackAttemptId, let installation = session.authority.installationID else {
            throw PlaybackSequencedError.authorityChanged
        }
        let auth = try await currentAuth(session.authority)
        let eventID = UUID().uuidString.lowercased()
        let body = try encodeBody(APIv2PlaybackRouteEventBody(installationID: installation, eventID: eventID, event: event), sortedKeys: false)
        let raw = try await api.v2.playbackRequest(method: "POST", suffix: "/route-events", body: body, auth: auth)
        let receipt = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackRouteEventReceipt.self, from: raw.data)
        guard raw.statusCode == 202, receipt.eventId == eventID,
              receipt.outcome == "accepted" else { throw PlaybackSequencedError.invalidResponse }
    }

    struct ControlBinding: Sendable {
        let sessionID: String
        let authority: PlaybackMutationAuthority
        let auth: CapturedOrdinaryRequestAuth
    }

    func controlBinding(sessionID: String) async throws -> ControlBinding {
        guard let session = mutable(sessionID),
              session.authority.installationID != nil else { throw PlaybackSequencedError.invalidSession }
        let binding = ControlBinding(sessionID: sessionID, authority: session.authority,
            auth: try await currentAuth(session.authority))
        try await validateControlBinding(binding)
        return binding
    }

    func validateControlBinding(_ binding: ControlBinding) async throws {
        guard let session = mutable(binding.sessionID),
              session.authority == binding.authority else { throw PlaybackSequencedError.invalidSession }
        _ = try await currentAuth(binding.authority)
        guard await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: binding.auth) != nil,
              stillAccepts(session) else { throw PlaybackSequencedError.authorityChanged }
    }

    /// Media resolution shares the durable session fence with control. It must
    /// never pick a server or credential from a later account selection.
    func streamRequest(sessionID: String, rawURL: String, additionalHeaders: [String: String],
                       requiresHeaderAuthenticatedMedia: Bool,
                       allowsAuthorizedMediaOrigins: Bool = false) async throws -> StreamRequest {
        if let auxiliary = sessions[sessionID]?.auxiliary,
           let request = try await auxiliary.resolveStreamRequest(rawURL: rawURL,
               requiresHeaderAuthenticatedMedia: requiresHeaderAuthenticatedMedia,
               allowsAuthorizedMediaOrigins: allowsAuthorizedMediaOrigins) {
            return request
        }
        // A restored response has no ephemeral original auth for a proxy plan.
        guard !allowsAuthorizedMediaOrigins, !StreamRequest.isHeaderAuthenticatedAPIPrimary(rawURL, sessionID: sessionID) else { throw PlaybackSequencedError.authorityChanged }
        let binding = try await controlBinding(sessionID: sessionID)
        guard let request = StreamRequest.resolve(rawURL: rawURL,
            serverURL: binding.auth.account.serverURL, additionalHeaders: additionalHeaders,
            accessToken: binding.auth.accessToken,
            requiresHeaderAuthenticatedMedia: requiresHeaderAuthenticatedMedia,
            apiV2SessionId: sessionID) else { throw PlaybackSequencedError.invalidSession }
        try await validateControlBinding(binding)
        return request
    }

    func controlRequest(_ binding: ControlBinding) async throws -> URLRequest {
        try await validateControlBinding(binding)
        guard let installation = binding.authority.installationID else { throw PlaybackSequencedError.invalidSession }
        let request = try await api.v2.playbackControlRequest(sessionID: binding.sessionID,
            installationID: installation, auth: binding.auth)
        try await validateControlBinding(binding)
        return request
    }

    /// Local comparison only. The installation ID is captured once from
    /// `GET /api/v2/playback/capabilities` in `captureStartAuth` (or in
    /// `restorePending` after a restart) and is echoed on every mutation. A stale
    /// installation is answered with `409 installation_changed`, so re-probing
    /// capabilities per call adds a round trip without adding a guarantee.
    private func currentAuth(_ authority: PlaybackMutationAuthority) async throws -> CapturedOrdinaryRequestAuth {
        guard let current = await tokens.captureDurableAccountAuth(),
              try PlaybackMutationAuthority(auth: current, installationID: authority.installationID) == authority else {
            throw PlaybackSequencedError.authorityChanged
        }
        return current.request
    }

    func report(sessionID: String, position: Double, isPaused: Bool) async throws {
        guard let session = mutable(sessionID) else { throw PlaybackSequencedError.invalidSession }
        let auth = try await currentAuth(session.authority)
        guard stillAccepts(session) else { throw PlaybackSequencedError.invalidSession }
        let sample = try await store.prepareProgress(session.recordID, authority: session.authority,
            position: position, isPaused: isPaused)
        let receipt = try await api.reportSequencedPlaybackProgress(sessionID: sessionID, sample: sample, auth: auth, installationID: session.authority.installationID)
        _ = try await currentAuth(session.authority)
        try await store.acknowledgeProgress(session.recordID, authority: session.authority, sent: sample, receipt: receipt)
    }

    @discardableResult
    func stop(sessionID: String, position: Double?, isPaused: Bool) async throws -> Bool {
        guard var session = sessions[sessionID] else { throw PlaybackSequencedError.invalidSession }
        let intent = session.stop ?? StopIntent(position: position, isPaused: isPaused)
        if session.stop == nil {
            session.stop = intent
            sessions[sessionID] = session
        }
        guard !session.isDraining else { return false }
        sessions[sessionID]?.isDraining = true
        defer { sessions[sessionID]?.isDraining = false }
        // Stop intent and the drain lock are taken without suspending, so the
        // plan is retired only once no other caller can still be adopting one.
        await session.auxiliary.invalidate()
        await publishStopNotice(session.recordID, pending: true)
        // Keep the exact UUID and sample if durable publication fails. No request
        // may leave this coordinator until that same intent is persisted.
        let proposal: PlaybackSequencedStop
        if let existing = intent.proposed { proposal = existing } else {
            proposal = try await store.proposedStop(session.recordID, authority: session.authority,
                position: intent.position, isPaused: intent.isPaused)
        }
        sessions[sessionID]?.stop?.proposed = proposal
        let stop = try await store.persistStop(session.recordID, authority: session.authority, stop: proposal)
        let saved = try await store.session(session.recordID, authority: session.authority)
        if saved.stopState.isTerminal {
            await publishStopNotice(session.recordID, pending: false)
            if saved.stopState == .abandoned { throw PlaybackOwnerLossRecovery.terminalFailure }
            return true
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        for attempt in 0...retryDelays.count {
            do {
                try Task.checkCancellation()
                let auth = try await currentAuth(session.authority)
                let resolution = try await api.resolveSequencedPlaybackStop(sessionID: session.sessionID, stop: stop,
                    auth: auth, installationID: session.authority.installationID)
                _ = try await currentAuth(session.authority)
                switch resolution {
                case .ordinary(let receipt):
                    try await store.acknowledgeStop(session.recordID, authority: session.authority, sent: stop, receipt: receipt)
                    if receipt.outcome != .draining {
                        await publishStopNotice(session.recordID, pending: false)
                        return true
                    }
                case .ownerLost(let recovery):
                    try await store.observeStopOwnerLoss(session.recordID, authority: session.authority, sent: stop,
                        recovery: recovery)
                    if recovery.state == .aborted {
                        await publishStopNotice(session.recordID, pending: false)
                        // Do not let a pending final sample or an automatic bound
                        // part transition interpret abandonment as its STOP success.
                        throw PlaybackOwnerLossRecovery.terminalFailure
                    }
                }
            } catch let error as PlaybackV3TerminalFailure where error.reason == "playback_owner_lost" { throw error }
            catch PlaybackSequencedError.authorityChanged { return false }
            catch HTTPError.requestIdentityChanged { return false }
            catch HTTPError.http(let code, _) where [400, 401, 403, 404, 409, 422].contains(code) { return false }
            catch APIv2Error.problem(let problem) where [400, 401, 403, 404, 409, 422].contains(problem.status) { return false }
            catch APIv2Error.httpStatus(let code) where [400, 401, 403, 404, 409, 422].contains(code) { return false }
            catch is CancellationError { return false }
            catch { /* Preserve exact durable intent after an uncertain response. */ }
            guard attempt < retryDelays.count, ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: retryDelays[attempt]) } catch { return false }
        }
        return false
    }

    /// Explicit same-process user retry. Unknown-installation records are never
    /// loaded into this session map automatically after process restart.
    func retryPendingStops() async {
        var justResolved: Set<String> = []
        for attempt in Array(attempts.values) where attempt.phase == .unresolved {
            if let response = try? await resolveStart(attempt.start, retire: true),
               let id = response.sessionId ?? response.playbackPlan?.sessionId { justResolved.insert(id) }
        }
        for session in Array(sessions.values) {
            guard !justResolved.contains(session.sessionID) else { continue }
            // An intended or restart-recovered stop is retried on its own word;
            // anything else needs a durable unfinished stop to justify a retry.
            if session.stop == nil, !session.restoredAfterRestart {
                guard let saved = try? await store.session(session.recordID, authority: session.authority),
                      saved.stop != nil, !saved.stopState.isTerminal else { continue }
            }
            _ = try? await stop(sessionID: session.sessionID, position: nil, isPaused: true)
        }
    }
}
