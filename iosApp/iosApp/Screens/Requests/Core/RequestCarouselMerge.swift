import Foundation

/// One carousel on the Requests hub: a row of the server's Discover layout,
/// or, from an older server, one merged from its per-media-type sections.
struct RequestCarousel: Identifiable, Equatable {
    let id: String
    let title: String
    let results: [RequestMediaResult]
    /// A row of the server's layout with more pages: it has a See all page.
    var seeAll: Bool = false
}

enum RequestCarouselMerge {
    /// An older server returns fixed per-type sections; the hub merges them
    /// into two product carousels. "Crowd favorites" is client copy for the
    /// popular sections.
    static let trendingKeys: Set<String> = ["trending_movies", "trending_series"]
    static let popularKeys: Set<String> = ["popular_movies", "popular_series"]

    /// The studio, network and genre card rows, which the apps do not draw.
    static let brandRowTypes: Set<String> = ["studios", "networks", "genres"]

    /// A server with an admin-defined layout sends `rowOrder`: its rows show
    /// as they are, in that order. Card rows and rows with no titles are
    /// skipped. An older server gets the two merged carousels.
    static func carousels(from layout: RequestDiscoverLayout) -> [RequestCarousel] {
        guard !layout.rowOrder.isEmpty else { return carousels(from: layout.sections) }
        let sections = Dictionary(layout.sections.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        return layout.rowOrder.compactMap { row in
            guard !brandRowTypes.contains(row.type),
                  let section = sections[row.key], !section.results.isEmpty else { return nil }
            // A row trimmed to its size has more titles even on a one-page source.
            let more = section.totalPages > 1 || section.totalResults > section.results.count
            return RequestCarousel(id: section.key, title: section.title, results: section.results, seeAll: more)
        }
    }

    static func carousels(from sections: [RequestDiscoverySection]) -> [RequestCarousel] {
        [
            merge(sections, keys: trendingKeys, id: "trending", title: "Trending now"),
            merge(sections, keys: popularKeys, id: "popular", title: "Crowd favorites"),
        ].compactMap { $0 }
    }

    private static func merge(
        _ sections: [RequestDiscoverySection],
        keys: Set<String>,
        id: String,
        title: String
    ) -> RequestCarousel? {
        let matched = sections.filter { keys.contains($0.key) }
        let results = interleave(matched.map(\.results))
        guard !results.isEmpty else { return nil }
        return RequestCarousel(id: id, title: title, results: results)
    }

    /// Round-robin interleave so neither media type dominates a merged row;
    /// tolerates uneven list lengths and drops duplicate ids (the same title
    /// can chart in more than one source section).
    static func interleave(_ lists: [[RequestMediaResult]]) -> [RequestMediaResult] {
        var merged: [RequestMediaResult] = []
        var seen = Set<String>()
        let longest = lists.map(\.count).max() ?? 0
        for index in 0..<longest {
            for list in lists where index < list.count {
                let item = list[index]
                guard seen.insert(item.id).inserted else { continue }
                merged.append(item)
            }
        }
        return merged
    }
}

/// How a row's See all page moves from page to page.
enum RequestDiscoverPaging {
    /// TMDB's own ceiling on its paged feeds.
    static let maxPage = 500

    /// The page after `last`. When the server read several source pages to
    /// fill one it answers with `nextPage`, since `page + 1` would repeat
    /// titles; a `nextPage` past the last page means the end, and one that
    /// does not move forward is taken as the end. A page without one read a
    /// single source page, so `page + 1` follows, up to TMDB's cap.
    static func nextPage(after last: RequestDiscoverySection, requested: Int) -> Int? {
        let pageCount = min(max(last.totalPages, 0), maxPage)
        if let cursor = last.nextPage {
            return cursor > requested && cursor <= pageCount ? cursor : nil
        }
        return requested < pageCount ? requested + 1 : nil
    }
}
