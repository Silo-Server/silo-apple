import Foundation

/// Loads one movie box set for `BoxSetDetailView`.
@Observable
@MainActor
final class BoxSetDetailViewModel {
    let id: String
    let libraryId: Int
    private(set) var detail: CatalogBoxSetDetail?
    private(set) var error: ErrorState?

    private let api: SiloAPI
    /// Bumped by every load so an older answer never replaces a newer one.
    private var generation = 0

    init(id: String, libraryId: Int, api: SiloAPI = .shared) {
        self.id = id
        self.libraryId = libraryId
        self.api = api
    }

    /// Reads the box set. A reload over a shown box set (after playback, or
    /// back from one of its movies) keeps it on screen if the read fails,
    /// unless the server answers 404: box sets were turned off or too few of
    /// its movies are visible, so the page shows why instead of a stale Play.
    func load() async {
        generation += 1
        let myGeneration = generation
        do {
            let fresh = try await api.boxSet(id: id, libraryId: libraryId)
            guard myGeneration == generation, !Task.isCancelled else { return }
            detail = fresh
            error = nil
        } catch {
            guard myGeneration == generation, !Task.isCancelled else { return }
            let state = Self.errorState(error)
            if detail == nil || state.isNotFound {
                detail = nil
                self.error = state
            }
        }
    }

    /// A 404 means box sets are off for the library or too few of its movies
    /// are visible; say that rather than a bare "Not found".
    static func errorState(_ error: Error) -> ErrorState {
        let state = ErrorState(error)
        guard state.isNotFound else { return state }
        return ErrorState(
            statusCode: 404,
            message: "This box set isn't available. Box sets may be turned off for this library, or too few of its movies are here."
        )
    }
}
