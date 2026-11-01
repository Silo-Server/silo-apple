import Foundation
import XCTest
@testable import Silo

/// The Home Sections editor saves the profile's layout on the server: a
/// reorder or show/hide sends the whole override set and refreshes Home, and
/// a refused save puts the last saved layout back on screen unless a later
/// change is queued to carry it.
@MainActor
final class HomeSectionsEditorModelTests: XCTestCase {
    private var stub = APIv2TestStub()

    private func row(_ id: String, hidden: Bool = false) -> String {
        #"{"id":"\#(id)","section_type":"recently_added","title":"Row \#(id)","default_title":"Row \#(id)","featured":false,"item_limit":20,"hidden":\#(hidden),"is_custom":false,"customized":false,"position":0}"#
    }

    private func model() async throws -> HomeSectionsEditorModel {
        stub = APIv2TestStub()
        let name = "HomeSectionsEditorModelTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "home-editor-test")
        await tokens.setServerUrl("https://editor.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        var next = 0
        return HomeSectionsEditorModel(api: SiloAPI(http: http, tokenStore: tokens),
                                       newID: { next += 1; return "new-\(next)" })
    }

    private func serveLayout() {
        stub.reply(path: "/api/v2/profile/sections/settings", 200, #"{"items":[\#(row("a")),\#(row("b")),\#(row("c", hidden: true))]}"#)
        stub.reply(path: "/api/v2/profile/sections", 200,
            #"{"items":[{"id":"o-b","section_id":"b","position":1,"hidden":false,"removed":false,"section_type":"","title":"Mine","featured":null,"item_limit":null,"is_user_added":false,"user_section_type":"","user_title":"","created_at":null,"updated_at":null}]}"#)
    }

    private func savedOverrides() throws -> [[String: Any]] {
        let put = try XCTUnwrap(stub.requests.last { $0.method == "PUT" })
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(put.body)) as? [String: Any])
        return try XCTUnwrap(body["overrides"] as? [[String: Any]])
    }

    func testReorderSavesTheWholeLayoutAndRefreshesHome() async throws {
        let editor = try await model()
        serveLayout()
        await editor.load()
        XCTAssertEqual(editor.rows.map(\.id), ["a", "b", "c"])

        stub.sequence([.json(204, "")])
        let refreshed = expectation(forNotification: .homeSectionsShouldRefresh, object: nil)
        await editor.move(fromOffsets: IndexSet(integer: 0), toOffset: 3).value

        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertEqual(editor.rows.map(\.id), ["b", "c", "a"])
        XCTAssertNil(editor.saveError)
        let overrides = try savedOverrides()
        XCTAssertEqual(overrides.map { $0["id"] as? String }, ["o-b", "new-1", "new-2"])
        XCTAssertEqual(overrides.map { $0["section_id"] as? String }, ["b", "c", "a"])
        XCTAssertEqual(overrides.map { $0["position"] as? Int }, [0, 1, 2])
        XCTAssertEqual(overrides.map { $0["hidden"] as? Bool }, [false, true, false])
        XCTAssertEqual(overrides.first?["title"] as? String, "Mine")
    }

    func testMoveDownAndShowingARowSaveTheirChange() async throws {
        let editor = try await model()
        serveLayout()
        await editor.load()

        stub.sequence([.json(204, ""), .json(204, "")])
        await editor.move(id: "a", by: 1).value
        await editor.setHidden(false, id: "c").value

        XCTAssertEqual(editor.rows.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(editor.rows.map(\.hidden), [false, false, false])
        let overrides = try savedOverrides()
        XCTAssertEqual(overrides.map { $0["section_id"] as? String }, ["b", "a", "c"])
        XCTAssertEqual(overrides.map { $0["hidden"] as? Bool }, [false, false, false])
        // The second save reuses the override the first one created.
        XCTAssertEqual(overrides.map { $0["id"] as? String }, ["o-b", "new-1", "new-2"])
    }

    func testRefusedSaveShowsAnErrorAndRestoresTheSavedOrder() async throws {
        let editor = try await model()
        serveLayout()
        await editor.load()

        stub.sequence([.json(422, #"{"type":"https://siloserver.org/docs/api/v2/problems/validation_failed","title":"Validation failed","status":422,"detail":"Bad set."}"#)])
        await editor.move(fromOffsets: IndexSet(integer: 2), toOffset: 0).value

        XCTAssertEqual(editor.rows.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(editor.rows.map(\.hidden), [false, false, true])
        XCTAssertNotNil(editor.saveError)
    }

    func testAnEditQueuedBehindARefusedSaveStillSavesAndKeepsBothChanges() async throws {
        let editor = try await model()
        serveLayout()
        await editor.load()

        stub.sequence([.json(422, #"{"type":"https://siloserver.org/docs/api/v2/problems/validation_failed","title":"Validation failed","status":422,"detail":"Bad set."}"#), .json(204, "")])
        stub.hold(path: "/api/v2/profile/sections")
        let first = editor.move(id: "a", by: 1)
        await stub.waitUntilHeld()
        let second = editor.setHidden(true, id: "b")
        stub.release()
        await first.value
        await second.value

        XCTAssertEqual(stub.requests.filter { $0.method == "PUT" }.count, 2, "the queued edit must still save")
        XCTAssertEqual(editor.rows.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(editor.rows.map(\.hidden), [true, false, true])
        XCTAssertNil(editor.saveError, "the later save stored the refused change too")
        let overrides = try savedOverrides()
        XCTAssertEqual(overrides.map { $0["section_id"] as? String }, ["b", "a", "c"])
        XCTAssertEqual(overrides.map { $0["hidden"] as? Bool }, [true, false, true])
    }

    func testAnEditQueuedBehindASaveStillSavesAfterTheEditorCloses() async throws {
        var editor: HomeSectionsEditorModel? = try await model()
        serveLayout()
        await editor?.load()

        stub.sequence([.json(204, ""), .json(204, "")])
        stub.hold(path: "/api/v2/profile/sections")
        let first = try XCTUnwrap(editor).move(id: "a", by: 1)
        await stub.waitUntilHeld()
        let second = try XCTUnwrap(editor).setHidden(true, id: "b")
        editor = nil // Done or Back while the first save is in flight.
        stub.release()
        await first.value
        await second.value

        let puts = stub.requests.filter { $0.method == "PUT" }
        XCTAssertEqual(puts.count, 2, "the second edit must not be dropped")
        let overrides = try savedOverrides()
        XCTAssertEqual(overrides.map { $0["section_id"] as? String }, ["b", "a", "c"])
        XCTAssertEqual(overrides.map { $0["hidden"] as? Bool }, [true, false, true])
    }

    func testAReloadThatOverlapsAnEditKeepsTheEdit() async throws {
        let editor = try await model()
        serveLayout()
        await editor.load()

        stub.hold(path: "/api/v2/profile/sections/settings")
        let reload = Task { await editor.load() }
        await stub.waitUntilHeld()
        try await waitUntil("the reload's override read") {
            stub.requests.filter { $0.method == "GET" && $0.path == "/api/v2/profile/sections" }.count == 2
        }
        stub.sequence([.json(204, "")])
        let edit = editor.move(id: "a", by: 1)
        stub.release()
        await reload.value
        await edit.value

        XCTAssertEqual(editor.rows.map(\.id), ["b", "a", "c"])
        XCTAssertNil(editor.saveError)
        let overrides = try savedOverrides()
        XCTAssertEqual(overrides.map { $0["section_id"] as? String }, ["b", "a", "c"])
    }

    func testAReloadWaitsForAnEditQueuedWhileItWaitsForEarlierSaves() async throws {
        let editor = try await model()
        serveLayout()
        await editor.load()
        let settingsReads = {
            self.stub.requests.filter { $0.method == "GET" && $0.path == "/api/v2/profile/sections/settings" }.count
        }

        stub.sequence(path: "/api/v2/profile/sections", [.json(204, ""), .json(204, "")])
        stub.hold(path: "/api/v2/profile/sections")
        let first = editor.move(id: "a", by: 1)
        await stub.waitUntilHeld()
        let reload = Task { await editor.load() }
        await Task.yield() // the reload is now waiting for the first save
        let second = editor.setHidden(true, id: "b")
        // Let the first save land and park the second one.
        stub.release()
        stub.hold(path: "/api/v2/profile/sections")
        await first.value
        await stub.waitUntilHeld()

        let readWhileSaving = await eventually(timeout: .milliseconds(500)) { settingsReads() > 1 }
        XCTAssertFalse(readWhileSaving, "the reload read the layout while the edit queued during its wait was still saving")
        stub.release()
        await second.value
        await reload.value
        XCTAssertEqual(settingsReads(), 2)
    }

    func testFailedLoadIsReportedInsteadOfAnEmptyList() async throws {
        let editor = try await model()
        stub.reply(path: "/api/v2/profile/sections/settings", 503,
            #"{"type":"https://siloserver.org/docs/api/v2/problems/dependency_unavailable","title":"Unavailable","status":503,"detail":"Down"}"#)
        stub.reply(path: "/api/v2/profile/sections", 200, #"{"items":[]}"#)

        await editor.load()

        guard case .failed = editor.phase else { return XCTFail("expected a load failure, got \(editor.phase)") }
        XCTAssertTrue(editor.rows.isEmpty)
    }
}
