import Foundation
import XCTest
@testable import Silo

final class ProfileHomeLayoutTests: XCTestCase {
    private func makeRow(
        id: String,
        type: String = "recently_added",
        title: String = "Recently Added",
        featured: Bool = false,
        itemLimit: Int = 20,
        hidden: Bool = false,
        isCustom: Bool = false,
        position: Int = 0,
        config: [String: SettingJSONValue]? = nil
    ) -> APIv2ProfileSectionSetting {
        APIv2ProfileSectionSetting(
            id: id,
            sectionType: type,
            title: title,
            defaultTitle: title,
            featured: featured,
            itemLimit: itemLimit,
            hidden: hidden,
            isCustom: isCustom,
            customized: isCustom || hidden,
            position: position,
            config: config
        )
    }

    func testHidingAdminRowWithoutReorderingDoesNotPinPositions() {
        let a = makeRow(id: "sec-a", title: "Continue Watching", position: 0)
        let b = makeRow(id: "sec-b", title: "Recently Added", position: 1)
        var bHidden = b
        bHidden.hidden = true

        let overrides = ProfileHomeLayout.overrides(
            rows: [a, bHidden],
            baseline: [a, b],
            saved: [],
            newID: { "ovr-1" }
        )

        XCTAssertEqual(overrides.count, 1)
        XCTAssertEqual(overrides[0].sectionId, "sec-b")
        XCTAssertNil(overrides[0].position)
        XCTAssertTrue(overrides[0].hidden)
        XCTAssertFalse(overrides[0].isUserAdded)
    }

    func testReorderingAdminRowsPinsAllPositions() {
        let a = makeRow(id: "sec-a", position: 0)
        let b = makeRow(id: "sec-b", position: 1)
        var counter = 0

        let overrides = ProfileHomeLayout.overrides(
            rows: [b, a],
            baseline: [a, b],
            saved: [],
            newID: {
                counter += 1
                return "ovr-\(counter)"
            }
        )

        XCTAssertEqual(overrides.map(\.sectionId), ["sec-b", "sec-a"])
        XCTAssertEqual(overrides.map(\.position), [0, 1])
    }

    func testAddingCustomRowPersistsFeaturedItemLimitAndConfigWithoutPinningAdminOrder() {
        let adminRow = makeRow(id: "sec-a", position: 0)
        let customRow = makeRow(
            id: "custom-1",
            type: "format_showcase",
            title: "Dolby Vision Picks",
            featured: true,
            itemLimit: 30,
            hidden: false,
            isCustom: true,
            position: 1,
            config: ["format": .string("dolby_vision")]
        )

        let overrides = ProfileHomeLayout.overrides(
            rows: [adminRow, customRow],
            baseline: [adminRow],
            saved: [],
            newID: { "unused" }
        )

        XCTAssertEqual(overrides.count, 1)
        let added = overrides[0]
        XCTAssertEqual(added.id, "custom-1")
        XCTAssertEqual(added.sectionId, "")
        XCTAssertTrue(added.isUserAdded)
        XCTAssertEqual(added.userSectionType, "format_showcase")
        XCTAssertEqual(added.userTitle, "Dolby Vision Picks")
        XCTAssertEqual(added.featured, true)
        XCTAssertEqual(added.itemLimit, 30)
        XCTAssertEqual(added.position, 1)
        XCTAssertEqual(added.userConfig?["format"], .string("dolby_vision"))
    }

    func testRemovingCustomRowOmitsItsOverrideWhileKeepingRemovedAdminOverrides() {
        let adminRow = makeRow(id: "sec-a", position: 0)
        let customRow = makeRow(id: "custom-1", isCustom: true, position: 1)
        let saved: [APIv2SectionOverride] = [
            APIv2SectionOverride(
                id: "custom-1",
                sectionId: "",
                position: 1,
                hidden: false,
                isUserAdded: true,
                userSectionType: "hidden_gems",
                userTitle: "Hidden Gems"
            ),
            APIv2SectionOverride(
                id: "ovr-removed",
                sectionId: "sec-removed",
                position: nil,
                hidden: false,
                removed: true
            ),
        ]

        let overrides = ProfileHomeLayout.overrides(
            rows: [adminRow],
            baseline: [adminRow, customRow],
            saved: saved,
            newID: { "unused" }
        )

        XCTAssertEqual(overrides.map(\.id), ["ovr-removed"])
        XCTAssertTrue(overrides[0].removed)
    }

