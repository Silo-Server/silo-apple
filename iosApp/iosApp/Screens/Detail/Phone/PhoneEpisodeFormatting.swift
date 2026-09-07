#if !os(tvOS)
import SwiftUI

/// Shared display formatting for the compact episode rail and expanded iPad
/// rows. Keeping these labels in one seam prevents the two adaptive layouts
/// from drifting as metadata rules evolve.
enum PhoneEpisodeFormatting {
    static func title(for episode: EpisodeListItem) -> String {
        episode.title ?? "Episode \(episode.episodeNumber)"
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

/// Long-press menu shared by the compact episode card and the expanded iPad
/// row: Play, then the watched toggle. Mirrors the tvOS episode rail. The
/// caller flips its optimistic state first and rolls back only on failure.
struct PhoneEpisodeContextActions: View {
    let episode: EpisodeListItem
    let isPlayed: Bool
    let onPlay: (() -> Void)?
    let onSetWatched: ((Bool) async -> Bool)?
    @Binding var playedOverride: Bool?

    var body: some View {
        if let onPlay {
            Button(action: onPlay) {
                Label(
                    "Play S\(episode.seasonNumber):E\(episode.episodeNumber)",
                    systemImage: "play.fill"
                )
            }
        }

        if let onSetWatched {
            Button {
                let played = !isPlayed
                Task { @MainActor in
                    playedOverride = played
                    if await onSetWatched(played) == false {
                        playedOverride = nil
                    }
                }
            } label: {
                Label(
                    isPlayed ? "Mark as Unwatched" : "Mark as Watched",
                    systemImage: isPlayed ? "circle" : "checkmark.circle"
                )
            }
        }
    }
}
#endif
