import Foundation
import XCTest
@testable import Silo

/// Every owner-scoped `SiloAPI` read rechecks its owner after decoding and
/// projection. The client's owner fence already refuses a switch during the
/// round trip; these tests switch the profile after the fence has let the
/// read through, using the `ownerRecheckBarrier` seam, and expect the facade
/// to refuse the finished result.
@MainActor
final class SiloAPIOwnerRecheckTests: XCTestCase {
    private struct Harness {
        let stub: APIv2TestStub
        let tokens: TokenStore
        let http: HTTPClient
        let api: SiloAPI
    }

    /// One read through the facade and the single reply that answers it.
    private struct Read {
        let name: String
        /// `nil` where the path holds a percent-encoded ID.
        let path: String?
        let body: String
        var headers: [String: String] = [:]
        let call: @Sendable (SiloAPI) async throws -> Void
    }

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private let detailJSON = #"{"content_id":"movie","type":"movie","title":"Movie","status":"available","genres":[],"keywords":[],"cast":[],"crew":[],"versions":[],"subtitles":[]}"#
    private let watchJSON = #"{"content_id":"movie","type":"movie","title":"Movie","versions":[],"subtitles":[]}"#
    private let catalogFirstPage = #"{"items":[{"content_id":"movie:heat","type":"movie","title":"Heat"}],"page":{"has_more":true,"next_cursor":"cursor-2"},"total":2,"total_exact":true,"window_cursor":"w"}"#
    private let catalogLastPage = #"{"items":[{"content_id":"movie:ronin","type":"movie","title":"Ronin"}],"page":{"has_more":false},"total":2,"total_exact":true,"window_cursor":"w"}"#
    private let catalogTerminal = #"{"items":[],"page":{"has_more":false},"total":10000,"total_exact":false,"window_cursor":"window"}"#
    private let changedSource = #"{"type":"https://siloserver.org/docs/api/v2/problems/invalid_cursor","title":"Invalid cursor","status":400,"detail":"The catalog source changed. Restart from the first page."}"#
    private let freshFirstPage = #"{"items":[{"content_id":"movie:thief","type":"movie","title":"Thief"}],"page":{"has_more":true,"next_cursor":"fresh-2"},"total":3,"total_exact":true,"window_cursor":"w2"}"#
    private let collection = #"{"id":"c1","name":"Saved","collection_type":"manual","group_id":"g1"}"#
    private let group = #"{"id":"g1","name":"Seasonal","slug":"seasonal","default_sort_mode":"manual","sort_order":0}"#
    private let capabilities = #"{"revision":"r1","state":"available","allowed":true,"groups":true,"imports":false,"artwork":false,"item_reorder":false,"display_filter_fields":[],"display_filter_presets":{"watched":[],"media":[]},"collection_default_sort":false,"collection_sort_preferences":false,"effective_collection_sort":false,"sort_preference_kinds":[]}"#

