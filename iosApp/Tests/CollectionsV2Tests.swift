import Foundation
import XCTest
@testable import Silo

/// Personal collections on the v2 wire: the editor's observed ETag rides on
/// the mutation as `If-Match` under the same owner, and the card read follows
/// opaque catalog pages under the owner that opened it.
final class CollectionsV2Tests: XCTestCase {
    private let collection = #"{"id":"c1","name":"Saved","collection_type":"manual","group_id":"g1"}"#
    private var stub = APIv2TestStub()

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func client() async throws -> (APIv2Client, TokenStore) {
        let name = "CollectionsV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://collections.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens)
    }

    private func page(_ items: String, hasMore: Bool, next: String? = nil) -> String {
        let page = next.map { #"{"has_more":\#(hasMore),"next_cursor":"\#($0)"}"# } ?? #"{"has_more":\#(hasMore)}"#
        return #"{"items":[\#(items)],"page":\#(page),"total":1,"total_exact":true,"window_cursor":"w"}"#
    }

    func testMoveUsesObservedETagAndExplicitNull() async throws {
        stub.reply(200, collection, headers: ["ETag": #""observed""#])
        let (api, _) = try await client()
        let editor: CollectionEditor<UserCollection> = try await api.collectionEditor("/api/v2/collections/c1")
        XCTAssertEqual(editor.value.id, "c1")
        XCTAssertEqual(editor.version.etag, #""observed""#)
        stub.reply(200, collection, headers: ["ETag": #""new""#])
        let moved: UserCollection = try await api.mutateCollection(method: "PATCH", version: editor.version,
            body: UpdateUserCollectionGroupBody(groupId: nil))
        XCTAssertEqual(moved.id, "c1")
        let sent = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(sent.method, "PATCH")
        XCTAssertEqual(sent.path, "/api/v2/collections/c1")
        XCTAssertEqual(sent.header("if-match"), #""observed""#)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(sent.body)) as? [String: Any])
        XCTAssertTrue(decoded["group_id"] is NSNull)
    }

    func testStaleVersionSurfacesAsProblemAndIsNotRetried() async throws {
        stub.reply(200, collection, headers: ["ETag": #""first""#])
        let (api, _) = try await client()
        let editor: CollectionEditor<UserCollection> = try await api.collectionEditor("/api/v2/collections/c1")
        stub.reply(412, #"{"type":"https://siloserver.org/docs/api/v2/problems/stale_version","title":"Conflict","status":412,"detail":"Changed","instance":"urn:test"}"#)
        do {
            let _: UserCollection = try await api.mutateCollection(method: "PATCH", version: editor.version,
                body: UpdateUserCollectionGroupBody(groupId: nil))
            XCTFail("a 412 is a definite failure the caller must review")
        } catch APIv2Error.problem(let problem) {
            XCTAssertEqual(problem.status, 412)
            XCTAssertEqual(problem.identifier, "stale_version")
        }
        XCTAssertEqual(stub.requests.count, 2, "one read, one mutation, no replay")
        XCTAssertEqual(stub.requests.last?.header("if-match"), #""first""#, "the observed tag is sent unchanged")
    }

    func testMutationRefusesAnOwnerOtherThanTheEditorsAndDeleteRequires204() async throws {
        stub.reply(200, collection, headers: ["ETag": #""first""#])
        let (api, tokens) = try await client()
        let editor: CollectionEditor<UserCollection> = try await api.collectionEditor("/api/v2/collections/c1")
        await tokens.setProfileToken("replacement")
        do {
            try await api.deleteCollection(version: editor.version)
            XCTFail("a version captured for another owner cannot be sent")
        } catch HTTPError.requestIdentityChanged { }
        XCTAssertEqual(stub.requests.count, 1, "nothing left the device")

        stub.reply(200, collection, headers: ["ETag": #""second""#])
        let current: CollectionEditor<UserCollection> = try await api.collectionEditor("/api/v2/collections/c1")
        stub.reply(200, "")
        do {
            try await api.deleteCollection(version: current.version)
            XCTFail("delete requires exactly 204")
        } catch APIv2Error.httpStatus(200) { }
        stub.reply(204, "")
        try await api.deleteCollection(version: current.version)
        XCTAssertEqual(stub.requests.last?.method, "DELETE")
        XCTAssertEqual(stub.requests.last?.header("if-match"), #""second""#)
    }

    func testPersonalCardsFollowOpaqueCursorAndNeverDecodeMembership() async throws {
        stub.sequence([
            .json(200, page(#"{"content_id":"film1","type":"movie","title":"Film"}"#, hasMore: true, next: "opaque-next")),
            .json(200, page("", hasMore: false)),
        ])
        let (api, tokens) = try await client()
        let authValue = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(authValue)
        let result = try await api.personalCollectionCards(id: "c1", auth: auth)
        XCTAssertEqual(result.items.map(\.contentId), ["film1"])
        XCTAssertEqual(result.hasMore, false)
        XCTAssertEqual(result.total, 1)
        let sent = stub.requests
        XCTAssertEqual(sent.count, 2)
        for request in sent {
            XCTAssertEqual(request.path, "/api/v2/catalog")
            XCTAssertEqual(request.query["source"], "user_collection")
            XCTAssertEqual(request.query["collection_id"], "c1")
            XCTAssertEqual(request.query["limit"], "50")
            XCTAssertNil(request.query["offset"])
            XCTAssertNil(request.query["sort"])
        }
        XCTAssertEqual(sent[1].query["cursor"], "opaque-next")
    }

    func testPersonalCardsRejectIncompletePage() async throws {
        stub.reply(200, page("", hasMore: true))
        let (api, tokens) = try await client()
        let authValue = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(authValue)
        do {
            _ = try await api.personalCollectionCards(id: "c1", auth: auth)
            XCTFail("Expected incomplete page error")
        } catch APIv2Error.invalidCatalogContinuation { }
        XCTAssertEqual(stub.requests.count, 1)
    }

    func testPersonalCardsPublishNothingWhenTheOwnerChangesMidRead() async throws {
        stub.sequence([
            .json(200, page(#"{"content_id":"film1","type":"movie","title":"Film"}"#, hasMore: true, next: "opaque-next")),
            .json(200, page("", hasMore: false)),
        ])
        let (api, tokens) = try await client()
        let authValue = await tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(authValue)
        stub.hold()
        let pending = Task { try await api.personalCollectionCards(id: "c1", auth: auth) }
        await stub.waitUntilHeld()
        await tokens.setProfileToken("replacement")
        stub.release()
        do {
            _ = try await pending.value
            XCTFail("a partial list under a replaced owner is never published")
        } catch HTTPError.authorityChanged { }
        XCTAssertEqual(stub.requests.count, 1, "the second page is never requested")
    }

    func testMissingETagCannotOpenEditor() async throws {
        stub.reply(200, collection)
        let (api, _) = try await client()
        do {
            let _: CollectionEditor<UserCollection> = try await api.collectionEditor("/api/v2/collections/c1")
            XCTFail("Expected missing version")
        } catch APIv2Error.missingCollectionVersion { }
    }
}
