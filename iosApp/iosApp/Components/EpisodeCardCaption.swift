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
    static func code(season: Int, episode: Int, locale: Locale = AppLanguage.formattingLocale) -> String {
        AppLanguage.string(.catalogEpisodeTag(padded(season, locale: locale), padded(episode, locale: locale)), locale: locale)
    }

    /// Two digits at least, in the locale's digits: "01", "12", "2021".
    private static func padded(_ number: Int, locale: Locale) -> String {
        LocaleFormat.localized(String(format: "%02d", number), locale: locale)
    }

    /// Spoken season and episode: "Season 1, Episode 2", or "Specials,
    /// Episode 2" for season 0.
    static func spokenCode(season: Int, episode: Int, locale: Locale = AppLanguage.formattingLocale) -> String {
        let seasonLabel: LocalizedStringResource = season == 0
            ? .detailSpecials
            : .detailSeason(LocaleFormat.integer(season, locale: locale))
        return [seasonLabel, .detailEpisode(LocaleFormat.integer(episode, locale: locale))]
            .map { AppLanguage.string($0, locale: locale) }
            .joined(separator: ", ")
    }

    /// "S01E02 · Pilot" from an episode code and title.
    static func titled(code: String, title: String, locale: Locale = AppLanguage.formattingLocale) -> String {
        AppLanguage.string(.detailEpisodeCardTitle(code, title), locale: locale)
    }

    static func isEpisode(_ item: some EpisodeCaptionSource) -> Bool {
        item.type.lowercased() == "episode"
    }

    static func code(for item: some EpisodeCaptionSource, locale: Locale = AppLanguage.formattingLocale) -> String? {
        guard isEpisode(item),
              let season = item.seasonNumber,
              let episode = item.episodeNumber else { return nil }
        return code(season: season, episode: episode, locale: locale)
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
    static func line(for item: some EpisodeCaptionSource, locale: Locale = AppLanguage.formattingLocale) -> String? {
        let code = code(for: item, locale: locale)
        let title = episodeTitle(for: item)
        if let code, let title { return titled(code: code, title: title, locale: locale) }
        return code ?? title
    }

    /// Spoken form for accessibility: "Season 1, Episode 2, Pilot".
    static func accessibilityLabel(for item: some EpisodeCaptionSource, locale: Locale = AppLanguage.formattingLocale) -> String? {
        guard isEpisode(item) else { return nil }
        var parts: [String] = []
        if let season = item.seasonNumber, let episode = item.episodeNumber {
            parts.append(spokenCode(season: season, episode: episode, locale: locale))
        }
        if let title = episodeTitle(for: item) {
            parts.append(title)
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

// MARK: - Episode rails

/// The caption under an episode rail card on the iPhone, iPad, Mac, and Apple
/// TV, matched by the Android and web clients: "S01E02 · Pilot", then the air
/// date and runtime.
extension EpisodeCardCaption {
    /// "S01E02 · Pilot", so a special (S00) and each episode's place in the
    /// season read at a glance. Just the code when the episode has no title.
    static func railTitle(for episode: EpisodeListItem, locale: Locale = AppLanguage.formattingLocale) -> String {
        let code = Self.code(season: episode.seasonNumber, episode: episode.episodeNumber, locale: locale)
        guard let title = episode.title?.trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty else { return code }
        return titled(code: code, title: title, locale: locale)
    }

    /// "Feb 18, 2026  ·  52m", or nil when neither part is known.
    static func railMetadata(for episode: EpisodeListItem) -> String? {
        var parts: [String] = []
        if let airDate = DetailDateFormatting.abbreviatedDate(episode.airDate) {
            parts.append(airDate)
        }
        if let runtime = MediaTextFormatting.runtime(minutes: episode.runtime) {
            parts.append(runtime)
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ·  ")
    }
}