    /// A session acting as `profile-one`. `barrier` runs where the facade
    /// rechecks the owner, after the read's round trip and projection.
    private func harness(barrier: @escaping @Sendable (TokenStore) async -> Void) async throws -> Harness {
        let stub = APIv2TestStub()
        let name = "SiloAPIOwnerRecheckTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "owner-recheck-test")
        await tokens.setServerUrl("https://owner.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        let api = SiloAPI(http: http, tokenStore: tokens, ownerRecheckBarrier: { await barrier(tokens) })
        return Harness(stub: stub, tokens: tokens, http: http, api: api)
    }

    private static let switchToProfileTwo: @Sendable (TokenStore) async -> Void = {
        await $0.setProfileId("profile-two")
    }

    private func personalListPage(_ ids: [String], next: String?) -> String {
        let items = ids.map { #"{"content_id":"\#($0)","type":"movie","title":"\#($0)"}"# }.joined(separator: ",")
        let page = next.map { #"{"has_more":true,"next_cursor":"\#($0)"}"# } ?? #"{"has_more":false}"#
        return #"{"items":[\#(items)],"page":\#(page)}"#
    }

    private var ownerScopedReads: [Read] {
        [
            Read(name: "recommendationsSimilar", path: nil,
                 body: #"{"items":[{"content_id":"movie:ronin","type":"movie","title":"Ronin"}]}"#,
                 call: { _ = try await $0.recommendationsSimilar(contentId: "movie:heat") }),
            Read(name: "recommendationsDiscover", path: "/api/v2/recommendations/discover",
                 body: #"{"items":[{"type":"cluster","kind":"cluster","key":"0","title":"Because you enjoy Crime","items":[{"content_id":"movie:heat","type":"movie","title":"Heat"}]},{"type":"popular","title":"Popular","items":[]}]}"#,
                 call: { _ = try await $0.recommendationsDiscover() }),
            Read(name: "calendarEvents", path: "/api/v2/calendar", body: #"{"events":[]}"#,
                 call: { _ = try await $0.calendarEvents(start: "2026-09-21", end: "2026-09-27", filter: "following", timezone: "UTC") }),
            Read(name: "catalogFilters", path: "/api/v2/catalog/filters",
                 body: #"{"genres":["Drama"],"studios":[],"networks":[],"countries":[],"content_ratings":[],"original_languages":[],"authors":[],"narrators":[],"series":[]}"#,
                 call: { _ = try await $0.catalogFilters(libraryId: nil, includeTechnical: false) }),
            Read(name: "catalogPage", path: "/api/v2/catalog", body: catalogLastPage,
                 call: { _ = try await $0.catalogPage(.history(limit: 60)) }),
            Read(name: "itemDetail", path: "/api/v2/catalog/items/movie", body: detailJSON,
                 call: { _ = try await $0.itemDetail(contentId: "movie") }),
            Read(name: "seasons", path: "/api/v2/catalog/series/series/seasons", body: #"{"items":[]}"#,
                 call: { _ = try await $0.seasons(seriesId: "series") }),
            Read(name: "episodes", path: "/api/v2/catalog/series/series/seasons/0/episodes", body: #"{"items":[]}"#,
                 call: { _ = try await $0.episodes(seriesId: "series", seasonNumber: 0) }),
            Read(name: "watchDetail", path: "/api/v2/watch/movie", body: watchJSON,
                 call: { _ = try await $0.watchDetail(contentId: "movie") }),
            Read(name: "person", path: nil, body: #"{"id":"7","name":"Al Pacino"}"#,
                 call: { _ = try await $0.person(id: "7") }),
            Read(name: "libraryCollections", path: "/api/v2/library/7/collections",
                 body: #"{"library_id":"7","collections":[],"groups":[]}"#,
                 call: { _ = try await $0.libraryCollections(libraryId: 7) }),
            Read(name: "favorites", path: "/api/v2/favorites", body: personalListPage(["movie:one"], next: nil),
                 call: { _ = try await $0.favorites() }),
            Read(name: "watchlist", path: "/api/v2/watchlist", body: personalListPage(["movie:one"], next: nil),
                 call: { _ = try await $0.watchlist() }),
            Read(name: "collections", path: "/api/v2/collections", body: #"{"items":[],"groups":[]}"#,
                 call: { _ = try await $0.collections() }),
            Read(name: "collectionCapabilities", path: "/api/v2/collections/capabilities", body: capabilities,
                 call: { _ = try await $0.collectionCapabilities() }),
            Read(name: "collectionItems", path: "/api/v2/catalog", body: catalogTerminal,
                 call: { _ = try await $0.collectionItems(collectionId: "c1") }),
            Read(name: "collectionEditor", path: "/api/v2/collections/c1", body: collection,
                 headers: ["ETag": #""v1""#],
                 call: { _ = try await $0.collectionEditor(id: "c1") }),
            Read(name: "collectionGroupEditor", path: "/api/v2/collections/groups/g1", body: group,
                 headers: ["ETag": #""g-v1""#],
                 call: { _ = try await $0.collectionGroupEditor(id: "g1") }),
        ]
    }

    func testEveryOwnerScopedReadRefusesAResultFinishedAfterAProfileSwitch() async throws {
        let reads = ownerScopedReads
        XCTAssertEqual(reads.count, 18)
        for read in reads {
            let harness = try await harness(barrier: Self.switchToProfileTwo)
            harness.stub.sequence([.json(200, read.body, headers: read.headers)])

            do {
                try await read.call(harness.api)
                XCTFail("\(read.name) returned the previous profile's data")
            } catch HTTPError.requestIdentityChanged {
                // The facade's recheck refused a result the fence let through.
            } catch {
                XCTFail("\(read.name): unexpected \(error)")
            }

            // One complete read reached the server for profile one, so the
            // pre-dispatch checks and the fence passed; for the paged
            // personal lists that one request is the whole, finished list.
            let requests = harness.stub.requests
            XCTAssertEqual(requests.count, 1, "\(read.name) sent \(requests.count) requests")
            XCTAssertEqual(requests.first?.header("x-profile-id"), "profile-one", read.name)
            if let path = read.path {
                XCTAssertEqual(requests.first?.path, path, read.name)
            }
        }
    }

    func testNextCatalogPageRefusesBothTheNextAndTheRestartedPage() async throws {
        let harness = try await harness(barrier: Self.switchToProfileTwo)
        let firstPageReader = SiloAPI(http: harness.http, tokenStore: harness.tokens)
        let stub = harness.stub

        // The normal next page.
        stub.sequence([.json(200, catalogFirstPage), .json(200, catalogLastPage)])
        let first = try await firstPageReader.catalogPage(.history(limit: 60))
        do {
            _ = try await harness.api.nextCatalogPage(XCTUnwrap(first.continuation))
            XCTFail("the next page returned the previous profile's cards")
        } catch HTTPError.requestIdentityChanged {
        } catch {
            XCTFail("next page: unexpected \(error)")
        }
        XCTAssertEqual(stub.requests.map { $0.query["cursor"] }, [nil, "cursor-2"])

        // The fresh first page read in place of a rejected cursor.
        await harness.tokens.setProfileId("profile-one")
        stub.sequence([.json(200, catalogFirstPage), .json(400, changedSource), .json(200, freshFirstPage)])
        let second = try await firstPageReader.catalogPage(.history(limit: 60))
        do {
            _ = try await harness.api.nextCatalogPage(XCTUnwrap(second.continuation))
            XCTFail("the restarted page returned the previous profile's cards")
        } catch HTTPError.requestIdentityChanged {
        } catch {
            XCTFail("restarted page: unexpected \(error)")
        }

        let requests = stub.requests
        XCTAssertEqual(requests.map { $0.query["cursor"] }, [nil, "cursor-2", nil, "cursor-2", nil],
                       "the restart read a fresh first page before the recheck refused it")
        for request in requests {
            XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        }
    }

    func testReadsSucceedWhileTheOwnerIsUnchanged() async throws {
        let rechecks = Counter()
        let harness = try await harness(barrier: { _ in await rechecks.increment() })
        let api = harness.api
        harness.stub.sequence([
            .json(200, detailJSON),
            .json(200, #"{"items":[]}"#),
            .json(200, personalListPage(["movie:one"], next: nil)),
            .json(200, collection, headers: ["ETag": #""v1""#]),
        ])

        let detail = try await api.itemDetail(contentId: "movie")
        XCTAssertEqual(detail.contentId, "movie")
        let episodes = try await api.episodes(seriesId: "series", seasonNumber: 0)
        XCTAssertEqual(episodes.episodes.count, 0)
        let favorites = try await api.favorites()
        XCTAssertEqual(favorites.items.map(\.contentId), ["movie:one"])
        let editor = try await api.collectionEditor(id: "c1")
        XCTAssertEqual(editor.value.id, "c1")
        XCTAssertEqual(editor.version.etag, #""v1""#)

        let recheckCount = await rechecks.value
        XCTAssertEqual(recheckCount, 4, "every read passed through the owner recheck")
    }
}
