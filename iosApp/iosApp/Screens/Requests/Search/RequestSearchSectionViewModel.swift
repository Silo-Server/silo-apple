import Foundation

/// Backs the "Available to request" section embedded in the library
/// `SearchView`. Driven by the same query string the catalog search owns
/// (one text field, one debounce feel, two independent result sets and
/// failure domains — a requests-API error just hides this supplementary
/// section without touching the primary search).
@Observable
@MainActor
final class RequestSearchSectionViewModel {
    private(set) var results: [RequestMediaResult] = []
    private(set) var isLoading = false

    private var searchTask: Task<Void, Never>?
    private let api: ContinuumAPI

    /// Cap the inline strip — it supplements library results, it doesn't
    /// replace the hub's full search.
    private let maxResults = 12

    init(api: ContinuumAPI = .shared) {
        self.api = api
    }

    func onQueryChanged(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard RequestsFeatureStore.shared.isEnabled, trimmed.count > 1 else {
            results = []
            isLoading = false
            return
        }
        searchTask = Task {
            // Same 300ms debounce as `SearchViewModel` for a single feel.
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await performSearch(trimmed)
        }
    }

    private func performSearch(_ trimmed: String) async {
        isLoading = true
        do {
            let page = try await api.requestsSearch(query: trimmed)
            guard !Task.isCancelled else { return }
            // Only titles the library can't already answer — in-library
            // matches are what the catalog grid above is for.
            results = page.results
                .filter { $0.availability != .available && $0.mediaType != .unknown }
                .prefix(maxResults)
                .map { $0 }
        } catch {
            guard !Task.isCancelled else { return }
            // Silent: this is a supplementary strip, not the primary search.
            results = []
        }
        isLoading = false
    }

    /// Bus consumer: flip ribbons in place after a create elsewhere.
    func applyRequestUpdate(_ record: MediaRequest) {
        results.applyRequestUpdate(record)
    }
}
