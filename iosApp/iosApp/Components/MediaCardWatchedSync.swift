import Foundation

/// Catalog cards have no page-specific watched coordinator. The server
/// resolves movie/series targets; invalidate every derived list that can
/// depend on watched membership before the next visit.
@MainActor
enum MediaCardWatchedSync {
    /// Dispatches once through `PersonalStateSync` under the owner current at
    /// the tap. Caches are invalidated only for an applied change.
    static func setWatched(contentId: String, played: Bool, seriesId: String? = nil) async -> PersonalStateOutcome {
        let outcome = await PersonalStateSync.outcome {
            try await PersonalStateSync.set(.watched, contentId: contentId, to: played)
        }
        if outcome == .applied {
            PersonalStateSync.invalidateItemState(contentId: contentId, seriesId: seriesId)
        }
        return outcome
    }
}
