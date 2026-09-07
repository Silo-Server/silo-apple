import Foundation

@Observable
@MainActor
class RecommendationsViewModel {
    var sections: [ResolvedSection] = []
    var isLoading = false
    var isRefreshing = false
    var error: ErrorState?

    /// Matches the Android behavior: the row whose label is "For You"
    /// (case-insensitive) is pinned to the top; everything else keeps the
    /// server's order.
    private static let forYouTitle = "for you"

    private let api: SiloAPI
    private let tokens: TokenStore
    @ObservationIgnored private var requestToken = 0
    private(set) var displayedAuth: CapturedOrdinaryRequestAuth?
    let membership: ReadOwnedMembershipModel

    init(api: SiloAPI = .shared, tokens: TokenStore = .shared) {
        self.api = api
        self.tokens = tokens
        membership = ReadOwnedMembershipModel(api: api.v2, tokens: tokens)
    }

    func loadRecommendations() async {
        #if os(iOS)
        guard !isLoading, !isRefreshing else { return }
        #endif
        await load()
    }

    func refresh() async { await load() }

    private func load() async {
        requestToken += 1
        let run = requestToken
        let revisionAtStart = membership.mutationRevision
        defer {
            if run == requestToken && revisionAtStart == membership.mutationRevision { publishMembership() }
        }
        guard let auth = await tokens.captureOrdinaryRequestAuth(), auth.profileId != nil else {
            guard run == requestToken, !Task.isCancelled else { return }
            sections = []; isLoading = false; isRefreshing = false
            error = ErrorState(HTTPError.requestIdentityChanged)
            return
        }
        let mayRead = await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
        guard run == requestToken, !Task.isCancelled else { return }
        guard mayRead else { sections = []; isLoading = false; isRefreshing = false; return }
        guard revisionAtStart == membership.mutationRevision else { return }
        if let cached = StartupContentPrefetcher.cachedRecommendations(auth: auth) {
            sections = sortedNonEmptySections(from: cached.sections)
        } else if displayedAuth.map({ StartupContentPrefetcher.sameRecommendationOwner($0, auth) }) != true {
            sections = []
        }
        // Cache invalidation need not blank already-visible cards for the same owner.
        displayedAuth = auth
        publishMembership()
        isLoading = sections.isEmpty
        isRefreshing = !sections.isEmpty
        error = nil
        defer {
            if run == requestToken { isLoading = false; isRefreshing = false }
        }
        do {
            let revision = membership.mutationRevision
            let response = try await StartupContentPrefetcher.fetchRecommendations(auth: auth, api: api, tokens: tokens)
            let mayPublish = await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
            guard run == requestToken, !Task.isCancelled else { return }
            guard mayPublish else { sections = []; return }
            guard revision == membership.mutationRevision else {
                ResponseCache.shared.remove(CacheKey.recommendations)
                return
            }
            sections = sortedNonEmptySections(from: response.sections)
        } catch {
            let current = await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
            guard run == requestToken, !Task.isCancelled else { return }
            guard current else { sections = []; return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            self.error = ErrorState(error)
        }
    }

    private func publishMembership() {
        let owner = displayedAuth.map { CatalogCardOwner(auth: $0, scope: "recommendations", filterKey: "") }
        membership.publish(owner: owner, rows: sections.flatMap { $0.items.map { ($0.contentId, $0.userState) } },
            cacheKeys: [CacheKey.recommendations])
    }

    private func sortedNonEmptySections(from raw: [ResolvedSection]) -> [ResolvedSection] {
        let nonEmpty = raw.filter { !$0.items.isEmpty }
        let forYou = nonEmpty.filter { $0.title.lowercased() == Self.forYouTitle }
        let others = nonEmpty.filter { $0.title.lowercased() != Self.forYouTitle }
        return forYou + others
    }
}