    func testPinnedAndMatchingCollectionRowDistinguishPersonalAndServerCollections() {
        let personal = ProfileHomeLayout.makeCollectionRow(
            id: "row-u",
            title: "My Sci-Fi",
            collectionId: "col-1",
            isUserCollection: true,
            position: 0,
            itemLimit: 25,
            featured: true
        )
        var serverHidden = ProfileHomeLayout.makeCollectionRow(
            id: "row-l",
            title: "Marvel",
            collectionId: "col-1",
            isUserCollection: false,
            position: 1
        )
        serverHidden.hidden = true

        let rows = [personal, serverHidden]

        XCTAssertEqual(
            ProfileHomeLayout.pinnedCollectionRow(collectionId: "col-1", isUserCollection: true, in: rows)?.id,
            "row-u"
        )
        XCTAssertNil(
            ProfileHomeLayout.pinnedCollectionRow(collectionId: "col-1", isUserCollection: false, in: rows)
        )
        XCTAssertEqual(
            ProfileHomeLayout.matchingCollectionRow(collectionId: "col-1", isUserCollection: false, in: rows)?.id,
            "row-l"
        )
        XCTAssertEqual(personal.itemLimit, 25)
        XCTAssertTrue(personal.featured)
    }

    func testOverrideEncodingOmitsEmptySectionIdAndNilConfigObjects() throws {
        let override = APIv2SectionOverride(
            id: "custom-1",
            sectionId: "",
            position: 0,
            hidden: false,
            featured: true,
            itemLimit: 15,
            isUserAdded: true,
            userSectionType: "mood_collection",
            userTitle: "Date Night",
            config: nil,
            userConfig: ["mood": .string("date_night")]
        )

        let data = try JSONEncoder().encode(override)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["section_id"])
        XCTAssertNil(json["config"])
        XCTAssertEqual(json["is_user_added"] as? Bool, true)
        XCTAssertEqual(json["user_section_type"] as? String, "mood_collection")
        XCTAssertEqual(json["user_title"] as? String, "Date Night")
        XCTAssertEqual(json["featured"] as? Bool, true)
        XCTAssertEqual(json["item_limit"] as? Int, 15)
        XCTAssertEqual((json["user_config"] as? [String: String])?["mood"], "date_night")
    }

    @MainActor
    func testReorderVisibleSlotsKeepsHiddenRowsAnchored() {
        let a = makeRow(id: "sec-a", position: 0)
        let h = makeRow(id: "sec-h", hidden: true, position: 1)
        let b = makeRow(id: "sec-b", position: 2)

        // Swapping visible rows A and B keeps hidden row H anchored at index 1.
        let swapped = HomeSectionsEditorModel.reorderVisibleSlots(in: [a, h, b]) { visible in
            visible.swapAt(0, 1)
            return true
        }
        XCTAssertEqual(swapped?.map(\.id), ["sec-b", "sec-h", "sec-a"])
    }

    @MainActor
    func testMoveToBottomOnLastVisibleRowIsNoOpAndSendsNoSave() async throws {
        let stub = APIv2TestStub()
        let name = "ProfileHomeLayoutTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(
            keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokens.switchActiveServer(serverId: "layout-test")
        await tokens.setServerUrl("https://layout.example")
        await tokens.setProfileId("profile-one")
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let identity = HTTPRequestIdentity(
            serverId: "layout-test",
            serverURL: "https://layout.example",
            profileId: "profile-one",
            clientFamily: "ios"
        )

        let settingsJSON = """
        {"items":[
          {"id":"sec-a","section_type":"recently_added","title":"A","default_title":"A","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":0},
          {"id":"sec-h","section_type":"recently_added","title":"H","default_title":"H","featured":false,"item_limit":20,"hidden":true,"is_custom":false,"customized":true,"position":1},
          {"id":"sec-b","section_type":"recently_added","title":"B","default_title":"B","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":2}
        ]}
        """
        let overridesJSON = #"{"items":[{"id":"ovr-h","section_id":"sec-h","hidden":true,"removed":false,"section_type":"","title":"","is_user_added":false,"user_section_type":"","user_title":""}]}"#
        stub.reply(path: "/api/v2/profile/sections/settings", 200, settingsJSON)
        stub.reply(path: "/api/v2/profile/sections", 200, overridesJSON)

        let editor = HomeSectionsEditorModel(scope: .home, api: api, requestIdentity: { identity })
        let loaded = await editor.load()
        XCTAssertTrue(loaded)
        XCTAssertEqual(editor.rows.map(\.id), ["sec-a", "sec-h", "sec-b"])

        let requestCountAfterLoad = stub.requests.count
        await editor.moveToBottom(id: "sec-b").value

        XCTAssertEqual(editor.rows.map(\.id), ["sec-a", "sec-h", "sec-b"])
        XCTAssertEqual(stub.requests.count, requestCountAfterLoad)
    }

    func testAddingCustomRowAfterHiddenAdminRowDoesNotPinAdminOrder() throws {
        let a = makeRow(id: "sec-a", position: 0)
        let h = makeRow(id: "sec-h", hidden: true, position: 1)
        let b = makeRow(id: "sec-b", position: 2)
        let custom = makeRow(id: "custom-1", isCustom: true, position: 3)

        let overrides = ProfileHomeLayout.overrides(
            rows: [a, h, b, custom],
            baseline: [a, h, b],
            saved: [APIv2SectionOverride(id: "ovr-h", sectionId: "sec-h", position: nil, hidden: true)],
            newID: { "unused" }
        )

        let adminHidden = try XCTUnwrap(overrides.first { $0.sectionId == "sec-h" })
        XCTAssertTrue(adminHidden.hidden)
        XCTAssertNil(adminHidden.position)
        XCTAssertNil(overrides.first { $0.sectionId == "sec-a" })
        XCTAssertNil(overrides.first { $0.sectionId == "sec-b" })
        XCTAssertEqual(overrides.first { $0.id == "custom-1" }?.position, 3)
    }

    @MainActor
    func testApplyingVisibleOrderPreservesRestoredVisibilityAndHiddenSlots() {
        let a = makeRow(id: "sec-a", position: 0)
        let c = makeRow(id: "sec-c", position: 1)
        let h = makeRow(id: "sec-h", hidden: true, position: 2)
        let b = makeRow(id: "sec-b", position: 3)
        let d = makeRow(id: "sec-d", position: 4)

        // Simulates hiding C (failed -> C restored at index 1 in committedRows) while D was dragged and returned.
        let noop = HomeSectionsEditorModel.applyingVisibleOrder(
            ["sec-a", "sec-b", "sec-d"],
            to: [a, c, h, b, d]
        )
        XCTAssertEqual(noop.map(\.id), ["sec-a", "sec-c", "sec-h", "sec-b", "sec-d"])

        // Dragging D above B reorders only the drafted rows while keeping restored C and hidden H anchored.
        let reordered = HomeSectionsEditorModel.applyingVisibleOrder(
            ["sec-a", "sec-d", "sec-b"],
            to: [a, c, h, b, d]
        )
        XCTAssertEqual(reordered.map(\.id), ["sec-a", "sec-c", "sec-h", "sec-d", "sec-b"])
        XCTAssertEqual(reordered.map(\.hidden), [false, false, true, false, false])
    }

    @MainActor
    func testMoveVisibleToTopKeepsHiddenRowsAnchored() {
        let a = makeRow(id: "sec-a", position: 0)
        let h = makeRow(id: "sec-h", hidden: true, position: 1)
        let b = makeRow(id: "sec-b", position: 2)

        let moved = HomeSectionsEditorModel.reorderVisibleSlots(in: [a, h, b]) { visible in
            guard let visibleIndex = visible.firstIndex(where: { $0.id == "sec-b" }),
                  visibleIndex > 0 else { return false }
            let row = visible.remove(at: visibleIndex)
            visible.insert(row, at: 0)
            return true
        }

        XCTAssertEqual(moved?.map(\.id), ["sec-b", "sec-h", "sec-a"])
        XCTAssertEqual(moved?.map(\.hidden), [false, true, false])
    }

    @MainActor
    func testRecipePresenceDistinguishesUnfilteredFromFilteredRows() {
        let filteredWatchlist = makeRow(
            id: "wl-movies",
            type: "watchlist",
            config: ["media_type": .string("movie")]
        )
        let libraryRestrictedWatchlist = makeRow(
            id: "wl-movies-lib7",
            type: "watchlist",
            config: ["media_type": .string("movie"), "filter_library_ids": .array([.int(7)])]
        )
        let unfilteredWatchlist = makeRow(
            id: "wl-all",
            type: "watchlist",
            config: nil
        )

        XCTAssertFalse(HomeSectionsEditorModel.matchesRecipe(filteredWatchlist, sectionType: "watchlist", params: [:]))
        XCTAssertTrue(HomeSectionsEditorModel.matchesRecipe(filteredWatchlist, sectionType: "watchlist", params: ["media_type": .string("movie")]))
        XCTAssertFalse(HomeSectionsEditorModel.matchesRecipe(libraryRestrictedWatchlist, sectionType: "watchlist", params: ["media_type": .string("movie")]))
        XCTAssertTrue(HomeSectionsEditorModel.matchesRecipe(
            libraryRestrictedWatchlist,
            sectionType: "watchlist",
            params: ["media_type": .string("movie"), "filter_library_ids": .array([.int(7)])]
        ))
        XCTAssertTrue(HomeSectionsEditorModel.matchesRecipe(unfilteredWatchlist, sectionType: "watchlist", params: [:]))
        XCTAssertFalse(HomeSectionsEditorModel.matchesRecipe(unfilteredWatchlist, sectionType: "watchlist", params: ["media_type": .string("movie")]))
    }

    @MainActor
    func testUncertainLayoutSavePreservesAndRebasesNewerQueuedEdit() async throws {
        let stub = APIv2TestStub()
        let name = "ProfileHomeLayoutTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(
            keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokens.switchActiveServer(serverId: "layout-test")
        await tokens.setServerUrl("https://layout.example")
        await tokens.setProfileId("profile-one")
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let identity = HTTPRequestIdentity(
            serverId: "layout-test",
            serverURL: "https://layout.example",
            profileId: "profile-one",
            clientFamily: "ios"
        )

        let initialSettings = """
        {"items":[
          {"id":"sec-a","section_type":"recently_added","title":"A","default_title":"A","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":0},
          {"id":"sec-b","section_type":"recently_added","title":"B","default_title":"B","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":1},
          {"id":"sec-c","section_type":"recently_added","title":"C","default_title":"C","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":2}
        ]}
        """
        let initialOverrides = #"{"items":[]}"#
        stub.reply(path: "/api/v2/profile/sections/settings", 200, initialSettings)
        stub.reply(path: "/api/v2/profile/sections", 200, initialOverrides)

        let editor = HomeSectionsEditorModel(scope: .home, api: api, requestIdentity: { identity })
        let loaded = await editor.load()
        XCTAssertTrue(loaded)

        // Authoritative reload reflects that PUT #1 (hiding sec-a) committed on the server
        // before the response was lost.
        let reloadedSettings = """
        {"items":[
          {"id":"sec-a","section_type":"recently_added","title":"A","default_title":"A","featured":false,"item_limit":20,"hidden":true,"is_custom":false,"customized":true,"position":0},
          {"id":"sec-b","section_type":"recently_added","title":"B","default_title":"B","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":1},
          {"id":"sec-c","section_type":"recently_added","title":"C","default_title":"C","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":2}
        ]}
        """
        let reloadedOverrides = #"{"items":[{"id":"ovr-a","section_id":"sec-a","hidden":true,"removed":false,"section_type":"","title":"","is_user_added":false,"user_section_type":"","user_title":""}]}"#

        stub.reply(path: "/api/v2/profile/sections/settings", 200, reloadedSettings)
        // Sequence on /api/v2/profile/sections:
        // 1) PUT #1 loses connection (uncertain outcome)
        // 2) GET during reloadAfterReset returns reloadedOverrides
        // 3) PUT #2 (rebased Edit 2) succeeds with 200
        stub.sequence(path: "/api/v2/profile/sections", [
            .failure(URLError(.networkConnectionLost)),
            .json(200, reloadedOverrides),
            .json(200, "{}"),
        ])
        stub.hold(path: "/api/v2/profile/sections")

        let edit1 = editor.setHidden(true, id: "sec-a")
        await stub.waitUntilHeld()

        // Queue Edit 2 while PUT #1 is still in flight.
        let edit2 = editor.setHidden(true, id: "sec-b")
        stub.release()

        await edit1.value
        await edit2.value

        XCTAssertEqual(editor.phase, .loaded)
        XCTAssertNotNil(editor.saveError)
        XCTAssertEqual(editor.rows.map(\.hidden), [true, true, false])
        let putRequests = stub.requests.filter { $0.method == "PUT" && $0.path == "/api/v2/profile/sections" }
        XCTAssertEqual(putRequests.count, 2)
        // Done stays open once when an earlier edit in the waited batch failed,
        // then closes on a second tap once the user has seen the error.
        let firstDone = await editor.waitForPendingSaves()
        XCTAssertFalse(firstDone)
        let secondDone = await editor.waitForPendingSaves()
        XCTAssertTrue(secondDone)
    }

    @MainActor
    func testPerformQuickActionAbortsWhenIdentityChanges() async throws {
        let stub = APIv2TestStub()
        let name = "ProfileHomeLayoutTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(
            keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokens.switchActiveServer(serverId: "layout-test")
        await tokens.setServerUrl("https://layout.example")
        await tokens.setProfileId("profile-one")
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        var currentIdentity = HTTPRequestIdentity(
            serverId: "layout-test",
            serverURL: "https://layout.example",
            profileId: "profile-one",
            clientFamily: "ios"
        )
        let settingsJSON = """
        {"items":[
          {"id":"sec-a","section_type":"recently_added","title":"A","default_title":"A","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":0}
        ]}
        """
        stub.reply(path: "/api/v2/profile/sections/settings", 200, settingsJSON)
        stub.reply(path: "/api/v2/profile/sections", 200, #"{"items":[]}"#)
        stub.hold(path: "/api/v2/profile/sections/settings")

        var onNextIdentityRead: (() -> Void)?
        let editor = HomeSectionsEditorModel(scope: .home, api: api, requestIdentity: {
            if let signal = onNextIdentityRead {
                onNextIdentityRead = nil
                signal()
            }
            return currentIdentity
        })

        let first = Task {
            await editor.performQuickAction { $0.setHidden(true, id: "sec-a") }
        }
        await stub.waitUntilHeld()

        var secondMutationRan = false
        var secondTask: Task<HomeSectionsEditorModel.QuickActionResult, Never>?
        await withCheckedContinuation { continuation in
            onNextIdentityRead = { continuation.resume() }
            secondTask = Task {
                await editor.performQuickAction { model in
                    secondMutationRan = true
                    return model.setHidden(true, id: "sec-a")
                }
            }
        }
        let second = try XCTUnwrap(secondTask)

        // Switch profile only after `second` has deterministically captured `profile-one`.
        currentIdentity = HTTPRequestIdentity(
            serverId: "layout-test",
            serverURL: "https://layout.example",
            profileId: "profile-two",
            clientFamily: "ios"
        )
        stub.release()

        let firstResult = await first.value
        let secondResult = await second.value

        XCTAssertFalse(firstResult.succeeded)
        XCTAssertFalse(secondResult.succeeded)
        XCTAssertNil(secondResult.errorMessage)
        XCTAssertFalse(secondMutationRan)
        XCTAssertTrue(stub.requests.filter { $0.method == "PUT" }.isEmpty)
    }

    @MainActor
    func testHomePreferencesPreservesAndRetriesQueuedWriteAfterAuthorizationRecovery() async throws {
        let identity = HTTPRequestIdentity(
            serverId: "prefs-test",
            serverURL: "https://prefs.example",
            profileId: "profile-one",
            clientFamily: "ios"
        )
        let scopedTransport = FakeHomePreferencesTransport()
        let writeTransport = FakeHomePreferencesWriteTransport()
        let writer = ProfileSettingsWriter(
            transport: writeTransport,
            sleep: { _ in }
        )
        let model = HomePreferencesModel(
            transport: scopedTransport,
            writer: writer,
            requestIdentity: { identity }
        )

        await model.load()
        XCTAssertTrue(model.isAuthorized)
        XCTAssertFalse(model.hideWatchedItems)
        guard model.canEdit(.homeHideWatchedItems) else {
            XCTFail("Expected homeHideWatchedItems to be editable after load")
            return
        }

        // Hold Write 1 in flight, enqueue Write 2 behind it, then transiently fail a refresh
        // so Write 2 sees authorization unavailable when it wakes up.
        let writeHeldExpectation = expectation(description: "first preference write held in flight")
        defer { writeTransport.releaseHeldWrite() }
        writeTransport.holdNextWrite(onHeld: { writeHeldExpectation.fulfill() })
        model.setHideWatchedItems(true)
        await fulfillment(of: [writeHeldExpectation], timeout: 2.0)

        model.setHideWatchedItems(false)

        scopedTransport.capabilities = .failed(.transport(description: "offline"))
        await model.load()
        XCTAssertFalse(model.isAuthorized)

        // Restore capabilities before releasing Write 1; the server still reports `true`
        // (old value) during recovery so we prove recovery does NOT discard Write 2 (`false`).
        scopedTransport.capabilities = .available(FakeHomePreferencesTransport.makeCapabilities())
        scopedTransport.hideWatchedItems = true
        writeTransport.releaseHeldWrite()

        // Wait for recovery load and automatic retry of Write 2 to complete.
        for _ in 0..<100 {
            if model.isAuthorized,
               !model.hasReconcilingKeys,
               writeTransport.writtenValues.last == .bool(false) {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(model.isAuthorized)
        XCTAssertFalse(model.hasReconcilingKeys)
        XCTAssertFalse(model.hideWatchedItems)
        XCTAssertEqual(writeTransport.writtenValues.last, .bool(false))
    }

    @MainActor
    func testAddToCollectionWaitForPendingMutationsKeepsSheetOpenOnceOnFailure() async throws {
        let stub = APIv2TestStub()
        let name = "ProfileHomeLayoutTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(
            keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokens.switchActiveServer(serverId: "collection-test")
        await tokens.setServerUrl("https://collection.example")
        await tokens.setProfileId("profile-one")
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let identity = HTTPRequestIdentity(
            serverId: "collection-test",
            serverURL: "https://collection.example",
            profileId: "profile-one",
            clientFamily: "ios"
        )

        let collectionsJSON = """
        {"items":[
          {"id":"col-1","name":"Favorites","collection_type":"manual","item_count":2}
        ],"groups":[]}
        """
        stub.reply(path: "/api/v2/collections", 200, collectionsJSON)
        stub.reply(path: "/api/v2/catalog/items/movie-42/collections", 200, #"{"items":[]}"#)

        let model = AddToCollectionModel(
            contentId: "movie-42",
            api: api,
            requestIdentity: { identity }
        )
        await model.load()
        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(model.entries.count, 1)

        let itemPath = "/api/v2/collections/col-1/items/movie-42"
        stub.sequence(path: itemPath, [
            .json(500, #"{"error":{"code":"internal","message":"server error"}}"#),
            .json(204, ""),
        ])
        stub.hold(path: itemPath)

        let failedToggle = Task { await model.toggle(collectionId: "col-1") }
        await stub.waitUntilHeld()
        XCTAssertTrue(model.hasPendingMutations)

        let waitOnFailure = Task { await model.waitForPendingMutations() }
        stub.release()

        await failedToggle.value
        let settledAfterFailure = await waitOnFailure.value
        XCTAssertFalse(settledAfterFailure)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.hasPendingMutations)
        XCTAssertEqual(model.entries.first?.containsItem, false)

        // Second Done tap with no new failure acknowledges the error and closes cleanly.
        let acknowledged = await model.waitForPendingMutations()
        XCTAssertTrue(acknowledged)

        // A subsequent successful mutation settles and allows Done to dismiss.
        stub.hold(path: itemPath)
        let succeededToggle = Task { await model.toggle(collectionId: "col-1") }
        await stub.waitUntilHeld()
        let waitOnSuccess = Task { await model.waitForPendingMutations() }
        stub.release()

        await succeededToggle.value
        let settledAfterSuccess = await waitOnSuccess.value
        XCTAssertTrue(settledAfterSuccess)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.entries.first?.containsItem, true)
    }

    @MainActor
    func testForegroundLoadDoesNotDropInFlightQuickAction() async throws {
        let stub = APIv2TestStub()
        let name = "ProfileHomeLayoutTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(
            keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokens.switchActiveServer(serverId: "quick-action-test")
        await tokens.setServerUrl("https://quick.example")
        await tokens.setProfileId("profile-one")
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let identity = HTTPRequestIdentity(
            serverId: "quick-action-test",
            serverURL: "https://quick.example",
            profileId: "profile-one",
            clientFamily: "ios"
        )

        let settingsJSON = """
        {"items":[
          {"id":"sec-a","section_type":"recently_added","title":"A","default_title":"A","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":0}
        ]}
        """
        stub.reply(path: "/api/v2/profile/sections/settings", 200, settingsJSON)
        stub.reply(path: "/api/v2/profile/sections", 200, #"{"items":[]}"#)
        stub.hold(path: "/api/v2/profile/sections/settings")

        let editor = HomeSectionsEditorModel(scope: .home, api: api, requestIdentity: { identity })
        let quickAction = Task {
            await editor.performQuickAction { $0.setHidden(true, id: "sec-a") }
        }
        await stub.waitUntilHeld()

        // Opening Customize mode calls `load()` while the quick action's read is in flight.
        let foregroundLoad = Task { await editor.load() }
        await Task.yield()
        stub.release()

        let result = await quickAction.value
        let loaded = await foregroundLoad.value
        XCTAssertTrue(result.succeeded)
        XCTAssertNil(result.errorMessage)
        XCTAssertTrue(loaded)
        let putRequests = stub.requests.filter { $0.method == "PUT" && $0.path == "/api/v2/profile/sections" }
        XCTAssertEqual(putRequests.count, 1)
    }
}

@MainActor
private final class FakeHomePreferencesTransport: ProfileScopedSettingTransport, @unchecked Sendable {
    var capabilities: SettingsCapabilitiesResult = .available(FakeHomePreferencesTransport.makeCapabilities())
    var hideWatchedItems = false

    static func makeCapabilities() -> APIv2SettingsContractCapabilities {
        APIv2SettingsContractCapabilities(
            revision: "capabilities-20",
            state: "available",
            allowed: true,
            manifestRevision: 20,
            clientFamilies: ["tv", "mobile", "tablet", "desktop", "web"],
            supportsBatchedEffective: true
        )
    }

    nonisolated func contractCapabilities(
        requestIdentity: HTTPRequestIdentity
    ) async -> SettingsCapabilitiesResult {
        await MainActor.run { capabilities }
    }

    nonisolated func effectiveValues(
        keys: [SettingKey],
        requestIdentity: HTTPRequestIdentity
    ) async throws -> EffectiveSettingValuesResponse {
        let hideWatched = await MainActor.run { hideWatchedItems }
        let rows: [[String: Any]] = keys.map { key in
            switch key {
            case .uiNextUpMode:
                return ["key": key.rawValue, "value": "combined", "source": "profile"]
            case .uiNextUpNewReleasesFirst:
                return ["key": key.rawValue, "value": false, "source": "profile"]
            case .homeHideWatchedItems:
                return ["key": key.rawValue, "value": hideWatched, "source": "profile"]
            default:
                return ["key": key.rawValue, "value": false, "source": "profile"]
            }
        }
        let data = try JSONSerialization.data(withJSONObject: ["items": rows, "revision": 1])
        return try SettingsWireCoding.makeDecoder().decode(EffectiveSettingValuesResponse.self, from: data)
    }

    nonisolated func putProfileValue(
        key: SettingKey,
        value: SettingJSONValue,
        requestIdentity: HTTPRequestIdentity
    ) async throws {}
}

@MainActor
private final class FakeHomePreferencesWriteTransport: ProfileSettingsTransport, @unchecked Sendable {
    private(set) var writtenValues: [SettingJSONValue] = []
    private var shouldHoldNext = false
    private var released = false
    private var onHeldHandler: (() -> Void)?
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func holdNextWrite(onHeld: @escaping () -> Void) {
        shouldHoldNext = true
        released = false
        onHeldHandler = onHeld
    }

    func releaseHeldWrite() {
        shouldHoldNext = false
        released = true
        onHeldHandler = nil
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    private func waitUntilReleased() async {
        if released { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    nonisolated func putValue(
        key: SettingKey,
        value: SettingJSONValue,
        profileId: String?
    ) async throws {
        try await putValue(key: key, value: value, profileId: profileId, requestIdentity: nil)
    }

    nonisolated func putValue(
        key: SettingKey,
        value: SettingJSONValue,
        profileId: String?,
        requestIdentity: HTTPRequestIdentity?
    ) async throws {
        let hold = await MainActor.run { () -> Bool in
            if shouldHoldNext {
                shouldHoldNext = false
                let handler = onHeldHandler
                onHeldHandler = nil
                handler?()
                return true
            }
            return false
        }
        if hold {
            await waitUntilReleased()
        }
        await MainActor.run {
            writtenValues.append(value)
        }
    }

    nonisolated func effectiveValues(
        keys: [SettingKey]
    ) async throws -> EffectiveSettingValuesResponse {
        let data = try JSONSerialization.data(withJSONObject: ["items": [], "revision": 1])
        return try SettingsWireCoding.makeDecoder().decode(EffectiveSettingValuesResponse.self, from: data)
    }
}
