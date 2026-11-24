import Foundation
import XCTest
@testable import Silo

@MainActor
final class LibraryCollectionDetailViewModelTests: XCTestCase {
    private func client(_ handler: StubURLProtocol.Handler) async throws -> (SiloAPI, TokenStore) {
        let name = "LibraryCollectionDetailTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
                               defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "collection-test")
        await tokens.setServerUrl("https://collection.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: handler.makeSession(), tokenStore: tokens)
        return (SiloAPI(http: http, tokenStore: tokens), tokens)
    }

    override func tearDown() {
        ResponseCache.shared.removeAll(withPrefix: CacheKey.catalogCollectionItems("mixed-review"))
        super.tearDown()
    }

    private func load(_ model: LibraryCollectionDetailViewModel, scope: LibraryVideoScope,
                      reset: Bool = true) async {
        await model.load(libraryId: 7, collectionId: "mixed-review", kind: .regular,
                         mediaScope: scope, reset: reset)
    }

    nonisolated private static func page(_ id: String, type: String, cursor: String? = nil) -> StubURLProtocol.Response {
        page([id], type: type, cursor: cursor)
    }

    nonisolated private static func page(_ ids: [String], type: String, cursor: String? = nil) -> StubURLProtocol.Response {
        let paging = cursor.map { #""has_more":true,"next_cursor":"\#($0)""# } ?? #""has_more":false"#
        let itemsJSON = ids.map { #"{"content_id":"\#($0)","type":"\#(type)","title":"\#($0)"}"# }.joined(separator: ",")
        let json = #"{"items":[\#(itemsJSON)],"total":\#(max(ids.count, 2)),"total_exact":true,"window_cursor":"window","page":{\#(paging)}}"#
        return StubURLProtocol.Response(status: 200, headers: ["Content-Type": "application/json"], body: Data(json.utf8))
    }

    func testLateMovieResponseCannotReplaceSeriesRowsOrContinuation() async throws {
        let firstSeriesIds = (1...CatalogGrid.loadMoreLead).map { "show-\($0)" }
        let handler = StubURLProtocol.Handler()
        let oldGate = StubURLProtocol.Gate()
        handler.route(StubURLProtocol.any) { request in
            if request.query["type"] == "movie" {
                await oldGate.wait()
                return Self.page("film", type: "movie", cursor: "movie-next")
            }
            if request.query["cursor"] != nil { return Self.page("show-tail", type: "series") }
            return Self.page(firstSeriesIds, type: "series", cursor: "series-next")
        }
        let (api, tokens) = try await client(handler)
        let model = LibraryCollectionDetailViewModel(api: api, tokens: tokens)
        let old = Task { await load(model, scope: .movie) }
        defer { old.cancel() }
        try await handler.waitForRequest { $0.query["type"] == "movie" }
        await load(model, scope: .series)
        await oldGate.open()
        await old.value
        XCTAssertEqual(model.items.map(\.contentId), firstSeriesIds)
        XCTAssertTrue(model.hasMore)
        await load(model, scope: .series, reset: false)
        XCTAssertEqual(model.items.map(\.contentId), firstSeriesIds + ["show-tail"])
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(handler.requests.last?.query["cursor"], "series-next")
        XCTAssertEqual(handler.requests.last?.query["type"], "series")
        XCTAssertEqual(handler.requests.last?.query["library_id"], "7")
    }

    func testObsoleteCompletionCannotClearReplacementLoadingState() async throws {
        let handler = StubURLProtocol.Handler()
        let oldGate = StubURLProtocol.Gate()
        let newGate = StubURLProtocol.Gate()
        handler.route(StubURLProtocol.any) { request in
            let type = request.query["type"] ?? "movie"
            if type == "movie" { await oldGate.wait() } else { await newGate.wait() }
            return Self.page(type, type: type)
        }
        let (api, tokens) = try await client(handler)
        let model = LibraryCollectionDetailViewModel(api: api, tokens: tokens)
        let old = Task { await load(model, scope: .movie) }
        defer { old.cancel() }
        try await handler.waitForRequest { $0.query["type"] == "movie" }
        let replacement = Task { await load(model, scope: .series) }
        defer { replacement.cancel() }
        try await handler.waitForRequest { $0.query["type"] == "series" }
        await oldGate.open()
        await old.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.isLoading)
        await newGate.open()
        await replacement.value
        XCTAssertFalse(model.isLoading)
        XCTAssertEqual(model.items.map(\.contentId), ["series"])
    }

    func testProfileChangeRejectsCachedRowsAndInFlightResponse() async throws {
        let handler = StubURLProtocol.Handler()
        let gate = StubURLProtocol.Gate()
        handler.expect(StubURLProtocol.any) { _ in Self.page("cached", type: "movie") }
        handler.route(StubURLProtocol.any) { _ in
            await gate.wait()
            return Self.page("late", type: "movie")
        }
        let (api, tokens) = try await client(handler)
        let model = LibraryCollectionDetailViewModel(api: api, tokens: tokens)
        await load(model, scope: .movie)
        XCTAssertEqual(model.items.map(\.contentId), ["cached"])
        await tokens.setProfileId("profile-two")
        let pending = Task { await load(model, scope: .movie) }
        defer { pending.cancel() }
        try await handler.waitForRequest { $0.header("x-profile-id") == "profile-two" }
        XCTAssertTrue(model.items.isEmpty)
        await tokens.setProfileId("profile-three")
        await gate.open()
        await pending.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isLoading)
        XCTAssertNotNil(model.error)
    }

