import Foundation
import OSLog
#if os(tvOS)
import TVServices
#endif

struct PreparedPlayback {
    let watchDetail: WatchDetail
    let selectedVersion: FileVersion
    let session: PlaybackSessionResponse
    let activeQualityId: String
    let protocolV3: PreparedPlaybackV3?

    init(
        watchDetail: WatchDetail,
        selectedVersion: FileVersion,
        session: PlaybackSessionResponse,
        activeQualityId: String = ApplePlaybackQuality.autoId,
        protocolV3: PreparedPlaybackV3? = nil
    ) {
        self.watchDetail = watchDetail
        self.selectedVersion = selectedVersion
        self.session = session
        self.activeQualityId = activeQualityId
        self.protocolV3 = protocolV3
    }

    var displayTitle: String {
        if watchDetail.type == "episode" {
            let season = watchDetail.seasonNumber.map { "S\($0)" } ?? nil
            let episode = watchDetail.episodeNumber.map { "E\($0)" } ?? nil
            let episodeTag = [season, episode].compactMap { $0 }.joined()

            if let seriesTitle = watchDetail.seriesTitle, !seriesTitle.isEmpty, !episodeTag.isEmpty {
                return "\(seriesTitle) • \(episodeTag) • \(watchDetail.title)"
            }
        }

        return watchDetail.title
    }

    /// Build the hero-strip metadata bundle for the tvOS overlay. Reads
    /// everything off the already-fetched `WatchDetail` + `FileVersion` so
    /// the overlay doesn't need a second API call — we only transform the
    /// shapes the server already gave us into display strings.
    func playerMetadata(primaryAudioLayout: String? = nil) -> PlayerMetadata {
        let isEpisode = watchDetail.type == "episode"
        let episodeTag: String? = {
            guard isEpisode else { return nil }
            let s = watchDetail.seasonNumber.map { "S\($0)" }
            let e = watchDetail.episodeNumber.map { "E\($0)" }
            let joined = [s, e].compactMap { $0 }.joined(separator: " · ")
            return joined.isEmpty ? nil : joined
        }()

        var badges: [String] = []
        if let resolution = selectedVersion.resolution, !resolution.isEmpty {
            badges.append(PlayerMetadata.badgeLabel(forResolution: resolution))
        }
        if selectedVersion.hdr == true {
            badges.append("HDR")
        }
        if let codec = selectedVersion.codecVideo?.uppercased(), !codec.isEmpty {
            badges.append(codec)
        }
        if let layout = primaryAudioLayout?.uppercased(), !layout.isEmpty {
            badges.append(layout)
        } else if let audioCodec = selectedVersion.codecAudio?.uppercased(), !audioCodec.isEmpty {
            badges.append(audioCodec)
        }

        return PlayerMetadata(
            seriesTitle: isEpisode ? watchDetail.seriesTitle : nil,
            episodeTag: episodeTag,
            primaryTitle: watchDetail.title,
            year: isEpisode ? nil : watchDetail.year,
            overview: watchDetail.overview,
            badges: badges
        )
    }
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

/// Secondary metadata shown in the tvOS player overlay's hero strip.
/// Populated from the playback session at load time via
/// `PreparedPlayback.playerMetadata(primaryAudioLayout:)` — everything here
/// is already fetched as part of `/api/v1/watch/{id}`, so no extra API
/// calls are needed.
struct PlayerMetadata: Equatable {
    /// For episodes: series title, e.g. "Foundation".
    var seriesTitle: String?
    /// For episodes: "S2 · E3" or similar compact tag.
    var episodeTag: String?
    /// Episode display title when the container is a series episode.
    /// For movies, this is the only title and is shown as the hero title.
    var primaryTitle: String
    /// Release year for movies; nil for episodes.
    var year: Int?
    /// Short plot description. Surfaced as secondary text below the title.
    var overview: String?
    /// Tagged media attributes rendered as pills in the hero strip:
    /// "4K" / "HDR" / "DV" / "HEVC" / "5.1" etc.
    var badges: [String]

    static let empty = PlayerMetadata(
        seriesTitle: nil,
        episodeTag: nil,
        primaryTitle: "",
        year: nil,
        overview: nil,
        badges: []
    )

