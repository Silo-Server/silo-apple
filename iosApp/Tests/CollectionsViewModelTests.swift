import Foundation
import XCTest
@testable import Silo

/// The personal-collections screen on v2: group controls follow the groups
/// capability (a failed read is retryable, not "unsupported"), and an edit
/// that conflicts or has an unknown outcome keeps the sheet and requires a
/// reload instead of being resent.
@MainActor
final class CollectionsViewModelTests: XCTestCase {
    private let collection = #"{"id":"c1","name":"Saved","collection_type":"manual","group_id":null}"#
    private var stub = APIv2TestStub()

    override func setUp() async throws {
        try await super.setUp()
        stub = APIv2TestStub()
        ResponseCache.shared.remove(CacheKey.collections)
    }

    override func tearDown() async throws {
        ResponseCache.shared.remove(CacheKey.collections)
        try await super.tearDown()
    }

    private func viewModel() async throws -> CollectionsViewModel {
        let name = "CollectionsViewModelTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "collections-vm-test")
        await tokens.setServerUrl("https://collections.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return CollectionsViewModel(api: SiloAPI(http: http, tokenStore: tokens))
    }

    private func capabilities(groups: Bool) -> String {
        #"{"revision":"r1","state":"available","allowed":true,"groups":\#(groups),"imports":false,"artwork":false,"item_reorder":false,"display_filter_fields":[],"display_filter_presets":{"watched":[],"media":[]},"collection_default_sort":false,"collection_sort_preferences":false,"effective_collection_sort":false,"sort_preference_kinds":[]}"#
    }

    private func listBody(groups: String = "") -> String {
        #"{"items":[\#(collection)],"groups":[\#(groups)]}"#
    }

    private func requests(_ method: String, path: String) -> [StubURLProtocol.Request] {
        stub.requests.filter { $0.method == method && $0.path == path }
    }

    // MARK: Groups capability

    func testFailedCapabilityReadLeavesARetryableStateThatHidesGroupControls() async throws {
        stub.reply(path: "/api/v2/collections", 200, listBody())
        stub.reply(path: "/api/v2/collections/capabilities", 503,
                   #"{"type":"https://siloserver.org/docs/api/v2/problems/dependency_unavailable","title":"Unavailable","status":503,"detail":"Down","instance":"urn:test"}"#)
        let model = try await viewModel()
        await model.loadCollections()

        XCTAssertEqual(model.collections.map(\.id), ["c1"], "the list still loads")
        guard case .unknown = model.groupSupport else {
            return XCTFail("a failed read is not a verdict, got \(model.groupSupport)")
        }
        XCTAssertFalse(model.canManageGroups)

        stub.reply(path: "/api/v2/collections/capabilities", 200, capabilities(groups: true))
        await model.retryGroupSupport()
        XCTAssertEqual(model.groupSupport, .available)
        XCTAssertTrue(model.canManageGroups)
    }

    func testStoreWithoutGroupsHidesGroupControlsAndA501ConfirmsIt() async throws {
        stub.reply(path: "/api/v2/collections", 200, listBody())
        stub.reply(path: "/api/v2/collections/capabilities", 200, capabilities(groups: false))
        let model = try await viewModel()
        await model.loadCollections()
        XCTAssertEqual(model.groupSupport, .unavailable)
        XCTAssertFalse(model.canManageGroups)

        // A capability that changed after the read: the 501 wins.
        stub.reply(path: "/api/v2/collections/capabilities", 200, capabilities(groups: true))
        await model.retryGroupSupport()
        stub.reply(path: "/api/v2/collections/groups", 501,
                   #"{"type":"https://siloserver.org/docs/api/v2/problems/capability_unsupported","title":"Capability unsupported","status":501,"detail":"The acting account does not support collection groups","instance":"urn:test"}"#)
        model.pendingGroupAction = .create
        await model.createGroup(name: "Seasonal")
        XCTAssertEqual(model.groupSupport, .unavailable)
        XCTAssertNotNil(model.groupError)
        XCTAssertEqual(requests("POST", path: "/api/v2/collections/groups").count, 1)
    }

    // MARK: Editors

    func testStaleMoveKeepsTheSheetAndSendsOnlyAfterReload() async throws {
        stub.reply(path: "/api/v2/collections", 200, listBody(groups: #"{"id":"g1","name":"G","slug":"g","default_sort_mode":"manual","sort_order":0}"#))
        stub.reply(path: "/api/v2/collections/capabilities", 200, capabilities(groups: true))
        let model = try await viewModel()
        await model.loadCollections()
        let target = try XCTUnwrap(model.collections.first)

        model.pendingGroupAction = .move(target)
        stub.sequence([.json(200, collection, headers: ["ETag": #""v1""#])])
        await model.loadEditor()
        XCTAssertTrue(model.canSubmitGroupAction)

        stub.sequence([.json(412, #"{"type":"https://siloserver.org/docs/api/v2/problems/stale_version","title":"Conflict","status":412,"detail":"Changed","instance":"urn:test"}"#)])
        await model.moveCollection(id: "c1", toGroupId: "g1")
        XCTAssertNotNil(model.pendingGroupAction, "the sheet stays open with the chosen target")
        XCTAssertTrue(model.editorNeedsReload)
        XCTAssertFalse(model.canSubmitGroupAction)

        await model.moveCollection(id: "c1", toGroupId: "g1")
        XCTAssertEqual(requests("PATCH", path: "/api/v2/collections/c1").count, 1, "no resend before a reload")

        stub.sequence([.json(200, collection, headers: ["ETag": #""v2""#])])
        await model.loadEditor()
        XCTAssertFalse(model.editorNeedsReload)
        let moved = #"{"id":"c1","name":"Saved","collection_type":"manual","group_id":"g1"}"#
        stub.sequence([.json(200, moved, headers: ["ETag": #""v3""#])])
        await model.moveCollection(id: "c1", toGroupId: "g1")

        let patches = requests("PATCH", path: "/api/v2/collections/c1")
        XCTAssertEqual(patches.map { $0.header("if-match") }, [#""v1""#, #""v2""#])
        XCTAssertNil(model.pendingGroupAction)
        XCTAssertEqual(model.collections.first?.groupId, "g1")
    }

    func testUnknownOutcomeHoldsTheEditUntilReload() async throws {
        stub.reply(path: "/api/v2/collections", 200, listBody())
        stub.reply(path: "/api/v2/collections/capabilities", 200, capabilities(groups: true))
        let model = try await viewModel()
        await model.loadCollections()
        let target = try XCTUnwrap(model.collections.first)

        model.pendingGroupAction = .deleteCollection(target)
        stub.sequence([.json(200, collection, headers: ["ETag": #""v1""#]), .failure(URLError(.networkConnectionLost))])
        await model.loadEditor()
        await model.deleteCollection(id: "c1")

        XCTAssertNotNil(model.pendingGroupAction)
        XCTAssertTrue(model.editorNeedsReload)
        XCTAssertEqual(model.collections.map(\.id), ["c1"], "nothing is removed on an unknown outcome")
        await model.deleteCollection(id: "c1")
        XCTAssertEqual(requests("DELETE", path: "/api/v2/collections/c1").count, 1, "never replayed")

        // The reload finds the collection gone: the earlier delete landed.
        stub.reply(path: "/api/v2/collections/c1", 404,
                   #"{"type":"https://siloserver.org/docs/api/v2/problems/not_found","title":"Not Found","status":404,"detail":"Gone","instance":"urn:test"}"#)
        stub.reply(path: "/api/v2/collections", 200, #"{"items":[],"groups":[]}"#)
        await model.loadEditor()
        XCTAssertNil(model.pendingGroupAction)
        XCTAssertTrue(model.collections.isEmpty)
    }

    private let group = #"{"id":"g1","name":"G","slug":"g","default_sort_mode":"manual","sort_order":0}"#
    private let notFound = #"{"type":"https://siloserver.org/docs/api/v2/problems/not_found","title":"Not Found","status":404,"detail":"Gone","instance":"urn:test"}"#

    /// Starts a collection delete whose answer is held, dismisses its sheet,
    /// opens a group rename with a loaded editor, then delivers `reply`.
    private func deleteAnsweredAfterTheNextSheetOpened(_ reply: APIv2TestStub.Reply) async throws -> CollectionsViewModel {
        stub.reply(path: "/api/v2/collections", 200, listBody(groups: group))
        stub.reply(path: "/api/v2/collections/capabilities", 200, capabilities(groups: true))
        let model = try await viewModel()
        await model.loadCollections()
        let target = try XCTUnwrap(model.collections.first)
        let renamed = try XCTUnwrap(model.groups.first)

        model.pendingGroupAction = .deleteCollection(target)
        stub.sequence([.json(200, collection, headers: ["ETag": #""v1""#])])
        await model.loadEditor()
        stub.sequence([reply])
        stub.hold()
        let write = Task { await model.deleteCollection(id: "c1") }
        await stub.waitUntilHeld()

        model.pendingGroupAction = nil
        model.pendingGroupAction = .rename(renamed)
        stub.sequence([.json(200, group, headers: ["ETag": #""g-v1""#])])
        await model.loadEditor()
        XCTAssertFalse(model.canSubmitGroupAction, "one write at a time, even across sheets")

        stub.release()
        await write.value
        return model
    }

    private func assertRenameSheetUntouched(_ model: CollectionsViewModel, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(model.pendingGroupAction?.id, "rename:g1", "the next sheet stays open", file: file, line: line)
        XCTAssertNil(model.groupError, file: file, line: line)
        XCTAssertFalse(model.editorNeedsReload, file: file, line: line)
        XCTAssertTrue(model.canSubmitGroupAction, file: file, line: line)
    }

    func testUnknownOutcomeFromADismissedSheetRereadsTheListAndLeavesTheNextSheetAlone() async throws {
        let listReads = { self.requests("GET", path: "/api/v2/collections").count }
        let model = try await deleteAnsweredAfterTheNextSheetOpened(.failure(URLError(.networkConnectionLost)))
        assertRenameSheetUntouched(model)
        XCTAssertEqual(listReads(), 2, "the delete may have landed, so the list is read again")
    }

    func testSuccessFromADismissedSheetUpdatesTheListButKeepsTheNextSheetOpen() async throws {
        let model = try await deleteAnsweredAfterTheNextSheetOpened(.json(204, ""))
        assertRenameSheetUntouched(model)
        XCTAssertTrue(model.collections.isEmpty)
    }

    func testConflictFromADismissedSheetLeavesTheNextSheetAlone() async throws {
        let model = try await deleteAnsweredAfterTheNextSheetOpened(.json(412,
            #"{"type":"https://siloserver.org/docs/api/v2/problems/stale_version","title":"Conflict","status":412,"detail":"Changed","instance":"urn:test"}"#))
        assertRenameSheetUntouched(model)
    }

    func testEditThatFindsTheItemGoneClosesTheSheetAndRereadsTheList() async throws {
        stub.reply(path: "/api/v2/collections", 200, listBody(groups: group))
        stub.reply(path: "/api/v2/collections/capabilities", 200, capabilities(groups: true))
        let model = try await viewModel()
        await model.loadCollections()
        let target = try XCTUnwrap(model.collections.first)

        // Deleted on another device after this sheet read its version.
        model.pendingGroupAction = .move(target)
        stub.sequence([.json(200, collection, headers: ["ETag": #""v1""#]), .json(404, notFound)])
        await model.loadEditor()
        stub.reply(path: "/api/v2/collections", 200, #"{"items":[],"groups":[\#(group)]}"#)
        await model.moveCollection(id: "c1", toGroupId: "g1")

        XCTAssertNil(model.pendingGroupAction, "a 404 closes the sheet, as it does on Reload")
        XCTAssertTrue(model.collections.isEmpty)
        XCTAssertEqual(requests("GET", path: "/api/v2/collections").count, 2)
        XCTAssertEqual(requests("PATCH", path: "/api/v2/collections/c1").count, 1)
    }

    func testTransportFailuresBeforeDispatchAreDefinite() {
        XCTAssertFalse(CollectionsViewModel.outcomeIsUncertain(URLError(.notConnectedToInternet)))
        XCTAssertFalse(CollectionsViewModel.outcomeIsUncertain(HTTPError.requestIdentityChanged))
        XCTAssertFalse(CollectionsViewModel.outcomeIsUncertain(APIv2Error.httpStatus(500)))
        XCTAssertTrue(CollectionsViewModel.outcomeIsUncertain(URLError(.timedOut)))
        XCTAssertTrue(CollectionsViewModel.outcomeIsUncertain(HTTPError.network(underlying: URLError(.networkConnectionLost))))
        XCTAssertTrue(CollectionsViewModel.outcomeIsUncertain(APIv2Error.httpStatus(200)),
                      "an accepted write with an unexpected answer may have been applied")
    }
}
