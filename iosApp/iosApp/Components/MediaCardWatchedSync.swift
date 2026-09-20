import Foundation

/// Catalog cards have no page-specific watched coordinator. The server
/// resolves movie/series targets; invalidate every derived list that can
/// depend on watched membership before the next visit.
@MainActor
enum MediaCardWatchedSync {
    static func setWatched(contentId: String, played: Bool, seriesId: String? = nil) async -> Bool {
        do {
            try await SiloAPI.shared.setWatched(contentId: contentId, played: played)
            ResponseCache.shared.removeItemMetadata(contentId: contentId)
            if let seriesId {
                ResponseCache.shared.removeItemMetadata(contentId: seriesId)
            }
            StartupContentPrefetcher.invalidateHomeSectionsInFlight()
            for key in [CacheKey.homeSections, CacheKey.recommendations, CacheKey.favorites,
                        CacheKey.watchlist, CacheKey.history] {
                ResponseCache.shared.remove(key)
            }
            for prefix in ["browse:", "tvlibrary:", "library:", "collection:"] {
                ResponseCache.shared.removeAll(withPrefix: prefix)
            }
            #if os(tvOS)
            ItemDetailCache.shared.markStaleFamily(contentId: contentId)
            #endif
            return true
        } catch {
            return false
        }
    }
}
