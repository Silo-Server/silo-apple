import Foundation

/// Keeps collection pages with the library, media scope and profile that requested them.
@Observable
@MainActor
final class LibraryCollectionDetailViewModel {
    private(set) var items: [BrowseItem] = []
    private(set) var isLoading = false
    private(set) var hasLoadedOnce = false
    private(set) var pageSequence = 0
    private(set) var error: ErrorState?
    private(set) var refreshError: ErrorState?
    private(set) var paginationError: ErrorState?
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
    private var invalidationGeneration = 0
    private var hasPendingInvalidation = false

    init(api: SiloAPI = .shared, tokens: TokenStore = .shared) {
        self.api = api
        self.tokens = tokens
    }

    func noteInvalidation() {
        invalidationGeneration += 1
        hasPendingInvalidation = true
        continuation = nil
    }

    @discardableResult
    func load(libraryId: Int, collectionId: String, kind: LibraryCollectionKind,
              mediaScope: LibraryVideoScope?, reset: Bool) async -> Bool {
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
        } else if isLoading || !hasMore || refreshError != nil || hasPendingInvalidation {
            return false
        }
        var hadVisibleItemsBeforeLoad = !items.isEmpty
        let requestGeneration = generation
        let startInvalidation = invalidationGeneration
        isLoading = true
        error = nil
        paginationError = nil
        if resetsPage {
            refreshError = nil
        }
        defer {
            if requestGeneration == generation { isLoading = false }
        }

