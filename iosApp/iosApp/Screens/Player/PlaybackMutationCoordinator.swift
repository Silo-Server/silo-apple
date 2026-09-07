import Foundation
import Observation

@Observable
@MainActor
final class PlaybackStopNotices {
    static let shared = PlaybackStopNotices()
    private(set) var pending: Set<UUID> = []
    func setPending(_ id: UUID, _ value: Bool) {
        if value { pending.insert(id) } else { pending.remove(id) }
    }
}

/// Retains sequenced mutation intent independently of the player/bridge lifetime.
/// Cross-process replay is not activated without authenticated installation identity.
actor PlaybackMutationCoordinator {
    static let shared = PlaybackMutationCoordinator()

    private struct Context: Sendable {
        let recordID: UUID
        let sessionID: String
        let authority: PlaybackMutationAuthority
        let attemptID: String?
    }
    private let api: SiloAPI
    private let tokens: TokenStore
    private let store: PlaybackMutationStore
    private let retryDelays: [Duration]
    private let pendingStarts: @Sendable (PlaybackMutationAuthority) async throws -> [StoredPlaybackStart]
    private var completedStarts: Set<UUID> = []
    private var resolvingStarts: Set<UUID> = []
    private var unresolvedStarts: [UUID: StoredPlaybackStart] = [:]
    private var contexts: [String: Context] = [:]
    private struct StopIntent {
        let position: Double?
        let isPaused: Bool
        var proposed: PlaybackSequencedStop?
    }
    private var stopIntents: [UUID: StopIntent] = [:]
    private var draining: Set<UUID> = []

    init(api: SiloAPI = .shared, tokens: TokenStore = .shared, store: PlaybackMutationStore = .shared,
         retryDelays: [Duration] = [.seconds(1), .seconds(2), .seconds(4), .seconds(5), .seconds(5), .seconds(5), .seconds(5)],
         pendingStarts: (@Sendable (PlaybackMutationAuthority) async throws -> [StoredPlaybackStart])? = nil) {
        self.api = api
        self.tokens = tokens
        self.store = store
        self.retryDelays = retryDelays
        self.pendingStarts = pendingStarts ?? { try await store.pendingStarts(authority: $0) }
    }

    func register(sessionID: String, features: [String], auth: CapturedDurableAccountAuth,
                  installationID: String? = nil, attemptID: String? = nil) async throws {
        guard features.contains(PlaybackSequencedContract.feature) else { return }
        let authority = try PlaybackMutationAuthority(auth: auth, installationID: installationID)
        _ = try await currentAuth(authority)
        let saved = try await store.register(sessionID: sessionID, authority: authority)
        _ = try await currentAuth(authority)
        // A bare server session ID must never retarget an older bridge's
        // delayed callback to another account/profile/origin in this process.
        if let existing = contexts[sessionID], existing.authority != authority {
            throw PlaybackSequencedError.authorityChanged
        }
        contexts[sessionID] = Context(recordID: saved.id, sessionID: sessionID, authority: authority,
            attemptID: attemptID ?? contexts[sessionID]?.attemptID)
    }

    func requireResolvedStartBeforeLegacy(auth: CapturedDurableAccountAuth) async throws {
        if try await store.hasUnresolvedStart(auth: auth) { throw PlaybackSequencedError.pendingStart }
    }

    /// Starting playback requires the configured v2 contract and a durable owner.
    func captureStartAuth() async throws -> (request: CapturedOrdinaryRequestAuth,
                                             durable: CapturedDurableAccountAuth?,
                                             capability: APIv2PlaybackCapabilities) {
        guard let request = await tokens.captureOrdinaryRequestAuth() else {
            throw PlaybackSequencedError.authorityChanged
        }
        let durable = await tokens.captureDurableAccountAuth()
        guard durable == nil || durable?.request == request else { throw PlaybackSequencedError.authorityChanged }
        let capability = try await api.v2.playbackCapabilities(auth: request)
        guard await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: request) != nil else {
            throw PlaybackSequencedError.authorityChanged
        }
        let installation = try capability.requireAvailable()
        guard let durable else { throw PlaybackSequencedError.authorityChanged }
        _ = try await currentAuth(PlaybackMutationAuthority(auth: durable, installationID: installation))
        return (request, durable, capability)
    }

    func startV2(request: PlaybackV3StartRequest, auth: CapturedDurableAccountAuth?,
                 capability: APIv2PlaybackCapabilities) async throws -> PlaybackV3DecisionResponse {
        guard let auth else { throw PlaybackSequencedError.authorityChanged }
        let installation = try capability.requireAvailable()
        let authority = try PlaybackMutationAuthority(auth: auth, installationID: installation)
        guard request.profileId == authority.profileID else { throw PlaybackSequencedError.authorityChanged }
        _ = try await currentAuth(authority)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(APIv2PlaybackStartBody(request, installationID: installation))
        let start = try await store.prepareStart(authority: authority, attemptID: request.playbackAttemptId, body: body)
        guard !completedStarts.contains(start.id) else { throw PlaybackSequencedError.invalidSession }
        unresolvedStarts[start.id] = start
        await PlaybackStopNotices.shared.setPending(start.id, true)
        return try await resolveStart(start, retire: false)
    }

    private func resolveStart(_ start: StoredPlaybackStart, retire: Bool) async throws -> PlaybackV3DecisionResponse {
        // Explicit app Retry must not retire an allocation while its player
        // still owns the in-flight start and is about to begin playback.
        guard !completedStarts.contains(start.id) else { throw PlaybackSequencedError.invalidSession }
        guard resolvingStarts.insert(start.id).inserted else { throw PlaybackSequencedError.pendingStart }
        defer { resolvingStarts.remove(start.id) }
        // Snapshots held across actor suspension are not permission to retire
        // a start. Re-read the journal while owning this attempt's resolution.
        let start = try await store.start(start.id, authority: start.authority)
        guard !start.finished else {
            completedStarts.insert(start.id)
            unresolvedStarts.removeValue(forKey: start.id)
            await PlaybackStopNotices.shared.setPending(start.id, false)
            throw PlaybackSequencedError.invalidSession
        }
        let auth = try await currentAuth(start.authority)
        let data: Data
        if let saved = start.response { data = saved }
        else {
            // A validation response does not prove that an earlier uncertain
            // dispatch of this attempt never allocated a session. Retain the
            // journal until an authoritative replay resolves that allocation.
            let response = try await api.v2.playbackRequest(method: "POST", suffix: "/start", body: start.body, auth: auth)
            guard response.statusCode == 201 else { throw PlaybackSequencedError.invalidResponse }
            data = response.data
            try await store.acknowledgeStart(start.id, authority: start.authority, response: data, finished: false)
        }
        _ = try await currentAuth(start.authority)
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackDecision.self, from: data)
        let sessionID = wire.sessionId ?? wire.playbackPlan?.sessionId
        if let sessionID {
            guard let durable = await tokens.captureDurableAccountAuth(),
                  try PlaybackMutationAuthority(auth: durable, installationID: start.authority.installationID) == start.authority else {
                throw PlaybackSequencedError.authorityChanged
            }
            try await register(sessionID: sessionID, features: [PlaybackSequencedContract.feature], auth: durable,
                installationID: start.authority.installationID, attemptID: start.attemptID)
            if retire { _ = try await stop(sessionID: sessionID, position: nil, isPaused: true) }
        } else if wire.outcome != "adaptation_unavailable" { throw PlaybackSequencedError.invalidResponse }
        // A known session is now independently journaled, even if local plan
        // projection fails. Explicit retry resolves uncertainty without autoplay.
        try await store.acknowledgeStart(start.id, authority: start.authority, response: data, finished: true)
        completedStarts.insert(start.id)
        unresolvedStarts.removeValue(forKey: start.id)
        await PlaybackStopNotices.shared.setPending(start.id, false)
        do { return try wire.legacy() }
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
            _ = try await currentAuth(authority)
            for start in try await pendingStarts(authority) {
                guard !completedStarts.contains(start.id) else { continue }
                unresolvedStarts[start.id] = start
                await PlaybackStopNotices.shared.setPending(start.id, true)
                if completedStarts.contains(start.id) {
                    unresolvedStarts.removeValue(forKey: start.id)
                    await PlaybackStopNotices.shared.setPending(start.id, false)
                }
            }
            for session in try await store.pendingStops(authority: authority, afterRestart: true) {
                try await register(sessionID: session.sessionID, features: [PlaybackSequencedContract.feature], auth: auth,
                    installationID: authority.installationID)
                await PlaybackStopNotices.shared.setPending(session.id, true)
            }
        } catch { /* Unknown or changed authority remains quarantined. */ }
    }

    func usesV2(_ sessionID: String) -> Bool { contexts[sessionID]?.authority.installationID != nil }

    func handles(_ sessionID: String) -> Bool { contexts[sessionID] != nil }

    func replan(sessionID: String, request: PlaybackV3ReplanRequest) async throws -> PlaybackV3DecisionResponse {
        guard let context = contexts[sessionID], let installation = context.authority.installationID,
              context.attemptID == request.playbackAttemptId, stopIntents[context.recordID] == nil else {
            throw PlaybackSequencedError.authorityChanged
        }
        guard ["seek_reanchor", "seek_failure_recovery", "failure_recovery"].contains(request.operation) else {
            throw PlaybackV3TerminalFailure(reason: "capability_unsupported",
                message: "This server does not support changing playback tracks, quality or output during API v2 playback.", retryable: false)
        }
        let auth = try await currentAuth(context.authority)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(APIv2PlaybackReplanBody(installationID: installation, request: request))
        let saved = try await store.prepareReplan(sessionID: sessionID, authority: context.authority,
            requestID: request.replanRequestId, body: body)
        _ = try await currentAuth(context.authority)
        guard stopIntents[context.recordID] == nil else { throw PlaybackSequencedError.invalidSession }
        let raw = try await api.v2.playbackRequest(method: "POST", suffix: "/\(sessionID)/replan", body: saved.body, auth: auth)
        guard raw.statusCode == 200 else { throw PlaybackSequencedError.invalidResponse }
        _ = try await currentAuth(context.authority)
        let wire = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackDecision.self, from: raw.data)
        guard (wire.sessionId ?? wire.playbackPlan?.sessionId) == sessionID else { throw PlaybackSequencedError.invalidResponse }
        let response = try wire.legacy()
        try await store.acknowledgeReplan(saved, response: raw.data)
        guard stopIntents[context.recordID] == nil else { throw PlaybackSequencedError.invalidSession }
        return response
    }

    /// Diagnostics have one dispatch and never drive a playback mutation retry.
    func reportRouteEvent(_ event: PlaybackV3RouteEvent) async throws {
        guard let sessionID = event.sessionId, let context = contexts[sessionID],
              context.attemptID == event.playbackAttemptId, let installation = context.authority.installationID else {
            throw PlaybackSequencedError.authorityChanged
        }
        let auth = try await currentAuth(context.authority)
        let eventID = UUID().uuidString.lowercased()
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let body = try encoder.encode(APIv2PlaybackRouteEventBody(installationID: installation, eventID: eventID, event: event))
        let raw = try await api.v2.playbackRequest(method: "POST", suffix: "/route-events", body: body, auth: auth)
        _ = try await currentAuth(context.authority)
        let receipt = try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackRouteEventReceipt.self, from: raw.data)
        guard raw.statusCode == 202, receipt.eventId == eventID, receipt.outcome == "accepted" else {
            throw PlaybackSequencedError.invalidResponse
        }
    }

    struct ControlBinding: Sendable {
        let sessionID: String
        let authority: PlaybackMutationAuthority
        let auth: CapturedOrdinaryRequestAuth
    }

    func controlBinding(sessionID: String) async throws -> ControlBinding {
        guard let context = contexts[sessionID], context.authority.installationID != nil,
              stopIntents[context.recordID] == nil else { throw PlaybackSequencedError.invalidSession }
        let auth = try await currentAuth(context.authority)
        let binding = ControlBinding(sessionID: sessionID, authority: context.authority, auth: auth)
        try await validateControlBinding(binding)
        return binding
    }

    func validateControlBinding(_ binding: ControlBinding) async throws {
        guard let context = contexts[binding.sessionID], context.authority == binding.authority,
              stopIntents[context.recordID] == nil else { throw PlaybackSequencedError.invalidSession }
        _ = try await currentAuth(binding.authority)
        guard await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: binding.auth) != nil,
              stopIntents[context.recordID] == nil else { throw PlaybackSequencedError.authorityChanged }
    }

    /// Media resolution shares the durable session fence with control. It must
    /// never pick a server or credential from a later account selection.
    func streamRequest(sessionID: String, rawURL: String, additionalHeaders: [String: String],
                       requiresHeaderAuthenticatedMedia: Bool,
                       allowsAuthorizedMediaOrigins: Bool = false) async throws -> StreamRequest {
        let binding = try await controlBinding(sessionID: sessionID)
        guard let request = StreamRequest.resolve(rawURL: rawURL,
            serverURL: binding.auth.account.serverURL, additionalHeaders: additionalHeaders,
            accessToken: binding.auth.accessToken,
            requiresHeaderAuthenticatedMedia: requiresHeaderAuthenticatedMedia,
            authorizedMediaOriginSessionId: allowsAuthorizedMediaOrigins ? sessionID : nil,
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

    private func currentAuth(_ authority: PlaybackMutationAuthority) async throws -> CapturedOrdinaryRequestAuth {
        guard let current = await tokens.captureDurableAccountAuth(),
              try PlaybackMutationAuthority(auth: current, installationID: authority.installationID) == authority else {
            throw PlaybackSequencedError.authorityChanged
        }
        if let installation = authority.installationID {
            let capability = try await api.v2.playbackCapabilities(auth: current.request)
            guard try capability.requireAvailable() == installation else { throw PlaybackSequencedError.authorityChanged }
            guard let after = await tokens.captureDurableAccountAuth(),
                  try PlaybackMutationAuthority(auth: after, installationID: installation) == authority else {
                throw PlaybackSequencedError.authorityChanged
            }
        }
        return current.request
    }

    func report(sessionID: String, position: Double, isPaused: Bool) async throws {
        guard let context = contexts[sessionID] else { throw PlaybackSequencedError.invalidSession }
        guard stopIntents[context.recordID] == nil else { throw PlaybackSequencedError.invalidSession }
        let auth = try await currentAuth(context.authority)
        guard stopIntents[context.recordID] == nil else { throw PlaybackSequencedError.invalidSession }
        let sample = try await store.prepareProgress(context.recordID, authority: context.authority,
            position: position, isPaused: isPaused)
        let receipt = try await api.reportSequencedPlaybackProgress(sessionID: sessionID, sample: sample, auth: auth, installationID: context.authority.installationID)
        _ = try await currentAuth(context.authority)
        try await store.acknowledgeProgress(context.recordID, authority: context.authority, sent: sample, receipt: receipt)
    }

    @discardableResult
    func stop(sessionID: String, position: Double?, isPaused: Bool) async throws -> Bool {
        guard let context = contexts[sessionID] else { throw PlaybackSequencedError.invalidSession }
        if stopIntents[context.recordID] == nil {
            stopIntents[context.recordID] = StopIntent(position: position, isPaused: isPaused)
        }
        guard draining.insert(context.recordID).inserted else { return false }
        defer { draining.remove(context.recordID) }
        await PlaybackStopNotices.shared.setPending(context.recordID, true)
        var intent = stopIntents[context.recordID]!
        if intent.proposed == nil {
            intent.proposed = try await store.proposedStop(context.recordID, authority: context.authority,
                position: intent.position, isPaused: intent.isPaused)
            stopIntents[context.recordID] = intent
        }
        // Keep the exact UUID and sample if durable publication fails. No request
        // may leave this coordinator until that same intent is persisted.
        let stop = try await store.persistStop(context.recordID, authority: context.authority, stop: intent.proposed!)
        let saved = try await store.session(context.recordID, authority: context.authority)
        if saved.stopState == .terminal {
            await PlaybackStopNotices.shared.setPending(context.recordID, false)
            return true
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        for attempt in 0...retryDelays.count {
            do {
                try Task.checkCancellation()
                let auth = try await currentAuth(context.authority)
                let receipt = try await api.stopSequencedPlayback(sessionID: context.sessionID, stop: stop, auth: auth, installationID: context.authority.installationID)
                _ = try await currentAuth(context.authority)
                try await store.acknowledgeStop(context.recordID, authority: context.authority, sent: stop, receipt: receipt)
                if receipt.outcome != .draining {
                    await PlaybackStopNotices.shared.setPending(context.recordID, false)
                    return true
                }
            } catch PlaybackSequencedError.authorityChanged { return false }
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
    /// loaded into this context map automatically after process restart.
    func retryPendingStops() async {
        var justResolved: Set<String> = []
        for start in Array(unresolvedStarts.values) {
            if let response = try? await resolveStart(start, retire: true),
               let id = response.sessionId ?? response.playbackPlan?.sessionId { justResolved.insert(id) }
        }
        for context in Array(contexts.values) {
            guard !justResolved.contains(context.sessionID) else { continue }
            if stopIntents[context.recordID] != nil {
                _ = try? await stop(sessionID: context.sessionID, position: nil, isPaused: true)
                continue
            }
            guard let session = try? await store.session(context.recordID, authority: context.authority),
                  session.stop != nil, session.stopState != .terminal else { continue }
            _ = try? await stop(sessionID: context.sessionID, position: nil, isPaused: true)
        }
    }
}
