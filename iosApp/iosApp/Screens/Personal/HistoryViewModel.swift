import Foundation

/// Loads watch history using viewer-pinned catalog cursors.
@Observable
@MainActor
class HistoryViewModel {
    private let catalog: CollectionDetailViewModel
    var items: [BrowseItem] { catalog.items }
    var isLoading: Bool { catalog.isLoading }
    var error: ErrorState? { catalog.membership.error ?? catalog.error }
    var hasMore: Bool { catalog.hasMore }
    var totalItems: Int? { catalog.totalItems }
    var membership: ReadOwnedMembershipModel { catalog.membership }

    init(api: APIv2Client = SiloAPI.shared.v2, tokens: TokenStore = .shared) {
        catalog = CollectionDetailViewModel(api: api, tokens: tokens)
    }

    /// "523 items" when the exact total is known, otherwise a lower bound such
    /// as "60+ items" while more pages remain.
    var countLabel: String {
        let count = totalItems ?? items.count
        let isLowerBound = totalItems == nil && (hasMore || error != nil)
        let suffix = isLowerBound ? "+" : ""
        let unit = (count == 1 && !isLowerBound) ? "item" : "items"
        return "\(count)\(suffix) \(unit)"
    }

    func load(reset: Bool) async {
        var query = APIv2CatalogQuery()
        query.source = "history"
        query.limit = 60
        await catalog.loadCatalog(query: query, reset: reset)
    }
}
