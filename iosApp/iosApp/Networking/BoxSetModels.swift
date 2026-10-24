import Foundation

/// A movie box set: the movies TMDB lists in one collection (a franchise such
/// as Harry Potter) that the viewer can see in one library. It arrives on a
/// `box_set` card of a `group=box_set` library browse, and from
/// `GET /api/v2/catalog/box-sets?q=`; `GET /api/v2/catalog/box-sets/{id}`
/// opens it as a ``CatalogBoxSetDetail``.
struct CatalogBoxSet: Codable, Hashable, Identifiable {
    /// The TMDB collection ID.
    let id: String
    /// The library whose movies make up the box set; the box set read needs it.
    let libraryId: String
    let title: String
    var overview: String? = nil
    @ArtworkURL var posterUrl: String? = nil
    var posterThumbhash: String? = nil
    @ArtworkURL var backdropUrl: String? = nil
    var backdropThumbhash: String? = nil
    /// The collection's movies in the library that the viewer can see.
    let movieCount: Int
    /// How many of those movies the profile has played.
    let playedCount: Int
    var firstYear: Int? = nil
    var lastYear: Int? = nil

    /// The app's numeric library ID, or nil when the server sent one the app
    /// cannot address.
    var appLibraryId: Int? {
        guard let value = Int(libraryId), value > 0 else { return nil }
        return value
    }

    /// "2001 – 2011", one year when the box set spans one, or nil without years.
    var yearsText: String? {
        let first = firstYear.flatMap { $0 > 0 ? $0 : nil }
        let last = lastYear.flatMap { $0 > 0 ? $0 : nil }
        if let first, let last, first != last { return "\(first) – \(last)" }
        return (first ?? last).map(String.init)
    }

    var filmCountText: String { Self.filmCount(movieCount) }

    static func filmCount(_ count: Int) -> String {
        "\(count) \(count == 1 ? "film" : "films")"
    }

    /// Watched share for the card's progress bar; nil before the first film.
    var watchedProgress: Double? {
        guard movieCount > 0, playedCount > 0 else { return nil }
        return min(1, Double(playedCount) / Double(movieCount))
    }

    /// A card's second line: watched progress once started, else the years,
    /// else the film count.
    var cardCaption: String {
        if playedCount > 0 { return "\(playedCount) / \(movieCount) watched" }
        return yearsText ?? filmCountText
    }

    var accessibilityLabel: String {
        var parts = [title, "Box set of \(filmCountText)"]
        if let yearsText { parts.append(yearsText) }
        if playedCount > 0 { parts.append("\(playedCount) of \(movieCount) watched") }
        return parts.joined(separator: ", ")
    }
}

/// `GET /api/v2/catalog/box-sets/{id}`: the box set with its movies the viewer
/// can see in that library, in collection (release) order.
struct CatalogBoxSetDetail: Decodable {
    let boxSet: CatalogBoxSet
    let items: [BrowseItem]

    private enum CodingKeys: String, CodingKey { case items }

    init(boxSet: CatalogBoxSet, items: [BrowseItem]) {
        self.boxSet = boxSet
        self.items = items
    }

    init(from decoder: Decoder) throws {
        // The box set's own fields sit beside `items` in one object.
        boxSet = try CatalogBoxSet(from: decoder)
        items = try decoder.container(keyedBy: CodingKeys.self).decode([BrowseItem].self, forKey: .items)
    }

    /// The movie Play starts: the first in collection order the profile has
    /// not played, or the first once all are played.
    var nextMovie: BrowseItem? {
        items.first { $0.userState?.played != true } ?? items.first
    }

    /// Some, but not all, of the films are played; Play then reads Continue.
    var isStarted: Bool {
        boxSet.playedCount > 0 && boxSet.playedCount < boxSet.movieCount
    }

    var playVerb: String { isStarted ? "Continue" : "Play" }

    /// "Play <title>" or "Continue · <title>"; nil without movies.
    var playLabel: String? {
        guard let nextMovie else { return nil }
        return isStarted ? "Continue · \(nextMovie.title)" : "Play \(nextMovie.title)"
    }

    /// Hero facts: film count, year range, and watched progress once started.
    var factTokens: [String] {
        var tokens = [boxSet.filmCountText]
        if let years = boxSet.yearsText { tokens.append(years) }
        if boxSet.playedCount > 0 {
            tokens.append("\(boxSet.playedCount) of \(boxSet.movieCount) watched")
        }
        return tokens
    }
}

/// `GET /api/v2/catalog/box-sets?q=`: best match first, never null.
struct CatalogBoxSetList: Decodable {
    let items: [CatalogBoxSet]
}

extension BrowseItem {
    /// A box set card of a `group=box_set` browse, which opens the box set
    /// rather than a title page.
    var isBoxSet: Bool { type == "box_set" && boxSet != nil }

    /// A search result lifted into a card, so grids draw it like a browse card.
    init(boxSet: CatalogBoxSet) {
        self.init(
            contentId: "box_set:\(boxSet.id)",
            type: "box_set",
            title: boxSet.title,
            year: boxSet.firstYear,
            genres: nil,
            contentRating: nil,
            advisoryAge: nil,
            advisorySource: nil,
            status: nil,
            ratingImdb: nil,
            ratingTmdb: nil,
            ratingRtCritic: nil,
            ratingRtAudience: nil,
            runtime: nil,
            originalLanguage: nil,
            studios: nil,
            networks: nil,
            showStatus: nil,
            overview: boxSet.overview,
            posterUrl: boxSet.posterUrl,
            posterThumbhash: boxSet.posterThumbhash,
            backdropUrl: boxSet.backdropUrl,
            backdropThumbhash: boxSet.backdropThumbhash,
            addedAt: nil,
            releaseDate: nil,
            lastAirDate: nil,
            userState: nil,
            overlaySummary: nil,
            boxSet: boxSet
        )
    }
}
