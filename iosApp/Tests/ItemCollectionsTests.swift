import Foundation
import XCTest
@testable import Silo

/// The collections row on movie and series pages (silo-server#4528,
/// silo-apple#1222). `listCatalogItemCollections` answers the collections
/// that hold a title; with one, it also carries a few of that collection's
/// other titles.
@MainActor
final class ItemCollectionsTests: XCTestCase {
    private static let capabilitiesPath = "/api/v2/catalog/search/capabilities"

    private let crimeClassics = #"{"id":"01J9Z8C3W4R5T6Y7U8I9O0P1Q2","source":"library","title":"Crime classics","poster_url":"/api/v2/images/collections/01J9Z8C3W4R5T6Y7U8I9O0P1Q2/poster","poster_is_collage":false,"item_count":24,"library_id":"1"}"#
    private let favorites = #"{"id":"c1","source":"user","title":"Favorites","poster_url":"/api/v2/images/user-collections/c1/collage","poster_is_collage":true,"item_count":7,"creator_profile_id":"p-owner"}"#
    private let harborLights = #"{"content_id":"movie:harbor-lights-2019","type":"movie","title":"Harbor Lights","year":2019,"genres":[],"keywords":[],"status":"","poster_url":"/api/v2/images/items/movie:harbor-lights-2019/poster"}"#

    private var stub = APIv2TestStub()

    override func setUp() async throws {
        try await super.setUp()
        stub = APIv2TestStub()
    }

