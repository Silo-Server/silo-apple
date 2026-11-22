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

    typealias FetchRecommendations = () async throws -> SectionsResponse
    private let fetchRecommendations: FetchRecommendations
    /// Loads now running, and the titles marked Not interested while any of
    /// them ran. A response the server built before the mark can still hold
    /// the title, so it is filtered out of what those loads return.
    private var loadsInFlight = 0
    private var markedDuringLoad: Set<String> = []

    init(fetchRecommendations: @escaping FetchRecommendations = StartupContentPrefetcher.fetchRecommendations) {
        self.fetchRecommendations = fetchRecommendations
        if let cached: SectionsResponse = ResponseCache.shared.get(CacheKey.recommendations) {
            sections = sortedNonEmptySections(from: cached.sections)
        }
    }

    func loadRecommendations() async {
        #if os(iOS)
        // MainTabView starts this before the lazy For You tab is constructed.
        // If the destination appears while that same model is still loading,
        // keep observing the in-flight result instead of scheduling duplicate
        // view work around the shared network single-flight.
        guard !isLoading, !isRefreshing else { return }
        #endif

        if sections.isEmpty {
            isLoading = true
        } else {
            isRefreshing = true
        }
        error = nil

        do {
            try await loadSections()
        } catch let err {
            if sections.isEmpty {
                self.error = ErrorState(err)
            }
        }

        isLoading = false
        isRefreshing = false
    }

    /// Pull-to-refresh variant — keeps existing content on screen while the
    /// network call is in flight so the list doesn't jump back to a spinner.
    func refresh() async {
        isRefreshing = true
        do {
            try await loadSections()
            error = nil
        } catch let err {
            self.error = ErrorState(err)
        }
        isRefreshing = false
    }

    /// Drops a title the server just marked Not interested, so it leaves the
    /// rows on screen at once instead of on the next load.
    func removeNotInterested(contentId: String) {
        if loadsInFlight > 0 {
            markedDuringLoad.insert(contentId)
        }
        sections = HomeSectionsMutation.removingNotInterestedFromRecommendations(
            contentId: contentId,
            from: sections
        )
        .filter { !$0.items.isEmpty }
    }

    /// Filters and assigns in the same turn as the response arrives, so no
    /// mark can land between the two.
    private func loadSections() async throws {
        loadsInFlight += 1
        defer {
            loadsInFlight -= 1
            if loadsInFlight == 0 { markedDuringLoad.removeAll() }
        }
        let response = try await fetchRecommendations()
        let unmarked = markedDuringLoad.reduce(response.sections) { sections, contentId in
            HomeSectionsMutation.removingNotInterestedFromRecommendations(contentId: contentId, from: sections)
        }
        sections = sortedNonEmptySections(from: unmarked)
    }

    private func sortedNonEmptySections(from raw: [ResolvedSection]) -> [ResolvedSection] {
        let nonEmpty = raw.filter { !$0.items.isEmpty }
        let forYou = nonEmpty.filter { $0.title.lowercased() == Self.forYouTitle }
        let others = nonEmpty.filter { $0.title.lowercased() != Self.forYouTitle }
        return forYou + others
    }
}
