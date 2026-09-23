import Foundation
import XCTest
@testable import Silo

/// Catalog lists (browse, search, history, person credits, collection items)
/// through the `SiloAPI` funnel on `/api/v2/catalog`: the first page's
/// request, cursor paging from the continuation, and the switch to
/// `POST /catalog/query` for filter sets too long for a GET.
final class CatalogPagingAPITests: XCTestCase {
    private let firstPage = #"{"items":[{"content_id":"movie:heat","type":"movie","title":"Heat"}],"page":{"has_more":true,"next_cursor":"cursor-2"},"total":2,"total_exact":true,"window_cursor":"w"}"#
    private let lastPage = #"{"items":[{"content_id":"movie:ronin","type":"movie","title":"Ronin"}],"page":{"has_more":false},"total":2,"total_exact":true,"window_cursor":"w"}"#

    private func client(stub: APIv2TestStub) async throws -> (SiloAPI, TokenStore) {
        let name = "CatalogPagingAPITests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "catalog-paging-test")
        await tokens.setServerUrl("https://catalog.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (SiloAPI(http: http, tokenStore: tokens), tokens)
    }

    func testHistoryPagesByCursorWithTheFirstPageQuery() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.sequence([.json(200, firstPage), .json(200, lastPage)])

        let first = try await api.catalogPage(.history(limit: 60))
        let next = try await api.nextCatalogPage(XCTUnwrap(first.continuation))

        XCTAssertEqual(first.response.items.map(\.contentId), ["movie:heat"])
        XCTAssertEqual(first.response.total, 2)
        XCTAssertEqual(first.response.totalExact, true)
        XCTAssertEqual(first.response.hasMore, true)
        XCTAssertEqual(next.response.items.map(\.contentId), ["movie:ronin"])
        XCTAssertNil(next.continuation, "the last page ends the list")
        XCTAssertEqual(next.response.hasMore, false)

        let requests = stub.requests
        XCTAssertEqual(requests.map(\.method), ["GET", "GET"])
        XCTAssertEqual(requests.map(\.path), ["/api/v2/catalog", "/api/v2/catalog"])
        for request in requests {
            XCTAssertEqual(request.query["source"], "history")
            XCTAssertEqual(request.query["limit"], "60")
            XCTAssertEqual(request.header("x-profile-id"), "profile-one")
            for key in ["offset", "snapshot", "snapshot_at", "include_total"] {
                XCTAssertNil(request.query[key], "\(key) is v1 paging")
            }
        }
        XCTAssertNil(requests[0].query["cursor"])
        XCTAssertEqual(requests[1].query["cursor"], "cursor-2")
    }

    func testSourceQueriesCarryTheirScope() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(200, lastPage)

        _ = try await api.catalogPage(.personCredits(personId: 42, type: "movie", limit: 60))
        _ = try await api.catalogPage(.collectionItems(kind: .userCollections, collectionId: "c/1", limit: 60))
        _ = try await api.catalogPage(.collectionItems(kind: .regular, collectionId: "lc1", limit: 60))
        _ = try await api.catalogPage(.search("heat", type: "video", limit: 60))

