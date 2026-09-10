import Foundation
import OSLog
#if os(tvOS)
import TVServices
#endif

enum PlaybackSessionStopResolution: Equatable, Sendable {
    case noSession, closed, pending, ownerLost
}

enum PlaybackProgressReportResult: Equatable {
    case success
    case missingSession
    case transientFailure
}

struct PlaybackV3TerminalFailure: LocalizedError, Equatable {
    let reason: String
    let message: String
    let retryable: Bool

    var errorDescription: String? { message }
}

/// One capability probe per active server, shared by video and audiobook
/// playback. The Aether-only client requires both the neutral plan contract and
/// credential-free, header-authenticated media transport before it can expose
/// a source URL to the engine. Keeping the in-flight task in the cache prevents
/// two player models starting together from issuing duplicate probes.
actor PlaybackV3CapabilityGate {
    static let shared = PlaybackV3CapabilityGate()

    /// What the active server advertises, as far as this client's contract
    /// cares. `authorizedMediaOrigins` is optional and only informs which
    /// feature tokens a start request may negotiate.
    struct NeutralProtocolV3Capability: Equatable {
        let supported: Bool
        let authorizedMediaOrigins: Bool

        static let unsupported = NeutralProtocolV3Capability(
            supported: false,
            authorizedMediaOrigins: false
        )
    }

    private var availabilityByServerId: [String: NeutralProtocolV3Capability] = [:]
    private var probeByServerId: [String: Task<NeutralProtocolV3Capability, Error>] = [:]

    @discardableResult
    func requireNeutralProtocolV3() async throws -> NeutralProtocolV3Capability {
        let serverId = await TokenStore.shared.getActiveServerId()
        let available: NeutralProtocolV3Capability
        if let cached = availabilityByServerId[serverId] {
            available = cached
        } else {
            let probe: Task<NeutralProtocolV3Capability, Error>
            if let pending = probeByServerId[serverId] {
                probe = pending
            } else {
                probe = Task {
                    do {
                        let capability = try await SiloAPI.shared.playbackV3Capability()
                        return NeutralProtocolV3Capability(
                            supported: PlaybackSessionBridge.supportsNeutralProtocolV3(capability),
                            authorizedMediaOrigins: capability.features.contains(
                                PlaybackProtocolV3.authorizedMediaOriginsFeature
                            )
                        )
                    } catch {
                        if PlaybackSessionBridge.isMissingProtocolV3Capability(error) {
                            return .unsupported
                        }
                        throw error
                    }
                }
                probeByServerId[serverId] = probe
            }
            do {
                available = try await probe.value
                // A positive capability is stable for the lifetime of this
                // process. A negative result may only mean that a rolling
                // server upgrade or proxy repair has not reached this client
                // yet, so allow the next Play attempt to probe again instead
                // of requiring an app relaunch.
                if available.supported {
                    availabilityByServerId[serverId] = available
                }
                probeByServerId[serverId] = nil
            } catch {
                probeByServerId[serverId] = nil
                throw error
            }
        }

        guard available.supported else {
            throw PlaybackV3TerminalFailure(
                reason: "server_upgrade_required",
                message: "Your Silo server hasn't been updated to support the latest version of this app. Please update your server, or downgrade the TestFlight app version until the server has been updated.",
                retryable: false
            )
        }
        return available
    }
}

