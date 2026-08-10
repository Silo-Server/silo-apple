#if !os(tvOS)
import Foundation

/// Shared display formatting for the compact episode rail and expanded iPad
/// rows. Keeping these labels in one seam prevents the two adaptive layouts
/// from drifting as metadata rules evolve.
enum PhoneEpisodeFormatting {
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
            parts.append(formatRuntime(runtime))
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
        isCurrent: Bool
    ) -> String {
        episodeRailAccessibilityLabel(
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            title: episode.title,
            metadata: metadataLine(for: episode),
            isCurrent: isCurrent,
            isPlayed: episode.userData?.played == true
        )
    }

    private static func formatRuntime(_ minutes: Int) -> String {
        if minutes >= 60 {
            return "\(minutes / 60)h \(minutes % 60)m"
        }
        return "\(minutes)m"
    }
}
#endif
