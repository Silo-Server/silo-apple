import Foundation
import OSLog

/// Content selection for a Protocol V3 start: which file version, audio track,
/// subtitle track, quality rung, and resume position the request should ask
/// for. None of this is session management, so none of it needs the bridge's
/// actor state or the network.
enum PlaybackContentSelection {
    private static let nearEndResumeSuppressionSeconds: Double = 5
    private static let pastEndResumeClampSeconds: Double = 0.25

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "Playback"
    )

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

    /// What a start request asks the server to plan for.
    struct Start {
        let selectedVersion: FileVersion
        let qualityPreference: String?
        let bandwidthCapKbps: Int?
        let startPosition: Double?
        let audioTrackIndex: Int?
        let subtitleTrackIndex: Int?
        let subtitleCombinedIndex: Int?
    }

    static func resolve(
        watchDetail: WatchDetail,
        preferredFileId: Int?,
        preferredAudioTrackIndex: Int?,
        preferredSubtitleTrackIndex: Int?,
        preferredProtocolV3SubtitleIndex: Int?,
        initialSubtitlePreferences: InitialProtocolV3SubtitlePreferences?,
        startFromBeginning: Bool,
        resumePosition: Double?,
        allowNearEndResume: Bool,
        prefersLastUsedVersion: Bool,
        preferredQualityOverride: String?,
        settingsPreferredQuality: String,
        settingsMaxBitrateKbps: Int?
    ) -> Start {
        // A mid-stream quality-change replan passes an explicit override
        // (e.g. back to Auto) that must win over the persisted setting.
        let lastUsedQuality = prefersLastUsedVersion
            ? normalizedQualityPreference(watchDetail.userData?.lastResolution)
            : nil
        let preferredQuality = preferredQualityOverride.map {
            ApplePlaybackQuality.protocolV3QualityId($0)
        } ?? lastUsedQuality
            ?? normalizedQualityPreference(settingsPreferredQuality)
        let selectedVersion = selectStartVersion(
            watchDetail: watchDetail,
            preferredFileId: preferredFileId,
            prefersLastUsedVersion: prefersLastUsedVersion,
            preferredQuality: preferredQuality
        )
        let resolvedAudioTrackIndex = preferredAudioTrackIndex
            ?? selectedVersion.effectiveAudioTrackIndex
        let subtitleIntent = initialProtocolV3SubtitleIntent(
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
            currentAudioLanguage: selectedVersion.audioTracks?.first(where: {
                $0.index == resolvedAudioTrackIndex
            })?.language
        )
        let startPosition = resolvedStartPosition(
            startFromBeginning: startFromBeginning,
            explicitResumePosition: finiteNonNegative(resumePosition),
            storedResumePosition: finiteNonNegative(watchDetail.userData?.positionSeconds),
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
        // Without an explicit pick, send the server's own detail-resolved
        // effective audio index so a movie's remembered track survives.
        return Start(
            selectedVersion: selectedVersion,
            qualityPreference: resolvedQualityPreference,
            bandwidthCapKbps: AppleQualityAxes.resolvedBitrateCap(
                qualityOverride: preferredQualityOverride,
                fallbackBitrateKbps: settingsMaxBitrateKbps
            ),
            startPosition: startPosition,
            audioTrackIndex: resolvedAudioTrackIndex,
            subtitleTrackIndex: subtitleIntent.ffmpegStreamIndex,
            subtitleCombinedIndex: subtitleIntent.combinedIndex
        )
    }

    private static func finiteNonNegative(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func selectStartVersion(
        watchDetail: WatchDetail,
        preferredFileId: Int?,
        prefersLastUsedVersion: Bool,
        preferredQuality: String?
    ) -> FileVersion {
        if let preferredFileId,
           let requestedVersion = watchDetail.versions.first(where: { $0.fileId == preferredFileId }) {
            logger.info(
                "Using manually selected version fileId=\(requestedVersion.fileId, privacy: .public)"
            )
            return requestedVersion
        }
        if prefersLastUsedVersion,
           let lastFileId = watchDetail.userData?.lastFileId,
           let lastUsedVersion = watchDetail.versions.first(where: { $0.fileId == lastFileId }) {
            logger.info(
                "Resuming last-used version fileId=\(lastUsedVersion.fileId, privacy: .public)"
            )
            return lastUsedVersion
        }
        if let preferredFileId {
            logger.warning(
                "Requested fileId=\(preferredFileId, privacy: .public) is unavailable; falling back to automatic selection"
            )
        }
        return selectVersion(
            from: watchDetail.versions,
            lastFileId: watchDetail.userData?.lastFileId,
            preferredQuality: preferredQuality
        )
    }

    // MARK: - Subtitles

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

    // MARK: - Resume position

    static func resolvedStartPosition(
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
            .compactMap(finiteNonNegative)
            .filter { $0 > 0 }
            .min()

        guard let durationHint else {
            return candidatePosition
        }

        if allowNearEndResume {
            guard candidatePosition >= durationHint else {
                return candidatePosition
            }
            let clampedPosition = max(0, durationHint - pastEndResumeClampSeconds)
            logger.warning(
                "Resume position \(candidatePosition, privacy: .public) reached/passed duration hint \(durationHint, privacy: .public); clamping transient resume to \(clampedPosition, privacy: .public)"
            )
            return clampedPosition
        }

        let nearEndCutoff = max(0, durationHint - nearEndResumeSuppressionSeconds)
        guard candidatePosition >= nearEndCutoff else {
            return candidatePosition
        }

        logger.info(
            "Suppressing resume position \(candidatePosition, privacy: .public) near duration hint \(durationHint, privacy: .public); restarting from beginning"
        )
        return 0
    }

    // MARK: - Quality and track identity

    static func normalizedQualityPreference(_ quality: String?) -> String? {
        let normalized = ApplePlaybackQuality.normalizeStoredId(quality)
        return normalized == ApplePlaybackQuality.autoId ? nil : normalized
    }

    static func protocolV3QualityPreference(_ quality: String?) -> String {
        let serverId = ApplePlaybackQuality.protocolV3QualityId(quality)
        if ApplePlaybackQuality.settingsOptions.contains(where: { $0.id == serverId }) {
            return AppleQualityAxes.split(serverId).resolution
        }
        return serverId
    }

    static func protocolV3TrackId(fileId: Int, kind: String, index: Int) -> String {
        "file:\(fileId):\(kind):\(index)"
    }

    static func requestedQualityPreference(
        preferredQuality: String?,
        selectedVersion: FileVersion,
        hasManualSelection: Bool
    ) -> String? {
        guard hasManualSelection else {
            return preferredQuality
        }

        return selectedVersion.resolution ?? preferredQuality ?? "original"
    }

    // MARK: - Version ranking

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
