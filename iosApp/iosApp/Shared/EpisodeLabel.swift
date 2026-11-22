import Foundation

/// How an episode is named wherever its season and episode numbers would
/// show: "S01E02", "S1 · E2", "Season 1 · Episode 2" and the other code
/// styles, or the episode's air date ("Nov 20, 2026") when its series labels
/// episodes by date.
///
/// A series the server marks `episode_labels: "air_date"` has synthetic
/// numbers: Sportarr numbers each league's events S<year>E<n>, so an NBA
/// game would read "S2026E296". Those numbers still sort the episodes and
/// drive next-up and playback; only the label changes. An undated episode
/// keeps its numbers. Mirrors `formatEpisodeLabel` in the web app's
/// `episodeCardLabels.ts`.
enum EpisodeLabel {
    /// The only `episode_labels` value; absent means the series uses numbers.
    static let airDateLabels = "air_date"

    /// The ways the apps write a season and episode code.
    enum Style {
        /// "S01E02", padded to two digits so codes line up across a row.
        case paddedTag
        /// "S1E2".
        case tag
        /// "S1 · E2".
        case caption
        /// "S1·E2", on play buttons.
        case dotted
        /// "S1:E2", in the player eyebrow.
        case colon
        /// "S1:E2", in Watch Party facts.
        case watchParty
        /// "S1 · E2", in Watch Party's episode lists.
        case watchPartyLine
        /// "S1 E2", on the tvOS Home marquee.
        case spaced
        /// "Season 1 · Episode 2" ("Specials · Episode 2" for season 0).
        case eyebrow
        /// "Season 1, Episode 2", read by a screen reader.
        case spoken
    }

    /// Whether a series names its episodes by air date.
    static func labelsByAirDate(_ labels: String?) -> Bool {
        labels == airDateLabels
    }

    /// The medium date ("Nov 20, 2026") that names an episode of a
    /// date-labeled series, as a calendar date with no time-zone shift; nil
    /// when the series uses numbers or the episode is undated.
    static func airDate(labels: String?, airDate: String?, locale: Locale = AppLanguage.formattingLocale) -> String? {
        guard labelsByAirDate(labels) else { return nil }
        return DetailDateFormatting.abbreviatedDate(airDate, locale: locale)
    }

    /// The episode's label: its air date when the series is labeled by date
    /// and the episode is dated, else its code in `style`.
    static func text(
        season: Int,
        episode: Int,
        style: Style = .paddedTag,
        labels: String?,
        airDate: String?,
        locale: Locale = AppLanguage.formattingLocale
    ) -> String {
        Self.airDate(labels: labels, airDate: airDate, locale: locale)
            ?? code(season: season, episode: episode, style: style, locale: locale)
    }

    /// The season and episode code in `style`, whatever the series' labels.
    static func code(season: Int, episode: Int, style: Style = .paddedTag, locale: Locale = AppLanguage.formattingLocale) -> String {
        let s = LocaleFormat.codeNumber(season)
        let e = LocaleFormat.codeNumber(episode)
        let resource: LocalizedStringResource
        switch style {
        case .paddedTag:
            // Two digits at least, in ASCII digits like every code (D78).
            resource = .catalogEpisodeTag(String(format: "%02d", season), String(format: "%02d", episode))
        case .tag: resource = .catalogEpisodeTag(s, e)
        case .caption: resource = .catalogEpisodeCaption(s, e)
        case .dotted: resource = .detailEpisodeCode(s, e)
        case .colon: resource = .playerEyebrowEpisode(s, e)
        case .watchParty: resource = .watchPartyFactsEpisodeCode(s, e)
        case .watchPartyLine: resource = .watchPartyEpisodesLine(s, e)
        case .spaced: resource = .homeSeasonEpisode(s, e)
        case .eyebrow:
            return AppLanguage.string(.detailEpisodeEyebrow(seasonName(season, locale: locale), LocaleFormat.integer(episode, locale: locale)), locale: locale)
        case .spoken:
            return [seasonName(season, locale: locale), AppLanguage.string(.detailEpisode(LocaleFormat.integer(episode, locale: locale)), locale: locale)]
                .joined(separator: ", ")
        }
        return AppLanguage.string(resource, locale: locale)
    }

    /// "Season 1", or "Specials" for season 0.
    private static func seasonName(_ season: Int, locale: Locale) -> String {
        AppLanguage.string(season == 0 ? .detailSpecials : .detailSeason(LocaleFormat.integer(season, locale: locale)), locale: locale)
    }
}