/// Owns the server playback-session lifecycle and Protocol V3 contract state.
/// Capability reporting must stay aligned with what the active AetherEngine
/// boundary can actually execute.
actor PlaybackSessionBridge {
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Playback"
    )

    /// Dedups the whole retirement — final progress report, DELETE, and the
    /// shared resolution a second caller awaits — for ordinary non-v2 sessions
    /// too; the coordinator's `draining` set only dedups the v2 stop request.
    private var retiringSession: Task<PlaybackSessionStopResolution, Never>?
    private let mutationCoordinator: PlaybackMutationCoordinator
    private let api: SiloAPI
    private let tokens: TokenStore

    init(mutationCoordinator: PlaybackMutationCoordinator = .shared, api: SiloAPI = .shared, tokens: TokenStore = .shared) {
        self.mutationCoordinator = mutationCoordinator
        self.api = api
        self.tokens = tokens
    }
    /// Session, plan, and two-phase route-transition state. The bridge owns
    /// the side effects each mutation reports back; it owns no copy of them.
    private var transition = ProtocolV3Transition()
    private var protocolV3FirstFramePlanIds: Set<String> = []

    private func isCurrentProtocolV3Attempt(
        _ expected: ProtocolV3AttemptIdentity,
        sessionId expectedSessionId: String
    ) -> Bool {
        !Task.isCancelled && transition.matchesAttempt(expected, sessionId: expectedSessionId)
    }

    private func discardStaleProtocolV3Response(
        _ response: PlaybackV3DecisionValidation
    ) {
        let allocatedSessionId: String?
        switch response {
        case .playable(_, let responseSessionId):
            allocatedSessionId = responseSessionId
        case .incompatible(let responseSessionId):
            allocatedSessionId = responseSessionId
        case .terminal:
            allocatedSessionId = nil
        }
        guard let allocatedSessionId, allocatedSessionId != transition.sessionId else { return }
        stopStaleSession(allocatedSessionId)
    }

    /// Cleanup must outlive the cancelled request that produced the stale
    /// response. An unstructured task intentionally does not inherit its
    /// caller's cancellation; failure remains best-effort and server timeout is
    /// the final fallback.
    private func stopStaleSession(_ staleSessionId: String) {
        Task {
            await self.retireAbandonedSession(staleSessionId, reason: "stale_allocation")
        }
    }

    /// The coordinator records the binding — or the registration failure — so
    /// the bridge keeps no parallel view of which sessions are sequenced.
    private func registerSequencedAllocation(_ response: PlaybackV3DecisionResponse,
                                             auth: CapturedDurableAccountAuth?) async throws {
        guard let id = Self.allocatedSessionId(in: response) else { return }
        guard await mutationCoordinator.sequencedState(id) != .bound else { return }
        try await mutationCoordinator.register(sessionID: id, features: response.serverFeatures, auth: auth)
    }

    /// Retires a server session this client allocated but will never execute.
    ///
    /// Recovery is impossible here — the server reclaims idle sessions on its
    /// own — but a failure still costs the user a lingering session slot, so it
    /// is logged rather than swallowed. The DELETE in `stopSession` has always
    /// logged; these paths used a bare `try?` and were silent.
    func retireAbandonedSession(
        _ abandonedSessionId: String,
        reason: String
    ) async {
        do {
            switch await mutationCoordinator.sequencedState(abandonedSessionId) {
            case .bound:
                _ = try await mutationCoordinator.stop(sessionID: abandonedSessionId, position: nil, isPaused: true)
                return
            case .registrationFailed:
                // A sequenced allocation this process never bound has no durable
                // stop intent, and a plain DELETE would discard the server's stop
                // contract for it. Fail closed and let the idle timeout reclaim it.
                throw PlaybackSequencedError.authorityChanged
            case .notSequenced:
                try await api.stopPlayback(sessionId: abandonedSessionId)
            }
        } catch {
            logger.error(
                "abandoned-session stop failed for \(abandonedSessionId, privacy: .public) (\(reason, privacy: .public)); server-side session may linger until idle timeout: \(MediaLogRedactor.sanitize(error), privacy: .public)"
            )
        }
    }

    /// The attempt a terminal route event names. There is none before a start
    /// succeeds, so a failed start reports no event.
    private struct ProtocolV3TerminalReport {
        let active: ActiveProtocolV3
        let sessionId: String
    }

    /// The dead end shared by start and replan: retire the session this client
    /// will never execute, report the terminal route event, then hand the
    /// caller the failure to throw. The order is load-bearing — the abandoned
    /// session is released before the event that explains why, and the throw
    /// happens last, in the caller.
    ///
    /// `retiring` is nil when the response allocated nothing or when the
    /// allocation is the session still in use. `retireReason` defaults to
    /// `reason`; the two differ wherever the server-facing stop reason names
    /// the response that was rejected rather than the failure it produced.
    @discardableResult
    private func failProtocolV3Attempt(
        reason: String,
        message: String,
        retryable: Bool = false,
        retiring retiredSessionId: String?,
        retireReason: String? = nil,
        reporting report: ProtocolV3TerminalReport? = nil
    ) async -> PlaybackV3TerminalFailure {
        if let retiredSessionId {
            await retireAbandonedSession(retiredSessionId, reason: retireReason ?? reason)
        }
        if let report {
            await emitProtocolV3Terminal(
                active: report.active,
                sessionId: report.sessionId,
                reason: reason,
                message: message
            )
        }
        return PlaybackV3TerminalFailure(reason: reason, message: message, retryable: retryable)
    }

    /// Performs the server-facing work a transition mutation reported: retire
    /// the session nothing owns any more, then emit the commit's route event.
    private func apply(_ outcome: ProtocolV3Transition.Outcome) {
        if let retiredSessionId = outcome.retireSessionId {
            stopStaleSession(retiredSessionId)
        }
        guard let commit = outcome.commitEvent else { return }
        // Route telemetry is best-effort and must not make this actor
        // reentrant between committing the candidate and returning the
        // result to its owner. Teardown or a newer load may otherwise run
        // during the HTTP await and then be followed by stale VM work.
        Task {
            await emitProtocolV3Event(
                active: commit.active,
                sessionId: commit.sessionId,
                event: commit.event,
                classification: nil,
                fallbackReason: nil,
                diagnostics: commit.diagnostics
            )
        }
    }

    /// Commits the server decision only after Aether's load epoch commits.
    /// Returns false when a newer transition or teardown already won.
    func commitPendingProtocolV3Transition(_ prepared: PreparedPlayback) -> Bool {
        guard let outcome = transition.commit(prepared) else { return false }
        apply(outcome)
        return true
    }

    /// See `ProtocolV3Transition.promoteForRecovery`: this reports the exact
    /// failed candidate as the current attempt without committing execution.
    func promotePendingProtocolV3TransitionForRecovery(
        _ prepared: PreparedPlayback
    ) -> Bool {
        guard let outcome = transition.promoteForRecovery(prepared) else { return false }
        apply(outcome)
        return true
    }

    /// See `ProtocolV3Transition.rollback`.
    func rollbackPendingProtocolV3Transition(_ prepared: PreparedPlayback) {
        apply(transition.rollback(prepared))
    }

    /// See `ProtocolV3Transition.committedSession`.
    func committedProtocolV3Session(
        planId expectedPlanId: String,
        sessionId expectedSessionId: String
    ) -> PlaybackSessionResponse? {
        transition.committedSession(planId: expectedPlanId, sessionId: expectedSessionId)
    }

    /// Stages a server-issued candidate and makes it the bridge's current
    /// attempt. The candidate stays provisional until the owning player proves
    /// Aether accepted the matching source.
    private func adopt(
        active: ActiveProtocolV3,
        session: PlaybackSessionResponse,
        commitEvent: String? = nil,
        commitDiagnostics: [String: String] = [:]
    ) {
        apply(transition.stage(
            candidateSessionId: session.sessionId,
            candidatePlanId: active.plan.planId,
            commitEvent: commitEvent,
            commitDiagnostics: commitDiagnostics
        ))
        transition.adopt(active: active, session: session)
        retiringSession = nil
        consecutiveProgressFailures = 0
        #if os(iOS) || os(tvOS)
        // Only record the session id for later diagnostics bundling when
        // diagnostics is actually collecting for the active binding. Recording
        // unconditionally would accumulate playback identifiers from periods
        // where capture is off (Crash Reports = Never, or a disabled/
        // storage-unavailable status) that could then surface in a later manual
        // report or after diagnostics is re-enabled. The breadcrumb below is
        // already gated by the same signal inside the journal.
        if DiagnosticsCoordinator.isDiagnosticsCaptureEnabled {
            RecentSessionTracker.shared.record(sessionID: session.sessionId)
        }
        DiagnosticsCoordinator.recordBreadcrumb(
            category: .playback,
            tag: "PlaybackSession",
            message: "playback session adopted",
            attrs: [
                "session_id": .string(session.sessionId),
                "play_method": .string(session.playMethod),
            ]
        )
        #endif
    }

    // MARK: - Start Session

    func startSession(
        contentId: String,
        preferredFileId: Int? = nil,
        preferredAudioTrackIndex: Int? = nil,
        preferredSubtitleTrackIndex: Int? = nil,
        preferredProtocolV3SubtitleIndex: Int? = nil,
        initialSubtitlePreferences: PlaybackContentSelection.InitialProtocolV3SubtitlePreferences? = nil,
        startFromBeginning: Bool,
        resumePosition: Double? = nil,
        allowNearEndResume: Bool = false,
        prefersLastUsedVersion: Bool = false,
        preferredQualityOverride: String? = nil
    ) async throws -> PreparedPlayback {
        logger.info("Fetching watch detail for \(contentId, privacy: .public)")
        let watchDetail = try await api.watchDetail(contentId: contentId)
        logger.info("Got \(watchDetail.versions.count) versions, type=\(watchDetail.type, privacy: .public)")

        guard !watchDetail.versions.isEmpty else {
            throw APIError.httpError(statusCode: 404)
        }

        let playerSettings = PlayerSettings.shared
        let selection = PlaybackContentSelection.resolve(
            watchDetail: watchDetail,
            preferredFileId: preferredFileId,
            preferredAudioTrackIndex: preferredAudioTrackIndex,
            preferredSubtitleTrackIndex: preferredSubtitleTrackIndex,
            preferredProtocolV3SubtitleIndex: preferredProtocolV3SubtitleIndex,
            initialSubtitlePreferences: initialSubtitlePreferences,
            startFromBeginning: startFromBeginning,
            resumePosition: resumePosition,
            allowNearEndResume: allowNearEndResume,
            prefersLastUsedVersion: prefersLastUsedVersion,
            preferredQualityOverride: preferredQualityOverride,
            settingsPreferredQuality: playerSettings.preferredQuality,
            settingsMaxBitrateKbps: playerSettings.maxBitrateKbps
        )
        let profileId = await tokens.getProfileId()
        guard let profileId,
              !profileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PlaybackV3TerminalFailure(
                reason: "profile_required",
                message: "Select a profile before starting playback.",
                retryable: false
            )
        }
        // Protocol v3 is the only playback contract. There is no legacy start
        // path to fall back to — `/api/v1/playback/start` rejects any body
        // whose `protocol_version` is not 3.
        let staged = try await stageProtocolV3Start(
            watchDetail: watchDetail,
            selection: selection,
            profileId: profileId
        )
        return adoptProtocolV3Start(staged, watchDetail: watchDetail)
    }

    /// The session a start/replan decision allocated, if any. A terminal
    /// outcome allocates nothing; both a playable plan and a structurally
    /// incompatible one can carry a live session that needs retiring.
    static func allocatedSessionId(in response: PlaybackV3DecisionResponse) -> String? {
        switch response.validatedForApple() {
        case .playable(_, let allocated):
            return allocated
        case .incompatible(let allocated):
            return allocated
        case .terminal:
            return nil
        }
    }

    private func stageProtocolV3Start(
        watchDetail: WatchDetail,
        selection: PlaybackContentSelection.Start,
        profileId: String
    ) async throws -> StagedProtocolV3Start {
        let startAuth = try await mutationCoordinator.captureStartAuth()
        let capturedPlaybackAuth = startAuth.durable
        let requestsAuthorizedMediaOrigins = startAuth.capability.features.contains(
            PlaybackProtocolV3.authorizedMediaOriginsFeature)

        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        cmpLog("[CMP-OUTPUT] phase=start \(snapshot.outputDiagnosticsLogFields)")
        let playbackAttemptId = "apple:\(UUID().uuidString.lowercased())"
        let request = Self.startRequest(
            selection: selection,
            profileId: profileId,
            playbackAttemptId: playbackAttemptId,
            snapshot: snapshot,
            authorizedMediaOrigins: requestsAuthorizedMediaOrigins
        )

        logger.info(
            "Starting protocol V3 attempt=\(playbackAttemptId, privacy: .public) fileId=\(selection.selectedVersion.fileId, privacy: .public)"
        )
        // Callers cancel this task on the autoplay start timeout and on player
        // dismissal. The POST allocates a server session, so cancelling it
        // mid-flight used to leave that session stranded until the server's idle
        // timeout. Shield the request from cancellation and retire whatever it
        // allocated if the caller has already walked away.
        let response = try await PlaybackCancellationShield.run {
            try await self.mutationCoordinator.startV2(request: request,
                auth: capturedPlaybackAuth, capability: startAuth.capability)
        } reclaim: { [self] abandoned in
            guard let orphaned = Self.allocatedSessionId(in: abandoned) else { return }
            try? await registerSequencedAllocation(abandoned, auth: capturedPlaybackAuth)
            await retireAbandonedSession(orphaned, reason: "cancelled_start")
        }

        try await registerSequencedAllocation(response, auth: capturedPlaybackAuth)
        return try await adoptableStart(
            response,
            watchDetail: watchDetail,
            playbackAttemptId: playbackAttemptId,
            qualityPreference: selection.qualityPreference,
            bandwidthCapKbps: selection.bandwidthCapKbps,
            snapshot: snapshot,
            requestsAuthorizedMediaOrigins: requestsAuthorizedMediaOrigins
        )
    }

    private static func startRequest(
        selection: PlaybackContentSelection.Start,
        profileId: String,
        playbackAttemptId: String,
        snapshot: ApplePlaybackV3CapabilitySnapshot,
        authorizedMediaOrigins: Bool
    ) -> PlaybackV3StartRequest {
        let fileId = selection.selectedVersion.fileId
        let subtitleCombinedIndex = selection.subtitleCombinedIndex
            ?? selection.subtitleTrackIndex.flatMap {
                ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                    ffmpegStreamIndex: $0,
                    in: selection.selectedVersion
                )
            }
        return PlaybackV3StartRequest(
            protocolVersion: PlaybackProtocolV3.version,
            clientFeatures: ApplePlaybackV3Capabilities.startFeatures(
                authorizedMediaOrigins: authorizedMediaOrigins
            ),
            fileId: fileId,
            profileId: profileId,
            playbackAttemptId: playbackAttemptId,
            qualityPreference: PlaybackContentSelection.protocolV3QualityPreference(
                selection.qualityPreference
            ),
            subtitleFidelityPreference: "preserve",
            progressPersistence: nil,
            startPosition: selection.startPosition,
            audioTrackId: selection.audioTrackIndex.flatMap {
                $0 >= 0 ? PlaybackContentSelection.protocolV3TrackId(
                    fileId: fileId, kind: "audio", index: $0) : nil
            },
            audioTrackIndex: selection.audioTrackIndex.flatMap { $0 >= 0 ? $0 : nil },
            subtitleTrackId: subtitleCombinedIndex.flatMap {
                $0 >= 0 ? PlaybackContentSelection.protocolV3TrackId(
                    fileId: fileId, kind: "subtitle", index: $0) : nil
            },
            subtitleTrackIndex: subtitleCombinedIndex,
            metered: false,
            bandwidthEstimateKbps: nil,
            bandwidthCapKbps: selection.bandwidthCapKbps,
            clientCapabilities: snapshot.capabilities,
            clientPlaybackContext: snapshot.context
        )
    }

    /// Validates a start response into the state a start can adopt, retiring
    /// and reporting whatever this client cannot execute.
    private func adoptableStart(
        _ response: PlaybackV3DecisionResponse,
        watchDetail: WatchDetail,
        playbackAttemptId: String,
        qualityPreference: String?,
        bandwidthCapKbps: Int?,
        snapshot: ApplePlaybackV3CapabilitySnapshot,
        requestsAuthorizedMediaOrigins: Bool
    ) async throws -> StagedProtocolV3Start {
        switch response.validatedForApple() {
        case .terminal(let terminal):
            throw PlaybackV3TerminalFailure(
                reason: terminal.reason,
                message: terminal.message,
                retryable: terminal.retryable
            )
        case .incompatible(let allocatedSessionId):
            throw await failProtocolV3Attempt(
                reason: "invalid_playback_plan",
                message: "The server returned an incompatible protocol V3 playback plan.",
                retiring: allocatedSessionId,
                retireReason: "incompatible_start_response"
            )
        case .playable(let plan, let resolvedSessionId):
            guard response.serverFeatures.contains(
                PlaybackProtocolV3.headerAuthenticatedMediaFeature
            ) else {
                throw await failProtocolV3Attempt(
                    reason: "server_upgrade_required",
                    message: "This server did not honor authenticated media transport for the playback plan.",
                    retiring: resolvedSessionId,
                    retireReason: "start_without_header_authenticated_media"
                )
            }
            do {
                try ApplePlaybackV3PlanAdapter.validate(plan)
            } catch {
                await retireAbandonedSession(
                    resolvedSessionId,
                    reason: "unexecutable_start_plan"
                )
                throw error
            }
            guard let effectiveVersion = watchDetail.versions.first(where: {
                $0.fileId == plan.effectiveMediaFileId
            }) else {
                throw await failProtocolV3Attempt(
                    reason: "effective_file_unavailable",
                    message: "The server selected a media version that is not present in the item response.",
                    retiring: resolvedSessionId,
                    retireReason: "start_effective_file_unavailable"
                )
            }
            return StagedProtocolV3Start(
                playbackAttemptId: playbackAttemptId,
                clientQualityId: ApplePlaybackQuality.protocolV3QualityId(qualityPreference),
                bandwidthCapKbps: bandwidthCapKbps,
                snapshot: snapshot,
                serverFeatures: response.serverFeatures,
                // Negotiated only when we asked and the server both advertises
                // and honours it; otherwise the plan's media URLs must stay
                // API-relative and are validated as such.
                negotiatedAuthorizedMediaOrigins: requestsAuthorizedMediaOrigins
                    && response.serverFeatures.contains(
                        PlaybackProtocolV3.authorizedMediaOriginsFeature
                    ),
                plan: plan,
                sessionId: resolvedSessionId,
                selectedVersion: effectiveVersion,
                session: ApplePlaybackV3PlanAdapter.playbackSession(
                    plan: plan,
                    sessionId: resolvedSessionId,
                    selectedVersion: effectiveVersion,
                    serverFeatures: response.serverFeatures
                )
            )
        }
    }

    private func adoptProtocolV3Start(
        _ staged: StagedProtocolV3Start,
        watchDetail: WatchDetail
    ) -> PreparedPlayback {
        let planAttemptId = "apple-plan:\(UUID().uuidString.lowercased())"
        // Attempt keys are server-owned; the client only ever echoes them.
        let planAttemptKey = staged.plan.planAttemptKey
        protocolV3FirstFramePlanIds.removeAll()
        adopt(
            active: ActiveProtocolV3(
                playbackAttemptId: staged.playbackAttemptId,
                planAttemptId: planAttemptId,
                planAttemptKey: planAttemptKey,
                attemptedPlanKeys: [planAttemptKey],
                attemptCount: 1,
                clientQualityId: staged.clientQualityId,
                usesServerQualityPreference: false,
                bandwidthCapKbps: staged.bandwidthCapKbps,
                snapshot: staged.snapshot,
                serverFeatures: staged.serverFeatures,
                negotiatedAuthorizedMediaOrigins: staged.negotiatedAuthorizedMediaOrigins,
                plan: staged.plan
            ),
            session: staged.session
        )
        logger.info(
            "Protocol V3 plan selected id=\(staged.plan.planId, privacy: .public) delivery=\(staged.plan.delivery, privacy: .public)"
        )
        return PreparedPlayback(
            watchDetail: watchDetail,
            selectedVersion: staged.selectedVersion,
            session: staged.session,
            activeQualityId: ApplePlaybackQuality.activeProtocolV3QualityId(
                requestedQualityId: staged.clientQualityId,
                availableQualities: staged.plan.availableQualities
            ),
            protocolV3: PreparedPlaybackV3(
                playbackAttemptId: staged.playbackAttemptId,
                planAttemptId: planAttemptId,
                planAttemptKey: planAttemptKey,
                outputContextId: staged.snapshot.outputContextId,
                serverFeatures: staged.serverFeatures,
                negotiatedAuthorizedMediaOrigins: staged.negotiatedAuthorizedMediaOrigins,
                plan: staged.plan
            )
        )
    }

    /// AVAudioSession emits route-change notifications for configuration
    /// updates performed by the player itself (for example, selecting a new
    /// preferred multichannel layout). A V3 route replan is only warranted
    /// when the opaque output identity used to select the active plan changed.
    static func isMaterialOutputRouteChange(
        activeOutputContextId: String?,
        observedOutputContextId: String?
    ) -> Bool {
        activeOutputContextId != observedOutputContextId
    }

    static func supportsNeutralProtocolV3(_ capability: PlaybackV3CapabilityResponse) -> Bool {
        capability.enabled
            && capability.protocolVersions.contains(PlaybackProtocolV3.version)
            && capability.features.contains(PlaybackProtocolV3.planFeature)
            && capability.features.contains(PlaybackProtocolV3.neutralContractFeature)
            && capability.features.contains(PlaybackProtocolV3.headerAuthenticatedMediaFeature)
    }

    static func isMissingProtocolV3Capability(_ error: Error) -> Bool {
        guard let httpError = error as? HTTPError,
              case .http(let statusCode, _) = httpError else {
            return false
        }
        return statusCode == 404 || statusCode == 405
    }

    static func terminalStartRouteEvent(
        playbackAttemptId: String,
        snapshot: ApplePlaybackV3CapabilitySnapshot,
        terminal: PlaybackV3Terminal
    ) -> PlaybackV3RouteEvent {
        PlaybackV3RouteEvent(
            protocolVersion: PlaybackProtocolV3.version,
            playbackAttemptId: playbackAttemptId,
            sessionId: nil,
            planId: nil,
            planAttemptId: nil,
            planAttemptKey: nil,
            event: "terminal",
            failureClassification: nil,
            fallbackReason: terminal.reason,
            appliedQuirkIds: [],
            quirkRegistryRevision: nil,
            outputContextId: snapshot.outputContextId,
            diagnostics: ["error_cause": String(terminal.message.prefix(256))]
        )
    }

    static func reportTerminalStart(
        playbackAttemptId: String,
        snapshot: ApplePlaybackV3CapabilitySnapshot,
        terminal: PlaybackV3Terminal
    ) async {
        let event = terminalStartRouteEvent(
            playbackAttemptId: playbackAttemptId,
            snapshot: snapshot,
            terminal: terminal
        )
        do {
            try await SiloAPI.shared.reportPlaybackRouteEventV3(event)
        } catch {
            Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
                category: "Playback"
            ).warning(
                "Protocol V3 terminal-start route event failed: \(MediaLogRedactor.sanitize(error), privacy: .public)"
            )
        }
    }



    func replanProtocolV3(
        watchDetail: WatchDetail,
        position: Double,
        classification: String,
        message: String,
        operation: String? = nil,
        qualityPreference: String? = nil,
        audioTrackIndex: Int? = nil,
        subtitleTrackIndex: Int? = nil,
        outputRouteSnapshot: ApplePlaybackV3CapabilitySnapshot? = nil
    ) async throws -> PreparedPlayback? {
        guard var active = transition.active,
              let currentSessionId = transition.sessionId else {
            return nil
        }
        let expectedAttempt = ProtocolV3AttemptIdentity(active)
        let usesV2 = await mutationCoordinator.sequencedState(currentSessionId) == .bound
        let decision = PlaybackReplanDecision.classify(
            active: active,
            classification: classification,
            requestedOperation: operation,
            usesV2: usesV2,
            position: position,
            qualityPreference: qualityPreference,
            audioTrackIndex: audioTrackIndex,
            subtitleTrackIndex: subtitleTrackIndex
        )
        if case .terminal(let exhausted) = decision {
            throw await failProtocolV3Attempt(
                reason: exhausted.reason,
                message: exhausted.message,
                retryable: exhausted.retryable,
                retiring: nil,
                reporting: .init(active: active, sessionId: currentSessionId)
            )
        }
        if classification == "output_route_changed" {
            active.snapshot = outputRouteSnapshot ?? ApplePlaybackV3Capabilities.snapshot()
            cmpLog("[CMP-OUTPUT] phase=route_change \(active.snapshot.outputDiagnosticsLogFields)")
        }
        guard case .request(let requestPlan) = decision else { return nil }

        announceReplanRequested(active: active, sessionId: currentSessionId,
            requestPlan: requestPlan, classification: classification, message: message)
        guard isCurrentProtocolV3Attempt(expectedAttempt, sessionId: currentSessionId) else {
            throw CancellationError()
        }

        let response = try await mutationCoordinator.replan(
            sessionID: currentSessionId,
            request: Self.replanRequest(active: active, requestPlan: requestPlan,
                classification: classification, message: message)
        )
        let validatedResponse = response.validatedForApple()
        guard isCurrentProtocolV3Attempt(expectedAttempt, sessionId: currentSessionId) else {
            discardStaleProtocolV3Response(validatedResponse)
            throw CancellationError()
        }
        let accepted = try await acceptReplan(validatedResponse, response: response,
            active: active, sessionId: currentSessionId, requestPlan: requestPlan,
            watchDetail: watchDetail)
        return adoptReplan(accepted, active: active, requestPlan: requestPlan,
            watchDetail: watchDetail)
    }

    /// Records that a replan was requested, locally and on the server. Both are
    /// best-effort: the route event must not hold the route transition on a
    /// separate HTTP round-trip, and the immutable prior-attempt identity is
    /// captured here so a later replan cannot change what the event names.
    private func announceReplanRequested(
        active: ActiveProtocolV3,
        sessionId: String,
        requestPlan: PlaybackReplanRequestPlan,
        classification: String,
        message: String
    ) {
        #if os(iOS) || os(tvOS)
        // The server-side route event below is the authoritative record, but
        // it only exists if the report POST succeeds and it lands in the
        // server's telemetry, not the user's bundle. This is the client-side
        // counterpart: a replan is a route change the user experiences as a
        // reload, so the bundle needs to show that one happened, why, and
        // where in the timeline — without the free-text `message`, which is
        // user-facing prose the classification already summarises.
        DiagTrace.breadcrumb(
            .essential,
            category: .playback,
            tag: "PlaybackSession",
            message: "protocol v3 replan requested",
            attrs: [
                "session_id": .string(sessionId),
                "reason": .string(classification),
                "play_method": .string(active.plan.delivery),
                "position_ms": .int(Self.diagnosticsPositionMilliseconds(requestPlan.position)),
            ]
        )
        #endif
        let eventActive = active
        Task {
            await emitProtocolV3Event(
                active: eventActive,
                sessionId: sessionId,
                event: requestPlan.eventName,
                classification: classification,
                fallbackReason: nil,
                diagnostics: ["error_cause": String(message.prefix(512))]
            )
        }
    }

    private static func replanRequest(
        active: ActiveProtocolV3,
        requestPlan: PlaybackReplanRequestPlan,
        classification: String,
        message: String
    ) -> PlaybackV3ReplanRequest {
        PlaybackV3ReplanRequest(
            protocolVersion: PlaybackProtocolV3.version,
            // Sticky: a replan may neither add nor drop the negotiated origin
            // token, so it repeats the attempt's captured state verbatim.
            clientFeatures: ApplePlaybackV3Capabilities.startFeatures(
                authorizedMediaOrigins: active.negotiatedAuthorizedMediaOrigins
            ),
            operation: requestPlan.operation,
            playbackAttemptId: active.playbackAttemptId,
            replanRequestId: "apple-replan:\(UUID().uuidString.lowercased())",
            failedPlanId: active.plan.planId,
            planAttemptId: active.planAttemptId,
            planAttemptKey: active.planAttemptKey,
            attemptedPlanKeys: requestPlan.attemptedPlanKeys,
            attemptCount: requestPlan.attemptCount,
            qualityPreference: requestPlan.qualityPreference,
            positionSeconds: requestPlan.position,
            metered: false,
            bandwidthEstimateKbps: nil,
            bandwidthCapKbps: requestPlan.bandwidthCapKbps,
            selectedTracks: requestPlan.selectedTracks,
            failure: PlaybackReplanDecision.replanFailure(
                operation: requestPlan.operation,
                classification: classification,
                message: message
            ),
            // Apple never mutates a server plan locally, so it never has a
            // mutation to fold into the server's next attempt key.
            localMutations: [],
            clientCapabilities: active.snapshot.capabilities,
            clientPlaybackContext: active.snapshot.context
        )
    }

    /// The replacement the server accepted, once every rejection path has
    /// retired what it abandoned and reported its terminal route event.
    private struct AcceptedReplan {
        let plan: PlaybackV3Plan
        let sessionId: String
        let serverFeatures: [String]
        let preservesAttempt: Bool
        let selectedVersion: FileVersion
    }

    private func acceptReplan(
        _ validated: PlaybackV3DecisionValidation,
        response: PlaybackV3DecisionResponse,
        active: ActiveProtocolV3,
        sessionId currentSessionId: String,
        requestPlan: PlaybackReplanRequestPlan,
        watchDetail: WatchDetail
    ) async throws -> AcceptedReplan {
        // A rejected response allocates nothing worth keeping unless the
        // allocation is the session still in use, which must survive.
        func reject(
            _ reason: String,
            _ message: String,
            retryable: Bool = false,
            retiring allocated: String?,
            retireReason: String? = nil
        ) async -> PlaybackV3TerminalFailure {
            await failProtocolV3Attempt(
                reason: reason,
                message: message,
                retryable: retryable,
                retiring: allocated == currentSessionId ? nil : allocated,
                retireReason: retireReason,
                reporting: .init(active: active, sessionId: currentSessionId)
            )
        }

        switch validated {
        case .terminal(let terminal):
            throw await reject(terminal.reason, terminal.message,
                retryable: terminal.retryable, retiring: nil)
        case .incompatible(let allocatedSessionId):
            throw await reject("invalid_replan",
                "The server returned an incompatible protocol V3 replacement plan.",
                retiring: allocatedSessionId,
                retireReason: "incompatible_replan_response")
        case .playable(let nextPlan, let nextSessionId):
            guard response.serverFeatures.contains(
                PlaybackProtocolV3.headerAuthenticatedMediaFeature
            ) else {
                throw await reject("server_upgrade_required",
                    "The server did not preserve authenticated media transport during replanning.",
                    retiring: nextSessionId,
                    retireReason: "replan_without_header_authenticated_media")
            }
            do {
                try ApplePlaybackV3PlanAdapter.validate(nextPlan)
            } catch {
                // The adapter's own error stays the thrown one; the helper's
                // failure only describes what the terminal event reports.
                _ = await reject("invalid_replan", error.localizedDescription,
                    retiring: nextSessionId, retireReason: "unexecutable_replan_plan")
                throw error
            }
            let preservesAttempt: Bool
            do {
                preservesAttempt = try PlaybackReplanDecision.replanPreservesAttempt(
                    operation: requestPlan.operation, usesV2: requestPlan.usesV2,
                    currentSessionID: currentSessionId, nextSessionID: nextSessionId,
                    current: active.plan, next: nextPlan,
                    attemptedKeys: requestPlan.attemptedPlanKeys,
                    responseFeatures: response.serverFeatures)
            } catch let failure as PlaybackV3TerminalFailure {
                throw await reject(failure.reason, failure.message,
                    retryable: failure.retryable, retiring: nextSessionId)
            }
            guard let selectedVersion = watchDetail.versions.first(where: {
                $0.fileId == nextPlan.effectiveMediaFileId
            }) else {
                throw await reject("effective_file_unavailable",
                    "The replacement plan selected an unavailable media version.",
                    retiring: nextSessionId,
                    retireReason: "replan_effective_file_unavailable")
            }
            return AcceptedReplan(plan: nextPlan, sessionId: nextSessionId,
                serverFeatures: response.serverFeatures,
                preservesAttempt: preservesAttempt, selectedVersion: selectedVersion)
        }
    }

    private func adoptReplan(
        _ accepted: AcceptedReplan,
        active: ActiveProtocolV3,
        requestPlan: PlaybackReplanRequestPlan,
        watchDetail: WatchDetail
    ) -> PreparedPlayback {
        var active = active
        let nextSession = ApplePlaybackV3PlanAdapter.playbackSession(
            plan: accepted.plan,
            sessionId: accepted.sessionId,
            selectedVersion: accepted.selectedVersion,
            serverFeatures: accepted.serverFeatures
        )
        if !accepted.preservesAttempt {
            active.planAttemptId = "apple-plan:\(UUID().uuidString.lowercased())"
            active.planAttemptKey = accepted.plan.planAttemptKey
            active.attemptedPlanKeys = requestPlan.attemptedPlanKeys + [accepted.plan.planAttemptKey]
            active.attemptCount = requestPlan.invalidatesIntent ? 1 : active.attemptCount + 1
        }
        active.serverFeatures = accepted.serverFeatures
        active.plan = accepted.plan
        active.clientQualityId = requestPlan.clientQualityId
        active.usesServerQualityPreference = requestPlan.usesServerQualityPreference
        active.bandwidthCapKbps = requestPlan.bandwidthCapKbps
        adopt(
            active: active,
            session: nextSession,
            commitEvent: requestPlan.isSeekReanchor ? "seek_reanchored" : nil,
            // §7.5 spells the seek target `target_source_position_seconds`;
            // `position_seconds` is not on the allowlist and was dropped.
            commitDiagnostics: requestPlan.isSeekReanchor
                ? ["target_source_position_seconds": String(requestPlan.position)]
                : [:]
        )
        return PreparedPlayback(
            watchDetail: watchDetail,
            selectedVersion: accepted.selectedVersion,
            session: nextSession,
            activeQualityId: ApplePlaybackQuality.activeProtocolV3QualityId(
                requestedQualityId: requestPlan.clientQualityId,
                availableQualities: accepted.plan.availableQualities
            ),
            protocolV3: PreparedPlaybackV3(
                playbackAttemptId: active.playbackAttemptId,
                planAttemptId: active.planAttemptId,
                planAttemptKey: active.planAttemptKey,
                outputContextId: active.snapshot.outputContextId,
                serverFeatures: active.serverFeatures,
                negotiatedAuthorizedMediaOrigins: active.negotiatedAuthorizedMediaOrigins,
                plan: accepted.plan
            )
        )
    }

    func reportProtocolV3PlanExecutionStarted(_ prepared: PreparedPlayback) async {
        guard let active = transition.active,
              let sessionId = transition.sessionId,
              sessionId == prepared.session.sessionId,
              active.plan.planId == prepared.protocolV3?.plan.planId else { return }
        await emitRuntimeCorrections(active: active, sessionId: sessionId, stage: "applied")
    }

    /// One event per runtime correction the plan carries, at the stage the
    /// caller reached.
    ///
    /// §7.5 retains `correction_id`/`correction_stage`; the former
    /// `runtime_correction` key was dropped server-side, so these events
    /// carried no correction identity at all.
    private func emitRuntimeCorrections(
        active: ActiveProtocolV3,
        sessionId: String,
        stage: String
    ) async {
        for correction in active.plan.runtimeCorrections {
            await emitProtocolV3Event(
                active: active,
                sessionId: sessionId,
                event: "runtime_correction_\(stage)",
                classification: nil,
                fallbackReason: nil,
                diagnostics: [
                    "correction_id": correction,
                    "correction_stage": stage,
                ]
            )
        }
    }

    func reportProtocolV3FirstFrame(
        planId expectedPlanId: String,
        sessionId expectedSessionId: String,
        milliseconds: Int?
    ) async {
        guard let active = transition.active,
              let sessionId = transition.sessionId,
              sessionId == expectedSessionId,
              active.plan.planId == expectedPlanId else { return }
        guard protocolV3FirstFramePlanIds.insert(active.plan.planId).inserted else { return }
        var diagnostics: [String: String] = [:]
        if let milliseconds { diagnostics["first_frame_ms"] = String(max(0, milliseconds)) }
        await emitProtocolV3Event(
            active: active,
            sessionId: sessionId,
            event: "first_frame",
            classification: nil,
            fallbackReason: nil,
            diagnostics: diagnostics
        )
        await emitRuntimeCorrections(active: active, sessionId: sessionId, stage: "succeeded")
    }

    private func emitProtocolV3Event(
        active: ActiveProtocolV3,
        sessionId: String,
        event: String,
        classification: String?,
        fallbackReason: String?,
        diagnostics: [String: String]
    ) async {
        let event = PlaybackV3RouteEvent(
            protocolVersion: PlaybackProtocolV3.version,
            playbackAttemptId: active.playbackAttemptId,
            sessionId: sessionId,
            planId: active.plan.planId,
            planAttemptId: active.planAttemptId,
            planAttemptKey: active.planAttemptKey,
            event: event,
            failureClassification: classification,
            fallbackReason: fallbackReason,
            appliedQuirkIds: active.plan.appliedQuirks.map(\.id),
            quirkRegistryRevision: active.plan.appliedQuirks.first?.registryRevision,
            outputContextId: active.snapshot.outputContextId,
            diagnostics: diagnostics
        )
        do {
            try await mutationCoordinator.reportRouteEvent(event)
        } catch {
            logger.warning("Protocol V3 route event \(event.event, privacy: .public) failed: \(MediaLogRedactor.sanitize(error), privacy: .public)")
        }
    }

    private func emitProtocolV3Terminal(
        active: ActiveProtocolV3,
        sessionId: String,
        reason: String,
        message: String
    ) async {
        #if os(iOS) || os(tvOS)
        // Every route-ladder dead end funnels through here, so one breadcrumb
        // covers them all: attempt limit, replan loop, invalid plan, missing
        // effective file. `reason` is already a server-defined stable token,
        // which is exactly what the attribute wants — the prose `message` is
        // deliberately left out.
        DiagTrace.breadcrumb(
            .essential,
            level: .error,
            category: .playback,
            tag: "PlaybackSession",
            message: "protocol v3 route exhausted",
            attrs: [
                "session_id": .string(sessionId),
                "reason": .string(reason),
                "play_method": .string(active.plan.delivery),
            ]
        )
        #endif
        await emitProtocolV3Event(
            active: active,
            sessionId: sessionId,
            event: "terminal",
            classification: nil,
            fallbackReason: reason,
            diagnostics: ["error_cause": String(message.prefix(512))]
        )
    }

    // MARK: - Progress Reporting

    /// Counts consecutive `reportProgress` failures since the last success.
    /// Logged for triage; a threshold escalation surfaces the session as
    /// "may be orphaned on server" so downstream code can act on it later.
    private var consecutiveProgressFailures = 0
    private var emittedOrphanedSessionWarning = false
    private static let orphanedSessionLogThreshold = 3

    @discardableResult
    func reportProgress(position: Double, isPaused: Bool) async -> PlaybackProgressReportResult {
        guard let sid = transition.sessionId else { return .transientFailure }
        guard position.isFinite, position >= 0 else { return .transientFailure }

        if await mutationCoordinator.sequencedState(sid) != .notSequenced {
            do {
                try await mutationCoordinator.report(sessionID: sid, position: position, isPaused: isPaused)
                return .success
            } catch {
                logger.warning("Sequenced playback progress remains pending: \(MediaLogRedactor.sanitize(error), privacy: .public)")
                // A rejected bound session cannot be silently renewed as a new attempt.
                return .transientFailure
            }
        }
        let report = ProgressReport(position: position, isPaused: isPaused)
        do {
            try await api.reportPlaybackProgress(
                sessionId: sid,
                report: report
            )
            consecutiveProgressFailures = 0
            emittedOrphanedSessionWarning = false
            return .success
        } catch {
            consecutiveProgressFailures += 1
            logger.warning(
                "reportProgress failed for session \(sid, privacy: .public) (consecutive=\(self.consecutiveProgressFailures)): \(MediaLogRedactor.sanitize(error), privacy: .public)"
            )
            if Self.isPlaybackSessionMissing(error) {
                emittedOrphanedSessionWarning = true
                logger.error(
                    "playback session \(sid, privacy: .public) no longer exists on server; renewal required"
                )
                return .missingSession
            }
            if consecutiveProgressFailures >= Self.orphanedSessionLogThreshold,
               !emittedOrphanedSessionWarning {
                emittedOrphanedSessionWarning = true
                logger.error(
                    "playback session \(sid, privacy: .public) progress reporting has failed \(self.consecutiveProgressFailures) consecutive times; server-side session may be stale"
                )
            }
            return .transientFailure
        }
    }

    /// Resolves the media request for a session the bridge allocated. Media
    /// authority stays with the coordinator; the player consumes the outcome.
    /// A local download carries its own `file://` source and never has one.
    func streamRequest(
        session: PlaybackSessionResponse,
        additionalHeaders: [String: String] = [:],
        requiresHeaderAuthenticatedMedia: Bool = false,
        allowsAuthorizedMediaOrigins: Bool = false
    ) async -> StreamRequest? {
        if session.streamUrl.hasPrefix("file://") {
            return StreamRequest.resolve(rawURL: session.streamUrl, serverURL: "",
                additionalHeaders: [:], accessToken: nil,
                requiresHeaderAuthenticatedMedia: requiresHeaderAuthenticatedMedia)
        }
        return try? await mutationCoordinator.streamRequest(
            sessionID: session.sessionId, rawURL: session.streamUrl,
            additionalHeaders: additionalHeaders,
            requiresHeaderAuthenticatedMedia: requiresHeaderAuthenticatedMedia,
            allowsAuthorizedMediaOrigins: allowsAuthorizedMediaOrigins)
    }

    func syncProgress(
        contentId: String,
        position: Double,
        duration: Double,
        forceOverwrite: Bool
    ) async -> Bool {
        guard !contentId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              position.isFinite,
              position >= 0 else {
            return false
        }

        do {
            try await api.syncProgress(
                mediaItemId: contentId,
                position: position,
                duration: duration.isFinite && duration > 0 ? duration : 0,
                forceOverwrite: forceOverwrite
            )
            return true
        } catch {
            logger.warning(
                "syncProgress failed for \(contentId, privacy: .public) at \(position, privacy: .public): \(MediaLogRedactor.sanitize(error), privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Stop Session

    /// Clamps a playback position in seconds to a non-negative whole-millisecond
    /// count suitable for the `playback.position_ms` diagnostics attribute.
    /// Non-finite and negative inputs collapse to zero, matching how the rest of
    /// this type treats an unusable position.
    static func diagnosticsPositionMilliseconds(_ position: Double) -> Int {
        let seconds = position.isFinite ? max(0, position) : 0
        let milliseconds = (seconds * 1000).rounded()
        guard milliseconds < Double(Int.max) else { return Int.max }
        return Int(milliseconds)
    }

    /// Retires the active server session exactly once.
    ///
    /// This actor is reentrant at every `await` below, and there are three of
    /// them (route event, final progress, DELETE). Reading `sessionId` and only
    /// clearing it after those awaits let a second caller — teardown racing an
    /// autoplay transition — claim the same id and send a duplicate final
    /// progress report and a duplicate DELETE. Claiming the id and clearing all
    /// session-scoped state up front makes concurrent callers share the retirement
    /// result, including terminal abandonment. It also stops the
    /// late clears from wiping a *new* session adopted while these awaits were
    /// still in flight.
    @discardableResult
    func stopSession(position: Double, isPaused: Bool) async -> PlaybackSessionStopResolution {
        guard let sid = transition.sessionId else {
            return await retiringSession?.value ?? .noSession
        }
        let stopped = transition.clear()
        protocolV3FirstFramePlanIds.removeAll()
        consecutiveProgressFailures = 0
        emittedOrphanedSessionWarning = false

        let retirement = Task { @MainActor in
            await self.finishStoppedSession(sid, active: stopped.active,
                supersededSessionId: stopped.supersededSessionId,
                position: position, isPaused: isPaused)
        }
        retiringSession = retirement
        return await retirement.value
    }

    private func finishStoppedSession(_ sid: String, active stoppingProtocolV3: ActiveProtocolV3?,
        supersededSessionId: String?, position: Double, isPaused: Bool) async -> PlaybackSessionStopResolution {
        if let supersededSessionId, supersededSessionId != sid {
            stopStaleSession(supersededSessionId)
        }
        // One read decides both the breadcrumb wording and the stop route; a
        // failed registration stays on the sequenced route so it can never fall
        // through to the plain DELETE below.
        let isSequenced = await mutationCoordinator.sequencedState(sid) != .notSequenced
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.recordBreadcrumb(
            category: .playback,
            tag: "PlaybackSession",
            message: isSequenced ? "local playback closed; server stop pending" : "playback session stopped",
            attrs: [
                "session_id": .string(sid),
                // The attribute registry has no float type, so playback
                // position is reported in whole milliseconds.
                "position_ms": .int(Self.diagnosticsPositionMilliseconds(position)),
            ]
        )
        #endif

        if let active = stoppingProtocolV3 {
            await emitProtocolV3Event(
                active: active,
                sessionId: sid,
                event: "stopped",
                classification: nil,
                fallbackReason: nil,
                diagnostics: [
                    "target_source_position_seconds":
                        String(position.isFinite ? max(0, position) : 0),
                ]
            )
        }

        if isSequenced {
            do {
                return try await mutationCoordinator.stop(sessionID: sid, position: position, isPaused: isPaused) ? .closed : .pending
            }
            catch let failure as PlaybackV3TerminalFailure where failure.reason == "playback_owner_lost" {
                logger.info("Playback ended after server owner loss; pending final sample was not applied")
                return .ownerLost
            }
            catch { logger.error("Playback stop remains pending: \(MediaLogRedactor.sanitize(error), privacy: .public)") }
            return .pending
        }

        if position.isFinite, position >= 0 {
            let report = ProgressReport(position: position, isPaused: isPaused)
            do {
                try await api.reportPlaybackProgress(
                    sessionId: sid,
                    report: report
                )
            } catch {
                logger.warning(
                    "final stop-session progress report failed for \(sid, privacy: .public): \(MediaLogRedactor.sanitize(error), privacy: .public)"
                )
            }
        }

        do {
            try await api.stopPlayback(sessionId: sid)
        } catch {
            // Best-effort delete; the server times out idle sessions on its
            // own, but a missed delete extends the grace period. Log so
            // accumulated failures are observable rather than silent.
            logger.error(
                "stop-session DELETE failed for \(sid, privacy: .public); server-side session may linger until idle timeout: \(MediaLogRedactor.sanitize(error), privacy: .public)"
            )
        }

        #if os(tvOS)
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
        return .closed
    }

    // MARK: - Helpers

    static func isPlaybackSessionMissing(_ error: Error) -> Bool {
        guard case let HTTPError.http(statusCode, body) = error,
              statusCode == 404 else {
            return false
        }
        if let httpError = error as? HTTPError,
           httpError.serverErrorCode == "playback_session_not_found" {
            return true
        }
        return (body ?? "").contains("Playback session not found")
    }

}
