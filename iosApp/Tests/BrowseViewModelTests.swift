import XCTest
@testable import Silo

@MainActor
final class BrowseViewModelTests: XCTestCase {
    override func tearDown() {
        ResponseCache.shared.remove(CacheKey.userLibraries)
        super.tearDown()
    }

    func testMixedLibraryCategorySelectsTheMatchingVideoScope() {
        XCTAssertEqual(mixedLibraryVideoScope(libraryType: "mixed", category: .movies, selection: .series), .movie)
        XCTAssertEqual(mixedLibraryVideoScope(libraryType: "mixed", category: .series, selection: .movie), .series)
        XCTAssertEqual(mixedLibraryVideoScope(libraryType: "mixed", category: nil, selection: .series), .series)
        XCTAssertNil(mixedLibraryVideoScope(libraryType: "audiobooks", category: nil, selection: .movie))
    }

    func testSwitchingScopeOnSameLibraryClearsOldItemsAndUsesScopedCache() async throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let film = try decoder.decode(BrowseItem.self, from: Data(#"{"content_id":"film","type":"movie","title":"Film"}"#.utf8))
        let show = try decoder.decode(BrowseItem.self, from: Data(#"{"content_id":"show","type":"series","title":"Show"}"#.utf8))
        let movieKey = CacheKey.browse(libraryId: 809, filterKey: CatalogFilterState.none.cacheKeyFragment, mediaScope: "movie")
        let seriesKey = CacheKey.browse(libraryId: 809, filterKey: CatalogFilterState.none.cacheKeyFragment, mediaScope: "series")
        let combinedKey = CacheKey.browse(libraryId: 809, filterKey: CatalogFilterState.none.cacheKeyFragment)
        defer {
            for key in [movieKey, seriesKey, combinedKey] { ResponseCache.shared.remove(key) }
        }
        ResponseCache.shared.set(CatalogResponse(items: [film, show], total: 2, totalExact: true, hasMore: false), for: combinedKey)
        ResponseCache.shared.set(CatalogResponse(items: [film], total: 1, totalExact: true, hasMore: true), for: movieKey)
        ResponseCache.shared.set(CatalogResponse(items: [show], total: 1, totalExact: true, hasMore: false), for: seriesKey)
        let viewModel = BrowseViewModel()
        await viewModel.configure(libraryId: 809, libraryType: "mixed", mediaScope: .movie)
        XCTAssertEqual(viewModel.items.map(\.contentId), ["film"])
        XCTAssertEqual(viewModel.mediaType, .movie)
        XCTAssertTrue(viewModel.hasMore)
        await viewModel.configure(libraryId: 809, libraryType: "mixed", mediaScope: .series)
        XCTAssertEqual(viewModel.items.map(\.contentId), ["show"])
        XCTAssertEqual(viewModel.mediaType, .series)
        XCTAssertFalse(viewModel.hasMore)
    }

    func testConfigureUsesInitialMixedLibraryType() async {
        let viewModel = BrowseViewModel()

        await viewModel.configure(libraryId: 8, libraryType: "mixed")

        XCTAssertEqual(viewModel.mediaType, .mixed)
    }

    func testConfigureUsesCachedLibraryTypeBeforeItemsLoad() async {
        ResponseCache.shared.set(
            LibrariesResponse(libraries: [
                Library(id: 8, name: "Mixed Media", type: "mixed", sortOrder: nil, posterUrl: nil),
            ]),
            for: CacheKey.userLibraries
        )
        let viewModel = BrowseViewModel()

        await viewModel.configure(libraryId: 8)

        XCTAssertEqual(viewModel.mediaType, .mixed)
    }
}