    func testCancellationClearsLoadingAndAllowsRetry() async throws {
        let handler = StubURLProtocol.Handler()
        let gate = StubURLProtocol.Gate()
        handler.expect(StubURLProtocol.any) { _ in
            await gate.wait()
            return Self.page("cancelled", type: "series")
        }
        handler.route(StubURLProtocol.any) { _ in Self.page("retry", type: "series") }
        let (api, tokens) = try await client(handler)
        let model = LibraryCollectionDetailViewModel(api: api, tokens: tokens)
        let pending = Task { await load(model, scope: .series) }
        try await handler.waitForRequest { _ in true }
        pending.cancel()
        await pending.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isLoading)
        XCTAssertNil(model.error)
        await load(model, scope: .series)
        XCTAssertEqual(model.items.map(\.contentId), ["retry"])
    }

    func testFailedRefreshKeepsEveryPreviouslyLoadedPage() async throws {
        let firstPageIds = (1...CatalogGrid.loadMoreLead).map { "first-\($0)" }
        let handler = StubURLProtocol.Handler()
        handler.expect(StubURLProtocol.any) { _ in
            Self.page(firstPageIds, type: "movie", cursor: "second-page")
        }
        handler.expect(StubURLProtocol.any) { _ in Self.page("second", type: "movie") }
        handler.route(StubURLProtocol.any) { _ in throw URLError(.networkConnectionLost) }
        let (api, tokens) = try await client(handler)
        let model = LibraryCollectionDetailViewModel(api: api, tokens: tokens)
        await load(model, scope: .movie)
        await load(model, scope: .movie, reset: false)
        XCTAssertEqual(model.items.map(\.contentId), firstPageIds + ["second"])

        // Cache invalidation must not turn a failed refresh into an empty grid.
        ResponseCache.shared.removeAll(withPrefix: CacheKey.catalogCollectionItems("mixed-review"))
        await load(model, scope: .movie)
        XCTAssertEqual(model.items.map(\.contentId), firstPageIds + ["second"])
        XCTAssertNotNil(model.refreshError)
        XCTAssertFalse(model.isLoading)
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(handler.requests.count, 3)
    }

    func testPaginationDeduplicatesAndAccumulatesAcrossSparsePages() async throws {
        let firstPageIds = (1...CatalogGrid.loadMoreLead).map { "item-\($0)" }
        let pageThreeIds = (1...CatalogGrid.loadMoreLead).map { "next-\($0)" }
        let handler = StubURLProtocol.Handler()
        handler.expect(StubURLProtocol.any) { _ in
            Self.page(firstPageIds, type: "movie", cursor: "c2")
        }
        // Page 2 repeats already-loaded items only; pagination must keep reading.
        handler.expect(StubURLProtocol.any) { request in
            XCTAssertEqual(request.query["cursor"], "c2")
            return Self.page(["item-1", "item-2"], type: "movie", cursor: "c3")
        }
        handler.expect(StubURLProtocol.any) { request in
            XCTAssertEqual(request.query["cursor"], "c3")
            return Self.page(["item-3"] + pageThreeIds, type: "movie", cursor: "c4")
        }
        let (api, tokens) = try await client(handler)
        let model = LibraryCollectionDetailViewModel(api: api, tokens: tokens)
        await load(model, scope: .movie)
        XCTAssertEqual(model.items.map(\.contentId), firstPageIds)
        XCTAssertTrue(model.hasMore)

        await load(model, scope: .movie, reset: false)
        XCTAssertEqual(model.items.map(\.contentId), firstPageIds + pageThreeIds)
        XCTAssertTrue(model.hasMore)
        XCTAssertNil(model.paginationError)
    }

    func testFailedPaginationSurfacesRetryableErrorWithoutResettingLoadedPages() async throws {
        let firstPageIds = (1...CatalogGrid.loadMoreLead).map { "item-\($0)" }
        let handler = StubURLProtocol.Handler()
        handler.expect(StubURLProtocol.any) { _ in
            Self.page(firstPageIds, type: "movie", cursor: "c2")
        }
        handler.expect(StubURLProtocol.any) { request in
            XCTAssertEqual(request.query["cursor"], "c2")
            throw URLError(.networkConnectionLost)
        }
        handler.expect(StubURLProtocol.any) { request in
            XCTAssertEqual(request.query["cursor"], "c2")
            return Self.page("page-two-item", type: "movie")
        }
        let (api, tokens) = try await client(handler)
        let model = LibraryCollectionDetailViewModel(api: api, tokens: tokens)
        await load(model, scope: .movie)
        XCTAssertEqual(model.items.map(\.contentId), firstPageIds)
        XCTAssertTrue(model.hasMore)

        await load(model, scope: .movie, reset: false)
        XCTAssertEqual(model.items.map(\.contentId), firstPageIds)
        XCTAssertNotNil(model.paginationError)
        XCTAssertNil(model.refreshError)
        XCTAssertTrue(model.hasMore)

        // Retrying pagination reuses the same continuation without resetting page 1.
        await load(model, scope: .movie, reset: false)
        XCTAssertEqual(model.items.map(\.contentId), firstPageIds + ["page-two-item"])
        XCTAssertNil(model.paginationError)
        XCTAssertFalse(model.hasMore)
    }

    func testPartialFirstPageIsPreservedWhenSecondPageFailsDuringAccumulation() async throws {
        let handler = StubURLProtocol.Handler()
        handler.expect(StubURLProtocol.any) { _ in
            Self.page("only-one", type: "movie", cursor: "c2")
        }
        handler.expect(StubURLProtocol.any) { request in
            XCTAssertEqual(request.query["cursor"], "c2")
            throw URLError(.networkConnectionLost)
        }
        handler.expect(StubURLProtocol.any) { request in
            XCTAssertEqual(request.query["cursor"], "c2")
            return Self.page("second-one", type: "movie")
        }
        let (api, tokens) = try await client(handler)
        let model = LibraryCollectionDetailViewModel(api: api, tokens: tokens)
        await load(model, scope: .movie)
        XCTAssertEqual(model.items.map(\.contentId), ["only-one"])
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.paginationError)
        XCTAssertTrue(model.hasMore)

        await load(model, scope: .movie, reset: false)
        XCTAssertEqual(model.items.map(\.contentId), ["only-one", "second-one"])
        XCTAssertNil(model.paginationError)
        XCTAssertFalse(model.hasMore)
    }

    func testEmptyRegularCollectionRefreshKeepsLoadedStateAndSurfacesInlineRefreshError() async throws {
        let handler = StubURLProtocol.Handler()
        handler.expect(StubURLProtocol.any) { _ in Self.page([], type: "movie") }
        handler.expect(StubURLProtocol.any) { _ in throw URLError(.networkConnectionLost) }
        let (api, tokens) = try await client(handler)
        let model = LibraryCollectionDetailViewModel(api: api, tokens: tokens)
        XCTAssertFalse(model.hasLoadedOnce)

        await load(model, scope: .movie)
        XCTAssertTrue(model.hasLoadedOnce)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.error)

        let seqBeforeRefresh = model.pageSequence
        await load(model, scope: .movie, reset: true)
        XCTAssertTrue(model.hasLoadedOnce)
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.refreshError)
        XCTAssertEqual(model.pageSequence, seqBeforeRefresh)
    }

    func testPaginationBudgetPublishesValidatedCardsAndAllowsContinuingFromCursor() async throws {
        let handler = StubURLProtocol.Handler()
        // Page 1 returns one card; pages 2..5 repeat that card under distinct cursors,
        // exhausting the 5-page per-batch budget; page 6 delivers a new card.
        handler.expect(StubURLProtocol.any) { _ in Self.page("only-one", type: "movie", cursor: "c2") }
        handler.expect(StubURLProtocol.any) { _ in Self.page("only-one", type: "movie", cursor: "c3") }
        handler.expect(StubURLProtocol.any) { _ in Self.page("only-one", type: "movie", cursor: "c4") }
        handler.expect(StubURLProtocol.any) { _ in Self.page("only-one", type: "movie", cursor: "c5") }
        handler.expect(StubURLProtocol.any) { _ in Self.page("only-one", type: "movie", cursor: "c6") }
        handler.expect(StubURLProtocol.any) { request in
            XCTAssertEqual(request.query["cursor"], "c6")
            return Self.page("later-card", type: "movie")
        }
        let (api, tokens) = try await client(handler)
        let model = LibraryCollectionDetailViewModel(api: api, tokens: tokens)

        await load(model, scope: .movie)
        XCTAssertEqual(handler.requests.count, 5)
        XCTAssertEqual(model.items.map(\.contentId), ["only-one"])
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.paginationError)
        XCTAssertTrue(model.hasMore)

        await load(model, scope: .movie, reset: false)
        XCTAssertEqual(model.items.map(\.contentId), ["only-one", "later-card"])
        XCTAssertNil(model.paginationError)
        XCTAssertFalse(model.hasMore)
    }

    func testProfileSwitchPreservesNewProfileFirstPageWhenContinuationFails() async throws {
        let handler = StubURLProtocol.Handler()
        handler.expect(StubURLProtocol.any) { _ in Self.page("profile-one-item", type: "movie") }
        handler.expect(StubURLProtocol.any) { _ in Self.page("profile-two-first", type: "movie", cursor: "p2-next") }
        handler.expect(StubURLProtocol.any) { _ in throw URLError(.networkConnectionLost) }
        let (api, tokens) = try await client(handler)
        let model = LibraryCollectionDetailViewModel(api: api, tokens: tokens)

        await load(model, scope: .movie)
        XCTAssertEqual(model.items.map(\.contentId), ["profile-one-item"])

        await tokens.setProfileId("profile-two")
        await load(model, scope: .movie)
        XCTAssertEqual(model.items.map(\.contentId), ["profile-two-first"])
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.paginationError)
        XCTAssertTrue(model.hasMore)
    }

    func testColdLoadPublishesFirstPageCardsBeforeSecondPageCompletes() async throws {
        let handler = StubURLProtocol.Handler()
        let secondPageStarted = expectation(description: "second page request started")
        let releaseSecondPage = DispatchSemaphore(value: 0)
        defer { releaseSecondPage.signal() }

        handler.expect(StubURLProtocol.any) { _ in Self.page("page-one-card", type: "movie", cursor: "p2") }
        handler.expect(StubURLProtocol.any) { _ in
            secondPageStarted.fulfill()
            _ = releaseSecondPage.wait(timeout: .now() + 5)
            return Self.page("page-two-card", type: "movie")
        }
        let (api, tokens) = try await client(handler)
        let model = LibraryCollectionDetailViewModel(api: api, tokens: tokens)

        let loadTask = Task {
            await self.load(model, scope: .movie)
        }
        await fulfillment(of: [secondPageStarted], timeout: 5.0)

        // Page 1 must already be visible on a cold load while page 2 is still in flight.
        XCTAssertEqual(model.items.map(\.contentId), ["page-one-card"])
        XCTAssertTrue(model.hasLoadedOnce)
        XCTAssertTrue(model.hasMore)

        releaseSecondPage.signal()
        await loadTask.value

        XCTAssertEqual(model.items.map(\.contentId), ["page-one-card", "page-two-card"])
        XCTAssertFalse(model.hasMore)
        XCTAssertNil(model.error)
    }
}
