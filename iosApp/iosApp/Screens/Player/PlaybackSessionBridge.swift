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

/// One capability probe per active server, shared by video and audiobook
/// playback. Keeping the in-flight task in the cache prevents two player
/// models starting together from issuing duplicate probes.
actor PlaybackV3CapabilityGate {
    static let shared = PlaybackV3CapabilityGate()

    private let transport: any PlaybackTransport
    private var availabilityByServerId: [String: Bool] = [:]
    private var probeByServerId: [String: Task<Bool, Error>] = [:]

    init(transport: any PlaybackTransport = SiloAPI.shared) {
        self.transport = transport
    }

    func requireNeutralProtocolV3() async throws {
        let serverId = await TokenStore.shared.getActiveServerId()
        let available: Bool
        if let cached = availabilityByServerId[serverId] {
            available = cached
        } else {
            let probe: Task<Bool, Error>
            if let pending = probeByServerId[serverId] {
                probe = pending
            } else {
                probe = Task { [transport] in
                    do {
                        let capability = try await transport.playbackV3Capability()
                        return PlaybackSessionBridge.supportsNeutralProtocolV3(capability)
                    } catch {
                        if PlaybackSessionBridge.isMissingProtocolV3Capability(error) {
                            return false
                        }
                        throw error
                    }
                }
                probeByServerId[serverId] = probe
            }
            do {
                available = try await probe.value
                availabilityByServerId[serverId] = available
                probeByServerId[serverId] = nil
            } catch {
                probeByServerId[serverId] = nil
                throw error
            }
        }

        guard available else {
            throw PlaybackV3TerminalFailure(
                reason: "server_upgrade_required",
                message: "This server does not support the playback protocol this app requires. Update the server to continue.",
                retryable: false
            )
        }
    }
}

