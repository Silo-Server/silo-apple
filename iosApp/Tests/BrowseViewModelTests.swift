import XCTest
@testable import Silo

@MainActor
final class BrowseViewModelTests: XCTestCase {
    override func tearDown() {
        ResponseCache.shared.remove(CacheKey.userLibraries)
        super.tearDown()
    }

    func testMixedLibraryUsesTheSelectedVideoScope() {
        XCTAssertEqual(mixedLibraryVideoScope(libraryType: "mixed", selection: .series), .series)
        XCTAssertEqual(mixedLibraryVideoScope(libraryType: "mixed", selection: .movie), .movie)
        XCTAssertNil(mixedLibraryVideoScope(libraryType: "audiobooks", selection: .movie))
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

    func testJumpingToALetterReadsItsFirstPageAndAllBringsTheLibraryBack() async throws {
        let stub = APIv2TestStub()
        let api = try await stubbedAPI(stub)
        let library = Self.page(["movie:alien", "movie:matrix"], nextCursor: "cursor-2")
        stub.sequence([.json(200, library), .json(200, Self.page(["movie:matrix"])), .json(200, library)])
        var letterM = CatalogFilterState.none
        letterM.namePrefix = "M"
        let cacheKeys = [CatalogFilterState.none, letterM].map {
            CacheKey.browse(libraryId: 811, filterKey: $0.cacheKeyFragment)
        }
        defer {
            for key in cacheKeys { ResponseCache.shared.remove(key) }
        }
        var lettersRead: [String?] = []
        let viewModel = BrowseViewModel { libraryId, state, mediaScope in
            lettersRead.append(state.namePrefix)
            return try await api.catalogPage(CatalogQueryBuilder.build(
                state, libraryId: libraryId, mediaType: .movie, limit: 60, includeType: false, enforcedScope: mediaScope
            ))
        }
        await viewModel.configure(libraryId: 811, libraryType: "movies")
        await viewModel.loadItems(reset: true)
        XCTAssertEqual(viewModel.items.map(\.contentId), ["movie:alien", "movie:matrix"])
        XCTAssertTrue(viewModel.hasMore)

        await viewModel.jumpToPrefix("M")

        XCTAssertEqual(viewModel.filterState.namePrefix, "M")
        XCTAssertEqual(viewModel.items.map(\.contentId), ["movie:matrix"], "the letter's page replaces the grid")
        XCTAssertFalse(viewModel.hasMore)
        XCTAssertEqual(stub.requests.last?.query["name_prefix"], "M")
        XCTAssertNil(stub.requests.last?.query["cursor"], "a letter starts again from page 1")

        await viewModel.jumpToPrefix(nil)

        XCTAssertNil(viewModel.filterState.namePrefix)
        XCTAssertEqual(viewModel.items.map(\.contentId), ["movie:alien", "movie:matrix"])
        XCTAssertNil(stub.requests.last?.query["name_prefix"])
        XCTAssertEqual(lettersRead, [nil, "M", nil], "one page-1 read per change, none through the old cursor")
        XCTAssertEqual(stub.requests.count, 3)
    }

    private func stubbedAPI(_ stub: APIv2TestStub) async throws -> SiloAPI {
        let name = "BrowseViewModelTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "browse-test")
        await tokens.setServerUrl("https://browse.example")
        await tokens.setProfileId("profile-one")
        return SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
    }

    private static func page(_ ids: [String], nextCursor: String? = nil) -> String {
        let items = ids.map { #"{"content_id":"\#($0)","type":"movie","title":"\#($0)"}"# }.joined(separator: ",")
        let page = nextCursor.map { #"{"has_more":true,"next_cursor":"\#($0)"}"# } ?? #"{"has_more":false}"#
        return #"{"items":[\#(items)],"page":\#(page),"total":\#(ids.count),"total_exact":true,"window_cursor":"w"}"#
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
