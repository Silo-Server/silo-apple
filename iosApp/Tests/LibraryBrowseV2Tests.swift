import Foundation
import XCTest
@testable import Silo

/// Library sections and the Collections tab through the `SiloAPI` facade on
/// `/api/v2`. Both run on iOS and tvOS; the tvOS library landing page and
/// collections grid render exactly these values.
final class LibraryBrowseV2Tests: XCTestCase {
    private let sectionsJSON = #"{"sections":[{"id":"recent","section_type":"recently_added","title":"Recently Added","items":[{"content_id":"series:severance","type":"series","title":"Severance"}]}]}"#

    private func client(stub: APIv2TestStub) async throws -> (SiloAPI, TokenStore) {
        let name = "LibraryBrowseV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "library-test")
        await tokens.setServerUrl("https://library.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (SiloAPI(http: http, tokenStore: tokens), tokens)
    }

    private func card(_ id: String, title: String, poster: String = "", extra: String = "") -> String {
        #"{"id":"\#(id)","title":"\#(title)","poster_url":"\#(poster)","item_count":3\#(extra)}"#
    }

    private func curated(_ id: String, title: String, type: String) -> String {
        #"{"id":"\#(id)","library_id":"7","library_ids":["7"],"title":"\#(title)","collection_type":"\#(type)","poster_url":"","item_count":3,"sort_order":0,"created_at":"2026-01-02T03:04:05.678Z","updated_at":"2026-01-02T03:04:05.678Z"}"#
    }

    // MARK: Sections

    func testSectionsReadAsTheActingProfileAndStayOwnedByIt() async throws {
        let stub = APIv2TestStub()
        let (api, tokens) = try await client(stub: stub)
        stub.reply(path: "/api/v2/library/7/sections", 200, sectionsJSON)

        let read = try await api.librarySections(libraryId: 7)

        let request = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v2/library/7/sections")
        XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        XCTAssertEqual(read.libraryId, 7)
        XCTAssertEqual(read.sections.map(\.id), ["recent"])
        XCTAssertEqual(read.sections.first?.items.map(\.contentId), ["series:severance"])
        let ownsRead = await api.isCurrentOwner(read.auth)
        XCTAssertTrue(ownsRead)

        // Sections fetched for one profile never apply to the next.
        await tokens.setProfileId("profile-two")
        let stillOwnsRead = await api.isCurrentOwner(read.auth)
        XCTAssertFalse(stillOwnsRead)
    }

    func testSectionsSurfaceProblemsInsteadOfAnEmptyLibrary() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(path: "/api/v2/library/7/sections", 404,
            #"{"type":"https://siloserver.org/docs/api/v2/problems/not_found","title":"Not found","status":404,"detail":"No such library."}"#)

        do {
            _ = try await api.librarySections(libraryId: 7)
            XCTFail("A problem response must not become an empty library")
        } catch let APIv2Error.problem(problem) {
            XCTAssertEqual(problem.status, 404)
        }
    }

    func testSectionsWithDuplicateIdsAreRejected() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(path: "/api/v2/library/7/sections", 200,
            #"{"sections":[{"id":"a","section_type":"genre","title":"A","items":[]},{"id":"a","section_type":"genre","title":"B","items":[]}]}"#)

        do {
            _ = try await api.librarySections(libraryId: 7)
            XCTFail("Ambiguous section ids must not reach the landing page")
        } catch APIv2Error.incompleteCatalogRead {}
    }

    // MARK: Collections tab

    func testGroupedTabMapsKindsAndPlacesUngroupedBySortOrder() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        let body = """
        {"library_id":"7",
         "collections":[\(curated("c1", title: "Franchise A", type: "smart"))],
         "groups":[
           {"id":"g-admin","name":"Franchises","kind":"admin","sort_mode":"name_asc","sort_order":0,
            "collections":[\(card("c1", title: "Franchise A", poster: "/img/c1.jpg"))]},
           {"id":"g-personal","name":"From profiles","kind":"user_collections","sort_mode":"name_asc","sort_order":20,
            "collections":[\(card("u1", title: "Saved", extra: #","creator_profile_id":"profile-two""#))]},
           {"id":"g-future","name":"Future","kind":"editorial","sort_mode":"name_asc","sort_order":30,
            "collections":[\(card("f1", title: "Picks"))]}
         ],
         "ungrouped":{"sort_order":10,"collections":[\(card("c2", title: "Loose"))]}}
        """
        stub.reply(path: "/api/v2/library/7/collections", 200, body)

        let response = try await api.libraryCollections(libraryId: 7)

        let request = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/api/v2/library/7/collections")
        XCTAssertEqual(request.header("x-profile-id"), "profile-one")

        let sections = response.resolvedSections
        XCTAssertEqual(sections.map(\.id), ["g-admin", "__ungrouped__", "g-personal", "g-future"])
        XCTAssertEqual(sections.map(\.kind), [.regular, .regular, .userCollections, .regular])
        XCTAssertEqual(sections[0].collections.first?.name, "Franchise A")
        XCTAssertEqual(sections[0].collections.first?.collectionType, "smart")
        XCTAssertEqual(sections[0].collections.first?.posterUrl, "https://library.example/img/c1.jpg")
        XCTAssertNil(sections[1].collections.first?.posterUrl, "an empty poster means none")
        XCTAssertEqual(sections[2].collections.first?.kind, .userCollections)
        XCTAssertEqual(sections[2].collections.first?.creatorProfileId, "profile-two")
        XCTAssertEqual(response.collections.map(\.id), ["c1", "c2", "u1", "f1"])
    }

    func testTabWithoutGroupsShowsTheCuratedListAsOneSection() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(path: "/api/v2/library/7/collections", 200,
            #"{"library_id":"7","collections":[\#(curated("c1", title: "Oscar Winners", type: "manual"))],"groups":[]}"#)

        let response = try await api.libraryCollections(libraryId: 7)

        XCTAssertTrue(response.sections.isEmpty)
        let sections = response.resolvedSections
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.kind, .regular)
        XCTAssertEqual(sections.first?.collections.map(\.name), ["Oscar Winners"])
        XCTAssertEqual(sections.first?.collections.first?.kind, .regular)
    }

    func testTabForAnotherLibraryIsRejected() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(path: "/api/v2/library/7/collections", 200, #"{"library_id":"8","collections":[],"groups":[]}"#)

        do {
            _ = try await api.libraryCollections(libraryId: 7)
            XCTFail("Another library's tab must not render under this one")
        } catch APIv2Error.incompleteCatalogRead {}
    }

    func testTabIsNotReturnedAfterTheProfileChangesMidRead() async throws {
        let stub = APIv2TestStub()
        let (api, tokens) = try await client(stub: stub)
        stub.reply(path: "/api/v2/library/7/collections", 200, #"{"library_id":"7","collections":[],"groups":[]}"#)
        stub.hold()

        let pending = Task { try await api.libraryCollections(libraryId: 7) }
        await stub.waitUntilHeld()
        await tokens.setProfileId("profile-two")
        stub.release()

        do {
            _ = try await pending.value
            XCTFail("One profile's personal collections never reach the next")
        } catch {
            XCTAssertTrue(error is HTTPError, "unexpected error \(error)")
        }
    }
}
