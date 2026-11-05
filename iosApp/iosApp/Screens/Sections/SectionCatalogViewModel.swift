import Foundation

/// Pages one Home or library row from the catalog's `section` source, kept
/// with the profile that requested it.
@Observable
@MainActor
final class SectionCatalogViewModel {
    private(set) var items: [BrowseItem] = []
    private(set) var isLoading = false
    private(set) var error: ErrorState?
    /// The server no longer offers the row: it was removed or hidden, or its
    /// library is no longer accessible.
    private(set) var isUnavailable = false
    private(set) var hasMore = true
    private(set) var totalItems: Int?

    private let api: SiloAPI
    private let tokens: TokenStore
    private var target: SectionCatalogTarget?
    private var owner: CapturedOrdinaryRequestAuth?
    private var continuation: APIv2CatalogContinuation?
    private var generation = 0

    init(api: SiloAPI = .shared, tokens: TokenStore = .shared) {
        self.api = api
        self.tokens = tokens
    }

    /// Loads `requested` unless it is already shown, as when the page comes
    /// back from a card's detail page.
    func open(_ requested: SectionCatalogTarget) async {
        if target == requested, !items.isEmpty || isUnavailable { return }
        await load(requested, reset: true)
    }

    func load(_ requested: SectionCatalogTarget, reset: Bool) async {
        let targetChanged = target != requested
        let resetsPage = reset || targetChanged
        if resetsPage {
            // Supersede an in-flight page before checking its loading flag.
            generation += 1
            target = requested
            // Refreshing the same row keeps the visible cards if the network
            // fails. A different row cannot reuse them.
            if targetChanged { clearPage() }
        } else if isLoading || !hasMore {
            return
        }
        let requestGeneration = generation
        isLoading = true
        error = nil
        defer {
            if requestGeneration == generation { isLoading = false }
        }

        do {
            guard let requestOwner = await tokens.captureOrdinaryRequestAuth() else {
                throw HTTPError.requestIdentityChanged
            }
            guard requestGeneration == generation, !Task.isCancelled else { return }
            if let owner, !owner.sameCredentialIdentity(as: requestOwner) { clearPage() }
            owner = requestOwner

            var nextPage = resetsPage ? nil : continuation
            var loaded: [BrowseItem] = []
            var startsOver = false
            var page: CatalogListPage
            // A media scope can thin a page to a few cards or none. Read on
            // until the load has enough cards to move the grid's load-more
            // trigger onto a new card, or the row ends.
            repeat {
                if let nextPage {
                    page = try await api.nextCatalogPage(nextPage)
                } else {
                    page = try await api.catalogPage(.sectionItems(requested, limit: 60))
                }
                // Every page, so a profile switch stops the read before it
                // follows the continuation.
                let stillOwnsRequest = await api.isCurrentOwner(requestOwner)
                guard requestGeneration == generation, !Task.isCancelled else { return }
                guard stillOwnsRequest else { throw HTTPError.requestIdentityChanged }
                if page.startsOver {
                    loaded = []
                    startsOver = true
                }
                // Section reads take no type overlay, so a Movies or Series
                // view filters the row's cards here.
                loaded += page.response.items.filter { requested.mediaScope?.contains($0.type) ?? true }
                nextPage = page.continuation
            } while loaded.count < CatalogGrid.loadMoreLead && nextPage != nil

            if resetsPage || startsOver {
                items = loaded
            } else {
                items.append(contentsOf: loaded)
            }
            // A filtered page's total counts every type.
            totalItems = requested.mediaScope == nil && page.response.totalExact != false ? page.response.total : nil
            continuation = page.continuation
            hasMore = page.continuation != nil
            isUnavailable = false
        } catch {
            guard requestGeneration == generation, !Task.isCancelled else { return }
            var error = error
            // A failure read for a profile that is no longer active says
            // nothing about this row for the current one.
            if let owner, !(await api.isCurrentOwner(owner)) {
                guard requestGeneration == generation, !Task.isCancelled else { return }
                error = HTTPError.requestIdentityChanged
            }
            if case HTTPError.requestIdentityChanged = error { clearPage() }
            if case HTTPError.authorityChanged = error { clearPage() }
            if Self.isNotFound(error) {
                clearPage()
                hasMore = false
                isUnavailable = true
                return
            }
            if items.isEmpty { self.error = ErrorState(error) }
        }
    }

    private static func isNotFound(_ error: Error) -> Bool {
        switch error {
        case APIv2Error.httpStatus(404): true
        case APIv2Error.problem(let problem): problem.status == 404
        default: false
        }
    }

    private func clearPage() {
        items = []
        continuation = nil
        totalItems = nil
        hasMore = true
    }
}
