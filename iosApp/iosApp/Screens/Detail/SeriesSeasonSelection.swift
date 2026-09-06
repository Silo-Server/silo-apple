import Foundation

/// Keeps a season choice and its carousel destination in the same operation.
/// Loads may finish after cancellation; only the latest choice can scroll.
@Observable
@MainActor
final class SeriesSeasonSelection {
    private(set) var latestSeasonId: String?
    @ObservationIgnored private var task: Task<Void, Never>?

    func select(
        _ season: Season,
        load: @escaping @MainActor (Season) async -> String?,
        didSelect: @escaping @MainActor (String) -> Void
    ) {
        cancel()
        latestSeasonId = season.id
        task = Task { @MainActor in
            guard !Task.isCancelled else { return }
            let contentId = await load(season)
            guard !Task.isCancelled else { return }
            task = nil
            if let contentId {
                // Keep the completed choice authoritative while SwiftUI still
                // has focus callbacks carrying the previous rendered season.
                didSelect(contentId)
            } else {
                latestSeasonId = nil
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        latestSeasonId = nil
    }
}
