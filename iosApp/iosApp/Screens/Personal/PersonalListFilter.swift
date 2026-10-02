import Foundation

/// Watched-state narrowing for a saved list. Read from each item's
/// `userState.played`; items without user state count as unwatched.
enum PersonalListWatchFilter: String, CaseIterable, Identifiable {
    case all
    case unwatched
    case watched

    var id: Self { self }

    var label: String {
        switch self {
        case .all: return "All"
        case .unwatched: return "Unwatched"
        case .watched: return "Watched"
        }
    }

    func includes(_ item: BrowseItem) -> Bool {
        let played = item.userState?.played ?? false
        switch self {
        case .all: return true
        case .unwatched: return !played
        case .watched: return played
        }
    }
}

/// Sort order for a saved list. `.listOrder` keeps the order the server
/// returned the list in.
enum PersonalListSort: String, CaseIterable, Identifiable {
    case listOrder
    case title
    case releaseYear
    case rating

    var id: Self { self }

    var label: String {
        switch self {
        case .listOrder: return "List Order"
        case .title: return "Title"
        case .releaseYear: return "Release Year"
        case .rating: return "Rating"
        }
    }
}

/// Client-side filter and sort for Favorites and Watchlist. Both screens
/// already hold the whole list, so filtering never needs a server round trip.
struct PersonalListFilter: Equatable {
    var watch: PersonalListWatchFilter = .all
    /// Selected genres. An item matches when it has any of them.
    var genres: Set<String> = []
    var sort: PersonalListSort = .listOrder

    /// Number of active filter dimensions, for the Filter badge. Sort is
    /// not a filter and is not counted.
    var activeFilterCount: Int {
        (watch == .all ? 0 : 1) + (genres.isEmpty ? 0 : 1)
    }

    var hasActiveFilters: Bool { activeFilterCount > 0 }

    mutating func clearFilters() {
        watch = .all
        genres.removeAll()
    }

    mutating func toggleGenre(_ genre: String) {
        if genres.contains(genre) {
            genres.remove(genre)
        } else {
            genres.insert(genre)
        }
    }

    /// Drops selected genres that no longer appear in `available`, so a
    /// genre picked under one media type can't silently empty another.
    mutating func pruneGenres(to available: [String]) {
        genres.formIntersection(available)
    }

    /// Distinct genres across `items`, sorted for display.
    static func availableGenres(in items: [BrowseItem]) -> [String] {
        var seen = Set<String>()
        for item in items {
            for genre in item.genres ?? [] {
                let trimmed = genre.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { seen.insert(trimmed) }
            }
        }
        return seen.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    func apply(to items: [BrowseItem]) -> [BrowseItem] {
        let filtered = items.filter { item in
            guard watch.includes(item) else { return false }
            guard !genres.isEmpty else { return true }
            let itemGenres = (item.genres ?? []).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return itemGenres.contains { genres.contains($0) }
        }
        return sorted(filtered)
    }

    /// Every item takes part in the sort. Ties, and items missing the sort
    /// value (which go last), fall back to title order, then list order.
    private func sorted(_ items: [BrowseItem]) -> [BrowseItem] {
        guard sort != .listOrder else { return items }
        return items.enumerated()
            .sorted { lhs, rhs in
                var result = Self.compare(lhs.element, rhs.element, by: sort)
                if result == .orderedSame, sort != .title {
                    result = Self.compare(lhs.element, rhs.element, by: .title)
                }
                switch result {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.offset < rhs.offset
                }
            }
            .map(\.element)
    }

    private static func compare(
        _ lhs: BrowseItem,
        _ rhs: BrowseItem,
        by sort: PersonalListSort
    ) -> ComparisonResult {
        switch sort {
        case .listOrder:
            return .orderedSame
        case .title:
            return lhs.title.localizedStandardCompare(rhs.title)
        case .releaseYear:
            // Newest first; items without a year go last.
            return descendingNilsLast(year(of: lhs), year(of: rhs))
        case .rating:
            // Highest first; items without a rating go last.
            return descendingNilsLast(rating(of: lhs), rating(of: rhs))
        }
    }

    /// The card year, or the year of the release date when the server sent
    /// only a date.
    private static func year(of item: BrowseItem) -> Int? {
        if let year = item.year, year > 0 { return year }
        guard let date = item.releaseDate, date.count >= 4 else { return nil }
        return Int(date.prefix(4))
    }

    /// The rating the card shows: IMDb, or TMDB when there is no usable
    /// IMDb score. Never Rotten Tomatoes, which can be stored even when an
    /// administrator has turned it off.
    private static func rating(of item: BrowseItem) -> Double? {
        DisplayRating.primaryCard(imdb: item.ratingImdb, tmdb: item.ratingTmdb)?.score
    }

    private static func descendingNilsLast<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (l?, r?):
            if l == r { return .orderedSame }
            return l > r ? .orderedAscending : .orderedDescending
        case (.some, .none): return .orderedAscending
        case (.none, .some): return .orderedDescending
        case (.none, .none): return .orderedSame
        }
    }
}
