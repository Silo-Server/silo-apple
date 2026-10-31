import Foundation
import XCTest
@testable import Silo

/// The override set a reorder or show/hide saves for the profile's Home. The
/// PUT replaces everything the profile saved for the page, so the set must
/// carry its renames, added rows and removed rows through unchanged.
final class ProfileHomeLayoutTests: XCTestCase {
    private func row(_ id: String, hidden: Bool = false, custom: Bool = false) -> APIv2ProfileSectionSetting {
        let json = #"{"id":"\#(id)","section_type":"recently_added","title":"\#(id)","default_title":"\#(id)","featured":false,"item_limit":20,"hidden":\#(hidden),"is_custom":\#(custom),"customized":false,"position":0}"#
        return try! JSONDecoder().decode(APIv2ProfileSectionSetting.self, from: Data(json.utf8))
    }

    private func ids() -> () -> String {
        var next = 0
        return { next += 1; return "new-\(next)" }
    }

    func testAReorderGivesEveryRowItsListPositionAndUnsavedAdminRowsANewOverride() {
        let overrides = ProfileHomeLayout.overrides(
            rows: [row("b"), row("a", hidden: true)],
            baseline: [row("a"), row("b")],
            saved: [],
            newID: ids()
        )

        XCTAssertEqual(overrides, [
            APIv2SectionOverride(id: "new-1", sectionId: "b", position: 0, hidden: false),
            APIv2SectionOverride(id: "new-2", sectionId: "a", position: 1, hidden: true),
        ])
    }

    func testSavedChangesSurviveAndOnlyPositionAndHiddenMove() {
        let renamed = APIv2SectionOverride(
            id: "o-a", sectionId: "a", position: 0, hidden: false, title: "My Picks",
            featured: true, itemLimit: 12, config: ["window": .string("7d")]
        )
        let built = APIv2SectionOverride(
            id: "custom-1", sectionId: "", position: 1, hidden: false, isUserAdded: true,
            userSectionType: "hidden_gems", userTitle: "Gems", userConfig: ["min_rating": .double(7.5)]
        )
        let removed = APIv2SectionOverride(id: "o-gone", sectionId: "gone", position: nil, hidden: false, removed: true)

        let overrides = ProfileHomeLayout.overrides(
            rows: [row("custom-1", hidden: true, custom: true), row("b"), row("a")],
            baseline: [row("a"), row("custom-1", custom: true), row("b")],
            saved: [renamed, built, removed],
            newID: ids()
        )

        XCTAssertEqual(overrides, [
            APIv2SectionOverride(
                id: "custom-1", sectionId: "", position: 0, hidden: true, isUserAdded: true,
                userSectionType: "hidden_gems", userTitle: "Gems", userConfig: ["min_rating": .double(7.5)]
            ),
            APIv2SectionOverride(id: "new-1", sectionId: "b", position: 1, hidden: false),
            APIv2SectionOverride(
                id: "o-a", sectionId: "a", position: 2, hidden: false, title: "My Picks",
                featured: true, itemLimit: 12, config: ["window": .string("7d")]
            ),
            removed,
        ])
    }

    func testASavedOverrideWithoutAnIdGetsOne() {
        let overrides = ProfileHomeLayout.overrides(
            rows: [row("a")],
            baseline: [row("a", hidden: true)],
            saved: [APIv2SectionOverride(id: "", sectionId: "a", position: 4, hidden: true, title: "Mine")],
            newID: ids()
        )

        XCTAssertEqual(overrides, [
            APIv2SectionOverride(id: "new-1", sectionId: "a", position: 0, hidden: false, title: "Mine"),
        ])
    }

    func testHidingARowOnAFreshProfileSavesOnlyThatRowAndNoPositions() {
        let overrides = ProfileHomeLayout.overrides(
            rows: [row("a"), row("b", hidden: true), row("c")],
            baseline: [row("a"), row("b"), row("c")],
            saved: [],
            newID: ids()
        )

        // Rows the profile never ordered keep following the admin's order.
        XCTAssertEqual(overrides, [
            APIv2SectionOverride(id: "new-1", sectionId: "b", position: nil, hidden: true),
        ])
    }

    func testHidingARowWithoutAnOrderKeepsEverySavedOverrideAsItWas() {
        let renamed = APIv2SectionOverride(id: "o-a", sectionId: "a", position: nil, hidden: false, title: "Mine")
        let built = APIv2SectionOverride(
            id: "custom-1", sectionId: "", position: 3, hidden: false, isUserAdded: true,
            userSectionType: "hidden_gems", userTitle: "Gems"
        )
        let removed = APIv2SectionOverride(id: "o-gone", sectionId: "gone", position: nil, hidden: false, removed: true)

        let overrides = ProfileHomeLayout.overrides(
            rows: [row("a", hidden: true), row("b"), row("custom-1", custom: true)],
            baseline: [row("a"), row("b"), row("custom-1", custom: true)],
            saved: [renamed, built, removed],
            newID: ids()
        )

        XCTAssertEqual(overrides, [
            APIv2SectionOverride(id: "o-a", sectionId: "a", position: nil, hidden: true, title: "Mine"),
            built,
            removed,
        ])
    }

    func testHidingARowAfterAReorderKeepsSavingTheOrder() {
        let overrides = ProfileHomeLayout.overrides(
            rows: [row("b"), row("a"), row("c", hidden: true)],
            baseline: [row("b"), row("a"), row("c")],
            saved: [
                APIv2SectionOverride(id: "o-b", sectionId: "b", position: 0, hidden: false),
                APIv2SectionOverride(id: "o-a", sectionId: "a", position: 1, hidden: false),
            ],
            newID: ids()
        )

        XCTAssertEqual(overrides, [
            APIv2SectionOverride(id: "o-b", sectionId: "b", position: 0, hidden: false),
            APIv2SectionOverride(id: "o-a", sectionId: "a", position: 1, hidden: false),
            APIv2SectionOverride(id: "new-1", sectionId: "c", position: 2, hidden: true),
        ])
    }

    func testWriteBodyOmitsUnsavedConfigsAndReadOnlyMembers() throws {
        let saved = try JSONDecoder().decode(APIv2SectionOverride.self, from: Data(
            #"{"id":"o1","section_id":"s1","position":null,"hidden":false,"removed":false,"section_type":"","title":"","featured":null,"item_limit":null,"is_user_added":false,"user_section_type":"","user_title":"","config":{"sort":{"field":"added_at"}},"created_at":"2026-01-02T03:04:05.000Z","updated_at":null}"#.utf8))

        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any])

        XCTAssertEqual(Set(object.keys), [
            "id", "section_id", "position", "hidden", "removed", "section_type", "title",
            "featured", "item_limit", "is_user_added", "user_section_type", "user_title", "config",
        ])
        XCTAssertEqual((object["config"] as? [String: Any])?["sort"] as? [String: String], ["field": "added_at"])
    }
}
