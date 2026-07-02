import Foundation

/// One product carousel on the Requests hub, merged from the server's
/// per-media-type discover sections.
struct RequestCarousel: Identifiable, Equatable {
    let id: String
    let title: String
    let results: [RequestMediaResult]
}

enum RequestCarouselMerge {
    /// The server returns fixed per-type sections; the hub shows exactly two
    /// product carousels. "Crowd favorites" is client copy for the popular
    /// sections.
    static let trendingKeys: Set<String> = ["trending_movies", "trending_series"]
    static let popularKeys: Set<String> = ["popular_movies", "popular_series"]

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
