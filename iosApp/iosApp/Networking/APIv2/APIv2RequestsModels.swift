import Foundation

// MARK: Media requests (`/api/v2/requests`)

/// `GET /api/v2/requests/discover`: the discovery rows with their first
/// page. The server omits `page` because the collection is bounded.
struct APIv2DiscoverSectionCollection: Decodable {
    let items: [RequestDiscoverySection]
}

/// `GET /api/v2/requests/mine` page. `page` is absent only on a bounded
/// collection, which is complete by definition.
struct APIv2RequestsPage: Decodable {
    let items: [MediaRequest]
    let page: APIv2Page?
}

/// Requests-specific failures: refusals raised before a call leaves the
/// device, and a mutation whose owner changed while it was underway.
enum APIv2RequestsError: LocalizedError, Equatable {
    /// The v2 detail and create operations accept only `movie` and `series`.
    case unsupportedMediaType
    /// Search needs non-blank text; the server answers 422 otherwise.
    case emptySearchQuery
    /// The account, credential owner, or profile changed after a create or
    /// cancel captured its owner. The response was discarded, and the server
    /// may already have acted; a read under the new owner cannot say what
    /// happened for the old one.
    case outcomeUnknownOwnerChanged

    var errorDescription: String? {
        switch self {
        case .unsupportedMediaType: return "This title can't be requested."
        case .emptySearchQuery: return "Enter a title to search for."
        case .outcomeUnknownOwnerChanged:
            return "The account or profile changed before the request was confirmed."
        }
    }
}
