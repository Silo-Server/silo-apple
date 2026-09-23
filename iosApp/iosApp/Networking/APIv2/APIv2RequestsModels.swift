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

/// Refusals raised before a requests call leaves the device.
enum APIv2RequestsError: LocalizedError, Equatable {
    /// The v2 detail and create operations accept only `movie` and `series`.
    case unsupportedMediaType
    /// Search needs non-blank text; the server answers 422 otherwise.
    case emptySearchQuery

    var errorDescription: String? {
        switch self {
        case .unsupportedMediaType: return "This title can't be requested."
        case .emptySearchQuery: return "Enter a title to search for."
        }
    }
}
