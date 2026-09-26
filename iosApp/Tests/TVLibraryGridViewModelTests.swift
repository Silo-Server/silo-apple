#if os(tvOS)
import Foundation
import XCTest
@testable import Silo

/// The Apple TV library grid supersedes an in-flight fetch whenever the
/// letter, sort or filter changes. The superseded fetch must leave the
/// loading flags to the fetch that replaced it: clearing them early shows
/// "No titles match" over an empty grid, or reopens load-more during a cached
/// refresh and sends a second page-1 request.
@MainActor
final class TVLibraryGridViewModelTests: XCTestCase {
    private enum Page {
        static let all = #"{"items":[{"content_id":"movie:heat","type":"movie","title":"Heat"}],"page":{"has_more":true,"next_cursor":"all-2"},"total":2,"total_exact":true,"window_cursor":"w"}"#
        static let liveB = #"{"items":[{"content_id":"movie:blade-runner","type":"movie","title":"Blade Runner"}],"page":{"has_more":true,"next_cursor":"b-2"},"total":2,"total_exact":true,"window_cursor":"w"}"#
        static let cachedB = #"{"items":[{"content_id":"movie:cached-b","type":"movie","title":"Cached B"}],"page":{"has_more":true,"next_cursor":"cached-2"},"total":2,"total_exact":true,"window_cursor":"w"}"#
        static let unavailable = #"{"type":"https://siloserver.org/docs/api/v2/problems/service_unavailable","title":"Service unavailable","status":503,"detail":"Down","instance":"urn:silo:request:1"}"#
    }

    /// Replies run off the main actor, so the count is lock-protected.
    private final class ReplyCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func next() -> Int {
            lock.withLock {
                value += 1
                return value
            }
        }
    }

    private let libraryId = Int.random(in: 900_000...999_999)

    // MARK: - Tests

    func testSupersededFetchKeepsLoadingWhileTheNewPageIsInFlight() async throws {
        let handler = StubURLProtocol.Handler()
        let (gateAll, gateB) = stubCatalog(handler)
        let vm = try await makeViewModel(handler)

        let first = Task { await vm.loadInitial() }
        try await handler.waitForRequest(where: Self.firstPage(prefix: nil))
        let jump = Task { await vm.jumpToPrefix("B") }
        try await handler.waitForRequest(where: Self.firstPage(prefix: "B"))

        await gateAll.open()
        await first.value
        XCTAssertTrue(vm.isLoading, "the B page is still loading, so the grid must not show its empty state")
        XCTAssertTrue(vm.items.isEmpty, "the superseded page is discarded")
        XCTAssertNil(vm.error)

        await gateB.open()
        await jump.value
        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertEqual(vm.items.map(\.contentId), ["movie:blade-runner"])
        XCTAssertEqual(handler.requests.filter(Self.firstPage(prefix: "B")).count, 1)
        XCTAssertTrue(handler.unmatched.isEmpty, "\(handler.unmatched.map(\.path))")
    }

    func testSupersededFetchDoesNotReopenLoadMoreDuringACachedRefresh() async throws {
        let handler = StubURLProtocol.Handler()
        let (gateAll, gateB) = stubCatalog(handler)
        let vm = try await makeViewModel(handler)
        // Seeded after init, which hydrates only the unprefixed key.
        try seedCachedPage(Page.cachedB, prefix: "B")

        let first = Task { await vm.loadInitial() }
        try await handler.waitForRequest(where: Self.firstPage(prefix: nil))
        let jump = Task { await vm.jumpToPrefix("B") }
        try await handler.waitForRequest(where: Self.firstPage(prefix: "B"))
        XCTAssertTrue(vm.isRefreshing, "precondition: the cached B page is showing while it refreshes")
        XCTAssertEqual(vm.items.map(\.contentId), ["movie:cached-b"], "precondition: the cached B page hydrated")

        await gateAll.open()
        await first.value
        XCTAssertTrue(vm.isRefreshing, "the B refresh is still in flight")

        await vm.loadMoreIfNeeded()
        XCTAssertEqual(
            handler.requests.filter(Self.firstPage(prefix: "B")).count, 1,
            "load-more must wait for the in-flight refresh instead of requesting page 1 again"
        )

        await gateB.open()
        await jump.value
        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertTrue(vm.hasMore)
        XCTAssertEqual(vm.items.map(\.contentId), ["movie:blade-runner"])
        XCTAssertTrue(handler.unmatched.isEmpty, "\(handler.unmatched.map(\.path))")
    }

    func testFailedCurrentFetchClearsLoading() async throws {
        let handler = StubURLProtocol.Handler()
        handler.route(Self.firstPage(prefix: nil)) { _ in
            .json(Page.unavailable, status: 503, headers: ["Content-Type": "application/problem+json"])
        }
        let vm = try await makeViewModel(handler)

        await vm.loadInitial()

        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(vm.isRefreshing)
        XCTAssertNotNil(vm.error)
        XCTAssertEqual(handler.requests.count, 1)
        XCTAssertTrue(handler.unmatched.isEmpty, "\(handler.unmatched.map(\.path))")
    }

    // MARK: - Harness

    /// Page 1 of the whole library waits on the first gate. The first page-1
    /// request for "B" waits on the second gate; later ones reply at once.
    /// Both gates open at teardown so a failed assertion never leaves a reply
    /// suspended.
    private func stubCatalog(
        _ handler: StubURLProtocol.Handler
    ) -> (all: StubURLProtocol.Gate, b: StubURLProtocol.Gate) {
        let gateAll = StubURLProtocol.Gate()
        let gateB = StubURLProtocol.Gate()
        addTeardownBlock {
            await gateAll.open()
            await gateB.open()
        }
        handler.route(Self.firstPage(prefix: nil)) { _ in
            await gateAll.wait()
            return .json(Page.all)
        }
        let bReplies = ReplyCounter()
        handler.route(Self.firstPage(prefix: "B")) { _ in
            if bReplies.next() == 1 {
                await gateB.wait()
            }
            return .json(Page.liveB)
        }
        return (gateAll, gateB)
    }

    private static func firstPage(prefix: String?) -> StubURLProtocol.Matcher {
        { request in
            request.method == "GET"
                && request.path == "/api/v2/catalog"
                && request.query["name_prefix"] == prefix
                && request.query["cursor"] == nil
        }
    }

    private func makeViewModel(_ handler: StubURLProtocol.Handler) async throws -> TVLibraryGridViewModel {
        let name = "TVLibraryGridViewModelTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "tv-library-grid-test")
        await tokens.setServerUrl("https://catalog.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: handler.makeSession(), tokenStore: tokens)

        let libraryId = self.libraryId
        addTeardownBlock { @MainActor in
            ResponseCache.shared.removeAll(withPrefix: "tvlibrary:v2:\(libraryId):")
        }
        return TVLibraryGridViewModel(
            libraryId: libraryId,
            libraryType: "movie",
            api: SiloAPI(http: http, tokenStore: tokens)
        )
    }

    private func seedCachedPage(_ body: String, prefix: String) throws {
        var filter = CatalogFilterState.none
        filter.namePrefix = prefix
        let page = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogPage.self, from: Data(body.utf8))
        ResponseCache.shared.set(
            CatalogResponse(catalogPage: page),
            for: CacheKey.tvLibrary(libraryId: libraryId, filterKey: filter.cacheKeyFragment)
        )
    }
}
#endif
