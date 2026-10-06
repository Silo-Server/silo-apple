#if !os(tvOS)
import Foundation

/// Labels for PhoneEpisodeRail cards.
enum PhoneEpisodeFormatting {
    /// "S01E02 · Pilot", the same caption the tvOS Series carousel and Home
    /// episode cards use, so a special (S00) and each episode's place in the
    /// season read at a glance. Just the code when the episode has no title.
    static func title(for episode: EpisodeListItem) -> String {
        let code = EpisodeCardCaption.code(
            season: episode.seasonNumber,
            episode: episode.episodeNumber
        )
        guard let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return code }
        return "\(code) · \(title)"
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
