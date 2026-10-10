import Foundation

/// A card model that may be an episode: Home section rows and catalog rows
/// (search returns episodes on servers with the `video_with_episodes` scope).
protocol EpisodeCaptionSource {
    var type: String { get }
    var title: String { get }
    var seriesTitle: String? { get }
    var seasonNumber: Int? { get }
    var episodeNumber: Int? { get }
}

extension SectionItem: EpisodeCaptionSource {}
extension BrowseItem: EpisodeCaptionSource {}

/// Episode context for card captions. Episode cards are captioned with the
/// series name, so the season/episode code and episode title live on the
/// secondary line ("S01E02 · Pilot") in place of the year. The line is always
/// rendered single-line and tail-truncated so card heights stay uniform
/// across a row.
enum EpisodeCardCaption {
    /// "S01E02" — zero-padded so codes line up across a row.
    static func code(season: Int, episode: Int) -> String {
        String(format: "S%02dE%02d", season, episode)
    }

    static func isEpisode(_ item: some EpisodeCaptionSource) -> Bool {
        item.type.lowercased() == "episode"
    }

    static func code(for item: some EpisodeCaptionSource) -> String? {
        guard isEpisode(item),
              let season = item.seasonNumber,
              let episode = item.episodeNumber else { return nil }
        return code(season: season, episode: episode)
    }

    /// The episode's own title, or `nil` when it is empty or merely repeats
    /// the series name (some scanners fill unknown titles that way).
    static func episodeTitle(for item: some EpisodeCaptionSource) -> String? {
        guard isEpisode(item) else { return nil }
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        if let series = item.seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
           series.caseInsensitiveCompare(title) == .orderedSame {
            return nil
        }
        return title
    }

    /// Primary caption: the series name for an episode, whose own `title` is
    /// the episode title (often "TBA" when unannounced); the title otherwise.
    static func cardTitle(for item: some EpisodeCaptionSource) -> String {
        guard isEpisode(item),
              let series = item.seriesTitle?.trimmingCharacters(in: .whitespacesAndNewlines),
              !series.isEmpty else { return item.title }
        return series
    }

    /// Secondary caption line: "S01E02 · Pilot". Falls back to whichever part
    /// is available; `nil` for non-episodes.
    static func line(for item: some EpisodeCaptionSource) -> String? {
        let parts = [code(for: item), episodeTitle(for: item)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Spoken form for accessibility: "Season 1, Episode 2, Pilot".
    static func accessibilityLabel(for item: some EpisodeCaptionSource) -> String? {
        guard isEpisode(item) else { return nil }
        var parts: [String] = []
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            let seasonLabel = season == 0 ? "Specials" : "Season \(season)"
            parts.append("\(seasonLabel), Episode \(episode)")
        }
        if let title = episodeTitle(for: item) {
            parts.append(title)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}
