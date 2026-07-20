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

    init(
        watchDetail: WatchDetail,
        selectedVersion: FileVersion,
        session: PlaybackSessionResponse,
        activeQualityId: String = ApplePlaybackQuality.autoId
    ) {
        self.watchDetail = watchDetail
        self.selectedVersion = selectedVersion
        self.session = session
        self.activeQualityId = activeQualityId
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
    /// The exact request that started the current session, kept as the
    /// template for a silent same-plan renewal after the server loses the
    /// session (restart, idle reap, expired reconstruct token).
    private var lastStartRequest: StartPlaybackRequest?

    private func adoptSession(_ session: PlaybackSessionResponse) {
        sessionId = session.sessionId
        currentSession = session
        RecentSessionTracker.shared.record(sessionID: session.sessionId)
        #if os(iOS) || os(tvOS)
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

    private struct ClientPlaybackPlan {
        let selectedVersion: FileVersion
        let playMethod: String?
        let prefersSDRTranscode: Bool
        let capabilities: (
            codecsVideo: [String],
            codecsAudio: [String],
            containers: [String],
            maxResolution: String?,
            hdr: Bool
        )
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
        let preferredQuality = normalizedQualityPreference(
            preferredQualityOverride ?? PlayerSettings.shared.preferredQuality
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

            initiallySelectedVersion = selectVersion(
                from: watchDetail,
                preferredQuality: preferredQuality
            )
        }
        let playbackPlan = planClientPlayback(
            watchDetail: watchDetail,
            initiallySelectedVersion: initiallySelectedVersion,
            preferredQuality: preferredQuality
        )
        let selectedVersion = playbackPlan.selectedVersion
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
        // Without an explicit pick, send the server's own detail-resolved
        // effective audio index. /playback/start only consults saved audio
        // prefs for episodes (its series-id lookup is empty for movies), so
        // a movie's remembered track would otherwise be dropped here even
        // though the watch detail above already resolved it.
        let request = StartPlaybackRequest(
            fileId: selectedVersion.fileId,
            profileId: profileId,
            playMethod: playbackPlan.playMethod,
            startPosition: effectiveStartPosition,
            audioTrackIndex: preferredAudioTrackIndex ?? selectedVersion.effectiveAudioTrackIndex,
            preserveDirectAudioSelection: playbackPlan.playMethod == PlaybackDeliveryStrategy.direct.name,
            codecsVideo: playbackPlan.capabilities.codecsVideo,
            codecsAudio: playbackPlan.capabilities.codecsAudio,
            containers: playbackPlan.capabilities.containers,
            maxResolution: playbackPlan.capabilities.maxResolution,
            hdr: playbackPlan.capabilities.hdr
        )

        logger.info("Starting session for fileId=\(selectedVersion.fileId, privacy: .public)")
        let initialSession: PlaybackSessionResponse = try await ContinuumAPI.shared.post(
            "/api/v1/playback/start",
            body: request
        )
        lastStartRequest = request
        logger.info(
            "Session started: method=\(initialSession.playMethod, privacy: .public), streamUrl=\(initialSession.streamUrl, privacy: .public)"
        )

        var session = try await preparePlaybackSessionIfNeeded(
            initialSession,
            watchDetail: watchDetail,
            selectedVersion: selectedVersion,
            preferredQuality: resolvedQualityPreference,
            effectiveStartPosition: effectiveStartPosition,
            prefersSDRTranscode: playbackPlan.prefersSDRTranscode
        )
        // Older direct-play servers that ignore `startPosition` may still echo
        // the stored resume point; force the caller's chosen start position
        // locally so the player doesn't snap elsewhere after bootstrap. Do not
        // do this for HLS: remux manifests are player-local timelines and carry
        // the movie-time mapping in `timelineOffsetSeconds`.
        if let effectiveStartPosition,
           PlaybackDeliveryStrategy(playMethod: session.playMethod) == .direct {
            session.position = effectiveStartPosition
        }

        adoptSession(session)
        return PreparedPlayback(
            watchDetail: watchDetail,
            selectedVersion: selectedVersion,
            session: session,
            activeQualityId: ApplePlaybackQuality.activeQualityId(
                requestedQualityId: resolvedQualityPreference,
                selectedVersion: selectedVersion,
                delivery: PlaybackDeliveryStrategy(playMethod: session.playMethod)
            )
        )
    }

    enum DirectSessionRenewalError: Error {
        /// No live direct-play session (or no captured start request) to
        /// renew — the caller must run a full visible renewal instead.
        case noRenewableSession
        /// The server re-planned playback (different delivery or file); the
        /// renewed session cannot be adopted in place.
        case planChanged(playMethod: String, mediaFileId: Int?)
    }

    /// Renews a lost direct-play session in place: re-POSTs the captured
    /// start request (same file, same capability set) at the given position
    /// and adopts the new session id/stream URL without touching playback.
    /// The bytes of a direct-play stream are the file itself, so a renewed
    /// session serves the identical content and the source proxy can simply
    /// retarget. Throws `planChanged` — after best-effort stopping the
    /// unwanted new session so it doesn't hold a concurrency-cap slot —
    /// when the server answers with anything but direct play of the same
    /// file.
    func renewDirectSession(
        position: Double,
        audioTrackIndex: Int?
    ) async throws -> PlaybackSessionResponse {
        guard let template = lastStartRequest,
              let current = currentSession,
              PlaybackDeliveryStrategy(playMethod: current.playMethod) == .direct else {
            throw DirectSessionRenewalError.noRenewableSession
        }
        let normalizedPosition = position.isFinite ? max(0, position) : 0
        let request = StartPlaybackRequest(
            fileId: template.fileId,
            profileId: template.profileId,
            playMethod: template.playMethod,
            startPosition: normalizedPosition,
            audioTrackIndex: audioTrackIndex ?? template.audioTrackIndex,
            preserveDirectAudioSelection: template.preserveDirectAudioSelection,
            codecsVideo: template.codecsVideo,
            codecsAudio: template.codecsAudio,
            containers: template.containers,
            maxResolution: template.maxResolution,
            hdr: template.hdr,
            disableProgressPersistence: template.disableProgressPersistence
        )
        logger.info(
            "Renewing direct session fileId=\(template.fileId, privacy: .public) position=\(normalizedPosition, privacy: .public)"
        )
        var renewed: PlaybackSessionResponse = try await ContinuumAPI.shared.post(
            "/api/v1/playback/start",
            body: request
        )
        guard PlaybackDeliveryStrategy(playMethod: renewed.playMethod) == .direct,
              renewed.mediaFileId == current.mediaFileId else {
            try? await ContinuumAPI.shared.delete("/api/v1/playback/\(renewed.sessionId)")
            throw DirectSessionRenewalError.planChanged(
                playMethod: renewed.playMethod,
                mediaFileId: renewed.mediaFileId
            )
        }
        // Same rule as startSession's direct path: pin the caller's position
        // locally so a server echoing the stored resume point can't snap the
        // timeline elsewhere.
        renewed.position = normalizedPosition
        lastStartRequest = request
        adoptSession(renewed)
        consecutiveProgressFailures = 0
        emittedOrphanedSessionWarning = false
        logger.info("Direct session renewed: \(renewed.sessionId, privacy: .public)")
        return renewed
    }

    func restartCurrentTranscode(
        selectedVersion: FileVersion,
        seekSeconds: Double,
        qualityId: String? = nil
    ) async throws -> PlaybackSessionResponse {
        guard let currentSession else {
            throw APIError.unsupportedMedia("No active playback session")
        }

        let preferredQuality = qualityId ?? requestedQualityPreference(
            preferredQuality: normalizedQualityPreference(PlayerSettings.shared.preferredQuality),
            selectedVersion: selectedVersion,
            hasManualSelection: true
        )
        let qualityOption = ApplePlaybackQuality.resolvedRequestOption(
            preferredQualityId: preferredQuality,
            selectedVersion: selectedVersion,
            delivery: PlaybackDeliveryStrategy(playMethod: currentSession.playMethod)
        )
        let currentDelivery = PlaybackDeliveryStrategy(playMethod: currentSession.playMethod)
        let forcedByQuality = ApplePlaybackQuality.shouldForceTranscode(
            preferredQualityId: preferredQuality,
            selectedVersion: selectedVersion
        )
        let useCopyVideo = currentDelivery == .remux
            || qualityOption.isOriginal
            || (!forcedByQuality && currentDelivery != .transcode)
        let transcodeRequest = TranscodeStartRequest(
            sessionId: currentSession.sessionId,
            seekSeconds: seekSeconds,
            targetResolution: useCopyVideo ? "" : ApplePlaybackQuality.targetResolution(
                for: qualityOption,
                selectedVersion: selectedVersion
            ),
            targetCodecVideo: useCopyVideo ? "copy" : "h264",
            targetCodecAudio: "aac",
            targetBitrateKbps: useCopyVideo ? 0 : ApplePlaybackQuality.targetBitrateKbps(
                for: qualityOption,
                selectedVersion: selectedVersion
            ),
            segmentDuration: 2,
            subtitleTrackIndex: -1,
            subtitleBurnIn: false
        )

        logger.info(
            "Restarting current transcode session=\(currentSession.sessionId, privacy: .public) seek=\(seekSeconds, privacy: .public)"
        )
        let transcodeResponse = try await ContinuumAPI.shared.startTranscode(
            request: transcodeRequest
        )
        let restartedSession = PlaybackSessionResponse(
            sessionId: transcodeResponse.sessionId,
            userId: currentSession.userId,
            profileId: currentSession.profileId,
            mediaFileId: currentSession.mediaFileId,
            playMethod: transcodeResponse.canSeekAnywhere
                ? PlaybackDeliveryStrategy.transcode.name
                : PlaybackDeliveryStrategy.remux.name,
            position: transcodeResponse.playerStartSeconds,
            isPaused: false,
            streamUrl: transcodeResponse.manifestUrl,
            audioTrackIndex: currentSession.audioTrackIndex,
            durationSeconds: transcodeResponse.durationSeconds ?? currentSession.durationSeconds,
            timelineOffsetSeconds: transcodeResponse.timelineOffsetSeconds,
            subtitleUrls: currentSession.subtitleUrls,
            playbackInfo: currentSession.playbackInfo
        )
        adoptSession(restartedSession)
        return restartedSession
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

    private func preparePlaybackSessionIfNeeded(
        _ session: PlaybackSessionResponse,
        watchDetail: WatchDetail,
        selectedVersion: FileVersion,
        preferredQuality: String?,
        effectiveStartPosition: Double?,
        prefersSDRTranscode: Bool
    ) async throws -> PlaybackSessionResponse {
        // Trust the server's selected delivery strategy: remux/transcode
        // responses still need the HLS pipeline kicked off via
        // /playback/transcode/start.
        let strategy = PlaybackDeliveryStrategy(playMethod: session.playMethod)

        guard strategy != .direct else {
            return session
        }
        logger.info("Requesting HLS delivery: \(strategy.name, privacy: .public)")

        // Resume point for the HLS manifest. "Start over" forces 0 so the
        // server generates a fresh segment window from the top of the file
        // — the stored `userData.positionSeconds` would otherwise win here.
        let resumeSeconds = effectiveStartPosition ?? watchDetail.userData?.positionSeconds ?? session.position

        // Remux = codec copy in HLS container (original video quality, AAC audio).
        // Transcode = server re-encodes video at the requested target.
        let isRemux = strategy == .remux
        let qualityOption = ApplePlaybackQuality.resolvedRequestOption(
            preferredQualityId: preferredQuality,
            selectedVersion: selectedVersion,
            delivery: strategy
        )
        let useCopyVideo = isRemux || qualityOption.isOriginal
        let transcodeRequest = TranscodeStartRequest(
            sessionId: session.sessionId,
            seekSeconds: resumeSeconds,
            targetResolution: useCopyVideo ? "" : ApplePlaybackQuality.targetResolution(
                for: qualityOption,
                selectedVersion: selectedVersion
            ),
            targetCodecVideo: useCopyVideo ? "copy" : "h264",
            targetCodecAudio: "aac",
            targetBitrateKbps: useCopyVideo ? 0 : ApplePlaybackQuality.targetBitrateKbps(
                for: qualityOption,
                selectedVersion: selectedVersion
            ),
            segmentDuration: 2,
            subtitleTrackIndex: -1,
            subtitleBurnIn: false
        )

        let transcodeResponse: TranscodeStartResponse
        do {
            transcodeResponse = try await ContinuumAPI.shared.post(
                "/api/v1/playback/transcode/start",
                body: transcodeRequest
            )
        } catch {
            // Two distinct 422 cases the server emits:
            //   1. Copy-mode request against an older server without the
            //      codec-copy bypass — fall back to 1080p h264 transcode.
            //   2. Non-copy transcode request against a 4K source without
            //      `allow_4k_transcode=true` and no lower-res alternate
            //      (the "no_alternate_version" guard). Only way past that
            //      guard is to ask for copy mode, which skips the check.
            //      Common on simulator where caps only advertise h264.
            // CDNs often replace 4xx JSON with HTML, so the `no_alternate`
            // substring check is best-effort; trust the 422 code.
            let isRecoverable: Bool = {
                if case let HTTPError.http(statusCode, body) = error {
                    return statusCode == 422 || (body ?? "").contains("no_alternate")
                }
                return false
            }()
            guard isRecoverable else { throw error }

            if isRemux {
                logger.warning("4K copy rejected, falling back to 1080p transcode")
                let fallback = TranscodeStartRequest(
                    sessionId: session.sessionId,
                    seekSeconds: resumeSeconds,
                    targetResolution: "1080p",
                    targetCodecVideo: "h264",
                    targetCodecAudio: "aac",
                    targetBitrateKbps: 6000,
                    segmentDuration: 2,
                    subtitleTrackIndex: -1,
                    subtitleBurnIn: false
                )
                transcodeResponse = try await ContinuumAPI.shared.post(
                    "/api/v1/playback/transcode/start",
                    body: fallback
                )
            } else {
                if prefersSDRTranscode {
                    throw APIError.unsupportedMedia(
                        "This iPhone build cannot direct-play this HDR source yet. "
                        + "Add a 1080p/SDR version for this item or enable 4K transcoding "
                        + "on the Silo server."
                    )
                }
                #if targetEnvironment(simulator)
                // Simulator's software HEVC decoder can't keep up with 4K in
                // real time. Surface a readable error instead of asking the
                // server for codec-copy — that would succeed server-side but
                // stall the display pipeline as every decoded frame arrives
                // too late to show, leaving a black screen.
                throw APIError.unsupportedMedia(
                    "This 4K content cannot be played on the iOS simulator. "
                    + "Test on a real Apple TV or iPhone, enable 4K transcoding "
                    + "on the Silo server, or add a lower-resolution version."
                )
                #else
                logger.warning("Transcode rejected and no lower server fallback is available")
                throw APIError.unsupportedMedia(
                    "4K Transcoding has been disabled by the server Admin. Adjust your settings or choose a lower quality version."
                )
                #endif
            }
        }

        if let switchedFileId = transcodeResponse.switchedFileId {
            logger.info("Server switched playback to fileId=\(switchedFileId, privacy: .public)")
        }

        let effectiveStrategy: PlaybackDeliveryStrategy = transcodeResponse.canSeekAnywhere
            ? .transcode
            : .remux
        if effectiveStrategy != strategy {
            logger.info(
                "HLS delivery mode changed during bootstrap requested=\(strategy.name, privacy: .public) effective=\(effectiveStrategy.name, privacy: .public)"
            )
        }

        return PlaybackSessionResponse(
            sessionId: transcodeResponse.sessionId,
            userId: session.userId,
            profileId: session.profileId,
            mediaFileId: session.mediaFileId,
            // Use the effective post-bootstrap HLS mode, not just the
            // originally requested strategy. The server can promote seeked
            // copy-mode requests into real transcodes so resumed playback lands
            // on independently decodable segments.
            playMethod: effectiveStrategy.name,
            position: transcodeResponse.playerStartSeconds,
            isPaused: false,
            streamUrl: transcodeResponse.manifestUrl,
            audioTrackIndex: session.audioTrackIndex,
            durationSeconds: transcodeResponse.durationSeconds ?? session.durationSeconds,
            timelineOffsetSeconds: transcodeResponse.timelineOffsetSeconds,
            subtitleUrls: session.subtitleUrls,
            playbackInfo: session.playbackInfo
        )
    }

    /// Codec/container capabilities reported to the server. Returned as a
    /// simple tuple since the wire body is flat — there's no transport
    /// struct to reify on iOS.
    ///
    /// The previous Apple bootstrap still claimed broader direct-play
    /// coverage (`av1`, `vp9`, `mpeg2video`, etc.), but the live PlayerCore path only direct
    /// decodes H.264/HEVC. Keep this list truthful so the server does not
    /// select versions the Apple stack cannot actually open.
    ///
    /// These caps describe what the direct startup path can request from the
    /// server. iPhone HDR files may still switch off PlayerCore later if VT
    /// rejects the stream, but that backend handoff needs the original direct
    /// source URL first, so we keep capability reporting truthful here.
    private func makeClientCaps(avoidDirectHDRPlayback: Bool) -> (
        codecsVideo: [String],
        codecsAudio: [String],
        containers: [String],
        maxResolution: String?,
        hdr: Bool
    ) {
        #if targetEnvironment(simulator)
        return (
            codecsVideo: ["h264"],
            codecsAudio: ["aac", "ac3", "eac3", "mp3", "opus", "flac"],
            containers: ["mp4", "mov", "m4v", "mkv"],
            maxResolution: "1080p",
            hdr: false
        )
        #else
        return (
            codecsVideo: avoidDirectHDRPlayback ? ["h264"] : ["h264", "hevc"],
            codecsAudio: [
                "aac", "ac3", "eac3", "dts", "truehd", "flac", "mp3",
                "opus", "vorbis", "pcm", "pcm_s16le", "pcm_s24le"
            ],
            containers: ["mkv", "mp4", "mov", "m4v", "webm", "avi", "ts", "m2ts"],
            maxResolution: avoidDirectHDRPlayback ? "1080p" : nil,
            hdr: !avoidDirectHDRPlayback
        )
        #endif
    }

    private func makeMacClientCaps() -> (
        codecsVideo: [String],
        codecsAudio: [String],
        containers: [String],
        maxResolution: String?,
        hdr: Bool
    ) {
        (
            codecsVideo: ["h264", "hevc"],
            codecsAudio: ["aac", "ac3", "eac3", "alac", "mp3"],
            containers: ["mp4", "mov", "m4v"],
            maxResolution: nil,
            hdr: true
        )
    }

    private func makeMPEG2DirectClientCaps() -> (
        codecsVideo: [String],
        codecsAudio: [String],
        containers: [String],
        maxResolution: String?,
        hdr: Bool
    ) {
        var caps = makeClientCaps(avoidDirectHDRPlayback: false)
        if !caps.codecsVideo.contains(where: { $0.caseInsensitiveCompare("mpeg2video") == .orderedSame }) {
            caps.codecsVideo.append("mpeg2video")
        }
        return caps
    }

    private func planClientPlayback(
        watchDetail: WatchDetail,
        initiallySelectedVersion: FileVersion,
        preferredQuality: String?
    ) -> ClientPlaybackPlan {
        let requestedTranscode = ApplePlaybackQuality.shouldForceTranscode(
            preferredQualityId: preferredQuality,
            selectedVersion: initiallySelectedVersion
        )
        #if os(macOS)
        return ClientPlaybackPlan(
            selectedVersion: initiallySelectedVersion,
            playMethod: requestedTranscode
                ? PlaybackDeliveryStrategy.transcode.name
                : PlaybackDeliveryStrategy.direct.name,
            prefersSDRTranscode: false,
            capabilities: makeMacClientCaps()
        )
        #else
        return ClientPlaybackPlan(
            selectedVersion: initiallySelectedVersion,
            playMethod: requestedTranscode
                ? PlaybackDeliveryStrategy.transcode.name
                : PlaybackDeliveryStrategy.direct.name,
            prefersSDRTranscode: false,
            capabilities: isMPEG2Video(initiallySelectedVersion)
                ? makeMPEG2DirectClientCaps()
                : makeClientCaps(avoidDirectHDRPlayback: false)
        )
        #endif
    }

    private func isMPEG2Video(_ version: FileVersion) -> Bool {
        normalizedVideoCodec(version.codecVideo) == "mpeg2video"
    }

    private func normalizedVideoCodec(_ raw: String?) -> String? {
        switch normalizedToken(raw) {
        case "h264", "h.264", "avc", "avc1":
            return "h264"
        case "hevc", "h265", "h.265", "hvc1", "hev1":
            return "hevc"
        case "mpeg2", "mpeg-2", "mpeg2video", "mpeg-2 video", "mp2v":
            return "mpeg2video"
        default:
            return normalizedToken(raw)
        }
    }

    private func normalizedToken(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let token = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return token.isEmpty ? nil : token
    }

    private func normalizedQualityPreference(_ quality: String?) -> String? {
        let normalized = ApplePlaybackQuality.normalizeStoredId(quality)
        return normalized == ApplePlaybackQuality.autoId ? nil : normalized
    }

    /// Pick the best version for the user's preferred quality. Compatibility
    /// filtering happens separately in `planClientPlayback`; this ranking step
    /// only decides the user's preferred source before device-specific fallbacks
    /// are applied.
    private func selectVersion(
        from watchDetail: WatchDetail,
        preferredQuality: String?
    ) -> FileVersion {
        let ranked = watchDetail.versions.sorted {
            score(for: $0, preferredQuality: preferredQuality) >
                score(for: $1, preferredQuality: preferredQuality)
        }

        if let preferredQuality,
           let matchingQuality = ranked.first(where: {
               qualityMatches($0.resolution, preferredQuality: preferredQuality)
           }) {
            return matchingQuality
        }

        if let lastFileId = watchDetail.userData?.lastFileId,
           let lastUsed = watchDetail.versions.first(where: { $0.fileId == lastFileId }) {
            return lastUsed
        }

        return ranked.first ?? watchDetail.versions[0]
    }

    private func score(for version: FileVersion, preferredQuality: String?) -> Int {
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

    private func qualityMatches(_ resolution: String?, preferredQuality: String) -> Bool {
        let versionRank = resolutionRank(resolution)
        let requestedRank = resolutionRank(preferredQuality)
        return versionRank > 0 && versionRank <= requestedRank
    }

    private func resolutionRank(_ value: String?) -> Int {
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
