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
        PosterImageCache.prefetchArtwork(items[(index + 1)..<end].compactMap(artwork))
    }

    /// Warms the leading cards of each row.
    /// Returns what it warmed, so the caller can cancel it.
    @discardableResult
    static func warmRows<Row, Item>(
        _ rows: some Sequence<Row>,
        items: (Row) -> [Item],
        artwork: (Row, Item) -> CardArtwork?
    ) -> [CardArtwork] {
        let cards = rows.flatMap { row in items(row).prefix(cardsAhead).compactMap { artwork(row, $0) } }
        PosterImageCache.prefetchArtwork(cards)
        return cards
    }
}