/// Manages the lifecycle of a playback session with the Silo API.
/// Handles session creation, periodic progress reporting, and cleanup.
///
/// Apple playback runs entirely through the shared `AVPlayerBackend`, so
/// capability reporting needs to stay aligned with what that backend can
/// actually direct-play.
actor PlaybackSessionBridge {
    private static let nearEndResumeSuppressionSeconds: Double = 5
    private static let pastEndResumeClampSeconds: Double = 0.25

    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Playback"
    )

    /// Every server call this actor makes goes through here. Production passes
    /// nothing and gets `SiloAPI.shared`, so the call sequence is unchanged.
    private let transport: any PlaybackTransport
    /// The gate is a process-wide single-flight cache shared with the audiobook
    /// engine, so the default stays the singleton; a bridge built on a
    /// non-default transport passes the matching gate instead of probing the
    /// network through the shared one.
    private let capabilityGate: PlaybackV3CapabilityGate

    init(
        transport: any PlaybackTransport = SiloAPI.shared,
        capabilityGate: PlaybackV3CapabilityGate = .shared
    ) {
        self.transport = transport
        self.capabilityGate = capabilityGate
    }

    private var sessionId: String?
    private var currentSession: PlaybackSessionResponse?

    /// The server session this bridge currently owns, if any. Wave 2 widens
    /// this into the full `SessionIdentity`.
    var currentSessionId: String? { sessionId }

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

    enum DirectSessionRenewalError: Error {
        case noActiveDirectSession
        case replacementPlanChanged
    }

    private struct StagedProtocolV3Start {
        let playbackAttemptId: String
        let clientQualityId: String
        let bandwidthCapKbps: Int?
        let snapshot: ApplePlaybackV3CapabilitySnapshot
        let serverFeatures: [String]
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
        Task { [transport] in
            try? await transport.stopPlayback(sessionId: staleSessionId)
        }
    }

    private func adoptSession(_ session: PlaybackSessionResponse) {
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
        preferredQualityOverride: String? = nil
    ) async throws -> PreparedPlayback {
        logger.info("Fetching watch detail for \(contentId, privacy: .public)")
        let watchDetail: WatchDetail = try await transport.watchDetail(contentId: contentId)
        logger.info("Got \(watchDetail.versions.count) versions, type=\(watchDetail.type, privacy: .public)")

        guard !watchDetail.versions.isEmpty else {
            throw APIError.httpError(statusCode: 404)
        }

        // A mid-stream quality-change replan passes an explicit override
        // (e.g. back to Auto) that must win over the persisted setting.
        let playerSettings = PlayerSettings.shared
        let preferredQuality = preferredQualityOverride.map {
            ApplePlaybackQuality.protocolV3QualityId($0)
        } ?? normalizedQualityPreference(playerSettings.preferredQuality)
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

        var externalOrdinal = 0
        let candidates = (version.subtitleTracks ?? []).compactMap { track -> PlayerTrack? in
            let isExternal = track.external == true
            let trackId: Int64
            let sourceIndex: Int?
            if isExternal {
                sourceIndex = externalOrdinal
                trackId = SubtitleTrackIdSpace.makeSidecarTrackId(urlIndex: externalOrdinal)
                externalOrdinal += 1
            } else {
                guard let index = track.index else { return nil }
                sourceIndex = nil
                trackId = Int64(index)
            }
            return PlayerTrack(
                trackId: trackId,
                kind: .sub,
                title: track.title ?? track.embeddedTitle,
                lang: track.language,
                codec: track.codec,
                audioChannelsLayout: nil,
                audioChannelCount: nil,
                bitrate: nil,
                isDefault: track.isDefault ?? false,
                isForced: track.forced ?? false,
                isHearingImpaired: track.hearingImpaired ?? false,
                isVisualImpaired: false,
                isExternal: isExternal,
                isSelected: false,
                ffIndex: isExternal ? nil : track.index,
                srcId: sourceIndex
            )
        }
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
        try await capabilityGate.requireNeutralProtocolV3()

        let snapshot = ApplePlaybackV3Capabilities.snapshot()
        cmpLog("[CMP-OUTPUT] phase=start \(snapshot.outputDiagnosticsLogFields)")
        let playbackAttemptId = "apple:\(UUID().uuidString.lowercased())"
        let request = PlaybackV3StartRequest(
            protocolVersion: PlaybackProtocolV3.version,
            clientFeatures: ApplePlaybackV3Capabilities.features,
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
        let response: PlaybackV3DecisionResponse
        do {
            response = try await transport.startPlaybackV3(request: request)
        } catch let error as HTTPError {
            guard case .network = error else { throw error }
            // Reuse the exact request and playback_attempt_id so an ambiguous
            // first response cannot allocate a second logical attempt.
            response = try await transport.startPlaybackV3(request: request)
        }

        let (plan, resolvedSessionId) = try await ApplePlaybackV3PlanAdapter.resolvePlayablePlan(
            response,
            playbackAttemptId: playbackAttemptId,
            snapshot: snapshot
        )
        guard let effectiveVersion = watchDetail.versions.first(where: {
            $0.fileId == plan.effectiveMediaFileId
        }) else {
            try? await transport.stopPlayback(sessionId: resolvedSessionId)
            throw PlaybackV3TerminalFailure(
                reason: "effective_file_unavailable",
                message: "The server selected a media version that is not present in the item response.",
                retryable: false
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
            plan: plan,
            sessionId: resolvedSessionId,
            selectedVersion: effectiveVersion,
            session: session
        )
    }

    private func adoptProtocolV3Start(
        _ staged: StagedProtocolV3Start,
        watchDetail: WatchDetail
    ) -> PreparedPlayback {
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
            bandwidthCapKbps: staged.bandwidthCapKbps,
            snapshot: staged.snapshot,
            serverFeatures: staged.serverFeatures,
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

    /// Creates a fresh V3 session for an expired direct stream, but publishes
    /// it only when the transport can be swapped underneath the existing
    /// source proxy without changing what the player is rendering.
    func renewDirectSession(
        watchDetail: WatchDetail,
        position: Double,
        audioTrackIndex: Int?,
        subtitleTrackIndex: Int?
    ) async throws -> PreparedPlayback {
        guard let active = activeProtocolV3,
              let oldSessionId = sessionId,
              active.plan.delivery == "original_http",
              currentSession?.playMethod.lowercased() == "direct" else {
            throw DirectSessionRenewalError.noActiveDirectSession
        }
        let expectedAttempt = ProtocolV3AttemptIdentity(active)
        guard let requestedVersion = watchDetail.versions.first(where: {
            $0.fileId == active.plan.requestedMediaFileId
        }), let profileId = await TokenStore.shared.getProfileId(),
              !profileId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DirectSessionRenewalError.noActiveDirectSession
        }

        let selectedAudioIndex = audioTrackIndex ?? active.plan.selectedTracks.audio?.index
        let selectedSubtitleIndex = subtitleTrackIndex ?? active.plan.selectedTracks.subtitle?.index
        let staged = try await stageProtocolV3Start(
            watchDetail: watchDetail,
            selectedVersion: requestedVersion,
            profileId: profileId,
            qualityPreference: active.clientQualityId,
            bandwidthCapKbps: active.bandwidthCapKbps,
            startPosition: position.isFinite ? max(0, position) : 0,
            audioTrackIndex: selectedAudioIndex,
            subtitleCombinedIndex: selectedSubtitleIndex
        )
        guard isCurrentProtocolV3Attempt(expectedAttempt, sessionId: oldSessionId) else {
            stopStaleSession(staged.sessionId)
            throw CancellationError()
        }
        guard Self.canRetargetDirectSession(from: active.plan, to: staged.plan) else {
            stopStaleSession(staged.sessionId)
            throw DirectSessionRenewalError.replacementPlanChanged
        }

        let prepared = adoptProtocolV3Start(staged, watchDetail: watchDetail)
        if staged.sessionId != oldSessionId {
            stopStaleSession(oldSessionId)
        }
        return prepared
    }

    static func canRetargetDirectSession(
        from current: PlaybackV3Plan,
        to replacement: PlaybackV3Plan
    ) -> Bool {
        current.delivery == "original_http"
            && replacement.delivery == current.delivery
            && replacement.requestedMediaFileId == current.requestedMediaFileId
            && replacement.effectiveMediaFileId == current.effectiveMediaFileId
            && replacement.stream.protocol == current.stream.protocol
            && replacement.stream.container == current.stream.container
            && replacement.stream.mimeType == current.stream.mimeType
            && replacement.stream.headerRefresh == current.stream.headerRefresh
            && replacement.timeline.streamOriginSeconds == current.timeline.streamOriginSeconds
            && replacement.timeline.timelineOffsetSeconds == current.timeline.timelineOffsetSeconds
            && replacement.timeline.canSeekAnywhere == current.timeline.canSeekAnywhere
            && replacement.timeline.seekRestoration == current.timeline.seekRestoration
            && replacement.selectedTracks == current.selectedTracks
            && replacement.effectiveRecipe == current.effectiveRecipe
            && replacement.claims == current.claims
            && replacement.subtitle.mode == current.subtitle.mode
            && replacement.subtitle.trackId == current.subtitle.trackId
            && replacement.subtitle.artifact?.mimeType == current.subtitle.artifact?.mimeType
            && replacement.subtitle.artifact?.format == current.subtitle.artifact?.format
            && replacement.subtitle.artifact?.timingOriginSeconds == current.subtitle.artifact?.timingOriginSeconds
            && replacement.transformations == current.transformations
            && replacement.appliedQuirks == current.appliedQuirks
            && replacement.runtimeCorrections == current.runtimeCorrections
            && replacement.source == current.source
            && replacement.subtitleFidelityPolicy == current.subtitleFidelityPolicy
    }

    /// Maps a local failure/intent classification onto the protocol's replan
    /// operation. A user-initiated track or quality change is an intent, not a
    /// failure, and carries no `failure` block. An output-route change is also
    /// an intent — nothing failed, the sink capabilities changed — but only a
    /// server advertising `outputChangeFeature` understands the dedicated
    /// operation; against an older server it stays failure recovery carrying
    /// the `output_route_changed` classification.
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
        terminal: PlaybackV3Terminal,
        transport: any PlaybackTransport = SiloAPI.shared
    ) async {
        let event = terminalStartRouteEvent(
            playbackAttemptId: playbackAttemptId,
            snapshot: snapshot,
            terminal: terminal
        )
        do {
            try await transport.reportPlaybackRouteEventV3(event)
        } catch {
            Logger(
                subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
                category: "Playback"
            ).warning(
                "Protocol V3 terminal-start route event failed: \(String(describing: error), privacy: .public)"
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
        // Derived after the guard: the mapping gates the `output_change`
        // operation on what this server advertised for the active plan.
        let operation = operation ?? Self.replanOperation(
            forClassification: classification,
            serverFeatures: active.serverFeatures
        )
        let expectedAttempt = ProtocolV3AttemptIdentity(active)
        guard active.attemptCount < 8 else {
            throw await terminalReplanFailure(
                active: active,
                sessionId: currentSessionId,
                reason: "attempt_limit_reached",
                message: "Playback recovery exhausted the protocol V3 route ladder."
            )
        }

        if classification == "output_route_changed" {
            active.snapshot = outputRouteSnapshot ?? ApplePlaybackV3Capabilities.snapshot()
            cmpLog("[CMP-OUTPUT] phase=route_change \(active.snapshot.outputDiagnosticsLogFields)")
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
            ApplePlaybackQuality.protocolV3QualityId($0)
        } ?? active.clientQualityId
        let requestedBandwidthCapKbps = AppleQualityAxes.resolvedBitrateCap(
            qualityOverride: qualityPreference,
            fallbackBitrateKbps: active.bandwidthCapKbps
        )
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
        let response = try await transport.replanPlaybackV3(
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
            throw await terminalReplanFailure(
                active: active,
                sessionId: currentSessionId,
                reason: terminal.reason,
                message: terminal.message,
                retryable: terminal.retryable
            )
        case .incompatible(let allocatedSessionId):
            throw await terminalReplanFailure(
                active: active,
                sessionId: currentSessionId,
                abandoning: allocatedSessionId,
                reason: "invalid_replan",
                message: "The server returned an incompatible protocol V3 replacement plan."
            )
        case .playable(let nextPlan, let nextSessionId):
            do {
                try ApplePlaybackV3PlanAdapter.validate(nextPlan)
            } catch {
                if nextSessionId != currentSessionId {
                    try? await transport.stopPlayback(sessionId: nextSessionId)
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
                throw await terminalReplanFailure(
                    active: active,
                    sessionId: currentSessionId,
                    abandoning: nextSessionId,
                    reason: "replan_loop_detected",
                    message: "The server returned a protocol V3 plan that already failed on this output route."
                )
            }
            guard let selectedVersion = watchDetail.versions.first(where: {
                $0.fileId == nextPlan.effectiveMediaFileId
            }) else {
                throw await terminalReplanFailure(
                    active: active,
                    sessionId: currentSessionId,
                    abandoning: nextSessionId,
                    reason: "effective_file_unavailable",
                    message: "The replacement plan selected an unavailable media version."
                )
            }
            let nextSession = ApplePlaybackV3PlanAdapter.playbackSession(
                plan: nextPlan,
                sessionId: nextSessionId,
                selectedVersion: selectedVersion,
                serverFeatures: response.serverFeatures
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
                    throw await terminalReplanFailure(
                        active: active,
                        sessionId: currentSessionId,
                        reason: "invalid_seek_reanchor_response",
                        message: "The server changed the route or playback intent during a V3 seek re-anchor."
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
            adoptSession(nextSession)
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
                activeQualityId: ApplePlaybackQuality.activeProtocolV3QualityId(
                    requestedQualityId: requestedClientQualityId,
                    availableQualities: nextPlan.availableQualities
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
            try await transport.reportPlaybackRouteEventV3(event)
        } catch {
            logger.warning("Protocol V3 route event \(event.event, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The replan route ladder's dead end: optionally abandon the replacement
    /// session the server allocated, emit the terminal route event, and hand
    /// back the failure to throw. Naming each reason token and prose message
    /// once per site is the point — they used to be spelled twice.
    private func terminalReplanFailure(
        active: ActiveProtocolV3,
        sessionId: String,
        abandoning: String? = nil,
        reason: String,
        message: String,
        retryable: Bool = false
    ) async -> PlaybackV3TerminalFailure {
        if let abandoning, abandoning != sessionId {
            try? await transport.stopPlayback(sessionId: abandoning)
        }
        await emitProtocolV3Terminal(
            active: active,
            sessionId: sessionId,
            reason: reason,
            message: message
        )
        return PlaybackV3TerminalFailure(reason: reason, message: message, retryable: retryable)
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

        let report = ProgressReport(position: position, isPaused: isPaused)
        do {
            try await transport.reportPlaybackProgress(sessionId: sid, report: report)
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
            try await transport.syncProgress(
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

    func stopSession(position: Double, isPaused: Bool) async {
        guard let sid = sessionId else { return }
        await stopSession(expectedSessionId: sid, position: position, isPaused: isPaused)
    }

    /// Stop a *named* session. A caller that decided to stop while holding an
    /// identity must not stop whatever session happens to be current by the
    /// time it gets here — the same reason the clear at the end of this method
    /// is identity-conditional, applied one await earlier.
    func stopSession(expectedSessionId: String, position: Double, isPaused: Bool) async {
        guard sessionId == expectedSessionId else { return }
        let sid = expectedSessionId
        #if os(iOS) || os(tvOS)
        DiagnosticsCoordinator.recordBreadcrumb(
            category: .playback,
            tag: "PlaybackSession",
            message: "playback session stopped",
            attrs: [
                "session_id": .string(sid),
                // The attribute registry has no float type, so playback
                // position is reported in whole milliseconds.
                "position_ms": .int(Self.diagnosticsPositionMilliseconds(position)),
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
                try await transport.reportPlaybackProgress(sessionId: sid, report: report)
            } catch {
                logger.warning(
                    "final stop-session progress report failed for \(sid, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }

        do {
            try await transport.stopPlayback(sessionId: sid)
        } catch {
            // Best-effort delete; the server times out idle sessions on its
            // own, but a missed delete extends the grace period. Log so
            // accumulated failures are observable rather than silent.
            logger.error(
                "stop-session DELETE failed for \(sid, privacy: .public); server-side session may linger until idle timeout: \(String(describing: error), privacy: .public)"
            )
        }
        // Three awaits happened above; a newer session may have been adopted
        // in the meantime (tvOS background suspend racing an explicit resume).
        // Clearing identity unconditionally would erase that live session and
        // leave progress reporting, renewal and replans without one, so the
        // clear is identity-conditional like every other post-await mutation
        // here. The replacement session runs its own stop, including the tvOS
        // Top Shelf nudge below.
        guard sessionId == sid else { return }
        sessionId = nil
        currentSession = nil
        activeProtocolV3 = nil
        protocolV3FirstFramePlanIds.removeAll()
        consecutiveProgressFailures = 0
        emittedOrphanedSessionWarning = false

        #if os(tvOS)
        // Nudge the Top Shelf to re-fetch now that progress has advanced.
        TVTopShelfContentProvider.topShelfContentDidChange()
        #endif
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
