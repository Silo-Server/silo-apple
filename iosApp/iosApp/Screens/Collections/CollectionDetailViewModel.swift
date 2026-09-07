import Foundation

@Observable
@MainActor
final class CollectionDetailViewModel {
    private(set) var items: [BrowseItem] = []
    private(set) var isLoading = false
    private(set) var error: ErrorState?
    private(set) var hasMore = false
    private(set) var totalItems: Int?
    private var continuation: APIv2CatalogContinuation?
    let membership: ReadOwnedMembershipModel
    private let api: APIv2Client
    private let tokens: TokenStore
    private var generation = 0
    private struct CachedRead {
        let owner: CatalogCardOwner
        let response: CatalogResponse
    }

    init(api: APIv2Client = SiloAPI.shared.v2, tokens: TokenStore = .shared) {
        self.api = api
        self.tokens = tokens
        membership = ReadOwnedMembershipModel(api: api, tokens: tokens)
    }

    func cancel() {
        generation += 1
        items = []
        membership.publish(owner: nil, rows: [])
        isLoading = false
        hasMore = false
        continuation = nil
        totalItems = nil
    }

    func load(collectionId: String) async {
        generation += 1
        let run = generation
        isLoading = true
        error = nil
        defer { if run == generation { isLoading = false } }
        let captured = await tokens.captureOrdinaryRequestAuth()
        guard run == generation, !Task.isCancelled else { return }
        guard let auth = captured, auth.profileId != nil else {
            items = []; membership.publish(owner: nil, rows: [])
            error = ErrorState(HTTPError.requestIdentityChanged)
            return
        }
        let owner = CatalogCardOwner(auth: auth, scope: "collection:\(collectionId)", filterKey: "")
        let key = CacheKey.collectionItems(collectionId)
        if membership.displayedRead != owner {
            items = []; membership.publish(owner: nil, rows: [])
        }
        do {
            guard await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
                throw HTTPError.requestIdentityChanged
            }
            guard run == generation, !Task.isCancelled else { return }
            if let cached: CachedRead = ResponseCache.shared.get(key), cached.owner == owner {
                publish(cached.response, owner: owner, key: key)
            }
            let revision = membership.mutationRevision
            let response = try await api.personalCollectionCards(id: collectionId, auth: auth)
            let current = await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
            guard run == generation, !Task.isCancelled else { return }
            guard current else { throw HTTPError.requestIdentityChanged }
            guard revision == membership.mutationRevision else { return }
            ResponseCache.shared.set(CachedRead(owner: owner, response: response), for: key)
            publish(response, owner: owner, key: key)
        } catch {
            let current = await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
            guard run == generation, !Task.isCancelled else { return }
            if !current { items = []; membership.publish(owner: nil, rows: []) }
            self.error = ErrorState(error)
        }
    }

    /// Library collections keep incremental paging, with the same captured owner
    /// on every continuation and no legacy unowned cache hydration.
    func loadCatalog(query: APIv2CatalogQuery, reset: Bool) async {
        guard reset || (hasMore && !isLoading) else { return }
        if reset { generation += 1 }
        let run = generation
        isLoading = true
        error = nil
        defer { if run == generation { isLoading = false } }
        let captured = await tokens.captureOrdinaryRequestAuth()
        guard run == generation, !Task.isCancelled else { return }
        guard let auth = captured, auth.profileId != nil else { cancel(); return }
        let key = query.source == "history" ? CacheKey.history : CacheKey.collectionItems(query.collectionId ?? "")
        let owner = CatalogCardOwner(auth: auth,
            scope: "collection:\(query.source):\(query.libraryId ?? ""):\(query.collectionId ?? "")", filterKey: "")
        if membership.displayedRead != owner {
            items = []; continuation = nil; hasMore = false
            membership.publish(owner: nil, rows: [])
            guard reset else { error = ErrorState(HTTPError.requestIdentityChanged); return }
        }
        let revision = membership.mutationRevision
        do {
            let page: APIv2CatalogResult
            if reset {
                page = try await api.catalogPage(query: query, auth: auth)
            } else {
                guard let continuation, continuation.auth == auth, continuation.query == query else {
                    throw HTTPError.requestIdentityChanged
                }
                page = try await api.nextCatalogPage(continuation)
            }
            let current = await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
            guard run == generation, !Task.isCancelled else { return }
            guard current, page.auth == auth else { throw HTTPError.requestIdentityChanged }
            guard revision == membership.mutationRevision else { return }
            if reset {
                items = page.value.items
            } else {
                // Preserve accepted flags on existing cards while appending a page.
                items = items.map { item in
                    var updated = item
                    updated.userState = membership.userState(for: item.contentId) ?? item.userState
                    return updated
                }
                let existing = Set(items.map(\.contentId))
                items.append(contentsOf: page.value.items.filter { !existing.contains($0.contentId) })
            }
            totalItems = page.value.totalExact ? page.value.total : nil
            continuation = page.continuation
            hasMore = continuation != nil
            membership.publish(owner: owner, rows: items.map { ($0.contentId, $0.userState) }, cacheKeys: [key])
        } catch {
            let current = await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
            guard run == generation, !Task.isCancelled else { return }
            if !current { items = []; membership.publish(owner: nil, rows: []) }
            hasMore = false
            self.error = ErrorState(error)
        }
    }

    private func publish(_ response: CatalogResponse, owner: CatalogCardOwner, key: String) {
        items = response.items
        membership.publish(owner: owner, rows: items.map { ($0.contentId, $0.userState) }, cacheKeys: [key])
    }
}
