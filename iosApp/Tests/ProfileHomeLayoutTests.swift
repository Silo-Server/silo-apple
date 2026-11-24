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
        let multiLibraryWatchlist = makeRow(
            id: "wl-movies-lib9-7",
            type: "watchlist",
            config: ["media_type": .string("movie"), "filter_library_ids": .array([.int(9), .int(7)])]
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
        XCTAssertTrue(HomeSectionsEditorModel.matchesRecipe(
            multiLibraryWatchlist,
            sectionType: "watchlist",
            params: ["media_type": .string("movie"), "filter_library_ids": .array([.int(7), .int(9)])]
        ))
        XCTAssertFalse(HomeSectionsEditorModel.matchesRecipe(
            multiLibraryWatchlist,
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
        defer { stub.release() }
        await stub.waitUntilHeld()

        var secondMutationRan = false
        let secondEnqueued = expectation(description: "second quick action captured identity")
        onNextIdentityRead = { secondEnqueued.fulfill() }
        let second = Task {
            await editor.performQuickAction { model in
                secondMutationRan = true
                return model.setHidden(true, id: "sec-a")
            }
        }
        await fulfillment(of: [secondEnqueued], timeout: 5.0)

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
          {"id":"col-1","name":"Favorites","collection_type":"manual","item_count":2,"creator_profile_id":"profile-one","contains":false}
        ],"groups":[]}
        """
        stub.reply(path: "/api/v2/collections/capabilities", 200, #"{"revision":"1","state":"available","allowed":true,"groups":false,"login_sharing":true,"contains_item":true}"#)
        stub.reply(path: "/api/v2/collections", 200, collectionsJSON)

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

        let failedToggle = model.startToggle(collectionId: "col-1")
        defer { stub.release() }
        // Synchronous registration guarantees Done sees the pending mutation immediately,
        // even before the scheduled Task body reaches its first network suspension.
        XCTAssertTrue(model.hasPendingMutations)
        await stub.waitUntilHeld()

        let failureWaiterRegistered = expectation(description: "Done registered mutation waiter on failure")
        model.onMutationWaiterRegistered = {
            model.onMutationWaiterRegistered = nil
            failureWaiterRegistered.fulfill()
        }
        let waitOnFailure = Task { await model.waitForPendingMutations() }
        await fulfillment(of: [failureWaiterRegistered], timeout: 5.0)
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
        let succeededToggle = model.startToggle(collectionId: "col-1")
        XCTAssertTrue(model.hasPendingMutations)
        await stub.waitUntilHeld()
        let successWaiterRegistered = expectation(description: "Done registered mutation waiter on success")
        model.onMutationWaiterRegistered = {
            model.onMutationWaiterRegistered = nil
            successWaiterRegistered.fulfill()
        }
        let waitOnSuccess = Task { await model.waitForPendingMutations() }
        await fulfillment(of: [successWaiterRegistered], timeout: 5.0)
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
        // Wait for `load()` to deterministically enter its quick-action barrier before releasing.
        let enteredLoadExpectation = expectation(description: "foreground load entered quick-action barrier")
        editor.onLoadWaitingForQuickActions = {
            editor.onLoadWaitingForQuickActions = nil
            enteredLoadExpectation.fulfill()
        }
        let foregroundLoad = Task { await editor.load() }
        await fulfillment(of: [enteredLoadExpectation], timeout: 2.0)
        stub.release()

        let result = await quickAction.value
        let loaded = await foregroundLoad.value
        XCTAssertTrue(result.succeeded)
        XCTAssertNil(result.errorMessage)
        XCTAssertTrue(loaded)
        let putRequests = stub.requests.filter { $0.method == "PUT" && $0.path == "/api/v2/profile/sections" }
        XCTAssertEqual(putRequests.count, 1)
    }

    @MainActor
    func testReplayingQueuedMovePreservesOriginalSwapTargetWhenFirstPutFails() async throws {
        let stub = APIv2TestStub()
        let name = "ProfileHomeLayoutTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(
            keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokens.switchActiveServer(serverId: "move-replay-test")
        await tokens.setServerUrl("https://move.example")
        await tokens.setProfileId("profile-one")
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let identity = HTTPRequestIdentity(
            serverId: "move-replay-test",
            serverURL: "https://move.example",
            profileId: "profile-one",
            clientFamily: "ios"
        )

        let settingsJSON = """
        {"items":[
          {"id":"sec-a","section_type":"recently_added","title":"A","default_title":"A","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":0},
          {"id":"sec-b","section_type":"recently_added","title":"B","default_title":"B","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":1},
          {"id":"sec-c","section_type":"recently_added","title":"C","default_title":"C","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":2}
        ]}
        """
        stub.reply(path: "/api/v2/profile/sections/settings", 200, settingsJSON)
        stub.reply(path: "/api/v2/profile/sections", 200, #"{"items":[]}"#)

        let editor = HomeSectionsEditorModel(scope: .home, api: api, requestIdentity: { identity })
        let loaded = await editor.load()
        XCTAssertTrue(loaded)

        // PUT #1 (moving A down past B) is definitely rejected (500).
        stub.sequence(path: "/api/v2/profile/sections", [
            .json(500, #"{"error":{"code":"internal","message":"failed"}}"#),
            .json(200, "{}"),
        ])
        stub.hold(path: "/api/v2/profile/sections")

        // Move A down -> optimistic [B, A, C]
        let move1 = editor.moveVisible(id: "sec-a", by: 1)
        await stub.waitUntilHeld()
        XCTAssertEqual(editor.rows.map(\.id), ["sec-b", "sec-a", "sec-c"])

        // While PUT #1 is in flight, move B down (intended to cross A -> [A, B, C]).
        let move2 = editor.moveVisible(id: "sec-b", by: 1)
        XCTAssertEqual(editor.rows.map(\.id), ["sec-a", "sec-b", "sec-c"])

        stub.release()
        await move1.value
        await move2.value

        // When PUT #1 fails, replaying move2 onto [A, B, C] must NOT swap B with C.
        XCTAssertEqual(editor.rows.map(\.id), ["sec-a", "sec-b", "sec-c"])
    }

    @MainActor
    func testReplayingCommittedDragDoesNotRestoreRejectedPriorReorder() async throws {
        let stub = APIv2TestStub()
        let name = "ProfileHomeLayoutTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(
            keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokens.switchActiveServer(serverId: "drag-replay-test")
        await tokens.setServerUrl("https://drag.example")
        await tokens.setProfileId("profile-one")
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let identity = HTTPRequestIdentity(
            serverId: "drag-replay-test",
            serverURL: "https://drag.example",
            profileId: "profile-one",
            clientFamily: "ios"
        )

        let settingsJSON = """
        {"items":[
          {"id":"sec-a","section_type":"recently_added","title":"A","default_title":"A","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":0},
          {"id":"sec-b","section_type":"recently_added","title":"B","default_title":"B","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":1},
          {"id":"sec-c","section_type":"recently_added","title":"C","default_title":"C","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":2}
        ]}
        """
        stub.reply(path: "/api/v2/profile/sections/settings", 200, settingsJSON)
        stub.reply(path: "/api/v2/profile/sections", 200, #"{"items":[]}"#)

        let editor = HomeSectionsEditorModel(scope: .home, api: api, requestIdentity: { identity })
        let loaded = await editor.load()
        XCTAssertTrue(loaded)

        // PUT #1 (moving C to top) is rejected; PUT #2 (replaying drag of B above A) succeeds.
        stub.sequence(path: "/api/v2/profile/sections", [
            .json(500, #"{"error":{"code":"internal","message":"failed"}}"#),
            .json(200, "{}"),
        ])
        stub.hold(path: "/api/v2/profile/sections")

        let moveC = editor.moveToTop(id: "sec-c")
        await stub.waitUntilHeld()
        XCTAssertEqual(editor.rows.map(\.id), ["sec-c", "sec-a", "sec-b"])

        // Drag B above A while PUT #1 is pending -> draft [C, B, A].
        XCTAssertTrue(editor.swapVisibleDuringDrag(id: "sec-b", by: -1))
        XCTAssertEqual(editor.rows.map(\.id), ["sec-c", "sec-b", "sec-a"])

        // When PUT #1 is rejected before drop, the live preview immediately stops
        // showing C at the top and shows [B, A, C] before commit.
        stub.release()
        await moveC.value
        XCTAssertEqual(editor.rows.map(\.id), ["sec-b", "sec-a", "sec-c"])

        let dragB = editor.commitDraggedOrder()
        await dragB.value

        // Committing the drag yields the exact same order as the live preview
        // AND sends a second PUT with B, A, C at positions 0, 1, 2.
        XCTAssertEqual(editor.rows.map(\.id), ["sec-b", "sec-a", "sec-c"])
        let putRequests = stub.requests.filter { $0.method == "PUT" && $0.path == "/api/v2/profile/sections" }
        XCTAssertEqual(putRequests.count, 2)
        struct OverridesBody: Decodable { let overrides: [APIv2SectionOverride] }
        let secondRequest = try XCTUnwrap(putRequests.dropFirst().first)
        let secondBody = try XCTUnwrap(secondRequest.body)
        let decoded = try JSONDecoder().decode(OverridesBody.self, from: secondBody)
        let positionsById = Dictionary(uniqueKeysWithValues: decoded.overrides.map { ($0.sectionId, $0.position) })
        XCTAssertEqual(positionsById["sec-b"], 0)
        XCTAssertEqual(positionsById["sec-a"], 1)
        XCTAssertEqual(positionsById["sec-c"], 2)
    }

    @MainActor
    func testReversedDragClearsDraftAndDoesNotSaveOnDropAfterRejectedPriorReorder() async throws {
        let stub = APIv2TestStub()
        let name = "ProfileHomeLayoutTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(
            keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokens.switchActiveServer(serverId: "drag-reverse-test")
        await tokens.setServerUrl("https://drag-reverse.example")
        await tokens.setProfileId("profile-one")
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let identity = HTTPRequestIdentity(
            serverId: "drag-reverse-test",
            serverURL: "https://drag-reverse.example",
            profileId: "profile-one",
            clientFamily: "ios"
        )

        let settingsJSON = """
        {"items":[
          {"id":"sec-a","section_type":"recently_added","title":"A","default_title":"A","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":0},
          {"id":"sec-b","section_type":"recently_added","title":"B","default_title":"B","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":1},
          {"id":"sec-c","section_type":"recently_added","title":"C","default_title":"C","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":2}
        ]}
        """
        stub.reply(path: "/api/v2/profile/sections/settings", 200, settingsJSON)
        stub.reply(path: "/api/v2/profile/sections", 200, #"{"items":[]}"#)

        let editor = HomeSectionsEditorModel(scope: .home, api: api, requestIdentity: { identity })
        let loaded = await editor.load()
        XCTAssertTrue(loaded)

        // PUT #1 (move C to top) will be rejected.
        stub.sequence(path: "/api/v2/profile/sections", [
            .json(500, #"{"error":{"code":"internal","message":"failed"}}"#),
        ])
        stub.hold(path: "/api/v2/profile/sections")

        let moveC = editor.moveToTop(id: "sec-c")
        await stub.waitUntilHeld()
        XCTAssertEqual(editor.rows.map(\.id), ["sec-c", "sec-a", "sec-b"])

        // Drag A up past C, then back down past C (returning to its starting slot).
        XCTAssertTrue(editor.swapVisibleDuringDrag(id: "sec-a", by: -1))
        XCTAssertEqual(editor.rows.map(\.id), ["sec-a", "sec-c", "sec-b"])
        XCTAssertTrue(editor.swapVisibleDuringDrag(id: "sec-a", by: 1))
        XCTAssertEqual(editor.rows.map(\.id), ["sec-c", "sec-a", "sec-b"])

        // PUT #1 fails -> base restores [A, B, C]. Dropping A must NOT save [B, C, A].
        stub.release()
        await moveC.value
        XCTAssertEqual(editor.rows.map(\.id), ["sec-a", "sec-b", "sec-c"])

        let dropTask = editor.commitDraggedOrder()
        await dropTask.value
        XCTAssertEqual(editor.rows.map(\.id), ["sec-a", "sec-b", "sec-c"])
        let putRequests = stub.requests.filter { $0.method == "PUT" && $0.path == "/api/v2/profile/sections" }
        XCTAssertEqual(putRequests.count, 1)
    }

    @MainActor
    func testAddToCollectionGatesMembershipOnCapabilitiesFiltersForeignSharedAndLocksUnconfirmedRows() async throws {
        let stub = APIv2TestStub()
        let name = "ProfileHomeLayoutTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(
            keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokens.switchActiveServer(serverId: "cap-test")
        await tokens.setServerUrl("https://cap.example")
        await tokens.setProfileId("profile-one")
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let identity = HTTPRequestIdentity(
            serverId: "cap-test",
            serverURL: "https://cap.example",
            profileId: "profile-one",
            clientFamily: "ios"
        )

        // 1) Server advertises contains_item: single /api/v2/collections?contains_item= read,
        //    no /api/v2/catalog/items/{id}/collections call, and other profiles' shared collections excluded.
        stub.reply(path: "/api/v2/collections/capabilities", 200, #"{"revision":"1","state":"available","allowed":true,"groups":false,"login_sharing":true,"contains_item":true}"#)
        stub.reply(path: "/api/v2/collections", 200, """
        {"items":[
          {"id":"own-1","name":"Mine","collection_type":"manual","item_count":3,"is_shared":true,"creator_profile_id":"profile-one","contains":true},
          {"id":"other-1","name":"Partner Shared","collection_type":"manual","item_count":5,"is_shared":true,"creator_profile_id":"profile-two"}
        ],"groups":[]}
        """)

        let case1Start = stub.requests.count
        let model = AddToCollectionModel(contentId: "movie-99", api: api, requestIdentity: { identity })
        await model.load()
        let case1Requests = Array(stub.requests[case1Start...])
        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(model.entries.map(\.id), ["own-1"])
        XCTAssertEqual(model.entries.first?.containsItem, true)
        let case1CollectionsReq = try XCTUnwrap(case1Requests.first { $0.path == "/api/v2/collections" })
        XCTAssertEqual(case1CollectionsReq.query["contains_item"], "movie-99")
        XCTAssertFalse(case1Requests.contains { $0.path == "/api/v2/catalog/items/movie-99/collections" })

        // 2) Server lacks both contains_item and item_collections: skips membership route
        //    and still loads the personal collection list without contains_item.
        stub.reply(path: "/api/v2/collections/capabilities", 200, #"{"revision":"1","state":"available","allowed":true,"groups":false,"login_sharing":false,"contains_item":false}"#)
        stub.reply(path: "/api/v2/catalog/search/capabilities", 200, #"{"revision":"1","state":"available","allowed":true,"item_collections":false}"#)
        let case2Start = stub.requests.count
        let olderModel = AddToCollectionModel(contentId: "movie-99", api: api, requestIdentity: { identity })
        await olderModel.load()
        let case2Requests = Array(stub.requests[case2Start...])
        XCTAssertTrue(olderModel.hasLoaded)
        XCTAssertEqual(olderModel.entries.map(\.id), ["own-1"])
        XCTAssertNil(olderModel.entries.first?.containsItem)
        let case2CollectionsReq = try XCTUnwrap(case2Requests.first { $0.path == "/api/v2/collections" })
        XCTAssertNil(case2CollectionsReq.query["contains_item"])
        XCTAssertFalse(case2Requests.contains { $0.path == "/api/v2/catalog/items/movie-99/collections" })

        // 3) Recoverable capability probe failures (e.g. 503) still load the personal
        //    collection list with unknown membership instead of blocking the picker.
        stub.reply(path: "/api/v2/collections/capabilities", 503, #"{"error":{"code":"unavailable","message":"degraded"}}"#)
        stub.reply(path: "/api/v2/catalog/search/capabilities", 503, #"{"error":{"code":"unavailable","message":"degraded"}}"#)
        let degradedModel = AddToCollectionModel(contentId: "movie-99", api: api, requestIdentity: { identity })
        await degradedModel.load()
        XCTAssertTrue(degradedModel.hasLoaded)
        XCTAssertEqual(degradedModel.entries.map(\.id), ["own-1"])
        XCTAssertNil(degradedModel.entries.first?.containsItem)

        // 4) Unconfirmed row after failed load + uncertain toggle stays locked even when
        //    a degraded reload loads the list without confirmed membership, and unlocks
        //    only once Retry confirms membership from the server.
        stub.reply(path: "/api/v2/collections", 500, #"{"error":{"code":"internal","message":"down"}}"#)
        let recoveryModel = AddToCollectionModel(contentId: "movie-99", api: api, requestIdentity: { identity })
        await recoveryModel.load()
        XCTAssertFalse(recoveryModel.hasLoaded)

        stub.reply(path: "/api/v2/collections", 201, #"{"id":"new-1","name":"Weekend","collection_type":"manual","item_count":0,"creator_profile_id":"profile-one"}"#)
        stub.reply(path: "/api/v2/collections/new-1/items/movie-99", 204, "")
        let created = await recoveryModel.createAndAdd(name: "Weekend")
        XCTAssertEqual(created, .createdAndAdded)
        XCTAssertEqual(recoveryModel.entries.map(\.id), ["new-1"])

        // Removing fails with uncertain outcome (no response / network error -> mayHaveApplied)
        // while reconciliation fails on /api/v2/collections.
        stub.reply(path: "/api/v2/collections", 500, #"{"error":{"code":"internal","message":"down"}}"#)
        stub.sequence(path: "/api/v2/collections/new-1/items/movie-99", [.failure(URLError(.networkConnectionLost))])
        await recoveryModel.toggle(collectionId: "new-1")
        XCTAssertTrue(recoveryModel.unconfirmedCollectionIds.contains("new-1"))

        let requestsBeforeBlockedTap = stub.requests.count
        await recoveryModel.toggle(collectionId: "new-1")
        XCTAssertEqual(stub.requests.count, requestsBeforeBlockedTap)

        // Degraded Retry (collections succeeds, capability probes still 503): list loads
        // with unknown membership, but "new-1" stays locked until membership is confirmed.
        stub.reply(path: "/api/v2/collections", 200, """
        {"items":[
          {"id":"new-1","name":"Weekend","collection_type":"manual","item_count":0,"creator_profile_id":"profile-one"}
        ],"groups":[]}
        """)
        await recoveryModel.load()
        XCTAssertTrue(recoveryModel.hasLoaded)
        XCTAssertNil(recoveryModel.entries.first?.containsItem)
        XCTAssertTrue(recoveryModel.unconfirmedCollectionIds.contains("new-1"))

        // Confirmed Retry succeeds and unlocks the row.
        stub.reply(path: "/api/v2/collections/capabilities", 200, #"{"revision":"1","state":"available","allowed":true,"groups":false,"login_sharing":true,"contains_item":true}"#)
        stub.reply(path: "/api/v2/collections", 200, """
        {"items":[
          {"id":"new-1","name":"Weekend","collection_type":"manual","item_count":0,"creator_profile_id":"profile-one","contains":false}
        ],"groups":[]}
        """)
        await recoveryModel.load()
        XCTAssertTrue(recoveryModel.hasLoaded)
        XCTAssertEqual(recoveryModel.entries.first?.containsItem, false)
        XCTAssertTrue(recoveryModel.unconfirmedCollectionIds.isEmpty)
    }

    @MainActor
    func testCollectionPlacementGatesSharingOnLoginSharingAndCreator() async throws {
        let stub = APIv2TestStub()
        let name = "ProfileHomeLayoutTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(
            keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokens.switchActiveServer(serverId: "share-gate-test")
        await tokens.setServerUrl("https://share.example")
        await tokens.setProfileId("profile-owner")
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let identity = HTTPRequestIdentity(
            serverId: "share-gate-test",
            serverURL: "https://share.example",
            profileId: "profile-owner",
            clientFamily: "ios"
        )

        stub.reply(path: "/api/v2/profile/sections/settings", 200, #"{"items":[]}"#)
        stub.reply(path: "/api/v2/profile/sections", 200, #"{"items":[]}"#)

        // 1) login_sharing false -> Share hidden without shareLoadFailed.
        stub.reply(path: "/api/v2/collections/capabilities", 200, #"{"revision":"1","state":"available","allowed":true,"groups":false,"login_sharing":false}"#)
        stub.sequence(path: "/api/v2/collections/col-1", [
            .json(
                200,
                #"{"id":"col-1","name":"Mine","collection_type":"manual","is_shared":false,"creator_profile_id":"profile-owner"}"#,
                headers: ["ETag": #""v1""#]
            ),
        ])
        let noSharingModel = CollectionPlacementModel(
            collectionId: "col-1",
            title: "Mine",
            isUserCollection: true,
            api: api,
            requestIdentity: { identity }
        )
        await noSharingModel.load()
        XCTAssertFalse(noSharingModel.canToggleShare)
        XCTAssertFalse(noSharingModel.shareLoadFailed)

        // 2) login_sharing true but another profile is creator -> Share hidden.
        stub.reply(path: "/api/v2/collections/capabilities", 200, #"{"revision":"1","state":"available","allowed":true,"groups":false,"login_sharing":true}"#)
        stub.sequence(path: "/api/v2/collections/col-1", [
            .json(
                200,
                #"{"id":"col-1","name":"Shared By Other","collection_type":"manual","is_shared":true,"creator_profile_id":"profile-other"}"#,
                headers: ["ETag": #""v1""#]
            ),
        ])
        let viewerModel = CollectionPlacementModel(
            collectionId: "col-1",
            title: "Shared By Other",
            isUserCollection: true,
            api: api,
            requestIdentity: { identity }
        )
        await viewerModel.load()
        XCTAssertFalse(viewerModel.canToggleShare)
        XCTAssertFalse(viewerModel.shareLoadFailed)

        // 3) login_sharing true and acting profile is creator -> Share enabled.
        stub.sequence(path: "/api/v2/collections/col-1", [
            .json(
                200,
                #"{"id":"col-1","name":"Mine","collection_type":"manual","is_shared":true,"creator_profile_id":"profile-owner"}"#,
                headers: ["ETag": #""v2""#]
            ),
        ])
        let ownerModel = CollectionPlacementModel(
            collectionId: "col-1",
            title: "Mine",
            isUserCollection: true,
            api: api,
            requestIdentity: { identity }
        )
        await ownerModel.load()
        XCTAssertTrue(ownerModel.canToggleShare)
        XCTAssertTrue(ownerModel.isShared)
        XCTAssertFalse(ownerModel.shareLoadFailed)
    }

    func testRemovingCustomRowUpdatesSurvivingCustomRowPositionsWithoutPinningAdminOrder() {
        let a = makeRow(id: "admin-a", position: 0)
        let x = makeRow(id: "custom-x", isCustom: true, position: 1)
        let b = makeRow(id: "admin-b", position: 2)
        let y = makeRow(id: "custom-y", isCustom: true, position: 3)
        let c = makeRow(id: "admin-c", position: 4)
        let baseline = [a, x, b, y, c]
        let saved: [APIv2SectionOverride] = [
            APIv2SectionOverride(id: "custom-x", sectionId: "", position: 1, hidden: false, isUserAdded: true, userSectionType: "collection", userTitle: "X"),
            APIv2SectionOverride(id: "custom-y", sectionId: "", position: 3, hidden: false, isUserAdded: true, userSectionType: "collection", userTitle: "Y"),
        ]

        // Remove custom-x -> [A, B, Y, C]. Surviving custom-y must update to position 2
        // without pinning admin rows A, B, or C.
        let updated = ProfileHomeLayout.overrides(rows: [a, b, y, c], baseline: baseline, saved: saved)
        XCTAssertEqual(updated.map(\.id), ["custom-y"])
        XCTAssertEqual(updated.first?.position, 2)
    }

    @MainActor
    func testHomePreferencesReconcilesWhenRefusalFollowsEarlierRetryableFailure() async throws {
        let identity = HTTPRequestIdentity(
            serverId: "prefs-retry-refusal",
            serverURL: "https://prefs.example",
            profileId: "profile-one",
            clientFamily: "ios"
        )
        let scopedTransport = FakeHomePreferencesTransport()
        let writeTransport = FakeHomePreferencesWriteTransport()
        let writer = ProfileSettingsWriter(
            transport: writeTransport,
            retryPolicy: .init(maximumAutomaticRetries: 2, base: .milliseconds(1), maximum: .milliseconds(1)),
            sleep: { _ in }
        )
        let model = HomePreferencesModel(
            transport: scopedTransport,
            writer: writer,
            requestIdentity: { identity }
        )

        await model.load()
        XCTAssertFalse(model.hideWatchedItems)

        // 1) A first-attempt refusal (403) with no prior retryable failure rolls back cleanly.
        writeTransport.queuedErrors = [
            SettingsAPIError.server(status: 403, code: "forbidden", message: "Denied"),
        ]
        model.setHideWatchedItems(true)
        for _ in 0..<100 {
            if !model.isSaving && model.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.hideWatchedItems)
        XCTAssertFalse(model.hasReconcilingKeys)

        // 2) An earlier retryable failure (response lost — server applied `true`) followed
        //    by a refusal (403) on retry must report uncertainty and reconcile from the server
        //    instead of rolling back to `false`.
        scopedTransport.hideWatchedItems = true
        writeTransport.queuedErrors = [
            SettingsAPIError.transport(description: "response lost"),
            SettingsAPIError.server(status: 403, code: "forbidden", message: "Denied"),
        ]
        let writesBefore = writeTransport.writtenValues.count
        model.setHideWatchedItems(true)
        for _ in 0..<100 {
            if writeTransport.writtenValues.count >= writesBefore + 2,
               !model.isSaving,
               !model.hasReconcilingKeys,
               model.errorMessage != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(writeTransport.writtenValues.count, writesBefore + 2)
        XCTAssertTrue(model.hideWatchedItems)
        XCTAssertFalse(model.hasReconcilingKeys)
        XCTAssertNotNil(model.errorMessage)

        // 3) A retryable failure followed by `serverUpgradeRequired` preserves the
        //    terminal upgrade classification instead of wrapping in `HeldChange`.
        writeTransport.queuedErrors = [
            SettingsAPIError.transport(description: "response lost"),
            SettingsAPIError.serverUpgradeRequired,
        ]
        do {
            try await writer.write(.homeHideWatchedItems, value: .bool(false), profileId: identity.profileId)
            XCTFail("Expected serverUpgradeRequired to be thrown")
        } catch let error as SettingsAPIError {
            XCTAssertEqual(error, .serverUpgradeRequired)
        } catch {
            XCTFail("Expected SettingsAPIError.serverUpgradeRequired, got \(error)")
        }
    }

    @MainActor
    func testHomePreferencesReportsDeferredEditDroppedWhenRecoveryFindsUnsupportedCapabilities() async throws {
        let identity = HTTPRequestIdentity(
            serverId: "prefs-drop-deferred",
            serverURL: "https://prefs.example",
            profileId: "profile-one",
            clientFamily: "ios"
        )
        let scopedTransport = FakeHomePreferencesTransport()
        let writeTransport = FakeHomePreferencesWriteTransport()
        let writer = ProfileSettingsWriter(transport: writeTransport, sleep: { _ in })
        let model = HomePreferencesModel(
            transport: scopedTransport,
            writer: writer,
            requestIdentity: { identity }
        )

        await model.load()
        XCTAssertTrue(model.isAuthorized)

        let heldExpectation = expectation(description: "first write held")
        defer { writeTransport.releaseHeldWrite() }
        writeTransport.holdNextWrite(onHeld: { heldExpectation.fulfill() })
        model.setHideWatchedItems(true)
        await fulfillment(of: [heldExpectation], timeout: 2.0)

        // Queue a second write while Write 1 is in flight, then lose authorization.
        model.setHideWatchedItems(false)
        scopedTransport.capabilities = .failed(.transport(description: "offline"))
        await model.load()
        XCTAssertFalse(model.isAuthorized)

        // Recovery discovers the server no longer supports settings (.unavailable).
        scopedTransport.capabilities = .unavailable
        writeTransport.releaseHeldWrite()

        let settled = await model.waitForPendingWrites()
        XCTAssertFalse(settled, "waitForPendingWrites must report the dropped deferred edit as unsaved")
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testAddToCollectionPreservesFallbackMembershipAndMarksCountUnknownWhenPostAddRefreshFails() async throws {
        let stub = APIv2TestStub()
        let name = "ProfileHomeLayoutTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(
            keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokens.switchActiveServer(serverId: "fallback-count-test")
        await tokens.setServerUrl("https://fallback.example")
        await tokens.setProfileId("profile-one")
        let api = SiloAPI(http: HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokenStore: tokens)
        let identity = HTTPRequestIdentity(
            serverId: "fallback-count-test",
            serverURL: "https://fallback.example",
            profileId: "profile-one",
            clientFamily: "ios"
        )

        // 1) Create-and-add before initial load completes on a server with neither
        //    contains_item nor item_collections: recovery read returns the new collection
        //    with nil membership, and must preserve confirmed membership (`true`) from fallbackEntry.
        stub.reply(path: "/api/v2/collections/capabilities", 200, #"{"revision":"1","state":"available","allowed":true,"groups":false,"login_sharing":false,"contains_item":false}"#)
        stub.reply(path: "/api/v2/catalog/search/capabilities", 200, #"{"revision":"1","state":"available","allowed":true,"item_collections":false}"#)
        stub.reply(path: "/api/v2/collections", 500, #"{"error":{"code":"internal","message":"down"}}"#)

        let model = AddToCollectionModel(contentId: "movie-77", api: api, requestIdentity: { identity })
        await model.load()
        XCTAssertFalse(model.hasLoaded)

        stub.sequence(path: "/api/v2/collections", [
            .json(201, #"{"id":"new-col","name":"New","collection_type":"manual","item_count":0,"creator_profile_id":"profile-one"}"#),
            .json(200, """
            {"items":[
              {"id":"new-col","name":"New","collection_type":"manual","item_count":1,"creator_profile_id":"profile-one"},
              {"id":"old-col","name":"Old","collection_type":"manual","item_count":2,"creator_profile_id":"profile-one"}
            ],"groups":[]}
            """),
        ])
        stub.reply(path: "/api/v2/collections/new-col/items/movie-77", 204, "")
        let created = await model.createAndAdd(name: "New")
        XCTAssertEqual(created, .createdAndAdded)
        XCTAssertTrue(model.hasLoaded)
        XCTAssertEqual(model.entries.first(where: { $0.id == "new-col" })?.containsItem, true)
        XCTAssertNil(model.entries.first(where: { $0.id == "old-col" })?.containsItem)
        XCTAssertEqual(model.entries.first(where: { $0.id == "old-col" })?.itemCount, 2)

        // 2) Adding from unknown membership when the post-add count refresh fails must
        //    keep confirmed membership (`true`) and mark `itemCount` as `nil` (unknown)
        //    so a subsequent remove does not decrement the stale pre-add count (`2 -> 1`).
        stub.reply(path: "/api/v2/collections", 503, #"{"error":{"code":"unavailable","message":"busy"}}"#)
        stub.reply(path: "/api/v2/collections/old-col/items/movie-77", 204, "")
        await model.toggle(collectionId: "old-col")
        let afterAdd = try XCTUnwrap(model.entries.first(where: { $0.id == "old-col" }))
        XCTAssertEqual(afterAdd.containsItem, true)
        XCTAssertNil(afterAdd.itemCount)

        await model.toggle(collectionId: "old-col")
        let afterRemove = try XCTUnwrap(model.entries.first(where: { $0.id == "old-col" }))
        XCTAssertEqual(afterRemove.containsItem, false)
        XCTAssertNil(afterRemove.itemCount)

        // 3) Combined contains_item read failing with 503 still falls back to unfiltered
        //    /api/v2/collections so the list stays available with unknown membership.
        stub.reply(path: "/api/v2/collections/capabilities", 200, #"{"revision":"1","state":"available","allowed":true,"groups":false,"login_sharing":false,"contains_item":true}"#)
        stub.sequence(path: "/api/v2/collections", [
            .json(503, #"{"error":{"code":"unavailable","message":"membership query failed"}}"#),
            .json(200, """
            {"items":[
              {"id":"old-col","name":"Old","collection_type":"manual","item_count":2,"creator_profile_id":"profile-one"}
            ],"groups":[]}
            """),
        ])
        let fallbackModel = AddToCollectionModel(contentId: "movie-77", api: api, requestIdentity: { identity })
        await fallbackModel.load()
        XCTAssertTrue(fallbackModel.hasLoaded)
        XCTAssertEqual(fallbackModel.entries.map(\.id), ["old-col"])
        XCTAssertNil(fallbackModel.entries.first?.containsItem)
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
    var queuedErrors: [Error] = []
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
        let nextError: Error? = await MainActor.run {
            writtenValues.append(value)
            return queuedErrors.isEmpty ? nil : queuedErrors.removeFirst()
        }
        if let nextError {
            throw nextError
        }
    }

    nonisolated func effectiveValues(
        keys: [SettingKey]
    ) async throws -> EffectiveSettingValuesResponse {
        let data = try JSONSerialization.data(withJSONObject: ["items": [], "revision": 1])
        return try SettingsWireCoding.makeDecoder().decode(EffectiveSettingValuesResponse.self, from: data)
    }
}
