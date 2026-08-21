import Foundation

/// The single owner of automatic version precedence.
///
/// Both the detail screens (which version's tracks/format to label) and
/// `PlaybackSessionBridge` (which version Play actually asks the server for)
/// resolve through `autoVersion`, so the label can never describe a file
/// other than the one that starts. The precedence matches silo-android's
/// `selectTvDetailDisplayVersion` / `selectPlaybackVersion` pair:
///
/// 1. this visit's explicit Version pick,
/// 2. the item's last-played file,
/// 3. the user's quality preference,
/// 4. the best-ranked version (resolution first, dynamic range as tiebreak).
enum DetailVersionSelection {

    /// Detail-screen entry point: takes the raw stored quality id and
    /// normalizes it through the same closed catalog the bridge uses.
    static func displayVersion(
        versions: [FileVersion],
        selectedFileId: Int?,
        lastFileId: Int?,
        preferredQualityId: String? = nil,
        dynamicRange: VersionDynamicRangePreference.Context = .current
    ) -> FileVersion? {
        autoVersion(
            versions: versions,
            selectedFileId: selectedFileId,
            lastFileId: lastFileId,
            preferredQuality: normalizedQualityPreference(preferredQualityId),
            dynamicRange: dynamicRange
        )
    }

    /// The precedence itself. `preferredQuality` is already normalized —
    /// `nil` means Auto. Callers that hold a raw stored id go through
    /// `displayVersion`; callers that hold a server-owned rung id (an
    /// in-player quality override) pass it verbatim so an additive rung the
    /// local catalog does not know is not silently coerced to Auto.
    static func autoVersion(
        versions: [FileVersion],
        selectedFileId: Int?,
        lastFileId: Int?,
        preferredQuality: String?,
        dynamicRange: VersionDynamicRangePreference.Context = .current
    ) -> FileVersion? {
        if let selectedFileId,
           let selected = versions.first(where: { $0.fileId == selectedFileId }) {
            return selected
        }

        if let lastFileId,
           let lastUsed = versions.first(where: { $0.fileId == lastFileId }) {
            return lastUsed
        }

        let rankedVersions = ranked(versions, preferredQuality: preferredQuality, dynamicRange: dynamicRange)

        // The quality rung. `score` already puts every version inside the
        // requested ceiling above every version outside it, so this is the
        // head of `rankedVersions` whenever anything matches; stating it keeps the
        // precedence readable and independent of the scoring weights.
        if let preferredQuality,
           let matchingQuality = rankedVersions.first(where: {
               qualityMatches($0.resolution, preferredQuality: preferredQuality)
           }) {
            return matchingQuality
        }

        return rankedVersions.first
    }

    /// Deterministic: score descending, then fileId ascending, so an
    /// equal-resolution / equal-dynamic-range tie is never resolved by array
    /// order.
    private static func ranked(
        _ versions: [FileVersion],
        preferredQuality: String?,
        dynamicRange: VersionDynamicRangePreference.Context
    ) -> [FileVersion] {
        versions.sorted { lhs, rhs in
            let ls = score(for: lhs, preferredQuality: preferredQuality, dynamicRange: dynamicRange)
            let rs = score(for: rhs, preferredQuality: preferredQuality, dynamicRange: dynamicRange)
            return ls != rs ? ls > rs : lhs.fileId < rhs.fileId
        }
    }

    private static func normalizedQualityPreference(_ quality: String?) -> String? {
        let normalized = ApplePlaybackQuality.normalizeStoredId(quality)
        return normalized == ApplePlaybackQuality.autoId ? nil : normalized
    }

    private static func score(
        for version: FileVersion,
        preferredQuality: String?,
        dynamicRange: VersionDynamicRangePreference.Context
    ) -> Int {
        var score = resolutionRank(version.resolution) * 10

        if let preferredQuality {
            if preferredQuality == ApplePlaybackQuality.originalId {
                score += 5
            } else if qualityMatches(version.resolution, preferredQuality: preferredQuality) {
                score += 100
            } else if resolutionRank(version.resolution) > resolutionRank(preferredQuality) {
                score -= 50
            }
        }

        score += VersionDynamicRangePreference.bonus(for: version, context: dynamicRange)
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
