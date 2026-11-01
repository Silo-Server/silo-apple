import Foundation

/// Which films a movie page's box set row shows. The row does not scroll: it
/// holds as many poster cards as fit across the page, the last of them an
/// Explore all card that opens the box set page.
enum BoxSetRowWindow {
    /// How many poster cards of `cardWidth` fit across `width`, `spacing`
    /// apart.
    static func slots(width: CGFloat, cardWidth: CGFloat, spacing: CGFloat) -> Int {
        guard cardWidth > 0, width > 0 else { return 0 }
        return Int(((width + spacing) / (cardWidth + spacing)).rounded(.down))
    }

    /// The films shown in `slots` cards, one of them kept for the Explore all
    /// card when `endsWithExploreAll`.
    static func films(
        _ items: [BrowseItem],
        currentContentId: String,
        slots: Int,
        endsWithExploreAll: Bool
    ) -> ArraySlice<BrowseItem> {
        let filmSlots = max(0, slots - (endsWithExploreAll ? 1 : 0))
        let first = start(
            current: items.firstIndex { $0.contentId == currentContentId },
            count: items.count,
            filmSlots: filmSlots
        )
        return items[first..<min(items.count, first + filmSlots)]
    }

    /// The index of the first of `count` films when `filmSlots` fit. The row
    /// starts at the first film; when the film on screen (`current`) would
    /// not fit, it slides so that film shows after the one before it.
    static func start(current: Int?, count: Int, filmSlots: Int) -> Int {
        guard let current, current >= filmSlots, filmSlots > 0 else { return 0 }
        // With a single slot there is no room for the film before.
        let before = filmSlots > 1 ? 1 : 0
        return min(max(current - before, 0), count - filmSlots)
    }
}
