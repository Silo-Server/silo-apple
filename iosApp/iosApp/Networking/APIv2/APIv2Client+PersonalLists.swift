import Foundation

extension APIv2Client {
    /// Every item on the acting profile's favorites or watchlist, newest
    /// first. All pages keep the first page's owner; a list longer than the
    /// page budget throws rather than showing a truncated list as complete.
    func personalListItems(kind: APIv2PersonalListKind, imageSize: String?,
                           auth: CapturedOrdinaryRequestAuth) async throws -> CatalogResponse {
        var result = try await personalList(kind: kind, limit: 200, imageSize: imageSize, auth: auth)
        var items = result.value.items
        for pageNumber in 1...100 {
            guard let continuation = result.continuation else {
                return CatalogResponse(items: items, total: items.count, totalExact: true, hasMore: false)
            }
            guard pageNumber < 100 else { break }
            result = try await nextPersonalListPage(continuation)
            items.append(contentsOf: result.value.items)
        }
        throw APIv2Error.incompletePersonalList
    }
}
