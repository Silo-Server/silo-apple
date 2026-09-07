import Foundation

/// A continuous run of loaded seasons. A missing page is a boundary, while
/// a successfully loaded empty season can be crossed. Matches Android TV.
struct SeriesEpisodeWindow {
    let episodes: [EpisodeListItem]
    let previousSeason: Int?
    let nextSeason: Int?

    static func orderedSeasons(_ seasons: [Season]) -> [Season] {
        var seen = Set<Int>()
        return seasons.sorted {
            let lhsSpecial = $0.isSpecials == true || $0.seasonNumber == 0
            let rhsSpecial = $1.isSpecials == true || $1.seasonNumber == 0
            if lhsSpecial != rhsSpecial { return !lhsSpecial }
            return $0.seasonNumber < $1.seasonNumber
        }.filter { seen.insert($0.seasonNumber).inserted }
    }

    static func snapshot(
        seasons: [Season], selected: Int?, pages: [Int: [EpisodeListItem]]
    ) -> Self {
        let order = orderedSeasons(seasons).map(\.seasonNumber)
        guard let selected, let index = order.firstIndex(of: selected),
              pages[selected] != nil else {
            return Self(episodes: [], previousSeason: nil, nextSeason: nil)
        }
        var first = index
        var last = index
        while first > 0, pages[order[first - 1]] != nil { first -= 1 }
        while last + 1 < order.count, pages[order[last + 1]] != nil { last += 1 }
        var seen = Set<String>()
        let episodes = order[first...last].flatMap { number in
            (pages[number] ?? []).sorted { $0.episodeNumber < $1.episodeNumber }
        }.filter { seen.insert($0.contentId).inserted }
        return Self(
            episodes: episodes,
            previousSeason: first > 0 ? order[first - 1] : nil,
            nextSeason: last + 1 < order.count ? order[last + 1] : nil
        )
    }

    /// Retain five nonempty season pages around the selected episode. Empty
    /// results stay as inexpensive markers so they aren't repeatedly fetched.
    static func retainedPages(
        seasons: [Season], selected: Int, pages: [Int: [EpisodeListItem]]
    ) -> [Int: [EpisodeListItem]] {
        let order = orderedSeasons(seasons).map(\.seasonNumber)
        guard let index = order.firstIndex(of: selected) else { return pages }
        let nearest = order.enumerated().filter { !(pages[$0.element]?.isEmpty ?? true) }
            .sorted {
                let lhs = abs($0.offset - index)
                let rhs = abs($1.offset - index)
                return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
            }.prefix(5).map(\.element)
        let keep = Set(nearest)
        return pages.filter { order.contains($0.key) && ($0.value.isEmpty || keep.contains($0.key)) }
    }
}
