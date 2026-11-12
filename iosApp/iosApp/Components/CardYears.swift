import Foundation

/// A card model whose caption shows years: Home section rows and catalog rows.
protocol CardYearsSource {
    var type: String { get }
    var year: Int? { get }
    var showStatus: String? { get }
    var lastAirDate: String? { get }
}

extension SectionItem: CardYearsSource {}
extension BrowseItem: CardYearsSource {}

/// The years line under a card title. A series shows the years it ran:
/// "2019 – 2023" once it has ended, "2021 – Present" while it is running.
/// Everything else shows its year, and so does a series whose row doesn't
/// say when it ended or whether it is still running.
enum CardYears {
    static func caption(for item: some CardYearsSource, locale: Locale) -> String? {
        guard let year = item.year else { return nil }
        let first = LocaleFormat.integer(year, locale: locale)
        guard let status = item.showStatus, SiloMediaType.isSeries(item.type) else { return first }
        // The server stores one spelling of each airing state.
        switch status {
        case "returning":
            return AppLanguage.string(.shellCardYearsToPresent(first), locale: locale)
        case "ended", "cancelled":
            // A calendar date, "2023-05-28".
            guard let lastYear = item.lastAirDate.flatMap({ Int($0.prefix(4)) }), lastYear > year else { return first }
            let last = LocaleFormat.integer(lastYear, locale: locale)
            return AppLanguage.string(.shellCardYearRange(first, last), locale: locale)
        default:
            return first
        }
    }
}
