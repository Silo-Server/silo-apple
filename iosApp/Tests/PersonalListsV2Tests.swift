import Foundation
import XCTest
@testable import Silo

final class PersonalListsV2Tests: XCTestCase {
    // Exact server fixtures from contracts/api/v2/fixtures at b3da15b8.
    private let favoritesFixture = #"""
{
  "items": [
    {
      "content_id": "movie:c",
      "type": "movie",
      "title": "Title movie:c",
      "genres": [],
      "keywords": [],
      "status": "matched"
    }
  ],
  "page": {
    "next_cursor": "eyJ2IjoxLCJwIjp7ImEiOiIyMDI2LTAxLTAyVDAzOjA0OjA1WiIsIm0iOiJtb3ZpZTpjIn19.hRfCrVJ0-ojaIuwjyGYST1kQNiJig-Y15YAyNu8rTDA",
    "has_more": true
  }
}
"""#
    private let watchlistFixture = #"""
{
  "items": [
    {
      "content_id": "series:c",
      "type": "series",
      "title": "Title series:c",
      "genres": [],
      "keywords": [],
      "status": "matched"
    }
  ],
  "page": {
    "next_cursor": "eyJ2IjoxLCJwIjp7ImEiOiIyMDI2LTAxLTAyVDAzOjA0OjA1WiIsIm0iOiJzZXJpZXM6YyJ9fQ.bwg6G38bVfFeYdMdMKPldAxvN7eFQnln1YQMlInOGYQ",
    "has_more": true
  }
}
"""#

    private let terminal = #"{"items":[],"page":{"has_more":false}}"#

    private func client(updateRequired: Bool = false) async throws -> (APIv2Client, TokenStore) {
        let name = "PersonalListsV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name); CatalogProtocol.reset() }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://personal.example")
        await tokens.setProfileId("profile-one")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { updateRequired }), tokens)
    }

    @MainActor
    func testViewModelContinuesEmptyAndDuplicatePages() async throws {
        ResponseCache.shared.clearAll()
        let (api, tokens) = try await client()
        let model = PersonalListViewModel(kind: .favorites, api: api, tokenStore: tokens)
        CatalogProtocol.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"one"}}"#)
        await model.reload()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.hasMore, "Load More must remain available on an empty page")
        CatalogProtocol.reply(200, #"{"items":[{"content_id":"same","title":"Same","type":"movie"},{"content_id":"same","title":"Same","type":"movie"}],"page":{"has_more":true,"next_cursor":"two"}}"#)
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.contentId), ["same"])
        XCTAssertTrue(model.hasMore)
        CatalogProtocol.reply(200, terminal)
        await model.loadMore()
        XCTAssertEqual(model.items.count, 1)
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(CatalogProtocol.requests().count, 3)
    }

    @MainActor
    func testViewModelRetainsCardsAndRequiresExplicitReloadAfterFailure() async throws {
        ResponseCache.shared.clearAll()
        let (api, tokens) = try await client()
        let model = PersonalListViewModel(kind: .watchlist, api: api, tokenStore: tokens)
        CatalogProtocol.reply(200, watchlistFixture)
        await model.reload()
        CatalogProtocol.reply(400, #"{"type":"https://siloserver.org/docs/api/v2/problems/invalid_cursor","title":"Expired","status":400,"detail":"Reload list"}"#)
        await model.loadMore()
        XCTAssertEqual(model.items.map(\.contentId), ["series:c"])
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.hasMore)
        await model.loadMore()
        XCTAssertEqual(CatalogProtocol.requests().count, 2)
        CatalogProtocol.reply(200, terminal)
        await model.reload()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testViewModelCacheContainsCardsButCannotResumeAfterFailedRefresh() async throws {
        ResponseCache.shared.clearAll()
        let (api, tokens) = try await client()
        let first = PersonalListViewModel(kind: .favorites, api: api, tokenStore: tokens)
        CatalogProtocol.reply(200, favoritesFixture)
        await first.reload()
        let restored = PersonalListViewModel(kind: .favorites, api: api, tokenStore: tokens)
        CatalogProtocol.reply(503, #"{"type":"about:blank","title":"Unavailable","status":503,"detail":"Try later"}"#)
        await restored.reload()
        XCTAssertEqual(restored.items.map(\.contentId), ["movie:c"])
        XCTAssertFalse(restored.hasMore)
        XCTAssertNotNil(restored.error)
        await restored.loadMore()
        XCTAssertEqual(CatalogProtocol.requests().count, 2)
        await tokens.setProfileId("another-profile")
        await restored.reload()
        XCTAssertTrue(restored.items.isEmpty, "A different viewer must not hydrate cached cards")
    }

    @MainActor
    func testViewModelClearsCardsWhenViewerChangesDuringPaging() async throws {
        ResponseCache.shared.clearAll()
        let (api, tokens) = try await client()
        let model = PersonalListViewModel(kind: .favorites, api: api, tokenStore: tokens)
        CatalogProtocol.reply(200, favoritesFixture)
        await model.reload()
        let captured = expectation(description: "page captured")
        CatalogProtocol.hold { captured.fulfill() }
        let request = Task { await model.loadMore() }
        await fulfillment(of: [captured], timeout: 2)
        await tokens.setProfileId("new-profile")
        CatalogProtocol.release()
        await request.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.hasMore)
        XCTAssertNotNil(model.error)
        CatalogProtocol.reply(200, terminal)
        await model.reload()
        XCTAssertNil(model.error)
    }

    @MainActor
    func testViewModelCancellationCannotPublishHeldResponse() async throws {
        ResponseCache.shared.clearAll()
        let (api, tokens) = try await client()
        let model = PersonalListViewModel(kind: .favorites, api: api, tokenStore: tokens)
        CatalogProtocol.reply(200, favoritesFixture)
        let captured = expectation(description: "page captured")
        CatalogProtocol.hold { captured.fulfill() }
        let request = Task { await model.reload() }
        await fulfillment(of: [captured], timeout: 2)
        model.cancel()
        CatalogProtocol.release()
        await request.value
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(model.isLoading)
        CatalogProtocol.reply(200, terminal)
        await model.reload()
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertNil(model.error)
    }

    func testActualServerFixturesDecodeWithoutCatalogTotalsOrWindow() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        for (fixture, id) in [(favoritesFixture, "movie:c"), (watchlistFixture, "series:c")] {
            let page = try decoder.decode(APIv2PersonalListPage.self, from: Data(fixture.utf8))
            XCTAssertEqual(page.items.first?.contentId, id)
            XCTAssertTrue(page.page.hasMore)
            XCTAssertNotNil(page.page.nextCursor)
        }
        for malformed in [#"{"items":[]}"#, #"{"page":{"has_more":false}}"#,
                          #"{"items":[],"page":{}}"#, #"{"items":[{"item_id":"movie"}],"page":{"has_more":false}}"#] {
            XCTAssertThrowsError(try decoder.decode(APIv2PersonalListPage.self, from: Data(malformed.utf8)))
        }
    }

    func testBothKindsPinPathLimitArtworkAndOpaqueCursor() async throws {
        let (api, _) = try await client()
        for (kind, fixture) in [(APIv2PersonalListKind.favorites, favoritesFixture), (.watchlist, watchlistFixture)] {
            CatalogProtocol.reset()
            CatalogProtocol.reply(200, fixture)
            let first = try await api.personalList(kind: kind, limit: 200, imageSize: "small")
            let continuation = try XCTUnwrap(first.continuation)
            XCTAssertEqual(continuation.kind, kind)
            CatalogProtocol.reply(200, terminal)
            let last = try await api.nextPersonalListPage(continuation)
            XCTAssertNil(last.continuation)
            let calls = CatalogProtocol.requests()
            XCTAssertEqual(calls.count, 2)
            for (index, call) in calls.enumerated() {
                XCTAssertEqual(call.0.httpMethod, "GET")
                XCTAssertEqual(call.0.url?.path, "/api/v2/\(kind.rawValue)")
                XCTAssertEqual(call.0.value(forHTTPHeaderField: "X-Profile-Id"), "profile-one")
                let items = URLComponents(url: call.0.url!, resolvingAgainstBaseURL: false)!.queryItems!
                let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value!) })
                XCTAssertEqual(query["limit"], "200")
                XCTAssertEqual(query["image_size"], "small")
                XCTAssertNil(query["offset"])
                XCTAssertNil(query["window_cursor"])
                XCTAssertEqual(query["cursor"], index == 0 ? nil : continuation.cursor)
            }
        }
    }

    func testEmptyAndDuplicatePagesRetainContinuationOnePageAtATime() async throws {
        let (api, _) = try await client()
        CatalogProtocol.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"empty-next"}}"#)
        let empty = try await api.personalList(kind: .watchlist)
        XCTAssertTrue(empty.value.items.isEmpty)
        XCTAssertNotNil(empty.continuation)
        XCTAssertEqual(CatalogProtocol.requests().count, 1)
        let card = #"{"content_id":"same","title":"Same","type":"movie"}"#
        CatalogProtocol.reply(200, "{\"items\":[\(card),\(card)],\"page\":{\"has_more\":true,\"next_cursor\":\"duplicate-next\"}}")
        let duplicates = try await api.nextPersonalListPage(XCTUnwrap(empty.continuation))
        XCTAssertEqual(duplicates.value.items.count, 2)
        XCTAssertEqual(duplicates.continuation?.cursor, "duplicate-next")
        XCTAssertEqual(CatalogProtocol.requests().count, 2)
    }

    func testMissingRepeatedAndContradictoryCursorFail() async throws {
        let (api, _) = try await client()
        for page in [#"{"has_more":true}"#, #"{"has_more":true,"next_cursor":""}"#,
                     #"{"has_more":false,"next_cursor":"next"}"#] {
            CatalogProtocol.reply(200, "{\"items\":[],\"page\":\(page)}")
            do { _ = try await api.personalList(kind: .favorites); XCTFail("Expected malformed cursor") }
            catch APIv2Error.invalidPersonalListContinuation { }
        }
        CatalogProtocol.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"same"}}"#)
        let first = try await api.personalList(kind: .favorites)
        do { _ = try await api.nextPersonalListPage(XCTUnwrap(first.continuation)); XCTFail("Expected repeated cursor") }
        catch APIv2Error.invalidPersonalListContinuation { }
        XCTAssertEqual(CatalogProtocol.requests().count, 5)
    }

    func testContinuationRejectsChangedProfileOrAccountBeforeDispatch() async throws {
        for changeAccount in [false, true] {
            CatalogProtocol.reset()
            let (api, tokens) = try await client()
            CatalogProtocol.reply(200, favoritesFixture)
            let first = try await api.personalList(kind: .favorites)
            if changeAccount { await tokens.switchActiveServer(serverId: "other") }
            else { await tokens.setProfileId("other") }
            do { _ = try await api.nextPersonalListPage(XCTUnwrap(first.continuation)); XCTFail("Expected authority rejection") }
            catch HTTPError.requestIdentityChanged { }
            XCTAssertEqual(CatalogProtocol.requests().count, 1)
        }
    }

    func testChangedProfileRejectsInFlightPageBeforePublication() async throws {
        let (api, tokens) = try await client()
        CatalogProtocol.reply(200, favoritesFixture)
        let captured = expectation(description: "personal request captured")
        CatalogProtocol.hold { captured.fulfill() }
        let request = Task { try await api.personalList(kind: .favorites) }
        await fulfillment(of: [captured], timeout: 2)
        await tokens.setProfileId("other")
        CatalogProtocol.release()
        do { _ = try await request.value; XCTFail("Expected authority rejection") }
        catch HTTPError.requestIdentityChanged { }
        XCTAssertEqual(CatalogProtocol.requests().count, 1)
    }

    func testExpiredCursorDoesNotRetryOrRestart() async throws {
        let (api, _) = try await client()
        CatalogProtocol.reply(200, watchlistFixture)
        let first = try await api.personalList(kind: .watchlist)
        CatalogProtocol.reply(400, #"{"type":"https://siloserver.org/docs/api/v2/problems/invalid_cursor","title":"Expired","status":400,"detail":"Reload list"}"#)
        do { _ = try await api.nextPersonalListPage(XCTUnwrap(first.continuation)); XCTFail("Expected expired cursor") }
        catch APIv2Error.problem(let problem) { XCTAssertTrue(problem.type.hasSuffix("/invalid_cursor")) }
        XCTAssertEqual(CatalogProtocol.requests().count, 2)
    }

    func testGateAndInvalidLimitsPreventDispatch() async throws {
        let (api, _) = try await client()
        for limit in [0, 201] {
            do { _ = try await api.personalList(kind: .favorites, limit: limit); XCTFail("Expected invalid limit") }
            catch APIv2Error.invalidPersonalListQuery { }
        }
        let (gated, _) = try await client(updateRequired: true)
        do { _ = try await gated.personalList(kind: .watchlist); XCTFail("Expected gate") }
        catch APIv2Error.serverUpdateRequired { }
        XCTAssertTrue(CatalogProtocol.requests().isEmpty)
    }
}
