import Foundation

extension APIv2Client {
    /// All pages retain the displayed collection's original authority and query.
    /// A partial list is never published as a complete collection.
    func personalCollectionCards(id: String, auth: CapturedOrdinaryRequestAuth) async throws -> CatalogResponse {
        var query = APIv2CatalogQuery()
        query.source = "user_collection"
        query.collectionId = id
        var result = try await catalogPage(query: query, auth: auth)
        var items = result.value.items
        for pageNumber in 1...100 {
            guard let continuation = result.continuation else {
                return CatalogResponse(collectionCards: items)
            }
            guard pageNumber < 100 else { throw APIv2Error.incompleteCollection }
            result = try await nextCatalogPage(continuation)
            items.append(contentsOf: result.value.items)
        }
        throw APIv2Error.incompleteCollection
    }
}

extension CatalogResponse {
    /// A complete personal-collection card list assembled from v2 catalog
    /// pages. There is no snapshot and no further page by construction.
    init(collectionCards: [BrowseItem]) {
        total = collectionCards.count
        totalExact = true
        hasMore = false
        items = collectionCards
        source = "user_collection"
        title = nil
        snapshot = nil
    }
}
