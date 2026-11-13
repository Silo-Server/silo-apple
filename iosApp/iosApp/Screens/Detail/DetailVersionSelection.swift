import Foundation

/// The file a detail page shows, and so the file Play and Download use.
/// Edition is the cut; Version is which of its files plays. Auto never
/// changes the cut.
enum DetailVersionSelection {
    /// The pinned file when the viewer picked one in Version. Otherwise Auto:
    /// the best file for the quality preference within the current edition
    /// (the last-played one on a tie). The current edition is the one picked
    /// on the page (`editionId`), else the one last played (`lastEditionKey`,
    /// else the edition of `lastFileId`), else the one holding the best file.
    static func displayVersion(
        versions: [FileVersion],
        selectedFileId: Int?,
        lastFileId: Int?,
        preferredQualityId: String? = nil,
        editionId: String? = nil,
        lastEditionKey: String? = nil
    ) -> FileVersion? {
        if let selectedFileId,
           let selected = versions.first(where: { $0.fileId == selectedFileId }) {
            return selected
        }

        let edition = PlaybackEditions.edition(forKey: editionId, in: versions)
            ?? PlaybackEditions.edition(forKey: lastEditionKey, in: versions)
            ?? PlaybackEditions.edition(forFileId: lastFileId, in: versions)
        // A tie goes to the file last played, such as a Dolby Vision copy
        // picked over an HDR10 one of the same resolution.
        let preferredQuality = normalizedQualityPreference(preferredQualityId)
        func rank(_ version: FileVersion) -> (Int, Int) {
            (score(for: version, preferredQuality: preferredQuality), version.fileId == lastFileId ? 1 : 0)
        }
        return (edition?.versions ?? versions).max { rank($0) < rank($1) }
    }

    /// The stored quality as a resolution cap, or nil when it caps nothing.
    private static func normalizedQualityPreference(_ quality: String?) -> String? {
        let id = ApplePlaybackQuality.normalizeStoredId(quality)
        return id == ApplePlaybackQuality.autoId || id == ApplePlaybackQuality.ultraHDId ? nil : id
    }

    /// Highest wins: the sharpest file within the preference, then a file of
    /// unknown resolution, then the closest file above it.
    private static func score(for version: FileVersion, preferredQuality: String?) -> Int {
        let rank = resolutionRank(version.resolution)
        guard let preferredQuality else { return rank * 10 }
        if qualityMatches(version.resolution, preferredQuality: preferredQuality) {
            return 100 + rank * 10
        }
        return rank > resolutionRank(preferredQuality) ? -rank * 10 : rank * 10
    }

    private static func qualityMatches(_ resolution: String?, preferredQuality: String) -> Bool {
        let versionRank = resolutionRank(resolution)
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
