import Foundation

/// View-side projection of an `ItemDetail` containing only what a similar-item
/// poster card needs.
struct SimilarPosterItem: Identifiable, Hashable {
    let contentId: String
    let title: String
    let posterUrl: String?
    let posterThumbhash: String?
    let year: Int?

    var id: String { contentId }

    var accessibilityDescription: String {
        [title, year.map(String.init)].compactMap { $0 }.joined(separator: ", ")
    }

    init(detail: ItemDetail) {
        contentId = detail.contentId
        title = detail.title
        posterUrl = detail.posterUrl
        posterThumbhash = detail.posterThumbhash
        year = detail.year
    }
}

/// Resolves the ranked similar-item response into detail-card projections.
/// Failed detail lookups are non-fatal and the server's ranking is preserved.
enum SimilarRecommendationsLoader {
    static func load(
        contentId: String,
        limit: Int = 12,
        api: SiloAPI = .shared
    ) async throws -> [SimilarPosterItem] {
        let scored = try await api.recommendationsSimilar(
            contentId: contentId,
            limit: limit
        )
        let resolved = await withTaskGroup(of: (Int, ItemDetail?).self) { group in
            for (index, ref) in scored.enumerated() {
                group.addTask {
                    let detail = try? await api.itemDetail(contentId: ref.mediaItemId)
                    return (index, detail)
                }
            }

            var pairs: [(Int, ItemDetail)] = []
            for await (index, detail) in group {
                if let detail {
                    pairs.append((index, detail))
                }
            }
            return pairs.sorted(by: { $0.0 < $1.0 }).map(\.1)
        }
        return resolved.map(SimilarPosterItem.init(detail:))
    }
}
