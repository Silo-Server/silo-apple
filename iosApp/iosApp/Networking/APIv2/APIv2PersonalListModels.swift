import Foundation

enum APIv2PersonalListKind: String, Hashable {
    case favorites
    case watchlist
}

/// Personal list pages carry cards and cursor state, never catalog totals or windows.
struct APIv2PersonalListPage: Decodable {
    let items: [BrowseItem]
    let page: APIv2Page
}
