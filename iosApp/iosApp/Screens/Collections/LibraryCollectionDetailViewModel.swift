import Foundation

/// Keeps collection pages with the library, media scope and profile that requested them.
@Observable
@MainActor
final class LibraryCollectionDetailViewModel {
    private(set) var items: [BrowseItem] = []
    private(set) var isLoading = false
    private(set) var error: ErrorState?
    private(set) var hasMore = true
    private(set) var totalItems: Int?

    private struct Selection: Equatable {
        let libraryId: Int
        let collectionId: String
        let kind: LibraryCollectionKind
        let mediaScope: LibraryVideoScope?

        var cacheKey: String {
            CacheKey.catalogCollectionItems(collectionId)
                + ".library-\(libraryId).kind-\(kind.rawValue).type-\(mediaScope?.rawValue ?? "all")"
        }
    }

    private struct CachedPage {
        let owner: CapturedOrdinaryRequestAuth
        let response: CatalogResponse
    }

    private let api: SiloAPI
    private let tokens: TokenStore
    private var selection: Selection?
    private var owner: CapturedOrdinaryRequestAuth?
    private var continuation: APIv2CatalogContinuation?
    private var generation = 0

    init(api: SiloAPI = .shared, tokens: TokenStore = .shared) {
        self.api = api
        self.tokens = tokens
    }

    func load(libraryId: Int, collectionId: String, kind: LibraryCollectionKind,
              mediaScope: LibraryVideoScope?, reset: Bool) async {
        let requested = Selection(libraryId: libraryId, collectionId: collectionId,
                                  kind: kind, mediaScope: mediaScope)
        let selectionChanged = selection != requested
        let resetsPage = reset || selectionChanged
        if resetsPage {
            // Supersede an in-flight page before checking its loading flag.
            generation += 1
            selection = requested
            // Refreshing the same selection keeps every visible page if the
            // network fails. A different selection cannot reuse those rows.
            if selectionChanged { clearPage() }
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
            if resetsPage, items.isEmpty,
               let cached: CachedPage = ResponseCache.shared.get(requested.cacheKey),
               cached.owner.sameCredentialIdentity(as: requestOwner) {
                items = cached.response.items
                totalItems = cached.response.totalExact == false ? nil : cached.response.total
                hasMore = cached.response.hasMore ?? false
            }

            // Cached rows have no live cursor. Their next load starts at page one.
            let nextPage = resetsPage ? nil : continuation
            let page: CatalogListPage
            if let nextPage {
                page = try await api.nextCatalogPage(nextPage)
            } else {
                var query = APIv2CatalogQuery.collectionItems(
                    kind: kind, collectionId: collectionId, limit: 60
                )
                query.type = mediaScope?.rawValue
                if mediaScope != nil { query.libraryId = String(libraryId) }
                page = try await api.catalogPage(query)
            }
            let stillOwnsRequest = await api.isCurrentOwner(requestOwner)
            guard requestGeneration == generation, !Task.isCancelled else { return }
            guard stillOwnsRequest else { throw HTTPError.requestIdentityChanged }

            if nextPage != nil, !page.startsOver {
                items.append(contentsOf: page.response.items)
            } else {
                items = page.response.items
                ResponseCache.shared.set(CachedPage(owner: requestOwner, response: page.response),
                                         for: requested.cacheKey)
            }
            totalItems = page.response.totalExact == false ? nil : page.response.total
            continuation = page.continuation
            hasMore = page.continuation != nil
        } catch {
            guard requestGeneration == generation, !Task.isCancelled else { return }
            if case HTTPError.requestIdentityChanged = error { clearPage() }
            if case HTTPError.authorityChanged = error { clearPage() }
            if items.isEmpty { self.error = ErrorState(error) }
        }
    }

    private func clearPage() {
        items = []
        continuation = nil
        totalItems = nil
        hasMore = true
    }
}
