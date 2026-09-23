import Foundation
import XCTest
@testable import Silo

/// Favorites and watchlist screens read the whole list from
/// `/api/v2/favorites` and `/api/v2/watchlist` by cursor, with no item cap.
final class PersonalListsAPITests: XCTestCase {
    private func client(stub: APIv2TestStub) async throws -> (SiloAPI, TokenStore) {
        let name = "PersonalListsAPITests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "personal-lists-test")
        await tokens.setServerUrl("https://lists.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (SiloAPI(http: http, tokenStore: tokens), tokens)
    }

    private func page(_ ids: [String], next: String?) -> String {
        let items = ids.map { #"{"content_id":"\#($0)","type":"movie","title":"\#($0)"}"# }.joined(separator: ",")
        let page = next.map { #"{"has_more":true,"next_cursor":"\#($0)"}"# } ?? #"{"has_more":false}"#
        return #"{"items":[\#(items)],"page":\#(page)}"#
    }

    func testFavoritesReadsEveryPage() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        let firstIDs = (0..<200).map { "movie:\($0)" }
        stub.sequence([.json(200, page(firstIDs, next: "c2")), .json(200, page([], next: "c3")),
                       .json(200, page(["movie:last"], next: nil))])

        let response = try await api.favorites()

        XCTAssertEqual(response.items.map(\.contentId), firstIDs + ["movie:last"],
                       "items past the first 100 stay, and an empty middle page still advances")
        XCTAssertEqual(response.total, 201)
        XCTAssertEqual(response.hasMore, false)
        let requests = stub.requests
        XCTAssertEqual(requests.map(\.path), Array(repeating: "/api/v2/favorites", count: 3))
        XCTAssertEqual(requests.map { $0.query["cursor"] }, [nil, "c2", "c3"])
        for request in requests {
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.query["limit"], "200")
            XCTAssertNil(request.query["offset"], "offset is v1 paging")
            XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        }
    }

    func testWatchlistReadsTheWatchlistRoute() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.sequence([.json(200, page(["show:one"], next: "c2")), .json(200, page(["movie:two"], next: nil))])

        let response = try await api.watchlist()

        XCTAssertEqual(response.items.map(\.contentId), ["show:one", "movie:two"])
        XCTAssertEqual(stub.requests.map(\.path), ["/api/v2/watchlist", "/api/v2/watchlist"])
    }

    func testListPastThePageBudgetFailsInsteadOfTruncating() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.sequence((1...101).map { .json(200, page(["movie:\($0)"], next: "c\($0 + 1)")) })

        do {
            _ = try await api.favorites()
            XCTFail("a list that never ends is not shown as complete")
        } catch APIv2Error.incompletePersonalList {
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(stub.requests.count, 100)
    }

    func testRepeatedCursorFails() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.sequence([.json(200, page(["movie:one"], next: "c2")), .json(200, page(["movie:two"], next: "c2"))])

        do {
            _ = try await api.watchlist()
            XCTFail("a repeated cursor would loop")
        } catch APIv2Error.invalidPersonalListContinuation {
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testProfileSwitchDuringTheReadDiscardsTheList() async throws {
        let stub = APIv2TestStub()
        let (api, tokens) = try await client(stub: stub)
        stub.sequence([.json(200, page(["movie:one"], next: nil))])
        stub.hold()

        let read = Task { try await api.favorites() }
        await stub.waitUntilHeld()
        await tokens.setProfileId("profile-two")
        stub.release()

        do {
            _ = try await read.value
            XCTFail("profile one's favorites must not reach profile two")
        } catch {}
    }
}
