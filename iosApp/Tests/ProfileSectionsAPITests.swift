import Foundation
import XCTest
@testable import Silo

/// The acting profile's own Home layout through `SiloAPI` on `/api/v2`: both
/// reads and the replacing write are scoped to Home and to the profile the
/// session acts as, and a section's config keys travel unchanged.
final class ProfileSectionsAPITests: XCTestCase {
    static let settingsJSON = #"{"items":[{"id":"s-cw","section_type":"continue_watching","title":"Continue Watching","default_title":"Continue Watching","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":0,"config":{"continue_type":"watching"}},{"id":"c-1","section_type":"hidden_gems","title":"Gems","default_title":"","featured":false,"item_limit":20,"hidden":true,"is_custom":true,"customized":false,"position":1}]}"#
    static let overridesJSON = #"{"items":[{"id":"c-1","section_id":"","position":1,"hidden":true,"removed":false,"section_type":"","title":"","featured":null,"item_limit":null,"is_user_added":true,"user_section_type":"hidden_gems","user_title":"Gems","user_config":{"min_rating":7.5},"created_at":"2026-01-02T03:04:05.000Z","updated_at":"2026-01-02T03:04:05.000Z"},{"id":"o-gone","section_id":"s-gone","position":null,"hidden":false,"removed":true,"section_type":"","title":"","featured":null,"item_limit":null,"is_user_added":false,"user_section_type":"","user_title":"","created_at":null,"updated_at":null}]}"#

    private func client(stub: APIv2TestStub) async throws -> (SiloAPI, TokenStore) {
        let name = "ProfileSectionsAPITests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "profile-sections-test")
        await tokens.setServerUrl("https://sections.example")
        await tokens.setProfileId("profile-one")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        return (SiloAPI(http: http, tokenStore: tokens), tokens)
    }

    func testLayoutReadsBothHomeListsAsTheActingProfile() async throws {
        let stub = APIv2TestStub()
        let (api, tokens) = try await client(stub: stub)
        stub.reply(path: "/api/v2/profile/sections/settings", 200, Self.settingsJSON)
        stub.reply(path: "/api/v2/profile/sections", 200, Self.overridesJSON)

        let layout = try await api.profileHomeLayout()

        XCTAssertEqual(stub.requests.map(\.method), ["GET", "GET"])
        XCTAssertEqual(Set(stub.requests.map(\.path)), ["/api/v2/profile/sections/settings", "/api/v2/profile/sections"])
        for request in stub.requests {
            XCTAssertEqual(request.query, ["scope": "home"])
            XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        }
        XCTAssertEqual(layout.rows.map(\.id), ["s-cw", "c-1"])
        XCTAssertEqual(layout.rows.map(\.hidden), [false, true])
        XCTAssertEqual(layout.rows.map(\.isCustom), [false, true])
        XCTAssertEqual(layout.rows.first?.config, ["continue_type": .string("watching")])
        XCTAssertEqual(layout.saved, [
            APIv2SectionOverride(
                id: "c-1", sectionId: "", position: 1, hidden: true, isUserAdded: true,
                userSectionType: "hidden_gems", userTitle: "Gems", userConfig: ["min_rating": .double(7.5)]
            ),
            APIv2SectionOverride(id: "o-gone", sectionId: "s-gone", position: nil, hidden: false, removed: true),
        ])
        let owns = await api.isCurrentOwner(layout.auth)
        XCTAssertTrue(owns)
        await tokens.setProfileId("profile-two")
        let stillOwns = await api.isCurrentOwner(layout.auth)
        XCTAssertFalse(stillOwns)
    }

    func testDuplicateRowIdsAreRefusedRatherThanEdited() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        let row = #"{"id":"s-cw","section_type":"continue_watching","title":"CW","default_title":"CW","featured":false,"item_limit":20,"hidden":false,"is_custom":false,"customized":false,"position":0}"#
        stub.reply(path: "/api/v2/profile/sections/settings", 200, #"{"items":[\#(row),\#(row)]}"#)
        stub.reply(path: "/api/v2/profile/sections", 200, #"{"items":[]}"#)

        do {
            _ = try await api.profileHomeLayout()
            XCTFail("Rows that cannot be told apart must not reach the editor")
        } catch {}
    }

    func testSaveReplacesTheHomeOverrideSetForTheReadsOwner() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(path: "/api/v2/profile/sections/settings", 200, Self.settingsJSON)
        stub.reply(path: "/api/v2/profile/sections", 200, Self.overridesJSON)
        let layout = try await api.profileHomeLayout()
        stub.sequence([.json(204, "")])

        try await api.saveProfileHomeLayout([
            APIv2SectionOverride(id: "n-1", sectionId: "s-cw", position: 0, hidden: true,
                                 config: ["sort": .object(["field": .string("added_at")])]),
        ], auth: layout.auth)

        let request = try XCTUnwrap(stub.requests.last)
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.path, "/api/v2/profile/sections")
        XCTAssertEqual(request.query, ["scope": "home"])
        XCTAssertEqual(request.header("x-profile-id"), "profile-one")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        let overrides = try XCTUnwrap(body["overrides"] as? [[String: Any]])
        XCTAssertEqual(Set(body.keys), ["overrides"])
        XCTAssertEqual(overrides.count, 1)
        XCTAssertEqual(overrides[0]["id"] as? String, "n-1")
        XCTAssertEqual(overrides[0]["section_id"] as? String, "s-cw")
        XCTAssertEqual(overrides[0]["position"] as? Int, 0)
        XCTAssertEqual(overrides[0]["hidden"] as? Bool, true)
        XCTAssertEqual((overrides[0]["config"] as? [String: Any])?["sort"] as? [String: String], ["field": "added_at"])
    }

    func testSaveIsRefusedOnceTheProfileChanged() async throws {
        let stub = APIv2TestStub()
        let (api, tokens) = try await client(stub: stub)
        stub.reply(path: "/api/v2/profile/sections/settings", 200, Self.settingsJSON)
        stub.reply(path: "/api/v2/profile/sections", 200, Self.overridesJSON)
        let layout = try await api.profileHomeLayout()
        let reads = stub.requests.count
        await tokens.setProfileId("profile-two")

        do {
            try await api.saveProfileHomeLayout([], auth: layout.auth)
            XCTFail("One profile's layout must never be written over another's")
        } catch {}
        XCTAssertEqual(stub.requests.count, reads)
    }

    func testSaveThrowsUnlessTheServerAnswersNoContent() async throws {
        let stub = APIv2TestStub()
        let (api, _) = try await client(stub: stub)
        stub.reply(path: "/api/v2/profile/sections/settings", 200, Self.settingsJSON)
        stub.reply(path: "/api/v2/profile/sections", 200, Self.overridesJSON)
        let layout = try await api.profileHomeLayout()
        stub.sequence([
            .json(200, "{}"),
            .json(422, #"{"type":"https://siloserver.org/docs/api/v2/problems/validation_failed","title":"Validation failed","status":422,"detail":"Bad set."}"#),
        ])

        for _ in 0..<2 {
            do {
                try await api.saveProfileHomeLayout([], auth: layout.auth)
                XCTFail("Only 204 confirms the save")
            } catch {}
        }
    }
}
