import Foundation
import XCTest
@testable import Silo

/// Personal collections on the v2 wire: the editor's observed ETag rides on
/// the mutation as `If-Match` under the same owner, every write asserts its
/// one success status and is never resent, and the card read follows opaque
/// catalog pages under the owner that opened it.
final class CollectionsV2Tests: XCTestCase {
    private let collection = #"{"id":"c1","name":"Saved","collection_type":"manual","group_id":"g1"}"#
    private let group = #"{"id":"g1","name":"Seasonal","slug":"seasonal","default_sort_mode":"manual","sort_order":0}"#
    private let stale = #"{"type":"https://siloserver.org/docs/api/v2/problems/stale_version","title":"Conflict","status":412,"detail":"Changed","instance":"urn:test"}"#
    private var stub = APIv2TestStub()

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func client() async throws -> (APIv2Client, TokenStore, CapturedOrdinaryRequestAuth) {
        let name = "CollectionsV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "test-server")
        await tokens.setServerUrl("https://collections.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        let captured = await tokens.captureOrdinaryRequestAuth()
        return (APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }), tokens, try XCTUnwrap(captured))
    }

    private func page(_ items: String, hasMore: Bool, next: String? = nil) -> String {
        let page = next.map { #"{"has_more":\#(hasMore),"next_cursor":"\#($0)"}"# } ?? #"{"has_more":\#(hasMore)}"#
        return #"{"items":[\#(items)],"page":\#(page),"total":1,"total_exact":true,"window_cursor":"w"}"#
    }

    private func jsonBody(_ request: StubURLProtocol.Request?) throws -> [String: Any] {
        let body = try XCTUnwrap(request?.body)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // MARK: List, capabilities, create

    func testListDecodesItemsAndGroupsForTheActingProfile() async throws {
        stub.reply(200, #"{"items":[\#(collection)],"groups":[\#(group)]}"#)
        let (api, _, auth) = try await client()
        let list = try await api.personalCollections(auth: auth)
        XCTAssertEqual(list.items.map(\.id), ["c1"])
        XCTAssertEqual(list.items.first?.groupId, "g1")
        XCTAssertEqual(list.groups.map(\.id), ["g1"])
        let sent = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(sent.method, "GET")
        XCTAssertEqual(sent.path, "/api/v2/collections")
        XCTAssertEqual(sent.header("x-profile-id"), "profile-one")
    }

    func testListThatSaysMoreFollowsIsRefused() async throws {
        stub.reply(200, #"{"items":[\#(collection)],"groups":[],"page":{"has_more":true,"next_cursor":"n"}}"#)
        let (api, _, auth) = try await client()
        do {
            _ = try await api.personalCollections(auth: auth)
            XCTFail("a cut-off list is never shown as complete")
        } catch APIv2Error.incompleteCollection { }
    }

    func testCapabilitiesGateGroupsOnAllowedStateAndGroups() async throws {
        let (api, _, auth) = try await client()
        func capabilities(_ state: String, allowed: Bool, groups: Bool) -> String {
            #"{"revision":"r1","state":"\#(state)","allowed":\#(allowed),"groups":\#(groups),"imports":false,"artwork":false,"item_reorder":false,"display_filter_fields":[],"display_filter_presets":{"watched":[],"media":[]},"collection_default_sort":false,"collection_sort_preferences":false,"effective_collection_sort":false,"sort_preference_kinds":[]}"#
        }
        stub.reply(200, capabilities("available", allowed: true, groups: true))
        let supported = try await api.collectionCapabilities(auth: auth)
        XCTAssertTrue(supported.supportsGroups)
        XCTAssertEqual(stub.requests.last?.path, "/api/v2/collections/capabilities")
        stub.reply(200, capabilities("available", allowed: true, groups: false))
        let sqlite = try await api.collectionCapabilities(auth: auth)
        XCTAssertFalse(sqlite.supportsGroups, "SQLite stores answer 501 for every group operation")
        stub.reply(200, capabilities("not_configured", allowed: true, groups: false))
        let notConfigured = try await api.collectionCapabilities(auth: auth)
        XCTAssertFalse(notConfigured.supportsGroups)
    }

    func testCreateSendsManualCollectionOnceAndRequires201() async throws {
        stub.reply(201, collection, headers: ["Location": "/api/v2/collections/c1"])
        let (api, _, auth) = try await client()
        let created = try await api.createCollection(name: "Saved", auth: auth)
        XCTAssertEqual(created.id, "c1")
        let sent = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/api/v2/collections")
        XCTAssertNil(sent.header("if-match"))
        let body = try jsonBody(sent)
        XCTAssertEqual(body["name"] as? String, "Saved")
        XCTAssertEqual(body["collection_type"] as? String, "manual")

        stub.reply(200, collection)
        do {
            _ = try await api.createCollection(name: "Saved", auth: auth)
            XCTFail("create answers 201")
        } catch APIv2Error.httpStatus(200) { }

        stub.fail(.networkConnectionLost)
        do {
            _ = try await api.createCollection(name: "Saved", auth: auth)
            XCTFail("a lost answer is reported, not resent")
        } catch { }
        XCTAssertEqual(stub.requests.count, 3, "each create is dispatched exactly once")
    }

    func testCreateGroupSendsNameOnly() async throws {
        stub.reply(201, group)
        let (api, _, auth) = try await client()
        let created = try await api.createCollectionGroup(name: "Seasonal", auth: auth)
        XCTAssertEqual(created.id, "g1")
        let sent = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.path, "/api/v2/collections/groups")
        XCTAssertEqual(try jsonBody(sent).keys.sorted(), ["name"])
    }

    // MARK: Editors

    func testMoveUsesObservedETagAndExplicitNull() async throws {
        stub.reply(200, collection, headers: ["ETag": #""observed""#])
        let (api, _, auth) = try await client()
        let editor = try await api.collectionEditor(id: "c1", auth: auth)
        XCTAssertEqual(editor.value.id, "c1")
        XCTAssertEqual(editor.version.etag, #""observed""#)
        XCTAssertEqual(stub.requests.last?.path, "/api/v2/collections/c1")
        stub.reply(200, collection, headers: ["ETag": #""new""#])
        let moved = try await api.moveCollection(editor.version, toGroupId: nil)
        XCTAssertEqual(moved.id, "c1")
        let sent = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(sent.method, "PATCH")
        XCTAssertEqual(sent.path, "/api/v2/collections/c1")
        XCTAssertEqual(sent.header("if-match"), #""observed""#)
        XCTAssertTrue(try jsonBody(sent)["group_id"] is NSNull, "null ungroups; an omitted member would mean unchanged")
    }

    func testStaleVersionSurfacesAsProblemAndIsNotRetried() async throws {
        stub.reply(200, collection, headers: ["ETag": #""first""#])
        let (api, _, auth) = try await client()
        let editor = try await api.collectionEditor(id: "c1", auth: auth)
        stub.reply(412, stale, headers: ["ETag": #""second""#])
        do {
            _ = try await api.moveCollection(editor.version, toGroupId: "g2")
            XCTFail("a 412 is a definite failure the caller must review")
        } catch APIv2Error.problem(let problem) {
            XCTAssertEqual(problem.status, 412)
            XCTAssertEqual(problem.identifier, "stale_version")
        }
        XCTAssertEqual(stub.requests.count, 2, "one read, one mutation, no replay")
        XCTAssertEqual(stub.requests.last?.header("if-match"), #""first""#, "the observed tag is sent unchanged")
    }

    func testGroupEditorRenameAndDeleteSendTheirVersion() async throws {
        stub.reply(200, group, headers: ["ETag": #""g-v1""#])
        let (api, _, auth) = try await client()
        let editor = try await api.collectionGroupEditor(id: "g1", auth: auth)
        XCTAssertEqual(stub.requests.last?.path, "/api/v2/collections/groups/g1")
        stub.reply(200, #"{"id":"g1","name":"Winter","slug":"seasonal","default_sort_mode":"manual","sort_order":0}"#)
        let renamed = try await api.renameCollectionGroup(editor.version, name: "Winter")
        XCTAssertEqual(renamed.name, "Winter")
        let rename = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(rename.method, "PATCH")
        XCTAssertEqual(rename.header("if-match"), #""g-v1""#)
        XCTAssertEqual(try jsonBody(rename) as? [String: String], ["name": "Winter"])

        stub.reply(428, #"{"type":"https://siloserver.org/docs/api/v2/problems/precondition_required","title":"Precondition Required","status":428,"detail":"Send If-Match","instance":"urn:test"}"#)
        do {
            try await api.deleteCollectionGroup(editor.version)
            XCTFail("a 428 is surfaced, never answered with a wildcard")
        } catch APIv2Error.problem(let problem) {
            XCTAssertEqual(problem.status, 428)
        }
        let delete = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(delete.method, "DELETE")
        XCTAssertEqual(delete.path, "/api/v2/collections/groups/g1")
        XCTAssertEqual(delete.header("if-match"), #""g-v1""#)
    }

    func testMutationRefusesAnOwnerOtherThanTheEditorsAndDeleteRequires204() async throws {
        stub.reply(200, collection, headers: ["ETag": #""first""#])
        let (api, tokens, auth) = try await client()
        let editor = try await api.collectionEditor(id: "c1", auth: auth)
        await tokens.setProfileToken("replacement")
        do {
            try await api.deleteCollection(editor.version)
            XCTFail("a version captured for another owner cannot be sent")
        } catch is APIv2OwnerChangedBeforeDispatch { }
        XCTAssertEqual(stub.requests.count, 1, "nothing left the device")

        let currentAuthValue = await tokens.captureOrdinaryRequestAuth()
        let currentAuth = try XCTUnwrap(currentAuthValue)
        stub.reply(200, collection, headers: ["ETag": #""second""#])
        let current = try await api.collectionEditor(id: "c1", auth: currentAuth)
        stub.reply(200, "")
        do {
            try await api.deleteCollection(current.version)
            XCTFail("delete requires exactly 204")
        } catch APIv2Error.httpStatus(200) { }
        stub.reply(204, "")
        try await api.deleteCollection(current.version)
        XCTAssertEqual(stub.requests.last?.method, "DELETE")
        XCTAssertEqual(stub.requests.last?.header("if-match"), #""second""#)
    }

    func testEditorNeedsAStrongETagForTheRequestedId() async throws {
        let (api, _, auth) = try await client()
        stub.reply(200, collection)
        do {
            _ = try await api.collectionEditor(id: "c1", auth: auth)
            XCTFail("Expected missing version")
        } catch APIv2Error.missingEntityTag { }
        stub.reply(200, collection, headers: ["ETag": #"W/"weak""#])
        do {
            _ = try await api.collectionEditor(id: "c1", auth: auth)
            XCTFail("a weak validator cannot guard a write")
        } catch APIv2Error.missingEntityTag { }
        stub.reply(200, collection, headers: ["ETag": #""tag""#])
        do {
            _ = try await api.collectionEditor(id: "other", auth: auth)
            XCTFail("the editor must describe the requested collection")
        } catch APIv2Error.incompleteCollection { }
    }

    func testEditorPathEncodesTheId() async throws {
        stub.reply(200, #"{"id":"a/b","name":"Saved"}"#, headers: ["ETag": #""tag""#])
        let (api, _, auth) = try await client()
        _ = try await api.collectionEditor(id: "a/b", auth: auth)
        let url = try XCTUnwrap(stub.requests.last?.url)
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
                       "/api/v2/collections/a%2Fb")
    }

    // MARK: Cards

    func testPersonalCardsFollowOpaqueCursorAndNeverDecodeMembership() async throws {
        stub.sequence([
            .json(200, page(#"{"content_id":"film1","type":"movie","title":"Film"}"#, hasMore: true, next: "opaque-next")),
            .json(200, page("", hasMore: false)),
        ])
        let (api, _, auth) = try await client()
        let result = try await api.personalCollectionCards(id: "c1", imageSize: "w342", auth: auth)
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
            XCTAssertEqual(request.query["image_size"], "w342")
            XCTAssertNil(request.query["offset"])
            XCTAssertNil(request.query["sort"])
        }
        XCTAssertEqual(sent[1].query["cursor"], "opaque-next")
    }

    func testPersonalCardsRejectIncompletePage() async throws {
        stub.reply(200, page("", hasMore: true))
        let (api, _, auth) = try await client()
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
        let (api, tokens, auth) = try await client()
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
}
