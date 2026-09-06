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

struct APIv2PersonalListContinuation {
    let kind: APIv2PersonalListKind
    let limit: Int
    let imageSize: String?
    let cursor: String
    let seen: Set<String>
    let identity: HTTPRequestIdentity
    let account: RefreshAccountIdentity
    let auth: CapturedOrdinaryRequestAuth
}

struct APIv2PersonalListResult {
    let auth: CapturedOrdinaryRequestAuth
    let value: APIv2PersonalListPage
    let continuation: APIv2PersonalListContinuation?
}
