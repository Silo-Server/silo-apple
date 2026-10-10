import Foundation

/// One external rating as Silo shows it: the source's mark and the score on
/// the source's own scale ("IMDb 8.5", "RT 93%").
///
/// Item detail from a current server carries the list already chosen, ordered
/// and formatted (`ratings` on `GET /api/v2/catalog/items/{id}`), and clients
/// render it verbatim. `source` is open-ended because plugins can add sources:
/// an unknown source shows `name` as its mark.
struct DisplayRating: Codable, Hashable, Sendable {
    /// Machine id such as `imdb`, `tmdb`, `rt_critic`, `rt_audience`.
    let source: String
    /// The source's plain-text mark ("IMDb", "TMDB", "RT", "RT Audience").
    let name: String
    /// The score on a 0-100 scale. Never shown; `display` is.
    let score: Double
    /// The score as the server formatted it on the source's own scale.
    let display: String

    static let imdbSource = "imdb"
    static let tmdbSource = "tmdb"

    /// TMDB is the one source whose mark is its logo; every other source
    /// shows `name` as text.
    var isTMDB: Bool { source == Self.tmdbSource }

    /// What assistive technologies read for this entry: "IMDb 8.5".
    var accessibilityText: String { "\(name) \(display)" }
}

extension DisplayRating {
    /// An IMDb score out of 10, or nil when there is no usable score.
    static func imdb(_ value: Double?) -> DisplayRating? {
        outOfTen(source: imdbSource, name: "IMDb", value: value)
    }

    /// A TMDB score out of 10, or nil when there is no usable score. Also
    /// covers titles known only from TMDB, such as a title someone can request.
    static func tmdb(_ value: Double?) -> DisplayRating? {
        outOfTen(source: tmdbSource, name: "TMDB", value: value)
    }

    /// The row an older server implies, which sends no `ratings` list: IMDb
    /// then TMDB. Never Rotten Tomatoes, because item detail keeps the stored
    /// RT scores for metadata editors even when an administrator has RT off.
    static func fallback(imdb: Double?, tmdb: Double?) -> [DisplayRating] {
        [Self.imdb(imdb), Self.tmdb(tmdb)].compactMap { $0 }
    }

    /// The one rating a card-sized summary shows (the tvOS focus marquee):
    /// IMDb, or TMDB when there is no IMDb score. Every Silo client follows
    /// the same rule.
    static func primaryCard(imdb: Double?, tmdb: Double?) -> DisplayRating? {
        Self.imdb(imdb) ?? Self.tmdb(tmdb)
    }

    /// The most ratings a phone-width title page shows, all on one line.
    /// Wider layouts show the server's whole list.
    static let phoneLimit = 3

    /// The rows a phone-width title page tries, longest first: the first
    /// `phoneLimit` entries in server order, then one fewer at a time down to
    /// one. The page shows the first row that fits on one line, so entries
    /// drop from the end instead of wrapping.
    static func phoneRowCandidates(_ ratings: [DisplayRating]) -> [[DisplayRating]] {
        rowCandidates(ratings, limit: phoneLimit)
    }

    /// The rows a one-line ratings row tries, longest first: at most `limit`
    /// entries in server order, then one fewer at a time down to one. Empty
    /// when there are no ratings.
    static func rowCandidates(_ ratings: [DisplayRating], limit: Int = .max) -> [[DisplayRating]] {
        stride(from: min(ratings.count, limit), to: 0, by: -1)
            .map { Array(ratings.prefix($0)) }
    }

    /// One decimal with a period whatever the device locale: "8.5", never "8,5".
    static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", locale: posixLocale, (value * 10).rounded() / 10)
    }

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private static func outOfTen(source: String, name: String, value: Double?) -> DisplayRating? {
        guard let value, value.isFinite, value > 0, value <= 10 else { return nil }
        return DisplayRating(source: source, name: name, score: value * 10, display: oneDecimal(value))
    }
}

extension ItemDetail {
    /// The ratings row a title page shows: the server's list, or, from an
    /// older server that sends none, IMDb then TMDB from the detail's fields.
    var displayRatings: [DisplayRating] {
        ratings ?? DisplayRating.fallback(imdb: ratingImdb, tmdb: ratingTmdb)
    }
}
