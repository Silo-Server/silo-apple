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

    func testJumpingPastTheLoadedTitlesKeepsTheLettersBeforeItWithinReach() async throws {
        let stub = APIv2TestStub()
        let api = try await stubbedAPI(stub)
        let letters = #"{"total":130,"letters":[{"letter":"A","count":70,"position":0},{"letter":"Y","count":60,"position":70}],"runs":[{"letter":"A","position":0},{"letter":"Y","position":70}]}"#
        let titles = { (range: Range<Int>) in range.map { "movie:t\($0)" } }
        stub.sequence([
            .json(200, Self.page(["movie:alien", "movie:avatar"], nextCursor: "cursor-2")),
            .json(200, letters),
            .json(200, Self.page(titles(51..<129))),
            .json(200, Self.page(titles(0..<51))),
            .json(200, Self.page(titles(129..<130))),
        ])
        let cacheKey = CacheKey.browse(libraryId: 811, filterKey: CatalogFilterState.none.cacheKeyFragment)
        defer {
            ResponseCache.shared.remove(cacheKey)
            ResponseCache.shared.remove("browseletters:" + cacheKey)
        }
        let viewModel = BrowseViewModel(
            readFirstPage: { libraryId, state, mediaScope in
                try await api.catalogPage(CatalogQueryBuilder.build(
                    state, libraryId: libraryId, mediaType: .movie, limit: 60, includeType: false, enforcedScope: mediaScope
                ))
            },
            readPage: { try await api.catalogPage($0) },
            readLetters: { try await api.catalogLetters($0) }
        )
        await viewModel.configure(libraryId: 811, libraryType: "movies")
        await viewModel.loadItems(reset: true)
        await viewModel.loadLetterIndex()
        XCTAssertEqual(stub.requests.last?.path, "/api/v2/catalog/letters")

        let loaded = await viewModel.jump(to: "A", columns: 3)
        XCTAssertEqual(loaded, "movie:alien", "a loaded letter is only a scroll away")
        XCTAssertEqual(stub.requests.count, 2)

        // Y's first title is at 70, in the row starting at 69; the grid starts
        // six rows above that row.
        let jumped = await viewModel.jump(to: "Y", columns: 3)
        XCTAssertEqual(jumped, "movie:t70")
        XCTAssertEqual(stub.requests.last?.query["seek"], "51")
        XCTAssertEqual(stub.requests.last?.query["limit"], "78")
        XCTAssertEqual(viewModel.windowStart, 51)
        XCTAssertTrue(viewModel.hasEarlier)

        // Scrolling up from Y reads the titles above it, whole rows at a time.
        await viewModel.loadEarlier(columns: 3)
        XCTAssertNil(stub.requests.last?.query["seek"], "position 0 is the first page")
        XCTAssertEqual(stub.requests.last?.query["limit"], "51")
        XCTAssertEqual(viewModel.windowStart, 0)
        XCTAssertFalse(viewModel.hasEarlier)
        XCTAssertEqual(viewModel.items.first?.contentId, "movie:t0")
        XCTAssertEqual(viewModel.items.count, 129)

        // Scrolling down continues by position, not through page 1's cursor.
        await viewModel.loadItems()
        XCTAssertEqual(stub.requests.last?.query["seek"], "129")
        XCTAssertNil(stub.requests.last?.query["cursor"])
        XCTAssertEqual(viewModel.items.count, 130)
        XCTAssertFalse(viewModel.hasMore)
    }

    func testTitleOrderReadsTheListByPositionOnceTheLetterIndexArrives() async throws {
        let stub = APIv2TestStub()
        let api = try await stubbedAPI(stub)
        let letters = #"{"total":430,"letters":[{"letter":"A","count":370,"position":0},{"letter":"Y","count":60,"position":370}],"runs":[{"letter":"A","position":0},{"letter":"Y","position":370}]}"#
        let hundred = Self.page((0..<100).map { "movie:t\($0)" })
        stub.sequence([
            .json(200, Self.page(["movie:alien", "movie:avatar"], nextCursor: "cursor-2")),
            .json(200, letters),
            .json(200, hundred),
            .json(200, hundred),
            .json(200, letters),
        ])
        let cacheKey = CacheKey.browse(libraryId: 812, filterKey: CatalogFilterState.none.cacheKeyFragment)
        defer { ResponseCache.shared.remove(cacheKey) }
        let viewModel = BrowseViewModel(
            readFirstPage: { libraryId, state, mediaScope in
                try await api.catalogPage(CatalogQueryBuilder.build(
                    state, libraryId: libraryId, mediaType: .movie, limit: 60, includeType: false, enforcedScope: mediaScope
                ))
            },
            readPage: { try await api.catalogPage($0) },
            readLetters: { try await api.catalogLetters($0) }
        )
        await viewModel.configure(libraryId: 812, libraryType: "movies")
        await viewModel.loadItems(reset: true)
        XCTAssertNil(viewModel.pager, "no letter index yet: the grid shows the loaded titles")
        await viewModel.loadLetterIndex()
        let pager = try XCTUnwrap(viewModel.pager)
        XCTAssertEqual(pager.total, 430, "the grid is as long as the whole list")

        // Y's first title and the screenful after it span two pages.
        let position = await viewModel.position(forJumpTo: "Y", patience: .seconds(2))
        XCTAssertEqual(position, 370)
        let reads = stub.requests.dropFirst(2)
        XCTAssertEqual(reads.compactMap { $0.query["seek"] }.sorted(), ["300", "400"])
        XCTAssertEqual(Set(reads.compactMap { $0.query["limit"] }), ["100"])
        XCTAssertNotNil(pager.item(at: 370))

        // Coming back to the screen reads the index again; the same list
        // keeps the titles already read.
        await viewModel.loadLetterIndex()
        XCTAssertTrue(viewModel.pager === pager)
    }

    func testAJumpToALoadedLetterOverridesAnEarlierJumpStillLoading() async throws {
        let stub = APIv2TestStub()
        let api = try await stubbedAPI(stub)
        let letters = #"{"total":130,"letters":[{"letter":"A","count":70,"position":0},{"letter":"Y","count":60,"position":70}],"runs":[{"letter":"A","position":0},{"letter":"Y","position":70}]}"#
        stub.sequence([
            .json(200, Self.page(["movie:alien", "movie:avatar"], nextCursor: "cursor-2")),
            .json(200, letters),
            .json(200, Self.page(["movie:yojimbo"])),
        ])
        let cacheKey = CacheKey.browse(libraryId: 812, filterKey: CatalogFilterState.none.cacheKeyFragment)
        defer {
            ResponseCache.shared.remove(cacheKey)
            ResponseCache.shared.remove("browseletters:" + cacheKey)
        }
        let viewModel = BrowseViewModel(
            readFirstPage: { libraryId, state, mediaScope in
                try await api.catalogPage(CatalogQueryBuilder.build(
                    state, libraryId: libraryId, mediaType: .movie, limit: 60, includeType: false, enforcedScope: mediaScope
                ))
            },
            readPage: { try await api.catalogPage($0) },
            readLetters: { try await api.catalogLetters($0) }
        )
        await viewModel.configure(libraryId: 812, libraryType: "movies")
        await viewModel.loadItems(reset: true)
        await viewModel.loadLetterIndex()

        stub.hold(path: "/api/v2/catalog")
        let toY = Task { await viewModel.jump(to: "Y", columns: 3) }
        await stub.waitUntilHeld()
        let toA = await viewModel.jump(to: "A", columns: 3)
        stub.release()
        let staleY = await toY.value

        XCTAssertEqual(toA, "movie:alien")
        XCTAssertNil(staleY, "the later jump wins")
        XCTAssertEqual(viewModel.items.first?.contentId, "movie:alien")
        XCTAssertFalse(viewModel.hasEarlier)
    }

    func testAJumpThatOvertakesALoadingPageLeavesTheGridFreeToLoadMore() async throws {
        let stub = APIv2TestStub()
        let api = try await stubbedAPI(stub)
        let letters = #"{"total":300,"letters":[{"letter":"A","count":100,"position":0},{"letter":"M","count":100,"position":100},{"letter":"Y","count":100,"position":200}],"runs":[{"letter":"A","position":0},{"letter":"M","position":100},{"letter":"Y","position":200}]}"#
        stub.sequence([
            .json(200, Self.page(["movie:alien", "movie:avatar"], nextCursor: "cursor-2")),
            .json(200, letters),
            .json(200, Self.page((182..<260).map { "movie:t\($0)" })),
            .json(200, Self.page(["movie:t260"])),
        ])
        let cacheKey = CacheKey.browse(libraryId: 813, filterKey: CatalogFilterState.none.cacheKeyFragment)
        defer {
            ResponseCache.shared.remove(cacheKey)
            ResponseCache.shared.remove("browseletters:" + cacheKey)
        }
        // Positional reads park here while `parking` is set, and fail while
        // `failing` is set.
        var parking = false
        var failing = false
        var parked: CheckedContinuation<Void, Never>?
        let viewModel = BrowseViewModel(
            readFirstPage: { libraryId, state, mediaScope in
                try await api.catalogPage(CatalogQueryBuilder.build(
                    state, libraryId: libraryId, mediaType: .movie, limit: 60, includeType: false, enforcedScope: mediaScope
                ))
            },
            readPage: { query in
                if failing { throw URLError(.notConnectedToInternet) }
                if parking { await withCheckedContinuation { parked = $0 } }
                return try await api.catalogPage(query)
            },
            readLetters: { try await api.catalogLetters($0) }
        )
        await viewModel.configure(libraryId: 813, libraryType: "movies")
        await viewModel.loadItems(reset: true)
        await viewModel.loadLetterIndex()
        let landedOnY = await viewModel.jump(to: "Y", columns: 3)
        XCTAssertNotNil(landedOnY)

        // The page below Y is loading when a jump to M overtakes it and fails.
        parking = true
        let loadMore = Task { await viewModel.loadItems() }
        while parked == nil { await Task.yield() }
        XCTAssertTrue(viewModel.isLoading)
        parking = false
        failing = true
        let failedJump = await viewModel.jump(to: "M", columns: 3)
        XCTAssertNil(failedJump)
        XCTAssertFalse(viewModel.isLoading, "the overtaken page no longer blocks loading more")

        failing = false
        parked?.resume()
        await loadMore.value
        XCTAssertFalse(viewModel.isLoading)
    }

    func testFiltersReportHowManyTitlesTheyLeave() async throws {
        let stub = APIv2TestStub()
        let api = try await stubbedAPI(stub)
        stub.sequence([
            .json(200, Self.page(["movie:alien"], nextCursor: "c", total: 1284)),
            .json(200, Self.page(["movie:alien"], nextCursor: "c", total: 42)),
            .json(200, Self.page(["movie:alien"], nextCursor: "c", total: 500, exact: false)),
            .json(200, Self.page(["movie:alien"], nextCursor: "c", total: 1284)),
        ])
        let unfiltered = CatalogFilterState.none
        var drama = unfiltered
        drama.genres = ["Drama"]
        var dramaOrComedy = drama
        dramaOrComedy.genres = ["Drama", "Comedy"]
        defer {
            for state in [unfiltered, drama, dramaOrComedy] {
                ResponseCache.shared.remove(CacheKey.browse(libraryId: 812, filterKey: state.cacheKeyFragment))
            }
        }
        let viewModel = BrowseViewModel(
            readFirstPage: { libraryId, state, mediaScope in
                try await api.catalogPage(CatalogQueryBuilder.build(
                    state, libraryId: libraryId, mediaType: .movie, limit: 60, includeType: false, enforcedScope: mediaScope
                ))
            },
            readPage: { try await api.catalogPage($0) },
            readLetters: { _ in nil }
        )
        await viewModel.configure(libraryId: 812, libraryType: "movies")
        await viewModel.loadItems(reset: true)
        XCTAssertNil(viewModel.filteredTotal, "the header counts the whole library itself")

        await viewModel.apply(drama)
        XCTAssertEqual(viewModel.filteredTotal, .exact(42))

        await viewModel.apply(dramaOrComedy)
        XCTAssertEqual(viewModel.filteredTotal, .uncounted, "an estimate is not shown as the count")

        await viewModel.clearFilters()
        XCTAssertNil(viewModel.filteredTotal)
    }

    func testRestoredFiltersNeverShowTheWholeLibraryCount() async throws {
        // Saved filters are kept per account; give this run one, then put
        // back whatever the host had.
        let defaults = SharedDefaults.shared
        let keys = [SharedStorage.activeServerIdKey, SharedStorage.activeAccountKey, SharedStorage.profileIdKey]
        let saved = keys.map { defaults.object(forKey: $0) }
        addTeardownBlock {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.setObject(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let selection = AccountSelection(serverId: "browse-restore", localAccountId: UUID().uuidString)
        defaults.set("browse-restore", forKey: SharedStorage.activeServerIdKey)
        defaults.set(try JSONEncoder().encode(selection), forKey: SharedStorage.activeAccountKey)
        defaults.set("profile-one", forKey: SharedStorage.profileIdKey)
        var drama = CatalogFilterState.none
        drama.genres = ["Drama"]
        BrowsePrefsStore.shared.saveState(drama, libraryId: 813)
        defer { BrowsePrefsStore.shared.clearState(libraryId: 813) }

        let viewModel = BrowseViewModel(
            readFirstPage: { _, _, _ in throw URLError(.notConnectedToInternet) },
            readLetters: { _ in nil }
        )
        await viewModel.configure(libraryId: 813, libraryType: "movies")
        XCTAssertEqual(viewModel.filterState.genres, ["Drama"])
        XCTAssertEqual(viewModel.filteredTotal, .uncounted, "loading")
        await viewModel.loadItems(reset: true)
        XCTAssertEqual(viewModel.filteredTotal, .uncounted, "the first page failed")
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

    private static func page(_ ids: [String], nextCursor: String? = nil, total: Int? = nil, exact: Bool = true) -> String {
        let items = ids.map { #"{"content_id":"\#($0)","type":"movie","title":"\#($0)"}"# }.joined(separator: ",")
        let page = nextCursor.map { #"{"has_more":true,"next_cursor":"\#($0)"}"# } ?? #"{"has_more":false}"#
        return #"{"items":[\#(items)],"page":\#(page),"total":\#(total ?? ids.count),"total_exact":\#(exact),"window_cursor":"w"}"#
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
