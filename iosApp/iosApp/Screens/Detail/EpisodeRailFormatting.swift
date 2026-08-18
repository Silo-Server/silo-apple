import Foundation

/// Shared display formatting for episode rails and expanded rows across Apple
/// platforms. Keeping labels and progress rules in one seam prevents the phone,
/// tablet, and tvOS presentations from drifting.
enum EpisodeRailFormatting {
    static func title(for episode: EpisodeListItem) -> String {
        episode.title ?? "Episode \(episode.episodeNumber)"
    }

    static func cardNumberLabel(for episode: EpisodeListItem) -> String {
        "EPISODE \(episode.episodeNumber)"
    }

    static func compactNumberLabel(for episode: EpisodeListItem) -> String {
        String(format: "S%02dE%02d", episode.seasonNumber, episode.episodeNumber)
    }

    static func metadataLine(for episode: EpisodeListItem) -> String? {
        var parts: [String] = []
        if let airDate = DetailDateFormatting.abbreviatedDate(episode.airDate) {
            parts.append(airDate)
        }
        if let runtime = episode.runtime, runtime > 0 {
            parts.append(DetailFacts.episodeRuntime(minutes: runtime))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }

    static func progressFraction(for episode: EpisodeListItem) -> Double? {
        guard let userData = episode.userData,
              let position = userData.positionSeconds,
              let duration = userData.durationSeconds,
              duration > 0,
              position > 0,
              position < duration
        else { return nil }
        return position / duration
    }

    static func accessibilityDescription(
        for episode: EpisodeListItem,
        isCurrent: Bool,
        isPlayed: Bool? = nil
    ) -> String {
        episodeRailAccessibilityLabel(
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            title: episode.title,
            metadata: metadataLine(for: episode),
            isCurrent: isCurrent,
            isPlayed: isPlayed ?? (episode.userData?.played == true)
        )
    }
}
