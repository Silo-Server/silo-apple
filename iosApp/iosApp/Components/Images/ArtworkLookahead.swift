import Foundation

/// A card's artwork and the size the card draws it at.
struct CardArtwork {
    let url: String
    let pointSize: CGSize
}

/// Decodes the artwork of cards just past the ones on screen, at the size
/// those cards draw it, so a card that scrolls or is focused into view
/// paints its image on its first frame instead of its thumbhash.
@MainActor
enum ArtworkLookahead {
    /// Cards warmed past the focused or newly shown card in a row: a little
    /// more than one screen width.
    #if os(tvOS)
    static let cardsAhead = 10
    #else
    static let cardsAhead = 6
    #endif
    /// Rows warmed below a row that comes into view, `cardsAhead` cards each.
    static let rowsAhead = 2

    /// Warms the cards after `index` in a row.
    static func warmCards<Item>(after index: Int, in items: [Item], artwork: (Item) -> CardArtwork?) {
        guard index + 1 < items.count else { return }
        let end = min(items.count, index + 1 + cardsAhead)
        warm(items[(index + 1)..<end].compactMap(artwork))
    }

    /// Warms the leading cards of each row.
    static func warmRows<Row, Item>(
        _ rows: some Sequence<Row>,
        items: (Row) -> [Item],
        artwork: (Row, Item) -> CardArtwork?
    ) {
        warm(rows.flatMap { row in items(row).prefix(cardsAhead).compactMap { artwork(row, $0) } })
    }

    private static func warm(_ artwork: [CardArtwork]) {
        // A row has one or two card sizes, so a linear grouping is enough.
        var groups: [(size: CGSize, urls: [URL])] = []
        for card in artwork {
            guard !card.url.isEmpty, let url = URL(string: card.url) else { continue }
            if let index = groups.firstIndex(where: { $0.size == card.pointSize }) {
                groups[index].urls.append(url)
            } else {
                groups.append((card.pointSize, [url]))
            }
        }
        for group in groups {
            PosterImageCache.prefetchArtwork(group.urls, pointSize: group.size)
        }
    }
}
