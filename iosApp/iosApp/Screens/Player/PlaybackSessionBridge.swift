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
    private static let nearEndResumeSuppressionSeconds: Double = 5
    private static let pastEndResumeClampSeconds: Double = 0.25

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
    private var sessionId: String?
    private var currentSession: PlaybackSessionResponse?

    private struct ActiveProtocolV3 {
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

    private struct ProtocolV3AttemptIdentity: Equatable {
        let playbackAttemptId: String
        let planAttemptId: String
        let planAttemptKey: String

        init(_ active: ActiveProtocolV3) {
            playbackAttemptId = active.playbackAttemptId
            planAttemptId = active.planAttemptId
            planAttemptKey = active.planAttemptKey
        }
    }

    private struct StagedProtocolV3Start {
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

    struct InitialProtocolV3SubtitleIntent: Equatable {
        let ffmpegStreamIndex: Int?
        let combinedIndex: Int?
    }

    struct InitialProtocolV3SubtitlePreferences: Equatable {
        let preferredLanguage: String?
        let additionalPreferredLanguages: [String]
        let mode: SubtitleMode?
        let showForced: Bool
        let forcedOnly: Bool
        let preferAccessibilityTracks: Bool
        let disableWhenNoLanguageMatch: Bool
        let trackSignature: SubtitleTrackSignature?
    }

    private var activeProtocolV3: ActiveProtocolV3?
    private var protocolV3FirstFramePlanIds: Set<String> = []

    /// A server decision is only provisional until the owning player proves
    /// that Aether accepted the corresponding source. Keeping the prior bridge
    /// state here prevents a cancelled/failed load from publishing a session
    /// and plan that never became executable. A successful commit also retires
    /// the replaced server session exactly once.
    private struct PendingProtocolV3Transition {
        let priorSessionId: String?
        let priorSession: PlaybackSessionResponse?
        let priorProtocolV3: ActiveProtocolV3?
        let candidateSessionId: String
        let candidatePlanId: String
        let commitEvent: String?
        let commitDiagnostics: [String: String]
    }

    private var pendingProtocolV3Transition: PendingProtocolV3Transition?

    /// The staged transition this prepared playback came from, if it is still
    /// the staged one. Identity is the candidate session and plan the server
    /// issued. Whether the bridge already points at that candidate is a
    /// separate question: commit and recovery require it, while a rollback has
    /// to recognise a candidate the bridge never adopted.
    private func stagedTransition(
        matching prepared: PreparedPlayback
    ) -> PendingProtocolV3Transition? {
        guard let pending = pendingProtocolV3Transition,
              pending.candidateSessionId == prepared.session.sessionId,
              pending.candidatePlanId == prepared.protocolV3?.plan.planId else {
            return nil
        }
        return pending
    }

    private func isCurrentProtocolV3Attempt(
        _ expected: ProtocolV3AttemptIdentity,
        sessionId expectedSessionId: String
    ) -> Bool {
        guard !Task.isCancelled,
              sessionId == expectedSessionId,
              currentSession?.sessionId == expectedSessionId,
              let activeProtocolV3 else {
            return false
        }
        return ProtocolV3AttemptIdentity(activeProtocolV3) == expected
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
        guard let allocatedSessionId, allocatedSessionId != sessionId else { return }
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

    /// Records a server-issued candidate plan as pending until Aether commits
    /// the matching load epoch, preserving the last committed state for rollback.
    private func stageProtocolV3Transition(
        candidateSessionId: String,
        candidatePlanId: String,
        commitEvent: String? = nil,
        commitDiagnostics: [String: String] = [:]
    ) {
        // A newer load superseding an uncommitted candidate restores the last
        // committed bridge state and retires the abandoned allocation first.
        // A replan issued against that uncommitted candidate reuses its
        // session id, so the "abandoned" allocation is the one about to be
        // staged again; retiring it would DELETE the session the engine is
        // about to read from and strand playback in 404 backoff.
        rollbackAnyPendingProtocolV3Transition(retainingSessionId: candidateSessionId)
        pendingProtocolV3Transition = PendingProtocolV3Transition(
            priorSessionId: sessionId,
            priorSession: currentSession,
            priorProtocolV3: activeProtocolV3,
            candidateSessionId: candidateSessionId,
            candidatePlanId: candidatePlanId,
            commitEvent: commitEvent,
            commitDiagnostics: commitDiagnostics
        )
    }

    /// Commits the server decision only after Aether's load epoch commits.
    /// Returns false when a newer transition or teardown already won.
    func commitPendingProtocolV3Transition(_ prepared: PreparedPlayback) -> Bool {
        guard let pending = stagedTransition(matching: prepared),
              sessionId == pending.candidateSessionId,
              activeProtocolV3?.plan.planId == pending.candidatePlanId else {
            return false
        }
        pendingProtocolV3Transition = nil
        if let priorSessionId = pending.priorSessionId,
           priorSessionId != pending.candidateSessionId {
            stopStaleSession(priorSessionId)
        }
        if let event = pending.commitEvent, let activeProtocolV3 {
            // Route telemetry is best-effort and must not make this actor
            // reentrant between committing the candidate and returning the
            // result to its owner. Teardown or a newer load may otherwise run
            // during the HTTP await and then be followed by stale VM work.
            let committedActive = activeProtocolV3
            let committedSessionId = pending.candidateSessionId
            let committedDiagnostics = pending.commitDiagnostics
            Task {
                await emitProtocolV3Event(
                    active: committedActive,
                    sessionId: committedSessionId,
                    event: event,
                    classification: nil,
                    fallbackReason: nil,
                    diagnostics: committedDiagnostics
                )
            }
        }
        return true
    }

    /// Returns the committed wire session only when it still belongs to the
    /// exact plan the player is recovering. This lets the player rebuild the
    /// same immutable plan with refreshed request headers without asking the
    /// server to advance the route ladder.
    func committedProtocolV3Session(
        planId expectedPlanId: String,
        sessionId expectedSessionId: String
    ) -> PlaybackSessionResponse? {
        guard pendingProtocolV3Transition == nil,
              sessionId == expectedSessionId,
              currentSession?.sessionId == expectedSessionId,
              activeProtocolV3?.plan.planId == expectedPlanId else {
            return nil
        }
        return currentSession
    }

    /// Promotes a candidate that Aether could not open solely so the client
    /// can report that exact failed attempt and request the next server route.
    /// This is not an execution commit: it emits no success event, binds no
    /// realtime channel, and cannot report first frame. The failed candidate
    /// nevertheless becomes the current server attempt because a V3 replan
    /// must echo the identity of the plan that actually failed.
    func promotePendingProtocolV3TransitionForRecovery(
        _ prepared: PreparedPlayback
    ) -> Bool {
        guard let pending = stagedTransition(matching: prepared),
              sessionId == pending.candidateSessionId,
              activeProtocolV3?.plan.planId == pending.candidatePlanId else {
            return false
        }
        pendingProtocolV3Transition = nil
        if let priorSessionId = pending.priorSessionId,
           priorSessionId != pending.candidateSessionId {
            stopStaleSession(priorSessionId)
        }
        return true
    }

    /// Restores the last committed bridge state after an invalid URL,
    /// cancellation, or Aether load failure and retires a distinct candidate
    /// session. Same-session replans restore client state; the server keeps its
    /// own immutable attempt history for the next bounded replan.
    func rollbackPendingProtocolV3Transition(_ prepared: PreparedPlayback) {
        guard stagedTransition(matching: prepared) != nil else { return }
        rollbackAnyPendingProtocolV3Transition()
    }

    /// `retainingSessionId` names a session the caller is about to stage again;
    /// it is left alive on the server instead of being retired as abandoned.
    private func rollbackAnyPendingProtocolV3Transition(
        retainingSessionId: String? = nil
    ) {
        guard let pending = pendingProtocolV3Transition else { return }
        pendingProtocolV3Transition = nil
        sessionId = pending.priorSessionId
        currentSession = pending.priorSession
        activeProtocolV3 = pending.priorProtocolV3
        if Self.shouldRetireRolledBackCandidate(
            candidateSessionId: pending.candidateSessionId,
            priorSessionId: pending.priorSessionId,
            retainingSessionId: retainingSessionId
        ) {
            stopStaleSession(pending.candidateSessionId)
        }
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

    private func adoptSession(_ session: PlaybackSessionResponse) {
        retiringSession = nil
        sessionId = session.sessionId
        currentSession = session
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
        initialSubtitlePreferences: InitialProtocolV3SubtitlePreferences? = nil,
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

        // A mid-stream quality-change replan passes an explicit override
        // (e.g. back to Auto) that must win over the persisted setting.
        let playerSettings = PlayerSettings.shared
        let lastUsedQuality = prefersLastUsedVersion
            ? normalizedQualityPreference(watchDetail.userData?.lastResolution)
            : nil
        let preferredQuality = preferredQualityOverride.map {
            ApplePlaybackQuality.protocolV3QualityId($0)
        } ?? lastUsedQuality
            ?? normalizedQualityPreference(playerSettings.preferredQuality)
        let bandwidthCapKbps = AppleQualityAxes.resolvedBitrateCap(
            qualityOverride: preferredQualityOverride,
            fallbackBitrateKbps: playerSettings.maxBitrateKbps
        )
        let normalizedResumePosition: Double? = {
            guard let resumePosition, resumePosition.isFinite, resumePosition >= 0 else {
                return nil
            }
            return resumePosition
        }()
        let storedResumePosition: Double? = {
            guard let storedResumePosition = watchDetail.userData?.positionSeconds,
                  storedResumePosition.isFinite,
                  storedResumePosition >= 0 else {
                return nil
            }
            return storedResumePosition
        }()

        let initiallySelectedVersion: FileVersion
        if let preferredFileId,
           let requestedVersion = watchDetail.versions.first(where: { $0.fileId == preferredFileId }) {
            initiallySelectedVersion = requestedVersion
            logger.info(
                "Using manually selected version fileId=\(requestedVersion.fileId, privacy: .public)"
            )
        } else if prefersLastUsedVersion,
                  let lastFileId = watchDetail.userData?.lastFileId,
                  let lastUsedVersion = watchDetail.versions.first(where: {
                      $0.fileId == lastFileId
                  }) {
            initiallySelectedVersion = lastUsedVersion
            logger.info(
                "Resuming last-used version fileId=\(lastUsedVersion.fileId, privacy: .public)"
            )
        } else {
            if let preferredFileId {
                logger.warning(
                    "Requested fileId=\(preferredFileId, privacy: .public) is unavailable; falling back to automatic selection"
                )
            }

            initiallySelectedVersion = Self.selectVersion(
                from: watchDetail.versions,
                lastFileId: watchDetail.userData?.lastFileId,
                preferredQuality: preferredQuality
            )
        }
        let selectedVersion = initiallySelectedVersion
        let resolvedAudioTrackIndex = preferredAudioTrackIndex
            ?? selectedVersion.effectiveAudioTrackIndex
        let selectedAudioLanguage = selectedVersion.audioTracks?.first(where: {
            $0.index == resolvedAudioTrackIndex
        })?.language
        let subtitleIntent = Self.initialProtocolV3SubtitleIntent(
            version: selectedVersion,
            explicitFFmpegIndex: preferredSubtitleTrackIndex,
            explicitCombinedIndex: preferredProtocolV3SubtitleIndex,
            preferredLanguage: initialSubtitlePreferences == nil
                ? watchDetail.effectiveSubtitleLanguage
                : initialSubtitlePreferences?.preferredLanguage,
            additionalPreferredLanguages: initialSubtitlePreferences?.additionalPreferredLanguages ?? [],
            mode: initialSubtitlePreferences == nil
                ? SubtitleMode(rawValue: watchDetail.effectiveSubtitleMode ?? "")
                : initialSubtitlePreferences?.mode,
            showForced: initialSubtitlePreferences?.showForced
                ?? (watchDetail.effectiveShowForcedSubtitles ?? false),
            forcedOnly: initialSubtitlePreferences?.forcedOnly ?? false,
            preferAccessibilityTracks: initialSubtitlePreferences?.preferAccessibilityTracks ?? false,
            disableWhenNoLanguageMatch: initialSubtitlePreferences?.disableWhenNoLanguageMatch ?? false,
            trackSignature: initialSubtitlePreferences == nil
                ? watchDetail.effectiveSubtitleTrackSignature
                : initialSubtitlePreferences?.trackSignature,
            currentAudioLanguage: selectedAudioLanguage
        )
        let effectiveStartPosition = resolvedStartPosition(
            startFromBeginning: startFromBeginning,
            explicitResumePosition: normalizedResumePosition,
            storedResumePosition: storedResumePosition,
            watchDetail: watchDetail,
            selectedVersion: selectedVersion,
            allowNearEndResume: allowNearEndResume
        )
        logger.info(
            "Selected version fileId=\(selectedVersion.fileId, privacy: .public) resolution=\(selectedVersion.resolution ?? "unknown", privacy: .public) codec=\(selectedVersion.codecVideo ?? "unknown", privacy: .public) bitrate=\(selectedVersion.bitrate ?? 0)"
        )

        // Quality preference is a server-owned planning input. An explicit
        // override is the user's in-player choice, so preserve it verbatim
        // instead of deriving a different rung from the selected file.
        let resolvedQualityPreference = preferredQualityOverride != nil
            ? preferredQuality
            : requestedQualityPreference(
                preferredQuality: preferredQuality,
                selectedVersion: selectedVersion,
                hasManualSelection: preferredFileId != nil
                    || (prefersLastUsedVersion
                        && selectedVersion.fileId == watchDetail.userData?.lastFileId)
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
        return try await startProtocolV3(
            watchDetail: watchDetail,
            selectedVersion: selectedVersion,
            profileId: profileId,
            qualityPreference: resolvedQualityPreference,
            bandwidthCapKbps: bandwidthCapKbps,
            startPosition: effectiveStartPosition,
            // Without an explicit pick, send the server's own detail-resolved
            // effective audio index so a movie's remembered track survives.
            audioTrackIndex: resolvedAudioTrackIndex,
            subtitleTrackIndex: subtitleIntent.ffmpegStreamIndex,
            subtitleCombinedIndex: subtitleIntent.combinedIndex
        )
    }

    /// Resolves "Auto" before the first V3 request. The player otherwise
    /// applies the same preference resolver only after opening the file,
    /// which can make it render a container-default/forced track while the
    /// server still believes the authoritative plan has subtitles off.
    static func initialProtocolV3SubtitleIntent(
        version: FileVersion,
        explicitFFmpegIndex: Int?,
        explicitCombinedIndex: Int?,
        preferredLanguage: String?,
        additionalPreferredLanguages: [String] = [],
        mode: SubtitleMode?,
        showForced: Bool,
        forcedOnly: Bool = false,
        preferAccessibilityTracks: Bool = false,
        disableWhenNoLanguageMatch: Bool = false,
        trackSignature: SubtitleTrackSignature?,
        currentAudioLanguage: String?
    ) -> InitialProtocolV3SubtitleIntent {
        if let explicitCombinedIndex {
            return InitialProtocolV3SubtitleIntent(
                ffmpegStreamIndex: explicitFFmpegIndex.flatMap { $0 >= 0 ? $0 : nil },
                combinedIndex: explicitCombinedIndex >= 0 ? explicitCombinedIndex : nil
            )
        }
        if let explicitFFmpegIndex {
            guard explicitFFmpegIndex >= 0 else {
                return InitialProtocolV3SubtitleIntent(ffmpegStreamIndex: nil, combinedIndex: nil)
            }
            return InitialProtocolV3SubtitleIntent(
                ffmpegStreamIndex: explicitFFmpegIndex,
                combinedIndex: ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                    ffmpegStreamIndex: explicitFFmpegIndex,
                    in: version
                )
            )
        }

        let candidates = SubtitleTrackCandidates.playerTracks(from: version.subtitleTracks ?? [])
        let resolution = SubtitleAutoResolver.resolve(.init(
            preferredLanguage: preferredLanguage,
            additionalPreferredLanguages: additionalPreferredLanguages,
            mode: mode,
            showForced: showForced,
            forcedOnly: forcedOnly,
            preferAccessibilityTracks: preferAccessibilityTracks,
            disableWhenNoLanguageMatch: disableWhenNoLanguageMatch,
            trackSignature: trackSignature,
            availableSubtitles: candidates,
            currentAudioLanguage: currentAudioLanguage
        ))
        let selected: PlayerTrack?
        switch resolution {
        case .select(let track):
            selected = track
        case .disable:
            selected = nil
        case .noChange:
            // "Leave the player alone" means its demuxer keeps the media's
            // default track; the sidecar route also promotes a forced track.
            // Freeze that deterministic choice into the plan up front.
            selected = candidates.first(where: { $0.isDefault })
                ?? candidates.first(where: { $0.isForced })
        }
        guard let selected else {
            return InitialProtocolV3SubtitleIntent(ffmpegStreamIndex: nil, combinedIndex: nil)
        }
        return InitialProtocolV3SubtitleIntent(
            ffmpegStreamIndex: selected.ffIndex,
            combinedIndex: ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                for: selected,
                in: version
            )
        )
    }

    private func startProtocolV3(
        watchDetail: WatchDetail,
        selectedVersion: FileVersion,
        profileId: String,
        qualityPreference: String?,
        bandwidthCapKbps: Int?,
        startPosition: Double?,
        audioTrackIndex: Int?,
        subtitleTrackIndex: Int?,
        subtitleCombinedIndex: Int? = nil
    ) async throws -> PreparedPlayback {
        let resolvedSubtitleCombinedIndex = subtitleCombinedIndex ?? subtitleTrackIndex.flatMap {
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                ffmpegStreamIndex: $0,
                in: selectedVersion
            )
        }
        let staged = try await stageProtocolV3Start(
            watchDetail: watchDetail,
            selectedVersion: selectedVersion,
            profileId: profileId,
            qualityPreference: qualityPreference,
            bandwidthCapKbps: bandwidthCapKbps,
            startPosition: startPosition,
            audioTrackIndex: audioTrackIndex,
            subtitleCombinedIndex: resolvedSubtitleCombinedIndex
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
        selectedVersion: FileVersion,
        profileId: String,
        qualityPreference: String?,
        bandwidthCapKbps: Int?,
        startPosition: Double?,
        audioTrackIndex: Int?,
        subtitleCombinedIndex: Int?
    ) async throws -> StagedProtocolV3Start {
        let startAuth = try await mutationCoordinator.captureStartAuth()
        let capturedPlaybackAuth = startAuth.durable
        let initialCapability = startAuth.capability
        let requestsAuthorizedMediaOrigins = initialCapability.features.contains(
            PlaybackProtocolV3.authorizedMediaOriginsFeature)

        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        cmpLog("[CMP-OUTPUT] phase=start \(snapshot.outputDiagnosticsLogFields)")
        let playbackAttemptId = "apple:\(UUID().uuidString.lowercased())"
        let request = PlaybackV3StartRequest(
            protocolVersion: PlaybackProtocolV3.version,
            clientFeatures: ApplePlaybackV3Capabilities.startFeatures(
                authorizedMediaOrigins: requestsAuthorizedMediaOrigins
            ),
            fileId: selectedVersion.fileId,
            profileId: profileId,
            playbackAttemptId: playbackAttemptId,
            qualityPreference: protocolV3QualityPreference(qualityPreference),
            subtitleFidelityPreference: "preserve",
            progressPersistence: nil,
            startPosition: startPosition,
            audioTrackId: audioTrackIndex.flatMap {
                $0 >= 0 ? protocolV3TrackId(fileId: selectedVersion.fileId, kind: "audio", index: $0) : nil
            },
            audioTrackIndex: audioTrackIndex.flatMap { $0 >= 0 ? $0 : nil },
            subtitleTrackId: subtitleCombinedIndex.flatMap {
                $0 >= 0 ? protocolV3TrackId(fileId: selectedVersion.fileId, kind: "subtitle", index: $0) : nil
            },
            subtitleTrackIndex: subtitleCombinedIndex,
            metered: false,
            bandwidthEstimateKbps: nil,
            bandwidthCapKbps: bandwidthCapKbps,
            clientCapabilities: snapshot.capabilities,
            clientPlaybackContext: snapshot.context
        )

        logger.info(
            "Starting protocol V3 attempt=\(playbackAttemptId, privacy: .public) fileId=\(selectedVersion.fileId, privacy: .public)"
        )
        // Callers cancel this task on the autoplay start timeout and on player
        // dismissal. The POST allocates a server session, so cancelling it
        // mid-flight used to leave that session stranded until the server's idle
        // timeout. Shield the request from cancellation and retire whatever it
        // allocated if the caller has already walked away.
        let response = try await PlaybackCancellationShield.run {
            try await self.mutationCoordinator.startV2(request: request,
                auth: capturedPlaybackAuth, capability: initialCapability)
        } reclaim: { [self] abandoned in
            guard let orphaned = Self.allocatedSessionId(in: abandoned) else { return }
            try? await registerSequencedAllocation(abandoned, auth: capturedPlaybackAuth)
            await retireAbandonedSession(orphaned, reason: "cancelled_start")
        }

        try await registerSequencedAllocation(response, auth: capturedPlaybackAuth)

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
            let session = ApplePlaybackV3PlanAdapter.playbackSession(
                plan: plan,
                sessionId: resolvedSessionId,
                selectedVersion: effectiveVersion,
                serverFeatures: response.serverFeatures
            )
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
                session: session
            )
        }
    }

    private func adoptProtocolV3Start(
        _ staged: StagedProtocolV3Start,
        watchDetail: WatchDetail
    ) -> PreparedPlayback {
        stageProtocolV3Transition(
            candidateSessionId: staged.sessionId,
            candidatePlanId: staged.plan.planId
        )
        let planAttemptId = "apple-plan:\(UUID().uuidString.lowercased())"
        // Attempt keys are server-owned; the client only ever echoes them.
        let planAttemptKey = staged.plan.planAttemptKey
        activeProtocolV3 = ActiveProtocolV3(
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
        )
        protocolV3FirstFramePlanIds.removeAll()
        adoptSession(staged.session)
        let preparedV3 = PreparedPlaybackV3(
            playbackAttemptId: staged.playbackAttemptId,
            planAttemptId: planAttemptId,
            planAttemptKey: planAttemptKey,
            outputContextId: staged.snapshot.outputContextId,
            serverFeatures: staged.serverFeatures,
            negotiatedAuthorizedMediaOrigins: staged.negotiatedAuthorizedMediaOrigins,
            plan: staged.plan
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
            protocolV3: preparedV3
        )
    }

    /// Maps a local failure/intent classification onto the protocol's replan
    /// operation. A user-initiated track or quality change is an intent, not a
    /// failure, and carries no `failure` block.
    ///
    /// An output-route change is an intent too: the device never rejected the
    /// plan, the display it was chosen for did. §6 gives `output_change`
    /// exactly that meaning — it keeps the previous route eligible, where
    /// `failure_recovery` excludes the current plan key and so forces a
    /// different route even when the new sink can still play it.
    ///
    /// That operation only exists on a server advertising `output_change_v1`;
    /// an older one rejects it as an invalid operation, so the historical
    /// failure-recovery spelling remains the fallback there. Omitting
    /// `serverFeatures` means exactly that older server.
    static func replanOperation(
        forClassification classification: String,
        serverFeatures: [String] = []
    ) -> String {
        switch classification {
        case "audio_track_changed", "subtitle_track_changed":
            return PlaybackProtocolV3.ReplanOperation.trackChange
        case "quality_changed":
            return PlaybackProtocolV3.ReplanOperation.qualityChange
        case "output_route_changed"
            where serverFeatures.contains(PlaybackProtocolV3.outputChangeFeature):
            return PlaybackProtocolV3.ReplanOperation.outputChange
        default:
            return PlaybackProtocolV3.ReplanOperation.failureRecovery
        }
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

    static func replanFailure(
        operation: String,
        classification: String,
        message: String
    ) -> PlaybackV3Failure? {
        switch operation {
        case PlaybackProtocolV3.ReplanOperation.trackChange,
             PlaybackProtocolV3.ReplanOperation.qualityChange,
             // The server rejects an `output_change` that carries a failure:
             // "output_change must not include failure".
             PlaybackProtocolV3.ReplanOperation.outputChange,
             PlaybackProtocolV3.ReplanOperation.seekReanchor:
            return nil
        default:
            return PlaybackV3Failure(
                classification: classification,
                message: String(message.prefix(512)),
                decoderName: nil
            )
        }
    }

    static func isV2SameRouteRecovery(operation: String, usesV2: Bool) -> Bool {
        usesV2 && [PlaybackProtocolV3.ReplanOperation.failureRecovery,
                   PlaybackProtocolV3.ReplanOperation.seekFailureRecovery,
                   PlaybackProtocolV3.ReplanOperation.seekReanchor].contains(operation)
    }

    static func replanPreservesAttempt(operation: String, usesV2: Bool,
        currentSessionID: String, nextSessionID: String,
        current: PlaybackV3Plan, next: PlaybackV3Plan,
        attemptedKeys: [String], responseFeatures: [String]) throws -> Bool {
        let isSeekReanchor = operation == PlaybackProtocolV3.ReplanOperation.seekReanchor
        let v2SameRoute = isV2SameRouteRecovery(operation: operation, usesV2: usesV2)
        let preservesRoute = isSeekReanchor || v2SameRoute
        guard preservesRoute || !attemptedKeys.contains(next.planAttemptKey) else {
            throw PlaybackV3TerminalFailure(reason: "replan_loop_detected",
                message: "The server returned a protocol V3 plan that already failed on this output route.", retryable: false)
        }
        if preservesRoute {
            guard currentSessionID == nextSessionID,
                  (v2SameRoute || responseFeatures.contains(PlaybackProtocolV3.seekReanchorFeature)),
                  (!v2SameRoute || (next.planId == current.planId
                    && next.effectiveMediaFileId == current.effectiveMediaFileId
                    && next.requestedMediaFileId == current.requestedMediaFileId
                    && next.source == current.source
                    && next.stream.protocol == current.stream.protocol
                    && next.stream.container == current.stream.container)),
                  next.planAttemptKey == current.planAttemptKey,
                  next.delivery == current.delivery,
                  next.effectiveRecipe == current.effectiveRecipe,
                  next.selectedTracks == current.selectedTracks,
                  next.transformations == current.transformations,
                  next.appliedQuirks == current.appliedQuirks,
                  next.runtimeCorrections == current.runtimeCorrections else {
                throw PlaybackV3TerminalFailure(reason: "invalid_seek_reanchor_response",
                    message: "The server changed the route or playback intent during a V3 seek re-anchor.", retryable: false)
            }
        }
        return preservesRoute
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
        guard var active = activeProtocolV3,
              let currentSessionId = sessionId else {
            return nil
        }
        // Resolved after the guard because the intent mapping depends on what
        // the server advertised for this attempt.
        let operation = operation ?? Self.replanOperation(
            forClassification: classification,
            serverFeatures: active.serverFeatures
        )
        let expectedAttempt = ProtocolV3AttemptIdentity(active)
        guard active.attemptCount < 8 else {
            throw await failProtocolV3Attempt(
                reason: "attempt_limit_reached",
                message: "Playback recovery exhausted the protocol V3 route ladder.",
                retiring: nil,
                reporting: .init(active: active, sessionId: currentSessionId)
            )
        }

        if classification == "output_route_changed" {
            active.snapshot = outputRouteSnapshot ?? ApplePlaybackV3Capabilities.snapshot()
            cmpLog("[CMP-OUTPUT] phase=route_change \(active.snapshot.outputDiagnosticsLogFields)")
        }

        let isIntent = operation == PlaybackProtocolV3.ReplanOperation.trackChange
            || operation == PlaybackProtocolV3.ReplanOperation.qualityChange
            || operation == PlaybackProtocolV3.ReplanOperation.outputChange
        let invalidatesIntent = isIntent || classification == "output_route_changed"
        let isSeekReanchor = operation == PlaybackProtocolV3.ReplanOperation.seekReanchor
        let usesV2 = await mutationCoordinator.sequencedState(currentSessionId) == .bound
        let preservesRoute = isSeekReanchor || Self.isV2SameRouteRecovery(operation: operation, usesV2: usesV2)
        if isSeekReanchor,
           !active.serverFeatures.contains(PlaybackProtocolV3.seekReanchorFeature) {
            return nil
        }
        let attemptedKeys = preservesRoute
            ? active.attemptedPlanKeys
            : invalidatesIntent
            ? []
            : Array(Set(active.attemptedPlanKeys + [active.planAttemptKey])).sorted()
        let selectedFileId = active.plan.effectiveMediaFileId
        let selectedAudio = (preservesRoute ? nil : audioTrackIndex).flatMap { index in
            guard index >= 0 else { return nil }
            return PlaybackV3TrackIdentity(
                id: protocolV3TrackId(fileId: selectedFileId, kind: "audio", index: index),
                index: index
            )
        } ?? active.plan.selectedTracks.audio
        let selectedSubtitle: PlaybackV3TrackIdentity? = {
            if preservesRoute { return active.plan.selectedTracks.subtitle }
            if classification == "subtitle_track_changed" {
                return subtitleTrackIndex.flatMap { index in
                    guard index >= 0 else { return nil }
                    return PlaybackV3TrackIdentity(
                        id: protocolV3TrackId(fileId: selectedFileId, kind: "subtitle", index: index),
                        index: index
                    )
                }
            }
            return active.plan.selectedTracks.subtitle
        }()
        let selectedTracks = PlaybackV3SelectedTracks(audio: selectedAudio, subtitle: selectedSubtitle)
        let normalizedPosition = position.isFinite ? max(0, position) : 0
        let qualitySelection = qualityPreference.map {
            ApplePlaybackQuality.protocolV3Selection(
                requestedQualityId: $0,
                availableQualities: active.plan.availableQualities
            )
        }
        let requestedClientQualityId = qualitySelection?.clientQualityId
            ?? active.clientQualityId
        let requestedUsesServerQualityPreference = qualitySelection?.isServerOwned
            ?? active.usesServerQualityPreference
        let requestedQualityPreference = qualitySelection?.serverPreference
            ?? (requestedUsesServerQualityPreference
                ? requestedClientQualityId
                : protocolV3QualityPreference(requestedClientQualityId))
        let requestedBandwidthCapKbps: Int?
        if let qualitySelection {
            requestedBandwidthCapKbps = qualitySelection.bandwidthCapKbps
        } else {
            requestedBandwidthCapKbps = active.bandwidthCapKbps
        }
        let eventName = isSeekReanchor
            ? "seek_reanchor_requested"
            : (invalidatesIntent ? "plan_invalidated" : "plan_failed")
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
                "session_id": .string(currentSessionId),
                "reason": .string(classification),
                "play_method": .string(active.plan.delivery),
                "position_ms": .int(Self.diagnosticsPositionMilliseconds(normalizedPosition)),
            ]
        )
        #endif
        // Telemetry is best-effort and must not hold the route transition on
        // a separate HTTP round-trip. The immutable prior-attempt identity is
        // captured here so a later replan cannot change what the event names.
        let eventActive = active
        Task {
            await emitProtocolV3Event(
                active: eventActive,
                sessionId: currentSessionId,
                event: eventName,
                classification: classification,
                fallbackReason: nil,
                diagnostics: ["error_cause": String(message.prefix(512))]
            )
        }
        guard isCurrentProtocolV3Attempt(expectedAttempt, sessionId: currentSessionId) else {
            throw CancellationError()
        }

        let request = PlaybackV3ReplanRequest(
            protocolVersion: PlaybackProtocolV3.version,
            // Sticky: a replan may neither add nor drop the negotiated origin
            // token, so it repeats the attempt's captured state verbatim.
            clientFeatures: ApplePlaybackV3Capabilities.startFeatures(
                authorizedMediaOrigins: active.negotiatedAuthorizedMediaOrigins
            ),
            operation: operation,
            playbackAttemptId: active.playbackAttemptId,
            replanRequestId: "apple-replan:\(UUID().uuidString.lowercased())",
            failedPlanId: active.plan.planId,
            planAttemptId: active.planAttemptId,
            planAttemptKey: active.planAttemptKey,
            attemptedPlanKeys: attemptedKeys,
            attemptCount: invalidatesIntent ? 1 : active.attemptCount,
            qualityPreference: requestedQualityPreference,
            positionSeconds: normalizedPosition,
            metered: false,
            bandwidthEstimateKbps: nil,
            bandwidthCapKbps: requestedBandwidthCapKbps,
            selectedTracks: selectedTracks,
            failure: Self.replanFailure(
                operation: operation,
                classification: classification,
                message: message
            ),
            // Apple never mutates a server plan locally, so it never has a
            // mutation to fold into the server's next attempt key.
            localMutations: [],
            clientCapabilities: active.snapshot.capabilities,
            clientPlaybackContext: active.snapshot.context
        )
        let response = try await mutationCoordinator.replan(sessionID: currentSessionId, request: request)
        let validatedResponse = response.validatedForApple()
        guard isCurrentProtocolV3Attempt(expectedAttempt, sessionId: currentSessionId) else {
            discardStaleProtocolV3Response(validatedResponse)
            throw CancellationError()
        }
        switch validatedResponse {
        case .terminal(let terminal):
            throw await failProtocolV3Attempt(
                reason: terminal.reason,
                message: terminal.message,
                retryable: terminal.retryable,
                retiring: nil,
                reporting: .init(active: active, sessionId: currentSessionId)
            )
        case .incompatible(let allocatedSessionId):
            throw await failProtocolV3Attempt(
                reason: "invalid_replan",
                message: "The server returned an incompatible protocol V3 replacement plan.",
                retiring: allocatedSessionId == currentSessionId ? nil : allocatedSessionId,
                retireReason: "incompatible_replan_response",
                reporting: .init(active: active, sessionId: currentSessionId)
            )
        case .playable(let nextPlan, let nextSessionId):
            guard response.serverFeatures.contains(
                PlaybackProtocolV3.headerAuthenticatedMediaFeature
            ) else {
                throw await failProtocolV3Attempt(
                    reason: "server_upgrade_required",
                    message: "The server did not preserve authenticated media transport during replanning.",
                    retiring: nextSessionId == currentSessionId ? nil : nextSessionId,
                    retireReason: "replan_without_header_authenticated_media",
                    reporting: .init(active: active, sessionId: currentSessionId)
                )
            }
            do {
                try ApplePlaybackV3PlanAdapter.validate(nextPlan)
            } catch {
                // The adapter's own error stays the thrown one; the helper's
                // failure only describes what the terminal event reports.
                await failProtocolV3Attempt(
                    reason: "invalid_replan",
                    message: error.localizedDescription,
                    retiring: nextSessionId == currentSessionId ? nil : nextSessionId,
                    retireReason: "unexecutable_replan_plan",
                    reporting: .init(active: active, sessionId: currentSessionId)
                )
                throw error
            }
            let nextKey = nextPlan.planAttemptKey
            let preservesAttempt: Bool
            do {
                preservesAttempt = try Self.replanPreservesAttempt(operation: operation,
                    usesV2: usesV2,
                    currentSessionID: currentSessionId, nextSessionID: nextSessionId,
                    current: active.plan, next: nextPlan, attemptedKeys: attemptedKeys,
                    responseFeatures: response.serverFeatures)
            } catch let failure as PlaybackV3TerminalFailure {
                throw await failProtocolV3Attempt(
                    reason: failure.reason,
                    message: failure.message,
                    retryable: failure.retryable,
                    retiring: nextSessionId == currentSessionId ? nil : nextSessionId,
                    reporting: .init(active: active, sessionId: currentSessionId)
                )
            }
            guard let selectedVersion = watchDetail.versions.first(where: {
                $0.fileId == nextPlan.effectiveMediaFileId
            }) else {
                throw await failProtocolV3Attempt(
                    reason: "effective_file_unavailable",
                    message: "The replacement plan selected an unavailable media version.",
                    retiring: nextSessionId == currentSessionId ? nil : nextSessionId,
                    retireReason: "replan_effective_file_unavailable",
                    reporting: .init(active: active, sessionId: currentSessionId)
                )
            }
            let nextSession = ApplePlaybackV3PlanAdapter.playbackSession(
                plan: nextPlan,
                sessionId: nextSessionId,
                selectedVersion: selectedVersion,
                serverFeatures: response.serverFeatures
            )
            if !preservesAttempt {
                active.planAttemptId = "apple-plan:\(UUID().uuidString.lowercased())"
                active.planAttemptKey = nextKey
                active.attemptedPlanKeys = attemptedKeys + [nextKey]
                active.attemptCount = invalidatesIntent ? 1 : active.attemptCount + 1
            }
            active.serverFeatures = response.serverFeatures
            active.plan = nextPlan
            active.clientQualityId = requestedClientQualityId
            active.usesServerQualityPreference = requestedUsesServerQualityPreference
            active.bandwidthCapKbps = requestedBandwidthCapKbps
            stageProtocolV3Transition(
                candidateSessionId: nextSessionId,
                candidatePlanId: nextPlan.planId,
                commitEvent: isSeekReanchor ? "seek_reanchored" : nil,
                // §7.5 spells the seek target `target_source_position_seconds`;
                // `position_seconds` is not on the allowlist and was dropped.
                commitDiagnostics: isSeekReanchor
                    ? ["target_source_position_seconds": String(normalizedPosition)]
                    : [:]
            )
            activeProtocolV3 = active
            adoptSession(nextSession)
            let preparedV3 = PreparedPlaybackV3(
                playbackAttemptId: active.playbackAttemptId,
                planAttemptId: active.planAttemptId,
                planAttemptKey: active.planAttemptKey,
                outputContextId: active.snapshot.outputContextId,
                serverFeatures: active.serverFeatures,
                negotiatedAuthorizedMediaOrigins: active.negotiatedAuthorizedMediaOrigins,
                plan: nextPlan
            )
            return PreparedPlayback(
                watchDetail: watchDetail,
                selectedVersion: selectedVersion,
                session: nextSession,
                activeQualityId: ApplePlaybackQuality.activeProtocolV3QualityId(
                    requestedQualityId: requestedClientQualityId,
                    availableQualities: nextPlan.availableQualities
                ),
                protocolV3: preparedV3
            )
        }
    }

    func reportProtocolV3PlanExecutionStarted(_ prepared: PreparedPlayback) async {
        guard let active = activeProtocolV3,
              let sessionId,
              sessionId == prepared.session.sessionId,
              active.plan.planId == prepared.protocolV3?.plan.planId else { return }
        for correction in active.plan.runtimeCorrections {
            await emitProtocolV3Event(
                active: active,
                sessionId: sessionId,
                event: "runtime_correction_applied",
                classification: nil,
                fallbackReason: nil,
                // §7.5 retains `correction_id`/`correction_stage`; the former
                // `runtime_correction` key was dropped server-side, so these
                // events carried no correction identity at all.
                diagnostics: [
                    "correction_id": correction,
                    "correction_stage": "applied",
                ]
            )
        }
    }

    func reportProtocolV3FirstFrame(
        planId expectedPlanId: String,
        sessionId expectedSessionId: String,
        milliseconds: Int?
    ) async {
        guard let active = activeProtocolV3,
              let sessionId,
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
        for correction in active.plan.runtimeCorrections {
            await emitProtocolV3Event(
                active: active,
                sessionId: sessionId,
                event: "runtime_correction_succeeded",
                classification: nil,
                fallbackReason: nil,
                diagnostics: [
                    "correction_id": correction,
                    "correction_stage": "succeeded",
                ]
            )
        }
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

    private func resolvedStartPosition(
        startFromBeginning: Bool,
        explicitResumePosition: Double?,
        storedResumePosition: Double?,
        watchDetail: WatchDetail,
        selectedVersion: FileVersion,
        allowNearEndResume: Bool
    ) -> Double? {
        if startFromBeginning {
            return 0
        }

        guard let candidatePosition = explicitResumePosition ?? storedResumePosition else {
            return nil
        }

        let durationHint = [watchDetail.userData?.durationSeconds, selectedVersion.duration]
            .compactMap { value -> Double? in
                guard let value, value.isFinite, value > 0 else { return nil }
                return value
            }
            .min()

        guard let durationHint else {
            return candidatePosition
        }

        if allowNearEndResume {
            guard candidatePosition >= durationHint else {
                return candidatePosition
            }
            let clampedPosition = max(0, durationHint - Self.pastEndResumeClampSeconds)
            logger.warning(
                "Resume position \(candidatePosition, privacy: .public) reached/passed duration hint \(durationHint, privacy: .public); clamping transient resume to \(clampedPosition, privacy: .public)"
            )
            return clampedPosition
        }

        let nearEndCutoff = max(0, durationHint - Self.nearEndResumeSuppressionSeconds)
        guard candidatePosition >= nearEndCutoff else {
            return candidatePosition
        }

        logger.info(
            "Suppressing resume position \(candidatePosition, privacy: .public) near duration hint \(durationHint, privacy: .public); restarting from beginning"
        )
        return 0
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
        guard let sid = sessionId else { return .transientFailure }
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
        guard let sid = sessionId else {
            return await retiringSession?.value ?? .noSession
        }
        let stoppingProtocolV3 = activeProtocolV3
        let supersededSessionId = pendingProtocolV3Transition?.priorSessionId

        sessionId = nil
        currentSession = nil
        activeProtocolV3 = nil
        pendingProtocolV3Transition = nil
        protocolV3FirstFramePlanIds.removeAll()
        consecutiveProgressFailures = 0
        emittedOrphanedSessionWarning = false

        let retirement = Task { @MainActor in
            await self.finishStoppedSession(sid, active: stoppingProtocolV3,
                supersededSessionId: supersededSessionId, position: position, isPaused: isPaused)
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

    private func normalizedQualityPreference(_ quality: String?) -> String? {
        let normalized = ApplePlaybackQuality.normalizeStoredId(quality)
        return normalized == ApplePlaybackQuality.autoId ? nil : normalized
    }

    private func protocolV3QualityPreference(_ quality: String?) -> String {
        let serverId = ApplePlaybackQuality.protocolV3QualityId(quality)
        if ApplePlaybackQuality.settingsOptions.contains(where: { $0.id == serverId }) {
            return AppleQualityAxes.split(serverId).resolution
        }
        return serverId
    }

    private func protocolV3TrackId(fileId: Int, kind: String, index: Int) -> String {
        "file:\(fileId):\(kind):\(index)"
    }

    /// Pick the best version for the user's preferred quality. The server does
    /// the compatibility filtering from the reported capability snapshot and
    /// may answer with a different `effective_media_file_id`; this ranking step
    /// only decides which version the request asks for.
    static func selectVersion(
        from versions: [FileVersion],
        lastFileId: Int?,
        preferredQuality: String?
    ) -> FileVersion {
        let ranked = versions.sorted {
            score(for: $0, preferredQuality: preferredQuality) >
                score(for: $1, preferredQuality: preferredQuality)
        }

        if let preferredQuality,
           let matchingQuality = ranked.first(where: {
               qualityMatches($0.resolution, preferredQuality: preferredQuality)
           }) {
            return matchingQuality
        }

        if let lastFileId,
           let lastUsed = versions.first(where: { $0.fileId == lastFileId }) {
            return lastUsed
        }

        return ranked.first ?? versions[0]
    }

    private static func score(for version: FileVersion, preferredQuality: String?) -> Int {
        var score = resolutionRank(version.resolution) * 10

        if let preferredQuality {
            if preferredQuality == "original" {
                score += 5
            } else if qualityMatches(version.resolution, preferredQuality: preferredQuality) {
                score += 100
            } else if resolutionRank(version.resolution) > resolutionRank(preferredQuality) {
                score -= 50
            }
        }

        return score
    }

    private func requestedQualityPreference(
        preferredQuality: String?,
        selectedVersion: FileVersion,
        hasManualSelection: Bool
    ) -> String? {
        guard hasManualSelection else {
            return preferredQuality
        }

        return selectedVersion.resolution ?? preferredQuality ?? "original"
    }

    private static func qualityMatches(_ resolution: String?, preferredQuality: String) -> Bool {
        let versionRank = resolutionRank(resolution)
        if preferredQuality == ApplePlaybackQuality.originalId {
            return versionRank > 0
        }
        let requestedRank = resolutionRank(preferredQuality)
        return versionRank > 0 && versionRank <= requestedRank
    }

    private static func resolutionRank(_ value: String?) -> Int {
        guard let value = value?.lowercased() else { return 0 }

        if value.contains("2160") || value.contains("4k") {
            return 4
        }
        if value.contains("1080") {
            return 3
        }
        if value.contains("720") {
            return 2
        }
        if value.contains("480") {
            return 1
        }
        return 0
    }

}
