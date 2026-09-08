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
    private struct AuxiliaryPlanAuthority {
        let id: UUID
        let plan: PlaybackV3Plan
        let auth: CapturedOrdinaryRequestAuth
        let allowsAuthorizedOrigins: Bool
        var scope: ProxyAuxiliaryScope?
    }
    /// Memory only. A restored durable response cannot recreate these credentials.
    private var originalStartAuth: [UUID: CapturedOrdinaryRequestAuth] = [:]
    private var auxiliaryPlans: [String: AuxiliaryPlanAuthority] = [:]
    private var auxiliaryAdoptions: [String: UUID] = [:]
    private struct StopIntent {
        let position: Double?
        let isPaused: Bool
        var proposed: PlaybackSequencedStop?
    }
    private var stopIntents: [UUID: StopIntent] = [:]
    private var draining: Set<UUID> = []
    private var restoredBoundSessions: Set<UUID> = []

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
                  installationID: String? = nil, attemptID: String? = nil, progressTimeline: APIv2ProgressTimeline? = nil) async throws {
        guard features.contains(PlaybackSequencedContract.feature) else { return }
        let authority = try PlaybackMutationAuthority(auth: auth, installationID: installationID)
        _ = try await currentAuth(authority)
        let saved = try await store.register(sessionID: sessionID, authority: authority, progressTimeline: progressTimeline, attemptID: attemptID)
        _ = try await currentAuth(authority)
        // A bare server session ID must never retarget an older bridge's
        // delayed callback to another account/profile/origin in this process.
        if let existing = contexts[sessionID], existing.authority != authority {
            throw PlaybackSequencedError.authorityChanged
        }
        contexts[sessionID] = Context(recordID: saved.id, sessionID: sessionID, authority: authority,
            attemptID: try await store.originalAttemptID(saved) ?? contexts[sessionID]?.attemptID)
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

    func discoverTimeline(fileID: Int, itemID: String, auth: CapturedDurableAccountAuth,
                          capability: APIv2PlaybackCapabilities) async throws -> APIv2PlaybackManifest {
        guard capability.features.contains(APIv2PlaybackManifest.feature) else {
            throw PlaybackV3TerminalFailure(reason: "bound_timeline_unsupported",
                message: "Update the server to play audiobooks with API v2.", retryable: false)
        }
        let installation = try capability.requireAvailable()
        let authority = try PlaybackMutationAuthority(auth: auth, installationID: installation)
        let requestAuth = try await currentAuth(authority)
        let manifest = try await api.v2.playbackManifest(fileID: fileID, installationID: installation,
            itemID: itemID, auth: requestAuth)
        _ = try await currentAuth(authority)
        return manifest
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
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(APIv2PlaybackStartBody(request, installationID: installation))
        let prepared = try await store.prepareStartWithDisposition(authority: authority,
            attemptID: request.playbackAttemptId, body: body, progressTimeline: progressTimeline)
        let start = prepared.start
        if prepared.created { originalStartAuth[start.id] = auth.request }
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
        defer {
            resolvingStarts.remove(start.id)
            if completedStarts.contains(start.id) { originalStartAuth.removeValue(forKey: start.id) }
        }
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
        // Autoplay recovery can reuse only this process's original snapshot.
        // Explicit retirement may resolve uncertainty with current durable-owner
        // credentials, but cannot grant media authority from that replay.
        if !retire, let original = originalStartAuth[start.id], original != auth {
            throw PlaybackSequencedError.authorityChanged
        }
        let data: Data
        if let saved = start.response { data = saved }
        else {
            // A validation response does not prove that an earlier uncertain
            // dispatch of this attempt never allocated a session. Retain the
            // journal until an authoritative replay resolves that allocation.
            let response = try await api.v2.playbackRequest(method: "POST", suffix: "/start", body: start.body, auth: auth)
            _ = try await currentAuth(start.authority)
            if let recovery = try PlaybackOwnerLossRecovery.decode(response.data, status: response.statusCode, start: true) {
                try await store.observeStartOwnerLoss(start.id, authority: start.authority, recovery: recovery, response: response.data)
                if recovery.state == .draining { throw PlaybackSequencedError.pendingStart }
                completedStarts.insert(start.id)
                unresolvedStarts.removeValue(forKey: start.id)
                await PlaybackStopNotices.shared.setPending(start.id, false)
                // A terminal decision has no renderer/session adoption. Original
                // body and any historical response remain unchanged in the journal.
                return try HTTPClient.makeJSONDecoder().decode(APIv2PlaybackDecision.self, from: response.data).legacy()
            }
            guard start.ownerLoss == nil, response.statusCode == 201 else { throw PlaybackSequencedError.invalidResponse }
            data = response.data
            try await store.acknowledgeStart(start.id, authority: start.authority, response: data, finished: false)
        }
        _ = try await currentAuth(start.authority)
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
        completedStarts.insert(start.id)
        unresolvedStarts.removeValue(forKey: start.id)
        await PlaybackStopNotices.shared.setPending(start.id, false)
        do {
            let response = try wire.legacy()
            if let sessionID, !retire {
                let input = try JSONSerialization.jsonObject(with: start.body) as? [String: Any]
                let features = input?["client_features"] as? [String] ?? []
                try await adoptAuxiliaryAuthority(plan: response.playbackPlan, sessionID: sessionID, auth: originalStartAuth[start.id],
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
                // A live player or resolving allocation owns its session. Only
                // an abandoned bound session gets an explicit stop-recovery notice.
                if session.stop == nil {
                    guard contexts[session.sessionID] == nil, resolvingStarts.isEmpty else { continue }
                    restoredBoundSessions.insert(session.id)
                }
                try await register(sessionID: session.sessionID, features: [PlaybackSequencedContract.feature], auth: auth,
                    installationID: authority.installationID, progressTimeline: session.progressTimeline)
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
        let allowsAuthorizedOrigins = auxiliaryPlans[sessionID]?.allowsAuthorizedOrigins ?? false
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
        try await adoptAuxiliaryAuthority(plan: response.playbackPlan, sessionID: sessionID, auth: auth,
            allowsAuthorizedOrigins: allowsAuthorizedOrigins)
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
        if let captured = auxiliaryPlans[sessionID] {
            guard !allowsAuthorizedMediaOrigins || captured.allowsAuthorizedOrigins else { throw PlaybackSequencedError.invalidSession }
            guard captured.plan.stream.url == rawURL else { throw PlaybackSequencedError.invalidSession }
            guard await auxiliaryAuthorityIsCurrent(sessionID: sessionID, planID: captured.plan.planId,
                    auth: captured.auth, bindingID: captured.id) else {
                captured.scope?.invalidate()
                throw PlaybackSequencedError.authorityChanged
            }
            // Join the immutable wire plan only with the original request authority.
            guard var request = StreamRequest.resolve(rawURL: rawURL,
                serverURL: captured.auth.account.serverURL,
                additionalHeaders: ["X-Profile-Id": captured.auth.profileId ?? ""],
                accessToken: captured.auth.accessToken,
                requiresHeaderAuthenticatedMedia: requiresHeaderAuthenticatedMedia,
                authorizedMediaOriginSessionId: allowsAuthorizedMediaOrigins ? sessionID : nil,
                apiV2SessionId: sessionID) else { throw PlaybackSequencedError.invalidSession }
            guard var current = auxiliaryPlans[sessionID], current.id == captured.id else {
                throw PlaybackSequencedError.authorityChanged
            }
            if allowsAuthorizedMediaOrigins || StreamRequest.isHeaderAuthenticatedAPIPrimary(rawURL, sessionID: sessionID) {
                if current.scope == nil {
                    let planID = captured.plan.planId
                    let auth = captured.auth
                    let bindingID = captured.id
                    current.scope = try ProxyAuxiliaryScope(plan: captured.plan, sessionID: sessionID,
                        sourceURL: request.url, auth: auth, tokens: tokens) { [weak self] in
                        await self?.auxiliaryAuthorityIsCurrent(sessionID: sessionID, planID: planID,
                            auth: auth, bindingID: bindingID) ?? false
                    }
                    guard auxiliaryPlans[sessionID]?.id == captured.id else {
                        current.scope?.invalidate()
                        throw PlaybackSequencedError.authorityChanged
                    }
                    auxiliaryPlans[sessionID] = current
                }
                request.proxyAuxiliaryScope = current.scope
            }
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

    /// Called only with the response to the captured request that adopted the
    /// plan. Durable response bytes are neither decorated nor re-encoded.
    func adoptAuxiliaryAuthority(plan: PlaybackV3Plan?, sessionID: String,
                                auth: CapturedOrdinaryRequestAuth?, allowsAuthorizedOrigins: Bool = false) async throws {
        let adoption = UUID()
        auxiliaryAdoptions[sessionID] = adoption
        auxiliaryPlans.removeValue(forKey: sessionID)?.scope?.invalidate()
        guard let plan else { return }
        let primaryPath = URLComponents(string: plan.stream.url)?.percentEncodedPath ?? ""
        let headerPrimary = StreamRequest.isHeaderAuthenticatedAPIPrimary(plan.stream.url, sessionID: sessionID)
            || StreamRequest.isAllowedAuthorizedMediaOriginPath(primaryPath, sessionId: sessionID)
        let auxiliaryURLs = [plan.subtitle.artifact?.url] + plan.subtitle.inventory.flatMap { [$0.url, $0.fontBundleUrl] }
        guard headerPrimary || auxiliaryURLs.compactMap({ $0 }).contains(where: StreamRequest.isHeaderAuthenticatedAuxiliaryURL) else { return }
        guard let auth else { throw PlaybackSequencedError.authorityChanged }
        try ApplePlaybackV3PlanAdapter.validate(plan)
        guard plan.stream.headers.allSatisfy({ key, value in
            key.caseInsensitiveCompare("X-Profile-Id") != .orderedSame || value == auth.profileId
        }) else { throw PlaybackSequencedError.authorityChanged }
        guard let context = contexts[sessionID], stopIntents[context.recordID] == nil,
              auth.profileId == context.authority.profileID,
              auth.account.serverId == context.authority.serverID,
              auth.account.serverURL == context.authority.origin,
              let owner = await tokens.captureDurableAccountAuth(), owner.request == auth,
              try PlaybackMutationAuthority(auth: owner, installationID: context.authority.installationID) == context.authority,
              contexts[sessionID]?.recordID == context.recordID,
              stopIntents[context.recordID] == nil,
              await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) == auth,
              contexts[sessionID]?.recordID == context.recordID,
              stopIntents[context.recordID] == nil,
              auxiliaryAdoptions[sessionID] == adoption else {
            throw PlaybackSequencedError.authorityChanged
        }
        auxiliaryPlans[sessionID] = AuxiliaryPlanAuthority(id: adoption, plan: plan, auth: auth, allowsAuthorizedOrigins: allowsAuthorizedOrigins)
    }

    private func auxiliaryAuthorityIsCurrent(sessionID: String, planID: String,
                                            auth: CapturedOrdinaryRequestAuth, bindingID: UUID) async -> Bool {
        guard let context = contexts[sessionID], stopIntents[context.recordID] == nil,
              let captured = auxiliaryPlans[sessionID], captured.id == bindingID, captured.plan.planId == planID, captured.auth == auth,
              await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) == auth,
              auxiliaryPlans[sessionID]?.id == bindingID,
              stopIntents[context.recordID] == nil else { return false }
        return true
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
        auxiliaryAdoptions[sessionID] = UUID()
        auxiliaryPlans.removeValue(forKey: sessionID)?.scope?.invalidate()
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
        if saved.stopState.isTerminal {
            await PlaybackStopNotices.shared.setPending(context.recordID, false)
            if saved.stopState == .abandoned { throw PlaybackOwnerLossRecovery.terminalFailure }
            return true
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        for attempt in 0...retryDelays.count {
            do {
                try Task.checkCancellation()
                let auth = try await currentAuth(context.authority)
                let resolution = try await api.resolveSequencedPlaybackStop(sessionID: context.sessionID, stop: stop,
                    auth: auth, installationID: context.authority.installationID)
                _ = try await currentAuth(context.authority)
                switch resolution {
                case .ordinary(let receipt):
                    try await store.acknowledgeStop(context.recordID, authority: context.authority, sent: stop, receipt: receipt)
                    if receipt.outcome != .draining {
                        await PlaybackStopNotices.shared.setPending(context.recordID, false)
                        return true
                    }
                case .ownerLost(let recovery, let response):
                    try await store.observeStopOwnerLoss(context.recordID, authority: context.authority, sent: stop,
                        recovery: recovery, response: response)
                    if recovery.state == .aborted {
                        await PlaybackStopNotices.shared.setPending(context.recordID, false)
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
    /// loaded into this context map automatically after process restart.
    func retryPendingStops() async {
        var justResolved: Set<String> = []
        for start in Array(unresolvedStarts.values) {
            if let response = try? await resolveStart(start, retire: true),
               let id = response.sessionId ?? response.playbackPlan?.sessionId { justResolved.insert(id) }
        }
        for context in Array(contexts.values) {
            guard !justResolved.contains(context.sessionID) else { continue }
            if stopIntents[context.recordID] != nil || restoredBoundSessions.contains(context.recordID) {
                _ = try? await stop(sessionID: context.sessionID, position: nil, isPaused: true)
                continue
            }
            guard let session = try? await store.session(context.recordID, authority: context.authority),
                  session.stop != nil, !session.stopState.isTerminal else { continue }
            _ = try? await stop(sessionID: context.sessionID, position: nil, isPaused: true)
        }
    }
}