    private func api() async throws -> SiloAPI {
        let name = "ItemCollectionsTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "item-collections-test")
        await tokens.setServerUrl("https://collections.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return SiloAPI(http: http, tokenStore: tokens)
    }

    private func advertise(itemCollections: Bool) {
        let flag = itemCollections ? #","item_collections":true"# : ""
        stub.reply(path: Self.capabilitiesPath, 200,
                   #"{"revision":"r","state":"available","allowed":true\#(flag)}"#)
    }

    // MARK: The read

    /// The page asks for its title's collections in the library it was
    /// opened from, and gets the cards and the one collection's titles.
    func testTitlePageReadsItsCollectionsAndTheOneCollectionsTitles() async throws {
        let api = try await api()
        advertise(itemCollections: true)
        let path = "/api/v2/catalog/items/movie:night-train-1987/collections"
        stub.reply(path: path, 200, #"{"items":[\#(crimeClassics)],"preview_items":[\#(harborLights)]}"#)

        let read = try await api.itemCollections(contentId: "movie:night-train-1987", libraryId: 1)

        let request = try XCTUnwrap(stub.requests.last { $0.path == path })
        XCTAssertEqual(request.query["library_id"], "1")
        XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        let found = try XCTUnwrap(read)
        XCTAssertEqual(found.cards.map(\.title), ["Crime classics"])
        XCTAssertEqual(found.cards.first?.source, .library(libraryId: 1))
        XCTAssertEqual(found.preview.map(\.contentId), ["movie:harbor-lights-2019"])
    }

    /// A server without `item_collections` is not asked, and is asked again
    /// on the next page, so one upgraded while the app runs shows the row
    /// without a relaunch. Once it says yes, the answer is kept.
    func testTitlePageAsksAgainUntilTheServerAdvertisesItemCollections() async throws {
        let api = try await api()
        stub.sequence(path: Self.capabilitiesPath, [
            .json(200, #"{"revision":"r","state":"available","allowed":true,"box_sets":true}"#),
            .json(200, #"{"revision":"r","state":"available","allowed":true,"item_collections":true}"#),
        ])
        let path = "/api/v2/catalog/items/series:1/collections"
        stub.reply(path: path, 200, #"{"items":[\#(crimeClassics),\#(favorites)],"preview_items":[]}"#)

        let before = try await api.itemCollections(contentId: "series:1", libraryId: nil)
        XCTAssertNil(before)
        XCTAssertFalse(stub.requestedPaths.contains(path), "a server without the read is not asked")

        let first = try await api.itemCollections(contentId: "series:1", libraryId: nil)
        _ = try await api.itemCollections(contentId: "series:1", libraryId: nil)
        XCTAssertEqual(first?.cards.map(\.rowKey), ["library:01J9Z8C3W4R5T6Y7U8I9O0P1Q2", "user:c1"])
        XCTAssertNil(stub.requests.last { $0.path == path }?.query["library_id"])
        XCTAssertEqual(stub.requestedPaths.filter { $0 == Self.capabilitiesPath }.count, 2)
        XCTAssertEqual(stub.requestedPaths.filter { $0 == path }.count, 2)
    }

    /// A capabilities read that says yes to box sets and collections is kept
    /// for both, so a later collections check asks the server nothing.
    func testOneCapabilitiesReadIsKeptForBothTitlePageFeatures() async throws {
        let api = try await api()
        stub.reply(path: Self.capabilitiesPath, 200,
                   #"{"revision":"r","state":"available","allowed":true,"box_sets":true,"item_collections":true}"#)
        stub.reply(path: "/api/v2/catalog/items/m1/box-set", 200, "{}")
        stub.reply(path: "/api/v2/catalog/items/m1/collections", 200, #"{"items":[],"preview_items":[]}"#)

        _ = try await api.itemBoxSet(contentId: "m1", libraryId: 1)
        let read = try await api.itemCollections(contentId: "m1", libraryId: 1)

        XCTAssertEqual(read?.cards.count, 0)
        XCTAssertEqual(stub.requestedPaths.filter { $0 == Self.capabilitiesPath }.count, 1)
    }

    /// A title the server no longer serves the viewer has no collections,
    /// so a reread removes the row. A dropped connection is a failure, which
    /// the page answers by keeping its last row.
    func testTitleTheServerNoLongerServesHasNoCollections() async throws {
        let api = try await api()
        advertise(itemCollections: true)
        let path = "/api/v2/catalog/items/movie:gone/collections"
        stub.sequence(path: path, [
            .json(404, #"{"type":"https://siloserver.org/docs/api/v2/problems/not_found","title":"Not found","status":404,"detail":"Not found","instance":"urn:test"}"#),
            .failure(URLError(.networkConnectionLost)),
        ])

        let gone = try await api.itemCollections(contentId: "movie:gone", libraryId: 1)
        XCTAssertNil(gone)
        do {
            _ = try await api.itemCollections(contentId: "movie:gone", libraryId: 1)
            XCTFail("a dropped connection is a failure, not an answer")
        } catch {}
    }

    // MARK: The row

    private func card(_ id: String, _ title: String) -> SectionCollectionCard {
        SectionCollectionCard(id: id, source: .library(libraryId: 1), title: title, itemCount: 3)
    }

    private func titles(_ count: Int) throws -> [BrowseItem] {
        let json = "[" + (1...count).map { #"{"content_id":"m\#($0)","type":"movie","title":"M\#($0)"}"# }
            .joined(separator: ",") + "]"
        return try HTTPClient.makeJSONDecoder().decode([BrowseItem].self, from: Data(json.utf8))
    }

    /// One collection with other titles shows them under its name, at most
    /// six; one with none, or several, shows the collection cards; nothing
    /// shows no row.
    func testRowShowsTheOneCollectionsTitlesOrEveryCollection() throws {
        let ghibli = card("g", "Studio Ghibli")
        let picked = try XCTUnwrap(ItemCollectionsRowContent(CatalogItemCollections(cards: [ghibli], preview: try titles(8))))
        XCTAssertEqual(picked, .titles(collection: ghibli, items: try titles(6)))

        let alone = try XCTUnwrap(ItemCollectionsRowContent(CatalogItemCollections(cards: [ghibli])))
        XCTAssertEqual(alone, .collections([ghibli]), "a collection holding only this title shows its card")

        let many = (1...15).map { card("c\($0)", "Collection \($0)") }
        let all = try XCTUnwrap(ItemCollectionsRowContent(CatalogItemCollections(cards: many, preview: try titles(2))))
        XCTAssertEqual(all, .collections(many), "every collection, with no cap")

        XCTAssertNil(ItemCollectionsRowContent(CatalogItemCollections(cards: [])))
        XCTAssertNil(ItemCollectionsRowContent(nil))
    }
}