        for attempt in 0..<2 {
            let startToken = ResponseCache.shared.writeToken
            var capturedOwner: CapturedOrdinaryRequestAuth?
            var validatedReplacedPageOne = resetsPage || continuation == nil
            var validatedLoaded: [BrowseItem] = []
            var lastValidatedPage: CatalogListPage?
            do {
                guard let requestOwner = await tokens.captureOrdinaryRequestAuth() else {
                    throw HTTPError.requestIdentityChanged
                }
                capturedOwner = requestOwner
                guard requestGeneration == generation,
                      invalidationGeneration == startInvalidation,
                      !Task.isCancelled else { return false }
                if let owner, !owner.sameCredentialIdentity(as: requestOwner) { clearPage() }
                owner = requestOwner
                hadVisibleItemsBeforeLoad = !items.isEmpty
                if resetsPage, items.isEmpty,
                   let cached: CachedPage = ResponseCache.shared.get(requested.cacheKey),
                   cached.owner.sameCredentialIdentity(as: requestOwner) {
                    items = cached.response.items
                    totalItems = cached.response.totalExact == false ? nil : cached.response.total
                    hasMore = cached.response.hasMore ?? false
                    if !items.isEmpty {
                        hasLoadedOnce = true
                    }
                }

                // Cached rows have no live cursor. Their next load starts at page one.
                var nextPage = resetsPage ? nil : continuation
                var replacedPageOne = nextPage == nil
                validatedReplacedPageOne = replacedPageOne
                var seenIds = replacedPageOne ? Set<String>() : Set(items.map(\.id))
                var loaded: [BrowseItem] = []
                var restarts = 0
                var fetchedPages = 0
                let maxPagesPerBatch = 5
                var page: CatalogListPage
                // Accumulate distinct cards across pages until enough new items
                // are available to move CatalogGrid's load-more trigger onto a new
                // card, or until the continuation or per-batch budget is exhausted.
                var wasCacheInvalidated = false
                repeat {
                    fetchedPages += 1
                    if let currentPage = nextPage {
                        page = try await api.nextCatalogPage(currentPage)
                    } else {
                        var query = APIv2CatalogQuery.collectionItems(
                            kind: kind, collectionId: collectionId, limit: 60
                        )
                        query.type = mediaScope?.rawValue
                        if mediaScope != nil { query.libraryId = String(libraryId) }
                        page = try await api.catalogPage(query)
                    }
                    let stillOwnsRequest = await api.isCurrentOwner(requestOwner)
                    guard requestGeneration == generation,
                          invalidationGeneration == startInvalidation,
                          !Task.isCancelled else { return false }
                    guard stillOwnsRequest else { throw HTTPError.requestIdentityChanged }
                    if ResponseCache.shared.wasInvalidated(requested.cacheKey, after: startToken) {
                        wasCacheInvalidated = true
                        break
                    }

                    if page.startsOver {
                        restarts += 1
                        replacedPageOne = true
                        validatedReplacedPageOne = true
                        loaded = []
                        seenIds = []
                    }
                    for item in page.response.items where seenIds.insert(item.id).inserted {
                        loaded.append(item)
                    }
                    validatedLoaded = loaded
                    lastValidatedPage = page
                    nextPage = page.continuation
                } while loaded.count < CatalogGrid.loadMoreLead
                    && nextPage != nil
                    && restarts < 2
                    && fetchedPages < maxPagesPerBatch

                if wasCacheInvalidated {
                    if attempt == 0 && (resetsPage || continuation == nil) { continue }
                    let retryError = ErrorState(URLError(.cannotLoadFromNetwork))
                    if !resetsPage && continuation != nil {
                        continuation = nil
                        hasPendingInvalidation = true
                        self.refreshError = retryError
                    } else if items.isEmpty && (!hasLoadedOnce || kind != .regular) {
                        self.error = retryError
                    } else if resetsPage {
                        self.refreshError = retryError
                    } else {
                        self.paginationError = retryError
                    }
                    return false
                }

                if loaded.count < CatalogGrid.loadMoreLead && nextPage != nil && restarts >= 2 {
                    throw APIv2Error.invalidCatalogContinuation
                }

                let hitPageBudget = loaded.count < CatalogGrid.loadMoreLead && nextPage != nil

                if !replacedPageOne {
                    items.append(contentsOf: loaded)
                } else {
                    items = loaded
                    let cachedResponse = CatalogResponse(
                        items: loaded,
                        total: page.response.total,
                        totalExact: page.response.totalExact,
                        hasMore: page.continuation != nil
                    )
                    ResponseCache.shared.set(CachedPage(owner: requestOwner, response: cachedResponse),
                                             for: requested.cacheKey, fetchedAt: startToken)
                }
                if replacedPageOne || page.response.totalExact != false {
                    totalItems = page.response.totalExact == false ? nil : page.response.total
                }
                continuation = page.continuation
                hasMore = page.continuation != nil
                hasLoadedOnce = true
                pageSequence += 1
                error = nil
                paginationError = hitPageBudget ? ErrorState(APIv2Error.invalidCatalogContinuation) : nil
                if replacedPageOne {
                    refreshError = nil
                    hasPendingInvalidation = false
                }
                return !hitPageBudget
            } catch {
                var effectiveError = error
                var ownerStillValid = false
                if let capturedOwner {
                    let stillOwnsRequest = await api.isCurrentOwner(capturedOwner)
                    guard requestGeneration == generation,
                          invalidationGeneration == startInvalidation,
                          !Task.isCancelled else { return false }
                    if !stillOwnsRequest {
                        effectiveError = HTTPError.requestIdentityChanged
                    } else {
                        ownerStillValid = true
                    }
                } else {
                    guard requestGeneration == generation,
                          invalidationGeneration == startInvalidation,
                          !Task.isCancelled else { return false }
                    effectiveError = HTTPError.requestIdentityChanged
                }
                let isIdentityError: Bool
                if case HTTPError.requestIdentityChanged = effectiveError {
                    clearPage()
                    isIdentityError = true
                } else if case HTTPError.authorityChanged = effectiveError {
                    clearPage()
                    isIdentityError = true
                } else {
                    isIdentityError = false
                }
                if !isIdentityError,
                   ResponseCache.shared.wasInvalidated(requested.cacheKey, after: startToken) {
                    if attempt == 0 && (resetsPage || continuation == nil) { continue }
                    let retryError = ErrorState(URLError(.cannotLoadFromNetwork))
                    if !resetsPage && continuation != nil {
                        continuation = nil
                        hasPendingInvalidation = true
                        self.refreshError = retryError
                    } else if items.isEmpty && (!hasLoadedOnce || kind != .regular) {
                        self.error = retryError
                    } else if resetsPage {
                        self.refreshError = retryError
                    } else {
                        self.paginationError = retryError
                    }
                    return false
                }
                // If an earlier page in this batch already succeeded and ownership is
                // still intact, publish those validated cards and surface a retryable
                // pagination error on the failed continuation — unless this was a
                // refresh over already-visible pages, in which case keep the existing
                // pages intact and surface refreshError instead of replacing them with
                // an incomplete prefix.
                if ownerStillValid,
                   !isIdentityError,
                   !(resetsPage && hadVisibleItemsBeforeLoad),
                   let lastValidatedPage,
                   let capturedOwner,
                   (!validatedLoaded.isEmpty || lastValidatedPage.continuation != nil) {
                    if !validatedReplacedPageOne {
                        items.append(contentsOf: validatedLoaded)
                    } else {
                        items = validatedLoaded
                        let cachedResponse = CatalogResponse(
                            items: validatedLoaded,
                            total: lastValidatedPage.response.total,
                            totalExact: lastValidatedPage.response.totalExact,
                            hasMore: lastValidatedPage.continuation != nil
                        )
                        ResponseCache.shared.set(CachedPage(owner: capturedOwner, response: cachedResponse),
                                                 for: requested.cacheKey, fetchedAt: startToken)
                    }
                    if validatedReplacedPageOne || lastValidatedPage.response.totalExact != false {
                        totalItems = lastValidatedPage.response.totalExact == false ? nil : lastValidatedPage.response.total
                    }
                    continuation = lastValidatedPage.continuation
                    hasMore = lastValidatedPage.continuation != nil
                    hasLoadedOnce = true
                    pageSequence += 1
                    self.error = nil
                    if validatedReplacedPageOne {
                        self.refreshError = nil
                        hasPendingInvalidation = false
                    }
                    self.paginationError = ErrorState(effectiveError)
                    return false
                }
                if items.isEmpty && (!hasLoadedOnce || isIdentityError || kind != .regular) {
                    self.error = ErrorState(effectiveError)
                } else if resetsPage {
                    self.refreshError = ErrorState(effectiveError)
                } else {
                    self.paginationError = ErrorState(effectiveError)
                }
                return false
            }
        }
        return false
    }

    private func clearPage() {
        items = []
        hasLoadedOnce = false
        continuation = nil
        totalItems = nil
        hasMore = true
        refreshError = nil
        paginationError = nil
        hasPendingInvalidation = false
    }
}
