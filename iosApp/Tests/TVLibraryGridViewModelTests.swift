#if os(tvOS)
import Foundation
import XCTest
@testable import Silo

/// The Apple TV library grid paints page 1 from the response cache, then
/// fetches it again once, so a title added or removed on the server shows
/// without a relaunch. A list that already holds a live page is left alone.
@MainActor
final class TVLibraryGridViewModelTests: XCTestCase {
    private var stub = APIv2TestStub()
    private var cacheKeys: [String] = []

    override func setUp() async throws {
        try await super.setUp()
        stub = APIv2TestStub()
    }

    override func tearDown() async throws {
        for key in cacheKeys { ResponseCache.shared.remove(key) }
        cacheKeys = []
        try await super.tearDown()
    }

    private func api(session: URLSession? = nil) async throws -> SiloAPI {
        let name = "TVLibraryGridViewModelTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "tv-grid-test")
        await tokens.setServerUrl("https://tv-grid.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: session ?? stub.makeSession(), tokenStore: tokens)
        // Its own capability, so sizing the artwork never reaches the shared client.
        let capability = ImageSizeCapability(platformPrefersLargeImages: false) { throw URLError(.unsupportedURL) }
        return SiloAPI(http: http, tokenStore: tokens, imageSizeCapability: capability)
    }

    /// A grid opened over `ids` cached as the library's page 1. Nothing
    /// suspends between the cache write and the model's `init`, so the host
    /// app's own startup cannot clear the entry in between.
    private func cachedGrid(
        _ ids: [String], libraryId: Int, hasMore: Bool, filter: CatalogFilterState = .none, api: SiloAPI
    ) throws -> TVLibraryGridViewModel {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let items = try ids.map {
            try decoder.decode(BrowseItem.self, from: Data(#"{"content_id":"\#($0)","type":"movie","title":"\#($0)"}"#.utf8))
        }
        let key = CacheKey.tvLibrary(libraryId: libraryId, filterKey: filter.cacheKeyFragment)
        cacheKeys.append(key)
        ResponseCache.shared.set(
            CatalogResponse(items: items, total: items.count, totalExact: true, hasMore: hasMore), for: key
        )
        let model = TVLibraryGridViewModel(libraryId: libraryId, libraryType: "movies", initialFilter: filter, api: api)
        XCTAssertEqual(model.items.map(\.contentId), ids, "the cached page shows before any request")
        return model
    }

    private func page(_ ids: [String], nextCursor: String? = nil) -> APIv2TestStub.Reply {
        .json(200, Self.pageBody(ids, nextCursor: nextCursor))
    }

    private static func pageBody(_ ids: [String], nextCursor: String? = nil) -> String {
        let items = ids.map { #"{"content_id":"\#($0)","type":"movie","title":"\#($0)"}"# }.joined(separator: ",")
        let page = nextCursor.map { #"{"has_more":true,"next_cursor":"\#($0)"}"# } ?? #"{"has_more":false}"#
        return #"{"items":[\#(items)],"page":\#(page),"total":\#(ids.count),"total_exact":true,"window_cursor":"w"}"#
    }

    func testCachedFirstPageIsRefetchedWhenTheGridOpens() async throws {
        stub.reply(page(["movie:new", "movie:old"]))
        let model = try cachedGrid(["movie:old"], libraryId: 990_101, hasMore: false, api: try await api())

        await model.loadInitial()

        XCTAssertEqual(stub.requestedPaths, ["/api/v2/catalog"])
        XCTAssertNil(stub.requests.first?.query["cursor"], "page 1 is read again")
        XCTAssertEqual(model.items.map(\.contentId), ["movie:new", "movie:old"])
    }

    func testCachedPageStaysUpWhileItIsRefetched() async throws {
        stub.reply(page(["movie:new", "movie:old"]))
        let model = try cachedGrid(["movie:old"], libraryId: 990_104, hasMore: false, api: try await api())
        // A watched or favorite change drops the cached library pages.
        ResponseCache.shared.remove(try XCTUnwrap(cacheKeys.last))
        stub.hold()

        let refresh = Task { await model.loadInitial() }
        try await stub.handler.waitForRequest(where: StubURLProtocol.path("/api/v2/catalog"))

        XCTAssertEqual(model.items.map(\.contentId), ["movie:old"], "the grid is not emptied for the refresh")
        stub.release()
        await refresh.value
        XCTAssertEqual(model.items.map(\.contentId), ["movie:new", "movie:old"])
    }

    func testEmptyRefreshKeepsTheCachedPageUntilItsReasonIsKnown() async throws {
        var filter = CatalogFilterState()
        filter.namePrefix = "Z"
        // The grid asks for a page of 100; the check for whether the library
        // has any titles asks for one, and waits here until the test lets it go.
        let isLibraryCheck: StubURLProtocol.Matcher = { $0.query["limit"] == "1" }
        let libraryCheck = StubURLProtocol.Gate()
        let handler = StubURLProtocol.Handler()
        let otherTitle = Self.pageBody(["movie:other"])
        let noTitles = Self.pageBody([])
        handler.route(isLibraryCheck) { _ in
            await libraryCheck.wait()
            return .json(otherTitle)
        }
        handler.route(StubURLProtocol.any) { _ in .json(noTitles) }
        let model = try cachedGrid(
            ["movie:old"], libraryId: 990_105, hasMore: false, filter: filter,
            api: try await api(session: handler.makeSession())
        )

        let refresh = Task { await model.loadInitial() }
        try await handler.waitForRequest(where: isLibraryCheck)

        XCTAssertEqual(model.items.map(\.contentId), ["movie:old"], "no empty state before its message is settled")
        await libraryCheck.open()
        await refresh.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertEqual(model.emptyReason, .noFilterMatches)
    }

    func testLivePagedListIsLeftAloneWhenTheGridReappears() async throws {
        stub.sequence([page(["movie:a"], nextCursor: "cursor-2"), page(["movie:b"])])
        let model = try cachedGrid(["movie:old"], libraryId: 990_102, hasMore: true, api: try await api())
        await model.loadInitial()
        await model.loadMoreIfNeeded()
        XCTAssertEqual(model.items.map(\.contentId), ["movie:a", "movie:b"])

        // Coming back from a title page runs the grid's appear task again.
        await model.loadInitial()

        XCTAssertEqual(stub.requests.count, 2, "no request once a live page has arrived")
        XCTAssertEqual(model.items.map(\.contentId), ["movie:a", "movie:b"])
    }

    func testFailedRefreshKeepsTheCachedPageAndIsTriedAgain() async throws {
        stub.fail()
        let model = try cachedGrid(["movie:old"], libraryId: 990_103, hasMore: false, api: try await api())

        await model.loadInitial()

        XCTAssertEqual(model.items.map(\.contentId), ["movie:old"])
        XCTAssertNil(model.error, "a cached page stays up without an error")

        stub.reply(page(["movie:new", "movie:old"]))
        await model.loadInitial()

        XCTAssertEqual(model.items.map(\.contentId), ["movie:new", "movie:old"])
    }
}
#endif