    /// Map raw resolution strings ("1920x1080", "1080p", "2160p") to the
    /// short marketing label shown in the overlay ("4K" / "FHD" / "HD" / "SD").
    static func badgeLabel(forResolution raw: String) -> String {
        let lower = raw.lowercased()
        if lower.contains("2160") || lower.contains("4k") { return "4K" }
        if lower.contains("1440") { return "QHD" }
        if lower.contains("1080") { return "FHD" }
        if lower.contains("720") { return "HD" }
        if lower.contains("480") { return "SD" }
        return raw.uppercased()
    }
}

enum PlaybackDeliveryStrategy {
    case direct
    case remux
    case transcode

    init(playMethod: String) {
        switch playMethod.lowercased() {
        case "remux":
            self = .remux
        case "transcode":
            self = .transcode
        default:
            self = .direct
        }
    }

    var name: String {
        switch self {
        case .direct:
            return "direct"
        case .remux:
            return "remux"
        case .transcode:
            return "transcode"
        }
    }

    var preservesSourceVideoMetadata: Bool {
        switch self {
        case .direct, .remux:
            return true
        case .transcode:
            return false
        }
    }
}

/// Manages the lifecycle of a playback session with the Continuum API.
/// Handles session creation, periodic progress reporting, and cleanup.
///
/// Apple playback now runs through the shared PlayerCore / AVPlayerBackend
/// stack, so capability reporting needs to stay aligned with what those
/// backends can actually direct-play.
actor PlaybackSessionBridge {
    private static let nearEndResumeSuppressionSeconds: Double = 5
    private static let pastEndResumeClampSeconds: Double = 0.25

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "Playback"
    )

    private var sessionId: String?
    private var currentSession: PlaybackSessionResponse?
    private var protocolV3Available: Bool?

    private struct ActiveProtocolV3 {
        let playbackAttemptId: String
        var planAttemptId: String
        var planAttemptKey: String
        var attemptedPlanKeys: [String]
        var attemptCount: Int
        var clientQualityId: String
        /// The independent bandwidth ceiling captured for this attempt. Every
        /// replan must repeat it or recovery silently widens the connection.
        var bandwidthCapKbps: Int?
        var snapshot: ApplePlaybackV3CapabilitySnapshot
        var serverFeatures: [String]
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

    private struct ActiveQualityIntent {
        var clientQualityId: String
        var bandwidthCapKbps: Int?
    }

