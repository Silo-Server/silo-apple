import XCTest
@testable import Silo

/// A favorite, watchlist or watched change drops the same cross-screen caches
/// whichever screen made it. Personal-state writes go through the injected
/// `send`, so nothing reaches a signed-in server.
@MainActor
final class PersonalStateCacheInvalidationTests: XCTestCase {
    private let itemId = "personal-state-cache-episode"
    private let seriesId = "personal-state-cache-series"
    private let libraryId = 918_273
    private let collectionId = "personal-state-cache-collection"

    /// Lists and grids that can show an item's personal flags, one key from
    /// each `CacheKey` builder.
    private var listAndGridKeys: [String] {
        [
            CacheKey.homeSections,
            CacheKey.recommendations,
            CacheKey.favorites,
            CacheKey.watchlist,
            CacheKey.history,
            CacheKey.browse(libraryId: libraryId, filterKey: "sort=title"),
            CacheKey.browse(libraryId: nil, filterKey: "sort=title"),
            CacheKey.tvLibrary(libraryId: libraryId, filterKey: "sort=title"),
            CacheKey.librarySections(libraryId),
            CacheKey.collectionItems(collectionId),
            CacheKey.catalogCollectionItems(collectionId),
        ]
    }

    func testDetailChangeDropsLibraryAndCollectionGrids() async throws {
        let seeded = listAndGridKeys + [CacheKey.itemDetail(seriesId)]
        defer { remove(seeded) }
        let model = try hydratedEpisode()
        seed(seeded)

        await model.toggleWatched(send: { _, _ in .applied })

        for key in seeded {
            XCTAssertNil(ResponseCache.shared.get(key, as: String.self), "\(key) should be dropped")
        }
    }

    func testPersonalStateInvalidationKeepsUnrelatedEntries() {
        let kept = [
            // The card path writes this pair back and must keep it.
            CacheKey.itemDetail(itemId),
            CacheKey.itemUserState(itemId),
            // "collections:list" must not match the "collection:" prefix.
            CacheKey.collections,
            CacheKey.catalogFilters(libraryId: libraryId),
            CacheKey.calendarWeek("personal-state-cache-week", filter: "all"),
        ]
        defer { remove(listAndGridKeys + kept) }
        seed(listAndGridKeys + kept)

        ResponseCache.shared.invalidatePersonalState()

        for key in listAndGridKeys {
            XCTAssertNil(ResponseCache.shared.get(key, as: String.self), "\(key) should be dropped")
        }
        for key in kept {
            XCTAssertNotNil(ResponseCache.shared.get(key, as: String.self), "\(key) should stay")
        }
    }

    // MARK: - Fixtures

    /// An episode page painted from cache. Episodes skip `/watch` enrichment
    /// and have no season structure, and the test never loads, so nothing
    /// reaches the network.
    private func hydratedEpisode() throws -> ItemDetailViewModel {
        let json = """
            {"contentId":"\(itemId)","type":"episode","title":"Synthetic",\
            "seriesId":"\(seriesId)","userData":{"played":false}}
            """
        let detail = try JSONDecoder().decode(ItemDetail.self, from: Data(json.utf8))
        ResponseCache.shared.set(detail, for: CacheKey.itemDetail(itemId))
        let model = ItemDetailViewModel()
        model.hydrateFromCache(contentId: itemId)
        XCTAssertEqual(model.detail?.seriesId, seriesId)
        return model
    }

    private func seed(_ keys: [String]) {
        for key in keys { ResponseCache.shared.set("seeded", for: key) }
    }

    /// Also clears the hydrated episode's own entries.
    private func remove(_ keys: [String]) {
        for key in keys { ResponseCache.shared.remove(key) }
        ResponseCache.shared.removeAll(withPrefix: CacheKey.itemDetail(itemId))
    }
}
