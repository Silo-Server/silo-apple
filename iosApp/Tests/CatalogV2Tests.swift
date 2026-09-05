import Foundation
import XCTest
@testable import Silo

final class CatalogV2Tests: XCTestCase {
    private let terminal = #"{"items":[],"page":{"has_more":false},"total":10000,"total_exact":false,"window_cursor":"window"}"#

    private func client() async throws -> (APIv2Client, TokenStore) {
        let name = "CatalogV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name); CatalogProtocol.reset() }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://catalog.example")
        await tokens.setProfileId("profile-one")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CatalogProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: configuration), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens)
    }

    @MainActor
    func testSearchPreservesResultsAndRequiresReloadAfterCursorFailure() async throws {
        let (api, _) = try await client()
        let model = SearchViewModel(api: api)
        model.query = "example"
        CatalogProtocol.reply(200, #"{"items":[{"content_id":"one","type":"movie","title":"One"}],"page":{"has_more":true,"next_cursor":"next"},"total":10000,"total_exact":false,"window_cursor":"w","search_diagnostics":{"provider":"search","mode":"semantic","semantic_used":true,"result_window_limit":250}}"#)
        await model.performSearch()
        XCTAssertEqual(model.results.count, 1)
        XCTAssertEqual(model.countLabel, "About 10000 results")
        XCTAssertEqual(model.resultWindowLimit, 250)
        CatalogProtocol.reply(400, #"{"type":"about:blank","title":"Expired","status":400,"detail":"Reload the search","code":"invalid_cursor"}"#)
        await model.loadMore()
        XCTAssertEqual(model.results.count, 1)
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.hasMore)
        let count = CatalogProtocol.requests().count
        await model.loadMore()
        XCTAssertEqual(CatalogProtocol.requests().count, count)
        CatalogProtocol.reply(200, terminal)
        await model.performSearch(reset: true)
        XCTAssertNil(model.error)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertEqual(CatalogProtocol.requests().count, count + 2)
    }

    @MainActor
    func testSearchCapabilityDenialPreventsCatalogDispatch() async throws {
        let (api, _) = try await client()
        CatalogProtocol.denySearch()
        let model = SearchViewModel(api: api)
        model.query = "example"
        await model.performSearch()
        XCTAssertNotNil(model.error)
        XCTAssertFalse(model.hasMore)
        XCTAssertEqual(CatalogProtocol.requests().map { $0.0.url!.path }, ["/api/v2/catalog/search/capabilities"])
    }

    func testStrictPageRejectsLegacyAndMalformedEnvelopes() throws {
        for body in [
            #"{"items":[],"has_more":false,"total":0,"total_exact":true,"snapshot":"old"}"#,
            #"{"page":{"has_more":false},"total":0,"total_exact":true,"window_cursor":"w"}"#,
            #"{"items":[],"page":{},"total":0,"total_exact":true,"window_cursor":"w"}"#,
            #"{"items":[{"collection_id":"c","media_item_id":"m"}],"page":{"has_more":false},"total":1,"total_exact":true,"window_cursor":"w"}"#,
        ] {
            XCTAssertThrowsError(try HTTPClient.makeJSONDecoder().decode(APIv2CatalogPage.self, from: Data(body.utf8)))
        }
    }

    func testGETSignedSortAndStructuredGroupsHaveNoLegacyPagination() throws {
        var query = APIv2CatalogQuery()
        query.libraryId = "opaque-library"
        query.sort = "year"
        query.order = "desc"
        query.skipTotal = true
        query.groups = [.init(match: "any", rules: [
            .init(field: "year", op: "between", value: .numbers([1990, 1999])),
            .init(field: "genre", op: "contains", value: .string("Science Fiction")),
        ])]
        let parameters = try query.getParameters()
        XCTAssertEqual(parameters["sort"], "-year")
        XCTAssertEqual(parameters["library_id"], "opaque-library")
        XCTAssertEqual(parameters["skip_total"], "true")
        for key in ["offset", "snapshot_at", "order", "include_total"] { XCTAssertNil(parameters[key]) }
        XCTAssertFalse(parameters.keys.contains { $0.hasPrefix("groups[") })
        let data = Data(try XCTUnwrap(parameters["groups"]).utf8)
        let groups = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let rules = try XCTUnwrap(groups.first?["rules"] as? [[String: Any]])
        XCTAssertEqual(rules[0]["value"] as? [Int], [1990, 1999])
        XCTAssertEqual(rules[1]["value"] as? String, "Science Fiction")
        XCTAssertNil(try APIv2CatalogQuery().getParameters()["sort"], "No override preserves source order")
    }

    func testPOSTBodyUsesTypedValuesAndCursorWhileRetainingOperation() async throws {
        CatalogProtocol.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"opaque"},"total":42,"total_exact":true,"window_cursor":"w"}"#)
        let (api, _) = try await client()
        var query = APIv2CatalogQuery()
        query.sort = "year"
        query.order = "desc"
        query.imageSize = "small"
        query.groups = [.init(match: "all", rules: [.init(field: "watched", op: "is", value: .bool(true))])]
        let first = try await api.catalogPage(query: query, operation: .query)
        CatalogProtocol.reply(200, terminal)
        _ = try await api.nextCatalogPage(XCTUnwrap(first.continuation))
        let calls = CatalogProtocol.requests()
        XCTAssertEqual(calls.count, 2)
        for call in calls {
            XCTAssertEqual(call.0.httpMethod, "POST")
            XCTAssertEqual(call.0.url?.path, "/api/v2/catalog/query")
            XCTAssertEqual(call.0.value(forHTTPHeaderField: "X-Profile-Id"), "profile-one")
            let parameters = URLComponents(url: call.0.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(parameters?.first { $0.name == "image_size" }?.value, "small")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(call.1)) as? [String: Any])
            XCTAssertEqual(body["sort"] as? String, "year")
            XCTAssertEqual(body["order"] as? String, "desc")
            XCTAssertNil(body["image_size"])
        }
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(calls[1].1)) as? [String: Any])
        XCTAssertEqual(body["cursor"] as? String, "opaque")
        let groups = try XCTUnwrap(body["groups"] as? [[String: Any]])
        let rules = try XCTUnwrap(groups[0]["rules"] as? [[String: Any]])
        XCTAssertEqual(rules[0]["value"] as? Bool, true)
    }

    func testGETContinuationPinsScopeAndRejectsProfileChangeBeforeDispatch() async throws {
        CatalogProtocol.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"next"},"total":2,"total_exact":true,"window_cursor":"w"}"#)
        let (api, tokens) = try await client()
        var query = APIv2CatalogQuery()
        query.source = "library_collection"
        query.collectionId = "c1"
        query.limit = 40
        let first = try await api.catalogPage(query: query)
        let continuation = try XCTUnwrap(first.continuation)
        XCTAssertEqual(continuation.query, query)
        await tokens.setProfileId("profile-two")
        do {
            _ = try await api.nextCatalogPage(continuation)
            XCTFail("Expected captured identity rejection")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertEqual(CatalogProtocol.requests().count, 1)
    }

    func testGETCursorDispatchRetainsScopeAndOmittedSort() async throws {
        CatalogProtocol.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"opaque-next"},"total":2,"total_exact":true,"window_cursor":"w"}"#)
        let (api, _) = try await client()
        var query = APIv2CatalogQuery()
        query.source = "library_collection"
        query.collectionId = "collection-one"
        query.libraryId = "library-one"
        query.limit = 40
        let first = try await api.catalogPage(query: query)
        CatalogProtocol.reply(200, terminal)
        let last = try await api.nextCatalogPage(XCTUnwrap(first.continuation))
        XCTAssertNil(last.continuation)
        let calls = CatalogProtocol.requests()
        XCTAssertEqual(calls.count, 2)
        for (index, call) in calls.enumerated() {
            XCTAssertEqual(call.0.httpMethod, "GET")
            XCTAssertEqual(call.0.url?.path, "/api/v2/catalog")
            let items = try XCTUnwrap(URLComponents(url: XCTUnwrap(call.0.url), resolvingAgainstBaseURL: false)?.queryItems)
            let parameters = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value) })
            XCTAssertEqual(parameters["source"], "library_collection")
            XCTAssertEqual(parameters["collection_id"], "collection-one")
            XCTAssertEqual(parameters["library_id"], "library-one")
            XCTAssertEqual(parameters["limit"], "40")
            XCTAssertNil(parameters["sort"])
            XCTAssertNil(parameters["offset"])
            if index == 0 { XCTAssertNil(parameters["cursor"]) }
            else { XCTAssertEqual(parameters["cursor"], "opaque-next") }
        }
    }

    func testContinuationRejectsChangedAccountBeforeDispatch() async throws {
        CatalogProtocol.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"next"},"total":2,"total_exact":true,"window_cursor":"w"}"#)
        let (api, tokens) = try await client()
        let first = try await api.catalogPage(query: .init())
        await tokens.switchActiveServer(serverId: "another-server")
        do {
            _ = try await api.nextCatalogPage(XCTUnwrap(first.continuation))
            XCTFail("Expected captured account rejection")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertEqual(CatalogProtocol.requests().count, 1)
    }

    func testMissingAndRepeatedCursorsFailWithoutReturningPartialPage() async throws {
        let (api, _) = try await client()
        CatalogProtocol.reply(200, #"{"items":[],"page":{"has_more":true},"total":3,"total_exact":true,"window_cursor":"w"}"#)
        do { _ = try await api.catalogPage(query: .init()); XCTFail("Expected missing cursor") }
        catch APIv2Error.invalidCatalogContinuation { }
        CatalogProtocol.reply(200, #"{"items":[],"page":{"has_more":true,"next_cursor":"same"},"total":3,"total_exact":true,"window_cursor":"w"}"#)
        let first = try await api.catalogPage(query: .init())
        do { _ = try await api.nextCatalogPage(XCTUnwrap(first.continuation)); XCTFail("Expected repeated cursor") }
        catch APIv2Error.invalidCatalogContinuation { }
        XCTAssertEqual(CatalogProtocol.requests().count, 3)
    }

    func testExpiredCursorProblemRequiresExplicitRestart() async throws {
        CatalogProtocol.reply(400, #"{"type":"https://siloserver.org/docs/api/v2/problems/invalid_cursor","title":"Invalid cursor","status":400,"detail":"Ranking expired; restart.","instance":"urn:test"}"#)
        let (api, _) = try await client()
        do { _ = try await api.catalogPage(query: .init()); XCTFail("Expected cursor problem") }
        catch APIv2Error.problem(let problem) { XCTAssertEqual(problem.status, 400) }
        XCTAssertEqual(CatalogProtocol.requests().count, 1)
    }

    func testNestedFacetsAndStringLibraryIdentifier() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let facets = try decoder.decode(APIv2CatalogFilters.self, from: Data(#"{"genres":[],"studios":[],"networks":[],"countries":[],"content_ratings":[],"original_languages":[],"authors":[],"narrators":[],"series":[],"technical":{"resolutions":["4K"],"audio_languages":["en"],"subtitle_languages":[]}}"#.utf8))
        XCTAssertEqual(facets.technical?.resolutions, ["4K"])
        let tab = try decoder.decode(APIv2LibraryCollectionTab.self, from: Data(#"{"library_id":"opaque-library","collections":[],"groups":[]}"#.utf8))
        XCTAssertEqual(tab.libraryId, "opaque-library")
        XCTAssertThrowsError(try decoder.decode(APIv2LibraryCollectionTab.self, from: Data(#"{"library_id":42,"collections":[],"groups":[]}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode(APIv2LibraryCollectionTab.self, from: Data(#"{"library_id":"42","collections":[]}"#.utf8)))
    }

    func testSearchWindowIsNotGlobalTotalAndInstantDecodes() throws {
        let body = #"{"items":[],"page":{"has_more":false},"total":10000,"total_exact":false,"window_cursor":"w","search_diagnostics":{"provider":"future-provider","mode":"hybrid","semantic_used":true,"result_window_limit":250,"session_expires_at":"2026-09-05T20:00:00.000Z"},"effective_sort":{"field":"title","order":"asc"}}"#
        let page = try HTTPClient.makeJSONDecoder().decode(APIv2CatalogPage.self, from: Data(body.utf8))
        XCTAssertEqual(page.total, 10000)
        XCTAssertFalse(page.totalExact)
        XCTAssertEqual(page.searchDiagnostics?.resultWindowLimit, 250)
        XCTAssertNotNil(page.searchDiagnostics?.sessionExpiresAt)
        XCTAssertEqual(page.effectiveSort?.field, "title")
    }

    func testPageLimitAndOversizedGETRejectBeforeTransport() async throws {
        let (api, _) = try await client()
        var query = APIv2CatalogQuery()
        query.limit = 101
        do { _ = try await api.catalogPage(query: query); XCTFail("Expected invalid limit") }
        catch APIv2Error.invalidCatalogQuery { }
        query.limit = 50
        query.groups = [.init(match: "all", rules: [.init(field: "title", op: "contains", value: .string(String(repeating: "x", count: 32769)))])]
        do { _ = try await api.catalogPage(query: query); XCTFail("Expected oversized GET rejection") }
        catch APIv2Error.invalidCatalogQuery { }
        XCTAssertTrue(CatalogProtocol.requests().isEmpty)
    }
}

private final class CatalogProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var response = (200, "{}")
    nonisolated(unsafe) private static var searchAllowed = true
    static func denySearch() { lock.withLock { searchAllowed = false } }
    nonisolated(unsafe) private static var recorded: [(URLRequest, Data?)] = []
    static func reset() { lock.withLock { recorded = []; response = (200, "{}"); searchAllowed = true } }
    static func reply(_ status: Int, _ body: String) { lock.withLock { response = (status, body) } }
    static func requests() -> [(URLRequest, Data?)] { lock.withLock { recorded } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                bytes.append(buffer, count: count)
            }
            data = bytes
        }
        let reply = Self.lock.withLock {
            Self.recorded.append((request, data))
            if request.url?.path == "/api/v2/catalog/search/capabilities" {
                return (200, "{\"revision\":\"one\",\"state\":\"ready\",\"provider\":\"search\",\"allowed\":\(Self.searchAllowed)}")
            }
            return Self.response
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil,
            headerFields: ["Content-Type": reply.0 >= 400 ? "application/problem+json" : "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