    private var activeProtocolV3: ActiveProtocolV3?
    /// Exact session-level quality intent. The cap cannot be reconstructed from
    /// `clientQualityId`: a foreign 1080p/6 Mbps pair maps to Apple's 8 Mbps rung.
    private var activeQualityIntent: ActiveQualityIntent?
    private var protocolV3FirstFramePlanIds: Set<String> = []

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
            try? await ContinuumAPI.shared.stopPlayback(sessionId: staleSessionId)
        }
    }

    private func adoptSession(_ session: PlaybackSessionResponse) {
        sessionId = session.sessionId
        currentSession = session
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
        startFromBeginning: Bool,
        resumePosition: Double? = nil,
        allowNearEndResume: Bool = false,
        preferredQualityOverride: String? = nil
    ) async throws -> PreparedPlayback {
        logger.info("Fetching watch detail for \(contentId, privacy: .public)")
        let watchDetail: WatchDetail = try await ContinuumAPI.shared.get(
            "/api/v1/watch/\(contentId)"
        )
        logger.info("Got \(watchDetail.versions.count) versions, type=\(watchDetail.type, privacy: .public)")

        guard !watchDetail.versions.isEmpty else {
            throw APIError.httpError(statusCode: 404)
        }

        // A mid-stream quality-change replan passes an explicit override
        // (e.g. back to Auto) that must win over the persisted setting.
        let playerSettings = PlayerSettings.shared
        let preferredQuality = normalizedQualityPreference(
            preferredQualityOverride ?? playerSettings.preferredQuality
        )
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

        // Quality preference is still used downstream to pick the transcode
        // target if the server decides remux/transcode is needed. The server
        // itself infers delivery strategy from the codec/container caps
        // below and does not read a `quality_preference` field.
        // An explicit override is the user's in-player choice — honor it
        // directly instead of re-deriving from the manually selected version
        // (which would report the version's native tier as the active quality).
        let resolvedQualityPreference = preferredQualityOverride != nil
            ? preferredQuality
            : requestedQualityPreference(
                preferredQuality: preferredQuality,
                selectedVersion: selectedVersion,
                hasManualSelection: preferredFileId != nil
            )
        let profileId = await TokenStore.shared.getProfileId()
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
            audioTrackIndex: preferredAudioTrackIndex ?? selectedVersion.effectiveAudioTrackIndex,
            subtitleTrackIndex: preferredSubtitleTrackIndex
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
        subtitleTrackIndex: Int?
    ) async throws -> PreparedPlayback {
        if protocolV3Available == nil {
            let capability = try await ContinuumAPI.shared.playbackV3Capability()
            protocolV3Available = capability.enabled
                && capability.protocolVersions.contains(PlaybackProtocolV3.version)
                && capability.features.contains(PlaybackProtocolV3.planFeature)
        }
        // A server that cannot speak v3 cannot serve this client at all; there
        // is no downgrade path left to take.
        guard protocolV3Available == true else {
            throw PlaybackV3TerminalFailure(
                reason: "server_upgrade_required",
                message: "This server does not support the playback protocol this app requires. Update the server to continue.",
                retryable: false
            )
        }

        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        let playbackAttemptId = "apple:\(UUID().uuidString.lowercased())"
        let protocolV3SubtitleTrackIndex = subtitleTrackIndex.flatMap {
            ApplePlaybackV3PlanAdapter.serverCombinedSubtitleIndex(
                ffmpegStreamIndex: $0,
                in: selectedVersion
            )
        }
        let request = PlaybackV3StartRequest(
            protocolVersion: PlaybackProtocolV3.version,
            clientFeatures: ApplePlaybackV3Capabilities.features,
            fileId: selectedVersion.fileId,
            profileId: profileId,
            playbackAttemptId: playbackAttemptId,
            qualityPreference: protocolV3QualityPreference(qualityPreference),
            subtitleFidelityPreference: "preserve",
            startPosition: startPosition,
            audioTrackId: audioTrackIndex.flatMap {
                $0 >= 0 ? protocolV3TrackId(fileId: selectedVersion.fileId, kind: "audio", index: $0) : nil
            },
            audioTrackIndex: audioTrackIndex.flatMap { $0 >= 0 ? $0 : nil },
            subtitleTrackId: protocolV3SubtitleTrackIndex.flatMap {
                $0 >= 0 ? protocolV3TrackId(fileId: selectedVersion.fileId, kind: "subtitle", index: $0) : nil
            },
            subtitleTrackIndex: protocolV3SubtitleTrackIndex,
            metered: false,
            bandwidthEstimateKbps: nil,
            bandwidthCapKbps: bandwidthCapKbps,
            clientCapabilities: snapshot.capabilities,
            clientPlaybackContext: snapshot.context
        )

        logger.info(
            "Starting protocol V3 attempt=\(playbackAttemptId, privacy: .public) fileId=\(selectedVersion.fileId, privacy: .public)"
        )
        let response: PlaybackV3DecisionResponse
        do {
            response = try await ContinuumAPI.shared.startPlaybackV3(request: request)
        } catch let error as HTTPError {
            guard case .network = error else { throw error }
            // Reuse the exact request and playback_attempt_id so an ambiguous
            // first response cannot allocate a second logical attempt.
            response = try await ContinuumAPI.shared.startPlaybackV3(request: request)
        }

        switch response.validatedForApple() {
        case .terminal(let terminal):
            throw PlaybackV3TerminalFailure(
                reason: terminal.reason,
                message: terminal.message,
                retryable: terminal.retryable
            )
        case .incompatible(let allocatedSessionId):
            if let allocatedSessionId {
                try? await ContinuumAPI.shared.stopPlayback(sessionId: allocatedSessionId)
            }
            throw PlaybackV3TerminalFailure(
                reason: "invalid_playback_plan",
                message: "The server returned an incompatible protocol V3 playback plan.",
                retryable: false
            )
        case .playable(let plan, let resolvedSessionId):
            try ApplePlaybackV3PlanAdapter.validate(plan)
            guard let effectiveVersion = watchDetail.versions.first(where: {
                $0.fileId == plan.effectiveMediaFileId
            }) else {
                try? await ContinuumAPI.shared.stopPlayback(sessionId: resolvedSessionId)
                throw PlaybackV3TerminalFailure(
                    reason: "effective_file_unavailable",
                    message: "The server selected a media version that is not present in the item response.",
                    retryable: false
                )
            }
            let session = ApplePlaybackV3PlanAdapter.playbackSession(
                plan: plan,
                sessionId: resolvedSessionId,
                selectedVersion: effectiveVersion
            )
            let planAttemptId = "apple-plan:\(UUID().uuidString.lowercased())"
            // Attempt keys are server-owned; the client only ever echoes them.
            let planAttemptKey = plan.planAttemptKey
            let serverFeatures = response.serverFeatures
            activeProtocolV3 = ActiveProtocolV3(
                playbackAttemptId: playbackAttemptId,
                planAttemptId: planAttemptId,
                planAttemptKey: planAttemptKey,
                attemptedPlanKeys: [planAttemptKey],
                attemptCount: 1,
                clientQualityId: ApplePlaybackQuality.normalizeStoredId(qualityPreference),
                bandwidthCapKbps: bandwidthCapKbps,
                snapshot: snapshot,
                serverFeatures: serverFeatures,
                plan: plan
            )
            activeQualityIntent = ActiveQualityIntent(
                clientQualityId: ApplePlaybackQuality.normalizeStoredId(qualityPreference),
                bandwidthCapKbps: bandwidthCapKbps
            )
            protocolV3FirstFramePlanIds.removeAll()
            sessionId = resolvedSessionId
            currentSession = session
            let preparedV3 = PreparedPlaybackV3(
                playbackAttemptId: playbackAttemptId,
                planAttemptId: planAttemptId,
                planAttemptKey: planAttemptKey,
                outputContextId: snapshot.outputContextId,
                serverFeatures: serverFeatures,
                plan: plan
            )
            logger.info(
                "Protocol V3 plan selected id=\(plan.planId, privacy: .public) delivery=\(plan.delivery, privacy: .public)"
            )
            return PreparedPlayback(
                watchDetail: watchDetail,
                selectedVersion: effectiveVersion,
                session: session,
                activeQualityId: ApplePlaybackQuality.activeQualityId(
                    requestedQualityId: qualityPreference,
                    selectedVersion: effectiveVersion,
                    delivery: PlaybackDeliveryStrategy(playMethod: session.playMethod)
                ),
                protocolV3: preparedV3
            )
        }
    }

    /// Maps a local failure/intent classification onto the protocol's replan
    /// operation. A user-initiated track or quality change is an intent, not a
    /// failure, and carries no `failure` block. An output-route change stays
    /// failure recovery: the route the plan was chosen for no longer exists.
    static func replanOperation(forClassification classification: String) -> String {
        switch classification {
        case "audio_track_changed", "subtitle_track_changed":
            return PlaybackProtocolV3.ReplanOperation.trackChange
        case "quality_changed":
            return PlaybackProtocolV3.ReplanOperation.qualityChange
        default:
            return PlaybackProtocolV3.ReplanOperation.failureRecovery
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
        subtitleTrackIndex: Int? = nil
    ) async throws -> PreparedPlayback? {
        let operation = operation ?? Self.replanOperation(forClassification: classification)
        guard var active = activeProtocolV3,
              let currentSessionId = sessionId else {
            return nil
        }
        let expectedAttempt = ProtocolV3AttemptIdentity(active)
        guard active.attemptCount < 8 else {
            await emitProtocolV3Terminal(
                active: active,
                sessionId: currentSessionId,
                reason: "attempt_limit_reached",
                message: "Playback recovery exhausted the protocol V3 route ladder."
            )
            throw PlaybackV3TerminalFailure(
                reason: "attempt_limit_reached",
                message: "Playback recovery exhausted the protocol V3 route ladder.",
                retryable: false
            )
        }

        if classification == "output_route_changed" {
            active.snapshot = ApplePlaybackV3Capabilities.snapshot()
        }

        let isIntent = operation == PlaybackProtocolV3.ReplanOperation.trackChange
            || operation == PlaybackProtocolV3.ReplanOperation.qualityChange
        let invalidatesIntent = isIntent || classification == "output_route_changed"
        let isSeekReanchor = operation == PlaybackProtocolV3.ReplanOperation.seekReanchor
        if isSeekReanchor,
           !active.serverFeatures.contains(PlaybackProtocolV3.seekReanchorFeature) {
            return nil
        }
        let attemptedKeys = isSeekReanchor
            ? active.attemptedPlanKeys
            : invalidatesIntent
            ? []
            : Array(Set(active.attemptedPlanKeys + [active.planAttemptKey])).sorted()
        let selectedFileId = active.plan.effectiveMediaFileId
        let selectedAudio = (isSeekReanchor ? nil : audioTrackIndex).flatMap { index in
            guard index >= 0 else { return nil }
            return PlaybackV3TrackIdentity(
                id: protocolV3TrackId(fileId: selectedFileId, kind: "audio", index: index),
                index: index
            )
        } ?? active.plan.selectedTracks.audio
        let selectedSubtitle: PlaybackV3TrackIdentity? = {
            if isSeekReanchor { return active.plan.selectedTracks.subtitle }
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
        let requestedClientQualityId = qualityPreference.map {
            ApplePlaybackQuality.normalizeStoredId($0)
        } ?? active.clientQualityId
        let requestedBandwidthCapKbps = AppleQualityAxes.resolvedBitrateCap(
            qualityOverride: qualityPreference,
            fallbackBitrateKbps: active.bandwidthCapKbps
        )
        let eventName = isSeekReanchor
            ? "seek_reanchor_requested"
            : (invalidatesIntent ? "plan_invalidated" : "plan_failed")
        await emitProtocolV3Event(
            active: active,
            sessionId: currentSessionId,
            event: eventName,
            classification: classification,
            fallbackReason: nil,
            diagnostics: ["message": String(message.prefix(512))]
        )
        guard isCurrentProtocolV3Attempt(expectedAttempt, sessionId: currentSessionId) else {
            throw CancellationError()
        }

        let request = PlaybackV3ReplanRequest(
            protocolVersion: PlaybackProtocolV3.version,
            clientFeatures: ApplePlaybackV3Capabilities.features,
            operation: operation,
            playbackAttemptId: active.playbackAttemptId,
            replanRequestId: "apple-replan:\(UUID().uuidString.lowercased())",
            failedPlanId: active.plan.planId,
            planAttemptId: active.planAttemptId,
            planAttemptKey: active.planAttemptKey,
            attemptedPlanKeys: attemptedKeys,
            attemptCount: invalidatesIntent ? 1 : active.attemptCount,
            qualityPreference: protocolV3QualityPreference(requestedClientQualityId),
            positionSeconds: normalizedPosition,
            metered: false,
            bandwidthEstimateKbps: nil,
            bandwidthCapKbps: requestedBandwidthCapKbps,
            selectedTracks: selectedTracks,
            // A user intent carries no failure. Only recovery does.
            failure: isIntent ? nil : PlaybackV3Failure(
                classification: classification,
                message: String(message.prefix(512)),
                decoderName: nil
            ),
            // Apple never mutates a server plan locally, so it never has a
            // mutation to fold into the server's next attempt key.
            localMutations: [],
            clientCapabilities: active.snapshot.capabilities,
            clientPlaybackContext: active.snapshot.context
        )
        let response = try await ContinuumAPI.shared.replanPlaybackV3(
            sessionId: currentSessionId,
            request: request
        )
        let validatedResponse = response.validatedForApple()
        guard isCurrentProtocolV3Attempt(expectedAttempt, sessionId: currentSessionId) else {
            discardStaleProtocolV3Response(validatedResponse)
            throw CancellationError()
        }
        switch validatedResponse {
        case .terminal(let terminal):
            await emitProtocolV3Terminal(
                active: active,
                sessionId: currentSessionId,
                reason: terminal.reason,
                message: terminal.message
            )
            throw PlaybackV3TerminalFailure(
                reason: terminal.reason,
                message: terminal.message,
                retryable: terminal.retryable
            )
        case .incompatible(let allocatedSessionId):
            if let allocatedSessionId, allocatedSessionId != currentSessionId {
                try? await ContinuumAPI.shared.stopPlayback(sessionId: allocatedSessionId)
            }
            await emitProtocolV3Terminal(
                active: active,
                sessionId: currentSessionId,
                reason: "invalid_replan",
                message: "The server returned an incompatible protocol V3 replacement plan."
            )
            throw PlaybackV3TerminalFailure(
                reason: "invalid_replan",
                message: "The server returned an incompatible protocol V3 replacement plan.",
                retryable: false
            )
        case .playable(let nextPlan, let nextSessionId):
            do {
                try ApplePlaybackV3PlanAdapter.validate(nextPlan)
            } catch {
                if nextSessionId != currentSessionId {
                    try? await ContinuumAPI.shared.stopPlayback(sessionId: nextSessionId)
                }
                await emitProtocolV3Terminal(
                    active: active,
                    sessionId: currentSessionId,
                    reason: "invalid_replan",
                    message: error.localizedDescription
                )
                throw error
            }
            let nextKey = nextPlan.planAttemptKey
            guard isSeekReanchor || !attemptedKeys.contains(nextKey) else {
                if nextSessionId != currentSessionId {
                    try? await ContinuumAPI.shared.stopPlayback(sessionId: nextSessionId)
                }
                await emitProtocolV3Terminal(
                    active: active,
                    sessionId: currentSessionId,
                    reason: "replan_loop_detected",
                    message: "The server returned a protocol V3 plan that already failed on this output route."
                )
                throw PlaybackV3TerminalFailure(
                    reason: "replan_loop_detected",
                    message: "The server returned a protocol V3 plan that already failed on this output route.",
                    retryable: false
                )
            }
            guard let selectedVersion = watchDetail.versions.first(where: {
                $0.fileId == nextPlan.effectiveMediaFileId
            }) else {
                if nextSessionId != currentSessionId {
                    try? await ContinuumAPI.shared.stopPlayback(sessionId: nextSessionId)
                }
                await emitProtocolV3Terminal(
                    active: active,
                    sessionId: currentSessionId,
                    reason: "effective_file_unavailable",
                    message: "The replacement plan selected an unavailable media version."
                )
                throw PlaybackV3TerminalFailure(
                    reason: "effective_file_unavailable",
                    message: "The replacement plan selected an unavailable media version.",
                    retryable: false
                )
            }
            let nextSession = ApplePlaybackV3PlanAdapter.playbackSession(
                plan: nextPlan,
                sessionId: nextSessionId,
                selectedVersion: selectedVersion
            )
            if isSeekReanchor {
                guard nextSessionId == currentSessionId,
                      response.serverFeatures.contains(PlaybackProtocolV3.seekReanchorFeature),
                      nextKey == active.planAttemptKey,
                      nextPlan.delivery == active.plan.delivery,
                      nextPlan.effectiveRecipe == active.plan.effectiveRecipe,
                      nextPlan.selectedTracks == active.plan.selectedTracks,
                      nextPlan.transformations == active.plan.transformations,
                      nextPlan.appliedQuirks == active.plan.appliedQuirks,
                      nextPlan.runtimeCorrections == active.plan.runtimeCorrections else {
                    await emitProtocolV3Terminal(
                        active: active,
                        sessionId: currentSessionId,
                        reason: "invalid_seek_reanchor_response",
                        message: "The server changed the route or playback intent during a V3 seek re-anchor."
                    )
                    throw PlaybackV3TerminalFailure(
                        reason: "invalid_seek_reanchor_response",
                        message: "The server changed the route or playback intent during a V3 seek re-anchor.",
                        retryable: false
                    )
                }
            } else {
                active.planAttemptId = "apple-plan:\(UUID().uuidString.lowercased())"
                active.planAttemptKey = nextKey
                active.attemptedPlanKeys = attemptedKeys + [nextKey]
                active.attemptCount = invalidatesIntent ? 1 : active.attemptCount + 1
            }
            active.serverFeatures = response.serverFeatures
            active.plan = nextPlan
            active.clientQualityId = requestedClientQualityId
            active.bandwidthCapKbps = requestedBandwidthCapKbps
            activeProtocolV3 = active
            activeQualityIntent = ActiveQualityIntent(
                clientQualityId: requestedClientQualityId,
                bandwidthCapKbps: requestedBandwidthCapKbps
            )
            sessionId = nextSessionId
            self.currentSession = nextSession
            if isSeekReanchor {
                await emitProtocolV3Event(
                    active: active,
                    sessionId: nextSessionId,
                    event: "seek_reanchored",
                    classification: nil,
                    fallbackReason: nil,
                    diagnostics: ["position_seconds": String(normalizedPosition)]
                )
            }
            let preparedV3 = PreparedPlaybackV3(
                playbackAttemptId: active.playbackAttemptId,
                planAttemptId: active.planAttemptId,
                planAttemptKey: active.planAttemptKey,
                outputContextId: active.snapshot.outputContextId,
                serverFeatures: active.serverFeatures,
                plan: nextPlan
            )
            return PreparedPlayback(
                watchDetail: watchDetail,
                selectedVersion: selectedVersion,
                session: nextSession,
                activeQualityId: ApplePlaybackQuality.activeQualityId(
                    requestedQualityId: requestedClientQualityId,
                    selectedVersion: selectedVersion,
                    delivery: PlaybackDeliveryStrategy(playMethod: nextSession.playMethod)
                ),
                protocolV3: preparedV3
            )
        }
    }

    func reportProtocolV3PlanExecutionStarted() async {
        guard let active = activeProtocolV3, let sessionId else { return }
        for correction in active.plan.runtimeCorrections {
            await emitProtocolV3Event(
                active: active,
                sessionId: sessionId,
                event: "runtime_correction_applied",
                classification: nil,
                fallbackReason: nil,
                diagnostics: ["runtime_correction": correction]
            )
        }
    }

    func reportProtocolV3FirstFrame(milliseconds: Int?) async {
        guard let active = activeProtocolV3, let sessionId else { return }
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
                diagnostics: ["runtime_correction": correction]
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
            try await ContinuumAPI.shared.reportPlaybackRouteEventV3(event)
        } catch {
            logger.warning("Protocol V3 route event \(event.event, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func emitProtocolV3Terminal(
        active: ActiveProtocolV3,
        sessionId: String,
        reason: String,
        message: String
    ) async {
        await emitProtocolV3Event(
            active: active,
            sessionId: sessionId,
            event: "terminal",
            classification: nil,
            fallbackReason: reason,
            diagnostics: ["message": String(message.prefix(512))]
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

        let report = ProgressReport(position: position, isPaused: isPaused)
        do {
            try await ContinuumAPI.shared.postVoid(
                "/api/v1/playback/\(sid)/progress",
                body: report
            )
            consecutiveProgressFailures = 0
            emittedOrphanedSessionWarning = false
            return .success
        } catch {
            consecutiveProgressFailures += 1
            logger.warning(
                "reportProgress failed for session \(sid, privacy: .public) (consecutive=\(self.consecutiveProgressFailures)): \(String(describing: error), privacy: .public)"
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
            try await ContinuumAPI.shared.syncProgress(
                mediaItemId: contentId,
                position: position,
                duration: duration.isFinite && duration > 0 ? duration : 0,
                forceOverwrite: forceOverwrite
            )
            return true
        } catch {
            logger.warning(
                "syncProgress failed for \(contentId, privacy: .public) at \(position, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    // MARK: - Stop Session

    func stopSession(position: Double, isPaused: Bool) async {
        guard let sid = sessionId else { return }
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.recordBreadcrumb(
            category: .playback,
            tag: "PlaybackSession",
            message: "playback session stopped",
            attrs: [
                "session_id": .string(sid),
                "position_seconds": .double(position.isFinite ? max(0, position) : 0),
            ]
        )
        #endif

        if let active = activeProtocolV3 {
            await emitProtocolV3Event(
                active: active,
                sessionId: sid,
                event: "stopped",
                classification: nil,
                fallbackReason: nil,
                diagnostics: ["position_seconds": String(position.isFinite ? max(0, position) : 0)]
            )
        }

        if position.isFinite, position >= 0 {
            let report = ProgressReport(position: position, isPaused: isPaused)
            do {
                try await ContinuumAPI.shared.postVoid(
                    "/api/v1/playback/\(sid)/progress",
                    body: report
                )
            } catch {
                logger.warning(
                    "final stop-session progress report failed for \(sid, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }

        do {
            try await ContinuumAPI.shared.delete("/api/v1/playback/\(sid)")
        } catch {
            // Best-effort delete; the server times out idle sessions on its
            // own, but a missed delete extends the grace period. Log so
            // accumulated failures are observable rather than silent.
            logger.error(
                "stop-session DELETE failed for \(sid, privacy: .public); server-side session may linger until idle timeout: \(String(describing: error), privacy: .public)"
            )
        }
        sessionId = nil
        currentSession = nil
        activeProtocolV3 = nil
        activeQualityIntent = nil
        protocolV3FirstFramePlanIds.removeAll()
        consecutiveProgressFailures = 0
        emittedOrphanedSessionWarning = false

        #if os(tvOS)
        // Nudge the Top Shelf to re-fetch now that progress has advanced.
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
    }

    // MARK: - Helpers

    private static func isPlaybackSessionMissing(_ error: Error) -> Bool {
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
        AppleQualityAxes.split(
            ApplePlaybackQuality.normalizeStoredId(quality)
        ).resolution
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
