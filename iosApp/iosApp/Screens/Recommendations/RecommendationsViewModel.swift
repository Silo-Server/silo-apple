import Foundation

@Observable
@MainActor
class RecommendationsViewModel {
    var sections: [ResolvedSection] = []
    var isLoading = false
    var error: ErrorState?

    /// Matches the Android behavior: the row whose label is "For You"
    /// (case-insensitive) is pinned to the top; everything else keeps the
    /// server's order.
    private static let forYouTitle = "for you"

    init() {
        if let cached: SectionsResponse = ResponseCache.shared.get(CacheKey.recommendations) {
            sections = sortedNonEmptySections(from: cached.sections)
        }
    }

    func loadRecommendations() async {
        if sections.isEmpty {
            isLoading = true
        }
        error = nil

        do {
            let response = try await StartupContentPrefetcher.fetchRecommendations()
            sections = sortedNonEmptySections(from: response.sections)
        } catch let err {
            if sections.isEmpty {
                self.error = ErrorState(err)
            }
        }

        isLoading = false
    }

    /// Pull-to-refresh variant — keeps existing content on screen while the
    /// network call is in flight so the list doesn't jump back to a spinner.
    func refresh() async {
        do {
            let response = try await StartupContentPrefetcher.fetchRecommendations()
            sections = sortedNonEmptySections(from: response.sections)
            error = nil
        } catch let err {
            self.error = ErrorState(err)
        }
    }

    private func sortedNonEmptySections(from raw: [ResolvedSection]) -> [ResolvedSection] {
        let nonEmpty = raw.filter { !$0.items.isEmpty }
        let forYou = nonEmpty.filter { $0.title.lowercased() == Self.forYouTitle }
        let others = nonEmpty.filter { $0.title.lowercased() != Self.forYouTitle }
        return forYou + others
    }
}