        let queries = stub.requests.map(\.query)
        XCTAssertEqual(queries.count, 4)
        XCTAssertEqual(queries[0]["source"], "person")
        XCTAssertEqual(queries[0]["person_id"], "42")
        XCTAssertEqual(queries[0]["type"], "movie")
        XCTAssertEqual(queries[0]["sort"], "-year", "credits list newest first")
        XCTAssertEqual(queries[1]["source"], "user_collection")
        XCTAssertEqual(queries[1]["collection_id"], "c/1")
        XCTAssertEqual(queries[2]["source"], "library_collection")
        XCTAssertEqual(queries[2]["collection_id"], "lc1")
        XCTAssertEqual(queries[3]["source"], "query")
        XCTAssertEqual(queries[3]["q"], "heat")
        XCTAssertEqual(queries[3]["type"], "video")
    }

    func testOversizedFiltersPageThroughThePOSTQuery() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.sequence([.json(200, firstPage), .json(200, lastPage)])
        var state = CatalogFilterState()
        state.studios = Set((0..<2000).map { "Studio number \($0)" })
        let query = CatalogQueryBuilder.build(state, libraryId: 7, mediaType: .movie, limit: 60, includeType: false)

        let first = try await api.catalogPage(query)
        _ = try await api.nextCatalogPage(XCTUnwrap(first.continuation))

        let requests = stub.requests
        XCTAssertEqual(requests.map(\.method), ["POST", "POST"], "the continuation keeps the operation")
        XCTAssertEqual(requests.map(\.path), ["/api/v2/catalog/query", "/api/v2/catalog/query"])
        var bodies: [[String: Any]] = []
        for request in requests {
            XCTAssertNil(request.query["groups"], "the filters travel in the body")
            let body = try XCTUnwrap(request.body)
            bodies.append(try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any]))
        }
        XCTAssertEqual(bodies[0]["library_id"] as? String, "7")
        XCTAssertEqual(bodies[0]["limit"] as? Int, 60)
        XCTAssertEqual((bodies[0]["groups"] as? [Any])?.count, 1)
        XCTAssertNil(bodies[0]["cursor"])
        XCTAssertEqual(bodies[1]["cursor"] as? String, "cursor-2")
        XCTAssertEqual((bodies[1]["groups"] as? [Any])?.count, 1, "later pages resend the first page's query")
        for key in ["offset", "snapshot_at", "include_total"] {
            XCTAssertNil(bodies[0][key])
        }
    }

    private let changedSource = #"{"type":"https://siloserver.org/docs/api/v2/problems/invalid_cursor","title":"Invalid cursor","status":400,"detail":"The catalog source changed. Restart from the first page."}"#
    private let freshFirstPage = #"{"items":[{"content_id":"movie:thief","type":"movie","title":"Thief"}],"page":{"has_more":true,"next_cursor":"fresh-2"},"total":3,"total_exact":true,"window_cursor":"w2"}"#

    func testRejectedCursorStartsOverFromTheFirstPage() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.sequence([.json(200, firstPage), .json(400, changedSource), .json(200, freshFirstPage), .json(200, lastPage)])

        let first = try await api.catalogPage(.collectionItems(kind: .userCollections, collectionId: "c1", limit: 60))
        let restarted = try await api.nextCatalogPage(XCTUnwrap(first.continuation))
        XCTAssertTrue(restarted.startsOver, "the caller replaces its grid")
        XCTAssertEqual(restarted.response.items.map(\.contentId), ["movie:thief"])
        XCTAssertEqual(restarted.response.total, 3)
        let next = try await api.nextCatalogPage(XCTUnwrap(restarted.continuation))
        XCTAssertFalse(next.startsOver)

        let requests = stub.requests
        XCTAssertEqual(requests.map { $0.query["cursor"] }, [nil, "cursor-2", nil, "fresh-2"],
                       "the rejected cursor is never sent again")
        for request in requests {
            XCTAssertEqual(request.query["source"], "user_collection")
            XCTAssertEqual(request.query["collection_id"], "c1")
            XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        }
    }

    func testRepeatedCursorStartsOverFromTheFirstPage() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.sequence([.json(200, firstPage), .json(200, firstPage), .json(200, freshFirstPage)])

        let first = try await api.catalogPage(.history(limit: 60))
        let restarted = try await api.nextCatalogPage(XCTUnwrap(first.continuation))

        XCTAssertTrue(restarted.startsOver)
        XCTAssertEqual(restarted.response.items.map(\.contentId), ["movie:thief"])
        XCTAssertEqual(stub.requests.map { $0.query["cursor"] }, [nil, "cursor-2", nil])
    }

    func testOtherPageFailuresDoNotStartOver() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.sequence([.json(200, firstPage), .json(400, #"{"type":"https://siloserver.org/docs/api/v2/problems/validation_failed","title":"Invalid","status":400,"detail":"limit is out of range"}"#)])

        let first = try await api.catalogPage(.history(limit: 60))
        do {
            _ = try await api.nextCatalogPage(XCTUnwrap(first.continuation))
            XCTFail("Only a rejected cursor starts over")
        } catch APIv2Error.problem(let problem) {
            XCTAssertEqual(problem.identifier, "validation_failed")
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(stub.requests.count, 2, "no first page is reread")
    }

    func testContinuationRefusesAReplacedProfile() async throws {
        let stub = APIv2TestStub()
        let (api, tokens) = try await client(stub: stub)
        stub.reply(200, firstPage)

        let first = try await api.catalogPage(.history(limit: 60))
        await tokens.setProfileId("profile-two")

        do {
            _ = try await api.nextCatalogPage(XCTUnwrap(first.continuation))
            XCTFail("A continuation cannot page another profile's list")
        } catch HTTPError.requestIdentityChanged {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(stub.requests.count, 1, "the refused page is never requested")
    }

    func testMalformedPageSurfacesInsteadOfAnEmptyList() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        // The v1 offset shape has no `page` or `window_cursor`.
        stub.reply(200, #"{"items":[],"total":0,"has_more":false,"snapshot":"s"}"#)

        do {
            _ = try await api.catalogPage(.history(limit: 60))
            XCTFail("A v1-shaped body must not read as an empty history")
        } catch {
            XCTAssertEqual(StartupContentPrefetcher.prefetchFailureReason(error), "decode_failed")
        }
    }
}
