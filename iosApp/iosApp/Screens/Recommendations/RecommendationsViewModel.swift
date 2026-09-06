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
    @ObservationIgnored private var displayedAuth: CapturedOrdinaryRequestAuth?

    init(api: SiloAPI = .shared, tokens: TokenStore = .shared) {
        self.api = api
        self.tokens = tokens
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
        guard let auth = await tokens.captureOrdinaryRequestAuth(), auth.profileId != nil else {
            guard run == requestToken, !Task.isCancelled else { return }
            sections = []; isLoading = false; isRefreshing = false
            error = ErrorState(HTTPError.requestIdentityChanged)
            return
        }
        let mayRead = await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
        guard run == requestToken, !Task.isCancelled else { return }
        guard mayRead else { sections = []; isLoading = false; isRefreshing = false; return }
        if let cached = StartupContentPrefetcher.cachedRecommendations(auth: auth) {
            sections = sortedNonEmptySections(from: cached.sections)
        } else if displayedAuth.map({ StartupContentPrefetcher.sameRecommendationOwner($0, auth) }) != true {
            sections = []
        }
        // Cache invalidation need not blank already-visible cards for the same owner.
        displayedAuth = auth
        isLoading = sections.isEmpty
        isRefreshing = !sections.isEmpty
        error = nil
        defer {
            if run == requestToken { isLoading = false; isRefreshing = false }
        }
        do {
            let response = try await StartupContentPrefetcher.fetchRecommendations(auth: auth, api: api, tokens: tokens)
            let mayPublish = await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
            guard run == requestToken, !Task.isCancelled else { return }
            guard mayPublish else { sections = []; return }
            sections = sortedNonEmptySections(from: response.sections)
        } catch {
            let current = await tokens.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
            guard run == requestToken, !Task.isCancelled else { return }
            guard current else { sections = []; return }
            if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
            self.error = ErrorState(error)
        }
    }

    private func sortedNonEmptySections(from raw: [ResolvedSection]) -> [ResolvedSection] {
        let nonEmpty = raw.filter { !$0.items.isEmpty }
        let forYou = nonEmpty.filter { $0.title.lowercased() == Self.forYouTitle }
        let others = nonEmpty.filter { $0.title.lowercased() != Self.forYouTitle }
        return forYou + others
    }
}
