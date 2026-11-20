import Foundation

/// `GET /api/v2/catalog/items/{id}/collections` (`listCatalogItemCollections`):
/// the collections a movie or series page lists, and, when exactly one holds
/// the title, up to six of that collection's other titles.
struct CatalogItemCollections: Decodable, Equatable {
    /// Server collections first, then personal ones. The server has already
    /// applied every viewer rule.
    let cards: [SectionCollectionCard]
    /// Filled only when `cards` holds exactly one collection.
    let preview: [BrowseItem]

    init(cards: [SectionCollectionCard], preview: [BrowseItem] = []) {
        self.cards = cards
        self.preview = preview
    }

    private enum CodingKeys: String, CodingKey {
        case items, previewItems
    }

    /// One card or title the app cannot open drops out, not the row.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cards = try c.decode([LossyElement<SectionCollectionCard>].self, forKey: .items).compactMap(\.value)
        preview = (try c.decodeIfPresent([LossyElement<BrowseItem>].self, forKey: .previewItems) ?? [])
            .compactMap(\.value)
    }
}

/// What a movie or series page's collections row shows.
enum ItemCollectionsRowContent: Equatable {
    /// The only collection holding the title: some of its other titles under
    /// its name, with a way to open it.
    case titles(collection: SectionCollectionCard, items: [BrowseItem])
    /// "Also in": a card for every collection, with no cap.
    case collections([SectionCollectionCard])

    /// At most this many of the one collection's titles; the server sends
    /// up to six.
    static let maxTitles = 6

    /// Nil draws no row: nothing read yet, or no collection holds the title.
    init?(_ read: CatalogItemCollections?) {
        guard let read, let first = read.cards.first else { return nil }
        if read.cards.count == 1, !read.preview.isEmpty {
            self = .titles(collection: first, items: Array(read.preview.prefix(Self.maxTitles)))
        } else {
            self = .collections(read.cards)
        }
    }
}
