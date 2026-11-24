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
    func testReorderVisibleSlotsKeepsHiddenRowsAnchoredAndNoOpsLastToBottom() {
        let a = makeRow(id: "sec-a", position: 0)
        let h = makeRow(id: "sec-h", hidden: true, position: 1)
        let b = makeRow(id: "sec-b", position: 2)

        // Swapping visible rows A and B keeps hidden row H anchored at index 1.
        let swapped = HomeSectionsEditorModel.reorderVisibleSlots(in: [a, h, b]) { visible in
            visible.swapAt(0, 1)
            return true
        }
        XCTAssertEqual(swapped?.map(\.id), ["sec-b", "sec-h", "sec-a"])

        // Moving already-last visible row B to bottom returns nil (no-op).
        let noop = HomeSectionsEditorModel.reorderVisibleSlots(in: [a, h, b]) { visible in
            guard let index = visible.firstIndex(where: { $0.id == "sec-b" }),
                  index < visible.count - 1 else { return false }
            let row = visible.remove(at: index)
            visible.append(row)
            return true
        }
        XCTAssertNil(noop)
    }

    func testAddingCustomRowAfterHiddenAdminRowDoesNotPinAdminOrder() {
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

        let adminHidden = overrides.first { $0.sectionId == "sec-h" }
        XCTAssertNil(adminHidden?.position)
        XCTAssertNil(overrides.first { $0.sectionId == "sec-a" })
        XCTAssertNil(overrides.first { $0.sectionId == "sec-b" })
        XCTAssertEqual(overrides.first { $0.id == "custom-1" }?.position, 3)
    }
}
