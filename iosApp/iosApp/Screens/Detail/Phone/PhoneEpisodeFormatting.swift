#if !os(tvOS)
import Foundation

/// Labels for PhoneEpisodeRail cards.
enum PhoneEpisodeFormatting {
    static func title(for episode: EpisodeListItem) -> String {
        episode.title ?? "Episode \(episode.episodeNumber)"
    }

    static func metadataLine(for episode: EpisodeListItem) -> String? {
        var parts: [String] = []
        if let airDate = DetailDateFormatting.abbreviatedDate(episode.airDate) {
            parts.append(airDate)
        }
        if let runtime = MediaTextFormatting.runtime(minutes: episode.runtime) {
            parts.append(runtime)
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
}
#endif
