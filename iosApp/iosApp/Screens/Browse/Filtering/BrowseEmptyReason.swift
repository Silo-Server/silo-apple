import Foundation

/// Why a browse grid came back with nothing to show.
enum BrowseEmptyReason: Equatable {
    /// The library holds no titles the active profile can see.
    case libraryEmpty
    /// The library has titles, but the active filters exclude all of them.
    case noFilterMatches

    /// Classify an empty first page. Without filters, an empty page already
    /// means the library is empty. With filters, `libraryHasItems` asks the
    /// catalog for one unfiltered item; it runs only on this path, so a
    /// non-empty grid never pays for it. A failed check keeps the filter
    /// message, whose Clear filters action is still a valid next step.
    static func classify(
        filter: CatalogFilterState,
        libraryHasItems: () async throws -> Bool
    ) async -> BrowseEmptyReason {
        guard filter.hasActiveFilters || filter.namePrefix != nil else { return .libraryEmpty }
        do {
            return try await libraryHasItems() ? .noFilterMatches : .libraryEmpty
        } catch {
            return .noFilterMatches
        }
    }
}
